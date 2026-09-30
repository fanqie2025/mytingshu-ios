# -*- coding: utf-8 -*-
"""解析 Mach-O 可执行文件头，确认是不是合格的 iOS arm64 可执行文件。"""
import struct
import sys

sys.stdout.reconfigure(encoding="utf-8")

LC_BUILD_VERSION = 0x32
LC_VERSION_MIN_IPHONEOS = 0x25
LC_MAIN = 0x80000028
LC_LOAD_DYLIB = 0xC
LC_ID_DYLIB = 0xD
LC_SEGMENT_64 = 0x19

PLATFORMS = {1: "macOS", 2: "iOS", 3: "tvOS", 4: "watchOS", 5: "bridgeOS", 6: "macCatalyst", 7: "iOSSimulator"}

FILETYPES = {1: "MH_OBJECT", 2: "MH_EXECUTE", 6: "MH_DYLIB", 8: "MH_BUNDLE"}

CPU = {0x0100000C: "arm64", 0x01000007: "x86_64", 0x0000000C: "arm"}


def u32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def u64(b, o):
    return struct.unpack_from("<Q", b, o)[0]


def ver(v):
    return "%d.%d.%d" % ((v >> 16) & 0xFFFF, (v >> 8) & 0xFF, v & 0xFF)


def main(path):
    with open(path, "rb") as f:
        b = f.read()
    magic = u32(b, 0)
    if magic not in (0xFEEDFACF, 0xFEEDFACE):
        print("不是 Mach-O：magic=0x%X" % magic)
        return 1
    is64 = magic == 0xFEEDFACF
    cputype = u32(b, 4)
    filetype = u32(b, 12)
    ncmds = u32(b, 16)
    print("文件        : %s" % path)
    print("架构        : %s" % CPU.get(cputype, hex(cputype)))
    print("文件类型    : %s (0x%X)" % (FILETYPES.get(filetype, "?"), filetype))
    print("LoadCommand : %d 条" % ncmds)

    off = 32 if is64 else 28
    dylibs = []
    main_ok = False
    for _ in range(ncmds):
        cmd = u32(b, off)
        cmdsize = u32(b, off + 4)
        if cmd == LC_BUILD_VERSION:
            platform = u32(b, off + 8)
            minos = u32(b, off + 12)
            sdk = u32(b, off + 16)
            print("平台        : %s   最低系统 %s   SDK %s" % (PLATFORMS.get(platform, platform), ver(minos), ver(sdk)))
        elif cmd == LC_VERSION_MIN_IPHONEOS:
            print("最低系统(旧式): %s  SDK %s" % (ver(u32(b, off + 8)), ver(u32(b, off + 12))))
        elif cmd == LC_MAIN:
            main_ok = True
        elif cmd in (LC_LOAD_DYLIB, LC_ID_DYLIB):
            name_off = u32(b, off + 8)
            start = off + name_off
            end = b.index(b"\x00", start)
            dylibs.append(b[start:end].decode("utf-8", "replace"))
        off += cmdsize
    print("入口(LC_MAIN): %s" % ("有" if main_ok else "缺失！"))
    print("依赖库 %d 个：" % len(dylibs))
    for d in dylibs:
        print("   - %s" % d)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
