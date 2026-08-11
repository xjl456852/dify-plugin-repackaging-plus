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
ACTIVE_DOWNLOAD_PID=
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
import unicodedata
from urllib.parse import urlsplit, urlunsplit


MAX_DISPLAY_INPUT_BYTES = 1024 * 1024
MAX_DISPLAY_OUTPUT_BYTES = MAX_DISPLAY_INPUT_BYTES + 64
TRUNCATION_MARKER = "\n[pip diagnostic output truncated]\n"
supported_scheme_pattern = re.compile(
    r"(?:https?|socks(?:4a?|5h?))://",
    re.IGNORECASE,
)
url_pattern = re.compile(
    supported_scheme_pattern.pattern + r"\S+",
    re.IGNORECASE,
)


def redact_url(match):
    if input_truncated and match.end() == len(text):
        return "<redacted-url>"
    raw_url = match.group(0)
    trailing = ""
    while raw_url and raw_url[-1] in "'\"].,;)}>":
        trailing = raw_url[-1] + trailing
        raw_url = raw_url[:-1]
    try:
        scheme_end = raw_url.find("://") + 3
        if supported_scheme_pattern.search(raw_url, scheme_end):
            return "<redacted-url>" + trailing
        if any(
            not character.isprintable()
            or unicodedata.category(character).startswith("C")
            or character in "<>\"\\"
            for character in raw_url
        ) or re.search(r"%(?![0-9A-Fa-f]{2})", raw_url):
            raise ValueError("unsafe character in URL")
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
    except (TypeError, UnicodeError, ValueError):
        safe_url = "<redacted-url>"
    return safe_url + trailing


raw_input = sys.stdin.buffer.read(MAX_DISPLAY_INPUT_BYTES + 1)
input_truncated = len(raw_input) > MAX_DISPLAY_INPUT_BYTES
raw_input = raw_input[:MAX_DISPLAY_INPUT_BYTES]
text = raw_input.decode("utf-8", errors="surrogateescape")
redacted = url_pattern.sub(redact_url, text)
safe_output = []
safe_output_bytes = 0
display_truncated = input_truncated
for character in redacted:
    if character in "\n\t":
        safe_character = character
    else:
        codepoint = ord(character)
        category = unicodedata.category(character)
        if 0xDC80 <= codepoint <= 0xDCFF:
            safe_character = f"\\x{codepoint - 0xDC00:02x}"
        elif character == "\r":
            safe_character = "\\r"
        elif not character.isprintable() or category.startswith("C") or category in {"Zl", "Zp"}:
            if codepoint < 0x80:
                safe_character = f"\\x{codepoint:02x}"
            elif codepoint <= 0xFFFF:
                safe_character = f"\\u{codepoint:04x}"
            else:
                safe_character = f"\\U{codepoint:08x}"
        else:
            safe_character = character
    encoded_size = len(safe_character.encode("utf-8"))
    if safe_output_bytes + encoded_size > MAX_DISPLAY_OUTPUT_BYTES:
        display_truncated = True
        break
    safe_output.append(safe_character)
    safe_output_bytes += encoded_size
if display_truncated:
    safe_output.append(TRUNCATION_MARKER)
sys.stdout.buffer.write("".join(safe_output).encode("utf-8"))
PY
}

extract_missing_requirement() {
  local pip_output_file=$1

  python3 - "$pip_output_file" <<'PY'
from pathlib import Path
import re
import sys
import unicodedata


MAX_PIP_OUTPUT_BYTES = 16 * 1024 * 1024
path = Path(sys.argv[1])
try:
    if not path.is_file() or path.stat().st_size > MAX_PIP_OUTPUT_BYTES:
        raise ValueError("invalid pip output file")
    log = path.read_text(encoding="utf-8")
except (OSError, UnicodeError, ValueError):
    raise SystemExit(1)

for character in log:
    if character in "\n\r\t":
        continue
    category = unicodedata.category(character)
    if not character.isprintable() or category.startswith("C") or category in {"Zl", "Zp"}:
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
for diagnostic_line in diagnostics.split("\n"):
    if not diagnostic_line.strip(" \t\r"):
        continue
    diagnostic_line = diagnostic_line.strip(" \t\r")
    if not any(pattern.fullmatch(diagnostic_line) for pattern in benign_progress_patterns):
        raise SystemExit(1)

dependency_context = re.compile(r"\s+\(from [^()\t\r\n]+\)\s*$", re.IGNORECASE)
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
    return name + spec, name


try:
    first, first_name = normalize_requirement(
        missing_version_matches[0].group(1), strip_context=True
    )
    second, second_name = normalize_requirement(missing_distribution_matches[0].group(1))
except ValueError:
    raise SystemExit(1)
if first != second or first_name != second_name:
    raise SystemExit(1)
print(f"{first}\t{first_name}")
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
    'Only validated pure Python universal wheels may be built from source; native source builds and build-host architecture fallbacks remain disabled.' >&2
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

task3_python() {
  env -u PYTHONPATH -u PYTHONHOME -u VIRTUAL_ENV python3 "$@"
}

reset_private_command_log() {
  local output_log=$1

  run_bounded_command_log "$output_log" :
}

run_bounded_command_log() {
  local output_log=$1
  shift
  local -a pipeline_status=()

  "$@" 2>&1 | task3_python -B /dev/fd/3 "$output_log" 3<<'PY'
import os
import stat
import sys


MAX_RAW_LOG_BYTES = 1024 * 1024
TRUNCATION_MARKER = b"\n[raw diagnostic output truncated]\n"
path = sys.argv[1]
try:
    existing = os.lstat(path)
    # COORDINATOR_LOG_PREOPEN_IDENTITY_CAPTURED
except FileNotFoundError:
    existing = None
if existing is not None and (
    stat.S_ISLNK(existing.st_mode)
    or not stat.S_ISREG(existing.st_mode)
    or existing.st_uid != os.geteuid()
    or existing.st_nlink != 1
    or stat.S_IMODE(existing.st_mode) != 0o600
):
    raise SystemExit(1)
open_flags = os.O_WRONLY | os.O_NOFOLLOW
if existing is None:
    open_flags |= os.O_CREAT | os.O_EXCL
descriptor = os.open(path, open_flags, 0o600)
written = 0
truncated = False


def write_all(contents):
    position = 0
    while position < len(contents):
        position += os.write(descriptor, contents[position:])


try:
    opened = os.fstat(descriptor)
    linked = os.lstat(path)
    if (
        not stat.S_ISREG(opened.st_mode)
        or opened.st_uid != os.geteuid()
        or opened.st_nlink != 1
        or (existing is not None and stat.S_IMODE(opened.st_mode) != 0o600)
        or (opened.st_dev, opened.st_ino) != (linked.st_dev, linked.st_ino)
        or stat.S_ISLNK(linked.st_mode)
        or not stat.S_ISREG(linked.st_mode)
        or linked.st_uid != os.geteuid()
        or linked.st_nlink != 1
        or stat.S_IMODE(linked.st_mode) != 0o600
        or (
            existing is not None
            and (existing.st_dev, existing.st_ino) != (opened.st_dev, opened.st_ino)
        )
    ):
        raise OSError("diagnostic log is not a regular file")
    os.fchmod(descriptor, 0o600)
    if stat.S_IMODE(os.fstat(descriptor).st_mode) != 0o600:
        raise OSError("diagnostic log is not private")
    os.ftruncate(descriptor, 0)
    after_truncate = os.lstat(path)
    if (after_truncate.st_dev, after_truncate.st_ino) != (opened.st_dev, opened.st_ino):
        raise OSError("diagnostic log identity changed")
    while True:
        chunk = sys.stdin.buffer.read(64 * 1024)
        if not chunk:
            break
        remaining = MAX_RAW_LOG_BYTES - written
        if remaining > 0:
            retained = chunk[:remaining]
            write_all(retained)
            written += len(retained)
        if len(chunk) > max(remaining, 0):
            truncated = True
    if truncated:
        write_all(TRUNCATION_MARKER)
finally:
    os.close(descriptor)
PY
  pipeline_status=("${PIPESTATUS[@]}")
  ((${pipeline_status[1]:-1} == 0)) || return "${pipeline_status[1]:-1}"
  return "${pipeline_status[0]:-1}"
}

run_supervised_command_log() {
  local output_log=$1
  local timeout_seconds=$2
  local supervisor_status
  shift 2

  REPAIR_SUPERVISOR_STARTING=true
  env -u PYTHONPATH -u PYTHONHOME -u VIRTUAL_ENV \
    python3 -B /dev/fd/3 "$output_log" "$timeout_seconds" "$@" 3<<'PY' &
import ctypes
import errno
import os
import select
import signal
import stat
import subprocess
import sys
import time


MAX_RAW_LOG_BYTES = 1024 * 1024
TRUNCATION_MARKER = b"\n[raw diagnostic output truncated]\n"
SUPERVISOR_ERROR_MARKER = b"\n[build process supervision failed]\n"
PR_SET_CHILD_SUBREAPER = 36
TERM_GRACE_SECONDS = 0.25
KILL_AFTER_SECONDS = 2.0

log_path = sys.argv[1]
timeout_seconds = int(sys.argv[2])
command = sys.argv[3:]
if not command or timeout_seconds < 1:
    raise SystemExit(125)

log_flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0)
log_descriptor = os.open(log_path, log_flags, 0o600)
written = 0
truncated = False
pipe_eof = False
process = None
pipe_descriptor = None
requested_signal = None


def write_all(contents):
    position = 0
    while position < len(contents):
        position += os.write(log_descriptor, contents[position:])


def retain_output(contents):
    global truncated, written
    remaining = MAX_RAW_LOG_BYTES - written
    if remaining > 0:
        retained = contents[:remaining]
        write_all(retained)
        written += len(retained)
    if len(contents) > max(remaining, 0):
        truncated = True


def drain_output(wait_seconds=0.0):
    global pipe_eof
    if pipe_descriptor is None or pipe_eof:
        return
    try:
        readable, _, _ = select.select([pipe_descriptor], [], [], max(wait_seconds, 0.0))
    except InterruptedError:
        return
    if not readable:
        return
    while True:
        try:
            contents = os.read(pipe_descriptor, 64 * 1024)
        except BlockingIOError:
            return
        except InterruptedError:
            continue
        if not contents:
            pipe_eof = True
            return
        retain_output(contents)


def read_process_identity(process_id):
    with open(f"/proc/{process_id}/stat", "rb") as stat_file:
        contents = stat_file.read(64 * 1024)
    closing_parenthesis = contents.rfind(b")")
    if closing_parenthesis < 0:
        raise ValueError("invalid /proc stat record")
    fields = contents[closing_parenthesis + 2:].split()
    if len(fields) <= 19:
        raise ValueError("short /proc stat record")
    return int(fields[1]), int(fields[19])


def process_snapshot():
    snapshot = {}
    try:
        entries = os.scandir("/proc")
    except OSError as error:
        raise RuntimeError("/proc is unavailable") from error
    with entries:
        for entry in entries:
            if not entry.name.isdecimal():
                continue
            try:
                process_id = int(entry.name)
                snapshot[process_id] = read_process_identity(process_id)
            except (FileNotFoundError, ProcessLookupError):
                continue
            except (OSError, ValueError) as error:
                # A vanished process is harmless; every other read failure is fail-closed.
                raise RuntimeError("cannot inspect process descendants") from error
    return snapshot


def descendants():
    snapshot = process_snapshot()
    found = {}
    frontier = {os.getpid()}
    while frontier:
        next_frontier = {
            process_id: starttime
            for process_id, (parent_id, starttime) in snapshot.items()
            if parent_id in frontier and process_id not in found
        }
        found.update(next_frontier)
        frontier = set(next_frontier)
    found.pop(os.getpid(), None)
    return found


def identity_matches(process_id, expected_starttime):
    try:
        _, current_starttime = read_process_identity(process_id)
    except (FileNotFoundError, ProcessLookupError):
        return False
    return current_starttime == expected_starttime


def signal_one_process(process_id, expected_starttime, selected_signal):
    if not identity_matches(process_id, expected_starttime):
        return
    pidfd_open = os.pidfd_open if hasattr(os, "pidfd_open") else None
    pidfd_send_signal = signal.pidfd_send_signal if hasattr(signal, "pidfd_send_signal") else None
    if pidfd_open is not None and pidfd_send_signal is not None:
        try:
            descriptor = pidfd_open(process_id, 0)
        except ProcessLookupError:
            return
        except PermissionError as error:
            raise RuntimeError("cannot signal build descendant") from error
        except OSError as error:
            if error.errno not in {errno.ENOSYS, errno.EINVAL, errno.EOPNOTSUPP}:
                raise RuntimeError("cannot bind build descendant pidfd") from error
        else:
            try:
                if not identity_matches(process_id, expected_starttime):
                    return
                pidfd_send_signal(descriptor, selected_signal, None, 0)
            except ProcessLookupError:
                return
            except PermissionError as error:
                raise RuntimeError("cannot signal build descendant pidfd") from error
            except OSError as error:
                if error.errno not in {errno.ENOSYS, errno.EINVAL, errno.EOPNOTSUPP}:
                    raise RuntimeError("cannot signal build descendant pidfd") from error
            else:
                return
            finally:
                os.close(descriptor)
    if not identity_matches(process_id, expected_starttime):
        return
    try:
        os.kill(process_id, selected_signal)
    except ProcessLookupError:
        return
    except PermissionError as error:
        raise RuntimeError("cannot signal build descendant") from error


def signal_processes(process_identities, selected_signal):
    for process_id, starttime in process_identities.items():
        signal_one_process(process_id, starttime, selected_signal)


def signal_original_group(selected_signal, _process_identities):
    if process is None:
        return
    # Popen cannot release/reuse this PID while poll() still reports it alive.
    # After the leader exits, descendants are signalled only through bound PID identities.
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, selected_signal)
    except ProcessLookupError:
        return
    except PermissionError as error:
        raise RuntimeError("cannot signal build process group") from error


