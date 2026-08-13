#!/usr/bin/env bash
# ==============================================================================
# Actum Intelligence Platform — GPU Node Cluster Bootstrap
# ==============================================================================
# Prepares a Linux node (Ubuntu 22.04, systemd, containerd-backed
# Kubernetes/kubelet) to run GPU-accelerated inference workloads:
#
#   1. Verifies/installs the NVIDIA proprietary driver.
#   2. Installs the NVIDIA Container Toolkit and wires it into containerd.
#   3. Configures containerd's default runtime to `nvidia`.
#   4. Verifies the full stack end-to-end with a real GPU container run.
#   5. Applies kubelet-facing node labels so the Kubernetes scheduler (via
#      nodeSelector/tolerations in the Helm chart) can correctly target
#      this node for GPU workloads.
#
# Usage:
#   sudo ./cluster-bootstrap.sh
#
# Idempotent: safe to re-run; every step checks current state before acting.
# ==============================================================================

set -o errexit
set -o nounset
set -o pipefail

# ------------------------------------------------------------------------------
# Constants & globals
# ------------------------------------------------------------------------------
readonly SCRIPT_NAME="$(basename "$0")"
readonly LOG_FILE="/var/log/actum-cluster-bootstrap.log"
readonly REQUIRED_DRIVER_MIN_VERSION="535"
readonly NVIDIA_CONTAINER_TOOLKIT_VERSION="1.16.2-1"
readonly CONTAINERD_CONFIG="/etc/containerd/config.toml"
readonly GPU_NODE_LABEL="nvidia.com/gpu.present=true"
readonly GPU_TAINT="nvidia.com/gpu=present:NoSchedule"

# ------------------------------------------------------------------------------
# Logging helpers — every line is timestamped and mirrored to both stdout
# and a persistent audit log, since this script is expected to run
# unattended as part of node provisioning (cloud-init / Ansible / Terraform
# provisioner) where interactive output may not be captured elsewhere.
# ------------------------------------------------------------------------------
_log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '[%s] [%s] %s\n' "${timestamp}" "${level}" "${message}" | tee -a "${LOG_FILE}"
}

log_info()  { _log "INFO"  "$@"; }
log_warn()  { _log "WARN"  "$@"; }
log_error() { _log "ERROR" "$@" >&2; }

fatal() {
    log_error "$*"
    log_error "Bootstrap aborted. See ${LOG_FILE} for full detail."
    exit 1
}

# ------------------------------------------------------------------------------
# Preflight checks
# ------------------------------------------------------------------------------
require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        fatal "This script must be run as root (e.g. via sudo). Current EUID=${EUID}."
    fi
}

require_supported_os() {
    if [[ ! -f /etc/os-release ]]; then
        fatal "Cannot determine OS distribution: /etc/os-release not found."
    fi
    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "${ID:-}" != "ubuntu" ]]; then
        fatal "Unsupported OS '${ID:-unknown}'. This script targets Ubuntu 22.04 LTS."
    fi
    if [[ "${VERSION_ID:-}" != "22.04" ]]; then
        log_warn "OS version ${VERSION_ID:-unknown} detected; this script is validated against 22.04 and may require adjustment."
    fi
    log_info "OS check passed: ${PRETTY_NAME:-Ubuntu 22.04}."
}

require_gpu_hardware_present() {
    if ! command -v lspci &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq pciutils
    fi
    if ! lspci | grep -qi nvidia; then
        fatal "No NVIDIA GPU device detected via lspci. This node is not eligible for the GPU workload pool."
    fi
    log_info "NVIDIA GPU hardware detected:"
    lspci | grep -i nvidia | tee -a "${LOG_FILE}"
}

