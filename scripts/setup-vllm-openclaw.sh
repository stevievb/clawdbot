#!/usr/bin/env bash
#
# Automate vLLM on two DGX Sparks + OpenClaw config for local vLLM ("this mode").
#
# Prereqs:
#   - Passwordless SSH to both Spark nodes.
#   - One-time on BOTH nodes (run in two SSH sessions):
#       cd /home/YOUR_USER
#       wget -q https://raw.githubusercontent.com/vllm-project/vllm/refs/heads/main/examples/online_serving/run_cluster.sh && chmod +x run_cluster.sh
#       docker pull nvcr.io/nvidia/vllm:25.11-py3
#   - One-time on Node 1 (head): HuggingFace login and model download if using a gated model:
#       docker exec -it $(docker ps -q -f name=node-) bash -c 'hf auth login && hf download meta-llama/Llama-3.3-70B-Instruct'
#
# Usage:
#   ./scripts/setup-vllm-openclaw.sh [full|openclaw-only]
#
#   full          Bring up Ray cluster + vLLM on Sparks, then configure OpenClaw (default).
#   openclaw-only Only write/merge OpenClaw config; assume vLLM is already reachable.
#
#   For more output (timestamps, step labels, SSH verbose):  VLLM_VERBOSE=1 ./scripts/setup-vllm-openclaw.sh full
#

set -euo pipefail

# Set VLLM_VERBOSE=1 for verbose logging (timestamps, step labels, SSH verbose)
if [[ "${VLLM_VERBOSE:-0}" == "1" ]]; then
  set -x
  SSH_OPTS="-v"
else
  SSH_OPTS=""
fi

# ---- Config (edit these) ----
NODE1_HOST="${VLLM_NODE1_HOST:-192.168.0.14}"
NODE2_HOST="${VLLM_NODE2_HOST:-192.168.0.63}"
SSH_USER="${VLLM_SSH_USER:-stevievb}"
MN_IF_NAME="${VLLM_MN_IF_NAME:-enp1s0f0np0}"
VLLM_IMAGE="${VLLM_IMAGE:-nvcr.io/nvidia/vllm:25.11-py3}"
# HuggingFace model ID (must be downloaded on the cluster first if gated)
MODEL_ID="${VLLM_MODEL_ID:-meta-llama/Llama-3.3-70B-Instruct}"
MAX_MODEL_LEN="${VLLM_MAX_MODEL_LEN:-2048}"
# Where OpenClaw config lives (default ~/.openclaw/openclaw.json)
OPENCLAW_STATE_DIR="${OPENCLAW_STATE_DIR:-$HOME/.openclaw}"
OPENCLAW_CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-$OPENCLAW_STATE_DIR/openclaw.json}"
# vLLM base URL as seen from this Mac (use 127.0.0.1:8000 if using SSH port-forward)
VLLM_BASE_URL="${VLLM_BASE_URL:-http://127.0.0.1:8000/v1}"
# If true, script will start SSH port-forward 8000 -> NODE1:8000 in background
START_PORT_FORWARD="${START_PORT_FORWARD:-true}"

# ---- Internals ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MODE="${1:-full}"

