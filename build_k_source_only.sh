#!/usr/bin/env bash
#
# build_k_source_only.sh - restore/prep the exact Linux kernel source tree
# for the existing 6.18.y x86_64 bzImage.
#
# IMPORTANT:
#   - This script does NOT build bzImage.
#   - This script does NOT build vmlinux.
#   - This script does NOT build any kernel modules.
#   - This script only restores the matching Linux source tree and prepares
#     the existing kernel configuration so we can integrate/build Arm Kbase.
#
# Intended flow for this lab:
#
#   existing artifact bzImage + config
#              |
#              v
#   restore Linux source
#              |
#              v
#   modules_prepare / config validation
#              |
#              v
#   Arm Kbase integration + Arm VP patches
#              |
#              v
#   build mali_kbase.ko
#
# Usage:
#   ./build_k_source_only.sh
#   ./build_k_source_only.sh --version 6.18.54
#   ./build_k_source_only.sh --no-download
#   ./build_k_source_only.sh --clean
#
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORK_DIR="${WORK_DIR:-${ROOT_DIR}/kernel-build}"
SRC_ROOT="${SRC_ROOT:-${WORK_DIR}/src}"
BUILD_DIR="${BUILD_DIR:-${WORK_DIR}/build}"
CACHE_DIR="${CACHE_DIR:-${WORK_DIR}/cache}"

ARTIFACT_KERNEL_ROOT="${ARTIFACT_KERNEL_ROOT:-${ROOT_DIR}/artifacts/kernel}"
LOG_DIR="${LOG_DIR:-${ROOT_DIR}/logs}"

KERNEL_VERSION="${KERNEL_VERSION:-6.18.54}"
JOBS="${JOBS:-$(nproc)}"

CLEAN=0
NO_DOWNLOAD=0

BASE_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x"

usage() {
    cat <<USAGE
Usage: $0 [options]

Restore and prepare the Linux kernel source corresponding to the existing
artifact kernel. This is SOURCE-ONLY: it does not compile bzImage/vmlinux.

Options:
  --version VERSION   Linux version (default: ${KERNEL_VERSION})
  --clean             Remove the restored source/build/cache for this version
  --no-download       Require the kernel tarball to already exist in cache
  --jobs N             Reserved for consistency; used only for informational output
  --help              Show this help

Expected existing artifact:
  artifacts/kernel/linux-VERSION/config
  artifacts/kernel/linux-VERSION/bzImage

Result:
  kernel-build/src/linux-VERSION/
  kernel-build/build/.config
  kernel-build/build/Makefile (generated metadata)
  kernel-build/build/Module.symvers (only if it already exists; this script
                                     does not generate it)
USAGE
}

