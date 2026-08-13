# ==============================================================================
# ActumAI Intelligence Platform — vLLM Inference Runtime Image
# ==============================================================================
# Multi-stage build:
#   1. "builder"  — installs build toolchain + Python deps into an isolated
#                   virtualenv, so the final image never carries compilers,
#                   headers, or pip caches.
#   2. "runtime"  — minimal CUDA runtime (not "devel") + copied virtualenv,
#                   running as a non-root, non-privileged user.
#
# Target hardware: NVIDIA GPUs (Ampere/Hopper) with CUDA 12.1 driver
# compatibility. Base images are pinned to exact tags for reproducible,
# auditable builds — never ":latest" in production.
# ==============================================================================

# ------------------------------------------------------------------------------
# Stage 1: builder
# ------------------------------------------------------------------------------
FROM nvidia/cuda:12.1.1-devel-ubuntu22.04 AS builder

ARG PYTHON_VERSION=3.11
ARG VLLM_VERSION=0.6.3

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Install the minimal build toolchain required to compile Python wheels with
# native/CUDA extensions (vLLM ships some custom CUDA kernels compiled at
# install time for certain configurations).
RUN apt-get update && apt-get install -y --no-install-recommends \
        software-properties-common \
        curl \
        git \
        build-essential \
        ca-certificates \
    && add-apt-repository -y ppa:deadsnakes/ppa \
    && apt-get update && apt-get install -y --no-install-recommends \
        python${PYTHON_VERSION} \
        python${PYTHON_VERSION}-dev \
        python${PYTHON_VERSION}-venv \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/python${PYTHON_VERSION} /usr/bin/python3

# Build an isolated virtualenv so the runtime stage can copy it verbatim
# without pulling in build-essential, git, or apt caches.
RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

RUN pip install --upgrade pip==24.3.1 setuptools==75.6.0 wheel==0.45.1

# Pin vLLM and its serving dependencies to exact versions for reproducible,
# auditable builds. torch is resolved transitively by vllm's own constraint
# file to guarantee CUDA/binary compatibility.
RUN pip install \
        "vllm==${VLLM_VERSION}" \
        "ray[default]==2.38.0" \
        "prometheus-client==0.21.0" \
        "hf-transfer==0.1.8"

# ------------------------------------------------------------------------------
# Stage 2: runtime
# ------------------------------------------------------------------------------
FROM nvidia/cuda:12.1.1-runtime-ubuntu22.04 AS runtime

ARG PYTHON_VERSION=3.11

LABEL org.opencontainers.image.title="actum-intelligence-vllm" \
      org.opencontainers.image.description="Actum Intelligence Platform — production vLLM inference runtime" \
      org.opencontainers.image.vendor="Actum" \
      org.opencontainers.image.licenses="Apache-2.0"

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:${PATH}" \
    HF_HOME=/data/hf-cache \
    HF_HUB_ENABLE_HF_TRANSFER=1 \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    VLLM_WORKER_MULTIPROC_METHOD=spawn

# Only the minimal runtime libraries (no compilers, no headers, no dev
# packages) are installed here, keeping the final image lean and reducing
# its attack surface.
RUN apt-get update && apt-get install -y --no-install-recommends \
        software-properties-common \
        curl \
        ca-certificates \
        libgomp1 \
    && add-apt-repository -y ppa:deadsnakes/ppa \
    && apt-get update && apt-get install -y --no-install-recommends \
        python${PYTHON_VERSION} \
        python${PYTHON_VERSION}-venv \
    && ln -sf /usr/bin/python${PYTHON_VERSION} /usr/bin/python3 \
    && apt-get purge -y --auto-remove software-properties-common \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# Copy the pre-built virtualenv from the builder stage — no compilers or
# package indices are ever present in this final layer.
COPY --from=builder /opt/venv /opt/venv

# Create a dedicated, unprivileged system user/group. Running vLLM as root
# inside the container is unnecessary and violates the principle of least
# privilege; Kubernetes securityContext additionally enforces this at the
# pod level (see charts/actum-intelligence/templates/deployment.yaml).
RUN groupadd --system --gid 10001 actum \
    && useradd --system --uid 10001 --gid actum --no-create-home \
               --shell /usr/sbin/nologin actum \
    && mkdir -p /data/hf-cache /app \
    && chown -R actum:actum /data /app

WORKDIR /app

# Drop root privileges for the remainder of the build and for the running
# container process.
USER actum:actum

# vLLM's OpenAI-compatible server listens on this port by default; exposed
# for documentation purposes (Kubernetes Service defines the actual routing).
EXPOSE 8000

# Container-level healthcheck mirrors the Kubernetes readiness probe,
# providing a fast-fail signal to `docker run` / non-k8s orchestrators too.
HEALTHCHECK --interval=30s --timeout=5s --start-period=180s --retries=3 \
    CMD curl --fail --silent http://127.0.0.1:8000/health || exit 1

# No shell-form CMD, no implicit root fallback: the entrypoint is the
# vLLM OpenAI-compatible API server module, with model/parallelism
# configuration supplied entirely via environment variables injected by the
# Helm chart (see values.yaml / deployment.yaml), keeping the image itself
# model-agnostic and reusable across every model served by the platform.
ENTRYPOINT ["python3", "-m", "vllm.entrypoints.openai.api_server"]
CMD ["--host", "0.0.0.0", "--port", "8000"]
