#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 --all | --include <comma-separated-path-patterns>" >&2
}

case "${1:-}" in
  --all)
    if [[ $# -ne 1 ]]; then
      usage
      exit 2
    fi
    include=""
    ;;
  --include)
    if [[ $# -ne 2 || -z "${2:-}" ]]; then
      usage
      exit 2
    fi
    include="$2"
    ;;
  *)
    usage
    exit 2
    ;;
esac

: "${PITCHAI_LFS_GITHUB_TOKEN:?PITCHAI_LFS_GITHUB_TOKEN is required}"

ensure_git_lfs() {
  if git lfs version >/dev/null 2>&1; then
    return
  fi

  local version="3.7.1"
  local system machine asset expected_sha256 archive_format
  system="$(uname -s)"
  machine="$(uname -m)"

  case "${system}/${machine}" in
    Linux/x86_64 | Linux/amd64)
      asset="git-lfs-linux-amd64-v${version}.tar.gz"
      expected_sha256="1c0b6ee5200ca708c5cebebb18fdeb0e1c98f1af5c1a9cba205a4c0ab5a5ec08"
      archive_format="tar.gz"
      ;;
    Linux/aarch64 | Linux/arm64)
      asset="git-lfs-linux-arm64-v${version}.tar.gz"
      expected_sha256="73a9c90eeb4312133a63c3eaee0c38c019ea7bfa0953d174809d25b18588dd8d"
      archive_format="tar.gz"
      ;;
    Darwin/x86_64 | Darwin/amd64)
      asset="git-lfs-darwin-amd64-v${version}.zip"
      expected_sha256="b5b1b641c0648c83661fa9eda991cd3eff945264dabc2cdf411a80dfe7ec0970"
      archive_format="zip"
      ;;
    Darwin/arm64 | Darwin/aarch64)
      asset="git-lfs-darwin-arm64-v${version}.zip"
      expected_sha256="76260fb34f4ee622ff0a66b857e5954aa49c7e343a92e57a1ec4a760618c94b2"
      archive_format="zip"
      ;;
    *)
      echo "No verified Git LFS ${version} archive is configured for ${system}/${machine}." >&2
      exit 1
      ;;
  esac

  local cache_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/pitchai-git-lfs-${version}-${system}-${machine}"
  local local_bin="${cache_root}/bin/git-lfs"

  if [[ ! -x "$local_bin" ]]; then
    local download_dir
    download_dir="$(mktemp -d "${cache_root}.download.XXXXXX")"
    trap 'rm -rf -- "$download_dir"' RETURN

    local archive="${download_dir}/${asset}"
    curl --fail --location --retry 3 --retry-all-errors \
      --output "$archive" \
      "https://github.com/git-lfs/git-lfs/releases/download/v${version}/${asset}"
    if command -v sha256sum >/dev/null 2>&1; then
      printf '%s  %s\n' "$expected_sha256" "$archive" | sha256sum --check --strict
    elif command -v shasum >/dev/null 2>&1; then
      printf '%s  %s\n' "$expected_sha256" "$archive" | shasum -a 256 --check
    else
      echo 'Neither sha256sum nor shasum is available to verify Git LFS.' >&2
      exit 1
    fi

    if [[ "$archive_format" == "zip" ]]; then
      unzip -q "$archive" -d "$download_dir"
    else
      tar --extract --gzip --file "$archive" --directory "$download_dir"
    fi
    local extracted_bin
    extracted_bin="$(find "$download_dir" -type f -name git-lfs -print -quit)"
    if [[ -z "$extracted_bin" ]]; then
      echo "The verified Git LFS archive did not contain git-lfs." >&2
      exit 1
    fi

    mkdir -p "${cache_root}/bin"
    install -m 0755 "$extracted_bin" "$local_bin"
    rm -rf -- "$download_dir"
    trap - RETURN
  fi

  export PATH="${cache_root}/bin:${PATH}"
  if [[ -n "${GITHUB_PATH:-}" ]]; then
    printf '%s\n' "${cache_root}/bin" >> "$GITHUB_PATH"
  fi
}

ensure_git_lfs
git lfs version
git lfs install --local
git lfs fsck --pointers HEAD

# Keep the token out of Git configuration and command arguments. Git passes the
# step environment to this command-scoped credential helper when LFS requests
# credentials from the repository-scoped URL in .lfsconfig.
# Expansion must happen inside Git's helper process.
# shellcheck disable=SC2016
credential_helper='!f() { if [ "$1" = get ]; then printf "username=x-access-token\npassword=%s\n" "$PITCHAI_LFS_GITHUB_TOKEN"; fi; }; f'
pull=(
  git
  -c credential.https://lfs.pitchai.net.useHttpPath=true
  -c "credential.https://lfs.pitchai.net.helper=${credential_helper}"
  lfs pull
)

if [[ -n "$include" ]]; then
  matched_count="$(git lfs ls-files --name-only --include="$include" --exclude="" HEAD | wc -l)"
  if [[ "$matched_count" -eq 0 ]]; then
    echo "No Git LFS paths matched the requested include patterns: $include" >&2
    exit 1
  fi

  "${pull[@]}" --include="$include" --exclude=""

  unresolved="$(git lfs ls-files --include="$include" --exclude="" | awk '$2 == "-" { print }')"
  if [[ -n "$unresolved" ]]; then
    echo "Git LFS left requested paths as pointers:" >&2
    printf '%s\n' "$unresolved" >&2
    exit 1
  fi

  echo "Materialized $matched_count Git LFS paths."
else
  "${pull[@]}"
  git lfs fsck HEAD
fi
