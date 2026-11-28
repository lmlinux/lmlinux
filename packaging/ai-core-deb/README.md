# packaging/ai-core-deb — the lmlinux-ai-core Debian package

`lmlinux-ai-core` packages the ai-core file set as a real `.deb` for the live
image and standalone installations. The package defaults are official
llama-server b12669 + Qwen3.5-9B GGUF + hax 0.7.0, matching the sole active
model flavor. The live-image builder still explicitly pins the model path,
hash, alias, and hax seed for the distribution image. LiteRT-LM 0.19.2 remains
bundled as the non-default Gemma-flavor engine.

## Build

```bash
packaging/ai-core-deb/build-deb.sh
```

Output: `build/debian/out/lmlinux-ai-core_<version>-<rev>_amd64.deb` plus a
`.sha256` sidecar. Environment: `OUT_DIR` (shippable debs; test-only revisions
must go elsewhere), `DEB_VERSION` (default 0.2.0), `DEB_REVISION` (default 7),
`VENV_TARBALL`, `VENV_CACHE_DIR`, `VENV_HOST`, `PIP_MIRROR`,
`VENV_REBUILD_OVERWRITE=1`, and `FORCE_REBUILD=1`.

`HAX_ARCHIVE` and `LLAMA_ARCHIVE` can point at locally staged official release
archives. Without them the builder downloads from the upstream GitHub releases.
Both paths enforce the same pinned sha256 values; the staged binaries are also
executed for version and shared-library checks before packaging.

The build is staleness-checked: an inputs hash (packaging sources, maintainer
scripts, templates, versions, and all payload hashes) is stamped next to the
artifact (`<deb>.inputs`). A matching stamp makes the build a no-op; any input
change rebuilds it, so ISO and chroot tests cannot silently use a stale package.

The venv cache is version-stamped
(`ai-core-venv-litert-lm-<version>.tar.xz`) and revalidated from the venv's
dist-info on every build. When the cache is absent, `VENV_HOST` is required:
the builder SSHes to that Debian 13 amd64 machine and builds at
`/opt/ai-core/venv` there. That staging step removes `/opt/ai-core` on the
host; it refuses an existing path unless `VENV_REBUILD_OVERWRITE=1` is
explicitly set.

## Why a handcrafted .deb (tar+ar), not dpkg-buildpackage/debhelper

- The package ships scripts, conffiles, systemd units, official prebuilt
  binaries, and a prebuilt venv; there is no source to compile.
- The package build does not require `dpkg-buildpackage` or debhelper. A
  `.deb` is an `ar` archive (`debian-binary`, `control.tar.gz`,
  `data.tar.xz`); dpkg/apt support it fully.
- The venv must be built on Debian 13 (Python 3.13, amd64, final path
  `/opt/ai-core/venv`) because venv console scripts are not relocatable.

## Contents

| Path | Origin | Notes |
|---|---|---|
| `/opt/ai-core/llama-b12669/` | official ggml-org/llama.cpp b12669 Ubuntu x64 release | default engine; binaries, shared libraries, symlinks, and MIT license retain the official layout |
| `/usr/bin/hax` | official hax v0.7.0 release | sole shipped harness; pinned sha256, MIT |
| `/opt/ai-core/venv/` | staged from Debian 13 | optional LiteRT-LM 0.19.2 engine |
| `/opt/ai-core/{engine.sh,import-model.sh}` | `packaging/ai-core/` | engine selection and verified GGUF/LiteRT model import |
| `/opt/ai-core/AGENTS.md` | `packaging/ai-core/AGENTS.md` | tuned English hax skill text; batched read-only collection and explicit write approval |
| `/usr/bin/ai` | `packaging/ai-core/ai.sh` | unified entry point; hax default, `HARNESS=` switch retained |
| `/usr/lib/systemd/system/ai-core.service`, `ai-core-model-import.service` | unit files here | same content `install.sh` generates (keep in sync) |
| `/etc/ai-core/config.env`, `/etc/profile.d/ai-core.sh` | `config.env`, `profile-ai-core.sh` | conffiles; default `ENGINE=llama-server`, `HARNESS=hax`, port 21718 |
| `/usr/share/doc/lmlinux-ai-core/{copyright,hax.LICENSE,changelog.Debian.gz}` | upstream notices, `copyright.in`, `changelog.in` | includes generated licenses for bundled venv wheels |
| `/usr/share/lintian/overrides/lmlinux-ai-core` | `lintian-overrides` | documented deviations |

Not shipped: the model (placed in `/opt/ai-core/models/` by the live-image
builder or imported by `ai-core-model-import.service`) and
`packaging/ai-core/install.sh` itself. `/root/.litert-lm/config.json` is created
by `postinst` only when absent for the optional Gemma flavor.

hax combines its built-in prompt with the tuned skill text installed at
`/opt/ai-core/AGENTS.md`. The assistant runs hax from that directory, so the
file is loaded automatically.

## Maintainer-script behavior

- `postinst configure`: create the LiteRT-LM context config if absent;
  byte-compile the bundled venv; enable `ai-core.service`; on a live system,
  reload units and restart only an already-active service.
- `prerm remove|deconfigure`: stop an active service before files vanish.
- `postrm remove`: drop boot enablement.
- `postrm purge`: remove enablement state and both model locations.

Dependencies: `python3 (>= 3.13~), python3 (<< 3.14~), mount`, plus the
llama.cpp runtime closure `libc6 (>= 2.34), libgcc-s1, libgomp1 (>= 6),
libssl3t64 (>= 3.0.0), libstdc++6 (>= 12)`. The Python bounds keep the optional
venv interpreter in lockstep with Debian 13. `libssl3t64` is the actual Debian
13 package shipping both `libssl.so.3` and `libcrypto.so.3` (it Provides
`libssl3`; there is no separate `libcrypto3` package). The symbol-version
rationale for every bound is documented beside `Depends:` in `control.in`.

## Validation

The build verifies the pinned upstream archives and executes the staged hax
and llama-server binaries before packaging. For runtime validation, install
the package in a clean Debian 13 environment and check file/unit/entry-point
installation, service enablement, actual llama-server startup, idempotent
reinstall, conffile-preserving upgrade, removal/purge, and lintian. The live
builder additionally executes llama-server inside the target rootfs and
checks the installed entry points, service, model, and configuration.

Runtime checks are separate from local archive inspection and shell syntax
checks; do not claim them without an actual run.
