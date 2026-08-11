import io
import os
import re
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest
import warnings
import zipfile
from email.message import Message
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
VALIDATOR = ROOT / "tools" / "validate_python_distribution.py"


def pkg_info(name="docopt", version="0.6.2"):
    return f"Metadata-Version: 2.1\nName: {name}\nVersion: {version}\n\n".encode()


def wheel_metadata(name="docopt", version="0.6.2", purelib="true", tags=None):
    if tags is None:
        tags = ["py2-none-any", "py3-none-any"]
    lines = ["Wheel-Version: 1.0", "Generator: tests", f"Root-Is-Purelib: {purelib}"]
    lines.extend(f"Tag: {tag}" for tag in tags)
    return ("\n".join(lines) + "\n\n").encode()


def normalized_wheel_name(name):
    return re.sub(r"[-_.]+", "_", name).lower()


def corrupt_stored_zip_member(path, member_name, offset):
    with zipfile.ZipFile(path) as archive:
        info = archive.getinfo(member_name)
        payload_offset = info.header_offset + 30 + len(info.filename.encode()) + len(info.extra)
    with Path(path).open("r+b") as artifact:
        artifact.seek(payload_offset + offset)
        original = artifact.read(1)
        artifact.seek(payload_offset + offset)
        artifact.write(bytes([original[0] ^ 0xFF]))


def patch_zip_member_compression(path, member_name, method=99):
    target = member_name.encode()
    data = bytearray(Path(path).read_bytes())
    with zipfile.ZipFile(path) as archive:
        local_offset = archive.getinfo(member_name).header_offset
    data[local_offset + 8:local_offset + 10] = method.to_bytes(2, "little")
    position = 0
    while True:
        position = data.find(b"PK\x01\x02", position)
        if position < 0:
            raise AssertionError(f"central directory entry not found: {member_name}")
        name_length = int.from_bytes(data[position + 28:position + 30], "little")
        name = bytes(data[position + 46:position + 46 + name_length])
        if name == target:
            data[position + 10:position + 12] = method.to_bytes(2, "little")
            Path(path).write_bytes(data)
            return
        position += 46 + name_length


def corrupt_gzip_trailer(path):
    with Path(path).open("r+b") as artifact:
        artifact.seek(-8, os.SEEK_END)
        value = artifact.read(1)
        artifact.seek(-8, os.SEEK_END)
        artifact.write(bytes([value[0] ^ 0xFF]))


def patch_zip_member_size(path, member_name, size):
    target = member_name.encode()
    data = bytearray(Path(path).read_bytes())
    position = 0
    while True:
        position = data.find(b"PK\x01\x02", position)
        if position < 0:
            raise AssertionError(f"central directory entry not found: {member_name}")
        name_length = int.from_bytes(data[position + 28:position + 30], "little")
        if bytes(data[position + 46:position + 46 + name_length]) == target:
            data[position + 24:position + 28] = size.to_bytes(4, "little")
            Path(path).write_bytes(data)
            return
        position += 46 + name_length


class DistributionFixture:
    def __init__(self, directory):
        self.directory = Path(directory)

    def tar(self, filename, entries):
        path = self.directory / filename
        with tarfile.open(path, "w:gz") as archive:
            for name, data, kind in entries:
                info = tarfile.TarInfo(name)
                if kind == "file":
                    info.size = len(data)
                    archive.addfile(info, io.BytesIO(data))
                elif kind == "symlink":
                    info.type = tarfile.SYMTYPE
                    info.linkname = data.decode()
                    archive.addfile(info)
                else:
                    raise ValueError(kind)
        return path

    def zip(self, filename, entries, duplicate_warning=False):
        path = self.directory / filename
        context = warnings.catch_warnings() if duplicate_warning else None
        if context:
            context.__enter__()
            warnings.simplefilter("ignore", UserWarning)
        try:
            with zipfile.ZipFile(path, "w") as archive:
                for name, data, kind in entries:
                    info = zipfile.ZipInfo(name)
                    if kind == "symlink":
                        info.create_system = 3
                        info.external_attr = (stat.S_IFLNK | 0o777) << 16
                    elif kind == "directory_no_slash":
                        info.create_system = 3
                        info.external_attr = (stat.S_IFDIR | 0o755) << 16
                    archive.writestr(info, data)
        finally:
            if context:
                context.__exit__(None, None, None)
        return path

    def wheel(self, filename="docopt-0.6.2-py2.py3-none-any.whl", name="docopt",
              version="0.6.2", purelib="true", tags=None, extra=None,
              dist_info_name=None, dist_info_version=None):
        if dist_info_name is None:
            dist_info_name = normalized_wheel_name(name)
        if dist_info_version is None:
            dist_info_version = version
        dist_info = f"{dist_info_name}-{dist_info_version}.dist-info"
        entries = [
            (f"{dist_info}/METADATA", pkg_info(name, version), "file"),
            (f"{dist_info}/WHEEL", wheel_metadata(name, version, purelib, tags), "file"),
            (f"{name}.py", b"# pure python\n", "file"),
        ]
        if extra:
            entries.extend(extra)
        return self.zip(filename, entries)


class ValidatePythonDistributionTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.fixture = DistributionFixture(self.tempdir.name)

    def tearDown(self):
        self.tempdir.cleanup()

    def run_validator(self, *arguments):
        return subprocess.run(
            [sys.executable, str(VALIDATOR), *map(str, arguments)],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )

    def assert_error(self, result, reason):
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"validation failed: {reason}", result.stderr)

    def test_safe_tar_gz_sdist_is_accepted(self):
        artifact = self.fixture.tar("docopt-0.6.2.tar.gz", [
            ("docopt-0.6.2/PKG-INFO", pkg_info(), "file"),
            ("docopt-0.6.2/docopt.py", b"# pure python\n", "file"),
        ])
        result = self.run_validator("sdist", self.fixture.directory, "--name", "docopt")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, f"{artifact.resolve()}\tdocopt\t0.6.2\n")

    def test_sdist_rejects_bad_gzip_trailer(self):
        artifact = self.fixture.tar("docopt-0.6.2.tar.gz", [
            ("docopt-0.6.2/PKG-INFO", pkg_info(), "file"),
            ("docopt-0.6.2/data.txt", b"payload", "file"),
        ])
        corrupt_gzip_trailer(artifact)
        self.assert_error(self.run_validator("sdist", self.fixture.directory, "--name", "docopt"), "invalid tar.gz sdist")

    def test_multiple_sdist_candidates_are_rejected(self):
        self.fixture.tar("a.tar.gz", [("a/PKG-INFO", pkg_info(), "file")])
        self.fixture.zip("b.zip", [("b/PKG-INFO", pkg_info(), "file")])
        self.assert_error(self.run_validator("sdist", self.fixture.directory, "--name", "docopt"), "exactly one sdist")

    @unittest.skipIf(os.name == "nt" or os.geteuid() == 0, "requires non-root POSIX permissions")
    def test_unreadable_candidate_directory_is_normalized(self):
        directory = self.fixture.directory
        os.chmod(directory, 0)
        try:
            result = self.run_validator("sdist", directory, "--name", "docopt")
        finally:
            os.chmod(directory, 0o700)
        self.assert_error(result, "candidate directory cannot be inspected")
        self.assertNotIn("Traceback", result.stderr)

    def test_sdist_parent_traversal_is_rejected(self):
        self.fixture.tar("docopt.tar.gz", [("../PKG-INFO", pkg_info(), "file")])
        self.assert_error(self.run_validator("sdist", self.fixture.directory, "--name", "docopt"), "unsafe archive path")

    def test_sdist_symlink_is_rejected(self):
        self.fixture.tar("docopt.tar.gz", [
            ("docopt/PKG-INFO", pkg_info(), "file"),
            ("docopt/link", b"target", "symlink"),
        ])
        self.assert_error(self.run_validator("sdist", self.fixture.directory, "--name", "docopt"), "link entry")

    def test_safe_zip_sdist_is_accepted(self):
        artifact = self.fixture.zip("docopt.zip", [("docopt/PKG-INFO", pkg_info(), "file")])
        result = self.run_validator("sdist", self.fixture.directory, "--name", "Docopt")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, f"{artifact.resolve()}\tdocopt\t0.6.2\n")

    def test_corrupt_zip_sdist_is_rejected(self):
        (self.fixture.directory / "docopt.zip").write_bytes(b"not a zip")
        self.assert_error(self.run_validator("sdist", self.fixture.directory, "--name", "docopt"), "invalid zip sdist")

    def test_sdist_metadata_name_mismatch_is_rejected(self):
        self.fixture.tar("docopt.tar.gz", [("docopt/PKG-INFO", pkg_info("other"), "file")])
        self.assert_error(self.run_validator("sdist", self.fixture.directory, "--name", "docopt"), "metadata name does not match")

    def test_sdist_corrupt_non_metadata_zip_member_is_rejected(self):
        artifact = self.fixture.zip("docopt.zip", [
            ("docopt/PKG-INFO", pkg_info(), "file"),
            ("docopt/data.txt", b"0123456789", "file"),
        ])
        corrupt_stored_zip_member(artifact, "docopt/data.txt", 5)
        self.assert_error(self.run_validator("sdist", self.fixture.directory, "--name", "docopt"), "invalid zip sdist")

    def test_sdist_unsupported_zip_compression_is_normalized(self):
        artifact = self.fixture.zip("docopt.zip", [
            ("docopt/PKG-INFO", pkg_info(), "file"),
            ("docopt/data.txt", b"payload", "file"),
        ])
        patch_zip_member_compression(artifact, "docopt/data.txt")
        result = self.run_validator("sdist", self.fixture.directory, "--name", "docopt")
        self.assert_error(result, "invalid zip sdist")
        self.assertNotIn("Traceback", result.stderr)

    def test_pure_wheel_is_accepted(self):
        artifact = self.fixture.wheel()
        result = self.run_validator("wheel", self.fixture.directory, "--name", "docopt", "--version", "0.6.2")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, f"{artifact.resolve()}\tdocopt\t0.6.2\n")

    def test_pure_wheel_with_legal_numeric_build_tag_is_accepted(self):
        artifact = self.fixture.wheel(filename="docopt-0.6.2-1_local-py3-none-any.whl")
        result = self.run_validator("wheel", self.fixture.directory, "--name", "docopt", "--version", "0.6.2")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, f"{artifact.resolve()}\tdocopt\t0.6.2\n")

    def test_pure_wheel_with_dotted_build_tag_is_accepted(self):
        self.fixture.wheel(filename="docopt-0.6.2-1.local-py3-none-any.whl")
        result = self.run_validator("wheel", self.fixture.directory, "--name", "docopt", "--version", "0.6.2")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_pure_wheel_with_general_pep427_build_tag_is_accepted(self):
        self.fixture.wheel(filename="docopt-0.6.2-1@local-py3-none-any.whl")
        result = self.run_validator("wheel", self.fixture.directory, "--name", "docopt", "--version", "0.6.2")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_wheel_epoch_local_filename_identity_is_accepted(self):
        artifact = self.fixture.wheel(
            filename="docopt-1!2.0+local-py3-none-any.whl", version="1!2.0+local",
        )
        result = self.run_validator("wheel", self.fixture.directory, "--name", "docopt", "--version", "1!2.0+local")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, f"{artifact.resolve()}\tdocopt\t1!2.0+local\n")

    def test_wheel_underscore_escaped_epoch_and_local_version_is_rejected(self):
        self.fixture.wheel(
            filename="docopt-1_2.0_local-py3-none-any.whl", version="1!2.0+local",
            dist_info_version="1_2.0_local",
        )
        result = self.run_validator("wheel", self.fixture.directory, "--name", "docopt", "--version", "1!2.0+local")
        self.assert_error(result, "invalid wheel version")

    def test_wheel_project_name_uses_normalized_filename_component(self):
        artifact = self.fixture.wheel(
            filename="my_project_name-0.6.2-py3-none-any.whl", name="My.Project-Name",
        )
        result = self.run_validator(
            "wheel", self.fixture.directory, "--name", "my-project-name", "--version", "0.6.2",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, f"{artifact.resolve()}\tmy-project-name\t0.6.2\n")

    def test_wheel_legacy_project_name_separators_are_accepted_safely(self):
        for legacy_name in ("My..Project", "My._Project"):
            with self.subTest(legacy_name=legacy_name), tempfile.TemporaryDirectory() as directory:
                fixture = DistributionFixture(directory)
                artifact = fixture.wheel(
                    filename=f"{legacy_name}-0.6.2-py3-none-any.whl", name=legacy_name,
                )
                result = self.run_validator(
                    "wheel", directory, "--name", "my-project", "--version", "0.6.2",
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, f"{artifact.resolve()}\tmy-project\t0.6.2\n")

    def test_pep440_alternate_versions_are_normalized(self):
        cases = [
            ("v1.0", "1.0"),
            (" 1.0 ", "1.0"),
            ("01!02.003", "1!2.3"),
            ("1.0alpha", "1.0a0"),
            ("1.0beta2", "1.0b2"),
            ("1.0preview.3", "1.0rc3"),
            ("1.0-1", "1.0.post1"),
            ("1.0rev", "1.0.post0"),
            ("1.0dev", "1.0.dev0"),
            ("1.0+ABC-01_local", "1.0+abc.1.local"),
        ]
        for raw_version, normalized_version in cases:
            with self.subTest(raw_version=raw_version), tempfile.TemporaryDirectory() as directory:
                fixture = DistributionFixture(directory)
                artifact = fixture.wheel(
                    filename=f"docopt-{normalized_version}-py3-none-any.whl",
                    version=raw_version,
                    dist_info_version=normalized_version,
                )
                result = self.run_validator(
                    "wheel", directory, "--name", "docopt", "--version", raw_version,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, f"{artifact.resolve()}\tdocopt\t{normalized_version}\n")

    def test_expected_alternate_version_matches_normalized_wheel_version(self):
        artifact = self.fixture.wheel(
            filename="docopt-1.0.post1-py3-none-any.whl", version="1.0.post1",
        )
        result = self.run_validator(
            "wheel", self.fixture.directory, "--name", "docopt", "--version", "1.0-1",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, f"{artifact.resolve()}\tdocopt\t1.0.post1\n")

    def test_malformed_pep440_versions_are_rejected(self):
        malformed_versions = [
            "bad!",
            "1_2.0_local",
            "1.0+abc+def",
            "1.0+abc..def",
            "1.0\x01",
        ]
        for version in malformed_versions:
            with self.subTest(version=repr(version)), tempfile.TemporaryDirectory() as directory:
                fixture = DistributionFixture(directory)
                fixture.wheel(
                    filename="docopt-1.0-py3-none-any.whl",
                    version=version,
                    dist_info_version="1.0",
                )
                result = self.run_validator(
                    "wheel", directory, "--name", "docopt", "--version", "1.0",
                )
                self.assert_error(result, "invalid metadata version")

    def test_wheel_invalid_metadata_version_is_rejected(self):
        self.fixture.wheel(filename="docopt-bad!-py3-none-any.whl", version="bad!")
        self.assert_error(self.run_validator("wheel", self.fixture.directory, "--name", "docopt", "--version", "bad!"), "invalid metadata version")

    def test_wheel_control_character_metadata_is_rejected(self):
        self.fixture.wheel(name="doc\topt")
        self.assert_error(self.run_validator("wheel", self.fixture.directory, "--name", "docopt", "--version", "0.6.2"), "invalid metadata Name")

    def test_wheel_oversize_metadata_declaration_is_rejected(self):
        artifact = self.fixture.wheel()
        patch_zip_member_size(artifact, "docopt-0.6.2.dist-info/METADATA", 16 * 1024 * 1024 + 1)
        self.assert_error(self.run_validator("wheel", self.fixture.directory, "--name", "docopt", "--version", "0.6.2"), "metadata exceeds size limit")

    def test_wheel_aggregate_size_declaration_is_rejected(self):
        artifact = self.fixture.wheel(extra=[("payload-a", b"a", "file"), ("payload-b", b"b", "file")])
        declared_size = 3 * 1024 * 1024 * 1024
        for member_name in ("docopt.py", "payload-a", "payload-b"):
            patch_zip_member_size(artifact, member_name, declared_size)
        self.assert_error(self.run_validator("wheel", self.fixture.directory, "--name", "docopt", "--version", "0.6.2"), "archive size limit exceeded")

    def test_platform_wheel_is_rejected(self):
        self.fixture.wheel(filename="docopt-0.6.2-py3-none-manylinux.whl")
        self.assert_error(self.run_validator("wheel", self.fixture.directory, "--name", "docopt", "--version", "0.6.2"), "platform tag must be any")

    def test_abi3_wheel_is_rejected(self):
        self.fixture.wheel(filename="docopt-0.6.2-cp311-abi3-any.whl", tags=["cp311-abi3-any"])
        self.assert_error(self.run_validator("wheel", self.fixture.directory, "--name", "docopt", "--version", "0.6.2"), "ABI tag must be none")

    def test_non_purelib_wheel_is_rejected(self):
        self.fixture.wheel(purelib="false")
        self.assert_error(self.run_validator("wheel", self.fixture.directory, "--name", "docopt", "--version", "0.6.2"), "Root-Is-Purelib must be true")

    def test_false_universal_wheel_with_native_extension_is_rejected(self):
        self.fixture.wheel(extra=[("docopt.so", b"not a real binary", "file")])
        self.assert_error(self.run_validator("wheel", self.fixture.directory, "--name", "docopt", "--version", "0.6.2"), "native extension")

    def test_false_universal_wheel_with_elf_binary_is_rejected(self):
        self.fixture.wheel(extra=[("payload.bin", b"\x7fELFpayload", "file")])
        self.assert_error(self.run_validator("wheel", self.fixture.directory, "--name", "docopt", "--version", "0.6.2"), "ELF binary")

    def test_wheel_rejects_directory_mode_entry_without_directory_name(self):
        self.fixture.wheel(extra=[("docopt/payload.bin", b"\x7fELFpayload", "directory_no_slash")])
        self.assert_error(
            self.run_validator("wheel", self.fixture.directory, "--name", "docopt", "--version", "0.6.2"),
            "unsafe archive entry",
        )

    def test_wheel_corrupt_payload_after_first_four_bytes_is_rejected(self):
        artifact = self.fixture.wheel(extra=[("payload.bin", b"0" * 8192, "file")])
        corrupt_stored_zip_member(artifact, "payload.bin", 5000)
        self.assert_error(self.run_validator("wheel", self.fixture.directory, "--name", "docopt", "--version", "0.6.2"), "invalid wheel archive")

    def test_wheel_unsupported_zip_compression_is_normalized(self):
        artifact = self.fixture.wheel()
        patch_zip_member_compression(artifact, "docopt.py")
        result = self.run_validator("wheel", self.fixture.directory, "--name", "docopt", "--version", "0.6.2")
        self.assert_error(result, "invalid wheel archive")
        self.assertNotIn("Traceback", result.stderr)

    def test_wheel_metadata_identity_mismatch_is_rejected(self):
        self.fixture.wheel(name="other")
        self.assert_error(self.run_validator("wheel", self.fixture.directory, "--name", "docopt", "--version", "0.6.2"), "metadata name does not match")

    def test_zip_symlink_is_rejected(self):
        self.fixture.wheel(extra=[("docopt/link", b"target", "symlink")])
        self.assert_error(self.run_validator("wheel", self.fixture.directory, "--name", "docopt", "--version", "0.6.2"), "link entry")

    def test_duplicate_wheel_path_is_rejected(self):
        dist_info = "docopt-0.6.2.dist-info"
        self.fixture.zip("docopt-0.6.2-py3-none-any.whl", [
            (f"{dist_info}/METADATA", pkg_info(), "file"),
            (f"{dist_info}/WHEEL", wheel_metadata(), "file"),
            ("docopt.py", b"one", "file"),
            ("docopt.py", b"two", "file"),
        ], duplicate_warning=True)
        self.assert_error(self.run_validator("wheel", self.fixture.directory, "--name", "docopt", "--version", "0.6.2"), "duplicate archive entry")

    def test_wheel_dot_path_alias_is_rejected_as_duplicate(self):
        self.fixture.wheel(extra=[("./docopt.py", b"# aliased path\n", "file")])
        self.assert_error(
            self.run_validator("wheel", self.fixture.directory, "--name", "docopt", "--version", "0.6.2"),
            "duplicate archive entry",
        )


if __name__ == "__main__":
    unittest.main()
