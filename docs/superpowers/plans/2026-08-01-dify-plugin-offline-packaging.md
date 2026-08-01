# Dify Plugin Version-Independent Offline Packaging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make both existing commands produce architecture-correct Dify plugin packages whose requirements and uv project installation paths resolve exclusively from bundled wheels.

**Architecture:** `plugin_repackaging.sh` becomes the sourceable, strict-mode implementation and separates host architecture from target wheel architecture. The AMD64-to-ARM64 script becomes a compatibility wrapper. A fresh staging directory is normalized into a dual-path offline project, verified with uv for the target platform, packaged with the host CLI, and structurally inspected before success is reported.

**Tech Stack:** Bash 4+, pip download, uv 0.7.21+, unzip/zip-compatible `.difypkg` archives, Dify plugin CLI, Docker for the optional ARM64 daemon verification.

**End-to-end implementation note:** Real `uv 0.11.24` validation found that universal locking also resolves default development groups and non-target platforms. The final implementation therefore removes modern `[dependency-groups]` and legacy `[tool.uv].dev-dependencies` / `default-groups` from the staged runtime copy, and writes a Linux/architecture/Python-specific `[tool.uv].environments` marker into `pyproject.toml`. `uv.toml` remains responsible only for offline mode and the local flat index because `environments` is not valid in that configuration file.

---

## File Structure

- Modify `plugin_repackaging.sh`: unified CLI, dependency export/download, offline metadata, validation, packaging, cleanup.
- Modify `plugin_repackaging_amd64_to_arm64.sh`: ARM64 target compatibility wrapper.
- Create `tests/test_repackaging.sh`: dependency-free Bash regression and orchestration tests.
- Modify `README.md`: prerequisites, compatibility model, normal and cross-architecture use, advanced overrides, failure semantics.
- Use `langgenius-openai_api_compatible_0.0.57.difypkg`: local end-to-end fixture only; do not commit generated or extracted artifacts.

### Task 1: Add the RED test harness for architecture and entrypoint behavior

**Files:**

- Create: `tests/test_repackaging.sh`
- Test: `tests/test_repackaging.sh`

- [ ] **Step 1: Create a minimal Bash test harness**

```bash
#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS_COUNT=0
FAIL_COUNT=0

fail() { printf 'not ok - %s\n' "$1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
pass() { printf 'ok - %s\n' "$1"; PASS_COUNT=$((PASS_COUNT + 1)); }
assert_eq() {
  local expected=$1 actual=$2 name=$3
  if [[ "$actual" == "$expected" ]]; then pass "$name"; else fail "$name (expected=$expected actual=$actual)"; fi
}
assert_file_contains() {
  local file=$1 expected=$2 name=${3:-"$file contains $expected"}
  grep -Fq -- "$expected" "$file" && pass "$name" || fail "$name"
}
assert_file_not_contains() {
  local file=$1 unexpected=$2 name=${3:-"$file excludes $unexpected"}
  if grep -Fq -- "$unexpected" "$file"; then fail "$name"; else pass "$name"; fi
}
assert_file_missing() {
  local file=$1 name=${2:-"$file is absent"}
  [[ ! -e "$file" ]] && pass "$name" || fail "$name"
}
assert_file_starts_with() {
  local file=$1 expected=$2 name=${3:-"$file has expected prefix"}
  [[ "$(head -n2 "$file")" == "$expected" ]] && pass "$name" || fail "$name"
}

source "$ROOT_DIR/plugin_repackaging.sh"
```

- [ ] **Step 2: Add tests for normalized architectures, host packager selection, Python ABI, target platforms, and the wrapper**

```bash
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
(( FAIL_COUNT == 0 ))
```

- [ ] **Step 3: Run the tests and verify RED**

Run: `wsl.exe --distribution Ubuntu-24.04 -u xiejl -- bash -lc 'cd /mnt/h/code/dify-plugin-repackaging-plus && bash tests/test_repackaging.sh'`

