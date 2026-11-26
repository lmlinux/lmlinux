#!/bin/bash
# lmlinux live-ISO builder — the distribution image.
#
# Bakes the lmlinux AI stack into the official Debian 13 live Cinnamon
# image and republishes the ISO in ONE xorriso session:
#   1. acquire the sha256-pinned debian-live Cinnamon ISO (download if
#      missing; the hash is cross-checked between the official cdimage
#      archive and the mirror)
#   2. extract /live/filesystem.squashfs and unsquash it to a rootfs tree
#   3. chroot: dpkg -i the lmlinux-ai-core .deb (offline — the live
#      system satisfies its dependencies; the postinst is chroot-safe by
#      design) and place the GGUF model at the configured MODEL_PATH under
#      /opt/ai-core/models/ (the exact path import-model.sh registers and
#      llama-server loads)
#   4. re-squash the rootfs with zstd (kernel-supported; the compression
#      rationale is in the script body) and the original block size
#   5. rebuild the ISO with -boot_image replay and the original geometry,
#      mapping the new squashfs over /live/filesystem.squashfs — the
#      vanilla boot menu, kernel, and initrd stay untouched
#   6. verify the boot metadata invariants (MBR identity apart from the
#      partition table, valid CHS geometry,
#      identical El Torito properties/options, BIOS and UEFI boot images
#      byte-identical apart from the fields xorriso legitimately rewrites
#      on relocation), the squashfs extracted back from the published ISO
#      byte-identical, and the model hash re-verified inside it
#   7. publish the ISO plus a whole-ISO sha256 with atomic renames
#
# The result boots straight into a live Cinnamon desktop where the AI
# works offline (model included); running the on-desktop installer copies
# the whole system — AI included — to disk, fully offline. No preseed and
# no network are needed when booting or installing from the finished image.
#
# MODEL PAYLOAD: MODEL_PATH (local file) or MODEL_URL (fetched into the out
# cache), always pinned by
# MODEL_SHA256 and verified BEFORE anything enters the squashfs. Without
# either, a 9MiB random dummy is generated (pipeline smoke builds only).

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${OUT_DIR:-$ROOT/build/debian/out}
LIVE_URL=${LIVE_URL:-https://mirrors.ustc.edu.cn/debian-cd/13.8.0-live/amd64/iso-hybrid/debian-live-13.8.0-amd64-cinnamon.iso}
LIVE_NAME=${LIVE_URL##*/}
LIVE_SHA256=${LIVE_SHA256:-eea22158e45dd7e0fba13bca5ebbcedd0014086464c1e3ae602ec73ae2932be7}
# Debian 13.8.0 live Cinnamon; the hash was cross-checked between
# cdimage.debian.org and the USTC mirror.
MODEL_FILE=${MODEL_FILE:-Qwen3.5-9B-Q4_K_M.gguf}
MODEL_ALIAS=${MODEL_ALIAS:-qwen3.5-9b}
DUMMY_MODEL_SIZE=${DUMMY_MODEL_SIZE:-9437184}
# Real-model build: MODEL_PATH selects a local payload file (skips dummy
# generation); MODEL_URL fetches the payload into the out cache when
# MODEL_PATH is not given. Either way MODEL_SHA256 is the pinned expected
# hash and is REQUIRED (fail-fast before anything enters the squashfs).
# When both are given, MODEL_PATH wins and MODEL_URL is ignored.
MODEL_PATH=${MODEL_PATH:-}
MODEL_URL=${MODEL_URL:-}
PINNED_MODEL_SHA256=${MODEL_SHA256:-}
ISO_NAME=${ISO_NAME:-lmlinux-debian-13.8.0-amd64-cinnamon-live-${MODEL_ALIAS}}
# CPU cap for the parallel squashfs steps (unsquashfs/mksquashfs). Both tools
# default to every core, which starves other work on a shared build host;
# 16 keeps the slow step comfortably fast. Override with BUILD_PROCESSORS.
BUILD_PROCESSORS=${BUILD_PROCESSORS:-16}
KEEP_WORK=${KEEP_WORK:-0}

WORK=
ISO=
REBUILD_ISO=
BOOT_BEFORE=
BOOT_AFTER=
MBR_BEFORE=
MBR_AFTER=
BIOS_IMG_DIR=
CHECKSUM_WORK=
CHROOT_MOUNTED=
ALLOW_ZERO_CHS=0

log() { printf '[build-live] %s\n' "$*"; }
die() { printf '[build-live] ERROR: %s\n' "$*" >&2; exit 1; }

cleanup() {
  status=$?
  trap - EXIT
  if [ -n "$CHROOT_MOUNTED" ]; then
    umount "$CHROOT_MOUNTED/dev" 2>/dev/null || true
    umount "$CHROOT_MOUNTED/proc" 2>/dev/null || true
    umount "$CHROOT_MOUNTED/sys" 2>/dev/null || true
  fi
  if [ "$KEEP_WORK" = 1 ] && [ -n "$WORK" ]; then
    log "KEEP_WORK=1: work tree kept at $WORK"
  else
    [ -z "$WORK" ] || rm -rf "$WORK"
  fi
  [ -z "$ISO" ] || rm -f "$ISO"
  [ -z "$REBUILD_ISO" ] || rm -f "$REBUILD_ISO"
  [ -z "$BOOT_BEFORE" ] || rm -f "$BOOT_BEFORE"
  [ -z "$BOOT_AFTER" ] || rm -f "$BOOT_AFTER"
  [ -z "$MBR_BEFORE" ] || rm -f "$MBR_BEFORE"
  [ -z "$MBR_AFTER" ] || rm -f "$MBR_AFTER"
  [ -z "$BIOS_IMG_DIR" ] || rm -rf "$BIOS_IMG_DIR"
  [ -z "$CHECKSUM_WORK" ] || rm -f "$CHECKSUM_WORK"
  exit "$status"
}
trap cleanup EXIT

case $ISO_NAME in
  *[!A-Za-z0-9._-]*|'') die "ISO_NAME may contain only letters, digits, dots, underscores, and dashes" ;;
esac
case $MODEL_FILE in
  *[!A-Za-z0-9._-]*|'') die "MODEL_FILE must be a plain filename containing only letters, digits, dots, underscores, and dashes" ;;
