#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Bud Ecosystem — https://github.com/BudEcosystem/AMD-Ryzen-AI-Halo-Setup
# =============================================================================
#  amd-ryzen-ai-setup.sh
#
#  One-shot, idempotent developer setup for AMD Ryzen AI machines on Linux:
#    * Ryzen AI Max / Max+ 300  (Strix Halo,  Radeon 8050S/8060S, gfx1151, XDNA2)
#    * Ryzen AI 300 / 400       (Strix / Krackan / Gorgon Point, gfx1150/1152, XDNA2)
#    * Ryzen 7040/8040/200      (Phoenix / Hawk Point, gfx1103, XDNA1 - GPU only for LLM NPU)
#
#  What it sets up
#    GPU : ROCm (HIP, rocBLAS, hipBLASLt, MIOpen, MIGraphX, RCCL, rocprof...),
#          OpenCL, Vulkan (RADV), VA-API, GTT/TTM unified-memory tuning
#    NPU : amdxdna kernel driver check (in-tree >= 7.0 or DKMS), NPU firmware,
#          XRT runtime + xrt-smi, memlock limits, FastFlowLM (LLMs on the NPU),
#          optional IRON/MLIR-AIE (program the NPU directly), optional Ryzen AI SW
#    CPU : microcode, amd-pstate/EPP check, power profile, BLIS/libFLAME/OpenBLAS,
#          OpenMP/TBB, perf tools
#    AI  : Python venv with ROCm PyTorch for the detected gfx target,
#          ONNX/ONNX Runtime, HF transformers, Jupyter; Lemonade server
#          (GPU via llama.cpp ROCm/Vulkan, NPU via FastFlowLM); optional
#          llama.cpp source build (HIP + Vulkan); optional Docker
#    QA  : a verification suite (rerun any time with --verify)
#
#  Supported OS
#    Ubuntu 26.04 LTS / 26.10+  (recommended - ROCm + XRT straight from Ubuntu)
#    Ubuntu 24.04 LTS           (OEM/HWE kernel + AMD ROCm repo + Lemonade PPA)
#    Ubuntu 25.10               (best effort)
#
#  Usage:  sudo ./amd-ryzen-ai-setup.sh [options]      (see --help)
# =============================================================================

set -Eeuo pipefail
shopt -s nullglob

SCRIPT_VERSION="1.0.0"
SCRIPT_NAME="amd-ryzen-ai-setup"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"

# ----------------------------------------------------------------------------
# Defaults (override with flags or environment variables)
# ----------------------------------------------------------------------------
PROFILE="${PROFILE:-standard}"            # minimal | standard | full
ASSUME_YES="${ASSUME_YES:-0}"
DRY_RUN="${DRY_RUN:-0}"
ONLY_STAGES=""
SKIP_STAGES=""
TARGET_USER="${TARGET_USER:-${SUDO_USER:-}}"
ROCM_SOURCE="${ROCM_SOURCE:-auto}"        # auto | distro | amd | pip-only | none
ROCM_AMD_VERSION="${ROCM_AMD_VERSION:-latest}"  # e.g. 10.1 (AMD repo only)
GTT_GB="${GTT_GB:-auto}"                  # auto | <number> | 0 (= don't touch)
VENV_DIR="${VENV_DIR:-}"                  # default: ~TARGET_USER/amd-ai/venv
VENV_PYTHON="${VENV_PYTHON:-3.12}"        # python for the AI venv (via uv)
WITH_LEMONADE="${WITH_LEMONADE:-auto}"
WITH_FLM="${WITH_FLM:-auto}"
WITH_LLAMACPP="${WITH_LLAMACPP:-auto}"
WITH_IRON="${WITH_IRON:-auto}"
WITH_DOCKER="${WITH_DOCKER:-auto}"
WITH_PYTORCH="${WITH_PYTORCH:-auto}"
RYZEN_AI_SW_DIR="${RYZEN_AI_SW_DIR:-}"    # dir with AMD Ryzen AI SW downloads
APPLY_FIRMWARE_UPDATES="${APPLY_FIRMWARE_UPDATES:-0}"  # fwupd BIOS/EC updates
FORCE="${FORCE:-0}"
NO_UPGRADE="${NO_UPGRADE:-0}"
SRC_DIR="${SRC_DIR:-}"                    # default: ~TARGET_USER/amd-ai/src

LOG_DIR="/var/log/${SCRIPT_NAME}"
STATE_DIR="/var/lib/${SCRIPT_NAME}"
ENV_FILE="/etc/profile.d/amd-ryzen-ai.sh"
LOCK_FILE="/run/${SCRIPT_NAME}.lock"

ALL_STAGES="preflight base firmware kernel gpu memory npu cpu python lemonade llamacpp iron ryzenai docker finalize verify"

# Runtime state (stages run in subshells -> share notes/warnings/reboot flag via files)
RUN_TMP="$(mktemp -d /tmp/${SCRIPT_NAME}.XXXXXX)"
trap 'rm -rf "$RUN_TMP"' EXIT
OPTIONAL_STAGES=" lemonade llamacpp iron ryzenai docker "
declare -A VERIFY=()
declare -a VERIFY_ORDER=()

# ----------------------------------------------------------------------------
# Pretty output / logging
# ----------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[34m'; C_C=$'\e[36m'; C_0=$'\e[0m'; C_BOLD=$'\e[1m'
else
  C_R=""; C_G=""; C_Y=""; C_B=""; C_C=""; C_0=""; C_BOLD=""
fi
log()   { printf '%s[%s]%s %s\n' "$C_B" "$(date +%H:%M:%S)" "$C_0" "$*"; }
info()  { printf '%s  ->%s %s\n' "$C_C" "$C_0" "$*"; }
ok()    { printf '%s  OK%s %s\n' "$C_G" "$C_0" "$*"; }
warn()  { printf '%s WARN%s %s\n' "$C_Y" "$C_0" "$*" >&2; printf '%s\n' "$*" >> "$RUN_TMP/warnings"; }
err()   { printf '%sERROR%s %s\n' "$C_R" "$C_0" "$*" >&2; }
die()   { err "$*"; exit 1; }
stage() { printf '\n%s==== [%s] %s ====%s\n' "$C_BOLD" "$1" "${2:-}" "$C_0"; }
note()  { printf '%s\n' "$*" >> "$RUN_TMP/notes"; }
need_reboot() { : > "$RUN_TMP/reboot"; }

on_error() {
  local rc=$? line=${BASH_LINENO[0]} cmd=${BASH_COMMAND}
  err "Command failed (rc=$rc) at line $line: $cmd"
  err "Full log: ${LOG_FILE:-n/a}. Re-run the script; completed steps are skipped (idempotent)."
  exit "$rc"
}
trap on_error ERR

run() {   # run a command (or echo it in dry-run mode)
  if [[ "$DRY_RUN" == 1 ]]; then printf '%s  [dry-run]%s %s\n' "$C_Y" "$C_0" "$*"; return 0; fi
  "$@"
}

as_user() {  # run a bash snippet as the target (non-root) user with a login env
  local snippet="$1"
  if [[ "$DRY_RUN" == 1 ]]; then printf '%s  [dry-run as %s]%s %s\n' "$C_Y" "$TARGET_USER" "$C_0" "$snippet"; return 0; fi
  sudo -u "$TARGET_USER" -H env -u PYTHONPATH PATH="$USER_HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    HOME="$USER_HOME" bash -c "$snippet"
}

confirm() {
  [[ "$ASSUME_YES" == 1 ]] && return 0
  [[ -t 0 ]] || return 0
  local ans; read -r -p "$1 [Y/n] " ans || true
  [[ -z "$ans" || "$ans" =~ ^[Yy] ]]
}

retry() {  # retry <n> <cmd...>
  local n=$1; shift; local i
  for ((i=1; i<=n; i++)); do
    "$@" && return 0
    warn "Attempt $i/$n failed: $*"; sleep $((i*5))
  done
  return 1
}

download() {  # download <url> <dest>
  run retry 3 curl -fsSL --connect-timeout 20 --retry 3 -o "$2" "$1"
}

qgrep() { grep "$@" >/dev/null; }   # like grep -q but drains its input (no SIGPIPE false-negatives under pipefail)
version_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]; }

want() {  # want <feature-var-value> <default-for-profile-standard> <default-for-full>
  # resolves auto/1/0 against the profile
  local v="$1" std="$2" full="${3:-$2}"
  case "$v" in
    1|yes|true|on)  return 0 ;;
    0|no|false|off) return 1 ;;
  esac
  case "$PROFILE" in
    minimal)  return 1 ;;
    standard) [[ "$std" == 1 ]] ;;
    full)     [[ "$full" == 1 ]] ;;
  esac
}

stage_enabled() {
  local s="$1"
  if [[ -n "$ONLY_STAGES" ]]; then [[ ",$ONLY_STAGES," == *",$s,"* ]] || return 1; fi
  if [[ -n "$SKIP_STAGES" ]]; then [[ ",$SKIP_STAGES," == *",$s,"* ]] && return 1; fi
  return 0
}

write_file() {  # write_file <path> <mode> <content>  - only rewrites when changed; returns 0 if changed
  local path="$1" mode="$2" content="$3"
  if [[ -f "$path" ]] && [[ "$(cat "$path")" == "$content" ]]; then return 1; fi
  if [[ "$DRY_RUN" == 1 ]]; then info "[dry-run] would write $path"; return 0; fi
  install -d -m 0755 "$(dirname "$path")"
  printf '%s\n' "$content" > "$path"
  chmod "$mode" "$path"
  info "wrote $path"
  return 0
}

# ----------------------------------------------------------------------------
# apt helpers
# ----------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -q -o DPkg::Lock::Timeout=900 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
APT_UPDATED=0

apt_update() {
  if [[ "$APT_UPDATED" == 0 || "${1:-}" == force ]]; then
    run retry 3 apt-get -q -o DPkg::Lock::Timeout=900 update
    APT_UPDATED=1
  fi
}
pkg_available() { apt-cache show "$1" >/dev/null 2>&1 && [[ -n "$(apt-cache policy "$1" | awk '/Candidate:/ {print $2}' | grep -v '(none)')" ]]; }
pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | qgrep "install ok installed"; }