Expected: FAIL because the existing script dispatches while sourced and the required functions/wrapper do not exist.

### Task 2: Implement the unified, sourceable architecture core

**Files:**

- Modify: `plugin_repackaging.sh`
- Modify: `plugin_repackaging_amd64_to_arm64.sh`
- Test: `tests/test_repackaging.sh`

- [ ] **Step 1: Replace top-level execution with strict-mode helpers and a guarded `main`**

```bash
#!/usr/bin/env bash
# author: xiejianglei
set -Eeuo pipefail

normalize_arch() {
  case "$1" in
    x86_64|amd64) printf 'x86_64\n' ;;
    aarch64|arm64) printf 'aarch64\n' ;;
    *) printf 'unsupported architecture: %s\n' "$1" >&2; return 1 ;;
  esac
}

packager_name_for_host() {
  case "$(normalize_arch "$1")" in
    x86_64) printf 'dify-plugin-linux-amd64-5g\n' ;;
    aarch64) printf 'dify-plugin-linux-arm64-5g\n' ;;
  esac
}

python_abi() {
  local version=${1//./}
  printf 'cp%s\n' "$version"
}

default_platforms() {
  local suffix
  if [[ -n "${DIFY_MANYLINUX_PLATFORMS:-}" ]]; then
    tr ',' '\n' <<< "$DIFY_MANYLINUX_PLATFORMS"
    return
  fi
  case "$(normalize_arch "$1")" in
    x86_64) suffix=x86_64 ;;
    aarch64) suffix=aarch64 ;;
  esac
  printf 'manylinux_2_28_%s\nmanylinux2014_%s\n' "$suffix" "$suffix"
}

main() {
  case "${1:-}" in
    local) local_source "$@" ;;
    market) market_source "$@" ;;
    github) github_source "$@" ;;
    *) usage >&2; return 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
```

- [ ] **Step 2: Replace the cross-architecture implementation with a compatibility wrapper**

```bash
#!/usr/bin/env bash
# author: xiejianglei
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DIFY_TARGET_ARCH=aarch64
exec "$SCRIPT_DIR/plugin_repackaging.sh" "$@"
```

- [ ] **Step 3: Run the test and verify GREEN**

Run: `wsl.exe --distribution Ubuntu-24.04 -u xiejl -- bash -lc 'cd /mnt/h/code/dify-plugin-repackaging-plus && bash tests/test_repackaging.sh'`

Expected: all Task 1 assertions PASS.

- [ ] **Step 4: Commit the architecture core**

```bash
git add -- plugin_repackaging.sh plugin_repackaging_amd64_to_arm64.sh tests/test_repackaging.sh
git commit --no-verify -m "refactor: unify offline repackaging entrypoints"
```

### Task 3: Add and implement dual-path offline metadata normalization

**Files:**

- Modify: `tests/test_repackaging.sh`
- Modify: `plugin_repackaging.sh`

- [ ] **Step 1: Add failing fixture tests for Python detection, requirements directives, uv config, lock removal, and `.difyignore`**

```bash
fixture="$(mktemp -d)"
printf '3.12\n' > "$fixture/.python-version"
printf 'requests==2.34.2\n' > "$fixture/requirements.txt"
printf '[project]\nrequires-python = ">=3.12"\n' > "$fixture/pyproject.toml"
printf 'version = 1\n' > "$fixture/uv.lock"
printf 'wheels/\nuv.toml\n.venv/\n' > "$fixture/.difyignore"

assert_eq 3.12 "$(detect_python_version "$fixture")" 'reads .python-version'
prepare_download_requirements "$fixture" "$fixture/download.txt"
write_offline_metadata "$fixture" "$fixture/download.txt"
assert_file_starts_with "$fixture/requirements.txt" $'--no-index\n--find-links=./wheels'
assert_file_contains "$fixture/uv.toml" 'offline = true'
assert_file_contains "$fixture/uv.toml" 'format = "flat"'
assert_file_missing "$fixture/uv.lock"
assert_file_not_contains "$fixture/.difyignore" 'wheels/'
assert_file_not_contains "$fixture/.difyignore" 'uv.toml'
```

