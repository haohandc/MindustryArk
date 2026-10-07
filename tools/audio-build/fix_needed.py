# -*- coding: utf-8 -*-
r"""
把 libarcarm64.so 的 DT_NEEDED 从 `libSDL3.so.0` 改成 `libSDL3.so`。

为什么必须改：
  · 我们自己编的 SDL3 的 SONAME 是 `libSDL3.so.0`
  · 但设备上提供 SDL3 的是 AMCL（`/data/storage/el1/bundle/libs/arm64/libSDL3.so`），
    它的 SONAME 是 **`libSDL3.so`** —— 没有 `.0` 别名
  · 于是动态链接器找不到 `libSDL3.so.0`，libarcarm64.so 加载失败

改成依赖 `libSDL3.so` 还有个额外好处：**和 AMCL 共用同一个 SDL 实例**。
SDL 的音频与视频子系统共享全局状态，若我们用另一份 SDL3，
就会有两个独立实例 —— 窗口归一个、音频设备归另一个，这正是要避免的。

实现方式：在 .dynstr 里做**等长**替换（12+1 字节 -> 10+3 字节），
所有偏移保持不变，因此不可能破坏 ELF 的其它部分。

用法: python fix_needed.py <输入.so> <输出.so>
"""
import io
import os
import shutil
import struct
import sys

sys.stdout.reconfigure(encoding="utf-8")

OLD = b"libSDL3.so.0\x00"
NEW = b"libSDL3.so\x00\x00\x00"      # 必须与 OLD 等长


def main():
    if len(sys.argv) < 3:
        raise SystemExit("用法: python fix_needed.py <in.so> <out.so>")
    src, dst = sys.argv[1], sys.argv[2]

    if len(OLD) != len(NEW):
        raise SystemExit("!! 替换串长度不等，会破坏 ELF 偏移")

    shutil.copyfile(src, dst)
    data = bytearray(open(dst, "rb").read())

    # 解析节头，定位 .dynstr
    e_shoff = struct.unpack("<Q", data[0x28:0x30])[0]
    e_shentsize = struct.unpack("<H", data[0x3A:0x3C])[0]
    e_shnum = struct.unpack("<H", data[0x3C:0x3E])[0]
    e_shstrndx = struct.unpack("<H", data[0x3E:0x40])[0]

    secs = []
    for i in range(e_shnum):
        o = e_shoff + i * e_shentsize
        name, typ, flags, addr, off, size, link, info, align, entsize = struct.unpack("<IIQQQQIIQQ", data[o:o + 64])
        secs.append(dict(name=name, typ=typ, off=off, size=size, link=link))

    shstr = secs[e_shstrndx]
    for s in secs:
        raw = bytes(data[shstr["off"] + s["name"]:])
        s["nm"] = raw[:raw.index(b"\x00")].decode()

    dynstr = next((s for s in secs if s["nm"] == ".dynstr"), None)
    if dynstr is None:
        raise SystemExit("找不到 .dynstr")

    start, end = dynstr["off"], dynstr["off"] + dynstr["size"]
    region = bytes(data[start:end])
    count = region.count(OLD)
    print("  .dynstr 里 '%s' 出现 %d 次" % (OLD[:-1].decode(), count))
    if count != 1:
        raise SystemExit("!! 期望恰好 1 次，实际 %d 次 —— 中止以免改错" % count)

    idx = start + region.index(OLD)
    data[idx:idx + len(OLD)] = NEW
    open(dst, "wb").write(bytes(data))
    print("  已改写 DT_NEEDED: libSDL3.so.0 -> libSDL3.so（等长替换，偏移不变）")
    print("  输出: %s (%d 字节)" % (dst, len(data)))


if __name__ == "__main__":
    main()
