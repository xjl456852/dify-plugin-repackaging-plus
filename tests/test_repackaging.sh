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

if python3 -B -m unittest -v "$ROOT_DIR/tests/test_validate_python_distribution.py"; then
  pass 'Python distribution archive validator suite passes'
else
  fail 'Python distribution archive validator suite passes'
fi

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
GENERATED_ROOT_TEST_DIRS=()

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
  local generated_root_test_dir
  for generated_root_test_dir in "${GENERATED_ROOT_TEST_DIRS[@]}"; do
    case "$generated_root_test_dir" in
      "$ROOT_DIR"/.coordinator-drvfs-test.*)
        if [[ -d "$generated_root_test_dir" && ! -L "$generated_root_test_dir" && \
          "$(realpath -e -- "$generated_root_test_dir")" == "$generated_root_test_dir" ]]; then
          rm -rf -- "$generated_root_test_dir"
        fi
        ;;
    esac
  done
}

trap cleanup_test_files EXIT

bounded_log_new="$FIXTURE_DIR/bounded-new.log"
if run_bounded_command_log "$bounded_log_new" printf 'new bounded output\n'; then
  pass 'bounded coordinator capture safely creates a new private log'
else
  fail 'bounded coordinator capture safely creates a new private log'
fi
assert_eq 600 "$(stat -c '%a' "$bounded_log_new")" 'new bounded coordinator log is mode 0600'
assert_eq 'new bounded output' "$(<"$bounded_log_new")" 'new bounded coordinator log contains command output'

printf 'old bounded output\n' >"$bounded_log_new"
chmod 600 -- "$bounded_log_new"
if run_bounded_command_log "$bounded_log_new" printf 'replacement bounded output\n'; then
  pass 'bounded coordinator capture safely replaces an existing private log'
else
  fail 'bounded coordinator capture safely replaces an existing private log'
fi
assert_eq 'replacement bounded output' "$(<"$bounded_log_new")" 'existing bounded coordinator log is truncated only after validation'

bounded_capture_python="$FIXTURE_DIR/bounded-capture-race.py"
awk '
  /^run_bounded_command_log\(\) \{/ { in_function = 1 }
  in_function && /3<<'\''PY'\''$/ { in_python = 1; next }
  in_python && /^PY$/ { exit }
  in_python {
    print
    if ($0 ~ /^[[:space:]]*existing = os\.lstat\(path\)$/) {
      print "    open(os.environ[\"DIFY_TEST_RACE_READY\"], \"w\").close()"
      print "    while not os.path.exists(os.environ[\"DIFY_TEST_RACE_GO\"]): pass"
    }
  }
' "$ROOT_DIR/plugin_repackaging.sh" >"$bounded_capture_python"

run_bounded_capture_race() {
  local race_name=$1 replacement_kind=$2
  local race_dir="$FIXTURE_DIR/bounded-race-$race_name"
  local log_path="$race_dir/current.log"
  local victim_path="$race_dir/victim.log"
  local ready_path="$race_dir/ready"
  local go_path="$race_dir/go"
  local status_path="$race_dir/status"
  local runner_pid race_status

  mkdir -p -- "$race_dir"
  printf 'prechecked log\n' >"$log_path"
  printf 'victim sentinel\n' >"$victim_path"
  chmod 600 -- "$log_path" "$victim_path"
  (
    if printf 'attacker controlled replacement\n' | \
      DIFY_TEST_RACE_READY="$ready_path" DIFY_TEST_RACE_GO="$go_path" \
      python3 -B "$bounded_capture_python" "$log_path" 2>/dev/null; then
      capture_status=0
    else
      capture_status=$?
    fi
    printf '%s\n' "$capture_status" >"$status_path"
  ) &
  runner_pid=$!
  for _ in $(seq 1 200); do
    [[ -e "$ready_path" ]] && break
    sleep 0.01
  done
  if [[ ! -e "$ready_path" ]]; then
    kill "$runner_pid" 2>/dev/null || true
    wait "$runner_pid" 2>/dev/null || true
    fail "bounded capture reaches deterministic pre-open race hook: $race_name"
    return
  fi
  rm -f -- "$log_path"
  if [[ "$replacement_kind" == hardlink ]]; then
    ln -- "$victim_path" "$log_path"
  else
    mv -- "$victim_path" "$log_path"
  fi
  : >"$go_path"
  wait "$runner_pid"
  race_status="$(<"$status_path")"
  if [[ "$race_status" != 0 ]]; then
    pass "bounded capture rejects a pre-open identity swap: $race_name"
  else
    fail "bounded capture rejects a pre-open identity swap: $race_name"
  fi
  if [[ "$(<"$log_path")" == 'victim sentinel' ]]; then
    pass "bounded capture does not truncate the swapped victim: $race_name"
  else
    fail "bounded capture does not truncate the swapped victim: $race_name"
  fi
}

run_bounded_capture_race hardlink hardlink
run_bounded_capture_race independent-file independent

mode_zero_workspace="$(mktemp -d -- /tmp/dify-plugin-coordinator.XXXXXXXX)"
mkdir -p -- "$mode_zero_workspace/nested/deeper"
printf 'cleanup sentinel\n' >"$mode_zero_workspace/nested/deeper/file"
chmod 000 -- "$mode_zero_workspace/nested" "$mode_zero_workspace"
if cleanup_coordinator_workspace "$mode_zero_workspace"; then
  pass 'coordinator cleanup recovers an owned mode-000 top workspace and nested directory'
else
  fail 'coordinator cleanup recovers an owned mode-000 top workspace and nested directory'
fi
assert_file_missing "$mode_zero_workspace" 'mode-000 coordinator workspace leaves no residue'
if [[ -d "$mode_zero_workspace" && ! -L "$mode_zero_workspace" ]]; then
  chmod 700 -- "$mode_zero_workspace" 2>/dev/null || true
  chmod -R u+rwx -- "$mode_zero_workspace" 2>/dev/null || true
  rm -rf -- "$mode_zero_workspace"
fi

cleanup_python="$FIXTURE_DIR/coordinator-cleanup-race.py"
awk '
  /^cleanup_coordinator_workspace\(\) \{/ { in_function = 1 }
  in_function && /<<'\''PY'\''$/ { in_python = 1; next }
  in_python && /^PY$/ { exit }
  in_python {
    print
    if ($0 ~ /COORDINATOR_WORKSPACE_CLEANUP_IDENTITY_CAPTURED/) {
      print "    open(os.environ[\"DIFY_TEST_RACE_READY\"], \"w\").close()"
      print "    while not os.path.exists(os.environ[\"DIFY_TEST_RACE_GO\"]): pass"
    }
  }
' "$ROOT_DIR/plugin_repackaging.sh" >"$cleanup_python"
cleanup_race_workspace="$(mktemp -d -- /tmp/dify-plugin-coordinator.XXXXXXXX)"
cleanup_race_held="$cleanup_race_workspace.held"
cleanup_race_victim="$(mktemp -d -- /tmp/dify-plugin-coordinator.XXXXXXXX)"
cleanup_race_ready="$FIXTURE_DIR/cleanup-race.ready"
cleanup_race_go="$FIXTURE_DIR/cleanup-race.go"
cleanup_race_status="$FIXTURE_DIR/cleanup-race.status"
chmod 000 -- "$cleanup_race_workspace" "$cleanup_race_victim"
(
  if DIFY_TEST_RACE_READY="$cleanup_race_ready" DIFY_TEST_RACE_GO="$cleanup_race_go" \
    python3 -B "$cleanup_python" "$cleanup_race_workspace"; then
    cleanup_status=0
  else
    cleanup_status=$?
  fi
  printf '%s\n' "$cleanup_status" >"$cleanup_race_status"
) &
cleanup_runner_pid=$!
for _ in $(seq 1 200); do
  [[ -e "$cleanup_race_ready" ]] && break
  sleep 0.01
done
mv -- "$cleanup_race_workspace" "$cleanup_race_held"
mv -- "$cleanup_race_victim" "$cleanup_race_workspace"
: >"$cleanup_race_go"
wait "$cleanup_runner_pid"
if [[ "$(<"$cleanup_race_status")" != 0 ]]; then
  pass 'coordinator cleanup fails closed when its top workspace is replaced'
else
  fail 'coordinator cleanup fails closed when its top workspace is replaced'
fi
assert_eq 0 "$(stat -c '%a' "$cleanup_race_workspace")" 'coordinator cleanup never chmods an attacker replacement'
chmod 700 -- "$cleanup_race_workspace" "$cleanup_race_held"
rm -rf -- "$cleanup_race_workspace" "$cleanup_race_held"

foreign_repair_parent="$FIXTURE_DIR/foreign-owned-repair"
foreign_repair_dir="$foreign_repair_parent/sdist-repair"
mkdir -p -- "$foreign_repair_dir"
chmod 700 -- "$foreign_repair_dir"
if sudo -n chown 0:0 -- "$foreign_repair_dir" 2>/dev/null; then
  if validate_sdist_repair_dir "$foreign_repair_dir" >/dev/null 2>&1; then
    fail 'foreign-owned explicit repair root is rejected before use'
  else
    pass 'foreign-owned explicit repair root is rejected before use'
  fi
  sudo -n chown "$(id -u):$(id -g)" -- "$foreign_repair_dir"
else
  if grep -A45 '^validate_sdist_repair_dir()' "$ROOT_DIR/plugin_repackaging.sh" | grep -q 'os.geteuid'; then
    pass 'explicit repair ownership check is present when root chown is unavailable'
  else
    fail 'explicit repair ownership check is present when root chown is unavailable'
  fi
fi

diagnostic_workspace="$(mktemp -d -- /tmp/dify-plugin-coordinator.XXXXXXXX)"
chmod 700 -- "$diagnostic_workspace"
diagnostic_initial="$diagnostic_workspace/initial.test.log"
diagnostic_current="$diagnostic_workspace/current.test.log"
diagnostic_victim="$diagnostic_workspace/victim"
diagnostic_output="$FIXTURE_DIR/unsafe-diagnostic-output.log"
printf 'initial diagnostic\n' >"$diagnostic_initial"
printf 'diagnostic victim sentinel\n' >"$diagnostic_victim"
chmod 600 -- "$diagnostic_initial" "$diagnostic_victim"
diagnostic_snapshot=
if snapshot_coordinator_log "$diagnostic_initial" "$diagnostic_workspace" diagnostic_snapshot; then
  pass 'coordinator diagnostic snapshot accepts a private regular log'
else
  fail 'coordinator diagnostic snapshot accepts a private regular log'
fi
assert_eq 600 "$(stat -c '%a' "$diagnostic_snapshot")" 'coordinator diagnostic snapshot is created mode 0600'
assert_eq 'initial diagnostic' "$(<"$diagnostic_snapshot")" 'coordinator diagnostic snapshot preserves bounded contents'

run_unsafe_diagnostic_display() {
  local kind=$1 status

  rm -f -- "$diagnostic_current"
  case "$kind" in
    fifo)
      mkfifo -- "$diagnostic_current"
      chmod 600 -- "$diagnostic_current"
      ;;
    socket)
      python3 -B - "$diagnostic_current" <<'PY'
import socket
import sys

listener = socket.socket(socket.AF_UNIX)
listener.bind(sys.argv[1])
listener.close()
PY
      chmod 600 -- "$diagnostic_current"
      ;;
    symlink)
      ln -s -- "$diagnostic_victim" "$diagnostic_current"
      ;;
    hardlink)
      ln -- "$diagnostic_victim" "$diagnostic_current"
      ;;
    device)
      sudo -n mknod "$diagnostic_current" c 1 3
      sudo -n chown "$(id -u):$(id -g)" "$diagnostic_current"
      sudo -n chmod 600 "$diagnostic_current"
      ;;
  esac
  if timeout 3 bash -c \
    'source "$1"; display_distinct_coordinator_logs "$2" "$3" "$4"' \
    _ "$ROOT_DIR/plugin_repackaging.sh" "$diagnostic_initial" "$diagnostic_current" \
    "$diagnostic_workspace" >"$diagnostic_output" 2>&1; then
    status=0
  else
    status=$?
  fi
  if [[ "$status" != 0 && "$status" != 124 ]]; then
    pass "unsafe coordinator diagnostic is rejected without blocking: $kind"
  else
    fail "unsafe coordinator diagnostic is rejected without blocking: $kind"
  fi
  assert_file_contains \
    "$diagnostic_output" \
    'coordinator diagnostics could not be snapshotted safely' \
    "unsafe coordinator diagnostic emits a fixed safe message: $kind"
  rm -f -- "$diagnostic_current"
}

for diagnostic_kind in fifo socket symlink hardlink; do
  run_unsafe_diagnostic_display "$diagnostic_kind"
done
if sudo -n true 2>/dev/null; then
  run_unsafe_diagnostic_display device
else
  pass 'device diagnostic fixture requires passwordless sudo; other special files cover non-regular rejection'
  pass 'device diagnostic fixed-message check requires passwordless sudo; other special files cover safe reporting'
fi
assert_eq 'diagnostic victim sentinel' "$(<"$diagnostic_victim")" 'unsafe diagnostic paths never alter their victim'

