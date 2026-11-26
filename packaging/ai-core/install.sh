#!/bin/bash
# lmlinux ai-core one-command installer
#
# Default flavor: Qwen3.5-4B GGUF + official llama-server b12669 + hax 0.7.0.
# The non-default ENGINE=litert-lm path retains the Gemma 4 E4B flavor.
# Everything listens only on loopback; hax loads the installed AGENTS.md skill text.
#
# Usage: bash install.sh
# Environment variables:
#   ENGINE=llama-server|litert-lm  Inference engine (default llama-server)
#   AI_CORE_PORT             Local listening port (defaults: 21718 / 21717)
#   HF_MIRROR                Model mirror (default https://hf-mirror.com)
#   HAX_ARCHIVE              Optional local hax release archive (hash-checked)
#   LLAMA_ARCHIVE            Optional local llama.cpp release archive (hash-checked)
#   AI_CORE_IMAGE_BUILD=1    Skip model download, service startup, and smoke checks
#
# Trust model: model and binary archives are sha256-pinned. hax comes only from
# github.com/OleksandrChekhovskyi/hax releases (MIT license, redistribution
# permitted with its notice); llama.cpp comes only from ggml-org/llama.cpp
# releases. On restricted networks, curl honors http_proxy/https_proxy.

set -euo pipefail

AI_CORE_HOME=/opt/ai-core
VENV=$AI_CORE_HOME/venv
AI_CORE_CONFIG=/etc/ai-core/config.env
HAX_VERSION=0.7.0
HAX_SHA256=970183b80f1e7e8d2d4f8d9905234f415deb21cc80f111fbb5cc85bb9575fa3e
LLAMA_VERSION=b12669
LLAMA_SHA256=67d4bb52a775aa00a77895c07af4d95fc28b7b51c1e4dd04ecf6af21d08138a4
LLAMA_HOME=$AI_CORE_HOME/llama-$LLAMA_VERSION
LITERT_LM_VERSION=0.19.2
HF_MIRROR=${HF_MIRROR:-https://hf-mirror.com}
PIP_MIRROR=https://pypi.tuna.tsinghua.edu.cn

ENGINE_REQUESTED=${ENGINE:-}
PORT_REQUESTED=${AI_CORE_PORT:-}
[ -r "$AI_CORE_CONFIG" ] && . "$AI_CORE_CONFIG"
ENGINE=${ENGINE_REQUESTED:-${ENGINE:-llama-server}}
case "$ENGINE" in
  llama-server)
    DEFAULT_PORT=21718
    MODEL_REPO=unsloth/Qwen3.5-4B-GGUF
    MODEL_FILE=Qwen3.5-4B-Q4_K_M.gguf
    MODEL_ID=qwen3.5-4b
    MODEL_SHA256=00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4
    MODEL_PATH=$AI_CORE_HOME/models/$MODEL_FILE
    ;;
  litert-lm)
    DEFAULT_PORT=21717
    MODEL_REPO=litert-community/gemma-4-E4B-it-litert-lm
    MODEL_FILE=gemma-4-E4B-it.litertlm
    MODEL_ID=gemma-4-E4B-it.litertlm
    MODEL_SHA256=0b2a8980ce155fd97673d8e820b4d29d9c7d99b8fa6806f425d969b145bd52e0
    ;;
  *) echo "Unsupported ENGINE=$ENGINE (expected llama-server or litert-lm)" >&2; exit 1 ;;
esac
PORT=${PORT_REQUESTED:-${AI_CORE_PORT:-$DEFAULT_PORT}}

log() { echo "[ai-core] $*"; }

[ "$(id -u)" = 0 ] || { echo "Run as root"; exit 1; }
cd "$(dirname "$0")"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

set_config_value() {
  key=$1
  value=$2
  if grep -Fqx "$key=$value" "$AI_CORE_CONFIG" 2>/dev/null; then
    return
  fi
  sed -i "/^$key=/d" "$AI_CORE_CONFIG"
  printf '%s=%s\n' "$key" "$value" >> "$AI_CORE_CONFIG"
}

fetch_verified_archive() {
  source_archive=$1
  url=$2
  expected_sha=$3
  destination=$4
  if [ -n "$source_archive" ]; then
    [ -f "$source_archive" ] || { log "Archive not found: $source_archive"; exit 1; }
    cp "$source_archive" "$destination"
  else
    log "Downloading $url"
    curl -fsSL --retry 3 -o "$destination" "$url" || {
      log "Download failed; configure a GitHub proxy and rerun: $url"
      exit 1
    }
  fi
  printf '%s  %s\n' "$expected_sha" "$destination" | sha256sum -c - || {
    log "Archive verification failed: $destination"
    exit 1
  }
}