log() { printf '[setup-vllm-openclaw] %s %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
log_step() { log ">>> $*"; }
ssh1() { ssh $SSH_OPTS -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$SSH_USER@$NODE1_HOST" "$@"; }
ssh2() { ssh $SSH_OPTS -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$SSH_USER@$NODE2_HOST" "$@"; }

# ---- OpenClaw: ensure state dir and merge vLLM config ----
setup_openclaw_config() {
  local base_url="$1"
  local model_id="$2"
  local max_len="$3"

  mkdir -p "$OPENCLAW_STATE_DIR"
  local config_path="$OPENCLAW_CONFIG_PATH"

  if ! command -v node >/dev/null 2>&1; then
    log "Node.js not found; writing minimal OpenClaw config to $config_path (no merge)."
    cat > "$config_path" << EOF
{
  "agents": {
    "defaults": {
      "model": { "primary": "vllm/$model_id" }
    }
  },
  "models": {
    "mode": "merge",
    "providers": {
      "vllm": {
        "baseUrl": "$base_url",
        "apiKey": "vllm-local",
        "api": "openai-completions",
        "models": [
          {
            "id": "$model_id",
            "name": "vLLM (Sparks)",
            "reasoning": false,
            "input": ["text"],
            "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
            "contextWindow": $max_len,
            "maxTokens": $max_len
          }
        ]
      }
    }
  }
}
EOF
    log "Wrote $config_path. Set VLLM_API_KEY=vllm-local when running OpenClaw."
    return 0
  fi

  # Merge with existing config via Node (supports JSON5)
  node --input-type=module - "$config_path" "$base_url" "$model_id" "$max_len" << 'NODE'
import fs from "node:fs";
import path from "node:path";
// JSON5 if available (openclaw uses it), else JSON
let parse, stringify;
try {
  const JSON5 = await import("json5");
  parse = JSON5.parse;
  stringify = (o) => JSON.stringify(o, null, 2);
} catch {
  parse = JSON.parse;
  stringify = (o) => JSON.stringify(o, null, 2);
}
const configPath = process.argv[2];
const baseUrl = process.argv[3];
const modelId = process.argv[4];
const maxLen = Number(process.argv[5]) || 2048;

let cfg = {};
if (fs.existsSync(configPath)) {
  try {
    cfg = parse(fs.readFileSync(configPath, "utf-8"));
  } catch (e) {
    console.error("[setup-vllm-openclaw] Could not parse existing config:", e.message);
    process.exit(1);
  }
}

cfg.agents = cfg.agents || {};
cfg.agents.defaults = cfg.agents.defaults || {};
cfg.agents.defaults.model = { primary: `vllm/${modelId}` };

cfg.models = cfg.models || {};
cfg.models.mode = cfg.models.mode || "merge";
cfg.models.providers = cfg.models.providers || {};
cfg.models.providers.vllm = {
  baseUrl,
  apiKey: "vllm-local",
  api: "openai-completions",
  models: [
    {
      id: modelId,
      name: "vLLM (Sparks)",
      reasoning: false,
      input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: maxLen,
      maxTokens: maxLen,
    },
  ],
};

fs.writeFileSync(configPath, stringify(cfg), "utf-8");
console.log("Updated", configPath);
NODE
  log "OpenClaw config updated at $config_path (vLLM primary model: vllm/$model_id)."
}

# ---- Cluster: start Ray head on Node 1 ----
start_ray_head() {
  log_step "Starting Ray head on $NODE1_HOST ..."
  ssh1 "bash -c 'cd /home/$SSH_USER && export VLLM_IMAGE=\"$VLLM_IMAGE\" && export MN_IF_NAME=\"$MN_IF_NAME\" && \
    export VLLM_HOST_IP=\$(ip -4 addr show \$MN_IF_NAME 2>/dev/null | grep -oP \"(?<=inet )[\\d.]+\" || true) && \
    if [ -z \"\$VLLM_HOST_IP\" ]; then echo No IP on $MN_IF_NAME; exit 1; fi && \
    nohup bash run_cluster.sh \$VLLM_IMAGE \$VLLM_HOST_IP --head ~/.cache/huggingface \
      -e VLLM_HOST_IP=\$VLLM_HOST_IP \
      -e UCX_NET_DEVICES=\$MN_IF_NAME \
      -e NCCL_SOCKET_IFNAME=\$MN_IF_NAME \
      -e OMPI_MCA_btl_tcp_if_include=\$MN_IF_NAME \
      -e GLOO_SOCKET_IFNAME=\$MN_IF_NAME \
      -e TP_SOCKET_IFNAME=\$MN_IF_NAME \
      -e RAY_memory_monitor_refresh_ms=0 \
      -e MASTER_ADDR=\$VLLM_HOST_IP \
      </dev/null >> /tmp/ray-head.log 2>&1 & disown; exit 0'"
  log "Ray head started in background (log on Node 1: /tmp/ray-head.log). Waiting 45s for container..."
  sleep 45
  log "Wait done. Checking for container..."
}

# ---- Cluster: start Ray worker on Node 2 ----
# Run the worker SSH in background from our side so we never block on the remote command.
start_ray_worker() {
  local head_ip="$1"
  log_step "Starting Ray worker on $NODE2_HOST (head $head_ip) ..."
  (
    ssh2 "bash -c 'cd /home/$SSH_USER && export VLLM_IMAGE=\"$VLLM_IMAGE\" && export MN_IF_NAME=\"$MN_IF_NAME\" && \
      export VLLM_HOST_IP=\$(ip -4 addr show \$MN_IF_NAME 2>/dev/null | grep -oP \"(?<=inet )[\\d.]+\" || true) && \
      export HEAD_NODE_IP=\"$head_ip\" && \
      nohup bash run_cluster.sh \$VLLM_IMAGE \$HEAD_NODE_IP --worker ~/.cache/huggingface \
        -e VLLM_HOST_IP=\$VLLM_HOST_IP \
        -e UCX_NET_DEVICES=\$MN_IF_NAME \
        -e NCCL_SOCKET_IFNAME=\$MN_IF_NAME \
        -e OMPI_MCA_btl_tcp_if_include=\$MN_IF_NAME \
        -e GLOO_SOCKET_IFNAME=\$MN_IF_NAME \
        -e TP_SOCKET_IFNAME=\$MN_IF_NAME \
        -e RAY_memory_monitor_refresh_ms=0 \
        -e MASTER_ADDR=\$HEAD_NODE_IP \
        </dev/null >> /tmp/ray-worker.log 2>&1 & disown; exit 0'"
  ) >> /tmp/setup-vllm-worker-ssh.log 2>&1 &
  log "Ray worker SSH launched in background (remote log: Node 2 /tmp/ray-worker.log). Waiting 40s..."
  sleep 40
  log "Wait done."
}

# ---- Cluster: get container name on Node 1 ----
get_container_name() {
  log_step "Getting Ray container name on Node 1..."
  ssh1 "docker ps --format '{{.Names}}' | grep -E '^node-[0-9]+\$' | head -1"
}

# ---- Cluster: start vLLM serve inside container ----
start_vllm_serve() {
  local container="$1"
  log_step "Starting vLLM serve in container $container (model $MODEL_ID) ..."
  ssh1 "docker exec -d $container /bin/bash -c 'vllm serve $MODEL_ID --tensor-parallel-size 2 --max_model_len $MAX_MODEL_LEN'"
  log "vLLM serve started in background. Waiting for /v1/models (polling every 5s, up to 120s)..."
  local i=0
  while [ $i -lt 24 ]; do
    log "  Poll $((i+1))/24: checking http://localhost:8000/v1/models inside container..."
    if ssh1 "docker exec $container curl -sf http://localhost:8000/v1/models" >/dev/null 2>&1; then
      log "vLLM is up and responding."
      return 0
    fi
    sleep 5
    i=$((i + 1))
  done
  log "WARNING: vLLM /v1/models did not respond in time. It may still be loading (check container logs)."
}

# ---- Port forward: Mac 8000 -> Node1 8000 ----
# vLLM listens on 8000 inside the Ray container. run_cluster.sh usually publishes it to the host;
# if not, set START_PORT_FORWARD=false and VLLM_BASE_URL=http://$NODE1_HOST:8000/v1 (and ensure firewall allows 8000).
start_port_forward() {
  log_step "Starting SSH port-forward localhost:8000 -> $NODE1_HOST:8000 (background)."
  if ssh -f -o ExitOnForwardFailure=yes -L 8000:localhost:8000 "$SSH_USER@$NODE1_HOST" -N 2>/dev/null; then
    log "Port forward active: use VLLM_BASE_URL=http://127.0.0.1:8000/v1 from this Mac."
  else
    log "Port forward failed (e.g. port 8000 in use). Use VLLM_BASE_URL=http://$NODE1_HOST:8000/v1 if on same network."
  fi
}

# ---- Main ----
main() {
  log "========== setup-vllm-openclaw.sh (mode=$MODE) =========="
  log "NODE1=$NODE1_HOST NODE2=$NODE2_HOST USER=$SSH_USER MODEL=$MODEL_ID"
  if [[ "$MODE" != "full" && "$MODE" != "openclaw-only" ]]; then
    log "Usage: $0 [full|openclaw-only]"
    exit 1
  fi

  if [[ "$MODE" == "full" ]]; then
    log_step "Getting head IP from Node 1 (interface $MN_IF_NAME)..."
    HEAD_IP=$(ssh1 "ip -4 addr show $MN_IF_NAME 2>/dev/null | grep -oP '(?<=inet )[\d.]+'" | tr -d '\r')
    if [[ -z "$HEAD_IP" ]]; then
      log "ERROR: Could not get head IP from $NODE1_HOST interface $MN_IF_NAME."
      exit 1
    fi
    log "Head IP: $HEAD_IP"

    start_ray_head
    start_ray_worker "$HEAD_IP"

    log_step "Looking up Ray container on Node 1..."
    CONTAINER=$(get_container_name)
    if [[ -z "$CONTAINER" ]]; then
      log "ERROR: Could not find Ray container on Node 1. Check /tmp/ray-head.log on $NODE1_HOST."
      log "  You can inspect with: ssh $SSH_USER@$NODE1_HOST 'tail -100 /tmp/ray-head.log'"
      exit 1
    fi
    log "Using container: $CONTAINER"
    start_vllm_serve "$CONTAINER"

    if [[ "$START_PORT_FORWARD" == "true" ]]; then
      # vLLM is inside Docker; we need to reach it from Mac. On Node1, is 8000 exposed on host?
      # Typically run_cluster.sh maps container 8000 to host 8000, so SSH -L 8000:localhost:8000 to Node1 works.
      start_port_forward
    else
      log "Skipping port forward. Set VLLM_BASE_URL=http://$NODE1_HOST:8000/v1 if OpenClaw runs on same network."
    fi
  fi

  # Always ensure OpenClaw config is set for vLLM
  log_step "Writing/merging OpenClaw config to $OPENCLAW_CONFIG_PATH ..."
  setup_openclaw_config "$VLLM_BASE_URL" "$MODEL_ID" "$MAX_MODEL_LEN"

  log "========== Done =========="
  log "  OpenClaw config: $OPENCLAW_CONFIG_PATH"
  log "  Test vLLM:       curl $VLLM_BASE_URL/models"
  log "  Run gateway:     openclaw start (or pnpm start); set VLLM_API_KEY=vllm-local if needed."
}

main "$@"
