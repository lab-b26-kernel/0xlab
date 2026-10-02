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
