#!/bin/sh
# Select the inference engine configured in /etc/ai-core/config.env.
# systemd supplies the same file through EnvironmentFile; sourcing it here
# also makes manual/container launches use exactly the service configuration.

set -eu

AI_CORE_HOME=${AI_CORE_HOME:-/opt/ai-core}
AI_CORE_CONFIG=${AI_CORE_CONFIG:-/etc/ai-core/config.env}
[ -r "$AI_CORE_CONFIG" ] && . "$AI_CORE_CONFIG"

ENGINE=${ENGINE:-llama-server}

case "$ENGINE" in
  llama-server)
    AI_CORE_PORT=${AI_CORE_PORT:-21718}
    LLAMA_HOME=${LLAMA_HOME:-$AI_CORE_HOME/llama-b12669}
    MODEL_PATH=${MODEL_PATH:-$AI_CORE_HOME/models/Qwen3.5-4B-Q4_K_M.gguf}
    MODEL_ALIAS=${MODEL_ALIAS:-qwen3.5-4b}
    LD_LIBRARY_PATH=$LLAMA_HOME${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
    export LD_LIBRARY_PATH
    exec "$LLAMA_HOME/llama-server" \
      -m "$MODEL_PATH" \
      --host 127.0.0.1 \
      --port "$AI_CORE_PORT" \
      --alias "$MODEL_ALIAS" \
      -c 16384 \
      --jinja
    ;;
  litert-lm)
    # The Gemma flavor retains its validated LiteRT-LM seat. Its compiled
    # models need the 16384-token setting in /root/.litert-lm/config.json.
    AI_CORE_PORT=${AI_CORE_PORT:-21717}
    exec "$AI_CORE_HOME/venv/bin/litert-lm" serve \
      --host 127.0.0.1 \
      --port "$AI_CORE_PORT"
    ;;
  *)
    echo "ai-core engine: unsupported ENGINE=$ENGINE (expected llama-server or litert-lm)" >&2
    exit 1
    ;;
esac
