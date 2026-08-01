#!/usr/bin/env bash
# author: xiejianglei
set -Eeuo pipefail

PIP_MIRROR_URL="${PIP_MIRROR_URL:-https://mirrors.aliyun.com/pypi/simple}"

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

detect_python_version() {
  local plugin_dir=$1
  local requested=${DIFY_PYTHON_VERSION:-}
  local detected=

  if [[ -n "$requested" ]]; then
    printf '%s\n' "$requested"
    return
  fi

  if [[ -f "$plugin_dir/.python-version" ]]; then
    detected="$(tr -d '[:space:]' <"$plugin_dir/.python-version")"
  elif [[ -f "$plugin_dir/pyproject.toml" ]]; then
    detected="$(
      sed -nE \
        's/^[[:space:]]*requires-python[[:space:]]*=[[:space:]]*"[^0-9]*([0-9]+\.[0-9]+).*"/\1/p' \
        "$plugin_dir/pyproject.toml" | head -n1
    )"
  fi

  printf '%s\n' "${detected:-3.12}"
}

export_requirements_from_uv() {
  local plugin_dir=$1
  local output=$2
  local uv_command=${DIFY_UV_COMMAND:-uv}
  local -a args=(
    export
    --format requirements.txt
    --no-group dev
    --no-emit-project
    --no-hashes
    --no-header
    --no-annotate
  )

  if [[ -f "$plugin_dir/uv.lock" ]]; then
    args+=(--frozen)
  fi

  (cd "$plugin_dir" && "$uv_command" "${args[@]}") >"$output"
}

prepare_download_requirements() {
  local plugin_dir=$1
  local output=$2

  if [[ -f "$plugin_dir/requirements.txt" ]]; then
    sed -E \
      '/^[[:space:]]*--(no-index|find-links)([=[:space:]].*)?$/d' \
      "$plugin_dir/requirements.txt" >"$output"
  elif [[ -f "$plugin_dir/pyproject.toml" ]]; then
    export_requirements_from_uv "$plugin_dir" "$output"
  else
    : >"$output"
  fi
}

sanitize_difyignore() {
  local ignore_file=$1

  [[ -f "$ignore_file" ]] || return 0
  sed -i -E \
    -e '\#^[[:space:]]*/?wheels(/(\*\*)?)?/?[[:space:]]*$#d' \
    -e '\#^[[:space:]]*/?uv\.toml[[:space:]]*$#d' \
    "$ignore_file"
}

write_offline_metadata() {
  local plugin_dir=$1
  local clean_requirements=$2

  {
    printf '%s\n' '--no-index' '--find-links=./wheels'
    cat "$clean_requirements"
  } >"$plugin_dir/requirements.txt"

  cat >"$plugin_dir/uv.toml" <<'EOF'
offline = true

[[index]]
name = "dify-offline-wheels"
url = "./wheels"
format = "flat"
default = true
EOF

  rm -f -- "$plugin_dir/uv.lock"
  sanitize_difyignore "$plugin_dir/.difyignore"
}

resolve_pip_command() {
  local -n result=$1

  if [[ -n "${DIFY_PIP_COMMAND:-}" ]]; then
    read -r -a result <<<"$DIFY_PIP_COMMAND"
  elif python3 -m pip --version >/dev/null 2>&1; then
    result=(python3 -m pip)
  elif command -v pip >/dev/null 2>&1; then
    result=(pip)
  elif command -v pip3 >/dev/null 2>&1; then
    result=(pip3)
  else
    printf 'pip not found; install python3-pip or set DIFY_PIP_COMMAND\n' >&2
    return 1
  fi
}

reset_wheels_dir() {
  local wheels_dir=$1
  local parent

  parent="$(dirname "$wheels_dir")"
  if [[ "$(basename "$wheels_dir")" != wheels || "$parent" == / || "$parent" == . ]]; then
    printf 'refusing to reset unsafe wheels path: %s\n' "$wheels_dir" >&2
    return 1
  fi

  rm -rf -- "$wheels_dir"
  mkdir -p "$wheels_dir"
}

download_wheels() {
  local requirements=$1
  local wheels_dir=$2
  local target_arch=$3
  local python_version=$4
  local abi platform
  local -a pip_command=()
  local -a platform_args=()

  reset_wheels_dir "$wheels_dir"
  if ! grep -Eq '^[[:space:]]*[^#[:space:]]' "$requirements"; then
    return 0
  fi

  resolve_pip_command pip_command
  abi="$(python_abi "$python_version")"
  while IFS= read -r platform; do
    [[ -n "$platform" ]] && platform_args+=(--platform "$platform")
  done < <(default_platforms "$target_arch")

  "${pip_command[@]}" download \
    --index-url "$PIP_MIRROR_URL" \
    --python-version "$python_version" \
    --implementation cp \
    --abi "$abi" \
    "${platform_args[@]}" \
    --only-binary=:all: \
    --requirement "$requirements" \
    --dest "$wheels_dir"
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
