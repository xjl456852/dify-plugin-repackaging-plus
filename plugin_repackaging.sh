#!/usr/bin/env bash
# author: xiejianglei
set -Eeuo pipefail

GITHUB_API_URL="${GITHUB_API_URL:-https://github.com}"
MARKETPLACE_API_URL="${MARKETPLACE_API_URL:-https://marketplace.dify.ai}"
PIP_MIRROR_URL="${PIP_MIRROR_URL:-https://mirrors.aliyun.com/pypi/simple}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST_ARCH=
TARGET_ARCH=
PACKAGER_BINARY=
ACTIVE_STAGING=
ACTIVE_OUTPUT=
BUILD_SUCCEEDED=false

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

target_triple() {
  case "$(normalize_arch "$1")" in
    x86_64)
      printf 'x86_64-unknown-linux-gnu\n'
      ;;
    aarch64)
      printf 'aarch64-unknown-linux-gnu\n'
      ;;
  esac
}

verify_requirements_offline() {
  local plugin_dir=$1
  local target_arch=$2
  local python_version=$3
  local uv_command=${DIFY_UV_COMMAND:-uv}

  (
    cd "$plugin_dir"
    "$uv_command" pip install \
      --dry-run \
      --offline \
      --python-version "$python_version" \
      --python-platform "$(target_triple "$target_arch")" \
      --target .offline-verify \
      --requirement requirements.txt
  )
  rm -rf -- "$plugin_dir/.offline-verify"
}

verify_pyproject_offline() {
  local plugin_dir=$1
  local target_arch=$2
  local uv_command=${DIFY_UV_COMMAND:-uv}

  [[ -f "$plugin_dir/pyproject.toml" ]] || return 0
  (
    cd "$plugin_dir"
    "$uv_command" sync \
      --dry-run \
      --offline \
      --no-dev \
      --python-platform "$(target_triple "$target_arch")"
  )
  rm -f -- "$plugin_dir/uv.lock"
}

verify_output_archive() {
  local output=$1
  local requires_wheel=$2
  local requires_pyproject=$3
  local target_arch=$4
  local entries

  unzip -tq "$output" >/dev/null
  entries="$(unzip -Z1 "$output")"

  grep -qx 'requirements.txt' <<<"$entries"
  grep -qx 'uv.toml' <<<"$entries"
  ! grep -Eq '(^|/)uv\.lock$' <<<"$entries"
  [[ "$requires_wheel" != true ]] || grep -Eq '^wheels/.+\.whl$' <<<"$entries"
  [[ "$requires_pyproject" != true ]] || grep -qx 'pyproject.toml' <<<"$entries"

  if [[ "$target_arch" == aarch64 ]]; then
    ! grep -E '^wheels/.+x86_64.+\.whl$' <<<"$entries"
  fi
}

cleanup_active_staging() {
  [[ -n "$ACTIVE_STAGING" ]] || return 0

  case "$ACTIVE_STAGING" in
    "$SCRIPT_DIR"/.dify-repackaging.*)
      [[ -d "$ACTIVE_STAGING" ]] && rm -rf -- "$ACTIVE_STAGING"
      ACTIVE_STAGING=
      ;;
    *)
      printf 'refusing to clean unsafe staging path: %s\n' "$ACTIVE_STAGING" >&2
      return 1
      ;;
  esac
}

