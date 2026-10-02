#!/usr/bin/env bash
#
# build_k.sh - fresh Arm GPU bug-bounty/QEMU kernel builder
#
# Default: current 6.18.y LTS line, x86_64 guest kernel, with debugging,
# KCOV/KASAN/KFENCE/UBSAN, tracing, KGDB/GDB symbols, modules, initramfs,
# and QEMU/VirtIO support.
#
# GDB is a host debugger; the kernel enables the symbols/features GDB needs.
# This script does NOT add Mali/Kbase or Arm virtual-device patches.
# Those must be integrated from the exact in-scope release later.
#
# Usage:
#   ./build_k.sh
#   ./build_k.sh --version 6.18.54
#   ./build_k.sh --jobs 8
#   ./build_k.sh --clean
#   KERNEL_VERSION=6.18.54 ./build_k.sh
#
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${ROOT_DIR}/kernel-build"
SRC_DIR="${WORK_DIR}/src"
BUILD_DIR="${WORK_DIR}/build"
CACHE_DIR="${WORK_DIR}/cache"
ARTIFACT_DIR="${ROOT_DIR}/artifacts/kernel"
LOG_DIR="${ROOT_DIR}/logs"

KERNEL_MAJOR_MINOR="${KERNEL_MAJOR_MINOR:-6.18}"
KERNEL_VERSION="${KERNEL_VERSION:-}"
JOBS="${JOBS:-$(nproc)}"
PROFILE="${PROFILE:-research}"
CLEAN=0
NO_DOWNLOAD=0

INDEX_URL="https://www.kernel.org/pub/linux/kernel/v6.x/"
BASE_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x"

usage() {
    cat <<USAGE
Usage: $0 [options]

  --version VERSION   Build explicit 6.18.y release, e.g. 6.18.54
  --jobs N            Parallel jobs (default: nproc)
  --profile MODE      research or bounty (default: research)
  --clean             Remove previous build output before building
  --no-download       Require cached tarball; do not download
  --help              Show help

Environment:
  KERNEL_VERSION=6.18.54
  JOBS=8
  PROFILE=research
USAGE
}

log() { printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
trap 'printf "\n[ERROR] build_k.sh failed at line %s\n" "$LINENO" >&2' ERR

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) [[ $# -ge 2 ]] || die "--version requires a value"; KERNEL_VERSION="$2"; shift 2 ;;
        --jobs) [[ $# -ge 2 ]] || die "--jobs requires a value"; JOBS="$2"; shift 2 ;;
        --profile) [[ $# -ge 2 ]] || die "--profile requires a value"; PROFILE="$2"; shift 2 ;;
        --clean) CLEAN=1; shift ;;
        --no-download) NO_DOWNLOAD=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

[[ "${JOBS}" =~ ^[1-9][0-9]*$ ]] || die "Invalid job count: ${JOBS}"
[[ "${PROFILE}" == "research" || "${PROFILE}" == "bounty" ]] || die "PROFILE must be research or bounty"

for cmd in make curl sha256sum xz tar gcc; do
    command -v "$cmd" >/dev/null 2>&1 || die "Missing host tool: $cmd. Run init_.sh first."
done

mkdir -p "$SRC_DIR" "$CACHE_DIR" "$ARTIFACT_DIR" "$LOG_DIR"
LOG_FILE="${LOG_DIR}/build_k-$(date '+%Y%m%d-%H%M%S').log"
exec > >(tee -a "$LOG_FILE") 2>&1

log "Host arch: $(uname -m)"
log "Host kernel: $(uname -sr)"
log "CPU cores: $(nproc)"
log "Build jobs: ${JOBS}"

if [[ "$CLEAN" -eq 1 ]]; then
    log "Cleaning build output"
    rm -rf "$BUILD_DIR"
fi
mkdir -p "$BUILD_DIR"

# Select current patchlevel from kernel.org, unless explicitly pinned.
if [[ -z "$KERNEL_VERSION" ]]; then
    log "Discovering latest ${KERNEL_MAJOR_MINOR}.y release..."
    html="$(curl -fsSL --retry 3 --connect-timeout 15 --max-time 60 "$INDEX_URL")" \
        || die "Cannot access kernel.org"
    KERNEL_VERSION="$(printf '%s\n' "$html" |
        grep -oE "linux-${KERNEL_MAJOR_MINOR}\\.[0-9]+\\.tar\\.xz" |
        sed -E 's/^linux-//; s/\\.tar\\.xz$//' |
        sort -V | tail -n1)"
fi

[[ "$KERNEL_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
    die "Invalid kernel version: ${KERNEL_VERSION}"

tarball="linux-${KERNEL_VERSION}.tar.xz"
tarball_path="${CACHE_DIR}/${tarball}"
url="${BASE_URL}/${tarball}"

log "Selected kernel: Linux ${KERNEL_VERSION}"

if [[ "$NO_DOWNLOAD" -eq 0 && ! -f "$tarball_path" ]]; then
    log "Downloading ${tarball}"
    curl -fL --retry 3 --connect-timeout 15 --max-time 900 \
        -o "${tarball_path}.partial" "$url"
    mv "${tarball_path}.partial" "$tarball_path"
elif [[ ! -f "$tarball_path" ]]; then
    die "Cached tarball missing: $tarball_path"
else
    log "Using cached tarball"
fi

log "Fetching kernel checksum manifest"
sums="${CACHE_DIR}/sha256sums.asc"
curl -fL --retry 3 --connect-timeout 15 --max-time 60 \
    -o "${sums}.partial" "${BASE_URL}/sha256sums.asc"
mv "${sums}.partial" "$sums"

expected="$(grep -E "[[:space:]]${tarball}$" "$sums" | awk '{print $1}' | head -n1 || true)"
[[ -n "$expected" ]] || die "No checksum entry found for ${tarball}"
actual="$(sha256sum "$tarball_path" | awk '{print $1}')"
[[ "$expected" == "$actual" ]] || die "SHA-256 mismatch: expected $expected, got $actual"
log "SHA-256 verification: PASS"

kernel_src="${SRC_DIR}/linux-${KERNEL_VERSION}"
if [[ ! -f "${kernel_src}/Makefile" ]]; then
    log "Extracting kernel source"
    tar -xJf "$tarball_path" -C "$SRC_DIR"
else
    log "Kernel source already extracted"
fi
[[ -f "${kernel_src}/Makefile" ]] || die "Kernel source is incomplete"

export ARCH=x86
export HOSTCC="${HOSTCC:-gcc}"
export HOSTCXX="${HOSTCXX:-g++}"

log "Generating x86_64 baseline configuration"
make -C "$kernel_src" O="$BUILD_DIR" x86_64_defconfig

config_script="${kernel_src}/scripts/config"
[[ -x "$config_script" ]] || chmod +x "$config_script"

enable() {
    local sym="$1"
    "$config_script" --file "$BUILD_DIR/.config" --enable "$sym" 2>/dev/null || \
        log "NOTICE: ${sym} unavailable/unsupported; leaving kernel default"
}

disable() {
    local sym="$1"
    "$config_script" --file "$BUILD_DIR/.config" --disable "$sym" 2>/dev/null || \
        log "NOTICE: ${sym} unavailable/unsupported; leaving kernel default"
}

setval() {
    local sym="$1" val="$2"
    "$config_script" --file "$BUILD_DIR/.config" --set-val "$sym" "$val" 2>/dev/null || \
        log "NOTICE: ${sym} unavailable/unsupported; leaving kernel default"
}

# ---------------------------------------------------------------------------
# Profile selection
# ---------------------------------------------------------------------------
#
# Arm's published device-configuration guide is restrictive about which kernel
# KConfig options may be changed on a bounty-conforming environment: CONFIG_COMPAT,
# one ARM64 page-size option, KASAN options, and UBSAN options. Therefore this
# script deliberately separates:
#
#   research  = instrumented discovery kernel for QEMU/GDB/syzkaller work
#   bounty    = conservative candidate profile; leaves most of x86_64_defconfig
#               untouched. Exact Arm virtual-platform/Kbase configuration must
#               be applied later from Arm's supplied guide.
#
# A research crash must later be revalidated with an eligible configuration.
#
# Note: this lab's virtual-machine target is x86_64, so ARM64 page-size options
# are not applicable to this guest.
# ---------------------------------------------------------------------------

if [[ "${PROFILE}" == "research" ]]; then
    log "Using RESEARCH profile: debug + KCOV + sanitizers + tracing"

    # Debug/GDB support. GDB remains a host program; these options provide
    # DWARF/symbol information and kernel-side debugging support.
    enable CONFIG_DEBUG_KERNEL
    enable CONFIG_DEBUG_INFO
    enable CONFIG_DEBUG_INFO_DWARF5
    enable CONFIG_FRAME_POINTER
    enable CONFIG_KALLSYMS
    enable CONFIG_KALLSYMS_ALL
    enable CONFIG_GDB_SCRIPTS
    enable CONFIG_KGDB
    enable CONFIG_KGDB_SERIAL_CONSOLE

    enable CONFIG_MODULES
    enable CONFIG_MODULE_UNLOAD
    enable CONFIG_MODVERSIONS

    # Coverage and memory-safety diagnostics.
    enable CONFIG_KCOV
    enable CONFIG_KCOV_ENABLE_COMPARISONS
    enable CONFIG_KASAN
    enable CONFIG_KASAN_GENERIC
    disable CONFIG_KASAN_SW_TAGS
    disable CONFIG_KASAN_HW_TAGS
    enable CONFIG_KFENCE
    enable CONFIG_UBSAN
    enable CONFIG_UBSAN_BOUNDS
    enable CONFIG_UBSAN_SHIFT
    enable CONFIG_UBSAN_DIVREM
    enable CONFIG_UBSAN_BOOL
    enable CONFIG_UBSAN_ENUM
    disable CONFIG_UBSAN_TRAP

    # Keep KCSAN off in the primary fuzz profile; use a separate experiment.
    disable CONFIG_KCSAN

    # Tracing / dynamic instrumentation.
    enable CONFIG_FTRACE
    enable CONFIG_FUNCTION_TRACER
    enable CONFIG_FUNCTION_GRAPH_TRACER
    enable CONFIG_DYNAMIC_FTRACE
    enable CONFIG_KPROBES
else
    log "Using BOUNTY profile: conservative kernel configuration"
    # Do not change arbitrary debug/KCOV/KGDB options here. Arm's published
    # configuration guide only explicitly permits a small set of config changes.
    # KASAN/UBSAN are intentionally left at their defconfig state unless the
    # researcher modifies this profile deliberately for an allowed experiment.
fi

# QEMU essentials that are expected to be part of a usable x86_64 virtual
# environment. These are kernel capabilities needed to boot/use the VM rather
# than Mali-specific target code.
enable CONFIG_BLK_DEV_INITRD
enable CONFIG_DEVTMPFS
enable CONFIG_DEVTMPFS_MOUNT
enable CONFIG_TTY
enable CONFIG_VT
enable CONFIG_VT_CONSOLE
enable CONFIG_SERIAL_8250
enable CONFIG_SERIAL_8250_CONSOLE
enable CONFIG_SERIAL_CORE
enable CONFIG_PCI
enable CONFIG_BLOCK
enable CONFIG_VIRTIO
enable CONFIG_VIRTIO_PCI
enable CONFIG_VIRTIO_BLK
enable CONFIG_VIRTIO_NET
enable CONFIG_VIRTIO_CONSOLE
enable CONFIG_VIRTIO_MMIO
enable CONFIG_MSDOS_PARTITION
enable CONFIG_EFI_PARTITION

# Guest networking useful for SSH/syzkaller control.
enable CONFIG_NET
enable CONFIG_INET
enable CONFIG_UNIX
enable CONFIG_PACKET
enable CONFIG_NETDEVICES
enable CONFIG_ETHERNET

# Optional QEMU host/guest sharing.
enable CONFIG_NET_9P
enable CONFIG_NET_9P_VIRTIO
enable CONFIG_9P_FS

# Initramfs compression formats.
enable CONFIG_RD_GZIP
enable CONFIG_RD_XZ
enable CONFIG_RD_ZSTD
enable CONFIG_RD_LZ4

enable CONFIG_MAGIC_SYSRQ

if [[ "${PROFILE}" == "research" ]]; then
    enable CONFIG_PANIC_ON_OOPS
    setval CONFIG_PANIC 10
fi

# Keep kernel self-tests/test-only surfaces out of the target.
disable CONFIG_KUNIT
disable CONFIG_KUNIT_ALL_TESTS
disable CONFIG_TESTING

tmpconfig="${BUILD_DIR}/.config.before-olddefconfig"
cp "$BUILD_DIR/.config" "$tmpconfig"
log "Resolving configuration dependencies"
make -C "$kernel_src" O="$BUILD_DIR" olddefconfig

log "Final selected research features"
grep -E '^CONFIG_(DEBUG_INFO|DEBUG_INFO_DWARF|GDB_SCRIPTS|KGDB|KGDB_SERIAL|FRAME_POINTER|KALLSYMS|KCOV|KASAN|KFENCE|UBSAN|FTRACE|FUNCTION_|KPROBES|BLK_DEV_INITRD|DEVTMPFS|VIRTIO|PCI|NET_9P|9P_FS)=' \
    "$BUILD_DIR/.config" || true

log "Building Linux ${KERNEL_VERSION}"
start="$(date +%s)"
make -C "$kernel_src" O="$BUILD_DIR" -j"$JOBS" bzImage vmlinux modules
end="$(date +%s)"
seconds=$((end - start))

vmlinux="$BUILD_DIR/vmlinux"
bzimage="$BUILD_DIR/arch/x86/boot/bzImage"
[[ -f "$vmlinux" ]] || die "vmlinux missing after build"
[[ -f "$bzimage" ]] || die "bzImage missing after build"

artifact="${ARTIFACT_DIR}/linux-${KERNEL_VERSION}"
rm -rf "$artifact"
mkdir -p "$artifact"
cp "$vmlinux" "$artifact/vmlinux"
cp "$bzimage" "$artifact/bzImage"
cp "$BUILD_DIR/System.map" "$artifact/System.map"
cp "$BUILD_DIR/.config" "$artifact/config"

cat > "$artifact/build-info.txt" <<INFO
kernel_version=${KERNEL_VERSION}
kernel_line=${KERNEL_MAJOR_MINOR}.y
kernel_tarball=${tarball}
kernel_sha256=${actual}
arch=x86
subarch=x86_64
jobs=${JOBS}
build_seconds=${seconds}
built_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
host_arch=$(uname -m)
host_kernel=$(uname -sr)
INFO

sha256sum "$artifact/vmlinux" "$artifact/bzImage" "$artifact/System.map" "$artifact/config" > "$artifact/SHA256SUMS"

log "BUILD PASS"
log "Kernel: Linux ${KERNEL_VERSION} x86_64"
log "Artifacts: ${artifact}"
log "Build time: ${seconds}s"

echo
cat <<EOF
============================================================
build_k.sh COMPLETE
============================================================

Kernel:       Linux ${KERNEL_VERSION} (${KERNEL_MAJOR_MINOR}.y line)
Profile:      ${PROFILE}
Guest arch:   x86_64 / qemu-system-x86_64

Debug/fuzzing features are enabled only in PROFILE=research.
For PROFILE=bounty, this script intentionally avoids arbitrary debug/KCOV/KGDB changes.

Research profile includes:
  DEBUG_INFO + DWARF5, GDB_SCRIPTS, KGDB
  KALLSYMS / FRAME_POINTER
  KCOV + comparisons
  KASAN (generic), KFENCE, UBSAN
  FTRACE / function tracer / graph tracer / KPROBES


QEMU:
  initramfs support, devtmpfs, serial console
  PCI + VirtIO block/net/console/mmio

Artifacts:
  ${artifact}/

Host GDB is separate from the kernel. The kernel has the symbols and
kernel-side debugging support needed for source-level debugging.

This build contains no Mali/Kbase code yet.
The default kernel selection follows Arm's guidance to use a current Linux stable/LTS
for a new virtual environment; Kbase/virtual-platform compatibility still has to be
checked against the exact Arm-supplied release.

For bounty work, treat PROFILE=research as a discovery/instrumentation kernel, not
as proof of a bounty-conforming configuration. Revalidate any finding with the
allowed Arm configuration.

Build log:
  ${LOG_FILE}
============================================================
EOF
