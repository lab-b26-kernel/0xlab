#!/usr/bin/env bash
#
# andro_lab / fresh Codespace host bootstrap
#
# Prepares a fresh Debian/Ubuntu/GitHub Codespace for:
#   - Linux x86_64 kernel build
#   - QEMU x86_64 guest execution
#   - KVM when /dev/kvm is exposed
#   - kernel debugging/instrumentation work
#   - initramfs/rootfs construction
#   - future syzkaller build/integration
#
# This installs HOST tools only. It does not clone repositories, fetch a
# kernel, apply Mali patches, configure/build the kernel, or start QEMU.
#
# Usage:
#   chmod +x init_.sh
#   ./init_.sh
#

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "$0")"
LOG_FILE="${HOME}/andro_lab-init.log"

log() {
    printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

die() {
    printf '\n[ERROR] %s\n' "$*" >&2
    exit 1
}

trap 'printf "\n[ERROR] %s failed at line %s\n" "$SCRIPT_NAME" "$LINENO" >&2' ERR

[[ "${EUID}" -ne 0 ]] || die "Run as a normal user with sudo access, not as root."
command -v sudo >/dev/null 2>&1 || die "sudo is required."
command -v apt-get >/dev/null 2>&1 || die "This script requires a Debian/Ubuntu-based Codespace."

. /etc/os-release
exec > >(tee -a "${LOG_FILE}") 2>&1

log "OS: ${PRETTY_NAME:-unknown}"
log "Kernel: $(uname -srmo)"
log "Host architecture: $(uname -m)"
log "CPU cores: $(nproc)"
log "Memory: $(awk '/MemTotal:/ {printf "%.1f GiB\n", $2/1024/1024}' /proc/meminfo)"

if [[ "$(uname -m)" != "x86_64" ]]; then
    log "WARNING: host is not x86_64; the planned guest launcher uses qemu-system-x86_64."
fi

# Kernel build / debug / source handling
KERNEL_PACKAGES=(
    build-essential
    gcc
    g++
    make
    bc
    bison
    flex
    libssl-dev
    libelf-dev
    libncurses-dev
    dwarves
    pkg-config
    git
    ca-certificates
    curl
    wget
    xz-utils
    zstd
    gzip
    bzip2
    tar
    unzip
    patch
    diffutils
    file
    rsync
    cpio
    kmod
)

# QEMU / debugging
VM_PACKAGES=(
    qemu-system-x86
    qemu-utils
    gdb
    gdb-multiarch
    strace
    ltrace
    tmux
    socat
)

# Optional Clang/LLVM kernel toolchain.
LLVM_PACKAGES=(
    clang
    llvm
    lld
    llvm-dev
)

# Future syzkaller / scripting support.
FUZZ_PACKAGES=(
    golang-go
    python3
    python3-pip
    python3-venv
    python3-dev
    jq
    xxd
    lz4
)

# Optional headers/libs frequently useful around kernel/debug tooling.
OPTIONAL_PACKAGES=(
    libdw-dev
    libcap-dev
)

log "Updating APT metadata..."
sudo apt-get update

log "Installing kernel build prerequisites..."
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    "${KERNEL_PACKAGES[@]}"

log "Installing QEMU/debugging tools..."
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    "${VM_PACKAGES[@]}"

log "Installing Clang/LLVM toolchain..."
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    "${LLVM_PACKAGES[@]}"

log "Installing future syzkaller/scripting prerequisites..."
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    "${FUZZ_PACKAGES[@]}"

log "Installing optional packages when available..."
for pkg in "${OPTIONAL_PACKAGES[@]}"; do
    if apt-cache show "${pkg}" >/dev/null 2>&1; then
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${pkg}" || true
    else
        log "Optional package unavailable in this image: ${pkg}"
    fi
done

mkdir -p \
    "${HOME}/tools" \
    "${HOME}/src" \
    "${HOME}/kernels" \
    "${HOME}/artifacts" \
    "${HOME}/logs"

check_cmd() {
    local cmd="$1"
    local hint="${2:-}"
    command -v "${cmd}" >/dev/null 2>&1 || {
        [[ -z "${hint}" ]] || die "Missing '${cmd}' (package: ${hint})."
        die "Missing '${cmd}'."
    }
    printf '  %-22s %s\n' "${cmd}" "$(command -v "${cmd}")"
}

log "Checking installed commands..."
check_cmd git git
check_cmd make build-essential
check_cmd gcc gcc
check_cmd g++ g++
check_cmd bc bc
check_cmd bison bison
check_cmd flex flex
check_cmd python3 python3
check_cmd curl curl
check_cmd wget wget
check_cmd cpio cpio
check_cmd rsync rsync
check_cmd gdb gdb
check_cmd qemu-system-x86_64 qemu-system-x86
check_cmd qemu-img qemu-utils
check_cmd clang clang
check_cmd llvm-config llvm
check_cmd go golang-go
check_cmd xz xz-utils
check_cmd zstd zstd
check_cmd strace strace
check_cmd tmux tmux

log "Versions:"
printf '  GCC:        '; gcc --version | head -n1
printf '  Clang:      '; clang --version | head -n1
printf '  LLVM:       '; llvm-config --version
printf '  Make:       '; make --version | head -n1
printf '  GDB:        '; gdb --version | head -n1
printf '  QEMU:       '; qemu-system-x86_64 --version | head -n1
printf '  Go:         '; go version
printf '  Python:     '; python3 --version

log "Checking QEMU x86 machine models..."
qemu-system-x86_64 -machine help >/dev/null 2>&1 \
    || die "QEMU is installed but qemu-system-x86_64 -machine help failed."
log "QEMU machine-model query: PASS"

log "Checking KVM exposure..."
if [[ -e /dev/kvm ]]; then
    log "/dev/kvm exists."
    if command -v modprobe >/dev/null 2>&1; then
        sudo modprobe kvm 2>/dev/null || true
        sudo modprobe kvm_intel 2>/dev/null || sudo modprobe kvm_amd 2>/dev/null || true
    fi
    ls -l /dev/kvm || true
    if [[ -r /dev/kvm && -w /dev/kvm ]]; then
        log "KVM device is readable/writable by the current user."
    else
        log "KVM exists but is not directly readable/writable by the current user."
    fi
else
    log "/dev/kvm is not exposed. QEMU can still run with TCG, but VM performance will be lower."
fi

log "Checking kernel-build-related headers..."
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

cat > "${tmpdir}/headers.c" <<'EOF'
#include <openssl/ssl.h>
#include <elf.h>
#include <ncurses.h>
int main(void) {
    (void)OPENSSL_init_ssl(0, NULL);
    return 0;
}
EOF

if gcc -c "${tmpdir}/headers.c" -o "${tmpdir}/headers.o" >/dev/null 2>&1; then
    log "OpenSSL/ELF/ncurses development-header smoke test: PASS"
else
    log "WARNING: development-header smoke test failed; inspect APT packages before the kernel build."
fi

# Put Go-installed user binaries on PATH for future syzkaller use.
mkdir -p "${HOME}/go/bin"
if [[ -f "${HOME}/.bashrc" ]] &&
   ! grep -Fq 'export PATH="$HOME/go/bin:$PATH"' "${HOME}/.bashrc"; then
    cat >> "${HOME}/.bashrc" <<'EOF'

# Go user binaries
export PATH="$HOME/go/bin:$PATH"
EOF
fi
export PATH="${HOME}/go/bin:${PATH}"

git config --global --get init.defaultBranch >/dev/null 2>&1 || \
    git config --global init.defaultBranch main

cat <<EOF

============================================================
andro_lab fresh Codespace bootstrap: COMPLETE
============================================================

HOST TOOLCHAIN
  [OK] GCC/G++ + GNU Make
  [OK] flex/bison/bc
  [OK] OpenSSL/ELF/ncurses development libraries
  [OK] dwarves/pahole
  [OK] Clang/LLVM/lld
  [OK] Git/curl/wget/archive tools
  [OK] cpio/rsync/kmod

VM / DEBUG
  [OK] qemu-system-x86_64
  [OK] qemu-img/qemu-utils
  [OK] GDB + GDB multiarch
  [OK] strace/ltrace/tmux/socat
  [OK] KVM detection

FUZZING PREPARATION
  [OK] Go
  [OK] Python3 + venv/pip
  [OK] jq

IMPORTANT
  This script only prepares the HOST.
  It does not fetch/build Linux.
  It does not fetch/build QEMU from source.
  It does not clone the Mali/Kbase tree.
  It does not apply virtual-device patches.
  It does not create the rootfs.
  It does not start QEMU.

Useful checks after this script:
  uname -m
  nproc
  free -h
  qemu-system-x86_64 --version
  test -e /dev/kvm && ls -l /dev/kvm || true
  gcc --version
  clang --version
  go version

Install log:
  ${LOG_FILE}

============================================================
EOF