snapshot_python="$FIXTURE_DIR/coordinator-snapshot-race.py"
awk '
  /^snapshot_coordinator_log\(\) \{/ { in_function = 1 }
  in_function && /<<'\''PY'\''$/ { in_python = 1; next }
  in_python && /^PY$/ { exit }
  in_python {
    print
    if ($0 ~ /COORDINATOR_LOG_SNAPSHOT_PREOPEN/) {
      print "    open(os.environ[\"DIFY_TEST_RACE_READY\"], \"w\").close()"
      print "    while not os.path.exists(os.environ[\"DIFY_TEST_RACE_GO\"]): pass"
    }
  }
' "$ROOT_DIR/plugin_repackaging.sh" >"$snapshot_python"
snapshot_source="$diagnostic_workspace/snapshot-source.log"
snapshot_replacement="$diagnostic_workspace/snapshot-replacement.log"
snapshot_ready="$FIXTURE_DIR/snapshot-race.ready"
snapshot_go="$FIXTURE_DIR/snapshot-race.go"
snapshot_status_file="$FIXTURE_DIR/snapshot-race.status"
printf 'snapshot original\n' >"$snapshot_source"
printf 'snapshot replacement sentinel\n' >"$snapshot_replacement"
chmod 600 -- "$snapshot_source" "$snapshot_replacement"
(
  if DIFY_TEST_RACE_READY="$snapshot_ready" DIFY_TEST_RACE_GO="$snapshot_go" \
    python3 -B "$snapshot_python" "$snapshot_source" "$diagnostic_workspace" \
    >"$FIXTURE_DIR/snapshot-race.stdout"; then
    snapshot_status=0
  else
    snapshot_status=$?
  fi
  printf '%s\n' "$snapshot_status" >"$snapshot_status_file"
) &
snapshot_runner_pid=$!
for _ in $(seq 1 200); do
  [[ -e "$snapshot_ready" ]] && break
  sleep 0.01
done
rm -f -- "$snapshot_source"
mv -- "$snapshot_replacement" "$snapshot_source"
: >"$snapshot_go"
wait "$snapshot_runner_pid"
if [[ "$(<"$snapshot_status_file")" != 0 ]]; then
  pass 'coordinator diagnostic snapshot rejects a deterministic pre-open path swap'
else
  fail 'coordinator diagnostic snapshot rejects a deterministic pre-open path swap'
fi
assert_eq 'snapshot replacement sentinel' "$(<"$snapshot_source")" 'diagnostic snapshot path swap leaves replacement unchanged'
rm -f -- "$snapshot_source" "$diagnostic_victim" "$diagnostic_initial"
cleanup_coordinator_workspace "$diagnostic_workspace" >/dev/null 2>&1 || true

write_missing_wheel_log() {
  local file=$1
  local first_requirement=$2
  local second_requirement=${3:-$2}

  printf '%s\n' \
    "ERROR: Could not find a version that satisfies the requirement $first_requirement (from versions: none)" \
    "ERROR: No matching distribution found for $second_requirement" \
    >"$file"
}

missing_log="$FIXTURE_DIR/missing-wheel.log"
write_missing_wheel_log "$missing_log" 'docopt (from records)' docopt
assert_eq $'docopt\tdocopt' "$(extract_missing_requirement "$missing_log" 2>/dev/null)" 'unconstrained missing wheel includes a canonical-name field'

write_missing_wheel_log "$missing_log" 'DocOpt == 0.6.2' 'docopt==0.6.2'
assert_eq $'docopt==0.6.2\tdocopt' "$(extract_missing_requirement "$missing_log" 2>/dev/null)" 'constrained missing wheel includes its canonical name'

write_missing_wheel_log \
  "$missing_log" \
  'Acme.Widget_Name-extra >= 1.0, < 2.0' \
  'acme-widget-name-extra>=1.0,<2.0'
assert_eq \
  $'acme-widget-name-extra>=1.0,<2.0\tacme-widget-name-extra' \
  "$(extract_missing_requirement "$missing_log" 2>/dev/null)" \
  'standard name separators and compound PEP 440 comparisons are normalized'

for safe_marker_requirement in network==1.0 proxy 'ssl>=1.0,<2' traceback; do
  write_missing_wheel_log "$missing_log" "$safe_marker_requirement"
  assert_eq \
    "$safe_marker_requirement"$'\t'"${safe_marker_requirement%%[=<>!~]*}" \
    "$(extract_missing_requirement "$missing_log" 2>/dev/null)" \
    "diagnostic word remains valid inside exact missing requirement: $safe_marker_requirement"
done

for safe_marker_requirement in network==1.0 proxy 'ssl>=1.0,<2' traceback; do
  write_missing_wheel_log "$missing_log" "$safe_marker_requirement"
  printf 'Collecting legitimate package %s\n' "$safe_marker_requirement" >>"$missing_log"
  assert_eq \
    "$safe_marker_requirement"$'\t'"${safe_marker_requirement%%[=<>!~]*}" \
    "$(extract_missing_requirement "$missing_log" 2>/dev/null)" \
    "benign pip progress does not turn a package name into a failure marker: $safe_marker_requirement"
done

cat >"$missing_log" <<'EOF'
Looking in indexes: https://mirrors.aliyun.com/pypi/simple
Looking in links: /tmp/dify built wheels
Collecting records~=0.6.0 (from -r /tmp/download-requirements.txt (line 2))
  Using cached https://files.example/records-0.6.0-py2.py3-none-any.whl.metadata (7.0 kB)
Collecting network==1.0 (from records~=0.6.0)
  Downloading https://files.example/network-1.0-py3-none-any.whl.metadata (2.1 kB)
Collecting proxy (from records~=0.6.0)
  Downloading proxy-1.0-py3-none-any.whl (10 kB)
Collecting ssl>=1.0,<2 (from records~=0.6.0)
  Using cached ssl-1.5-py3-none-any.whl (12 kB)
Collecting traceback (from records~=0.6.0)
  Downloading traceback-1.0-py3-none-any.whl (25 kB)
INFO: pip is looking at multiple versions of records to determine which version is compatible with other requirements. This could take a while.
  Downloading yarl-1.24.5-cp312-cp312-manylinux2014_aarch64.whl (107 kB)
     ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ 107.6/107.6 kB 2.8 MB/s eta 0:00:00
ERROR: Could not find a version that satisfies the requirement docopt (from records) (from versions: none)
ERROR: No matching distribution found for docopt
EOF
assert_eq $'docopt\tdocopt' "$(extract_missing_requirement "$missing_log" 2>/dev/null)" 'realistic benign resolver progress includes the canonical name'

for unsafe_failure_marker in \
  'ProxyError' \
  'NameResolutionError' \
  'Name or service not known' \
  'Could not resolve host: mirror.example' \
  'No route to host' \
  'HTTP Error 407.' \
  'Access denied.' \
  'Temporary failure in name resolution.' \
  'Cannot connect to proxy.' \
  'TLS handshake error.' \
  'certificate has expired.' \
  'Dependency resolution failed.' \
  'version conflict detected.' \
  'UNEXPECTED-DIAGNOSTIC-SENTINEL' \
  'ConnectTimeoutError' \
  'ReadTimeoutError' \
  'connection refused' \
  'operation timed out' \
  'SSLError' \
  'TLS handshake failed' \
  'certificate verify failed' \
  'CERTIFICATE_VERIFY_FAILED' \
  '401 authentication required' \
  'invalid credentials' \
  'THESE PACKAGES DO NOT MATCH THE HASHES' \
  'HashMismatch' \
  'ResolutionImpossible: conflicting dependencies' \
  'Traceback (most recent call last):'; do
  write_missing_wheel_log "$missing_log" docopt
  printf '%s\n' "$unsafe_failure_marker" >>"$missing_log"
  if extract_missing_requirement "$missing_log" >/dev/null 2>&1; then
    fail "missing-wheel classification rejects $unsafe_failure_marker"
  else
    pass "missing-wheel classification rejects $unsafe_failure_marker"
  fi
done

write_missing_wheel_log "$missing_log" docopt
printf '\v\n' >>"$missing_log"
if extract_missing_requirement "$missing_log" >/dev/null 2>&1; then
  fail 'control-only unknown diagnostics fail closed'
else
  pass 'control-only unknown diagnostics fail closed'
fi

unicode_diagnostics=($'\u0085' $'\u2028' $'\u2029')
unicode_diagnostic_names=('U+0085 NEL' 'U+2028 line separator' 'U+2029 paragraph separator')
for unicode_index in "${!unicode_diagnostics[@]}"; do
  write_missing_wheel_log "$missing_log" docopt
  printf '%s\n' "${unicode_diagnostics[$unicode_index]}" >>"$missing_log"
  if extract_missing_requirement "$missing_log" >/dev/null 2>&1; then
    fail "${unicode_diagnostic_names[$unicode_index]} anywhere in raw pip output is rejected"
  else
    pass "${unicode_diagnostic_names[$unicode_index]} anywhere in raw pip output is rejected"
  fi
done

for unsafe_dependency_context in \
  $'docopt (from records\t)' \
  $'docopt (from records\v)' \
  $'docopt (from records\u0085)'; do
  write_missing_wheel_log "$missing_log" "$unsafe_dependency_context" docopt
  if extract_missing_requirement "$missing_log" >/dev/null 2>&1; then
    fail 'Unicode/control characters are rejected before dependency context is stripped'
  else
    pass 'Unicode/control characters are rejected before dependency context is stripped'
  fi
done

printf '%s\r\n%s\r\n' \
  $'\tERROR: Could not find a version that satisfies the requirement docopt (from versions: none)' \
  $'\tERROR: No matching distribution found for docopt' \
  >"$missing_log"
assert_eq $'docopt\tdocopt' "$(extract_missing_requirement "$missing_log" 2>/dev/null)" 'ordinary TAB indentation and CRLF remain accepted'

write_missing_wheel_log "$missing_log" docopt click
if extract_missing_requirement "$missing_log" >/dev/null 2>&1; then
  fail 'mismatched missing requirements are rejected'
else
  pass 'mismatched missing requirements are rejected'
fi

write_missing_wheel_log "$missing_log" docopt
printf '%s\n' \
  'ERROR: Could not find a version that satisfies the requirement click (from versions: none)' \
  'ERROR: No matching distribution found for click' \
  >>"$missing_log"
if extract_missing_requirement "$missing_log" >/dev/null 2>&1; then
  fail 'multiple missing requirements are rejected'
else
  pass 'multiple missing requirements are rejected'
fi

unsafe_requirements=(
  '--extra-index-url=https://evil.example/simple'
  'https://evil.example/docopt.tar.gz'
  '../docopt'
  'docopt @ https://evil.example/docopt.tar.gz'
  'docopt; python_version >= "3.12"'
  'docopt[all]'
  '-e git+https://evil.example/docopt.git'
  'docopt$(touch exploit)'
  $'docopt\t==0.6.2'
)
for unsafe_requirement in "${unsafe_requirements[@]}"; do
  write_missing_wheel_log "$missing_log" "$unsafe_requirement"
  if extract_missing_requirement "$missing_log" >/dev/null 2>&1; then
    fail "unsafe missing requirement is rejected: $unsafe_requirement"
  else
    pass "unsafe missing requirement is rejected: $unsafe_requirement"
  fi
done

redacted_pip_log="$FIXTURE_DIR/redacted-pip.log"
printf '%s\n' \
  'Looking in indexes: https://mirror-user:mirror-secret@mirror.example/simple?token=query-secret#fragment' \
  'Using proxy socks5h://proxy-user:proxy-secret@10.10.10.10:28802/route?socks-token=secret#fragment' \
  'Found link https://links-user:links-password@wheels.example/packages/docopt.whl?download=links-token#sha256=secret' \
  | redact_pip_log >"$redacted_pip_log" 2>/dev/null || true
assert_file_contains "$redacted_pip_log" 'https://***@mirror.example/simple' 'captured pip diagnostics retain a safe index location'
assert_file_contains "$redacted_pip_log" 'socks5h://***@10.10.10.10:28802/route' 'captured pip diagnostics retain a safe SOCKS proxy location'
assert_file_contains "$redacted_pip_log" 'https://***@wheels.example/packages/docopt.whl' 'captured pip diagnostics retain a safe find-links location'
for secret_value in mirror-user mirror-secret query-secret proxy-user proxy-secret socks-token links-user links-password links-token; do
  assert_file_not_contains "$redacted_pip_log" "$secret_value" "captured pip diagnostics redact $secret_value"
done

apostrophe_url_log="$FIXTURE_DIR/apostrophe-url.log"
printf '%s\n' \
  'HTTPS "https://review-user:before'"'"'apostrophe-tail-secret@mirror.example/simple?review-query-secret=yes#review-fragment-secret"' \
  "HTTP 'http://http-user:http-password@mirror.example/simple?http-query-secret=yes#http-fragment-secret'" \
  'SOCKS [socks5h://socks-review-user:socks-review-password@10.10.10.10:28802/path?socks-review-query=yes#socks-review-fragment]' \
  | redact_pip_log >"$apostrophe_url_log" 2>/dev/null || true
assert_file_contains "$apostrophe_url_log" 'https://***@mirror.example/simple' 'apostrophe-bearing HTTPS userinfo is redacted as one URL token'
assert_file_contains "$apostrophe_url_log" 'http://***@mirror.example/simple' 'quoted HTTP userinfo is redacted'
assert_file_contains "$apostrophe_url_log" 'socks5h://***@10.10.10.10:28802/path' 'surrounded SOCKS userinfo is redacted'
for secret_value in \
  review-user before apostrophe-tail-secret review-query-secret review-fragment-secret \
  http-user http-password http-query-secret http-fragment-secret \
  socks-review-user socks-review-password socks-review-query socks-review-fragment; do
  assert_file_not_contains "$apostrophe_url_log" "$secret_value" "maximal URL token redaction hides $secret_value"
done

adjacent_url_log="$FIXTURE_DIR/adjacent-url.log"
printf '%s\n' \
  'Adjacent "https://first-user:first-secret@one.example/simple,https://second-user:second-secret@two.example/private?second-query=x#second-fragment"' \
  "Mixed (http://third-user:third-secret@three.example/start;socks5h://fourth-user:fourth-secret@10.10.10.10:28802/private?fourth-query=x#fourth-fragment)" \
  | redact_pip_log >"$adjacent_url_log" 2>/dev/null || true
assert_eq 2 "$(grep -o '<redacted-url>' "$adjacent_url_log" | wc -l)" 'adjacent supported URL schemes redact each ambiguous maximal token completely'
for secret_value in \
  first-user first-secret second-user second-secret second-query second-fragment \
  third-user third-secret fourth-user fourth-secret fourth-query fourth-fragment; do
  assert_file_not_contains "$adjacent_url_log" "$secret_value" "adjacent URL redaction hides $secret_value"
done

unsafe_terminal_input="$FIXTURE_DIR/unsafe-terminal-input.bin"
unsafe_terminal_output="$FIXTURE_DIR/unsafe-terminal-output.txt"
printf '%s' $'URL https://terminal-user:terminal-password@mirror.example/simple?terminal-query-secret=yes#terminal-fragment-secret\n' >"$unsafe_terminal_input"
printf '%s' $'OSC52 \e]52;c;clipboard-payload\a end\nCR safe-prefix\roverwrite-text\nNEL before\u0085after\nBIDI before\u202eafter\n' >>"$unsafe_terminal_input"
printf '\377invalid-utf8\n' >>"$unsafe_terminal_input"
redact_pip_log <"$unsafe_terminal_input" >"$unsafe_terminal_output" 2>/dev/null || true
if python3 - "$unsafe_terminal_output" <<'PY'
from pathlib import Path
import sys
import unicodedata

try:
    text = Path(sys.argv[1]).read_text(encoding="utf-8")
except UnicodeError:
    raise SystemExit(1)
for character in text:
    if character in "\n\t":
        continue
    category = unicodedata.category(character)
    if character == "\r" or category.startswith("C") or category in {"Zl", "Zp"}:
        raise SystemExit(1)
PY
then
  pass 'displayed pip diagnostics contain only safe UTF-8 terminal text'
else
  fail 'displayed pip diagnostics contain only safe UTF-8 terminal text'
fi
for visible_escape in '\x1b' '\x07' '\r' '\u0085' '\u202e' '\xff'; do
  assert_file_contains "$unsafe_terminal_output" "$visible_escape" "unsafe terminal byte is rendered visibly as $visible_escape"
done
for secret_value in terminal-user terminal-password terminal-query-secret terminal-fragment-secret; do
  assert_file_not_contains "$unsafe_terminal_output" "$secret_value" "terminal-safe display still redacts $secret_value"
done

display_input_limit=$((1024 * 1024))
truncated_url_input="$FIXTURE_DIR/truncated-url-input.bin"
truncated_url_output="$FIXTURE_DIR/truncated-url-output.txt"
cut_url_prefix='https://cut-user:cut-password'
head -c "$((display_input_limit - ${#cut_url_prefix}))" /dev/zero | tr '\0' A >"$truncated_url_input"
printf '%s' "$cut_url_prefix" >>"$truncated_url_input"
printf '%s' '@mirror.example/simple?cut-query-secret=yes#cut-fragment-secret UNPROCESSED-URL-TAIL-SECRET' >>"$truncated_url_input"
printf '\033]52;c;tail-control-payload\007\n' >>"$truncated_url_input"
redact_pip_log <"$truncated_url_input" >"$truncated_url_output" 2>/dev/null || true
assert_file_contains "$truncated_url_output" '[pip diagnostic output truncated]' 'bounded redactor marks URL-boundary truncation'
for secret_value in cut-user cut-password cut-query-secret cut-fragment-secret UNPROCESSED-URL-TAIL-SECRET tail-control-payload; do
  assert_file_not_contains "$truncated_url_output" "$secret_value" "URL-boundary truncation never emits $secret_value"
done
if (( $(stat -c %s "$truncated_url_output") <= display_input_limit + 128 )); then
  pass 'URL-boundary redacted output stays within its documented bound'
else
  fail 'URL-boundary redacted output stays within its documented bound'
fi

truncated_utf8_input="$FIXTURE_DIR/truncated-utf8-input.bin"
truncated_utf8_output="$FIXTURE_DIR/truncated-utf8-output.txt"
head -c "$((display_input_limit - 1))" /dev/zero | tr '\0' B >"$truncated_utf8_input"
printf '\342' >>"$truncated_utf8_input"
printf '\202\254 UNPROCESSED-UTF8-TAIL-SECRET\033]52;c;utf8-tail-control\007\n' >>"$truncated_utf8_input"
redact_pip_log <"$truncated_utf8_input" >"$truncated_utf8_output" 2>/dev/null || true
assert_file_contains "$truncated_utf8_output" '\xe2' 'partial UTF-8 byte at display boundary is rendered visibly'
assert_file_contains "$truncated_utf8_output" '[pip diagnostic output truncated]' 'bounded redactor marks UTF-8-boundary truncation'
assert_file_not_contains "$truncated_utf8_output" 'UNPROCESSED-UTF8-TAIL-SECRET' 'UTF-8-boundary truncation never emits unprocessed tail text'
assert_file_not_contains "$truncated_utf8_output" 'utf8-tail-control' 'UTF-8-boundary truncation never emits tail control payload'
if python3 -c 'from pathlib import Path; import sys; Path(sys.argv[1]).read_text(encoding="utf-8")' "$truncated_utf8_output"; then
  pass 'UTF-8-boundary redacted output remains valid UTF-8'
else
  fail 'UTF-8-boundary redacted output remains valid UTF-8'
fi
if (( $(stat -c %s "$truncated_utf8_output") <= display_input_limit + 128 )); then
  pass 'UTF-8-boundary redacted output stays within its documented bound'
else
  fail 'UTF-8-boundary redacted output stays within its documented bound'
fi

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
if [[ "${FAKE_PIP_DIAGNOSTIC_FAILURE:-0}" == 1 ]]; then
  printf '%s\n' 'Looking in indexes: https://diag-user:diag-password@mirror.example/simple?token=diag-token#fragment'
  printf '%s\n' 'Proxy socks5h://socks-user:socks-password@10.10.10.10:28802/path?socks-query=secret#fragment' >&2
  exit 64
fi
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
assert_file_not_contains "$PIP_ARGS_LOG" '--find-links' 'default wheel download passes no optional find-links arguments'
assert_file_missing "$wheel_dir/stale-1.0-cp312-cp312-manylinux_2_28_x86_64.whl" 'wheelhouse is rebuilt without stale x86 wheel'

platform_count="$(grep -c -- '--platform' "$PIP_ARGS_LOG")"
assert_eq 2 "$platform_count" 'pip receives exactly two target platform options'

if grep -Fq -- '"${local_wheel_args[@]}"' "$ROOT_DIR/plugin_repackaging.sh"; then
  fail 'default download path avoids Bash 4.3 empty-array expansion'
else
  pass 'default download path avoids Bash 4.3 empty-array expansion'
fi

if bash43_command="$(command -v bash4.3 2>/dev/null)" && [[ -n "$bash43_command" ]]; then
  bash43_case_dir="$FIXTURE_DIR/bash43-case"
  mkdir -p "$bash43_case_dir/wheels"
  if env \
    -u http_proxy -u https_proxy -u all_proxy \
    -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
    BASH43_ROOT="$ROOT_DIR" \
    BASH43_REQUIREMENTS="$metadata_dir/download.txt" \
    BASH43_WHEELS="$bash43_case_dir/wheels" \
    BASH43_LOG="$bash43_case_dir/pip-output.log" \
    DIFY_PIP_COMMAND="$fake_bin/pip-download" \
    PIP_ARGS_LOG="$PIP_ARGS_LOG" \
    "$bash43_command" -uc \
      'source "$BASH43_ROOT/plugin_repackaging.sh"; download_wheels_once "$BASH43_REQUIREMENTS" "$BASH43_WHEELS" aarch64 3.12 "$BASH43_LOG"'; then
    pass 'Bash 4.3 executes the default one-shot download path'
  else
    fail 'Bash 4.3 executes the default one-shot download path'
  fi
else
  pass 'Bash 4.3 runtime unavailable; static empty-array regression covers its known set-u limitation'
fi

download_once_case_dir="$FIXTURE_DIR/download-once-case"
download_once_wheel_dir="$download_once_case_dir/wheels"
download_once_log="$download_once_case_dir/pip-output.log"
local_built_wheels="$download_once_case_dir/--built wheels"
mkdir -p "$download_once_wheel_dir" "$local_built_wheels"
if PIP_MIRROR_URL='https://target-index.example/simple' \
  DIFY_PIP_COMMAND="$fake_bin/pip-download" \
  without_proxy_environment download_wheels_once \
    "$metadata_dir/download.txt" \
    "$download_once_wheel_dir" \
    aarch64 \
    3.12 \
    "$download_once_log" \
    '' \
    "$local_built_wheels"; then
  pass 'one-shot wheel download accepts a local built-wheel directory'
else
  fail 'one-shot wheel download accepts a local built-wheel directory'
fi
assert_file_contains "$PIP_ARGS_LOG" '--only-binary=:all:' 'one-shot wheel download keeps binary-only policy'
assert_file_contains "$PIP_ARGS_LOG" '--disable-pip-version-check' 'one-shot wheel download suppresses unrelated pip update warnings'
assert_eq 1 "$(grep -Fxc -- '--index-url' "$PIP_ARGS_LOG")" 'one-shot wheel download passes one index option'
assert_eq 1 "$(grep -Fxc -- 'https://target-index.example/simple' "$PIP_ARGS_LOG")" 'one-shot wheel download passes the exact configured index'
assert_file_contains "$PIP_ARGS_LOG" '--python-version' 'one-shot wheel download keeps target Python'
assert_file_contains "$PIP_ARGS_LOG" 'cp312' 'one-shot wheel download keeps target ABI'
assert_file_contains "$PIP_ARGS_LOG" 'manylinux_2_28_aarch64' 'one-shot wheel download keeps target platform'
assert_eq 1 "$(grep -Fxc -- '--find-links' "$PIP_ARGS_LOG")" 'local wheel directory uses one find-links option'
assert_eq 1 "$(grep -Fxc -- "$local_built_wheels" "$PIP_ARGS_LOG")" 'local wheel directory with spaces is one find-links value'

download_diagnostic_log="$download_once_case_dir/diagnostic-output.log"
if FAKE_PIP_DIAGNOSTIC_FAILURE=1 \
  DIFY_PIP_COMMAND="$fake_bin/pip-download" \
  without_proxy_environment download_wheels_once \
    "$metadata_dir/download.txt" \
    "$download_once_wheel_dir" \
    aarch64 \
    3.12 \
    "$download_once_log" \
    >"$download_diagnostic_log" 2>&1; then
  fail 'one-shot diagnostic fixture fails as requested'
else
  pass 'one-shot diagnostic fixture fails as requested'
fi
assert_file_contains "$download_diagnostic_log" 'https://***@mirror.example/simple' 'download diagnostics expose only a safe index URL'
assert_file_contains "$download_diagnostic_log" 'socks5h://***@10.10.10.10:28802/path' 'download diagnostics expose only a safe SOCKS URL'
for secret_value in diag-user diag-password diag-token socks-user socks-password socks-query; do
  assert_file_not_contains "$download_diagnostic_log" "$secret_value" "download diagnostics redact $secret_value"
done

write_missing_wheel_log "$download_once_log" docopt
if DIFY_PIP_COMMAND="$fake_bin/pip-download" \
  without_proxy_environment download_wheels_once \
    "$metadata_dir/download.txt" \
    "$download_once_wheel_dir" \
    aarch64 \
    3.12 \
    "$download_once_log" \
    '' \
    "$download_once_case_dir/missing-built-wheels" \
    true \
    false \
    >/dev/null 2>&1; then
  fail 'invalid local wheel directory stops bounded one-shot download'
else
  pass 'invalid local wheel directory stops bounded one-shot download'
fi
assert_eq 0 "$(stat -c '%s' "$download_once_log")" 'missing built-wheels pre-pip failure empties the bounded attempt log'
if extract_missing_requirement "$download_once_log" >/dev/null 2>&1; then
  fail 'missing built-wheels pre-pip failure cannot leave stale classifiable output'
else
  pass 'missing built-wheels pre-pip failure cannot leave stale classifiable output'
fi

write_missing_wheel_log "$download_once_log" docopt
if https_proxy='socks5h://10.10.10.10:28802' HTTPS_PROXY= HTTP_PROXY= http_proxy= \
  ALL_PROXY= all_proxy= DIFY_PIP_COMMAND="$fake_bin/pip-download" \
  download_wheels_once \
    "$metadata_dir/download.txt" \
    "$download_once_wheel_dir" \
    aarch64 \
    3.12 \
    "$download_once_log" \
    '' \
    '' \
    true \
    false \
    >/dev/null 2>&1; then
  fail 'invalid SOCKS bootstrap stops bounded one-shot download before pip'
else
  pass 'invalid SOCKS bootstrap stops bounded one-shot download before pip'
fi
assert_eq 0 "$(stat -c '%s' "$download_once_log")" 'SOCKS bootstrap pre-pip failure empties the bounded attempt log'
if extract_missing_requirement "$download_once_log" >/dev/null 2>&1; then
  fail 'SOCKS bootstrap pre-pip failure cannot leave stale classifiable output'
else
  pass 'SOCKS bootstrap pre-pip failure cannot leave stale classifiable output'
fi

write_missing_wheel_log "$download_once_log" docopt
if (
  resolve_pip_command() { return 1; }
  without_proxy_environment download_wheels_once \
    "$metadata_dir/download.txt" \
    "$download_once_wheel_dir" \
    aarch64 \
    3.12 \
    "$download_once_log" \
    '' \
    '' \
    true \
    false
) >/dev/null 2>&1; then
  fail 'pip command resolution failure stops bounded one-shot download before pip'
else
  pass 'pip command resolution failure stops bounded one-shot download before pip'
fi
assert_eq 0 "$(stat -c '%s' "$download_once_log")" 'pip resolution pre-pip failure empties the bounded attempt log'
if extract_missing_requirement "$download_once_log" >/dev/null 2>&1; then
  fail 'pip resolution pre-pip failure cannot leave stale classifiable output'
else
  pass 'pip resolution pre-pip failure cannot leave stale classifiable output'
fi

pre_pip_symlink_victim="$download_once_case_dir/pre-pip-symlink-victim.txt"
pre_pip_symlink_log="$download_once_case_dir/pre-pip-symlink.log"
printf 'pre-pip-symlink-victim\n' >"$pre_pip_symlink_victim"
chmod 600 -- "$pre_pip_symlink_victim"
ln -s -- "$pre_pip_symlink_victim" "$pre_pip_symlink_log"
if DIFY_PIP_COMMAND="$fake_bin/pip-download" \
  without_proxy_environment download_wheels_once \
    "$metadata_dir/download.txt" "$download_once_wheel_dir" aarch64 3.12 \
    "$pre_pip_symlink_log" '' "$download_once_case_dir/missing-built-wheels" true false \
    >/dev/null 2>&1; then
  fail 'pre-pip log reset rejects a symlink path'
else
  pass 'pre-pip log reset rejects a symlink path'
fi
assert_eq 'pre-pip-symlink-victim' "$(<"$pre_pip_symlink_victim")" 'pre-pip log reset never truncates a symlink victim'

pre_pip_hardlink_victim="$download_once_case_dir/pre-pip-hardlink-victim.txt"
pre_pip_hardlink_log="$download_once_case_dir/pre-pip-hardlink.log"
printf 'pre-pip-hardlink-victim\n' >"$pre_pip_hardlink_victim"
chmod 600 -- "$pre_pip_hardlink_victim"
ln -- "$pre_pip_hardlink_victim" "$pre_pip_hardlink_log"
if DIFY_PIP_COMMAND="$fake_bin/pip-download" \
  without_proxy_environment download_wheels_once \
    "$metadata_dir/download.txt" "$download_once_wheel_dir" aarch64 3.12 \
    "$pre_pip_hardlink_log" '' "$download_once_case_dir/missing-built-wheels" true false \
    >/dev/null 2>&1; then
  fail 'pre-pip log reset rejects a hardlink path'
else
  pass 'pre-pip log reset rejects a hardlink path'
fi
assert_eq 'pre-pip-hardlink-victim' "$(<"$pre_pip_hardlink_victim")" 'pre-pip log reset never truncates a hardlink victim'

bounded_log_victim="$download_once_case_dir/bounded-log-victim.txt"
bounded_log_symlink="$download_once_case_dir/bounded-log-symlink.log"
printf 'victim-must-remain-unchanged\n' >"$bounded_log_victim"
ln -s -- "$bounded_log_victim" "$bounded_log_symlink"
if DIFY_PIP_COMMAND="$fake_bin/pip-download" \
  without_proxy_environment download_wheels_once \
    "$metadata_dir/download.txt" \
    "$download_once_wheel_dir" \
    aarch64 \
    3.12 \
    "$bounded_log_symlink" \
    '' \
    '' \
    true \
    false \
    >/dev/null 2>&1; then
  fail 'bounded one-shot capture rejects a swapped symlink log path'
else
  pass 'bounded one-shot capture rejects a swapped symlink log path'
fi
assert_eq 'victim-must-remain-unchanged' "$(<"$bounded_log_victim")" 'bounded capture never truncates a symlink victim'

bounded_hardlink_victim="$download_once_case_dir/bounded-hardlink-victim.txt"
bounded_hardlink_log="$download_once_case_dir/bounded-hardlink.log"
printf 'hardlink-victim-must-remain-unchanged\n' >"$bounded_hardlink_victim"
chmod 600 -- "$bounded_hardlink_victim"
ln -- "$bounded_hardlink_victim" "$bounded_hardlink_log"
if DIFY_PIP_COMMAND="$fake_bin/pip-download" \
  without_proxy_environment download_wheels_once \
    "$metadata_dir/download.txt" \
    "$download_once_wheel_dir" \
    aarch64 \
    3.12 \
    "$bounded_hardlink_log" \
    '' \
    '' \
    true \
    false \
    >/dev/null 2>&1; then
  fail 'bounded one-shot capture rejects a hard-linked log path'
else
  pass 'bounded one-shot capture rejects a hard-linked log path'
fi
assert_eq 'hardlink-victim-must-remain-unchanged' "$(<"$bounded_hardlink_victim")" 'bounded capture never truncates a hardlink victim'

set +e
sdist_repair_fixture_dir="$FIXTURE_DIR/sdist-repair-fixtures"
mkdir -p "$sdist_repair_fixture_dir"
python3 - "$sdist_repair_fixture_dir" <<'PY'
from pathlib import Path
import io
import sys
import tarfile
import zipfile


root = Path(sys.argv[1])


def write_sdist(path, name="docopt", version="0.6.2"):
    prefix = f"{name}-{version}"
    metadata = f"Metadata-Version: 2.1\nName: {name}\nVersion: {version}\n\n".encode()
    with tarfile.open(path, "w:gz") as archive:
        for member_name, contents in (
            (f"{prefix}/PKG-INFO", metadata),
            (f"{prefix}/setup.py", b"from setuptools import setup\nsetup()\n"),
        ):
            info = tarfile.TarInfo(member_name)
            info.size = len(contents)
            info.mode = 0o644
            archive.addfile(info, io.BytesIO(contents))


def write_wheel(path, name="docopt", version="0.6.2", pure=True, native=False, payload_size=0):
    distribution = name.replace("-", "_")
    dist_info = f"{distribution}-{version}.dist-info"
    wheel = (
        "Wheel-Version: 1.0\n"
        "Generator: repair-test\n"
        f"Root-Is-Purelib: {'true' if pure else 'false'}\n"
        "Tag: py2-none-any\n"
        "Tag: py3-none-any\n\n"
    ).encode()
    metadata = f"Metadata-Version: 2.1\nName: {name}\nVersion: {version}\n\n".encode()
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(f"{dist_info}/METADATA", metadata)
        archive.writestr(f"{dist_info}/WHEEL", wheel)
        archive.writestr(f"{distribution}.py", b"__version__ = '0.6.2'\n")
        if payload_size:
            archive.writestr(f"{distribution}/large_payload", b"\0" * payload_size)
        if native:
            archive.writestr(f"{distribution}/native_payload", b"\x7fELF" + b"\0" * 32)


write_sdist(root / "docopt-0.6.2.tar.gz")
write_sdist(root / "other-1.0.tar.gz", "other", "1.0")
write_wheel(root / "docopt-0.6.2-py2.py3-none-any.whl")
write_wheel(root / "other-1.0-py3-none-any.whl", "other", "1.0")
write_wheel(root / "docopt-0.6.2-py3-none-any.whl", pure=False)
write_wheel(root / "docopt-0.6.2-py2.py3-none-any-native.whl", native=True)
write_wheel(root / "docopt-0.6.2-py2.py3-none-any-large.whl", payload_size=32 * 1024 * 1024)
PY

cat >"$fake_bin/pip-sdist-repair" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
{
  printf 'CALL\n'
  printf 'ARG:%s\n' "$@"
} >>"$REPAIR_PIP_ARGS_LOG"
{
  printf 'CALL\n'
  printf 'HOME=%s\n' "${HOME:-}"
  printf 'NETRC_FILE=%s\n' "$([[ -f "${HOME:-}/.netrc" ]] && printf present || printf absent)"
  printf 'NETRC_MODE=%s\n' "$([[ -f "${HOME:-}/.netrc" ]] && stat -c '%a' "${HOME:-}/.netrc" || printf absent)"
  if [[ -f "${HOME:-}/.netrc" ]] && python3 -c 'import netrc, sys; assert netrc.netrc(sys.argv[1]).authenticators("target-index.example")' "${HOME:-}/.netrc"; then
    printf 'NETRC_PARSE=valid\n'
  else
    printf 'NETRC_PARSE=absent-or-invalid\n'
  fi
  printf 'PIP_EXTRA_INDEX_URL=%s\n' "${PIP_EXTRA_INDEX_URL:-}"
  printf 'PIP_CONFIG_FILE=%s\n' "${PIP_CONFIG_FILE:-}"
  printf 'PIP_MIRROR_URL=%s\n' "${PIP_MIRROR_URL:-}"
  printf 'NETRC=%s\n' "${NETRC:-}"
  printf 'PYTHONPATH=%s\n' "${PYTHONPATH:-}"
  printf 'PYTHONHOME=%s\n' "${PYTHONHOME:-}"
  printf 'VIRTUAL_ENV=%s\n' "${VIRTUAL_ENV:-}"
  printf 'CONDA_PREFIX=%s\n' "${CONDA_PREFIX:-}"
  printf 'HTTPS_PROXY=%s\n' "${HTTPS_PROXY:-${https_proxy:-}}"
  printf 'SSL_CERT_FILE=%s\n' "${SSL_CERT_FILE:-}"
} >>"$REPAIR_PIP_ENV_LOG"
tr '\0' ' ' <"/proc/$PPID/cmdline" >>"$REPAIR_TOOL_PROC_LOG"
printf '\n' >>"$REPAIR_TOOL_PROC_LOG"
dest=
while (($#)); do
  if [[ "$1" == --dest ]]; then
    shift
    dest=${1:-}
  fi
  shift
done
case "${REPAIR_PIP_MODE:-success}" in
  failure)
    printf 'download failed via https://download-user:download-password@mirror.example/simple?token=download-query#download-fragment\033[31m\n' >&2
    exit 41
    ;;
  truststore)
    attempt=0
    [[ -f "$REPAIR_PIP_ATTEMPT_FILE" ]] && attempt="$(<"$REPAIR_PIP_ATTEMPT_FILE")"
    attempt=$((attempt + 1))
    printf '%s\n' "$attempt" >"$REPAIR_PIP_ATTEMPT_FILE"
    if ((attempt == 1)); then
      printf '%s\n' "TypeError: PoolKey.__new__() got an unexpected keyword argument 'key_proxy_ssl_context'" >&2
      exit 42
    fi
    [[ "${PIP_USE_DEPRECATED:-}" == legacy-certs ]] || exit 43
    ;;
  slow)
    sleep 0.3
    ;;
esac
[[ -n "$dest" ]]
mkdir -p "$dest"
case "${REPAIR_PIP_MODE:-success}" in
  multiple)
    cp "$REPAIR_SDIST_FIXTURE" "$dest/"
    cp "$REPAIR_OTHER_SDIST_FIXTURE" "$dest/"
    ;;
  mismatch)
    cp "$REPAIR_OTHER_SDIST_FIXTURE" "$dest/"
    ;;
  corrupt)
    printf 'not an archive\n' >"$dest/docopt-0.6.2.tar.gz"
    ;;
  *)
    cp "$REPAIR_SDIST_FIXTURE" "$dest/"
    ;;
esac
EOF

cat >"$fake_bin/uv-sdist-repair" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
{
  printf 'CALL\n'
  printf 'ENV:UV_CACHE_DIR=%s\n' "${UV_CACHE_DIR:-}"
  printf 'ENV:UV_PYTHON_INSTALL_DIR=%s\n' "${UV_PYTHON_INSTALL_DIR:-}"
  printf 'ENV:CONDA_PREFIX=%s\n' "${CONDA_PREFIX:-}"
  printf 'ARG:%s\n' "$@"
} >>"$REPAIR_UV_ARGS_LOG"
{
  printf 'CALL\n'
  printf 'HOME=%s\n' "${HOME:-}"
  printf 'NETRC_FILE=%s\n' "$([[ -f "${HOME:-}/.netrc" ]] && printf present || printf absent)"
  printf 'NETRC_MODE=%s\n' "$([[ -f "${HOME:-}/.netrc" ]] && stat -c '%a' "${HOME:-}/.netrc" || printf absent)"
  if [[ -f "${HOME:-}/.netrc" ]] && python3 -c 'import netrc, sys; assert netrc.netrc(sys.argv[1]).authenticators("target-index.example")' "${HOME:-}/.netrc"; then
    printf 'NETRC_PARSE=valid\n'
  else
    printf 'NETRC_PARSE=absent-or-invalid\n'
  fi
  printf 'UV_NO_BUILD_ISOLATION=%s\n' "${UV_NO_BUILD_ISOLATION:-}"
  printf 'UV_EXTRA_INDEX_URL=%s\n' "${UV_EXTRA_INDEX_URL:-}"
  printf 'PIP_EXTRA_INDEX_URL=%s\n' "${PIP_EXTRA_INDEX_URL:-}"
  printf 'PIP_MIRROR_URL=%s\n' "${PIP_MIRROR_URL:-}"
  printf 'NETRC=%s\n' "${NETRC:-}"
  printf 'PYTHONPATH=%s\n' "${PYTHONPATH:-}"
  printf 'PYTHONHOME=%s\n' "${PYTHONHOME:-}"
  printf 'VIRTUAL_ENV=%s\n' "${VIRTUAL_ENV:-}"
  printf 'CONDA_PREFIX=%s\n' "${CONDA_PREFIX:-}"
  printf 'HTTPS_PROXY=%s\n' "${HTTPS_PROXY:-${https_proxy:-}}"
  printf 'SSL_CERT_FILE=%s\n' "${SSL_CERT_FILE:-}"
} >>"$REPAIR_UV_ENV_LOG"
tr '\0' ' ' <"/proc/$PPID/cmdline" >>"$REPAIR_TOOL_PROC_LOG"
printf '\n' >>"$REPAIR_TOOL_PROC_LOG"
if [[ "${REPAIR_UV_MODE:-success}" == failure ]]; then
  printf 'build failed via socks5h://build-user:build-password@10.10.10.10:28802/path?token=build-query#build-fragment diagnostic\033[31m\n' >&2
  exit 51
fi
if [[ "${REPAIR_UV_MODE:-success}" == flood-failure ]]; then
  head -c $((2 * 1024 * 1024)) /dev/zero | tr '\0' X >&2
  exit 52
fi
if [[ "${REPAIR_UV_MODE:-success}" == timeout ]]; then
  sleep 5
  exit 53
fi
if [[ "${REPAIR_UV_MODE:-success}" == steal-secrets ]]; then
  {
    printf 'HOME=%s\n' "${HOME:-}"
    [[ -f "${HOME:-}/.netrc" ]] && sed 's/^/NETRC:/' "${HOME:-}/.netrc"
    env | grep -E 'SECRET|TOKEN|PASSWORD|PIP_MIRROR_URL' || true
  } >"$REPAIR_SECRET_STEAL_MARKER"
  exit 54
