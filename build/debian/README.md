# build/debian — live ISO builder

`build-live-iso.sh` rebuilds the official Debian 13.8.0 live Cinnamon ISO
with the lmlinux AI stack and a verified model baked into the live
filesystem. The finished image boots into Cinnamon with the assistant
available offline. Its standard Debian installer copies the complete system,
including the AI stack and model, to disk without network access. The boot
menus, kernel, initrd, and installer flow remain the stock Debian live ones.

## Prerequisites

Run the builder as root on an amd64 build host with:

- `xorriso` and `squashfs-tools` (`unsquashfs` and `mksquashfs`);
- `curl`, `ar`, `xz`, `ssh`, Python 3, tar, and the usual GNU core utilities;
- enough free space in `OUT_DIR` for the source ISO, package cache, unpacked
  rootfs, rebuilt squashfs, and output ISO;
- a model source and its pinned SHA-256 for a real-model build.

Unless `AI_CORE_DEB` supplies a prebuilt package, the script invokes
`packaging/ai-core-deb/build-deb.sh`. That package builder embeds a prebuilt
LiteRT-LM venv. Because venvs are not relocatable, the venv must be created at
`/opt/ai-core/venv` on a Debian 13 amd64 host with Python 3.13. Provide either:

- `VENV_TARBALL`: an existing compatible venv tarball; or
- `VENV_HOST`: an SSH destination such as `user@host` where the builder can
  stage the venv. This is required when no cached tarball exists.
  Virtualization is not required; a `debian:13` container host is sufficient.

Staging removes `/opt/ai-core` on `VENV_HOST`. It refuses to overwrite an
existing path unless `VENV_REBUILD_OVERWRITE=1` is explicitly set.

Downloads use `curl`, which honors the standard `http_proxy` and
`https_proxy` environment variables. If the default Debian mirror is
unreachable, configure those variables or set `LIVE_URL` to another mirror
while retaining the correct `LIVE_SHA256`.

## Model contract

The live builder defaults to **Qwen3.5-9B Q4_K_M**, even though the standalone
package and manual installer retain their Qwen3.5-4B package defaults:

```text
MODEL_FILE=Qwen3.5-9B-Q4_K_M.gguf
MODEL_ALIAS=qwen3.5-9b
MODEL_SHA256=03b74727a860a56338e042c4420bb3f04b2fec5734175f4cb9fa853daf52b7e8
```

Provide a model source:

- `MODEL_PATH`: a local model file; or
- `MODEL_URL`: an HTTPS URL downloaded into the output cache.

`MODEL_SHA256` is mandatory with either source and is checked before the
model enters the image. If both sources are set, `MODEL_PATH` wins. Model
weights are build inputs and are not repository assets.

Without either source, the builder creates a 9 MiB random dummy model for
pipeline smoke builds only. A dummy image cannot serve the model and must not
be distributed. Set `MODEL_FILE`, `MODEL_ALIAS`, and `MODEL_SHA256` together
when selecting another real model. `ISO_NAME` must contain `MODEL_ALIAS`
(case-insensitive); include the quantization in the name as well.

## Build examples

From a local model file:

```bash
MODEL_PATH=<path-to>/Qwen3.5-9B-Q4_K_M.gguf \
MODEL_FILE=Qwen3.5-9B-Q4_K_M.gguf \
MODEL_ALIAS=qwen3.5-9b \
MODEL_SHA256=03b74727a860a56338e042c4420bb3f04b2fec5734175f4cb9fa853daf52b7e8 \
ISO_NAME=lmlinux-debian-13.8.0-amd64-cinnamon-live-qwen3.5-9b-q4_k_m-20261125 \
  build/debian/build-live-iso.sh
```

Or download the pinned model from Hugging Face into the build cache:

