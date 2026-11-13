#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Bud Ecosystem — https://github.com/BudEcosystem/AMD-Ryzen-AI-Halo-Setup
# =============================================================================
# amd-ryzen-ai-test.sh — post-install acceptance tests for AMD Ryzen AI systems
#
# Validates the stack installed by amd-ryzen-ai-setup.sh (or by hand) end-to-end:
#   system  : OS/kernel, pending reboot, firmware, apt health, disk
#   memory  : RAM, VRAM carve-out, GTT (configured vs. active)
#   gpu     : amdgpu, /dev/kfd + render node access, ROCm, HIP compile+run,
#             amd-smi, OpenCL, Vulkan, VA-API
#   npu     : PCI device, amdxdna, /dev/accel, firmware, memlock, XRT
#             examine/validate, FastFlowLM validate + real LLM inference, IRON
#   cpu     : power profile, AVX-512, BLAS libs, NumPy matmul throughput
#   python  : venv, PyTorch ROCm + fp16 matmul TFLOPS, AI package imports
#   apps    : llama.cpp (devices, optional llama-bench), Lemonade server +
#             GPU/NPU chat completions, Docker
#
# Safe to run any time; it changes nothing on the system (except optionally
# downloading a small test model with --pull-models).
#
#   ./amd-ryzen-ai-test.sh                 # full test as current user (this session)
#   sudo ./amd-ryzen-ai-test.sh            # test as $SUDO_USER in a *fresh* login session
#   ./amd-ryzen-ai-test.sh --quick         # skip slow tests (~20 s)
#   ./amd-ryzen-ai-test.sh --only gpu,npu --json report.json --junit report.xml
#
# Exit codes: 0 = no FAIL (WARN allowed unless --strict), 1 = at least one FAIL,
#             2 = usage error, 3 = tests incomplete (stale session, see report)
# =============================================================================
set -uo pipefail
VERSION="1.0.0"

# ---------------------------------------------------------------- options ----
QUICK=0; STRICT=0; VERBOSE=0; PULL=0; KEEP_TMP=0
ONLY="system,memory,gpu,npu,cpu,python,apps"
JSON_OUT=""; JUNIT_OUT=""; REPORT_DIR=""
TUSER="${SUDO_USER:-${USER:-$(id -un)}}"
VENV=""; IRON_DIR=""; LLAMA_DIR=""; GGUF=""; FLM_MODEL=""; LEMONADE_PORT="${LEMONADE_PORT:-13305}"
NO_COLOR="${NO_COLOR:-}"

usage() {
  cat <<EOF
amd-ryzen-ai-test.sh v$VERSION — acceptance tests for AMD Ryzen AI (GPU + NPU + CPU)

Usage: $0 [options]
  -q, --quick            Skip slow tests (xrt-smi validate, IRON build, LLM inference,
                         benchmarks). ~20 s instead of ~3-5 min.
      --only LIST        Comma list of categories: system,memory,gpu,npu,cpu,python,apps
      --strict           Treat WARN as failure (exit 1)
      --json FILE        Write machine-readable results
      --junit FILE       Write JUnit XML (for CI dashboards)
      --report-dir DIR   Where to save the text/JSON report
                         (default: ~/amd-ai/test-reports)
      --user NAME        User to test as (default: \$SUDO_USER or current user)
      --venv DIR         Python venv (default: ~/amd-ai/venv)
      --iron-dir DIR     mlir-aie checkout (default: ~/amd-ai/src/mlir-aie)
      --llama-dir DIR    llama.cpp checkout (default: ~/amd-ai/src/llama.cpp)
      --gguf FILE        GGUF model for llama-bench (default: auto-detect)
      --flm-model TAG    FastFlowLM model for NPU inference (default: first installed)
      --lemonade-port N  Lemonade server port (default: 13305)
      --pull-models      Download small test models if none present
                         (FLM llama3.2:1b ~1.3 GB)
      --keep-tmp         Keep the temp dir with test sources/logs
      --no-color         Plain output
  -v, --verbose          Print command output of failing tests
  -h, --help             This help

Run as root (sudo) to test what a *fresh login* of the user sees (new groups and
memlock limits apply immediately). Run as the user to test the current session.
EOF
}

while (($#)); do
  case "$1" in
    -q|--quick) QUICK=1;;
    --only) ONLY="$2"; shift;;
    --strict) STRICT=1;;
    --json) JSON_OUT="$2"; shift;;
    --junit) JUNIT_OUT="$2"; shift;;
    --report-dir) REPORT_DIR="$2"; shift;;
    --user) TUSER="$2"; shift;;
    --venv) VENV="$2"; shift;;
    --iron-dir) IRON_DIR="$2"; shift;;
    --llama-dir) LLAMA_DIR="$2"; shift;;
    --gguf) GGUF="$2"; shift;;
    --flm-model) FLM_MODEL="$2"; shift;;
    --lemonade-port) LEMONADE_PORT="$2"; shift;;
    --pull-models) PULL=1;;
    --keep-tmp) KEEP_TMP=1;;
    --no-color) NO_COLOR=1;;
    -v|--verbose) VERBOSE=1;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2;;
  esac
  shift
done

