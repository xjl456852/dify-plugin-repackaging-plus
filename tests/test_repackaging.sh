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

FIXTURE_DIR="$(mktemp -d /tmp/dify-repackaging-tests.XXXXXX)"
GENERATED_TEST_OUTPUT=

cleanup_test_files() {
  rm -rf -- "$FIXTURE_DIR"
  if [[ "$GENERATED_TEST_OUTPUT" == "$ROOT_DIR/source plugin-offline.difypkg" ]]; then
    rm -f -- "$GENERATED_TEST_OUTPUT"
  fi
}

trap cleanup_test_files EXIT

metadata_dir="$FIXTURE_DIR/metadata"
mkdir -p "$metadata_dir"
printf '3.12\n' >"$metadata_dir/.python-version"
printf '%s\n' '--no-index --find-links=./old-wheels' 'requests==2.34.2' >"$metadata_dir/requirements.txt"
printf '%s\n' \
  '[project]' \
  'requires-python = ">=3.12"' \
  '[dependency-groups]' \
  'dev = ["black>=26.5.1", "pytest>=9.0.3"]' \
  '[tool.example]' \
  'enabled = true' >"$metadata_dir/pyproject.toml"
printf 'version = 1\n' >"$metadata_dir/uv.lock"
printf '%s\n' 'wheels/' '/wheels/**' 'uv.toml' '.venv/' >"$metadata_dir/.difyignore"

assert_eq 3.12 "$(detect_python_version "$metadata_dir")" 'reads .python-version'
assert_eq 3.13 "$(DIFY_PYTHON_VERSION=3.13 detect_python_version "$metadata_dir")" 'Python version override'

prepare_download_requirements "$metadata_dir" "$metadata_dir/download.txt"
assert_file_not_contains "$metadata_dir/download.txt" '--no-index' 'download input strips old no-index directive'
assert_file_contains "$metadata_dir/download.txt" 'requests==2.34.2' 'download input keeps pinned requirement'

write_offline_metadata "$metadata_dir" "$metadata_dir/download.txt" aarch64 3.12
assert_file_starts_with "$metadata_dir/requirements.txt" $'--no-index\n--find-links=./wheels' 'requirements uses local wheelhouse only'
assert_file_contains "$metadata_dir/uv.toml" 'offline = true' 'uv config disables network'
assert_file_not_contains "$metadata_dir/uv.toml" 'environments' 'uv.toml contains only global settings'
assert_file_contains "$metadata_dir/pyproject.toml" '[tool.uv]' 'runtime pyproject contains uv project settings'
assert_file_contains "$metadata_dir/pyproject.toml" "sys_platform == 'linux'" 'uv resolution is limited to Linux'
assert_file_contains "$metadata_dir/pyproject.toml" "platform_machine == 'aarch64'" 'uv resolution is limited to ARM64'
assert_file_contains "$metadata_dir/pyproject.toml" "python_version == '3.12'" 'uv resolution is limited to target Python'
assert_file_contains "$metadata_dir/uv.toml" 'url = "./wheels"' 'uv config uses local wheelhouse'
assert_file_contains "$metadata_dir/uv.toml" 'format = "flat"' 'uv config declares flat index'
assert_file_contains "$metadata_dir/uv.toml" 'default = true' 'uv config replaces default registry'
assert_file_missing "$metadata_dir/uv.lock" 'remote uv lock is removed'
assert_file_not_contains "$metadata_dir/pyproject.toml" '[dependency-groups]' 'runtime pyproject excludes dependency groups'
assert_file_not_contains "$metadata_dir/pyproject.toml" 'black' 'runtime pyproject excludes development tools'
assert_file_contains "$metadata_dir/pyproject.toml" '[tool.example]' 'runtime pyproject preserves unrelated sections'
assert_file_not_contains "$metadata_dir/.difyignore" 'wheels/' 'difyignore includes wheels'
assert_file_not_contains "$metadata_dir/.difyignore" 'uv.toml' 'difyignore includes uv config'
assert_file_contains "$metadata_dir/.difyignore" '.venv/' 'difyignore preserves unrelated patterns'

