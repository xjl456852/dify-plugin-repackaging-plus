# Pure Python sdist Self-Healing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 当目标平台严格 wheel 下载只因某个依赖仅发布 sdist 而失败时，在临时目录自动构建并严格准入纯 Python 通用 wheel，然后重新完成 ARM64/AMD64 离线依赖解析。

**Architecture:** 保留 `download_wheels` 作为上层协调入口，把单次 wheel-only 下载、错误分类、sdist 获取、uv/PEP 517 构建和重试循环拆成独立函数。新增一个只依赖 Python 标准库的归档验证器，负责在构建前拒绝危险 sdist，并在构建后同时验证 wheel 文件名、元数据、ZIP 安全属性及原生二进制内容。最终解析仍使用目标 Python/ABI/平台和 `--only-binary=:all:`，接受的临时 wheel 只通过 `--find-links` 参与全量重新解析。

**Tech Stack:** Bash 4+、Python 3 标准库、pip download、uv 0.7.21+ / PEP 517、unittest、ZIP/TAR、现有伪命令测试框架。

---

## 文件结构

- Create: `tools/validate_python_distribution.py` — 安全检查单个 sdist 目录或 wheel 目录，输出已验证的路径、规范化名称和版本。
- Create: `tests/test_validate_python_distribution.py` — 使用标准库生成归档 fixture，覆盖归档和纯 wheel 准入边界。
- Modify: `plugin_repackaging.sh` — 增加下载输出捕获、错误分类、源码构建、准入和有界重试协调。
- Modify: `tests/test_repackaging.sh` — 覆盖 shell 编排、代理复用、失败分类、循环限制和完整归档。
- Modify: `README.md` — 说明自动源码自愈、执行第三方构建代码的风险、关闭开关和不支持原生扩展的边界。

### Task 1: 建立安全的 Python 分发归档验证器

**Files:**
- Create: `tests/test_validate_python_distribution.py`
- Create: `tools/validate_python_distribution.py`
- Modify: `tests/test_repackaging.sh`

- [ ] **Step 1: 编写验证器失败测试**

创建 `tests/test_validate_python_distribution.py`。测试通过 `subprocess.run` 调用 CLI，避免只验证内部函数。fixture 使用 `tempfile`、`tarfile` 和 `zipfile` 动态生成，不提交二进制文件。文件内容如下：

```python
from __future__ import annotations

import io
from pathlib import Path
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest
import warnings
import zipfile


ROOT = Path(__file__).resolve().parents[1]
VALIDATOR = ROOT / "tools" / "validate_python_distribution.py"


def metadata(name: str, version: str) -> bytes:
    return f"Metadata-Version: 2.1\nName: {name}\nVersion: {version}\n\n".encode()


def wheel_entries(
    name: str,
    version: str,
    root_is_purelib: str = "true",
    tag: str = "py3-none-any",
) -> dict[str, bytes]:
    dist = name.replace("-", "_")
    info = f"{dist}-{version}.dist-info"
    return {
        f"{info}/METADATA": metadata(name, version),
        f"{info}/WHEEL": (
            "Wheel-Version: 1.0\n"
            "Generator: tests\n"
            f"Root-Is-Purelib: {root_is_purelib}\n"
            f"Tag: {tag}\n\n"
        ).encode(),
        f"{dist}.py": b"VALUE = 1\n",
    }


class DistributionValidatorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def run_validator(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(VALIDATOR), *args],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def make_sdist(self, filename: str = "docopt-0.6.2.tar.gz") -> Path:
        path = self.root / filename
        with tarfile.open(path, "w:gz") as archive:
            payload = metadata("docopt", "0.6.2")
            member = tarfile.TarInfo("docopt-0.6.2/PKG-INFO")
            member.size = len(payload)
            archive.addfile(member, io.BytesIO(payload))
        return path

    def make_wheel(
        self,
        filename: str = "docopt-0.6.2-py2.py3-none-any.whl",
        entries: dict[str, bytes] | None = None,
    ) -> Path:
        path = self.root / filename
        with zipfile.ZipFile(path, "w") as archive:
            for name, payload in (entries or wheel_entries("docopt", "0.6.2")).items():
                archive.writestr(name, payload)
        return path

    def test_accepts_safe_sdist_and_reports_identity(self) -> None:
        archive = self.make_sdist()
        result = self.run_validator("sdist", str(self.root), "--name", "docopt")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), f"{archive.resolve()}\tdocopt\t0.6.2")

    def test_rejects_multiple_sdist_candidates(self) -> None:
        self.make_sdist()
        self.make_sdist("docopt-copy-0.6.2.tar.gz")
        result = self.run_validator("sdist", str(self.root), "--name", "docopt")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exactly one sdist", result.stderr)

    def test_rejects_sdist_parent_traversal(self) -> None:
        path = self.root / "docopt-0.6.2.tar.gz"
        with tarfile.open(path, "w:gz") as archive:
            payload = b"escape"
            member = tarfile.TarInfo("../escape")
            member.size = len(payload)
            archive.addfile(member, io.BytesIO(payload))
        result = self.run_validator("sdist", str(self.root), "--name", "docopt")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsafe archive path", result.stderr)

    def test_rejects_sdist_symlink(self) -> None:
        path = self.root / "docopt-0.6.2.tar.gz"
        with tarfile.open(path, "w:gz") as archive:
            member = tarfile.TarInfo("docopt-0.6.2/link")
            member.type = tarfile.SYMTYPE
            member.linkname = "/tmp/outside"
            archive.addfile(member)
        result = self.run_validator("sdist", str(self.root), "--name", "docopt")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("link entry", result.stderr)

    def test_accepts_safe_zip_sdist(self) -> None:
        path = self.root / "docopt-0.6.2.zip"
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("docopt-0.6.2/PKG-INFO", metadata("docopt", "0.6.2"))
        result = self.run_validator("sdist", str(self.root), "--name", "docopt")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), f"{path.resolve()}\tdocopt\t0.6.2")

    def test_rejects_corrupt_sdist(self) -> None:
        (self.root / "docopt-0.6.2.zip").write_bytes(b"not-a-zip")
        result = self.run_validator("sdist", str(self.root), "--name", "docopt")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid zip sdist", result.stderr)

    def test_rejects_sdist_metadata_identity_mismatch(self) -> None:
        path = self.root / "docopt-0.6.2.tar.gz"
        with tarfile.open(path, "w:gz") as archive:
            payload = metadata("other", "0.6.2")
            member = tarfile.TarInfo("docopt-0.6.2/PKG-INFO")
            member.size = len(payload)
            archive.addfile(member, io.BytesIO(payload))
        result = self.run_validator("sdist", str(self.root), "--name", "docopt")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("sdist metadata identity mismatch", result.stderr)

    def test_accepts_pure_universal_wheel(self) -> None:
        archive = self.make_wheel()
        result = self.run_validator(
            "wheel", str(self.root), "--name", "docopt", "--version", "0.6.2"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), f"{archive.resolve()}\tdocopt\t0.6.2")

    def test_rejects_platform_wheel(self) -> None:
        entries = wheel_entries(
            "docopt", "0.6.2", tag="cp312-cp312-manylinux_2_28_x86_64"
        )
        self.make_wheel("docopt-0.6.2-cp312-cp312-manylinux_2_28_x86_64.whl", entries)
        result = self.run_validator(
            "wheel", str(self.root), "--name", "docopt", "--version", "0.6.2"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("platform tag must be any", result.stderr)

    def test_rejects_abi3_wheel(self) -> None:
        entries = wheel_entries("docopt", "0.6.2", tag="cp38-abi3-any")
        self.make_wheel("docopt-0.6.2-cp38-abi3-any.whl", entries)
        result = self.run_validator(
            "wheel", str(self.root), "--name", "docopt", "--version", "0.6.2"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ABI tag must be none", result.stderr)

    def test_rejects_non_purelib_wheel(self) -> None:
        self.make_wheel(entries=wheel_entries("docopt", "0.6.2", root_is_purelib="false"))
        result = self.run_validator(
            "wheel", str(self.root), "--name", "docopt", "--version", "0.6.2"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Root-Is-Purelib must be true", result.stderr)

    def test_rejects_false_universal_wheel_with_native_suffix(self) -> None:
        entries = wheel_entries("docopt", "0.6.2")
        entries["docopt/native.so"] = b"native"
        self.make_wheel(entries=entries)
        result = self.run_validator(
            "wheel", str(self.root), "--name", "docopt", "--version", "0.6.2"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("native extension", result.stderr)

    def test_rejects_false_universal_wheel_with_elf_magic(self) -> None:
        entries = wheel_entries("docopt", "0.6.2")
        entries["docopt/payload.bin"] = b"\x7fELFpayload"
        self.make_wheel(entries=entries)
        result = self.run_validator(
            "wheel", str(self.root), "--name", "docopt", "--version", "0.6.2"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ELF binary", result.stderr)

    def test_rejects_wheel_metadata_identity_mismatch(self) -> None:
        self.make_wheel(entries=wheel_entries("other", "0.6.2"))
        result = self.run_validator(
            "wheel", str(self.root), "--name", "docopt", "--version", "0.6.2"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("metadata identity mismatch", result.stderr)

    def test_rejects_wheel_symlink(self) -> None:
        path = self.make_wheel()
        with zipfile.ZipFile(path, "a") as archive:
            link = zipfile.ZipInfo("docopt/link")
            link.create_system = 3
            link.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(link, "/tmp/outside")
        result = self.run_validator(
            "wheel", str(self.root), "--name", "docopt", "--version", "0.6.2"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("link entry", result.stderr)

    def test_rejects_duplicate_wheel_entry(self) -> None:
        path = self.make_wheel()
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(path, "a") as archive:
                archive.writestr("docopt.py", "VALUE = 2\n")
        result = self.run_validator(
            "wheel", str(self.root), "--name", "docopt", "--version", "0.6.2"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("duplicate archive entry", result.stderr)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 运行测试并确认 RED**

Run:

```bash
python3 -m unittest -v tests/test_validate_python_distribution.py
```

Expected: FAIL，原因是 `tools/validate_python_distribution.py` 不存在。

- [ ] **Step 3: 实现标准库验证器**

创建 `tools/validate_python_distribution.py`，CLI 固定为：

```text
validate_python_distribution.py sdist <directory> --name <expected-name>
validate_python_distribution.py wheel <directory> --name <expected-name> --version <expected-version>
```

实现以下完整文件；所有拒绝原因抛出 `ValidationError`，`main()` 只向 stderr 打印 `validation failed: <reason>` 并返回 1：

```python
from __future__ import annotations

