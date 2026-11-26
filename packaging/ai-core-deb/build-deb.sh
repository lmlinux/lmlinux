#!/bin/bash
# Build the lmlinux-ai-core Debian package (.deb) for the live image and
# standalone installations. Output: $OUT/lmlinux-ai-core_<version>_amd64.deb (+ .sha256).
#
# WHY A HANDCRAFTED DEB (not dpkg-buildpackage/debhelper): the package ships
# only scripts, conffiles, systemd units, and a PREBUILT venv — there is no
# source to compile, so debhelper's build machinery buys nothing here, and
# the build host is Rocky (no dpkg toolchain). A .deb is just an ar archive
# (debian-binary + control.tar.gz + data.tar.xz) assembled with tar+ar, which
# dpkg/apt on the target fully support: dpkg database entry, conffile
# handling, maintainer scripts, apt upgrades. The venv cannot be built on
# Rocky anyway (Python 3.12 vs Debian 13's 3.13), so it is built on a
# Debian 13 staging host and cached as a tarball.
#
# File set = the install.sh AI_CORE_IMAGE_BUILD=1 payload: the optional
# LiteRT-LM venv, official hax and llama-server binaries, /opt/ai-core payload,
# /usr/bin/ai + /usr/bin/hax, two systemd units, /etc/ai-core/config.env and
# /etc/profile.d/ai-core.sh as conffiles. The MODEL IS NOT in the package
# (imported from media by ai-core-model-import.service). install.sh itself is
# not shipped: the deb IS the installer now. /root/.litert-lm/config.json is
# created by postinst instead of being shipped, so upgrades never clobber a
# user-tuned file.
#
# Usage: packaging/ai-core-deb/build-deb.sh
# Environment:
#   OUT_DIR         output dir (default build/debian/out); holds the shippable
#                   debs — test-only revisions belong elsewhere (the chroot
#                   test uses OUT_DIR=<testdir>) so the ISO builder's
#                   newest-deb pick cannot ship a never-validated artifact
#   DEB_VERSION     upstream version (default 0.2.0)
#   DEB_REVISION    Debian revision (default 6)
#   VENV_TARBALL    explicit prebuilt venv tarball to embed (skips staging)
#   VENV_CACHE_DIR  venv tarball cache dir (default build/debian/out,
#                   independent of OUT_DIR; the cache filename embeds the
#                   pinned litert-lm version)
#   VENV_HOST       ssh target for venv staging (required when no cached venv
#                   tarball exists; any Debian 13 amd64 machine, e.g. user@host)
#   PIP_MIRROR      pypi mirror for litert-lm (default Tsinghua)
#   VENV_REBUILD_OVERWRITE=1  opt-in to overwrite an existing /opt/ai-core
#                   on the venv staging host (staging refuses otherwise)
#   HAX_ARCHIVE     optional local hax 0.7.0 archive (sha256 verified)
#   LLAMA_ARCHIVE   optional local llama.cpp b12669 archive (sha256 verified)

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SRC=$ROOT/packaging/ai-core
DEBDIR=$ROOT/packaging/ai-core-deb
OUT=${OUT_DIR:-$ROOT/build/debian/out}
VENV_CACHE_DIR=${VENV_CACHE_DIR:-$ROOT/build/debian/out}
DEB_VERSION=${DEB_VERSION:-0.2.0}
DEB_REVISION=${DEB_REVISION:-6}
VENV_HOST=${VENV_HOST:-}
PIP_MIRROR=${PIP_MIRROR:-https://pypi.tuna.tsinghua.edu.cn/simple}
LITERT_LM_VERSION=0.19.2
HAX_VERSION=0.7.0
HAX_SHA256=970183b80f1e7e8d2d4f8d9905234f415deb21cc80f111fbb5cc85bb9575fa3e
LLAMA_VERSION=b12669
LLAMA_SHA256=67d4bb52a775aa00a77895c07af4d95fc28b7b51c1e4dd04ecf6af21d08138a4
PKG=lmlinux-ai-core
FULL_VERSION=$DEB_VERSION-$DEB_REVISION
DEB=$OUT/${PKG}_${DEB_VERSION}-${DEB_REVISION}_amd64.deb
# The version is stamped into the cache name AND revalidated from the
# venv's dist-info on every use, so bumping LITERT_LM_VERSION cannot
# silently reuse a stale cache.
VENV_CACHE=$VENV_CACHE_DIR/ai-core-venv-litert-lm-$LITERT_LM_VERSION.tar.xz

log() { printf '[build-deb] %s\n' "$*"; }
die() { printf '[build-deb] ERROR: %s\n' "$*" >&2; exit 1; }

command -v ar >/dev/null 2>&1 || die "ar is required"
command -v xz >/dev/null 2>&1 || die "xz is required"
command -v ssh >/dev/null 2>&1 || die "ssh is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required (copyright generation)"
command -v curl >/dev/null 2>&1 || die "curl is required (pinned upstream archives)"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/lmlinux-deb.XXXXXX")
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# Official release archives are mandatory payload, never optional downloads on
# the installed system. Local staging overrides receive exactly the same pin
# verification as network downloads. hax is MIT; its copyright notice ships in
# /usr/share/doc/lmlinux-ai-core/hax.LICENSE.
mkdir "$WORK/downloads" "$WORK/hax-extract" "$WORK/llama-extract"
fetch_verified_archive() {
  local source_archive=$1 url=$2 expected_sha=$3 destination=$4
  if [ -n "$source_archive" ]; then
    [ -f "$source_archive" ] || die "archive not found: $source_archive"
    cp "$source_archive" "$destination"
  else
    log "Downloading $url"
    curl -fsSL --retry 3 -o "$destination" "$url" \
      || die "download failed (check the network or configure http_proxy/https_proxy and retry): $url"
  fi
  printf '%s  %s\n' "$expected_sha" "$destination" | sha256sum -c - \
    || die "archive hash mismatch: $destination"
}

HAX_URL="https://github.com/OleksandrChekhovskyi/hax/releases/download/v${HAX_VERSION}/hax-${HAX_VERSION}-linux-x86_64.tar.gz"
LLAMA_URL="https://github.com/ggml-org/llama.cpp/releases/download/$LLAMA_VERSION/llama-$LLAMA_VERSION-bin-ubuntu-x64.tar.gz"

# ── 1. Stage the prebuilt venv ────────────────────────────────
# Built on a Debian 13 staging host (same Python 3.13 / amd64 as the install
# target) AT THE FINAL PATH /opt/ai-core/venv: venvs are not relocatable,
# and pip-generated console scripts embed the creation path in their
# shebangs (a /tmp staging path would ship broken #! lines — lintian caught
# exactly that). The tar stream on stdout is cached under $VENV_CACHE_DIR
# with the pinned litert-lm version in the filename, and every use
# revalidates the version from the venv's dist-info (below), so a version
# bump cannot silently reuse a stale cache. Diagnostics go to stderr.
if [ -z "${VENV_TARBALL:-}" ]; then
  VENV_TARBALL=$VENV_CACHE
fi
if [ ! -f "$VENV_TARBALL" ]; then
  [ -n "$VENV_HOST" ] || die "VENV_HOST is required for venv staging (set it to a reachable Debian 13 amd64 host, e.g. user@host), or provide VENV_TARBALL"
  log "No venv tarball at $VENV_TARBALL; building litert-lm $LITERT_LM_VERSION venv on $VENV_HOST (Debian 13, at /opt/ai-core/venv)"
  mkdir -p "$VENV_CACHE_DIR"
  # Guard opt-in: an existing /opt/ai-core on the staging host may be a live
  # ai-core install, not ours to destroy.
  VENV_OVERWRITE=${VENV_REBUILD_OVERWRITE:-0}
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$VENV_HOST" 'bash -s' \
      > "$WORK/venv.tar" 2> >(tee "$WORK/venv-build.log" >&2) <<EOF
set -euo pipefail
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 missing on the venv build host" >&2; exit 1; }
dpkg -s python3-venv >/dev/null 2>&1 || sudo apt-get install -y -qq python3-venv
if [ -e /opt/ai-core ] && [ "$VENV_OVERWRITE" != "1" ]; then
  echo "ERROR: /opt/ai-core already exists on the venv staging host; refusing to overwrite (set VENV_REBUILD_OVERWRITE=1 to force)" >&2
  exit 1
fi
[ "$VENV_OVERWRITE" = "1" ] && [ -e /opt/ai-core ] && echo "WARNING: overwriting existing /opt/ai-core on the staging host (VENV_REBUILD_OVERWRITE=1)" >&2
sudo rm -rf /opt/ai-core
sudo mkdir -p /opt/ai-core
sudo python3 -m venv /opt/ai-core/venv
sudo /opt/ai-core/venv/bin/pip install -q -i $PIP_MIRROR "litert-lm==$LITERT_LM_VERSION"
sudo /opt/ai-core/venv/bin/litert-lm --version >&2
sudo /opt/ai-core/venv/bin/python -c "import litert_lm; print('venv import ok')" >&2
echo "venv staging: streaming tar" >&2
sudo tar -C /opt/ai-core --numeric-owner --owner=0 --group=0 --sort=name --mtime='2026-01-01 00:00:00 UTC' -cf - venv
sudo rm -rf /opt/ai-core
EOF
  [ -s "$WORK/venv.tar" ] || die "venv staging produced no tar stream (see venv-build.log)"
  xz -T0 -6 < "$WORK/venv.tar" > "$VENV_TARBALL.part"
  mv -f "$VENV_TARBALL.part" "$VENV_TARBALL"
  log "Venv tarball cached: $VENV_TARBALL ($(du -h "$VENV_TARBALL" | cut -f1))"
fi

# ── 1.5 Rebuild-or-skip (staleness detection) ─────────────────
# A cached .deb must never silently ship stale ai-core content: the inputs
# (packaging sources, maintainer scripts, template files, the version, the
# venv tarball hash) are hashed into a stamp next to the artifact. When the
# stamp matches, the build is a no-op (fast); when any input changed or the
# stamp is missing, the package is rebuilt. FORCE_REBUILD=1 overrides.
inputs_hash() {
  {
    sha256sum \
      "$SRC/import-model.sh" "$SRC/engine.sh" "$SRC/ai.sh" \
      "$SRC/AGENTS.md" "$SRC/hax-LICENSE" \
      "$DEBDIR/control.in" "$DEBDIR/conffiles" "$DEBDIR/config.env" \
      "$DEBDIR/build-deb.sh" "$DEBDIR/profile-ai-core.sh" "$DEBDIR/ai-core.service" \
      "$DEBDIR/ai-core-model-import.service" "$DEBDIR/postinst" \
      "$DEBDIR/prerm" "$DEBDIR/postrm" "$DEBDIR/changelog.in" \
      "$DEBDIR/copyright.in" "$DEBDIR/lintian-overrides" \
      "$DEBDIR/gen-third-party-notices.py"
    echo "version: $FULL_VERSION"
    echo "venv: $(sha256sum "$VENV_TARBALL" | cut -d' ' -f1)"
    echo "hax: $HAX_SHA256"
    echo "llama: $LLAMA_SHA256"
  } | sha256sum | cut -d' ' -f1
}
INPUTS=$(inputs_hash)
if [ -z "${FORCE_REBUILD:-}" ] && [ -f "$DEB" ] && [ -f "$DEB.inputs" ] \
   && [ "$(cat "$DEB.inputs")" = "$INPUTS" ]; then
  log "Package is up to date for the current sources (inputs stamp matches); skipping rebuild"
  log "Artifact: $DEB"
  log "Checksum: $(cut -d' ' -f1 "$DEB.sha256")"
  exit 0
fi

# Fresh inputs require the verified official payloads. This stays AFTER the
# no-op check so an up-to-date package never needs network or staging archives.
fetch_verified_archive "${HAX_ARCHIVE:-}" "$HAX_URL" "$HAX_SHA256" "$WORK/downloads/hax.tar.gz"
fetch_verified_archive "${LLAMA_ARCHIVE:-}" "$LLAMA_URL" "$LLAMA_SHA256" "$WORK/downloads/llama.tar.gz"
tar -xzf "$WORK/downloads/hax.tar.gz" -C "$WORK/hax-extract"
tar -xzf "$WORK/downloads/llama.tar.gz" -C "$WORK/llama-extract"
[ -f "$WORK/hax-extract/hax" ] || die "hax archive has no hax binary"
[ -d "$WORK/llama-extract/llama-$LLAMA_VERSION" ] || die "llama archive has no llama-$LLAMA_VERSION directory"

# ── 2. Assemble the data tree (dpkg paths, root-owned) ────────
TREE=$WORK/tree
CTRL=$WORK/ctrl
mkdir -p "$TREE/opt/ai-core" "$TREE/usr/bin" "$TREE/usr/lib/systemd/system" \
         "$TREE/etc/ai-core" "$TREE/etc/profile.d" "$CTRL"

# ai-core payload (single source of truth: packaging/ai-core/)
install -m 755 "$SRC/import-model.sh"    "$TREE/opt/ai-core/import-model.sh"
install -m 755 "$SRC/engine.sh"          "$TREE/opt/ai-core/engine.sh"
install -m 644 "$SRC/AGENTS.md"           "$TREE/opt/ai-core/AGENTS.md"
install -m 755 "$SRC/ai.sh"              "$TREE/usr/bin/ai"
install -m 755 "$WORK/hax-extract/hax"   "$TREE/usr/bin/hax"
cp -a "$WORK/llama-extract/llama-$LLAMA_VERSION" "$TREE/opt/ai-core/llama-$LLAMA_VERSION"

# systemd units (distro location /usr/lib/systemd/system)
install -m 644 "$DEBDIR/ai-core.service"               "$TREE/usr/lib/systemd/system/ai-core.service"
install -m 644 "$DEBDIR/ai-core-model-import.service"  "$TREE/usr/lib/systemd/system/ai-core-model-import.service"

# conffiles
install -m 644 "$DEBDIR/config.env"         "$TREE/etc/ai-core/config.env"
install -m 644 "$DEBDIR/profile-ai-core.sh" "$TREE/etc/profile.d/ai-core.sh"

# package documentation directories (filled after the venv is in the tree:
# the copyright embeds the third-party license texts of the bundled wheels)
mkdir -p "$TREE/usr/share/doc/$PKG" "$TREE/usr/share/lintian/overrides"
install -m 644 "$SRC/hax-LICENSE" "$TREE/usr/share/doc/$PKG/hax.LICENSE"
install -m 644 "$DEBDIR/lintian-overrides" "$TREE/usr/share/lintian/overrides/$PKG"

# Execute the exact staged binaries before packaging: a wrong architecture,
# missing shared library, or stale staging archive fails the build here.
"$TREE/usr/bin/hax" --version | grep -q "$HAX_VERSION" \
  || die "staged hax does not report version $HAX_VERSION"
LD_LIBRARY_PATH="$TREE/opt/ai-core/llama-$LLAMA_VERSION" \
  "$TREE/opt/ai-core/llama-$LLAMA_VERSION/llama-server" --version 2>&1 \
  | grep -q 'build 12669,' || die "staged llama-server is not build 12669"
sed -e "s|@VERSION@|$FULL_VERSION|" "$DEBDIR/changelog.in" \
    > "$TREE/usr/share/doc/$PKG/changelog.Debian"
grep -q '@[A-Z_]*@' "$TREE/usr/share/doc/$PKG/changelog.Debian" \
  && die "Unrendered placeholder remains in the changelog"
gzip -9n < "$TREE/usr/share/doc/$PKG/changelog.Debian" \
    > "$TREE/usr/share/doc/$PKG/changelog.Debian.gz"
rm -f "$TREE/usr/share/doc/$PKG/changelog.Debian"

# the prebuilt venv
mkdir -p "$TREE/opt/ai-core/venv"
xz -dc "$VENV_TARBALL" | tar -x --numeric-owner --strip-components=1 -C "$TREE/opt/ai-core/venv"
[ -x "$TREE/opt/ai-core/venv/bin/litert-lm" ] || die "staged venv is broken (no venv/bin/litert-lm)"

# Cache validation: the venv must carry exactly the pinned litert-lm
# version. This runs on EVERY build (cached tarball included), so a stale
# cache after bumping LITERT_LM_VERSION fails the build loudly.
DIST_INFO=$(find "$TREE/opt/ai-core/venv" -maxdepth 4 -type d -name 'litert_lm-*.dist-info' -printf '%f\n' | sort -u)
[ "$DIST_INFO" = "litert_lm-$LITERT_LM_VERSION.dist-info" ] \
  || die "staged venv does not match the pinned litert-lm version: expected litert_lm-$LITERT_LM_VERSION.dist-info, found: ${DIST_INFO:-none}"

# Relocation guard (real check, replaces the old staging-marker grep):
# venv console scripts and activate scripts embed absolute paths — every
# embedded venv path must be the final install path /opt/ai-core/venv.
BAD_INTERPRETERS=$(grep -h '^#!' "$TREE"/opt/ai-core/venv/bin/* 2>/dev/null | sort -u \
  | grep -vE "^#!/opt/ai-core/venv/bin/[^[:space:]]+$" \
  | grep -vE "^#!/(usr/bin/env [^[:space:]]+|bin/(ba)?sh)$" || true)
[ -z "$BAD_INTERPRETERS" ] \
  || die "venv scripts embed interpreters outside the installed venv: $BAD_INTERPRETERS"
BAD_VIRTUAL_ENV=$(grep -h '^VIRTUAL_ENV=' "$TREE"/opt/ai-core/venv/bin/activate* 2>/dev/null | sort -u \
  | grep -v '^VIRTUAL_ENV="/opt/ai-core/venv"$' || true)
[ -z "$BAD_VIRTUAL_ENV" ] \
  || die "venv activate scripts embed a non-final VIRTUAL_ENV path: $BAD_VIRTUAL_ENV"

# venv hygiene for the package: no bytecode (postinst byte-compiles — also
# avoids stale .pyc after mtime normalization), no venv control file
find "$TREE/opt/ai-core/venv" -type d -name __pycache__ -prune -exec rm -rf {} +
rm -f "$TREE/opt/ai-core/venv/.gitignore"

# Normalize modes (pip leaves group-writable files): dirs 755; files 755 if
# they carry any execute bit (scripts), 644 otherwise.
find "$TREE" -type d -exec chmod 755 {} +
find "$TREE" -type f -perm /111 -exec chmod 755 {} +
find "$TREE" -type f ! -perm /111 -exec chmod 644 {} +

# ── 2.5 Copyright: our stanzas + the bundled wheels' license texts ──
# The package redistributes prebuilt PyPI wheels, so their licenses must
# ship with it (review finding: a flat MIT-only notice is not enough).
# The generated stanzas replace the @THIRD_PARTY@ marker in the template;
# first-match-wins puts the catch-all MIT stanza last.
python3 "$DEBDIR/gen-third-party-notices.py" "$TREE/opt/ai-core/venv" > "$WORK/third-party.txt" \
  || die "third-party license generation failed"
[ -s "$WORK/third-party.txt" ] || die "third-party license generation produced no output"
awk -v third="$WORK/third-party.txt" '
  /^@THIRD_PARTY@$/ { while ((getline line < third) > 0) print line; next }
  { print }
' "$DEBDIR/copyright.in" > "$TREE/usr/share/doc/$PKG/copyright"
grep -q '@[A-Z_]*@' "$TREE/usr/share/doc/$PKG/copyright" \
  && die "Unrendered placeholder remains in the copyright file"

# ── 3. Control tree ───────────────────────────────────────────
INSTALLED_SIZE=$(du -sk "$TREE" | cut -f1)
# Debian control files have no comment syntax (dpkg's RFC822 parser rejects
# '#' lines), so the control.in header comments are documentation only and
# are stripped at render time.
sed -e "s|@VERSION@|$FULL_VERSION|" \
    -e "s|@INSTALLED_SIZE@|$INSTALLED_SIZE|" \
    "$DEBDIR/control.in" | grep -v '^#' > "$CTRL/control"
grep -q '@[A-Z_]*@' "$CTRL/control" && die "Unrendered placeholder remains in control"
install -m 644 "$DEBDIR/conffiles" "$CTRL/conffiles"
install -m 755 "$DEBDIR/postinst"  "$CTRL/postinst"
install -m 755 "$DEBDIR/prerm"     "$CTRL/prerm"
install -m 755 "$DEBDIR/postrm"    "$CTRL/postrm"

# md5sums for the shipped non-conffile files (dpkg -V support). Conffiles are
# tracked by dpkg separately and are NOT listed, matching dpkg-deb's output.
CONFFILES=" $(sed 's|^/|./|; s|$| |' "$CTRL/conffiles" | tr -d '\n') "
(cd "$TREE" && find . -type f | LC_ALL=C sort) | while IFS= read -r f; do
  case "$CONFFILES" in *" $f "*) continue ;; esac
  (cd "$TREE" && md5sum "$f") | sed 's|  \./|  |'
done > "$CTRL/md5sums"
[ -s "$CTRL/md5sums" ] || die "md5sums generation failed"

# ── 4. Assemble the .deb (ar: debian-binary, control.tar.gz, data.tar.xz) ──
# Deterministic tar flags (sorted names, root:root, fixed mtime) keep rebuilds
# stable; the .sha256 sidecar pins the exact artifact.
TAR_FLAGS=(--sort=name --numeric-owner --owner=0 --group=0 --format=gnu
           --mtime='2026-01-01 00:00:00 UTC')

tar "${TAR_FLAGS[@]}" -C "$CTRL" -cf - . | gzip -9n > "$WORK/control.tar.gz"
tar "${TAR_FLAGS[@]}" -C "$TREE" -cf - . | xz -T0 -6 > "$WORK/data.tar.xz"
printf '2.0\n' > "$WORK/debian-binary"

mkdir -p "$OUT"
rm -f "$DEB" "$DEB.sha256"
(cd "$WORK" && ar rcD "${DEB}" debian-binary control.tar.gz data.tar.xz)
log "Assembled $DEB"

checksum=$(sha256sum "$DEB")
checksum=${checksum%% *}
printf '%s  %s\n' "$checksum" "$(basename "$DEB")" > "$DEB.sha256"
printf '%s\n' "$INPUTS" > "$DEB.inputs"

log ""
log "Package:    $PKG $FULL_VERSION (amd64)"
log "Data size:  $(du -h "$WORK/data.tar.xz" | cut -f1) compressed / ${INSTALLED_SIZE} KiB installed"
log "Artifact:   $DEB"
log "Checksum:   $checksum"
log "Validation: install in a clean Debian 13 chroot (enablement, entry points,"
log "            idempotent reinstall, apt upgrade, clean removal)"