fi
out_dir=
while (($#)); do
  if [[ "$1" == --out-dir ]]; then
    shift
    out_dir=${1:-}
  fi
  shift
done
[[ -n "$out_dir" ]]
mkdir -p "$out_dir"
case "${REPAIR_UV_MODE:-success}" in
  slow)
    sleep 1
    cp "$REPAIR_WHEEL_FIXTURE" "$out_dir/"
    ;;
  replace-original)
    cp "$REPAIR_LARGE_WHEEL_FIXTURE" "$out_dir/docopt-0.6.2-py2.py3-none-any.whl"
    (
      candidate_dir="$(dirname -- "$out_dir")"
      for _ in $(seq 1 3000); do
        if pgrep -af 'validate_python_distribution.py' | grep -Fq -- "$candidate_dir"; then
          cp "$REPAIR_NATIVE_WHEEL_FIXTURE" "$out_dir/docopt-0.6.2-py2.py3-none-any.whl"
          printf 'seen\n' >"$REPAIR_REPLACER_SEEN"
          exit
        fi
        sleep 0.001
      done
    ) </dev/null >/dev/null 2>&1 &
    printf '%s\n' "$!" >"$REPAIR_REPLACER_PID_FILE"
    ;;
  mutate-snapshot)
    cp "$REPAIR_LARGE_WHEEL_FIXTURE" "$out_dir/docopt-0.6.2-py2.py3-none-any.whl"
    ;;
  background-replace)
    cp "$REPAIR_WHEEL_FIXTURE" "$out_dir/"
    (
      printf 'started\n' >"$REPAIR_BACKGROUND_STARTED"
      for _ in $(seq 1 10000); do
        if [[ -f "$REPAIR_BACKGROUND_BUILT_WHEEL" ]]; then
          chmod u+w "$REPAIR_BACKGROUND_BUILT_WHEEL" 2>/dev/null || true
          cp "$REPAIR_NATIVE_WHEEL_FIXTURE" "$REPAIR_BACKGROUND_BUILT_WHEEL" 2>/dev/null || true
          printf 'replaced\n' >"$REPAIR_BACKGROUND_REPLACED"
          exit
        fi
        sleep 0.001
      done
    ) </dev/null >/dev/null 2>&1 &
    for _ in $(seq 1 1000); do
      [[ -f "$REPAIR_BACKGROUND_STARTED" ]] && break
      sleep 0.001
    done
    ;;
  double-fork-replace)
    cp "$REPAIR_WHEEL_FIXTURE" "$out_dir/"
    python3 - "$REPAIR_BACKGROUND_STARTED" "$REPAIR_BACKGROUND_REPLACED" \
      "$REPAIR_BACKGROUND_BUILT_WHEEL" "$REPAIR_NATIVE_WHEEL_FIXTURE" <<'PY'
import os
from pathlib import Path
import shutil
import sys
import time


started, replaced, built_wheel, malicious_wheel = map(Path, sys.argv[1:])
if os.fork():
    raise SystemExit(0)
os.setsid()
if os.fork():
    os._exit(0)
null_fd = os.open(os.devnull, os.O_RDWR)
for descriptor in (0, 1, 2):
    os.dup2(null_fd, descriptor)
if null_fd > 2:
    os.close(null_fd)
started.write_text("started\n", encoding="utf-8")
for _ in range(10000):
    if built_wheel.is_file():
        try:
            built_wheel.chmod(0o600)
            shutil.copyfile(malicious_wheel, built_wheel)
            replaced.write_text("replaced\n", encoding="utf-8")
        except OSError:
            pass
        os._exit(0)
    time.sleep(0.001)
os._exit(0)
PY
    for _ in $(seq 1 1000); do
      [[ -f "$REPAIR_BACKGROUND_STARTED" ]] && break
      sleep 0.001
    done
    ;;
  hold-pipe)
    cp "$REPAIR_WHEEL_FIXTURE" "$out_dir/"
    python3 - "$REPAIR_BACKGROUND_STARTED" <<'PY' &
import os
from pathlib import Path
import sys
import time


if os.fork():
    raise SystemExit(0)
Path(sys.argv[1]).write_text("started\n", encoding="utf-8")
time.sleep(5)
os._exit(0)
PY
    for _ in $(seq 1 1000); do
      [[ -f "$REPAIR_BACKGROUND_STARTED" ]] && break
      sleep 0.001
    done
    ;;
  cancel-block)
    printf '%s\n' "$BASHPID" >"$REPAIR_CANCEL_UV_PID_FILE"
    (
      printf '%s\n' "$BASHPID" >"$REPAIR_CANCEL_CHILD_PID_FILE"
      while :; do sleep 1; done
    ) </dev/null >/dev/null 2>&1 &
    python3 - "$REPAIR_CANCEL_DOUBLEFORK_PID_FILE" <<'PY'
import os
from pathlib import Path
import sys
import time


if os.fork():
    raise SystemExit(0)
os.setsid()
if os.fork():
    os._exit(0)
null_fd = os.open(os.devnull, os.O_RDWR)
for descriptor in (0, 1, 2):
    os.dup2(null_fd, descriptor)
if null_fd > 2:
    os.close(null_fd)
Path(sys.argv[1]).write_text(f"{os.getpid()}\n", encoding="utf-8")
while True:
    time.sleep(1)
PY
    for _ in $(seq 1 1000); do
      [[ -s "$REPAIR_CANCEL_CHILD_PID_FILE" && -s "$REPAIR_CANCEL_DOUBLEFORK_PID_FILE" ]] && break
      sleep 0.001
    done
    while :; do sleep 1; done
    ;;
  native)
    cp "$REPAIR_NATIVE_WHEEL_FIXTURE" "$out_dir/docopt-0.6.2-py2.py3-none-any.whl"
    ;;
  nonpure)
    cp "$REPAIR_NONPURE_WHEEL_FIXTURE" "$out_dir/"
    ;;
  mismatch)
    cp "$REPAIR_OTHER_WHEEL_FIXTURE" "$out_dir/"
    ;;
  multiple)
    cp "$REPAIR_WHEEL_FIXTURE" "$out_dir/"
    printf 'not a wheel\n' >"$out_dir/extra-1.0-py3-none-any.whl"
    ;;
  *)
    cp "$REPAIR_WHEEL_FIXTURE" "$out_dir/"
    ;;
esac
EOF
chmod +x "$fake_bin/pip-sdist-repair" "$fake_bin/uv-sdist-repair"

export REPAIR_PIP_ARGS_LOG="$FIXTURE_DIR/sdist-repair-pip.args"
export REPAIR_UV_ARGS_LOG="$FIXTURE_DIR/sdist-repair-uv.args"
export REPAIR_PIP_ENV_LOG="$FIXTURE_DIR/sdist-repair-pip.env"
export REPAIR_UV_ENV_LOG="$FIXTURE_DIR/sdist-repair-uv.env"
export REPAIR_TOOL_PROC_LOG="$FIXTURE_DIR/sdist-repair-tool-proc.log"
export REPAIR_SDIST_FIXTURE="$sdist_repair_fixture_dir/docopt-0.6.2.tar.gz"
export REPAIR_OTHER_SDIST_FIXTURE="$sdist_repair_fixture_dir/other-1.0.tar.gz"
export REPAIR_WHEEL_FIXTURE="$sdist_repair_fixture_dir/docopt-0.6.2-py2.py3-none-any.whl"
export REPAIR_OTHER_WHEEL_FIXTURE="$sdist_repair_fixture_dir/other-1.0-py3-none-any.whl"
export REPAIR_NONPURE_WHEEL_FIXTURE="$sdist_repair_fixture_dir/docopt-0.6.2-py3-none-any.whl"
export REPAIR_NATIVE_WHEEL_FIXTURE="$sdist_repair_fixture_dir/docopt-0.6.2-py2.py3-none-any-native.whl"
export REPAIR_LARGE_WHEEL_FIXTURE="$sdist_repair_fixture_dir/docopt-0.6.2-py2.py3-none-any-large.whl"
export REPAIR_REPLACER_PID_FILE="$FIXTURE_DIR/sdist-repair-replacer.pid"
export REPAIR_MUTATION_PID_FILE="$FIXTURE_DIR/sdist-repair-mutation.pid"
export REPAIR_REPLACER_SEEN="$FIXTURE_DIR/sdist-repair-replacer.seen"
export REPAIR_BACKGROUND_STARTED="$FIXTURE_DIR/sdist-repair-background.started"
export REPAIR_BACKGROUND_REPLACED="$FIXTURE_DIR/sdist-repair-background.replaced"
export REPAIR_SECRET_STEAL_MARKER="$FIXTURE_DIR/sdist-repair-secret-steal.marker"
export REPAIR_CANCEL_UV_PID_FILE="$FIXTURE_DIR/sdist-repair-cancel-uv.pid"
export REPAIR_CANCEL_CHILD_PID_FILE="$FIXTURE_DIR/sdist-repair-cancel-child.pid"
export REPAIR_CANCEL_DOUBLEFORK_PID_FILE="$FIXTURE_DIR/sdist-repair-cancel-doublefork.pid"
: >"$REPAIR_PIP_ARGS_LOG"
: >"$REPAIR_UV_ARGS_LOG"
: >"$REPAIR_PIP_ENV_LOG"
: >"$REPAIR_UV_ENV_LOG"
: >"$REPAIR_TOOL_PROC_LOG"

repair_parent="$FIXTURE_DIR/repair parent with spaces"
mkdir -p "$repair_parent"
repair_dir="$repair_parent/sdist-repair"
fake_conda_prefix="$FIXTURE_DIR/fake-conda"
mkdir -p "$fake_conda_prefix"
printf 'unchanged\n' >"$fake_conda_prefix/marker"
repair_requirement='docopt>=0.6,<1'
repair_pip_command=("$fake_bin/pip-sdist-repair")
repair_success_log="$FIXTURE_DIR/sdist-repair-success.log"
if PIP_MIRROR_URL='https://target-index.example/simple' \
  UV_NO_BUILD_ISOLATION='uv-isolation-sentinel' \
  UV_EXTRA_INDEX_URL='https://uv-extra-sentinel.example/simple' \
  PIP_EXTRA_INDEX_URL='https://pip-extra-sentinel.example/simple' \
  PIP_CONFIG_FILE="$FIXTURE_DIR/pip-config-sentinel" \
  NETRC="$FIXTURE_DIR/netrc-sentinel" \
  PYTHONPATH="$FIXTURE_DIR/pythonpath-sentinel" \
  PYTHONHOME=/usr \
  VIRTUAL_ENV="$FIXTURE_DIR/venv-sentinel" \
  HOME="$FIXTURE_DIR/home-sentinel" \
  CONDA_PREFIX="$fake_conda_prefix" \
  https_proxy='http://required-proxy.example:8080' HTTPS_PROXY= \
  http_proxy= HTTP_PROXY= all_proxy= ALL_PROXY= \
  SSL_CERT_FILE="$FIXTURE_DIR/ca-sentinel.pem" \
  repair_one_pure_sdist \
    repair_pip_command \
    "$fake_bin/uv-sdist-repair" \
    "$repair_requirement" \
    docopt \
    3.12 \
    "$repair_dir" \
    '' \
    1 >"$repair_success_log" 2>&1; then
  pass 'one pure source distribution is repaired in isolated staging'
else
  fail 'one pure source distribution is repaired in isolated staging'
  sed 's/^/# sdist repair: /' "$repair_success_log"
fi
assert_file_contains "$repair_success_log" 'Pure Python wheel admitted: docopt-0.6.2-py2.py3-none-any.whl' 'successful repair reports admitted wheel only after validation'
if [[ -f "$repair_dir/built-wheels/docopt-0.6.2-py2.py3-none-any.whl" ]]; then
  pass 'validated universal wheel reaches built-wheels'
else
  fail 'validated universal wheel reaches built-wheels'
fi
expected_repair_pip_args="$FIXTURE_DIR/expected-repair-pip.args"
printf '%s\n' \
  'CALL' \
  'ARG:download' \
  'ARG:--isolated' \
  'ARG:--disable-pip-version-check' \
  'ARG:--index-url' \
  'ARG:https://target-index.example/simple' \
  'ARG:--python-version' \
  'ARG:3.12' \
  'ARG:--implementation' \
  'ARG:cp' \
  'ARG:--no-deps' \
  'ARG:--no-binary=:all:' \
  'ARG:--dest' \
  "ARG:$repair_dir/candidate-1/source" \
  "ARG:$repair_requirement" >"$expected_repair_pip_args"
if diff -u "$expected_repair_pip_args" "$REPAIR_PIP_ARGS_LOG" >/dev/null; then
  pass 'sdist download uses exact target, index, isolation, destination, and one requirement argument'
else
  fail 'sdist download uses exact target, index, isolation, destination, and one requirement argument'
fi
assert_eq 1 "$(grep -Fxc -- "ARG:$repair_requirement" "$REPAIR_PIP_ARGS_LOG")" 'legal version constraint remains one pip argument'
validated_sdist_path="$(realpath -m -- "$repair_dir/candidate-1/source/docopt-0.6.2.tar.gz")"
expected_repair_uv_args="$FIXTURE_DIR/expected-repair-uv.args"
printf '%s\n' \
  'CALL' \
  "ENV:UV_CACHE_DIR=$repair_dir/uv-cache" \
  "ENV:UV_PYTHON_INSTALL_DIR=$repair_dir/uv-python" \
  'ENV:CONDA_PREFIX=' \
  'ARG:build' \
  'ARG:--wheel' \
  'ARG:--no-config' \
  'ARG:--out-dir' \
  "ARG:$repair_dir/candidate-1/wheel" \
  'ARG:--python' \
  'ARG:3.12' \
  'ARG:--index-url' \
  'ARG:https://target-index.example/simple' \
  "ARG:$validated_sdist_path" >"$expected_repair_uv_args"
if diff -u "$expected_repair_uv_args" "$REPAIR_UV_ARGS_LOG" >/dev/null; then
  pass 'uv build uses exact target Python, configured index, validated sdist, and controlled cache paths'
else
  fail 'uv build uses exact target Python, configured index, validated sdist, and controlled cache paths'
fi
assert_eq unchanged "$(<"$fake_conda_prefix/marker")" 'repair leaves caller Conda prefix contents unchanged'
for environment_log in "$REPAIR_PIP_ENV_LOG" "$REPAIR_UV_ENV_LOG"; do
  assert_file_contains "$environment_log" "HOME=$repair_dir/candidate-1" 'tool child receives only the controlled private HOME'
  assert_file_contains "$environment_log" 'NETRC_FILE=absent' 'tool child receives no package-index credential file'
  assert_file_contains "$environment_log" 'NETRC_MODE=absent' 'tool child cannot read private index credentials'
  assert_file_contains "$environment_log" 'NETRC_PARSE=absent-or-invalid' 'tool child receives no parseable netrc authentication'
  assert_file_contains "$environment_log" 'HTTPS_PROXY=http://required-proxy.example:8080' 'required HTTP proxy survives environment isolation'
  assert_file_contains "$environment_log" "SSL_CERT_FILE=$FIXTURE_DIR/ca-sentinel.pem" 'required CA environment survives isolation'
  for poisoned_value in uv-isolation-sentinel uv-extra-sentinel pip-extra-sentinel pip-config-sentinel \
    pythonpath-sentinel /usr venv-sentinel home-sentinel fake-conda netrc-sentinel \
    caller-secret-sentinel; do
    assert_file_not_contains "$environment_log" "$poisoned_value" "tool child environment excludes caller poison $poisoned_value"
  done
done
for tool_args_log in "$REPAIR_PIP_ARGS_LOG" "$REPAIR_UV_ARGS_LOG"; do
  assert_file_not_contains "$tool_args_log" 'caller-secret-sentinel' 'tool argv excludes caller secret sentinel'
done
assert_file_not_contains "$REPAIR_TOOL_PROC_LOG" 'caller-secret-sentinel' 'caller secret sentinel is absent from observed parent process argv'
assert_file_missing "$repair_dir/candidate-1/auth-home/.netrc" 'successful repair removes private netrc immediately after tool use'
assert_file_missing "$repair_dir/candidate-1/auth-home" 'successful repair removes its empty private authentication HOME'

for hostile_index_url in \
  'https://good.example machine evil.example/simple' \
  'https://good%20example.example/simple' \
  'https://user:password@target-index.example/simple' \
  'https://user%20name:password@target-index.example/simple' \
  'https://user:pass%0Aword@target-index.example/simple' \
  'https://user:pass%22word@target-index.example/simple' \
  'https://user:pass%5Cword@target-index.example/simple' \
  'https://target-index.example/simple?token=secret' \
  'https://target-index.example/simple#secret' \
  'https://target-index.example/simple%20path'; do
  if printf '%s' "$hostile_index_url" | sanitize_index_url_for_tools >/dev/null 2>&1; then
    fail 'authenticated or ambiguous source-build index is rejected'
  else
    pass 'authenticated or ambiguous source-build index is rejected'
  fi
done
assert_eq \
  'https://[2001:db8::1]:8443/simple' \
  "$(printf '%s' 'https://[2001:db8::1]:8443/simple' | sanitize_index_url_for_tools)" \
  'unauthenticated IPv6 package index with an explicit port is accepted exactly'

authenticated_repair_parent="$FIXTURE_DIR/authenticated repair parent"
mkdir -p "$authenticated_repair_parent"
authenticated_repair_dir="$authenticated_repair_parent/sdist-repair"
authenticated_repair_log="$FIXTURE_DIR/sdist-repair-authenticated-index.log"
pip_calls_before="$(grep -c '^CALL$' "$REPAIR_PIP_ARGS_LOG")"
uv_calls_before="$(grep -c '^CALL$' "$REPAIR_UV_ARGS_LOG")"
rm -f -- "$REPAIR_SECRET_STEAL_MARKER"
if PIP_MIRROR_URL='https://auth-user-sentinel:auth-password-sentinel@target-index.example/simple' \
  REPAIR_UV_MODE=steal-secrets CALLER_SECRET_TOKEN='environment-secret-sentinel' \
  without_proxy_environment repair_one_pure_sdist \
    repair_pip_command "$fake_bin/uv-sdist-repair" docopt docopt 3.12 "$authenticated_repair_dir" '' 1 \
    >"$authenticated_repair_log" 2>&1; then
  fail 'authenticated index is rejected before arbitrary source-build code can run'
else
  pass 'authenticated index is rejected before arbitrary source-build code can run'
fi
assert_file_contains "$authenticated_repair_log" \
  'authenticated package indexes are unsupported for third-party source builds' \
  'authenticated source-build index rejection has a fixed safe explanation'
for secret_value in auth-user-sentinel auth-password-sentinel environment-secret-sentinel; do
  assert_file_not_contains "$authenticated_repair_log" "$secret_value" "authenticated index rejection hides $secret_value"
done
assert_eq "$pip_calls_before" "$(grep -c '^CALL$' "$REPAIR_PIP_ARGS_LOG")" 'authenticated index rejection cannot invoke pip'
assert_eq "$uv_calls_before" "$(grep -c '^CALL$' "$REPAIR_UV_ARGS_LOG")" 'authenticated index rejection cannot invoke uv'
assert_file_missing "$REPAIR_SECRET_STEAL_MARKER" 'adversarial backend cannot inspect HOME, netrc, or caller environment secrets'
assert_file_missing "$authenticated_repair_dir" 'authenticated index rejection creates no source-repair staging'

query_repair_parent="$FIXTURE_DIR/query repair parent"
mkdir -p "$query_repair_parent"
query_repair_dir="$query_repair_parent/sdist-repair"
pip_calls_before="$(grep -c '^CALL$' "$REPAIR_PIP_ARGS_LOG")"
if PIP_MIRROR_URL='https://query-user:query-password@target-index.example/simple?token=argv-query-sentinel#argv-fragment-sentinel' \
  without_proxy_environment repair_one_pure_sdist \
    repair_pip_command "$fake_bin/uv-sdist-repair" docopt docopt 3.12 "$query_repair_dir" '' 1 \
    >"$FIXTURE_DIR/sdist-repair-query-index.log" 2>&1; then
  fail 'index query and fragment credentials fail closed before tool execution'
else
  pass 'index query and fragment credentials fail closed before tool execution'
fi
assert_eq "$pip_calls_before" "$(grep -c '^CALL$' "$REPAIR_PIP_ARGS_LOG")" 'unsafe index query cannot reach pip argv'
assert_file_missing "$query_repair_dir" 'unsafe index query creates no repair staging'
for secret_value in query-user query-password argv-query-sentinel argv-fragment-sentinel; do
  assert_file_not_contains "$FIXTURE_DIR/sdist-repair-query-index.log" "$secret_value" "unsafe index explanation hides $secret_value"
done

pip_calls_before="$(grep -c '^CALL$' "$REPAIR_PIP_ARGS_LOG")"
if without_proxy_environment repair_one_pure_sdist \
  repair_pip_command "$fake_bin/uv-sdist-repair" '--index-url=evil' docopt 3.12 "$repair_dir" '' 2 \
  >"$FIXTURE_DIR/sdist-repair-unsafe-requirement.log" 2>&1; then
  fail 'option-like sdist requirement is rejected before pip'
else
  pass 'option-like sdist requirement is rejected before pip'
fi
assert_eq "$pip_calls_before" "$(grep -c '^CALL$' "$REPAIR_PIP_ARGS_LOG")" 'unsafe requirement cannot invoke pip'
assert_file_missing "$repair_dir/candidate-2" 'unsafe requirement creates no candidate staging'
for invalid_identifier_case in pip-name canonical-name python-version; do
  identifier_pip_name=repair_pip_command
  identifier_canonical_name=docopt
  identifier_python_version=3.12
  case "$invalid_identifier_case" in
    pip-name)
      identifier_pip_name='bad[name]'
      ;;
    canonical-name)
      identifier_canonical_name='docopt/../../outside'
      ;;
    python-version)
      identifier_python_version='3.12 --system'
      ;;
  esac
  if without_proxy_environment repair_one_pure_sdist \
    "$identifier_pip_name" "$fake_bin/uv-sdist-repair" docopt "$identifier_canonical_name" \
    "$identifier_python_version" "$repair_dir" '' 2 \
    >"$FIXTURE_DIR/sdist-repair-invalid-$invalid_identifier_case.log" 2>&1; then
    fail "$invalid_identifier_case is rejected before repair side effects"
  else
    pass "$invalid_identifier_case is rejected before repair side effects"
  fi
done
assert_eq "$pip_calls_before" "$(grep -c '^CALL$' "$REPAIR_PIP_ARGS_LOG")" 'invalid repair identifiers cannot invoke pip'
assert_file_missing "$repair_dir/candidate-2" 'invalid repair identifiers create no candidate staging'
assert_file_contains "$FIXTURE_DIR/sdist-repair-invalid-pip-name.log" \
  'invalid pip command array name for pure Python sdist repair' \
  'invalid pip array name is rejected before Bash nameref evaluation'
assert_file_not_contains "$FIXTURE_DIR/sdist-repair-invalid-pip-name.log" \
  'invalid variable name for name reference' \
  'invalid pip array name cannot trigger a Bash nameref diagnostic'
identifier_function_source="$(sed -n '/^validate_sdist_repair_identifiers() {/,/^}/p' "$ROOT_DIR/plugin_repackaging.sh")"
identifier_name_check_line="$(grep -n 'pip_command_name.*=~' <<<"$identifier_function_source" | head -n1 | cut -d: -f1)"
identifier_nameref_line="$(grep -n 'local -n selected_pip_command' <<<"$identifier_function_source" | head -n1 | cut -d: -f1)"
if [[ -n "$identifier_name_check_line" && -n "$identifier_nameref_line" ]] && \
  ((identifier_name_check_line < identifier_nameref_line)); then
  pass 'pip array identifier syntax is checked before creating a Bash nameref'
else
  fail 'pip array identifier syntax is checked before creating a Bash nameref'
fi

if validate_sdist_repair_dir relative/sdist-repair >/dev/null 2>&1 || \
  validate_sdist_repair_dir "$repair_parent/not-repair" >/dev/null 2>&1; then
  fail 'repair staging requires an absolute path with the exact sdist-repair leaf'
else
  pass 'repair staging requires an absolute path with the exact sdist-repair leaf'
fi
symlink_parent_target="$FIXTURE_DIR/symlink-parent-target"
symlink_parent="$FIXTURE_DIR/symlink-parent"
mkdir -p "$symlink_parent_target"
ln -s "$symlink_parent_target" "$symlink_parent"
if without_proxy_environment repair_one_pure_sdist \
  repair_pip_command "$fake_bin/uv-sdist-repair" docopt docopt 3.12 "$symlink_parent/sdist-repair" '' 1 \
  >"$FIXTURE_DIR/sdist-repair-symlink.log" 2>&1; then
  fail 'symlinked repair staging parent is rejected before writes'
else
  pass 'symlinked repair staging parent is rejected before writes'
fi
assert_file_missing "$symlink_parent_target/sdist-repair" 'symlink rejection prevents writes outside controlled tree'
mkdir -p "$symlink_parent_target/sdist-repair/candidate-1/source"
pip_calls_before="$(grep -c '^CALL$' "$REPAIR_PIP_ARGS_LOG")"
if without_proxy_environment download_sdist \
  repair_pip_command docopt 3.12 \
  "$symlink_parent/sdist-repair/candidate-1/source" '' \
  "$symlink_parent/sdist-repair/candidate-1/download.log" \
  >"$FIXTURE_DIR/sdist-download-symlink.log" 2>&1; then
  fail 'direct sdist download rejects a symlinked repair ancestor'
else
  pass 'direct sdist download rejects a symlinked repair ancestor'
fi
assert_eq "$pip_calls_before" "$(grep -c '^CALL$' "$REPAIR_PIP_ARGS_LOG")" 'symlinked direct sdist download cannot invoke pip'
invalid_socks_target="$FIXTURE_DIR/invalid-socks-target"
invalid_socks_link="$FIXTURE_DIR/invalid-socks-link"
mkdir -p "$invalid_socks_target"
ln -s "$invalid_socks_target" "$invalid_socks_link"
pip_calls_before="$(grep -c '^CALL$' "$REPAIR_PIP_ARGS_LOG")"
if without_proxy_environment repair_one_pure_sdist \
  repair_pip_command "$fake_bin/uv-sdist-repair" docopt docopt 3.12 "$repair_dir" "$invalid_socks_link" 11 \
  >"$FIXTURE_DIR/sdist-repair-invalid-socks-site.log" 2>&1; then
  fail 'symlinked temporary SOCKS site is rejected before repair side effects'
else
  pass 'symlinked temporary SOCKS site is rejected before repair side effects'
fi
assert_eq "$pip_calls_before" "$(grep -c '^CALL$' "$REPAIR_PIP_ARGS_LOG")" 'unsafe temporary SOCKS site cannot invoke pip'
assert_file_missing "$repair_dir/candidate-11" 'unsafe temporary SOCKS site creates no candidate staging'
if without_proxy_environment repair_one_pure_sdist \
  repair_pip_command "$fake_bin/uv-sdist-repair" docopt docopt 3.12 "$repair_dir" '' 0 \
  >"$FIXTURE_DIR/sdist-repair-ordinal.log" 2>&1; then
  fail 'candidate ordinal must be a positive decimal'
else
  pass 'candidate ordinal must be a positive decimal'
fi
pip_calls_before="$(grep -c '^CALL$' "$REPAIR_PIP_ARGS_LOG")"
if without_proxy_environment repair_one_pure_sdist \
  repair_pip_command "$fake_bin/uv-sdist-repair" docopt docopt 3.12 "$repair_dir" '' 1 \
  >"$FIXTURE_DIR/sdist-repair-reuse.log" 2>&1; then
  fail 'existing candidate staging cannot be reused'
else
  pass 'existing candidate staging cannot be reused'
fi
assert_eq "$pip_calls_before" "$(grep -c '^CALL$' "$REPAIR_PIP_ARGS_LOG")" 'candidate reuse is rejected before pip'

uv_calls_before="$(grep -c '^CALL$' "$REPAIR_UV_ARGS_LOG")"
download_failure_log="$FIXTURE_DIR/sdist-repair-download-failure.log"
if PIP_MIRROR_URL='https://target-index.example/simple' \
  REPAIR_PIP_MODE=failure \
  without_proxy_environment repair_one_pure_sdist \
    repair_pip_command "$fake_bin/uv-sdist-repair" docopt docopt 3.12 "$repair_dir" '' 2 \
    >"$download_failure_log" 2>&1; then
  fail 'sdist download failure stops repair'
else
  pass 'sdist download failure stops repair'
fi
assert_file_contains "$download_failure_log" 'Pure Python sdist repair failed during download: docopt (index: https://target-index.example/simple)' 'download failure reports a stable sanitized stage error'
for secret_value in download-user download-password download-query download-fragment index-user index-password $'\033'; do
  assert_file_not_contains "$download_failure_log" "$secret_value" "download repair diagnostic hides $secret_value"
done
assert_eq "$uv_calls_before" "$(grep -c '^CALL$' "$REPAIR_UV_ARGS_LOG")" 'download failure does not invoke uv'
assert_file_missing "$repair_dir/built-wheels/partial-2.whl" 'download failure admits no partial wheel'
assert_file_missing "$repair_dir/candidate-2/auth-home/.netrc" 'download failure removes private index credentials'

