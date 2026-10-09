import struct, sys, os, re
sys.stdout.reconfigure(encoding="utf-8")

def dynsyms(path):
    d = open(path, "rb").read()
    sh = struct.unpack("<Q", d[0x28:0x30])[0]
    es = struct.unpack("<H", d[0x3A:0x3C])[0]
    n  = struct.unpack("<H", d[0x3C:0x3E])[0]
    sx = struct.unpack("<H", d[0x3E:0x40])[0]
    secs = []
    for i in range(n):
        o = sh + i * es
        nm, typ, fl, ad, off, sz, lk, inf, al, en = struct.unpack("<IIQQQQIIQQ", d[o:o+64])
        secs.append(dict(nm=nm, typ=typ, off=off, size=sz, lk=lk, en=en))
    s = secs[sx]
    for x in secs:
        y = d[s["off"]+x["nm"]:]; x["name"] = y[:y.index(b"\0")].decode()
    out = set()
    for x in secs:
        if x["name"] == ".dynsym":
            st = secs[x["lk"]]
            for j in range(x["size"] // x["en"]):
                o = x["off"] + j * x["en"]
                nm, info, other, shndx, val, sz = struct.unpack("<IBBHQQ", d[o:o+24])
                if shndx == 0:
                    continue
                y = d[st["off"]+nm:]; out.add(y[:y.index(b"\0")].decode())
    return out

# 路径一律可覆盖，且不含用户名（理由见 build.sh 顶部那段）
_TMPROOT = os.environ.get("ARK_TMP") or os.environ.get("TEMP") or os.environ.get("TMPDIR") or "/tmp"
TB = os.environ.get("ARK_SOLOUD_BUILD") or os.path.join(_TMPROOT, "soloudbuild")
a = dynsyms(os.path.join(TB, "libarcarm64_new.so"))
b = dynsyms(os.path.join(os.environ["TEMP"], "real_arcarm64.so"))

ja = {x for x in a if x.startswith("Java_arc_audio_Soloud_")}
jb = {x for x in b if x.startswith("Java_arc_audio_Soloud_")}

print("导出符号总数:  我们 %d   官方 %d" % (len(a), len(b)))
print("JNI 符号:      我们 %d   官方 %d" % (len(ja), len(jb)))
print()
print("★ JNI 符号集完全一致 =", ja == jb)
print("  我们有他们没有:", sorted(ja - jb) or "无")
print("  他们有我们没有:", sorted(jb - ja) or "无")
print()
sola = {x for x in a if "SoLoud" in x or "Soloud" in x}
solb = {x for x in b if "SoLoud" in x or "Soloud" in x}
print("SoLoud 相关符号: 我们 %d   官方 %d" % (len(sola), len(solb)))
inter = sola & solb
print("  官方独有 (我们缺): %d" % len(solb - sola))
for x in sorted(solb - sola)[:8]:
    print("     ", x)
