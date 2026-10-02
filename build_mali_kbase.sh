#!/usr/bin/env bash
#
# build_mali_kbase.sh
#
# Arm Virtual Platform / x86 Simulated Platform Device Kbase integration and
# module build helper for the 0xlab layout.
#
# IMPORTANT:
#   - Does NOT rebuild bzImage.
#   - Does NOT run "make bzImage".
#   - Uses the existing Linux 6.18.54 artifact config.
#   - Integrates one exact Arm Kbase release into a clean per-release copy of
#     the Linux source tree.
#   - Tests Arm's supplied x86 VP patches before applying them.
#
# Expected repo layout:
#
#   0xlab/
#   ├── artifacts/kernel/linux-6.18.54/
#   │   ├── bzImage
#   │   └── config
#   ├── kernel-build/
#   │   ├── src/linux-6.18.54/          # from build_k_source_only.sh
#   │   └── build/                      # old/source-only workspace
#   ├── drivers/mali/
#   │   ├── *r53p0*.tar.gz
#   │   └── *r56p0*.tar.gz
#   └── assets/                         # Arm VP patch ZIP or archive containing it
#
# Arm x86 VP patch archive:
#   patches_for_virtual_device.zip
#
# Arm's documented x86 Simulated Platform Device Kconfig:
#   CONFIG_MALI_MIDGARD=m
#   CONFIG_MALI_CSF_SUPPORT=y
#   CONFIG_MALI_EXPERT=y
#   CONFIG_MALI_NO_MALI=y
#   CONFIG_MALI_REAL_HW=n
#   CONFIG_MALI_NO_MALI_DEFAULT_GPU="tKRx"
#   CONFIG_MALI_PLATFORM_NAME="vexpress"
#
# The six supplied VP patches are documented by Arm as clean for r54p0.
# Therefore the default behavior for r53p0/r56p0 is:
#   1. dry-run all six patches
#   2. apply them only when every dry-run succeeds
#   3. stop on any mismatch rather than silently forcing a port
#
# Usage:
#   ./build_mali_kbase.sh --driver r53p0
#   ./build_mali_kbase.sh --driver r56p0
#   ./build_mali_kbase.sh --driver all
#
# Optional:
#   --skip-vp-patches       Build for source analysis only; NOT an Arm x86 VP
#                           runtime configuration.
#   --jobs N
#   --clean
#   --keep-work
#
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

KERNEL_VERSION="${KERNEL_VERSION:-6.18.54}"
KERNEL_SRC="${KERNEL_SRC:-${ROOT_DIR}/kernel-build/src/linux-${KERNEL_VERSION}}"
KERNEL_ARTIFACT_DIR="${KERNEL_ARTIFACT_DIR:-${ROOT_DIR}/artifacts/kernel/linux-${KERNEL_VERSION}}"
KERNEL_CONFIG="${KERNEL_CONFIG:-${KERNEL_ARTIFACT_DIR}/config}"
KERNEL_BZIMAGE="${KERNEL_BZIMAGE:-${KERNEL_ARTIFACT_DIR}/bzImage}"

DRIVER_ROOT="${DRIVER_ROOT:-${ROOT_DIR}/drivers/mali}"
ASSETS_ROOT="${ASSETS_ROOT:-${ROOT_DIR}/assets}"

WORK_ROOT="${WORK_ROOT:-${ROOT_DIR}/kernel-build/mali}"
ARTIFACT_ROOT="${ARTIFACT_ROOT:-${ROOT_DIR}/artifacts/drivers}"

JOBS="${JOBS:-$(nproc)}"
DRIVER="r53p0"
SKIP_VP_PATCHES=0
CLEAN=0
KEEP_WORK=0
KO_PATH=""

usage() {
    cat <<USAGE
Usage: $0 [options]

Build Arm Mali Kbase as a module for the existing Linux ${KERNEL_VERSION}
x86_64 kernel artifact.

Options:
  --driver r53p0|r56p0|all
  --jobs N
  --skip-vp-patches
       Skip Arm's x86 Simulated Platform Device patches.
       This is source/build experimentation only, not the Arm VP configuration.
  --clean
  --keep-work
  --help

Environment overrides:
  KERNEL_VERSION
  KERNEL_SRC
  KERNEL_ARTIFACT_DIR
  KERNEL_CONFIG
  KERNEL_BZIMAGE
  DRIVER_ROOT
  ASSETS_ROOT
  WORK_ROOT
  ARTIFACT_ROOT
  JOBS

Examples:
  $0 --driver r53p0
  $0 --driver r56p0 --jobs 8
USAGE
}