# ── 1. System dependencies ──────────────────────────────────
if command -v apt-get >/dev/null; then
  # Separate statements: "update && install" would swallow an update failure.
  apt-get update -qq
  if [ "$ENGINE" = "litert-lm" ]; then
    apt-get install -y -qq python3-venv curl
  else
    apt-get install -y -qq curl
  fi
elif command -v dnf >/dev/null; then
  if [ "$ENGINE" = "litert-lm" ]; then
    dnf install -y -q python3 python3-pip curl || true   # Test machine path (Rocky)
  else
    dnf install -y -q curl || true
  fi
fi

# ── 1.5 Loopback and port preflight (skipped during image builds) ──
if [ "${AI_CORE_IMAGE_BUILD:-0}" != "1" ]; then
  if command -v ip >/dev/null 2>&1; then
    ip link set lo up 2>/dev/null || log "Warning: could not enable lo; continuing with the local connectivity check"
  fi
  if command -v ss >/dev/null 2>&1; then
    LISTENERS=$(ss -tlnp "sport = :$PORT" 2>/dev/null | tail -n +2)
    OURS=0
    if [ -n "$LISTENERS" ] && systemctl is-active --quiet ai-core.service 2>/dev/null; then
      MAIN_PID=$(systemctl show ai-core.service -p MainPID --value 2>/dev/null || echo 0)
      if [ -n "$MAIN_PID" ] && [ "$MAIN_PID" != "0" ] \
         && echo "$LISTENERS" | grep -q "pid=$MAIN_PID,"; then
        OURS=1
      fi
    fi
    if [ -n "$LISTENERS" ] && [ "$OURS" != "1" ]; then
      log "Port $PORT is already in use:"
      echo "$LISTENERS"
      log "Rerun with another port: AI_CORE_PORT=<free-port> bash install.sh"
      log "On an installed system, edit /etc/ai-core/config.env, restart ai-core, and log in to a new shell"
      exit 1
    fi
  fi
fi

# ── 2. Official pinned binaries: hax and llama-server ─────────
if ! command -v hax >/dev/null 2>&1 || ! hax --version 2>/dev/null | grep -q "$HAX_VERSION"; then
  HAX_URL="https://github.com/OleksandrChekhovskyi/hax/releases/download/v${HAX_VERSION}/hax-${HAX_VERSION}-linux-x86_64.tar.gz"
  HAX_EXTRACT_DIR="$WORK_DIR/hax-extract"
  mkdir -p "$HAX_EXTRACT_DIR"
  fetch_verified_archive "${HAX_ARCHIVE:-}" "$HAX_URL" "$HAX_SHA256" "$WORK_DIR/hax.tar.gz"
  tar xzf "$WORK_DIR/hax.tar.gz" -C "$HAX_EXTRACT_DIR"
  install -m 755 "$HAX_EXTRACT_DIR/hax" /usr/bin/hax
fi
hax --version | grep -q "$HAX_VERSION" || { log "hax version check failed"; exit 1; }
log "hax $(hax --version) installed (MIT; upstream license notice included)"

if ! LD_LIBRARY_PATH=$LLAMA_HOME "$LLAMA_HOME/llama-server" --version 2>&1 | grep -q 'build 12669,'; then
  LLAMA_URL="https://github.com/ggml-org/llama.cpp/releases/download/$LLAMA_VERSION/llama-$LLAMA_VERSION-bin-ubuntu-x64.tar.gz"
  LLAMA_EXTRACT_DIR="$WORK_DIR/llama-extract"
  mkdir -p "$LLAMA_EXTRACT_DIR"
  fetch_verified_archive "${LLAMA_ARCHIVE:-}" "$LLAMA_URL" "$LLAMA_SHA256" "$WORK_DIR/llama.tar.gz"
  tar xzf "$WORK_DIR/llama.tar.gz" -C "$LLAMA_EXTRACT_DIR"
  mkdir -p "$LLAMA_HOME"
  cp -a "$LLAMA_EXTRACT_DIR/llama-$LLAMA_VERSION/." "$LLAMA_HOME/"
fi
LD_LIBRARY_PATH=$LLAMA_HOME "$LLAMA_HOME/llama-server" --version 2>&1 | grep -q 'build 12669,' || {
  log "llama-server version check failed"
  exit 1
}
log "llama-server $LLAMA_VERSION installed with its official shared-library layout"