esac
case $MODEL_ALIAS in
  *[!A-Za-z0-9._-]*|'') die "MODEL_ALIAS may contain only letters, digits, dots, underscores, and dashes" ;;
esac
case ${ISO_NAME,,} in
  *"${MODEL_ALIAS,,}"*) ;;
  *) die "ISO_NAME must contain the model alias '$MODEL_ALIAS' so artifacts identify their model" ;;
esac

command -v xorriso >/dev/null 2>&1 || die "xorriso is required; install it first"
command -v unsquashfs >/dev/null 2>&1 || die "unsquashfs is required; install squashfs-tools first"
command -v mksquashfs >/dev/null 2>&1 || die "mksquashfs is required; install squashfs-tools first"
[ "$(id -u)" = 0 ] || die "must run as root (chroot and mount are required)"
ISO_FINAL=$OUT/$ISO_NAME.iso
LIVE=$OUT/$LIVE_NAME

if [ -n "$MODEL_PATH" ] && [ -n "$MODEL_URL" ]; then
  log "Both MODEL_PATH and MODEL_URL are set; using MODEL_PATH and ignoring MODEL_URL"
  MODEL_URL=
fi

mkdir -p "$OUT"

# ── 1. Live ISO acquisition and verification ───────────────────
if [ ! -f "$LIVE" ]; then
  log "Downloading $LIVE_URL"
  if ! curl -fsSL --retry 3 -o "$LIVE.part" "$LIVE_URL"; then
    die "Download failed — check the network (curl honors http_proxy/https_proxy for restricted networks), or point LIVE_URL at a reachable Debian mirror"
  fi
  mv "$LIVE.part" "$LIVE"
fi
ACTUAL_SHA256=$(sha256sum "$LIVE")
ACTUAL_SHA256=${ACTUAL_SHA256%% *}
[ "$ACTUAL_SHA256" = "$LIVE_SHA256" ] \
  || die "Live ISO hash mismatch: $LIVE (expected $LIVE_SHA256, got $ACTUAL_SHA256)"
log "Live ISO verified: $LIVE ($LIVE_SHA256)"

# ── 2. Payload: model (real or dummy) ──────────────────────────
PAYLOAD_MODEL=
if [ -z "$MODEL_PATH" ] && [ -n "$MODEL_URL" ]; then
  [ -n "$PINNED_MODEL_SHA256" ] \
    || die "MODEL_SHA256 is required when MODEL_URL is set (pinned verification before import)"
  MODEL_PATH=$OUT/$MODEL_FILE
  if [ -f "$MODEL_PATH" ] && printf '%s  %s\n' "$PINNED_MODEL_SHA256" "$MODEL_PATH" | sha256sum -c --status 2>/dev/null; then
    log "Model cache hit: $MODEL_PATH (sha256 verified)"
  else
    log "Fetching the model payload from $MODEL_URL"
    fetch_ok=0
    for attempt in 1 2; do
      rm -f "$MODEL_PATH.part"
      if curl -fL --retry 3 --retry-delay 2 -o "$MODEL_PATH.part" "$MODEL_URL" \
         && printf '%s  %s\n' "$PINNED_MODEL_SHA256" "$MODEL_PATH.part" | sha256sum -c --status; then
        fetch_ok=1
        break
      fi
      log "Model fetch attempt $attempt failed (network error or hash mismatch); retrying from scratch"
    done
    [ "$fetch_ok" = 1 ] || die "Could not fetch a payload matching MODEL_SHA256 from $MODEL_URL"
    mv -f "$MODEL_PATH.part" "$MODEL_PATH"
  fi
fi
if [ -n "$MODEL_PATH" ]; then
  [ -f "$MODEL_PATH" ] || die "MODEL_PATH not found: $MODEL_PATH"
  [ -n "$PINNED_MODEL_SHA256" ] \
    || die "MODEL_SHA256 is required when MODEL_PATH is set (pinned verification before import)"
  ACTUAL_MODEL_SHA256=$(sha256sum "$MODEL_PATH")
  ACTUAL_MODEL_SHA256=${ACTUAL_MODEL_SHA256%% *}
  [ "$ACTUAL_MODEL_SHA256" = "$PINNED_MODEL_SHA256" ] \
    || die "Model payload hash mismatch: $MODEL_PATH (expected $PINNED_MODEL_SHA256, got $ACTUAL_MODEL_SHA256)"
  PAYLOAD_MODEL=$MODEL_PATH
  log "Real model payload: $MODEL_PATH ($(stat -c %s "$PAYLOAD_MODEL") bytes, sha256 $PINNED_MODEL_SHA256)"
