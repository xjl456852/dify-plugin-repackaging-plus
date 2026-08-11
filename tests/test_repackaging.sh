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

assert_toml_valid() {
  local file=$1 name=${2:-"$file is valid TOML"}
  if python3 -c 'import pathlib, sys, tomllib; tomllib.loads(pathlib.Path(sys.argv[1]).read_text())' "$file"; then
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
assert_eq cp312 "$(python_abi 3.12.7)" 'Python patch version normalizes to CPython 3.12 ABI'
assert_eq $'manylinux_2_28_aarch64\nmanylinux2014_aarch64' "$(default_platforms aarch64)" 'ARM64 platform set'
assert_eq custom_aarch64 "$(DIFY_MANYLINUX_PLATFORMS=custom_aarch64 default_platforms aarch64)" 'platform override'

detect_proxy_fixture() {
  local variable_name=$1
  local proxy_url=$2

  (
    unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
    export "$variable_name=$proxy_url"
    detect_socks_proxy
  )
}

without_proxy_environment() {
  (
    unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
    "$@"
  )
}

for proxy_scheme in socks4 socks4a socks5 socks5h; do
  proxy_url="$proxy_scheme://10.10.10.10:28802"
  assert_eq \
    "$proxy_url" \
    "$(detect_proxy_fixture https_proxy "$proxy_url")" \
    "$proxy_scheme proxy requires SOCKS support"
done
assert_eq \
  'SoCkS5H://10.10.10.10:28802' \
  "$(detect_proxy_fixture ALL_PROXY 'SoCkS5H://10.10.10.10:28802')" \
  'proxy scheme matching is case-insensitive'
if detect_proxy_fixture HTTP_PROXY 'http://10.10.10.10:28802' >/dev/null; then
  fail 'HTTP proxy does not require SOCKS support'
else
  pass 'HTTP proxy does not require SOCKS support'
fi
if detect_proxy_fixture HTTPS_PROXY '' >/dev/null; then
  fail 'empty proxy environment does not require SOCKS support'
else
  pass 'empty proxy environment does not require SOCKS support'
fi
assert_eq \
  'socks5h://***@10.10.10.10:28802' \
  "$(redact_url_for_log 'socks5h://proxy-user:proxy-secret@10.10.10.10:28802')" \
  'proxy credentials are redacted for logs'
assert_eq \
  'https://***@mirror.example/simple' \
  "$(redact_url_for_log 'https://mirror-user:mirror-secret@mirror.example/simple?token=query-secret#fragment')" \
  'index credentials and query tokens are redacted for logs'
if uv_version_at_least 0.7.21 0.7.21 && uv_version_at_least 0.11.24 0.7.21; then
  pass 'supported uv versions satisfy the minimum'
else
  fail 'supported uv versions satisfy the minimum'
fi
if uv_version_at_least 0.7.20 0.7.21; then
  fail 'uv version before sync target-platform support is rejected'
else
  pass 'uv version before sync target-platform support is rejected'
fi

FIXTURE_DIR="$(mktemp -d /tmp/dify-repackaging-tests.XXXXXX)"
GENERATED_TEST_OUTPUT=
GENERATED_REMOTE_FILES=()

cleanup_test_files() {
  rm -rf -- "$FIXTURE_DIR"
  if [[ "$GENERATED_TEST_OUTPUT" == "$ROOT_DIR/source plugin-offline.difypkg" ]]; then
    rm -f -- "$GENERATED_TEST_OUTPUT"
  fi
  local generated_remote_file
  for generated_remote_file in "${GENERATED_REMOTE_FILES[@]}"; do
    case "$generated_remote_file" in
      "$ROOT_DIR"/repackaging-test-*)
        rm -f -- "$generated_remote_file"
        ;;
    esac
  done
}

trap cleanup_test_files EXIT

metadata_dir="$FIXTURE_DIR/metadata"
mkdir -p "$metadata_dir"
printf '3.12.7\n' >"$metadata_dir/.python-version"
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
printf '%s\n' \
  'meta:' \
  '  runner:' \
  '    language: python' \
  '    version: "3.11.9"' >"$metadata_dir/manifest.yaml"
assert_eq 3.11 "$(detect_python_version "$metadata_dir")" 'manifest runner version precedes .python-version'
assert_eq 3.13 "$(DIFY_PYTHON_VERSION=3.13 detect_python_version "$metadata_dir")" 'Python version override precedes manifest'
printf '%s\n' \
  'meta:' \
  '  version: 9.9.9' \
  '  runner:' \
  '    language: python' \
  "    version: '3.10'" >"$metadata_dir/manifest.yaml"
assert_eq 3.10 "$(detect_python_version "$metadata_dir")" 'manifest parser reads single-quoted runner version only'
printf '%s\n' \
  'meta:' \
  '  runner:' \
  '    language: python' \
  '    version: latest' >"$metadata_dir/manifest.yaml"
assert_eq 3.12 "$(detect_python_version "$metadata_dir")" 'invalid manifest runner version falls back to .python-version'
printf '%s\n' 'meta:' '  version: 9.9.9' >"$metadata_dir/manifest.yaml"
assert_eq 3.12 "$(detect_python_version "$metadata_dir")" 'manifest without runner falls back to .python-version'
rm -f -- "$metadata_dir/manifest.yaml"

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
  '  "pytest-cov[all]>=7.0.0",' \
  ']' \
  'environments = "sys_platform == '\''win32'\''"' \
  'index-strategy = "first-index"' \
  '[tool.example]' \
  'enabled = true' >"$legacy_uv_dir/pyproject.toml"

