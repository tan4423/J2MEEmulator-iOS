#!/usr/bin/env python3
"""Offline class/method/field API audit against JarBox runtime JARs.

Never executes game Java code. Reports potential static references only:
reflection and dynamic classloading cannot be predicted.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import re
import struct
import sys
import zipfile

MAX_CLASS_BYTES = 8 * 1024 * 1024
MAX_ENTRIES = 30000
DESC = re.compile(r"L([^;<>]+);")


class FormatError(Exception):
    pass


class Reader:
    def __init__(self, data):
        self.data, self.pos = data, 0

    def take(self, n):
        if n < 0 or self.pos + n > len(self.data):
            raise FormatError("truncated classfile")
        part = self.data[self.pos:self.pos + n]
        self.pos += n
        return part

    def u1(self):
        return self.take(1)[0]

    def u2(self):
        return struct.unpack(">H", self.take(2))[0]

    def u4(self):
        return struct.unpack(">I", self.take(4))[0]


def parse_class(data):
    r = Reader(data)
    if r.u4() != 0xCAFEBABE:
        raise FormatError("not a Java classfile")
    minor, major, count = r.u2(), r.u2(), r.u2()
    if count < 1:
        raise FormatError("bad constant pool size")
    cp = [None] * count
    i = 1
    while i < count:
        tag = r.u1()
        if tag == 1:
            cp[i] = (tag, r.take(r.u2()).decode("utf-8", "replace"))
        elif tag in (3, 4):
            r.take(4)
            cp[i] = (tag,)
        elif tag in (5, 6):
            r.take(8)
            cp[i] = (tag,)
            i += 1
        elif tag in (7, 8, 16, 19, 20):
            cp[i] = (tag, r.u2())
        elif tag in (9, 10, 11, 12, 17, 18):
            cp[i] = (tag, r.u2(), r.u2())
        elif tag == 15:
            cp[i] = (tag, r.u1(), r.u2())
        else:
            raise FormatError("unknown constant pool tag " + str(tag))
        i += 1

    def item(index, tag):
        if not 0 < index < count or cp[index] is None or cp[index][0] != tag:
            raise FormatError("invalid constant pool reference")
        return cp[index]

    def utf(i):
        return item(i, 1)[1]

    def cname(i):
        return utf(item(i, 7)[1])

    def attrs():
        for _ in range(r.u2()):
            utf(r.u2())
            r.take(r.u4())

    r.u2()  # access flags
    own = cname(r.u2())
    sup_idx = r.u2()
    parent = cname(sup_idx) if sup_idx else None
    interfaces = [cname(r.u2()) for _ in range(r.u2())]
    fields, methods, needed = set(), set(), set()

    for dest in (fields, methods):
        for _ in range(r.u2()):
            r.u2()
            name, desc = utf(r.u2()), utf(r.u2())
            dest.add((name, desc))
            needed.update(DESC.findall(desc))
            attrs()
    attrs()

    methodrefs, fieldrefs = set(), set()
    for p in cp[1:]:
        if p is None:
            continue
        if p[0] == 7:
            value = utf(p[1])
            needed.update(DESC.findall(value) if value.startswith("[") else [value])
        elif p[0] == 12:
            needed.update(DESC.findall(utf(p[2])))
        elif p[0] in (9, 10, 11):
            owner = cname(p[1])
            nt = item(p[2], 12)
            name, desc = utf(nt[1]), utf(nt[2])
            needed.update(DESC.findall(desc))
            if owner.startswith("["):
                needed.update(DESC.findall(owner))
                continue
            needed.add(owner)
            (fieldrefs if p[0] == 9 else methodrefs).add((owner, name, desc))
    if parent:
        needed.add(parent)
    needed.update(interfaces)
    needed.discard(own)
    return {
        "name": own, "parent": parent, "interfaces": interfaces,
        "methods": methods, "fields": fields, "needed": needed,
        "methodrefs": methodrefs, "fieldrefs": fieldrefs,
    }


def load_jar(path):
    classes, invalid = {}, []
    with zipfile.ZipFile(path) as archive:
        if len(archive.infolist()) > MAX_ENTRIES:
            raise FormatError("too many archive entries")
        for entry in archive.infolist():
            if not entry.filename.endswith(".class") or entry.filename.startswith("META-INF/"):
                continue
            if entry.file_size > MAX_CLASS_BYTES:
                invalid.append({"entry": entry.filename, "error": "oversized class"})
                continue
            try:
                with archive.open(entry) as stream:
                    data = stream.read(MAX_CLASS_BYTES + 1)
                if len(data) > MAX_CLASS_BYTES:
                    raise FormatError("oversized class")
                cl = parse_class(data)
                classes.setdefault(cl["name"], cl)
            except (FormatError, OSError, EOFError, ValueError, RuntimeError) as err:
                invalid.append({"entry": entry.filename, "error": str(err)[:150]})
    return classes, invalid


def resolve_member(owner, signature, field, universe):
    """True/False/None; None means a missing ancestor prevents certainty."""
    pending, visited, incomplete = [owner], set(), False
    while pending:
        key = pending.pop()
        if key in visited:
            continue
        visited.add(key)
        cl = universe.get(key)
        if cl is None:
            # Ignore nothing: a missing non-Object superclass may supply
            # members; but java/lang/Object is a known leaf of the hierarchy
            # and cannot define arbitrary game-specific methods.
            if key == "java/lang/Object":
                known_object_methods = {
                    ("<init>", "()V"), ("equals", "(Ljava/lang/Object;)Z"),
                    ("hashCode", "()I"), ("toString", "()Ljava/lang/String;"),
                    ("getClass", "()Ljava/lang/Class;"),
                    ("notify", "()V"), ("notifyAll", "()V"),
                    ("wait", "()V"), ("wait", "(J)V"), ("wait", "(JI)V"),
                    ("clone", "()Ljava/lang/Object;"), ("finalize", "()V"),
                }
                if not field and signature in known_object_methods:
                    return True
                continue
            incomplete = True
            continue
        if signature in cl["fields" if field else "methods"]:
            return True
        if cl["parent"] and signature[0] != "<init>":
            pending.append(cl["parent"])
        if not field:
            pending.extend(cl["interfaces"])
    return None if incomplete else False


def audit(game, boot, api, maximum=100):
    universe = dict(api)
    universe.update(boot)
    universe.update(game)
    missing_classes, missing_methods, missing_fields = set(), set(), set()
    external = set()
    for cl in game.values():
        for owner in cl["needed"]:
            if owner in game:
                continue
            external.add(owner)
            if owner not in universe:
                missing_classes.add(owner)
        for field, refs in ((False, cl["methodrefs"]), (True, cl["fieldrefs"])):
            for owner, name, descriptor in refs:
                if owner in game:
                    continue
                external.add(owner)
                if owner not in universe:
                    missing_classes.add(owner)
                elif resolve_member(owner, (name, descriptor), field, universe) is False:
                    label = (f"{owner}.{name}:{descriptor}" if field
                             else f"{owner}.{name}{descriptor}")
                    (missing_fields if field else missing_methods).add(label)
    return {
        "classes_in_game": len(game),
        "external_classes_referenced": len(external),
        "missing_class_count": len(missing_classes),
        "missing_method_count": len(missing_methods),
        "missing_field_count": len(missing_fields),
        "missing_classes": sorted(missing_classes)[:maximum],
        "missing_methods": sorted(missing_methods)[:maximum],
        "missing_fields": sorted(missing_fields)[:maximum],
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--boot", required=True, type=Path)
    parser.add_argument("--api", required=True, type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("games", type=Path, nargs="+")
    args = parser.parse_args(argv)
    try:
        boot, e1 = load_jar(args.boot)
        api, e2 = load_jar(args.api)
        reports = []
        for game in args.games:
            classes, errors = load_jar(game)
            item = {"jar": game.name, **audit(classes, boot, api)}
            item["parse_errors"] = errors[:20]
            reports.append(item)
    except (OSError, zipfile.BadZipFile, FormatError) as err:
        parser.error(str(err))
    payload = {
        "format": "jarbox-api-audit-v1",
        "runtime_classes": len(set(boot) | set(api)),
        "runtime_parse_errors": len(e1) + len(e2),
        "note": "Static potential references; reflection/native/dynamic loading are not covered.",
        "games": reports,
    }
    result = json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.write_text(result, encoding="utf-8")
    else:
        sys.stdout.write(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