else
  DUMMY_MODEL=$OUT/dummy-$MODEL_FILE
  if [ ! -f "$DUMMY_MODEL" ]; then
    log "Generating $DUMMY_MODEL_SIZE-byte dummy model payload"
    head -c "$DUMMY_MODEL_SIZE" /dev/urandom > "$DUMMY_MODEL.part"
    mv "$DUMMY_MODEL.part" "$DUMMY_MODEL"
  fi
  PAYLOAD_MODEL=$DUMMY_MODEL
  log "Dummy model: $DUMMY_MODEL ($DUMMY_MODEL_SIZE bytes)"
fi
MODEL_SHA256=$(sha256sum "$PAYLOAD_MODEL")
MODEL_SHA256=${MODEL_SHA256%% *}
MODEL_SIZE=$(stat -c %s "$PAYLOAD_MODEL")
log "Model payload: $(basename "$PAYLOAD_MODEL") ($MODEL_SIZE bytes, sha256 $MODEL_SHA256)"

# ── 2.5 lmlinux-ai-core .deb (the apt-installable ai-core payload) ──
# Unless an explicit AI_CORE_DEB is pinned, the deb builder ALWAYS runs
# here: it no-ops when the existing artifact is fresh for the current
# sources (inputs stamp), and rebuilds when any packaging source changed —
# a cached .deb can never ship stale ai-core content in the image.
if [ -z "${AI_CORE_DEB:-}" ]; then
  bash "$ROOT/packaging/ai-core-deb/build-deb.sh"
  AI_CORE_DEB=$(ls -1 "$OUT"/lmlinux-ai-core_*_amd64.deb | sort -V | tail -1)
fi
[ -f "$AI_CORE_DEB" ] || die "ai-core .deb not found: $AI_CORE_DEB"
AI_CORE_DEB_NAME=${AI_CORE_DEB##*/}
AI_CORE_DEB_SHA256=$(sha256sum "$AI_CORE_DEB")
AI_CORE_DEB_SHA256=${AI_CORE_DEB_SHA256%% *}
log "ai-core package: $AI_CORE_DEB ($AI_CORE_DEB_NAME, sha256 $AI_CORE_DEB_SHA256)"

# ── 3. Unsquash the live system ────────────────────────────────
# The work tree lives under OUT (not /tmp): it needs ~3x the squashfs
# size, and xorriso's medium capacity is the OUT_DIR filesystem's free
# space, so OUT must be on a filesystem with room anyway.
WORK=$(mktemp -d "$OUT/live-build.XXXXXX")
log "Work tree: $WORK"

xorriso -osirrox on -indev "$LIVE" -extract /live/filesystem.squashfs "$WORK/filesystem.squashfs" \
  || die "Could not extract /live/filesystem.squashfs from the live ISO"
SQUASH_ORIG_SIZE=$(stat -c %s "$WORK/filesystem.squashfs")
log "Extracted filesystem.squashfs ($SQUASH_ORIG_SIZE bytes)"

# Compression: zstd, NOT the live image's xz. Debian picks xz to minimize
# mirror download bandwidth; this image ships on offline USB media where
# size is not the constraint but the USER'S decompression cost is: live
# boot reads the squashfs lazily and the on-desktop installer reads it in
# full (~13 GiB decompressed), and the kernel's zstd decoder is 3-5x
# faster than xz. The Debian 13 kernel supports zstd squashfs
# (CONFIG_SQUASHFS_ZSTD=y, verified in the live kernel config). The
# incompressible default model payload (~5.29 GiB) is stored as cheap
# uncompressed blocks under either compressor, so zstd costs only ~1 GiB of
# image size on the compressible system part.
SQUASH_COMP=zstd
SQUASH_INFO=$(unsquashfs -s "$WORK/filesystem.squashfs")
SQUASH_BLOCK=$(printf '%s\n' "$SQUASH_INFO" | sed -n 's/^Block size \([0-9]*\)$/\1/p')
[ -n "$SQUASH_BLOCK" ] || die "Could not read the squashfs block size from the live image"
log "Squashfs: compression $SQUASH_COMP, block size $SQUASH_BLOCK"

log "Unsquashing the live rootfs (this is the slow step)"
unsquashfs -no-progress -processors "$BUILD_PROCESSORS" -d "$WORK/rootfs" "$WORK/filesystem.squashfs" \
  || die "unsquashfs failed"
[ -d "$WORK/rootfs/usr" ] || die "unsquashfs produced no usable rootfs tree"

# ── 4. Chroot: install ai-core, place the model ────────────────
mount --bind /proc "$WORK/rootfs/proc" || die "Could not bind /proc into the chroot"
CHROOT_PROC=$WORK/rootfs/proc
mount --bind /sys "$WORK/rootfs/sys" || { umount "$CHROOT_PROC"; die "Could not bind /sys into the chroot"; }
CHROOT_SYS=$WORK/rootfs/sys
mount --bind /dev "$WORK/rootfs/dev" || { umount "$CHROOT_SYS" "$CHROOT_PROC"; die "Could not bind /dev into the chroot"; }
CHROOT_DEV=$WORK/rootfs/dev
CHROOT_MOUNTED=$WORK/rootfs

log "Installing the ai-core .deb in the chroot (offline)"
cp "$AI_CORE_DEB" "$WORK/rootfs/tmp/ai-core.deb"
chroot "$WORK/rootfs" /usr/bin/dpkg -i /tmp/ai-core.deb \
  || { log "chroot dpkg output:"; chroot "$WORK/rootfs" /usr/bin/dpkg --audit || true; die "dpkg -i failed in the chroot"; }
rm -f "$WORK/rootfs/tmp/ai-core.deb"

# GGUF into the path shared by import-model.sh and engine.sh. Hardlink it,
# verify the bytes through the rootfs, and pin all three model identity fields
# in config.env. Explicit custom and dummy builds must never inherit the
# package's default filename, hash, or alias.
MODEL_DIR="$WORK/rootfs/opt/ai-core/models"
INSTALLED_MODEL_PATH="$MODEL_DIR/$MODEL_FILE"
mkdir -p "$MODEL_DIR"
ln "$PAYLOAD_MODEL" "$INSTALLED_MODEL_PATH"
log "Model placed at /opt/ai-core/models/$MODEL_FILE"

log "Verifying the model hash through the rootfs tree"
REGISTRY_SHA256=$(sha256sum "$INSTALLED_MODEL_PATH")
REGISTRY_SHA256=${REGISTRY_SHA256%% *}
[ "$REGISTRY_SHA256" = "$MODEL_SHA256" ] \
  || die "GGUF model hash mismatch inside the rootfs tree (expected $MODEL_SHA256, got $REGISTRY_SHA256)"
sed -i \
  -e "s|^MODEL_PATH=.*|MODEL_PATH=/opt/ai-core/models/$MODEL_FILE|" \
  -e "s|^MODEL_SHA256=.*|MODEL_SHA256=$MODEL_SHA256|" \
  -e "s|^MODEL_ALIAS=.*|MODEL_ALIAS=$MODEL_ALIAS|" \
  "$WORK/rootfs/etc/ai-core/config.env"
grep -qx "MODEL_PATH=/opt/ai-core/models/$MODEL_FILE" "$WORK/rootfs/etc/ai-core/config.env" \
  || die "config.env MODEL_PATH does not match the baked GGUF location"
grep -qx "MODEL_SHA256=$MODEL_SHA256" "$WORK/rootfs/etc/ai-core/config.env" \
  || die "config.env MODEL_SHA256 does not match the baked GGUF hash"
grep -qx "MODEL_ALIAS=$MODEL_ALIAS" "$WORK/rootfs/etc/ai-core/config.env" \
  || die "config.env MODEL_ALIAS does not match the requested model alias"

# postinst seeds /etc/skel from the package defaults before the live builder
# pins the requested model above. Align that seed too, or a live user's bare
# hax would keep requesting the package's default model instead of MODEL_ALIAS.
HAX_PORT=$(sed -n 's/^AI_CORE_PORT=//p' "$WORK/rootfs/etc/ai-core/config.env")
case $HAX_PORT in
  *[!0-9]*|'') die "config.env AI_CORE_PORT is not a numeric port" ;;