cleanup_runtime() {
  local status=$?

  cleanup_active_staging || status=$?
  if [[ "$BUILD_SUCCEEDED" != true && -n "$ACTIVE_OUTPUT" ]]; then
    case "$ACTIVE_OUTPUT" in
      "$SCRIPT_DIR"/*-offline.difypkg)
        rm -f -- "$ACTIVE_OUTPUT"
        ;;
      *)
        printf 'refusing to clean unsafe output path: %s\n' "$ACTIVE_OUTPUT" >&2
        status=1
        ;;
    esac
  fi
  return "$status"
}

initialize_runtime() {
  local uv_command=${DIFY_UV_COMMAND:-uv}

  HOST_ARCH="$(normalize_arch "$(uname -m)")"
  TARGET_ARCH="$(normalize_arch "${DIFY_TARGET_ARCH:-$HOST_ARCH}")"
  PACKAGER_BINARY="${DIFY_PACKAGER_BINARY:-$SCRIPT_DIR/$(packager_name_for_host "$HOST_ARCH")}" 

  command -v unzip >/dev/null 2>&1 || {
    printf 'unzip not found\n' >&2
    return 1
  }
  command -v realpath >/dev/null 2>&1 || {
    printf 'realpath not found\n' >&2
    return 1
  }
  if [[ ! -x "$uv_command" ]] && ! command -v "$uv_command" >/dev/null 2>&1; then
    printf 'uv not found: %s\n' "$uv_command" >&2
    return 1
  fi
  if [[ ! -f "$PACKAGER_BINARY" ]]; then
    printf 'Dify packager not found: %s\n' "$PACKAGER_BINARY" >&2
    return 1
  fi
  chmod +x "$PACKAGER_BINARY"
}

repackage() {
  local package_path=$1
  local package_filename package_name staging plugin_dir output python_version
  local requires_wheel=false
  local requires_pyproject=false

  package_filename="$(basename "$package_path")"
  package_name="${package_filename%.*}"
  output="$SCRIPT_DIR/${package_name}-offline.difypkg"
  ACTIVE_OUTPUT=$output
  BUILD_SUCCEEDED=false
  rm -f -- "$output"

  staging="$(mktemp -d "$SCRIPT_DIR/.dify-repackaging.XXXXXX")"
  ACTIVE_STAGING=$staging
  plugin_dir="$staging/plugin"
  mkdir -p "$plugin_dir"

  printf 'Unpacking %s ...\n' "$package_filename"
  unzip -q -o "$package_path" -d "$plugin_dir"
  python_version="$(detect_python_version "$plugin_dir")"
  printf 'Target: Python %s, %s\n' "$python_version" "$TARGET_ARCH"

  prepare_download_requirements "$plugin_dir" "$staging/download-requirements.txt"
  if grep -Eq '^[[:space:]]*[^#[:space:]]' "$staging/download-requirements.txt"; then
    requires_wheel=true
  fi
  [[ -f "$plugin_dir/pyproject.toml" ]] && requires_pyproject=true

  download_wheels \
    "$staging/download-requirements.txt" \
    "$plugin_dir/wheels" \
    "$TARGET_ARCH" \
    "$python_version"
  write_offline_metadata "$plugin_dir" "$staging/download-requirements.txt"

  printf 'Verifying requirements.txt offline path ...\n'
  verify_requirements_offline "$plugin_dir" "$TARGET_ARCH" "$python_version"
  if [[ "$requires_pyproject" == true ]]; then
    printf 'Verifying pyproject.toml offline path ...\n'
    verify_pyproject_offline "$plugin_dir" "$TARGET_ARCH"
  fi

  "$PACKAGER_BINARY" plugin package "$plugin_dir" -o "$output"
  verify_output_archive "$output" "$requires_wheel" "$requires_pyproject" "$TARGET_ARCH"

  BUILD_SUCCEEDED=true
  cleanup_active_staging
  printf 'Repackage success.\nOutput: %s\n' "$output"
}

usage() {
  printf 'Usage: %s {local <difypkg>|market <author> <name> <version>|github <repo> <release> <asset>}\n' "$0"
}

local_source() {
  local package_path

  [[ $# -eq 2 ]] || {
    usage >&2
    return 1
  }
  [[ -f "$2" ]] || {
    printf 'plugin package not found: %s\n' "$2" >&2
    return 1
  }
  package_path="$(realpath -- "$2")"
  repackage "$package_path"
}

market_source() {
  local output

  [[ $# -eq 4 ]] || {
    usage >&2
    return 1
  }
  command -v curl >/dev/null 2>&1 || {
    printf 'curl not found\n' >&2
    return 1
  }
  output="$SCRIPT_DIR/$2-$3_$4.difypkg"
  curl --fail --location --show-error --output "$output" \
    "$MARKETPLACE_API_URL/api/v1/plugins/$2/$3/$4/download"
  repackage "$output"
}

github_source() {
  [[ $# -eq 4 ]] || {
    usage >&2
    return 1
  }
  local repo=$2
  local release=$3
  local asset=$4
  local output

  command -v curl >/dev/null 2>&1 || {
    printf 'curl not found\n' >&2
    return 1
  }
  if [[ "$repo" != "$GITHUB_API_URL"/* ]]; then
    repo="$GITHUB_API_URL/$repo"
  fi
  output="$SCRIPT_DIR/${asset%.difypkg}-$release.difypkg"
  curl --fail --location --show-error --output "$output" \
    "$repo/releases/download/$release/$asset"
  repackage "$output"
}

main() {
  initialize_runtime
  trap cleanup_runtime EXIT

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
