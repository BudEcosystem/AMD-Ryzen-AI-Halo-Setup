#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Bud Ecosystem — https://github.com/BudEcosystem/AMD-Ryzen-AI-Halo-Setup
# =============================================================================
# install.sh — one-line bootstrap for AMD Ryzen AI Halo Setup
#
#   Full setup (GPU + NPU + CPU stack), then acceptance tests:
#     curl -fsSL https://raw.githubusercontent.com/BudEcosystem/AMD-Ryzen-AI-Halo-Setup/main/install.sh | sudo bash
#
#   Pass options to the setup script after "-s --":
#     curl -fsSL .../install.sh | sudo bash -s -- --profile full -y
#
#   Only run the tests (no changes to the system, no root needed):
#     curl -fsSL .../install.sh | bash -s -- --test-only
#
# Installer options (everything else is passed to amd-ryzen-ai-setup.sh):
#   --ref REF        Git branch/tag to install from (default: main)
#   --test-only      Download and run amd-ryzen-ai-test.sh only
#   --no-test        Skip the acceptance tests after setup
#   --quick          Quick verification / tests (skip slow benchmarks)
#   --dry-run | -n   Show what setup would do, change nothing
# With --test-only, the remaining options go to amd-ryzen-ai-test.sh.
# =============================================================================
set -euo pipefail

REPO="BudEcosystem/AMD-Ryzen-AI-Halo-Setup"
REF="${AMD_SETUP_REF:-main}"
TEST_ONLY=0; RUN_TEST=1; SETUP_ARGS=(); TEST_ARGS=(); RAW_ARGS=()

while (($#)); do
  case "$1" in
    --ref) REF="$2"; shift;;
    --test-only) TEST_ONLY=1;;
    --no-test) RUN_TEST=0;;
    --quick) TEST_ARGS+=(--quick); SETUP_ARGS+=(--quick-verify); RAW_ARGS+=(--quick);;
    *) SETUP_ARGS+=("$1"); RAW_ARGS+=("$1");;
  esac
  shift
done

if [[ -t 1 ]]; then B=$'\e[1m'; G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; Z=$'\e[0m'; else B=""; G=""; R=""; Y=""; Z=""; fi
say() { printf '%s==>%s %s\n' "$B$G" "$Z" "$*"; }
die() { printf '%serror:%s %s\n' "$R" "$Z" "$*" >&2; exit 1; }

[[ "$(uname -s)" == Linux ]] || die "Linux only (this machine: $(uname -s))."
[[ "$(uname -m)" == x86_64 ]] || die "x86_64 only (this machine: $(uname -m))."
for c in curl tar; do command -v "$c" >/dev/null || die "'$c' is required (sudo apt install $c)."; done
if ! grep -qi 'AMD' /proc/cpuinfo; then
  printf '%swarning:%s no AMD CPU detected; the scripts target AMD Ryzen AI systems.\n' "$Y" "$Z"
fi

# Use the scripts next to this file when run from a git checkout, otherwise download.
SRC=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [[ -f "$d/amd-ryzen-ai-setup.sh" && -f "$d/amd-ryzen-ai-test.sh" ]] && SRC="$d"
fi
if [[ -z "$SRC" ]]; then
  WORK="$(mktemp -d /tmp/amd-ryzen-ai-setup.XXXXXX)"; chmod 755 "$WORK"
  trap 'rm -rf "$WORK"' EXIT
  say "Downloading $REPO@$REF"
  curl -fsSL --retry 3 "https://codeload.github.com/$REPO/tar.gz/$REF" | tar -xz -C "$WORK" --strip-components=1 \
    || die "download failed (check network / --ref $REF)"
  SRC="$WORK"
  chmod 755 "$SRC"/*.sh
fi

# Interactive prompts need a terminal even when this script arrives via a pipe.
TTY=/dev/null; [[ -r /dev/tty ]] && { : </dev/tty; } 2>/dev/null && TTY=/dev/tty

if ((TEST_ONLY)); then
  say "Running acceptance tests"
  exec bash "$SRC/amd-ryzen-ai-test.sh" "${RAW_ARGS[@]}" <"$TTY"
fi

((EUID == 0)) || die "setup needs root: pipe into 'sudo bash' (or add --test-only to just test)."
[[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]] || \
  printf '%snote:%s run via sudo from your normal user so the developer tools land in that home.\n' "$Y" "$Z"

say "Running amd-ryzen-ai-setup.sh ${SETUP_ARGS[*]}"
set +e
bash "$SRC/amd-ryzen-ai-setup.sh" "${SETUP_ARGS[@]}" <"$TTY"
rc=$?
set -e
dry=0; for a in "${SETUP_ARGS[@]}"; do [[ "$a" == -n || "$a" == --dry-run ]] && dry=1; done
if ((rc != 0)); then
  printf '%sSetup finished with exit code %d.%s Logs: /var/log/amd-ryzen-ai-setup/\n' "$R" "$rc" "$Z"
fi
if ((RUN_TEST && !dry)); then
  say "Running acceptance tests (fresh login session of ${SUDO_USER:-root})"
  bash "$SRC/amd-ryzen-ai-test.sh" "${TEST_ARGS[@]}" || true
fi
cat <<EOF

${B}Next steps${Z}
  1. Reboot if the summary above asks for it:   sudo reboot
  2. Re-test any time:                           amd-ryzen-ai-test        (or: amd-ryzen-ai-test --quick)
  3. Re-run / update the setup:                  sudo amd-ryzen-ai-setup -y
EOF
exit "$rc"