if [[ -t 1 && -z "$NO_COLOR" ]]; then
  C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[34m'; C_D=$'\e[2m'; C_BOLD=$'\e[1m'; C_0=$'\e[0m'
else C_R=""; C_G=""; C_Y=""; C_B=""; C_D=""; C_BOLD=""; C_0=""; fi

getent passwd "$TUSER" >/dev/null || { echo "User '$TUSER' does not exist" >&2; exit 2; }
UHOME="$(getent passwd "$TUSER" | cut -d: -f6)"
VENV="${VENV:-$UHOME/amd-ai/venv}"
IRON_DIR="${IRON_DIR:-$UHOME/amd-ai/src/mlir-aie}"
LLAMA_DIR="${LLAMA_DIR:-$UHOME/amd-ai/src/llama.cpp}"
REPORT_DIR="${REPORT_DIR:-$UHOME/amd-ai/test-reports}"

# Run a command as the target user. As root this is a fresh PAM login session
# (current /etc/group membership, limits.d memlock); as the user it is this session.
if ((EUID == 0)) && [[ "$TUSER" != root ]]; then
  MODE="fresh login session of $TUSER (via sudo)"
  u() { sudo -u "$TUSER" -H bash -lc "$1" 2>&1; }
else
  MODE="current session of $TUSER"
  u() { bash -lc "$1" 2>&1; }
fi

qgrep() { grep "$@" >/dev/null; }     # grep -q without SIGPIPE/pipefail false negatives
has() { command -v "$1" >/dev/null 2>&1; }
want() { [[ ",$ONLY," == *",$1,"* ]]; }
slow() { ((QUICK == 0)); }
oneline() { tr '\n' ' ' | tr -s ' ' | sed 's/^ //; s/ $//' | cut -c1-"${1:-180}"; }
strip_ansi() { sed 's/\x1b\[[0-9;?]*[A-Za-z]//g'; }
version_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]; }

TMP="$(mktemp -d /tmp/amd-ai-test.XXXXXX)"; chmod 755 "$TMP"
((EUID == 0)) && chown "$TUSER" "$TMP"
cleanup() { ((KEEP_TMP)) && echo "temp dir kept: $TMP" || rm -rf "$TMP"; }
trap cleanup EXIT
trap 'echo; echo "interrupted"; exit 130' INT TERM

# --------------------------------------------------------------- results -----
R_CAT=(); R_NAME=(); R_ST=(); R_DET=(); R_SEC=()
CUR_CAT=""; T0=$SECONDS; STALE_SESSION=0
section() { CUR_CAT="$1"; printf '\n%s== %s ==%s\n' "$C_BOLD$C_B" "$2" "$C_0"; T0=$SECONDS; }
# res <name> PASS|WARN|FAIL|SKIP|INFO <detail> [raw output for --verbose]
res() {
  local c; case "$2" in PASS) c=$C_G;; WARN) c=$C_Y;; FAIL) c=$C_R;; SKIP) c=$C_D;; *) c="";; esac
  R_CAT+=("$CUR_CAT"); R_NAME+=("$1"); R_ST+=("$2"); R_DET+=("$3"); R_SEC+=("$((SECONDS - T0))")
  printf '  %-28s %s%-4s%s  %s\n' "$1" "$c" "$2" "$C_0" "$3"
  if ((VERBOSE)) && [[ "$2" == FAIL && -n "${4:-}" ]]; then sed 's/^/      | /' <<<"$4" | tail -n 25; fi
  T0=$SECONDS
}

# ------------------------------------------------------------ hw detect ------
GPU_PCI="$(lspci -Dnn 2>/dev/null | awk '/(VGA|Display)/ && /\[1002:/ {print $1; exit}')"
GPU_ID="$(lspci -nn -s "$GPU_PCI" 2>/dev/null | grep -oE '1002:[0-9a-f]{4}' | head -n1)"
NPU_PCI="$(lspci -Dnn 2>/dev/null | awk '/\[1022:(1502|17f0)\]/ {print $1; exit}')"
NPU_ID="$(lspci -nn -s "$NPU_PCI" 2>/dev/null | grep -oE '1022:(1502|17f0)' | head -n1)"
gfx_from_kfd() {
  local v; v="$(awk '/gfx_target_version/ && $2>0 {print $2; exit}' /sys/class/kfd/kfd/topology/nodes/*/properties 2>/dev/null)"
  [[ -n "$v" ]] && printf 'gfx%d%x%x' $((v / 10000)) $(((v / 100) % 100)) $((v % 100))
}
GFX="$(gfx_from_kfd)"
if [[ -z "$GFX" ]]; then
  case "${GPU_ID#1002:}" in 1586) GFX=gfx1151;; 150e) GFX=gfx1150;; 1114) GFX=gfx1152;; 15bf|15c8|1900|1901) GFX=gfx1103;; esac
fi
CPU_MODEL="$(awk -F': ' '/model name/ {print $2; exit}' /proc/cpuinfo)"
case "${NPU_ID#1022:}" in 1502) NPU_GEN="XDNA1 (aie2)";; 17f0) NPU_GEN="XDNA2 (aie2p)";; *) NPU_GEN="";; esac
ROCM_BIN=""; for d in /opt/rocm/bin /usr/bin; do [[ -x "$d/rocminfo" ]] && { ROCM_BIN="$d"; break; }; done

printf '%sAMD Ryzen AI acceptance tests v%s%s  (%s)\n' "$C_BOLD" "$VERSION" "$C_0" "$(date -Is)"
printf '  host    : %s | %s\n' "$(hostname)" "$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo ?)"
printf '  cpu     : %s\n' "$CPU_MODEL"
printf '  gpu     : %s %s %s\n' "${GPU_PCI:-none}" "${GPU_ID:-}" "${GFX:-}"
printf '  npu     : %s %s %s\n' "${NPU_PCI:-none}" "${NPU_ID:-}" "$NPU_GEN"
printf '  mode    : %s%s\n' "$MODE" "$( ((QUICK)) && echo ', quick')"

# ================================================================ system =====
test_system() {
  section system "System"
  local os; os="$(. /etc/os-release; echo "$PRETTY_NAME")"
  res "OS" INFO "$os ($(uname -m))"
  local run newest; run="$(uname -r)"
  newest="$(ls /boot/vmlinuz-* 2>/dev/null | sed 's|/boot/vmlinuz-||' | sort -V | tail -n1)"
  if [[ -n "$newest" && "$newest" != "$run" ]]; then res "Kernel" WARN "running $run, newer $newest installed -> reboot"
  else res "Kernel" PASS "$run"; fi
  if [[ -e /var/run/reboot-required ]]; then
    res "Reboot pending" WARN "$(cat /var/run/reboot-required.pkgs 2>/dev/null | sort -u | paste -sd, | cut -c1-120)"
  else res "Reboot pending" PASS "no"; fi
  local fw; fw="$(dpkg-query -W -f='${Version}' linux-firmware 2>/dev/null || rpm -q linux-firmware 2>/dev/null || echo)"
  [[ -n "$fw" ]] && res "linux-firmware" INFO "$fw" || res "linux-firmware" WARN "package not found"
  if has mokutil; then res "Secure Boot" INFO "$(mokutil --sb-state 2>&1 | head -n1)"; fi
  if has dpkg; then
    local a; a="$(dpkg --audit 2>&1)"
    [[ -z "$a" ]] && res "Package DB" PASS "dpkg consistent" || res "Package DB" WARN "$(oneline 120 <<<"$a")"
  fi
  local free; free="$(df -BG --output=avail "$UHOME" 2>/dev/null | tail -n1 | tr -dc 0-9)"
  if [[ -n "$free" ]]; then ((free >= 30)) && res "Disk free (home)" PASS "${free} GiB" || res "Disk free (home)" WARN "${free} GiB (models need 5-100 GiB)"; fi
}