esac
HAX_SEED=$WORK/rootfs/etc/skel/.config/hax/config.json
[ -f "$HAX_SEED" ] || die "postinst did not seed the live user's hax config"
sed -i \
  -e "s|^  \"model\": \".*\",$|  \"model\": \"$MODEL_ALIAS\",|" \
  -e "s|^      \"base_url\": \"http://127.0.0.1:[0-9]*/v1\"$|      \"base_url\": \"http://127.0.0.1:$HAX_PORT/v1\"|" \
  "$HAX_SEED"
grep -Fqx "  \"model\": \"$MODEL_ALIAS\"," "$HAX_SEED" \
  || die "hax seed model does not match the requested model alias"
grep -Fqx "      \"base_url\": \"http://127.0.0.1:$HAX_PORT/v1\"" "$HAX_SEED" \
  || die "hax seed endpoint does not match config.env"

log "Verifying the staged llama-server binary in the chroot"
chroot "$WORK/rootfs" /usr/bin/env \
  "LD_LIBRARY_PATH=/opt/ai-core/llama-b12669" \
  /opt/ai-core/llama-b12669/llama-server --version >/dev/null 2>&1 \
  || die "llama-server could not execute in the target rootfs"

# The image is boot-complete: sanity-check the pieces the installed/live
# boot needs.
[ -x "$WORK/rootfs/usr/bin/ai" ] || die "/usr/bin/ai is missing after the chroot install"
[ -x "$WORK/rootfs/usr/bin/hax" ] || die "/usr/bin/hax is missing after the chroot install"
[ -x "$WORK/rootfs/opt/ai-core/llama-b12669/llama-server" ] || die "llama-server is missing after the chroot install"
[ -f "$WORK/rootfs/usr/lib/systemd/system/ai-core.service" ] || die "ai-core.service is missing after the chroot install"
# The enablement symlink is absolute (/usr/lib/systemd/...), so -e would
# resolve it against the BUILD HOST root and miss; -L proves the postinst
# created it, and the target existence was checked above.
[ -L "$WORK/rootfs/etc/systemd/system/multi-user.target.wants/ai-core.service" ] \
  || [ -e "$WORK/rootfs/etc/systemd/system/multi-user.target.wants/ai-core.service" ] \
  || die "ai-core.service is not enabled after the chroot install (postinst should have done it)"

umount "$CHROOT_DEV" "$CHROOT_SYS" "$CHROOT_PROC"
CHROOT_MOUNTED=

log "Chroot stage complete: ai-core installed, GGUF model placed and verified"

# ── 5. Re-squash ───────────────────────────────────────────────
log "Re-squashing the rootfs (compression $SQUASH_COMP, block $SQUASH_BLOCK, $BUILD_PROCESSORS processors; this is the slow step)"
mksquashfs "$WORK/rootfs" "$WORK/filesystem.squashfs.new" \
  -comp "$SQUASH_COMP" -b "$SQUASH_BLOCK" -processors "$BUILD_PROCESSORS" -noappend -no-recovery -no-progress \
  || die "mksquashfs failed"
SQUASH_NEW_SIZE=$(stat -c %s "$WORK/filesystem.squashfs.new")
log "New squashfs: $SQUASH_NEW_SIZE bytes (was $SQUASH_ORIG_SIZE)"

