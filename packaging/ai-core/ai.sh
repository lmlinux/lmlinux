#!/bin/sh
# ai — the unified lmlinux agent entry point
# Dispatches to HARNESS from /etc/ai-core/config.env; the switch is retained
# for future harnesses even though hax is the only harness shipped by default.
# Install in /usr/bin so the entry point is available in every system layout.

CONFIG=${AI_CORE_CONFIG:-/etc/ai-core/config.env}
[ -f "$CONFIG" ] && . "$CONFIG"
HARNESS=${HARNESS:-hax}
ENGINE=${ENGINE:-llama-server}

if [ "$HARNESS" = "hax" ]; then
    if [ "$ENGINE" = "litert-lm" ]; then
        HAX_PROVIDER=${HAX_PROVIDER:-openai}
        HAX_OPENAI_BASE_URL=${HAX_OPENAI_BASE_URL:-http://127.0.0.1:${AI_CORE_PORT:-21717}/v1}
        HAX_OPENAI_API_KEY=${HAX_OPENAI_API_KEY:-local}
        export HAX_PROVIDER HAX_OPENAI_BASE_URL HAX_OPENAI_API_KEY
    else
        # The battery-validated hax path is the native llama.cpp provider.
        # Do not substitute the openai provider against this endpoint.
        HAX_PROVIDER=${HAX_PROVIDER:-llama.cpp}
        HAX_LLAMACPP_BASE_URL=${HAX_LLAMACPP_BASE_URL:-http://127.0.0.1:${AI_CORE_PORT:-21718}/v1}
        export HAX_PROVIDER HAX_LLAMACPP_BASE_URL
    fi
fi

if ! command -v "$HARNESS" >/dev/null 2>&1; then
    echo "ai: harness '$HARNESS' is unavailable; check HARNESS= in $CONFIG or install the selected harness" >&2
    exit 1
fi

# Readiness gate (real-machine finding, 2026-11-25): on a cold boot the
# engine only listens after the model-import unit has verified the
# multi-GB model and llama-server has loaded it. Opening `ai` inside
# that window made hax's startup auto-discovery fail after ~16 s of
# retries ("failed to auto-discover model ... / is llama-server
# running?") and dropped the REPL into a no-provider state. Wait for
# the local endpoint instead, with plain progress lines, while the
# units report start-up in progress; when the engine is deliberately
# stopped (the README documents `systemctl stop ai-core` to free
# memory) or has failed, print one actionable line and hand off — hax
# reports its own error. Pass through silently when systemd cannot
# answer (chroot package tests) or curl is unavailable, so checks like
# `ai --version` never block. Validated on the llama-server engine
# path; the non-default LiteRT-LM flavor is unchanged.
if [ "$HARNESS" = "hax" ] && [ "$ENGINE" != "litert-lm" ] \
   && command -v curl >/dev/null 2>&1 \
   && ! curl -sf -m 1 "http://127.0.0.1:${AI_CORE_PORT:-21718}/v1/models" >/dev/null 2>&1; then
    engine_unit_state=$(systemctl is-active ai-core.service 2>/dev/null) || true
    import_unit_state=$(systemctl is-active ai-core-model-import.service 2>/dev/null) || true
    if [ -n "$engine_unit_state$import_unit_state" ]; then
        startup_in_progress() {
            case "$engine_unit_state" in activating|active) return 0 ;; esac
            [ "$import_unit_state" = "activating" ]
        }
        i=0
        while startup_in_progress; do
            if [ -t 2 ] && [ "$i" -eq 0 ]; then
                echo "ai: the local engine is still starting (first boot verifies and loads the model); waiting..." >&2
            fi
            curl -sf -m 1 "http://127.0.0.1:${AI_CORE_PORT:-21718}/v1/models" >/dev/null 2>&1 && break
            i=$((i + 1))
            [ "$i" -ge 150 ] && break
            [ -t 2 ] && [ $((i % 8)) -eq 0 ] \
                && echo "ai: still waiting for the local engine (~$((i * 2))s)..." >&2
            sleep 2
            engine_unit_state=$(systemctl is-active ai-core.service 2>/dev/null) || true
            import_unit_state=$(systemctl is-active ai-core-model-import.service 2>/dev/null) || true
        done
        if ! curl -sf -m 1 "http://127.0.0.1:${AI_CORE_PORT:-21718}/v1/models" >/dev/null 2>&1; then
            echo "ai: the local engine is not reachable; if it is stopped: sudo systemctl start ai-core (details: journalctl -u ai-core -b)" >&2
        fi
    fi
fi

# Dispatch transparency: print one line to interactive stderr only; stay quiet in pipes and scripts
if [ -t 2 ]; then
    echo "ai → $HARNESS" >&2
fi

exec "$HARNESS" "$@"