legacy_uv_dir="$FIXTURE_DIR/legacy-uv-metadata"
mkdir -p "$legacy_uv_dir"
printf '%s\n' \
  '[project]' \
  'dependencies = ["httpx==0.28.1"]' \
  '[tool.uv]' \
  'dev-dependencies = [' \
  '  "pytest>=9.0.3",' \
  ']' \
  'environments = [' \
  '  "sys_platform == '\''win32'\''",' \
  ']' \
  'index-strategy = "first-index"' >"$legacy_uv_dir/pyproject.toml"

sanitize_pyproject_for_runtime "$legacy_uv_dir/pyproject.toml"
configure_pyproject_environment "$legacy_uv_dir/pyproject.toml" aarch64 3.12
assert_file_not_contains "$legacy_uv_dir/pyproject.toml" 'dev-dependencies' 'legacy uv development dependency key is removed'
assert_file_not_contains "$legacy_uv_dir/pyproject.toml" 'pytest' 'legacy uv development packages are removed'
assert_file_not_contains "$legacy_uv_dir/pyproject.toml" 'win32' 'existing uv environment marker is replaced'
assert_file_contains "$legacy_uv_dir/pyproject.toml" "platform_machine == 'aarch64'" 'existing tool.uv receives target environment'
assert_file_contains "$legacy_uv_dir/pyproject.toml" 'index-strategy = "first-index"' 'existing tool.uv settings are preserved'
assert_eq 1 "$(grep -c '^\[tool\.uv\]$' "$legacy_uv_dir/pyproject.toml")" 'existing tool.uv section is not duplicated'

fake_bin="$FIXTURE_DIR/fake-bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/uv-export" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$UV_EXPORT_LOG"
printf 'httpx==0.28.1\n'
EOF
chmod +x "$fake_bin/uv-export"

export_dir="$FIXTURE_DIR/export-with-lock"
mkdir -p "$export_dir"
printf '%s\n' '[project]' 'dependencies = ["httpx==0.28.1"]' >"$export_dir/pyproject.toml"
printf 'version = 1\n' >"$export_dir/uv.lock"
export UV_EXPORT_LOG="$FIXTURE_DIR/uv-export.args"
DIFY_UV_COMMAND="$fake_bin/uv-export" prepare_download_requirements "$export_dir" "$export_dir/download.txt"
assert_file_contains "$export_dir/download.txt" 'httpx==0.28.1' 'pyproject-only input exports requirements'
assert_file_contains "$UV_EXPORT_LOG" '--frozen' 'uv export honors existing lock'
assert_file_contains "$UV_EXPORT_LOG" '--no-emit-project' 'uv export excludes the plugin project'
assert_file_contains "$UV_EXPORT_LOG" 'dev' 'uv export excludes development dependencies'
assert_file_contains "$UV_EXPORT_LOG" '--no-default-groups' 'uv export excludes every default dependency group'

export_dir_no_lock="$FIXTURE_DIR/export-without-lock"
mkdir -p "$export_dir_no_lock"
printf '%s\n' '[project]' 'dependencies = ["httpx==0.28.1"]' >"$export_dir_no_lock/pyproject.toml"
: >"$UV_EXPORT_LOG"
DIFY_UV_COMMAND="$fake_bin/uv-export" prepare_download_requirements "$export_dir_no_lock" "$export_dir_no_lock/download.txt"
assert_file_not_contains "$UV_EXPORT_LOG" '--frozen' 'uv export resolves pyproject without stale lock'