# ------------------------------------------------------------------------------
# Step 1: NVIDIA driver installation / verification
# ------------------------------------------------------------------------------
install_or_verify_nvidia_driver() {
    log_info "Checking for existing NVIDIA driver installation..."

    if command -v nvidia-smi &>/dev/null; then
        local installed_version
        installed_version="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits | head -n1)"
        local installed_major="${installed_version%%.*}"
        log_info "Existing NVIDIA driver detected: version ${installed_version}."

        if [[ "${installed_major}" -ge "${REQUIRED_DRIVER_MIN_VERSION}" ]]; then
            log_info "Installed driver version (${installed_version}) satisfies minimum required (${REQUIRED_DRIVER_MIN_VERSION}.x). Skipping installation."
            return 0
        else
            log_warn "Installed driver major version ${installed_major} is below the required minimum ${REQUIRED_DRIVER_MIN_VERSION}. Upgrading."
        fi
    else
        log_info "No NVIDIA driver detected. Proceeding with installation."
    fi

    log_info "Installing kernel headers and build dependencies..."
    apt-get update -qq
    apt-get install -y -qq \
        "linux-headers-$(uname -r)" \
        build-essential \
        dkms \
        ca-certificates \
        curl \
        gnupg

    log_info "Adding the NVIDIA CUDA repository..."
    local distro="ubuntu2204"
    local keyring_url="https://developer.download.nvidia.com/compute/cuda/repos/${distro}/x86_64/cuda-keyring_1.1-1_all.deb"
    local tmp_deb
    tmp_deb="$(mktemp --suffix=.deb)"
    curl -fsSL "${keyring_url}" -o "${tmp_deb}"
    dpkg -i "${tmp_deb}"
    rm -f "${tmp_deb}"
    apt-get update -qq

    log_info "Installing NVIDIA driver (server/production branch, version >= ${REQUIRED_DRIVER_MIN_VERSION})..."
    apt-get install -y -qq "nvidia-driver-${REQUIRED_DRIVER_MIN_VERSION}-server"

    log_warn "A kernel module was just installed. A REBOOT is required before nvidia-smi will function."
    touch /var/run/actum-bootstrap-reboot-required
}

# ------------------------------------------------------------------------------
# Step 2: NVIDIA Container Toolkit installation
# ------------------------------------------------------------------------------
install_nvidia_container_toolkit() {
    log_info "Checking for existing NVIDIA Container Toolkit installation..."

    if dpkg -l | grep -q nvidia-container-toolkit; then
        local current_version
        current_version="$(dpkg -l | awk '/nvidia-container-toolkit/{print $3}' | head -n1)"
        log_info "NVIDIA Container Toolkit already installed: ${current_version}. Skipping package installation."
    else
        log_info "Adding the NVIDIA Container Toolkit apt repository..."
        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
            | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

        curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
            | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
            > /etc/apt/sources.list.d/nvidia-container-toolkit.list

        apt-get update -qq
        apt-get install -y -qq \
            "nvidia-container-toolkit=${NVIDIA_CONTAINER_TOOLKIT_VERSION}" \
            "nvidia-container-toolkit-base=${NVIDIA_CONTAINER_TOOLKIT_VERSION}" \
            "libnvidia-container-tools" \
            "libnvidia-container1"

        log_info "NVIDIA Container Toolkit installed successfully."
    fi
}

# ------------------------------------------------------------------------------
# Step 3: Wire the toolkit into containerd (the CRI runtime used by kubelet)
# ------------------------------------------------------------------------------
configure_containerd_runtime() {
    log_info "Configuring containerd to use the NVIDIA runtime..."

    if [[ ! -f "${CONTAINERD_CONFIG}" ]]; then
        fatal "containerd config not found at ${CONTAINERD_CONFIG}. Is containerd installed and is this a kubelet-managed node?"
    fi

    cp "${CONTAINERD_CONFIG}" "${CONTAINERD_CONFIG}.bak.$(date +%s)"
    log_info "Backed up existing containerd config."

    # nvidia-ctk performs an idempotent, structured merge into
    # containerd's TOML config rather than a naive text substitution,
    # correctly handling a config file that may already have been
    # customized (e.g. by a previous run of this script or by the cluster
    # provisioning tool).
    nvidia-ctk runtime configure --runtime=containerd --config="${CONTAINERD_CONFIG}"

    # Set NVIDIA as the DEFAULT runtime (rather than requiring every pod
    # spec to explicitly declare runtimeClassName: nvidia) so that the
    # Helm chart's Deployment does not need to carry a runtime-specific
    # field, keeping the chart portable across clusters that provision GPU
    # nodes differently.
    nvidia-ctk runtime configure --runtime=containerd --config="${CONTAINERD_CONFIG}" --set-as-default

    log_info "Restarting containerd to apply the new runtime configuration..."
    systemctl restart containerd
    sleep 3

    if ! systemctl is-active --quiet containerd; then
        fatal "containerd failed to restart cleanly after runtime configuration. Check: journalctl -u containerd -n 100"
    fi
    log_info "containerd restarted successfully with the NVIDIA runtime configured as default."
}