apt_install() {  # apt_install pkg... : installs those that exist; warns about the rest
  local p; local -a ok_pkgs=() missing=() todo=()
  for p in "$@"; do
    if pkg_installed "$p"; then ok_pkgs+=("$p")
    elif pkg_available "$p"; then todo+=("$p")
    else missing+=("$p"); fi
  done
  ((${#missing[@]})) && warn "Not available on this release, skipped: ${missing[*]}"
  if ((${#todo[@]})); then
    info "apt install: ${todo[*]}"
    run retry 2 apt-get install "${APT_OPTS[@]}" "${todo[@]}"
  fi
  return 0
}

add_apt_source() {  # add_apt_source <name> <deb822-content> [keyurl keyring]
  local name="$1" content="$2" keyurl="${3:-}" keyring="${4:-}"
  if [[ -n "$keyurl" && ! -s "$keyring" ]]; then
    run install -d -m 0755 "$(dirname "$keyring")"
    if [[ "$DRY_RUN" != 1 ]]; then
      retry 3 curl -fsSL "$keyurl" | gpg --dearmor --yes -o "$keyring"
      chmod 0644 "$keyring"
    fi
  fi
  if write_file "/etc/apt/sources.list.d/${name}.sources" 0644 "$content"; then apt_update force; fi
}

# ----------------------------------------------------------------------------
# Detection
# ----------------------------------------------------------------------------
detect_os() {
  [[ -r /etc/os-release ]] || die "/etc/os-release missing - unsupported OS"
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-unknown}"; OS_VER="${VERSION_ID:-0}"; OS_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
  OS_PRETTY="${PRETTY_NAME:-$OS_ID $OS_VER}"
  OS_FAMILY=other
  [[ "$OS_ID" == ubuntu || "${ID_LIKE:-}" == *ubuntu* ]] && OS_FAMILY=ubuntu
  [[ "$OS_FAMILY" == other && ( "$OS_ID" == debian || "${ID_LIKE:-}" == *debian* ) ]] && OS_FAMILY=debian
  # Ubuntu derivatives (Pop!_OS, Mint, Zorin...) report UBUNTU_CODENAME
  UBU_CODENAME="${UBUNTU_CODENAME:-$OS_CODENAME}"
  case "$UBU_CODENAME" in
    noble)    UBU_VER=24.04 ;;
    plucky)   UBU_VER=25.04 ;;
    questing) UBU_VER=25.10 ;;
    resolute) UBU_VER=26.04 ;;
    *)        UBU_VER="$OS_VER" ;;
  esac
  [[ "$OS_FAMILY" == ubuntu && "$OS_ID" != ubuntu ]] && [[ "$UBU_VER" != *.* ]] && UBU_VER=0
  KERNEL="$(uname -r)"; KERNEL_BASE="${KERNEL%%-*}"
}

detect_hw() {
  CPU_MODEL="$(awk -F': ' '/model name/ {print $2; exit}' /proc/cpuinfo)"
  CPU_VENDOR="$(awk -F': ' '/vendor_id/ {print $2; exit}' /proc/cpuinfo)"
  RAM_GB=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 / 1024 ))
  GPU_PCI_ID=""; GPU_NAME=""; GFX=""; GPU_FAMILY=""
  NPU_PCI_ID=""; NPU_GEN=""; NPU_NAME=""
  local line id
  while read -r line; do
    id="$(grep -oE '\[1002:[0-9a-f]{4}\]' <<<"$line" | tr -d '[]' | head -n1)"
    [[ -z "$id" ]] && continue
    GPU_PCI_ID="$id"; GPU_NAME="$(sed -E 's/^[^:]+: //' <<<"$line")"
    case "${id#1002:}" in
      1586)           GFX=gfx1151; GPU_FAMILY="Strix Halo (Radeon 8050S/8060S)" ;;
      150e)           GFX=gfx1150; GPU_FAMILY="Strix Point / Gorgon Point (Radeon 880M/890M)" ;;
      1114)           GFX=gfx1152; GPU_FAMILY="Krackan Point (Radeon 820M/840M/860M)" ;;
      15bf|15c8|1900|1901) GFX=gfx1103; GPU_FAMILY="Phoenix / Hawk Point (Radeon 740M/760M/780M)" ;;
      164e|1681)      GFX=gfx1036; GPU_FAMILY="Raphael/Rembrandt iGPU" ;;
      *)              GPU_FAMILY="other AMD GPU" ;;
    esac
    break
  done < <(lspci -nn 2>/dev/null | grep -E 'VGA|Display|3D' | grep -E '\[1002:')
  # Ask the kernel (KFD topology) for the authoritative gfx target if PCI map missed
  if [[ -z "$GFX" ]]; then
    local v
    for f in /sys/class/kfd/kfd/topology/nodes/*/properties; do
      v="$(awk '/gfx_target_version/ {print $2}' "$f")"
      [[ -n "$v" && "$v" != 0 ]] || continue
      GFX="gfx$((v/10000))$(printf '%x' $(((v/100)%100)))$(printf '%x' $((v%100)))"; break
    done
  fi
  line="$(lspci -nn 2>/dev/null | grep -E '\[1022:(1502|17f0)\]' | head -n1 || true)"
  if [[ -n "$line" ]]; then
    NPU_PCI_ID="$(grep -oE '\[1022:[0-9a-f]{4}\]' <<<"$line" | tr -d '[]')"
    NPU_NAME="$(sed -E 's/^[^:]+: //' <<<"$line")"
    case "$NPU_PCI_ID" in
      1022:1502) NPU_GEN=XDNA1 ;;   # aie2  - Phoenix / Hawk Point
      1022:17f0) NPU_GEN=XDNA2 ;;   # aie2p - Strix / Strix Halo / Krackan / Gorgon
    esac
  fi
  NPU_FW="$(cat /sys/bus/pci/drivers/amdxdna/*/fw_version 2>/dev/null | head -n1 || true)"
  VRAM_BYTES="$(cat /sys/class/drm/card*/device/mem_info_vram_total 2>/dev/null | sort -n | tail -n1 || echo 0)"
  GTT_BYTES="$(cat /sys/class/drm/card*/device/mem_info_gtt_total 2>/dev/null | sort -n | tail -n1 || echo 0)"
  SYS_VENDOR="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true)"
  PRODUCT="$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)"
  BIOS_VER="$(cat /sys/class/dmi/id/bios_version 2>/dev/null || true) ($(cat /sys/class/dmi/id/bios_date 2>/dev/null || true))"
  SECURE_BOOT=unknown
  if command -v mokutil >/dev/null; then
    mokutil --sb-state 2>/dev/null | qgrep -i 'enabled' && SECURE_BOOT=enabled || SECURE_BOOT=disabled
  fi
}

print_detection() {
  stage detect "System detection"
  printf '  %-14s %s\n' "Script" "$SCRIPT_NAME $SCRIPT_VERSION (profile: $PROFILE)" \
    "OS" "$OS_PRETTY [family=$OS_FAMILY ubuntu-base=$UBU_VER codename=$UBU_CODENAME]" \
    "Kernel" "$KERNEL" \
    "Machine" "$SYS_VENDOR $PRODUCT, BIOS $BIOS_VER" \
    "CPU" "$CPU_MODEL ($(nproc) threads)" \
    "RAM" "${RAM_GB} GiB visible to OS" \
    "GPU" "${GPU_NAME:-not found} -> ${GFX:-unknown gfx} ${GPU_FAMILY:+[$GPU_FAMILY]}" \
    "GPU memory" "VRAM carve-out $((VRAM_BYTES/1024/1024/1024)) GiB, GTT $((GTT_BYTES/1024/1024/1024)) GiB" \
    "NPU" "${NPU_NAME:-not found} ${NPU_GEN:+[$NPU_GEN]} ${NPU_FW:+fw $NPU_FW}" \
    "Secure Boot" "$SECURE_BOOT" \
    "Target user" "$TARGET_USER ($USER_HOME)"
}

# ----------------------------------------------------------------------------
# Stage: preflight
# ----------------------------------------------------------------------------
stage_preflight() {
  stage preflight "Sanity checks"
  [[ "$CPU_VENDOR" == AuthenticAMD ]] || { [[ "$FORCE" == 1 ]] && warn "Non-AMD CPU ($CPU_VENDOR) - continuing (--force)" || die "This is not an AMD CPU ($CPU_VENDOR). Use --force to continue anyway."; }
  if grep -qi microsoft /proc/version 2>/dev/null; then
    die "WSL detected. This script configures bare-metal Linux. For WSL use AMD's 'ROCm on WSL' guide."
  fi
  if systemd-detect-virt -q 2>/dev/null; then
    warn "Running inside a VM/container ($(systemd-detect-virt)). GPU/NPU passthrough is required for anything to work."
  fi
  case "$OS_FAMILY" in
    ubuntu)
      if ! version_ge "$UBU_VER" 24.04; then
        die "Ubuntu $UBU_VER is too old. Use Ubuntu 24.04 LTS or 26.04 LTS (recommended)."
      fi
      [[ "$UBU_VER" == 24.10 || "$UBU_VER" == 25.04 ]] && warn "Ubuntu $UBU_VER is EOL; upgrade to 26.04 LTS. Continuing best-effort."
      ;;
    debian) [[ "$FORCE" == 1 ]] || die "Debian is only partially supported (use --force). Recommended: Ubuntu 26.04 LTS." ;;
    *) die "Unsupported distribution '$OS_ID'. Fedora 43+/Arch ship ROCm+XRT natively; this script targets Ubuntu. Recommended: Ubuntu 26.04 LTS." ;;
  esac
  [[ -n "$GPU_PCI_ID" ]] || warn "No AMD GPU found by lspci."
  [[ -n "$GFX" ]] || warn "Could not determine the gfx target; ROCm library selection will fall back to generic."
  [[ -n "$NPU_PCI_ID" ]] || warn "No AMD NPU found by lspci. If this is a Ryzen AI part, enable the NPU / 'IPU' in BIOS."
  if [[ "$NPU_GEN" == XDNA1 ]]; then
    warn "XDNA1 NPU (Phoenix/Hawk Point): FastFlowLM/Lemonade LLM-on-NPU requires XDNA2. XRT + IRON will still be installed."
  fi
  if grep -qw 'amd_iommu=off' /proc/cmdline; then
    warn "Kernel cmdline contains amd_iommu=off - this DISABLES the NPU (amdxdna needs IOMMU/SVA). Remove it from GRUB_CMDLINE_LINUX in /etc/default/grub."
  fi
  local free_gb; free_gb=$(df -BG --output=avail / | tail -1 | tr -dc 0-9)
  (( free_gb >= 40 )) || warn "Only ${free_gb} GiB free on / ; a full install needs ~40 GiB (models need more)."
  ((free_gb >= 15)) || [[ "$FORCE" == 1 ]] || die "Less than 15 GiB free on /. Free space or use --force."
  if ! curl -fsS --max-time 15 -o /dev/null https://archive.ubuntu.com/ 2>/dev/null && \
     ! curl -fsS --max-time 15 -o /dev/null https://github.com 2>/dev/null; then
    die "No internet connectivity (honours http_proxy/https_proxy env vars)."
  fi
  if [[ "$VRAM_BYTES" -gt $((8*1024*1024*1024)) && "$RAM_GB" -ge 32 ]]; then
    note "BIOS reserves $((VRAM_BYTES/1024/1024/1024)) GiB as dedicated VRAM. For large LLMs AMD recommends a small carve-out (e.g. 512 MB-2 GB) and a large GTT (configured by this script). Change 'UMA Frame Buffer Size' in BIOS if needed."
  fi
  ok "preflight passed"
}