import argparse
from email import policy
from email.parser import BytesParser
from pathlib import Path, PurePosixPath
import re
import stat
import sys
import tarfile
import zipfile


NATIVE_SUFFIXES = (".so", ".dll", ".pyd", ".dylib")
NATIVE_MAGICS = {
    b"\x7fELF": "ELF",
    b"MZ": "PE",
    b"\xfe\xed\xfa\xce": "Mach-O",
    b"\xce\xfa\xed\xfe": "Mach-O",
    b"\xfe\xed\xfa\xcf": "Mach-O",
    b"\xcf\xfa\xed\xfe": "Mach-O",
    b"\xca\xfe\xba\xbe": "Mach-O",
    b"\xbe\xba\xfe\xca": "Mach-O",
    b"\xca\xfe\xba\xbf": "Mach-O",
    b"\xbf\xba\xfe\xca": "Mach-O",
}


class ValidationError(Exception):
    pass


def canonicalize_name(value: str) -> str:
    return re.sub(r"[-_.]+", "-", value).lower()


def wheel_escape(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9.]+", "_", value)


def validate_member_name(name: str) -> PurePosixPath:
    if (
        not name
        or "\\" in name
        or "\x00" in name
        or name.startswith("/")
        or re.match(r"^[A-Za-z]:", name)
    ):
        raise ValidationError(f"unsafe archive path: {name!r}")
    path = PurePosixPath(name)
    if any(part in {"", ".", ".."} for part in path.parts):
        raise ValidationError(f"unsafe archive path: {name!r}")
    return path


def remember_member(path: PurePosixPath, seen: set[str]) -> None:
    key = str(path).casefold()
    if key in seen:
        raise ValidationError(f"duplicate archive entry: {path}")
    seen.add(key)


def parse_identity(payload: bytes) -> tuple[str, str]:
    message = BytesParser(policy=policy.default).parsebytes(payload)
    name = message.get("Name")
    version = message.get("Version")
    if not name or not version:
        raise ValidationError("distribution metadata has no Name or Version")
    return name, version


def read_tar_sdist(path: Path) -> bytes:
    seen: set[str] = set()
    metadata_members: list[tarfile.TarInfo] = []
    try:
        with tarfile.open(path, "r:*") as archive:
            for member in archive.getmembers():
                member_path = validate_member_name(member.name)
                remember_member(member_path, seen)
                if member.issym() or member.islnk():
                    raise ValidationError(f"link entry is not allowed: {member.name}")
                if not (member.isfile() or member.isdir()):
                    raise ValidationError(f"special archive entry is not allowed: {member.name}")
                if member.isfile() and len(member_path.parts) == 2 and member_path.name == "PKG-INFO":
                    metadata_members.append(member)
            if len(metadata_members) != 1:
                raise ValidationError(
                    f"expected exactly one top-level PKG-INFO, found {len(metadata_members)}"
                )
            stream = archive.extractfile(metadata_members[0])
            if stream is None:
                raise ValidationError("unable to read sdist PKG-INFO")
            return stream.read()
    except (tarfile.TarError, OSError) as error:
        raise ValidationError(f"invalid tar sdist: {error}") from error


def zip_entry_type(info: zipfile.ZipInfo) -> int:
    return stat.S_IFMT((info.external_attr >> 16) & 0xFFFF)


def validate_zip_entry_type(info: zipfile.ZipInfo) -> None:
    entry_type = zip_entry_type(info)
    if entry_type == stat.S_IFLNK:
        raise ValidationError(f"link entry is not allowed: {info.filename}")
    if entry_type not in {0, stat.S_IFREG, stat.S_IFDIR}:
        raise ValidationError(f"special archive entry is not allowed: {info.filename}")


def read_zip_sdist(path: Path) -> bytes:
    seen: set[str] = set()
    metadata_members: list[zipfile.ZipInfo] = []
    try:
        with zipfile.ZipFile(path) as archive:
            for info in archive.infolist():
                member_path = validate_member_name(info.filename)
                remember_member(member_path, seen)
                validate_zip_entry_type(info)
                if not info.is_dir() and len(member_path.parts) == 2 and member_path.name == "PKG-INFO":
                    metadata_members.append(info)
            if len(metadata_members) != 1:
                raise ValidationError(
                    f"expected exactly one top-level PKG-INFO, found {len(metadata_members)}"
                )
            return archive.read(metadata_members[0])
    except (zipfile.BadZipFile, OSError) as error:
        raise ValidationError(f"invalid zip sdist: {error}") from error


def read_sdist_identity(source_dir: Path, expected_name: str) -> tuple[Path, str, str]:
    if not source_dir.is_dir() or source_dir.is_symlink():
        raise ValidationError(f"sdist source directory is invalid: {source_dir}")
    candidates = sorted(
        path
        for path in source_dir.iterdir()
        if path.is_file()
        and not path.is_symlink()
        and (path.name.endswith(".tar.gz") or path.suffix == ".zip")
    )
    if len(candidates) != 1:
        raise ValidationError(f"expected exactly one sdist, found {len(candidates)}")
    archive_path = candidates[0].resolve()
    payload = (
        read_tar_sdist(archive_path)
        if archive_path.name.endswith(".tar.gz")
        else read_zip_sdist(archive_path)
    )
    name, version = parse_identity(payload)
    if canonicalize_name(name) != canonicalize_name(expected_name):
        raise ValidationError("sdist metadata identity mismatch")
    return archive_path, canonicalize_name(name), version


def native_magic(payload: bytes) -> str | None:
    for magic, label in NATIVE_MAGICS.items():
        if payload.startswith(magic):
            return label
    return None


def validate_filename_tags(wheel_path: Path, name: str, version: str) -> None:
    try:
        prefix, python_tags, abi_tags, platform_tags = wheel_path.stem.rsplit("-", 3)
    except ValueError as error:
        raise ValidationError("invalid wheel filename") from error
    expected_prefix = f"{wheel_escape(name)}-{wheel_escape(version)}"
    if prefix != expected_prefix and not re.fullmatch(
        re.escape(expected_prefix) + r"-[0-9][A-Za-z0-9_]*", prefix
    ):
        raise ValidationError("wheel filename identity mismatch")
    if not python_tags:
        raise ValidationError("wheel filename has no Python tag")
    if any(tag != "none" for tag in abi_tags.split(".")):
        raise ValidationError("wheel ABI tag must be none")
    if any(tag != "any" for tag in platform_tags.split(".")):
        raise ValidationError("wheel platform tag must be any")