# ------------------------------------------------------------------------------
# Step 4: End-to-end GPU stack verification
# ------------------------------------------------------------------------------
verify_gpu_stack() {
    log_info "Verifying host-level driver via nvidia-smi..."

    if [[ -f /var/run/actum-bootstrap-reboot-required ]]; then
        log_warn "A reboot is pending from a fresh driver install. Skipping live nvidia-smi/container verification until after reboot."
        log_warn "Re-run this script after rebooting to complete verification."
        return 0
    fi

    if ! nvidia-smi &>/dev/null; then
        fatal "nvidia-smi failed to run. The NVIDIA driver is not functioning correctly on the host."
    fi
    log_info "Host nvidia-smi output:"
    nvidia-smi --query-gpu=name,driver_version,memory.total,memory.used,utilization.gpu \
        --format=csv | tee -a "${LOG_FILE}"

    log_info "Verifying GPU visibility inside a containerd-run container (this validates the full toolkit + runtime wiring end-to-end)..."

    if ! command -v ctr &>/dev/null; then
        log_warn "ctr CLI not found; skipping in-container verification. Ensure this is validated via 'kubectl run --rm -it gpu-test --image=nvidia/cuda:12.1.1-base-ubuntu22.04 -- nvidia-smi' once the node joins the cluster."
        return 0
    fi

    local test_output
    if test_output="$(ctr run --rm --gpus 0 \
        docker.io/nvidia/cuda:12.1.1-base-ubuntu22.04 \
        actum-gpu-verify nvidia-smi 2>&1)"; then
        log_info "In-container GPU verification SUCCEEDED. Sample output:"
        echo "${test_output}" | head -n 15 | tee -a "${LOG_FILE}"
    else
        fatal "In-container GPU verification FAILED. The container runtime cannot see the GPU. Output was:\n${test_output}"
    fi
}

# ------------------------------------------------------------------------------
# Step 5: Kubernetes node labeling for scheduler targeting
# ------------------------------------------------------------------------------
apply_kubernetes_node_labels() {
    log_info "Checking for local kubelet / kubeconfig to apply scheduler-facing node labels..."

    if ! command -v kubectl &>/dev/null; then
        log_warn "kubectl not found on this node. Skipping automatic node labeling/tainting."
        log_warn "Apply manually from a cluster-admin context once this node has joined:"
        log_warn "  kubectl label node <NODE_NAME> ${GPU_NODE_LABEL} --overwrite"
        log_warn "  kubectl taint node <NODE_NAME> ${GPU_TAINT} --overwrite"
        return 0
    fi

    local node_name
    node_name="$(hostname)"

    if ! kubectl get node "${node_name}" &>/dev/null; then
        log_warn "Node '${node_name}' is not yet registered with the cluster API server. Skipping labeling; run again after the node joins."
        return 0
    fi

    log_info "Applying scheduler label '${GPU_NODE_LABEL}' to node '${node_name}'..."
    kubectl label node "${node_name}" ${GPU_NODE_LABEL} --overwrite

    log_info "Applying scheduler taint '${GPU_TAINT}' to node '${node_name}' to reserve it exclusively for GPU workloads..."
    kubectl taint node "${node_name}" ${GPU_TAINT} --overwrite

    log_info "Node '${node_name}' is now labeled and tainted for GPU workload scheduling. This matches the nodeSelector/tolerations configured in charts/actum-intelligence/values.yaml."
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
main() {
    touch "${LOG_FILE}"
    log_info "========================================================"
    log_info " Actum Intelligence Platform — Cluster Bootstrap started"
    log_info "========================================================"

    require_root
    require_supported_os
    require_gpu_hardware_present

    install_or_verify_nvidia_driver
    install_nvidia_container_toolkit
    configure_containerd_runtime
    verify_gpu_stack
    apply_kubernetes_node_labels

    if [[ -f /var/run/actum-bootstrap-reboot-required ]]; then
        log_warn "=================================================================="
        log_warn " REBOOT REQUIRED to load the newly installed NVIDIA kernel module."
        log_warn " After reboot, re-run: sudo ${SCRIPT_NAME}"
        log_warn " to complete GPU/container-runtime verification and node labeling."
        log_warn "=================================================================="
        exit 75  # EX_TEMPFAIL — signals "retry after external action" to callers/CI
    fi

    log_info "========================================================"
    log_info " Bootstrap completed successfully. Node is ready for GPU"
    log_info " inference workloads."
    log_info "========================================================"
}

main "$@"