# ----------------------------------------------------------------------------
# Stage: base
# ----------------------------------------------------------------------------
stage_base() {
  stage base "Base system, build tools, Python tooling"
  if [[ "$OS_FAMILY" == ubuntu ]]; then
    # make sure universe/multiverse are enabled (ROCm + XRT live in universe)
    if ! grep -rqsE '^(Components:.*universe|deb .* universe)' /etc/apt/sources.list /etc/apt/sources.list.d/; then
      apt_install software-properties-common
      run add-apt-repository -y universe
      run add-apt-repository -y multiverse || true
      APT_UPDATED=0
    fi
  fi
  apt_update force
  if [[ "$NO_UPGRADE" != 1 ]]; then
    info "Upgrading installed packages (kernel, firmware, mesa updates matter for AMD)"
    local before; before="$(ls /boot/vmlinuz-* 2>/dev/null | sort)"
    run apt-get full-upgrade "${APT_OPTS[@]}"
    [[ "$before" != "$(ls /boot/vmlinuz-* 2>/dev/null | sort)" ]] && need_reboot
  fi
  apt_install build-essential cmake ninja-build pkg-config git git-lfs curl wget ca-certificates gnupg \
    jq unzip zstd xz-utils file pciutils usbutils lshw dmidecode mokutil software-properties-common \
    python3 python3-venv python3-pip python3-dev pipx ccache gdb strace lsof
  # uv (fast Python/venv manager) for the target user
  if ! as_user 'command -v uv >/dev/null 2>&1'; then
    as_user 'pipx install uv >/dev/null 2>&1 || pipx upgrade uv >/dev/null 2>&1 || true; pipx ensurepath >/dev/null 2>&1 || true'
  fi
  as_user 'git lfs install --skip-repo >/dev/null 2>&1 || true'
  ok "base done"
}

# ----------------------------------------------------------------------------
# Stage: firmware
# ----------------------------------------------------------------------------
stage_firmware() {
  stage firmware "CPU microcode, GPU/NPU firmware, BIOS (fwupd/LVFS)"
  apt_install linux-firmware amd64-microcode fwupd
  # Ubuntu 24.10+ splits AMD firmware into sub-packages
  pkg_available linux-firmware-amd-graphics && apt_install linux-firmware-amd-graphics
  pkg_available linux-firmware-amd-misc && apt_install linux-firmware-amd-misc
  local d; local -a npufw=(/lib/firmware/amdnpu/*/)
  if ((${#npufw[@]})); then
    for d in "${npufw[@]}"; do info "NPU firmware present: $(basename "$d"): $(ls "$d" | tr '\n' ' ')"; done
  else
    warn "No /lib/firmware/amdnpu found - NPU firmware missing; linux-firmware is too old."
  fi
  if [[ -n "$NPU_FW" ]] && ! version_ge "$NPU_FW" 1.1.0.0 && [[ "$NPU_GEN" == XDNA2 ]]; then
    warn "Loaded NPU firmware $NPU_FW < 1.1.0.0 (needed by FastFlowLM). It is updated after reboot into a newer kernel/linux-firmware."
  fi
  if command -v fwupdmgr >/dev/null; then
    info "Checking LVFS for BIOS/EC/dock firmware updates"
    run fwupdmgr refresh --force >/dev/null 2>&1 || true
    local upd; upd="$(fwupdmgr get-updates --no-unreported-check 2>/dev/null || true)"
    if grep -qiE 'New version|Upgrade|→' <<<"$upd"; then
      if [[ "$APPLY_FIRMWARE_UPDATES" == 1 ]]; then
        warn "Applying firmware updates via fwupd (machine may reboot into the updater)."
        run fwupdmgr update -y --no-reboot-check || warn "fwupd update failed"
        need_reboot
      else
        note "Firmware updates are available from LVFS. Review with 'fwupdmgr get-updates' and apply with 'fwupdmgr update' (or re-run with --apply-firmware-updates). Also check the OEM support site for BIOS updates."
      fi
    else
      info "fwupd: no LVFS updates listed (OEM BIOS updates may still exist on the vendor site)"
    fi
  fi
  ok "firmware done"
}

# ----------------------------------------------------------------------------
# Stage: kernel
# ----------------------------------------------------------------------------
stage_kernel() {
  stage kernel "Kernel requirements (amdgpu for ROCm, amdxdna for NPU)"
  # Strix Halo ROCm needs kernel fixes: Ubuntu 24.04 HWE >= 6.17.0-19 / OEM >= 6.14.0-1018, upstream >= 6.18.4.
  # NPU via in-tree amdxdna needs >= 6.14; FastFlowLM wants >= 7.0 (or amdxdna-dkms).
  local newest; newest="$(ls /boot/vmlinuz-* 2>/dev/null | sed 's#.*/vmlinuz-##' | sort -V | tail -n1)"
  info "running kernel $KERNEL, newest installed ${newest:-?}"
  if [[ "$OS_FAMILY" == ubuntu && "$UBU_VER" == 24.04 ]]; then
    # prefer the HWE kernel (6.17+). OEM 6.14 is the AMD-documented alternative.
    if ! version_ge "${newest%%-*}" 6.17; then
      info "Installing Ubuntu 24.04 HWE kernel (>= 6.17) for Strix/Strix Halo support"
      apt_install linux-generic-hwe-24.04
      local n2; n2="$(ls /boot/vmlinuz-* | sed 's#.*/vmlinuz-##' | sort -V | tail -n1)"
      if ! version_ge "${n2%%-*}" 6.17; then
        info "HWE kernel not new enough; installing OEM kernel linux-oem-24.04d"
        apt_install linux-oem-24.04d
      fi
      need_reboot
    fi
  fi
  if ! version_ge "$KERNEL_BASE" 6.14; then
    warn "Running kernel $KERNEL_BASE < 6.14: no in-tree NPU driver and incomplete Strix support. Reboot into the newest kernel after setup."
    need_reboot
  fi
  if modinfo amdgpu >/dev/null 2>&1; then ok "amdgpu module available"; else warn "amdgpu module missing for $KERNEL"; fi
  if modinfo amdxdna >/dev/null 2>&1; then ok "amdxdna module available ($(modinfo -F filename amdxdna))"; else info "amdxdna not in this kernel (DKMS will be used in the npu stage)"; fi
  # amdgpu DKMS from AMD is NOT needed (and is discouraged) for Ryzen APUs - inbox driver is used.
  if pkg_installed amdgpu-dkms; then
    warn "amdgpu-dkms is installed. AMD recommends the inbox kernel driver for Ryzen APUs; consider 'apt purge amdgpu-dkms'."
  fi
  ok "kernel done"
}

# ----------------------------------------------------------------------------
# Stage: gpu (ROCm / OpenCL / Vulkan)
# ----------------------------------------------------------------------------
resolve_rocm_source() {
  if [[ "$ROCM_SOURCE" == auto ]]; then
    if [[ "$OS_FAMILY" == ubuntu ]] && pkg_available rocm-dev && version_ge "$UBU_VER" 26.04; then
      ROCM_SOURCE=distro     # Canonical-packaged ROCm (26.04+)
    elif [[ "$OS_FAMILY" == ubuntu && ( "$UBU_VER" == 24.04 || "$UBU_VER" == 26.04 ) ]]; then
      ROCM_SOURCE=amd
    else
      ROCM_SOURCE=pip-only   # ROCm is still available to Python via AMD's wheels
    fi
  fi
}

install_rocm_amd_repo() {
  local repo_dist
  case "$UBU_VER" in 24.04) repo_dist=ubuntu2404 ;; 26.04) repo_dist=ubuntu2604 ;; 22.04) repo_dist=ubuntu2204 ;;
    *) repo_dist=ubuntu2604; warn "No AMD ROCm repo for Ubuntu $UBU_VER - trying ubuntu2604 packages" ;; esac
  apt_install libatomic1 libquadmath0
  add_apt_source amdrocm-stable "Types: deb
URIs: https://stable.repo.amd.com/rocm/core/packages/${repo_dist}/
Suites: stable
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/amdrocm.gpg" https://stable.repo.amd.com/rocm/gpg/packages.gpg /etc/apt/keyrings/amdrocm.gpg
  apt_update
  local ver="$ROCM_AMD_VERSION" g="${GFX:-}"
  if [[ "$ver" == latest ]]; then
    ver="$(apt-cache pkgnames amdrocm 2>/dev/null | grep -oE '^amdrocm[0-9]+\.[0-9]+$' | sed 's/amdrocm//' | sort -V | tail -n1)"
    [[ -n "$ver" ]] || die "Could not find amdrocm packages in the AMD repo"
  fi
  local -a pk=("amdrocm${ver}")
  if [[ -n "$g" ]] && pkg_available "amdrocm${ver}-${g}"; then pk=("amdrocm${ver}-${g}"); fi
  if [[ -n "$g" ]] && pkg_available "amdrocm-core-dev${ver}-${g}"; then pk+=("amdrocm-core-dev${ver}-${g}")
  elif pkg_available "amdrocm-core-dev${ver}"; then pk+=("amdrocm-core-dev${ver}"); fi
  info "Installing AMD ROCm ${ver} for ${g:-generic}: ${pk[*]}"
  apt_install "${pk[@]}"
}

detect_rocm_root() {
  local r
  if command -v rocminfo >/dev/null; then r="$(dirname "$(dirname "$(readlink -f "$(command -v rocminfo)")")")"
  else r="$(ls -d /opt/rocm*/bin/rocminfo 2>/dev/null | sort -V | tail -n1)"; r="${r%/bin/rocminfo}"; fi
  ROCM_ROOT="${r:-}"
}