# Structure check before the ISO rebuild: the AI payload must be inside.
# One listing pass into a file, then grep the file: piping unsquashfs -l
# into grep -q breaks under pipefail — grep exits on the first match,
# unsquashfs (still writing a ~290k-line listing) dies of SIGPIPE, and
# the pipeline reports failure although the path IS present.
SQUASH_LISTING=$WORK/squashfs-new.listing
unsquashfs -l "$WORK/filesystem.squashfs.new" > "$SQUASH_LISTING" \
  || die "Could not list the re-squashed filesystem"
for path in \
  /usr/bin/ai \
  /usr/bin/hax \
  /opt/ai-core/llama-b12669/llama-server \
  /usr/lib/systemd/system/ai-core.service \
  "/opt/ai-core/models/$MODEL_FILE" \
  /etc/ai-core/config.env \
  /etc/skel/.config/hax/config.json; do
  grep -q "$path" "$SQUASH_LISTING" \
    || die "$path is missing from the re-squashed filesystem"
done
log "Squashfs structure verified: ai entry point, service, model, config all present"

# ── 6. Boot metadata reports before the rebuild ────────────────
ISO=$OUT/$ISO_NAME.build-$$.iso
REBUILD_ISO=$OUT/$ISO_NAME.rebuild-$$.iso
BOOT_BEFORE=$WORK/boot-before.txt
BOOT_AFTER=$WORK/boot-after.txt
MBR_BEFORE=$WORK/mbr-before.bin
MBR_AFTER=$WORK/mbr-after.bin
BIOS_IMG_DIR=$WORK/bios-img
CHECKSUM_WORK=$OUT/$ISO_NAME.iso.sha256.$$

xorriso -indev "$LIVE" -report_el_torito plain -report_system_area plain > "$BOOT_BEFORE"
grep -Eq '^El Torito boot img :.*BIOS' "$BOOT_BEFORE" || die "Live ISO has no El Torito BIOS entry"
grep -Eq '^El Torito boot img :.*UEFI' "$BOOT_BEFORE" || die "Live ISO has no El Torito UEFI entry"
dd if="$LIVE" of="$MBR_BEFORE" bs=512 count=1 status=none

validate_boot_geometry() {
  awk -F: -v allow_zero="$ALLOW_ZERO_CHS" '
    /^MBR heads per cyl/ { heads = $2 + 0; head_lines++ }
    /^MBR secs per head/ { sectors = $2 + 0; sector_lines++ }
    END {
      if (head_lines != 1 || sector_lines != 1) {
        exit 1
      }
      if (allow_zero == 1) {
        # xorriso emits 0/0 when cylinder alignment is explicitly disabled
        # for an image beyond the MBR alignment limit. The LBA span check
        # below proves that the partition still covers the complete ISO.
        if (heads != 0 || sectors != 0) {
          exit 1
        }
      } else if (heads < 1 || heads > 255 || sectors < 1 || sectors > 63) {
        exit 1
      }
    }
  ' "$1" || die "Invalid MBR CHS geometry in $2"
}
validate_boot_geometry "$BOOT_BEFORE" "the live ISO"

# Rebuild in ONE session, replaying the boot configuration. Keep the
# original CHS geometry explicit so the replay cannot recompute it to
# zeroed fields. Exception: once the projected image exceeds what the
# original geometry can
# address (1024 cylinders × heads × secs × 512), xorriso cannot honor the
# requested geometry and the rebuilt MBR ends up with ZEROED CHS fields.
# Up to xorriso's documented MBR alignment limit, use the maximum
# conventional CHS geometry 255/63. Above 8,323,596,288 bytes, cylinder
# alignment is impossible: explicitly disable it and require the resulting
# 0/0 CHS plus a complete LBA partition span instead of misreporting aligned
# geometry. The normalized-report comparison below masks recomputed CHS lines.
ORIG_HEADS=$(awk -F: '/^MBR heads per cyl/ {print $2 + 0}' "$BOOT_BEFORE")
ORIG_SECS=$(awk -F: '/^MBR secs per head/ {print $2 + 0}' "$BOOT_BEFORE")
PROJECTED_SIZE=$(( $(stat -c %s "$LIVE") + SQUASH_NEW_SIZE + 33554432 ))  # +32MiB margin: metadata, cylinder alignment
CHS_CAPACITY=$(( 1024 * ORIG_HEADS * ORIG_SECS * 512 ))
MBR_ALIGNED_CAPACITY=8323596288
PARTITION_ALIGNMENT_OPTIONS=()
if [ "$PROJECTED_SIZE" -gt "$CHS_CAPACITY" ]; then
  PART_HEADS=255
  PART_SECS=63
  log "Projected image ($PROJECTED_SIZE bytes) exceeds the original CHS capacity ($CHS_CAPACITY bytes); rebuilding with the maximum conventional geometry 255/63"
else
  PART_HEADS=$ORIG_HEADS
  PART_SECS=$ORIG_SECS
fi
if [ "$PROJECTED_SIZE" -gt "$MBR_ALIGNED_CAPACITY" ]; then
  ALLOW_ZERO_CHS=1
  PARTITION_ALIGNMENT_OPTIONS=(-boot_image any partition_cyl_align=off)
  log "Projected image exceeds the MBR cylinder-alignment limit ($MBR_ALIGNED_CAPACITY bytes); disabling alignment and requiring 0/0 CHS with full LBA partition coverage"
