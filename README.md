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

- **Local inference**: a llama-server systemd service serves Qwen3.5-9B at
  `127.0.0.1:21718` (OpenAI-compatible API with tool calling), fully
  offline.
- **First-boot assistant**: hax handles install-time problems (network,
  mounts, apt sources, services) through its native llama.cpp provider.
  Sessions survive Ctrl+C and can be resumed with their prior context.
- **Model as firmware**: the model payload is pinned by sha256 and baked
  into the live image at build time — the repository never carries
  weights.

Status: `13.8.0-rc1` carries the Qwen3.5-9B, hax, and llama-server stack.
This exact image passed build-integrity checks, an independent artifact
review, offline live-boot and install-to-disk probes, and offline installed-
system cold-start, warm-follow-up, and bare-hax probes. These checks do not
complete the behavioral, complete offline-rescue/first-install, real-user,
or external-feedback gates required before GA. One unassisted offline-rescue
run on a 16 GiB RAM / 4-vCPU VM did not finish after about 66 minutes: it
changed APT sources to HTTP entries marked `[trusted=yes]`, altered
resolver/NetworkManager state, and pursued `dummy0`/veth recovery without
installing the rescue fixture. Expect long waits and review every proposed
privileged change. An installed-boot observation left a tty1 login prompt in
the foreground while LightDM/Cinnamon was starting on VT7; Ctrl+Alt+F7
exposed the desktop. Logs from a later reinstallation show LightDM requesting
VT7 activation about 17 and 39 seconds after boot, but the original
observation did not continuously record foreground-VT state. The user then
completed a completely fresh, no-keyboard-input installation that reached the
GUI automatically in nearly two minutes on the test VM. A separate initial HDD
boot had an unreproduced black-screen/unresponsive-VT transient
requiring a hard reset; subsequent final probes passed. This is a release
candidate, not the `latest` stable release. The execution trust layer below
remains a roadmap direction, not a current capability.

### Installing

The distribution image is a sha256-pinned Debian 13.8.0 live Cinnamon ISO
with the lmlinux AI stack baked in (several GiB with the real model). Write
it to a USB stick, boot it, and you land in a live Cinnamon desktop where
the AI works immediately — **no network and no installation needed**.

Get the image (GitHub Releases caps single files at 2 GiB, and this image
exceeds that limit, so it ships as an OCI artifact on ghcr):

```bash
oras pull ghcr.io/lmlinux/lmlinux-iso:rc
sha256sum lmlinux-debian-13.8.0-amd64-cinnamon-live-qwen3.5-9b-q4_k_m-20261125.iso
# 2eb28a574c67ce1b9cd6b306162a3f87ca1178ac291e310daa71b2c2bfea7ecd
sudo dd if=lmlinux-debian-13.8.0-amd64-cinnamon-live-qwen3.5-9b-q4_k_m-20261125.iso of=/dev/sdX bs=4M conv=fsync status=progress
```

The ISO is exactly **10,030,678,016 bytes**. Only the literal `rc` OCI tag is
published; there is no versioned registry tag and no `latest` tag.