for sdist_mode in corrupt multiple mismatch; do
  ordinal=3
  [[ "$sdist_mode" == multiple ]] && ordinal=4
  [[ "$sdist_mode" == mismatch ]] && ordinal=5
  uv_calls_before="$(grep -c '^CALL$' "$REPAIR_UV_ARGS_LOG")"
  validation_log="$FIXTURE_DIR/sdist-repair-$sdist_mode-sdist.log"
  if PIP_MIRROR_URL='https://target-index.example/simple' \
    REPAIR_PIP_MODE="$sdist_mode" \
    without_proxy_environment repair_one_pure_sdist \
      repair_pip_command "$fake_bin/uv-sdist-repair" docopt docopt 3.12 "$repair_dir" '' "$ordinal" \
      >"$validation_log" 2>&1; then
    fail "$sdist_mode sdist is rejected during validation"
  else
    pass "$sdist_mode sdist is rejected during validation"
  fi
  assert_file_contains "$validation_log" 'Pure Python sdist repair failed during validation: docopt' "$sdist_mode sdist reports the validation stage"
  assert_file_contains "$validation_log" 'validation failed:' "$sdist_mode sdist retains the validator explanation"
  assert_eq "$uv_calls_before" "$(grep -c '^CALL$' "$REPAIR_UV_ARGS_LOG")" "$sdist_mode sdist cannot invoke uv"
  assert_file_missing "$repair_dir/candidate-$ordinal/auth-home/.netrc" "$sdist_mode sdist validation failure removes private index credentials"
done

build_failure_log="$FIXTURE_DIR/sdist-repair-build-failure.log"
if PIP_MIRROR_URL='https://target-index.example/simple' \
  REPAIR_UV_MODE=failure \
  without_proxy_environment repair_one_pure_sdist \
    repair_pip_command "$fake_bin/uv-sdist-repair" docopt docopt 3.12 "$repair_dir" '' 6 \
    >"$build_failure_log" 2>&1; then
  fail 'uv build failure stops repair'
else
  pass 'uv build failure stops repair'
fi
assert_file_contains "$build_failure_log" 'Pure Python sdist repair failed during build: docopt' 'build failure reports a stable stage error'
assert_file_contains "$build_failure_log" 'socks5h://***@10.10.10.10:28802/path' 'build failure retains a safe proxy location'
for secret_value in build-user build-password build-query build-fragment $'\033'; do
  assert_file_not_contains "$build_failure_log" "$secret_value" "build repair diagnostic hides $secret_value"
done
assert_file_missing "$repair_dir/candidate-6/auth-home/.netrc" 'build failure removes private index credentials after supervised process cleanup'

for wheel_mode in native nonpure multiple mismatch; do
  ordinal=7
  [[ "$wheel_mode" == nonpure ]] && ordinal=8
  [[ "$wheel_mode" == multiple ]] && ordinal=9
  [[ "$wheel_mode" == mismatch ]] && ordinal=10
  validation_log="$FIXTURE_DIR/sdist-repair-$wheel_mode-wheel.log"
  if PIP_MIRROR_URL='https://target-index.example/simple' \
    REPAIR_UV_MODE="$wheel_mode" \
    without_proxy_environment repair_one_pure_sdist \
      repair_pip_command "$fake_bin/uv-sdist-repair" docopt docopt 3.12 "$repair_dir" '' "$ordinal" \
      >"$validation_log" 2>&1; then
    fail "$wheel_mode wheel is rejected during validation"
  else
    pass "$wheel_mode wheel is rejected during validation"
  fi
  assert_file_contains "$validation_log" 'Pure Python sdist repair failed during validation: docopt' "$wheel_mode wheel reports the validation stage"
  assert_file_contains "$validation_log" 'validation failed:' "$wheel_mode wheel retains the validator explanation"
  assert_file_missing "$repair_dir/candidate-$ordinal/auth-home/.netrc" "$wheel_mode wheel validation failure removes private index credentials"
done
assert_eq 1 "$(find "$repair_dir/built-wheels" -maxdepth 1 -type f -name '*.whl' | wc -l)" 'rejected wheels never enter built-wheels'

for private_dir in \
  "$repair_dir" \
  "$repair_dir/candidate-1" \
  "$repair_dir/candidate-1/source" \
  "$repair_dir/candidate-1/wheel" \
  "$repair_dir/built-wheels" \
  "$repair_dir/uv-cache" \
  "$repair_dir/uv-python"; do
  assert_eq 700 "$(stat -c '%a' "$private_dir")" "private repair directory uses mode 0700: $(basename -- "$private_dir")"
done
assert_eq 400 "$(stat -c '%a' "$repair_dir/built-wheels/docopt-0.6.2-py2.py3-none-any.whl")" 'admitted wheel is nonwritable'
assert_eq 0 "$(find "$repair_dir" -type f \( -name '*download*log*' -o -name '*build*log*' -o -name '*validation*log*' -o -name '*.record' \) | wc -l)" 'raw Task3 logs are removed after reporting'
assert_eq 0 "$(find "$repair_dir" -type d -name '.admission.*' | wc -l)" 'successful admission removes its private snapshot directory'

replace_repair_parent="$FIXTURE_DIR/replace repair parent"
mkdir -p "$replace_repair_parent"
replace_repair_dir="$replace_repair_parent/sdist-repair"
rm -f -- "$REPAIR_REPLACER_PID_FILE"
rm -f -- "$REPAIR_REPLACER_SEEN"
if REPAIR_UV_MODE=replace-original \
  without_proxy_environment repair_one_pure_sdist \
    repair_pip_command "$fake_bin/uv-sdist-repair" docopt docopt 3.12 "$replace_repair_dir" '' 1 \
    >"$FIXTURE_DIR/sdist-repair-replace-original.log" 2>&1; then
  pass 'backend replacement of the original output path cannot replace the admitted snapshot'
else
  fail 'backend replacement of the original output path cannot replace the admitted snapshot'
  sed 's/^/# replacement repair: /' "$FIXTURE_DIR/sdist-repair-replace-original.log"
fi
for _ in $(seq 1 200); do
  [[ -f "$REPAIR_REPLACER_SEEN" ]] && break
  sleep 0.01
done
assert_file_missing "$REPAIR_REPLACER_SEEN" 'supervisor terminates an ordinary backend child before snapshot validation starts'
if python3 -B "$ROOT_DIR/tools/validate_python_distribution.py" wheel \
  "$replace_repair_dir/built-wheels" --name docopt --version 0.6.2 >/dev/null 2>&1; then
  pass 'wheel admitted after ordinary backend-child cleanup independently revalidates'
else
  fail 'wheel admitted after ordinary backend-child cleanup independently revalidates'
fi
if [[ -f "$REPAIR_REPLACER_PID_FILE" ]]; then
  if kill -0 "$(<"$REPAIR_REPLACER_PID_FILE")" 2>/dev/null; then
    fail 'ordinary backend child is gone before repair returns'
    kill "$(<"$REPAIR_REPLACER_PID_FILE")" 2>/dev/null || true
  else
    pass 'ordinary backend child is gone before repair returns'
  fi
fi

for background_mode in background-replace double-fork-replace; do
  background_repair_parent="$FIXTURE_DIR/$background_mode repair parent"
  mkdir -p "$background_repair_parent"
  background_repair_dir="$background_repair_parent/sdist-repair"
  export REPAIR_BACKGROUND_BUILT_WHEEL="$background_repair_dir/built-wheels/docopt-0.6.2-py2.py3-none-any.whl"
  rm -f -- "$REPAIR_BACKGROUND_STARTED" "$REPAIR_BACKGROUND_REPLACED"
  if REPAIR_UV_MODE="$background_mode" \
    without_proxy_environment repair_one_pure_sdist \
      repair_pip_command "$fake_bin/uv-sdist-repair" docopt docopt 3.12 "$background_repair_dir" '' 1 \
      >"$FIXTURE_DIR/sdist-repair-$background_mode.log" 2>&1; then
    pass "$background_mode backend descendants are cleaned before admission"
  else
    fail "$background_mode backend descendants are cleaned before admission"
    sed 's/^/# supervised repair: /' "$FIXTURE_DIR/sdist-repair-$background_mode.log"
  fi
  assert_file_contains "$REPAIR_BACKGROUND_STARTED" 'started' "$background_mode adversarial child actually started"
  sleep 1
  assert_file_missing "$REPAIR_BACKGROUND_REPLACED" "$background_mode descendant cannot mutate built-wheels after repair returns"
  if python3 -B "$ROOT_DIR/tools/validate_python_distribution.py" wheel \
    "$background_repair_dir/built-wheels" --name docopt --version 0.6.2 >/dev/null 2>&1; then
    pass "$background_mode admitted wheel remains valid after a deliberate post-admission delay"
  else
    fail "$background_mode admitted wheel remains valid after a deliberate post-admission delay"
  fi
done

hold_pipe_parent="$FIXTURE_DIR/hold pipe repair parent"
mkdir -p "$hold_pipe_parent"
hold_pipe_dir="$hold_pipe_parent/sdist-repair"
rm -f -- "$REPAIR_BACKGROUND_STARTED"
hold_pipe_start=$SECONDS
if REPAIR_UV_MODE=hold-pipe \
  without_proxy_environment repair_one_pure_sdist \
    repair_pip_command "$fake_bin/uv-sdist-repair" docopt docopt 3.12 "$hold_pipe_dir" '' 1 \
    >"$FIXTURE_DIR/sdist-repair-hold-pipe.log" 2>&1; then
  pass 'child retaining build stdout cannot block supervised repair'
else
  fail 'child retaining build stdout cannot block supervised repair'
fi
hold_pipe_elapsed=$((SECONDS - hold_pipe_start))
assert_file_contains "$REPAIR_BACKGROUND_STARTED" 'started' 'stdout-retaining backend child actually started'
if ((hold_pipe_elapsed <= 3)); then
  pass 'supervisor cleanup deadline covers inherited build-output pipes'
else
  fail "supervisor cleanup deadline covers inherited build-output pipes (elapsed=${hold_pipe_elapsed}s)"
fi

cancel_repair_parent="$FIXTURE_DIR/cancel repair parent"
mkdir -p "$cancel_repair_parent"
cancel_repair_dir="$cancel_repair_parent/sdist-repair"
cancel_repair_log="$FIXTURE_DIR/sdist-repair-real-term.log"
rm -f -- "$REPAIR_CANCEL_UV_PID_FILE" "$REPAIR_CANCEL_CHILD_PID_FILE" \
  "$REPAIR_CANCEL_DOUBLEFORK_PID_FILE"
cancel_start_ns="$(date +%s%N)"
PIP_MIRROR_URL='https://target-index.example/simple' \
REPAIR_UV_MODE=cancel-block DIFY_SDIST_BUILD_TIMEOUT_SECONDS=4 \
bash -c '
  source "$1"
  repair_pip_command=("$2")
  repair_one_pure_sdist \
    repair_pip_command "$3" docopt docopt 3.12 "$4" "" 1
' _ "$ROOT_DIR/plugin_repackaging.sh" "$fake_bin/pip-sdist-repair" \
  "$fake_bin/uv-sdist-repair" "$cancel_repair_dir" >"$cancel_repair_log" 2>&1 &
cancel_launcher_pid=$!
for _ in $(seq 1 3000); do
  if [[ -s "$REPAIR_CANCEL_UV_PID_FILE" && -s "$REPAIR_CANCEL_CHILD_PID_FILE" && \
    -s "$REPAIR_CANCEL_DOUBLEFORK_PID_FILE" ]]; then
    break
  fi
  sleep 0.001
done
if [[ -s "$REPAIR_CANCEL_UV_PID_FILE" ]]; then
  cancel_uv_pid="$(<"$REPAIR_CANCEL_UV_PID_FILE")"
  cancel_supervisor_pid="$(awk '/^PPid:/{print $2}' "/proc/$cancel_uv_pid/status" 2>/dev/null)"
  cancel_repair_bash_pid="$(awk '/^PPid:/{print $2}' "/proc/$cancel_supervisor_pid/status" 2>/dev/null)"
else
  cancel_uv_pid=
  cancel_supervisor_pid=
  cancel_repair_bash_pid=
fi
if [[ "$cancel_repair_bash_pid" =~ ^[1-9][0-9]*$ ]] && kill -TERM "$cancel_repair_bash_pid" 2>/dev/null; then
  pass 'real cancellation sends TERM only to the active repair Bash process'
else
  fail 'real cancellation sends TERM only to the active repair Bash process'
  kill -TERM "$cancel_launcher_pid" 2>/dev/null || true
fi
if wait "$cancel_launcher_pid"; then
  cancel_repair_status=0
else
  cancel_repair_status=$?
fi
cancel_elapsed_ms=$(( ( $(date +%s%N) - cancel_start_ns ) / 1000000 ))
assert_eq 143 "$cancel_repair_status" 'TERM cancellation preserves the repair Bash signal-derived status'
if ((cancel_elapsed_ms <= 2500)); then
  pass "TERM cancellation completes descendant cleanup within the bounded deadline (${cancel_elapsed_ms}ms)"
else
  fail "TERM cancellation completes descendant cleanup within the bounded deadline (elapsed=${cancel_elapsed_ms}ms)"
fi
for cancelled_pid_file in "$REPAIR_CANCEL_UV_PID_FILE" "$REPAIR_CANCEL_CHILD_PID_FILE" \
  "$REPAIR_CANCEL_DOUBLEFORK_PID_FILE"; do
  cancelled_pid="$(<"$cancelled_pid_file")"
  if kill -0 "$cancelled_pid" 2>/dev/null; then
    fail "TERM cancellation reaps descendant PID from $(basename -- "$cancelled_pid_file")"
    kill -KILL "$cancelled_pid" 2>/dev/null || true
  else
    pass "TERM cancellation reaps descendant PID from $(basename -- "$cancelled_pid_file")"
  fi
done
assert_file_missing "$cancel_repair_dir/.repair-lock" 'TERM cancellation releases the exact repair-tree lock'
if [[ -d "$cancel_repair_dir/built-wheels" ]]; then
  assert_eq 0 "$(find "$cancel_repair_dir/built-wheels" -maxdepth 1 -type f -name '*.whl' | wc -l)" 'TERM cancellation admits no wheel'
else
  pass 'TERM cancellation admits no wheel'
fi
assert_eq 0 "$(find "$cancel_repair_dir" -type f \( -name '*build*log*' -o -name '*.netrc' \) | wc -l)" \
  'TERM cancellation removes raw build logs and retains no credential artifact'

late_cancel_parent="$FIXTURE_DIR/late cancel repair parent"
mkdir -p "$late_cancel_parent"
late_cancel_repair_dir="$late_cancel_parent/sdist-repair"
late_cancel_log="$FIXTURE_DIR/sdist-repair-late-cancel.log"
late_cancel_trigger_file="$FIXTURE_DIR/sdist-repair-late-cancel.triggered"
rm -f -- "$late_cancel_trigger_file"
if (
  set -T
  trap '
    if [[ "$BASH_COMMAND" == "REPAIR_SUPERVISOR_PID=" && \
      "${REPAIR_SUPERVISOR_PID:-}" =~ ^[1-9][0-9]*$ ]]; then
      trap - DEBUG
      printf "triggered\n" >"$late_cancel_trigger_file"
      kill -TERM "$BASHPID"
    fi
  ' DEBUG
  without_proxy_environment repair_one_pure_sdist \
    repair_pip_command "$fake_bin/uv-sdist-repair" docopt docopt 3.12 "$late_cancel_repair_dir" '' 1
) >"$late_cancel_log" 2>&1; then
  late_cancel_status=0
else
  late_cancel_status=$?
fi
assert_file_contains "$late_cancel_trigger_file" 'triggered' 'DEBUG trap deterministically reaches the post-wait PID-clear boundary'
assert_eq 143 "$late_cancel_status" 'late TERM after supervisor wait is preserved as cancellation'
if [[ -d "$late_cancel_repair_dir/built-wheels" ]]; then
  assert_eq 0 "$(find "$late_cancel_repair_dir/built-wheels" -maxdepth 1 -type f -name '*.whl' | wc -l)" \
    'late TERM cannot admit a wheel after the supervisor wait'
else
  pass 'late TERM cannot admit a wheel after the supervisor wait'
fi
assert_eq 0 "$(find "$late_cancel_repair_dir" -type d -name '.admission.*' | wc -l)" \
  'late TERM creates no admission snapshot'
assert_eq 1 "$(find "$late_cancel_repair_dir/candidate-1/wheel" -maxdepth 1 -type f -name '*.whl' | wc -l)" \
  'late TERM leaves the build output unmoved before the non-admission barrier'
assert_file_missing "$late_cancel_repair_dir/.repair-lock" 'late TERM releases the exact repair-tree lock'
assert_eq 0 "$(find "$late_cancel_repair_dir" -type f -name '*log*' | wc -l)" \
  'late TERM removes its exact raw stage log'

for late_cancel_iteration in $(seq 1 8); do
  late_cancel_stress_log="$FIXTURE_DIR/late-cancel-stress-$late_cancel_iteration.log"
  if (
    REPAIR_SUPERVISOR_PID=
    REPAIR_SUPERVISOR_STARTING=false
    REPAIR_CANCELLATION_ACTIVE=false
    REPAIR_CANCELLATION_EXIT_STATUS=
    REPAIR_CANCELLATION_SIGNAL_NAME=
    trap 'cancel_sdist_repair TERM 143' TERM
    set -T
    trap '
      if [[ "$BASH_COMMAND" == "REPAIR_SUPERVISOR_PID=" && \
        "${REPAIR_SUPERVISOR_PID:-}" =~ ^[1-9][0-9]*$ ]]; then
        trap - DEBUG
        kill -TERM "$BASHPID"
      fi
    ' DEBUG
    run_supervised_command_log "$late_cancel_stress_log" 5 bash -c 'exit 0'
  ) >/dev/null 2>&1; then
    late_cancel_stress_status=0
  else
    late_cancel_stress_status=$?
  fi
  assert_eq 143 "$late_cancel_stress_status" \
    "post-wait late cancellation stress iteration $late_cancel_iteration"
  rm -f -- "$late_cancel_stress_log"
done

mutation_repair_parent="$FIXTURE_DIR/mutation repair parent"
mkdir -p "$mutation_repair_parent"
mutation_repair_dir="$mutation_repair_parent/sdist-repair"
export REPAIR_MUTATION_SEEN="$FIXTURE_DIR/sdist-repair-mutation.seen"
rm -f -- "$REPAIR_MUTATION_SEEN" "$REPAIR_MUTATION_PID_FILE"
(
  for _ in $(seq 1 10000); do
    target="$(find "$mutation_repair_dir" -maxdepth 3 -type f -path '*/.admission.*/*.whl' -print -quit 2>/dev/null)"
    if [[ -n "$target" ]]; then
      chmod u+w "$target" 2>/dev/null || true
      printf 'snapshot mutation\n' >>"$target" 2>/dev/null || true
      printf 'seen\n' >"$REPAIR_MUTATION_SEEN"
      exit
    fi
    sleep 0.001
  done
) </dev/null >/dev/null 2>&1 &
printf '%s\n' "$!" >"$REPAIR_MUTATION_PID_FILE"
if REPAIR_UV_MODE=mutate-snapshot \
  without_proxy_environment repair_one_pure_sdist \
    repair_pip_command "$fake_bin/uv-sdist-repair" docopt docopt 3.12 "$mutation_repair_dir" '' 1 \
    >"$FIXTURE_DIR/sdist-repair-mutate-snapshot.log" 2>&1; then
  fail 'mutation of the private admission snapshot is detected'
else
  pass 'mutation of the private admission snapshot is detected'
fi
if [[ -f "$REPAIR_MUTATION_PID_FILE" && ! -f "$REPAIR_MUTATION_SEEN" ]]; then
  kill "$(<"$REPAIR_MUTATION_PID_FILE")" 2>/dev/null || true
fi
assert_file_contains "$REPAIR_MUTATION_SEEN" 'seen' 'adversarial backend reached the snapshot mutation attempt'
if [[ -d "$mutation_repair_dir/built-wheels" ]]; then
  assert_eq 0 "$(find "$mutation_repair_dir/built-wheels" -maxdepth 1 -type f -name '*.whl' | wc -l)" 'mutated snapshot is never admitted'
else
  pass 'mutated snapshot is never admitted'
fi

concurrent_repair_parent="$FIXTURE_DIR/concurrent repair parent"
mkdir -p "$concurrent_repair_parent"
concurrent_repair_dir="$concurrent_repair_parent/sdist-repair"
concurrent_pip_before="$(grep -c '^CALL$' "$REPAIR_PIP_ARGS_LOG")"
concurrent_uv_before="$(grep -c '^CALL$' "$REPAIR_UV_ARGS_LOG")"
(
  REPAIR_PIP_MODE=slow REPAIR_UV_MODE=slow \
    without_proxy_environment repair_one_pure_sdist \
      repair_pip_command "$fake_bin/uv-sdist-repair" docopt docopt 3.12 "$concurrent_repair_dir" '' 1 \
      >"$FIXTURE_DIR/sdist-repair-concurrent-1.log" 2>&1
  printf '%s\n' "$?" >"$FIXTURE_DIR/sdist-repair-concurrent-1.status"
) &
concurrent_pid_one=$!
(
  REPAIR_PIP_MODE=slow REPAIR_UV_MODE=slow \
    without_proxy_environment repair_one_pure_sdist \
      repair_pip_command "$fake_bin/uv-sdist-repair" docopt docopt 3.12 "$concurrent_repair_dir" '' 1 \
      >"$FIXTURE_DIR/sdist-repair-concurrent-2.log" 2>&1
  printf '%s\n' "$?" >"$FIXTURE_DIR/sdist-repair-concurrent-2.status"
) &
concurrent_pid_two=$!
wait "$concurrent_pid_one" "$concurrent_pid_two"
concurrent_successes=0
[[ "$(<"$FIXTURE_DIR/sdist-repair-concurrent-1.status")" == 0 ]] && concurrent_successes=$((concurrent_successes + 1))
[[ "$(<"$FIXTURE_DIR/sdist-repair-concurrent-2.status")" == 0 ]] && concurrent_successes=$((concurrent_successes + 1))
assert_eq 1 "$concurrent_successes" 'same candidate ordinal permits exactly one concurrent repair'
assert_eq 1 "$(( $(grep -c '^CALL$' "$REPAIR_PIP_ARGS_LOG") - concurrent_pip_before ))" 'repair-tree lock permits only one concurrent pip download'
assert_eq 1 "$(( $(grep -c '^CALL$' "$REPAIR_UV_ARGS_LOG") - concurrent_uv_before ))" 'repair-tree lock permits only one concurrent uv build'
assert_file_missing "$concurrent_repair_dir/.repair-lock" 'successful repair removes the exact repair-tree lock'
assert_eq 1 "$(find "$concurrent_repair_dir" -maxdepth 1 -type d -name 'candidate-*' | wc -l)" 'concurrent repair creates only one candidate tree'
assert_eq 0 "$(find "$concurrent_repair_dir" -type l | wc -l)" 'concurrent repair inserts no shared-tree symlink'

stale_lock_parent="$FIXTURE_DIR/stale lock parent"
stale_lock_dir="$stale_lock_parent/sdist-repair"
mkdir -p "$stale_lock_dir/.repair-lock"
chmod 700 -- "$stale_lock_dir" "$stale_lock_dir/.repair-lock"
pip_calls_before="$(grep -c '^CALL$' "$REPAIR_PIP_ARGS_LOG")"
if without_proxy_environment repair_one_pure_sdist \
  repair_pip_command "$fake_bin/uv-sdist-repair" docopt docopt 3.12 "$stale_lock_dir" '' 1 \
  >"$FIXTURE_DIR/sdist-repair-stale-lock.log" 2>&1; then
  fail 'held or stale repair-tree lock fails closed'
else
  pass 'held or stale repair-tree lock fails closed'
fi
assert_eq "$pip_calls_before" "$(grep -c '^CALL$' "$REPAIR_PIP_ARGS_LOG")" 'held repair-tree lock prevents pip execution'
assert_file_missing "$stale_lock_dir/candidate-1" 'held repair-tree lock prevents candidate creation'

bounded_permission_log="$FIXTURE_DIR/bounded-command-permission.log"
if run_bounded_command_log "$bounded_permission_log" printf 'bounded log\n'; then
  pass 'bounded command logger captures a successful command'
else
  fail 'bounded command logger captures a successful command'
fi
assert_eq 600 "$(stat -c '%a' "$bounded_permission_log")" 'bounded raw command log uses mode 0600'
rm -f -- "$bounded_permission_log"

supervisor_status_log="$FIXTURE_DIR/supervisor-status.log"
if run_supervised_command_log "$supervisor_status_log" 5 bash -c 'exit 37'; then
  supervisor_exit_status=0
else
  supervisor_exit_status=$?
fi
assert_eq 37 "$supervisor_exit_status" 'build supervisor preserves the uv process exit status'
assert_eq 600 "$(stat -c '%a' "$supervisor_status_log")" 'supervised raw build log uses mode 0600'
rm -f -- "$supervisor_status_log"

chmod_external_sentinel="$FIXTURE_DIR/chmod-external-sentinel"
chmod_symlink="$FIXTURE_DIR/chmod-symlink"
printf 'external sentinel\n' >"$chmod_external_sentinel"
chmod 640 -- "$chmod_external_sentinel"
ln -s "$chmod_external_sentinel" "$chmod_symlink"
if safe_fchmod_regular_file "$chmod_symlink" 400 >/dev/null 2>&1; then
  fail 'descriptor-bound mode hardening rejects a symlink swap target'
else
  pass 'descriptor-bound mode hardening rejects a symlink swap target'
fi
assert_eq 'external sentinel' "$(<"$chmod_external_sentinel")" 'symlink mode-hardening attempt leaves external content untouched'
assert_eq 640 "$(stat -c '%a' "$chmod_external_sentinel")" 'symlink mode-hardening attempt leaves external mode untouched'

invalid_timeout_parent="$FIXTURE_DIR/invalid timeout parent"
mkdir -p "$invalid_timeout_parent"
invalid_timeout_dir="$invalid_timeout_parent/sdist-repair"
pip_calls_before="$(grep -c '^CALL$' "$REPAIR_PIP_ARGS_LOG")"
if DIFY_SDIST_BUILD_TIMEOUT_SECONDS='1; touch unsafe' \
  without_proxy_environment repair_one_pure_sdist \
    repair_pip_command "$fake_bin/uv-sdist-repair" docopt docopt 3.12 "$invalid_timeout_dir" '' 1 \
    >"$FIXTURE_DIR/sdist-repair-invalid-timeout.log" 2>&1; then
  fail 'invalid sdist build timeout is rejected before side effects'
else
  pass 'invalid sdist build timeout is rejected before side effects'
fi
assert_eq "$pip_calls_before" "$(grep -c '^CALL$' "$REPAIR_PIP_ARGS_LOG")" 'invalid build timeout cannot invoke pip'
assert_file_missing "$invalid_timeout_dir" 'invalid build timeout creates no repair staging'

flood_repair_parent="$FIXTURE_DIR/flood repair parent"
mkdir -p "$flood_repair_parent"
flood_repair_dir="$flood_repair_parent/sdist-repair"
flood_repair_log="$FIXTURE_DIR/sdist-repair-flood.log"
if REPAIR_UV_MODE=flood-failure \
  without_proxy_environment repair_one_pure_sdist \
    repair_pip_command "$fake_bin/uv-sdist-repair" docopt docopt 3.12 "$flood_repair_dir" '' 1 \
    >"$flood_repair_log" 2>&1; then
  fail 'bounded build-output flood remains a build failure'
else
  pass 'bounded build-output flood remains a build failure'
fi
if (( $(stat -c '%s' "$flood_repair_log") <= 1100000 )); then
  pass 'displayed build-output flood remains bounded'
else
  fail 'displayed build-output flood remains bounded'
fi
assert_file_contains "$flood_repair_log" 'diagnostic output truncated' 'bounded build-output flood reports truncation'
assert_eq 0 "$(find "$flood_repair_dir" -type f -name '*build*log*' | wc -l)" 'raw flooded build log is removed after reporting'

