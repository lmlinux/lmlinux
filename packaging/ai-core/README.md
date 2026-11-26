# packaging/ai-core — local inference and hax assistant

This directory is the source of truth for the `lmlinux-ai-core` payload.
`install.sh` is the manual installer; `packaging/ai-core-deb/build-deb.sh`
packages the same entry points, import logic, engine selection, and systemd
units for the live image. Keep duplicated unit content synchronized.

## Package and live-image defaults

The package and manual installer default to Qwen3.5-4B. The live-image
builder defaults to Qwen3.5-9B and, after installing the package, pins the
selected model's path, hash, and alias in both `config.env` and the hax
configuration seed.

- **Engine:** official llama.cpp **b12669** Ubuntu x64 prebuilt binaries,
  pinned to sha256 `67d4bb52a775aa00a77895c07af4d95fc28b7b51c1e4dd04ecf6af21d08138a4`.
  The official shared-library layout is preserved under
  `/opt/ai-core/llama-b12669/`, and `engine.sh` sets `LD_LIBRARY_PATH` there.
- **Package model default:** unsloth **Qwen3.5-4B Q4_K_M GGUF**, pinned to
  sha256 `00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4`.
- **Live-image model default:** unsloth **Qwen3.5-9B Q4_K_M GGUF**, pinned to
  sha256 `03b74727a860a56338e042c4420bb3f04b2fec5734175f4cb9fa853daf52b7e8`.
  The builder accepts `MODEL_PATH` or `MODEL_URL` and verifies the selected
  model before adding it to the image. Models are build/import inputs, never
  repository assets.
- **Harness:** official **hax 0.7.0**, pinned to sha256
  `970183b80f1e7e8d2d4f8d9905234f415deb21cc80f111fbb5cc85bb9575fa3e`.
  hax is installed by default and is the only shipped harness. Its upstream
  license is **MIT**, which permits ISO redistribution with the included
  copyright and permission notice (`hax-LICENSE`).
- **Prompt:** hax uses its built-in prompt plus the tuned English skill text
  installed as `/opt/ai-core/AGENTS.md`. The text requires batched read-only
  collection and explicit approval before writes. Offline diagnosis runs hax
  from `/opt/ai-core`, which loads this file automatically.

With the package defaults, the service command is equivalent to:

```bash
llama-server -m /opt/ai-core/models/Qwen3.5-4B-Q4_K_M.gguf \
  --host 127.0.0.1 --port 21718 --alias qwen3.5-4b -c 16384 --jinja
```

`--jinja` is required for tool calling. The live builder changes the model
path and alias to its 9B defaults. In the released 9B image, llama-server
used about 8.7 GiB RSS in the reference setup; actual use depends on the
selected model, machine, and workload.

## Entry point and sessions

Run `ai` to start hax with its native `llama.cpp` provider. `ai -c` resumes
the previous session. hax saves interrupted sessions, so
Ctrl+C does not discard the conversation. The `HARNESS=` configuration switch
and unavailable-harness error remain as future wiring, although no alternate
harness is shipped.

## Engine switch

The package-default `/etc/ai-core/config.env` contains:

```bash
ENGINE=llama-server
HARNESS=hax
AI_CORE_PORT=21718
MODEL_PATH=/opt/ai-core/models/Qwen3.5-4B-Q4_K_M.gguf
MODEL_SHA256=00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4
MODEL_ALIAS=qwen3.5-4b
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
skips model download, service startup, and smoke checks. The live-image builder
places the verified GGUF directly at the configured `MODEL_PATH`.

## Memory control

The inference service keeps the model resident. Stop it with
`sudo systemctl stop ai-core`, restart it with `sudo systemctl start ai-core`,
or prevent boot startup with `sudo systemctl disable --now ai-core`.
