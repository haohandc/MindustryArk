# -*- coding: utf-8 -*-
r"""
把一次发布要上传的三个文件摆进 dist/。

    python scripts/stage_release.py

为什么这是一个脚本，而不是谁手工拷一下

    这一步【派生自另一个产物】（构建输出），而本项目为此付过一次代价：
    payload zip 在 2026-09-22 之前是手工打的，发出去的那份已经悄悄少了 21 个条目，
    其中有 jdkhome/conf/security/java.security.so —— 少了它 JVM 连一个类都定义不了 ——
    而那个 zip 看起来完全正常。⇒ 规矩是：派生步骤一律脚本化，并带前置断言。

它断言什么

    1. 版本三处一致：文件名、config.APP_VERSION、以及 HAP 里 pack.info 的 version。
       ⛔ 「我记得三处一起改过」不是安全假设。
    2. 要摆的是【未签名】那一份。
       ⚠️⚠️ 实测（2026-10-03，同一版的两份产物）：**签名与未签名无法用内容区分** ——
       100 个共同条目的 CRC 逐个相同、都有 module.json；差异只有「多一个 .pages.info」
       和约 2.4 MB 的签名块（而后者不在 zip 结构里，见下方 note）。
       ⇒ 判据只能是**文件名**（`-unsigned.hap` 是 hvigor 的契约，历来每次发布都用它）
         加上 pack.info 的版本。
       ⛔ 不要在这里发明更聪明的检查：**在正确的工作树上失败的检查，和坏树上通过的检查
         是同一种缺陷 —— 它会让读的人学会忽略它。**
    3. 拷贝真的落地了（重新哈希比对）。写下一个文件并相信它在，正是本脚本存在的理由。
    4. payload zip 存在，且**不比 entry/libs 里的任何文件旧** —— 那正是它当初悄悄过期的形态。
    5. 发布正文存在。

不做什么

    ⛔ 不跑 verify_hap.py（那是另一道闸门，很慢，而且它自己已经优先挑 `-unsigned.hap`）。
       跑它：python scripts/verify_hap.py
    ⛔ 不删 dist/ 里别的版本的文件 —— 那是历次发布的记录。
"""
import hashlib
import io
import json
import os
import shutil
import sys
import zipfile

sys.stdout.reconfigure(encoding="utf-8")
# ⚠️ stderr 也要 —— `sys.exit(消息)` 走的是 stderr，而这个脚本的报错是中文的。
#    只改 stdout 的话，报错在这里的 GBK 控制台上会变成解不开的字节：
#    实测（2026-10-03）调用方拿到的是 `0xb1` 开头的乱码，而不是那句「payload 过期了」。
sys.stderr.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config


def sha256f(path):
    h = hashlib.sha256()
    with io.open(path, "rb") as f:
        while True:
            b = f.read(1 << 20)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def haps_for_this_version():
    """当前版本的 HAP，未签名那份排在最前。"""
    hits = []
    for dp, _d, fs in os.walk(config.OUT_DIR):
        for f in fs:
            if f.endswith(".hap") and f.startswith(config.ARTIFACT_NAME):
                hits.append(os.path.join(dp, f))
    hits.sort()
    unsigned = [p for p in hits if p.endswith("-unsigned.hap")]
    return (unsigned + [p for p in hits if p not in unsigned]), hits


def version_in_pack_info(path):
    """HAP 的 pack.info 里写着的版本，形如 (name, code)。读不到就是 (None, None)。"""
    try:
        with zipfile.ZipFile(path) as z:
            info = json.loads(z.read("pack.info").decode("utf-8"))
        v = info["summary"]["app"]["version"]
        return (str(v.get("name", "")), v.get("code"))
    except Exception as e:
        print("   !! 读 pack.info 失败：%s" % e)
        return (None, None)