timeout_repair_parent="$FIXTURE_DIR/timeout repair parent"
mkdir -p "$timeout_repair_parent"
timeout_repair_dir="$timeout_repair_parent/sdist-repair"
timeout_start=$SECONDS
if DIFY_SDIST_BUILD_TIMEOUT_SECONDS=1 REPAIR_UV_MODE=timeout \
  without_proxy_environment repair_one_pure_sdist \
    repair_pip_command "$fake_bin/uv-sdist-repair" docopt docopt 3.12 "$timeout_repair_dir" '' 1 \
    >"$FIXTURE_DIR/sdist-repair-timeout.log" 2>&1; then
  fail 'sdist wheel build timeout stops repair'
else
  pass 'sdist wheel build timeout stops repair'
fi
timeout_elapsed=$((SECONDS - timeout_start))
if ((timeout_elapsed <= 4)); then
  pass 'sdist wheel build timeout is enforced within its kill-after bound'
else
  fail 'sdist wheel build timeout is enforced within its kill-after bound'
fi
assert_file_contains "$FIXTURE_DIR/sdist-repair-timeout.log" 'Pure Python sdist repair failed during build: docopt' 'timeout reports the stable build stage'
if [[ -d "$timeout_repair_dir/built-wheels" ]]; then
  assert_eq 0 "$(find "$timeout_repair_dir/built-wheels" -maxdepth 1 -type f -name '*.whl' | wc -l)" 'timed-out build admits no wheel'
else
  pass 'timed-out build admits no wheel'
fi

task3_function_source="$(sed -n '/^validate_sdist_repair_dir() {/,/^download_wheels_once() {/p' "$ROOT_DIR/plugin_repackaging.sh")"
supervisor_function_source="$(sed -n '/^run_supervised_command_log() {/,/^build_sanitized_environment_args() {/p' "$ROOT_DIR/plugin_repackaging.sh")"
if grep -Eq 'write_private_index_auth|remove_private_index_auth|auth-home/\.netrc' <<<"$task3_function_source"; then
  fail 'Task3 source-build repair retains no netrc credential production path'
else
  pass 'Task3 source-build repair retains no netrc credential production path'
fi
for supervisor_identity_guard in 'os.pidfd_open' 'signal.pidfd_send_signal' '/stat"' 'starttime'; do
  if grep -Fq "$supervisor_identity_guard" <<<"$supervisor_function_source"; then
    pass "supervisor binds descendant signals with $supervisor_identity_guard"
  else
    fail "supervisor binds descendant signals with $supervisor_identity_guard"
  fi
done
if grep -Eq '^[[:space:]]*chmod([[:space:]]|$)' <<<"$task3_function_source"; then
  fail 'Task3 performs no path-based chmod after a pathname safety check'
else
  pass 'Task3 performs no path-based chmod after a pathname safety check'
fi
if grep -Fq '${#' <<<"$task3_function_source"; then
  fail 'Task3 empty-array checks remain safe under Bash 4.3 nounset'
else
  pass 'Task3 empty-array checks remain safe under Bash 4.3 nounset'
fi
if bash43_command="$(command -v bash4.3 2>/dev/null)" && [[ -n "$bash43_command" ]]; then
  if ROOT_DIR="$ROOT_DIR" "$bash43_command" -uc \
    'source "$ROOT_DIR/plugin_repackaging.sh"; empty_pip=(); validate_sdist_repair_identifiers empty_pip /bin/true docopt docopt 3.12 1' \
    >"$FIXTURE_DIR/sdist-repair-bash43.log" 2>&1; then
    fail 'Bash 4.3 safely rejects an empty pip array under nounset'
  else
    pass 'Bash 4.3 safely rejects an empty pip array under nounset'
  fi
  assert_file_not_contains "$FIXTURE_DIR/sdist-repair-bash43.log" 'unbound variable' 'Bash 4.3 empty pip array emits no nounset diagnostic'
else
  pass 'Bash 4.3 runtime unavailable; static Task3 array regression remains active'
fi

conflict_repair_parent="$FIXTURE_DIR/conflict repair parent"
conflict_repair_dir="$conflict_repair_parent/sdist-repair"
mkdir -p "$conflict_repair_dir/built-wheels"
chmod 700 -- "$conflict_repair_dir" "$conflict_repair_dir/built-wheels"
printf 'preexisting different wheel\n' >"$conflict_repair_dir/built-wheels/docopt-0.6.2-py2.py3-none-any.whl"
conflict_repair_log="$FIXTURE_DIR/sdist-repair-conflict.log"
if without_proxy_environment repair_one_pure_sdist \
  repair_pip_command "$fake_bin/uv-sdist-repair" docopt docopt 3.12 "$conflict_repair_dir" '' 1 \
  >"$conflict_repair_log" 2>&1; then
  fail 'a different existing admitted-wheel filename is never overwritten'
else
  pass 'a different existing admitted-wheel filename is never overwritten'
fi
assert_eq 'preexisting different wheel' \
  "$(<"$conflict_repair_dir/built-wheels/docopt-0.6.2-py2.py3-none-any.whl")" \
  'failed wheel admission preserves the preexisting file byte-for-byte'
assert_file_contains "$conflict_repair_log" 'Pure Python sdist repair failed during validation: docopt' 'wheel admission conflict reports a stable validation-stage failure'

socks_repair_parent="$FIXTURE_DIR/socks repair parent"
mkdir -p "$socks_repair_parent"
socks_repair_dir="$socks_repair_parent/sdist-repair"
mkdir -p "$FIXTURE_DIR/fake-socks-site"
export REPAIR_PIP_ATTEMPT_FILE="$FIXTURE_DIR/sdist-repair-socks-attempt"
: >"$REPAIR_PIP_ARGS_LOG"
rm -f -- "$REPAIR_PIP_ATTEMPT_FILE"
socks_repair_log="$FIXTURE_DIR/sdist-repair-socks.log"
if https_proxy='socks5h://10.10.10.10:28802' HTTPS_PROXY= HTTP_PROXY= http_proxy= ALL_PROXY= all_proxy= \
  REPAIR_PIP_MODE=truststore repair_one_pure_sdist \
    repair_pip_command "$fake_bin/uv-sdist-repair" docopt docopt 3.12 "$socks_repair_dir" "$FIXTURE_DIR/fake-socks-site" 1 \
    >"$socks_repair_log" 2>&1; then
  pass 'sdist download preserves the exact SOCKS truststore compatibility retry'
else
  fail 'sdist download preserves the exact SOCKS truststore compatibility retry'
  sed 's/^/# socks sdist repair: /' "$socks_repair_log"
fi
assert_eq 2 "$(grep -c '^CALL$' "$REPAIR_PIP_ARGS_LOG")" 'sdist SOCKS truststore workaround retries exactly once'
assert_file_contains "$socks_repair_log" 'retrying once with PIP_USE_DEPRECATED=legacy-certs' 'sdist SOCKS retry is explained'
assert_eq 0 "$(find "$socks_repair_dir" -type f -name '*download*log*' | wc -l)" 'successful SOCKS retry removes all raw attempt diagnostics'
set -e

cat >"$fake_bin/pip-repair-coordinator" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
is_strict=false
dest=
find_links=
previous=
for argument in "$@"; do
  if [[ "$argument" == --only-binary=:all: ]]; then
    is_strict=true
  fi
  if [[ "$previous" == --dest ]]; then
    dest=$argument
  elif [[ "$previous" == --find-links ]]; then
    find_links=$argument
  fi
  previous=$argument
done
if [[ "$is_strict" != true ]]; then
  exec "$COORDINATOR_SOURCE_PIP" "$@"
fi
attempt=0
[[ -f "$COORDINATOR_STRICT_STATE" ]] && attempt="$(<"$COORDINATOR_STRICT_STATE")"
attempt=$((attempt + 1))
printf '%s\n' "$attempt" >"$COORDINATOR_STRICT_STATE"
{
  printf 'CALL:%s\n' "$attempt"
  printf 'ARG:%s\n' "$@"
} >>"$COORDINATOR_STRICT_ARGS_LOG"
[[ -n "$dest" ]]
mkdir -p -- "$dest"
if ((attempt == 1)); then
  touch -- "$dest/partial-from-failed-attempt.whl"
  printf '%s\n' \
    'Looking in indexes: https://strict-user:strict-password@mirror.example/simple?token=strict-query#strict-fragment' \
    'ERROR: Could not find a version that satisfies the requirement docopt (from records) (from versions: none)' \
    'ERROR: No matching distribution found for docopt'
  exit 1
fi
[[ -n "$find_links" && -d "$find_links" ]]
cp -- "$find_links"/*.whl "$dest/"
touch -- "$dest/runtime-1.0-py3-none-any.whl"
EOF
chmod +x "$fake_bin/pip-repair-coordinator"

coordinator_parent="$FIXTURE_DIR/coordinator --option parent"
coordinator_wheels="$coordinator_parent/wheels"
coordinator_repair_dir="$coordinator_parent/sdist-repair"
coordinator_requirements="$coordinator_parent/requirements.txt"
coordinator_output="$coordinator_parent/output.log"
mkdir -p -- "$coordinator_wheels"
printf 'records~=0.6.0\n' >"$coordinator_requirements"
touch -- "$coordinator_wheels/stale-before-coordinator.whl"
export COORDINATOR_SOURCE_PIP="$fake_bin/pip-sdist-repair"
export COORDINATOR_STRICT_STATE="$coordinator_parent/strict.state"
export COORDINATOR_STRICT_ARGS_LOG="$coordinator_parent/strict.args"
: >"$REPAIR_PIP_ARGS_LOG"
: >"$REPAIR_UV_ARGS_LOG"
: >"$COORDINATOR_STRICT_ARGS_LOG"
rm -f -- "$COORDINATOR_STRICT_STATE"
if PIP_MIRROR_URL='https://target-index.example/simple' \
  DIFY_PIP_COMMAND="$fake_bin/pip-repair-coordinator" \
  DIFY_UV_COMMAND="$fake_bin/uv-sdist-repair" \
  without_proxy_environment download_wheels \
    "$coordinator_requirements" "$coordinator_wheels" aarch64 3.12 '' "$coordinator_repair_dir" \
    >"$coordinator_output" 2>&1; then
  pass 'coordinator repairs one missing pure Python wheel and fully re-resolves'
else
  fail 'coordinator repairs one missing pure Python wheel and fully re-resolves'
  sed 's/^/# coordinator: /' "$coordinator_output"
fi
assert_eq 2 "$(grep -c '^CALL:' "$COORDINATOR_STRICT_ARGS_LOG")" 'one repaired candidate causes exactly two strict resolver attempts'
assert_eq 1 "$(grep -c '^CALL$' "$REPAIR_PIP_ARGS_LOG")" 'one repaired candidate downloads exactly one source distribution'
assert_eq 1 "$(grep -c '^CALL$' "$REPAIR_UV_ARGS_LOG")" 'one repaired candidate invokes uv exactly once'
assert_eq 2 "$(grep -c '^ARG:--only-binary=:all:$' "$COORDINATOR_STRICT_ARGS_LOG")" 'every strict retry remains binary-only'
assert_eq 2 "$(grep -c '^ARG:--python-version$' "$COORDINATOR_STRICT_ARGS_LOG")" 'every strict retry keeps target Python'
assert_eq 2 "$(grep -c '^ARG:cp312$' "$COORDINATOR_STRICT_ARGS_LOG")" 'every strict retry keeps target ABI'
assert_eq 4 "$(grep -c '^ARG:--platform$' "$COORDINATOR_STRICT_ARGS_LOG")" 'every strict retry keeps every target platform'
assert_eq 1 "$(grep -c '^ARG:--find-links$' "$COORDINATOR_STRICT_ARGS_LOG")" 'only the retry adds one admitted-wheel directory'
assert_eq 1 "$(grep -Fxc -- "ARG:$coordinator_repair_dir/built-wheels" "$COORDINATOR_STRICT_ARGS_LOG")" 'retry uses the validated built-wheels directory as one argument'
if [[ -f "$coordinator_wheels/docopt-0.6.2-py2.py3-none-any.whl" && \
  -f "$coordinator_wheels/runtime-1.0-py3-none-any.whl" ]]; then
  pass 'successful retry wheelhouse contains repaired and runtime wheels'
else
  fail 'successful retry wheelhouse contains repaired and runtime wheels'
fi
assert_file_missing "$coordinator_wheels/partial-from-failed-attempt.whl" 'failed-attempt partial wheel is removed before full retry'
assert_file_missing "$coordinator_wheels/stale-before-coordinator.whl" 'preexisting stale wheel is removed before initial resolution'
assert_file_contains "$coordinator_output" 'Pure Python sdist repair candidate: docopt' 'coordinator reports the safe classified candidate'
assert_file_contains "$coordinator_output" 'Source build target: Python 3.12, ABI cp312, architecture aarch64' 'coordinator reports the exact source build target'
assert_file_contains "$coordinator_output" 'Pure Python wheel admitted: docopt-0.6.2-py2.py3-none-any.whl' 'coordinator reports validated admission'

cat >"$fake_bin/pip-repair-coordinator-dynamic" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
is_strict=false
dest=
find_links=
previous=
for argument in "$@"; do
  [[ "$argument" == --only-binary=:all: ]] && is_strict=true
  if [[ "$previous" == --dest ]]; then
    dest=$argument
  elif [[ "$previous" == --find-links ]]; then
    find_links=$argument
  fi
  previous=$argument
done
[[ -n "$dest" ]]
if [[ "$is_strict" == true ]]; then
  attempt=0
  [[ -f "$COORDINATOR_STRICT_STATE" ]] && attempt="$(<"$COORDINATOR_STRICT_STATE")"
  attempt=$((attempt + 1))
  printf '%s\n' "$attempt" >"$COORDINATOR_STRICT_STATE"
  {
    printf 'CALL:%s\n' "$attempt"
    printf 'ARG:%s\n' "$@"
    if [[ -n "$find_links" && -d "$find_links" ]]; then
      while IFS= read -r wheel; do
        printf 'BUILT:%s\n' "$(basename -- "$wheel")"
      done < <(find "$find_links" -maxdepth 1 -type f -name '*.whl' -print | sort)
    fi
    coordinator_workspace="$(find /tmp -maxdepth 1 -type d -user "$(id -u)" \
      -name 'dify-plugin-coordinator.*' -printf '%T@ %p\n' | sort -nr | sed -n '1s/^[^ ]* //p')"
    if [[ -n "$coordinator_workspace" ]]; then
      printf 'WORKSPACE:%s\n' "$coordinator_workspace"
      printf 'LOGPARENTMODE:%s\n' "$(stat -c '%a' "$coordinator_workspace")"
      log_file="$(find "$coordinator_workspace" -maxdepth 1 -type f -name '*.log' -print -quit)"
      [[ -n "$log_file" ]] && printf 'LOGMODE:%s\n' "$(stat -c '%a' "$log_file")"
    fi
  } >>"$COORDINATOR_STRICT_ARGS_LOG"
  mkdir -p -- "$dest"
  sequence="$(sed -n "${attempt}p" "$COORDINATOR_SEQUENCE_FILE")"
  if [[ "$sequence" == SUCCESS ]]; then
    if [[ -n "$find_links" ]]; then
      cp -- "$find_links"/*.whl "$dest/"
    fi
    touch -- "$dest/runtime-1.0-py3-none-any.whl"
    if [[ "${COORDINATOR_MUTATE_WORKSPACE_MODE:-}" == 000 && -n "$coordinator_workspace" ]]; then
      mkdir -p -- "$coordinator_workspace/unreadable/nested"
      printf 'cleanup sentinel\n' >"$coordinator_workspace/unreadable/nested/file"
      chmod 000 -- "$coordinator_workspace/unreadable" "$coordinator_workspace"
    fi
    exit 0
  fi
  touch -- "$dest/partial-attempt-$attempt.whl"
  if [[ "$sequence" == RAW\|* ]]; then
    diagnostic=${sequence#RAW|}
    if [[ "$diagnostic" == CONTROL ]]; then
      printf '\vunsafe-control\n'
    elif [[ "$diagnostic" == FLOOD ]]; then
      head -c $((2 * 1024 * 1024)) /dev/zero | tr '\0' X
    else
      printf '%s\n' "$diagnostic"
    fi
    exit 1
  fi
  printf '%s\n' \
    'Looking in indexes: https://strict-user:strict-password@mirror.example/simple?token=strict-query#strict-fragment' \
    "ERROR: Could not find a version that satisfies the requirement $sequence (from dependency) (from versions: none)" \
    "ERROR: No matching distribution found for $sequence"
  if [[ "${COORDINATOR_MUTATE_WORKSPACE_MODE:-}" == 000 && -n "$coordinator_workspace" ]]; then
    mkdir -p -- "$coordinator_workspace/unreadable/nested"
    printf 'cleanup sentinel\n' >"$coordinator_workspace/unreadable/nested/file"
    chmod 000 -- "$coordinator_workspace/unreadable" "$coordinator_workspace"
  fi
  exit 1
fi

requirement=${!#}
{
  printf 'CALL\n'
  printf 'ARG:%s\n' "$@"
  printf 'REQUIREMENT:%s\n' "$requirement"
} >>"$COORDINATOR_SOURCE_ARGS_LOG"
case "${COORDINATOR_SOURCE_MODE:-success}" in
  failure)
    printf 'source failed via https://source-user:source-password@mirror.example/simple?token=source-query#source-fragment\n' >&2
    exit 41
    ;;
esac
python3 - "$dest" "$requirement" <<'PY'
from pathlib import Path
import io
import re
import sys
import tarfile


destination = Path(sys.argv[1])
requirement = sys.argv[2]
raw_name = re.split(r"[<>=!~]", requirement, maxsplit=1)[0]
name = re.sub(r"[-_.]+", "-", raw_name).lower()
version = "1.0"
prefix = f"{name}-{version}"
metadata = f"Metadata-Version: 2.1\nName: {name}\nVersion: {version}\n\n".encode()
destination.mkdir(parents=True, exist_ok=True)
with tarfile.open(destination / f"{prefix}.tar.gz", "w:gz") as archive:
    for member_name, contents in (
        (f"{prefix}/PKG-INFO", metadata),
        (f"{prefix}/setup.py", b"from setuptools import setup\nsetup()\n"),
    ):
        info = tarfile.TarInfo(member_name)
        info.size = len(contents)
        info.mode = 0o644
        archive.addfile(info, io.BytesIO(contents))
PY
EOF

cat >"$fake_bin/uv-repair-coordinator-dynamic" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
{
  printf 'CALL\n'
  printf 'ARG:%s\n' "$@"
} >>"$COORDINATOR_UV_ARGS_LOG"
case "${COORDINATOR_UV_MODE:-success}" in
  failure)
    printf 'build failed via socks5h://build-user:build-password@10.10.10.10:28802/path?token=build-query#build-fragment\n' >&2
    exit 51
    ;;
esac
out_dir=
previous=
for argument in "$@"; do
  if [[ "$previous" == --out-dir ]]; then
    out_dir=$argument
  fi
  previous=$argument
done
sdist=${!#}
[[ -n "$out_dir" && -f "$sdist" ]]
python3 - "$out_dir" "$sdist" "${COORDINATOR_UV_MODE:-success}" <<'PY'
from email.parser import BytesParser
from pathlib import Path
import re
import sys
import tarfile
import zipfile


output_dir = Path(sys.argv[1])
sdist = Path(sys.argv[2])
mode = sys.argv[3]
with tarfile.open(sdist, "r:gz") as archive:
    member = next(item for item in archive if item.name.endswith("/PKG-INFO"))
    stream = archive.extractfile(member)
    assert stream is not None
    metadata_bytes = stream.read()
metadata = BytesParser().parsebytes(metadata_bytes)
name = re.sub(r"[-_.]+", "-", metadata["Name"]).lower()
version = metadata["Version"]
if mode == "mismatch":
    name = "different-package"
distribution = name.replace("-", "_")
dist_info = f"{distribution}-{version}.dist-info"
root_is_pure = "false" if mode == "nonpure" else "true"
wheel_metadata = (
    "Wheel-Version: 1.0\n"
    "Generator: coordinator-test\n"
    f"Root-Is-Purelib: {root_is_pure}\n"
    "Tag: py3-none-any\n\n"
).encode()
output_dir.mkdir(parents=True, exist_ok=True)
wheel_path = output_dir / f"{distribution}-{version}-py3-none-any.whl"
with zipfile.ZipFile(wheel_path, "w", zipfile.ZIP_DEFLATED) as archive:
    archive.writestr(f"{dist_info}/METADATA", (
        f"Metadata-Version: 2.1\nName: {name}\nVersion: {version}\n\n"
    ).encode())
    archive.writestr(f"{dist_info}/WHEEL", wheel_metadata)
    if mode == "native":
        archive.writestr(f"{distribution}/native", b"\x7fELF" + b"\0" * 32)
    else:
        archive.writestr(f"{distribution}.py", b"VALUE = 1\n")
PY
EOF
chmod +x "$fake_bin/pip-repair-coordinator-dynamic" "$fake_bin/uv-repair-coordinator-dynamic"

prepare_dynamic_coordinator_case() {
  local case_name=$1
  shift
  DYNAMIC_CASE_DIR="$FIXTURE_DIR/coordinator-$case_name"
  DYNAMIC_WHEELS="$DYNAMIC_CASE_DIR/wheels"
  DYNAMIC_REPAIR_DIR="$DYNAMIC_CASE_DIR/sdist-repair"
  DYNAMIC_REQUIREMENTS="$DYNAMIC_CASE_DIR/requirements.txt"
  DYNAMIC_OUTPUT="$DYNAMIC_CASE_DIR/output.log"
  COORDINATOR_SEQUENCE_FILE="$DYNAMIC_CASE_DIR/sequence.txt"
  COORDINATOR_STRICT_STATE="$DYNAMIC_CASE_DIR/strict.state"
  COORDINATOR_STRICT_ARGS_LOG="$DYNAMIC_CASE_DIR/strict.args"
  COORDINATOR_SOURCE_ARGS_LOG="$DYNAMIC_CASE_DIR/source.args"
  COORDINATOR_UV_ARGS_LOG="$DYNAMIC_CASE_DIR/uv.args"
  export COORDINATOR_SEQUENCE_FILE COORDINATOR_STRICT_STATE COORDINATOR_STRICT_ARGS_LOG
  export COORDINATOR_SOURCE_ARGS_LOG COORDINATOR_UV_ARGS_LOG
  mkdir -p -- "$DYNAMIC_WHEELS"
  printf 'runtime-dependency\n' >"$DYNAMIC_REQUIREMENTS"
  printf '%s\n' "$@" >"$COORDINATOR_SEQUENCE_FILE"
  : >"$COORDINATOR_STRICT_ARGS_LOG"
  : >"$COORDINATOR_SOURCE_ARGS_LOG"
  : >"$COORDINATOR_UV_ARGS_LOG"
  rm -f -- "$COORDINATOR_STRICT_STATE"
}

run_dynamic_coordinator() {
  PIP_MIRROR_URL="${COORDINATOR_INDEX_URL:-https://target-index.example/simple}" \
    DIFY_PIP_COMMAND="$fake_bin/pip-repair-coordinator-dynamic" \
    DIFY_UV_COMMAND="$fake_bin/uv-repair-coordinator-dynamic" \
    without_proxy_environment download_wheels \
      "$DYNAMIC_REQUIREMENTS" "$DYNAMIC_WHEELS" aarch64 3.12 '' "$DYNAMIC_REPAIR_DIR"
}

run_dynamic_coordinator_default() {
  PIP_MIRROR_URL="${COORDINATOR_INDEX_URL:-https://target-index.example/simple}" \
    DIFY_PIP_COMMAND="$fake_bin/pip-repair-coordinator-dynamic" \
    DIFY_UV_COMMAND="$fake_bin/uv-repair-coordinator-dynamic" \
    without_proxy_environment download_wheels \
      "$DYNAMIC_REQUIREMENTS" "$DYNAMIC_WHEELS" aarch64 3.12 ''
}

assert_recorded_coordinator_workspaces_removed() {
  local record_file=$1
  local name=$2
  local workspace found=false

  while IFS= read -r workspace; do
    [[ -n "$workspace" ]] || continue
    found=true
    if [[ "$workspace" == /tmp/dify-plugin-coordinator.* && ! -e "$workspace" ]]; then
      continue
    fi
    fail "$name"
    return
  done < <(sed -n 's/^WORKSPACE://p' "$record_file" | sort -u)
  if [[ "$found" == true ]]; then
    pass "$name"
  else
    fail "$name (no secure workspace was observed)"
  fi
}

prepare_dynamic_coordinator_case foreign-explicit-repair docopt SUCCESS
mkdir -p -- "$DYNAMIC_REPAIR_DIR"
chmod 700 -- "$DYNAMIC_REPAIR_DIR"
if sudo -n chown 0:0 -- "$DYNAMIC_REPAIR_DIR" 2>/dev/null; then
  if run_dynamic_coordinator >"$DYNAMIC_OUTPUT" 2>&1; then
    fail 'coordinator rejects a foreign-owned explicit repair root'
  else
    pass 'coordinator rejects a foreign-owned explicit repair root'
  fi
  assert_eq 1 "$(grep -c '^CALL:' "$COORDINATOR_STRICT_ARGS_LOG")" 'foreign repair root stops after initial strict classification'
  assert_eq 0 "$(grep -c '^CALL$' "$COORDINATOR_SOURCE_ARGS_LOG")" 'foreign repair root is rejected before source pip'
  assert_eq 0 "$(grep -c '^CALL$' "$COORDINATOR_UV_ARGS_LOG")" 'foreign repair root is rejected before uv'
  assert_file_missing "$DYNAMIC_REPAIR_DIR/candidate-1" 'foreign repair root is rejected before managed-tree writes'
  sudo -n chown "$(id -u):$(id -g)" -- "$DYNAMIC_REPAIR_DIR"
else
  pass 'foreign repair coordinator fixture requires passwordless sudo; direct ownership check covers rejection'
  pass 'foreign repair source-pip side-effect fixture requires passwordless sudo'
  pass 'foreign repair uv side-effect fixture requires passwordless sudo'
  pass 'foreign repair write side-effect fixture requires passwordless sudo'
  pass 'foreign repair strict-attempt fixture requires passwordless sudo'
fi

foreign_built_repair="$FIXTURE_DIR/foreign-built/sdist-repair"
foreign_built_dir="$foreign_built_repair/built-wheels"
mkdir -p -- "$foreign_built_dir"
chmod 700 -- "$foreign_built_repair" "$foreign_built_dir"
if sudo -n chown 0:0 -- "$foreign_built_dir" 2>/dev/null; then
  if validate_repair_built_wheels_dir "$foreign_built_repair" "$foreign_built_dir"; then
    fail 'foreign-owned built-wheels directory is rejected before find-links'
  else
    pass 'foreign-owned built-wheels directory is rejected before find-links'
  fi
  sudo -n chown "$(id -u):$(id -g)" -- "$foreign_built_dir"
else
  pass 'foreign built-wheels ownership fixture requires passwordless sudo; production ownership check is covered statically'
fi

prepare_dynamic_coordinator_case stale-pre-pip-retry docopt SUCCESS
stale_retry_repair_count="$DYNAMIC_CASE_DIR/repair.count"
stale_retry_mutation_marker="$DYNAMIC_CASE_DIR/mutated"
if (
  repair_one_pure_sdist_impl() {
    local repair_dir=$6 count=0
    [[ -f "$stale_retry_repair_count" ]] && count="$(<"$stale_retry_repair_count")"
    count=$((count + 1))
    printf '%s\n' "$count" >"$stale_retry_repair_count"
    mkdir -p -- "$repair_dir/built-wheels"
    chmod 700 -- "$repair_dir" "$repair_dir/built-wheels"
    touch -- "$repair_dir/built-wheels/repaired-$count-py3-none-any.whl"
    printf 'Pure Python wheel admitted: repaired-%s-py3-none-any.whl\n' "$count"
  }
  validate_repair_built_wheels_dir() {
    local repair_dir=$1 built_wheels_dir=$2 workspace current_attempt_log
    if [[ ! -e "$stale_retry_mutation_marker" ]]; then
      workspace="$(dirname -- "$repair_dir")"
      [[ "$repair_dir" == /tmp/dify-plugin-coordinator.*/sdist-repair && \
        "$built_wheels_dir" == "$repair_dir/built-wheels" ]] || return 1
      current_attempt_log="$(find "$workspace" -maxdepth 1 -type f -name 'current.*.log' -print -quit)"
      [[ -n "$current_attempt_log" ]] || return 1
      write_missing_wheel_log "$current_attempt_log" stale_second_candidate
      mv -- "$built_wheels_dir" "$repair_dir/built-wheels.removed"
      : >"$stale_retry_mutation_marker"
    fi
    return 0
  }
  run_dynamic_coordinator_default
) >"$DYNAMIC_OUTPUT" 2>&1; then
  fail 'pre-pip retry failure with a seeded stale log fails closed'
