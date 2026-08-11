#!/usr/bin/env python3
"""Validate source and pure-Python wheel distribution archives without extraction."""

import argparse
import gzip
import os
import re
import stat
import sys
import tarfile
import zipfile
from email import policy
from email.parser import BytesParser
from pathlib import Path


class ValidationError(Exception):
    """An archive did not meet the repository's distribution safety rules."""

MAX_ARCHIVE_MEMBERS = 100000
MAX_METADATA_BYTES = 16 * 1024 * 1024
MAX_TOTAL_UNCOMPRESSED_BYTES = 8 * 1024 * 1024 * 1024
STREAM_CHUNK_SIZE = 1024 * 1024
PROJECT_NAME_RE = re.compile(r"[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?$")
VERSION_RE = re.compile(
    r"""
    \s*v?
    (?:
        (?:(?P<epoch>[0-9]+)!)?
        (?P<release>[0-9]+(?:\.[0-9]+)*)
        (?P<pre>
            [-_.]?
            (?P<pre_l>alpha|a|beta|b|preview|pre|c|rc)
            [-_.]?
            (?P<pre_n>[0-9]+)?
        )?
        (?P<post>
            (?:-(?P<post_n1>[0-9]+))
            |
            (?:
                [-_.]?
                (?P<post_l>post|rev|r)
                [-_.]?
                (?P<post_n2>[0-9]+)?
            )
        )?
        (?P<dev>
            [-_.]?
            (?P<dev_l>dev)
            [-_.]?
            (?P<dev_n>[0-9]+)?
        )?
    )
    (?:\+(?P<local>[a-z0-9]+(?:[-_.][a-z0-9]+)*))?
    \s*
    """,
    re.ASCII | re.IGNORECASE | re.VERBOSE,
)
WHEEL_DISTRIBUTION_RE = re.compile(r"[A-Za-z0-9](?:[A-Za-z0-9._]*[A-Za-z0-9])?$")


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise ValidationError(message)


def canonical_name(name):
    return re.sub(r"[-_.]+", "-", name).lower()


def has_ascii_control(value):
    return any(ord(character) < 32 or ord(character) == 127 for character in value)


def normalize_version(version):
    if has_ascii_control(version):
        raise ValueError("version contains an ASCII control character")
    match = VERSION_RE.fullmatch(version)
    if match is None:
        raise ValueError("version is not PEP 440 compliant")

    normalized = []
    epoch = int(match.group("epoch") or 0)
    if epoch:
        normalized.append(f"{epoch}!")
    normalized.append(".".join(str(int(part)) for part in match.group("release").split(".")))

    if match.group("pre") is not None:
        label = match.group("pre_l").lower()
        label = {"alpha": "a", "beta": "b", "c": "rc", "pre": "rc", "preview": "rc"}.get(label, label)
        normalized.append(f"{label}{int(match.group('pre_n') or 0)}")

    if match.group("post") is not None:
        number = match.group("post_n1") or match.group("post_n2") or "0"
        normalized.append(f".post{int(number)}")

    if match.group("dev") is not None:
        normalized.append(f".dev{int(match.group('dev_n') or 0)}")

    local = match.group("local")
    if local is not None:
        segments = re.split(r"[-_.]", local.lower())
        normalized_segments = [str(int(segment)) if re.fullmatch(r"[0-9]+", segment) else segment for segment in segments]
        normalized.append("+" + ".".join(normalized_segments))
    return "".join(normalized)


def wheel_distribution_component(name):
    return re.sub(r"[-_.]+", "_", name).lower()


def wheel_distribution_matches(component, name):
    if "__" in component or not WHEEL_DISTRIBUTION_RE.fullmatch(component):
        return False
    return canonical_name(component) == canonical_name(name)


def parse_metadata(contents, label):
    message = BytesParser(policy=policy.compat32).parsebytes(contents)
    name = message.get("Name")
    version = message.get("Version")
    if not name or not version:
        raise ValidationError(f"{label} is missing Name or Version")
    if has_ascii_control(name) or has_ascii_control(version):
        raise ValidationError("invalid metadata Name" if has_ascii_control(name) else "invalid metadata version")
    name, version = name.strip(), version.strip()
    if not PROJECT_NAME_RE.fullmatch(name):
        raise ValidationError("invalid metadata Name")
    try:
        version = normalize_version(version)
    except ValueError:
        raise ValidationError("invalid metadata version")
    return name, version, message


