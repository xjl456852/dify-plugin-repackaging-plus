#!/usr/bin/env python3
"""Validate source and pure-Python wheel distribution archives without extraction."""

import argparse
import os
import re
import stat
import sys
import tarfile
import zipfile
from email import policy
from email.parser import BytesParser
from pathlib import Path, PurePosixPath


class ValidationError(Exception):
    """An archive did not meet the repository's distribution safety rules."""


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise ValidationError(message)


def canonical_name(name):
    return re.sub(r"[-_.]+", "-", name).lower()


def parse_metadata(contents, label):
    message = BytesParser(policy=policy.compat32).parsebytes(contents)
    name = message.get("Name")
    version = message.get("Version")
    if not name or not version:
        raise ValidationError(f"{label} is missing Name or Version")
    return name.strip(), version.strip(), message


def validate_path(name):
    if not name or "\x00" in name or "\\" in name:
        raise ValidationError("unsafe archive path")
    if name.startswith("/") or re.match(r"^[A-Za-z]:", name):
        raise ValidationError("unsafe archive path")
    path = PurePosixPath(name)
    if any(part in ("", ".", "..") for part in path.parts):
        raise ValidationError("unsafe archive path")
    return name.rstrip("/")


def validate_tar_members(archive):
    members = archive.getmembers()
    paths = set()
    regular = []
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
            regular.append(member)
    return regular


def zip_entry_type(info):
    if info.create_system != 3:
        return 0
    return stat.S_IFMT(info.external_attr >> 16)


def validate_zip_members(archive):
    infos = archive.infolist()
    paths = set()
    regular = []
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
        if not info.is_dir() and kind != stat.S_IFDIR:
            regular.append(info)
    return regular


def candidate(directory, suffixes, kind):
    path = Path(directory)
    if not path.exists() or not path.is_dir() or path.is_symlink():
        raise ValidationError("candidate directory is missing, invalid, or a symlink")
    artifacts = []
    for entry in path.iterdir():
        if entry.name.lower().endswith(suffixes):
            if entry.is_symlink() or not entry.is_file():
                raise ValidationError("candidate artifact must be an ordinary file")
            artifacts.append(entry)
    if len(artifacts) != 1:
        raise ValidationError(f"exactly one {kind}")
    return artifacts[0].resolve()


def validate_sdist(directory, expected_name):
    artifact = candidate(directory, (".tar.gz", ".zip"), "sdist")
    try:
        if artifact.name.lower().endswith(".tar.gz"):
            with tarfile.open(artifact, "r:gz") as archive:
                members = validate_tar_members(archive)
                metadata = [member for member in members if re.fullmatch(r"[^/]+/PKG-INFO", member.name)]
                if len(metadata) != 1:
                    raise ValidationError("exactly one top-level PKG-INFO")
                stream = archive.extractfile(metadata[0])
                if stream is None:
                    raise ValidationError("cannot read PKG-INFO")
                name, version, _ = parse_metadata(stream.read(), "PKG-INFO")
        else:
            with zipfile.ZipFile(artifact) as archive:
                members = validate_zip_members(archive)
                metadata = [info for info in members if re.fullmatch(r"[^/]+/PKG-INFO", info.filename)]
                if len(metadata) != 1:
                    raise ValidationError("exactly one top-level PKG-INFO")
                name, version, _ = parse_metadata(archive.read(metadata[0]), "PKG-INFO")
    except ValidationError:
        raise
    except (tarfile.TarError, OSError, EOFError) as error:
        raise ValidationError("invalid tar.gz sdist") from error
    except zipfile.BadZipFile as error:
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
    build = parts[2:-3]
    python_tag, abi_tag, platform_tag = parts[-3:]
    if not distribution or not version or not python_tag:
        raise ValidationError("invalid wheel filename")
    if build and not re.fullmatch(r"[0-9][0-9A-Za-z.]*", build[0]):
        raise ValidationError("invalid wheel build tag")
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


def reject_native_content(archive, members):
    for info in members:
        lower_name = info.filename.casefold()
        if lower_name.endswith((".so", ".dll", ".pyd", ".dylib")) or ".so." in lower_name:
            raise ValidationError("native extension")
        with archive.open(info) as stream:
            magic = stream.read(4)
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
            name, version, _ = parse_metadata(archive.read(metadata[0]), "METADATA")
            wheel_message = BytesParser(policy=policy.compat32).parsebytes(archive.read(wheel_files[0]))
            wheel_parent = Path(metadata[0].filename).parent.name
            expected_dist_info = f"{filename_name.replace('-', '_')}-{filename_version}.dist-info"
            if canonical_name(name) != canonical_name(expected_name):
                raise ValidationError("metadata name does not match expected name")
            if version != expected_version:
                raise ValidationError("metadata version does not match expected version")
            if canonical_name(filename_name) != canonical_name(name) or filename_version != version:
                raise ValidationError("wheel filename identity does not match metadata")
            if wheel_parent != expected_dist_info:
                raise ValidationError("dist-info directory does not match wheel filename")
            validate_wheel_tags(wheel_message)
            reject_native_content(archive, members)
    except ValidationError:
        raise
    except (zipfile.BadZipFile, OSError, EOFError) as error:
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