- [ ] **Step 2: Run the new tests and verify RED**

Run: `wsl.exe --distribution Ubuntu-24.04 -u xiejl -- bash -lc 'cd /mnt/h/code/dify-plugin-repackaging-plus && bash tests/test_repackaging.sh'`

Expected: FAIL because metadata functions are undefined.

- [ ] **Step 3: Implement input normalization and metadata writers**

```bash
detect_python_version() {
  local plugin_dir=$1 requested=${DIFY_PYTHON_VERSION:-}
  [[ -n "$requested" ]] && { printf '%s\n' "$requested"; return; }
  if [[ -f "$plugin_dir/.python-version" ]]; then
    tr -d '[:space:]' < "$plugin_dir/.python-version"
    return
  fi
  local detected
  detected="$(sed -nE 's/^[[:space:]]*requires-python[[:space:]]*=[[:space:]]*"[^0-9]*([0-9]+\.[0-9]+).*"/\1/p' "$plugin_dir/pyproject.toml" 2>/dev/null | head -n1)"
  printf '%s\n' "${detected:-3.12}"
}

prepare_download_requirements() {
  local plugin_dir=$1 output=$2
  if [[ -f "$plugin_dir/requirements.txt" ]]; then
    sed -E '/^[[:space:]]*--(no-index|find-links)([=[:space:]].*)?$/d' "$plugin_dir/requirements.txt" > "$output"
  elif [[ -f "$plugin_dir/pyproject.toml" ]]; then
    export_requirements_from_uv "$plugin_dir" "$output"
  else
    : > "$output"
  fi
}

export_requirements_from_uv() {
  local plugin_dir=$1 output=$2
  local -a args=(export --format requirements.txt --no-group dev --no-emit-project --no-hashes --no-header --no-annotate)
  [[ -f "$plugin_dir/uv.lock" ]] && args+=(--frozen)
  (cd "$plugin_dir" && "${DIFY_UV_COMMAND:-uv}" "${args[@]}") > "$output"
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
  local plugin_dir=$1 clean_requirements=$2
  {
    printf '%s\n' '--no-index' '--find-links=./wheels'
    cat "$clean_requirements"
  } > "$plugin_dir/requirements.txt"
  cat > "$plugin_dir/uv.toml" <<'EOF'
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
```

- [ ] **Step 4: Run tests and verify GREEN**

Run: `wsl.exe --distribution Ubuntu-24.04 -u xiejl -- bash -lc 'cd /mnt/h/code/dify-plugin-repackaging-plus && bash tests/test_repackaging.sh'`

Expected: all metadata assertions PASS.

- [ ] **Step 5: Commit dual-path metadata support**

```bash
git add -- plugin_repackaging.sh tests/test_repackaging.sh
git commit --no-verify -m "feat: add dual-path offline dependency metadata"
```

### Task 4: Add and implement strict target-platform wheel downloading

**Files:**

- Modify: `tests/test_repackaging.sh`
- Modify: `plugin_repackaging.sh`

- [ ] **Step 1: Add a fake pip command and a failing argument test**

```bash
fake_bin="$fixture/fake-bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/pip" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$PIP_ARGS_LOG"
while (($#)); do
  if [[ "$1" == -d || "$1" == --dest ]]; then shift; mkdir -p "$1"; touch "$1/example-1.0-py3-none-any.whl"; fi
  shift
done
EOF
chmod +x "$fake_bin/pip"
PIP_ARGS_LOG="$fixture/pip.args" DIFY_PIP_COMMAND="$fake_bin/pip" \
  download_wheels "$fixture/download.txt" "$fixture/wheels" aarch64 3.12
assert_file_contains "$fixture/pip.args" 'manylinux_2_28_aarch64'
assert_file_contains "$fixture/pip.args" 'manylinux2014_aarch64'
assert_file_contains "$fixture/pip.args" 'cp312'
assert_file_contains "$fixture/pip.args" '--only-binary=:all:'
```