def validate_path(name):
    if not name or "\x00" in name or "\\" in name:
        raise ValidationError("unsafe archive path")
    if name.startswith("/") or re.match(r"^[A-Za-z]:", name):
        raise ValidationError("unsafe archive path")
    raw_parts = name.split("/")
    if ".." in raw_parts:
        raise ValidationError("unsafe archive path")
    normalized_parts = [part for part in raw_parts if part not in ("", ".")]
    if not normalized_parts:
        raise ValidationError("unsafe archive path")
    return "/".join(normalized_parts)


def validate_tar_members(archive):
    members = archive.getmembers()
    if len(members) > MAX_ARCHIVE_MEMBERS:
        raise ValidationError("archive member limit exceeded")
    paths = set()
    regular = []
    total_size = 0
    for member in members:
        path = validate_path(member.name)
        folded = path.casefold()
        if folded in paths:
            raise ValidationError("duplicate archive entry")
        paths.add(folded)
        if member.issym() or member.islnk():
            raise ValidationError("link entry")
        if not (member.isfile() or member.isdir()):
            raise ValidationError("unsafe archive entry")
        if member.isfile():
            total_size += member.size
            if total_size > MAX_TOTAL_UNCOMPRESSED_BYTES:
                raise ValidationError("archive size limit exceeded")
            regular.append(member)
    return regular


def zip_entry_type(info):
    if info.create_system != 3:
        return 0
    return stat.S_IFMT(info.external_attr >> 16)


def validate_zip_members(archive):
    infos = archive.infolist()
    if len(infos) > MAX_ARCHIVE_MEMBERS:
        raise ValidationError("archive member limit exceeded")
    paths = set()
    regular = []
    total_size = 0
    for info in infos:
        path = validate_path(info.orig_filename)
        folded = path.casefold()
        if folded in paths:
            raise ValidationError("duplicate archive entry")
        paths.add(folded)
        kind = zip_entry_type(info)
        if kind == stat.S_IFLNK:
            raise ValidationError("link entry")
        if kind and kind not in (stat.S_IFREG, stat.S_IFDIR):
            raise ValidationError("unsafe archive entry")
        if kind == stat.S_IFDIR and not info.is_dir():
            raise ValidationError("unsafe archive entry")
        if kind == stat.S_IFREG and info.is_dir():
            raise ValidationError("unsafe archive entry")
        if not info.is_dir():
            total_size += info.file_size
            if total_size > MAX_TOTAL_UNCOMPRESSED_BYTES:
                raise ValidationError("archive size limit exceeded")
            regular.append(info)
    return regular


def stream_members(archive, members, metadata_members):
    metadata = {}
    magics = {}
    for member in members:
        declared_size = member.size if isinstance(archive, tarfile.TarFile) else member.file_size
        if member in metadata_members and declared_size > MAX_METADATA_BYTES:
            raise ValidationError("metadata exceeds size limit")
        retained = bytearray() if member in metadata_members else None
        first_bytes = bytearray()
        stream = archive.extractfile(member) if isinstance(archive, tarfile.TarFile) else archive.open(member)
        if stream is None:
            raise ValidationError("cannot read archive member")
        with stream:
            while chunk := stream.read(STREAM_CHUNK_SIZE):
                if len(first_bytes) < 4:
                    first_bytes.extend(chunk[:4 - len(first_bytes)])
                if retained is not None:
                    retained.extend(chunk)
                    if len(retained) > MAX_METADATA_BYTES:
                        raise ValidationError("metadata exceeds size limit")
        magics[member] = bytes(first_bytes)
        if retained is not None:
            metadata[member] = bytes(retained)
    return metadata, magics


def verify_gzip_stream(path):
    with gzip.open(path, "rb") as stream:
        while stream.read(STREAM_CHUNK_SIZE):
            pass