fi
log "Rebuilding as a single session (CHS geometry $PART_HEADS/$PART_SECS)"
xorriso \
  -indev "$LIVE" -outdev "$REBUILD_ISO" \
  -boot_image any replay \
  -boot_image any "partition_hd_cyl=$PART_HEADS" \
  -boot_image any "partition_sec_hd=$PART_SECS" \
  "${PARTITION_ALIGNMENT_OPTIONS[@]}" \
  -map "$WORK/filesystem.squashfs.new" /live/filesystem.squashfs \
  || die "xorriso rebuild failed"

xorriso -indev "$REBUILD_ISO" -report_el_torito plain -report_system_area plain > "$BOOT_AFTER"
validate_boot_geometry "$BOOT_AFTER" "the rebuilt ISO"
if [ "$ALLOW_ZERO_CHS" = 1 ]; then
  read -r BEFORE_PART_START BEFORE_PART_BLOCKS < <(
    awk '/^MBR partition[[:space:]]*:/ && $4 == 1 { print $(NF - 1), $NF; exit }' "$BOOT_BEFORE"
  )
  read -r AFTER_PART_START AFTER_PART_BLOCKS < <(
    awk '/^MBR partition[[:space:]]*:/ && $4 == 1 { print $(NF - 1), $NF; exit }' "$BOOT_AFTER"
  )
  ISO_SECTORS=$(awk -F: '/^ISO image size\/512/ { print $2 + 0; exit }' "$BOOT_AFTER")
  [ -n "$BEFORE_PART_START" ] && [ -n "$BEFORE_PART_BLOCKS" ] \
    || die "Could not read the original MBR partition span"
  [ -n "$AFTER_PART_START" ] && [ -n "$AFTER_PART_BLOCKS" ] && [ "$ISO_SECTORS" -gt 0 ] \
    || die "Could not read the rebuilt MBR partition span"
  [ "$AFTER_PART_START" = "$BEFORE_PART_START" ] \
    || die "Large-image MBR partition start changed: $BEFORE_PART_START -> $AFTER_PART_START"
  [ "$AFTER_PART_BLOCKS" -eq $((ISO_SECTORS - AFTER_PART_START)) ] \
    || die "Large-image MBR partition does not cover the complete ISO: start=$AFTER_PART_START blocks=$AFTER_PART_BLOCKS iso_sectors=$ISO_SECTORS"
  log "Large-image MBR LBA span verified: start $AFTER_PART_START, blocks $AFTER_PART_BLOCKS, complete ISO coverage"
fi
dd if="$REBUILD_ISO" of="$MBR_AFTER" bs=512 count=1 status=none

# ── 7. Boot metadata verification ──────────────────────────────
# The live ISO MBR (syslinux isohdpfx) carries the BIOS boot image
# address at bytes 432-440; xorriso rewrites it on relocation, and
# regenerates the random disk signature (440-444). Everything else in the
# MBR must stay byte-identical; the partition table itself is checked via
# the normalized reports.
cmp -s <(dd if="$MBR_BEFORE" bs=1 count=432 status=none) \
       <(dd if="$MBR_AFTER" bs=1 count=432 status=none) \
  || die "MBR boot code changed during ISO rebuild; refusing to publish $ISO"
cmp -s <(dd if="$MBR_BEFORE" bs=1 skip=436 count=4 status=none) \
       <(dd if="$MBR_AFTER" bs=1 skip=436 count=4 status=none) \
  || die "MBR reserved area changed during ISO rebuild; refusing to publish $ISO"
cmp -s <(dd if="$MBR_BEFORE" bs=1 skip=444 count=2 status=none) \
       <(dd if="$MBR_AFTER" bs=1 skip=444 count=2 status=none) \
  || die "MBR reserved bytes changed during ISO rebuild; refusing to publish $ISO"
cmp -s <(dd if="$MBR_BEFORE" bs=1 skip=510 count=2 status=none) \
       <(dd if="$MBR_AFTER" bs=1 skip=510 count=2 status=none) \
  || die "MBR signature changed during ISO rebuild; refusing to publish $ISO"
SIG_BEFORE=$(od -An -tx1 -j440 -N4 "$MBR_BEFORE" | tr -d ' \n')
SIG_AFTER=$(od -An -tx1 -j440 -N4 "$MBR_AFTER" | tr -d ' \n')
[ -n "$SIG_AFTER" ] || die "MBR disk signature could not be read"
if [ "$SIG_BEFORE" != "$SIG_AFTER" ]; then
  log "MBR disk signature regenerated by the rebuild: $SIG_BEFORE -> $SIG_AFTER (xorriso behavior)"
fi

boot_image_address() {
  awk -v platform="$2" '
    /^El Torito boot img[[:space:]]*:/ && $7 == platform {
      if (++found == 1) {
        size = $(NF - 1)
        lba = $NF
      }
    }
    END {
      if (found != 1 || size !~ /^[0-9]+$/ || lba !~ /^[0-9]+$/ || size == 0 || size % 4 != 0) {
        exit 1
      }
      print size, lba
    }
  ' "$1"
}

bios_boot_entry_number() {
  awk '
    /^El Torito boot img[[:space:]]*:/ && $7 == "BIOS" {
      if (++found == 1) {
        entry = $6
      }
    }
    END {
      if (found != 1 || entry !~ /^[0-9]+$/) {
        exit 1
      }
      print entry
    }
  ' "$1"
}

bios_boot_img_path() {
  awk -v entry="$2" '
    /^El Torito img path[[:space:]]*:/ {
      sub(/^El Torito img path[[:space:]]*:[[:space:]]*/, "")
      number = $1
      sub(/^[^[:space:]]+[[:space:]]*/, "")
      if (number == entry) {
        print
        found++
      }
    }
    END { exit(found == 1 ? 0 : 1) }
  ' "$1"
}