sanitize_pyproject_for_runtime "$legacy_uv_dir/pyproject.toml"
configure_pyproject_environment "$legacy_uv_dir/pyproject.toml" aarch64 3.12
assert_file_not_contains "$legacy_uv_dir/pyproject.toml" 'dev-dependencies' 'legacy uv development dependency key is removed'
assert_file_not_contains "$legacy_uv_dir/pyproject.toml" 'pytest-cov' 'legacy uv development package extras are removed safely'
assert_file_not_contains "$legacy_uv_dir/pyproject.toml" 'win32' 'existing uv environment marker is replaced'
assert_file_contains "$legacy_uv_dir/pyproject.toml" "platform_machine == 'aarch64'" 'existing tool.uv receives target environment'
assert_file_contains "$legacy_uv_dir/pyproject.toml" 'index-strategy = "first-index"' 'existing tool.uv settings are preserved'
assert_file_contains "$legacy_uv_dir/pyproject.toml" '[tool.example]' 'section after scalar uv environment is preserved'
assert_file_contains "$legacy_uv_dir/pyproject.toml" 'enabled = true' 'settings after scalar uv environment are preserved'
assert_eq 1 "$(grep -c '^\[tool\.uv\]$' "$legacy_uv_dir/pyproject.toml")" 'existing tool.uv section is not duplicated'
assert_toml_valid "$legacy_uv_dir/pyproject.toml" 'normalized legacy uv metadata remains valid TOML'

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
DIFY_PIP_COMMAND="$fake_bin/pip-download" \
  without_proxy_environment download_wheels "$metadata_dir/download.txt" "$wheel_dir" aarch64 3.12
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
pip_download_failure_log="$FIXTURE_DIR/pip-download-failure.log"
if PIP_MIRROR_URL='https://mirror.example/simple' \
  DIFY_PIP_COMMAND="$fake_bin/pip-fail" \
  without_proxy_environment download_wheels \
    "$metadata_dir/download.txt" \
    "$wheel_dir" \
    aarch64 \
    3.12 \
    >"$pip_download_failure_log" 2>&1; then
  fail 'pip failure stops wheel download'
else
  pass 'pip failure stops wheel download'
fi
assert_file_contains "$pip_download_failure_log" 'Target Python: 3.12' 'download failure reports target Python'
assert_file_contains "$pip_download_failure_log" 'Target ABI: cp312' 'download failure reports target ABI'
assert_file_contains "$pip_download_failure_log" 'Target architecture: aarch64' 'download failure reports target architecture'
assert_file_contains "$pip_download_failure_log" 'Target platforms: manylinux_2_28_aarch64,manylinux2014_aarch64' 'download failure reports platform tags'
assert_file_contains "$pip_download_failure_log" 'Package index: https://mirror.example/simple' 'download failure reports package index'
assert_file_contains "$pip_download_failure_log" 'no compatible binary wheel' 'download failure explains binary wheel boundary'
assert_file_contains "$pip_download_failure_log" 'additional package index' 'download failure mentions private or specialized indexes'

empty_requirements="$FIXTURE_DIR/empty-requirements.txt"
: >"$empty_requirements"
if DIFY_PIP_COMMAND="$fake_bin/pip-fail" \
  without_proxy_environment download_wheels "$empty_requirements" "$wheel_dir" aarch64 3.12; then
  pass 'empty requirements do not invoke pip'
else
  fail 'empty requirements do not invoke pip'
fi

