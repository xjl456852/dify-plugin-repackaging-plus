# Self-Healing Offline Packaging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make offline packaging automatically recover when pip lacks SOCKS support, detect the Dify runner Python version from the plugin manifest, and produce actionable diagnostics for failures that cannot be repaired safely.

**Architecture:** Keep `plugin_repackaging.sh` as the single implementation. Add isolated helper functions for manifest parsing, proxy detection, temporary PySocks bootstrapping, and download diagnostics; all bootstrap artifacts live under the existing per-build staging directory and reach pip only through a command-scoped `PYTHONPATH`. Extend the existing shell test suite with fake pip/curl fixtures and retain the current strict no-source/no-host-architecture fallback behavior.

**Tech Stack:** Bash 4.3+, Python 3 standard library for HTML parsing, curl, pip, uv, unzip, existing Dify Plugin CLI.

---

## File map

- Modify `plugin_repackaging.sh`: production detection, temporary bootstrap, diagnostics, and staging integration.
- Modify `tests/test_repackaging.sh`: hermetic input package fixture and regression coverage.
- Modify `README.md`: automatic SOCKS handling, Python detection precedence, opt-out, and hard limits.
- Use `yangyaofei-vllm_0.2.3.difypkg` only for local acceptance; never add it to Git.

### Task 1: Restore a hermetic baseline fixture

**Files:**
- Modify: `tests/test_repackaging.sh`

- [ ] **Step 1: Run the current suite and record the baseline failure**

Run:

```bash
bash tests/test_repackaging.sh
```

Expected: FAIL because `langgenius-openai_api_compatible_0.0.57.difypkg` is absent from the repository.

- [ ] **Step 2: Replace the missing package dependency with a generated fixture**

Create a plugin tree under `$FIXTURE_DIR/input-plugin`, including `manifest.yaml`, `main.py`, `requirements.txt`, and `pyproject.toml`. Package it with Python's standard `zipfile` module into the existing path-with-spaces fixture. Use a deterministic fake Dify packager in the unit suite: it records the `plugin package <dir> -o <output>` arguments and writes the staging directory to the requested ZIP with relative archive paths. The real Dify CLI remains covered by Task 6's complete vLLM acceptance test, avoiding coupling unit tests to unrelated manifest schema and asset rules.

```bash
input_plugin_dir="$FIXTURE_DIR/input-plugin"
input_package="$FIXTURE_DIR/source plugin.difypkg"
mkdir -p "$input_plugin_dir"
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
  '  permission: {}' \
  'plugins: {}' \
  'meta:' \
  '  version: 0.0.1' \
  '  arch: [amd64, arm64]' \
  '  runner:' \
  '    language: python' \
  '    version: "3.12"' \
  '    entrypoint: main' >"$input_plugin_dir/manifest.yaml"
printf '%s\n' 'from dify_plugin import Plugin, DifyPluginEnv' 'Plugin(DifyPluginEnv()).run()' >"$input_plugin_dir/main.py"
printf '%s\n' 'dify-plugin==0.7.4' >"$input_plugin_dir/requirements.txt"
printf '%s\n' '[project]' 'name = "offline-fixture"' 'version = "0.0.1"' 'requires-python = ">=3.12"' 'dependencies = ["dify-plugin==0.7.4"]' >"$input_plugin_dir/pyproject.toml"
printf '%s\n' '<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"/>' >"$input_plugin_dir/icon.svg"
(
  cd "$input_plugin_dir"
  python3 -m zipfile -c "$input_package" manifest.yaml main.py requirements.txt pyproject.toml icon.svg
)
```

- [ ] **Step 3: Run the suite and establish a clean baseline**

Run: `bash tests/test_repackaging.sh`

Expected: exit 0 with `0 failed` before adding new behavior tests.

- [ ] **Step 4: Commit the test fixture repair**

```bash
git add tests/test_repackaging.sh
git commit -m "test: generate hermetic plugin fixture"
```

### Task 2: Detect Python from manifest runner metadata

**Files:**
- Modify: `tests/test_repackaging.sh`
- Modify: `plugin_repackaging.sh`

- [ ] **Step 1: Write failing precedence and fallback tests**

Add fixtures that prove:

```bash
printf '%s\n' 'meta:' '  runner:' '    language: python' '    version: "3.11.9"' >"$metadata_dir/manifest.yaml"
assert_eq 3.11 "$(detect_python_version "$metadata_dir")" 'manifest runner version precedes .python-version'
assert_eq 3.13 "$(DIFY_PYTHON_VERSION=3.13 detect_python_version "$metadata_dir")" 'explicit Python override precedes manifest'
printf '%s\n' 'meta:' '  runner:' '    language: python' '    version: latest' >"$metadata_dir/manifest.yaml"
assert_eq 3.12 "$(detect_python_version "$metadata_dir")" 'invalid manifest runner version falls back to .python-version'
```

