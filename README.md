<div align="center">

# AMD Ryzen AI Halo Setup

**One command sets up an AMD Ryzen AI machine on Linux as a GPU + NPU + CPU AI workstation.**

Drivers, firmware, ROCm, XRT, PyTorch, FastFlowLM, Lemonade, llama.cpp and IRON are
installed and configured, then tested end to end.

![Platform](https://img.shields.io/badge/platform-Ubuntu%2024.04%20%7C%2026.04%20%7C%2026.10-E95420?logo=ubuntu&logoColor=white)
![GPU](https://img.shields.io/badge/GPU-ROCm%20%2B%20Vulkan-ED1C24?logo=amd&logoColor=white)
![NPU](https://img.shields.io/badge/NPU-XDNA2%20%C2%B7%2050%20TOPS-ED1C24?logo=amd&logoColor=white)
![Shell](https://img.shields.io/badge/shell-bash-4EAA25?logo=gnubash&logoColor=white)

[Quick start](#-quick-start) · [What you get](#-what-you-get) · [Testing](#-testing-your-system) ·
[Supported systems](#-supported-systems) · [Options](#%EF%B8%8F-options) · [Troubleshooting](#-troubleshooting)

</div>

---

## 🚀 Quick start

On a fresh **Ubuntu** install on an AMD Ryzen AI machine, run from your normal
user account (not a root shell):

```bash
curl -fsSL https://raw.githubusercontent.com/BudEcosystem/AMD-Ryzen-AI-Halo-Setup/main/install.sh | sudo bash -s -- -y
sudo reboot
amd-ryzen-ai-test
```

That's it. The installer downloads the scripts, sets up the system, runs the
acceptance tests and tells you whether a reboot is needed.

<details>
<summary><b>Prefer to read the code first? Use a git clone instead.</b></summary>

```bash
git clone https://github.com/BudEcosystem/AMD-Ryzen-AI-Halo-Setup.git
cd AMD-Ryzen-AI-Halo-Setup
sudo ./amd-ryzen-ai-setup.sh --dry-run      # show every step without changing anything
sudo ./amd-ryzen-ai-setup.sh -y             # standard profile
sudo reboot
./amd-ryzen-ai-test.sh                      # acceptance tests
```
</details>

<details>
<summary><b>Just want to check an existing machine? Run the tests only (nothing is installed).</b></summary>

```bash
curl -fsSL https://raw.githubusercontent.com/BudEcosystem/AMD-Ryzen-AI-Halo-Setup/main/amd-ryzen-ai-test.sh | bash
```
</details>

| Profile | Command | Installs |
|---|---|---|
| `minimal` | `... \| sudo bash -s -- --profile minimal -y` | Drivers, firmware, ROCm, XRT, limits |
| `standard` *(default)* | `... \| sudo bash -s -- -y` | + PyTorch (ROCm), FastFlowLM, Lemonade server |
| `full` | `... \| sudo bash -s -- --profile full -y` | + llama.cpp built from source, IRON/MLIR-AIE, Docker |

> Expect **30–90 minutes**, depending on bandwidth. Downloads total about 12 GB:
> roughly 3 GB of ROCm packages, 6 GB of PyTorch/Python wheels and 3 GB for
> Lemonade's ROCm backend. You can safely run the script again, so a run cut
> short by a network failure can simply be repeated.

---

## ✨ What you get

| | Engine | Software stack | Measured on Ryzen AI MAX+ PRO 395 |
|---|---|---|---|
| 🟥 | **GPU**: Radeon 8060S, gfx1151, 40 CU | ROCm (HIP, rocBLAS, hipBLASLt, MIOpen, MIGraphX), PyTorch ROCm, Vulkan RADV, OpenCL, VA-API, llama.cpp (HIP + Vulkan) | PyTorch fp16 GEMM **28 TFLOPS** · Llama-3.2-1B **~220 tok/s** |
| 🟧 | **NPU**: XDNA2, 50 TOPS | `amdxdna` driver, XRT + `xrt-smi`, FastFlowLM (LLMs on the NPU), IRON/MLIR-AIE (custom kernels), Lemonade `flm:npu` | `xrt-smi validate` **51 TOPS** · Llama-3.2-1B **~70 tok/s** |
| 🟦 | **CPU**: 16 Zen 5 cores, AVX-512 | BLIS, libFLAME, OpenBLAS, OpenMP, TBB, NUMA/hwloc, perf, `performance` power profile | NumPy fp64 GEMM **~1.5 TFLOPS** |
| 🧠 | **Unified memory** | TTM/GTT sized so the iGPU can use most of system RAM (for example 80 GiB of a 96 GiB system) | 70B-class models fit on the GPU |

The installer also configures:
* **Lemonade server**: an OpenAI-compatible API and web UI at
  `http://localhost:13305`, which routes to the GPU or the NPU.
* **Python**: a Python 3.12 environment at `~/amd-ai/venv` with transformers,
  accelerate, datasets, ONNX Runtime and JupyterLab, plus a Jupyter kernel.
* **Permissions**: the `render` and `video` groups, udev rules, unlimited
  memlock for the NPU, and a shell environment file (`$AMD_GFX_TARGET`,
  `amd-ai-venv`).

### "I was told the NPU doesn't work on Linux"

That was true until recently. **It works now**, and this repo sets it up:

* The **`amdxdna` driver is in the mainline kernel** (6.14+; 7.0+ supports the
  newer firmware protocol). Ubuntu 26.04+ ships it. On 24.04 the script
  installs `amdxdna-dkms`.
* **XRT**, the NPU runtime, ships in Ubuntu 26.04+ (`libxrt-npu2`).
* **FastFlowLM** runs LLMs on the XDNA2 NPU under Linux, and **Lemonade** puts
  it behind an OpenAI-compatible server.
* **IRON / MLIR-AIE** lets you write your own NPU kernels in Python.
* **Ryzen AI Software** (ONNX Runtime + Vitis AI EP) has a Linux build for
  Ubuntu 24.04 only, behind an AMD account login. Pass
  `--ryzen-ai-sw-dir <downloads>` to install it.

---

## 🧪 Testing your system

`amd-ryzen-ai-test` is a standalone **acceptance test suite**. It needs no
root, changes nothing, and runs 50+ checks across seven categories,
including **real workloads** on every engine:

| Category | What it proves |
|---|---|
| `system` | OS and kernel, a pending reboot, linux-firmware, Secure Boot, dpkg health, disk space |
| `memory` | RAM, BIOS VRAM carve-out, and that the GTT limit is **configured and active** |
| `gpu` | amdgpu bound, `/dev/kfd` and render node access, groups active, `rocminfo`, **compiles and runs a HIP kernel** (bandwidth check), amd-smi, OpenCL, Vulkan, VA-API |
| `npu` | PCI device, amdxdna bound, `/dev/accel` access, firmware ≥ 1.1, memlock, `xrt-smi examine` and **`validate` (TOPS)**, `flm validate`, **LLM inference on the NPU**, **builds and runs an IRON kernel on the NPU** |
| `cpu` | Power profile, AVX-512/VNNI/BF16, math libraries, **NumPy GEMM GFLOPS** |
| `python` | venv, PyTorch sees the GPU, a **correctness check plus fp16/bf16 TFLOPS**, imports of 10 AI packages, ONNX Runtime EPs, Jupyter kernel |
| `apps` | llama.cpp sees ROCm and Vulkan, `llama-bench` (if a GGUF is present), Lemonade health and backends, **GPU and NPU chat completions through Lemonade**, Docker |

```bash
amd-ryzen-ai-test                 # full suite, ~3–5 min (as your user = tests your current session)
amd-ryzen-ai-test --quick         # skip slow tests, ~20 s
sudo amd-ryzen-ai-test            # test a *fresh login* of your user (before you re-login/reboot)
amd-ryzen-ai-test --only gpu,npu  # selected categories
amd-ryzen-ai-test --json r.json --junit r.xml   # machine-readable / CI output
amd-ryzen-ai-test --pull-models   # download a small NPU model if none is present
```

Example output (abridged):

```text
== NPU (XDNA / XRT / FastFlowLM / IRON) ==
  NPU PCI                      PASS  0000:c5:00.1 1022:17f0 XDNA2 (aie2p)
  amdxdna driver               PASS  bound (in-tree, kernel 7.3.0-10-generic)
  NPU firmware                 PASS  1.1.2.65
  XRT validate                 PASS  51 TOPS, latency 50 us, 94k op/s ...
  FLM NPU inference            PASS  llama3.2:1b: 60 tokens, 70.3 tok/s | "1, 2, 3, 4, 5, ..."
== Python / PyTorch ==
  PyTorch GPU                  PASS  torch 2.11.0+rocm7.13.0 | Radeon 8060S Graphics gfx1151 46 GiB
  PyTorch matmul               PASS  fp16 matmul 28.2 TFLOPS | bf16 matmul 27.5 TFLOPS
== Applications (llama.cpp / Lemonade / Docker) ==
  Lemonade GPU chat            PASS  Llama-3.2-1B-Instruct-GGUF: 60 tokens, 223.8 tok/s ...

Summary  45 PASS  1 WARN  0 FAIL  0 SKIP  (212s)
RESULT: PASS — system is ready for AMD GPU/NPU/CPU development.
Report: ~/amd-ai/test-reports/report-20261113-091500.{txt,json}
```

| Exit code | Meaning |
|---|---|
| `0` | **PASS**: no failures (warnings are allowed unless `--strict` is given) |
| `1` | **FAIL**: at least one check failed, and the summary lists what to fix |
| `3` | **INCOMPLETE**: no failures, but your login session predates the setup (groups or memlock not active yet). Re-login, reboot or use `sudo` |

Every run saves a report to `~/amd-ai/test-reports/`. Attach it to support
tickets.

---

## 💻 Supported systems

### Hardware

| Platform | GPU (gfx) | NPU | Status |
|---|---|---|---|
| **Ryzen AI Max / Max+ 300** (Strix Halo) | Radeon 8050S / 8060S (`gfx1151`) | XDNA2, 50 TOPS | ✅ primary target, tested |
| Ryzen AI 300 (Strix Point), AI 400 (Gorgon Point) | 880M / 890M (`gfx1150`) | XDNA2 | ✅ supported |
| Ryzen AI 5/7 300 (Krackan Point) | 820M–860M (`gfx1152`) | XDNA2 | ✅ supported |
| Ryzen 7040 / 8040 / 200 (Phoenix / Hawk Point) | 740M–780M (`gfx1103`) | XDNA1 | ⚠️ GPU + XRT; no LLMs on the NPU (FastFlowLM needs XDNA2) |

Tested on an **HP Z2 Mini G1a** (Ryzen AI MAX+ PRO 395, 128 GB). It should
also work on other Strix Halo systems such as the Framework Desktop, GMKtec
EVO-X2, ASUS ROG Flow Z13 and HP ZBook Ultra G1a.

### Operating systems

| OS | ROCm source | NPU runtime (XRT) | Status |
|---|---|---|---|
| **Ubuntu 26.04 LTS** | Ubuntu archive (ROCm 10.x) | Ubuntu archive | ⭐ **recommended** |
| Ubuntu 26.10+ | Ubuntu archive | Ubuntu archive | ✅ tested (26.10, kernel 7.3) |
| Ubuntu 24.04 LTS | AMD repo + HWE/OEM kernel | Lemonade PPA + `amdxdna-dkms` | ✅ supported |
| Ubuntu 25.10 | PyTorch wheels only | Lemonade PPA | ⚠️ best effort |
| Other distros | — | — | ❌ refused (`--force` for Debian) |

---

## 🧩 How it works

The setup runs in **stages**. Each stage checks the current state first and
skips work that is already done, so re-running the script also works as an
updater.

```mermaid
flowchart LR
  A[preflight] --> B[base] --> C[firmware] --> D[kernel]
  D --> E[gpu] --> F[memory] --> G[npu] --> H[cpu] --> I[python]
  I --> J[lemonade] --> K[llamacpp] --> L[iron] --> M[ryzenai] --> N[docker]
  N --> O[finalize] --> P[verify]
  classDef core fill:#ED1C24,color:#fff,stroke:#a00
  classDef opt fill:#444,color:#fff,stroke:#222
  class A,B,C,D,E,F,G,H,I,O,P core
  class J,K,L,M,N opt
```

**Core stages** (red) abort the run if they fail. **Optional stages** (grey)
only warn, so a temporary GitHub or PPA outage never breaks an install.

<details>
<summary><b>What each stage does</b></summary>

| Stage | What it does |
|---|---|
| `preflight` | Checks the CPU vendor, OS, disk space and network. Detects WSL/VMs, `amd_iommu=off` (which breaks the NPU) and the BIOS VRAM carve-out. |
| `base` | Runs `apt full-upgrade` and installs compilers, cmake/ninja, git-lfs, Python, pipx and `uv`. |
| `firmware` | Installs `linux-firmware` and `amd64-microcode`. Checks fwupd/LVFS for BIOS updates (applied only with `--apply-firmware-updates`) and that the NPU firmware is ≥ 1.1. |
| `kernel` | On 24.04 installs the HWE (≥ 6.17) or OEM kernel. Checks the `amdgpu`/`amdxdna` modules and warns about `amdgpu-dkms`, which is not wanted on APUs. |
| `gpu` | Installs ROCm (HIP, rocBLAS, hipBLASLt, MIOpen, MIGraphX, hipify), ROCm OpenCL, Vulkan RADV, VA-API, `amd-smi`, `nvtop` and `radeontop`. Adds the user to the `render`/`video` groups and installs udev rules. |
| `memory` | Lets the iGPU use most of system RAM (TTM `pages_limit`, the same file `amd-ttm` uses). Default: RAM minus max(8 GiB, 12.5 %). |
| `npu` | Installs XRT, `xrt-smi` and `pyxrt`, plus DKMS if needed. Sets memlock to unlimited (PAM + systemd), installs the `xrt-smi validate` archive and FastFlowLM. |
| `cpu` | Checks amd-pstate/EPP and sets the `performance` profile on desktops (laptops are left alone). Installs BLIS/libFLAME/OpenBLAS/LAPACKE, OpenMP, TBB, NUMA/hwloc, perf, lm-sensors and stress-ng. |
| `python` | Creates `~/amd-ai/venv` (uv, Python 3.12) with **ROCm PyTorch for the detected gfx target**, plus ONNX Runtime, transformers, accelerate, datasets, JupyterLab and a kernel. |
| `lemonade` | Installs the Lemonade server (systemd `lemond`, port 13305) with the `llamacpp:rocm`, `llamacpp:vulkan` and `flm:npu` backends. On Ubuntu releases the PPA doesn't cover, it uses the 26.04 suite, pinned to Lemonade packages only. |
| `llamacpp` | *(full)* Builds llama.cpp with HIP (rocWMMA flash attention) and Vulkan for this gfx target. |
| `iron` | *(full)* Installs MLIR-AIE/IRON at the latest release, in a venv on system Python so it matches the distro `pyxrt`. |
| `ryzenai` | *(opt-in)* Installs AMD Ryzen AI Software from tarballs you downloaded. |
| `docker` | *(full)* Installs Docker, adds the user to the docker group, and prints the GPU/NPU passthrough flags. |
| `finalize` | Writes `/etc/profile.d/amd-ryzen-ai.sh`, and installs `amd-ryzen-ai-setup` (sbin) and `amd-ryzen-ai-test` (bin). |
| `verify` | A built-in health check; `amd-ryzen-ai-test` is the more thorough suite. |
</details>

---

## ⚙️ Options

```text
sudo ./amd-ryzen-ai-setup.sh [options]

  --profile minimal|standard|full   what to install (default: standard)
  -y, --yes                         non-interactive
  -n, --dry-run                     print every action, change nothing
  --only a,b / --skip a,b           run or skip specific stages
  --verify / --quick-verify         health check only
  --user NAME                       developer user (default: the user who ran sudo)
  --rocm-source auto|distro|amd|pip-only|none     --rocm-version X.Y
  --gtt-gb N|auto|0                 GPU-addressable system RAM (0 = leave as is)
  --venv DIR  --python X.Y          Python environment location / version
  --with-X / --without-X            X = pytorch|flm|lemonade|llamacpp|iron|docker
  --ryzen-ai-sw-dir DIR             install AMD Ryzen AI Software tarballs
  --apply-firmware-updates          apply fwupd BIOS/firmware updates
  --no-upgrade  --force
```

The `install.sh` bootstrap accepts all of the above, plus `--ref <tag>` (pin
a release), `--test-only`, `--no-test` and `--quick`.

Logs are written to `/var/log/amd-ryzen-ai-setup/`.

---

## 🛠 Using the machine

```bash
amd-ai-venv                                  # activate ~/amd-ai/venv
python -c "import torch; print(torch.cuda.get_device_name(0))"
hipcc --offload-arch=$AMD_GFX_TARGET kernel.hip -o app

xrt-smi examine && xrt-smi validate          # NPU status / 50 TOPS benchmark
flm run llama3.2:1b                          # chat with an LLM on the NPU

lemonade backends                            # GPU (llamacpp:rocm/vulkan) + NPU (flm:npu)
lemonade run Llama-3.2-1B-Instruct-GGUF      # web UI at http://localhost:13305
curl localhost:13305/api/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"Llama-3.2-1B-Instruct-GGUF","messages":[{"role":"user","content":"Hi"}]}'

amd-smi monitor ; nvtop                      # GPU telemetry
amd-ryzen-ai-test --quick                    # health check
```

### BIOS settings worth checking

* **UMA frame buffer (dedicated VRAM).** Set it small (512 MB–4 GB). The script
  then gives the GPU most of system RAM through GTT. A large carve-out (32 GB+)
  also works, but that RAM is then hidden from the CPU.
* Keep the **NPU/IPU** and **IOMMU** enabled, and use a current BIOS.
* **Secure Boot** on 24.04 (DKMS): enroll the MOK key at the first reboot.

---

## 🩺 Troubleshooting

| Symptom | Fix |
|---|---|
| Tests say **INCOMPLETE** / memlock `8192` / group not active | Your session predates the setup. Log out and in, or reboot. `sudo amd-ryzen-ai-test` tests a fresh login. |
| `rocminfo`: permission denied | Not in `render` yet. Log out and in, or reboot. |
| `xrt-smi`: no devices | Check `lsmod \| grep amdxdna` and `journalctl -k \| grep -i xdna`. Make sure `amd_iommu=off` is not set and the NPU firmware is ≥ 1.1. |
| `xrt-smi`: `mmap ... Resource temporarily unavailable` | memlock isn't unlimited in this session. Re-login. |
| `xrt-smi validate`: `Archive not found` | `sudo amd-ryzen-ai-setup --only npu` |
| FLM: `No such device with index '0'` | `libxrt-npu2` is missing or memlock is too low. Re-run `--only npu`, then re-login. |
| PyTorch out of memory despite free RAM | `sudo amd-ryzen-ai-setup --only memory --gtt-gb <N>`, then reboot. |
| GTT limit "configured X, active Y" | Reboot to apply. |
| Lemonade `llamacpp:rocm` stays "installable" | Run `lemonade backends install llamacpp:rocm` and let it finish (several GB). |
| IRON `numpy._core._multiarray_umath` error | `sudo amd-ryzen-ai-setup --only iron` rebuilds the venv on system Python. |
| `mesa-opencl-icd` conflict | Expected: ROCm OpenCL replaces rusticl for compute. |
| ROCm profilers (rocprofv3) missing | Not packaged on Ubuntu yet. `pip install --index-url https://repo.amd.com/rocm/whl/gfx1151/ rocm-profiler` |

---

## 🏢 Deploying to a fleet / customers

* **Non-interactive:**
  `curl -fsSL .../install.sh | sudo bash -s -- -y --ref v1.0.0` installs from
  a pinned release for reproducible installs.
* **Two-step provisioning:** run setup, reboot, then
  `sudo -u <user> amd-ryzen-ai-test --json /var/tmp/amd-ai.json`. Exit code `0`
  means the machine is ready.
* **CI dashboards:** `--junit report.xml` produces standard JUnit XML.
* **Mirroring:** these external sources need to be reachable:
  * the Ubuntu archive
  * `repo.amd.com` (PyTorch ROCm wheels)
  * `stable.repo.amd.com` (ROCm on 24.04)
  * `ppa:lemonade-team/stable`
  * GitHub releases (FastFlowLM, mlir-aie, llama.cpp)
  * GitHub `Xilinx/VTD`

## 📁 Repository layout

| File | Purpose |
|---|---|
| [`install.sh`](install.sh) | One-line bootstrap: downloads the scripts, runs setup and then the tests |
| [`amd-ryzen-ai-setup.sh`](amd-ryzen-ai-setup.sh) | The idempotent, staged installer |
| [`amd-ryzen-ai-test.sh`](amd-ryzen-ai-test.sh) | Standalone acceptance test suite (no root, read-only) |

---

<div align="center">
<sub>Built by <a href="https://github.com/BudEcosystem">Bud Ecosystem</a>. Not affiliated with AMD. AMD, Ryzen, Radeon and ROCm are trademarks of Advanced Micro Devices, Inc.</sub>
</div>
