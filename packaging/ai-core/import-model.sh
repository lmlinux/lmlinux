#!/bin/bash
# ai-core model import from a file, block device, or offline boot media.
# GGUF imports copy and verify the model, then register MODEL_PATH and
# MODEL_SHA256 in config.env. The LiteRT-LM registry path remains available
# for the non-default Gemma flavor. All paths are idempotent.
set -euo pipefail

AI_CORE_HOME=${AI_CORE_HOME:-/opt/ai-core}
VENV=$AI_CORE_HOME/venv
AI_CORE_CONFIG=${AI_CORE_CONFIG:-/etc/ai-core/config.env}
[ -r "$AI_CORE_CONFIG" ] && . "$AI_CORE_CONFIG"
ENGINE=${ENGINE:-llama-server}

if [ "$ENGINE" = "llama-server" ]; then
  MODEL_PATH=${MODEL_PATH:-$AI_CORE_HOME/models/Qwen3.5-4B-Q4_K_M.gguf}
  MODEL_FILE=${AI_CORE_MODEL_FILE:-${MODEL_PATH##*/}}
  MODEL_SHA256=${AI_CORE_MODEL_SHA256:-${MODEL_SHA256:-00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4}}
elif [ "$ENGINE" = "litert-lm" ]; then
  MODEL_ID=${AI_CORE_MODEL_ID:-gemma-4-E4B-it.litertlm}
  MODEL_FILE=${AI_CORE_MODEL_FILE:-gemma-4-E4B-it.litertlm}
  MODEL_SHA256=${AI_CORE_MODEL_SHA256:-0b2a8980ce155fd97673d8e820b4d29d9c7d99b8fa6806f425d969b145bd52e0}
else
  echo "[ai-core-model] ERROR: unsupported ENGINE=$ENGINE" >&2
  exit 1
fi

MEDIA_MOUNT_POINT=
MEDIA_SOURCE=
MODEL_TMP=
DIRECT_ERROR=

log() { echo "[ai-core-model] $*"; }

cleanup() {
  status=$?
  trap - EXIT
  [ -z "$MODEL_TMP" ] || rm -f "$MODEL_TMP"
  [ -z "$DIRECT_ERROR" ] || rm -f "$DIRECT_ERROR"
  if [ -n "$MEDIA_MOUNT_POINT" ]; then
    if findmnt -rn --mountpoint "$MEDIA_MOUNT_POINT" >/dev/null 2>&1; then
      if ! umount "$MEDIA_MOUNT_POINT"; then
        log "ERROR: failed to unmount model media at $MEDIA_MOUNT_POINT"
        status=1
      fi
    fi
    if ! rmdir "$MEDIA_MOUNT_POINT" 2>/dev/null; then
      log "ERROR: failed to remove private model-media mountpoint $MEDIA_MOUNT_POINT"
      status=1
    fi
  fi
  exit "$status"
}
trap cleanup EXIT

set_config_value() {
  key=$1
  value=$2
  install -d -m 755 "$(dirname "$AI_CORE_CONFIG")"
  [ -e "$AI_CORE_CONFIG" ] || install -m 644 /dev/null "$AI_CORE_CONFIG"
  if grep -Fqx "$key=$value" "$AI_CORE_CONFIG"; then
    return
  fi
  sed -i "/^$key=/d" "$AI_CORE_CONFIG"
  printf '%s=%s\n' "$key" "$value" >> "$AI_CORE_CONFIG"
}

register_gguf() {
  set_config_value MODEL_PATH "$MODEL_PATH"
  set_config_value MODEL_SHA256 "$MODEL_SHA256"
  log "Registered MODEL_PATH and MODEL_SHA256 in $AI_CORE_CONFIG"
}

media_candidates() {
  if [ -n "${AI_CORE_MODEL_MEDIA_DEVICES:-}" ]; then
    for device in $AI_CORE_MODEL_MEDIA_DEVICES; do
      printf '%s\n' "$device"
    done
    return
  fi
  for device in /dev/sr*; do
    [ ! -b "$device" ] || printf '%s\n' "$device"
  done
  while read -r device type removable; do
    case $type in
      disk|part|rom)
        [ "$removable" != "1" ] || printf '%s\n' "$device"
        ;;
    esac
  done < <(lsblk -lnpo NAME,TYPE,RM 2>/dev/null)
}

locate_media() {
  MEDIA_MOUNT_POINT=$(mktemp -d "${TMPDIR:-/tmp}/ai-core-model-media.XXXXXX")
  chmod 700 "$MEDIA_MOUNT_POINT"
  seen_devices=
  while IFS= read -r device; do
    [ -n "$device" ] && [ -b "$device" ] || continue
    case " $seen_devices " in
      *" $device "*) continue ;;
    esac
    seen_devices="$seen_devices $device"
    if mount -o ro,nosuid,nodev,noexec "$device" "$MEDIA_MOUNT_POINT" 2>/dev/null; then
      log "Scanning read-only model media: $device"
      found_path=
      if [ -f "$MEDIA_MOUNT_POINT/$MODEL_FILE" ]; then
        found_path=$MEDIA_MOUNT_POINT/$MODEL_FILE
      else
        found_path=$(find "$MEDIA_MOUNT_POINT" -xdev -type f -name "$MODEL_FILE" -print -quit 2>/dev/null || true)
      fi
      if [ -n "$found_path" ]; then
        MEDIA_SOURCE=$found_path
        log "Found $MODEL_FILE on $device"
        return 0
      fi
      umount "$MEDIA_MOUNT_POINT"
    fi
  done < <(media_candidates)
  return 1
}