def main():
    root = config.PROJECT_ROOT
    dist = os.path.join(root, "dist")
    os.makedirs(dist, exist_ok=True)

    # --- 1. 挑出这一版的 HAP，并断言它真的是这一版、真的是未签名的那份 ----------
    ordered, all_hits = haps_for_this_version()
    if not all_hits:
        sys.exit("!! %s 下没有 .hap\n"
                 "   run: bash build.sh assembleHap --mode module "
                 "-p product=%s -p buildMode=<debug|release>" % (config.OUT_DIR, config.PRODUCT))
    if not ordered:
        others = [os.path.basename(p) for p in all_hits]
        sys.exit("!! 没有 %s 这一版的 HAP；这里有的是：%s\n"
                 "   名字带了版本号的包不能改成没带 —— 那会让版本闸门为此报出一个假的不匹配"
                 % (config.APP_VERSION, others))

    src = ordered[0]
    if not os.path.basename(src).endswith("-unsigned.hap"):
        sys.exit("!! 只找到已签名的那份：%s\n"
                 "   发布页要放的是【未签名】的 HAP（%s-unsigned.hap）——\n"
                 "   带签名的包只用于装机，⛔ 不能当发布附件。"
                 % (os.path.basename(src), config.ARTIFACT_NAME))

    print("staging %s" % config.APP_VERSION)
    print("   source  %s" % src)
    name, code = version_in_pack_info(src)
    if name != config.APP_VERSION or code != config.VERSION_CODE:
        sys.exit("!! 版本不符：pack.info 说 %r / %r，而 config 说 %r / %r\n"
                 "   三处（文件名、config.py、app.json5）必须一起改，见 scripts/config.py"
                 % (name, code, config.APP_VERSION, config.VERSION_CODE))
    print("   pack.info  version %s / code %s   OK" % (name, code))

    # 已签名那份如果也在，说一声 —— 它在产物目录里是正常的，只是别被挑错。
    twins = [p for p in all_hits if p != src and not p.endswith("-unsigned.hap")]
    if twins:
        print("   note    同目录还有已签名的 %s，本次不使用"
              % os.path.basename(twins[0]))

    # --- 2. 拷贝并核对它真的落地了 -----------------------------------------
    dst_hap = os.path.join(dist, os.path.basename(src))
    shutil.copy2(src, dst_hap)
    if sha256f(src) != sha256f(dst_hap):
        sys.exit("!! 拷贝与源不一致：%s" % dst_hap)
    print("   wrote   %s   %d B   与源逐字节相同" % (os.path.basename(dst_hap),
                                                  os.path.getsize(dst_hap)))

    # --- 3. payload zip：存在，且不比 entry/libs 旧 --------------------------
    dst_zip = os.path.join(dist, "%s-payload.zip" % config.ARTIFACT_NAME)
    if not os.path.isfile(dst_zip):
        sys.exit("!! 缺少 %s\n   run: python scripts/make_payload_zip.py"
                 % os.path.basename(dst_zip))
    zip_time = os.path.getmtime(dst_zip)
    newer = []
    for dp, _d, fs in os.walk(config.LIBS):
        for f in fs:
            p = os.path.join(dp, f)
            if os.path.getmtime(p) > zip_time:
                newer.append(os.path.relpath(p, config.PROJECT_ROOT))
    if newer:
        sys.exit("!! payload zip 比 entry/libs 里的 %d 个文件旧 —— 它已经过期了：\n   %s\n"
                 "   run: python scripts/make_payload_zip.py"
                 % (len(newer), "\n   ".join(sorted(newer)[:5])))
    print("   payload %s   %d B" % (os.path.basename(dst_zip), os.path.getsize(dst_zip)))

    # --- 4. 正文 ------------------------------------------------------------
    body = os.path.join(dist, "RELEASE-BODY-v%s.md" % config.APP_VERSION)
    if not os.path.isfile(body):
        sys.exit("!! 缺少 %s —— 发布表单里要贴的就是它" % os.path.basename(body))
    print("   body    %s   %d B" % (os.path.basename(body), os.path.getsize(body)))

    # --- 5. 打印台账要用的那几个数 ------------------------------------------
    print("\n附件两个（上传这两个）：")
    for p in (dst_hap, dst_zip):
        print("   %-46s %12d B  %s" % (os.path.basename(p), os.path.getsize(p), sha256f(p)))
    print("\n⚠️ 这两个哈希是【本地】数。RELEASE-MAINTENANCE.md 的台账要求发布之后")
    print("   把附件【下载回来重新哈希】——本地哈希证明不了别人下到的东西。")
    print("\n下一步：python scripts/verify_hap.py")


if __name__ == "__main__":
    main()