# ── 3. Optional LiteRT-LM engine (the Gemma flavor) ───────────
if [ "$ENGINE" = "litert-lm" ]; then
  litert_lm_version() {
    "$VENV/bin/python" -c 'from importlib.metadata import version; print(version("litert-lm"))' 2>/dev/null || true
  }
  if [ -x "$VENV/bin/python" ]; then
    INSTALLED_LITERT_LM_VERSION=$(litert_lm_version)
    if [ -n "$INSTALLED_LITERT_LM_VERSION" ] && [ "$INSTALLED_LITERT_LM_VERSION" != "$LITERT_LM_VERSION" ]; then
      log "The existing venv has litert-lm $INSTALLED_LITERT_LM_VERSION, but $LITERT_LM_VERSION is required; back up and remove the old venv first"
      exit 1
    fi
  fi
  if [ ! -x "$VENV/bin/litert-lm" ]; then
    [ -x "$VENV/bin/python" ] || python3 -m venv "$VENV"
    "$VENV/bin/pip" install -q -i "$PIP_MIRROR" "litert-lm==$LITERT_LM_VERSION"
  fi
  INSTALLED_LITERT_LM_VERSION=$(litert_lm_version)
  if [ "$INSTALLED_LITERT_LM_VERSION" != "$LITERT_LM_VERSION" ]; then
    log "litert-lm version check failed: expected $LITERT_LM_VERSION, found ${INSTALLED_LITERT_LM_VERSION:-unknown}"
    exit 1
  fi
  log "litert-lm $("$VENV/bin/litert-lm" --version 2>/dev/null || echo '?') is ready"
fi

# ── 4. Single configuration source ────────────────────────────
install -d -m 755 /etc/ai-core
if [ ! -e "$AI_CORE_CONFIG" ]; then
  install -m 644 /dev/null "$AI_CORE_CONFIG"
fi
set_config_value ENGINE "$ENGINE"
set_config_value HARNESS hax
set_config_value AI_CORE_PORT "$PORT"
if [ "$ENGINE" = "llama-server" ]; then
  set_config_value MODEL_PATH "$MODEL_PATH"
  set_config_value MODEL_SHA256 "$MODEL_SHA256"
  set_config_value MODEL_ALIAS "$MODEL_ID"
fi
log "Configuration: $AI_CORE_CONFIG (ENGINE=$ENGINE, HARNESS=hax, port $PORT)"

# ── 5. Model (import + sha256 verification) ───────────────────
if [ "${AI_CORE_IMAGE_BUILD:-0}" = "1" ]; then
  log "Image build mode: skipping model download; the image builder supplies the pinned model"
elif [ "$ENGINE" = "llama-server" ]; then
  if printf '%s  %s\n' "$MODEL_SHA256" "$MODEL_PATH" | sha256sum -c --status 2>/dev/null; then
    log "Model $MODEL_FILE is already imported and verified"
  else
    MODEL_DOWNLOAD="$WORK_DIR/$MODEL_FILE.download"
    log "Downloading model (2.55 GiB from $HF_MIRROR)..."
    curl -fL --retry 3 -o "$MODEL_DOWNLOAD" "$HF_MIRROR/$MODEL_REPO/resolve/main/$MODEL_FILE"
    AI_CORE_MODEL_SOURCE="$MODEL_DOWNLOAD" AI_CORE_MODEL_SHA256="$MODEL_SHA256" \
      MODEL_PATH="$MODEL_PATH" AI_CORE_CONFIG="$AI_CORE_CONFIG" bash ./import-model.sh
  fi
else
  if "$VENV/bin/litert-lm" list 2>/dev/null | grep -q "$MODEL_ID"; then
    log "Model $MODEL_ID is already imported; skipping download"
  else
    MODEL_DOWNLOAD="$WORK_DIR/$MODEL_FILE.download"
    log "Downloading model (3.5GB from $HF_MIRROR)..."
    curl -fL --retry 3 -o "$MODEL_DOWNLOAD" "$HF_MIRROR/$MODEL_REPO/resolve/main/$MODEL_FILE"
    printf '%s  %s\n' "$MODEL_SHA256" "$MODEL_DOWNLOAD" | sha256sum -c - || { echo "Model verification failed!"; exit 1; }
    "$VENV/bin/litert-lm" import "$MODEL_DOWNLOAD" "$MODEL_ID"
    log "Model import complete (sha256 verified)"
  fi
  mkdir -p /root/.litert-lm
  cat > /root/.litert-lm/config.json <<'EOF'
{
  "default": {
    "backend": "cpu",
    "max_num_tokens": 16384
  }
}
EOF
fi

