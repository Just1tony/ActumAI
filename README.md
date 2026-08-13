# Actum Intelligence Platform

**A production-grade, GPU-aware LLM inference platform on Kubernetes**

Actum Intelligence Platform packages [vLLM](https://github.com/vllm-project/vllm)
— a high-throughput, memory-efficient inference engine — as a hardened,
autoscaling, OpenAI-API-compatible service on Kubernetes. It is built as a
reference example of production LLMOps and Cloud-Native GPU platform
engineering: multi-stage container hardening, GPU-aware scheduling, model
weight caching, GPU-utilization-driven autoscaling, and defense-in-depth
Pod security.

---

## 1. Architecture

```
                                    ┌─────────────────────────────┐
                                    │   Client (OpenAI SDK / curl) │
                                    └──────────────┬────────────────┘
                                                   │ HTTP :80
                                                   ▼
┌──────────────────────────────────────────────────────────────────────────┐
│                      Kubernetes Cluster (namespace: actum)                │
│                                                                            │
│   ┌────────────────────────────────────────────────────────────────┐    │
│   │       Service "actum-intelligence" (ClusterIP, port 80)         │    │
│   │              routes to pods via selector labels                 │    │
│   └───────────────────────────────┬────────────────────────────────┘    │
│                                   │                                       │
│         ┌─────────────────────────┼─────────────────────────┐            │
│         ▼                         ▼                         ▼            │
│   ┌───────────┐             ┌───────────┐             ┌───────────┐     │
│   │  Pod 1     │             │  Pod 2     │             │  Pod N     │     │
│   │ vLLM       │             │ vLLM       │             │ vLLM       │     │
│   │ container  │             │ container  │             │ container  │     │
│   │ non-root   │             │ non-root   │             │ non-root   │     │
│   │ (uid 10001)│             │ (uid 10001)│             │ (uid 10001)│     │
│   │ GPU: 1     │             │ GPU: 1     │             │ GPU: 1     │     │
│   └─────┬──────┘             └─────┬──────┘             └─────┬──────┘     │
│         │ PVC (RWO/node-local)     │                          │            │
│         ▼                         ▼                          ▼            │
│   ┌────────────────────────────────────────────────────────────────┐    │
│   │       Hugging Face model-weight cache (PersistentVolume)         │    │
│   └────────────────────────────────────────────────────────────────┘    │
│                                                                            │
│   Scheduling constraints on every pod above:                             │
│     nodeSelector: nvidia.com/gpu.present=true                            │
│     tolerations:  nvidia.com/gpu=present:NoSchedule                      │
│                                                                            │
│   ┌────────────────────────────────────────────────────────────────┐    │
│   │                 GPU Node Pool (tainted, labeled)                  │    │
│   │  containerd → nvidia-container-toolkit → NVIDIA driver → GPU(s)   │    │
│   │  (provisioned by scripts/cluster-bootstrap.sh)                    │    │
│   └────────────────────────────────────────────────────────────────┘    │
│                                                                            │
│   ┌────────────────────────────────────────────────────────────────┐    │
│   │           HorizontalPodAutoscaler (autoscaling/v2)                │    │
│   │   metric 1: actum_vllm_gpu_utilization_percent  (Pods, custom)    │    │
│   │              ← DCGM Exporter → Prometheus → Prometheus Adapter    │    │
│   │   metric 2: cpu utilization                     (Resource)        │    │
│   │   scale-up: fast (30s window) | scale-down: slow (300s window)    │    │
│   └────────────────────────────────────────────────────────────────┘    │
│                                                                            │
│   ┌────────────────────────────────────────────────────────────────┐    │
│   │  PodDisruptionBudget (minAvailable: 2)  +  ServiceMonitor         │    │
│   │  (scrapes /metrics for Prometheus: latency, throughput, KV-cache) │    │
│   └────────────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────────────┘
```

### Component map

| Concern                        | Artifact                                              |
|----------------------------------|----------------------------------------------------------|
| Container image                  | `docker/Dockerfile` — multi-stage, non-root, CUDA runtime |
| Chart metadata                   | `charts/actum-intelligence/Chart.yaml`                    |
| Configuration surface             | `charts/actum-intelligence/values.yaml`                    |
| Workload + model cache PVC        | `templates/deployment.yaml`                                |
| Network exposure                  | `templates/service.yaml`                                   |
| GPU-aware autoscaling             | `templates/hpa.yaml`                                        |
| Availability guarantee            | `templates/poddisruptionbudget.yaml`                        |
| Identity / least privilege        | `templates/serviceaccount.yaml`                              |
| Observability wiring              | `templates/servicemonitor.yaml`                               |
| GPU node provisioning              | `scripts/cluster-bootstrap.sh`                                |

---

## 2. Container image hardening (`docker/Dockerfile`)

- **Multi-stage build**: the `builder` stage (CUDA `devel` image, compilers,
  pip) is discarded entirely; the `runtime` stage (CUDA `runtime` image)
  only receives the pre-built virtualenv via `COPY --from=builder`. The
  final image ships zero compilers, zero package indices, and zero build
  caches.
- **Non-root execution**: a dedicated system user `actum` (uid/gid `10001`)
  is created with `--no-create-home --shell /usr/sbin/nologin`, and `USER
  actum:actum` is set before the entrypoint. This is enforced redundantly at
  the Kubernetes layer via `securityContext.runAsNonRoot: true` and an
  explicit `runAsUser: 10001` in `values.yaml`, so a misconfigured image
  tag can never silently run as root in the cluster.
- **Pinned, auditable versions**: base images, Python, and every installed
  package (`vllm==0.6.3`, `ray[default]==2.38.0`, etc.) are pinned to exact
  versions — never `:latest` — for reproducible builds and clean CVE
  triage.
- **Model-agnostic image**: the entrypoint is the vLLM OpenAI-compatible
  server module with no baked-in model. Which model is served is entirely
  a Helm `values.yaml` concern (`vllm.model`), so one image serves every
  model on the platform.
- **Built-in healthcheck**: a `HEALTHCHECK` instruction mirrors the
  Kubernetes readiness probe so the same failure signal works under plain
  `docker run` / Nomad / ECS, not only Kubernetes.

---

## 3. GPU resource management

### 3.1 Requesting GPUs

Kubernetes schedules GPUs as an [extended
resource](https://kubernetes.io/docs/tasks/manage-gpus/scheduling-gpus/).
Every pod requests exactly one whole GPU — vLLM does not support fractional
GPU sharing safely for a single model replica — via:

```yaml
resources:
  requests:
    nvidia.com/gpu: 1
  limits:
    nvidia.com/gpu: 1     # requests == limits is mandatory for GPUs;
                           # the device plugin does not support overcommit
```

`nvidia.com/gpu` **must** have `requests == limits`: the NVIDIA device
plugin does not support GPU overcommitment or bursting, unlike CPU/memory.

### 3.2 Scheduling isolation

GPU nodes are **labeled and tainted** by `scripts/cluster-bootstrap.sh`:

```bash
kubectl label node <NODE> nvidia.com/gpu.present=true
kubectl taint node <NODE> nvidia.com/gpu=present:NoSchedule
```

The Helm chart's `nodeSelector` + `tolerations` (see `values.yaml`) are the
matching half of this contract: inference pods are the *only* workloads
that both tolerate the taint and match the label selector, guaranteeing
expensive GPU nodes never get occupied by unrelated CPU workloads, and that
inference pods never accidentally land on a non-GPU node.

### 3.3 Shared memory

vLLM's tensor-parallel workers and Ray's object store communicate via POSIX
shared memory. The chart provisions a dedicated `emptyDir{medium: Memory}`
volume mounted at `/dev/shm`, explicitly sized via `values.yaml`
(`shmSizeLimit: 8Gi`) — the container-runtime default of 64Mi causes silent,
hard-to-diagnose crashes under multi-worker load.

### 3.4 Autoscaling on real GPU load

`templates/hpa.yaml` scales on `actum_vllm_gpu_utilization_percent`, a
**custom metric** sourced from the NVIDIA DCGM Exporter → Prometheus →
Prometheus Adapter → Kubernetes Custom Metrics API. CPU utilization is kept
as a secondary safety-net signal only, since CPU is a poor proxy for load on
a GPU-bound inference workload. Required one-time cluster wiring:

```bash
helm install dcgm-exporter gpu-helm-charts/dcgm-exporter -n monitoring
helm install prometheus-adapter prometheus-community/prometheus-adapter \
  -n monitoring -f prometheus-adapter-values.yaml   # maps DCGM_FI_DEV_GPU_UTIL
```

Scale-up is fast (30s stabilization window, up to +100%/min) because
latency under load is user-facing; scale-down is deliberately slow (300s
window, -1 pod/2min) because every replacement replica pays a multi-minute
GPU model-load cost — flapping is far more expensive than a delayed
scale-down.

### 3.5 Model weight caching

A `ReadWriteOnce` `PersistentVolumeClaim` (`modelCache`, default 300Gi,
encrypted `gp3` storage class) is mounted at `/data/hf-cache` and set as
`HF_HOME`, so Hugging Face model weights are downloaded once and reused
across pod restarts/rollouts rather than re-downloaded from the Hub on
every cold start.

---

## 4. Security posture

| Control                              | Where enforced                                                  |
|----------------------------------------|--------------------------------------------------------------------|
| Non-root container process              | Dockerfile `USER actum:actum` + `securityContext.runAsUser: 10001` |
| No privilege escalation                 | `securityContext.allowPrivilegeEscalation: false`                    |
| All Linux capabilities dropped          | `securityContext.capabilities.drop: [ALL]`                            |
| Seccomp                                 | `podSecurityContext.seccompProfile.type: RuntimeDefault`               |
| No Kubernetes API access from the pod   | `serviceAccount.automountServiceAccountToken: false`                    |
| Explicit CPU/memory/GPU limits          | `resources.limits` in `values.yaml`                                     |
| Registry authentication                 | `imagePullSecrets`                                                      |
| Minimum serving capacity during drains  | `PodDisruptionBudget.minAvailable: 2`                                    |
| Zero-downtime rollouts                  | `RollingUpdate` with `maxUnavailable: 0`                                  |

---

## 5. Installation

### 5.1 Prerequisites

- Kubernetes >= 1.27 with at least one GPU-enabled node pool
- Helm >= 3.14
- `nvidia-device-plugin` DaemonSet installed cluster-wide (exposes
  `nvidia.com/gpu` as a schedulable resource)
- (Optional, for GPU-based HPA) DCGM Exporter + Prometheus + Prometheus
  Adapter, as described in §3.4

### 5.2 Bootstrap a GPU node

Run once per new GPU node, as root:

```bash
sudo scripts/cluster-bootstrap.sh
```

This installs/verifies the NVIDIA driver, installs the NVIDIA Container
Toolkit, configures containerd's default runtime, runs an end-to-end
in-container GPU verification, and applies the scheduler label/taint. The
script is idempotent and safe to re-run; it exits with code `75` if a
reboot is required after a fresh driver install, and should be re-run
after that reboot to complete verification.

### 5.3 Build and push the image

```bash
docker build -t registry.actum.ai/actum-intelligence/vllm-runtime:0.6.3-cuda12.1 \
  -f docker/Dockerfile docker/
docker push registry.actum.ai/actum-intelligence/vllm-runtime:0.6.3-cuda12.1
```

### 5.4 Create required Secrets

```bash
kubectl create namespace actum

kubectl create secret generic actum-vllm-api-key \
  --namespace actum \
  --from-literal=api-key="$(openssl rand -hex 32)" \
  --from-literal=hf-token="hf_your_huggingface_token"

kubectl create secret docker-registry actum-registry-credentials \
  --namespace actum \
  --docker-server=registry.actum.ai \
  --docker-username=<user> --docker-password=<token>
```

### 5.5 Install the chart

```bash
helm upgrade --install actum-intelligence charts/actum-intelligence \
  --namespace actum \
  --set vllm.model="meta-llama/Meta-Llama-3.1-8B-Instruct" \
  --set image.tag="0.6.3-cuda12.1" \
  --wait --timeout 15m
```

`--wait` blocks until the startup probe succeeds — allow 5-10 minutes for
initial model download into the PVC on a cold cache.

### 5.6 Verify

```bash
kubectl get pods -n actum -l app.kubernetes.io/name=actum-intelligence
kubectl get hpa -n actum
kubectl port-forward svc/actum-intelligence 8080:80 -n actum
curl http://localhost:8080/health
```

See `templates/NOTES.txt` (rendered automatically after `helm install`) for
a ready-to-use `curl` example against the OpenAI-compatible
`/v1/chat/completions` endpoint.

---

## 6. Upgrading / rolling out a new model

Changing the served model is a pure configuration change — no image
rebuild required:

```bash
helm upgrade actum-intelligence charts/actum-intelligence \
  --namespace actum \
  --reuse-values \
  --set vllm.model="mistralai/Mistral-7B-Instruct-v0.3" \
  --set vllm.servedModelName="actum-mistral-7b"
```

`maxUnavailable: 0` / `maxSurge: 1` in the rollout strategy guarantees the
old model replicas keep serving until new replicas pass their startup and
readiness probes, so there is no capacity dip during the swap.