```bash
MODEL_URL=https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-Q4_K_M.gguf \
MODEL_FILE=Qwen3.5-9B-Q4_K_M.gguf \
MODEL_ALIAS=qwen3.5-9b \
MODEL_SHA256=03b74727a860a56338e042c4420bb3f04b2fec5734175f4cb9fa853daf52b7e8 \
ISO_NAME=lmlinux-debian-13.8.0-amd64-cinnamon-live-qwen3.5-9b-q4_k_m-20261125 \
  build/debian/build-live-iso.sh
```

## Environment overrides

| Variable | Default / purpose |
|---|---|
| `OUT_DIR` | `build/debian/out`; inputs, caches, work trees, and outputs |
| `LIVE_URL` | USTC URL for `debian-live-13.8.0-amd64-cinnamon.iso` |
| `LIVE_SHA256` | `eea22158e45dd7e0fba13bca5ebbcedd0014086464c1e3ae602ec73ae2932be7` |
| `MODEL_PATH`, `MODEL_URL` | Local or downloaded model source; unset by default |
| `MODEL_SHA256` | Required expected hash for either real-model source |
| `MODEL_FILE` | `Qwen3.5-9B-Q4_K_M.gguf` |
| `MODEL_ALIAS` | `qwen3.5-9b` |
| `ISO_NAME` | `lmlinux-debian-13.8.0-amd64-cinnamon-live-${MODEL_ALIAS}`; must contain the alias |
| `DUMMY_MODEL_SIZE` | `9437184` bytes; dummy-model path only |
| `AI_CORE_DEB` | Optional package to embed; otherwise the package builder runs and the newest output package is selected |
| `BUILD_PROCESSORS` | `16`; CPU limit for squashfs extraction and creation |
| `KEEP_WORK` | `0`; set to `1` to retain the temporary work tree for diagnosis |

The invoked package builder also accepts `VENV_CACHE_DIR`, `PIP_MIRROR`,
`DEB_VERSION`, `DEB_REVISION`, `FORCE_REBUILD=1`, `HAX_ARCHIVE`, and
`LLAMA_ARCHIVE`. See `packaging/ai-core-deb/README.md` for package details.
`VENV_TARBALL` and `VENV_CACHE_DIR` default to the version-stamped cache under
`build/debian/out` unless overridden.

## Build and verification flow

The script:

1. downloads the pinned Debian live ISO if needed and verifies its SHA-256;
2. builds or accepts the ai-core `.deb`, records its SHA-256, and checks the
   model hash before image assembly;
3. extracts and unpacks `/live/filesystem.squashfs`;
4. installs the package in the offline chroot, places the model under
   `/opt/ai-core/models/`, and pins `MODEL_PATH`, `MODEL_SHA256`, and
   `MODEL_ALIAS` in `config.env` and the hax seed;
5. executes llama-server in the target rootfs and checks the `ai` and `hax`
   entry points, service enablement, model, and configuration;
6. re-squashes the rootfs with zstd and the original block size, then checks
   that all required payload paths are present;
7. rebuilds the ISO in one xorriso session with `-boot_image any replay`;
8. verifies MBR invariants, El Torito properties and options, BIOS/UEFI boot
   images, partition geometry, and large-image LBA coverage when applicable;
9. extracts the rebuilt squashfs and compares it byte-for-byte with the
   staged squashfs; and
10. atomically publishes the ISO and its whole-image SHA-256 sidecar.

Zstd replaces the source image's xz compression to reduce decompression cost
during live boot and installation on offline media. The model is already
incompressible and is stored as cheap uncompressed blocks under either
compressor.

## Outputs

The distribution outputs are:

```text
build/debian/out/<ISO_NAME>.iso
build/debian/out/<ISO_NAME>.iso.sha256
```

Verify an output from the output directory with:

```bash
sha256sum -c <ISO_NAME>.iso.sha256
stat -c '%s bytes' <ISO_NAME>.iso
```

Package-building intermediates include
`lmlinux-ai-core_<version>-<revision>_amd64.deb`, its `.sha256` and `.inputs`
sidecars, and the version-stamped venv tarball cache. They are build inputs,
not model-weight redistribution.