boot_info_table_enabled() {
  grep -q 'boot-info-table' "$BOOT_BEFORE"
}

# Zero the bytes inside an extracted BIOS boot image that xorriso
# legitimately rewrites when the image is relocated: the
# boot-info-table fields at image offset 8 (bi_pvd), offset 12
# (bi_file), and offset 20 (bi_csum).
mask_bios_boot_image() {
  cp -- "$1" "$2"
  if boot_info_table_enabled; then
    dd if=/dev/zero of="$2" bs=1 seek=8 count=4 conv=notrunc status=none
    dd if=/dev/zero of="$2" bs=1 seek=12 count=4 conv=notrunc status=none
    dd if=/dev/zero of="$2" bs=1 seek=20 count=4 conv=notrunc status=none
  fi
}

verify_bios_boot_image() {
  before_size=$1
  before_lba=$2
  after_size=$3
  after_lba=$4

  before_entry=$(bios_boot_entry_number "$BOOT_BEFORE") || die "Could not identify the single BIOS El Torito entry in $BOOT_BEFORE"
  after_entry=$(bios_boot_entry_number "$BOOT_AFTER") || die "Could not identify the single BIOS El Torito entry in $BOOT_AFTER"
  before_path=$(bios_boot_img_path "$BOOT_BEFORE" "$before_entry") || die "Could not read the BIOS boot image path from $BOOT_BEFORE"
  after_path=$(bios_boot_img_path "$BOOT_AFTER" "$after_entry") || die "Could not read the BIOS boot image path from $BOOT_AFTER"
  [ -n "$before_path" ] || die "Missing BIOS boot image path in $BOOT_BEFORE"
  [ "$before_path" = "$after_path" ] || die "BIOS boot image path changed during ISO rebuild: $before_path -> $after_path"

  mkdir -p "$BIOS_IMG_DIR"
  xorriso -osirrox on -indev "$LIVE" -extract "$before_path" "$BIOS_IMG_DIR/before.img" >/dev/null 2>&1 \
    || die "Could not extract the BIOS boot image $before_path from the live ISO"
  xorriso -osirrox on -indev "$REBUILD_ISO" -extract "$after_path" "$BIOS_IMG_DIR/after.img" >/dev/null 2>&1 \
    || die "Could not extract the BIOS boot image $after_path from the rebuilt ISO"

  if boot_info_table_enabled; then
    # boot-info-table is patched by xorriso on relocation: bi_pvd (byte 8),
    # bi_file (byte 12), and bi_csum (byte 20). Read them before masking.
    before_table_pvd=$(od -An -tu4 -j8 -N4 "$BIOS_IMG_DIR/before.img")
    after_table_pvd=$(od -An -tu4 -j8 -N4 "$BIOS_IMG_DIR/after.img")
    before_table_lba=$(od -An -tu4 -j12 -N4 "$BIOS_IMG_DIR/before.img")
    after_table_lba=$(od -An -tu4 -j12 -N4 "$BIOS_IMG_DIR/after.img")
  fi

  mask_bios_boot_image "$BIOS_IMG_DIR/before.img" "$BIOS_IMG_DIR/before.masked.img"
  mask_bios_boot_image "$BIOS_IMG_DIR/after.img" "$BIOS_IMG_DIR/after.masked.img"
  cmp -s "$BIOS_IMG_DIR/before.masked.img" "$BIOS_IMG_DIR/after.masked.img" \
    || die "BIOS boot image content changed during ISO rebuild; refusing to publish $ISO"

  if boot_info_table_enabled; then
    if [ "$before_table_lba" -eq "$before_lba" ]; then
      [ "$after_table_lba" -eq "$after_lba" ] \
        || die "BIOS boot-info-table image address was not updated to the relocated BIOS boot image (expected $after_lba, got $after_table_lba)"
    else
      [ "$before_table_lba" -eq "$after_table_lba" ] \
        || die "BIOS boot-info-table image address changed although the original image was not patched"
    fi
    # bi_pvd must point at a Primary Volume Descriptor of the rebuilt ISO
    # (byte 0 type 1, magic "CD001" at byte 1).
    if [ "$after_table_pvd" -gt 0 ] \
       && [ "$(dd if="$REBUILD_ISO" bs=2048 skip="$after_table_pvd" count=1 status=none | head -c 6 | od -An -tc | tr -d ' \n')" = '001CD001' ]; then
      :
    else
      die "BIOS boot-info-table bi_pvd does not reference a valid Primary Volume Descriptor in the rebuilt ISO (got $after_table_pvd)"
    fi
    if [ "$before_table_pvd" = "$after_table_pvd" ]; then
      log "Note: the Primary Volume Descriptor stayed at LBA $after_table_pvd during this rebuild"
    else
      log "Primary Volume Descriptor moved from LBA $before_table_pvd to LBA $after_table_pvd; boot-info-table updated accordingly"
    fi
  fi

  # The isohdpfx MBR patch: the BIOS boot image address at MBR bytes 432-440
  # (512-byte sector LBA of isolinux.bin). xorriso must update it to the
  # relocated image, exactly like the boot-info-table address above.
  mbr_isohybrid_addr=$(od -An -tu4 -j432 -N4 "$MBR_AFTER")
  [ "$mbr_isohybrid_addr" -eq $((after_lba * 4)) ] \
    || die "isohybrid MBR BIOS image address was not updated to the relocated BIOS boot image (expected $((after_lba * 4)), got $mbr_isohybrid_addr)"

  # The El Torito Catalog must reference exactly the file bytes verified
  # above, in both the original and the rebuilt ISO.
  cmp -s \
    <(dd if="$LIVE" bs=2048 skip="$before_lba" count=$((before_size / 4)) status=none) \
    <(head -c $((before_size * 512)) "$BIOS_IMG_DIR/before.img") \
    || die "El Torito BIOS entry does not reference the boot image file content in $LIVE"
  cmp -s \
    <(dd if="$REBUILD_ISO" bs=2048 skip="$after_lba" count=$((after_size / 4)) status=none) \
    <(head -c $((after_size * 512)) "$BIOS_IMG_DIR/after.img") \
    || die "El Torito BIOS entry does not reference the boot image file content in $REBUILD_ISO"
}

