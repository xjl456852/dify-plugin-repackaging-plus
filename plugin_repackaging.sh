#!/usr/bin/env bash
# author: xiejianglei
set -Eeuo pipefail

GITHUB_API_URL="${GITHUB_API_URL:-https://github.com}"
MARKETPLACE_API_URL="${MARKETPLACE_API_URL:-https://marketplace.dify.ai}"
PIP_MIRROR_URL="${PIP_MIRROR_URL:-https://mirrors.aliyun.com/pypi/simple}"
UV_MIN_VERSION=0.7.21
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

uv_version_at_least() {
  local installed=$1 required=$2
  local installed_major installed_minor installed_patch
  local required_major required_minor required_patch

  IFS=. read -r installed_major installed_minor installed_patch <<<"$installed"
  IFS=. read -r required_major required_minor required_patch <<<"$required"
  [[ "$installed_major" =~ ^[0-9]+$ && "$installed_minor" =~ ^[0-9]+$ && "$installed_patch" =~ ^[0-9]+$ ]] || return 1
  [[ "$required_major" =~ ^[0-9]+$ && "$required_minor" =~ ^[0-9]+$ && "$required_patch" =~ ^[0-9]+$ ]] || return 1

  if ((10#$installed_major != 10#$required_major)); then
    ((10#$installed_major > 10#$required_major))
  elif ((10#$installed_minor != 10#$required_minor)); then
    ((10#$installed_minor > 10#$required_minor))
  else
    ((10#$installed_patch >= 10#$required_patch))
  fi
}

check_uv_version() {
  local uv_command=$1
  local version_output installed_version

  version_output="$("$uv_command" --version)" || {
    printf 'failed to read uv version: %s\n' "$uv_command" >&2
    return 1
  }
  if [[ "$version_output" =~ (^|[[:space:]])([0-9]+\.[0-9]+\.[0-9]+)($|[[:space:]]) ]]; then
    installed_version=${BASH_REMATCH[2]}
  else
    printf 'unable to parse uv version: %s\n' "$version_output" >&2
    return 1
  fi
  if ! uv_version_at_least "$installed_version" "$UV_MIN_VERSION"; then
    printf 'uv %s or newer is required (found %s)\n' "$UV_MIN_VERSION" "$installed_version" >&2
    return 1
  fi
}

normalize_python_version() {
  local version=$1

  if [[ "$version" =~ ^([0-9]+)\.([0-9]+)(\.[0-9]+)?$ ]]; then
    printf '%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  else
    printf 'unsupported Python version: %s (expected MAJOR.MINOR or MAJOR.MINOR.PATCH)\n' "$version" >&2
    return 1
  fi
}

python_abi() {
  local version

  version="$(normalize_python_version "$1")"
  version=${version//./}
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

detect_socks_proxy() {
  local variable_name proxy_url scheme

  for variable_name in https_proxy HTTPS_PROXY http_proxy HTTP_PROXY all_proxy ALL_PROXY; do
    proxy_url=${!variable_name:-}
    [[ -n "$proxy_url" && "$proxy_url" == *://* ]] || continue
    scheme=${proxy_url%%://*}
    case "${scheme,,}" in
      socks4 | socks4a | socks5 | socks5h)
        printf '%s\n' "$proxy_url"
        return 0
        ;;
    esac
  done
  return 1
}

redact_url_for_log() {
  local url=$1

  python3 - "$url" <<'PY'
import sys
from urllib.parse import urlsplit, urlunsplit

try:
    parsed = urlsplit(sys.argv[1])
    if not parsed.scheme or not parsed.hostname:
        raise ValueError("URL must include a scheme and host")
    host = parsed.hostname
    if ":" in host:
        host = f"[{host}]"
    if parsed.port is not None:
        host = f"{host}:{parsed.port}"
    if parsed.username is not None or parsed.password is not None or "@" in parsed.netloc:
        host = f"***@{host}"
    print(urlunsplit((parsed.scheme, host, parsed.path, "", "")))
except (TypeError, ValueError):
    print("<redacted-url>")
PY
}

redact_pip_log() {
  python3 /dev/fd/3 3<<'PY'
import re
import sys
from urllib.parse import urlsplit, urlunsplit


url_pattern = re.compile(
    r"(?i)(?:https?|socks(?:4a?|5h?))://[^\s<>'\"]+"
)


def redact_url(match):
    raw_url = match.group(0)
    trailing = ""
    while raw_url and raw_url[-1] in ".,;)":
        trailing = raw_url[-1] + trailing
        raw_url = raw_url[:-1]
    try:
        parsed = urlsplit(raw_url)
        if not parsed.scheme or not parsed.hostname:
            raise ValueError("URL must include a scheme and host")
        host = parsed.hostname
        if ":" in host:
            host = f"[{host}]"
        if parsed.port is not None:
            host = f"{host}:{parsed.port}"
        if parsed.username is not None or parsed.password is not None or "@" in parsed.netloc:
            host = f"***@{host}"
        safe_url = urlunsplit((parsed.scheme, host, parsed.path, "", ""))
    except (TypeError, ValueError):
        safe_url = "<redacted-url>"
    return safe_url + trailing


for line in sys.stdin:
    sys.stdout.write(url_pattern.sub(redact_url, line))
PY
}

extract_missing_requirement() {
  local pip_output_file=$1

  python3 - "$pip_output_file" <<'PY'
from pathlib import Path
import re
import sys


MAX_PIP_OUTPUT_BYTES = 16 * 1024 * 1024
path = Path(sys.argv[1])
try:
    if not path.is_file() or path.stat().st_size > MAX_PIP_OUTPUT_BYTES:
        raise ValueError("invalid pip output file")
    log = path.read_text(encoding="utf-8", errors="replace")
except (OSError, ValueError):
    raise SystemExit(1)

missing_version_matches = list(re.finditer(
    r"^[ \t]*(?:ERROR:[ \t]*)?Could not find a version that satisfies the requirement "
    r"(.+?) \(from versions: none\)[ \t\r]*$",
    log,
    re.MULTILINE,
))
missing_distribution_matches = list(re.finditer(
    r"^[ \t]*(?:ERROR:[ \t]*)?No matching distribution found for (.+?)[ \t\r]*$",
    log,
    re.MULTILINE,
))
if len(missing_version_matches) != 1 or len(missing_distribution_matches) != 1:
    raise SystemExit(1)

diagnostic_parts = []
cursor = 0
for match in sorted(
    (missing_version_matches[0], missing_distribution_matches[0]),
    key=lambda item: item.start(),
):
    diagnostic_parts.append(log[cursor:match.start()])
    cursor = match.end()
diagnostic_parts.append(log[cursor:])
diagnostics = "".join(diagnostic_parts)

benign_progress_patterns = tuple(re.compile(pattern) for pattern in (
    r"Looking in indexes: \S+(?:,[ \t]+\S+)*",
    r"Looking in links: .+",
    r"Collecting .+",
    r"(?:Using cached|Downloading|Processing) .+",
    r"INFO: pip (?:is|is still) looking at multiple versions of .+",
    r"INFO: This is taking longer than usual\..+",
    r"(?:[━█▉▊▋▌▍▎▏#=><.\-]+[ \t]+)?"
    r"\d+(?:\.\d+)?/\d+(?:\.\d+)?[ \t]+(?:bytes|kB|MB|GB)"
    r"(?:[ \t]+\d+(?:\.\d+)?[ \t]+(?:kB|MB|GB)/s)?"
    r"(?:[ \t]+(?:eta[ \t]+)?(?:\d+:\d+(?::\d+)?|-:--:--))?",
))
if any(
    ord(character) < 32 and character not in "\n\t\r"
    for character in diagnostics
) or "\x7f" in diagnostics:
    raise SystemExit(1)
for diagnostic_line in diagnostics.splitlines():
    if not diagnostic_line.strip(" \t\r"):
        continue
    diagnostic_line = diagnostic_line.strip(" \t\r")
    if not any(pattern.fullmatch(diagnostic_line) for pattern in benign_progress_patterns):
        raise SystemExit(1)

dependency_context = re.compile(r"\s+\(from [^()\r\n]+\)\s*$", re.IGNORECASE)
requirement_pattern = re.compile(
    r"^\s*(?P<name>[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?)"
    r"(?:\s*(?P<spec>"
    r"(?:===|==|!=|~=|<=|>=|<|>)\s*[A-Za-z0-9][A-Za-z0-9.!+_*-]*"
    r"(?:\s*,\s*(?:===|==|!=|~=|<=|>=|<|>)\s*[A-Za-z0-9][A-Za-z0-9.!+_*-]*)*"
    r"))?\s*$"
)


def normalize_requirement(value, strip_context=False):
    if strip_context:
        while True:
            stripped = dependency_context.sub("", value)
            if stripped == value:
                break
            value = stripped
    if any(ord(character) < 32 or ord(character) == 127 for character in value):
        raise ValueError("control character in requirement")
    match = requirement_pattern.fullmatch(value)
    if match is None:
        raise ValueError("unsupported requirement")
    name = re.sub(r"[-_.]+", "-", match.group("name")).lower()
    spec = match.group("spec") or ""
    spec = re.sub(r"\s+", "", spec)
    return name + spec


try:
    first = normalize_requirement(missing_version_matches[0].group(1), strip_context=True)
    second = normalize_requirement(missing_distribution_matches[0].group(1))
except ValueError:
    raise SystemExit(1)
if first != second:
    raise SystemExit(1)
print(first)
PY
}

detect_manifest_python_version() {
  local manifest_file=$1
  local detected

  [[ -f "$manifest_file" ]] || return 1
  detected="$(
    awk '
      function indentation(line, first_non_space) {
        first_non_space = match(line, /[^[:space:]]/)
        return first_non_space ? first_non_space - 1 : length(line)
      }
      {
        line = $0
        sub(/[[:space:]]+#.*$/, "", line)
        if (line ~ /^[[:space:]]*meta[[:space:]]*:[[:space:]]*$/) {
          in_meta = 1
          meta_indent = indentation(line)
          next
        }
        if (in_meta && line !~ /^[[:space:]]*$/) {
          current_indent = indentation(line)
          if (current_indent <= meta_indent) {
            in_meta = 0
            in_runner = 0
          } else if (line ~ /^[[:space:]]*runner[[:space:]]*:[[:space:]]*$/) {
            in_runner = 1
            runner_indent = current_indent
            next
          }
        }
        if (in_runner && line !~ /^[[:space:]]*$/) {
          current_indent = indentation(line)
          if (current_indent <= runner_indent) {
            in_runner = 0
          } else if (line ~ /^[[:space:]]*version[[:space:]]*:/) {
            sub(/^[[:space:]]*version[[:space:]]*:[[:space:]]*/, "", line)
            sub(/[[:space:]]+$/, "", line)
            first = substr(line, 1, 1)
            last = substr(line, length(line), 1)
            if ((first == "\"" && last == "\"") || (first == "\047" && last == "\047")) {
              line = substr(line, 2, length(line) - 2)
            }
            print line
            exit
          }
        }
      }
    ' "$manifest_file"
  )"

  [[ -n "$detected" ]] || return 1
  normalize_python_version "$detected" 2>/dev/null
}

detect_python_version() {
  local plugin_dir=$1
  local requested=${DIFY_PYTHON_VERSION:-}
  local detected=

  if [[ -n "$requested" ]]; then
    normalize_python_version "$requested"
    return
  fi

  if detected="$(detect_manifest_python_version "$plugin_dir/manifest.yaml")"; then
    :
  elif [[ -f "$plugin_dir/.python-version" ]]; then
    detected="$(tr -d '[:space:]' <"$plugin_dir/.python-version")"
  elif [[ -f "$plugin_dir/pyproject.toml" ]]; then
    detected="$(
      sed -nE \
        's/^[[:space:]]*requires-python[[:space:]]*=[[:space:]]*"[^0-9]*([0-9]+\.[0-9]+).*"/\1/p' \
        "$plugin_dir/pyproject.toml" | head -n1
    )"
  fi

  normalize_python_version "${detected:-3.12}"
}

export_requirements_from_uv() {
  local plugin_dir=$1
  local output=$2
  local uv_command=${DIFY_UV_COMMAND:-uv}
  local -a args=(
    export
    --format requirements.txt
    --no-default-groups
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

sanitize_pyproject_for_runtime() {
  local pyproject_file=$1
  local temporary_file

  [[ -f "$pyproject_file" ]] || return 0
  temporary_file="$(mktemp "$(dirname "$pyproject_file")/.pyproject.runtime.XXXXXX")"
  awk '
    function array_delta(line,    i, character, quote, escaped, delta) {
      quote = ""
      escaped = 0
      delta = 0
      for (i = 1; i <= length(line); i++) {
        character = substr(line, i, 1)
        if (quote == "double") {
          if (escaped) {
            escaped = 0
          } else if (character == "\\") {
            escaped = 1
          } else if (character == "\"") {
            quote = ""
          }
        } else if (quote == "single") {
          if (character == sprintf("%c", 39)) {
            quote = ""
          }
        } else if (character == "#") {
          break
        } else if (character == "\"") {
          quote = "double"
        } else if (character == sprintf("%c", 39)) {
          quote = "single"
        } else if (character == "[") {
          delta++
        } else if (character == "]") {
          delta--
        }
      }
      return delta
    }
    {
      if (skipping_dependency_groups) {
        if ($0 ~ /^[[:space:]]*\[/) {
          skipping_dependency_groups = 0
        } else {
          next
        }
      }
      if ($0 ~ /^[[:space:]]*\[dependency-groups\][[:space:]]*$/) {
        skipping_dependency_groups = 1
        next
      }
      if (skipping_legacy_group) {
        legacy_group_depth += array_delta($0)
        if (legacy_group_depth <= 0) {
          skipping_legacy_group = 0
        }
        next
      }
      if ($0 ~ /^[[:space:]]*\[/) {
        in_tool_uv = ($0 ~ /^[[:space:]]*\[tool\.uv\][[:space:]]*$/)
        print
        next
      }
      if (in_tool_uv && $0 ~ /^[[:space:]]*(dev-dependencies|default-groups)[[:space:]]*=/) {
        legacy_group_depth = array_delta($0)
        if (legacy_group_depth > 0) {
          skipping_legacy_group = 1
        }
        next
      }
      print
    }
  ' "$pyproject_file" >"$temporary_file"
  mv -- "$temporary_file" "$pyproject_file"
}

configure_pyproject_environment() {
  local pyproject_file=$1
  local target_arch=$2
  local python_version=$3
  local platform_machine marker temporary_file

  [[ -f "$pyproject_file" ]] || return 0
  case "$(normalize_arch "$target_arch")" in
    x86_64)
      platform_machine=x86_64
      ;;
    aarch64)
      platform_machine=aarch64
      ;;
  esac
  marker="sys_platform == 'linux' and platform_machine == '$platform_machine' and python_version == '$python_version'"
  temporary_file="$(mktemp "$(dirname "$pyproject_file")/.pyproject.environment.XXXXXX")"

  awk -v marker="$marker" '
    function array_delta(line,    i, character, quote, escaped, delta) {
      quote = ""
      escaped = 0
      delta = 0
      for (i = 1; i <= length(line); i++) {
        character = substr(line, i, 1)
        if (quote == "double") {
          if (escaped) {
            escaped = 0
          } else if (character == "\\") {
            escaped = 1
          } else if (character == "\"") {
            quote = ""
          }
        } else if (quote == "single") {
          if (character == sprintf("%c", 39)) {
            quote = ""
          }
        } else if (character == "#") {
          break
        } else if (character == "\"") {
          quote = "double"
        } else if (character == sprintf("%c", 39)) {
          quote = "single"
        } else if (character == "[") {
          delta++
        } else if (character == "]") {
          delta--
        }
      }
      return delta
    }
    function print_environment() {
      print "environments = ["
      print "  \"" marker "\","
      print "]"
    }
    {
      if (skipping_environment) {
        environment_depth += array_delta($0)
        if (environment_depth <= 0) {
          skipping_environment = 0
        }
        next
      }
      if ($0 ~ /^[[:space:]]*\[tool\.uv\][[:space:]]*$/) {
        print
        print_environment()
        inserted_environment = 1
        in_tool_uv = 1
        next
      }
      if (in_tool_uv && $0 ~ /^[[:space:]]*\[/) {
        in_tool_uv = 0
      }
      if (in_tool_uv && $0 ~ /^[[:space:]]*environments[[:space:]]*=/) {
        environment_depth = array_delta($0)
        if (environment_depth > 0) {
          skipping_environment = 1
        }
        next
      }
      print
    }
    END {
      if (!inserted_environment) {
        print ""
        print "[tool.uv]"
        print_environment()
      }
    }
  ' "$pyproject_file" >"$temporary_file"
  mv -- "$temporary_file" "$pyproject_file"
}

write_offline_metadata() {
  local plugin_dir=$1
  local clean_requirements=$2
  local target_arch=${3:-${TARGET_ARCH:-$(normalize_arch "$(uname -m)")}}
  local python_version=${4:-$(detect_python_version "$plugin_dir")}

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

  sanitize_pyproject_for_runtime "$plugin_dir/pyproject.toml"
  configure_pyproject_environment "$plugin_dir/pyproject.toml" "$target_arch" "$python_version"
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

pip_has_pysocks() {
  local pip_command_name=$1
  local -n selected_pip_command=$pip_command_name

  "${selected_pip_command[@]}" show PySocks >/dev/null 2>&1
}

resolve_pysocks_wheel() {
  local simple_page=$1
  local simple_url=$2

  python3 - "$simple_page" "$simple_url" <<'PY'
from html.parser import HTMLParser
from pathlib import Path
import re
import sys
from urllib.parse import parse_qs, unquote, urljoin, urlsplit, urlunsplit


class LinkParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links = []

    def handle_starttag(self, tag, attrs):
        if tag.lower() != "a":
            return
        for name, value in attrs:
            if name.lower() == "href" and value:
                self.links.append(value)


parser = LinkParser()
parser.feed(Path(sys.argv[1]).read_text(encoding="utf-8"))
target = "pysocks-1.7.1-py3-none-any.whl"
for href in parser.links:
    absolute = urljoin(sys.argv[2], href)
    parsed = urlsplit(absolute)
    if parsed.scheme.lower() not in {"http", "https"} or not parsed.netloc:
        continue
    filename = unquote(parsed.path.rsplit("/", 1)[-1]).lower()
    if filename != target:
        continue
    hashes = parse_qs(parsed.fragment).get("sha256", [])
    if hashes and not re.fullmatch(r"[0-9a-fA-F]{64}", hashes[0]):
        raise SystemExit("invalid sha256 fragment for PySocks wheel")
    wheel_url = urlunsplit((parsed.scheme, parsed.netloc, parsed.path, parsed.query, ""))
    print(f"{wheel_url}\t{hashes[0].lower() if hashes else '-'}")
    raise SystemExit(0)
raise SystemExit("PySocks 1.7.1 universal wheel not found in simple index")
PY
}

file_sha256() {
  python3 - "$1" <<'PY'
from hashlib import sha256
from pathlib import Path
import sys

digest = sha256()
with Path(sys.argv[1]).open("rb") as source:
    for chunk in iter(lambda: source.read(1024 * 1024), b""):
        digest.update(chunk)
print(digest.hexdigest())
PY
}

prepare_pip_socks_support() {
  local pip_command_name=$1
  local bootstrap_dir=$2
  local result_name=$3
  local -n selected_pip_command=$pip_command_name
  local -n result=$result_name
  local proxy_url simple_url simple_page wheel_record wheel_url expected_sha256
  local wheel_file site_dir actual_sha256 safe_proxy_url safe_simple_url safe_wheel_url

  result=
  if ! proxy_url="$(detect_socks_proxy)"; then
    return 0
  fi
  if pip_has_pysocks "$pip_command_name"; then
    return 0
  fi
  case "${DIFY_AUTO_FIX_SOCKS:-1}" in
    0 | false | FALSE | no | NO)
      safe_proxy_url="$(redact_url_for_log "$proxy_url")"
      printf 'pip requires PySocks for proxy %s; automatic repair is disabled by DIFY_AUTO_FIX_SOCKS\n' "$safe_proxy_url" >&2
      return 1
      ;;
  esac
  command -v curl >/dev/null 2>&1 || {
    printf 'curl is required to repair missing pip SOCKS support without modifying the Python environment\n' >&2
    return 1
  }

  simple_url="${PIP_MIRROR_URL%/}/pysocks/"
  safe_proxy_url="$(redact_url_for_log "$proxy_url")"
  safe_simple_url="$(redact_url_for_log "$simple_url")"
  simple_page="$bootstrap_dir/pysocks-simple.html"
  wheel_file="$bootstrap_dir/PySocks-1.7.1-py3-none-any.whl"
  site_dir="$bootstrap_dir/site-packages"
  mkdir -p "$bootstrap_dir" "$site_dir"
  printf 'Preparing temporary pip SOCKS support for %s ...\n' "$safe_proxy_url"
  if ! curl --fail --location --show-error --output "$simple_page" "$simple_url"; then
    printf 'failed to download the PySocks simple index from %s\n' "$safe_simple_url" >&2
    return 1
  fi
  if ! wheel_record="$(resolve_pysocks_wheel "$simple_page" "$simple_url")"; then
    printf 'failed to locate PySocks 1.7.1 universal wheel in %s\n' "$safe_simple_url" >&2
    return 1
  fi
  wheel_url=${wheel_record%%$'\t'*}
  expected_sha256=${wheel_record#*$'\t'}
  safe_wheel_url="$(redact_url_for_log "$wheel_url")"
  if ! curl --fail --location --show-error --output "$wheel_file" "$wheel_url"; then
    printf 'failed to download temporary PySocks wheel from %s\n' "$safe_wheel_url" >&2
    return 1
  fi
  if [[ "$expected_sha256" != - ]]; then
    actual_sha256="$(file_sha256 "$wheel_file")"
    if [[ "$actual_sha256" != "$expected_sha256" ]]; then
      printf 'temporary PySocks wheel checksum mismatch: expected %s, got %s\n' \
        "$expected_sha256" "$actual_sha256" >&2
      return 1
    fi
  fi
  if ! env \
    -u http_proxy -u https_proxy -u all_proxy \
    -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    "${selected_pip_command[@]}" install \
      --disable-pip-version-check \
      --no-index \
      --no-deps \
      --target "$site_dir" \
      "$wheel_file"; then
    printf 'failed to install temporary PySocks support into %s\n' "$site_dir" >&2
    return 1
  fi
  result=$site_dir
}

report_wheel_download_failure() {
  local target_arch=$1
  local python_version=$2
  local abi=$3
  shift 3
  local platform_list safe_index_url

  platform_list="$(IFS=,; printf '%s' "$*")"
  safe_index_url="$(redact_url_for_log "$PIP_MIRROR_URL")"
  printf '%s\n' \
    'failed to download a complete binary wheel dependency set' \
    "Target Python: $python_version" \
    "Target ABI: $abi" \
    "Target architecture: $target_arch" \
    "Target platforms: $platform_list" \
    "Package index: $safe_index_url" \
    'Common causes: no compatible binary wheel for the target, conflicting version constraints, an additional package index is required, or the proxy/index is unreachable.' \
    'The packager will not compile source distributions or fall back to the build host architecture.' >&2
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

validate_pip_bootstrap_dir() {
  local bootstrap_dir=$1
  local parent

  if [[ -z "$bootstrap_dir" || "$(basename -- "$bootstrap_dir")" != pip-bootstrap ]]; then
    printf 'safe pip bootstrap directory is required for SOCKS repair\n' >&2
    return 1
  fi
  parent="$(dirname -- "$bootstrap_dir")"
  if [[ "$parent" == / || "$parent" == . || "$parent" == "$bootstrap_dir" ]]; then
    printf 'safe pip bootstrap directory is required for SOCKS repair\n' >&2
    return 1
  fi
}

run_pip_with_socks_retry() {
  local pip_command_name=$1
  local download_args_name=$2
  local socks_site_dir=$3
  local pip_output_log=$4
  local allow_legacy_retry=${5:-false}
  local -n selected_pip_command=$pip_command_name
  local -n selected_download_args=$download_args_name
  local pip_status retry_status
  local truststore_error="TypeError: PoolKey.__new__() got an unexpected keyword argument 'key_proxy_ssl_context'"

  : >"$pip_output_log"
  if [[ -n "$socks_site_dir" ]]; then
    if PYTHONPATH="$socks_site_dir${PYTHONPATH:+:$PYTHONPATH}" \
      "${selected_pip_command[@]}" "${selected_download_args[@]}" \
      >"$pip_output_log" 2>&1; then
      pip_status=0
    else
      pip_status=$?
    fi
  else
    if "${selected_pip_command[@]}" "${selected_download_args[@]}" \
      >"$pip_output_log" 2>&1; then
      pip_status=0
    else
      pip_status=$?
    fi
  fi
  redact_pip_log <"$pip_output_log" >&2 || printf 'pip output could not be displayed safely\n' >&2
  if ((pip_status == 0)); then
    return 0
  fi
  if [[ "$allow_legacy_retry" != true ]] || ! grep -Fxq -- "$truststore_error" "$pip_output_log"; then
    return "$pip_status"
  fi

  printf '%s\n' \
    'pip SOCKS support is incompatible with its truststore proxy context; retrying once with PIP_USE_DEPRECATED=legacy-certs.' >&2
  : >"$pip_output_log"
  if [[ -n "$socks_site_dir" ]]; then
    if PIP_USE_DEPRECATED=legacy-certs \
      PYTHONPATH="$socks_site_dir${PYTHONPATH:+:$PYTHONPATH}" \
      "${selected_pip_command[@]}" "${selected_download_args[@]}" \
      >"$pip_output_log" 2>&1; then
      retry_status=0
    else
      retry_status=$?
    fi
  else
    if PIP_USE_DEPRECATED=legacy-certs \
      "${selected_pip_command[@]}" "${selected_download_args[@]}" \
      >"$pip_output_log" 2>&1; then
      retry_status=0
    else
      retry_status=$?
    fi
  fi
  redact_pip_log <"$pip_output_log" >&2 || printf 'pip retry output could not be displayed safely\n' >&2
  return "$retry_status"
}

download_wheels_once() {
  local requirements=$1
  local wheels_dir=$2
  local target_arch=$3
  local python_version=$4
  local pip_output_log=$5
  local bootstrap_dir=${6:-}
  local local_wheels_dir=${7:-}
  local abi platform socks_proxy_url= socks_site_dir=
  local -a pip_command=()
  local -a platform_args=()
  local -a download_args=()
  local -a local_wheel_args=()

  : >"$pip_output_log" || return
  if [[ -n "$local_wheels_dir" ]]; then
    if [[ ! -d "$local_wheels_dir" ]]; then
      printf 'local built-wheel directory not found: %s\n' "$local_wheels_dir" >&2
      return 1
    fi
    local_wheels_dir="$(realpath -- "$local_wheels_dir")" || return
    local_wheel_args=(--find-links "$local_wheels_dir")
  fi
  socks_proxy_url="$(detect_socks_proxy)" || true
  if [[ -n "$socks_proxy_url" ]]; then
    validate_pip_bootstrap_dir "$bootstrap_dir" || return
  fi
  resolve_pip_command pip_command || return
  prepare_pip_socks_support pip_command "$bootstrap_dir" socks_site_dir || return
  abi="$(python_abi "$python_version")" || return
  while IFS= read -r platform; do
    if [[ -n "$platform" ]]; then
      platform_args+=(--platform "$platform")
    fi
  done < <(default_platforms "$target_arch")

  download_args=(
    download
    --disable-pip-version-check
    --index-url "$PIP_MIRROR_URL"
    "${local_wheel_args[@]}"
    --python-version "$python_version"
    --implementation cp
    --abi "$abi"
    "${platform_args[@]}"
    --only-binary=:all:
    --requirement "$requirements"
    --dest "$wheels_dir"
  )

  run_pip_with_socks_retry \
    pip_command \
    download_args \
    "$socks_site_dir" \
    "$pip_output_log" \
    "$([[ -n "$socks_proxy_url" ]] && printf true || printf false)"
}

download_wheels() {
  local requirements=$1
  local wheels_dir=$2
  local target_arch=$3
  local python_version=$4
  local bootstrap_dir=${5:-}
  local abi platform pip_output_log wheels_parent
  local -a platform_names=()

  reset_wheels_dir "$wheels_dir" || return
  if ! grep -Eq '^[[:space:]]*[^#[:space:]]' "$requirements"; then
    return 0
  fi
  abi="$(python_abi "$python_version")" || return
  while IFS= read -r platform; do
    if [[ -n "$platform" ]]; then
      platform_names+=("$platform")
    fi
  done < <(default_platforms "$target_arch")
  wheels_parent="$(dirname -- "$wheels_dir")"
  pip_output_log="$(mktemp "$wheels_parent/.pip-download.XXXXXX")" || return
  if download_wheels_once \
    "$requirements" \
    "$wheels_dir" \
    "$target_arch" \
    "$python_version" \
    "$pip_output_log" \
    "$bootstrap_dir"; then
    rm -f -- "$pip_output_log"
    return 0
  fi
  rm -f -- "$pip_output_log"
  report_wheel_download_failure \
    "$target_arch" \
    "$python_version" \
    "$abi" \
    "${platform_names[@]}"
  return 1
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

register_output_for_package() {
  local package_path=$1
  local package_filename package_name

  package_filename="$(basename "$package_path")"
  package_name="${package_filename%.*}"
  ACTIVE_OUTPUT="$SCRIPT_DIR/${package_name}-offline.difypkg"
  BUILD_SUCCEEDED=false
  rm -f -- "$ACTIVE_OUTPUT"
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
  check_uv_version "$uv_command"
  if [[ ! -f "$PACKAGER_BINARY" ]]; then
    printf 'Dify packager not found: %s\n' "$PACKAGER_BINARY" >&2
    return 1
  fi
  chmod +x "$PACKAGER_BINARY"
}

repackage() {
  local package_path=$1
  local package_filename staging plugin_dir output python_version
  local requires_wheel=false
  local requires_pyproject=false

  package_filename="$(basename "$package_path")"
  register_output_for_package "$package_path"
  output=$ACTIVE_OUTPUT

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
    "$python_version" \
    "$staging/pip-bootstrap"
  write_offline_metadata \
    "$plugin_dir" \
    "$staging/download-requirements.txt" \
    "$TARGET_ARCH" \
    "$python_version"

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
  register_output_for_package "$output"
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
  register_output_for_package "$output"
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