else
  pass 'pre-pip retry failure with a seeded stale log fails closed'
fi
assert_eq 1 "$(<"$stale_retry_repair_count")" 'pre-pip retry failure invokes no extra pure-sdist repair from stale diagnostics'
assert_eq 1 "$(grep -c '^CALL:' "$COORDINATOR_STRICT_ARGS_LOG")" 'pre-pip retry failure runs no extra strict pip attempt'
assert_file_not_contains "$DYNAMIC_OUTPUT" 'Pure Python sdist repair candidate: stale-second-candidate' 'pre-pip retry failure never classifies the seeded stale candidate'
assert_file_contains "$DYNAMIC_OUTPUT" 'Pure Python sdist repair failed during resolution after 1 admitted wheel(s).' 'empty current attempt log receives the post-admission failure report'
assert_recorded_coordinator_workspaces_removed \
  "$COORDINATOR_STRICT_ARGS_LOG" \
  'pre-pip retry failure removes its secure coordinator workspace'

prepare_dynamic_coordinator_case two-candidates alpha beta SUCCESS
if run_dynamic_coordinator >"$DYNAMIC_OUTPUT" 2>&1; then
  pass 'coordinator repairs two distinct pure Python candidates'
else
  fail 'coordinator repairs two distinct pure Python candidates'
  sed 's/^/# two candidates: /' "$DYNAMIC_OUTPUT"
fi
assert_eq 3 "$(grep -c '^CALL:' "$COORDINATOR_STRICT_ARGS_LOG")" 'two repairs cause three complete strict resolver attempts'
assert_eq 2 "$(grep -c '^CALL$' "$COORDINATOR_SOURCE_ARGS_LOG")" 'two repairs download exactly two source distributions'
assert_eq 2 "$(grep -c '^CALL$' "$COORDINATOR_UV_ARGS_LOG")" 'two repairs build exactly two wheels'
assert_eq 2 "$(grep -c '^BUILT:alpha-1.0-py3-none-any.whl$' "$COORDINATOR_STRICT_ARGS_LOG")" 'second retry sees the first admitted wheel and the third retains it'
assert_eq 1 "$(grep -c '^BUILT:beta-1.0-py3-none-any.whl$' "$COORDINATOR_STRICT_ARGS_LOG")" 'third retry sees the second admitted wheel'
assert_eq 2 "$(grep -c '^ARG:--find-links$' "$COORDINATOR_STRICT_ARGS_LOG")" 'each post-admission retry uses one local wheel directory'
assert_eq 3 "$(find "$DYNAMIC_WHEELS" -maxdepth 1 -type f -name '*.whl' | wc -l)" 'final full resolver pass contains two repaired wheels and runtime'
assert_eq 0 "$(find "$DYNAMIC_WHEELS" -maxdepth 1 -type f -name 'partial-*' | wc -l)" 'full retry reset removes every earlier partial wheel'

prepare_dynamic_coordinator_case repeated-canonical My_Pkg 'my-pkg>=2'
if run_dynamic_coordinator >"$DYNAMIC_OUTPUT" 2>&1; then
  fail 'canonical separator/case repeat stops the repair loop'
else
  pass 'canonical separator/case repeat stops the repair loop'
fi
assert_eq 2 "$(grep -c '^CALL:' "$COORDINATOR_STRICT_ARGS_LOG")" 'repeated candidate performs only two strict attempts'
assert_eq 1 "$(grep -c '^CALL$' "$COORDINATOR_SOURCE_ARGS_LOG")" 'repeated canonical candidate is built only once'
assert_eq 1 "$(grep -c '^CALL$' "$COORDINATOR_UV_ARGS_LOG")" 'repeated canonical candidate invokes uv only once'
assert_file_contains "$DYNAMIC_OUTPUT" 'repeated pure Python sdist repair candidate: my-pkg>=2' 'repeat diagnostic reports the safe changed constraint'

limit_candidates=()
for candidate_number in $(seq -w 1 17); do
  limit_candidates+=("pkg$candidate_number")
done
prepare_dynamic_coordinator_case repair-limit "${limit_candidates[@]}"
if run_dynamic_coordinator_default >"$DYNAMIC_OUTPUT" 2>&1; then
  fail 'seventeenth candidate reaches the bounded repair limit'
else
  pass 'seventeenth candidate reaches the bounded repair limit'
fi
assert_eq 17 "$(grep -c '^CALL:' "$COORDINATOR_STRICT_ARGS_LOG")" 'repair limit is checked after the seventeenth strict classification'
assert_eq 16 "$(grep -c '^CALL$' "$COORDINATOR_SOURCE_ARGS_LOG")" 'repair limit permits only sixteen source downloads'
assert_eq 16 "$(grep -c '^CALL$' "$COORDINATOR_UV_ARGS_LOG")" 'repair limit permits only sixteen builds'
assert_file_contains "$DYNAMIC_OUTPUT" 'pure Python sdist repair limit reached: 16' 'repair limit diagnostic is explicit'
assert_file_not_contains "$COORDINATOR_SOURCE_ARGS_LOG" 'REQUIREMENT:pkg17' 'seventeenth candidate is never downloaded as source'
assert_file_missing "$DYNAMIC_REPAIR_DIR" 'default repair staging is removed after the sixteen-candidate limit'
assert_recorded_coordinator_workspaces_removed \
  "$COORDINATOR_STRICT_ARGS_LOG" \
  'sixteen-candidate default repair removes its secure workspace'

for disabled_value in 0 false FALSE no NO; do
  prepare_dynamic_coordinator_case "disabled-$disabled_value" docopt
  if DIFY_AUTO_BUILD_PURE_SDIST="$disabled_value" run_dynamic_coordinator_default >"$DYNAMIC_OUTPUT" 2>&1; then
    fail "automatic pure repair disabled value fails safely: $disabled_value"
  else
    pass "automatic pure repair disabled value fails safely: $disabled_value"
  fi
  assert_eq 1 "$(grep -c '^CALL:' "$COORDINATOR_STRICT_ARGS_LOG")" "disabled value performs one strict attempt: $disabled_value"
  assert_eq 0 "$(grep -c '^CALL$' "$COORDINATOR_SOURCE_ARGS_LOG")" "disabled value downloads no source: $disabled_value"
  assert_eq 0 "$(grep -c '^CALL$' "$COORDINATOR_UV_ARGS_LOG")" "disabled value invokes no uv: $disabled_value"
  assert_file_missing "$DYNAMIC_REPAIR_DIR" "disabled value creates no repair staging: $disabled_value"
  assert_file_contains "$DYNAMIC_OUTPUT" 'Automatic pure Python sdist repair is disabled by DIFY_AUTO_BUILD_PURE_SDIST.' "disabled value reports its switch: $disabled_value"
  assert_recorded_coordinator_workspaces_removed \
    "$COORDINATOR_STRICT_ARGS_LOG" \
    "disabled default repair removes its secure workspace: $disabled_value"
done

prepare_dynamic_coordinator_case normal-success SUCCESS
if run_dynamic_coordinator_default >"$DYNAMIC_OUTPUT" 2>&1; then
  pass 'normal binary-only success preserves the one-pass path'
else
  fail 'normal binary-only success preserves the one-pass path'
fi
assert_eq 1 "$(grep -c '^CALL:' "$COORDINATOR_STRICT_ARGS_LOG")" 'normal success runs one strict resolver pass'
assert_eq 0 "$(grep -c '^CALL$' "$COORDINATOR_SOURCE_ARGS_LOG")" 'normal success downloads no source'
assert_eq 0 "$(grep -c '^CALL$' "$COORDINATOR_UV_ARGS_LOG")" 'normal success invokes no uv'
assert_file_missing "$DYNAMIC_REPAIR_DIR" 'normal success creates no repair directory'
assert_recorded_coordinator_workspaces_removed \
  "$COORDINATOR_STRICT_ARGS_LOG" \
  'normal success removes its secure coordinator workspace'

prepare_dynamic_coordinator_case mode-zero-success SUCCESS
if COORDINATOR_MUTATE_WORKSPACE_MODE=000 \
  run_dynamic_coordinator_default >"$DYNAMIC_OUTPUT" 2>&1; then
  pass 'successful resolution survives cleanup of a top-and-nested mode-000 workspace'
else
  fail 'successful resolution survives cleanup of a top-and-nested mode-000 workspace'
fi
assert_recorded_coordinator_workspaces_removed \
  "$COORDINATOR_STRICT_ARGS_LOG" \
  'success cleanup removes a top-and-nested mode-000 workspace'

prepare_dynamic_coordinator_case mode-zero-failure docopt
if COORDINATOR_MUTATE_WORKSPACE_MODE=000 \
  run_dynamic_coordinator_default >"$DYNAMIC_OUTPUT" 2>&1; then
  fail 'failed resolution with a top-and-nested mode-000 workspace fails closed'
else
  pass 'failed resolution with a top-and-nested mode-000 workspace fails closed'
fi
assert_recorded_coordinator_workspaces_removed \
  "$COORDINATOR_STRICT_ARGS_LOG" \
  'failure cleanup removes a top-and-nested mode-000 workspace'

prepare_dynamic_coordinator_case default-repair-dir docopt SUCCESS
uv_space_dir="$FIXTURE_DIR/coordinator tools with spaces"
uv_space_command="$uv_space_dir/uv dynamic"
untrusted_tmpdir="$DYNAMIC_CASE_DIR/untrusted-tmp"
mkdir -p -- "$uv_space_dir"
mkdir -p -- "$untrusted_tmpdir"
chmod 777 -- "$untrusted_tmpdir"
cp -- "$fake_bin/uv-repair-coordinator-dynamic" "$uv_space_command"
chmod +x "$uv_space_command"
if TMPDIR="$untrusted_tmpdir" \
  PIP_MIRROR_URL='https://target-index.example/simple' \
  DIFY_PIP_COMMAND="$fake_bin/pip-repair-coordinator-dynamic" \
  DIFY_UV_COMMAND="$uv_space_command" \
  without_proxy_environment download_wheels \
    "$DYNAMIC_REQUIREMENTS" "$DYNAMIC_WHEELS" aarch64 3.12 '' \
    >"$DYNAMIC_OUTPUT" 2>&1; then
  pass 'default sibling repair directory and exact uv path with spaces are supported'
else
  fail 'default sibling repair directory and exact uv path with spaces are supported'
fi
assert_eq 2 "$(grep -c '^CALL:' "$COORDINATOR_STRICT_ARGS_LOG")" 'default repair directory performs a complete retry'
assert_eq 1 "$(grep -c '^CALL$' "$COORDINATOR_UV_ARGS_LOG")" 'exact configured uv command is invoked once'
if grep -Eq '^ARG:/tmp/dify-plugin-coordinator\.[^/]+/sdist-repair/candidate-1/source$' "$COORDINATOR_SOURCE_ARGS_LOG"; then
  pass 'omitted sixth argument stages repair below the secure coordinator workspace'
else
  fail 'omitted sixth argument stages repair below the secure coordinator workspace'
fi
assert_file_missing "$DYNAMIC_REPAIR_DIR" 'default repair directory is not created beside the wheelhouse'
default_workspace="$(sed -n 's/^WORKSPACE://p' "$COORDINATOR_STRICT_ARGS_LOG" | head -n1)"
if [[ "$default_workspace" == /tmp/dify-plugin-coordinator.* && ! -e "$default_workspace" ]]; then
  pass 'successful default repair removes its secure coordinator workspace'
else
  fail 'successful default repair removes its secure coordinator workspace'
