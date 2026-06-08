#!/usr/bin/env bash
set -euo pipefail

# Runs a single reproduction experiment inside a SLURM allocation.
# Usage: run_in_job.sh <run_meta.json>

RUN_META="${1:?run_meta.json required}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

PYTHON="${WCSS_SPECEDGE_ROOT}/.venv/bin/python3"
METHOD=$("${PYTHON}" -c "import json,sys; print(json.load(open(sys.argv[1]))['method'])" "${RUN_META}")
CONFIG=$("${PYTHON}" -c "import json,sys; print(json.load(open(sys.argv[1]))['config_path'])" "${RUN_META}")
RUN_ID=$("${PYTHON}" -c "import json,sys; print(json.load(open(sys.argv[1]))['run_id'])" "${RUN_META}")

cd "${WCSS_SPECEDGE_ROOT}"
source .venv/bin/activate

export HF_HOME="${WCSS_HF_HOME}"
export XDG_CACHE_HOME="${WCSS_REPRO_ROOT}/xdg_cache"
mkdir -p "${XDG_CACHE_HOME}"

echo "=== SpecEdge reproduction run: ${RUN_ID} ==="
echo "Method:  ${METHOD}"
echo "Config:  ${CONFIG}"
echo "Node:    $(hostname)"
echo "GPUs:    $(nvidia-smi -L 2>/dev/null | wc -l | tr -d ' ')"
nvidia-smi || true

wait_for_port() {
    local port="$1"
    local retries=120
    local i
    for ((i = 1; i <= retries; i++)); do
        if "${PYTHON}" - <<PY
import socket, sys
s = socket.socket()
s.settimeout(1)
try:
    s.connect(("127.0.0.1", ${port}))
    sys.exit(0)
except OSError:
    sys.exit(1)
finally:
    s.close()
PY
        then
            echo "gRPC server ready on port ${port} (attempt ${i})"
            return 0
        fi
        sleep 5
    done
    echo "ERROR: gRPC server did not start on port ${port}" >&2
    return 1
}

RESULT_DIR=$("${PYTHON}" -c "import json,sys; print(json.load(open(sys.argv[1]))['result_dir'])" "${RUN_META}")
mkdir -p "${RESULT_DIR}"

{
    echo "run_id=${RUN_ID}"
    echo "method=${METHOD}"
    echo "hostname=$(hostname)"
    echo "slurm_job_id=${SLURM_JOB_ID:-local}"
    echo "start_time=$(date -Iseconds)"
    echo "cuda_visible_devices=${CUDA_VISIBLE_DEVICES:-}"
} > "${RESULT_DIR}/job_env.txt"

case "${METHOD}" in
    server_only)
        ./script/server_only.sh -f "${CONFIG}"
        ;;
    specedge)
        ./script/batch_server.sh -f "${CONFIG}" &
        SERVER_PID=$!
        trap 'kill ${SERVER_PID} 2>/dev/null || true' EXIT

        wait_for_port 8000
        "${PYTHON}" "${SCRIPT_DIR}/client_local.py" --config "${CONFIG}"
        CLIENT_RC=$?

        kill "${SERVER_PID}" 2>/dev/null || true
        wait "${SERVER_PID}" 2>/dev/null || true
        trap - EXIT

        if [[ ${CLIENT_RC} -ne 0 ]]; then
            echo "ERROR: edge clients failed with code ${CLIENT_RC}" >&2
            exit "${CLIENT_RC}"
        fi
        ;;
    *)
        echo "ERROR: unknown method ${METHOD}" >&2
        exit 1
        ;;
esac

echo "end_time=$(date -Iseconds)" >> "${RESULT_DIR}/job_env.txt"
echo "=== Run ${RUN_ID} completed ==="