verify_boot_image_address() {
  read -r before_size before_lba < <(boot_image_address "$BOOT_BEFORE" "$1") || die "Could not read the original $1 boot image address"
  read -r after_size after_lba < <(boot_image_address "$BOOT_AFTER" "$1") || die "Could not read the rebuilt $1 boot image address"
  [ "$before_size" = "$after_size" ] || die "$1 boot image size changed during ISO rebuild"
  if [ "$1" = "BIOS" ]; then
    verify_bios_boot_image "$before_size" "$before_lba" "$after_size" "$after_lba"
  else
    cmp -s \
      <(dd if="$LIVE" bs=2048 skip="$before_lba" count=$((before_size / 4)) status=none) \
      <(dd if="$REBUILD_ISO" bs=2048 skip="$after_lba" count=$((after_size / 4)) status=none) \
      || die "UEFI boot image content changed during ISO rebuild"
  fi
}

verify_boot_image_address BIOS
verify_boot_image_address UEFI

# Compare El Torito boot image options separately: dropped or mutated boot
# patch options (boot-info-table, grub2-boot-info) must fail the rebuild.
if ! diff -u <(grep '^El Torito img opts' "$BOOT_BEFORE") <(grep '^El Torito img opts' "$BOOT_AFTER"); then
  die "El Torito boot image options changed during ISO rebuild; refusing to publish $ISO"
fi

# Normalized report comparison: boot entry points and partition metadata may
# only change through legitimate relocation/growth/recomputation; everything
# else must stay.
normalized_boot_report() {
  awk -v allow_zero="$ALLOW_ZERO_CHS" '
    /^System area summary/ {
      if (allow_zero == 1) {
        sub(/cyl-align-(on|off)/, "cyl-align-<mode>")
      }
      print
      next
    }
    /^System area options/ && allow_zero == 1 { $NF = "<alignment>"; print; next }
    /^El Torito catalog/ { next }
    /^El Torito boot img[[:space:]]*:/ { $NF = "<relocated>"; print; next }
    /^El Torito img opts/ { next }
    /^ISO image size\/512/ { next }
    /^MBR heads per cyl/ { $NF = "<recomputed>"; print; next }
    /^MBR secs per head/ { $NF = "<recomputed>"; print; next }
    /^MBR partition[[:space:]]*:/ { $(NF - 1) = "<relocated>"; $NF = "<grown>"; print; next }
    /^GPT disk GUID/ { sub(/:.*/, ": <regenerated>"); print; next }
    /^GPT partition GUID/ { sub(/:.*/, ": <regenerated>"); print; next }
    /^GPT lba range/ { sub(/:.*/, ": <recomputed>"); print; next }
    /^GPT start and size/ { sub(/:.*/, ": <recomputed>"); print; next }
    /^APM start and size/ { sub(/:.*/, ": <recomputed>"); print; next }
    { print }
  ' "$1"
}
if ! diff -u <(normalized_boot_report "$BOOT_BEFORE") <(normalized_boot_report "$BOOT_AFTER"); then
  die "ISO boot entry points or partition metadata changed unexpectedly; refusing to publish $ISO"
fi
log "Boot metadata verified: MBR identity, El Torito properties, BIOS/UEFI boot image content"

# ── 8. Payload verification and atomic publish ─────────────────
xorriso -osirrox on -indev "$REBUILD_ISO" -extract /live/filesystem.squashfs "$WORK/filesystem.squashfs.verify" >/dev/null 2>&1 \
  || die "Could not extract /live/filesystem.squashfs from the rebuilt ISO"
cmp -s "$WORK/filesystem.squashfs.verify" "$WORK/filesystem.squashfs.new" \
  || die "filesystem.squashfs content changed in the ISO"
log "ISO payload verified: the baked squashfs landed byte-identical"

mv -f "$REBUILD_ISO" "$ISO"
REBUILD_ISO=
checksum=$(sha256sum "$ISO")
checksum=${checksum%% *}
printf '%s  %s\n' "$checksum" "$ISO_NAME.iso" > "$CHECKSUM_WORK"
mv -f "$ISO" "$ISO_FINAL"
ISO=
mv -f "$CHECKSUM_WORK" "$ISO_FINAL.sha256"
CHECKSUM_WORK=

log ""
log "Generated ISO: $ISO_FINAL"
log "Checksum: $ISO_FINAL.sha256"
log "Size: $(stat -c %s "$ISO_FINAL") bytes"
if [ -n "$MODEL_PATH" ]; then
  log "Model payload: real ($MODEL_SIZE bytes, sha256 $MODEL_SHA256) baked into the live system"
else
  log "WARNING: dummy model ($MODEL_SIZE bytes) — smoke build only, never distribute"
fi
log "The image boots into a live Cinnamon desktop with the AI working offline;"
log "the on-desktop installer copies the whole system to disk, fully offline."