`oras` is the [ORAS CLI](https://github.com/oras-project/oras); replace
`/dev/sdX` with your USB device — the write destroys its content. The
blob digest on ghcr is the file's sha256, so passing the hash check is
the end-to-end verification. Building from source is equally supported
(see Building below).

To install to disk, run the installer from the live desktop: it copies
the whole system — AI components and model included — to the disk you choose,
fully offline. The boot menus and the installer are the vanilla Debian
live ones; nothing is pre-answered for you. Budget the target disk
generously: the copy includes the full desktop system and the 5.29 GiB
model, and a 10 GiB disk fails at the install step (measured); 40 GiB
or more is comfortable.

On the 16 GiB RAM / 4-vCPU VMware test, a completely fresh installed boot
with no keyboard input activated the graphical VT at about **118 seconds**
and started the automatic Cinnamon user session at about **177 seconds**.
Boot-time SHA-256 verification of the existing 5.29 GiB model ran from about
36 to 180 seconds, overlapping graphics initialization. llama-server loaded
the model afterward, from about 183 to 212 seconds, so that later model-load
window does not explain the preceding graphical wait. Timing varies by
hardware: wait a few minutes before assuming a problem. If a tty1 login
prompt remains, Ctrl+Alt+F7 selects the graphical VT. Do not change the
default target or add tty1 autologin to work around this transition.

The 9B model needs **16 GiB of RAM**. The **first** prompt
after boot is slow — minutes, not seconds. First-use latency includes both
model loading and cold evaluation of the assistant's roughly 2.4K-token
system prompt. On a 4-vCPU 9B test, that first prompt evaluation alone took
about **7 minutes**; the complete first engine turn took about 8 minutes.
Later turns reuse the KV cache, although tool-driven repairs still involve
multiple inference rounds.

### Using the assistant

Open a terminal and run `ai` — that is the assistant's unified entry
point, fully offline. Use `ai` rather than invoking `hax` directly: `ai`
applies the local provider configuration and, on a cold boot, waits for
the engine to finish verifying and loading the model (with a short
progress line) instead of failing. It then starts **hax**, the only
harness shipped in the image, using its built-in prompt. Run `ai -c` to
resume the previous session with its context; interrupted sessions are
saved, so Ctrl+C does not force you to start over. The backend is set by
`HARNESS=` in `/etc/ai-core/config.env` — the one-line switch remains as
wiring for future harnesses.

Use ordinary `ai` for read-only diagnosis. For a system-maintenance task
where you explicitly authorize administrative writes, run `sudo ai`
yourself: this gives the assistant and its tools root privileges and is
not intended for routine questions. Enter your password at the operating
system's sudo prompt, not in the assistant conversation. The model is
offline, but hax saves session transcripts locally, so any secret pasted
into the chat can remain in those local files.

The inference service keeps the model resident in memory (about **8.7 GiB
RSS** in the 9B test; actual use varies). You can
choose between keeping it resident for faster warm follow-ups and stopping
it to free RAM:

    sudo systemctl stop ai-core

Stopping the service unloads the model and releases its weights and KV
cache; it does not delete the model, hax configuration, or saved sessions.
Any inference running at that moment is interrupted. The service stays
stopped until you restart it or reboot. `sudo systemctl start ai-core`
reloads the model, and the next prompt pays the model-load and cold-prefill
cost again. To keep the service from starting at boot: `sudo systemctl
disable --now ai-core`.

### Building

Build prerequisites: run as root with `xorriso` and `squashfs-tools`
installed, and stage the prebuilt litert-lm venv that the ai-core .deb
embeds — venvs are not relocatable, so it must be built on a Debian 13
amd64 host; no virtualization is involved (set `VENV_HOST=user@host`,
run the staging in a `debian:13` container, or point `VENV_TARBALL` at
an existing tarball). Full details: `build/debian/README.md`.

The model is a build input, not a repository asset — it comes from a local
file or is fetched from Hugging Face, and either source is verified
against `MODEL_SHA256` before anything enters the image. The result is
the distribution image:

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

`ISO_NAME` must contain `MODEL_ALIAS`; include the quantization as shown so
the artifact name identifies the exact model weight. The ISO and its
`.sha256` sidecar land in the output directory. See
`build/debian/README.md` for the full build chain and verification; ai-core
can also be installed standalone with
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

- **本地推理**：llama-server 以 systemd 服务在 `127.0.0.1:21718` 提供
  Qwen3.5-9B 推理（OpenAI 兼容 API、支持工具调用），完全离线。
- **装机助手**：hax 通过原生 llama.cpp provider 处理装机配置期问题
  （网络、挂载、软件源、服务）。会话可跨 Ctrl+C 保存，并带原上下文恢复。
- **模型即固件**：模型负载以 sha256 钉死哈希、构建时烤入 live 镜像
  ——本仓库永不携带模型权重。

状态：`13.8.0-rc1` 搭载 Qwen3.5-9B、hax 与 llama-server 栈。该精确镜像
已通过构建完整性检查、独立制品复核、离线 live 启动与装硬盘初探，以及
离线硬盘系统的冷启动、暖缓存追问和 bare-hax 终验。这些检查并未完成 GA
前仍需通过的行为电池、完整离线救援 / 首次安装、真实用户和外部反馈门槛。
一次在 16 GiB 内存 / 4 vCPU 虚拟机上的无人协助离线救援运行约 66 分钟仍
未完成：它把 APT 源改成标有 `[trusted=yes]` 的 HTTP 条目，改动
resolver/NetworkManager 状态，并转向 `dummy0`/veth 修复，最终仍未装上
救援夹具。多轮修复可能需要长时间等待，每项特权变更都应先审查。一次装后
启动观察到前台停在 tty1 登录提示，而 LightDM/Cinnamon 正在 VT7 启动；
按 Ctrl+Alt+F7 可看到桌面。后来重新安装系统的日志显示 LightDM 在开机约
17 秒和 39 秒请求激活 VT7，但最初观察并未连续记录前台 VT 状态。随后
用户完成了一次全程无键盘输入的全新安装，测试 VM 在近 2 分钟后自动进入
GUI。另一次首次 HDD 启动曾出现一次未复现的黑屏 / 虚拟终端无响应，需要硬复位；后续
终验通过。本版为候选发布，不是 `latest` 稳定版。下文执行信任层仍是路线图
方向，不是当前能力。

### 安装

发行镜像是以 sha256 钉死的 Debian 13.8.0 live Cinnamon ISO 重建的，
lmlinux AI 栈已烤入 live 系统（含真实模型时为数 GiB）。写入 U 盘、开机
即进入 live Cinnamon 桌面，AI 开箱即用——**无需联网、无需安装**。

获取镜像（GitHub Release 单文件上限 2 GiB，本镜像超过该上限，故以
OCI 制品形式发布在 ghcr）：

```bash
oras pull ghcr.io/lmlinux/lmlinux-iso:rc
sha256sum lmlinux-debian-13.8.0-amd64-cinnamon-live-qwen3.5-9b-q4_k_m-20261125.iso
# 2eb28a574c67ce1b9cd6b306162a3f87ca1178ac291e310daa71b2c2bfea7ecd
sudo dd if=lmlinux-debian-13.8.0-amd64-cinnamon-live-qwen3.5-9b-q4_k_m-20261125.iso of=/dev/sdX bs=4M conv=fsync status=progress
```

ISO 大小精确为 **10,030,678,016 字节**。OCI 制品仅使用字面 `rc` 标签，
不提供按版本号命名的 registry 标签，也不提供 `latest` 标签。

`oras` 见 [ORAS CLI](https://github.com/oras-project/oras)；`/dev/sdX`
换成你的 U 盘设备——写入会清掉整盘内容。ghcr 上的 blob digest 就是
文件 sha256，哈希校验通过即完成端到端验证。从源码构建同样完全支
持（见下文「构建」）。

要装到硬盘，在 live 桌面里运行安装器：它把整个系统——含AI组件与
模型——复制到你选的磁盘，全程离线。引导菜单与安装器都是原版
Debian live 的，没有任何问题被预先代答。目标盘要留足：复制内容
包括完整桌面系统与 5.29 GiB 模型，10 GiB 盘实测在「安装系统」步
失败；给 40 GiB 以上最稳。

在 16 GiB 内存、4 vCPU VMware 测试中，一次全程无键盘输入的全新安装
启动在约 **118 秒**自动激活图形 VT，并在约 **177 秒**开始 Cinnamon 用户
会话。对已有 5.29 GiB 模型的启动期 SHA-256 校验从约 36 秒持续到 180 秒，
与图形初始化重叠。llama-server 随后才在约 183–212 秒加载模型，因此这段
较晚的模型加载不能解释此前的图形等待。不同硬件的耗时会不同：请先等待
数分钟，不要急于认定启动异常。如果仍停在 tty1 登录提示，可按
Ctrl+Alt+F7 选择图形 VT。不要为绕过这个切换过程而修改默认 target 或添加
tty1 自动登录。

9B 模型需要 **16 GiB 内存**。开机后**第一个**问题响应慢——分钟级而非秒级。
首次延迟既包括模型加载，也包括助手约 2.4K-token 系统提示词的冷求值。
在 4 vCPU 的 9B 实测中，仅首次提示词求值就约需 **7 分钟**，完整首轮
引擎处理约 8 分钟。后续轮次会复用 KV 缓存，但工具驱动修复仍需要多次
推理。

### 助手用法

打开终端敲 `ai`——这是助手的统一入口，完全离线。请用 `ai`，不要直接
调用 `hax`：`ai` 会配置本地 provider，并在冷启动时等待引擎完成模型
校验和加载（显示简短进度提示），而不是直接失败；随后它启动镜像中唯一
内置的 **hax**，使用 hax 自带的内置 prompt。运行 `ai -c` 可带原上下文
恢复上一个会话；中断的会话会保存，Ctrl+C 后不必从头再来。后端由
`HARNESS=` 在 `/etc/ai-core/config.env` 决定——这一行切换接线保留给未来
的 harness。

日常只读诊断使用普通 `ai`。对于你明确授权管理员写操作的系统维护
任务，亲自运行 `sudo ai`：这会让助手及其工具获得 root 权限，不适合
日常提问。密码只输入操作系统的 sudo 提示，不要粘贴进助手对话。
模型虽然离线，但 hax 会把会话记录保存在本地，因此贴进对话的任何
秘密仍可能留在这些本地文件中。

推理服务会把模型常驻内存（9B 实测约 **8.7 GiB RSS**，实际占用随环境
变化）。你可以自由选择常驻以获得更快的暖缓存后续响应，
或停止服务释放内存：

    sudo systemctl stop ai-core

停止服务会卸载模型并释放权重与 KV 缓存占用的内存，不会删除模型、
hax 配置或已保存会话；当时正在进行的推理会被中断。停止后保持停止，
直到手动启动或重启。`sudo systemctl start ai-core` 会重新加载模型，
下一个问题也需重新承担模型加载和冷 prefill 成本。若想开机完全不
自启：`sudo systemctl disable --now ai-core`。

### 构建

构建前置：以 root 运行、构建机装好 `xorriso` 与 `squashfs-tools`，并
备好 ai-core .deb 内嵌的 litert-lm venv——venv 不可重定位，须在
Debian 13 amd64 主机上构建，全程不涉及虚拟化（设
`VENV_HOST=user@host`、在 `debian:13` 容器里跑 staging、或以
`VENV_TARBALL` 指向现成 tarball 均可）。完整说明见
`build/debian/README.md`。

模型是构建输入而非仓库资产——从本地文件或 Hugging Face 获取，两种
来源都会先对照 `MODEL_SHA256` 校验，通过才进入镜像。产出即发行
镜像：

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

`ISO_NAME` 必须包含 `MODEL_ALIAS`；按示例同时写入量化精度，让制品名
能识别具体模型权重。ISO 与 `.sha256` 校验文件输出到输出目录。完整
构建链与验证见 `build/debian/README.md`；ai-core 也可用
`packaging/ai-core/install.sh` 单独安装。

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