- [ ] **Step 2: Run tests and verify RED**

Run: `wsl.exe --distribution Ubuntu-24.04 -u xiejl -- bash -lc 'cd /mnt/h/code/dify-plugin-repackaging-plus && bash tests/test_repackaging.sh'`

Expected: FAIL because `download_wheels` is undefined.

- [ ] **Step 3: Implement one-shot binary-only downloads without host fallback**

```bash
resolve_pip_command() {
  local -n result=$1
  if [[ -n "${DIFY_PIP_COMMAND:-}" ]]; then
    read -r -a result <<< "$DIFY_PIP_COMMAND"
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

download_wheels() {
  local requirements=$1 wheels_dir=$2 target_arch=$3 python_version=$4
  local abi platform
  local -a pip_cmd platform_args
  resolve_pip_command pip_cmd
  abi="$(python_abi "$python_version")"
  while IFS= read -r platform; do platform_args+=(--platform "$platform"); done < <(default_platforms "$target_arch")
  rm -rf -- "$wheels_dir"
  mkdir -p "$wheels_dir"
  "${pip_cmd[@]}" download \
    --index-url "$PIP_MIRROR_URL" \
    --python-version "$python_version" \
    --implementation cp \
    --abi "$abi" \
    "${platform_args[@]}" \
    --only-binary=:all: \
    --requirement "$requirements" \
    --dest "$wheels_dir"
}
```

The implementation must not contain any second download without `--platform`. An empty dependency file may skip pip and leave an empty wheelhouse.

- [ ] **Step 4: Add a fake pip nonzero result assertion and verify failure propagation**

```bash
cat > "$fake_bin/pip-fail" <<'EOF'
#!/usr/bin/env bash
exit 23
EOF
chmod +x "$fake_bin/pip-fail"
if DIFY_PIP_COMMAND="$fake_bin/pip-fail" download_wheels "$fixture/download.txt" "$fixture/wheels" aarch64 3.12; then
  fail 'pip failure stops wheel download'
else
  pass 'pip failure stops wheel download'
fi
```

- [ ] **Step 5: Run tests and verify GREEN**

Run: `wsl.exe --distribution Ubuntu-24.04 -u xiejl -- bash -lc 'cd /mnt/h/code/dify-plugin-repackaging-plus && bash tests/test_repackaging.sh'`

Expected: target arguments pass and fake pip exit 23 is propagated.

- [ ] **Step 6: Commit strict wheel downloading**

```bash
git add -- plugin_repackaging.sh tests/test_repackaging.sh
git commit --no-verify -m "fix: download exact target architecture wheels"
```

### Task 5: Add and implement offline validation and packaging orchestration

**Files:**

- Modify: `tests/test_repackaging.sh`
- Modify: `plugin_repackaging.sh`

- [ ] **Step 1: Add an end-to-end fixture with fake uv, pip, and Dify packager**

The fixture builds a source ZIP containing `.python-version`, `requirements.txt`, `pyproject.toml`, `uv.lock`, `.difyignore`, and `manifest.yaml`. Fake tools log calls. The fake packager resolves the source and output arguments, then zips the source directory:

```bash
cat > "$fake_bin/uv" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$UV_ARGS_LOG"
exit "${FAKE_UV_EXIT:-0}"
EOF
cat > "$fake_bin/dify-packager" <<'EOF'
#!/usr/bin/env bash
source_dir=$3
output=$5
(cd "$source_dir" && zip -qr "$output" .)
EOF
chmod +x "$fake_bin/uv" "$fake_bin/dify-packager"
```

Invoke:

```bash
PATH="$fake_bin:$PATH" \
DIFY_PIP_COMMAND="$fake_bin/pip" \
DIFY_UV_COMMAND="$fake_bin/uv" \
DIFY_PACKAGER_BINARY="$fake_bin/dify-packager" \
DIFY_TARGET_ARCH=aarch64 \
bash "$ROOT_DIR/plugin_repackaging.sh" local "$fixture/source plugin.difypkg"
```

