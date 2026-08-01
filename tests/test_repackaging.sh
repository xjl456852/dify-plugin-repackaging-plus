#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS_COUNT=0
FAIL_COUNT=0

fail() {
  printf 'not ok - %s\n' "$1"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

pass() {
  printf 'ok - %s\n' "$1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

assert_eq() {
  local expected=$1 actual=$2 name=$3
  if [[ "$actual" == "$expected" ]]; then
    pass "$name"
  else
    fail "$name (expected=$expected actual=$actual)"
  fi
}

assert_file_contains() {
  local file=$1 expected=$2 name=${3:-"$file contains $expected"}
  if grep -Fq -- "$expected" "$file"; then
    pass "$name"
  else
    fail "$name"
  fi
}

assert_file_not_contains() {
  local file=$1 unexpected=$2 name=${3:-"$file excludes $unexpected"}
  if grep -Fq -- "$unexpected" "$file"; then
    fail "$name"
  else
    pass "$name"
  fi
}

assert_file_missing() {
  local file=$1 name=${2:-"$file is absent"}
  if [[ ! -e "$file" ]]; then
    pass "$name"
  else
    fail "$name"
  fi
}

assert_file_starts_with() {
  local file=$1 expected=$2 name=${3:-"$file has expected prefix"}
  if [[ "$(head -n2 "$file")" == "$expected" ]]; then
    pass "$name"
  else
    fail "$name"
  fi
}

source "$ROOT_DIR/plugin_repackaging.sh"

assert_eq x86_64 "$(normalize_arch amd64)" 'amd64 normalizes to x86_64'
assert_eq aarch64 "$(normalize_arch arm64)" 'arm64 normalizes to aarch64'
assert_eq dify-plugin-linux-amd64-5g "$(packager_name_for_host x86_64)" 'x86 host packager'
assert_eq dify-plugin-linux-arm64-5g "$(packager_name_for_host aarch64)" 'arm host packager'
assert_eq cp312 "$(python_abi 3.12)" 'Python 3.12 ABI'
assert_eq $'manylinux_2_28_aarch64\nmanylinux2014_aarch64' "$(default_platforms aarch64)" 'ARM64 platform set'
assert_eq custom_aarch64 "$(DIFY_MANYLINUX_PLATFORMS=custom_aarch64 default_platforms aarch64)" 'platform override'

if grep -q 'DIFY_TARGET_ARCH=aarch64' "$ROOT_DIR/plugin_repackaging_amd64_to_arm64.sh" &&
  grep -q 'exec .*plugin_repackaging.sh' "$ROOT_DIR/plugin_repackaging_amd64_to_arm64.sh"; then
  pass 'cross-architecture wrapper delegates to unified script'
else
  fail 'cross-architecture wrapper delegates to unified script'
fi

printf '%s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
((FAIL_COUNT == 0))
