# hax provider selection follows the configured engine.
[ -r /etc/ai-core/config.env ] && . /etc/ai-core/config.env
if [ "${ENGINE:-llama-server}" = "litert-lm" ]; then
  export HAX_PROVIDER="${HAX_PROVIDER:-openai}"
  export HAX_OPENAI_BASE_URL="${HAX_OPENAI_BASE_URL:-http://127.0.0.1:${AI_CORE_PORT:-21717}/v1}"
  export HAX_OPENAI_API_KEY="${HAX_OPENAI_API_KEY:-local}"
else
  export HAX_PROVIDER="${HAX_PROVIDER:-llama.cpp}"
  export HAX_LLAMACPP_BASE_URL="${HAX_LLAMACPP_BASE_URL:-http://127.0.0.1:${AI_CORE_PORT:-21718}/v1}"
fi