def validate_wheel(wheel_dir: Path, expected_name: str, expected_version: str) -> tuple[Path, str, str]:
    if not wheel_dir.is_dir() or wheel_dir.is_symlink():
        raise ValidationError(f"wheel directory is invalid: {wheel_dir}")
    wheels = sorted(
        path
        for path in wheel_dir.iterdir()
        if path.is_file() and not path.is_symlink() and path.suffix == ".whl"
    )
    if len(wheels) != 1:
        raise ValidationError(f"expected exactly one wheel, found {len(wheels)}")
    wheel_path = wheels[0].resolve()
    seen: set[str] = set()
    metadata_paths: list[PurePosixPath] = []
    wheel_paths: list[PurePosixPath] = []
    try:
        with zipfile.ZipFile(wheel_path) as archive:
            info_by_path: dict[PurePosixPath, zipfile.ZipInfo] = {}
            for info in archive.infolist():
                member_path = validate_member_name(info.filename)
                remember_member(member_path, seen)
                validate_zip_entry_type(info)
                info_by_path[member_path] = info
                if info.is_dir():
                    continue
                lowered = member_path.name.lower()
                if lowered.endswith(NATIVE_SUFFIXES) or ".so." in lowered:
                    raise ValidationError(f"native extension is not allowed: {member_path}")
                magic = native_magic(archive.read(info)[:4])
                if magic:
                    raise ValidationError(f"{magic} binary is not allowed: {member_path}")
                if len(member_path.parts) == 2 and member_path.parts[0].endswith(".dist-info"):
                    if member_path.name == "METADATA":
                        metadata_paths.append(member_path)
                    elif member_path.name == "WHEEL":
                        wheel_paths.append(member_path)
            if len(metadata_paths) != 1 or len(wheel_paths) != 1:
                raise ValidationError("wheel must contain exactly one METADATA and one WHEEL")
            if metadata_paths[0].parent != wheel_paths[0].parent:
                raise ValidationError("METADATA and WHEEL must share one dist-info directory")
            metadata_payload = archive.read(info_by_path[metadata_paths[0]])
            wheel_payload = archive.read(info_by_path[wheel_paths[0]])
    except (zipfile.BadZipFile, OSError) as error:
        raise ValidationError(f"invalid wheel zip: {error}") from error

    metadata_name, metadata_version = parse_identity(metadata_payload)
    if (
        canonicalize_name(metadata_name) != canonicalize_name(expected_name)
        or metadata_version != expected_version
    ):
        raise ValidationError("wheel metadata identity mismatch")
    expected_dist_info = (
        f"{wheel_escape(metadata_name)}-{wheel_escape(metadata_version)}.dist-info"
    )
    if metadata_paths[0].parts[0].casefold() != expected_dist_info.casefold():
        raise ValidationError("wheel dist-info identity mismatch")
    validate_filename_tags(wheel_path, metadata_name, metadata_version)

    wheel_message = BytesParser(policy=policy.default).parsebytes(wheel_payload)
    if (wheel_message.get("Root-Is-Purelib") or "").lower() != "true":
        raise ValidationError("Root-Is-Purelib must be true")
    tags = wheel_message.get_all("Tag", [])
    if not tags:
        raise ValidationError("WHEEL metadata has no Tag")
    for tag in tags:
        try:
            _, abi_tag, platform_tag = tag.rsplit("-", 2)
        except ValueError as error:
            raise ValidationError(f"invalid WHEEL Tag: {tag}") from error
        if any(value != "none" for value in abi_tag.split(".")):
            raise ValidationError("WHEEL ABI tag must be none")
        if any(value != "any" for value in platform_tag.split(".")):
            raise ValidationError("WHEEL platform tag must be any")
    return wheel_path, canonicalize_name(metadata_name), metadata_version


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    sdist = subparsers.add_parser("sdist")
    sdist.add_argument("directory", type=Path)
    sdist.add_argument("--name", required=True)
    wheel = subparsers.add_parser("wheel")
    wheel.add_argument("directory", type=Path)
    wheel.add_argument("--name", required=True)
    wheel.add_argument("--version", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        if args.command == "sdist":
            record = read_sdist_identity(args.directory, args.name)
        else:
            record = validate_wheel(args.directory, args.name, args.version)
    except ValidationError as error:
        print(f"validation failed: {error}", file=sys.stderr)
        return 1
    print("\t".join(str(value) for value in record))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

`main()` 成功时打印制表符分隔的绝对路径、规范化项目名和版本，便于 Bash 无歧义读取。

- [ ] **Step 4: 运行验证器测试并确认 GREEN**

Run:

```bash
python3 -m unittest -v tests/test_validate_python_distribution.py
```

Expected: 16 tests，全部 `ok`。

- [ ] **Step 5: 将验证器测试接入 Bash 总套件**

在 `tests/test_repackaging.sh` 建立临时 fixture 之前加入：

```bash
if python3 -m unittest -v tests/test_validate_python_distribution.py; then
  pass 'Python distribution validator suite passes'
else
  fail 'Python distribution validator suite passes'
fi
```

Run:

```bash
bash tests/test_repackaging.sh
```

Expected: 现有断言继续通过，并新增 `ok - Python distribution validator suite passes`。

- [ ] **Step 6: 提交验证器**

```bash
git add tools/validate_python_distribution.py tests/test_validate_python_distribution.py tests/test_repackaging.sh
git commit -m "feat: validate pure Python distribution archives"
```

### Task 2: 拆分单次 pip 下载并分类缺失 wheel 错误

**Files:**
- Modify: `plugin_repackaging.sh`
- Modify: `tests/test_repackaging.sh`

- [ ] **Step 1: 编写错误分类和本地 wheel 来源测试**

在 `tests/test_repackaging.sh` 的普通 pip 下载测试后增加四组日志 fixture：

```bash
printf '%s\n' \
  'ERROR: Could not find a version that satisfies the requirement docopt (from records) (from versions: none)' \
  'ERROR: No matching distribution found for docopt' >"$FIXTURE_DIR/missing-wheel.log"
assert_eq $'docopt\tdocopt' \
  "$(extract_missing_requirement "$FIXTURE_DIR/missing-wheel.log")" \
  'exact pip missing-distribution error yields a safe repair candidate'

printf '%s\n' \
  'WARNING: Retrying after connection broken by ProxyError' \
  'ERROR: No matching distribution found for docopt' >"$FIXTURE_DIR/proxy-failure.log"
if extract_missing_requirement "$FIXTURE_DIR/proxy-failure.log" >/dev/null; then
  fail 'proxy failure is not classified as a missing wheel'
else
  pass 'proxy failure is not classified as a missing wheel'
fi

printf '%s\n' \
  'ERROR: Could not find a version that satisfies the requirement --extra-index-url=https://evil.invalid' \
  'ERROR: No matching distribution found for --extra-index-url=https://evil.invalid' >"$FIXTURE_DIR/unsafe-requirement.log"
if extract_missing_requirement "$FIXTURE_DIR/unsafe-requirement.log" >/dev/null; then
  fail 'pip option text cannot become a repair requirement'
else
  pass 'pip option text cannot become a repair requirement'
fi

printf '%s\n' \
  'Looking in indexes: https://index-user:index-secret@mirror.example/simple?token=query-secret' \
  'Proxy: socks5h://proxy-user:proxy-secret@10.10.10.10:28802' \
  >"$FIXTURE_DIR/tool-secret.log"
print_tool_log_redacted "$FIXTURE_DIR/tool-secret.log" >"$FIXTURE_DIR/tool-safe.log"
assert_file_contains "$FIXTURE_DIR/tool-safe.log" 'https://***@mirror.example/simple' 'captured tool index URL is redacted'
assert_file_contains "$FIXTURE_DIR/tool-safe.log" 'socks5h://***@10.10.10.10:28802' 'captured tool proxy URL is redacted'
assert_file_not_contains "$FIXTURE_DIR/tool-safe.log" 'index-secret' 'captured tool log hides index password'
assert_file_not_contains "$FIXTURE_DIR/tool-safe.log" 'query-secret' 'captured tool log hides query token'
assert_file_not_contains "$FIXTURE_DIR/tool-safe.log" 'proxy-secret' 'captured tool log hides proxy password'
```

扩展 `pip-download` 伪命令记录参数，然后执行：

```bash
pip_command=("$fake_bin/pip-download")
mkdir -p "$FIXTURE_DIR/local-built-wheels"
download_wheels_once \
  pip_command \
  "$metadata_dir/download.txt" \
  "$wheel_dir" \
  aarch64 \
  3.12 \
  '' \
  "$FIXTURE_DIR/one-download.stderr" \
  "$FIXTURE_DIR/local-built-wheels"
assert_file_contains "$PIP_ARGS_LOG" '--find-links' 'retry uses admitted local wheel source'
assert_file_contains "$PIP_ARGS_LOG" "$FIXTURE_DIR/local-built-wheels" 'retry passes exact local wheel directory'
assert_file_contains "$PIP_ARGS_LOG" '--only-binary=:all:' 'retry remains wheel-only'
```

- [ ] **Step 2: 运行新断言并确认 RED**

Run:

```bash
bash tests/test_repackaging.sh
```

Expected: FAIL，提示 `extract_missing_requirement: command not found` 或 `download_wheels_once: command not found`。

- [ ] **Step 3: 实现日志脱敏和候选解析**

在 `redact_url_for_log` 后增加 `print_tool_log_redacted`。该函数读取文件并输出，不覆盖原始诊断文件：

```bash
print_tool_log_redacted() {
  local log_file=$1
  [[ -f "$log_file" ]] || return 0
  python3 - "$log_file" <<'PY'
from pathlib import Path
import re
import sys
from urllib.parse import urlsplit, urlunsplit

pattern = re.compile(r"(?i)\b(?:https?|socks4a?|socks5h?)://[^\s<>\"']+")

def replace(match: re.Match[str]) -> str:
    raw = match.group(0)
    trailing = ""
    while raw and raw[-1] in "),.;]":
        trailing = raw[-1] + trailing
        raw = raw[:-1]
    try:
        parsed = urlsplit(raw)
        if not parsed.hostname:
            raise ValueError
        host = parsed.hostname
        if ":" in host:
            host = f"[{host}]"
        if parsed.port is not None:
            host = f"{host}:{parsed.port}"
        if parsed.username is not None or parsed.password is not None or "@" in parsed.netloc:
            host = f"***@{host}"
        return urlunsplit((parsed.scheme, host, parsed.path, "", "")) + trailing
    except (TypeError, ValueError):
        return "<redacted-url>" + trailing

text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
sys.stdout.write(pattern.sub(replace, text))
PY
}
```

增加 `extract_missing_requirement`。实现必须：读取完整错误文件；先拒绝 `ProxyError`、`ConnectTimeout`、`ConnectionError`、`SSLError`、`CERTIFICATE_VERIFY_FAILED`、HTTP 401/403、DNS 失败、网络不可达、连接拒绝和 `Max retries exceeded`；要求唯一的最终 `No matching distribution found for <requirement>` 与同一 requirement 的 `Could not find a version that satisfies the requirement <requirement>` 同时存在；只允许 PEP 508 名称、可选 extras 和普通版本比较符，不允许 URL、路径、分号或以 `-` 开头的值。

```bash
extract_missing_requirement() {
  local error_log=$1
  python3 - "$error_log" <<'PY'
from pathlib import Path
import re
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
network_markers = (
    "ProxyError", "ConnectTimeout", "ConnectionError", "SSLError",
    "CERTIFICATE_VERIFY_FAILED", "Temporary failure in name resolution",
    "Name or service not known", "Network is unreachable", "Connection refused",
    "Max retries exceeded", "401 Client Error", "403 Client Error",
    "THESE PACKAGES DO NOT MATCH THE HASHES", "ResolutionImpossible",
    "conflicting dependencies",
)
if any(marker.lower() in text.lower() for marker in network_markers):
    raise SystemExit(1)
matches = re.findall(r"(?m)^ERROR: No matching distribution found for (.+?)\s*$", text)
if len(set(matches)) != 1:
    raise SystemExit(1)
requirement = matches[0].strip().replace(" ", "")
if f"Could not find a version that satisfies the requirement {matches[0].strip()}" not in text:
    raise SystemExit(1)
pattern = re.compile(
    r"^([A-Za-z0-9][A-Za-z0-9._-]*)"
    r"(?:\[[A-Za-z0-9._-]+(?:,[A-Za-z0-9._-]+)*\])?"
    r"(?:(?:===|==|!=|~=|<=|>=|<|>)[A-Za-z0-9.*+!_,<>=~-]+)?$"
)
match = pattern.fullmatch(requirement)
if not match:
    raise SystemExit(1)
canonical = re.sub(r"[-_.]+", "-", match.group(1)).lower()
print(f"{requirement}\t{canonical}")
PY
}
```

- [ ] **Step 4: 提取可复用的单次下载函数**

把现有下载命令及精确的 `key_proxy_ssl_context` 重试提取为以下函数：

```bash
run_pip_with_socks_retry() {
  local pip_command_name=$1 socks_site_dir=$2 error_log=$3
  shift 3
  local -n selected_pip_command=$pip_command_name
  local first_log="${error_log}.first"

  rm -f -- "$error_log" "$first_log"
  if [[ -n "$socks_site_dir" ]]; then
    if PYTHONPATH="$socks_site_dir${PYTHONPATH:+:$PYTHONPATH}" \
      "${selected_pip_command[@]}" "$@" 2>"$first_log"; then
      mv -- "$first_log" "$error_log"
      return 0
    fi
  elif "${selected_pip_command[@]}" "$@" 2>"$first_log"; then
    mv -- "$first_log" "$error_log"
    return 0
  fi

  if grep -Fq \
      "TypeError: PoolKey.__new__() got an unexpected keyword argument 'key_proxy_ssl_context'" \
      "$first_log"; then
    {
      cat "$first_log"
      printf '%s\n' \
        'pip SOCKS support is incompatible with its truststore proxy context; retrying once with PIP_USE_DEPRECATED=legacy-certs.'
    } >"$error_log"
    rm -f -- "$first_log"
    if [[ -n "$socks_site_dir" ]]; then
      PIP_USE_DEPRECATED=legacy-certs \
      PYTHONPATH="$socks_site_dir${PYTHONPATH:+:$PYTHONPATH}" \
        "${selected_pip_command[@]}" "$@" 2>>"$error_log"
    else
      PIP_USE_DEPRECATED=legacy-certs \
        "${selected_pip_command[@]}" "$@" 2>>"$error_log"
    fi
    return
  fi
  mv -- "$first_log" "$error_log"
  return 1
}

download_wheels_once() {
  local pip_command_name=$1 requirements=$2 wheels_dir=$3 target_arch=$4
  local python_version=$5 socks_site_dir=$6 error_log=$7 local_built_wheels=$8
  local abi platform
  local -a platform_args=()
  local -a download_args=()

  reset_wheels_dir "$wheels_dir" || return
  abi="$(python_abi "$python_version")" || return
  while IFS= read -r platform; do
    [[ -n "$platform" ]] && platform_args+=(--platform "$platform")
  done < <(default_platforms "$target_arch")
  download_args=(
    download
    --index-url "$PIP_MIRROR_URL"
    --python-version "$python_version"
    --implementation cp
    --abi "$abi"
    "${platform_args[@]}"
    --only-binary=:all:
  )
  if [[ -n "$local_built_wheels" ]]; then
    download_args+=(--find-links "$local_built_wheels")
  fi
  download_args+=(--requirement "$requirements" --dest "$wheels_dir")
  run_pip_with_socks_retry \
    "$pip_command_name" "$socks_site_dir" "$error_log" "${download_args[@]}"
}
```

此任务阶段用以下 `download_wheels` 保持外部行为不变，为下一任务的协调循环建立边界：

```bash
download_wheels() {
  local requirements=$1 wheels_dir=$2 target_arch=$3 python_version=$4
  local bootstrap_dir=${5:-}
  local socks_proxy_url= socks_site_dir= error_log error_parent abi platform
  local -a pip_command=() platform_names=()

  reset_wheels_dir "$wheels_dir" || return
  if ! grep -Eq '^[[:space:]]*[^#[:space:]]' "$requirements"; then
    return 0
  fi
  socks_proxy_url="$(detect_socks_proxy)" || true
  if [[ -n "$socks_proxy_url" ]]; then
    validate_pip_bootstrap_dir "$bootstrap_dir" || return
  fi
  resolve_pip_command pip_command || return
  prepare_pip_socks_support pip_command "$bootstrap_dir" socks_site_dir || return
  error_parent="$(dirname -- "$wheels_dir")"
  error_log="$error_parent/pip-download.stderr"
  if download_wheels_once pip_command "$requirements" "$wheels_dir" \
      "$target_arch" "$python_version" "$socks_site_dir" "$error_log" ''; then
    print_tool_log_redacted "$error_log" >&2
    rm -f -- "$error_log"
    return 0
  fi
  print_tool_log_redacted "$error_log" >&2
  rm -f -- "$error_log"
  abi="$(python_abi "$python_version")" || return
  while IFS= read -r platform; do
    [[ -n "$platform" ]] && platform_names+=("$platform")
  done < <(default_platforms "$target_arch")
  report_wheel_download_failure \
    "$target_arch" "$python_version" "$abi" "${platform_names[@]}"
  return 1
}
```

- [ ] **Step 5: 运行 shell 套件并确认 GREEN**

Run:

```bash
bash -n plugin_repackaging.sh tests/test_repackaging.sh
bash tests/test_repackaging.sh
```

Expected: 语法检查 exit 0；所有测试通过；SOCKS truststore 用例仍精确下载两次。

- [ ] **Step 6: 提交下载边界重构**

```bash
git add plugin_repackaging.sh tests/test_repackaging.sh
git commit -m "refactor: classify strict wheel download failures"
```

### Task 3: 在 staging 中下载、构建并准入一个纯 Python sdist

**Files:**
- Modify: `plugin_repackaging.sh`
- Modify: `tests/test_repackaging.sh`

- [ ] **Step 1: 编写单项修复失败测试**

在 Bash 测试中用以下代码生成安全的 docopt sdist、通用 wheel、带 ELF 的伪通用 wheel和两个伪命令：

```bash
sdist_fixture_dir="$FIXTURE_DIR/sdist-fixtures"
mkdir -p "$sdist_fixture_dir"
python3 - "$sdist_fixture_dir" <<'PY'
from pathlib import Path
import io
import sys
import tarfile
import zipfile

root = Path(sys.argv[1])
metadata = b"Metadata-Version: 2.1\nName: docopt\nVersion: 0.6.2\n\n"
with tarfile.open(root / "docopt-0.6.2.tar.gz", "w:gz") as archive:
    member = tarfile.TarInfo("docopt-0.6.2/PKG-INFO")
    member.size = len(metadata)
    archive.addfile(member, io.BytesIO(metadata))
wheel = {
    "docopt-0.6.2.dist-info/METADATA": metadata,
    "docopt-0.6.2.dist-info/WHEEL": (
        b"Wheel-Version: 1.0\nRoot-Is-Purelib: true\nTag: py2-none-any\nTag: py3-none-any\n\n"
    ),
    "docopt.py": b"VALUE = 1\n",
}
for filename, native in (
    ("docopt-0.6.2-py2.py3-none-any.whl", False),
    ("docopt-0.6.2-py3-none-any-elf.whl", True),
):
    with zipfile.ZipFile(root / filename, "w") as archive:
        for name, payload in wheel.items():
            archive.writestr(name, payload)
        if native:
            archive.writestr("docopt/payload.bin", b"\x7fELFpayload")
PY

cat >"$fake_bin/pip-sdist-repair" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SDIST_PIP_LOG"
dest=
while (($#)); do
  if [[ "$1" == --dest ]]; then
    shift
    dest=${1:-}
  fi
  shift
done
[[ -n "$dest" ]]
mkdir -p "$dest"
cp -- "$SDIST_FIXTURE_DIR/docopt-0.6.2.tar.gz" "$dest/"
EOF

cat >"$fake_bin/uv-sdist-build" <<'EOF'
#!/usr/bin/env bash
printf 'cache=%s\npython-install=%s\nargs=%s\n' \
  "${UV_CACHE_DIR:-}" "${UV_PYTHON_INSTALL_DIR:-}" "$*" >>"$SDIST_UV_LOG"
if (( ${FAKE_SDIST_UV_EXIT:-0} != 0 )); then
  printf 'simulated build failure\n' >&2
  exit "$FAKE_SDIST_UV_EXIT"
fi
out=
while (($#)); do
  if [[ "$1" == --out-dir ]]; then
    shift
    out=${1:-}
  fi
  shift
done
[[ -n "$out" ]]
mkdir -p "$out"
cp -- "$SDIST_WHEEL_FIXTURE" "$out/docopt-0.6.2-py2.py3-none-any.whl"
EOF
chmod +x "$fake_bin/pip-sdist-repair" "$fake_bin/uv-sdist-build"
export SDIST_FIXTURE_DIR="$sdist_fixture_dir"
export SDIST_PIP_LOG="$FIXTURE_DIR/sdist-pip.log"
export SDIST_UV_LOG="$FIXTURE_DIR/sdist-uv.log"
export SDIST_WHEEL_FIXTURE="$sdist_fixture_dir/docopt-0.6.2-py2.py3-none-any.whl"
```

直接调用以下待实现接口：

```bash
pip_command=("$fake_bin/pip-sdist-repair")
repair_one_pure_sdist \
  pip_command \
  "$fake_bin/uv-sdist-build" \
  'docopt' \
  'docopt' \
  '3.12' \
  "$FIXTURE_DIR/sdist-repair" \
  '' \
  1
```

然后加入精确断言：

```bash
assert_file_contains "$SDIST_PIP_LOG" '--index-url' 'sdist download receives an index'
assert_file_contains "$SDIST_PIP_LOG" "$PIP_MIRROR_URL" 'sdist download uses configured index'
assert_file_contains "$SDIST_PIP_LOG" '--python-version 3.12' 'sdist selection targets plugin Python'
assert_file_contains "$SDIST_PIP_LOG" '--no-deps' 'sdist selection downloads one package'
assert_file_contains "$SDIST_PIP_LOG" '--no-binary=:all:' 'sdist selection requires source'
assert_file_contains "$SDIST_UV_LOG" 'args=build --wheel --no-config' 'uv performs an isolated wheel build'
assert_file_contains "$SDIST_UV_LOG" '--python 3.12' 'uv build uses target Python'
assert_file_contains "$SDIST_UV_LOG" '--index-url' 'uv build receives configured index'
assert_file_contains "$SDIST_UV_LOG" "cache=$FIXTURE_DIR/sdist-repair/uv-cache" 'uv cache stays in repair staging'
assert_file_contains "$SDIST_UV_LOG" "python-install=$FIXTURE_DIR/sdist-repair/uv-python" 'uv Python stays in repair staging'
if [[ -f "$FIXTURE_DIR/sdist-repair/built-wheels/docopt-0.6.2-py2.py3-none-any.whl" ]]; then
  pass 'validated pure wheel enters local built wheel directory'
else
  fail 'validated pure wheel enters local built wheel directory'
fi

rm -rf -- "$FIXTURE_DIR/sdist-repair"
export SDIST_WHEEL_FIXTURE="$sdist_fixture_dir/docopt-0.6.2-py3-none-any-elf.whl"
if repair_one_pure_sdist \
    pip_command "$fake_bin/uv-sdist-build" docopt docopt 3.12 \
    "$FIXTURE_DIR/sdist-repair" '' 1 \
    >"$FIXTURE_DIR/native-repair.log" 2>&1; then
  fail 'native content cannot be admitted as a universal wheel'
else
  pass 'native content cannot be admitted as a universal wheel'
fi
assert_file_contains "$FIXTURE_DIR/native-repair.log" 'ELF binary' 'native rejection reports its content type'
assert_file_missing "$FIXTURE_DIR/sdist-repair/built-wheels/docopt-0.6.2-py2.py3-none-any.whl" 'rejected wheel never enters local source'
export SDIST_WHEEL_FIXTURE="$sdist_fixture_dir/docopt-0.6.2-py2.py3-none-any.whl"

rm -rf -- "$FIXTURE_DIR/sdist-repair"
if FAKE_SDIST_UV_EXIT=73 repair_one_pure_sdist \
    pip_command "$fake_bin/uv-sdist-build" docopt docopt 3.12 \
    "$FIXTURE_DIR/sdist-repair" '' 1 \
    >"$FIXTURE_DIR/build-failure.log" 2>&1; then
  fail 'PEP 517 build failure stops source repair'
else
  pass 'PEP 517 build failure stops source repair'
fi
assert_file_contains "$FIXTURE_DIR/build-failure.log" 'simulated build failure' 'build failure preserves tool output'
assert_file_contains "$FIXTURE_DIR/build-failure.log" 'failed during build: docopt' 'build failure reports its stage'
assert_file_missing "$FIXTURE_DIR/sdist-repair/built-wheels/docopt-0.6.2-py2.py3-none-any.whl" 'build failure admits no wheel'
```

- [ ] **Step 2: 运行单项修复测试并确认 RED**

Run:

```bash
bash tests/test_repackaging.sh
```

Expected: FAIL，提示 `repair_one_pure_sdist: command not found`。

- [ ] **Step 3: 实现安全 staging 路径与 sdist 下载**

增加以下路径检查；它只接受叶目录名 `sdist-repair`，且父目录不能是 `/`、`.` 或自身：

```bash
validate_sdist_repair_dir() {
  local repair_dir=$1 parent
  if [[ -z "$repair_dir" || "$(basename -- "$repair_dir")" != sdist-repair ]]; then
    printf 'safe sdist repair directory is required\n' >&2
    return 1
  fi
  parent="$(dirname -- "$repair_dir")"
  if [[ "$parent" == / || "$parent" == . || "$parent" == "$repair_dir" ]]; then
    printf 'safe sdist repair directory is required\n' >&2
    return 1
  fi
}
```

增加下载函数：

```bash
download_sdist() {
  local pip_command_name=$1 requirement=$2 python_version=$3
  local source_dir=$4 socks_site_dir=$5 error_log=$6
  local -n selected_pip_command=$pip_command_name
  local -a args=(
    download
    --index-url "$PIP_MIRROR_URL"
    --python-version "$python_version"
    --implementation cp
    --no-deps
    --no-binary=:all:
    --dest "$source_dir"
    "$requirement"
  )
  mkdir -p "$source_dir"
  run_pip_with_socks_retry \
    "$pip_command_name" "$socks_site_dir" "$error_log" "${args[@]}"
}
```

requirement 始终作为数组中的一个参数，不能通过 `eval` 或重新拆词执行。下载失败时使用 `print_tool_log_redacted`，并输出脱敏后的镜像地址。

- [ ] **Step 4: 实现 uv/PEP 517 构建和准入**

实现完整的 `repair_one_pure_sdist`：

```bash
repair_one_pure_sdist() {
  local pip_command_name=$1 uv_command=$2 requirement=$3 canonical_name=$4
  local python_version=$5 repair_dir=$6 socks_site_dir=$7 ordinal=$8
  local candidate_dir="$repair_dir/candidate-$ordinal"
  local source_dir="$candidate_dir/source"
  local wheel_dir="$candidate_dir/wheel"
  local source_log="$candidate_dir/sdist-download.log"
  local build_log="$candidate_dir/build.log"
  local record sdist_path metadata_name metadata_version wheel_record wheel_path

  validate_sdist_repair_dir "$repair_dir" || return
  mkdir -p "$source_dir" "$wheel_dir" "$repair_dir/built-wheels"
  if ! download_sdist "$pip_command_name" "$requirement" "$python_version" \
      "$source_dir" "$socks_site_dir" "$source_log"; then
    print_tool_log_redacted "$source_log" >&2
    printf 'Pure Python sdist repair failed during download: %s (index: %s)\n' \
      "$requirement" "$(redact_url_for_log "$PIP_MIRROR_URL")" >&2
    return 1
  fi
  if ! record="$(python3 "$SCRIPT_DIR/tools/validate_python_distribution.py" \
      sdist "$source_dir" --name "$canonical_name")"; then
    printf 'Pure Python sdist repair failed during validation: %s\n' "$requirement" >&2
    return 1
  fi
  IFS=$'\t' read -r sdist_path metadata_name metadata_version <<<"$record"

  if ! UV_CACHE_DIR="$repair_dir/uv-cache" \
      UV_PYTHON_INSTALL_DIR="$repair_dir/uv-python" \
      "$uv_command" build --wheel --no-config \
        --out-dir "$wheel_dir" \
        --python "$python_version" \
        --index-url "$PIP_MIRROR_URL" \
        "$sdist_path" >"$build_log" 2>&1; then
    print_tool_log_redacted "$build_log" >&2
    printf 'Pure Python sdist repair failed during build: %s\n' "$requirement" >&2
    return 1
  fi
  if ! wheel_record="$(python3 "$SCRIPT_DIR/tools/validate_python_distribution.py" \
      wheel "$wheel_dir" --name "$metadata_name" --version "$metadata_version")"; then
    printf 'Pure Python sdist repair failed during validation: %s\n' "$requirement" >&2
    return 1
  fi
  IFS=$'\t' read -r wheel_path _ _ <<<"$wheel_record"
  cp -- "$wheel_path" "$repair_dir/built-wheels/$(basename "$wheel_path")"
}
```

函数开始构建前打印目标 Python 和 requirement；不得打印未脱敏 URL。失败时不得复制候选 wheel。uv 找不到精确目标 Python 时直接传播非零状态，不尝试宿主的其他 Python 版本。

- [ ] **Step 5: 运行单元与 shell 套件并确认 GREEN**

Run:

```bash
python3 -m unittest -v tests/test_validate_python_distribution.py
bash tests/test_repackaging.sh
```

Expected: 全部通过；ELF 候选被拒绝；调用者 Python/Conda 中没有新增包。

- [ ] **Step 6: 提交单项 sdist 修复**

```bash
git add plugin_repackaging.sh tests/test_repackaging.sh
git commit -m "feat: build isolated pure Python wheels from sdist"
```

### Task 4: 增加有界自愈循环和完整依赖重新解析

**Files:**
- Modify: `plugin_repackaging.sh`
- Modify: `tests/test_repackaging.sh`

- [ ] **Step 1: 编写端到端协调器失败测试**

创建一个可切换场景的伪 pip。源码分支动态生成安全 sdist，严格分支按计数报告缺失依赖或把 `--find-links` 中已准入的 wheel 复制到最终目录：

```bash
cat >"$fake_bin/pip-repair-loop" <<'EOF'
#!/usr/bin/env bash
kind=strict
dest=
find_links=
last=
all_args=$*
for argument in "$@"; do
  last=$argument
  [[ "$argument" == --no-binary=:all: ]] && kind=sdist
done
while (($#)); do
  case "$1" in
    --dest)
      shift
      dest=${1:-}
      ;;
    --find-links)
      shift
      find_links=${1:-}
      ;;
  esac
  shift
done
printf '%s|%s|%s\n' "$kind" "$find_links" "$all_args" >>"$REPAIR_LOOP_PIP_LOG"
[[ -n "$dest" ]]
mkdir -p "$dest"

if [[ "$kind" == sdist ]]; then
  REPAIR_REQUEST="$last" REPAIR_DEST="$dest" python3 - <<'PY'
from pathlib import Path
import io
import os
import re
import tarfile

requirement = os.environ["REPAIR_REQUEST"]
name = re.match(r"[A-Za-z0-9][A-Za-z0-9._-]*", requirement).group(0)
version = "0.6.2" if name == "docopt" else "1.0"
normalized = re.sub(r"[-_.]+", "-", name).lower()
payload = f"Metadata-Version: 2.1\nName: {normalized}\nVersion: {version}\n\n".encode()
path = Path(os.environ["REPAIR_DEST"]) / f"{normalized}-{version}.tar.gz"
with tarfile.open(path, "w:gz") as archive:
    member = tarfile.TarInfo(f"{normalized}-{version}/PKG-INFO")
    member.size = len(payload)
    archive.addfile(member, io.BytesIO(payload))
PY
  exit 0
fi

count=$(cat "$REPAIR_LOOP_STATE" 2>/dev/null || printf '0')
count=$((count + 1))
printf '%s\n' "$count" >"$REPAIR_LOOP_STATE"
case "$REPAIR_LOOP_SCENARIO" in
  normal)
    touch "$dest/runtime-1.0-py3-none-any.whl"
    exit 0
    ;;
  docopt)
    if [[ -n "$find_links" && -f "$find_links/docopt-0.6.2-py2.py3-none-any.whl" ]]; then
      cp -- "$find_links/docopt-0.6.2-py2.py3-none-any.whl" "$dest/"
      touch "$dest/runtime-1.0-py3-none-any.whl"
      exit 0
    fi
    missing=docopt
    ;;
  two)
    if ((count == 1)); then missing=first-pure
    elif ((count == 2)); then missing=second-pure
    else
      cp -- "$find_links"/*.whl "$dest/"
      touch "$dest/runtime-1.0-py3-none-any.whl"
      exit 0
    fi
    ;;
  repeat)
    missing=docopt
    ;;
  limit)
    missing="pure-$count"
    ;;
  network)
    printf '%s\n' \
      'WARNING: Retrying after ConnectTimeout' \
      'ERROR: Could not find a version that satisfies the requirement docopt (from versions: none)' \
      'ERROR: No matching distribution found for docopt' >&2
    exit 1
    ;;
  auth)
    printf '%s\n' \
      'ERROR: 403 Client Error: Forbidden for url: https://user:secret@mirror.example/simple/docopt/' \
      'ERROR: Could not find a version that satisfies the requirement docopt (from versions: none)' \
      'ERROR: No matching distribution found for docopt' >&2
    exit 1
    ;;
  hash)
    printf '%s\n' 'ERROR: THESE PACKAGES DO NOT MATCH THE HASHES FROM THE REQUIREMENTS FILE.' >&2
    exit 1
    ;;
  conflict)
    printf '%s\n' 'ERROR: ResolutionImpossible: conflicting dependencies' >&2
    exit 1
    ;;
  *)
    exit 90
    ;;
esac
printf '%s\n' \
  "ERROR: Could not find a version that satisfies the requirement $missing (from versions: none)" \
  "ERROR: No matching distribution found for $missing" >&2
exit 1
EOF

cat >"$fake_bin/uv-repair-loop" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then
  printf 'uv 0.11.24\n'
  exit 0
fi
if [[ "${1:-}" == pip || "${1:-}" == sync ]]; then
  exit 0
fi
printf '%s\n' "$*" >>"$REPAIR_LOOP_UV_LOG"
out=
source_archive=
while (($#)); do
  if [[ "$1" == --out-dir ]]; then
    shift
    out=${1:-}
  elif [[ -f "$1" && ( "$1" == *.tar.gz || "$1" == *.zip ) ]]; then
    source_archive=$1
  fi
  shift
done
[[ -n "$out" && -n "$source_archive" ]]
REPAIR_SOURCE="$source_archive" REPAIR_OUT="$out" python3 - <<'PY'
from email import policy
from email.parser import BytesParser
from pathlib import Path
import os
import re
import tarfile
import zipfile

with tarfile.open(os.environ["REPAIR_SOURCE"], "r:*") as source:
    member = next(item for item in source.getmembers() if item.name.endswith("/PKG-INFO"))
    message = BytesParser(policy=policy.default).parsebytes(source.extractfile(member).read())
name = message["Name"]
version = message["Version"]
dist = re.sub(r"[^A-Za-z0-9.]+", "_", name)
python_tag = "py2.py3" if name == "docopt" else "py3"
wheel_name = f"{dist}-{version}-{python_tag}-none-any.whl"
wheel_metadata = (
    "Wheel-Version: 1.0\nRoot-Is-Purelib: true\n"
    + ("Tag: py2-none-any\nTag: py3-none-any\n\n" if name == "docopt" else "Tag: py3-none-any\n\n")
).encode()
output = Path(os.environ["REPAIR_OUT"])
output.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(output / wheel_name, "w") as archive:
    archive.writestr(
        f"{dist}-{version}.dist-info/METADATA",
        f"Metadata-Version: 2.1\nName: {name}\nVersion: {version}\n\n",
    )
    archive.writestr(f"{dist}-{version}.dist-info/WHEEL", wheel_metadata)
    archive.writestr(f"{dist}.py", "VALUE = 1\n")
PY
EOF
chmod +x "$fake_bin/pip-repair-loop" "$fake_bin/uv-repair-loop"
export REPAIR_LOOP_PIP_LOG="$FIXTURE_DIR/repair-loop-pip.log"
export REPAIR_LOOP_UV_LOG="$FIXTURE_DIR/repair-loop-uv.log"
export REPAIR_LOOP_STATE="$FIXTURE_DIR/repair-loop.state"
printf 'runtime==1.0\n' >"$FIXTURE_DIR/repair-requirements.txt"
```

先执行 docopt 成功场景并精确断言完整重试：

```bash
repair_case="$FIXTURE_DIR/repair-docopt"
rm -rf -- "$repair_case"
mkdir -p "$repair_case"
: >"$REPAIR_LOOP_PIP_LOG"
: >"$REPAIR_LOOP_UV_LOG"
rm -f -- "$REPAIR_LOOP_STATE"
if REPAIR_LOOP_SCENARIO=docopt \
  DIFY_PIP_COMMAND="$fake_bin/pip-repair-loop" \
  DIFY_UV_COMMAND="$fake_bin/uv-repair-loop" \
  without_proxy_environment download_wheels \
    "$FIXTURE_DIR/repair-requirements.txt" "$repair_case/wheels" \
    aarch64 3.12 "$repair_case/pip-bootstrap" "$repair_case/sdist-repair"; then
  pass 'docopt source-only dependency is repaired generically'
else
  fail 'docopt source-only dependency is repaired generically'
fi
assert_eq 2 "$(grep -c '^strict|' "$REPAIR_LOOP_PIP_LOG")" 'repair reruns strict target resolution once'
assert_eq 1 "$(grep -c '^sdist|' "$REPAIR_LOOP_PIP_LOG")" 'repair downloads one source distribution'
assert_eq 1 "$(wc -l <"$REPAIR_LOOP_UV_LOG")" 'repair builds one source distribution'
assert_eq 2 "$(grep '^strict|' "$REPAIR_LOOP_PIP_LOG" | grep -c -- '--only-binary=:all:')" 'every target resolution remains wheel-only'
assert_file_contains "$REPAIR_LOOP_PIP_LOG" "$repair_case/sdist-repair/built-wheels" 'retry uses admitted local wheel source'
if [[ -f "$repair_case/wheels/docopt-0.6.2-py2.py3-none-any.whl" ]]; then
  pass 'final target wheelhouse contains admitted docopt wheel'
else
  fail 'final target wheelhouse contains admitted docopt wheel'
fi
```

使用相同伪命令增加以下场景断言；每个场景前清空两个日志、状态文件并创建独立 case 目录：

```bash
# Disabled: one strict call, zero sdist/build calls, explicit switch message.
case_dir="$FIXTURE_DIR/repair-disabled"
: >"$REPAIR_LOOP_PIP_LOG"; : >"$REPAIR_LOOP_UV_LOG"; rm -f -- "$REPAIR_LOOP_STATE"
rm -rf -- "$case_dir"; mkdir -p "$case_dir"
if REPAIR_LOOP_SCENARIO=docopt DIFY_AUTO_BUILD_PURE_SDIST=0 \
  DIFY_PIP_COMMAND="$fake_bin/pip-repair-loop" DIFY_UV_COMMAND="$fake_bin/uv-repair-loop" \
  without_proxy_environment download_wheels "$FIXTURE_DIR/repair-requirements.txt" \
    "$case_dir/wheels" aarch64 3.12 "$case_dir/pip-bootstrap" "$case_dir/sdist-repair" \
    >"$case_dir/output.log" 2>&1; then fail 'disabled repair fails'; else pass 'disabled repair fails'; fi
assert_eq 1 "$(grep -c '^strict|' "$REPAIR_LOOP_PIP_LOG")" 'disabled repair runs one strict download'
assert_eq 0 "$(grep -c '^sdist|' "$REPAIR_LOOP_PIP_LOG")" 'disabled repair downloads no source'
assert_file_contains "$case_dir/output.log" 'disabled by DIFY_AUTO_BUILD_PURE_SDIST' 'disabled repair explains the switch'

# Two candidates: three strict calls, two sdist calls and two uv builds.
case_dir="$FIXTURE_DIR/repair-two"
: >"$REPAIR_LOOP_PIP_LOG"; : >"$REPAIR_LOOP_UV_LOG"; rm -f -- "$REPAIR_LOOP_STATE"
rm -rf -- "$case_dir"; mkdir -p "$case_dir"
REPAIR_LOOP_SCENARIO=two DIFY_PIP_COMMAND="$fake_bin/pip-repair-loop" \
  DIFY_UV_COMMAND="$fake_bin/uv-repair-loop" without_proxy_environment download_wheels \
  "$FIXTURE_DIR/repair-requirements.txt" "$case_dir/wheels" aarch64 3.12 \
  "$case_dir/pip-bootstrap" "$case_dir/sdist-repair"
assert_eq 3 "$(grep -c '^strict|' "$REPAIR_LOOP_PIP_LOG")" 'two candidates cause two full retries'
assert_eq 2 "$(grep -c '^sdist|' "$REPAIR_LOOP_PIP_LOG")" 'two candidates download two sdists'
assert_eq 2 "$(wc -l <"$REPAIR_LOOP_UV_LOG")" 'two candidates build twice'

# Repeated candidate: one build only, then explicit loop failure.
case_dir="$FIXTURE_DIR/repair-repeat"
: >"$REPAIR_LOOP_PIP_LOG"; : >"$REPAIR_LOOP_UV_LOG"; rm -f -- "$REPAIR_LOOP_STATE"
rm -rf -- "$case_dir"; mkdir -p "$case_dir"
if REPAIR_LOOP_SCENARIO=repeat DIFY_PIP_COMMAND="$fake_bin/pip-repair-loop" \
  DIFY_UV_COMMAND="$fake_bin/uv-repair-loop" without_proxy_environment download_wheels \
  "$FIXTURE_DIR/repair-requirements.txt" "$case_dir/wheels" aarch64 3.12 \
  "$case_dir/pip-bootstrap" "$case_dir/sdist-repair" >"$case_dir/output.log" 2>&1; then
  fail 'repeated candidate stops repair'; else pass 'repeated candidate stops repair'; fi
assert_eq 1 "$(wc -l <"$REPAIR_LOOP_UV_LOG")" 'repeated candidate is not rebuilt'
assert_file_contains "$case_dir/output.log" 'repeated pure Python sdist repair candidate' 'repeat failure is explicit'

# Limit: 17 strict failures expose 17 names, but only 16 builds run.
case_dir="$FIXTURE_DIR/repair-limit"
: >"$REPAIR_LOOP_PIP_LOG"; : >"$REPAIR_LOOP_UV_LOG"; rm -f -- "$REPAIR_LOOP_STATE"
rm -rf -- "$case_dir"; mkdir -p "$case_dir"
if REPAIR_LOOP_SCENARIO=limit DIFY_PIP_COMMAND="$fake_bin/pip-repair-loop" \
  DIFY_UV_COMMAND="$fake_bin/uv-repair-loop" without_proxy_environment download_wheels \
  "$FIXTURE_DIR/repair-requirements.txt" "$case_dir/wheels" aarch64 3.12 \
  "$case_dir/pip-bootstrap" "$case_dir/sdist-repair" >"$case_dir/output.log" 2>&1; then
  fail 'repair limit stops the loop'; else pass 'repair limit stops the loop'; fi
assert_eq 16 "$(wc -l <"$REPAIR_LOOP_UV_LOG")" 'repair limit permits exactly sixteen builds'
assert_file_contains "$case_dir/output.log" 'pure Python sdist repair limit reached: 16' 'repair limit is explicit'

# Network/auth/hash/conflict: none may execute source download or uv build.
for blocked_scenario in network auth hash conflict; do
  case_dir="$FIXTURE_DIR/repair-$blocked_scenario"
  : >"$REPAIR_LOOP_PIP_LOG"; : >"$REPAIR_LOOP_UV_LOG"; rm -f -- "$REPAIR_LOOP_STATE"
  rm -rf -- "$case_dir"; mkdir -p "$case_dir"
  if REPAIR_LOOP_SCENARIO="$blocked_scenario" DIFY_PIP_COMMAND="$fake_bin/pip-repair-loop" \
    DIFY_UV_COMMAND="$fake_bin/uv-repair-loop" without_proxy_environment download_wheels \
    "$FIXTURE_DIR/repair-requirements.txt" "$case_dir/wheels" aarch64 3.12 \
    "$case_dir/pip-bootstrap" "$case_dir/sdist-repair" >"$case_dir/output.log" 2>&1; then
    fail "$blocked_scenario error stops packaging"
  else
    pass "$blocked_scenario error stops packaging"
  fi
  assert_eq 0 "$(grep -c '^sdist|' "$REPAIR_LOOP_PIP_LOG")" "$blocked_scenario error downloads no sdist"
  assert_eq 0 "$(wc -l <"$REPAIR_LOOP_UV_LOG")" "$blocked_scenario error runs no build"
done

# Normal success: no source-repair directory is created.
case_dir="$FIXTURE_DIR/repair-normal"
: >"$REPAIR_LOOP_PIP_LOG"; : >"$REPAIR_LOOP_UV_LOG"; rm -f -- "$REPAIR_LOOP_STATE"
rm -rf -- "$case_dir"; mkdir -p "$case_dir"
REPAIR_LOOP_SCENARIO=normal DIFY_PIP_COMMAND="$fake_bin/pip-repair-loop" \
  DIFY_UV_COMMAND="$fake_bin/uv-repair-loop" without_proxy_environment download_wheels \
  "$FIXTURE_DIR/repair-requirements.txt" "$case_dir/wheels" aarch64 3.12 \
  "$case_dir/pip-bootstrap" "$case_dir/sdist-repair"
assert_file_missing "$case_dir/sdist-repair" 'normal wheel path creates no source repair directory'
```

- [ ] **Step 2: 运行协调器测试并确认 RED**

Run:

```bash
bash tests/test_repackaging.sh
```

Expected: 首个自愈用例 FAIL，因为 `download_wheels` 尚未调用 `repair_one_pure_sdist`。

- [ ] **Step 3: 将 `download_wheels` 改为有界协调器**

保持原五个参数并新增可选第六参数 `repair_dir`；默认值为 `$(dirname "$wheels_dir")/sdist-repair`。首次成功不创建它。先增加两个小函数：

```bash
pure_sdist_repair_enabled() {
  case "${DIFY_AUTO_BUILD_PURE_SDIST:-1}" in
    0 | false | FALSE | no | NO)
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

print_distinct_download_logs() {
  local initial_log=$1 current_log=$2
  print_tool_log_redacted "$initial_log" >&2
  if [[ "$current_log" != "$initial_log" ]] && ! cmp -s -- "$initial_log" "$current_log"; then
    print_tool_log_redacted "$current_log" >&2
  fi
}
```

然后用以下协调器替换 Task 2 的临时 `download_wheels`：

```bash
download_wheels() {
  local requirements=$1 wheels_dir=$2 target_arch=$3 python_version=$4
  local bootstrap_dir=${5:-}
  local repair_dir=${6:-"$(dirname -- "$wheels_dir")/sdist-repair"}
  local uv_command=${DIFY_UV_COMMAND:-uv}
  local socks_proxy_url= socks_site_dir= built_wheels=
  local error_parent download_error_log initial_error_log candidate_record
  local requirement canonical_name abi platform
  local repair_count=0 repair_limit=16
  local -a pip_command=() platform_names=()
  local -A repaired_requirements=()

  reset_wheels_dir "$wheels_dir" || return
  if ! grep -Eq '^[[:space:]]*[^#[:space:]]' "$requirements"; then
    return 0
  fi
  socks_proxy_url="$(detect_socks_proxy)" || true
  if [[ -n "$socks_proxy_url" ]]; then
    validate_pip_bootstrap_dir "$bootstrap_dir" || return
  fi
  resolve_pip_command pip_command || return
  prepare_pip_socks_support pip_command "$bootstrap_dir" socks_site_dir || return
  error_parent="$(dirname -- "$wheels_dir")"
  download_error_log="$error_parent/pip-download.stderr"
  initial_error_log="$error_parent/pip-download-initial.stderr"
  rm -f -- "$download_error_log" "$initial_error_log"
  abi="$(python_abi "$python_version")" || return
  while IFS= read -r platform; do
    [[ -n "$platform" ]] && platform_names+=("$platform")
  done < <(default_platforms "$target_arch")

  while true; do
    if download_wheels_once pip_command "$requirements" "$wheels_dir" \
        "$target_arch" "$python_version" "$socks_site_dir" \
        "$download_error_log" "$built_wheels"; then
      print_tool_log_redacted "$download_error_log" >&2
      rm -f -- "$download_error_log" "$initial_error_log"
      return 0
    fi
    if [[ ! -f "$initial_error_log" ]]; then
      cp -- "$download_error_log" "$initial_error_log"
    fi
    if ! candidate_record="$(extract_missing_requirement "$download_error_log")"; then
      print_distinct_download_logs "$initial_error_log" "$download_error_log"
      if ((repair_count > 0)); then
        printf 'Pure Python sdist repair failed during resolution after %s admitted wheel(s).\n' \
          "$repair_count" >&2
      fi
      report_wheel_download_failure \
        "$target_arch" "$python_version" "$abi" "${platform_names[@]}"
      return 1
    fi
    IFS=$'\t' read -r requirement canonical_name <<<"$candidate_record"
    if ! pure_sdist_repair_enabled; then
      print_distinct_download_logs "$initial_error_log" "$download_error_log"
      report_wheel_download_failure \
        "$target_arch" "$python_version" "$abi" "${platform_names[@]}"
      printf '%s\n' \
        'Automatic pure Python sdist repair is disabled by DIFY_AUTO_BUILD_PURE_SDIST.' >&2
      return 1
    fi
    if [[ -n "${repaired_requirements[$canonical_name]:-}" ]]; then
      print_distinct_download_logs "$initial_error_log" "$download_error_log"
      printf 'repeated pure Python sdist repair candidate: %s\n' "$requirement" >&2
      return 1
    fi
    if ((repair_count >= repair_limit)); then
      print_distinct_download_logs "$initial_error_log" "$download_error_log"
      printf 'pure Python sdist repair limit reached: %s\n' "$repair_limit" >&2
      return 1
    fi
    validate_sdist_repair_dir "$repair_dir" || return
    mkdir -p "$repair_dir"
    repaired_requirements[$canonical_name]=1
    repair_count=$((repair_count + 1))
    printf 'Pure Python sdist repair candidate: %s\n' "$requirement"
    printf 'Source build target: Python %s, ABI %s, architecture %s\n' \
      "$python_version" "$abi" "$target_arch"
    if ! repair_one_pure_sdist pip_command "$uv_command" "$requirement" \
        "$canonical_name" "$python_version" "$repair_dir" \
        "$socks_site_dir" "$repair_count"; then
      print_distinct_download_logs "$initial_error_log" "$download_error_log"
      printf '%s\n' \
        'Set DIFY_AUTO_BUILD_PURE_SDIST=0 to disable third-party source builds.' >&2
      return 1
    fi
    built_wheels="$repair_dir/built-wheels"
  done
}
```

`repair_one_pure_sdist` 在复制成功后增加：

```bash
printf 'Pure Python wheel admitted: %s\n' "$(basename -- "$wheel_path")"
```

把 `report_wheel_download_failure` 的最后一行替换为：

```bash
'Only validated pure Python universal wheels may be built from source; native source builds and build-host architecture fallbacks remain disabled.'
```

- [ ] **Step 4: 运行所有协调测试并确认 GREEN**

Run:

```bash
bash -n plugin_repackaging.sh tests/test_repackaging.sh
bash tests/test_repackaging.sh
```

Expected: 全部通过；正常路径没有源码目录；多项修复成功；重复和 16 项上限明确终止。

- [ ] **Step 5: 提交协调循环**

```bash
git add plugin_repackaging.sh tests/test_repackaging.sh
git commit -m "feat: retry wheel resolution with validated pure wheels"
```

### Task 5: 验证完整 `.difypkg` 边界并更新使用文档

**Files:**
- Modify: `tests/test_repackaging.sh`
- Modify: `README.md`

- [ ] **Step 1: 编写完整归档自愈失败测试**

复用现有 `input_package`、`GENERATED_TEST_OUTPUT` 和伪 packager，增加以下完整命令。伪 pip 首次报告 docopt，伪 uv 构建安全 wheel，第二次严格下载成功：

```bash
rm -f -- "$GENERATED_TEST_OUTPUT" "$REPAIR_LOOP_STATE"
: >"$REPAIR_LOOP_PIP_LOG"
: >"$REPAIR_LOOP_UV_LOG"
if env -u http_proxy -u https_proxy -u all_proxy \
  -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
  REPAIR_LOOP_SCENARIO=docopt \
  DIFY_PIP_COMMAND="$fake_bin/pip-repair-loop" \
  DIFY_UV_COMMAND="$fake_bin/uv-repair-loop" \
  DIFY_PACKAGER_BINARY="$fake_bin/dify-packager" \
  DIFY_TARGET_ARCH=aarch64 \
  bash "$ROOT_DIR/plugin_repackaging.sh" local "$input_package" \
    >"$FIXTURE_DIR/full-sdist-repair.log" 2>&1; then
  pass 'full repackaging self-heals a pure source dependency'
else
  fail 'full repackaging self-heals a pure source dependency'
  sed 's/^/# full sdist repair: /' "$FIXTURE_DIR/full-sdist-repair.log"
fi
archive_entries="$(unzip -Z1 "$GENERATED_TEST_OUTPUT")"
```

断言输出归档：

```bash
assert_eq 1 "$(grep -c '^wheels/docopt-0.6.2-py2.py3-none-any.whl$' <<<"$archive_entries")" \
  'self-healed archive contains admitted docopt wheel'
assert_eq 0 "$(grep -Eci 'sdist|candidate-|built-wheels|uv-cache|uv-python|pip-bootstrap' <<<"$archive_entries")" \
  'self-healed archive excludes every build-only artifact'
assert_eq 0 "$(grep -Eci 'x86_64|\.so$|\.pyd$|\.dll$|\.dylib$' <<<"$archive_entries")" \
  'self-healed ARM64 archive excludes host-native artifacts'
```

再增加返回 ELF wheel 的完整运行：

```bash
cat >"$fake_bin/uv-repair-native" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == --version ]]; then printf 'uv 0.11.24\\n'; exit 0; fi
if [[ "\${1:-}" == pip || "\${1:-}" == sync ]]; then exit 0; fi
SDIST_WHEEL_FIXTURE='$sdist_fixture_dir/docopt-0.6.2-py3-none-any-elf.whl' \\
  exec '$fake_bin/uv-sdist-build' "\$@"
EOF
chmod +x "$fake_bin/uv-repair-native"
rm -f -- "$GENERATED_TEST_OUTPUT" "$REPAIR_LOOP_STATE"
if env -u http_proxy -u https_proxy -u all_proxy \
  -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
  REPAIR_LOOP_SCENARIO=docopt \
  DIFY_PIP_COMMAND="$fake_bin/pip-repair-loop" \
  DIFY_UV_COMMAND="$fake_bin/uv-repair-native" \
  DIFY_PACKAGER_BINARY="$fake_bin/dify-packager" \
  DIFY_TARGET_ARCH=aarch64 \
  bash "$ROOT_DIR/plugin_repackaging.sh" local "$input_package" \
    >"$FIXTURE_DIR/full-native-repair.log" 2>&1; then
  fail 'full repackaging rejects native content from source build'
else
  pass 'full repackaging rejects native content from source build'
fi
assert_file_missing "$GENERATED_TEST_OUTPUT" 'native source failure leaves no offline package'
assert_eq 0 "$(find "$ROOT_DIR" -maxdepth 1 -type d -name '.dify-repackaging.*' | wc -l)" 'native source failure cleans staging'
```

- [ ] **Step 2: 运行完整归档测试并确认 RED**

Run:

```bash
bash tests/test_repackaging.sh
```

Expected: FAIL，成功归档包含 `sdist-repair/`，因为 `repackage` 尚未把修复目录从默认的 `plugin_dir` 移到 staging 根。

- [ ] **Step 3: 完成归档清理和失败消息的最小修正**

在 `repackage` 的 `download_wheels` 调用末尾增加第六个实参，使修复目录位于插件内容之外但仍处于现有清理边界：

```bash
  download_wheels \
    "$staging/download-requirements.txt" \
    "$plugin_dir/wheels" \
    "$TARGET_ARCH" \
    "$python_version" \
    "$staging/pip-bootstrap" \
    "$staging/sdist-repair"
```

不得新增 `.difyignore` 规则掩盖构建目录。`cleanup_runtime` 保持只递归删除 `"$SCRIPT_DIR"/.dify-repackaging.*`，输出失败仍删除受控的 `*-offline.difypkg`。

将自愈阶段错误固定为：

```text
Pure Python sdist repair candidate: <requirement>
Pure Python wheel admitted: <filename>
Pure Python sdist repair failed during <download|build|validation|resolution>: <requirement>
Set DIFY_AUTO_BUILD_PURE_SDIST=0 to disable third-party source builds.
```

所有 URL 通过 `redact_url_for_log` 或 `print_tool_log_redacted` 后输出。

- [ ] **Step 4: 更新 README**

在 SOCKS 章节后新增“纯 Python 源码依赖自动修复”，写明：严格 wheel 下载仍是首选；仅在 pip 明确缺少分发时下载 sdist；构建会执行第三方代码；最终只准入 `none-any`、purelib 且无原生内容的 wheel；原生扩展继续失败；临时环境不会修改 Conda。给出关闭方式：

```bash
export DIFY_AUTO_BUILD_PURE_SDIST=0
```

在“高级配置”加入同一变量。在“安全失败原则”把“只有源码包即失败”改为“源码只能生成并通过纯 Python 通用 wheel 准入；原生源码、交叉编译和无法验证的归档失败”。增加 `records -> docopt` 作为包名无关的行为示例，不建立包名 allowlist；明确 `records[all]` 的无效 extra 警告不会触发 requirements 改写，只有真实依赖解析结果决定成功或失败。

- [ ] **Step 5: 运行文档与完整测试检查**

Run:

```bash
bash tests/test_repackaging.sh
git diff --check
rg -n "DIFY_AUTO_BUILD_PURE_SDIST|none-any|第三方" README.md
```

Expected: 测试 0 failed；`git diff --check` exit 0；README 三类说明均可检索。

- [ ] **Step 6: 提交归档边界和文档**

```bash
git add tests/test_repackaging.sh README.md plugin_repackaging.sh
git commit -m "docs: explain pure Python sdist self-healing"
```

### Task 6: 使用 `database-plus` 做真实 ARM64 验收

**Files:**
- Verify only: `database-plus-0.1.0.difypkg`
- Verify only: generated `database-plus-0.1.0-offline.difypkg`

- [ ] **Step 1: 运行静态和完整自动测试**

在 WSL2 仓库目录执行：

```bash
bash -n plugin_repackaging.sh plugin_repackaging_amd64_to_arm64.sh tests/test_repackaging.sh
python3 -m unittest -v tests/test_validate_python_distribution.py
bash tests/test_repackaging.sh
git diff --check
```

Expected: 所有命令 exit 0，Bash 套件报告 `0 failed`。

- [ ] **Step 2: 确认调用者 Conda 环境未被修改**

在打包前记录：

```bash
python -m pip freeze --all | sort > /tmp/dify-plugin-before.txt
```

执行真实打包：

```bash
./plugin_repackaging_amd64_to_arm64.sh local database-plus-0.1.0.difypkg
```

打包后记录并比较：

```bash
python -m pip freeze --all | sort > /tmp/dify-plugin-after.txt
diff -u /tmp/dify-plugin-before.txt /tmp/dify-plugin-after.txt
```

Expected: 打包日志先显示 docopt 自愈候选，再显示 `docopt-0.6.2-py2.py3-none-any.whl` 已准入，最终 `Repackage success`；`diff` 无输出。

- [ ] **Step 3: 检查真实离线包结构和架构**

Run:

```bash
unzip -tq database-plus-0.1.0-offline.difypkg
unzip -Z1 database-plus-0.1.0-offline.difypkg | grep '^wheels/docopt-0.6.2-py2.py3-none-any.whl$'
if unzip -Z1 database-plus-0.1.0-offline.difypkg | grep -Eq '^wheels/.*(x86_64|win32|win_amd64|macosx).*\.whl$'; then exit 1; fi
if unzip -Z1 database-plus-0.1.0-offline.difypkg | grep -Eqi '(^|/)(sdist-repair|candidate-[0-9]+|built-wheels|uv-cache|uv-python|pip-bootstrap)(/|$)'; then exit 1; fi
```

Expected: ZIP 完整；精确找到一个 docopt 通用 wheel；两个反向检查 exit 0。

- [ ] **Step 4: 确认失败边界仍然有效**

Run:

```bash
DIFY_AUTO_BUILD_PURE_SDIST=0 ./plugin_repackaging_amd64_to_arm64.sh local database-plus-0.1.0.difypkg
```

Expected: docopt wheel-only 错误非零退出，日志提示自动构建已关闭，不保留新的残缺输出。测试前先将成功包复制到 `/tmp/database-plus-accepted.difypkg`，测试后恢复，避免把成功验收产物误删。

- [ ] **Step 5: 最终审查并提交剩余改动**

Run:

```bash
git status --short
git diff --check
git log --oneline -6
```

Expected: 只有用户原有/验收生成的 `.difypkg` 保持未跟踪；源码、测试和 README 都已提交；不提交任何插件包或临时文件。如验收仅产生未跟踪包，则无需额外提交。
