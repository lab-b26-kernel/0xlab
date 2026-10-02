#https://github.com/lab-a2684/andro_lab/blob/main/init_.sh
#!/usr/bin/env bash
set -Eeuo pipefail

: "${HOME:?HOME must be set}"

if ! command -v apt-get >/dev/null 2>&1 || ! command -v dpkg-query >/dev/null 2>&1; then
  printf '%s\n' 'This script requires a Debian-based system with apt-get.' >&2
  exit 1
fi

if [ "$(id -u)" -eq 0 ]; then
  sudo_command=()
elif command -v sudo >/dev/null 2>&1; then
  sudo_command=(sudo)
else
  printf '%s\n' 'Run this script as root or install sudo.' >&2
  exit 1
fi

packages=(ca-certificates curl git locate)
missing_packages=()
for package in "${packages[@]}"; do
  package_status="$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)"
  if [[ "$package_status" != *"install ok installed"* ]]; then
    missing_packages+=("$package")
  fi
done

if [ "${#missing_packages[@]}" -gt 0 ]; then
  export DEBIAN_FRONTEND=noninteractive
  "${sudo_command[@]}" apt-get update
  "${sudo_command[@]}" apt-get install -y "${missing_packages[@]}"
fi

if command -v updatedb >/dev/null 2>&1; then
  "${sudo_command[@]}" updatedb
fi

if ! command -v opencode >/dev/null 2>&1; then
  opencode_install_url="${OPENCODE_INSTALL_URL:-https://opencode.ai/v2/install}"
  curl -fsSL "$opencode_install_url" | bash
fi

opencode_bin_dir="${OPENCODE_BIN_DIR:-$HOME/.opencode/bin}"
if [ ! -d "$opencode_bin_dir" ]; then
  opencode_path="$(command -v opencode || true)"
  if [ -z "$opencode_path" ]; then
    printf '%s\n' 'OpenCode was not found after installation.' >&2
    exit 1
  fi
  opencode_bin_dir="$(dirname "$opencode_path")"
fi

export PATH="$opencode_bin_dir:$PATH"
path_line="export PATH=\"$opencode_bin_dir:\$PATH\""
path_marker="$opencode_bin_dir"
if [ "$opencode_bin_dir" = "$HOME/.opencode/bin" ]; then
  path_marker=".opencode/bin"
fi

for rc_file in "$HOME/.bashrc" "$HOME/.zshrc"; do
  if [ ! -e "$rc_file" ]; then
    : > "$rc_file"
  fi
  if ! grep -Fq "$path_marker" "$rc_file"; then
    printf '\n%s\n' "$path_line" >> "$rc_file"
  fi
done

printf '%s\n' 'Bootstrap completed.'
printf 'locate: %s\n' "$(command -v locate || printf 'not found')"
printf 'opencode: %s\n' "$(command -v opencode || printf 'not found')"
