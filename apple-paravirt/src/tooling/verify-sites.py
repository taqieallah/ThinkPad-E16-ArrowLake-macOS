#!/usr/bin/env python3
"""Static verification of the AppleParavirtGPU live-patch plan.

Checks, against the real 25G241 Mach-O and its disassembly:
  * the image identity (thin x86_64 KEXTBUNDLE with the audited UUID);
  * every patched site's bytes are exactly the expected original bytes;
  * every site starts on an instruction boundary and its span ends on one
    (a near CALL plus NOP padding must never split an instruction);
  * continuation == text_offset + span;
  * the unpatched (shared-cell) reads still match, and are marked unpatched;
  * kext/APVSites.generated.hpp is in sync with kext/sites.json;
  * every site span is 5..16 bytes, so a rel32 CALL fits.

Usage: python3 verify-sites.py [Mach-O path] [sites.json path]
Exit status 0 on PASS.
"""
import json
import pathlib
import re
import struct
import subprocess
import sys
import uuid

ROOT = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_IMAGE = ROOT / "apv" / "com.apple.driver.AppleParavirtGPU"
DEFAULT_SITES = ROOT / "kext" / "sites.json"
IMAGE_UUID = uuid.UUID("0cae9e29-bc33-315d-82a7-a7d30e9b971e")
TEXT_VMADDR = 0x14898000


def fail(message):
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def parse_macho(data):
    if len(data) < 32:
        fail("truncated Mach-O header")
    magic, cputype, _, filetype, ncmds, sizeofcmds, _, _ = struct.unpack_from("<8I", data)
    if magic != 0xFEEDFACF or cputype != 0x01000007 or filetype != 11:
        fail("expected a thin little-endian x86_64 KEXTBUNDLE")
    offset = 32
    end = 32 + sizeofcmds
    image_uuid = None
    text = None
    for _ in range(ncmds):
        cmd, length = struct.unpack_from("<II", data, offset)
        if length < 8 or offset + length > len(data):
            fail("invalid load command")
        if cmd == 0x1B:
            if length != 24 or image_uuid is not None:
                fail("invalid or duplicate LC_UUID")
            image_uuid = uuid.UUID(bytes=data[offset + 8:offset + 24])
        elif cmd == 0x19 and length >= 72:
            name, _, _, file_offset, file_size = struct.unpack_from("<16s4Q", data, offset + 8)
            if name.rstrip(b"\0") == b"__TEXT":
                if text is not None or file_offset + file_size > len(data):
                    fail("invalid or duplicate __TEXT")
                text = (file_offset, file_size)
        offset += length
    if offset != end or image_uuid != IMAGE_UUID or text is None:
        fail(f"unexpected image identity (uuid={image_uuid})")
    return text


def instruction_starts(image):
    """Return (starts, function_of_va) parsed from llvm-objdump."""
    disassembly = subprocess.run(
        ["xcrun", "llvm-objdump", "-d", "--no-show-raw-insn", "--symbolize-operands", str(image)],
        capture_output=True, text=True, check=True).stdout
    starts = set()
    functions = []
    for line in disassembly.splitlines():
        match = re.match(r"^([0-9a-f]+):", line)
        if match:
            starts.add(int(match.group(1), 16))
            continue
        match = re.match(r"^([0-9a-f]+) <(.+)>:$", line)
        if match:
            functions.append((int(match.group(1), 16), match.group(2)))
    return starts, functions


def symbol_at(functions, va):
    best = None
    for start, name in functions:
        if start <= va:
            best = (start, name)
        else:
            break
    return best


def main():
    image = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_IMAGE
    sites_path = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_SITES
    data = image.read_bytes()
    text_offset, text_size = parse_macho(data)
    doc = json.loads(sites_path.read_text())
    starts, functions = instruction_starts(image)

    def va(text_off):
        return TEXT_VMADDR + text_off

    checked = 0
    for site in doc["sites"]:
        name = site["name"]
        offset = int(site["text_offset"])
        span = int(site["span"])
        original = bytes.fromhex(site["original"])
        continuation = int(site["continuation"])
        if span != len(original):
            fail(f"{name}: span {span} != original length {len(original)}")
        if not 5 <= span <= 16:
            fail(f"{name}: span {span} cannot hold a near call")
        branch = int(site.get("branch_target", 0))
        if site["kind"] == "read_branch":
            if branch != offset + span:
                fail(f"{name}: branch_target != text_offset + span")
        elif continuation != offset + span:
            fail(f"{name}: continuation != text_offset + span")
        if offset + span > text_size:
            fail(f"{name}: site outside __TEXT")
        actual = data[text_offset + offset:text_offset + offset + span]
        if actual != original:
            fail(f"{name}: bytes {actual.hex(' ')} != expected {original.hex(' ')}")
        if va(offset) not in starts:
            fail(f"{name}: site does not start on an instruction boundary")
        if va(offset + span) not in starts:
            fail(f"{name}: span end does not land on an instruction boundary")
        if branch and va(branch) not in starts:
            fail(f"{name}: branch target does not land on an instruction boundary")
        if branch and va(continuation) not in starts:
            fail(f"{name}: branch continuation does not land on an instruction boundary")
        enclosing = symbol_at(functions, va(offset))
        if enclosing is None:
            fail(f"{name}: no enclosing function")
        print(f"  site {site['id']} {name:26s} __TEXT+0x{offset:05x} span {span:2d} "
              f"bar 0x{int(site['bar_offset']):04x} kind={site['kind']:12s} "
              f"in {enclosing[1]} (+0x{va(offset) - enclosing[0]:x})")
        checked += 1

    for site in doc.get("unpatched_register_reads", []):
        offset = int(site["text_offset"])
        original = bytes.fromhex(site["original"])
        actual = data[text_offset + offset:text_offset + offset + len(original)]
        if actual != original:
            fail(f"unpatched read at __TEXT+0x{offset:05x}: bytes differ")
        if va(offset) not in starts:
            fail(f"unpatched read at __TEXT+0x{offset:05x} is not an instruction start")
        print(f"  cell  ----  {site['role'][:60]:60s} __TEXT+0x{offset:05x} (unpatched)")
        checked += 1

    # The generated header must match sites.json.
    subprocess.run([sys.executable, str(ROOT / "tooling" / "gen-site-table.py")],
                   check=True, capture_output=True)
    generated = (ROOT / "kext" / "APVSites.generated.hpp").read_text()
    for site in doc["sites"]:
        needle = f"0x{int(site['text_offset']):x}, {int(site['span'])},"
        if needle not in generated:
            fail(f"generated header is missing site {site['name']}")

    print(f"PASS: {len(doc['sites'])} patched sites and "
          f"{len(doc.get('unpatched_register_reads', []))} shared-cell reads verified "
          f"against {IMAGE_UUID} (__TEXT {text_size:#x} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
