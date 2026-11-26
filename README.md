# lmlinux

**A Debian-based, AI-native Linux distribution — Linux with a local language model built in.**

[English](#english) · [中文](#中文)

---

## English

### What it is

lmlinux integrates a local language model into Debian 13. The system —
live session or installed — is an ordinary, fully writable Debian — `apt`
works and persists — with the AI stack preinstalled as regular packages.

It is built for **two situations where a cloud assistant cannot be relied
on**:

1. **Offline rescue**: investigate and help repair an existing system from
   the live or installed environment when internet access is unavailable —
   including configuration, package-source, mount, and service problems.
2. **First installation and first boot without a network**: get help with
   initial network, APT-source, mount, and service configuration and
   troubleshoot setup problems before the machine is online.

The assistant works locally in both scenarios; administrative changes still
require your explicit authorization through `sudo ai`.

### Component responsibilities

- **llama-server — local inference:** runs as a systemd service and serves
  Qwen3.5-9B at `127.0.0.1:21718`, fully offline, through an OpenAI-compatible
  API with tool calling.
- **hax — assistant interaction and sessions:** handles installation and
  rescue configuration problems (network, mounts, APT sources, and services)
  through its native llama.cpp provider. Sessions survive Ctrl+C and can be
  resumed with their prior context.
- **Model files — build-time payload:** the model is pinned by SHA-256 and
  baked into the live image at build time; the Git repository never carries
  model weights.

### Current status and validation

- **Release:** `13.8.0-rc1` carries the Qwen3.5-9B, hax, and llama-server
  stack. This is a release candidate, not the `latest` stable release.
- **Checks passed:** this exact image passed build-integrity checks, an
  independent artifact review, offline live-boot and install-to-disk probes,
  and offline installed-system cold-start, warm-follow-up, and bare-hax
  probes.
- **Successful APT-source repairs:**
  1. **Controlled single-fault test:** the assistant received only a
     natural-language request, with no repair commands, and replaced a broken
     cdrom-only APT source with official Debian 13 repositories in 16m15s.
     `apt-get update` succeeded, and independent update and package-resolution
     checks passed.
  2. **Final installation test:** the user observed another APT-source repair
     complete in about 8 minutes.
- **Intentional multi-fault stress test:** between those successes, a separate
  test deliberately chained multiple faults to explore the 9B model's limits
  without human intervention during the attempt. It was not a repeat of the
  single-fault repair and did not finish after about 66 minutes. It changed
  APT sources to HTTP entries marked `[trusted=yes]`, altered
  resolver/NetworkManager state, and pursued `dummy0`/veth recovery without
  installing the rescue fixture. Expect long waits and review every proposed
  privileged change.
- **Display observations:**
  - An installed boot left a tty1 login prompt in the foreground while
    LightDM/Cinnamon was starting on VT7; Ctrl+Alt+F7 exposed the desktop.
  - Logs from a later reinstallation show LightDM requesting VT7 activation
    about 17 and 39 seconds after boot, but the original observation did not
    continuously record foreground-VT state.
  - A completely fresh, no-keyboard-input installation reached the GUI
    automatically in nearly two minutes on the test VM.
  - A separate initial HDD boot had an unreproduced
    black-screen/unresponsive-VT transient requiring a hard reset; subsequent
    final probes passed.
- **Validation boundary:** the successful repairs and incomplete stress test
  are separate results. None of these checks completes the behavioral,
  complete offline-rescue/first-install, real-user, or external-feedback gates
  required before GA. The execution trust layer below remains a roadmap
  direction, not a current capability.

### Installing

The distribution image is a sha256-pinned Debian 13.8.0 live Cinnamon ISO
with the lmlinux AI stack baked in (several GiB with the real model).

#### Download and verify

1. Pull the image with the [ORAS CLI](https://github.com/oras-project/oras).
   GitHub Releases caps single files at 2 GiB, so this larger image ships as
   an OCI artifact on ghcr:

   ```bash
   oras pull ghcr.io/lmlinux/lmlinux-iso:rc
   ```

2. Verify the downloaded ISO:

   ```bash
   sha256sum lmlinux-debian-13.8.0-amd64-cinnamon-live-qwen3.5-9b-q4_k_m-20261125.iso
   # 2eb28a574c67ce1b9cd6b306162a3f87ca1178ac291e310daa71b2c2bfea7ecd
   ```

   - Exact size: **10,030,678,016 bytes**.
   - The ghcr blob digest is the file's SHA-256, so this hash check completes
     end-to-end verification.
   - Only the literal `rc` OCI tag is published; there is no versioned
     registry tag and no `latest` tag.

#### Write a USB stick and install

1. Write the verified ISO to your USB stick. Replace `/dev/sdX` with the
   **whole USB device**; this command destroys its contents:

   ```bash
   sudo dd if=lmlinux-debian-13.8.0-amd64-cinnamon-live-qwen3.5-9b-q4_k_m-20261125.iso of=/dev/sdX bs=4M conv=fsync status=progress
   ```

2. Boot the USB stick to enter a live Cinnamon desktop where the AI works
   immediately — **no network and no installation needed**.
3. To install to disk, run the installer from the live desktop:
   - It copies the whole system, including AI components and model, to the
     selected disk fully offline.
   - The boot menus and installer are the vanilla Debian live ones; nothing
     is pre-answered for you.
   - Allow **40 GiB or more**. The copy includes the full desktop and 5.29
     GiB model; a 10 GiB disk failed at the install step in testing.

Building from source is equally supported; see [Building](#building).

#### First boot and first prompt

- **Graphical handoff:** on the 16 GiB RAM / 4-vCPU VMware test, a completely
  fresh installed boot with no keyboard input activated the graphical VT at
  about **118 seconds** and started the automatic Cinnamon user session at
  about **177 seconds**.
- **Why the wait happens:** boot-time SHA-256 verification of the existing
  5.29 GiB model ran from about 36 to 180 seconds, overlapping graphics
  initialization. llama-server loaded the model afterward, from about 183 to
  212 seconds, so that later model-load window does not explain the preceding
  graphical wait.
- **What to do:** timing varies by hardware, so wait a few minutes before
  assuming a problem. If a tty1 login prompt remains, Ctrl+Alt+F7 selects the
  graphical VT. Do not change the default target or add tty1 autologin to work
  around this transition.
- **Memory requirement:** the 9B model needs **16 GiB of RAM**.
- **First-prompt latency:** the first prompt after boot takes minutes, not
  seconds. It includes model loading and cold evaluation of the assistant's
  roughly 2.4K-token system prompt. On a 4-vCPU 9B test, prompt evaluation
  alone took about **7 minutes**, and the complete first engine turn took
  about 8 minutes. Later turns reuse the KV cache, although tool-driven
  repairs still involve multiple inference rounds.

### Using the assistant

#### Start and resume

- **Start:** open a terminal and run `ai`, the unified offline entry point.
  Use it instead of invoking `hax` directly: `ai` applies the local provider
  configuration and, on a cold boot, waits for the engine to finish verifying
  and loading the model with a short progress line instead of failing. It then
  starts **hax**, the only harness shipped in the image, using its built-in
  prompt.
- **Resume:** run `ai -c` to resume the previous session with its context.
  Interrupted sessions are saved, so Ctrl+C does not force you to start over.
- **Backend wiring:** `HARNESS=` in `/etc/ai-core/config.env` selects the
  backend; the one-line switch remains as wiring for future harnesses.

#### Permissions and secrets

- Use ordinary `ai` for read-only diagnosis.
- For a system-maintenance task where you explicitly authorize administrative
  writes, run `sudo ai` yourself. This gives the assistant and its tools root
  privileges and is not intended for routine questions.
- Enter your password at the operating system's sudo prompt, not in the
  assistant conversation. The model is offline, but hax saves session
  transcripts locally, so any secret pasted into the chat can remain in those
  local files.

#### Manage resident memory

The inference service keeps the model resident in memory (about **8.7 GiB
RSS** in the 9B test; actual use varies). Keep it resident for faster warm
follow-ups, or stop it to free RAM:

```bash
sudo systemctl stop ai-core
```

- **Stopping** unloads the model and releases its weights and KV cache. It
  does not delete the model, hax configuration, or saved sessions, but it does
  interrupt any inference running at that moment. The service stays stopped
  until you restart it or reboot.
- **Restarting** with `sudo systemctl start ai-core` reloads the model; the
  next prompt pays the model-load and cold-prefill cost again.
- **Disabling at boot** is available with `sudo systemctl disable --now
  ai-core`.

### Building

#### Prerequisites

- Run as root with `xorriso` and `squashfs-tools` installed.
- Stage the prebuilt litert-lm venv embedded in the ai-core .deb. Venvs are
  not relocatable, so build it on a Debian 13 amd64 host; no virtualization
  is involved. Choose one staging method:
  - Set `VENV_HOST=user@host`.
  - Run the staging in a `debian:13` container.
  - Point `VENV_TARBALL` at an existing tarball.
- See `build/debian/README.md` for full details.

#### Model input and build

The model is a build input, not a repository asset. Use a local file or fetch
it from Hugging Face; either source is verified against `MODEL_SHA256` before
anything enters the image:

```bash
# from a local file
MODEL_PATH=<path-to>/Qwen3.5-9B-Q4_K_M.gguf \
MODEL_FILE=Qwen3.5-9B-Q4_K_M.gguf \
MODEL_ALIAS=qwen3.5-9b \
MODEL_SHA256=03b74727a860a56338e042c4420bb3f04b2fec5734175f4cb9fa853daf52b7e8 \
ISO_NAME=lmlinux-debian-13.8.0-amd64-cinnamon-live-qwen3.5-9b-q4_k_m \
  build/debian/build-live-iso.sh

# or fetched from Hugging Face into the build cache
MODEL_URL=https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-Q4_K_M.gguf \
MODEL_FILE=Qwen3.5-9B-Q4_K_M.gguf \
MODEL_ALIAS=qwen3.5-9b \
MODEL_SHA256=03b74727a860a56338e042c4420bb3f04b2fec5734175f4cb9fa853daf52b7e8 \
ISO_NAME=lmlinux-debian-13.8.0-amd64-cinnamon-live-qwen3.5-9b-q4_k_m \
  build/debian/build-live-iso.sh
```

#### Output and verification

- `ISO_NAME` must contain `MODEL_ALIAS`; include the quantization as shown so
  the artifact name identifies the exact model weight.
- The ISO and its `.sha256` sidecar land in the output directory.
- See `build/debian/README.md` for the full build chain and verification.
- To install ai-core without building an ISO, use
  `packaging/ai-core/install.sh`.

### The next layer: an execution trust layer

A roadmap direction, not a current capability — hardening agent
authorization and attribution from application-level behavior into
system-level primitives:

- **First-class audit of agent actions**: what each agent did is
  verifiable at the system level
- **Per-agent budgets**: a hard cap on each agent’s token and compute
  consumption
- **Computer-use input attribution**: the system can answer “which
  agent moved my mouse, and why”

### Components and licenses

| Component | Role | License |
|---|---|---|
| [Debian 13](https://www.debian.org/) | Base operating system | DFSG-free software |
| [llama.cpp](https://github.com/ggml-org/llama.cpp) | Default llama-server inference engine (b12669) | MIT |
| [Qwen3.5-9B](https://huggingface.co/unsloth/Qwen3.5-9B-GGUF) | Default GGUF model, fetched at build time (sha256-pinned) | Apache-2.0 — not redistributed here |
| [hax](https://github.com/OleksandrChekhovskyi/hax) | Default and only shipped assistant harness | MIT |
| [LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM) | Optional Gemma-flavor inference runtime | Apache-2.0 |
| [Gemma 4 E4B](https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm) | Optional non-default model | Gemma Terms of Use — not redistributed here |

This repository's code is MIT (`LICENSE`); third-party attributions and
license notices ship with the relevant package files.

### Repository layout

```text
packaging/ai-core/       Local inference, model import, installer, assistant
packaging/ai-core-deb/   lmlinux-ai-core .deb packaging (apt upgradable)
build/debian/            Live ISO builder and build documentation
```

---

## 中文

### 这是什么

lmlinux 把本地语言模型集成进 Debian 13。这套系统——live 会话或装到
硬盘后——就是普通的、可写的 Debian——`apt` 正常使用且持久——AI 栈
以常规软件包形式预装。

产品主打**两个无法依赖云端助手的场景**：

1. **离线救援**：无法联网时，从 live 或已安装环境排查并协助修复既有
   系统的配置、软件源、挂载和服务故障。
2. **首次安装及首次启动无网络**：在机器尚未联网时，协助完成网络、
   APT 源、挂载和服务等初始配置，排查安装及装后首次启动的问题。

两个场景中的助手都在本地运行；涉及管理员变更时，仍需你通过
`sudo ai` 明确授权。

### 核心组成与职责

- **llama-server——本地推理服务：** 以 systemd 服务运行，在
  `127.0.0.1:21718` 提供 Qwen3.5-9B 推理，完全离线，并支持工具调用的
  OpenAI 兼容 API。
- **hax——助手交互与会话管理：** 通过原生 llama.cpp provider 处理安装和
  救援中的配置问题（网络、挂载、APT 软件源和服务）。会话可跨 Ctrl+C 保存，
  并带原上下文恢复。
- **模型文件——构建期载荷：** 模型以 SHA-256 钉死哈希，构建时写入 live
  镜像；Git 仓库永不携带模型权重。

### 当前状态与验证

- **版本：** `13.8.0-rc1` 搭载 Qwen3.5-9B、hax 与 llama-server 栈。
  本版为候选发布，不是 `latest` 稳定版。
- **已通过检查：** 该精确镜像通过构建完整性检查、独立制品复核、离线
  live 启动与装硬盘初探，以及离线硬盘系统的冷启动、暖缓存追问和
  bare-hax 终验。
- **两次成功的软件源修复：**
  1. **受控单故障测试：** 只给自然语言请求、不提供修复命令，助手在
     16 分 15 秒内把失效的仅 cdrom APT 源替换为 Debian 13 官方源。
     `apt-get update` 成功，独立更新与软件包解析检查也通过。
  2. **最后一次安装测试：** 用户实测另一次软件源修复约 8 分钟完成。
- **刻意设计的多故障压力测试：** 两次成功之间进行的另一场测试连续叠加
  多个故障，全程无人干预，用于探索 9B 能力上限，并非重复上述单故障修复。
  该测试约 66 分钟后仍未完成：它把 APT 源改成标有 `[trusted=yes]` 的
  HTTP 条目，改动 resolver/NetworkManager 状态，并转向 `dummy0`/veth
  修复，最终仍未装上救援夹具。多轮修复可能需要长时间等待，每项特权变更
  都应先审查。
- **显示现象：**
  - 一次装后启动观察到前台停在 tty1 登录提示，而 LightDM/Cinnamon 正在
    VT7 启动；按 Ctrl+Alt+F7 可看到桌面。
  - 后来重新安装系统的日志显示 LightDM 在开机约 17 秒和 39 秒请求激活
    VT7，但最初观察并未连续记录前台 VT 状态。
  - 随后一次全程无键盘输入的全新安装在测试 VM 近 2 分钟后自动进入 GUI。
  - 另一次首次 HDD 启动曾出现未复现的黑屏 / 虚拟终端无响应，需要硬复位；
    后续终验通过。
- **验证边界：** 两次成功修复与未完成的压力测试是不同结果。上述检查均未
  完成 GA 前仍需通过的行为电池、完整离线救援 / 首次安装、真实用户和外部
  反馈门槛。下文执行信任层仍是路线图方向，不是当前能力。

### 安装

发行镜像是以 sha256 钉死的 Debian 13.8.0 live Cinnamon ISO 重建的，
lmlinux AI 栈已烤入 live 系统（含真实模型时为数 GiB）。

#### 下载并校验

1. 使用 [ORAS CLI](https://github.com/oras-project/oras) 拉取镜像。
   GitHub Release 单文件上限为 2 GiB，因此这个更大的镜像以 OCI 制品
   形式发布在 ghcr：

   ```bash
   oras pull ghcr.io/lmlinux/lmlinux-iso:rc
   ```

2. 校验下载的 ISO：

   ```bash
   sha256sum lmlinux-debian-13.8.0-amd64-cinnamon-live-qwen3.5-9b-q4_k_m-20261125.iso
   # 2eb28a574c67ce1b9cd6b306162a3f87ca1178ac291e310daa71b2c2bfea7ecd
   ```

   - 精确大小：**10,030,678,016 字节**。
   - ghcr 上的 blob digest 就是文件 SHA-256，哈希校验通过即完成端到端
     验证。
   - OCI 制品仅使用字面 `rc` 标签，不提供按版本号命名的 registry 标签，
     也不提供 `latest` 标签。

#### 写入 U 盘并安装

1. 把已校验的 ISO 写入 U 盘。将 `/dev/sdX` 替换为 **U 盘整盘设备**；
   以下命令会清除该设备的全部内容：

   ```bash
   sudo dd if=lmlinux-debian-13.8.0-amd64-cinnamon-live-qwen3.5-9b-q4_k_m-20261125.iso of=/dev/sdX bs=4M conv=fsync status=progress
   ```

2. 从 U 盘启动，进入 live Cinnamon 桌面，AI 开箱即用——**无需联网、
   无需安装**。
3. 要装到硬盘，在 live 桌面里运行安装器：
   - 它把整个系统（含 AI 组件与模型）复制到所选磁盘，全程离线。
   - 引导菜单与安装器都是原版 Debian live 的，没有任何问题被预先代答。
   - 建议目标盘准备 **40 GiB 或更多**。复制内容包括完整桌面系统与
     5.29 GiB 模型；10 GiB 盘实测在「安装系统」步失败。

从源码构建同样完全支持，见[构建](#构建)。

#### 首次启动与首次提问

- **图形切换：** 在 16 GiB 内存、4 vCPU VMware 测试中，一次全程无键盘
  输入的全新安装启动在约 **118 秒**自动激活图形 VT，并在约 **177 秒**
  开始 Cinnamon 用户会话。
- **等待期间在做什么：** 对已有 5.29 GiB 模型的启动期 SHA-256 校验从约
  36 秒持续到 180 秒，与图形初始化重叠。llama-server 随后才在约
  183–212 秒加载模型，因此这段较晚的模型加载不能解释此前的图形等待。
- **如何处理：** 不同硬件耗时会不同，请先等待数分钟，不要急于认定启动
  异常。如果仍停在 tty1 登录提示，可按 Ctrl+Alt+F7 选择图形 VT。不要为
  绕过这个切换过程而修改默认 target 或添加 tty1 自动登录。
- **内存要求：** 9B 模型需要 **16 GiB 内存**。
- **首次响应延迟：** 开机后第一个问题需要分钟级而非秒级响应，既包括模型
  加载，也包括助手约 2.4K-token 系统提示词的冷求值。在 4 vCPU 的 9B
  实测中，仅首次提示词求值就约需 **7 分钟**，完整首轮引擎处理约 8 分钟。
  后续轮次会复用 KV 缓存，但工具驱动修复仍需要多次推理。

### 助手用法

#### 启动与恢复

- **启动：** 打开终端运行统一离线入口 `ai`。请用 `ai`，不要直接调用
  `hax`：`ai` 会配置本地 provider，并在冷启动时等待引擎完成模型校验和
  加载（显示简短进度提示），而不是直接失败；随后启动镜像中唯一内置的
  **hax**，使用其内置 prompt。
- **恢复：** 运行 `ai -c` 可带原上下文恢复上一个会话；中断的会话会保存，
  Ctrl+C 后不必从头再来。
- **后端接线：** 后端由 `/etc/ai-core/config.env` 中的 `HARNESS=` 决定，
  这一行切换接线保留给未来的 harness。

#### 权限与秘密信息

- 日常只读诊断使用普通 `ai`。
- 对于你明确授权管理员写操作的系统维护任务，亲自运行 `sudo ai`。这会让
  助手及其工具获得 root 权限，不适合日常提问。
- 密码只输入操作系统的 sudo 提示，不要粘贴进助手对话。模型虽然离线，但
  hax 会把会话记录保存在本地，因此贴进对话的任何秘密仍可能留在这些本地
  文件中。

#### 管理常驻内存

推理服务会把模型常驻内存（9B 实测约 **8.7 GiB RSS**，实际占用随环境
变化）。可以保持常驻以获得更快的暖缓存后续响应，或停止服务释放内存：

```bash
sudo systemctl stop ai-core
```

- **停止服务**会卸载模型并释放权重与 KV 缓存占用的内存，不会删除模型、
  hax 配置或已保存会话，但当时正在进行的推理会被中断。服务保持停止，
  直到手动启动或重启。
- **重新启动**使用 `sudo systemctl start ai-core`，会重新加载模型；下一个
  问题也需重新承担模型加载和冷 prefill 成本。
- **禁止开机自启**使用 `sudo systemctl disable --now ai-core`。

### 构建

#### 前置条件

- 以 root 运行，构建机安装 `xorriso` 与 `squashfs-tools`。
- 备好 ai-core .deb 内嵌的 litert-lm venv。venv 不可重定位，须在
  Debian 13 amd64 主机上构建，全程不涉及虚拟化。任选一种准备方式：
  - 设置 `VENV_HOST=user@host`。
  - 在 `debian:13` 容器里运行 staging。
  - 将 `VENV_TARBALL` 指向现成 tarball。
- 完整说明见 `build/debian/README.md`。

#### 模型输入与构建

模型是构建输入而非仓库资产。可以使用本地文件或从 Hugging Face 获取；
两种来源都会先对照 `MODEL_SHA256` 校验，通过才进入镜像：

```bash
# 本地文件
MODEL_PATH=<模型路径>/Qwen3.5-9B-Q4_K_M.gguf \
MODEL_FILE=Qwen3.5-9B-Q4_K_M.gguf \
MODEL_ALIAS=qwen3.5-9b \
MODEL_SHA256=03b74727a860a56338e042c4420bb3f04b2fec5734175f4cb9fa853daf52b7e8 \
ISO_NAME=lmlinux-debian-13.8.0-amd64-cinnamon-live-qwen3.5-9b-q4_k_m \
  build/debian/build-live-iso.sh

# 或从 Hugging Face 拉取（进构建缓存）
MODEL_URL=https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-Q4_K_M.gguf \
MODEL_FILE=Qwen3.5-9B-Q4_K_M.gguf \
MODEL_ALIAS=qwen3.5-9b \
MODEL_SHA256=03b74727a860a56338e042c4420bb3f04b2fec5734175f4cb9fa853daf52b7e8 \
ISO_NAME=lmlinux-debian-13.8.0-amd64-cinnamon-live-qwen3.5-9b-q4_k_m \
  build/debian/build-live-iso.sh
```

#### 输出与验证

- `ISO_NAME` 必须包含 `MODEL_ALIAS`；按示例同时写入量化精度，让制品名
  能识别具体模型权重。
- ISO 与 `.sha256` 校验文件输出到输出目录。
- 完整构建链与验证见 `build/debian/README.md`。
- 如果只需单独安装 ai-core、无需构建 ISO，使用
  `packaging/ai-core/install.sh`。

### 下一层：执行信任层

路线图方向，不是当前能力——把 agent 授权与来源追溯从应用层行为
硬化为系统级原语：

- **agent 动作的一等公民审计**：每个 agent 做过什么，系统级可查证
- **per-agent 预算**：每个 agent 的 token/算力消耗有硬上限
- **computer-use 输入事件来源追溯**：系统答得上「刚才哪个 agent 动了
  我的鼠标、为什么」

### 组件与许可

| 组件 | 作用 | 许可 |
|---|---|---|
| [Debian 13](https://www.debian.org/) | 基础操作系统 | DFSG 自由软件 |
| [llama.cpp](https://github.com/ggml-org/llama.cpp) | 默认 llama-server 推理引擎（b12669） | MIT |
| [Qwen3.5-9B](https://huggingface.co/unsloth/Qwen3.5-9B-GGUF) | 默认 GGUF 模型，构建时拉取（sha256 钉死） | Apache-2.0——本仓不再分发 |
| [hax](https://github.com/OleksandrChekhovskyi/hax) | 默认且唯一内置的助手 harness | MIT |
| [LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM) | 可选 Gemma 味推理运行时 | Apache-2.0 |
| [Gemma 4 E4B](https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm) | 可选非默认模型 | Gemma Terms of Use——本仓不再分发 |

本仓库代码为 MIT（`LICENSE`）；第三方署名与许可声明随对应软件包文件提供。

### 仓库结构

```text
packaging/ai-core/       本地推理、模型导入、安装器、助手
packaging/ai-core-deb/   lmlinux-ai-core .deb 打包（可经 apt 升级）
build/debian/            live ISO 构建器与构建文档
```
