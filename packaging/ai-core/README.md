# packaging/ai-core — local inference and hax assistant

This directory is the source of truth for the `lmlinux-ai-core` payload.
`install.sh` is the manual installer; `packaging/ai-core-deb/build-deb.sh`
packages the same entry points, import logic, engine selection, and systemd
units for the live image. Keep duplicated unit content synchronized.

## Default stack

The package and standalone installer default to **Qwen3.5-9B**, the sole active
model flavor. The distribution live-image builder still explicitly pins the
model path, hash, alias, and hax seed for every image. The parked 4B flavor
remains reachable through explicit builder configuration or manual config
edits; generic build support is unchanged.

- **Engine:** official llama.cpp **b12669** Ubuntu x64 prebuilt binaries,
  pinned to sha256 `67d4bb52a775aa00a77895c07af4d95fc28b7b51c1e4dd04ecf6af21d08138a4`.
  The official shared-library layout is preserved under
  `/opt/ai-core/llama-b12669/`, and `engine.sh` sets `LD_LIBRARY_PATH` there.
- **Model:** unsloth **Qwen3.5-9B Q4_K_M GGUF**, 5,680,522,464 bytes
  (5.29 GiB), pinned to sha256
  `03b74727a860a56338e042c4420bb3f04b2fec5734175f4cb9fa853daf52b7e8`.
  It is a build/import input, never a repository asset.
- **Harness:** official **hax 0.7.0**, pinned to sha256
  `970183b80f1e7e8d2d4f8d9905234f415deb21cc80f111fbb5cc85bb9575fa3e`.
  hax is installed by default and is the only shipped harness. Its upstream
  license is **MIT**, which permits ISO redistribution with the included
  copyright and permission notice (`hax-LICENSE`).
- **Prompt:** hax uses its built-in prompt plus the tuned English skill text
  installed as `/opt/ai-core/AGENTS.md`. The text requires batched read-only
  collection and explicit approval before writes. Offline diagnosis runs hax
  from `/opt/ai-core`, which loads this file automatically.

The default service command is equivalent to:

```bash
llama-server -m /opt/ai-core/models/Qwen3.5-9B-Q4_K_M.gguf \
  --host 127.0.0.1 --port 21718 --alias qwen3.5-9b -c 16384 --jinja
```

`--jinja` is required for tool calling. The llama-server process uses about
8.7 GiB RSS in the validated 9B reference setup; actual use depends on the
machine and workload. Plan for **16 GiB of RAM**.

## Entry point and sessions

Run `ai` to start hax with its native `llama.cpp` provider. `ai -c` (equivalent
to `hax -c`) resumes the previous session. hax saves interrupted sessions, so
Ctrl+C does not discard the conversation. The `HARNESS=` configuration switch
and unavailable-harness error remain as future wiring, although no alternate
harness is shipped.

## Engine switch

`/etc/ai-core/config.env` contains:

```bash
ENGINE=llama-server
HARNESS=hax
AI_CORE_PORT=21718
MODEL_PATH=/opt/ai-core/models/Qwen3.5-9B-Q4_K_M.gguf
MODEL_SHA256=03b74727a860a56338e042c4420bb3f04b2fec5734175f4cb9fa853daf52b7e8
MODEL_ALIAS=qwen3.5-9b
```

After edits, run `sudo systemctl restart ai-core` and start a new shell (or
`source /etc/profile.d/ai-core.sh`). The `ai` launcher reads the same file, so
the service and hax endpoint cannot drift.

The **non-default Gemma flavor** retains the LiteRT-LM 0.19.2 engine path:
set `ENGINE=litert-lm`, use port 21717, and import the pinned
`gemma-4-E4B-it.litertlm` model. `install.sh` accepts `ENGINE=litert-lm` to
install that flavor, including its venv and 16384-token context config. For
this path hax uses the OpenAI-compatible provider; the default llama-server
path deliberately uses hax's native llama.cpp provider instead.