def reap_children():
    if process is not None:
        process.poll()
    while True:
        try:
            child_id, _ = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            return
        except InterruptedError:
            continue
        if child_id == 0:
            return


def request_shutdown(signal_number, _frame):
    global requested_signal
    requested_signal = signal_number


def include_live_main(process_identities):
    if process is None or process.poll() is not None:
        return
    try:
        _, starttime = read_process_identity(process.pid)
    except (FileNotFoundError, ProcessLookupError):
        return
    process_identities[process.pid] = starttime


def stop_and_reap_descendants(cleanup_deadline):
    targets = descendants()
    include_live_main(targets)
    signal_original_group(signal.SIGTERM, targets)
    signal_processes(targets, signal.SIGTERM)
    term_deadline = min(cleanup_deadline, time.monotonic() + TERM_GRACE_SECONDS)
    while time.monotonic() < term_deadline:
        drain_output(0.02)
        reap_children()
        current = descendants()
        include_live_main(current)
        if not current:
            break
        time.sleep(0.01)

    empty_scans = 0
    while time.monotonic() < cleanup_deadline:
        current = descendants()
        include_live_main(current)
        if current:
            empty_scans = 0
            signal_original_group(signal.SIGKILL, current)
            signal_processes(current, signal.SIGKILL)
        else:
            reap_children()
            current = descendants()
            include_live_main(current)
            if current:
                empty_scans = 0
            else:
                empty_scans += 1
                if empty_scans >= 3:
                    break
        drain_output(0.02)
        time.sleep(0.01)
    else:
        return False

    while not pipe_eof and time.monotonic() < cleanup_deadline:
        drain_output(0.02)
        reap_children()
        current = descendants()
        if current:
            signal_processes(current, signal.SIGKILL)
            empty_scans = 0
        time.sleep(0.01)
    reap_children()
    return pipe_eof and not descendants() and (process is None or process.poll() is not None)


result = 125
try:
    mode = os.fstat(log_descriptor).st_mode
    if not stat.S_ISREG(mode):
        raise RuntimeError("build log is not regular")
    os.fchmod(log_descriptor, 0o600)
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) != 0:
        error_number = ctypes.get_errno()
        raise OSError(error_number, os.strerror(error_number))
    if not os.path.isdir("/proc/self"):
        raise RuntimeError("Linux /proc is required")
    for handled_signal in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(handled_signal, request_shutdown)

    process = subprocess.Popen(
        command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        start_new_session=True,
        close_fds=True,
    )
    pipe_descriptor = process.stdout.fileno()
    os.set_blocking(pipe_descriptor, False)
    command_deadline = time.monotonic() + timeout_seconds
    timed_out = False
    main_status = None
    while True:
        drain_output(0.05)
        main_status = process.poll()
        if main_status is not None:
            break
        if requested_signal is not None:
            break
        if time.monotonic() >= command_deadline:
            timed_out = True
            break

    cleanup_deadline = time.monotonic() + KILL_AFTER_SECONDS
    cleanup_ok = stop_and_reap_descendants(cleanup_deadline)
    if not cleanup_ok:
        retain_output(SUPERVISOR_ERROR_MARKER)
        result = 125
    elif requested_signal is not None:
        result = 128 + requested_signal
    elif timed_out:
        result = 124
    elif main_status is None:
        result = 125
    elif main_status < 0:
        result = 128 + (-main_status)
    else:
        result = main_status
except BaseException:
    retain_output(SUPERVISOR_ERROR_MARKER)
    if process is not None:
        try:
            stop_and_reap_descendants(time.monotonic() + KILL_AFTER_SECONDS)
        except BaseException:
            pass
    result = 125
finally:
    if truncated:
        write_all(TRUNCATION_MARKER)
    if process is not None and process.stdout is not None:
        process.stdout.close()
    os.close(log_descriptor)
raise SystemExit(result)
PY
  REPAIR_SUPERVISOR_PID=$!
  REPAIR_SUPERVISOR_STARTING=false
  if [[ "${REPAIR_CANCELLATION_ACTIVE:-false}" == true ]]; then
    kill -s "${REPAIR_CANCELLATION_SIGNAL_NAME:-TERM}" "$REPAIR_SUPERVISOR_PID" 2>/dev/null || true
  fi
  if wait "$REPAIR_SUPERVISOR_PID"; then
    supervisor_status=0
  else
    supervisor_status=$?
  fi
  if [[ "${REPAIR_CANCELLATION_ACTIVE:-false}" == true ]]; then
    wait "$REPAIR_SUPERVISOR_PID" 2>/dev/null || true
  fi
  REPAIR_SUPERVISOR_STATE=reaped
  REPAIR_SUPERVISOR_PID=
  REPAIR_SUPERVISOR_STATE=idle
  if [[ "${REPAIR_CANCELLATION_ACTIVE:-false}" == true ]]; then
    exit "${REPAIR_CANCELLATION_EXIT_STATUS:-143}"
  fi
  return "$supervisor_status"
}

build_sanitized_environment_args() {
  local result_name=$1
  local controlled_home=$2
  local -n result=$result_name
  local variable_name

  result=()
  while IFS= read -r variable_name; do
    case "$variable_name" in
      PIP_* | UV_* | PYTHON* | VIRTUAL_ENV | CONDA_* | NETRC)
        result+=(-u "$variable_name")
        ;;
    esac
  done < <(compgen -e)
  result+=("HOME=$controlled_home")
}

run_selected_pip_attempt() {
  local pip_command_name=$1
  local download_args_name=$2
  local socks_site_dir=$3
  local pip_output_log=$4
  local use_legacy_certs=$5
  local clean_env_args_name=$6
  local bounded_capture=$7
  local -n selected_pip_command=$pip_command_name
  local -n selected_download_args=$download_args_name
  local -a command=(env)

  if [[ -n "$clean_env_args_name" ]]; then
    local -n selected_clean_env_args=$clean_env_args_name
    command+=("${selected_clean_env_args[@]}")
  fi
  if [[ "$use_legacy_certs" == true ]]; then
    command+=(PIP_USE_DEPRECATED=legacy-certs)
  fi
  if [[ -n "$socks_site_dir" ]]; then
    if [[ -n "$clean_env_args_name" ]]; then
      command+=("PYTHONPATH=$socks_site_dir")
    else
      command+=("PYTHONPATH=$socks_site_dir${PYTHONPATH:+:$PYTHONPATH}")
    fi
  fi
  command+=("${selected_pip_command[@]}" "${selected_download_args[@]}")
  if [[ "$bounded_capture" == true ]]; then
    run_bounded_command_log "$pip_output_log" "${command[@]}"
  else
    "${command[@]}" >"$pip_output_log" 2>&1
  fi
}

