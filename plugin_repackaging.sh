#!/usr/bin/env bash
# author: xiejianglei
set -Eeuo pipefail

normalize_arch() {
  case "$1" in
    x86_64 | amd64)
      printf 'x86_64\n'
      ;;
    aarch64 | arm64)
      printf 'aarch64\n'
      ;;
    *)
      printf 'unsupported architecture: %s\n' "$1" >&2
      return 1
      ;;
  esac
}

packager_name_for_host() {
  case "$(normalize_arch "$1")" in
    x86_64)
      printf 'dify-plugin-linux-amd64-5g\n'
      ;;
    aarch64)
      printf 'dify-plugin-linux-arm64-5g\n'
      ;;
  esac
}

python_abi() {
  local version=${1//./}
  printf 'cp%s\n' "$version"
}

default_platforms() {
  local suffix

  if [[ -n "${DIFY_MANYLINUX_PLATFORMS:-}" ]]; then
    tr ',' '\n' <<<"$DIFY_MANYLINUX_PLATFORMS"
    return
  fi

  case "$(normalize_arch "$1")" in
    x86_64)
      suffix=x86_64
      ;;
    aarch64)
      suffix=aarch64
      ;;
  esac
  printf 'manylinux_2_28_%s\nmanylinux2014_%s\n' "$suffix" "$suffix"
}

usage() {
  printf 'Usage: %s {local <difypkg>|market <author> <name> <version>|github <repo> <release> <asset>}\n' "$0"
}

main() {
  case "${1:-}" in
    local)
      local_source "$@"
      ;;
    market)
      market_source "$@"
      ;;
    github)
      github_source "$@"
      ;;
    *)
      usage >&2
      return 1
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