Also cover a manifest without `runner` and a quoted `3.12` value.

- [ ] **Step 2: Run tests and verify RED**

Run: `bash tests/test_repackaging.sh`

Expected: the manifest precedence assertion fails with actual `3.12` because production code does not read `manifest.yaml`.

- [ ] **Step 3: Implement manifest extraction and precedence**

Add `detect_manifest_python_version()` that limits its search to the indented `runner:` mapping, strips optional single/double quotes, and prints only values accepted by `normalize_python_version`. Update `detect_python_version()` to use:

```text
DIFY_PYTHON_VERSION > manifest runner.version > .python-version > requires-python > 3.12
```

An invalid manifest value must not emit an error; it returns no candidate and allows the next source to run.

- [ ] **Step 4: Run tests and verify GREEN**

Run: `bash tests/test_repackaging.sh`

Expected: exit 0 and all new manifest tests pass.

- [ ] **Step 5: Commit**

```bash
git add plugin_repackaging.sh tests/test_repackaging.sh
git commit -m "feat: detect plugin runner Python version"
```

### Task 3: Detect SOCKS proxy requirements

**Files:**
- Modify: `tests/test_repackaging.sh`
- Modify: `plugin_repackaging.sh`

- [ ] **Step 1: Write failing proxy classification tests**

Add assertions around a wished-for `detect_socks_proxy` function. Run each assertion with all six proxy variables first removed via `env -u` so the developer's shell does not influence the suite. Cover `socks4`, `socks4a`, `socks5`, and `socks5h`, uppercase variables, ordinary HTTP proxies, and an empty environment.

- [ ] **Step 2: Run tests and verify RED**

Run: `bash tests/test_repackaging.sh`

Expected: FAIL because `detect_socks_proxy` is undefined.

- [ ] **Step 3: Implement minimal classification**

Add a function that iterates over `https_proxy`, `HTTPS_PROXY`, `http_proxy`, `HTTP_PROXY`, `all_proxy`, and `ALL_PROXY`, returning the first value whose scheme matches `socks4`, `socks4a`, `socks5`, or `socks5h` case-insensitively. It prints nothing and returns 1 when no SOCKS proxy is active.

- [ ] **Step 4: Run tests and verify GREEN**

Run: `bash tests/test_repackaging.sh`

Expected: exit 0 with every proxy classification assertion passing.

- [ ] **Step 5: Commit**

```bash
git add plugin_repackaging.sh tests/test_repackaging.sh
git commit -m "feat: detect pip SOCKS proxy requirements"
```

### Task 4: Bootstrap PySocks inside staging

**Files:**
- Modify: `tests/test_repackaging.sh`
- Modify: `plugin_repackaging.sh`

- [ ] **Step 1: Write failing self-healing tests**

Extend fake pip so it distinguishes `show PySocks`, local `install`, and `download`. Extend fake curl so it can return a controlled simple page and wheel payload. Assert these behaviors independently:

- no SOCKS proxy: no `show`, curl, or bootstrap install;
- SOCKS plus successful `show PySocks`: no curl or bootstrap install;
- SOCKS plus missing PySocks: fetch simple page, select `PySocks-1.7.1-py3-none-any.whl`, install with `--no-index --no-deps --target`, and run download with the target directory in `PYTHONPATH`;
- a first download failure containing `key_proxy_ssl_context`: preserve the original stderr and retry exactly once with `PIP_USE_DEPRECATED=legacy-certs`;
- `DIFY_AUTO_FIX_SOCKS=0`: fail before curl with a precise PySocks message;
- missing wheel link, curl failure, checksum mismatch, and local install failure: return nonzero without invoking the final dependency download.

- [ ] **Step 2: Run tests and verify RED**

Run: `bash tests/test_repackaging.sh`

Expected: the missing-PySocks case fails because no bootstrap commands are issued.

- [ ] **Step 3: Implement the temporary bootstrap helpers**

Add focused helpers for:

```text
pip_has_pysocks <pip-array-name>
resolve_pysocks_wheel <simple-html> <simple-url>
prepare_pip_socks_support <pip-array-name> <bootstrap-dir> <result-variable-name>
```

`resolve_pysocks_wheel` uses Python's `html.parser` and `urllib.parse.urljoin` to locate the exact universal 1.7.1 wheel and return its URL plus optional SHA-256 fragment. `prepare_pip_socks_support` uses `curl --fail --location --show-error`, verifies SHA-256 when provided, and executes the local pip install through:

```bash
env -u http_proxy -u https_proxy -u all_proxy \
  -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
  "${pip_command[@]}" install --disable-pip-version-check \
  --no-index --no-deps --target "$site_dir" "$wheel_file"
```

