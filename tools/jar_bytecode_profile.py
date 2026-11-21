#!/usr/bin/env python3
"""Read-only JAR classfile/Java-version feature inventory for JarBox.

Does not execute or modify JARs. A static feature reference does not prove that
that code path is run or that miniJVM supports it. Multi-release entries are
reported separately rather than silently treated as baseline classes.
"""
from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
import struct
import sys
import zipfile

MAX_CLASS_BYTES = 8 * 1024 * 1024
MAX_ENTRIES = 30000
MAX_TOTAL_CLASS_BYTES = 256 * 1024 * 1024


class FormatError(ValueError):
    pass


class Reader:
    def __init__(self, data):
        self.data = data
        self.pos = 0

    def take(self, size):
        if size < 0 or self.pos + size > len(self.data):
            raise FormatError("truncated classfile")
        start = self.pos
        self.pos += size
        return self.data[start:self.pos]

    def u1(self):
        return self.take(1)[0]

    def u2(self):
        return struct.unpack(">H", self.take(2))[0]

    def u4(self):
        return struct.unpack(">I", self.take(4))[0]


def java_release(major):
    if major >= 49:
        return str(major - 44)
    return {45: "1.1", 46: "1.2", 47: "1.3", 48: "1.4"}.get(major, "unknown")


def parse_class_profile(data):
    r = Reader(data)
    if r.u4() != 0xCAFEBABE:
        raise FormatError("not a Java classfile")
    minor, major, count = r.u2(), r.u2(), r.u2()
    if count == 0:
        raise FormatError("invalid constant pool count")
    cp = [None] * count
    tags = Counter()
    i = 1
    while i < count:
        tag = r.u1()
        tags[tag] += 1
        if tag == 1:
            cp[i] = r.take(r.u2()).decode("utf-8", "replace")
        elif tag in (3, 4):
            r.take(4)
        elif tag in (9, 10, 11, 12, 17, 18):
            cp[i] = (tag, r.u2(), r.u2())
        elif tag in (5, 6):
            r.take(8)
            i += 1
        elif tag in (7, 8, 16, 19, 20):
            cp[i] = (tag, r.u2())
        elif tag == 15:
            cp[i] = (tag, r.u1(), r.u2())
        else:
            raise FormatError("unsupported constant-pool tag " + str(tag))
        i += 1

    def attributes():
        names = []
        for _ in range(r.u2()):
            index = r.u2()
            if index <= 0 or index >= count or not isinstance(cp[index], str):
                raise FormatError("invalid attribute name index")
            names.append(cp[index])
            r.take(r.u4())
        return names

    r.take(6)  # access_flags, this_class, super_class
    r.take(2 * r.u2())  # interfaces
    for _ in range(r.u2()):
        r.take(6)
        attributes()
    for _ in range(r.u2()):
        r.take(6)
        attributes()
    class_attributes = set()
    bootstrap_owners = set()
    for _ in range(r.u2()):
        index = r.u2()
        if index <= 0 or index >= count or not isinstance(cp[index], str):
            raise FormatError("invalid attribute name index")
        name = cp[index]
        class_attributes.add(name)
        length = r.u4()
        if name != "BootstrapMethods":
            r.take(length)
            continue
        end = r.pos + length
        if end > len(data):
            raise FormatError("truncated BootstrapMethods attribute")
        n = r.u2()
        for _ in range(n):
            handle_idx = r.u2()
            nargs = r.u2()
            r.take(2 * nargs)
            try:
                handle = cp[handle_idx]
                member = cp[handle[2]]
                owner = cp[member[1]]
                owner_name = cp[owner[1]]
                if handle[0] != 15 or member[0] not in (10, 11) or owner[0] != 7:
                    raise ValueError("unexpected bootstrap handle")
                if not isinstance(owner_name, str):
                    raise ValueError("invalid bootstrap owner")
                bootstrap_owners.add(owner_name)
            except (IndexError, TypeError, ValueError):
                raise FormatError("invalid bootstrap method handle")
        if r.pos != end:
            raise FormatError("invalid BootstrapMethods attribute length")
    if r.pos != len(data):
        raise FormatError("trailing data after classfile")

    features = set()
    for tag, name in ((15, "method_handle_constant"),
                      (16, "method_type_constant"),
                      (17, "constant_dynamic"),
                      (18, "invokedynamic_constant"),
                      (19, "module_constant"),
                      (20, "package_constant")):
        if tags[tag]:
            features.add(name)
    for attr in ("BootstrapMethods", "NestHost", "NestMembers", "Record",
                 "PermittedSubclasses", "Module", "ModulePackages", "ModuleMainClass"):
        if attr in class_attributes:
            features.add("attribute_" + attr)
    if minor == 65535:
        features.add("preview_classfile")
    return {"major": major, "minor": minor,
            "java_release": java_release(major), "features": sorted(features),
            "bootstrap_owners": sorted(bootstrap_owners)}


