#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

endpoint='https://lfs.pitchai.net/github.com/Pitch-A-I/symphony/info/lfs'
grep -Fqx $'\turl = '"$endpoint" .lfsconfig
if grep -Eiq 'token|password|@' .lfsconfig; then
  echo '.lfsconfig must remain credential-free.' >&2
  exit 1
fi

helper='scripts/ci/pull_pitchai_lfs.sh'
grep -Fq 'local version="3.7.1"' "$helper"
for expected_sha256 in \
  1c0b6ee5200ca708c5cebebb18fdeb0e1c98f1af5c1a9cba205a4c0ab5a5ec08 \
  73a9c90eeb4312133a63c3eaee0c38c019ea7bfa0953d174809d25b18588dd8d \
  b5b1b641c0648c83661fa9eda991cd3eff945264dabc2cdf411a80dfe7ec0970 \
  76260fb34f4ee622ff0a66b857e5954aa49c7e343a92e57a1ec4a760618c94b2
do
  grep -Fq "$expected_sha256" "$helper"
done
# This is the literal helper source text, not a value to expand here.
# shellcheck disable=SC2016
grep -Fq 'case "${system}/${machine}" in' "$helper"
grep -Fq 'sha256sum --check --strict' "$helper"
grep -Fq 'shasum -a 256 --check' "$helper"
grep -Fq 'unzip -q' "$helper"
grep -Fq 'git lfs install --local' "$helper"
grep -Fq 'git lfs fsck --pointers HEAD' "$helper"
grep -Fq 'credential.https://lfs.pitchai.net.helper' "$helper"
grep -Fq 'PITCHAI_LFS_GITHUB_TOKEN' "$helper"
if grep -Fq 'git config --global' "$helper"; then
  echo 'The LFS helper must not persist global Git configuration.' >&2
  exit 1
fi

mapfile -t paths < <(
  awk '$2 == "filter=lfs" && $3 == "diff=lfs" && $4 == "merge=lfs" && $5 == "-text" {print $1}' \
    .gitattributes | LC_ALL=C sort
)
if [[ "${#paths[@]}" -ne 1 ]]; then
  echo "Expected exactly 1 Git LFS path; found ${#paths[@]}." >&2
  exit 1
fi

path_set_sha256="$(printf '%s\n' "${paths[@]}" | sha256sum | awk '{print $1}')"
if [[ "$path_set_sha256" != 7e075e1cae34566e67985b30ddc7be7773747634e6dee047655961823cd42652 ]]; then
  echo "Unexpected Git LFS path set: $path_set_sha256" >&2
  exit 1
fi

for path in "${paths[@]}"; do
  if [[ "$path" == *'*'* || "$path" == *'?'* || "$path" == *'['* ]]; then
    echo "Git LFS paths must be exact, not patterns: $path" >&2
    exit 1
  fi
  grep -Fqx "$path filter=lfs diff=lfs merge=lfs -text" .gitattributes
  pointer="$(git show ":$path")"
  grep -Fqx 'version https://git-lfs.github.com/spec/v1' <<<"$pointer"
  grep -Eq '^oid sha256:[0-9a-f]{64}$' <<<"$pointer"
  grep -Eq '^size [0-9]+$' <<<"$pointer"
done

actual_path_count="$(grep -c ' filter=lfs diff=lfs merge=lfs -text$' .gitattributes)"
if [[ "$actual_path_count" -ne 1 ]]; then
  echo "Expected exactly 1 Git LFS attribute; found $actual_path_count." >&2
  exit 1
fi

echo 'Git LFS migration contract checks passed.'