run_pip_with_socks_retry() {
  local pip_command_name=$1
  local download_args_name=$2
  local socks_site_dir=$3
  local pip_output_log=$4
  local allow_legacy_retry=${5:-false}
  local clean_env_args_name=${6:-}
  local bounded_capture=${7:-false}
  local display_output=${8:-true}
  local pip_status retry_status
  local truststore_error="TypeError: PoolKey.__new__() got an unexpected keyword argument 'key_proxy_ssl_context'"

  if [[ "$bounded_capture" != true ]]; then
    : >"$pip_output_log"
  fi
  if run_selected_pip_attempt \
    "$pip_command_name" "$download_args_name" "$socks_site_dir" "$pip_output_log" \
    false "$clean_env_args_name" "$bounded_capture"; then
    pip_status=0
  else
    pip_status=$?
  fi
  if [[ "$display_output" == true ]]; then
    redact_pip_log <"$pip_output_log" >&2 || printf 'pip output could not be displayed safely\n' >&2
  fi
  if ((pip_status == 0)); then
    return 0
  fi
  if [[ "$allow_legacy_retry" != true ]] || ! grep -Fxq -- "$truststore_error" "$pip_output_log"; then
    return "$pip_status"
  fi

  printf '%s\n' \
    'pip SOCKS support is incompatible with its truststore proxy context; retrying once with PIP_USE_DEPRECATED=legacy-certs.' >&2
  if [[ "$bounded_capture" != true ]]; then
    : >"$pip_output_log"
  fi
  if run_selected_pip_attempt \
    "$pip_command_name" "$download_args_name" "$socks_site_dir" "$pip_output_log" \
    true "$clean_env_args_name" "$bounded_capture"; then
    retry_status=0
  else
    retry_status=$?
  fi
  if [[ "$display_output" == true ]]; then
    redact_pip_log <"$pip_output_log" >&2 || printf 'pip retry output could not be displayed safely\n' >&2
  fi
  return "$retry_status"
}

validate_sdist_repair_dir() {
  local repair_dir=${1:-}

  task3_python -B - "$repair_dir" <<'PY'
import os
import stat
import sys


path = sys.argv[1]
try:
    if (
        not path
        or any(ord(character) < 32 or ord(character) == 127 for character in path)
        or not os.path.isabs(path)
        or os.path.normpath(path) != path
    ):
        raise ValueError
    if os.path.basename(path) != "sdist-repair":
        raise ValueError
    parent = os.path.dirname(path)
    if parent in {"", ".", os.path.sep, path}:
        raise ValueError

    current = os.path.sep
    for component in path.split(os.path.sep)[1:]:
        current = os.path.join(current, component)
        if not os.path.lexists(current):
            break
        mode = os.lstat(current).st_mode
        if stat.S_ISLNK(mode) or not stat.S_ISDIR(mode):
            raise ValueError
    if not os.path.isdir(parent) or os.path.islink(parent):
        raise ValueError
    if os.path.lexists(path):
        repair = os.lstat(path)
        if (
            stat.S_ISLNK(repair.st_mode)
            or not stat.S_ISDIR(repair.st_mode)
            or repair.st_uid != os.geteuid()
            or stat.S_IMODE(repair.st_mode) != 0o700
        ):
            raise ValueError
except (OSError, ValueError):
    raise SystemExit(1)
PY
  if (($? != 0)); then
    printf 'safe absolute sdist-repair staging directory is required\n' >&2
    return 1
  fi
}

sanitize_index_url_for_tools() {
  task3_python -B /dev/fd/3 3<<'PY'
import re
import sys
from urllib.parse import unquote, urlsplit, urlunsplit


raw_url = sys.stdin.read()
try:
    if any(ord(character) < 32 or ord(character) == 127 for character in raw_url):
        raise ValueError
    parsed = urlsplit(raw_url)
    if parsed.scheme.lower() not in {"http", "https"} or not parsed.hostname:
        raise ValueError
    if parsed.query or parsed.fragment or parsed.username is not None or parsed.password is not None:
        raise ValueError
    host = parsed.hostname
    if (
        re.fullmatch(r"[A-Za-z0-9._:-]+", host) is None
        or any(character in host for character in "\"'\\")
    ):
        raise ValueError
    port = parsed.port
    if parsed.path and not parsed.path.startswith("/"):
        raise ValueError
    if re.search(r"%(?![0-9A-Fa-f]{2})", parsed.path):
        raise ValueError
    decoded_path = unquote(parsed.path, errors="strict")
    if (
        any(ord(character) < 32 or ord(character) == 127 for character in decoded_path)
        or any(character.isspace() or character in "\"'\\" for character in decoded_path)
        or re.fullmatch(r"[/A-Za-z0-9._~!$&()*+,;=:@%+-]*", parsed.path) is None
    ):
        raise ValueError
    if ":" in host:
        host = f"[{host}]"
    if port is not None:
        host = f"{host}:{port}"
    print(urlunsplit((parsed.scheme.lower(), host, parsed.path, "", "")))
except (TypeError, UnicodeError, ValueError):
    print(
        "authenticated package indexes are unsupported for third-party source builds",
        file=sys.stderr,
    )
    raise SystemExit(1)
PY
}

safe_fchmod_regular_file() {
  local path=$1
  local requested_mode=$2

  task3_python -B - "$path" "$requested_mode" <<'PY'
import os
import stat
import sys


path, raw_mode = sys.argv[1:]
if raw_mode not in {"400", "600"}:
    raise SystemExit(1)
requested_mode = int(raw_mode, 8)
descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
try:
    before = os.fstat(descriptor)
    if not stat.S_ISREG(before.st_mode):
        raise OSError("not a regular file")
    identity = (before.st_dev, before.st_ino)
    os.fchmod(descriptor, requested_mode)
    after = os.fstat(descriptor)
    current = os.lstat(path)
    if (
        (after.st_dev, after.st_ino) != identity
        or (current.st_dev, current.st_ino) != identity
        or not stat.S_ISREG(current.st_mode)
        or stat.S_IMODE(after.st_mode) != requested_mode
        or stat.S_IMODE(current.st_mode) != requested_mode
    ):
        raise OSError("file identity changed during mode update")
finally:
    os.close(descriptor)
PY
}

validate_private_stage_file() {
  task3_python -B - "$1" <<'PY'
import os
import stat
import sys


record = os.lstat(sys.argv[1])
if (
    stat.S_ISLNK(record.st_mode)
    or not stat.S_ISREG(record.st_mode)
    or record.st_uid != os.geteuid()
    or record.st_nlink != 1
    or stat.S_IMODE(record.st_mode) != 0o600
):
    raise SystemExit(1)
PY
}