## Model import

`import-model.sh` accepts `AI_CORE_MODEL_SOURCE` as a regular file, raw block
device, or `media` (scan optical/removable filesystems). GGUF imports:

1. copy into a temporary file beside `MODEL_PATH` using direct I/O where
   supported, with cache-evicted and buffered fallbacks;
2. verify the written file against the pinned sha256;
3. atomically rename it into place;
4. register `MODEL_PATH` and `MODEL_SHA256` in `/etc/ai-core/config.env`.

An already-present matching GGUF is verified and left untouched. A mismatched
GGUF with no replacement source fails rather than letting the service load an
untrusted model. The LiteRT-LM media/registry import remains unchanged in
purpose for the Gemma flavor.

With `AI_CORE_IMAGE_BUILD=1`, `install.sh` installs files and enables units but
skips automatic model download, service startup, and smoke checks. For the
llama-server flavor, an explicitly supplied `AI_CORE_MODEL_SOURCE` is still
imported and verified. Without a local source, model import is deferred and the
live-image builder places the verified GGUF directly at the configured
`MODEL_PATH`.

## Offline USB installation on Debian 13

The `packaging/ai-core/` directory is self-contained. Copy it to a USB stick as
`ai-core/`, then stage these three pinned payloads beside it (the example paths
below assume the stick is mounted at `/media/usb`):

- **hax 0.7.0**, saved as `hax-0.7.0-linux-x86_64.tar.gz`:
  `https://github.com/OleksandrChekhovskyi/hax/releases/download/v0.7.0/hax-0.7.0-linux-x86_64.tar.gz`
  with sha256 `970183b80f1e7e8d2d4f8d9905234f415deb21cc80f111fbb5cc85bb9575fa3e`.
- **llama.cpp b12669**, saved as `llama-b12669-bin-ubuntu-x64.tar.gz`:
  `https://github.com/ggml-org/llama.cpp/releases/download/b12669/llama-b12669-bin-ubuntu-x64.tar.gz`
  with sha256 `67d4bb52a775aa00a77895c07af4d95fc28b7b51c1e4dd04ecf6af21d08138a4`.
- **Qwen3.5-9B Q4_K_M GGUF**, saved as `Qwen3.5-9B-Q4_K_M.gguf` (5.29 GiB):
  `https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-Q4_K_M.gguf`
  with sha256 `03b74727a860a56338e042c4420bb3f04b2fec5734175f4cb9fa853daf52b7e8`.

Run `sha256sum` on all three staged files and compare them with these values
before carrying the stick to the target. The target must be **Debian 13 amd64**
with systemd, **16 GiB RAM**, and approximately **6 GiB of free disk space**
for the imported model and binaries. `curl` must either already be installed or
be installable from a configured local APT source or Debian installation media;
the installer makes no package-manager call when it is already present.

Run the installer with the three staged payloads:

```bash
sudo env HAX_ARCHIVE=/media/usb/hax-0.7.0-linux-x86_64.tar.gz \
         LLAMA_ARCHIVE=/media/usb/llama-b12669-bin-ubuntu-x64.tar.gz \
         AI_CORE_MODEL_SOURCE=/media/usb/Qwen3.5-9B-Q4_K_M.gguf \
         bash /media/usb/ai-core/install.sh
```

`sudo env` passes the three named settings explicitly; it does not depend on
preserving the caller's whole environment. With all payloads staged, binary
installation, model import, and the loopback smoke check require no external
network. `AI_CORE_MODEL_SOURCE` may instead name a raw block device or be set to
`media` to scan optical/removable filesystems. Without staged payloads or
already installed/verified components, the corresponding downloads require
network access.

## Memory control

The inference service keeps the model resident. Stop it with
`sudo systemctl stop ai-core`, restart it with `sudo systemctl start ai-core`,
or prevent boot startup with `sudo systemctl disable --now ai-core`.