log() {
    printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

die() {
    printf '\n[ERROR] %s\n' "$*" >&2
    exit 1
}

trap 'printf "\n[ERROR] build_k_source_only.sh failed at line %s\n" "$LINENO" >&2' ERR

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            [[ $# -ge 2 ]] || die "--version requires a value"
            KERNEL_VERSION="$2"
            shift 2
            ;;
        --jobs)
            [[ $# -ge 2 ]] || die "--jobs requires a value"
            JOBS="$2"
            shift 2
            ;;
        --clean)
            CLEAN=1
            shift
            ;;
        --no-download)
            NO_DOWNLOAD=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
done

[[ "${KERNEL_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
    die "Invalid kernel version: ${KERNEL_VERSION}"

[[ "${JOBS}" =~ ^[1-9][0-9]*$ ]] || \
    die "Invalid job count: ${JOBS}"

for cmd in make curl sha256sum xz tar gcc g++; do
    command -v "${cmd}" >/dev/null 2>&1 || \
        die "Missing host tool: ${cmd}. Run init_.sh first."
done

ARTIFACT_DIR="${ARTIFACT_KERNEL_ROOT}/linux-${KERNEL_VERSION}"
ARTIFACT_BZIMAGE="${ARTIFACT_DIR}/bzImage"
ARTIFACT_CONFIG="${ARTIFACT_DIR}/config"

KERNEL_SRC="${SRC_ROOT}/linux-${KERNEL_VERSION}"
TARBALL="${CACHE_DIR}/linux-${KERNEL_VERSION}.tar.xz"
CHECKSUMS="${CACHE_DIR}/sha256sums.asc"

mkdir -p "${SRC_ROOT}" "${CACHE_DIR}" "${BUILD_DIR}" "${LOG_DIR}"

LOG_FILE="${LOG_DIR}/build_k_source_only-$(date '+%Y%m%d-%H%M%S').log"
exec > >(tee -a "${LOG_FILE}") 2>&1

log "Source-only kernel restore"
log "Repository: ${ROOT_DIR}"
log "Kernel: Linux ${KERNEL_VERSION}"
log "Host arch: $(uname -m)"
log "Jobs (informational): ${JOBS}"

if [[ "${CLEAN}" -eq 1 ]]; then
    log "Cleaning only the disposable source-only workspace for ${KERNEL_VERSION}"
    rm -rf "${KERNEL_SRC}" "${BUILD_DIR:?}/"*
    rm -f "${TARBALL}" "${TARBALL}.partial" "${CHECKSUMS}" "${CHECKSUMS}.partial"
fi

# The existing kernel artifact must already exist. We intentionally do not
# generate a new kernel config here.
[[ -f "${ARTIFACT_BZIMAGE}" ]] || \
    die "Existing bzImage not found: ${ARTIFACT_BZIMAGE}"

[[ -f "${ARTIFACT_CONFIG}" ]] || \
    die "Existing kernel config not found: ${ARTIFACT_CONFIG}"

log "Existing bzImage:"
ls -lh "${ARTIFACT_BZIMAGE}"

log "Existing kernel config:"
ls -lh "${ARTIFACT_CONFIG}"

saved_config_sha256="$(sha256sum "${ARTIFACT_CONFIG}" | awk '{print $1}')"
log "Saved artifact config SHA-256: ${saved_config_sha256}"

# Download exact kernel source.
if [[ ! -f "${TARBALL}" ]]; then
    if [[ "${NO_DOWNLOAD}" -eq 1 ]]; then
        die "Kernel tarball is not cached and --no-download was specified: ${TARBALL}"
    fi

    log "Downloading Linux ${KERNEL_VERSION} source"
    curl -fL --retry 3 --connect-timeout 15 --max-time 900 \
        -o "${TARBALL}.partial" \
        "${BASE_URL}/linux-${KERNEL_VERSION}.tar.xz"
    mv "${TARBALL}.partial" "${TARBALL}"
else
    log "Using cached kernel tarball: ${TARBALL}"
fi

# Verify source archive against kernel.org's published checksum manifest.
if [[ ! -f "${CHECKSUMS}" ]]; then
    log "Downloading kernel.org SHA-256 manifest"
    curl -fL --retry 3 --connect-timeout 15 --max-time 60 \
        -o "${CHECKSUMS}.partial" \
        "${BASE_URL}/sha256sums.asc"
    mv "${CHECKSUMS}.partial" "${CHECKSUMS}"
else
    log "Using cached kernel.org checksum manifest"
fi

tarball_name="$(basename "${TARBALL}")"
expected_sha256="$(
    grep -E "[[:space:]]${tarball_name}$" "${CHECKSUMS}" |
    awk '{print $1}' |
    head -n1 || true
)"

[[ -n "${expected_sha256}" ]] || \
    die "No checksum entry found for ${tarball_name}"

actual_sha256="$(sha256sum "${TARBALL}" | awk '{print $1}')"

if [[ "${expected_sha256}" != "${actual_sha256}" ]]; then
    die "Kernel source SHA-256 mismatch:
  expected: ${expected_sha256}
  actual:   ${actual_sha256}"
fi

log "Kernel source SHA-256 verification: PASS"

# Extract only if the source tree is absent.
if [[ ! -f "${KERNEL_SRC}/Makefile" ]]; then
    log "Extracting ${tarball_name}"
    tar -xJf "${TARBALL}" -C "${SRC_ROOT}"
else
    log "Kernel source already extracted: ${KERNEL_SRC}"
fi

[[ -f "${KERNEL_SRC}/Makefile" ]] || \
    die "Kernel source is incomplete: ${KERNEL_SRC}/Makefile missing"

# Verify that the source tree really is the requested release.
source_version="$(make -s -C "${KERNEL_SRC}" kernelversion)"
[[ "${source_version}" == "${KERNEL_VERSION}" ]] || \
    die "Kernel source version mismatch:
  requested: ${KERNEL_VERSION}
  source:    ${source_version}"

log "Kernel source version: ${source_version}"

export ARCH=x86
export HOSTCC="${HOSTCC:-gcc}"
export HOSTCXX="${HOSTCXX:-g++}"

# Restore the exact .config that produced the existing artifact instead of
# generating a new x86_64_defconfig.
log "Restoring existing config into source/build workspace"

rm -f "${BUILD_DIR}/.config"
cp "${ARTIFACT_CONFIG}" "${BUILD_DIR}/.config"

# Run olddefconfig only to generate/refresh Kbuild metadata for this exact
# kernel version. We then verify whether the configuration changed.
before_olddefconfig_sha256="$(sha256sum "${BUILD_DIR}/.config" | awk '{print $1}')"

log "Running olddefconfig (no kernel image build)"
make -C "${KERNEL_SRC}" O="${BUILD_DIR}" olddefconfig

after_olddefconfig_sha256="$(sha256sum "${BUILD_DIR}/.config" | awk '{print $1}')"

if [[ "${before_olddefconfig_sha256}" != "${after_olddefconfig_sha256}" ]]; then
    log "NOTICE: olddefconfig changed the restored configuration."
    log "The resulting config is the Kbuild-resolved config for Linux ${KERNEL_VERSION}."

    # Preserve the exact config from the old kernel artifact for comparison.
    cp "${ARTIFACT_CONFIG}" "${BUILD_DIR}/config.from-artifact"
    log "Original artifact config preserved at: ${BUILD_DIR}/config.from-artifact"
else
    log "Config after olddefconfig: unchanged"
fi

# Prepare the source tree for module/Kbuild work. This does not build bzImage.
log "Running modules_prepare (no kernel image build)"
make -C "${KERNEL_SRC}" O="${BUILD_DIR}" modules_prepare

# Record the final prepared config hash.
prepared_config_sha256="$(sha256sum "${BUILD_DIR}/.config" | awk '{print $1}')"

cat > "${BUILD_DIR}/source-prepare-info.txt" <<INFO
kernel_version=${KERNEL_VERSION}
kernel_source=${KERNEL_SRC}
kernel_source_sha256=${actual_sha256}
artifact_bzimage=${ARTIFACT_BZIMAGE}
artifact_bzimage_sha256=$(sha256sum "${ARTIFACT_BZIMAGE}" | awk '{print $1}')
artifact_config=${ARTIFACT_CONFIG}
artifact_config_sha256=${saved_config_sha256}
prepared_config_sha256=${prepared_config_sha256}
arch=x86
subarch=x86_64
jobs_informational=${JOBS}
prepared_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
bzimage_rebuilt=no
vmlinux_rebuilt=no
modules_built=no
mali_kbase_built=no
INFO

# A source-only restore cannot manufacture Module.symvers. If it exists from a
# previous full kernel build, report it because it can be relevant when
# CONFIG_MODVERSIONS is enabled later. This script never creates it.
if [[ -f "${BUILD_DIR}/Module.symvers" ]]; then
    log "Module.symvers already present: $(stat -c '%s bytes' "${BUILD_DIR}/Module.symvers")"
else
    log "Module.symvers is NOT present."
    log "This is expected after a source-only restore; this script does not rebuild the kernel."
    log "When Kbase integration is built, we will determine whether the selected"
    log "Kbase/Kbuild configuration requires the prior kernel build metadata."
fi

log "Source-only restore completed successfully"

cat <<EOF

============================================================
build_k_source_only.sh COMPLETE
============================================================

Kernel source:
  ${KERNEL_SRC}

Prepared build metadata:
  ${BUILD_DIR}

Existing kernel image (reused, NOT rebuilt):
  ${ARTIFACT_BZIMAGE}

Existing kernel config:
  ${ARTIFACT_CONFIG}

Source SHA-256:
  ${actual_sha256}

Artifact config SHA-256:
  ${saved_config_sha256}

Prepared config SHA-256:
  ${prepared_config_sha256}

Next Arm-specific phase:
  1. Integrate the exact Kbase release into the Linux source tree.
  2. Test the supplied Arm x86 Simulated Platform Device patches.
  3. Configure the Arm No Mali / CSF / vexpress settings.
  4. Build mali_kbase.ko.

No bzImage was rebuilt by this script.
No vmlinux was rebuilt by this script.
No kernel modules were built by this script.

Log:
  ${LOG_FILE}
============================================================
EOF
