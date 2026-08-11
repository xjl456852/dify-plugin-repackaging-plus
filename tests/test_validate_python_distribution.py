import io
import os
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
                    archive.writestr(info, data)
        finally:
            if context:
                context.__exit__(None, None, None)
        return path

    def wheel(self, filename="docopt-0.6.2-py2.py3-none-any.whl", name="docopt",
              version="0.6.2", purelib="true", tags=None, extra=None):
        dist_info = f"{name.replace('-', '_')}-{version}.dist-info"
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

    def test_multiple_sdist_candidates_are_rejected(self):
        self.fixture.tar("a.tar.gz", [("a/PKG-INFO", pkg_info(), "file")])
        self.fixture.zip("b.zip", [("b/PKG-INFO", pkg_info(), "file")])
        self.assert_error(self.run_validator("sdist", self.fixture.directory, "--name", "docopt"), "exactly one sdist")

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

    def test_pure_wheel_is_accepted(self):
        artifact = self.fixture.wheel()
        result = self.run_validator("wheel", self.fixture.directory, "--name", "docopt", "--version", "0.6.2")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, f"{artifact.resolve()}\tdocopt\t0.6.2\n")

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


if __name__ == "__main__":
    unittest.main()