Assert that `source plugin-offline.difypkg` exists, contains `requirements.txt`, `uv.toml`, `pyproject.toml`, and `wheels/example-1.0-py3-none-any.whl`, and does not contain `uv.lock`. Assert the uv log contains both `pip install --dry-run` and `sync --dry-run`. Add variants where each fake tool fails and assert the output package is not reported as successful.

- [ ] **Step 2: Run the end-to-end test and verify RED**

Run: `wsl.exe --distribution Ubuntu-24.04 -u xiejl -- bash -lc 'cd /mnt/h/code/dify-plugin-repackaging-plus && bash tests/test_repackaging.sh'`

Expected: FAIL because repackage orchestration and validation are not implemented.

- [ ] **Step 3: Implement command validation, unique staging, source download modes, offline dry-runs, packaging, and archive inspection**

```bash
verify_requirements_offline() {
  local plugin_dir=$1 target_arch=$2 python_version=$3 target
  target="$(target_triple "$target_arch")"
  (cd "$plugin_dir" && "$UV_COMMAND" pip install --dry-run --offline \
    --python-version "$python_version" --python-platform "$target" \
    --target .offline-verify -r requirements.txt)
  rm -rf -- "$plugin_dir/.offline-verify"
}

verify_pyproject_offline() {
  local plugin_dir=$1 target_arch=$2
  [[ -f "$plugin_dir/pyproject.toml" ]] || return 0
  (cd "$plugin_dir" && "$UV_COMMAND" sync --dry-run --offline --no-dev \
    --python-platform "$(target_triple "$target_arch")")
  rm -f -- "$plugin_dir/uv.lock"
}

target_triple() {
  case "$(normalize_arch "$1")" in
    x86_64) printf 'x86_64-unknown-linux-gnu\n' ;;
    aarch64) printf 'aarch64-unknown-linux-gnu\n' ;;
  esac
}

verify_output_archive() {
  local output=$1 requires_wheel=$2 requires_pyproject=$3 entries
  unzip -tq "$output" >/dev/null
  entries="$(unzip -Z1 "$output")"
  grep -qx 'requirements.txt' <<< "$entries"
  grep -qx 'uv.toml' <<< "$entries"
  ! grep -Eq '(^|/)uv\.lock$' <<< "$entries"
  [[ "$requires_wheel" != true ]] || grep -Eq '^wheels/.+\.whl$' <<< "$entries"
  [[ "$requires_pyproject" != true ]] || grep -qx 'pyproject.toml' <<< "$entries"
  if [[ "$TARGET_ARCH" == aarch64 ]]; then
    ! grep -E '^wheels/.+x86_64.+\.whl$' <<< "$entries"
  fi
}

repackage() {
  local package_path=$1 package_name staging plugin_dir output python_version
  package_name="$(basename "${package_path%.*}")"
  staging="$(mktemp -d "$SCRIPT_DIR/.dify-repackaging.XXXXXX")"
  ACTIVE_STAGING=$staging
  plugin_dir="$staging/plugin"
  output="$SCRIPT_DIR/${package_name}-offline.difypkg"
  mkdir -p "$plugin_dir"
  unzip -q -o "$package_path" -d "$plugin_dir"
  python_version="$(detect_python_version "$plugin_dir")"
  prepare_download_requirements "$plugin_dir" "$staging/download-requirements.txt"
  download_wheels "$staging/download-requirements.txt" "$plugin_dir/wheels" "$TARGET_ARCH" "$python_version"
  write_offline_metadata "$plugin_dir" "$staging/download-requirements.txt"
  verify_requirements_offline "$plugin_dir" "$TARGET_ARCH" "$python_version"
  verify_pyproject_offline "$plugin_dir" "$TARGET_ARCH"
  "$PACKAGER_BINARY" plugin package "$plugin_dir" -o "$output"
  verify_output_archive "$output" "$(test -s "$staging/download-requirements.txt" && printf true || printf false)" "$(test -f "$plugin_dir/pyproject.toml" && printf true || printf false)"
  printf 'Repackage success.\nOutput: %s\n' "$output"
}
```