stage_gpu() {
  stage gpu "GPU stack: ROCm/HIP, OpenCL, Vulkan, VA-API"
  case "$ROCM_SOURCE" in
    distro)
      apt_install rocm-dev rocminfo amd-smi rocm-smi hipify-clang migraphx migraphx-dev \
        libhipblaslt-dev librocwmma-dev libcomposable-kernel-dev rocm-cmake
      # ROCm OpenCL conflicts with mesa-opencl-icd (rusticl); prefer ROCm's for compute
      if pkg_installed mesa-opencl-icd; then info "replacing mesa-opencl-icd with rocm-opencl-icd"; fi
      apt_install rocm-opencl-icd
      ;;
    amd)      install_rocm_amd_repo ;;
    pip-only) note "System ROCm packages are not available for this release; ROCm is provided to Python through AMD's wheels (python stage)." ;;
    none)     info "ROCm skipped (--rocm-source none)" ;;
  esac
  apt_install mesa-vulkan-drivers vulkan-tools libvulkan-dev glslang-tools glslc spirv-tools \
    clinfo ocl-icd-opencl-dev mesa-va-drivers vainfo radeontop nvtop
  # GPU access for the user
  local g changed=0
  for g in render video; do
    getent group "$g" >/dev/null || run groupadd -r "$g"
    if ! id -nG "$TARGET_USER" | tr ' ' '\n' | qgrep -x "$g"; then run usermod -aG "$g" "$TARGET_USER"; changed=1; fi
  done
  if ((changed)); then need_reboot; note "User $TARGET_USER added to render,video groups (log out/in or reboot)."; fi
  # udev: make sure kfd/render/accel nodes are group render (some images ship 0600/video)
  if write_file /etc/udev/rules.d/70-amd-ryzen-ai.rules 0644 '# amd-ryzen-ai-setup: GPU compute + NPU device access for group "render"
KERNEL=="kfd", GROUP="render", MODE="0660"
SUBSYSTEM=="drm", KERNEL=="renderD*", GROUP="render", MODE="0660"
SUBSYSTEM=="accel", KERNEL=="accel*", GROUP="render", MODE="0660"'; then
    run udevadm control --reload-rules || true
    run udevadm trigger --subsystem-match=drm --subsystem-match=accel --subsystem-match=kfd || true
  fi
  ok "gpu done"
}

# ----------------------------------------------------------------------------
# Stage: memory (GTT/TTM: how much system RAM the iGPU may use)
# ----------------------------------------------------------------------------
stage_memory() {
  stage memory "Unified memory: GTT/TTM limits for the iGPU"
  local total_kb gb pages
  total_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
  if [[ "$GTT_GB" == 0 ]]; then info "GTT tuning skipped (--gtt-gb 0)"; return 0; fi
  if [[ "$GTT_GB" == auto ]]; then
    # leave headroom for the OS: max(8 GiB, 12.5%) ; only worth it on >= 32 GiB machines
    local tot_gb=$((total_kb/1024/1024)) reserve
    reserve=$(( tot_gb/8 > 8 ? tot_gb/8 : 8 ))
    gb=$(( tot_gb - reserve ))
    if (( tot_gb < 32 )); then info "Only ${tot_gb} GiB RAM - keeping kernel default GTT (50%)"; return 0; fi
  else
    gb="$GTT_GB"
    local max_gb=$(( total_kb/1024/1024 - 4 ))
    if (( gb > max_gb )); then warn "--gtt-gb $gb exceeds usable RAM; clamping to ${max_gb} GiB"; gb=$max_gb; fi
  fi
  pages=$(( gb * 1024 * 1024 / 4 ))   # 4 KiB pages
  info "Allowing the GPU to map up to ${gb} GiB of system RAM (ttm pages_limit=${pages})"
  # Same file amd-ttm (amd-debug-tools) manages, so the two tools stay consistent.
  if write_file /etc/modprobe.d/ttm.conf 0644 "# amd-ryzen-ai-setup: GPU-addressable system memory = ${gb} GiB (change with: amd-ttm --set <GB>)
options ttm pages_limit=${pages} page_pool_size=${pages}"; then
    regen_initramfs
    need_reboot
  fi
  apt_install amd-debug-tools || true
  ok "memory done (effective after reboot)"
}

regen_initramfs() {
  if command -v update-initramfs >/dev/null; then run update-initramfs -u -k all
  elif command -v dracut >/dev/null; then run dracut --regenerate-all -f; fi
}

# ----------------------------------------------------------------------------
# Stage: npu (amdxdna + XRT + firmware + limits + FastFlowLM)
# ----------------------------------------------------------------------------
LEMONADE_PPA_SUITES="noble questing resolute"
LEMONADE_PPA_FPR_FALLBACK="881CF4B40B0BFA288D6776E83BF36CFA0BD50AEC"   # ppa:lemonade-team/stable signing key
add_lemonade_ppa() {   # Lemonade team PPA: XRT, amdxdna-dkms, lemonade-server for Ubuntu
  local suite="$UBU_CODENAME" pin_only_lemonade=0
  if [[ " $LEMONADE_PPA_SUITES " != *" $suite "* ]]; then
    suite=resolute; pin_only_lemonade=1
    info "Lemonade PPA has no '$UBU_CODENAME' suite; using '$suite' pinned to lemonade packages only"
  fi
  local fpr; fpr="$(lemonade_ppa_fpr)"; fpr="${fpr:-$LEMONADE_PPA_FPR_FALLBACK}"
  add_apt_source lemonade-team-stable "Types: deb
URIs: https://ppa.launchpadcontent.net/lemonade-team/stable/ubuntu/
Suites: ${suite}
Components: main
Signed-By: /etc/apt/keyrings/lemonade-team.gpg" \
    "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${fpr}" /etc/apt/keyrings/lemonade-team.gpg
  if ((pin_only_lemonade)); then
    # specific record first; 600 beats the (older) lemonade-server in the Ubuntu archive
    write_file /etc/apt/preferences.d/lemonade-team-stable 0644 "# amd-ryzen-ai-setup: only take Lemonade itself from the (foreign-suite) PPA; everything else from Ubuntu
Package: lemonade-server lemonade-desktop
Pin: release o=LP-PPA-lemonade-team-stable
Pin-Priority: 600

Package: *
Pin: release o=LP-PPA-lemonade-team-stable
Pin-Priority: -1" && apt_update force
  else
    run rm -f /etc/apt/preferences.d/lemonade-team-stable
  fi
  return 0
}
lemonade_ppa_fpr() {
  curl -fsSL https://api.launchpad.net/1.0/~lemonade-team/+archive/ubuntu/stable 2>/dev/null \
    | jq -r '.signing_key_fingerprint // empty' 2>/dev/null || true
}

stage_npu() {
  stage npu "NPU: amdxdna driver, XRT runtime, limits"
  if [[ -z "$NPU_PCI_ID" ]]; then warn "No NPU detected - skipping NPU stage"; return 0; fi
  # 1) Kernel driver: in-tree (>= 6.14; 7.0+ recommended) or DKMS from the Lemonade PPA
  local need_dkms=0
  if ! modinfo amdxdna >/dev/null 2>&1; then need_dkms=1
  elif ! version_ge "$KERNEL_BASE" 7.0 && [[ "$NPU_GEN" == XDNA2 ]]; then
    need_dkms=1; info "In-tree amdxdna on $KERNEL_BASE predates the protocol-7 firmware FastFlowLM expects; using amdxdna-dkms"
  fi
  # 2) XRT userspace: Ubuntu 26.04+ ships it (libxrt-npu2); otherwise the Lemonade PPA
  if ! pkg_available libxrt-npu2 || ((need_dkms)); then add_lemonade_ppa; fi
  apt_install libxrt2 libxrt-npu2 libxrt-utils libxrt-utils-npu libxrt-dev python3-xrt
  if ((need_dkms)); then
    apt_install dkms "linux-headers-$(uname -r)"
    [[ "$SECURE_BOOT" == enabled ]] && warn "Secure Boot is enabled: DKMS modules must be signed. Ubuntu will ask you to enroll a MOK key at next boot (choose 'Enroll MOK' and enter the password set during install)."
    apt_install amdxdna-dkms
    need_reboot
  fi
  # 3) memlock: NPU buffers are pinned; XRT/FLM fail with small RLIMIT_MEMLOCK
  local changed=0
  write_file /etc/security/limits.d/99-amd-npu.conf 0644 "# amd-ryzen-ai-setup: NPU (XRT) needs to pin large buffers
*    soft    memlock    unlimited
*    hard    memlock    unlimited
root soft    memlock    unlimited
root hard    memlock    unlimited" && changed=1
  # desktop sessions/services get limits from systemd, not PAM
  write_file /etc/systemd/system.conf.d/99-amd-npu-memlock.conf 0644 "[Manager]
DefaultLimitMEMLOCK=infinity" && changed=1
  write_file /etc/systemd/user.conf.d/99-amd-npu-memlock.conf 0644 "[Manager]
DefaultLimitMEMLOCK=infinity" && changed=1
  if ((changed)); then need_reboot; run systemctl daemon-reexec || true; fi
  # 4) xrt-smi validate test archive (not shipped in the distro packages; AMD VTD repo)
  install_vtd_archive
  # 5) FastFlowLM (LLMs on the XDNA2 NPU)
  if [[ "$NPU_GEN" == XDNA2 ]] && want "$WITH_FLM" 1 1; then install_flm; fi
  ok "npu done"
}

install_vtd_archive() {
  command -v xrt-smi >/dev/null || return 0
  local ver arch dir
  # run as the user: xrt-smi needs the (new) unlimited memlock, which a fresh PAM session gets
  ver="$(as_user 'xrt-smi --version 2>&1' | awk -F': *' '/XRT build version|^ *Version *:/ {print $2; exit}' | tr -d ' ')"
  [[ -n "$ver" ]] || { warn "could not read XRT version; skipping xrt-smi validate archive"; return 0; }
  case "$NPU_GEN" in XDNA2) arch=strx ;; XDNA1) arch=phx ;; *) return 0 ;; esac
  dir="$USER_HOME/.local/share/xrt/$ver/amdxdna/bins"
  if [[ -s "$dir/xrt_smi_${arch}.a" ]]; then ok "xrt-smi validate archive present ($arch, XRT $ver)"; return 0; fi
  info "Installing xrt-smi validate archive xrt_smi_${arch}.a for XRT $ver"
  as_user "mkdir -p '$dir' && curl -fsSL --retry 3 -o '$dir/xrt_smi_${arch}.a.tmp' https://raw.githubusercontent.com/Xilinx/VTD/main/archive/${arch}/xrt_smi_${arch}.a && mv '$dir/xrt_smi_${arch}.a.tmp' '$dir/xrt_smi_${arch}.a'" \
    || warn "could not download xrt-smi validate archive (xrt-smi validate will not work)"
}