log() {
    printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

die() {
    printf '\n[ERROR] %s\n' "$*" >&2
    exit 1
}

warn() {
    printf '\n[WARNING] %s\n' "$*" >&2
}

trap 'printf "\n[ERROR] build_mali_kbase.sh failed at line %s\n" "$LINENO" >&2' ERR

while [[ $# -gt 0 ]]; do
    case "$1" in
        --driver)
            [[ $# -ge 2 ]] || die "--driver requires r53p0, r56p0, or all"
            DRIVER="$2"
            shift 2
            ;;
        --jobs)
            [[ $# -ge 2 ]] || die "--jobs requires a value"
            JOBS="$2"
            shift 2
            ;;
        --skip-vp-patches)
            SKIP_VP_PATCHES=1
            shift
            ;;
        --clean)
            CLEAN=1
            shift
            ;;
        --keep-work)
            KEEP_WORK=1
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

[[ "$DRIVER" == "r53p0" || "$DRIVER" == "r56p0" || "$DRIVER" == "all" ]] || \
    die "--driver must be r53p0, r56p0, or all"

[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "Invalid jobs value: $JOBS"

for cmd in make tar sha256sum grep find patch unzip awk sed; do
    command -v "$cmd" >/dev/null 2>&1 || die "Missing host tool: $cmd"
done

[[ -f "$KERNEL_SRC/Makefile" ]] || \
    die "Linux source missing: $KERNEL_SRC
Run build_k_source_only.sh first."

[[ -f "$KERNEL_CONFIG" ]] || \
    die "Kernel config missing: $KERNEL_CONFIG"

[[ -f "$KERNEL_BZIMAGE" ]] || \
    die "Existing bzImage missing: $KERNEL_BZIMAGE"

[[ -d "$DRIVER_ROOT" ]] || die "Driver directory missing: $DRIVER_ROOT"

mkdir -p "$WORK_ROOT" "$ARTIFACT_ROOT"

LOG_DIR="${ROOT_DIR}/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/build_mali_kbase-$(date '+%Y%m%d-%H%M%S').log"
exec > >(tee -a "$LOG_FILE") 2>&1

log "Arm Kbase build stage"
log "Linux source: $KERNEL_SRC"
log "Existing bzImage: $KERNEL_BZIMAGE"
log "Kernel config: $KERNEL_CONFIG"
log "Driver root: $DRIVER_ROOT"
log "Jobs: $JOBS"

log "Verifying kernel source version"
SOURCE_VERSION="$(make -s -C "$KERNEL_SRC" kernelversion)"
[[ "$SOURCE_VERSION" == "$KERNEL_VERSION" ]] || \
    die "Kernel source version mismatch: expected $KERNEL_VERSION, got $SOURCE_VERSION"

export ARCH=x86
export HOSTCC="${HOSTCC:-gcc}"
export HOSTCXX="${HOSTCXX:-g++}"

# ---------------------------------------------------------------------------
# Locate the Arm VP patch ZIP.
# ---------------------------------------------------------------------------
PATCH_ZIP=""

if [[ -f "$ASSETS_ROOT/patches_for_virtual_device.zip" ]]; then
    PATCH_ZIP="$ASSETS_ROOT/patches_for_virtual_device.zip"
else
    candidate="$(find "$ASSETS_ROOT" "$ROOT_DIR" -maxdepth 3 -type f \
        -name 'patches_for_virtual_device.zip' -print -quit 2>/dev/null || true)"
    [[ -n "$candidate" ]] && PATCH_ZIP="$candidate"
fi

PATCH_ROOT="${WORK_ROOT}/arm-vp-patches"

extract_vp_patches() {
    rm -rf "$PATCH_ROOT"
    mkdir -p "$PATCH_ROOT"

    if [[ -n "$PATCH_ZIP" ]]; then
        log "Using Arm VP patch archive: $PATCH_ZIP"
        unzip -q "$PATCH_ZIP" -d "$PATCH_ROOT"
    else
        # Search uploaded/project archives for the nested patch ZIP.
        local outer
        outer="$(find "$ASSETS_ROOT" "$ROOT_DIR" -maxdepth 3 -type f \
            \( -name 'archive-*.zip' -o -name '*arm*gpu*.zip' \) \
            -print -quit 2>/dev/null || true)"

        if [[ -n "$outer" ]]; then
            log "Searching archive for patches_for_virtual_device.zip: $outer"
            local nested
            nested="${PATCH_ROOT}/nested"
            mkdir -p "$nested"
            unzip -q "$outer" -d "$nested"

            local nested_zip
            nested_zip="$(find "$nested" -type f \
                -name 'patches_for_virtual_device.zip' -print -quit 2>/dev/null || true)"

            if [[ -n "$nested_zip" ]]; then
                unzip -q "$nested_zip" -d "$PATCH_ROOT"
                PATCH_ZIP="$nested_zip"
            fi
        fi
    fi

    if [[ "$SKIP_VP_PATCHES" -eq 1 ]]; then
        log "VP patch application explicitly disabled."
        return 0
    fi

    [[ -n "$PATCH_ZIP" ]] || \
        die "Could not locate Arm patches_for_virtual_device.zip.
Place it under assets/ or provide an archive containing it."

    local count
    count="$(find "$PATCH_ROOT" -maxdepth 2 -type f -name '*.patch' | wc -l)"
    [[ "$count" -eq 6 ]] || \
        die "Expected 6 Arm VP patches, found $count in $PATCH_ROOT"

    log "Arm VP patch set:"
    find "$PATCH_ROOT" -type f -name '*.patch' -print | sort
}

# Extract once for the whole invocation.
extract_vp_patches

# ---------------------------------------------------------------------------
# Find driver archive for a release.
# ---------------------------------------------------------------------------
find_driver_archive() {
    local release="$1"
    local found=""

    found="$(find "$DRIVER_ROOT" -maxdepth 1 -type f \
        -iname "*${release}*.tar.gz" -print | sort | head -n1 || true)"

    [[ -n "$found" ]] || \
        die "No ${release} driver archive found in ${DRIVER_ROOT}"

    printf '%s\n' "$found"
}

# ---------------------------------------------------------------------------
# Extract Kbase archive and identify MALI_DIR.
# ---------------------------------------------------------------------------
prepare_driver_tree() {
    local release="$1"
    local archive
    archive="$(find_driver_archive "$release")"

    local extract_root="${WORK_ROOT}/input-${release}"
    rm -rf "$extract_root"
    mkdir -p "$extract_root"

    log "Driver archive: $archive"
    tar -xzf "$archive" -C "$extract_root"

    local mali_dir
    mali_dir="$(find "$extract_root" -type d -path '*/driver/product/kernel' -print -quit)"

    [[ -n "$mali_dir" ]] || \
        die "Cannot find */driver/product/kernel in ${archive}"

    printf '%s\n' "$mali_dir"
}

# ---------------------------------------------------------------------------
# Verify MALI_RELEASE_NAME.
# ---------------------------------------------------------------------------
verify_release() {
    local release="$1"
    local mali_dir="$2"
    local kbuild="${mali_dir}/driver/product/kernel/drivers/gpu/arm/midgard/Kbuild"

    [[ -f "$kbuild" ]] || \
        die "Kbase Kbuild missing: $kbuild"

    local release_line
    release_line="$(grep -n 'MALI_RELEASE_NAME' "$kbuild" | head -n1 || true)"

    [[ -n "$release_line" ]] || \
        die "MALI_RELEASE_NAME not found in $kbuild"

    log "${release} MALI_RELEASE_NAME: $release_line"

    case "$release" in
        r53p0)
            grep -q "r53p0" "$kbuild" || \
                die "Archive selected as r53p0 but Kbuild does not contain r53p0"
            ;;
        r56p0)
            grep -q "r56p0" "$kbuild" || \
                die "Archive selected as r56p0 but Kbuild does not contain r56p0"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Create a clean KDIR/KOUT per driver version.
# ---------------------------------------------------------------------------
prepare_kernel_copy() {
    local release="$1"

    local kdir="${WORK_ROOT}/kdir-${release}"
    local kout="${WORK_ROOT}/kout-${release}"

    if [[ "$CLEAN" -eq 1 ]]; then
        rm -rf "$kdir" "$kout"
    fi

    if [[ ! -f "$kdir/Makefile" ]]; then
        log "Creating clean Linux source copy for ${release}"
        cp -a "$KERNEL_SRC" "$kdir"
    else
        log "Reusing prepared Linux source copy: $kdir"
    fi

    mkdir -p "$kout"
    rm -f "$kout/.config"
    cp "$KERNEL_CONFIG" "$kout/.config"

    printf '%s\n%s\n' "$kdir" "$kout"
}

# ---------------------------------------------------------------------------
# Integrate Kbase into KDIR exactly in the Arm documented layout.
# ---------------------------------------------------------------------------
integrate_kbase() {
    local release="$1"
    local mali_dir="$2"
    local kdir="$3"

    log "Copying Kbase into Linux tree for ${release}"
    cp -a "$mali_dir/driver/product/kernel/." "$kdir/"

    local kbuild="$kdir/drivers/gpu/arm/midgard/Kbuild"
    [[ -f "$kbuild" ]] || die "Kbase was not copied correctly: $kbuild"

    # Arm's VP guide integration:
    #   obj-$(CONFIG_MALI_MIDGARD) += arm/
    #   source "drivers/gpu/arm/Kconfig"
    if ! grep -Fxq 'obj-$(CONFIG_MALI_MIDGARD) += arm/' "$kdir/drivers/gpu/Makefile"; then
        echo 'obj-$(CONFIG_MALI_MIDGARD) += arm/' >> "$kdir/drivers/gpu/Makefile"
    fi

    if ! grep -Fxq 'source "drivers/gpu/arm/Kconfig"' "$kdir/drivers/video/Kconfig"; then
        printf '%s\n' 'source "drivers/gpu/arm/Kconfig"' >> "$kdir/drivers/video/Kconfig"
    fi

    log "Kbase release after integration:"
    grep -n 'MALI_RELEASE_NAME' "$kbuild" | head -n1 || true
}

# ---------------------------------------------------------------------------
# Apply Arm six-patch VP workaround set, only after dry-run succeeds.
# ---------------------------------------------------------------------------
apply_vp_patches() {
    local release="$1"
    local kdir="$2"

    if [[ "$SKIP_VP_PATCHES" -eq 1 ]]; then
        warn "Skipping Arm VP patches for ${release}; this is NOT the documented x86 VP build."
        return
    fi

    mapfile -t patches < <(find "$PATCH_ROOT" -type f -name '*.patch' -print | sort)
    [[ "${#patches[@]}" -eq 6 ]] || die "Expected exactly 6 Arm VP patches"

    log "Dry-running all 6 Arm VP patches for ${release}"

    local p
    for p in "${patches[@]}"; do
        echo "===== DRY RUN: $(basename "$p") ====="
        if ! patch --dry-run --batch -p3 -i "$p"; then
            die "Arm VP patch does not apply cleanly to ${release}: $(basename "$p")
Arm documents the supplied set as clean for r54p0; stop here rather than forcing an unverified port."
        fi
    done

    log "All 6 Arm VP patches dry-run: PASS"
    log "Applying Arm VP patches"

    for p in "${patches[@]}"; do
        echo "===== APPLY: $(basename "$p") ====="
        patch --batch -p3 -i "$p"
    done
}

# ---------------------------------------------------------------------------
# Configure exact Arm x86 Simulated Platform Device settings.
# ---------------------------------------------------------------------------
configure_kbase() {
    local release="$1"
    local kdir="$2"
    local kout="$3"

    local config_script="${kdir}/scripts/config"
    [[ -x "$config_script" ]] || chmod +x "$config_script"

    log "Applying Arm x86 Simulated Platform Device Kconfig for ${release}"

    "$config_script" --file "$kout/.config" --module CONFIG_MALI_MIDGARD
    "$config_script" --file "$kout/.config" --enable CONFIG_MALI_CSF_SUPPORT
    "$config_script" --file "$kout/.config" --enable CONFIG_MALI_EXPERT
    "$config_script" --file "$kout/.config" --enable CONFIG_MALI_NO_MALI
    "$config_script" --file "$kout/.config" --disable CONFIG_MALI_REAL_HW
    "$config_script" --set-str CONFIG_MALI_NO_MALI_DEFAULT_GPU "tKRx"
    "$config_script" --set-str CONFIG_MALI_PLATFORM_NAME "vexpress"

    log "Resolving Kconfig dependencies"
    make -C "$kdir" O="$kout" olddefconfig

    log "Effective Mali configuration:"
    grep -E '^CONFIG_MALI_|^# CONFIG_MALI_' "$kout/.config" | sort
}

# ---------------------------------------------------------------------------
# Prepare the kernel build tree and build Kbase.
#
# CONFIG_MODVERSIONS matters because the old research build enabled it.
# modules_prepare alone does NOT create Module.symvers. If it is missing,
# build "modules" once without touching bzImage/vmlinux. This may compile
# other modules as well; it does not rebuild the kernel image.
# ---------------------------------------------------------------------------
build_kbase() {
    local release="$1"
    local kdir="$2"
    local kout="$3"

    log "Preparing kernel build tree for ${release}"
    make -C "$kdir" O="$kout" modules_prepare

    if grep -q '^CONFIG_MODVERSIONS=y' "$kout/.config" &&
       [[ ! -f "$kout/Module.symvers" ]]; then
        log "CONFIG_MODVERSIONS=y and Module.symvers is missing."
        log "Building kernel modules once to generate matching symbol CRCs."
        log "This does NOT run bzImage or vmlinux."
        make -C "$kdir" O="$kout" -j"$JOBS" modules
    fi

    log "Building Kbase module for ${release}"
    make -C "$kdir" O="$kout" \
        M=drivers/gpu/arm/midgard \
        -j"$JOBS" \
        modules

    KO_PATH="${kout}/drivers/gpu/arm/midgard/mali_kbase.ko"
    [[ -f "$KO_PATH" ]] || die "mali_kbase.ko not produced: $KO_PATH"
}

# ---------------------------------------------------------------------------
# Record artifact metadata.
# ---------------------------------------------------------------------------
package_kbase() {
    local release="$1"
    local kdir="$2"
    local kout="$3"
    local ko="$4"

    local out="${ARTIFACT_ROOT}/${release}"
    rm -rf "$out"
    mkdir -p "$out"

    cp "$ko" "$out/mali_kbase.ko"
    cp "$KERNEL_BZIMAGE" "$out/linux-${KERNEL_VERSION}-bzImage"
    cp "$KERNEL_CONFIG" "$out/linux-${KERNEL_VERSION}-config"

    local kbase_kbuild="${kdir}/drivers/gpu/arm/midgard/Kbuild"
    local version_line
    version_line="$(grep -n 'MALI_RELEASE_NAME' "$kbase_kbuild" | head -n1 || true)"

    cat > "$out/build-info.txt" <<INFO
driver_release=${release}
linux_version=${KERNEL_VERSION}
arch=x86
platform=vexpress
mali_config=module
mali_csf_support=y
mali_expert=y
mali_no_mali=y
mali_real_hw=n
mali_no_mali_default_gpu=tKRx
vp_patches_skipped=$([[ "$SKIP_VP_PATCHES" -eq 1 ]] && echo yes || echo no)
mali_release_line=${version_line}
kernel_source=${kdir}
kernel_build_output=${kout}
existing_bzimage=${KERNEL_BZIMAGE}
built_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
bzimage_rebuilt=no
vmlinux_rebuilt=no
kbase_module_built=yes
INFO

    sha256sum \
        "$out/mali_kbase.ko" \
        "$out/linux-${KERNEL_VERSION}-bzImage" \
        "$out/linux-${KERNEL_VERSION}-config" \
        > "$out/SHA256SUMS"

    log "Kbase artifact:"
    ls -lh "$out/mali_kbase.ko"
    log "Artifact directory: $out"
}

build_one() {
    local release="$1"

    log "============================================================"
    log "BUILDING KBASE: ${release}"
    log "============================================================"

    local mali_dir
    mali_dir="$(prepare_driver_tree "$release")"
    verify_release "$release" "$mali_dir"

    local kdir kout
    mapfile -t kp < <(prepare_kernel_copy "$release")
    kdir="${kp[0]}"
    kout="${kp[1]}"

    integrate_kbase "$release" "$mali_dir" "$kdir"
    cd "$kdir"
    apply_vp_patches "$release" "$kdir"
    configure_kbase "$release" "$kdir" "$kout"

    KO_PATH=""
    build_kbase "$release" "$kdir" "$kout"

    package_kbase "$release" "$kdir" "$kout" "$KO_PATH"

    cd "$ROOT_DIR"

    if [[ "$KEEP_WORK" -eq 0 ]]; then
        log "Keeping KDIR/KOUT because they are useful for debugging and GDB."
        log "Use --clean explicitly when you want to discard them."
    fi
}

case "$DRIVER" in
    r53p0)
        build_one r53p0
        ;;
    r56p0)
        build_one r56p0
        ;;
    all)
        build_one r53p0
        build_one r56p0
        ;;
esac

log "============================================================"
log "KBASE BUILD COMPLETE"
log "============================================================"
log "No bzImage was rebuilt."
log "No vmlinux was rebuilt."
log "See artifacts/drivers/ and logs/ for results."