def candidate(directory, suffixes, kind):
    try:
        path = Path(directory)
        if not path.exists() or not path.is_dir() or path.is_symlink():
            raise ValidationError("candidate directory is missing, invalid, or a symlink")
        artifacts = []
        for entry in path.iterdir():
            if entry.name.lower().endswith(suffixes):
                if entry.is_symlink() or not entry.is_file():
                    raise ValidationError("candidate artifact must be an ordinary file")
                artifacts.append(entry)
    except ValidationError:
        raise
    except (OSError, RuntimeError) as error:
        raise ValidationError("candidate directory cannot be inspected") from error
    if len(artifacts) != 1:
        raise ValidationError(f"exactly one {kind}")
    try:
        artifact = artifacts[0].resolve()
    except (OSError, RuntimeError) as error:
        raise ValidationError("candidate directory cannot be inspected") from error
    if has_ascii_control(str(artifact)):
        raise ValidationError("candidate path contains control characters")
    return artifact


def validate_sdist(directory, expected_name):
    artifact = candidate(directory, (".tar.gz", ".zip"), "sdist")
    if artifact.name.lower().endswith(".tar.gz"):
        try:
            with tarfile.open(artifact, "r:gz") as archive:
                members = validate_tar_members(archive)
                metadata = [member for member in members if re.fullmatch(r"[^/]+/PKG-INFO", member.name)]
                if len(metadata) != 1:
                    raise ValidationError("exactly one top-level PKG-INFO")
                contents, _ = stream_members(archive, members, set(metadata))
                name, version, _ = parse_metadata(contents[metadata[0]], "PKG-INFO")
            verify_gzip_stream(artifact)
        except ValidationError:
            raise
        except (tarfile.TarError, OSError, EOFError) as error:
            raise ValidationError("invalid tar.gz sdist") from error
    else:
        try:
            with zipfile.ZipFile(artifact) as archive:
                members = validate_zip_members(archive)
                metadata = [info for info in members if re.fullmatch(r"[^/]+/PKG-INFO", info.filename)]
                if len(metadata) != 1:
                    raise ValidationError("exactly one top-level PKG-INFO")
                contents, _ = stream_members(archive, members, set(metadata))
                name, version, _ = parse_metadata(contents[metadata[0]], "PKG-INFO")
        except ValidationError:
            raise
        except (zipfile.BadZipFile, OSError, EOFError, NotImplementedError, RuntimeError) as error:
            raise ValidationError("invalid zip sdist") from error
    canonical = canonical_name(name)
    if canonical != canonical_name(expected_name):
        raise ValidationError("metadata name does not match expected name")
    return artifact, canonical, version


def parse_wheel_filename(filename):
    if not filename.lower().endswith(".whl"):
        raise ValidationError("invalid wheel filename")
    parts = filename[:-4].split("-")
    if len(parts) not in (5, 6):
        raise ValidationError("invalid wheel filename")
    distribution, version = parts[0], parts[1]
    build = parts[2] if len(parts) == 6 else None
    python_tag, abi_tag, platform_tag = parts[-3:]
    if not WHEEL_DISTRIBUTION_RE.fullmatch(distribution) or not version or not python_tag:
        raise ValidationError("invalid wheel filename")
    if build is not None and (not build or has_ascii_control(build) or build[0] not in "0123456789"):
        raise ValidationError("invalid wheel build tag")
    if any(has_ascii_control(component) for component in (python_tag, abi_tag, platform_tag)):
        raise ValidationError("invalid wheel filename")
    if any(not tag for tag in python_tag.split(".")):
        raise ValidationError("invalid Python tag")
    if any(tag != "none" for tag in abi_tag.split(".")):
        raise ValidationError("ABI tag must be none")
    if any(tag != "any" for tag in platform_tag.split(".")):
        raise ValidationError("platform tag must be any")
    return distribution, version