# ── 6. Entry points, skill text, and license notices ──────────
install -m 644 AGENTS.md "$AI_CORE_HOME/AGENTS.md"
install -m 755 engine.sh "$AI_CORE_HOME/engine.sh"
install -m 755 import-model.sh "$AI_CORE_HOME/import-model.sh"
install -m 755 ai.sh /usr/bin/ai
install -d -m 755 /usr/share/doc/lmlinux-ai-core
install -m 644 hax-LICENSE /usr/share/doc/lmlinux-ai-core/hax.LICENSE
log "Agent entry point: ai (hax default; HARNESS= switch retained)"
log "hax skill text: $AI_CORE_HOME/AGENTS.md (batched collection and read-only discipline)"
log "Model import: ai-core-model-import.service (optional AI_CORE_MODEL_SOURCE, idempotent)"

# ── 7. systemd services ───────────────────────────────────────
cat > /etc/systemd/system/ai-core-model-import.service <<'EOF'
[Unit]
Description=lmlinux ai-core model import (offline media / first boot)
Before=ai-core.service

[Service]
Type=oneshot
Environment=HOME=/root
ExecStart=/opt/ai-core/import-model.sh
EOF

cat > /etc/systemd/system/ai-core.service <<'EOF'
[Unit]
Description=lmlinux ai-core inference service (ENGINE from config.env)
After=network.target ai-core-model-import.service
Requires=ai-core-model-import.service

[Service]
Environment=HOME=/root
EnvironmentFile=/etc/ai-core/config.env
ExecStart=/opt/ai-core/engine.sh
Restart=on-failure
RestartSec=5
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF
if [ "${AI_CORE_IMAGE_BUILD:-0}" = "1" ]; then
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable ai-core.service || log "Offline enable failed; enable the service on first boot"
  fi
  log "Image build mode: units installed; services are not started during the build"
elif command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload
  systemctl enable ai-core.service
  systemctl restart ai-core.service || log "systemctl restart failed; check: journalctl -u ai-core.service"
else
  log "systemd is unavailable (container/test machine); run manually: $AI_CORE_HOME/engine.sh"
fi

# ── 8. hax integration (all users) ────────────────────────────
cat > /etc/profile.d/ai-core.sh <<'EOF'
[ -r /etc/ai-core/config.env ] && . /etc/ai-core/config.env
if [ "${ENGINE:-llama-server}" = "litert-lm" ]; then
  export HAX_PROVIDER="${HAX_PROVIDER:-openai}"
  export HAX_OPENAI_BASE_URL="${HAX_OPENAI_BASE_URL:-http://127.0.0.1:${AI_CORE_PORT:-21717}/v1}"
  export HAX_OPENAI_API_KEY="${HAX_OPENAI_API_KEY:-local}"
else
  export HAX_PROVIDER="${HAX_PROVIDER:-llama.cpp}"
  export HAX_LLAMACPP_BASE_URL="${HAX_LLAMACPP_BASE_URL:-http://127.0.0.1:${AI_CORE_PORT:-21718}/v1}"
fi
EOF
log "hax integration: /etc/profile.d/ai-core.sh (native llama.cpp provider by default)"

if [ "${AI_CORE_IMAGE_BUILD:-0}" = "1" ]; then
  log "✅ Image build mode installation complete (model and startup validation are deferred to first boot)"
  exit 0
fi

# ── 9. Smoke checks ───────────────────────────────────────────
log "Waiting for the service to become ready..."
for i in $(seq 1 60); do
  if MODELS=$(curl -sf --max-time 2 "http://127.0.0.1:$PORT/v1/models" 2>/dev/null) \
     && grep -q "$MODEL_ID" <<<"$MODELS"; then
    break
  fi
  sleep 5
done
if MODELS=$(curl -sf --max-time 3 "http://127.0.0.1:$PORT/v1/models") \
   && grep -q "$MODEL_ID" <<<"$MODELS"; then
  log "✅ ai-core service is ready: http://127.0.0.1:$PORT"
  log "Usage (after logging in again, or first run: source /etc/profile.d/ai-core.sh):"
  log "  ai       # Start the hax-backed assistant"
  log "  ai -c    # Resume the previous hax session"
elif ! command -v systemctl >/dev/null 2>&1; then
  log "The service was not started automatically without systemd; start it manually:"
  log "  $AI_CORE_HOME/engine.sh"
else
  log "❌ Service is not ready; check: journalctl -u ai-core.service -n 50"
  exit 1
fi