drop_caches() {
  if [ -w /proc/sys/vm/drop_caches ]; then
    printf '3\n' > /proc/sys/vm/drop_caches
  fi
}

copy_file_with_cache_eviction() {
  source_path=$1
  source_size=$(stat -c %s "$source_path")
  chunk_size=67108864
  offset=0
  : > "$MODEL_TMP"
  while [ "$offset" -lt "$source_size" ]; do
    dd if="$source_path" of="$MODEL_TMP" bs=8M count="$chunk_size" \
      skip="$offset" seek="$offset" \
      iflag=skip_bytes,count_bytes,nocache oflag=seek_bytes \
      conv=notrunc,fsync status=none || return 1
    drop_caches
    offset=$((offset + chunk_size))
  done
}

copy_file_buffered() {
  source_path=$1
  source_size=$(stat -c %s "$source_path")
  chunk_size=67108864
  offset=0
  : > "$MODEL_TMP"
  while [ "$offset" -lt "$source_size" ]; do
    dd if="$source_path" of="$MODEL_TMP" bs=8M count="$chunk_size" \
      skip="$offset" seek="$offset" \
      iflag=skip_bytes,count_bytes oflag=seek_bytes \
      conv=notrunc,fsync status=none || return 1
    drop_caches
    offset=$((offset + chunk_size))
  done
}