socks_fake_bin="$FIXTURE_DIR/socks-fake-bin"
mkdir -p "$socks_fake_bin"
cat >"$socks_fake_bin/pip-socks" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SOCKS_PIP_LOG"
case "${1:-}" in
  show)
    [[ "${FAKE_PIP_HAS_PYSOCKS:-0}" == 1 ]]
    ;;
  install)
    if (( ${FAKE_PIP_INSTALL_EXIT:-0} != 0 )); then
      exit "$FAKE_PIP_INSTALL_EXIT"
    fi
    printf 'install-proxy=%s|%s|%s|%s|%s|%s\n' \
      "${http_proxy:-}" \
      "${https_proxy:-}" \
      "${all_proxy:-}" \
      "${HTTP_PROXY:-}" \
      "${HTTPS_PROXY:-}" \
      "${ALL_PROXY:-}" >>"$SOCKS_PIP_LOG"
    target=
    while (($#)); do
      if [[ "$1" == --target ]]; then
        shift
        target=${1:-}
      fi
      shift
    done
    [[ -n "$target" ]]
    mkdir -p "$target"
    printf '# temporary test module\n' >"$target/socks.py"
    ;;
  download)
    if [[ "${FAKE_PIP_SOCKS_TLS_BUG:-0}" == 1 && "${PIP_USE_DEPRECATED:-}" != legacy-certs ]]; then
      printf '%s\n' \
        "TypeError: PoolKey.__new__() got an unexpected keyword argument 'key_proxy_ssl_context'" >&2
      exit 86
    fi
    printf '%s\n' "${PYTHONPATH:-}" >"$SOCKS_PYTHONPATH_LOG"
    while (($#)); do
      if [[ "$1" == --dest ]]; then
        shift
        mkdir -p "$1"
        touch "$1/example-1.0-py3-none-any.whl"
      fi
      shift
    done
    ;;
esac
EOF
cat >"$socks_fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
output=
url=
printf '%s\n' "$*" >>"$SOCKS_CURL_LOG"
if (( ${FAKE_CURL_EXIT:-0} != 0 )); then
  exit "$FAKE_CURL_EXIT"
fi
while (($#)); do
  case "$1" in
    --output)
      shift
      output=${1:-}
      ;;
    http://* | https://*)
      url=$1
      ;;
  esac
  shift
done
[[ -n "$output" && -n "$url" ]]
case "$url" in
  */pysocks/)
    cp "$SOCKS_SIMPLE_PAGE" "$output"
    ;;
  *PySocks-1.7.1-py3-none-any.whl)
    cp "$SOCKS_WHEEL_FIXTURE" "$output"
    ;;
  *)
    exit 71
    ;;
esac
EOF
chmod +x "$socks_fake_bin/pip-socks" "$socks_fake_bin/curl"

export SOCKS_PIP_LOG="$FIXTURE_DIR/socks-pip.log"
export SOCKS_CURL_LOG="$FIXTURE_DIR/socks-curl.log"
export SOCKS_PYTHONPATH_LOG="$FIXTURE_DIR/socks-pythonpath.log"
export SOCKS_SIMPLE_PAGE="$FIXTURE_DIR/pysocks-simple.html"
export SOCKS_WHEEL_FIXTURE="$FIXTURE_DIR/PySocks-1.7.1-py3-none-any.whl"
printf 'fake universal wheel payload\n' >"$SOCKS_WHEEL_FIXTURE"
socks_wheel_sha256="$(sha256sum "$SOCKS_WHEEL_FIXTURE" | cut -d' ' -f1)"
printf '%s\n' \
  '<!doctype html>' \
  "<a href=\"https://files.example/PySocks-1.7.1-py3-none-any.whl#sha256=$socks_wheel_sha256\">PySocks</a>" \
  >"$SOCKS_SIMPLE_PAGE"
: >"$SOCKS_PIP_LOG"
: >"$SOCKS_CURL_LOG"
rm -f -- "$SOCKS_PYTHONPATH_LOG"
socks_case_dir="$FIXTURE_DIR/socks-case"
socks_wheel_dir="$socks_case_dir/wheels"
socks_bootstrap_dir="$FIXTURE_DIR/pip-bootstrap"
mkdir -p "$socks_case_dir"
if https_proxy='socks5h://10.10.10.10:28802' \
  HTTPS_PROXY= HTTP_PROXY= http_proxy= ALL_PROXY= all_proxy= \
  PATH="$socks_fake_bin:$PATH" \
  PIP_MIRROR_URL='https://mirror.example/simple' \
  DIFY_PIP_COMMAND="$socks_fake_bin/pip-socks" \
  download_wheels \
    "$metadata_dir/download.txt" \
    "$socks_wheel_dir" \
    aarch64 \
    3.12 \
    "$socks_bootstrap_dir"; then
  pass 'missing PySocks is repaired inside build staging'
else
  fail 'missing PySocks is repaired inside build staging'
fi
assert_file_contains "$SOCKS_PIP_LOG" 'show PySocks' 'pip SOCKS capability is checked without network'
assert_file_contains "$SOCKS_PIP_LOG" 'install --disable-pip-version-check --no-index --no-deps --target' 'PySocks wheel is installed into temporary target'
assert_file_contains "$SOCKS_PIP_LOG" 'install-proxy=|||||' 'temporary local install cannot inherit proxy settings'
assert_file_contains "$SOCKS_CURL_LOG" 'https://mirror.example/simple/pysocks/' 'PySocks simple index uses configured mirror'
assert_file_contains "$SOCKS_CURL_LOG" 'PySocks-1.7.1-py3-none-any.whl' 'universal PySocks wheel is downloaded'
if [[ -f "$SOCKS_PYTHONPATH_LOG" ]]; then
  assert_eq \
    "$socks_bootstrap_dir/site-packages" \
    "$(head -n1 "$SOCKS_PYTHONPATH_LOG")" \
    'dependency download receives temporary PySocks PYTHONPATH'
else
  fail 'dependency download receives temporary PySocks PYTHONPATH'
fi

unsafe_scheme_page="$FIXTURE_DIR/pysocks-unsafe-scheme.html"
printf '%s\n' \
  '<a href="file:///tmp/PySocks-1.7.1-py3-none-any.whl">PySocks</a>' \
  >"$unsafe_scheme_page"
if resolve_pysocks_wheel "$unsafe_scheme_page" 'https://mirror.example/simple/pysocks/' >/dev/null 2>&1; then
  fail 'PySocks wheel URL rejects non-HTTP schemes'
else
  pass 'PySocks wheel URL rejects non-HTTP schemes'
fi

: >"$SOCKS_PIP_LOG"
: >"$SOCKS_CURL_LOG"
missing_bootstrap_case_dir="$FIXTURE_DIR/socks-missing-bootstrap-case"
mkdir -p "$missing_bootstrap_case_dir"
if https_proxy='socks5h://10.10.10.10:28802' \
  HTTPS_PROXY= HTTP_PROXY= http_proxy= ALL_PROXY= all_proxy= \
  PATH="$socks_fake_bin:$PATH" \
  PIP_MIRROR_URL='https://mirror.example/simple' \
  SOCKS_SIMPLE_PAGE="$FIXTURE_DIR/pysocks-simple.html" \
  DIFY_PIP_COMMAND="$socks_fake_bin/pip-socks" \
  download_wheels \
    "$metadata_dir/download.txt" \
    "$missing_bootstrap_case_dir/wheels" \
    aarch64 \
    3.12 \
    >"$missing_bootstrap_case_dir/output.log" 2>&1; then
  fail 'SOCKS repair requires an explicit staging bootstrap directory'
else
  pass 'SOCKS repair requires an explicit staging bootstrap directory'
fi
assert_file_contains "$missing_bootstrap_case_dir/output.log" 'safe pip bootstrap directory is required' 'missing bootstrap directory fails clearly'
if [[ ! -s "$SOCKS_CURL_LOG" ]]; then
  pass 'missing bootstrap directory fails before network access'
else
  fail 'missing bootstrap directory fails before network access'
fi

: >"$SOCKS_PIP_LOG"
: >"$SOCKS_CURL_LOG"
tls_bug_case_dir="$FIXTURE_DIR/socks-tls-context-case"
mkdir -p "$tls_bug_case_dir"
if https_proxy='socks5h://10.10.10.10:28802' \
  HTTPS_PROXY= HTTP_PROXY= http_proxy= ALL_PROXY= all_proxy= \
  FAKE_PIP_SOCKS_TLS_BUG=1 \
  PATH="$socks_fake_bin:$PATH" \
  PIP_MIRROR_URL='https://mirror.example/simple' \
  SOCKS_SIMPLE_PAGE="$FIXTURE_DIR/pysocks-simple.html" \
  DIFY_PIP_COMMAND="$socks_fake_bin/pip-socks" \
  download_wheels \
    "$metadata_dir/download.txt" \
    "$tls_bug_case_dir/wheels" \
    aarch64 \
    3.12 \
    "$tls_bug_case_dir/pip-bootstrap" \
    >"$tls_bug_case_dir/output.log" 2>&1; then
  pass 'pip SOCKS proxy SSL context bug is retried automatically'
else
  fail 'pip SOCKS proxy SSL context bug is retried automatically'
fi
assert_eq 2 "$(grep -c '^download ' "$SOCKS_PIP_LOG")" 'SOCKS proxy SSL context workaround retries exactly once'
assert_file_contains "$tls_bug_case_dir/output.log" 'legacy-certs' 'SOCKS proxy SSL context retry is explained'

: >"$SOCKS_PIP_LOG"
: >"$SOCKS_CURL_LOG"
no_proxy_case_dir="$FIXTURE_DIR/no-proxy-case"
mkdir -p "$no_proxy_case_dir"
if PATH="$socks_fake_bin:$PATH" \
  DIFY_PIP_COMMAND="$socks_fake_bin/pip-socks" \
  without_proxy_environment download_wheels \
    "$metadata_dir/download.txt" \
    "$no_proxy_case_dir/wheels" \
    aarch64 \
    3.12 \
    "$no_proxy_case_dir/pip-bootstrap"; then
  pass 'no SOCKS proxy keeps the normal pip path'
else
  fail 'no SOCKS proxy keeps the normal pip path'
fi
assert_file_not_contains "$SOCKS_PIP_LOG" 'show PySocks' 'no SOCKS proxy skips PySocks capability check'
if [[ ! -s "$SOCKS_CURL_LOG" ]]; then
  pass 'no SOCKS proxy skips bootstrap downloads'
else
  fail 'no SOCKS proxy skips bootstrap downloads'
fi
assert_file_missing "$no_proxy_case_dir/pip-bootstrap" 'no SOCKS proxy creates no bootstrap directory'

: >"$SOCKS_PIP_LOG"
: >"$SOCKS_CURL_LOG"
installed_case_dir="$FIXTURE_DIR/pysocks-installed-case"
mkdir -p "$installed_case_dir"
if https_proxy='socks5h://10.10.10.10:28802' \
  HTTPS_PROXY= HTTP_PROXY= http_proxy= ALL_PROXY= all_proxy= \
  FAKE_PIP_HAS_PYSOCKS=1 \
  PATH="$socks_fake_bin:$PATH" \
  DIFY_PIP_COMMAND="$socks_fake_bin/pip-socks" \
  download_wheels \
    "$metadata_dir/download.txt" \
    "$installed_case_dir/wheels" \
    aarch64 \
    3.12 \
    "$installed_case_dir/pip-bootstrap"; then
  pass 'existing PySocks keeps the normal pip path'
else
  fail 'existing PySocks keeps the normal pip path'
fi
assert_file_contains "$SOCKS_PIP_LOG" 'show PySocks' 'existing PySocks is detected'
assert_file_not_contains "$SOCKS_PIP_LOG" 'install ' 'existing PySocks is not reinstalled'
if [[ ! -s "$SOCKS_CURL_LOG" ]]; then
  pass 'existing PySocks skips bootstrap downloads'
else
  fail 'existing PySocks skips bootstrap downloads'
fi
assert_file_missing "$installed_case_dir/pip-bootstrap" 'existing PySocks creates no bootstrap directory'

: >"$SOCKS_PIP_LOG"
: >"$SOCKS_CURL_LOG"
installed_tls_bug_case_dir="$FIXTURE_DIR/pysocks-installed-tls-context-case"
mkdir -p "$installed_tls_bug_case_dir"
if https_proxy='socks5h://10.10.10.10:28802' \
  HTTPS_PROXY= HTTP_PROXY= http_proxy= ALL_PROXY= all_proxy= \
  FAKE_PIP_HAS_PYSOCKS=1 \
  FAKE_PIP_SOCKS_TLS_BUG=1 \
  PATH="$socks_fake_bin:$PATH" \
  DIFY_PIP_COMMAND="$socks_fake_bin/pip-socks" \
  download_wheels \
    "$metadata_dir/download.txt" \
    "$installed_tls_bug_case_dir/wheels" \
    aarch64 \
    3.12 \
    "$installed_tls_bug_case_dir/pip-bootstrap" \
    >"$installed_tls_bug_case_dir/output.log" 2>&1; then
  pass 'installed PySocks also retries the proxy SSL context bug'
else
  fail 'installed PySocks also retries the proxy SSL context bug'
fi
assert_eq 2 "$(grep -c '^download ' "$SOCKS_PIP_LOG")" 'installed PySocks compatibility retry runs exactly once'
assert_file_contains "$installed_tls_bug_case_dir/output.log" 'legacy-certs' 'installed PySocks compatibility retry is explained'
assert_file_missing "$installed_tls_bug_case_dir/pip-bootstrap" 'installed PySocks retry creates no bootstrap directory'

: >"$SOCKS_PIP_LOG"
: >"$SOCKS_CURL_LOG"
disabled_case_dir="$FIXTURE_DIR/socks-disabled-case"
mkdir -p "$disabled_case_dir"
if https_proxy='socks5h://proxy-user:proxy-secret@10.10.10.10:28802' \
  HTTPS_PROXY= HTTP_PROXY= http_proxy= ALL_PROXY= all_proxy= \
  DIFY_AUTO_FIX_SOCKS=0 \
  PATH="$socks_fake_bin:$PATH" \
  DIFY_PIP_COMMAND="$socks_fake_bin/pip-socks" \
  download_wheels \
    "$metadata_dir/download.txt" \
    "$disabled_case_dir/wheels" \
    aarch64 \
    3.12 \
    "$disabled_case_dir/pip-bootstrap" \
    >"$disabled_case_dir/output.log" 2>&1; then
  fail 'disabled SOCKS repair fails before dependency download'
else
  pass 'disabled SOCKS repair fails before dependency download'
fi
assert_file_contains "$disabled_case_dir/output.log" 'automatic repair is disabled' 'disabled repair explains how it was disabled'
assert_file_not_contains "$disabled_case_dir/output.log" 'proxy-user' 'disabled repair log hides proxy username'
assert_file_not_contains "$disabled_case_dir/output.log" 'proxy-secret' 'disabled repair log hides proxy password'
assert_file_not_contains "$SOCKS_PIP_LOG" 'download ' 'disabled repair does not invoke dependency download'
if [[ ! -s "$SOCKS_CURL_LOG" ]]; then
  pass 'disabled SOCKS repair performs no network request'
else
  fail 'disabled SOCKS repair performs no network request'
fi

missing_link_page="$FIXTURE_DIR/pysocks-missing-link.html"
printf '%s\n' '<a href="other-1.0-py3-none-any.whl">Other</a>' >"$missing_link_page"
: >"$SOCKS_PIP_LOG"
: >"$SOCKS_CURL_LOG"
missing_link_case_dir="$FIXTURE_DIR/socks-missing-link-case"
mkdir -p "$missing_link_case_dir"
if https_proxy='socks5h://10.10.10.10:28802' \
  HTTPS_PROXY= HTTP_PROXY= http_proxy= ALL_PROXY= all_proxy= \
  PATH="$socks_fake_bin:$PATH" \
  PIP_MIRROR_URL='https://mirror.example/simple' \
  SOCKS_SIMPLE_PAGE="$missing_link_page" \
  DIFY_PIP_COMMAND="$socks_fake_bin/pip-socks" \
  download_wheels \
    "$metadata_dir/download.txt" \
    "$missing_link_case_dir/wheels" \
    aarch64 \
    3.12 \
    "$missing_link_case_dir/pip-bootstrap" \
    >"$missing_link_case_dir/output.log" 2>&1; then
  fail 'missing PySocks wheel fails safely'
else
  pass 'missing PySocks wheel fails safely'
fi
assert_file_contains "$missing_link_case_dir/output.log" 'failed to locate PySocks 1.7.1 universal wheel' 'missing wheel reports configured bootstrap requirement'
assert_file_not_contains "$SOCKS_PIP_LOG" 'download ' 'missing bootstrap wheel prevents dependency download'

wrong_checksum_page="$FIXTURE_DIR/pysocks-wrong-checksum.html"
printf '%s\n' \
  '<a href="https://files.example/PySocks-1.7.1-py3-none-any.whl#sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa">PySocks</a>' \
  >"$wrong_checksum_page"
: >"$SOCKS_PIP_LOG"
checksum_case_dir="$FIXTURE_DIR/socks-checksum-case"
mkdir -p "$checksum_case_dir"
if https_proxy='socks5h://10.10.10.10:28802' \
  HTTPS_PROXY= HTTP_PROXY= http_proxy= ALL_PROXY= all_proxy= \
  PATH="$socks_fake_bin:$PATH" \
  PIP_MIRROR_URL='https://mirror.example/simple' \
  SOCKS_SIMPLE_PAGE="$wrong_checksum_page" \
  DIFY_PIP_COMMAND="$socks_fake_bin/pip-socks" \
  download_wheels \
    "$metadata_dir/download.txt" \
    "$checksum_case_dir/wheels" \
    aarch64 \
    3.12 \
    "$checksum_case_dir/pip-bootstrap" \
    >"$checksum_case_dir/output.log" 2>&1; then
  fail 'PySocks checksum mismatch fails safely'
else
  pass 'PySocks checksum mismatch fails safely'
fi
assert_file_contains "$checksum_case_dir/output.log" 'checksum mismatch' 'checksum mismatch is explicit'
assert_file_not_contains "$SOCKS_PIP_LOG" 'install ' 'checksum mismatch prevents local install'

: >"$SOCKS_PIP_LOG"
install_failure_case_dir="$FIXTURE_DIR/socks-install-failure-case"
mkdir -p "$install_failure_case_dir"
if https_proxy='socks5h://10.10.10.10:28802' \
  HTTPS_PROXY= HTTP_PROXY= http_proxy= ALL_PROXY= all_proxy= \
  FAKE_PIP_INSTALL_EXIT=91 \
  PATH="$socks_fake_bin:$PATH" \
  PIP_MIRROR_URL='https://mirror.example/simple' \
  SOCKS_SIMPLE_PAGE="$FIXTURE_DIR/pysocks-simple.html" \
  DIFY_PIP_COMMAND="$socks_fake_bin/pip-socks" \
  download_wheels \
    "$metadata_dir/download.txt" \
    "$install_failure_case_dir/wheels" \
    aarch64 \
    3.12 \
    "$install_failure_case_dir/pip-bootstrap" \
    >"$install_failure_case_dir/output.log" 2>&1; then
  fail 'temporary PySocks install failure stops download'
else
  pass 'temporary PySocks install failure stops download'
fi
assert_file_contains "$install_failure_case_dir/output.log" 'failed to install temporary PySocks support' 'temporary install failure is explicit'
assert_file_not_contains "$SOCKS_PIP_LOG" 'download ' 'temporary install failure prevents dependency download'

: >"$SOCKS_PIP_LOG"
curl_failure_case_dir="$FIXTURE_DIR/socks-curl-failure-case"
mkdir -p "$curl_failure_case_dir"
if https_proxy='socks5h://10.10.10.10:28802' \
  HTTPS_PROXY= HTTP_PROXY= http_proxy= ALL_PROXY= all_proxy= \
  FAKE_CURL_EXIT=92 \
  PATH="$socks_fake_bin:$PATH" \
  PIP_MIRROR_URL='https://mirror-user:mirror-secret@mirror.example/simple' \
  DIFY_PIP_COMMAND="$socks_fake_bin/pip-socks" \
  download_wheels \
    "$metadata_dir/download.txt" \
    "$curl_failure_case_dir/wheels" \
    aarch64 \
    3.12 \
    "$curl_failure_case_dir/pip-bootstrap" \
    >"$curl_failure_case_dir/output.log" 2>&1; then
  fail 'PySocks index download failure stops dependency download'
else
  pass 'PySocks index download failure stops dependency download'
fi
assert_file_contains "$curl_failure_case_dir/output.log" 'failed to download the PySocks simple index' 'bootstrap curl failure is explicit'
assert_file_not_contains "$curl_failure_case_dir/output.log" 'mirror-user' 'bootstrap failure log hides index username'
assert_file_not_contains "$curl_failure_case_dir/output.log" 'mirror-secret' 'bootstrap failure log hides index password'
assert_file_not_contains "$SOCKS_PIP_LOG" 'download ' 'bootstrap curl failure prevents dependency download'

report_failure_log="$FIXTURE_DIR/report-wheel-failure.log"
PIP_MIRROR_URL='https://index-user:index-secret@mirror.example/simple?token=query-secret' \
  report_wheel_download_failure aarch64 3.12 cp312 manylinux_2_28_aarch64 \
  >"$report_failure_log" 2>&1
assert_file_contains "$report_failure_log" 'Package index: https://***@mirror.example/simple' 'wheel failure reports a safe index location'
assert_file_not_contains "$report_failure_log" 'index-user' 'wheel failure log hides index username'
assert_file_not_contains "$report_failure_log" 'index-secret' 'wheel failure log hides index password'
assert_file_not_contains "$report_failure_log" 'query-secret' 'wheel failure log hides index query token'

cat >"$fake_bin/uv-runtime" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then
  printf 'uv 0.11.24\n'
  exit 0
fi
printf '%s\n' "$*" >>"$UV_ARGS_LOG"
exit "${FAKE_UV_EXIT:-0}"
EOF
cat >"$fake_bin/uv-old" <<'EOF'
#!/usr/bin/env bash
printf 'uv 0.7.20\n'
EOF
cat >"$fake_bin/dify-packager" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$PACKAGER_ARGS_LOG"
plugin_dir=
output=
while (($#)); do
  case "$1" in
    package)
      shift
      plugin_dir=${1:-}
      ;;
    -o)
      shift
      output=${1:-}
      ;;
  esac
  shift
done
[[ -n "$plugin_dir" && -n "$output" ]]
python3 - "$plugin_dir" "$output" <<'PY'
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile
import sys

root = Path(sys.argv[1])
with ZipFile(sys.argv[2], "w", ZIP_DEFLATED) as archive:
    for path in sorted(root.rglob("*")):
        if path.is_file():
            archive.write(path, path.relative_to(root))
PY
EOF
cat >"$fake_bin/packager-fail" <<'EOF'
#!/usr/bin/env bash
exit 29
EOF
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 37
EOF
chmod +x "$fake_bin/uv-runtime" "$fake_bin/uv-old" "$fake_bin/dify-packager" "$fake_bin/packager-fail" "$fake_bin/curl"

if check_uv_version "$fake_bin/uv-old" >"$FIXTURE_DIR/uv-old.log" 2>&1; then
  fail 'uv without sync target-platform support is rejected by runtime check'
else
  pass 'uv without sync target-platform support is rejected by runtime check'
fi
assert_file_contains "$FIXTURE_DIR/uv-old.log" '0.7.21 or newer' 'old uv error reports the required version'

input_plugin_dir="$FIXTURE_DIR/input-plugin"
input_package="$FIXTURE_DIR/source plugin.difypkg"
mkdir -p "$input_plugin_dir/provider" "$input_plugin_dir/models/llm"
printf '%s\n' \
  'version: 0.0.1' \
  'type: plugin' \
  'author: tests' \
  'name: offline_fixture' \
  'label:' \
  '  en_US: Offline fixture' \
  'description:' \
  '  en_US: Offline packaging fixture' \
  'icon: icon.svg' \
  'resource:' \
  '  memory: 1048576' \
  '  permission:' \
  '    model:' \
  '      enabled: true' \
  '      llm: true' \
  '      text_embedding: false' \
  '      rerank: false' \
  '      tts: false' \
  '      speech2text: false' \
  '      moderation: false' \
  'plugins:' \
  '  models:' \
  '    - provider/offline_fixture.yaml' \
  'meta:' \
  '  version: 0.0.1' \
  '  arch: [amd64, arm64]' \
  '  runner:' \
  '    language: python' \
  '    version: "3.12"' \
  '    entrypoint: main' \
  'created_at: 2026-08-11' >"$input_plugin_dir/manifest.yaml"
printf '%s\n' \
  'from dify_plugin import Plugin, DifyPluginEnv' \
  'Plugin(DifyPluginEnv()).run()' >"$input_plugin_dir/main.py"
printf '%s\n' 'dify-plugin==0.7.4' >"$input_plugin_dir/requirements.txt"
printf '%s\n' \
  '[project]' \
  'name = "offline-fixture"' \
  'version = "0.0.1"' \
  'requires-python = ">=3.12"' \
  'dependencies = ["dify-plugin==0.7.4"]' >"$input_plugin_dir/pyproject.toml"
printf '%s\n' \
  '<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"/>' >"$input_plugin_dir/icon.svg"
printf '%s\n' \
  'provider: offline_fixture' \
  'label:' \
  '  en_US: Offline fixture' \
  'description:' \
  '  en_US: Offline packaging fixture' \
  'icon_small:' \
  '  en_US: icon.svg' \
  'icon_large:' \
  '  en_US: icon.svg' \
  'background: "#FFFFFF"' \
  'supported_model_types:' \
  '  - llm' \
  'configurate_methods:' \
  '  - customizable-model' \
  'model_credential_schema:' \
  '  model:' \
  '    label:' \
  '      en_US: Model name' \
  '    placeholder:' \
  '      en_US: Enter model name' \
  '  credential_form_schemas: []' \
  'extra:' \
  '  python:' \
  '    provider_source: provider/offline_fixture.py' \
  '    model_sources:' \
  '      - models/llm/llm.py' >"$input_plugin_dir/provider/offline_fixture.yaml"
printf '%s\n' \
  'from collections.abc import Mapping' \
  'from dify_plugin import ModelProvider' \
  '' \
  'class OfflineFixtureProvider(ModelProvider):' \
  '    def validate_provider_credentials(self, credentials: Mapping) -> None:' \
  '        pass' >"$input_plugin_dir/provider/offline_fixture.py"
printf '%s\n' \
  'from dify_plugin.interfaces.model.openai_compatible.llm import OAICompatLargeLanguageModel' \
  '' \
  'class OfflineFixtureLargeLanguageModel(OAICompatLargeLanguageModel):' \
  '    pass' >"$input_plugin_dir/models/llm/llm.py"
(
  cd "$input_plugin_dir"
  python3 - "$input_package" <<'PY'
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile
import sys

root = Path.cwd()
with ZipFile(sys.argv[1], "w", ZIP_DEFLATED) as archive:
    for path in sorted(root.rglob("*")):
        if path.is_file():
            archive.write(path, path.relative_to(root))
PY
)
GENERATED_TEST_OUTPUT="$ROOT_DIR/source plugin-offline.difypkg"
rm -f -- "$GENERATED_TEST_OUTPUT"
export UV_ARGS_LOG="$FIXTURE_DIR/uv-runtime.args"
export PACKAGER_ARGS_LOG="$FIXTURE_DIR/packager.args"

run_log="$FIXTURE_DIR/repackage.log"
if env -u http_proxy -u https_proxy -u all_proxy \
  -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
  DIFY_PIP_COMMAND="$fake_bin/pip-download" \
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
: >"$SOCKS_PIP_LOG"
: >"$SOCKS_CURL_LOG"
if https_proxy='socks5h://10.10.10.10:28802' \
  HTTPS_PROXY= HTTP_PROXY= http_proxy= ALL_PROXY= all_proxy= \
  PATH="$socks_fake_bin:$fake_bin:$PATH" \
  PIP_MIRROR_URL='https://mirror.example/simple' \
  SOCKS_SIMPLE_PAGE="$FIXTURE_DIR/pysocks-simple.html" \
  DIFY_PIP_COMMAND="$socks_fake_bin/pip-socks" \
  DIFY_UV_COMMAND="$fake_bin/uv-runtime" \
  DIFY_PACKAGER_BINARY="$fake_bin/dify-packager" \
  DIFY_TARGET_ARCH=aarch64 \
  bash "$ROOT_DIR/plugin_repackaging.sh" local "$input_package" \
    >"$FIXTURE_DIR/socks-repackage.log" 2>&1; then
  pass 'full repackaging repairs missing PySocks'
else
  fail 'full repackaging repairs missing PySocks'
  sed 's/^/# socks repackage: /' "$FIXTURE_DIR/socks-repackage.log"
fi
if [[ -f "$GENERATED_TEST_OUTPUT" ]]; then
  socks_archive_entries="$(unzip -Z1 "$GENERATED_TEST_OUTPUT")"
  assert_eq 1 "$(grep -c '^wheels/example-1.0-py3-none-any.whl$' <<<"$socks_archive_entries")" 'SOCKS-repaired archive contains runtime wheelhouse'
  assert_eq 0 "$(grep -ci 'pip-bootstrap' <<<"$socks_archive_entries")" 'SOCKS-repaired archive excludes bootstrap directory'
  assert_eq 0 "$(grep -ci 'PySocks' <<<"$socks_archive_entries")" 'SOCKS-repaired archive excludes PySocks wheel'
  assert_eq 0 "$(grep -c '/socks.py$' <<<"$socks_archive_entries")" 'SOCKS-repaired archive excludes temporary socks module'
else
  fail 'SOCKS-repaired offline package is created'
fi

rm -f -- "$GENERATED_TEST_OUTPUT"
if env -u http_proxy -u https_proxy -u all_proxy \
  -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
  DIFY_PIP_COMMAND="$fake_bin/pip-fail" \
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
if env -u http_proxy -u https_proxy -u all_proxy \
  -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
  FAKE_UV_EXIT=31 \
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
if env -u http_proxy -u https_proxy -u all_proxy \
  -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
  DIFY_PIP_COMMAND="$fake_bin/pip-download" \
  DIFY_UV_COMMAND="$fake_bin/uv-runtime" \
  DIFY_PACKAGER_BINARY="$fake_bin/packager-fail" \
  DIFY_TARGET_ARCH=aarch64 \
  bash "$ROOT_DIR/plugin_repackaging.sh" local "$input_package" >"$FIXTURE_DIR/packager-failure.log" 2>&1; then
  fail 'packager failure stops repackaging'
else
  pass 'packager failure stops repackaging'
fi
assert_file_missing "$GENERATED_TEST_OUTPUT" 'packager failure leaves no stale output'

remote_test_id="repackaging-test-${BASHPID}"
github_asset="${remote_test_id}.difypkg"
github_download="$ROOT_DIR/${remote_test_id}-v-test.difypkg"
github_offline="$ROOT_DIR/${remote_test_id}-v-test-offline.difypkg"
GENERATED_REMOTE_FILES+=("$github_download" "$github_offline")
touch "$github_offline"
if PATH="$fake_bin:$PATH" \
  DIFY_UV_COMMAND="$fake_bin/uv-runtime" \
  DIFY_PACKAGER_BINARY="$fake_bin/dify-packager" \
  bash "$ROOT_DIR/plugin_repackaging.sh" github owner/repository v-test "$github_asset" >"$FIXTURE_DIR/github-download-failure.log" 2>&1; then
  fail 'GitHub download failure stops repackaging'
else
  pass 'GitHub download failure stops repackaging'
fi
assert_file_missing "$github_offline" 'GitHub download failure removes stale offline output'

market_author="${remote_test_id}-author"
market_download="$ROOT_DIR/${market_author}-plugin_0.0.1.difypkg"
market_offline="$ROOT_DIR/${market_author}-plugin_0.0.1-offline.difypkg"
GENERATED_REMOTE_FILES+=("$market_download" "$market_offline")
touch "$market_offline"
if PATH="$fake_bin:$PATH" \
  DIFY_UV_COMMAND="$fake_bin/uv-runtime" \
  DIFY_PACKAGER_BINARY="$fake_bin/dify-packager" \
  bash "$ROOT_DIR/plugin_repackaging.sh" market "$market_author" plugin 0.0.1 >"$FIXTURE_DIR/market-download-failure.log" 2>&1; then
  fail 'Marketplace download failure stops repackaging'
else
  pass 'Marketplace download failure stops repackaging'
fi
assert_file_missing "$market_offline" 'Marketplace download failure removes stale offline output'

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