validate_sdist_repair_identifiers() {
  local pip_command_name=$1
  local uv_command=$2
  local requirement=$3
  local canonical_name=$4
  local python_version=$5
  local ordinal=$6
  local normalized_python declaration build_timeout

  [[ "$pip_command_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
    printf 'invalid pip command array name for pure Python sdist repair\n' >&2
    return 1
  }
  declaration="$(declare -p "$pip_command_name" 2>/dev/null)" || {
    printf 'pip command array not found for pure Python sdist repair\n' >&2
    return 1
  }
  local -n selected_pip_command=$pip_command_name
  [[ "$declaration" == 'declare -a '* && -n "${selected_pip_command[0]-}" ]] || {
    printf 'pip command array is invalid for pure Python sdist repair\n' >&2
    return 1
  }
  command -v "${selected_pip_command[0]}" >/dev/null 2>&1 || {
    printf 'pip command not found for pure Python sdist repair\n' >&2
    return 1
  }
  [[ -n "$uv_command" ]] && command -v "$uv_command" >/dev/null 2>&1 || {
    printf 'uv command not found for pure Python sdist repair\n' >&2
    return 1
  }
  build_timeout=${DIFY_SDIST_BUILD_TIMEOUT_SECONDS:-600}
  [[ "$build_timeout" =~ ^[1-9][0-9]*$ ]] && ((10#$build_timeout <= 3600)) || {
    printf 'DIFY_SDIST_BUILD_TIMEOUT_SECONDS must be between 1 and 3600\n' >&2
    return 1
  }
  [[ "$ordinal" =~ ^[1-9][0-9]*$ ]] || {
    printf 'pure Python sdist repair candidate ordinal must be a positive decimal\n' >&2
    return 1
  }
  normalized_python="$(normalize_python_version "$python_version")" || return
  [[ "$normalized_python" == "$python_version" ]] || {
    printf 'pure Python sdist repair requires an exact MAJOR.MINOR target Python\n' >&2
    return 1
  }
  task3_python -B - "$requirement" "$canonical_name" <<'PY'
import re
import sys


requirement, expected_name = sys.argv[1:]
name_pattern = r"[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?"
specifier = r"(?:===|==|!=|~=|<=|>=|<|>)[A-Za-z0-9][A-Za-z0-9.!+_*-]*"
requirement_pattern = re.compile(
    rf"^(?P<name>{name_pattern})(?:{specifier}(?:,{specifier})*)?$"
)
canonical_pattern = re.compile(r"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$")

match = requirement_pattern.fullmatch(requirement)
if match is None or canonical_pattern.fullmatch(expected_name) is None:
    raise SystemExit(1)
normalized_name = re.sub(r"[-_.]+", "-", match.group("name")).lower()
if normalized_name != expected_name:
    raise SystemExit(1)
PY
  if (($? != 0)); then
    printf 'unsafe or mismatched requirement for pure Python sdist repair\n' >&2
    return 1
  fi
}

validate_optional_socks_site_dir() {
  local socks_site_dir=$1

  [[ -z "$socks_site_dir" ]] && return 0
  task3_python -B - "$socks_site_dir" <<'PY'
import os
import stat
import sys


path = sys.argv[1]
try:
    if (
        not os.path.isabs(path)
        or os.path.normpath(path) != path
        or any(ord(character) < 32 or ord(character) == 127 for character in path)
    ):
        raise ValueError
    current = os.path.sep
    for component in path.split(os.path.sep)[1:]:
        current = os.path.join(current, component)
        mode = os.lstat(current).st_mode
        if stat.S_ISLNK(mode) or not stat.S_ISDIR(mode):
            raise ValueError
except (OSError, ValueError):
    raise SystemExit(1)
PY
  if (($? != 0)); then
    printf 'safe temporary SOCKS site directory is required for pure Python sdist repair\n' >&2
    return 1
  fi
}

validate_candidate_source_dir() {
  local source_dir=$1
  local error_log=$2

  task3_python -B - "$source_dir" "$error_log" <<'PY'
import os
import re
import stat
import sys


source_dir, error_log = sys.argv[1:]
try:
    if not os.path.isabs(source_dir) or os.path.normpath(source_dir) != source_dir:
        raise ValueError
    candidate_dir = os.path.dirname(source_dir)
    repair_dir = os.path.dirname(candidate_dir)
    if (
        os.path.basename(source_dir) != "source"
        or re.fullmatch(r"candidate-[1-9][0-9]*", os.path.basename(candidate_dir)) is None
        or os.path.basename(repair_dir) != "sdist-repair"
        or os.path.dirname(error_log) != candidate_dir
        or re.fullmatch(r"\.download-log\.[A-Za-z0-9]+", os.path.basename(error_log)) is None
    ):
        raise ValueError
    for path in (repair_dir, candidate_dir, source_dir):
        record = os.lstat(path)
        if (
            stat.S_ISLNK(record.st_mode)
            or not stat.S_ISDIR(record.st_mode)
            or record.st_uid != os.geteuid()
            or stat.S_IMODE(record.st_mode) != 0o700
        ):
            raise ValueError
    if any(os.scandir(source_dir)):
        raise ValueError
    if os.path.lexists(error_log):
        record = os.lstat(error_log)
        if (
            stat.S_ISLNK(record.st_mode)
            or not stat.S_ISREG(record.st_mode)
            or record.st_uid != os.geteuid()
            or record.st_nlink != 1
            or stat.S_IMODE(record.st_mode) != 0o600
        ):
            raise ValueError
except (OSError, ValueError):
    raise SystemExit(1)
PY
}

download_sdist() {
  local pip_command_name=$1
  local requirement=$2
  local python_version=$3
  local source_dir=$4
  local socks_site_dir=$5
  local error_log=$6
  local proxy_url= normalized_python declaration repair_dir safe_index candidate_home
  local -a download_args=()
  local -a clean_env_args=()

  [[ "$pip_command_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  declaration="$(declare -p "$pip_command_name" 2>/dev/null)" || return
  local -n selected_pip_command=$pip_command_name
  [[ "$declaration" == 'declare -a '* && -n "${selected_pip_command[0]-}" ]] || return 1
  normalized_python="$(normalize_python_version "$python_version")" || return
  [[ "$normalized_python" == "$python_version" ]] || return 1
  task3_python -B - "$requirement" <<'PY'
import re
import sys


name = r"[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?"
specifier = r"(?:===|==|!=|~=|<=|>=|<|>)[A-Za-z0-9][A-Za-z0-9.!+_*-]*"
if re.fullmatch(rf"{name}(?:{specifier}(?:,{specifier})*)?", sys.argv[1]) is None:
    raise SystemExit(1)
PY
  if (($? != 0)); then
    printf 'unsafe requirement for pure Python sdist download\n' >&2
    return 1
  fi
  repair_dir="$(dirname -- "$(dirname -- "$source_dir")")"
  validate_sdist_repair_dir "$repair_dir" || return
  validate_optional_socks_site_dir "$socks_site_dir" || return
  validate_candidate_source_dir "$source_dir" "$error_log" || {
    printf 'unsafe source staging for pure Python sdist download\n' >&2
    return 1
  }
  if ! safe_index="$(printf '%s' "$PIP_MIRROR_URL" | sanitize_index_url_for_tools)"; then
    return 1
  fi
  candidate_home="$(dirname -- "$source_dir")"
  [[ -d "$candidate_home" && ! -L "$candidate_home" ]] || return 1
  build_sanitized_environment_args clean_env_args "$candidate_home"
  proxy_url="$(detect_socks_proxy)" || true
  download_args=(
    download
    --isolated
    --disable-pip-version-check
    --index-url "$safe_index"
    --python-version "$python_version"
    --implementation cp
    --no-deps
    --no-binary=:all:
    --dest "$source_dir"
    "$requirement"
  )
  run_pip_with_socks_retry \
    "$pip_command_name" \
    download_args \
    "$socks_site_dir" \
    "$error_log" \
    "$([[ -n "$proxy_url" ]] && printf true || printf false)" \
    clean_env_args \
    true
}

parse_distribution_validator_record() {
  local line=$1
  local expected_dir=$2
  local path_result_name=$3
  local name_result_name=$4
  local version_result_name=$5
  local -n path_result=$path_result_name
  local -n name_result=$name_result_name
  local -n version_result=$version_result_name
  local extra expected_real artifact_real

  [[ -n "$line" && "$line" != *$'\n'* && "$line" != *$'\r'* ]] || return 1
  [[ "$line" == *$'\t'*$'\t'* && "$line" != *$'\t'*$'\t'*$'\t'* ]] || return 1
  IFS=$'\t' read -r path_result name_result version_result extra <<<"$line"
  [[ -n "$path_result" && -n "$name_result" && -n "$version_result" && -z "$extra" ]] || return 1
  [[ "$name_result" =~ ^[a-z0-9]+([a-z0-9-]*[a-z0-9])?$ ]] || return 1
  [[ "$version_result" =~ ^[A-Za-z0-9.!+]+$ ]] || return 1
  [[ -f "$path_result" && ! -L "$path_result" ]] || return 1
  expected_real="$(realpath -e -- "$expected_dir")" || return
  artifact_real="$(realpath -e -- "$path_result")" || return
  [[ "$path_result" == "$artifact_real" && "$(dirname -- "$artifact_real")" == "$expected_real" ]] || return 1
}

distribution_file_signature() {
  task3_python -B - "$1" <<'PY'
import hashlib
import os
import stat
import sys


path = sys.argv[1]
flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
descriptor = os.open(path, flags)
try:
    before = os.fstat(descriptor)
    if not stat.S_ISREG(before.st_mode):
        raise OSError("not a regular file")
    digest = hashlib.sha256()
    while True:
        chunk = os.read(descriptor, 1024 * 1024)
        if not chunk:
            break
        digest.update(chunk)
    after = os.fstat(descriptor)
    identity_before = (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
    identity_after = (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
    if identity_before != identity_after:
        raise OSError("file changed while hashing")
    print(":".join(map(str, identity_after)) + ":" + digest.hexdigest())
finally:
    os.close(descriptor)
PY
}

snapshot_built_wheel() {
  local wheel_dir=$1
  local candidate_dir=$2
  local snapshot_dir_result_name=$3
  local snapshot_path_result_name=$4
  local -n snapshot_dir_result=$snapshot_dir_result_name
  local -n snapshot_path_result=$snapshot_path_result_name
  local snapshot_record

  snapshot_record="$(task3_python -B - "$wheel_dir" "$candidate_dir" <<'PY'
import os
import stat
import sys
import tempfile


directory, candidate_dir = sys.argv[1:]
if os.path.dirname(directory) != candidate_dir or os.path.basename(directory) != "wheel":
    raise SystemExit(1)
for managed_directory in (candidate_dir, directory):
    managed = os.lstat(managed_directory)
    if (
        stat.S_ISLNK(managed.st_mode)
        or not stat.S_ISDIR(managed.st_mode)
        or managed.st_uid != os.geteuid()
        or stat.S_IMODE(managed.st_mode) != 0o700
    ):
        raise SystemExit(1)
entries = []
with os.scandir(directory) as iterator:
    for entry in iterator:
        entries.append(entry)
        if len(entries) > 1024:
            raise SystemExit(1)
if len(entries) != 1:
    raise SystemExit(1)
entry = entries[0]
if (
    any(ord(character) < 32 or ord(character) == 127 for character in entry.name)
    or not entry.name.lower().endswith(".whl")
    or entry.is_symlink()
):
    raise SystemExit(1)
entry_record = entry.stat(follow_symlinks=False)
if (
    not stat.S_ISREG(entry_record.st_mode)
    or entry_record.st_uid != os.geteuid()
    or entry_record.st_nlink != 1
):
    raise SystemExit(1)
source_path = os.path.join(directory, entry.name)
snapshot_dir = tempfile.mkdtemp(prefix=".admission.", dir=candidate_dir)
snapshot_path = os.path.join(snapshot_dir, entry.name)
descriptor = None
try:
    snapshot_record = os.lstat(snapshot_dir)
    if (
        not stat.S_ISDIR(snapshot_record.st_mode)
        or snapshot_record.st_uid != os.geteuid()
        or stat.S_IMODE(snapshot_record.st_mode) != 0o700
    ):
        raise OSError("snapshot directory is not private")
    descriptor = os.open(source_path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    before = os.fstat(descriptor)
    if not stat.S_ISREG(before.st_mode):
        raise OSError("wheel output is not regular")
    identity = (before.st_dev, before.st_ino)
    os.rename(source_path, snapshot_path)
    moved = os.lstat(snapshot_path)
    if (
        (moved.st_dev, moved.st_ino) != identity
        or not stat.S_ISREG(moved.st_mode)
        or os.path.lexists(source_path)
    ):
        raise OSError("wheel output identity changed during snapshot")
    os.fchmod(descriptor, 0o400)
    hardened = os.fstat(descriptor)
    current = os.lstat(snapshot_path)
    if (
        (hardened.st_dev, hardened.st_ino) != identity
        or (current.st_dev, current.st_ino) != identity
        or stat.S_IMODE(hardened.st_mode) != 0o400
        or stat.S_IMODE(current.st_mode) != 0o400
    ):
        raise OSError("wheel snapshot mode or identity changed")
    print(f"{snapshot_dir}\t{snapshot_path}")
except BaseException:
    try:
        if os.path.lexists(snapshot_path):
            os.unlink(snapshot_path)
        os.rmdir(snapshot_dir)
    except OSError:
        pass
    raise
finally:
    if descriptor is not None:
        os.close(descriptor)
PY
)" || return
  [[ "$snapshot_record" == *$'\t'* && "$snapshot_record" != *$'\n'* && "$snapshot_record" != *$'\r'* ]] || return 1
  IFS=$'\t' read -r snapshot_dir_result snapshot_path_result <<<"$snapshot_record"
  [[ -n "$snapshot_dir_result" && -n "$snapshot_path_result" && \
    "$(dirname -- "$snapshot_path_result")" == "$snapshot_dir_result" && \
    "$(dirname -- "$snapshot_dir_result")" == "$candidate_dir" && \
    "$(basename -- "$snapshot_dir_result")" == .admission.* && \
    -f "$snapshot_path_result" && ! -L "$snapshot_path_result" ]] || return 1
}

cleanup_admission_snapshot() {
  local snapshot_dir=$1
  local snapshot_path=$2

  [[ -n "$snapshot_dir" && -n "$snapshot_path" && \
    "$(dirname -- "$snapshot_path")" == "$snapshot_dir" && \
    "$(basename -- "$snapshot_dir")" == .admission.* ]] || return 1
  if [[ -f "$snapshot_path" && ! -L "$snapshot_path" ]]; then
    rm -f -- "$snapshot_path"
  fi
  rmdir -- "$snapshot_dir" 2>/dev/null || true
}

remove_private_stage_log() {
  local candidate_dir=$1
  local log_path=$2

  [[ -n "$log_path" && "$(dirname -- "$log_path")" == "$candidate_dir" ]] || return 1
  if [[ -f "$log_path" && ! -L "$log_path" ]]; then
    rm -f -- "$log_path"
  fi
}

admit_validated_snapshot() {
  local snapshot_path=$1
  local built_wheels_dir=$2
  local expected_signature=$3
  local basename target final_signature snapshot_dir

  basename="$(basename -- "$snapshot_path")"
  [[ "$basename" == *.whl && "$basename" != */* ]] || return 1
  [[ -d "$built_wheels_dir" && ! -L "$built_wheels_dir" ]] || return 1
  target="$built_wheels_dir/$basename"
  [[ ! -e "$target" && ! -L "$target" ]] || return 1
  [[ "$(distribution_file_signature "$snapshot_path")" == "$expected_signature" ]] || return 1
  safe_fchmod_regular_file "$snapshot_path" 400 || return
  snapshot_dir="$(dirname -- "$snapshot_path")"
  [[ "$(basename -- "$snapshot_dir")" == .admission.* ]] || return 1
  if ! mv -n -- "$snapshot_path" "$target"; then
    return 1
  fi
  [[ ! -e "$snapshot_path" && ! -L "$snapshot_path" ]] || return 1
  final_signature="$(distribution_file_signature "$target")" || {
    [[ -f "$target" && ! -L "$target" ]] && rm -f -- "$target"
    return 1
  }
  if [[ "$final_signature" != "$expected_signature" ]]; then
    [[ -f "$target" && ! -L "$target" ]] && rm -f -- "$target"
    return 1
  fi
  task3_python -B - "$target" <<'PY'
import os
import stat
import sys


mode = os.lstat(sys.argv[1]).st_mode
if stat.S_ISLNK(mode) or not stat.S_ISREG(mode) or stat.S_IMODE(mode) != 0o400:
    raise SystemExit(1)
PY
}

ensure_private_repair_directory() {
  local directory=$1

  if [[ -e "$directory" || -L "$directory" ]]; then
    validate_private_repair_layout "$directory" || return
  else
    mkdir -m 700 -- "$directory" || return
  fi
  validate_private_repair_layout "$directory"
}

validate_private_repair_layout() {
  task3_python -B - "$@" <<'PY'
import os
import stat
import sys


for path in sys.argv[1:]:
    try:
        record = os.lstat(path)
    except OSError:
        raise SystemExit(1)
    if (
        stat.S_ISLNK(record.st_mode)
        or not stat.S_ISDIR(record.st_mode)
        or record.st_uid != os.geteuid()
        or stat.S_IMODE(record.st_mode) != 0o700
    ):
        raise SystemExit(1)
PY
}

cleanup_sdist_repair_state() {
  local original_status=$?

  trap - EXIT HUP INT TERM
  if [[ "${REPAIR_SUPERVISOR_PID:-}" =~ ^[1-9][0-9]*$ ]]; then
    kill -TERM "$REPAIR_SUPERVISOR_PID" 2>/dev/null || true
    wait "$REPAIR_SUPERVISOR_PID" 2>/dev/null || true
    REPAIR_SUPERVISOR_PID=
  fi
  if [[ -n "${REPAIR_CANDIDATE_DIR_FOR_CLEANUP:-}" && -n "${REPAIR_STAGE_LOG_TO_CLEAN:-}" ]]; then
    remove_private_stage_log \
      "$REPAIR_CANDIDATE_DIR_FOR_CLEANUP" "$REPAIR_STAGE_LOG_TO_CLEAN" >/dev/null 2>&1 || true
  fi
  if [[ -n "${REPAIR_LOCK_TO_RELEASE:-}" && -n "${REPAIR_DIR_FOR_CLEANUP:-}" && \
    "$REPAIR_LOCK_TO_RELEASE" == "$REPAIR_DIR_FOR_CLEANUP/.repair-lock" ]]; then
    rmdir -- "$REPAIR_LOCK_TO_RELEASE" 2>/dev/null || true
  fi
  return "$original_status"
}

cancel_sdist_repair() {
  local signal_name=$1
  local exit_status=$2

  trap '' HUP INT TERM
  if [[ "${REPAIR_CANCELLATION_ACTIVE:-false}" == true ]]; then
    exit "$exit_status"
  fi
  REPAIR_CANCELLATION_ACTIVE=true
  REPAIR_CANCELLATION_EXIT_STATUS=$exit_status
  REPAIR_CANCELLATION_SIGNAL_NAME=$signal_name
  if [[ "${REPAIR_SUPERVISOR_PID:-}" =~ ^[1-9][0-9]*$ ]]; then
    kill -s "$signal_name" "$REPAIR_SUPERVISOR_PID" 2>/dev/null || true
    return 0
  fi
  if [[ "${REPAIR_SUPERVISOR_STARTING:-false}" == true ]]; then
    return 0
  fi
  exit "$exit_status"
}

cross_sdist_non_admission_cancellation_barrier() {
  if [[ "${REPAIR_CANCELLATION_ACTIVE:-false}" == true ]]; then
    exit "${REPAIR_CANCELLATION_EXIT_STATUS:-143}"
  fi
  REPAIR_ADMISSION_BARRIER_CROSSED=true
  if [[ "${REPAIR_CANCELLATION_ACTIVE:-false}" == true ]]; then
    exit "${REPAIR_CANCELLATION_EXIT_STATUS:-143}"
  fi
}

repair_one_pure_sdist_locked() {
  local pip_command_name=$1
  local uv_command=$2
  local requirement=$3
  local canonical_name=$4
  local python_version=$5
  local repair_dir=$6
  local socks_site_dir=$7
  local ordinal=$8
  local safe_index=$9
  local candidate_dir source_dir wheel_dir built_wheels_dir uv_cache_dir uv_python_dir
  local download_log= build_log= sdist_error= wheel_error=
  local sdist_output wheel_output sdist_path metadata_name metadata_version wheel_path wheel_name wheel_version
  local snapshot_dir= before_signature after_signature build_timeout build_status
  local -a clean_env_args=()
  local -a uv_build_command=()

  candidate_dir="$repair_dir/candidate-$ordinal"
  REPAIR_CANDIDATE_DIR_FOR_CLEANUP=$candidate_dir
  source_dir="$candidate_dir/source"
  wheel_dir="$candidate_dir/wheel"
  built_wheels_dir="$repair_dir/built-wheels"
  uv_cache_dir="$repair_dir/uv-cache"
  uv_python_dir="$repair_dir/uv-python"
  if ! mkdir -m 700 -- "$candidate_dir"; then
    printf 'pure Python sdist repair candidate staging is unsafe or already exists\n' >&2
    return 1
  fi
  validate_private_repair_layout \
    "$repair_dir" "$repair_dir/.repair-lock" "$candidate_dir" || return
  mkdir -m 700 -- "$source_dir" "$wheel_dir" || return
  validate_private_repair_layout "$source_dir" "$wheel_dir" || return
  ensure_private_repair_directory "$built_wheels_dir" || return
  ensure_private_repair_directory "$uv_cache_dir" || return
  ensure_private_repair_directory "$uv_python_dir" || return
  validate_private_repair_layout \
    "$repair_dir" "$repair_dir/.repair-lock" "$candidate_dir" "$source_dir" "$wheel_dir" \
    "$built_wheels_dir" "$uv_cache_dir" "$uv_python_dir" || return
  build_sanitized_environment_args clean_env_args "$candidate_dir"

  download_log="$(mktemp "$candidate_dir/.download-log.XXXXXXXX")" || return
  REPAIR_STAGE_LOG_TO_CLEAN=$download_log
  if ! validate_private_stage_file "$download_log"; then
    remove_private_stage_log "$candidate_dir" "$download_log" || true
    return 1
  fi
  if ! download_sdist \
    "$pip_command_name" "$requirement" "$python_version" "$source_dir" "$socks_site_dir" "$download_log"; then
    remove_private_stage_log "$candidate_dir" "$download_log" || true
    printf 'Pure Python sdist repair failed during download: %s (index: %s)\n' \
      "$requirement" "$safe_index" >&2
    return 1
  fi
  remove_private_stage_log "$candidate_dir" "$download_log" || return

  sdist_error="$(mktemp "$candidate_dir/.validation-log.XXXXXXXX")" || return
  REPAIR_STAGE_LOG_TO_CLEAN=$sdist_error
  if ! validate_private_stage_file "$sdist_error"; then
    remove_private_stage_log "$candidate_dir" "$sdist_error" || true
    return 1
  fi
  if ! sdist_output="$(env "${clean_env_args[@]}" python3 -B "$SCRIPT_DIR/tools/validate_python_distribution.py" \
    sdist "$source_dir" --name "$canonical_name" 2>"$sdist_error")"; then
    redact_pip_log <"$sdist_error" >&2 || printf 'validator output could not be displayed safely\n' >&2
    remove_private_stage_log "$candidate_dir" "$sdist_error" || true
    printf 'Pure Python sdist repair failed during validation: %s\n' "$requirement" >&2
    return 1
  fi
  remove_private_stage_log "$candidate_dir" "$sdist_error" || return
  if ! parse_distribution_validator_record \
    "$sdist_output" "$source_dir" sdist_path metadata_name metadata_version || \
    [[ "$metadata_name" != "$canonical_name" ]]; then
    printf '%s\n' 'validation failed: invalid sdist validator result' >&2
    printf 'Pure Python sdist repair failed during validation: %s\n' "$requirement" >&2
    return 1
  fi

  build_log="$(mktemp "$candidate_dir/.build-log.XXXXXXXX")" || return
  REPAIR_STAGE_LOG_TO_CLEAN=$build_log
  if ! validate_private_stage_file "$build_log"; then
    remove_private_stage_log "$candidate_dir" "$build_log" || true
    return 1
  fi
  build_timeout=${DIFY_SDIST_BUILD_TIMEOUT_SECONDS:-600}
  uv_build_command=(
    env "${clean_env_args[@]}"
    "UV_CACHE_DIR=$uv_cache_dir"
    "UV_PYTHON_INSTALL_DIR=$uv_python_dir"
    UV_PYTHON_PREFERENCE=only-managed
    "$uv_command" build
    --wheel
    --no-config
    --out-dir "$wheel_dir"
    --python "$python_version"
    --index-url "$safe_index"
    "$sdist_path"
  )
  if run_supervised_command_log "$build_log" "$build_timeout" "${uv_build_command[@]}"; then
    build_status=0
  else
    build_status=$?
  fi
  if ((build_status != 0)); then
    redact_pip_log <"$build_log" >&2 || printf 'build output could not be displayed safely\n' >&2
    remove_private_stage_log "$candidate_dir" "$build_log" || true
    printf 'Pure Python sdist repair failed during build: %s\n' "$requirement" >&2
    return 1
  fi
  remove_private_stage_log "$candidate_dir" "$build_log" || return

  cross_sdist_non_admission_cancellation_barrier
  if ! snapshot_built_wheel "$wheel_dir" "$candidate_dir" snapshot_dir wheel_path; then
    printf '%s\n' 'validation failed: exactly one safe wheel build output is required' >&2
    printf 'Pure Python sdist repair failed during validation: %s\n' "$requirement" >&2
    return 1
  fi
  before_signature="$(distribution_file_signature "$wheel_path")" || {
    cleanup_admission_snapshot "$snapshot_dir" "$wheel_path" || true
    return 1
  }
  wheel_error="$(mktemp "$candidate_dir/.validation-log.XXXXXXXX")" || {
    cleanup_admission_snapshot "$snapshot_dir" "$wheel_path" || true
    return 1
  }
  REPAIR_STAGE_LOG_TO_CLEAN=$wheel_error
  if ! validate_private_stage_file "$wheel_error"; then
    remove_private_stage_log "$candidate_dir" "$wheel_error" || true
    cleanup_admission_snapshot "$snapshot_dir" "$wheel_path" || true
    return 1
  fi
  if ! wheel_output="$(env "${clean_env_args[@]}" python3 -B "$SCRIPT_DIR/tools/validate_python_distribution.py" \
    wheel "$snapshot_dir" --name "$metadata_name" --version "$metadata_version" 2>"$wheel_error")"; then
    redact_pip_log <"$wheel_error" >&2 || printf 'validator output could not be displayed safely\n' >&2
    remove_private_stage_log "$candidate_dir" "$wheel_error" || true
    cleanup_admission_snapshot "$snapshot_dir" "$wheel_path" || true
    printf 'Pure Python sdist repair failed during validation: %s\n' "$requirement" >&2
    return 1
  fi
  if ! remove_private_stage_log "$candidate_dir" "$wheel_error"; then
    cleanup_admission_snapshot "$snapshot_dir" "$wheel_path" || true
    return 1
  fi
  after_signature="$(distribution_file_signature "$wheel_path")" || {
    cleanup_admission_snapshot "$snapshot_dir" "$wheel_path" || true
    return 1
  }
  if [[ "$before_signature" != "$after_signature" ]]; then
    cleanup_admission_snapshot "$snapshot_dir" "$wheel_path" || true
    printf '%s\n' 'validation failed: wheel snapshot changed during validation' >&2
    printf 'Pure Python sdist repair failed during validation: %s\n' "$requirement" >&2
    return 1
  fi
  if ! parse_distribution_validator_record \
    "$wheel_output" "$snapshot_dir" wheel_path wheel_name wheel_version || \
    [[ "$wheel_name" != "$metadata_name" || "$wheel_version" != "$metadata_version" ]]; then
    cleanup_admission_snapshot "$snapshot_dir" "$wheel_path" || true
    printf '%s\n' 'validation failed: invalid wheel validator result' >&2
    printf 'Pure Python sdist repair failed during validation: %s\n' "$requirement" >&2
    return 1
  fi
  if ! admit_validated_snapshot "$wheel_path" "$built_wheels_dir" "$after_signature"; then
    cleanup_admission_snapshot "$snapshot_dir" "$wheel_path" || true
    printf '%s\n' 'validation failed: unable to admit validated wheel safely' >&2
    printf 'Pure Python sdist repair failed during validation: %s\n' "$requirement" >&2
    return 1
  fi
  rmdir -- "$snapshot_dir" || return
  printf 'Pure Python wheel admitted: %s\n' "$(basename -- "$wheel_path")"
}

repair_one_pure_sdist_impl() {
  umask 077
  local pip_command_name=$1
  local uv_command=$2
  local requirement=$3
  local canonical_name=$4
  local python_version=$5
  local repair_dir=$6
  local socks_site_dir=$7
  local ordinal=$8
  local safe_index repair_lock_dir

  REPAIR_LOCK_TO_RELEASE=
  REPAIR_DIR_FOR_CLEANUP=
  REPAIR_CANDIDATE_DIR_FOR_CLEANUP=
  REPAIR_STAGE_LOG_TO_CLEAN=
  REPAIR_SUPERVISOR_PID=
  REPAIR_SUPERVISOR_STARTING=false
  REPAIR_SUPERVISOR_STATE=idle
  REPAIR_CANCELLATION_ACTIVE=false
  REPAIR_CANCELLATION_EXIT_STATUS=
  REPAIR_CANCELLATION_SIGNAL_NAME=
  REPAIR_ADMISSION_BARRIER_CROSSED=false
  trap cleanup_sdist_repair_state EXIT
  trap 'cancel_sdist_repair HUP 129' HUP
  trap 'cancel_sdist_repair INT 130' INT
  trap 'cancel_sdist_repair TERM 143' TERM

  validate_sdist_repair_dir "$repair_dir" || return
  validate_sdist_repair_identifiers \
    "$pip_command_name" "$uv_command" "$requirement" "$canonical_name" "$python_version" "$ordinal" || return
  validate_optional_socks_site_dir "$socks_site_dir" || return
  [[ -f "$SCRIPT_DIR/tools/validate_python_distribution.py" && \
    ! -L "$SCRIPT_DIR/tools/validate_python_distribution.py" ]] || {
    printf 'Python distribution validator is unavailable\n' >&2
    return 1
  }
  if ! safe_index="$(printf '%s' "$PIP_MIRROR_URL" | sanitize_index_url_for_tools)"; then
    printf 'Pure Python sdist repair rejected the configured package index\n' >&2
    return 1
  fi
  ensure_private_repair_directory "$repair_dir" || return
  repair_lock_dir="$repair_dir/.repair-lock"
  if ! mkdir -m 700 -- "$repair_lock_dir"; then
    printf 'pure Python sdist repair lock is already held or stale\n' >&2
    return 1
  fi
  REPAIR_LOCK_TO_RELEASE=$repair_lock_dir
  REPAIR_DIR_FOR_CLEANUP=$repair_dir
  validate_private_repair_layout "$repair_dir" "$repair_lock_dir" || return
  validate_sdist_repair_dir "$repair_dir" || return
  repair_one_pure_sdist_locked \
    "$pip_command_name" "$uv_command" "$requirement" "$canonical_name" "$python_version" \
    "$repair_dir" "$socks_site_dir" "$ordinal" "$safe_index"
}

repair_one_pure_sdist() (
  repair_one_pure_sdist_impl "$@"
)

download_wheels_once() {
  local requirements=$1
  local wheels_dir=$2
  local target_arch=$3
  local python_version=$4
  local pip_output_log=$5
  local bootstrap_dir=${6:-}
  local local_wheels_dir=${7:-}
  local bounded_capture=${8:-false}
  local display_output=${9:-true}
  local abi platform socks_proxy_url= socks_site_dir=
  local -a pip_command=()
  local -a platform_args=()
  local -a download_args=()

  reset_private_command_log "$pip_output_log" || return
  if [[ -n "$local_wheels_dir" ]]; then
    if [[ ! -d "$local_wheels_dir" ]]; then
      printf 'local built-wheel directory not found: %s\n' "$local_wheels_dir" >&2
      return 1
    fi
    local_wheels_dir="$(realpath -- "$local_wheels_dir")" || return
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
  )
  if [[ -n "$local_wheels_dir" ]]; then
    download_args+=(--find-links "$local_wheels_dir")
  fi
  download_args+=(
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
    "$([[ -n "$socks_proxy_url" ]] && printf true || printf false)" \
    '' \
    "$bounded_capture" \
    "$display_output"
}

validate_coordinator_workspace() {
  local workspace=$1

  task3_python -B - "$workspace" <<'PY'
import os
import re
import stat
import sys


workspace = sys.argv[1]
trusted_root = "/tmp"
try:
    root_mode = os.lstat(trusted_root).st_mode
    workspace_mode = os.lstat(workspace).st_mode
    if (
        os.path.realpath(trusted_root) != trusted_root
        or stat.S_ISLNK(root_mode)
        or not stat.S_ISDIR(root_mode)
        or not os.path.isabs(workspace)
        or os.path.realpath(workspace) != workspace
        or os.path.dirname(workspace) != trusted_root
        or re.fullmatch(r"dify-plugin-coordinator\.[A-Za-z0-9]+", os.path.basename(workspace)) is None
        or stat.S_ISLNK(workspace_mode)
        or not stat.S_ISDIR(workspace_mode)
        or os.lstat(workspace).st_uid != os.geteuid()
        or stat.S_IMODE(workspace_mode) != 0o700
    ):
        raise ValueError
except (OSError, ValueError):
    raise SystemExit(1)
PY
}

cleanup_coordinator_workspace() {
  local workspace=${1:-}

  [[ -n "$workspace" ]] || return 0
  task3_python -B - "$workspace" <<'PY'
import os
import re
import stat
import sys


workspace = sys.argv[1]
trusted_root = "/tmp"
basename = os.path.basename(workspace)
root_descriptor = None
workspace_descriptor = None
workspace_path_descriptor = None


def validate_path_directory(descriptor, expected):
    opened = os.fstat(descriptor)
    if (
        not stat.S_ISDIR(opened.st_mode)
        or opened.st_uid != os.geteuid()
        or (opened.st_dev, opened.st_ino) != (expected.st_dev, expected.st_ino)
    ):
        raise OSError("unsafe coordinator directory identity")


def restore_directory_mode(descriptor, expected):
    validate_path_directory(descriptor, expected)
    os.chmod(f"/proc/self/fd/{descriptor}", 0o700)
    restored = os.fstat(descriptor)
    if (
        (restored.st_dev, restored.st_ino) != (expected.st_dev, expected.st_ino)
        or stat.S_IMODE(restored.st_mode) != 0o700
    ):
        raise OSError("unable to restore coordinator directory mode")


def clear_directory(descriptor):
    for name in os.listdir(descriptor):
        entry = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
        if stat.S_ISDIR(entry.st_mode) and not stat.S_ISLNK(entry.st_mode):
            child_path = os.open(
                name,
                os.O_PATH | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=descriptor,
            )
            try:
                restore_directory_mode(child_path, entry)
                linked_after_restore = os.stat(
                    name,
                    dir_fd=descriptor,
                    follow_symlinks=False,
                )
                if (linked_after_restore.st_dev, linked_after_restore.st_ino) != (
                    entry.st_dev,
                    entry.st_ino,
                ):
                    raise OSError("coordinator subdirectory was replaced")
            finally:
                os.close(child_path)
            child = os.open(
                name,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=descriptor,
            )
            try:
                opened = os.fstat(child)
                if (
                    not stat.S_ISDIR(opened.st_mode)
                    or opened.st_uid != os.geteuid()
                    or (opened.st_dev, opened.st_ino) != (entry.st_dev, entry.st_ino)
                ):
                    raise OSError("unsafe coordinator subdirectory")
                clear_directory(child)
            finally:
                os.close(child)
            os.rmdir(name, dir_fd=descriptor)
        else:
            os.unlink(name, dir_fd=descriptor)


try:
    root_mode = os.lstat(trusted_root).st_mode
    if (
        os.path.realpath(trusted_root) != trusted_root
        or stat.S_ISLNK(root_mode)
        or not stat.S_ISDIR(root_mode)
        or not os.path.isabs(workspace)
        or os.path.realpath(workspace) != workspace
        or os.path.dirname(workspace) != trusted_root
        or re.fullmatch(r"dify-plugin-coordinator\.[A-Za-z0-9]+", basename) is None
    ):
        raise ValueError("unsafe coordinator workspace path")
    root_descriptor = os.open(
        trusted_root,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
    )
    linked = os.stat(basename, dir_fd=root_descriptor, follow_symlinks=False)
    # COORDINATOR_WORKSPACE_CLEANUP_IDENTITY_CAPTURED
    workspace_path_descriptor = os.open(
        basename,
        os.O_PATH | os.O_DIRECTORY | os.O_NOFOLLOW,
        dir_fd=root_descriptor,
    )
    if stat.S_ISLNK(linked.st_mode) or not stat.S_ISDIR(linked.st_mode):
        raise ValueError("unsafe coordinator workspace identity")
    restore_directory_mode(workspace_path_descriptor, linked)
    linked_after_restore = os.stat(
        basename,
        dir_fd=root_descriptor,
        follow_symlinks=False,
    )
    if (linked_after_restore.st_dev, linked_after_restore.st_ino) != (
        linked.st_dev,
        linked.st_ino,
    ):
        raise ValueError("coordinator workspace was replaced")
    workspace_descriptor = os.open(
        basename,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
        dir_fd=root_descriptor,
    )
    opened = os.fstat(workspace_descriptor)
    if (
        stat.S_ISLNK(linked.st_mode)
        or not stat.S_ISDIR(linked.st_mode)
        or not stat.S_ISDIR(opened.st_mode)
        or opened.st_uid != os.geteuid()
        or (opened.st_dev, opened.st_ino) != (linked.st_dev, linked.st_ino)
    ):
        raise ValueError("unsafe coordinator workspace identity")
    clear_directory(workspace_descriptor)
    os.close(workspace_descriptor)
    workspace_descriptor = None
    os.rmdir(basename, dir_fd=root_descriptor)
except (OSError, ValueError):
    raise SystemExit(1)
finally:
    if workspace_descriptor is not None:
        os.close(workspace_descriptor)
    if workspace_path_descriptor is not None:
        os.close(workspace_path_descriptor)
    if root_descriptor is not None:
        os.close(root_descriptor)
PY
  if (($? != 0)); then
    printf 'refusing to remove unsafe coordinator workspace: %s\n' "$workspace" >&2
    return 1
  fi
}

validate_coordinator_log_file() {
  local log_file=$1
  local workspace=$2

  validate_coordinator_workspace "$workspace" || return

  task3_python -B - "$log_file" "$workspace" <<'PY'
import os
import stat
import sys


path, parent = sys.argv[1:]
try:
    parent_mode = os.lstat(parent).st_mode
    mode = os.lstat(path).st_mode
    if (
        os.path.dirname(path) != parent
        or stat.S_ISLNK(parent_mode)
        or not stat.S_ISDIR(parent_mode)
        or stat.S_IMODE(parent_mode) != 0o700
        or stat.S_ISLNK(mode)
        or not stat.S_ISREG(mode)
        or os.lstat(path).st_uid != os.geteuid()
        or os.lstat(path).st_nlink != 1
        or stat.S_IMODE(mode) != 0o600
    ):
        raise ValueError
except (OSError, ValueError):
    raise SystemExit(1)
PY
}

snapshot_coordinator_log() {
  local source_log=$1
  local workspace=$2
  local result_name=$3
  local snapshot_path

  validate_coordinator_workspace "$workspace" || return
  if ! snapshot_path="$(task3_python -B - "$source_log" "$workspace" <<'PY'
import os
import secrets
import stat
import sys


source_path, workspace = sys.argv[1:]
source_basename = os.path.basename(source_path)
workspace_descriptor = None
source_descriptor = None
snapshot_descriptor = None
snapshot_basename = None
MAX_SNAPSHOT_BYTES = 2 * 1024 * 1024


def private_regular(record):
    return (
        stat.S_ISREG(record.st_mode)
        and not stat.S_ISLNK(record.st_mode)
        and record.st_uid == os.geteuid()
        and record.st_nlink == 1
        and stat.S_IMODE(record.st_mode) == 0o600
    )


def same_identity(left, right):
    return (left.st_dev, left.st_ino) == (right.st_dev, right.st_ino)


try:
    if os.path.dirname(source_path) != workspace or source_basename in {"", ".", ".."}:
        raise ValueError("unsafe coordinator log path")
    workspace_before = os.lstat(workspace)
    if (
        stat.S_ISLNK(workspace_before.st_mode)
        or not stat.S_ISDIR(workspace_before.st_mode)
        or workspace_before.st_uid != os.geteuid()
        or stat.S_IMODE(workspace_before.st_mode) != 0o700
    ):
        raise ValueError("unsafe coordinator workspace")
    workspace_descriptor = os.open(
        workspace,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
    )
    workspace_opened = os.fstat(workspace_descriptor)
    workspace_after = os.lstat(workspace)
    if (
        not same_identity(workspace_before, workspace_opened)
        or not same_identity(workspace_opened, workspace_after)
        or workspace_opened.st_uid != os.geteuid()
        or stat.S_IMODE(workspace_opened.st_mode) != 0o700
    ):
        raise OSError("coordinator workspace identity changed")

    source_before = os.stat(
        source_basename,
        dir_fd=workspace_descriptor,
        follow_symlinks=False,
    )
    # COORDINATOR_LOG_SNAPSHOT_PREOPEN
    if not private_regular(source_before):
        raise ValueError("unsafe coordinator diagnostic log")
    source_descriptor = os.open(
        source_basename,
        os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
        dir_fd=workspace_descriptor,
    )
    source_opened = os.fstat(source_descriptor)
    source_after_open = os.stat(
        source_basename,
        dir_fd=workspace_descriptor,
        follow_symlinks=False,
    )
    if (
        not private_regular(source_opened)
        or not private_regular(source_after_open)
        or not same_identity(source_before, source_opened)
        or not same_identity(source_opened, source_after_open)
    ):
        raise OSError("coordinator diagnostic log identity changed")

    for _ in range(128):
        candidate = f".diagnostic-snapshot.{secrets.token_hex(12)}.log"
        try:
            snapshot_descriptor = os.open(
                candidate,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                0o600,
                dir_fd=workspace_descriptor,
            )
            snapshot_basename = candidate
            break
        except FileExistsError:
            continue
    if snapshot_descriptor is None or snapshot_basename is None:
        raise OSError("unable to allocate coordinator diagnostic snapshot")
    snapshot_opened = os.fstat(snapshot_descriptor)
    if not private_regular(snapshot_opened):
        raise OSError("unsafe coordinator diagnostic snapshot")

    copied = 0
    while True:
        chunk = os.read(source_descriptor, 64 * 1024)
        if not chunk:
            break
        copied += len(chunk)
        if copied > MAX_SNAPSHOT_BYTES:
            raise OSError("coordinator diagnostic snapshot exceeds limit")
        position = 0
        while position < len(chunk):
            position += os.write(snapshot_descriptor, chunk[position:])

    source_after_read = os.fstat(source_descriptor)
    source_after_path = os.stat(
        source_basename,
        dir_fd=workspace_descriptor,
        follow_symlinks=False,
    )
    stable_fields = ("st_size", "st_mtime_ns", "st_ctime_ns")
    if (
        not same_identity(source_opened, source_after_read)
        or not same_identity(source_after_read, source_after_path)
        or any(getattr(source_opened, field) != getattr(source_after_read, field) for field in stable_fields)
        or any(getattr(source_after_read, field) != getattr(source_after_path, field) for field in stable_fields)
        or copied != source_opened.st_size
    ):
        raise OSError("coordinator diagnostic log changed during snapshot")
    os.fsync(snapshot_descriptor)
    os.close(snapshot_descriptor)
    snapshot_descriptor = None
    snapshot_linked = os.stat(
        snapshot_basename,
        dir_fd=workspace_descriptor,
        follow_symlinks=False,
    )
    if not private_regular(snapshot_linked):
        raise OSError("unsafe coordinator diagnostic snapshot")
    print(os.path.join(workspace, snapshot_basename))
except (OSError, ValueError):
    if snapshot_descriptor is not None:
        os.close(snapshot_descriptor)
        snapshot_descriptor = None
    if snapshot_basename is not None:
        try:
            os.unlink(snapshot_basename, dir_fd=workspace_descriptor)
        except OSError:
            pass
    raise SystemExit(1)
finally:
    if snapshot_descriptor is not None:
        os.close(snapshot_descriptor)
    if source_descriptor is not None:
        os.close(source_descriptor)
    if workspace_descriptor is not None:
        os.close(workspace_descriptor)
PY
)"; then
    return 1
  fi
  validate_coordinator_log_file "$snapshot_path" "$workspace" || return
  local -n snapshot_result=$result_name
  snapshot_result=$snapshot_path
}

display_distinct_coordinator_logs() {
  local initial_log=$1
  local current_log=$2
  local workspace=$3
  local initial_snapshot= current_snapshot=

  if ! snapshot_coordinator_log "$initial_log" "$workspace" initial_snapshot; then
    printf 'coordinator diagnostics could not be snapshotted safely\n' >&2
    return 1
  fi
  if [[ -n "$current_log" ]] && \
    ! snapshot_coordinator_log "$current_log" "$workspace" current_snapshot; then
    printf 'coordinator diagnostics could not be snapshotted safely\n' >&2
    return 1
  fi
  if [[ -z "$current_snapshot" ]] || cmp -s -- "$initial_snapshot" "$current_snapshot"; then
    printf 'Strict wheel-resolution diagnostics:\n' >&2
    redact_pip_log <"$initial_snapshot" >&2 || printf 'pip output could not be displayed safely\n' >&2
    return 0
  fi
  printf 'Initial strict wheel-resolution diagnostics:\n' >&2
  redact_pip_log <"$initial_snapshot" >&2 || printf 'initial pip output could not be displayed safely\n' >&2
  printf 'Final strict wheel-resolution diagnostics:\n' >&2
  redact_pip_log <"$current_snapshot" >&2 || printf 'final pip output could not be displayed safely\n' >&2
}

validate_repair_built_wheels_dir() {
  local repair_dir=$1
  local built_wheels_dir=$2

  task3_python -B - "$repair_dir" "$built_wheels_dir" <<'PY'
import os
import stat
import sys


repair_dir, built_wheels_dir = sys.argv[1:]
try:
    if (
        built_wheels_dir != os.path.join(repair_dir, "built-wheels")
        or not os.path.isabs(built_wheels_dir)
    ):
        raise ValueError
    for path in (repair_dir, built_wheels_dir):
        record = os.lstat(path)
        if (
            stat.S_ISLNK(record.st_mode)
            or not stat.S_ISDIR(record.st_mode)
            or record.st_uid != os.geteuid()
            or stat.S_IMODE(record.st_mode) != 0o700
        ):
            raise ValueError
except (OSError, ValueError):
    raise SystemExit(1)
PY
}

cancel_managed_child_and_exit() {
  local signal_name=$1
  local exit_status=$2
  local child_pid=${3:-}

  trap '' HUP INT TERM
  case "$signal_name:$exit_status" in
    HUP:129 | INT:130 | TERM:143)
      ;;
    *)
      exit 125
      ;;
  esac
  if [[ "$child_pid" =~ ^[1-9][0-9]*$ ]]; then
    kill -s "$signal_name" "$child_pid" 2>/dev/null || true
    wait "$child_pid" 2>/dev/null || true
  fi
  exit "$exit_status"
}

download_wheels_impl() {
  umask 077
  local requirements=$1
  local wheels_dir=$2
  local target_arch=$3
  local python_version=$4
  local bootstrap_dir=${5:-}
  local repair_dir=${6:-}
  local coordinator_workspace= initial_log= current_log=
  local abi platform
  local attempt_log missing_record requirement canonical_name uv_command
  local socks_proxy_url= socks_site_dir= local_wheels_dir= repair_status
  local active_repair_pid=
  local repair_count=0
  local -a platform_names=()
  local -a pip_command=()
  local -A repaired_candidates=()

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
  coordinator_workspace="$(mktemp -d -- /tmp/dify-plugin-coordinator.XXXXXXXX)" || return
  trap "cleanup_coordinator_workspace '$coordinator_workspace' || true" EXIT
  trap 'cancel_managed_child_and_exit INT 130 "${active_repair_pid:-}"' INT
  trap 'cancel_managed_child_and_exit TERM 143 "${active_repair_pid:-}"' TERM
  trap 'cancel_managed_child_and_exit HUP 129 "${active_repair_pid:-}"' HUP
  chmod 700 -- "$coordinator_workspace" || return
  validate_coordinator_workspace "$coordinator_workspace" || {
    printf 'failed to create a private coordinator workspace under /tmp\n' >&2
    return 1
  }
  if [[ -z "$repair_dir" ]]; then
    repair_dir="$coordinator_workspace/sdist-repair"
  fi
  initial_log="$(mktemp "$coordinator_workspace/initial.XXXXXXXX.log")" || return
  current_log="$(mktemp "$coordinator_workspace/current.XXXXXXXX.log")" || return
  chmod 600 -- "$initial_log" "$current_log" || return
  validate_coordinator_log_file "$initial_log" "$coordinator_workspace" || return
  validate_coordinator_log_file "$current_log" "$coordinator_workspace" || return

  while :; do
    reset_wheels_dir "$wheels_dir" || return
    if ((repair_count == 0)); then
      attempt_log=$initial_log
      local_wheels_dir=
    else
      attempt_log=$current_log
      local_wheels_dir="$repair_dir/built-wheels"
      if ! validate_repair_built_wheels_dir "$repair_dir" "$local_wheels_dir"; then
        printf 'validated built-wheel directory is unsafe\n' >&2
        return 1
      fi
    fi
    if download_wheels_once \
      "$requirements" "$wheels_dir" "$target_arch" "$python_version" "$attempt_log" \
      "$bootstrap_dir" "$local_wheels_dir" true false; then
      return 0
    fi
    validate_coordinator_log_file "$attempt_log" "$coordinator_workspace" || {
      printf 'strict wheel-resolution diagnostics are unsafe\n' >&2
      return 1
    }
    if ! missing_record="$(extract_missing_requirement "$attempt_log")"; then
      display_distinct_coordinator_logs "$initial_log" "$([[ "$attempt_log" == "$initial_log" ]] && printf '' || printf '%s' "$attempt_log")" "$coordinator_workspace" || true
      if ((repair_count > 0)); then
        printf 'Pure Python sdist repair failed during resolution after %s admitted wheel(s).\n' "$repair_count" >&2
      fi
      report_wheel_download_failure "$target_arch" "$python_version" "$abi" "${platform_names[@]}"
      return 1
    fi
    [[ "$missing_record" == *$'\t'* && "$missing_record" != *$'\t'*$'\t'* ]] || {
      printf 'invalid missing-wheel classification record\n' >&2
      return 1
    }
    requirement=${missing_record%%$'\t'*}
    canonical_name=${missing_record#*$'\t'}
    case "${DIFY_AUTO_BUILD_PURE_SDIST:-1}" in
      0 | false | FALSE | no | NO)
        display_distinct_coordinator_logs "$initial_log" '' "$coordinator_workspace" || true
        printf 'Automatic pure Python sdist repair is disabled by DIFY_AUTO_BUILD_PURE_SDIST.\n' >&2
        report_wheel_download_failure "$target_arch" "$python_version" "$abi" "${platform_names[@]}"
        return 1
        ;;
    esac
    uv_command=${DIFY_UV_COMMAND:-uv}
    resolve_pip_command pip_command || return
    validate_sdist_repair_identifiers \
      pip_command "$uv_command" "$requirement" "$canonical_name" "$python_version" "$((repair_count + 1))" || return
    validate_sdist_repair_dir "$repair_dir" || return
    if [[ -n "${repaired_candidates[$canonical_name]+present}" ]]; then
      display_distinct_coordinator_logs "$initial_log" "$attempt_log" "$coordinator_workspace" || true
      printf 'repeated pure Python sdist repair candidate: %s\n' "$requirement" >&2
      report_wheel_download_failure "$target_arch" "$python_version" "$abi" "${platform_names[@]}"
      return 1
    fi
    if ((repair_count >= 16)); then
      display_distinct_coordinator_logs "$initial_log" "$attempt_log" "$coordinator_workspace" || true
      printf 'pure Python sdist repair limit reached: 16\n' >&2
      report_wheel_download_failure "$target_arch" "$python_version" "$abi" "${platform_names[@]}"
      return 1
    fi
    socks_proxy_url="$(detect_socks_proxy)" || true
    if [[ -n "$socks_proxy_url" ]]; then
      validate_pip_bootstrap_dir "$bootstrap_dir" || return
    fi
    prepare_pip_socks_support pip_command "$bootstrap_dir" socks_site_dir || return
    repair_count=$((repair_count + 1))
    repaired_candidates[$canonical_name]=1
    printf 'Pure Python sdist repair candidate: %s\n' "$requirement"
    printf 'Source build target: Python %s, ABI %s, architecture %s\n' \
      "$python_version" "$abi" "$target_arch"
    repair_one_pure_sdist_impl \
      pip_command "$uv_command" "$requirement" "$canonical_name" "$python_version" \
      "$repair_dir" "$socks_site_dir" "$repair_count" &
    active_repair_pid=$!
    if wait "$active_repair_pid"; then
      repair_status=0
    else
      repair_status=$?
    fi
    active_repair_pid=
    if ((repair_status != 0)); then
      display_distinct_coordinator_logs "$initial_log" "$attempt_log" "$coordinator_workspace" || true
      printf 'Set DIFY_AUTO_BUILD_PURE_SDIST=0 to disable third-party source builds.\n' >&2
      case "$repair_status" in
        124 | 125 | 129 | 130 | 143)
          return "$repair_status"
          ;;
      esac
      report_wheel_download_failure "$target_arch" "$python_version" "$abi" "${platform_names[@]}"
      return 1
    fi
  done
}

download_wheels() {
  if [[ "${DOWNLOAD_WHEELS_RUN_IN_PLACE:-false}" == true ]]; then
    download_wheels_impl "$@"
  else
    (download_wheels_impl "$@")
  fi
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
  local package_filename staging plugin_dir output python_version download_status
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

  DOWNLOAD_WHEELS_RUN_IN_PLACE=true download_wheels \
    "$staging/download-requirements.txt" \
    "$plugin_dir/wheels" \
    "$TARGET_ARCH" \
    "$python_version" \
    "$staging/pip-bootstrap" &
  ACTIVE_DOWNLOAD_PID=$!
  if wait "$ACTIVE_DOWNLOAD_PID"; then
    download_status=0
  else
    download_status=$?
  fi
  ACTIVE_DOWNLOAD_PID=
  ((download_status == 0)) || return "$download_status"
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
  trap 'cancel_managed_child_and_exit HUP 129 "${ACTIVE_DOWNLOAD_PID:-}"' HUP
  trap 'cancel_managed_child_and_exit INT 130 "${ACTIVE_DOWNLOAD_PID:-}"' INT
  trap 'cancel_managed_child_and_exit TERM 143 "${ACTIVE_DOWNLOAD_PID:-}"' TERM

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