# ================================================================ memory =====
test_memory() {
  section memory "Memory (unified)"
  local ram vram gtt; ram=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 / 1024 ))
  res "System RAM (visible)" INFO "${ram} GiB"
  vram="$(cat /sys/class/drm/card*/device/mem_info_vram_total 2>/dev/null | sort -n | tail -n1)"
  gtt="$(cat /sys/class/drm/card*/device/mem_info_gtt_total 2>/dev/null | sort -n | tail -n1)"
  [[ -n "$vram" ]] && res "VRAM carve-out (BIOS)" INFO "$((vram / 1024**3)) GiB (lower to 0.5-4 GiB in BIOS to maximise GTT)"
  local cfg act
  cfg="$(grep -hoE 'pages_limit=[0-9]+' /etc/modprobe.d/*.conf 2>/dev/null | tail -n1 | cut -d= -f2)"
  act="$(cat /sys/module/ttm/parameters/pages_limit 2>/dev/null)"
  if [[ -n "$cfg" ]]; then
    if [[ "$cfg" == "$act" ]]; then res "GTT limit" PASS "$((cfg * 4 / 1024 / 1024)) GiB configured and active (GTT pool $((${gtt:-0} / 1024**3)) GiB)"
    else res "GTT limit" WARN "configured $((cfg * 4 / 1024 / 1024)) GiB, active $((${act:-0} * 4 / 1024 / 1024)) GiB -> reboot to apply"; fi
  else res "GTT limit" WARN "kernel default ($((${gtt:-0} / 1024**3)) GiB); set with amd-ryzen-ai-setup --only memory"; fi
}

# =================================================================== gpu =====
test_gpu() {
  section gpu "GPU (ROCm / HIP / Vulkan / OpenCL)"
  if [[ -z "$GPU_PCI" ]]; then res "AMD GPU" FAIL "no AMD display controller on PCI"; return; fi
  local drv; drv="$(basename "$(readlink -f "/sys/bus/pci/devices/$GPU_PCI/driver" 2>/dev/null)" 2>/dev/null)"
  [[ "$drv" == amdgpu ]] && res "amdgpu driver" PASS "bound to $GPU_PCI ($GPU_ID)" || res "amdgpu driver" FAIL "driver='${drv:-none}'"

  local out; out="$(u 'id -nG')"
  for g in render video; do
    if id -nG "$TUSER" | tr ' ' '\n' | qgrep -x "$g"; then
      if tr ' ' '\n' <<<"$out" | qgrep -x "$g"; then res "group $g" PASS "$TUSER is a member (active)"
      else res "group $g" WARN "member in /etc/group but not in this session -> log out/in"; STALE_SESSION=1; fi
    else res "group $g" FAIL "$TUSER not in '$g' (sudo usermod -aG $g $TUSER)"; fi
  done
  out="$(u '[ -r /dev/kfd ] && [ -w /dev/kfd ] && echo kfd; for r in /dev/dri/renderD*; do [ -r "$r" ] && [ -w "$r" ] && echo "$r"; done')"
  qgrep -x kfd <<<"$out" && res "/dev/kfd access" PASS "read/write" || res "/dev/kfd access" FAIL "no rw access to /dev/kfd"
  qgrep renderD <<<"$out" && res "render node access" PASS "$(grep renderD <<<"$out" | paste -sd' ')" || res "render node access" FAIL "no rw /dev/dri/renderD*"

  if [[ -n "$ROCM_BIN" ]]; then
    out="$(u "timeout 60 $ROCM_BIN/rocminfo")"
    if qgrep -E "Name: *${GFX:-gfx}" <<<"$out"; then
      res "ROCm rocminfo" PASS "$(grep -oE 'gfx[0-9a-f]+' <<<"$out" | head -n1) | $(grep -m1 'Marketing Name:.*Graphics' <<<"$out" | sed 's/.*Marketing Name: *//; s/ *$//') | HSA runtime $(grep -m1 -E 'Runtime Version:' <<<"$out" | sed 's/.*: *//')"
    else res "ROCm rocminfo" FAIL "$(tail -n2 <<<"$out" | oneline)" "$out"; fi
  else res "ROCm rocminfo" FAIL "rocminfo not installed"; fi

  local hipcc; hipcc="$(u 'command -v hipcc' | tail -n1)"
  if [[ -x "$hipcc" && -n "$GFX" ]]; then
    cat > "$TMP/vadd.hip" <<'EOF'
#include <hip/hip_runtime.h>
#include <cstdio>
__global__ void vadd(const float* a, const float* b, float* c, int n){int i=blockIdx.x*blockDim.x+threadIdx.x; if(i<n) c[i]=a[i]+b[i];}
int main(){const int n=1<<24; float *a,*b,*c;
 if(hipMallocManaged(&a,n*4)!=hipSuccess){printf("FAIL hipMallocManaged\n");return 1;}
 hipMallocManaged(&b,n*4); hipMallocManaged(&c,n*4); for(int i=0;i<n;i++){a[i]=i;b[i]=2*i;}
 vadd<<<(n+255)/256,256>>>(a,b,c,n); if(hipDeviceSynchronize()!=hipSuccess){printf("FAIL kernel\n");return 1;}
 hipEvent_t s,e; hipEventCreate(&s); hipEventCreate(&e); hipEventRecord(s);
 for(int r=0;r<20;r++) vadd<<<(n+255)/256,256>>>(a,b,c,n);
 hipEventRecord(e); hipEventSynchronize(e); float ms; hipEventElapsedTime(&ms,s,e);
 for(int i=0;i<n;i++) if(c[i]!=3.0f*i){printf("FAIL mismatch at %d\n",i);return 1;}
 hipDeviceProp_t p; hipGetDeviceProperties(&p,0);
 printf("OK %s %s %d CUs, %.0f GB/s\n",p.name,p.gcnArchName,p.multiProcessorCount, 20.0*3*n*4/(ms/1e3)/1e9); return 0;}
EOF
    out="$(u "cd $TMP && timeout 300 $hipcc --offload-arch=$GFX -O2 -o vadd vadd.hip && timeout 60 ./vadd")"
    if qgrep '^OK ' <<<"$out"; then res "HIP compile+run" PASS "$(grep -m1 '^OK ' <<<"$out" | cut -c4-)"
    else res "HIP compile+run" FAIL "$(grep -v '^$' <<<"$out" | tail -n2 | oneline)" "$out"; fi
  else res "HIP compile+run" SKIP "hipcc not found or GPU arch unknown"; fi

  if has amd-smi; then
    out="$(u 'timeout 30 amd-smi static --asic --vbios 2>/dev/null')"
    if qgrep -E 'MARKET_NAME|TARGET_GRAPHICS_VERSION' <<<"$out"; then
      res "amd-smi" PASS "$(grep -m1 MARKET_NAME <<<"$out" | sed 's/.*: *//') | $(grep -m1 TARGET_GRAPHICS_VERSION <<<"$out" | sed 's/.*: *//')"
    else res "amd-smi" WARN "no data (works with newer amdgpu/amd-smi)"; fi
  else res "amd-smi" SKIP "not installed"; fi

  if has clinfo; then
    out="$(u 'timeout 30 clinfo -l')"
    qgrep -i 'gfx\|radeon\|AMD' <<<"$(grep Device <<<"$out")" \
      && res "OpenCL" PASS "$(grep -m1 Device <<<"$out" | sed 's/.*Device #[0-9]*: //')" \
      || res "OpenCL" WARN "no AMD OpenCL device ($(oneline 80 <<<"$out"))"
  else res "OpenCL" SKIP "clinfo not installed"; fi

  if has vulkaninfo; then
    out="$(u 'timeout 30 vulkaninfo --summary')"
    qgrep RADV <<<"$out" \
      && res "Vulkan" PASS "$(grep -m1 deviceName <<<"$out" | sed 's/.*= //') | $(grep -m1 driverInfo <<<"$out" | sed 's/.*= //')" \
      || res "Vulkan" FAIL "RADV device not found" "$out"
  else res "Vulkan" SKIP "vulkaninfo not installed"; fi

  if has vainfo; then
    out="$(u 'timeout 30 vainfo --display drm' )"
    qgrep -E 'VAProfile(H264|HEVC|AV1)' <<<"$out" \
      && res "VA-API video" PASS "$(grep -m1 'Driver version' <<<"$out" | sed 's/.*Driver version: *//' | cut -c1-80) | $(grep -cE 'VAProfile.*VAEntrypointVLD' <<<"$out") decode profiles" \
      || res "VA-API video" WARN "no decode profiles"
  else res "VA-API video" SKIP "vainfo not installed"; fi
}