install_flm() {
  if command -v flm >/dev/null && [[ "${FLM_UPGRADE:-0}" != 1 ]]; then ok "FastFlowLM already installed ($(flm version 2>/dev/null | head -n1 || echo flm))"; return 0; fi
  local rel tag url asset distro_tag tmp
  rel="$(curl -fsSL https://api.github.com/repos/ROCm/FastFlowLM/releases/latest 2>/dev/null || true)"
  [[ -n "$rel" ]] || { warn "Could not query FastFlowLM releases (GitHub API). Lemonade can still auto-install FLM."; return 0; }
  tag="$(jq -r .tag_name <<<"$rel")"
  case "$UBU_VER" in 24.04) distro_tag=ubuntu24.04 ;; 25.10) distro_tag=ubuntu25.10 ;; 26.04) distro_tag=ubuntu26.04 ;; *) distro_tag=ubuntu26.04 ;; esac
  [[ "$OS_FAMILY" == debian ]] && distro_tag=debian13
  url="$(jq -r --arg t "_${distro_tag}_amd64.deb" '.assets[] | select(.name|endswith($t)) | select(.name|startswith("fastflowlm_")) | .browser_download_url' <<<"$rel" | head -n1)"
  [[ -n "$url" ]] || { warn "No FastFlowLM .deb for $distro_tag in $tag"; return 0; }
  tmp="$(mktemp -d)"; asset="$tmp/$(basename "$url")"
  info "Installing FastFlowLM $tag ($distro_tag)"
  download "$url" "$asset"
  chmod 755 "$tmp"; chmod 644 "$asset"
  run apt-get install "${APT_OPTS[@]}" "$asset"
  rm -rf "$tmp"
  note "FastFlowLM $tag installed: try 'flm validate', 'flm list', 'flm run llama3.2:1b'."
}

# ----------------------------------------------------------------------------
# Stage: cpu
# ----------------------------------------------------------------------------
stage_cpu() {
  stage cpu "CPU: amd-pstate, power profile, math libraries, profilers"
  apt_install libblis-dev libflame-dev libopenblas-dev liblapacke-dev libomp-dev libtbb-dev libnuma-dev hwloc \
    linux-tools-common "linux-tools-$(uname -r)" linux-tools-generic htop btop stress-ng lm-sensors
  local drv mode
  drv="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null || echo none)"
  mode="$(cat /sys/devices/system/cpu/amd_pstate/status 2>/dev/null || echo n/a)"
  info "cpufreq driver: $drv, amd_pstate mode: $mode"
  if [[ "$drv" != amd-pstate* ]]; then
    warn "amd-pstate is not active (driver=$drv). Enable CPPC in BIOS; kernel >= 6.5 uses amd-pstate-epp by default."
  fi
  # power profile: 'performance' for a dev workstation (plugged in). Laptops keep 'balanced'.
  local chassis; chassis="$(cat /sys/class/dmi/id/chassis_type 2>/dev/null || echo 0)"
  if command -v powerprofilesctl >/dev/null; then
    if [[ "$chassis" =~ ^(3|4|5|6|7|13|15|16|35|36)$ ]]; then   # desktop / tower / mini / all-in-one
      run powerprofilesctl set performance && info "power profile -> performance (desktop chassis)" || true
    else
      info "laptop/other chassis: keeping current power profile ($(powerprofilesctl get 2>/dev/null))"
    fi
  else
    apt_install power-profiles-daemon
  fi
  # BLIS is AMD's (AOCL) BLAS upstream; make it the system BLAS/LAPACK choice where possible
  local blas
  blas="$(update-alternatives --list libblas.so.3-x86_64-linux-gnu 2>/dev/null | grep -m1 blis || true)"
  [[ -n "$blas" ]] && run update-alternatives --set libblas.so.3-x86_64-linux-gnu "$blas" >/dev/null 2>&1 || true
  run sensors-detect --auto >/dev/null 2>&1 || true
  note "AMD AOCL (AOCC compiler, AOCL-BLAS/LAPACK/FFTW tuned for Zen 5) and ZenDNN/zentorch need an EULA download from amd.com/developer; BLIS/libFLAME (the open versions of AOCL BLAS/LAPACK) are installed."
  ok "cpu done"
}

# ----------------------------------------------------------------------------
# Stage: python (AI venv with ROCm PyTorch)
# ----------------------------------------------------------------------------
pick_torch_index() {
  local g="${GFX:-gfx1151}" u
  for u in "https://repo.amd.com/rocm/whl/${g}/" "https://rocm.nightlies.amd.com/v2/${g}/" ; do
    if curl -fsS --max-time 20 "${u}torch/" 2>/dev/null | qgrep 'torch-'; then echo "$u"; return 0; fi
  done
  # family indexes (gfx115x / gfx110x) as fallback
  case "$g" in gfx115*) u="https://rocm.nightlies.amd.com/v2/gfx1151/" ;; gfx110*) u="https://rocm.nightlies.amd.com/v2/gfx110X-all/" ;; *) u="" ;; esac
  [[ -n "$u" ]] && curl -fsS --max-time 20 "${u}torch/" 2>/dev/null | qgrep 'torch-' && { echo "$u"; return 0; }
  echo ""
}

stage_python() {
  stage python "Python AI environment (ROCm PyTorch, ONNX, HF, Jupyter)"
  want "$WITH_PYTORCH" 1 1 || { info "skipped"; return 0; }
  local venv="${VENV_DIR:-$USER_HOME/amd-ai/venv}" idx
  as_user "command -v uv >/dev/null" || as_user 'pipx install uv >/dev/null'
  if [[ ! -x "$venv/bin/python" ]]; then
    info "Creating venv $venv (Python $VENV_PYTHON via uv)"
    as_user "mkdir -p '$(dirname "$venv")' && uv venv --seed --python '$VENV_PYTHON' '$venv'"
  fi
  idx="$(pick_torch_index)"
  if [[ -n "$idx" ]]; then
    if ! as_user "'$venv/bin/python' -c 'import torch,sys; sys.exit(0 if torch.version.hip else 1)' 2>/dev/null"; then
      info "Installing ROCm PyTorch from $idx"
      as_user "VIRTUAL_ENV='$venv' uv pip install --python '$venv/bin/python' --index-url '$idx' torch torchvision torchaudio"
    fi
  else
    warn "No ROCm PyTorch wheel index found for ${GFX:-unknown}; installing CPU PyTorch"
    as_user "uv pip install --python '$venv/bin/python' --index-url https://download.pytorch.org/whl/cpu torch torchvision torchaudio"
  fi
  # Everything else from PyPI (torch already satisfied, so it is not replaced)
  as_user "uv pip install --python '$venv/bin/python' numpy pandas scipy matplotlib pillow tqdm \
    transformers accelerate datasets safetensors sentencepiece huggingface_hub \
    onnx onnxruntime onnxscript jupyterlab ipykernel ipywidgets openai"
  as_user "'$venv/bin/python' -m ipykernel install --user --name amd-ai --display-name 'Python (amd-ai ROCm)' >/dev/null 2>&1 || true"
  note "AI venv: source $venv/bin/activate   (torch.cuda.* APIs map to the AMD GPU via HIP)"
  ok "python done"
}

# ----------------------------------------------------------------------------
# Stage: lemonade (local LLM server: GPU via llama.cpp ROCm/Vulkan, NPU via FLM)
# ----------------------------------------------------------------------------
LEMONADE_PORT="${LEMONADE_PORT:-13305}"
lemonade_backend_installed() {  # <recipe:backend>
  lemonade backends 2>/dev/null | awk '/^[a-z]/ {r=$1; print r":"$2, $5; next} /^ +[a-z]/ {print r":"$1, $4}' | qgrep -x "$1 installed"
}
lemonade_health() { curl -fsS --max-time 5 "http://localhost:${LEMONADE_PORT}/api/v1/health" 2>/dev/null | qgrep '"status":"ok"'; }

stage_lemonade() {
  stage lemonade "Lemonade server (OpenAI-compatible local LLM server; GPU + NPU)"
  want "$WITH_LEMONADE" 1 1 || { info "skipped"; return 0; }
  if ! pkg_installed lemonade-server; then
    add_lemonade_ppa
    apt_install lemonade-server
  fi
  if pkg_installed lemonade-server; then
    # system service 'lemond' runs as user 'lemonade' -> needs GPU/NPU device access
    if id lemonade >/dev/null 2>&1 && ! id -nG lemonade | tr ' ' '\n' | qgrep -x render; then
      run usermod -aG render,video lemonade
    fi
    run systemctl daemon-reexec || true          # pick up DefaultLimitMEMLOCK for the service
    run systemctl enable lemond.service >/dev/null 2>&1 || true
    run systemctl restart lemond.service || warn "could not (re)start lemond.service"
    local i
    for i in $(seq 1 30); do lemonade_health && break; sleep 2; done
    lemonade_health || { warn "lemond is not answering on :${LEMONADE_PORT}"; return 0; }
    # pre-install the core backends: GPU (llama.cpp ROCm + Vulkan) and NPU (FastFlowLM)
    local -a backends=(llamacpp:rocm llamacpp:vulkan)
    [[ "$NPU_GEN" == XDNA2 ]] && backends+=(flm:npu)
    local b
    for b in "${backends[@]}"; do
      if lemonade_backend_installed "$b"; then
        ok "lemonade backend $b already installed"; continue
      fi
      info "lemonade backends install $b"
      # llamacpp:rocm pulls AMD's ROCm pip wheels for this gfx target (several GB) - allow time
      run timeout 5400 lemonade backends install "$b" >/dev/null 2>&1 || true
      lemonade_backend_installed "$b" || warn "lemonade backend $b not installed yet (it may still be downloading inside lemond; check later with 'lemonade backends' or retry: lemonade backends install $b)"
    done
    note "Lemonade: http://localhost:${LEMONADE_PORT} (web UI + OpenAI-compatible API at /v1). CLI: 'lemonade run <model>', 'lemonade backends'. Service: systemctl status lemond"
  else
    warn "Lemonade not installed (package unavailable). See https://lemonade-server.ai"
  fi
  ok "lemonade done"
}