def _manifest_multirelease(archive):
    # Manifest headers can be folded; unfold continuation lines before check.
    try:
        with archive.open("META-INF/MANIFEST.MF") as stream:
            data = stream.read(128 * 1024)
    except KeyError:
        return False
    lines = data.decode("utf-8", "replace").replace("\r\n", "\n").split("\n")
    unfolded = []
    for line in lines:
        if line.startswith(" ") and unfolded:
            unfolded[-1] += line[1:]
        else:
            unfolded.append(line)
    return any(line.lower().strip() == "multi-release: true" for line in unfolded)


def profile_jar(path):
    counts = Counter()
    versioned_counts = Counter()
    features = Counter()
    bootstrap_owners = Counter()
    errors = []
    previews = 0
    processed = 0
    total = 0
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        if len(entries) > MAX_ENTRIES:
            raise FormatError("archive has too many entries")
        multi_release = _manifest_multirelease(archive)
        for item in entries:
            name = item.filename
            if not name.endswith(".class") or item.is_dir():
                continue
            is_variant = name.startswith("META-INF/versions/")
            if name.startswith("META-INF/") and not is_variant:
                continue
            if item.file_size > MAX_CLASS_BYTES:
                errors.append({"entry": name, "error": "classfile exceeds size limit"})
                continue
            total += item.file_size
            if total > MAX_TOTAL_CLASS_BYTES:
                raise FormatError("archive classfiles exceed total size limit")
            try:
                with archive.open(item) as stream:
                    data = stream.read(MAX_CLASS_BYTES + 1)
                if len(data) > MAX_CLASS_BYTES:
                    raise FormatError("classfile exceeds size limit")
                info = parse_class_profile(data)
            except (FormatError, OSError, EOFError, ValueError, RuntimeError) as err:
                errors.append({"entry": name, "error": str(err)[:150]})
                continue
            (versioned_counts if is_variant else counts)[str(info["major"])] += 1
            if "preview_classfile" in info["features"]:
                previews += 1
            for feat in info["features"]:
                features[feat] += 1
            for owner in info["bootstrap_owners"]:
                bootstrap_owners[owner] += 1
            processed += 1
    version_hist = dict(sorted(counts.items(), key=lambda x: int(x[0])))
    variant_hist = dict(sorted(versioned_counts.items(), key=lambda x: int(x[0])))
    base_max = max((int(n) for n in counts), default=None)
    all_max = max([int(n) for n in counts] + [int(n) for n in versioned_counts], default=None)
    notes = ["Static classfile observations are not proof of runnable Java code or supported JVM instructions."]
    if base_max is not None and base_max > 52:
        notes.append("Base JAR contains Java 9+ classfiles; miniJVM execution requires separate verification.")
    if variant_hist:
        notes.append("Multi-release class variants are reported separately; JarBox selection behavior is not verified.")
    if features["invokedynamic_constant"] or features["constant_dynamic"]:
        notes.append("Dynamic constant/bootstrap references need separate on-device validation.")
    return {
        "jar": Path(path).name,
        "class_count": processed,
        "base_classfile_major_histogram": version_hist,
        "multi_release_classfile_major_histogram": variant_hist,
        "max_base_major": base_max,
        "minimum_base_java_release": java_release(base_max) if base_max else None,
        "max_all_entries_major": all_max,
        "has_post_java8_base_classfile": base_max is not None and base_max > 52,
        "has_preview_classfile": previews > 0,
        "manifest_multi_release": multi_release,
        "feature_class_counts": dict(sorted(features.items())),
        "bootstrap_owner_class_counts": dict(sorted(bootstrap_owners.items())),
        "parse_errors": errors[:50],
        "parse_error_count": len(errors),
        "notes": notes,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("jars", type=Path, nargs="+")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    try:
        payload = {"format": "jarbox-bytecode-profile-v1",
                   "jars": [profile_jar(path) for path in args.jars]}
    except (FormatError, OSError, zipfile.BadZipFile) as err:
        parser.error(str(err))
    result = json.dumps(payload, ensure_ascii=False, sort_keys=True, indent=2) + "\n"
    if args.output:
        args.output.write_text(result, encoding="utf-8")
    else:
        sys.stdout.write(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