# =================================================================== npu =====
NPU_RUNTIME_OK=0
test_npu() {
  section npu "NPU (XDNA / XRT / FastFlowLM / IRON)"
  if [[ -z "$NPU_PCI" ]]; then res "NPU device" SKIP "no Ryzen AI NPU on this system"; return; fi
  res "NPU PCI" PASS "$NPU_PCI $NPU_ID $NPU_GEN"
  local drv out; drv="$(basename "$(readlink -f "/sys/bus/pci/devices/$NPU_PCI/driver" 2>/dev/null)" 2>/dev/null)"
  if [[ "$drv" == amdxdna ]]; then
    local src; src="$(modinfo -F filename amdxdna 2>/dev/null)"
    res "amdxdna driver" PASS "bound ($([[ "$src" == *updates* || "$src" == *dkms* ]] && echo DKMS || echo in-tree), kernel $(uname -r))"
  else res "amdxdna driver" FAIL "driver='${drv:-none}' (needs kernel >= 6.14 or amdxdna-dkms; check 'journalctl -k | grep -i xdna')"; return; fi

  out="$(u 'for a in /dev/accel/accel*; do [ -r "$a" ] && [ -w "$a" ] && echo "$a"; done')"
  if qgrep accel <<<"$out"; then res "/dev/accel access" PASS "$(paste -sd' ' <<<"$out")"
  else res "/dev/accel access" FAIL "no rw /dev/accel/accel* (render group / udev rule)"; fi

  local fw; fw="$(cat "/sys/bus/pci/devices/$NPU_PCI/fw_version" 2>/dev/null)"
  if [[ -n "$fw" ]]; then version_ge "$fw" 1.1.0.0 && res "NPU firmware" PASS "$fw" || res "NPU firmware" WARN "$fw (FastFlowLM needs >= 1.1.0.0; update linux-firmware)"
  else res "NPU firmware" INFO "fw_version not exposed by driver"; fi

  local ml; ml="$(u 'ulimit -l' | tail -n1)"
  if [[ "$ml" == unlimited ]]; then res "memlock limit" PASS "unlimited"; NPU_RUNTIME_OK=1
  elif grep -rqs 'memlock' /etc/security/limits.d/ /etc/security/limits.conf; then
    res "memlock limit" WARN "${ml} KB in this session; configured unlimited -> log out/in or reboot (or test via sudo)"
    STALE_SESSION=1
  else res "memlock limit" FAIL "${ml} KB; NPU buffers need unlimited (/etc/security/limits.d)"; fi

  if ! has xrt-smi; then res "XRT xrt-smi" FAIL "xrt-smi not installed (XRT)"; fi
  local skip_rt="session memlock too low (re-login/reboot, or run with sudo)"
  if has xrt-smi && ((NPU_RUNTIME_OK == 0)); then
    res "XRT examine" SKIP "$skip_rt"
  elif has xrt-smi; then
    out="$(u 'timeout 60 xrt-smi examine' | strip_ansi)"
    if qgrep -iE 'NPU|RyzenAI|aie2' <<<"$out"; then
      res "XRT examine" PASS "XRT $(grep -m1 -E '^ *Version *:' <<<"$out" | sed 's/.*: *//') | $(grep -m1 -E '^\|\[[0-9a-f:.]+\]' <<<"$out" | tr -s ' |' ' ' | sed 's/^ //' | cut -c1-60)"
    else res "XRT examine" FAIL "$(tail -n3 <<<"$out" | oneline)" "$out"; fi
    if slow; then
      if ((NPU_RUNTIME_OK)); then
        out="$(u 'timeout 600 xrt-smi validate' | strip_ansi)"
        if qgrep 'Validation completed' <<<"$out" && qgrep PASSED <<<"$out" && ! qgrep FAILED <<<"$out"; then
          res "XRT validate" PASS "$(grep -E 'Details' <<<"$out" | sed 's/.*Details *: *//' | paste -sd, | cut -c1-150)"
        elif qgrep -i 'archive' <<<"$out"; then res "XRT validate" WARN "VTD test archive missing (re-run setup --only npu)" "$out"
        else res "XRT validate" FAIL "$(grep -iE 'fail|error' <<<"$out" | head -n2 | oneline)" "$out"; fi
      else res "XRT validate" SKIP "$skip_rt"; fi
    fi
  fi

  if has flm; then
    if ((NPU_RUNTIME_OK)); then
      out="$(u 'timeout 120 flm validate' | strip_ansi)"
      if qgrep -E 'NPU: /dev/accel' <<<"$out" && ! qgrep -iE '✗|error|fail' <<<"$out"; then
        res "FastFlowLM validate" PASS "$(grep -iE 'FW Version|Memlock' <<<"$out" | oneline 120)"
      else res "FastFlowLM validate" FAIL "$(oneline 160 <<<"$out")" "$out"; fi
    else res "FastFlowLM validate" SKIP "$skip_rt"; fi
    slow && test_flm_inference
  else res "FastFlowLM" SKIP "flm not installed"; fi

  if [[ -x "$IRON_DIR/ironenv/bin/python" ]]; then
    out="$(u "'$IRON_DIR/ironenv/bin/python' -c 'import aie, pyxrt; print(\"IMPORT_OK\")'")"
    if ! qgrep IMPORT_OK <<<"$out"; then res "IRON import" FAIL "$(tail -n1 <<<"$out")" "$out"
    elif ! slow; then res "IRON import" PASS "aie + pyxrt"
    elif ((NPU_RUNTIME_OK)); then
      # Build (aiecc + Peano) and run a real kernel on the NPU, in a scratch copy
      out="$(u "set -e; cp -r '$IRON_DIR/programming_examples/basic/vector_scalar_mul' '$TMP/vsm'; cd '$IRON_DIR'; source ironenv/bin/activate; source utils/env_setup.sh >/dev/null 2>&1; cd '$TMP/vsm'; timeout 900 python3 vector_scalar_mul.py")"
      if qgrep 'PASS!' <<<"$out"; then res "IRON NPU kernel" PASS "vector_scalar_mul built+run: $(grep -m1 '^NPU ' <<<"$out" | oneline 80)"
      else res "IRON NPU kernel" FAIL "$(grep -v '^$' <<<"$out" | tail -n2 | oneline)" "$out"; fi
    else res "IRON NPU kernel" SKIP "$skip_rt"; fi
  else res "IRON / MLIR-AIE" SKIP "not installed ($IRON_DIR/ironenv)"; fi
}