# ----------------------------------------------------------------------------
# Stage: llamacpp (source build with HIP + Vulkan for development)
# ----------------------------------------------------------------------------
stage_llamacpp() {
  stage llamacpp "llama.cpp source build (HIP/ROCm + Vulkan backends)"
  want "$WITH_LLAMACPP" 0 1 || { info "skipped (enable with --with-llamacpp)"; return 0; }
  [[ "$ROCM_SOURCE" == distro || "$ROCM_SOURCE" == amd ]] || { warn "llama.cpp HIP build needs system ROCm; building Vulkan only"; }
  apt_install libssl-dev spirv-headers libshaderc-dev glslc
  local src="${SRC_DIR:-$USER_HOME/amd-ai/src}/llama.cpp" hip=OFF
  [[ "$ROCM_SOURCE" == distro || "$ROCM_SOURCE" == amd ]] && hip=ON
  as_user "mkdir -p '$(dirname "$src")'; if [[ -d '$src/.git' ]]; then git -C '$src' pull --ff-only -q; else git clone -q --depth 1 https://github.com/ggml-org/llama.cpp '$src'; fi"
  as_user "cd '$src' && cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DGGML_HIP=$hip -DGPU_TARGETS='${GFX:-gfx1151}' -DGGML_HIP_ROCWMMA_FATTN=$hip \
      -DGGML_VULKAN=ON -DGGML_NATIVE=ON >/dev/null && cmake --build build -j\$(nproc) >/dev/null"
  note "llama.cpp built at $src/build/bin (llama-cli, llama-server, llama-bench). Use '--device ROCm0' or '--device Vulkan0'."
  ok "llamacpp done"
}

# ----------------------------------------------------------------------------
# Stage: iron (MLIR-AIE / IRON: program the NPU directly)
# ----------------------------------------------------------------------------
stage_iron() {
  stage iron "IRON / MLIR-AIE NPU programming toolchain"
  want "$WITH_IRON" 0 1 || { info "skipped (enable with --with-iron)"; return 0; }
  [[ -n "$NPU_PCI_ID" ]] || { warn "no NPU - skipping"; return 0; }
  apt_install clang lld uuid-dev libopencv-dev python3-opencv
  local src="${SRC_DIR:-$USER_HOME/amd-ai/src}/mlir-aie" venv tag ver sys_py_ver
  venv="$src/ironenv"
  # 1) newest release tag -> the mlir_aie wheel, peano pin and examples all match exactly
  tag="$(curl -fsSL https://api.github.com/repos/Xilinx/mlir-aie/releases/latest 2>/dev/null | jq -r '.tag_name // empty')"
  [[ -n "$tag" ]] || { warn "could not query mlir-aie releases (GitHub API)"; return 0; }
  ver="${tag#v}"
  if as_user "[[ -d '$src/.git' ]] && [[ \"\$(git -C '$src' describe --tags --exact-match 2>/dev/null)\" == '$tag' ]]"; then
    ok "mlir-aie $tag already checked out"
  else
    # shallow clone (full history is several GB)
    as_user "rm -rf '$src' && mkdir -p '$(dirname "$src")' && git -c advice.detachedHead=false clone -q --depth 1 --branch '$tag' https://github.com/Xilinx/mlir-aie '$src'"
  fi
  # 2) IRON needs pyxrt (XRT python bindings). The distro/PPA pyxrt is built for the *system*
  #    python, so the venv must use that same interpreter (with --system-site-packages to see pyxrt).
  #    Mixing a different python + /usr/lib/python3/dist-packages breaks numpy.
  sys_py_ver="$(/usr/bin/python3 -c 'import sys;print("%d%d"%sys.version_info[:2])')"
  if /usr/bin/python3 -c 'import pyxrt' 2>/dev/null && \
     curl -fsSL "https://github.com/Xilinx/mlir-aie/releases/expanded_assets/${tag}" 2>/dev/null | qgrep "mlir_aie-${ver}-cp${sys_py_ver}-cp${sys_py_ver}-manylinux"; then
    if ! as_user "'$venv/bin/python' -c 'import aie, pyxrt' 2>/dev/null && '$venv/bin/pip' show mlir_aie 2>/dev/null | grep -qx 'Version: ${ver}'"; then
      info "Creating IRON venv on system python (cp${sys_py_ver}) with pyxrt"
      as_user "set -e; cd '$src'; rm -rf ironenv; /usr/bin/python3 -m venv --system-site-packages ironenv; . ironenv/bin/activate
        pip install -q --upgrade pip
        pip install -q 'mlir_aie==${ver}' -f 'https://github.com/Xilinx/mlir-aie/releases/expanded_assets/${tag}'
        pip install -q --no-warn-conflicts -r utils/peano-requirements.txt
        pip install -q --no-warn-conflicts -r python/requirements.txt
        python -c 'import aie, pyxrt'" || { warn "IRON wheel install failed (see log)"; return 0; }
    else
      ok "IRON venv already up to date ($ver)"
    fi
  else
    # fallback: AMD's installer (hard-requires python3.12; provided via uv). pyxrt must then come from an XRT build for 3.12.
    as_user "command -v uv >/dev/null" || as_user 'pipx install uv >/dev/null'
    as_user "uv python install 3.12 >/dev/null 2>&1 || true"
    local py; py="$(as_user 'uv python find 3.12' 2>/dev/null || true)"
    [[ -n "$py" ]] || { warn "could not provision python3.12 for IRON"; return 0; }
    as_user "cd '$src' && PYTHON='$py' bash -c 'source utils/env_install.sh --no-pre-commit ironenv'" \
      || { warn "IRON env_install.sh failed (see log)"; return 0; }
    as_user "'$venv/bin/python' -c 'import pyxrt'" 2>/dev/null || warn "IRON installed but pyxrt is not importable from its python3.12 venv; NPU execution from IRON needs a matching pyxrt."
  fi
  note "IRON ${tag}: cd $src && source ironenv/bin/activate && source utils/env_setup.sh ; then e.g. 'cd programming_examples/basic/vector_scalar_mul && python3 vector_scalar_mul.py'"
  ok "iron done"
}

# ----------------------------------------------------------------------------
# Stage: ryzenai (AMD Ryzen AI Software: ONNX Runtime + Vitis AI EP) - optional
# ----------------------------------------------------------------------------
stage_ryzenai() {
  stage ryzenai "AMD Ryzen AI Software (ONNX Runtime Vitis AI EP) - optional"
  if [[ -z "$RYZEN_AI_SW_DIR" ]]; then
    info "skipped. The Ryzen AI SW tarball needs an AMD account download (ryzenai.docs.amd.com/en/latest/linux.html)."
    info "Re-run with --ryzen-ai-sw-dir <dir containing ryzen_ai-*.tgz> to install it."
    return 0
  fi
  [[ "$UBU_VER" == 24.04 ]] || warn "Ryzen AI Software officially supports Ubuntu 24.04 only; installing anyway."
  local tgz; tgz="$(ls "$RYZEN_AI_SW_DIR"/ryzen_ai-*.tgz 2>/dev/null | sort -V | tail -n1 || true)"
  [[ -n "$tgz" ]] || { warn "No ryzen_ai-*.tgz in $RYZEN_AI_SW_DIR"; return 0; }
  local dest="$USER_HOME/amd-ai/ryzen_ai"
  apt_install libboost-filesystem-dev dkms
  as_user "mkdir -p '$dest/pkg' && tar -xzf '$tgz' -C '$dest/pkg' && cd \"\$(dirname \"\$(find '$dest/pkg' -name install_ryzen_ai.sh | head -n1)\")\" && ./install_ryzen_ai.sh -a yes -p '$dest/venv'"
  note "Ryzen AI SW: source $dest/venv/bin/activate. It uses its own XRT build; the system XRT from Ubuntu is kept for FLM/IRON."
  ok "ryzenai done"
}

# ----------------------------------------------------------------------------
# Stage: docker (optional, with GPU passthrough helper)
# ----------------------------------------------------------------------------
stage_docker() {
  stage docker "Docker engine (ROCm containers)"
  want "$WITH_DOCKER" 0 1 || { info "skipped (enable with --with-docker)"; return 0; }
  command -v docker >/dev/null || apt_install docker.io docker-compose-v2 docker-buildx
  if ! id -nG "$TARGET_USER" | tr ' ' '\n' | qgrep -x docker; then run usermod -aG docker "$TARGET_USER"; need_reboot; fi
  run systemctl enable --now docker >/dev/null 2>&1 || true
  note "Docker GPU flags: --device=/dev/kfd --device=/dev/dri --device=/dev/accel --group-add render --ulimit memlock=-1 --security-opt seccomp=unconfined"
  ok "docker done"
}

# ----------------------------------------------------------------------------
# Stage: finalize (env file, helper command)
# ----------------------------------------------------------------------------
stage_finalize() {
  stage finalize "Environment file and helper command"
  local venv="${VENV_DIR:-$USER_HOME/amd-ai/venv}" rocm_lines=""
  if [[ -n "${ROCM_ROOT:-}" && "$ROCM_ROOT" != /usr && -d "$ROCM_ROOT" ]]; then
    rocm_lines="export ROCM_PATH=\"$ROCM_ROOT\"
case \":\$PATH:\" in *\":$ROCM_ROOT/bin:\"*) ;; *) export PATH=\"$ROCM_ROOT/bin:\$PATH\" ;; esac"
  elif [[ -d /opt/rocm/bin ]]; then
    rocm_lines='export ROCM_PATH=/opt/rocm
case ":$PATH:" in *":/opt/rocm/bin:"*) ;; *) export PATH="/opt/rocm/bin:$PATH" ;; esac'
  fi
  write_file "$ENV_FILE" 0644 "# Generated by ${SCRIPT_NAME} ${SCRIPT_VERSION} - AMD Ryzen AI developer environment
export AMD_GFX_TARGET=\"${GFX:-}\"
${rocm_lines}
# Default HIP offload arch for hipcc/cmake builds on this machine
export HIP_OFFLOAD_ARCH=\"${GFX:-}\"
export PYTORCH_ROCM_ARCH=\"${GFX:-}\"
alias amd-ai-venv='source \"${venv}/bin/activate\"'
alias amd-ai-check='amd-ryzen-ai-test --quick'
alias amd-ai-test='amd-ryzen-ai-test'" || true
  if [[ "$DRY_RUN" != 1 && "$SCRIPT_PATH" != "/usr/local/sbin/${SCRIPT_NAME}" ]]; then
    install -m 0755 "$SCRIPT_PATH" "/usr/local/sbin/${SCRIPT_NAME}"
    info "installed /usr/local/sbin/${SCRIPT_NAME} (run 'sudo ${SCRIPT_NAME} --verify' anytime)"
  fi
  local test_src; test_src="$(dirname "$SCRIPT_PATH")/amd-ryzen-ai-test.sh"
  if [[ "$DRY_RUN" != 1 && -f "$test_src" ]]; then
    install -m 0755 "$test_src" /usr/local/bin/amd-ryzen-ai-test
    info "installed /usr/local/bin/amd-ryzen-ai-test (acceptance tests; no root needed)"
  fi
  run install -d -m 0755 "$STATE_DIR"
  [[ "$DRY_RUN" == 1 ]] || date -Is > "$STATE_DIR/last-run"
  ok "finalize done"
}