Initialize runtime state and source modes with the following interfaces:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MARKETPLACE_API_URL="${MARKETPLACE_API_URL:-https://marketplace.dify.ai}"
PIP_MIRROR_URL="${PIP_MIRROR_URL:-https://mirrors.aliyun.com/pypi/simple}"
UV_COMMAND="${DIFY_UV_COMMAND:-uv}"
HOST_ARCH="$(normalize_arch "$(uname -m)")"
TARGET_ARCH="$(normalize_arch "${DIFY_TARGET_ARCH:-$HOST_ARCH}")"
PACKAGER_BINARY="${DIFY_PACKAGER_BINARY:-$SCRIPT_DIR/$(packager_name_for_host "$HOST_ARCH")}" 
ACTIVE_STAGING=

cleanup_active_staging() {
  [[ -n "$ACTIVE_STAGING" ]] || return 0
  case "$ACTIVE_STAGING" in
    "$SCRIPT_DIR"/.dify-repackaging.*)
      [[ -d "$ACTIVE_STAGING" ]] && rm -rf -- "$ACTIVE_STAGING"
      ;;
    *) printf 'refusing to clean unsafe staging path: %s\n' "$ACTIVE_STAGING" >&2; return 1 ;;
  esac
}

usage() {
  printf 'Usage: %s {local <difypkg>|market <author> <name> <version>|github <repo> <release> <asset>}\n' "$0"
}