The function stores an empty result when no overlay is needed and the temporary site directory when bootstrapping succeeds.

- [ ] **Step 4: Inject the overlay only into dependency download**

Change `download_wheels` to accept a fifth `bootstrap_dir` argument, call `prepare_pip_socks_support`, and run pip with a command-scoped `PYTHONPATH` only when a site directory is returned. Pass `$staging/pip-bootstrap` from `repackage`; keep all bootstrap data outside `$plugin_dir`.

- [ ] **Step 5: Run tests and verify GREEN**

Run: `bash tests/test_repackaging.sh`

Expected: exit 0; bootstrap tests pass and existing offline-package archive assertions show no bootstrap entries.

- [ ] **Step 6: Commit**

```bash
git add plugin_repackaging.sh tests/test_repackaging.sh
git commit -m "feat: self-heal missing pip SOCKS support"
```

### Task 5: Add actionable download failure diagnostics

**Files:**
- Modify: `tests/test_repackaging.sh`
- Modify: `plugin_repackaging.sh`

- [ ] **Step 1: Write a failing diagnostic test**

Capture the existing fake-pip failure log and assert it contains:

```text
Target Python: 3.12
Target ABI: cp312
Target architecture: aarch64
Target platforms: manylinux_2_28_aarch64,manylinux2014_aarch64
Package index: <configured mirror>
```

Also assert the message says the safe automatic boundary: missing binary wheel, conflicting constraints, extra index, or unreachable proxy; it must not claim to compile or fall back to the host architecture.

- [ ] **Step 2: Run tests and verify RED**

Run: `bash tests/test_repackaging.sh`

Expected: FAIL because the current function only returns pip's status.

- [ ] **Step 3: Wrap pip download with diagnostic output**

On nonzero pip download, print the target details to stderr and return failure. Preserve pip's original output by not redirecting the command. Join the already computed platform array with commas for display.

- [ ] **Step 4: Run tests and verify GREEN**

Run: `bash tests/test_repackaging.sh`

Expected: exit 0 and the failure-path assertions pass.

- [ ] **Step 5: Commit**

```bash
git add plugin_repackaging.sh tests/test_repackaging.sh
git commit -m "feat: explain unrepairable wheel failures"
```

### Task 6: Document and verify the complete workflow

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update user documentation**

Document that normal commands now self-heal missing PySocks in staging, `DIFY_AUTO_FIX_SOCKS=0` disables it, no permanent Python environment change occurs, and Python detection follows manifest runner metadata before development files. Keep the existing binary-wheel/system-dependency limitations explicit.

- [ ] **Step 2: Run static and automated verification**

Run:

```bash
bash -n plugin_repackaging.sh plugin_repackaging_amd64_to_arm64.sh tests/test_repackaging.sh
bash tests/test_repackaging.sh
git diff --check
```

Expected: every command exits 0 and the test summary reports `0 failed`.

- [ ] **Step 3: Run the original failure as a WSL acceptance test**

Run in Ubuntu 24.04 with the existing Conda environment and SOCKS proxy variables intact:

```bash
source /opt/modules/soft/miniforge3/etc/profile.d/conda.sh
conda activate dify-plugin
cd /mnt/h/code/dify-plugin-repackaging-plus
./plugin_repackaging_amd64_to_arm64.sh local yangyaofei-vllm_0.2.3.difypkg
```

Expected: the log reports temporary PySocks preparation, downloads only aarch64 or platform-independent wheels, passes offline validation, and creates `yangyaofei-vllm_0.2.3-offline.difypkg`.

- [ ] **Step 4: Inspect the acceptance artifact**

Run:

```bash
unzip -tq yangyaofei-vllm_0.2.3-offline.difypkg
unzip -Z1 yangyaofei-vllm_0.2.3-offline.difypkg | grep -E '^wheels/.+\.whl$'
! unzip -Z1 yangyaofei-vllm_0.2.3-offline.difypkg | grep -E 'x86_64|pip-bootstrap|PySocks'
```

Expected: ZIP integrity succeeds, runtime wheels exist, and neither x86_64 nor bootstrap-only PySocks artifacts are present. PySocks is a build-tool overlay and must not be added to the plugin runtime dependency closure.

- [ ] **Step 5: Commit documentation and final integration changes**

```bash
git add README.md plugin_repackaging.sh tests/test_repackaging.sh
git commit -m "docs: explain self-healing offline builds"
```

- [ ] **Step 6: Review final scope**

Run `git status --short --branch`, `git log --oneline origin/main..HEAD`, and `git diff origin/main...HEAD --stat`. Confirm the user-provided source `.difypkg` and generated offline artifact remain untracked and are not staged.