# ----------------------------------------------------------------------------
# Stage: verify
# ----------------------------------------------------------------------------
vset() { VERIFY["$1"]="$2|$3"; VERIFY_ORDER+=("$1"); }   # vset <name> PASS|WARN|FAIL|SKIP <detail>
ucheck() { sudo -u "$TARGET_USER" -H bash -lc "$1" 2>&1; }  # run as user with login env (groups from /etc/group via sg)

stage_verify() {
  stage verify "Verification"
  local out tmp; tmp="$(mktemp -d)"; chmod 755 "$tmp"
  local in_render=0
  id -nG "$TARGET_USER" | tr ' ' '\n' | qgrep -x render && in_render=1
  # 'sudo -u' starts a fresh PAM session for the user: new groups (render) and the new
  # memlock limit apply here even before the user has logged out/in.
  local SG="bash -c"

  # --- kernel / devices
  [[ -e /dev/kfd ]] && vset "GPU /dev/kfd" PASS "present" || vset "GPU /dev/kfd" FAIL "missing (amdgpu not loaded?)"
  local accel=(/dev/accel/accel*)
  if [[ -n "$NPU_PCI_ID" ]]; then
    if ((${#accel[@]})); then vset "NPU device" PASS "${accel[*]} ($(modinfo -F filename amdxdna 2>/dev/null | qgrep dkms && echo amdxdna-dkms || echo in-tree amdxdna))"
    else vset "NPU device" FAIL "no /dev/accel node (amdxdna not bound; check 'journalctl -k | grep amdxdna')"; fi
    local fw; fw="$(cat /sys/bus/pci/drivers/amdxdna/*/fw_version 2>/dev/null | head -n1 || true)"
    if [[ -n "$fw" ]]; then version_ge "$fw" 1.1.0.0 && vset "NPU firmware" PASS "$fw" || vset "NPU firmware" WARN "$fw (< 1.1.0.0, FLM needs newer)"
    else vset "NPU firmware" WARN "fw_version not exposed by this driver"; fi
  fi
  ((in_render)) && vset "User groups" PASS "$TARGET_USER in render" || vset "User groups" FAIL "$TARGET_USER not in render"
  local ml; ml="$(sudo -u "$TARGET_USER" -H bash -lc 'ulimit -l' 2>/dev/null || echo ?)"
  [[ "$ml" == unlimited ]] && vset "memlock limit" PASS "unlimited" || vset "memlock limit" WARN "$ml (unlimited after re-login/reboot)"
  local gtt; gtt="$(cat /sys/class/drm/card*/device/mem_info_gtt_total 2>/dev/null | sort -n | tail -n1 || echo 0)"
  vset "GPU memory" PASS "VRAM $(( $(cat /sys/class/drm/card*/device/mem_info_vram_total 2>/dev/null | sort -n | tail -n1 || echo 0) /1024/1024/1024 )) GiB + GTT $((gtt/1024/1024/1024)) GiB"

  # --- ROCm
  if command -v rocminfo >/dev/null || [[ -x "${ROCM_ROOT:-/opt/rocm}/bin/rocminfo" ]]; then
    out="$(ucheck "$SG 'rocminfo'" || true)"
    if grep -q "Name: *${GFX:-gfx}" <<<"$out"; then vset "ROCm rocminfo" PASS "agent $(grep -oE 'gfx[0-9a-f]+' <<<"$out" | head -n1) | $(grep -m1 -oE 'Marketing Name:.*Graphics' <<<"$out" | sed 's/Marketing Name: *//')"
    else vset "ROCm rocminfo" FAIL "$(tail -n2 <<<"$out" | tr '\n' ' ')"; fi
  else vset "ROCm rocminfo" SKIP "ROCm not installed system-wide"; fi
  if command -v hipcc >/dev/null && [[ -n "$GFX" ]]; then
    cat > "$tmp/vadd.hip" <<'EOF'
#include <hip/hip_runtime.h>
#include <cstdio>
__global__ void vadd(const float* a, const float* b, float* c, int n){int i=blockIdx.x*blockDim.x+threadIdx.x; if(i<n) c[i]=a[i]+b[i];}
int main(){const int n=1<<20; float *a,*b,*c; if(hipMallocManaged(&a,n*4)!=hipSuccess) {printf("hipMalloc failed\n");return 1;}
hipMallocManaged(&b,n*4); hipMallocManaged(&c,n*4); for(int i=0;i<n;i++){a[i]=i;b[i]=2*i;}
vadd<<<(n+255)/256,256>>>(a,b,c,n); if(hipDeviceSynchronize()!=hipSuccess){printf("kernel failed\n");return 1;}
for(int i=0;i<n;i++) if(c[i]!=3.0f*i){printf("mismatch at %d\n",i);return 1;}
hipDeviceProp_t p; hipGetDeviceProperties(&p,0); printf("OK %s %s\n",p.name,p.gcnArchName); return 0;}
EOF
    chmod 644 "$tmp/vadd.hip"
    if hipcc --offload-arch="$GFX" -O2 -o "$tmp/vadd" "$tmp/vadd.hip" >"$tmp/hipcc.log" 2>&1; then
      out="$(ucheck "$SG '$tmp/vadd'" || true)"
      if grep -q '^OK ' <<<"$out"; then vset "HIP compile+run" PASS "vector add: $(grep -m1 '^OK ' <<<"$out" | cut -c4-)"
      else vset "HIP compile+run" FAIL "$(tail -n2 <<<"$out" | xargs)"; fi
    else vset "HIP compile+run" FAIL "hipcc failed: $(tail -n3 "$tmp/hipcc.log" | tr '\n' ' ')"; fi
  else vset "HIP compile+run" SKIP "hipcc not available"; fi
  if command -v amd-smi >/dev/null; then
    out="$(amd-smi static --asic 2>/dev/null | grep -m1 -E 'MARKET_NAME|TARGET_GRAPHICS_VERSION' || true)"
    [[ -n "$out" ]] && vset "amd-smi" PASS "$(xargs <<<"$out")" || vset "amd-smi" WARN "no data"
  fi
  if command -v clinfo >/dev/null; then
    out="$(ucheck "$SG 'clinfo -l'" || true)"
    grep -q 'Device' <<<"$out" && vset "OpenCL" PASS "$(grep -m1 Device <<<"$out" | sed 's/.*Device #[0-9]*: //')" || vset "OpenCL" WARN "no OpenCL device"
  fi
  if command -v vulkaninfo >/dev/null; then
    out="$(ucheck "vulkaninfo --summary" || true)"
    grep -q 'RADV' <<<"$out" && vset "Vulkan" PASS "$(grep -m1 -E 'deviceName' <<<"$out" | sed 's/.*= //') | $(grep -m1 driverInfo <<<"$out" | sed 's/.*= //')" || vset "Vulkan" WARN "RADV device not found"
  fi

  # --- NPU / XRT
  if [[ -n "$NPU_PCI_ID" ]]; then
    if command -v xrt-smi >/dev/null; then
      out="$(ucheck "$SG 'xrt-smi examine'" || true)"
      if grep -qiE 'NPU|RyzenAI|aie2' <<<"$out"; then
        vset "XRT xrt-smi examine" PASS "$(grep -m1 -E '^\|\[[0-9a-f:.]+\]' <<<"$out" | tr -s ' |' ' ' | xargs) | fw $(grep -m1 'NPU Firmware Version' <<<"$out" | sed 's/.*: *//')"
        if [[ "${VERIFY_QUICK:-0}" != 1 ]]; then
          out="$(ucheck "$SG 'timeout 300 xrt-smi validate'" | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' || true)"
          if grep -q 'Validation completed' <<<"$out" && grep -q 'PASSED' <<<"$out" && ! grep -q 'FAILED' <<<"$out"; then
            vset "XRT xrt-smi validate" PASS "$(grep -E 'Details' <<<"$out" | sed 's/.*Details *: *//' | paste -sd, | cut -c1-140)"
          else vset "XRT xrt-smi validate" WARN "$(grep -iE 'fail|error|warn' <<<"$out" | head -n2 | xargs | cut -c1-160)"; fi
        fi
      else vset "XRT xrt-smi examine" FAIL "$(tail -n3 <<<"$out" | xargs | cut -c1-160)"; fi
    else vset "XRT xrt-smi examine" FAIL "xrt-smi not installed"; fi
    if command -v flm >/dev/null; then
      out="$(ucheck "$SG 'flm validate'" || true)"
      grep -qiE 'NPU: /dev/accel' <<<"$out" && ! grep -qiE '✗|error|fail' <<<"$out" \
        && vset "FastFlowLM" PASS "$(grep -iE 'FW Version|NPU:' <<<"$out" | xargs | cut -c1-140)" \
        || vset "FastFlowLM" WARN "$(xargs <<<"$out" | cut -c1-200)"
    fi
  fi

  # --- IRON (custom NPU kernels)
  local iron="${SRC_DIR:-$USER_HOME/amd-ai/src}/mlir-aie"
  if [[ -n "$NPU_PCI_ID" && -x "$iron/ironenv/bin/python" ]]; then
    if [[ "${VERIFY_QUICK:-0}" == 1 ]]; then
      out="$(ucheck "'$iron/ironenv/bin/python' -c 'import aie, pyxrt; print(\"ok\")'" || true)"
      [[ "$out" == *ok* ]] && vset "IRON / MLIR-AIE" PASS "aie + pyxrt import" || vset "IRON / MLIR-AIE" FAIL "$(tail -n1 <<<"$out")"
    else
      out="$(ucheck "$SG 'cd $iron && source ironenv/bin/activate && source utils/env_setup.sh >/dev/null 2>&1 && cd programming_examples/basic/vector_scalar_mul && timeout 600 python3 vector_scalar_mul.py'" 2>&1 || true)"
      if grep -q 'PASS!' <<<"$out"; then vset "IRON / MLIR-AIE" PASS "vector_scalar_mul on NPU: $(grep -m1 '^NPU ' <<<"$out" | sed 's/ *(avg\/min\/max us): */ avg us /' | cut -d' ' -f1-4)"
      else vset "IRON / MLIR-AIE" FAIL "$(tail -n2 <<<"$out" | xargs | cut -c1-160)"; fi
    fi
  fi

  # --- Python / PyTorch
  local venv="${VENV_DIR:-$USER_HOME/amd-ai/venv}"
  if [[ -x "$venv/bin/python" ]]; then
    cat > "$tmp/torch_check.py" <<'EOF'
import time, torch
ok = torch.cuda.is_available()
print("torch", torch.__version__, "hip", torch.version.hip, "gpu", torch.cuda.get_device_name(0) if ok else "-")
if ok:
    x = torch.randn(8192, 8192, device="cuda", dtype=torch.float16)
    for _ in range(3): y = x @ x          # warm-up (kernel selection / JIT)
    torch.cuda.synchronize(); t = time.time(); n = 20
    for _ in range(n): y = x @ x
    torch.cuda.synchronize(); dt = time.time() - t
    print("RESULT_OK fp16 matmul %.1f TFLOPS" % (2 * 8192**3 * n / dt / 1e12))
EOF
    chmod 644 "$tmp/torch_check.py"
    out="$(ucheck "$SG '$venv/bin/python $tmp/torch_check.py'" || true)"
    if grep -q 'RESULT_OK' <<<"$out"; then vset "PyTorch ROCm" PASS "$(grep -m1 '^torch' <<<"$out") | $(grep -m1 RESULT_OK <<<"$out" | sed 's/RESULT_OK //')"
    else vset "PyTorch ROCm" FAIL "$(tail -n3 <<<"$out" | xargs | cut -c1-200)"; fi
  fi
  # --- Lemonade
  if pkg_installed lemonade-server; then
    if lemonade_health; then
      local lb; lb="$(lemonade backends 2>/dev/null | awk '/^[a-z]/ {r=$1; if ($5=="installed") print r":"$2; next} /^ +[a-z]/ {if ($4=="installed") print r":"$1}' | paste -sd' ')"
      vset "Lemonade server" PASS "http://localhost:${LEMONADE_PORT} | backends: ${lb:-none}"
    else vset "Lemonade server" WARN "installed, lemond not responding on :${LEMONADE_PORT}"; fi
  fi
  rm -rf "$tmp"

  # --- report
  local k s d rc=0
  printf '\n%s%-24s %-5s %s%s\n' "$C_BOLD" "CHECK" "RESULT" "DETAIL" "$C_0"
  for k in "${VERIFY_ORDER[@]}"; do
    s="${VERIFY[$k]%%|*}"; d="${VERIFY[$k]#*|}"
    case "$s" in PASS) c=$C_G;; WARN) c=$C_Y;; FAIL) c=$C_R; rc=1;; *) c="";; esac
    printf '%-24s %s%-5s%s %s\n' "$k" "$c" "$s" "$C_0" "$d"
  done
  [[ -n "${LOG_FILE:-}" ]] && { for k in "${VERIFY_ORDER[@]}"; do echo "$k=${VERIFY[$k]}"; done > "$LOG_DIR/verify-latest.txt"; }
  echo "$rc" > "$RUN_TMP/verify_rc"
}