def validate_wheel_tags(message):
    if message.get("Root-Is-Purelib", "").strip().lower() != "true":
        raise ValidationError("Root-Is-Purelib must be true")
    tags = message.get_all("Tag", [])
    if not tags:
        raise ValidationError("WHEEL has no Tag")
    for tag in tags:
        parts = tag.strip().split("-")
        if len(parts) != 3 or not all(parts):
            raise ValidationError("invalid WHEEL Tag")
        _, abi, platform = parts
        if abi != "none":
            raise ValidationError("ABI tag must be none")
        if platform != "any":
            raise ValidationError("platform tag must be any")


MACH_O_MAGICS = {
    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
}


def reject_native_content(members, magics):
    for info in members:
        lower_name = info.filename.casefold()
        if lower_name.endswith((".so", ".dll", ".pyd", ".dylib")) or ".so." in lower_name:
            raise ValidationError("native extension")
        magic = magics[info]
        if magic == b"\x7fELF":
            raise ValidationError("ELF binary")
        if magic.startswith(b"MZ"):
            raise ValidationError("PE binary")
        if magic in MACH_O_MAGICS:
            raise ValidationError("Mach-O binary")


def validate_wheel(directory, expected_name, expected_version):
    artifact = candidate(directory, (".whl",), "wheel")
    filename_name, filename_version = parse_wheel_filename(artifact.name)
    try:
        with zipfile.ZipFile(artifact) as archive:
            members = validate_zip_members(archive)
            metadata = [info for info in members if re.fullmatch(r"[^/]+\.dist-info/METADATA", info.filename)]
            wheel_files = [info for info in members if re.fullmatch(r"[^/]+\.dist-info/WHEEL", info.filename)]
            if len(metadata) != 1 or len(wheel_files) != 1:
                raise ValidationError("exactly one dist-info METADATA and WHEEL")
            if Path(metadata[0].filename).parent != Path(wheel_files[0].filename).parent:
                raise ValidationError("METADATA and WHEEL are not siblings")
            contents, magics = stream_members(archive, members, set(metadata + wheel_files))
            name, version, _ = parse_metadata(contents[metadata[0]], "METADATA")
            try:
                normalized_filename_version = normalize_version(filename_version)
            except ValueError:
                raise ValidationError("invalid wheel version")
            if filename_version != normalized_filename_version:
                raise ValidationError("invalid wheel version")
            try:
                expected_version = normalize_version(expected_version)
            except ValueError:
                raise ValidationError("invalid expected version")
            wheel_message = BytesParser(policy=policy.compat32).parsebytes(contents[wheel_files[0]])
            wheel_parent = Path(metadata[0].filename).parent.name
            expected_dist_info = f"{wheel_distribution_component(name)}-{version}.dist-info"
            if canonical_name(name) != canonical_name(expected_name):
                raise ValidationError("metadata name does not match expected name")
            if version != expected_version:
                raise ValidationError("metadata version does not match expected version")
            if not wheel_distribution_matches(filename_name, name) or filename_version != version:
                raise ValidationError("wheel filename identity does not match metadata")
            if wheel_parent != expected_dist_info:
                raise ValidationError("dist-info directory does not match wheel filename")
            validate_wheel_tags(wheel_message)
            reject_native_content(members, magics)
    except ValidationError:
        raise
    except (zipfile.BadZipFile, OSError, EOFError, NotImplementedError, RuntimeError) as error:
        raise ValidationError("invalid wheel archive") from error
    return artifact, canonical_name(name), version


def main(argv=None):
    parser = Parser(prog="validate_python_distribution")
    subparsers = parser.add_subparsers(dest="command", required=True)
    sdist = subparsers.add_parser("sdist")
    sdist.add_argument("directory")
    sdist.add_argument("--name", required=True)
    wheel = subparsers.add_parser("wheel")
    wheel.add_argument("directory")
    wheel.add_argument("--name", required=True)
    wheel.add_argument("--version", required=True)
    try:
        args = parser.parse_args(argv)
        if args.command == "sdist":
            result = validate_sdist(args.directory, args.name)
        else:
            result = validate_wheel(args.directory, args.name, args.version)
    except ValidationError as error:
        print(f"validation failed: {error}", file=sys.stderr)
        return 1
    print("\t".join(map(str, result)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
