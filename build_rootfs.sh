#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# Fresh andro_lab x86_64 initramfs builder.
# Host prerequisites: cpio, gzip, file, find, coreutils.
# Installs busybox-static automatically on Debian/Ubuntu if needed.
# Does not fetch/build Linux, QEMU, Mali, or syzkaller.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOTFS_DIR="${ROOT_DIR}/rootfs"
OUT_DIR="${ROOT_DIR}/artifacts/rootfs"
OUT="${OUT_DIR}/initramfs.cpio.gz"
KEEP=0
KBASE=""
TEST=""

usage() {
  cat <<USAGE
Usage: $0 [options]
  --kbase PATH         Embed mali_kbase.ko
  --test-program PATH  Embed an EL0 test program in /opt/tests/
  --keep-rootfs        Keep unpacked rootfs/ after archive creation
  --help               Show this help
USAGE
}

log(){ printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die(){ echo "[ERROR] $*" >&2; exit 1; }
trap 'echo "[ERROR] failed at line $LINENO" >&2' ERR

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kbase) [[ $# -ge 2 ]] || die "--kbase needs a path"; KBASE="$2"; shift 2 ;;
    --test-program) [[ $# -ge 2 ]] || die "--test-program needs a path"; TEST="$2"; shift 2 ;;
    --keep-rootfs) KEEP=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

command -v cpio >/dev/null || die "cpio is missing; run init_.sh first"
command -v gzip >/dev/null || die "gzip is missing; run init_.sh first"
command -v file >/dev/null || die "file is missing; run init_.sh first"

if [[ -n "$KBASE" ]]; then [[ -f "$KBASE" ]] || die "Kbase module not found: $KBASE"; fi
if [[ -n "$TEST" ]]; then [[ -f "$TEST" ]] || die "test program not found: $TEST"; fi

# Prefer static BusyBox so the initramfs has no dependency on host libraries.
BUSYBOX="${BUSYBOX_BIN:-}"
if [[ -z "$BUSYBOX" ]]; then
  for p in /usr/bin/busybox /bin/busybox /usr/lib/x86_64-linux-gnu/busybox; do
    if [[ -x "$p" ]]; then BUSYBOX="$p"; break; fi
  done
fi

if [[ -z "$BUSYBOX" ]]; then
  if command -v apt-get >/dev/null && command -v sudo >/dev/null; then
    log "Installing busybox-static"
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends busybox-static
    BUSYBOX="$(command -v busybox || true)"
  fi
fi

[[ -n "$BUSYBOX" && -x "$BUSYBOX" ]] || die "Static BusyBox not found; install busybox-static or set BUSYBOX_BIN"
file "$BUSYBOX" | grep -qi 'statically linked' || die "BusyBox must be statically linked: $BUSYBOX"

rm -rf "$ROOTFS_DIR"
mkdir -p "$ROOTFS_DIR"/{bin,sbin,usr/bin,usr/sbin,proc,sys,dev,tmp,run,etc,opt/modules,opt/tests}
chmod 1777 "$ROOTFS_DIR/tmp"

cp "$BUSYBOX" "$ROOTFS_DIR/bin/busybox"
chmod 0755 "$ROOTFS_DIR/bin/busybox"
(
  cd "$ROOTFS_DIR"
  ./bin/busybox --install -s
)

cat > "$ROOTFS_DIR/init" <<'INIT'
#!/bin/sh
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
export HOME=/root
export TERM=linux

mkdir -p /proc /sys /dev /run /tmp /opt/modules /opt/tests
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mount -t tmpfs tmpfs /run 2>/dev/null || true

printf '\n==============================================\n'
printf ' andro_lab x86_64 guest\n'
printf '==============================================\n'
printf 'kernel: '; uname -a
printf 'cmdline: '; cat /proc/cmdline 2>/dev/null || true
echo

if [ -f /opt/modules/mali_kbase.ko ]; then
  echo '[*] Loading /opt/modules/mali_kbase.ko'
  insmod /opt/modules/mali_kbase.ko 2>&1 || echo '[!] Kbase load failed; inspect dmesg'
fi

echo '[*] Mali/Kbase modules:'
cat /proc/modules 2>/dev/null | grep -iE 'mali|kbase' || echo '    none'

echo '[*] Recent kernel log:'
dmesg 2>/dev/null | tail -80 || true

echo
if [ -c /dev/mali0 ]; then
  echo '[+] /dev/mali0 exists'
  ls -l /dev/mali0
else
  echo '[!] /dev/mali0 not present'
fi

echo
echo 'Guest ready.'
echo 'Useful commands:'
echo '  uname -a'
echo '  cat /proc/cmdline'
echo '  dmesg | tail -100'
echo '  cat /proc/modules'
echo '  ls -l /dev/mali0'
echo '  /opt/tests/<program>'
echo

exec /bin/sh </dev/console >/dev/console 2>&1
INIT
chmod 0755 "$ROOTFS_DIR/init"

if [[ -n "$KBASE" ]]; then
  cp "$KBASE" "$ROOTFS_DIR/opt/modules/mali_kbase.ko"
  chmod 0644 "$ROOTFS_DIR/opt/modules/mali_kbase.ko"
  sha256sum "$KBASE" > "$ROOTFS_DIR/etc/kbase.SHA256"
fi

if [[ -n "$TEST" ]]; then
  cp "$TEST" "$ROOTFS_DIR/opt/tests/$(basename "$TEST")"
  chmod 0755 "$ROOTFS_DIR/opt/tests/$(basename "$TEST")"
fi

cat > "$ROOTFS_DIR/etc/lab-release" <<META
name=andro_lab
arch=x86_64
rootfs=cpio-newc-gzip
busybox=$(basename "$BUSYBOX")
kbase=$([[ -n "$KBASE" ]] && echo yes || echo no)
test_program=$([[ -n "$TEST" ]] && echo yes || echo no)
built_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
META

mkdir -p "$OUT_DIR"
tmp="${OUT}.tmp"
rm -f "$tmp" "$OUT"

log "Creating initramfs: $OUT"
(
  cd "$ROOTFS_DIR"
  find . -print0 | LC_ALL=C sort -z | cpio --null -o -H newc 2>/dev/null | gzip -n -9
) > "$tmp"
mv "$tmp" "$OUT"

sha256sum "$OUT" > "$OUT.sha256"
cat > "$OUT_DIR/build-info.txt" <<INFO
name=andro_lab
architecture=x86_64
format=cpio-newc-gzip
busybox=$BUSYBOX
busybox_sha256=$(sha256sum "$BUSYBOX" | awk '{print $1}')
initramfs=$OUT
initramfs_sha256=$(sha256sum "$OUT" | awk '{print $1}')
kbase_embedded=$([[ -n "$KBASE" ]] && echo yes || echo no)
test_program_embedded=$([[ -n "$TEST" ]] && echo yes || echo no)
built_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
INFO

[[ "$KEEP" -eq 1 ]] || rm -rf "$ROOTFS_DIR"

log "Rootfs build complete"
echo "  initramfs: $OUT"
echo "  sha256:    $(sha256sum "$OUT" | awk '{print $1}')"
echo "  metadata:  $OUT_DIR/build-info.txt"