cat >"$fake_bin/pip-download" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$PIP_ARGS_LOG"
while (($#)); do
  if [[ "$1" == '-d' || "$1" == '--dest' ]]; then
    shift
    mkdir -p "$1"
    touch "$1/example-1.0-py3-none-any.whl"
  fi
  shift
done
EOF
chmod +x "$fake_bin/pip-download"

wheel_dir="$FIXTURE_DIR/wheels"
mkdir -p "$wheel_dir"
touch "$wheel_dir/stale-1.0-cp312-cp312-manylinux_2_28_x86_64.whl"
export PIP_ARGS_LOG="$FIXTURE_DIR/pip-download.args"
DIFY_PIP_COMMAND="$fake_bin/pip-download" download_wheels "$metadata_dir/download.txt" "$wheel_dir" aarch64 3.12
assert_file_contains "$PIP_ARGS_LOG" '--python-version' 'pip receives target Python option'
assert_file_contains "$PIP_ARGS_LOG" '3.12' 'pip targets Python 3.12'
assert_file_contains "$PIP_ARGS_LOG" 'cp312' 'pip receives CPython ABI'
assert_file_contains "$PIP_ARGS_LOG" 'manylinux_2_28_aarch64' 'pip accepts modern ARM64 wheels'
assert_file_contains "$PIP_ARGS_LOG" 'manylinux2014_aarch64' 'pip accepts legacy ARM64 wheels'
assert_file_contains "$PIP_ARGS_LOG" '--only-binary=:all:' 'pip rejects source distributions'
assert_file_missing "$wheel_dir/stale-1.0-cp312-cp312-manylinux_2_28_x86_64.whl" 'wheelhouse is rebuilt without stale x86 wheel'

platform_count="$(grep -c -- '--platform' "$PIP_ARGS_LOG")"
assert_eq 2 "$platform_count" 'pip receives exactly two target platform options'

cat >"$fake_bin/pip-fail" <<'EOF'
#!/usr/bin/env bash
exit 23
EOF
chmod +x "$fake_bin/pip-fail"
if DIFY_PIP_COMMAND="$fake_bin/pip-fail" download_wheels "$metadata_dir/download.txt" "$wheel_dir" aarch64 3.12; then
  fail 'pip failure stops wheel download'
else
  pass 'pip failure stops wheel download'
fi

empty_requirements="$FIXTURE_DIR/empty-requirements.txt"
: >"$empty_requirements"
if DIFY_PIP_COMMAND="$fake_bin/pip-fail" download_wheels "$empty_requirements" "$wheel_dir" aarch64 3.12; then
  pass 'empty requirements do not invoke pip'
else
  fail 'empty requirements do not invoke pip'
fi

cat >"$fake_bin/uv-runtime" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$UV_ARGS_LOG"
exit "${FAKE_UV_EXIT:-0}"
EOF
cat >"$fake_bin/dify-packager" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$PACKAGER_ARGS_LOG"
exec "$REAL_PACKAGER" "$@"
EOF
cat >"$fake_bin/packager-fail" <<'EOF'
#!/usr/bin/env bash
exit 29
EOF
chmod +x "$fake_bin/uv-runtime" "$fake_bin/dify-packager" "$fake_bin/packager-fail"

input_package="$FIXTURE_DIR/source plugin.difypkg"
cp "$ROOT_DIR/langgenius-openai_api_compatible_0.0.57.difypkg" "$input_package"
GENERATED_TEST_OUTPUT="$ROOT_DIR/source plugin-offline.difypkg"
rm -f -- "$GENERATED_TEST_OUTPUT"
export UV_ARGS_LOG="$FIXTURE_DIR/uv-runtime.args"
export PACKAGER_ARGS_LOG="$FIXTURE_DIR/packager.args"
export REAL_PACKAGER="$ROOT_DIR/dify-plugin-linux-amd64-5g"
chmod +x "$REAL_PACKAGER"

run_log="$FIXTURE_DIR/repackage.log"
if DIFY_PIP_COMMAND="$fake_bin/pip-download" \
  DIFY_UV_COMMAND="$fake_bin/uv-runtime" \
  DIFY_PACKAGER_BINARY="$fake_bin/dify-packager" \
  DIFY_TARGET_ARCH=aarch64 \
  bash "$ROOT_DIR/plugin_repackaging.sh" local "$input_package" >"$run_log" 2>&1; then
  pass 'local command packages a path containing spaces'
else
  fail 'local command packages a path containing spaces'
  sed 's/^/# repackage: /' "$run_log"
fi

if [[ -f "$GENERATED_TEST_OUTPUT" ]]; then
  pass 'offline package is created'
  archive_entries="$(unzip -Z1 "$GENERATED_TEST_OUTPUT")"
  assert_eq 1 "$(grep -c '^requirements.txt$' <<<"$archive_entries")" 'archive contains requirements'
  assert_eq 1 "$(grep -c '^uv.toml$' <<<"$archive_entries")" 'archive contains uv config'
  assert_eq 1 "$(grep -c '^pyproject.toml$' <<<"$archive_entries")" 'archive preserves pyproject'
  assert_eq 1 "$(grep -c '^wheels/example-1.0-py3-none-any.whl$' <<<"$archive_entries")" 'archive contains wheelhouse'
  assert_eq 0 "$(grep -c '^uv.lock$' <<<"$archive_entries")" 'archive excludes remote lock'
else
  fail 'offline package is created'
fi

if [[ -f "$UV_ARGS_LOG" ]]; then
  assert_file_contains "$UV_ARGS_LOG" 'pip install' 'requirements path is dry-run validated'
  assert_file_contains "$UV_ARGS_LOG" 'sync' 'pyproject path is dry-run validated'
  assert_file_contains "$UV_ARGS_LOG" '--offline' 'validation explicitly disables network'
else
  fail 'uv validation commands are recorded'
fi

staging_count="$(find "$ROOT_DIR" -maxdepth 1 -type d -name '.dify-repackaging.*' | wc -l)"
assert_eq 0 "$staging_count" 'successful build cleans its staging directory'

rm -f -- "$GENERATED_TEST_OUTPUT"
if DIFY_PIP_COMMAND="$fake_bin/pip-fail" \
  DIFY_UV_COMMAND="$fake_bin/uv-runtime" \
  DIFY_PACKAGER_BINARY="$fake_bin/dify-packager" \
  DIFY_TARGET_ARCH=aarch64 \
  bash "$ROOT_DIR/plugin_repackaging.sh" local "$input_package" >"$FIXTURE_DIR/pip-failure.log" 2>&1; then
  fail 'pip failure stops repackaging'
else
  pass 'pip failure stops repackaging'
fi
assert_file_missing "$GENERATED_TEST_OUTPUT" 'pip failure leaves no stale output'

rm -f -- "$GENERATED_TEST_OUTPUT"
if FAKE_UV_EXIT=31 \
  DIFY_PIP_COMMAND="$fake_bin/pip-download" \
  DIFY_UV_COMMAND="$fake_bin/uv-runtime" \
  DIFY_PACKAGER_BINARY="$fake_bin/dify-packager" \
  DIFY_TARGET_ARCH=aarch64 \
  bash "$ROOT_DIR/plugin_repackaging.sh" local "$input_package" >"$FIXTURE_DIR/uv-failure.log" 2>&1; then
  fail 'uv validation failure stops repackaging'
else
  pass 'uv validation failure stops repackaging'
fi
assert_file_missing "$GENERATED_TEST_OUTPUT" 'uv failure leaves no stale output'

rm -f -- "$GENERATED_TEST_OUTPUT"
if DIFY_PIP_COMMAND="$fake_bin/pip-download" \
  DIFY_UV_COMMAND="$fake_bin/uv-runtime" \
  DIFY_PACKAGER_BINARY="$fake_bin/packager-fail" \
  DIFY_TARGET_ARCH=aarch64 \
  bash "$ROOT_DIR/plugin_repackaging.sh" local "$input_package" >"$FIXTURE_DIR/packager-failure.log" 2>&1; then
  fail 'packager failure stops repackaging'
else
  pass 'packager failure stops repackaging'
fi
assert_file_missing "$GENERATED_TEST_OUTPUT" 'packager failure leaves no stale output'

if github_usage_error="$(github_source github 2>&1)"; then
  github_usage_status=0
else
  github_usage_status=$?
fi
if ((github_usage_status != 0)); then
  pass 'github mode rejects missing arguments'
else
  fail 'github mode rejects missing arguments'
fi
if grep -Fq 'Usage:' <<<"$github_usage_error"; then
  pass 'github mode reports usage for missing arguments'
else
  fail 'github mode reports usage for missing arguments'
fi
if grep -Fq 'unbound variable' <<<"$github_usage_error"; then
  fail 'github mode validates before reading arguments'
else
  pass 'github mode validates before reading arguments'
fi

if grep -q 'DIFY_TARGET_ARCH=aarch64' "$ROOT_DIR/plugin_repackaging_amd64_to_arm64.sh" &&
  grep -q 'exec .*plugin_repackaging.sh' "$ROOT_DIR/plugin_repackaging_amd64_to_arm64.sh"; then
  pass 'cross-architecture wrapper delegates to unified script'
else
  fail 'cross-architecture wrapper delegates to unified script'
fi

printf '%s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
((FAIL_COUNT == 0))