# ----------------------------------------------------------------------------
# CLI
# ----------------------------------------------------------------------------
usage() {
  cat <<EOF
$SCRIPT_NAME $SCRIPT_VERSION - set up AMD Ryzen AI (GPU + NPU + CPU) development on Ubuntu

Usage: sudo $0 [options]

Profiles:
  --profile minimal     drivers/firmware/runtimes only (ROCm, Vulkan, XRT, limits)
  --profile standard    + PyTorch venv, FastFlowLM, Lemonade            (default)
  --profile full        + llama.cpp source build, IRON/MLIR-AIE, Docker

General:
  -y, --yes             non-interactive (assume yes)
  -n, --dry-run         print what would be done
      --user NAME       user to configure (default: \$SUDO_USER)
      --only a,b        run only these stages
      --skip a,b        skip these stages
      --verify          only run the verification suite
      --quick-verify    verification without the (slow) NPU validate run
      --no-upgrade      don't run apt full-upgrade
      --force           continue on unsupported hardware/OS
  Stages: ${ALL_STAGES// /, }

Components:
  --rocm-source auto|distro|amd|pip-only|none   (auto: Ubuntu pkgs on 26.04+, AMD repo on 24.04)
  --rocm-version X.Y        AMD repo ROCm version (default latest)
  --gtt-gb N|auto|0         GPU-addressable system RAM in GiB (0 = leave kernel default)
  --venv DIR                AI venv location (default ~/amd-ai/venv)
  --python X.Y              venv Python version (default $VENV_PYTHON)
  --with-X / --without-X    X = pytorch, flm, lemonade, llamacpp, iron, docker
  --ryzen-ai-sw-dir DIR     install AMD Ryzen AI Software from downloaded ryzen_ai-*.tgz
  --apply-firmware-updates  apply BIOS/EC updates from LVFS via fwupd

Examples:
  sudo $0 -y                                  # recommended default
  sudo $0 -y --profile full --gtt-gb 96       # everything, 96 GiB GPU memory
  sudo $0 --verify                            # health check after reboot
EOF
}

parse_args() {
  while (($#)); do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      -y|--yes) ASSUME_YES=1 ;;
      -n|--dry-run) DRY_RUN=1 ;;
      --profile) PROFILE="$2"; shift ;;
      --user) TARGET_USER="$2"; shift ;;
      --only) ONLY_STAGES="$2"; shift ;;
      --skip) SKIP_STAGES="$2"; shift ;;
      --verify) ONLY_STAGES="verify" ;;
      --quick-verify) ONLY_STAGES="verify"; VERIFY_QUICK=1 ;;
      --no-upgrade) NO_UPGRADE=1 ;;
      --force) FORCE=1 ;;
      --rocm-source) ROCM_SOURCE="$2"; shift ;;
      --rocm-version) ROCM_AMD_VERSION="$2"; shift ;;
      --gtt-gb) GTT_GB="$2"; shift ;;
      --venv) VENV_DIR="$2"; shift ;;
      --python) VENV_PYTHON="$2"; shift ;;
      --ryzen-ai-sw-dir) RYZEN_AI_SW_DIR="$(readlink -f "$2")"; shift ;;
      --apply-firmware-updates) APPLY_FIRMWARE_UPDATES=1 ;;
      --with-pytorch) WITH_PYTORCH=1 ;;   --without-pytorch) WITH_PYTORCH=0 ;;
      --with-flm) WITH_FLM=1 ;;           --without-flm) WITH_FLM=0 ;;
      --with-lemonade) WITH_LEMONADE=1 ;; --without-lemonade) WITH_LEMONADE=0 ;;
      --with-llamacpp) WITH_LLAMACPP=1 ;; --without-llamacpp) WITH_LLAMACPP=0 ;;
      --with-iron) WITH_IRON=1 ;;         --without-iron) WITH_IRON=0 ;;
      --with-docker) WITH_DOCKER=1 ;;     --without-docker) WITH_DOCKER=0 ;;
      *) die "Unknown option: $1 (see --help)" ;;
    esac
    shift
  done
  [[ "$PROFILE" =~ ^(minimal|standard|full)$ ]] || die "Invalid --profile $PROFILE"
  [[ "$ROCM_SOURCE" =~ ^(auto|distro|amd|pip-only|none)$ ]] || die "Invalid --rocm-source $ROCM_SOURCE"
  [[ "$GTT_GB" =~ ^(auto|[0-9]+)$ ]] || die "Invalid --gtt-gb $GTT_GB"
}

main() {
  parse_args "$@"
  [[ $EUID -eq 0 ]] || die "Run as root: sudo $0 $*"
  if [[ -z "$TARGET_USER" || "$TARGET_USER" == root ]]; then
    TARGET_USER="$(logname 2>/dev/null || true)"
    [[ -n "$TARGET_USER" && "$TARGET_USER" != root ]] || TARGET_USER="$(getent passwd 1000 | cut -d: -f1)"
  fi
  id "$TARGET_USER" >/dev/null 2>&1 || die "User '$TARGET_USER' does not exist (use --user)"
  USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

  install -d -m 0755 "$LOG_DIR"
  LOG_FILE="$LOG_DIR/setup-$(date +%Y%m%d-%H%M%S).log"
  exec > >(tee -a "$LOG_FILE") 2>&1
  exec 9>"$LOCK_FILE"; flock -n 9 || die "Another instance is running ($LOCK_FILE)"

  detect_os; detect_hw; print_detection
  if [[ "$ONLY_STAGES" != verify ]]; then
    confirm "Proceed with setup (profile=$PROFILE)?" || die "Aborted by user"
  fi
  resolve_rocm_source; detect_rocm_root
  info "ROCm source: $ROCM_SOURCE${ROCM_ROOT:+ (root $ROCM_ROOT)}"
  local s rc
  for s in $ALL_STAGES; do
    stage_enabled "$s" || continue
    [[ "$s" == preflight && "$ONLY_STAGES" == verify ]] && continue
    # each stage runs in a subshell: a failing *optional* stage must not abort a customer install
    set +e; trap - ERR
    ( trap on_error ERR; set -e; detect_rocm_root; "stage_$s" )
    rc=$?
    trap on_error ERR; set -e
    if (( rc != 0 )); then
      if [[ "$OPTIONAL_STAGES" == *" $s "* ]]; then
        warn "Optional stage '$s' failed (rc=$rc) - continuing. Fix and re-run: sudo $SCRIPT_NAME --only $s"
      else
        err "Stage '$s' failed (rc=$rc). Fix the error above and re-run (completed steps are skipped)."
        exit "$rc"
      fi
    fi
  done

  stage summary "Summary"
  [[ -s "$RUN_TMP/notes" ]] && sed 's/^/  * /' "$RUN_TMP/notes"
  if [[ -s "$RUN_TMP/warnings" ]]; then printf '%sWarnings:%s\n' "$C_Y" "$C_0"; sort -u "$RUN_TMP/warnings" | sed 's/^/  ! /'; fi
  local newest_k; newest_k="$(ls /boot/vmlinuz-* 2>/dev/null | sed 's#.*/vmlinuz-##' | sort -V | tail -n1)"
  if [[ -f /var/run/reboot-required || ( -n "$newest_k" && "$newest_k" != "$(uname -r)" ) ]]; then
    [[ "$ONLY_STAGES" == verify ]] || need_reboot
    [[ -n "$newest_k" && "$newest_k" != "$(uname -r)" ]] && printf 'Note: running kernel %s, newest installed %s.\n' "$(uname -r)" "$newest_k"
  fi
  if [[ -e "$RUN_TMP/reboot" ]]; then
    printf '\n%sREBOOT REQUIRED%s to activate kernel/driver/group/memory changes.\n' "$C_BOLD$C_Y" "$C_0"
    printf 'After reboot run:  sudo %s --verify\n' "$SCRIPT_NAME"
  fi
  [[ -s "$RUN_TMP/verify_rc" ]] && VERIFY_RC="$(cat "$RUN_TMP/verify_rc")"
  printf 'Log: %s\n' "$LOG_FILE"
  exit "${VERIFY_RC:-0}"
}

main "$@"