test_flm_inference() {
  if ((NPU_RUNTIME_OK == 0)); then res "FLM NPU inference" SKIP "session memlock too low (re-login/reboot, or run with sudo)"; return; fi
  local model="$FLM_MODEL"
  if [[ -z "$model" ]]; then
    model="$(u 'flm list --filter installed 2>/dev/null' | strip_ansi | sed -n 's/^ *- \([^ ]*\) .*✅.*/\1/p' | head -n1)"
  fi
  if [[ -z "$model" ]] && ((PULL)); then
    u 'timeout 1800 flm pull llama3.2:1b' >/dev/null && model="llama3.2:1b"
  fi
  if [[ -z "$model" ]]; then res "FLM NPU inference" SKIP "no FLM model downloaded (flm pull llama3.2:1b, or --pull-models)"; return; fi
  local port=$((52700 + RANDOM % 200)) out
  cat > "$TMP/flm_test.sh" <<EOF
flm serve '$model' --port $port --quiet > '$TMP/flm.log' 2>&1 &
pid=\$!; trap 'kill \$pid 2>/dev/null; wait \$pid 2>/dev/null' EXIT
for i in \$(seq 1 240); do
  curl -fs "http://127.0.0.1:$port/v1/models" >/dev/null 2>&1 && break
  kill -0 \$pid 2>/dev/null || { echo "SERVER_DIED"; tail -n5 '$TMP/flm.log'; exit 1; }
  sleep 1
done
t0=\$(date +%s.%N)
curl -fsS --max-time 300 "http://127.0.0.1:$port/v1/chat/completions" -H 'Content-Type: application/json' \
  -d '{"model":"$model","messages":[{"role":"user","content":"Count from 1 to 20, separated by commas."}],"max_tokens":96,"temperature":0}'
echo; echo "WALL \$(echo "\$(date +%s.%N) - \$t0" | bc)"
EOF
  chmod 644 "$TMP/flm_test.sh"
  out="$(u "bash '$TMP/flm_test.sh'")"
  local r; r="$(parse_chat <<<"$out")"
  if [[ "$r" == OK* ]]; then res "FLM NPU inference" PASS "$model: ${r#OK }"
  else res "FLM NPU inference" FAIL "$model: $(oneline 160 <<<"${r#ERR }")" "$out"; fi
}

# Parse an OpenAI chat completion (+ optional "WALL <sec>" line) -> "OK <summary>" | "ERR <why>"
parse_chat() {
  python3 -I -c '
import json, re, sys
raw = sys.stdin.read()
wall = re.search(r"^WALL ([0-9.]+)", raw, re.M)
m = re.search(r"\{.*\}", raw, re.S)
try:
    d = json.loads(m.group(0)) if m else None
except Exception:
    d = None
if not d or "choices" not in d:
    print("ERR", raw.strip().replace("\n", " ")[:200]); sys.exit()
txt = (d["choices"][0].get("message") or {}).get("content", "").strip().replace("\n", " ")
u = d.get("usage") or {}; t = d.get("timings") or {}
n = u.get("completion_tokens") or t.get("predicted_n") or 0
tps = t.get("predicted_per_second") or u.get("decoding_speed_tps") or u.get("decode_tps")
if not tps and n and wall: tps = n / float(wall.group(1))
s = "%d tokens" % n
if tps: s += ", %.1f tok/s" % float(tps)
if t.get("prompt_per_second"): s += ", prefill %.0f tok/s" % t["prompt_per_second"]
print("OK" if txt else "ERR", s, "| \"%s\"" % txt[:50])
'
}

# =================================================================== cpu =====
test_cpu() {
  section cpu "CPU"
  res "CPU" INFO "$(lscpu 2>/dev/null | awk -F: '/^Core\(s\) per socket/ {gsub(/ /,"",$2); c=$2} /^Socket\(s\)/ {gsub(/ /,"",$2); s=$2} END {print c*s}') cores / $(nproc) threads, max $(( $(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null || echo 0) / 1000 )) MHz"
  if has powerprofilesctl; then
    local p; p="$(powerprofilesctl get 2>/dev/null)"
    [[ "$p" == performance ]] && res "Power profile" PASS "$p" || res "Power profile" INFO "${p:-?} (performance recommended for benchmarks)"
  else
    res "CPU governor" INFO "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo ?) / EPP $(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null || echo ?)"
  fi
  res "CPU driver" INFO "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null || echo ?)"
  local f; f="$(grep -m1 '^flags' /proc/cpuinfo)"
  local isa=(); for x in avx2 avx512f avx512bw avx512_vnni avx512_bf16 avx_vnni; do [[ " $f " == *" $x "* ]] && isa+=("$x"); done
  if [[ " $f " == *" avx512f "* ]]; then res "SIMD ISA" PASS "${isa[*]}"; else res "SIMD ISA" INFO "${isa[*]:-none} (no AVX-512: pre-Zen4 CPU)"; fi
  local libs=(); for l in libblis libopenblas libflame libomp libtbb libnuma; do ldconfig -p 2>/dev/null | qgrep "$l\.so" && libs+=("$l"); done
  ((${#libs[@]} >= 3)) && res "Math libraries" PASS "${libs[*]}" || res "Math libraries" WARN "found: ${libs[*]:-none}"
  if [[ -x "$VENV/bin/python" ]]; then
    cat > "$TMP/np_bench.py" <<'EOF'
import time, numpy as np
n = 4096; a = np.random.rand(n, n); b = np.random.rand(n, n); a @ b
t = time.time(); r = 3
for _ in range(r): a @ b
dt = time.time() - t
cfg = np.show_config(mode="dicts") if "mode" in np.show_config.__code__.co_varnames else {}
blas = (cfg.get("Build Dependencies", {}).get("blas", {}) or {}).get("name", "?")
print("NP_OK numpy %s fp64 matmul %.0f GFLOPS (BLAS %s)" % (np.__version__, 2 * n**3 * r / dt / 1e9, blas))
EOF
    local out; out="$(u "cd $TMP && OMP_NUM_THREADS=$(nproc) timeout 120 '$VENV/bin/python' np_bench.py")"
    qgrep NP_OK <<<"$out" && res "NumPy BLAS" PASS "$(grep -m1 NP_OK <<<"$out" | cut -c7-)" || res "NumPy BLAS" FAIL "$(tail -n1 <<<"$out")" "$out"
  fi
}

# ================================================================ python =====
test_python() {
  section python "Python / PyTorch"
  if [[ ! -x "$VENV/bin/python" ]]; then res "venv" FAIL "$VENV not found (setup --only python)"; return; fi
  res "venv" PASS "$VENV ($("$VENV/bin/python" -V 2>&1))"
  cat > "$TMP/torch_check.py" <<EOF
import sys, time
import torch
ok = torch.cuda.is_available()
print("INFO torch %s hip %s" % (torch.__version__, torch.version.hip))
if not ok: print("FAIL torch.cuda.is_available() is False"); sys.exit(1)
p = torch.cuda.get_device_properties(0)
print("DEV %s %s %.0f GiB" % (p.name, getattr(p, "gcnArchName", "?"), p.total_memory / 2**30))
x = torch.randn(1024, 1024, device="cuda"); assert torch.allclose((x @ x).cpu(), x.cpu() @ x.cpu(), atol=1e-2, rtol=1e-3)
print("CORRECT_OK")
if $((1 - QUICK)):
    n = 8192; a = torch.randn(n, n, device="cuda", dtype=torch.float16)
    for _ in range(3): a @ a
    torch.cuda.synchronize(); t = time.time(); r = 20
    for _ in range(r): a @ a
    torch.cuda.synchronize(); print("PERF fp16 matmul %.1f TFLOPS" % (2 * n**3 * r / (time.time() - t) / 1e12))
    b = torch.randn(n, n, device="cuda", dtype=torch.bfloat16)
    for _ in range(3): b @ b
    torch.cuda.synchronize(); t = time.time()
    for _ in range(r): b @ b
    torch.cuda.synchronize(); print("PERF bf16 matmul %.1f TFLOPS" % (2 * n**3 * r / (time.time() - t) / 1e12))
EOF
  local out; out="$(u "cd $TMP && timeout 600 '$VENV/bin/python' torch_check.py")"
  if qgrep CORRECT_OK <<<"$out"; then
    res "PyTorch GPU" PASS "$(grep -m1 '^INFO' <<<"$out" | cut -c6-) | $(grep -m1 '^DEV' <<<"$out" | cut -c5-)"
    qgrep '^PERF' <<<"$out" && res "PyTorch matmul" PASS "$(grep '^PERF' <<<"$out" | cut -c6- | paste -sd'|' | sed 's/|/ | /g')"
  else res "PyTorch GPU" FAIL "$(grep -v '^$' <<<"$out" | tail -n2 | oneline)" "$out"; fi

  out="$(u "cd $TMP && '$VENV/bin/python' - <<'EOF'
import importlib
for m in ['numpy','pandas','transformers','accelerate','datasets','huggingface_hub','onnx','onnxruntime','jupyterlab','ipykernel']:
    try:
        mod = importlib.import_module(m); print('OKMOD', m, getattr(mod, '__version__', ''))
    except Exception as e:
        print('BADMOD', m, type(e).__name__, str(e)[:80])
try:
    import onnxruntime as ort; print('ORTP', ','.join(ort.get_available_providers()))
except Exception: pass
EOF")"
  local bad; bad="$(grep '^BADMOD' <<<"$out" | cut -d' ' -f2- | paste -sd';')"
  [[ -z "$bad" ]] && res "AI packages" PASS "$(grep -c '^OKMOD' <<<"$out") packages import (transformers $(awk '$2=="transformers" {print $3}' <<<"$out"))" \
    || res "AI packages" WARN "failed: $(cut -c1-160 <<<"$bad")"
  qgrep '^ORTP' <<<"$out" && res "ONNX Runtime EPs" INFO "$(grep -m1 '^ORTP' <<<"$out" | cut -c6-)"
  local k ks=(); for k in "$UHOME"/.local/share/jupyter/kernels/*amd*; do [[ -d "$k" ]] && ks+=("${k##*/}"); done
  ((${#ks[@]})) && res "Jupyter kernel" PASS "${ks[*]}" || res "Jupyter kernel" INFO "no AMD kernel registered (setup --only python)"
}

# ================================================================== apps =====
test_apps() {
  section apps "Applications (llama.cpp / Lemonade / Docker)"
  local out bin="$LLAMA_DIR/build/bin"
  if [[ -x "$bin/llama-cli" ]]; then
    out="$(u "timeout 60 '$bin/llama-cli' --list-devices")"
    local devs; devs="$(grep -oE '^ *(ROCm|Vulkan|HIP)[0-9]+' <<<"$out" | xargs)"
    if [[ "$devs" == *ROCm* && "$devs" == *Vulkan* ]]; then res "llama.cpp devices" PASS "$devs ($(grep -m1 -E 'ROCm0' <<<"$out" | sed 's/.*(\(.*\))/\1/'))"
    elif [[ -n "$devs" ]]; then res "llama.cpp devices" WARN "only: $devs (expected ROCm + Vulkan)"
    else res "llama.cpp devices" FAIL "no GPU devices" "$out"; fi
    if slow; then
      local g="$GGUF"
      [[ -z "$g" ]] && g="$(u "find '$UHOME/.cache/huggingface' '$UHOME/models' '$UHOME/amd-ai/models' -name '*.gguf' -size +50M -size -8G -printf '%s %p\n' 2>/dev/null | sort -n | head -n1 | cut -d' ' -f2-" | tail -n1)"
      if [[ -n "$g" && -f "$g" ]]; then
        for dev in ROCm0 Vulkan0; do
          out="$(u "timeout 600 '$bin/llama-bench' -m '$g' -dev $dev -ngl 99 -fa 1 -p 512 -n 128 -r 2 -o json 2>/dev/null")"
          local pp tg
          read -r pp tg < <(python3 -I -c '
import json, re, sys
raw = sys.stdin.read(); m = re.search(r"\[.*\]", raw, re.S)
rows = json.loads(m.group(0)) if m else []
pp = [r["avg_ts"] for r in rows if r.get("n_prompt", 0) > 0 and r.get("n_gen", 0) == 0]
tg = [r["avg_ts"] for r in rows if r.get("n_gen", 0) > 0 and r.get("n_prompt", 0) == 0]
print("%.0f" % pp[0] if pp else "-", "%.0f" % tg[0] if tg else "")' <<<"$out" 2>/dev/null)
          [[ -n "$tg" ]] && res "llama-bench $dev" PASS "$(basename "$g"): pp512 $pp tok/s, tg128 $tg tok/s" \
            || res "llama-bench $dev" FAIL "$(grep -v '^$' <<<"$out" | tail -n2 | oneline)" "$out"
        done
      else res "llama-bench" SKIP "no GGUF found (pass --gguf FILE)"; fi
    fi
  else res "llama.cpp" SKIP "not built ($bin)"; fi

  if has lemonade || systemctl list-unit-files lemond.service >/dev/null 2>&1; then
    local active; active="$(systemctl is-active lemond 2>/dev/null)"
    local base="http://127.0.0.1:$LEMONADE_PORT"
    if curl -fsS --max-time 5 "$base/api/v1/health" 2>/dev/null | qgrep '"status":"ok"'; then
      res "Lemonade server" PASS "$base (lemond $active, $(lemonade --version 2>/dev/null | grep -oE '[0-9]+\.[0-9.]+' | head -n1))"
      local lb; lb="$(lemonade backends 2>/dev/null | awk '/^[a-z]/ {r=$1; if ($5=="installed") print r":"$2; next} /^ +[a-z]/ {if ($4=="installed") print r":"$1}' | paste -sd' ')"
      [[ -n "$lb" ]] && res "Lemonade backends" PASS "$lb" || res "Lemonade backends" WARN "none installed (lemonade backends)"
      if slow; then
        local models; models="$(curl -fsS --max-time 10 "$base/api/v1/models" | python3 -I -c '
import json, sys
d = json.load(sys.stdin).get("data", [])
gpu = [m["id"] for m in d if m.get("downloaded") and m.get("recipe") == "llamacpp"]
npu = [m["id"] for m in d if m.get("downloaded") and m.get("recipe") == "flm"]
print("GPU", gpu[0] if gpu else "-"); print("NPU", npu[0] if npu else "-")' 2>/dev/null)"
        local loaded; loaded="$(curl -fsS --max-time 5 "$base/api/v1/health" | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("model_loaded") or "")' 2>/dev/null)"
        local kind mid r
        for kind in GPU NPU; do
          mid="$(awk -v k=$kind '$1==k {print $2}' <<<"$models")"
          if [[ -z "$mid" || "$mid" == - ]]; then res "Lemonade $kind chat" SKIP "no downloaded $([[ $kind == GPU ]] && echo llamacpp || echo flm) model (lemonade pull ...)"; continue; fi
          out="$(curl -sS --max-time 600 "$base/api/v1/chat/completions" -H 'Content-Type: application/json' \
            -d "{\"model\":\"$mid\",\"messages\":[{\"role\":\"user\",\"content\":\"Count from 1 to 20, separated by commas.\"}],\"max_tokens\":96,\"temperature\":0}" 2>&1)"
          r="$(parse_chat <<<"$out")"
          [[ "$r" == OK* ]] && res "Lemonade $kind chat" PASS "$mid: ${r#OK }" || res "Lemonade $kind chat" FAIL "$mid: ${r#ERR }" "$out"
        done
        # leave the server as we found it
        [[ -z "$loaded" ]] && curl -fsS --max-time 30 -X POST "$base/api/v1/unload" >/dev/null 2>&1
      fi
    else res "Lemonade server" FAIL "not responding on $base (systemctl status lemond: $active)"; fi
  else res "Lemonade" SKIP "not installed"; fi

  if has docker; then
    out="$(u 'timeout 20 docker info --format "{{.ServerVersion}}"')"
    if [[ "$out" =~ ^[0-9] ]]; then res "Docker" PASS "server $(tail -n1 <<<"$out"), /dev/kfd + /dev/dri usable with --device"
    elif qgrep -i 'permission denied' <<<"$out"; then res "Docker" WARN "daemon not accessible (docker group needs re-login)"; STALE_SESSION=1
    else res "Docker" WARN "$(oneline 120 <<<"$out")"; fi
  fi
}

# ================================================================== main =====
START=$SECONDS
want system && test_system
want memory && test_memory
want gpu    && test_gpu
want npu    && test_npu
want cpu    && test_cpu
want python && test_python
want apps   && test_apps

# ---------------------------------------------------------------- summary ----
declare -A CNT=([PASS]=0 [WARN]=0 [FAIL]=0 [SKIP]=0 [INFO]=0)
for s in "${R_ST[@]}"; do CNT[$s]=$((CNT[$s] + 1)); done
RC=0
((CNT[FAIL] > 0)) && RC=1
((STRICT && CNT[WARN] > 0)) && RC=1
((RC == 0 && STALE_SESSION && CNT[SKIP] > 0)) && RC=3

printf '\n%sSummary%s  %s%d PASS%s  %s%d WARN%s  %s%d FAIL%s  %d SKIP  (%ds)\n' "$C_BOLD" "$C_0" \
  "$C_G" "${CNT[PASS]}" "$C_0" "$C_Y" "${CNT[WARN]}" "$C_0" "$C_R" "${CNT[FAIL]}" "$C_0" "${CNT[SKIP]}" $((SECONDS - START))
if ((CNT[FAIL])); then
  printf '%sFailed:%s\n' "$C_R" "$C_0"
  for i in "${!R_ST[@]}"; do [[ "${R_ST[$i]}" == FAIL ]] && printf '  - [%s] %s: %s\n' "${R_CAT[$i]}" "${R_NAME[$i]}" "${R_DET[$i]}"; done
fi
if ((STALE_SESSION)); then
  printf '%sNote:%s this login session predates the setup (groups/memlock not active yet).\n' "$C_Y" "$C_0"
  printf '      Log out and back in (or reboot), or run: sudo %s\n' "$0"
fi
case $RC in
  0) printf '%sRESULT: PASS%s — system is ready for AMD GPU/NPU/CPU development.\n' "$C_G$C_BOLD" "$C_0";;
  3) printf '%sRESULT: INCOMPLETE%s — no failures, but some tests could not run in this session.\n' "$C_Y$C_BOLD" "$C_0";;
  *) printf '%sRESULT: FAIL%s — see failed checks above; fix with: sudo amd-ryzen-ai-setup --only <stage>\n' "$C_R$C_BOLD" "$C_0";;
esac

# --------------------------------------------------------------- reports -----
json_esc() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\t'/ }"; s="${s//$'\n'/ }"; s="${s//$'\r'/}"; printf '%s' "$s"; }
xml_esc() { local s="$1"; s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"; s="${s//\"/&quot;}"; printf '%s' "$s"; }
write_json() {
  {
    printf '{\n  "tool": "amd-ryzen-ai-test", "version": "%s", "date": "%s",\n' "$VERSION" "$(date -Is)"
    printf '  "host": "%s", "product": "%s", "cpu": "%s", "gpu": "%s %s", "npu": "%s %s",\n' \
      "$(json_esc "$(hostname)")" "$(json_esc "$(cat /sys/class/dmi/id/product_name 2>/dev/null)")" "$(json_esc "$CPU_MODEL")" \
      "$GPU_ID" "$GFX" "$NPU_ID" "$NPU_GEN"
    printf '  "os": "%s", "kernel": "%s", "mode": "%s", "quick": %s,\n' \
      "$(json_esc "$(. /etc/os-release; echo "$PRETTY_NAME")")" "$(uname -r)" "$(json_esc "$MODE")" "$( ((QUICK)) && echo true || echo false)"
    printf '  "summary": {"pass": %d, "warn": %d, "fail": %d, "skip": %d, "exit_code": %d},\n  "results": [\n' \
      "${CNT[PASS]}" "${CNT[WARN]}" "${CNT[FAIL]}" "${CNT[SKIP]}" "$RC"
    local i n=${#R_ST[@]}
    for ((i = 0; i < n; i++)); do
      printf '    {"category": "%s", "name": "%s", "status": "%s", "detail": "%s", "seconds": %d}%s\n' \
        "${R_CAT[$i]}" "$(json_esc "${R_NAME[$i]}")" "${R_ST[$i]}" "$(json_esc "${R_DET[$i]}")" "${R_SEC[$i]}" "$( ((i < n - 1)) && echo ,)"
    done
    printf '  ]\n}\n'
  } > "$1"
}
write_junit() {
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<testsuites name="amd-ryzen-ai-test" tests="%d" failures="%d" skipped="%d">\n' \
      "${#R_ST[@]}" "${CNT[FAIL]}" "${CNT[SKIP]}"
    local cat i
    for cat in system memory gpu npu cpu python apps; do
      local idx=(); for i in "${!R_CAT[@]}"; do [[ "${R_CAT[$i]}" == "$cat" ]] && idx+=("$i"); done
      ((${#idx[@]})) || continue
      printf '  <testsuite name="%s" tests="%d">\n' "$cat" "${#idx[@]}"
      for i in "${idx[@]}"; do
        printf '    <testcase classname="amd.%s" name="%s" time="%d">' "$cat" "$(xml_esc "${R_NAME[$i]}")" "${R_SEC[$i]}"
        case "${R_ST[$i]}" in
          FAIL) printf '<failure message="%s"/>' "$(xml_esc "${R_DET[$i]}")";;
          SKIP) printf '<skipped message="%s"/>' "$(xml_esc "${R_DET[$i]}")";;
          *) printf '<system-out>%s: %s</system-out>' "${R_ST[$i]}" "$(xml_esc "${R_DET[$i]}")";;
        esac
        printf '</testcase>\n'
      done
      printf '  </testsuite>\n'
    done
    printf '</testsuites>\n'
  } > "$1"
}

if mkdir -p "$REPORT_DIR" 2>/dev/null; then
  ts="$(date +%Y%m%d-%H%M%S)"
  write_json "$REPORT_DIR/report-$ts.json"
  { for i in "${!R_ST[@]}"; do printf '%-7s %-5s %-28s %s\n' "${R_CAT[$i]}" "${R_ST[$i]}" "${R_NAME[$i]}" "${R_DET[$i]}"; done; } > "$REPORT_DIR/report-$ts.txt"
  ((EUID == 0)) && chown -R "$TUSER:" "$REPORT_DIR" 2>/dev/null
  printf '%sReport: %s/report-%s.{txt,json}%s\n' "$C_D" "$REPORT_DIR" "$ts" "$C_0"
fi
[[ -n "$JSON_OUT" ]] && write_json "$JSON_OUT"
[[ -n "$JUNIT_OUT" ]] && write_junit "$JUNIT_OUT"
exit $RC