fi
if [[ "$default_workspace" != "$untrusted_tmpdir"/* ]]; then
  pass 'coordinator workspace ignores untrusted TMPDIR'
else
  fail 'coordinator workspace ignores untrusted TMPDIR'
fi

prepare_dynamic_coordinator_case production-filesystem docopt SUCCESS
drvfs_case_dir="$ROOT_DIR/.coordinator-drvfs-test.$BASHPID"
GENERATED_ROOT_TEST_DIRS+=("$drvfs_case_dir")
mkdir -p -- "$drvfs_case_dir/wheels"
printf 'runtime-dependency\n' >"$drvfs_case_dir/requirements.txt"
touch -- "$drvfs_case_dir/mode-probe"
chmod 600 -- "$drvfs_case_dir/mode-probe"
drvfs_probe_mode="$(stat -c '%a' "$drvfs_case_dir/mode-probe")"
if [[ "$drvfs_probe_mode" != 600 ]]; then
  pass "production filesystem reproduces non-POSIX chmod semantics: mode $drvfs_probe_mode"
else
  chmod 777 -- "$drvfs_case_dir" "$drvfs_case_dir/wheels" "$drvfs_case_dir/requirements.txt" "$drvfs_case_dir/mode-probe"
  pass 'production-filesystem fallback seam forces permissive wheelhouse permissions'
fi
DYNAMIC_WHEELS="$drvfs_case_dir/wheels"
DYNAMIC_REQUIREMENTS="$drvfs_case_dir/requirements.txt"
DYNAMIC_REPAIR_DIR="$drvfs_case_dir/sdist-repair"
if run_dynamic_coordinator_default >"$DYNAMIC_OUTPUT" 2>&1; then
  pass 'default coordinator repair succeeds with requirements and wheels on the production filesystem'
else
  fail 'default coordinator repair succeeds with requirements and wheels on the production filesystem'
  sed 's/^/# production filesystem: /' "$DYNAMIC_OUTPUT"
fi
if [[ -f "$DYNAMIC_WHEELS/docopt-1.0-py3-none-any.whl" && \
  -f "$DYNAMIC_WHEELS/runtime-1.0-py3-none-any.whl" ]]; then
  pass 'final repaired wheelhouse lands on the production filesystem'
else
  fail 'final repaired wheelhouse lands on the production filesystem'
fi
assert_file_missing "$DYNAMIC_REPAIR_DIR" 'default repair staging never uses the permissive production filesystem'
assert_eq 0 "$(find "$drvfs_case_dir" -maxdepth 1 -type d -name '.pip-coordinator.*' | wc -l)" 'raw coordinator logs never use the permissive production filesystem'
assert_eq 0 "$(grep '^LOGPARENTMODE:' "$COORDINATOR_STRICT_ARGS_LOG" | grep -vc '^LOGPARENTMODE:700$' || true)" 'production-filesystem coordinator workspace is mode 0700 while pip runs'
assert_eq 0 "$(grep '^LOGMODE:' "$COORDINATOR_STRICT_ARGS_LOG" | grep -vc '^LOGMODE:600$' || true)" 'production-filesystem coordinator logs are mode 0600 while pip runs'
if grep -Eq '^ARG:/tmp/dify-plugin-coordinator\.[^/]+/sdist-repair/candidate-1/source$' "$COORDINATOR_SOURCE_ARGS_LOG"; then
  pass 'production-filesystem default repair source staging remains below /tmp'
else
  fail 'production-filesystem default repair source staging remains below /tmp'
fi
assert_recorded_coordinator_workspaces_removed \
  "$COORDINATOR_STRICT_ARGS_LOG" \
  'production-filesystem repair removes its secure coordinator workspace'

prepare_dynamic_coordinator_case log-setup-failure SUCCESS
export COORDINATOR_SETUP_WORKSPACE_MARKER="$DYNAMIC_CASE_DIR/setup-workspace.path"
if (
  mkdir() {
    local argument
    command mkdir "$@" || return
    for argument in "$@"; do
      if [[ "$argument" == /tmp/dify-plugin-coordinator.* ]]; then
        printf '%s\n' "$argument" >"$COORDINATOR_SETUP_WORKSPACE_MARKER"
      fi
    done
  }
  mktemp() {
    return 70
  }
  run_dynamic_coordinator
) >"$DYNAMIC_OUTPUT" 2>&1; then
  fail 'coordinator log-file setup failure stops safely'
else
  pass 'coordinator log-file setup failure stops safely'
fi
setup_failure_workspace="$(<"$COORDINATOR_SETUP_WORKSPACE_MARKER")"
if [[ "$setup_failure_workspace" == /tmp/dify-plugin-coordinator.* && ! -e "$setup_failure_workspace" ]]; then
  pass 'coordinator cleans its secure workspace when log-file setup fails'
else
  fail 'coordinator cleans its secure workspace when log-file setup fails'
fi

prepare_dynamic_coordinator_case empty-requirements docopt
: >"$DYNAMIC_REQUIREMENTS"
touch -- "$DYNAMIC_WHEELS/stale-before-empty.whl"
if run_dynamic_coordinator >"$DYNAMIC_OUTPUT" 2>&1; then
  pass 'empty requirements preserve the no-resolver path'
else
  fail 'empty requirements preserve the no-resolver path'
fi
assert_eq 0 "$(grep -c '^CALL:' "$COORDINATOR_STRICT_ARGS_LOG")" 'empty requirements invoke no strict resolver'
assert_eq 0 "$(grep -c '^CALL$' "$COORDINATOR_SOURCE_ARGS_LOG")" 'empty requirements download no source'
assert_eq 0 "$(grep -c '^CALL$' "$COORDINATOR_UV_ARGS_LOG")" 'empty requirements invoke no uv'
assert_file_missing "$DYNAMIC_REPAIR_DIR" 'empty requirements create no repair directory'
assert_file_missing "$DYNAMIC_WHEELS/stale-before-empty.whl" 'empty requirements retain existing wheelhouse reset behavior'

blocked_names=(network dns proxy auth tls cert timeout hash conflict resolution unknown control)
blocked_messages=(
  'Network is unreachable'
  'NameResolutionError: DNS lookup failed'
  'ProxyError: cannot connect to proxy'
  '401 authentication required for https://auth-user:auth-password@mirror.example/simple?token=auth-query'
  'TLS handshake failed'
  'certificate verify failed'
  'operation timed out'
  'THESE PACKAGES DO NOT MATCH THE HASHES'
  'version conflict detected'
  'ResolutionImpossible: conflicting dependencies'
  'UNEXPECTED-DIAGNOSTIC-SENTINEL'
  'CONTROL'
)
for blocked_index in "${!blocked_names[@]}"; do
  blocked_name=${blocked_names[$blocked_index]}
  blocked_message=${blocked_messages[$blocked_index]}
  prepare_dynamic_coordinator_case "blocked-$blocked_name" "RAW|$blocked_message"
  if run_dynamic_coordinator >"$DYNAMIC_OUTPUT" 2>&1; then
    fail "blocked strict failure never triggers repair: $blocked_name"
  else
    pass "blocked strict failure never triggers repair: $blocked_name"
  fi
  assert_eq 1 "$(grep -c '^CALL:' "$COORDINATOR_STRICT_ARGS_LOG")" "blocked failure performs one strict attempt: $blocked_name"
  assert_eq 0 "$(grep -c '^CALL$' "$COORDINATOR_SOURCE_ARGS_LOG")" "blocked failure downloads no source: $blocked_name"
  assert_eq 0 "$(grep -c '^CALL$' "$COORDINATOR_UV_ARGS_LOG")" "blocked failure invokes no uv: $blocked_name"
  assert_file_missing "$DYNAMIC_REPAIR_DIR" "blocked failure creates no repair staging: $blocked_name"
  assert_file_contains "$DYNAMIC_OUTPUT" 'failed to download a complete binary wheel dependency set' "blocked failure receives standard target report: $blocked_name"
  for secret_value in auth-user auth-password auth-query; do
    assert_file_not_contains "$DYNAMIC_OUTPUT" "$secret_value" "blocked diagnostic redacts $secret_value: $blocked_name"
  done
done

prepare_dynamic_coordinator_case blocked-flood 'RAW|FLOOD'
if run_dynamic_coordinator >"$DYNAMIC_OUTPUT" 2>&1; then
  fail 'oversized unknown strict diagnostic fails closed'
else
  pass 'oversized unknown strict diagnostic fails closed'
fi
if (( $(stat -c '%s' "$DYNAMIC_OUTPUT") <= 1100000 )); then
  pass 'coordinator strict diagnostic display remains bounded'
else
  fail 'coordinator strict diagnostic display remains bounded'
fi
assert_file_contains "$DYNAMIC_OUTPUT" 'diagnostic output truncated' 'bounded coordinator diagnostic reports truncation'
assert_eq 0 "$(grep -c '^CALL$' "$COORDINATOR_SOURCE_ARGS_LOG")" 'oversized unknown strict diagnostic downloads no source'
assert_file_missing "$DYNAMIC_REPAIR_DIR" 'oversized unknown strict diagnostic creates no repair staging'

prepare_dynamic_coordinator_case task3-download-failure docopt
if COORDINATOR_SOURCE_MODE=failure run_dynamic_coordinator >"$DYNAMIC_OUTPUT" 2>&1; then
  fail 'Task3 source download failure stops the coordinator immediately'
else
  pass 'Task3 source download failure stops the coordinator immediately'
fi
assert_eq 1 "$(grep -c '^CALL:' "$COORDINATOR_STRICT_ARGS_LOG")" 'source download failure performs no next strict retry'
assert_eq 1 "$(grep -c '^CALL$' "$COORDINATOR_SOURCE_ARGS_LOG")" 'source download failure invokes one source request'
assert_eq 0 "$(grep -c '^CALL$' "$COORDINATOR_UV_ARGS_LOG")" 'source download failure never invokes uv'
assert_file_contains "$DYNAMIC_OUTPUT" 'Set DIFY_AUTO_BUILD_PURE_SDIST=0 to disable third-party source builds.' 'source download failure reports the repair kill switch'
for secret_value in source-user source-password source-query; do
  assert_file_not_contains "$DYNAMIC_OUTPUT" "$secret_value" "source download failure redacts $secret_value"
done

for failed_uv_mode in failure native nonpure mismatch; do
  prepare_dynamic_coordinator_case "task3-$failed_uv_mode" docopt
  if COORDINATOR_UV_MODE="$failed_uv_mode" run_dynamic_coordinator >"$DYNAMIC_OUTPUT" 2>&1; then
    fail "Task3 $failed_uv_mode failure stops the coordinator immediately"
  else
    pass "Task3 $failed_uv_mode failure stops the coordinator immediately"
  fi
  assert_eq 1 "$(grep -c '^CALL:' "$COORDINATOR_STRICT_ARGS_LOG")" "Task3 $failed_uv_mode failure performs no next strict retry"
  assert_eq 1 "$(grep -c '^CALL$' "$COORDINATOR_SOURCE_ARGS_LOG")" "Task3 $failed_uv_mode failure downloads one source"
  assert_eq 1 "$(grep -c '^CALL$' "$COORDINATOR_UV_ARGS_LOG")" "Task3 $failed_uv_mode failure invokes uv once"
  assert_file_contains "$DYNAMIC_OUTPUT" 'Set DIFY_AUTO_BUILD_PURE_SDIST=0 to disable third-party source builds.' "Task3 $failed_uv_mode failure reports the repair kill switch"
  for secret_value in build-user build-password build-query; do
    assert_file_not_contains "$DYNAMIC_OUTPUT" "$secret_value" "Task3 $failed_uv_mode diagnostic redacts $secret_value"
  done
done

prepare_dynamic_coordinator_case authenticated-index docopt
if COORDINATOR_INDEX_URL='https://index-user:index-password@target-index.example/simple?token=index-query#fragment' \
  run_dynamic_coordinator >"$DYNAMIC_OUTPUT" 2>&1; then
  fail 'authenticated package index remains fail-closed for source repair'
else
  pass 'authenticated package index remains fail-closed for source repair'
fi
assert_eq 1 "$(grep -c '^CALL:' "$COORDINATOR_STRICT_ARGS_LOG")" 'authenticated index failure performs no next strict retry'
assert_eq 0 "$(grep -c '^CALL$' "$COORDINATOR_SOURCE_ARGS_LOG")" 'authenticated index rejection occurs before source download'
assert_eq 0 "$(grep -c '^CALL$' "$COORDINATOR_UV_ARGS_LOG")" 'authenticated index rejection occurs before uv'
assert_file_contains "$DYNAMIC_OUTPUT" 'Pure Python sdist repair rejected the configured package index' 'authenticated index rejection remains explicit'
assert_file_contains "$DYNAMIC_OUTPUT" 'Set DIFY_AUTO_BUILD_PURE_SDIST=0 to disable third-party source builds.' 'authenticated index rejection reports the repair kill switch'
for secret_value in index-user index-password index-query; do
  assert_file_not_contains "$DYNAMIC_OUTPUT" "$secret_value" "authenticated index rejection redacts $secret_value"
done

prepare_dynamic_coordinator_case final-unclassifiable gamma 'RAW|UNEXPECTED-FINAL-RESOLUTION-DIAGNOSTIC'
if run_dynamic_coordinator >"$DYNAMIC_OUTPUT" 2>&1; then
  fail 'unclassifiable re-resolution failure stops after one admission'
else
  pass 'unclassifiable re-resolution failure stops after one admission'
fi
assert_eq 2 "$(grep -c '^CALL:' "$COORDINATOR_STRICT_ARGS_LOG")" 'unclassifiable re-resolution performs exactly two strict attempts'
assert_eq 1 "$(grep -c '^CALL$' "$COORDINATOR_SOURCE_ARGS_LOG")" 'unclassifiable re-resolution admits only one source candidate'
assert_file_contains "$DYNAMIC_OUTPUT" 'Initial strict wheel-resolution diagnostics:' 'distinct first failure diagnostics are labelled'
assert_file_contains "$DYNAMIC_OUTPUT" 'Final strict wheel-resolution diagnostics:' 'distinct final failure diagnostics are labelled'
assert_file_contains "$DYNAMIC_OUTPUT" 'Pure Python sdist repair failed during resolution after 1 admitted wheel(s).' 'post-admission resolution failure reports its admission count'
assert_file_not_contains "$DYNAMIC_OUTPUT" 'strict-user' 'post-admission diagnostics redact initial index username'
assert_file_not_contains "$DYNAMIC_OUTPUT" 'strict-password' 'post-admission diagnostics redact initial index password'
assert_file_not_contains "$DYNAMIC_OUTPUT" 'strict-query' 'post-admission diagnostics redact initial index query'

prepare_dynamic_coordinator_case identical-repeat docopt docopt
if run_dynamic_coordinator >"$DYNAMIC_OUTPUT" 2>&1; then
  fail 'identical repeated candidate fails without rebuilding'
else
  pass 'identical repeated candidate fails without rebuilding'
fi
assert_eq 1 "$(grep -c '^Strict wheel-resolution diagnostics:$' "$DYNAMIC_OUTPUT")" 'identical initial/final diagnostics use one display section'
assert_eq 1 "$(grep -c 'Could not find a version that satisfies the requirement docopt' "$DYNAMIC_OUTPUT")" 'identical raw resolver diagnostics are displayed only once'
assert_eq 1 "$(grep -c '^CALL$' "$COORDINATOR_SOURCE_ARGS_LOG")" 'identical repeated candidate is built only once'

for cancellation_status in 124 125 129 130 143; do
  prepare_dynamic_coordinator_case "cancel-$cancellation_status" docopt
  if (
    repair_one_pure_sdist_impl() { return "$cancellation_status"; }
    run_dynamic_coordinator_default
  ) >"$DYNAMIC_OUTPUT" 2>&1; then
    observed_cancellation_status=0
  else
    observed_cancellation_status=$?
  fi
  assert_eq "$cancellation_status" "$observed_cancellation_status" "Task3 cancellation status propagates: $cancellation_status"
  assert_eq 1 "$(grep -c '^CALL:' "$COORDINATOR_STRICT_ARGS_LOG")" "Task3 cancellation permits no extra strict retry: $cancellation_status"
  assert_eq 0 "$(grep -c '^CALL$' "$COORDINATOR_SOURCE_ARGS_LOG")" "Task3 cancellation fixture downloads no source: $cancellation_status"
  assert_eq 0 "$(grep -c '^CALL$' "$COORDINATOR_UV_ARGS_LOG")" "Task3 cancellation fixture invokes no uv: $cancellation_status"
  assert_file_missing "$DYNAMIC_REPAIR_DIR/.repair-lock" "Task3 cancellation leaves no repair lock: $cancellation_status"
  assert_recorded_coordinator_workspaces_removed \
    "$COORDINATOR_STRICT_ARGS_LOG" \
    "Task3 cancellation removes the default secure workspace: $cancellation_status"
done

prepare_dynamic_coordinator_case cancel-mutated-workspace docopt
if (
  repair_one_pure_sdist_impl() {
    mutated_workspace="$(dirname -- "$6")"
    mkdir -p -- "$mutated_workspace/unreadable/nested"
    printf 'cleanup sentinel\n' >"$mutated_workspace/unreadable/nested/file"
    chmod 000 -- "$mutated_workspace/unreadable" "$mutated_workspace"
    return 129
  }
  run_dynamic_coordinator_default
) >"$DYNAMIC_OUTPUT" 2>&1; then
  mutated_workspace_status=0
else
  mutated_workspace_status=$?
fi
assert_eq 129 "$mutated_workspace_status" 'HUP status survives a Task3 workspace-mode mutation'
assert_file_not_contains "$DYNAMIC_OUTPUT" 'failed to download a complete binary wheel dependency set' 'HUP cancellation emits no ordinary resolver failure report'
assert_recorded_coordinator_workspaces_removed \
  "$COORDINATOR_STRICT_ARGS_LOG" \
  'coordinator removes its owned workspace after Task3 changes the workspace mode'

if grep '^LOGPARENTMODE:' "$COORDINATOR_STRICT_ARGS_LOG" | grep -qv '^LOGPARENTMODE:700$'; then
  fail 'coordinator raw-log parent remains private while pip runs'
else
  pass 'coordinator raw-log parent remains private while pip runs'
fi
assert_eq 0 "$(grep '^LOGMODE:' "$COORDINATOR_STRICT_ARGS_LOG" | grep -vc '^LOGMODE:600$' || true)" 'coordinator raw logs use mode 0600 while pip runs'
assert_eq 0 "$(find "$FIXTURE_DIR" -type d -name '.pip-coordinator.*' | wc -l)" 'coordinator removes every private raw-log directory after success and failure'
if [[ -d "$coordinator_repair_dir" && -f "$coordinator_repair_dir/built-wheels/docopt-0.6.2-py2.py3-none-any.whl" ]]; then
  pass 'coordinator log cleanup preserves the admitted repair tree'
else
  fail 'coordinator log cleanup preserves the admitted repair tree'
fi

coordinator_function_source="$(sed -n '/^download_wheels_impl() {/,/^download_wheels() {/p' "$ROOT_DIR/plugin_repackaging.sh")"
for source_specific_name in docopt records database-plus uxdb; do
  if grep -Fiq -- "$source_specific_name" <<<"$coordinator_function_source"; then
    fail "coordinator production remains generic: $source_specific_name"
  else
    pass "coordinator production remains generic: $source_specific_name"
  fi
done
if grep -Eq '(^|[[:space:]])eval([[:space:]]|$)|--no-binary|manylinux.*x86_64.*aarch64|aarch64.*x86_64' <<<"$coordinator_function_source"; then
  fail 'coordinator contains no eval, native-source mode, or host-architecture fallback'
else
  pass 'coordinator contains no eval, native-source mode, or host-architecture fallback'
fi
if grep -Fq '${#repaired_candidates' <<<"$coordinator_function_source"; then
  fail 'coordinator associative set avoids Bash 4.3 nounset-unsafe length expansion'
else
  pass 'coordinator associative set avoids Bash 4.3 nounset-unsafe length expansion'
fi
if bash43_command="$(command -v bash4.3 2>/dev/null)" && [[ -n "$bash43_command" ]]; then
  prepare_dynamic_coordinator_case bash43-success SUCCESS
  if env \
    -u http_proxy -u https_proxy -u all_proxy \
    -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
    ROOT_DIR="$ROOT_DIR" \
    DYNAMIC_REQUIREMENTS="$DYNAMIC_REQUIREMENTS" \
    DYNAMIC_WHEELS="$DYNAMIC_WHEELS" \
    DYNAMIC_REPAIR_DIR="$DYNAMIC_REPAIR_DIR" \
    DIFY_PIP_COMMAND="$fake_bin/pip-repair-coordinator-dynamic" \
    DIFY_UV_COMMAND="$fake_bin/uv-repair-coordinator-dynamic" \
    COORDINATOR_SEQUENCE_FILE="$COORDINATOR_SEQUENCE_FILE" \
    COORDINATOR_STRICT_STATE="$COORDINATOR_STRICT_STATE" \
    COORDINATOR_STRICT_ARGS_LOG="$COORDINATOR_STRICT_ARGS_LOG" \
    COORDINATOR_SOURCE_ARGS_LOG="$COORDINATOR_SOURCE_ARGS_LOG" \
    COORDINATOR_UV_ARGS_LOG="$COORDINATOR_UV_ARGS_LOG" \
    "$bash43_command" -uc \
      'source "$ROOT_DIR/plugin_repackaging.sh"; download_wheels "$DYNAMIC_REQUIREMENTS" "$DYNAMIC_WHEELS" aarch64 3.12 "" "$DYNAMIC_REPAIR_DIR"' \
      >"$DYNAMIC_OUTPUT" 2>&1; then
    pass 'Bash 4.3 executes the coordinator under nounset'
  else
    fail 'Bash 4.3 executes the coordinator under nounset'
  fi
else
  pass 'Bash 4.3 runtime unavailable; coordinator associative-set regressions are covered statically'
fi

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
assert_file_contains "$pip_download_failure_log" 'Only validated pure Python universal wheels may be built from source' 'standard failure report preserves the pure-only source boundary'

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
    if [[ "${FAKE_PIP_SOCKS_TLS_NEAR_MATCH:-0}" == 1 ]]; then
      printf '%s\n' \
        "TypeError: PoolKey.__new__() got an unexpected keyword argument 'key_proxy_ssl_context_extra'" >&2
      exit 87
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
near_match_case_dir="$FIXTURE_DIR/pysocks-near-match-case"
mkdir -p "$near_match_case_dir"
if https_proxy='socks5h://10.10.10.10:28802' \
  HTTPS_PROXY= HTTP_PROXY= http_proxy= ALL_PROXY= all_proxy= \
  FAKE_PIP_HAS_PYSOCKS=1 \
  FAKE_PIP_SOCKS_TLS_NEAR_MATCH=1 \
  PATH="$socks_fake_bin:$PATH" \
  DIFY_PIP_COMMAND="$socks_fake_bin/pip-socks" \
  download_wheels \
    "$metadata_dir/download.txt" \
    "$near_match_case_dir/wheels" \
    aarch64 \
    3.12 \
    "$near_match_case_dir/pip-bootstrap" \
    >"$near_match_case_dir/output.log" 2>&1; then
  fail 'near-match SOCKS truststore error remains a failure'
else
  pass 'near-match SOCKS truststore error remains a failure'
fi
assert_eq 1 "$(grep -c '^download ' "$SOCKS_PIP_LOG")" 'near-match SOCKS truststore error is not retried'
assert_file_not_contains "$near_match_case_dir/output.log" 'retrying once' 'near-match SOCKS error does not enable compatibility retry'

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
mkdir -p "$input_plugin_dir/provider" "$input_plugin_dir/models/llm" "$input_plugin_dir/wheels"
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
printf 'stale host wheel\n' >"$input_plugin_dir/wheels/stale-1.0-cp312-cp312-manylinux_2_28_x86_64.whl"
printf 'stale partial attempt\n' >"$input_plugin_dir/wheels/partial-from-original-attempt.whl"
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

cat >"$fake_bin/pip-full-repackage" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
is_strict=false
dest=
find_links=
previous=
for argument in "$@"; do
  [[ "$argument" == --only-binary=:all: ]] && is_strict=true
  if [[ "$previous" == --dest || "$previous" == -d ]]; then
    dest=$argument
  elif [[ "$previous" == --find-links ]]; then
    find_links=$argument
  fi
  previous=$argument
done
[[ -n "$dest" ]]
workspace="$(find /tmp -maxdepth 1 -type d -user "$(id -u)" \
  -name 'dify-plugin-coordinator.*' -printf '%T@ %p\n' | sort -nr | sed -n '1s/^[^ ]* //p')"
[[ -z "$workspace" ]] || printf 'WORKSPACE:%s\n' "$workspace" >>"$FULL_WORKSPACE_LOG"

if [[ "$is_strict" == true ]]; then
  attempt=0
  [[ -f "$FULL_STRICT_STATE" ]] && attempt="$(<"$FULL_STRICT_STATE")"
  attempt=$((attempt + 1))
  printf '%s\n' "$attempt" >"$FULL_STRICT_STATE"
  {
    printf 'STRICT:%s\n' "$attempt"
    printf 'ARG:%s\n' "$@"
  } >>"$FULL_PIP_LOG"
  mkdir -p -- "$dest"
  if [[ "${FULL_REPAIR_MODE:-success}" == wheel-only ]]; then
    touch -- "$dest/runtime-target-1.0-py3-none-any.whl"
    exit 0
  fi
  if ((attempt == 1)); then
    touch -- "$dest/partial-from-failed-attempt.whl"
    printf '%s\n' \
      'Looking in indexes: https://strict-user:strict-password@mirror.example/simple?token=strict-query#fragment' \
      'ERROR: Could not find a version that satisfies the requirement docopt (from records) (from versions: none)' \
      'ERROR: No matching distribution found for docopt'
    exit 1
  fi
  if [[ "${FULL_REPAIR_MODE:-success}" == resolution-failure ]]; then
    printf 'unexpected final resolution via https://final-user:final-password@mirror.example/simple?token=final-query#fragment\v\n'
    exit 1
  fi
  [[ -n "$find_links" && -d "$find_links" ]]
  cp -- "$find_links"/*.whl "$dest/"
  touch -- "$dest/runtime-target-1.0-py3-none-any.whl"
  exit 0
fi

printf 'SOURCE\n' >>"$FULL_PIP_LOG"
if [[ "${FULL_REPAIR_MODE:-success}" == download-failure ]]; then
  printf 'download failed via https://download-user:download-password@mirror.example/simple?token=download-query#fragment\v\n' >&2
  exit 41
fi
python3 - "$dest" <<'PY'
from pathlib import Path
import io
import tarfile
import sys

destination = Path(sys.argv[1])
destination.mkdir(parents=True, exist_ok=True)
prefix = "docopt-0.6.2"
metadata = b"Metadata-Version: 2.1\nName: docopt\nVersion: 0.6.2\n\n"
with tarfile.open(destination / f"{prefix}.tar.gz", "w:gz") as archive:
    for member_name, contents in (
        (f"{prefix}/PKG-INFO", metadata),
        (f"{prefix}/setup.py", b"from setuptools import setup\nsetup()\n"),
    ):
        info = tarfile.TarInfo(member_name)
        info.size = len(contents)
        info.mode = 0o644
        archive.addfile(info, io.BytesIO(contents))
PY
EOF

cat >"$fake_bin/uv-full-repackage" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${1:-}" == --version ]]; then
  printf 'uv 0.11.24\n'
  exit 0
fi
printf 'CALL:%s\n' "$*" >>"$FULL_UV_LOG"
if [[ "${1:-}" != build ]]; then
  exit "${FULL_VERIFY_STATUS:-0}"
fi
if [[ "${FULL_REPAIR_MODE:-success}" == build-failure ]]; then
  printf 'build failed via socks5h://build-user:build-password@10.10.10.10:28802/path?token=build-query#fragment\v\n' >&2
  exit 51
fi
if [[ "${FULL_REPAIR_MODE:-success}" == cancel ]]; then
  printf '%s\n' "$$" >"$FULL_CHILD_PID_FILE"
  : >"$FULL_CANCEL_MARKER"
  trap '' HUP INT TERM
  while :; do sleep 1; done
fi
out_dir=
previous=
for argument in "$@"; do
  if [[ "$previous" == --out-dir ]]; then
    out_dir=$argument
  fi
  previous=$argument
done
[[ -n "$out_dir" ]]
python3 - "$out_dir" "${FULL_REPAIR_MODE:-success}" <<'PY'
from pathlib import Path
import sys
import zipfile

output_dir = Path(sys.argv[1])
mode = sys.argv[2]
output_dir.mkdir(parents=True, exist_ok=True)
wheel = output_dir / "docopt-0.6.2-py2.py3-none-any.whl"
wheel_metadata = (
    "Wheel-Version: 1.0\n"
    "Generator: full-repackage-test\n"
    "Root-Is-Purelib: true\n"
    "Tag: py2-none-any\n"
    "Tag: py3-none-any\n\n"
).encode()
with zipfile.ZipFile(wheel, "w", zipfile.ZIP_DEFLATED) as archive:
    archive.writestr(
        "docopt-0.6.2.dist-info/METADATA",
        b"Metadata-Version: 2.1\nName: docopt\nVersion: 0.6.2\n\n",
    )
    archive.writestr("docopt-0.6.2.dist-info/WHEEL", wheel_metadata)
    if mode == "native":
        archive.writestr("docopt/native.bin", b"\x7fELF" + b"\0" * 32)
    else:
        archive.writestr("docopt.py", b"__version__ = '0.6.2'\n")
PY
EOF

cat >"$fake_bin/dify-packager-full" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
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
printf 'OUTPUT_PATH:%s\n' "$output" >>"$FULL_PACKAGER_LOG"
if [[ -e "${FULL_FORMAL_OUTPUT:-}" ]]; then
  printf 'FORMAL_AT_START:%s\n' "$(sha256sum "$FULL_FORMAL_OUTPUT" | cut -d' ' -f1)" >>"$FULL_PACKAGER_LOG"
else
  printf 'FORMAL_AT_START:absent\n' >>"$FULL_PACKAGER_LOG"
fi
if [[ -e "$output" ]]; then
  printf 'OUTPUT_WAS_ABSENT:false\n' >>"$FULL_PACKAGER_LOG"
  exit 87
fi
printf 'OUTPUT_WAS_ABSENT:true\n' >>"$FULL_PACKAGER_LOG"
case "${FULL_PACKAGER_MODE:-success}" in
  nonzero)
    printf 'partial package\n' >"$output"
    exit 61
    ;;
  crash)
    printf 'partial package\n' >"$output"
    kill -KILL "$$"
    ;;
  invalid)
    printf 'not a zip archive\n' >"$output"
    exit 0
    ;;
  slow-success)
    printf 'partial package\n' >"$output"
    printf '%s\n' "$$" >"$FULL_PACKAGER_CHILD_PID_FILE"
    : >"$FULL_PACKAGER_MARKER"
    while [[ ! -e "$FULL_PACKAGER_RELEASE" ]]; do sleep 0.05; done
    ;;
esac
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
chmod +x "$fake_bin/pip-full-repackage" "$fake_bin/uv-full-repackage" "$fake_bin/dify-packager-full"

export FULL_STRICT_STATE="$FIXTURE_DIR/full-strict.state"
export FULL_PIP_LOG="$FIXTURE_DIR/full-pip.args"
export FULL_UV_LOG="$FIXTURE_DIR/full-uv.args"
export FULL_PACKAGER_LOG="$FIXTURE_DIR/full-packager.args"
export FULL_WORKSPACE_LOG="$FIXTURE_DIR/full-workspaces.log"
export FULL_CANCEL_MARKER="$FIXTURE_DIR/full-cancel.ready"
export FULL_CHILD_PID_FILE="$FIXTURE_DIR/full-cancel-child.pid"
export FULL_FORMAL_OUTPUT="$GENERATED_TEST_OUTPUT"
export FULL_PACKAGER_MARKER="$FIXTURE_DIR/full-packager.ready"
export FULL_PACKAGER_RELEASE="$FIXTURE_DIR/full-packager.release"
export FULL_PACKAGER_CHILD_PID_FILE="$FIXTURE_DIR/full-packager-child.pid"
input_package_sha256="$(sha256sum "$input_package" | cut -d' ' -f1)"

prepare_full_repackage_case() {
  rm -f -- \
    "$GENERATED_TEST_OUTPUT" "$FULL_STRICT_STATE" "$FULL_CANCEL_MARKER" "$FULL_CHILD_PID_FILE" \
    "$FULL_PACKAGER_MARKER" "$FULL_PACKAGER_RELEASE" "$FULL_PACKAGER_CHILD_PID_FILE"
  : >"$FULL_PIP_LOG"
  : >"$FULL_UV_LOG"
  : >"$FULL_PACKAGER_LOG"
  : >"$FULL_WORKSPACE_LOG"
}

seed_prior_full_output() {
  python3 - "$GENERATED_TEST_OUTPUT" <<'PY'
from zipfile import ZIP_DEFLATED, ZipFile
import sys

with ZipFile(sys.argv[1], "w", ZIP_DEFLATED) as archive:
    archive.writestr("previous-valid-package.txt", "previous valid offline package sentinel\n")
PY
  PRIOR_FULL_OUTPUT_SHA256="$(sha256sum "$GENERATED_TEST_OUTPUT" | cut -d' ' -f1)"
}

run_full_repackage_case() {
  local mode=$1
  local log=$2
  shift 2
  env -u http_proxy -u https_proxy -u all_proxy \
    -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
    FULL_REPAIR_MODE="$mode" \
    DIFY_PIP_COMMAND="$fake_bin/pip-full-repackage" \
    DIFY_UV_COMMAND="$fake_bin/uv-full-repackage" \
    DIFY_PACKAGER_BINARY="$fake_bin/dify-packager-full" \
    DIFY_TARGET_ARCH=aarch64 \
    "$@" \
    bash "$ROOT_DIR/plugin_repackaging.sh" local "$input_package" >"$log" 2>&1
}

assert_full_repackage_cleanup() {
  local name=$1
  local workspace
  assert_eq 0 "$(find "$ROOT_DIR" -maxdepth 1 -type d -name '.dify-repackaging.*' | wc -l)" "$name cleans repository staging"
  assert_eq 0 "$(find "$ROOT_DIR" -maxdepth 1 -type d -name '.dify-output.*' | wc -l)" "$name cleans atomic-output staging"
  while IFS= read -r workspace; do
    [[ -z "$workspace" ]] && continue
    if [[ "$workspace" == /tmp/dify-plugin-coordinator.* && ! -e "$workspace" ]]; then
      continue
    fi
    fail "$name cleans its secure coordinator workspace"
    return
  done < <(sed -n 's/^WORKSPACE://p' "$FULL_WORKSPACE_LOG" | sort -u)
  if grep -q '^WORKSPACE:' "$FULL_WORKSPACE_LOG"; then
    pass "$name cleans its secure coordinator workspace"
  else
    pass "$name creates no coordinator workspace before early exit"
  fi
  assert_eq "$input_package_sha256" "$(sha256sum "$input_package" | cut -d' ' -f1)" "$name leaves its input package unchanged"
}

assert_initial_strict_secrets_redacted() {
  local log=$1
  local name=$2
  local secret_value
  for secret_value in strict-user strict-password strict-query; do
    assert_file_not_contains "$log" "$secret_value" "$name redacts $secret_value"
  done
}

prepare_full_repackage_case
seed_prior_full_output
full_success_log="$FIXTURE_DIR/full-repackage-success.log"
if run_full_repackage_case success "$full_success_log"; then
  pass 'full local command self-heals a pure Python sdist dependency'
else
  fail 'full local command self-heals a pure Python sdist dependency'
  sed 's/^/# full self-heal: /' "$full_success_log"
fi
assert_file_contains "$full_success_log" 'Pure Python sdist repair candidate: docopt' 'full self-heal reports its candidate'
assert_file_contains "$full_success_log" 'Pure Python wheel admitted: docopt-0.6.2-py2.py3-none-any.whl' 'full self-heal reports validated admission'
assert_file_contains "$full_success_log" 'Repackage success.' 'full self-heal reports package success'
if [[ -f "$GENERATED_TEST_OUTPUT" ]]; then
  full_archive_entries="$(unzip -Z1 "$GENERATED_TEST_OUTPUT")"
  if unzip -tq "$GENERATED_TEST_OUTPUT" >/dev/null; then
    pass 'full self-healed archive passes ZIP integrity verification'
  else
    fail 'full self-healed archive passes ZIP integrity verification'
  fi
  assert_eq 1 "$(grep -c '^wheels/docopt-0.6.2-py2.py3-none-any.whl$' <<<"$full_archive_entries")" 'full archive contains exactly one admitted docopt wheel'
  assert_eq 1 "$(grep -c '^wheels/runtime-target-1.0-py3-none-any.whl$' <<<"$full_archive_entries")" 'full archive contains its target runtime wheel'
  assert_eq 2 "$(grep -c '^wheels/.*\.whl$' <<<"$full_archive_entries")" 'full archive contains only the resolved wheel set'
  assert_eq 0 "$(grep -Eci '(^|/)(sdist-repair|candidate-[^/]*|built-wheels|uv-cache|uv-python|pip-bootstrap)(/|$)|\.(tar|tar\.gz|tgz|tar\.bz2|tar\.xz|zip)$|(^|/)(initial|current)\.[^/]*\.log$|(^|/)\.(download|build|validation)-log\.[^/]+$|coordinator' <<<"$full_archive_entries" || true)" 'full archive excludes source archives, repair state, caches, and raw logs'
  assert_eq 0 "$(grep -Eci 'x86_64|win32|win_amd64|macosx|\.so$|\.pyd$|\.dll$|\.dylib$' <<<"$full_archive_entries" || true)" 'full archive excludes host and native binaries'
  assert_eq 0 "$(grep -Ec 'stale|partial-from' <<<"$full_archive_entries" || true)" 'full archive excludes original and failed-attempt wheels'
else
  fail 'full self-healed archive is created only after successful packaging'
fi
assert_file_contains "$FULL_PACKAGER_LOG" 'OUTPUT_WAS_ABSENT:true' 'packager receives no partial pre-existing output'
assert_file_contains "$FULL_PACKAGER_LOG" "FORMAL_AT_START:$PRIOR_FULL_OUTPUT_SHA256" 'packager runs while the previous formal output remains intact'
if [[ -f "$GENERATED_TEST_OUTPUT" && "$(sha256sum "$GENERATED_TEST_OUTPUT" | cut -d' ' -f1)" != "$PRIOR_FULL_OUTPUT_SHA256" ]]; then
  pass 'successful full self-heal atomically replaces the prior output'
else
  fail 'successful full self-heal atomically replaces the prior output'
fi
assert_full_repackage_cleanup 'full self-heal success'
if [[ "$ROOT_DIR" == /mnt/?/* ]]; then
  if grep -Eq '^WORKSPACE:/tmp/dify-plugin-coordinator\.' "$FULL_WORKSPACE_LOG"; then
    pass 'DrvFS full self-heal keeps coordinator state on the Linux /tmp filesystem'
  else
    fail 'DrvFS full self-heal keeps coordinator state on the Linux /tmp filesystem'
  fi
else
  pass 'DrvFS full-flow check is not applicable outside a mounted Windows workspace'
fi

prepare_full_repackage_case
seed_prior_full_output
full_wheel_only_log="$FIXTURE_DIR/full-repackage-wheel-only.log"
if run_full_repackage_case wheel-only "$full_wheel_only_log"; then
  pass 'normal wheel-only full package remains successful'
else
  fail 'normal wheel-only full package remains successful'
fi
assert_file_not_contains "$full_wheel_only_log" 'Pure Python sdist repair candidate:' 'normal wheel-only flow emits no source-repair message'
assert_eq 0 "$(grep -c '^SOURCE$' "$FULL_PIP_LOG" || true)" 'normal wheel-only flow downloads no source'
if [[ -f "$GENERATED_TEST_OUTPUT" ]]; then
  wheel_only_entries="$(unzip -Z1 "$GENERATED_TEST_OUTPUT")"
  assert_eq 1 "$(grep -c '^wheels/runtime-target-1.0-py3-none-any.whl$' <<<"$wheel_only_entries")" 'normal wheel-only archive preserves its target wheel'
  assert_eq 0 "$(grep -Eci 'sdist|candidate-|built-wheels|uv-cache|uv-python|coordinator' <<<"$wheel_only_entries" || true)" 'normal wheel-only archive contains no repair artifacts'
else
  fail 'normal wheel-only full package creates its offline output'
fi
assert_full_repackage_cleanup 'normal wheel-only success'

prepare_full_repackage_case
seed_prior_full_output
full_disabled_log="$FIXTURE_DIR/full-repackage-disabled.log"
if run_full_repackage_case success "$full_disabled_log" DIFY_AUTO_BUILD_PURE_SDIST=0; then
  full_disabled_status=0
  fail 'disabled automatic source repair stops the full package'
else
  full_disabled_status=$?
  pass 'disabled automatic source repair stops the full package'
fi
assert_eq 1 "$full_disabled_status" 'disabled full flow returns ordinary failure status 1'
assert_eq 1 "$(grep -c '^STRICT:' "$FULL_PIP_LOG")" 'disabled full flow performs one strict attempt'
assert_eq 0 "$(grep -c '^SOURCE$' "$FULL_PIP_LOG" || true)" 'disabled full flow performs no source download'
assert_file_contains "$full_disabled_log" 'Automatic pure Python sdist repair is disabled by DIFY_AUTO_BUILD_PURE_SDIST.' 'disabled full flow reports the switch explicitly'
assert_eq "$PRIOR_FULL_OUTPUT_SHA256" "$(sha256sum "$GENERATED_TEST_OUTPUT" | cut -d' ' -f1)" 'disabled full flow preserves the prior valid output byte-for-byte'
assert_initial_strict_secrets_redacted "$full_disabled_log" 'disabled full flow'
assert_full_repackage_cleanup 'disabled full flow'

for full_failure_mode in download-failure build-failure native resolution-failure; do
  prepare_full_repackage_case
  seed_prior_full_output
  full_failure_log="$FIXTURE_DIR/full-repackage-$full_failure_mode.log"
  if run_full_repackage_case "$full_failure_mode" "$full_failure_log"; then
    full_failure_status=0
    fail "full $full_failure_mode repair failure stops packaging"
  else
    full_failure_status=$?
    pass "full $full_failure_mode repair failure stops packaging"
  fi
  assert_eq 1 "$full_failure_status" "full $full_failure_mode returns ordinary failure status 1"
  case "$full_failure_mode" in
    download-failure)
      assert_file_contains "$full_failure_log" 'Pure Python sdist repair failed during download:' 'full source download failure identifies its stage'
      ;;
    build-failure)
      assert_file_contains "$full_failure_log" 'Pure Python sdist repair failed during build:' 'full source build failure identifies its stage'
      ;;
    native)
      assert_file_contains "$full_failure_log" 'Pure Python sdist repair failed during validation:' 'full native wheel rejection identifies validation'
      assert_file_contains "$full_failure_log" 'native' 'full native wheel rejection exposes a safe validator reason'
      ;;
    resolution-failure)
      assert_file_contains "$full_failure_log" 'Pure Python sdist repair failed during resolution after 1 admitted wheel(s).' 'full final resolution failure identifies its stage'
      ;;
  esac
  assert_eq "$PRIOR_FULL_OUTPUT_SHA256" "$(sha256sum "$GENERATED_TEST_OUTPUT" | cut -d' ' -f1)" "full $full_failure_mode preserves the prior valid output byte-for-byte"
  assert_full_repackage_cleanup "full $full_failure_mode failure"
  assert_initial_strict_secrets_redacted "$full_failure_log" "full $full_failure_mode output"
  for secret_value in download-user download-password download-query build-user build-password build-query final-user final-password final-query; do
    assert_file_not_contains "$full_failure_log" "$secret_value" "full $full_failure_mode output redacts $secret_value"
  done
  if LC_ALL=C grep -q $'\v' "$full_failure_log"; then
    fail "full $full_failure_mode output strips control characters"
  else
    pass "full $full_failure_mode output strips control characters"
  fi
done

for full_packager_failure_mode in nonzero crash invalid; do
  prepare_full_repackage_case
  seed_prior_full_output
  full_packager_failure_log="$FIXTURE_DIR/full-packager-$full_packager_failure_mode.log"
  if run_full_repackage_case wheel-only "$full_packager_failure_log" \
    "FULL_PACKAGER_MODE=$full_packager_failure_mode"; then
    full_packager_failure_status=0
    fail "full packager $full_packager_failure_mode output stops publication"
  else
    full_packager_failure_status=$?
    pass "full packager $full_packager_failure_mode output stops publication"
  fi
  assert_eq 1 "$full_packager_failure_status" "full packager $full_packager_failure_mode normalizes to status 1"
  assert_eq "$PRIOR_FULL_OUTPUT_SHA256" "$(sha256sum "$GENERATED_TEST_OUTPUT" | cut -d' ' -f1)" "full packager $full_packager_failure_mode preserves the prior valid output"
  if unzip -tq "$GENERATED_TEST_OUTPUT" >/dev/null; then
    pass "full packager $full_packager_failure_mode leaves a valid prior archive"
  else
    fail "full packager $full_packager_failure_mode leaves a valid prior archive"
  fi
  assert_full_repackage_cleanup "full packager $full_packager_failure_mode failure"
done

prepare_full_repackage_case
full_atomic_success_log="$FIXTURE_DIR/full-packager-atomic-success.log"
setsid env -u http_proxy -u https_proxy -u all_proxy \
  -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
  FULL_REPAIR_MODE=wheel-only \
  FULL_PACKAGER_MODE=slow-success \
  DIFY_PIP_COMMAND="$fake_bin/pip-full-repackage" \
  DIFY_UV_COMMAND="$fake_bin/uv-full-repackage" \
  DIFY_PACKAGER_BINARY="$fake_bin/dify-packager-full" \
  DIFY_TARGET_ARCH=aarch64 \
  bash "$ROOT_DIR/plugin_repackaging.sh" local "$input_package" >"$full_atomic_success_log" 2>&1 &
full_atomic_success_pid=$!
for _ in {1..200}; do
  [[ -f "$FULL_PACKAGER_MARKER" ]] && break
  kill -0 "$full_atomic_success_pid" 2>/dev/null || break
  sleep 0.05
done
if [[ -f "$FULL_PACKAGER_MARKER" ]]; then
  pass 'slow packager reaches its partial temporary-output state'
else
  fail 'slow packager reaches its partial temporary-output state'
fi
assert_file_missing "$GENERATED_TEST_OUTPUT" 'formal output remains absent while a new package is partial'
if grep -Eq '^OUTPUT_PATH:.*/\.dify-output\.[^/]+/[^/]+\.difypkg$' "$FULL_PACKAGER_LOG"; then
  pass 'packager writes only to a same-parent controlled temporary directory'
else
  fail 'packager writes only to a same-parent controlled temporary directory'
fi
: >"$FULL_PACKAGER_RELEASE"
if wait "$full_atomic_success_pid"; then
  full_atomic_success_status=0
else
  full_atomic_success_status=$?
fi
assert_eq 0 "$full_atomic_success_status" 'slow successful packager publishes successfully'
if [[ -f "$GENERATED_TEST_OUTPUT" ]] && unzip -tq "$GENERATED_TEST_OUTPUT" >/dev/null; then
  pass 'slow successful packager publishes only a verified archive'
else
  fail 'slow successful packager publishes only a verified archive'
fi
assert_full_repackage_cleanup 'slow successful atomic publication'

prepare_full_repackage_case
seed_prior_full_output
full_atomic_cancel_log="$FIXTURE_DIR/full-packager-atomic-cancel.log"
setsid env -u http_proxy -u https_proxy -u all_proxy \
  -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
  FULL_REPAIR_MODE=wheel-only \
  FULL_PACKAGER_MODE=slow-success \
  DIFY_PIP_COMMAND="$fake_bin/pip-full-repackage" \
  DIFY_UV_COMMAND="$fake_bin/uv-full-repackage" \
  DIFY_PACKAGER_BINARY="$fake_bin/dify-packager-full" \
  DIFY_TARGET_ARCH=aarch64 \
  bash "$ROOT_DIR/plugin_repackaging.sh" local "$input_package" >"$full_atomic_cancel_log" 2>&1 &
full_atomic_cancel_pid=$!
for _ in {1..200}; do
  [[ -f "$FULL_PACKAGER_MARKER" ]] && break
  kill -0 "$full_atomic_cancel_pid" 2>/dev/null || break
  sleep 0.05
done
assert_eq "$PRIOR_FULL_OUTPUT_SHA256" "$(sha256sum "$GENERATED_TEST_OUTPUT" | cut -d' ' -f1)" 'prior output stays byte-identical while the replacement is partial'
kill -TERM "$full_atomic_cancel_pid" 2>/dev/null || true
if wait "$full_atomic_cancel_pid"; then
  full_atomic_cancel_status=0
else
  full_atomic_cancel_status=$?
fi
assert_eq 143 "$full_atomic_cancel_status" 'TERM during packaging preserves status 143'
assert_eq "$PRIOR_FULL_OUTPUT_SHA256" "$(sha256sum "$GENERATED_TEST_OUTPUT" | cut -d' ' -f1)" 'TERM during packaging preserves the prior valid output'
assert_full_repackage_cleanup 'TERM during atomic package creation'
if [[ -f "$FULL_PACKAGER_CHILD_PID_FILE" ]] && ! kill -0 "$(<"$FULL_PACKAGER_CHILD_PID_FILE")" 2>/dev/null; then
  pass 'TERM during packaging reaps the packager process'
else
  fail 'TERM during packaging reaps the packager process'
  [[ ! -f "$FULL_PACKAGER_CHILD_PID_FILE" ]] || kill -TERM "$(<"$FULL_PACKAGER_CHILD_PID_FILE")" 2>/dev/null || true
fi

prepare_full_repackage_case
seed_prior_full_output
full_cancel_log="$FIXTURE_DIR/full-repackage-cancel.log"
setsid env -u http_proxy -u https_proxy -u all_proxy \
  -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
  FULL_REPAIR_MODE=cancel \
  DIFY_PIP_COMMAND="$fake_bin/pip-full-repackage" \
  DIFY_UV_COMMAND="$fake_bin/uv-full-repackage" \
  DIFY_PACKAGER_BINARY="$fake_bin/dify-packager-full" \
  DIFY_TARGET_ARCH=aarch64 \
  bash "$ROOT_DIR/plugin_repackaging.sh" local "$input_package" >"$full_cancel_log" 2>&1 &
full_cancel_pid=$!
for _ in {1..200}; do
  [[ -f "$FULL_CANCEL_MARKER" ]] && break
  kill -0 "$full_cancel_pid" 2>/dev/null || break
  sleep 0.05
done
if [[ -f "$FULL_CANCEL_MARKER" ]]; then
  kill -TERM "$full_cancel_pid" 2>/dev/null || true
else
  fail 'full cancellation fixture reaches the supervised source build'
  kill -TERM -- "-$full_cancel_pid" 2>/dev/null || true
fi
if wait "$full_cancel_pid"; then
  full_cancel_status=0
else
  full_cancel_status=$?
fi
assert_eq 143 "$full_cancel_status" 'full local command preserves TERM status 143'
assert_eq "$PRIOR_FULL_OUTPUT_SHA256" "$(sha256sum "$GENERATED_TEST_OUTPUT" | cut -d' ' -f1)" 'cancelled full flow preserves the prior valid output byte-for-byte'
assert_initial_strict_secrets_redacted "$full_cancel_log" 'cancelled full flow'
assert_full_repackage_cleanup 'cancelled full flow'
if [[ -f "$FULL_CHILD_PID_FILE" ]] && ! kill -0 "$(<"$FULL_CHILD_PID_FILE")" 2>/dev/null; then
  pass 'full cancellation reaps the third-party build process'
else
  fail 'full cancellation reaps the third-party build process'
fi
# A failing cancellation assertion must not leave the diagnostic fixture alive.
# This is test sanitation after recording the immediate post-return state, not a
# grace period in the behavior under test.
if [[ -f "$FULL_CHILD_PID_FILE" ]] && kill -0 "$(<"$FULL_CHILD_PID_FILE")" 2>/dev/null; then
  printf '# cancellation diagnostic: top=%s returned=%s child=%s remained alive\n' \
    "$full_cancel_pid" "$full_cancel_status" "$(<"$FULL_CHILD_PID_FILE")"
  kill -TERM -- "-$full_cancel_pid" 2>/dev/null || true
  for _ in {1..200}; do
    kill -0 "$(<"$FULL_CHILD_PID_FILE")" 2>/dev/null || break
    sleep 0.05
  done
fi

FULL_DEBUG_ENV="$FIXTURE_DIR/full-debug-injection.sh"
FULL_DEBUG_LOG="$FIXTURE_DIR/full-debug-injection.log"
FULL_DEBUG_MARKER="$FIXTURE_DIR/full-debug-injection.marker"
export FULL_DEBUG_LOG FULL_DEBUG_MARKER
cat >"$FULL_DEBUG_ENV" <<'EOF'
set -T
trap '
  if [[ "${FULL_DEBUG_FIRED:-0}" != 1 && -n "${FULL_DEBUG_COMMAND:-}" && \
    "$BASH_COMMAND" == "$FULL_DEBUG_COMMAND" && \
    ( -z "${FULL_DEBUG_EXPECT_KIND:-}" || "${RUNTIME_CHILD_KIND:-}" == "$FULL_DEBUG_EXPECT_KIND" ) && \
    ( -z "${FULL_DEBUG_EXPECT_STATE:-}" || "${RUNTIME_CHILD_STATE:-}" == "$FULL_DEBUG_EXPECT_STATE" ) && \
    ( "${FULL_DEBUG_REQUIRE_STAGING:-0}" != 1 || -n "${ACTIVE_STAGING:-}" ) && \
    ( -z "${FULL_DEBUG_TRACKING_VARIABLE:-}" || "${tracking_variable:-}" == "$FULL_DEBUG_TRACKING_VARIABLE" ) ]]; then
    FULL_DEBUG_FIRED=1
    printf "TARGET:%s\nCOMMAND:%s\n" "$BASHPID" "$BASH_COMMAND" >>"$FULL_DEBUG_LOG"
    if [[ "$BASH_COMMAND" == *"\$!"* ]]; then
      printf "CHILD:%s\n" "$!" >>"$FULL_DEBUG_LOG"
    fi
    if [[ -n "${candidate:-}" ]]; then
      printf "CANDIDATE:%s\n" "$candidate" >>"$FULL_DEBUG_LOG"
    fi
    : >"$FULL_DEBUG_MARKER"
    trap - DEBUG
    kill -s "${FULL_DEBUG_SIGNAL:-TERM}" "$BASHPID"
  fi
' DEBUG
EOF

run_full_debug_signal_case() {
  local window_name=$1
  local debug_command=$2
  local signal_name=$3
  local expected_status=$4
  local repair_mode=${5:-success}
  local debug_log="$FIXTURE_DIR/full-debug-$window_name-$signal_name.log"
  local debug_status debug_child_pid= debug_candidate_path=
  local debug_expected_kind= debug_expected_state= debug_require_staging=0 debug_tracking_variable=

  case "$window_name" in
    download-clear-kind | download-reset-*)
      debug_expected_state=idle
      debug_require_staging=1
      ;;
    download-starting)
      debug_expected_kind=download
      debug_require_staging=1
      ;;
    packager-clear-kind | packager-reset-*)
      debug_expected_state=reaped
      debug_require_staging=1
      ;;
    packager-starting)
      debug_expected_kind=packager
      debug_require_staging=1
      ;;
    download-* | packager-*)
      debug_require_staging=1
      ;;
    repo-staging-*)
      debug_tracking_variable=ACTIVE_STAGING
      ;;
    output-temp-*)
      debug_tracking_variable=ACTIVE_OUTPUT_TEMP_DIR
      ;;
    coordinator-temp-trap)
      ;;
    coordinator-temp-*)
      debug_tracking_variable=ACTIVE_COORDINATOR_WORKSPACE
      ;;
  esac

  prepare_full_repackage_case
  seed_prior_full_output
  : >"$FULL_DEBUG_LOG"
  rm -f -- "$FULL_DEBUG_MARKER"
  if setsid env -u http_proxy -u https_proxy -u all_proxy \
    -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
    BASH_ENV="$FULL_DEBUG_ENV" \
    FULL_DEBUG_WINDOW="$window_name" \
    FULL_DEBUG_COMMAND="$debug_command" \
    FULL_DEBUG_EXPECT_KIND="$debug_expected_kind" \
    FULL_DEBUG_EXPECT_STATE="$debug_expected_state" \
    FULL_DEBUG_REQUIRE_STAGING="$debug_require_staging" \
    FULL_DEBUG_TRACKING_VARIABLE="$debug_tracking_variable" \
    FULL_DEBUG_SIGNAL="$signal_name" \
    FULL_REPAIR_MODE="$repair_mode" \
    DIFY_PIP_COMMAND="$fake_bin/pip-full-repackage" \
    DIFY_UV_COMMAND="$fake_bin/uv-full-repackage" \
    DIFY_PACKAGER_BINARY="$fake_bin/dify-packager-full" \
    DIFY_TARGET_ARCH=aarch64 \
    bash "$ROOT_DIR/plugin_repackaging.sh" local "$input_package" >"$debug_log" 2>&1; then
    debug_status=0
  else
    debug_status=$?
  fi
  if [[ -f "$FULL_DEBUG_MARKER" ]]; then
    pass "$window_name DEBUG injection reaches the exact pre-command window: $signal_name"
  else
    fail "$window_name DEBUG injection reaches the exact pre-command window: $signal_name"
  fi
  assert_eq "$expected_status" "$debug_status" "$window_name preserves $signal_name status $expected_status"
  assert_eq "$PRIOR_FULL_OUTPUT_SHA256" "$(sha256sum "$GENERATED_TEST_OUTPUT" | cut -d' ' -f1)" "$window_name $signal_name preserves the prior output"
  assert_initial_strict_secrets_redacted "$debug_log" "$window_name $signal_name output"
  assert_full_repackage_cleanup "$window_name $signal_name"
  debug_child_pid="$(sed -n 's/^CHILD://p' "$FULL_DEBUG_LOG" | tail -1)"
  if [[ -z "$debug_child_pid" || ! "$debug_child_pid" =~ ^[1-9][0-9]*$ ]] || \
    ! kill -0 "$debug_child_pid" 2>/dev/null; then
    pass "$window_name $signal_name leaves no tracked launch child"
  else
    fail "$window_name $signal_name leaves no tracked launch child"
    kill -TERM "$debug_child_pid" 2>/dev/null || true
    for _ in {1..200}; do
      kill -0 "$debug_child_pid" 2>/dev/null || break
      sleep 0.05
    done
  fi
  debug_candidate_path="$(sed -n 's/^CANDIDATE://p' "$FULL_DEBUG_LOG" | tail -1)"
  if [[ -z "$debug_candidate_path" || ! -e "$debug_candidate_path" && ! -L "$debug_candidate_path" ]]; then
    pass "$window_name $signal_name leaves no tracked temporary candidate"
  else
    fail "$window_name $signal_name leaves no tracked temporary candidate"
  fi
  if ps -eo args | grep -E '[p]ip-full-repackage|[u]v-full-repackage|[d]ify-packager-full' | grep -Fq "$FIXTURE_DIR"; then
    fail "$window_name $signal_name leaves no fixture bash, uv, packager, or sleep process"
  else
    pass "$window_name $signal_name leaves no fixture bash, uv, packager, or sleep process"
  fi
}