local_source() {
  [[ $# -eq 2 ]] || { usage >&2; return 1; }
  repackage "$(realpath -- "$2")"
}

market_source() {
  [[ $# -eq 4 ]] || { usage >&2; return 1; }
  local output="$SCRIPT_DIR/$2-$3_$4.difypkg"
  curl --fail --location --show-error --output "$output" \
    "$MARKETPLACE_API_URL/api/v1/plugins/$2/$3/$4/download"
  repackage "$output"
}

github_source() {
  [[ $# -eq 4 ]] || { usage >&2; return 1; }
  local repo=$2 release=$3 asset=$4 output
  [[ "$repo" == https://github.com/* ]] || repo="https://github.com/$repo"
  output="$SCRIPT_DIR/${asset%.difypkg}-$release.difypkg"
  curl --fail --location --show-error --output "$output" "$repo/releases/download/$release/$asset"
  repackage "$output"
}
```

All paths are quoted. Cleanup validates that `ACTIVE_STAGING` is a child matching `$SCRIPT_DIR/.dify-repackaging.*` before recursive deletion. `verify_output_archive` reads `unzip -Z1`, requires `requirements.txt` and `uv.toml`, conditionally requires a wheel and `pyproject.toml`, and rejects `uv.lock` plus any wheel name containing `x86_64` when the target is ARM64.

- [ ] **Step 4: Run tests and verify GREEN**

Run: `wsl.exe --distribution Ubuntu-24.04 -u xiejl -- bash -lc 'cd /mnt/h/code/dify-plugin-repackaging-plus && bash tests/test_repackaging.sh'`

Expected: all unit and fake end-to-end tests PASS; failure variants return nonzero.

- [ ] **Step 5: Run syntax checks**

Run: `wsl.exe --distribution Ubuntu-24.04 -u xiejl -- bash -lc 'cd /mnt/h/code/dify-plugin-repackaging-plus && bash -n plugin_repackaging.sh plugin_repackaging_amd64_to_arm64.sh tests/test_repackaging.sh'`

Expected: exit 0 with no output.

- [ ] **Step 6: Commit orchestration**

```bash
git add -- plugin_repackaging.sh tests/test_repackaging.sh
git commit --no-verify -m "feat: verify and package offline plugin environments"
```

### Task 6: Document and verify the real ARM64 package

**Files:**

- Modify: `README.md`
- Test: `tests/test_repackaging.sh`
- Fixture: `langgenius-openai_api_compatible_0.0.57.difypkg`

- [ ] **Step 1: Rewrite README usage and compatibility sections**

Document prerequisites, unchanged commands, automatic Python detection, dual requirements/uv compatibility, strict target-wheel behavior, `DIFY_PYTHON_VERSION`, `DIFY_TARGET_ARCH`, `DIFY_MANYLINUX_PLATFORMS`, and the fact that packages without binary wheels fail intentionally.

- [ ] **Step 2: Run all automated tests and syntax checks**

Run:

```powershell
wsl.exe --distribution Ubuntu-24.04 -u xiejl -- bash -lc 'cd /mnt/h/code/dify-plugin-repackaging-plus && bash tests/test_repackaging.sh && bash -n plugin_repackaging.sh plugin_repackaging_amd64_to_arm64.sh tests/test_repackaging.sh'
```

Expected: all assertions pass and exit code is 0.

- [ ] **Step 3: Create a temporary pip-enabled uv environment and run the real cross-architecture package command**

Run:

```powershell
wsl.exe --distribution Ubuntu-24.04 -u xiejl -- bash -lc 'uv venv /tmp/dify-repackaging-e2e/.venv --python 3.12 --seed && cd /mnt/h/code/dify-plugin-repackaging-plus && DIFY_PIP_COMMAND=/tmp/dify-repackaging-e2e/.venv/bin/pip ./plugin_repackaging_amd64_to_arm64.sh local langgenius-openai_api_compatible_0.0.57.difypkg'
```

Expected: command exits 0 and creates `langgenius-openai_api_compatible_0.0.57-offline.difypkg`.

- [ ] **Step 4: Inspect the real output wheel architecture, pinned versions, and metadata**

Run:

```powershell
wsl.exe --distribution Ubuntu-24.04 -u xiejl -- bash -lc 'cd /mnt/h/code/dify-plugin-repackaging-plus && unzip -Z1 langgenius-openai_api_compatible_0.0.57-offline.difypkg | tee /tmp/dify-offline-entries.txt && ! grep -q x86_64 /tmp/dify-offline-entries.txt && grep -q wheels/pyyaml-6.0.3 /tmp/dify-offline-entries.txt && grep -q wheels/gevent-26.5.0 /tmp/dify-offline-entries.txt && grep -q wheels/greenlet-3.5.1 /tmp/dify-offline-entries.txt && grep -q wheels/tiktoken-0.13.0 /tmp/dify-offline-entries.txt && grep -q wheels/idna-3.16 /tmp/dify-offline-entries.txt && grep -qx uv.toml /tmp/dify-offline-entries.txt && ! grep -qx uv.lock /tmp/dify-offline-entries.txt'
```

Expected: exit 0; no x86_64 wheel or uv lock is present.

- [ ] **Step 5: Run an ARM64/no-network container validation when Docker supports the image**

Mount an extracted copy of the generated package read-only into `langgenius/dify-plugin-daemon:0.6.3-local`, copy it to the container temporary filesystem, and run both uv dry-runs with `--network none`. Expected: both dependency paths resolve without a connection attempt.

- [ ] **Step 6: Commit documentation and tests**

```bash
git add -- README.md tests/test_repackaging.sh
git commit --no-verify -m "docs: explain version-independent offline packaging"
```

- [ ] **Step 7: Run final verification and inspect the final diff**

Run:

```powershell
wsl.exe --distribution Ubuntu-24.04 -u xiejl -- bash -lc 'cd /mnt/h/code/dify-plugin-repackaging-plus && bash tests/test_repackaging.sh && bash -n plugin_repackaging.sh plugin_repackaging_amd64_to_arm64.sh tests/test_repackaging.sh'
git status --short
git log --oneline --decorate -6
```

Expected: tests and syntax checks exit 0; only user-owned/generated artifacts remain untracked; implementation commits are visible.