copy_and_verify_gguf() {
  MODEL_DIR=${MODEL_PATH%/*}
  mkdir -p "$MODEL_DIR"
  MODEL_TMP=$(mktemp "$MODEL_DIR/.${MODEL_FILE}.import.XXXXXX")

  log "Direct-I/O chunked import from $SOURCE to $MODEL_PATH"
  DIRECT_ERROR=$(mktemp "${TMPDIR:-/tmp}/ai-core-model-direct.XXXXXX")
  if ! dd if="$SOURCE" of="$MODEL_TMP" bs=8M iflag=direct oflag=direct conv=fsync status=none 2> "$DIRECT_ERROR"; then
    if [ -b "$SOURCE" ]; then
      cat "$DIRECT_ERROR" >&2
      exit 1
    fi
    log "Direct I/O is unsupported for this file or filesystem; using 64MiB cache-evicted chunks"
    if ! copy_file_with_cache_eviction "$SOURCE"; then
      log "Non-cached input is unsupported; using buffered 64MiB chunks with fsync and cache eviction"
      copy_file_buffered "$SOURCE"
    fi
  fi
  rm -f "$DIRECT_ERROR"
  DIRECT_ERROR=

  log "Verifying written model"
  if ! MODEL_TMP_SHA256=$(dd if="$MODEL_TMP" bs=8M iflag=direct status=none 2>/dev/null | sha256sum); then
    log "Direct verification read is unsupported; evicting caches before a buffered read"
    drop_caches
    MODEL_TMP_SHA256=$(sha256sum "$MODEL_TMP")
  fi
  MODEL_TMP_SHA256=${MODEL_TMP_SHA256%% *}
  if [ "$MODEL_TMP_SHA256" != "$MODEL_SHA256" ]; then
    log "Model verification failed: expected $MODEL_SHA256, got $MODEL_TMP_SHA256"
    exit 1
  fi
  chmod 644 "$MODEL_TMP"
  mv -f "$MODEL_TMP" "$MODEL_PATH"
  MODEL_TMP=
  register_gguf
  log "GGUF model import complete"
}

if [ "$ENGINE" = "llama-server" ] && [ -f "$MODEL_PATH" ]; then
  if printf '%s  %s\n' "$MODEL_SHA256" "$MODEL_PATH" | sha256sum -c --status; then
    register_gguf
    log "Verified GGUF model is already present at $MODEL_PATH"
    exit 0
  fi
  log "Existing GGUF model does not match MODEL_SHA256: $MODEL_PATH"
elif [ "$ENGINE" = "litert-lm" ] && "$VENV/bin/litert-lm" list 2>/dev/null | grep -q "$MODEL_ID"; then
  exit 0
fi

SOURCE=${AI_CORE_MODEL_SOURCE:-}
if [ -z "$SOURCE" ]; then
  if [ "$ENGINE" = "llama-server" ] && [ -e "$MODEL_PATH" ]; then
    log "Refusing to start with a mismatched GGUF model and no replacement source"
    exit 1
  fi
  log "AI_CORE_MODEL_SOURCE not set, skipping (online install / manual import later)"
  exit 0
fi

MEDIA_IMPORT=0
if [ "$SOURCE" = "media" ]; then
  log "Locating $MODEL_FILE on optical or removable boot media"
  if ! locate_media; then
    log "No readable optical or removable filesystem contains $MODEL_FILE"
    exit 1
  fi
  SOURCE=$MEDIA_SOURCE
  MEDIA_IMPORT=1
fi

if [ ! -e "$SOURCE" ]; then
  log "Model source not found: $SOURCE"
  exit 1
fi

if [ "$ENGINE" = "llama-server" ]; then
  if [ ! -b "$SOURCE" ] && [ "$MEDIA_IMPORT" -eq 0 ]; then
    log "Verifying model source: $SOURCE"
    printf '%s  %s\n' "$MODEL_SHA256" "$SOURCE" | sha256sum -c -
  fi
  copy_and_verify_gguf
  exit 0
fi

if [ ! -b "$SOURCE" ] && [ "$MEDIA_IMPORT" -eq 0 ]; then
  log "Verifying model source: $SOURCE"
  printf '%s  %s\n' "$MODEL_SHA256" "$SOURCE" | sha256sum -c -
  log "Importing $MODEL_ID"
  "$VENV/bin/litert-lm" import "$SOURCE" "$MODEL_ID"
  log "Model import complete"
  exit 0
fi

MODEL_REGISTRY=${LITERT_LM_DIR:-$HOME/.litert-lm}/models
MODEL_DIR=$MODEL_REGISTRY/${MODEL_ID//\//--}
MODEL_PATH=$MODEL_DIR/model.litertlm
mkdir -p "$MODEL_DIR"
MODEL_TMP=$(mktemp "$MODEL_DIR/.model.litertlm.import.XXXXXX")

log "Direct-I/O chunked import for $MODEL_ID from $SOURCE"
DIRECT_ERROR=$(mktemp "${TMPDIR:-/tmp}/ai-core-model-direct.XXXXXX")
if ! dd if="$SOURCE" of="$MODEL_TMP" bs=8M iflag=direct oflag=direct conv=fsync status=none 2> "$DIRECT_ERROR"; then
  if [ -b "$SOURCE" ]; then
    cat "$DIRECT_ERROR" >&2
    exit 1
  fi
  log "Direct input is unsupported on this filesystem; using 64MiB chunks of 8MiB reads with cache eviction"
  copy_file_with_cache_eviction "$SOURCE"
fi
rm -f "$DIRECT_ERROR"
DIRECT_ERROR=

log "Verifying written model"
if ! MODEL_TMP_SHA256=$(dd if="$MODEL_TMP" bs=8M iflag=direct status=none 2>/dev/null | sha256sum); then
  log "Direct verification read is unsupported; evicting caches before a buffered read"
  drop_caches
  MODEL_TMP_SHA256=$(sha256sum "$MODEL_TMP")
fi
MODEL_TMP_SHA256=${MODEL_TMP_SHA256%% *}
if [ "$MODEL_TMP_SHA256" != "$MODEL_SHA256" ]; then
  log "Model verification failed: expected $MODEL_SHA256, got $MODEL_TMP_SHA256"
  exit 1
fi
chmod 644 "$MODEL_TMP"
mv -f "$MODEL_TMP" "$MODEL_PATH"
MODEL_TMP=
"$VENV/bin/litert-lm" list | grep -q "$MODEL_ID"
log "Model import complete"