debug_signals=(HUP INT TERM)
debug_statuses=(129 130 143)
download_launch_window_names=(
  download-clear-kind
  download-reset-signal
  download-reset-status
  download-kind
  download-starting
  download-fork
  download-pid
)
download_launch_window_commands=(
  'RUNTIME_CHILD_KIND='
  'RUNTIME_PENDING_SIGNAL='
  'RUNTIME_PENDING_STATUS='
  'RUNTIME_CHILD_KIND=download'
  'RUNTIME_CHILD_STATE=starting'
  'DOWNLOAD_WHEELS_RUN_IN_PLACE=true download_wheels "$staging/download-requirements.txt" "$plugin_dir/wheels" "$TARGET_ARCH" "$python_version" "$staging/pip-bootstrap"'
  'ACTIVE_DOWNLOAD_PID=$!'
)
repair_launch_window_names=(repair-starting repair-fork repair-pid)
repair_launch_window_commands=(
  'repair_child_state=starting'
  'repair_one_pure_sdist_impl pip_command "$uv_command" "$requirement" "$canonical_name" "$python_version" "$repair_dir" "$socks_site_dir" "$repair_count"'
  'active_repair_pid=$!'
)
packager_launch_window_names=(
  packager-clear-kind
  packager-reset-signal
  packager-reset-status
  packager-kind
  packager-starting
  packager-fork
  packager-pid
)
packager_launch_window_commands=(
  'RUNTIME_CHILD_KIND='
  'RUNTIME_PENDING_SIGNAL='
  'RUNTIME_PENDING_STATUS='
  'RUNTIME_CHILD_KIND=packager'
  'RUNTIME_CHILD_STATE=starting'
  '"$PACKAGER_BINARY" plugin package "$plugin_dir" -o "$temp_output"'
  'ACTIVE_PACKAGER_PID=$!'
)
for debug_index in "${!debug_signals[@]}"; do
  for window_index in "${!download_launch_window_names[@]}"; do
    run_full_debug_signal_case \
      "${download_launch_window_names[$window_index]}" \
      "${download_launch_window_commands[$window_index]}" \
      "${debug_signals[$debug_index]}" "${debug_statuses[$debug_index]}" success
  done
  for window_index in "${!repair_launch_window_names[@]}"; do
    run_full_debug_signal_case \
      "${repair_launch_window_names[$window_index]}" \
      "${repair_launch_window_commands[$window_index]}" \
      "${debug_signals[$debug_index]}" "${debug_statuses[$debug_index]}" success
  done
  for window_index in "${!packager_launch_window_names[@]}"; do
    run_full_debug_signal_case \
      "${packager_launch_window_names[$window_index]}" \
      "${packager_launch_window_commands[$window_index]}" \
      "${debug_signals[$debug_index]}" "${debug_statuses[$debug_index]}" wheel-only
  done
done

tracked_temp_window_names=(repo-staging-register repo-staging-mkdir repo-staging-created)
tracked_temp_window_commands=(
  'printf -v "$tracking_variable" '\''%s'\'' "$candidate"'
  'mkdir -m 700 -- "$candidate"'
  'return 0'
)
output_temp_window_names=(output-temp-register output-temp-mkdir output-temp-created)
coordinator_temp_window_names=(coordinator-temp-register coordinator-temp-mkdir coordinator-temp-created)
for debug_index in "${!debug_signals[@]}"; do
  for window_index in "${!tracked_temp_window_names[@]}"; do
    run_full_debug_signal_case \
      "${tracked_temp_window_names[$window_index]}" \
      "${tracked_temp_window_commands[$window_index]}" \
      "${debug_signals[$debug_index]}" "${debug_statuses[$debug_index]}" wheel-only
    run_full_debug_signal_case \
      "${output_temp_window_names[$window_index]}" \
      "${tracked_temp_window_commands[$window_index]}" \
      "${debug_signals[$debug_index]}" "${debug_statuses[$debug_index]}" wheel-only
    run_full_debug_signal_case \
      "${coordinator_temp_window_names[$window_index]}" \
      "${tracked_temp_window_commands[$window_index]}" \
      "${debug_signals[$debug_index]}" "${debug_statuses[$debug_index]}" success
  done
  run_full_debug_signal_case \
    coordinator-temp-trap 'tracked_temp_creation_barrier coordinator-traps-installed' \
    "${debug_signals[$debug_index]}" "${debug_statuses[$debug_index]}" success
done

run_full_debug_signal_case before-packager 'output_non_publication_barrier before-packager' TERM 143 wheel-only
run_full_debug_signal_case after-packager 'output_non_publication_barrier after-packager' TERM 143 wheel-only
run_full_debug_signal_case before-publish 'output_non_publication_barrier before-publish' TERM 143 wheel-only

repackage_function_source="$(sed -n '/^repackage() {/,/^}/p' "$ROOT_DIR/plugin_repackaging.sh")"
if grep -Fq '"$staging/sdist-repair"' <<<"$repackage_function_source"; then
  fail 'production repackage keeps source repair state out of DrvFS staging'
else
  pass 'production repackage keeps source repair state out of DrvFS staging'
fi
if grep -Eq 'rm -rf -- "\$SCRIPT_DIR"|chmod[^\n]*"\$SCRIPT_DIR"' <<<"$(sed -n '/^cleanup_runtime() {/,/^}/p' "$ROOT_DIR/plugin_repackaging.sh")"; then
  fail 'runtime cleanup never deletes or changes permissions on the broad repository path'
else
  pass 'runtime cleanup never deletes or changes permissions on the broad repository path'
fi

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
assert_eq "$input_package_sha256" "$(sha256sum "$input_package" | cut -d' ' -f1)" 'legacy successful build leaves its input package unchanged'

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
assert_eq "$input_package_sha256" "$(sha256sum "$input_package" | cut -d' ' -f1)" 'SOCKS-repaired build leaves its input package unchanged'

rm -f -- "$GENERATED_TEST_OUTPUT"
if env -u http_proxy -u https_proxy -u all_proxy \
  -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
  DIFY_PIP_COMMAND="$fake_bin/pip-fail" \
  DIFY_UV_COMMAND="$fake_bin/uv-runtime" \
  DIFY_PACKAGER_BINARY="$fake_bin/dify-packager" \
  DIFY_TARGET_ARCH=aarch64 \
  bash "$ROOT_DIR/plugin_repackaging.sh" local "$input_package" >"$FIXTURE_DIR/pip-failure.log" 2>&1; then
  pip_failure_status=0
  fail 'pip failure stops repackaging'
else
  pip_failure_status=$?
  pass 'pip failure stops repackaging'
fi
assert_eq 1 "$pip_failure_status" 'pip failure returns ordinary failure status 1'
assert_file_missing "$GENERATED_TEST_OUTPUT" 'pip failure leaves no stale output'
assert_eq "$input_package_sha256" "$(sha256sum "$input_package" | cut -d' ' -f1)" 'pip failure leaves its input package unchanged'

rm -f -- "$GENERATED_TEST_OUTPUT"
if env -u http_proxy -u https_proxy -u all_proxy \
  -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
  FAKE_UV_EXIT=31 \
  DIFY_PIP_COMMAND="$fake_bin/pip-download" \
  DIFY_UV_COMMAND="$fake_bin/uv-runtime" \
  DIFY_PACKAGER_BINARY="$fake_bin/dify-packager" \
  DIFY_TARGET_ARCH=aarch64 \
  bash "$ROOT_DIR/plugin_repackaging.sh" local "$input_package" >"$FIXTURE_DIR/uv-failure.log" 2>&1; then
  uv_failure_status=0
  fail 'uv validation failure stops repackaging'
else
  uv_failure_status=$?
  pass 'uv validation failure stops repackaging'
fi
assert_eq 1 "$uv_failure_status" 'uv validation failure returns ordinary failure status 1'
assert_file_missing "$GENERATED_TEST_OUTPUT" 'uv failure leaves no stale output'
assert_eq "$input_package_sha256" "$(sha256sum "$input_package" | cut -d' ' -f1)" 'uv failure leaves its input package unchanged'

rm -f -- "$GENERATED_TEST_OUTPUT"
if env -u http_proxy -u https_proxy -u all_proxy \
  -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
  DIFY_PIP_COMMAND="$fake_bin/pip-download" \
  DIFY_UV_COMMAND="$fake_bin/uv-runtime" \
  DIFY_PACKAGER_BINARY="$fake_bin/packager-fail" \
  DIFY_TARGET_ARCH=aarch64 \
  bash "$ROOT_DIR/plugin_repackaging.sh" local "$input_package" >"$FIXTURE_DIR/packager-failure.log" 2>&1; then
  packager_failure_status=0
  fail 'packager failure stops repackaging'
else
  packager_failure_status=$?
  pass 'packager failure stops repackaging'
fi
assert_eq 1 "$packager_failure_status" 'packager failure returns ordinary failure status 1'
assert_file_missing "$GENERATED_TEST_OUTPUT" 'packager failure leaves no stale output'
assert_eq "$input_package_sha256" "$(sha256sum "$input_package" | cut -d' ' -f1)" 'packager failure leaves its input package unchanged'

remote_test_id="repackaging-test-${BASHPID}"
github_asset="${remote_test_id}.difypkg"
github_download="$ROOT_DIR/${remote_test_id}-v-test.difypkg"
github_offline="$ROOT_DIR/${remote_test_id}-v-test-offline.difypkg"
GENERATED_REMOTE_FILES+=("$github_download" "$github_offline")
python3 - "$github_offline" <<'PY'
from zipfile import ZipFile
import sys
with ZipFile(sys.argv[1], "w") as archive:
    archive.writestr("previous.txt", "previous valid GitHub offline package\n")
PY
github_offline_sha256="$(sha256sum "$github_offline" | cut -d' ' -f1)"
if PATH="$fake_bin:$PATH" \
  DIFY_UV_COMMAND="$fake_bin/uv-runtime" \
  DIFY_PACKAGER_BINARY="$fake_bin/dify-packager" \
  bash "$ROOT_DIR/plugin_repackaging.sh" github owner/repository v-test "$github_asset" >"$FIXTURE_DIR/github-download-failure.log" 2>&1; then
  fail 'GitHub download failure stops repackaging'
else
  pass 'GitHub download failure stops repackaging'
fi
assert_eq "$github_offline_sha256" "$(sha256sum "$github_offline" | cut -d' ' -f1)" 'GitHub download failure preserves the prior valid offline output'

market_author="${remote_test_id}-author"
market_download="$ROOT_DIR/${market_author}-plugin_0.0.1.difypkg"
market_offline="$ROOT_DIR/${market_author}-plugin_0.0.1-offline.difypkg"
GENERATED_REMOTE_FILES+=("$market_download" "$market_offline")
python3 - "$market_offline" <<'PY'
from zipfile import ZipFile
import sys
with ZipFile(sys.argv[1], "w") as archive:
    archive.writestr("previous.txt", "previous valid Marketplace offline package\n")
PY
market_offline_sha256="$(sha256sum "$market_offline" | cut -d' ' -f1)"
if PATH="$fake_bin:$PATH" \
  DIFY_UV_COMMAND="$fake_bin/uv-runtime" \
  DIFY_PACKAGER_BINARY="$fake_bin/dify-packager" \
  bash "$ROOT_DIR/plugin_repackaging.sh" market "$market_author" plugin 0.0.1 >"$FIXTURE_DIR/market-download-failure.log" 2>&1; then
  fail 'Marketplace download failure stops repackaging'
else
  pass 'Marketplace download failure stops repackaging'
fi
assert_eq "$market_offline_sha256" "$(sha256sum "$market_offline" | cut -d' ' -f1)" 'Marketplace download failure preserves the prior valid offline output'

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

assert_file_contains "$ROOT_DIR/README.md" 'DIFY_AUTO_BUILD_PURE_SDIST=0' 'README documents the pure-sdist repair switch'
assert_file_contains "$ROOT_DIR/README.md" '第三方 PEP 517' 'README warns that source repair executes third-party build code'
assert_file_contains "$ROOT_DIR/README.md" 'none-any' 'README documents the universal pure-wheel admission boundary'
assert_file_contains "$ROOT_DIR/README.md" '原生扩展' 'README documents that native source builds remain unsupported'
assert_file_contains "$ROOT_DIR/README.md" '认证索引' 'README documents the authenticated-index source-repair limitation'
assert_file_contains "$ROOT_DIR/README.md" '/tmp' 'README documents private Linux temporary state'
assert_file_contains "$ROOT_DIR/README.md" 'DrvFS' 'README explains the WSL DrvFS boundary'
assert_file_contains "$ROOT_DIR/README.md" 'Conda' 'README promises not to mutate the caller Conda environment'
assert_file_contains "$ROOT_DIR/README.md" 'records[all]' 'README uses records/docopt only as a generic behavior example'
assert_file_contains "$ROOT_DIR/README.md" 'docopt' 'README includes the generic missing-wheel example'
assert_file_contains "$ROOT_DIR/README.md" '原子替换' 'README documents atomic final-output publication'
assert_file_contains "$ROOT_DIR/README.md" '保留已有' 'README documents prior-output preservation on failure'

printf '%s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
((FAIL_COUNT == 0))
