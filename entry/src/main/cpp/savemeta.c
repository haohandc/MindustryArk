/* [A]
 * 从 Mindustry 的存档文件（`.msav`）里读出它的元数据。
 *
 * 为什么需要它
 *   存档管理器要显示「这个存档是哪个版本写的、什么地图、多少模组、什么时候存的」。
 *   那些信息**在文件里**，但 ArkTS 读不出来 —— 文件是 zlib 压缩的，而 ArkTS 侧
 *   没有可用的流式解压。所以这一层放 native。
 *
 * 文件格式（2026-10-02 用真存档实测出来的，不是查文档）
 *
 *   1. 整个文件是 **zlib** 流（前两字节 `78 9c`）—— ⚠️ 不是 raw deflate。
 *      ⇒ 与 jarver.c 不同：那边要 `inflateInit2(-15)`，这里用标准的 `inflateInit()`。
 *
 *   2. 解压后的头部是**固定 14 字节**，然后是键值对序列：
 *
 *        MSAV                         4 字节
 *        [u32 大端 格式版本]            4..7    实测出现过 7 和 13
 *        [u16 大端 未知，实测恒为 0]     8..9
 *        [u16 大端 KV 块字节数]         10..11  实测 2422 / 8238 / 5460
 *        [u16 大端 条目数]             12..13  ⭐ 实测 16 / 20 / 16
 *        [键值对...]                   14..    ⭐ 固定偏移
 *
 *   3. 键值对的编码是 `[u16 大端长度][UTF-8 内容]`，键与值各一次前缀：
 *
 *        \x00\x08 playtime \x00\x05 59932
 *        ^^^^^^            ^^^^^^
 *        长 8，大端        长 5，大端
 *
 *      ⚠️ 大端 —— 实测 `\x00\x08` 就是 8，不是 2048。写反了会一直错位。
 *
 * ⛔⛔ 我在这里错过一次，记下来免得重犯：
 *   第一版我写的是 `p = 8`，因为当初是**用正则找字符串**、然后**假设** KV 从版本号后面
 *   就开始。**那是假设，没验过。** 结果真存档上**一条都解不出来**。
 *   ⇒ 用真文件扫偏移才定下来起点是 **14**，而且发现**文件自己写了条目数**。
 *   ⭐ 教训：**「我找到了这些字符串」不等于「我知道它们从哪开始」** ——
 *      正则命中只能证明字节存在，不能证明帧结构。
 *
 * 返回什么
 *   **原始文本**，每行一个 `key=value`。⛔ 这一层不决定显示格式 ——
 *   显示格式会随界面需要而变，而改了它就得重编译这个 .so。
 *   ⭐ 与 jarver.c 同一条约定。
 *
 * ⚠️⚠️ 三个边界，改的时候别破坏：
 *   1. **文件不是合法 msav ⇒ 返回空串**，不抛。玩家完全可以往目录里丢个乱七八糟的东西。
 *   2. **解压有上限** —— 输入上限 INPUT_MAX、输出上限 OUT_MAX。⛔ 没有上限的话，
 *      一个精心构造的小文件能解出几个 GB（解压炸弹），而这是我们自己的进程。
 *   3. **单个值有上限**（VALUE_MAX）。⛔ 我原来在这儿写着「实测 `rules` 超过上限，
 *      会被标成 omitted」—— **那是猜的，实测它没有超**（0.msav 与 sector-erekir-10.msav
 *      的 `rules` 都完整解出来了）。
 *      ⚠️ 但这条上限仍然必要：`rules` 里含 256 个队伍的条目，**将来可能更大**，
 *      而 `sector` 正好在它里面（`rules:...sector:erekir-10...`）⇒ 一旦超限被略过，
 *      调用方必须能从**文件名**或 `sectorPreset` 拿到归属，⛔ 不能只依赖 rules。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <zlib.h>
#include <node_api.h>

/** [B] 只读压缩文件的前这么多字节。元数据在解压流的头几 KB 内，够用。 */
#define INPUT_MAX  (256 * 1024)

/** [A] 解压输出的上限。
 * ⚠️ 元数据实测落在解压后 ~2.5 KB 处，而 `rules` 一个字段就有 5822 字节。
 * 8 KB 留的余量足够覆盖到 `rules` 结束，同时把解压炸弹挡在门外。 */
#define OUT_MAX    (32 * 1024)

/** [B] 单个值的上限；超过就整条略过并如实记下字节数。 */
#define VALUE_MAX  (8 * 1024)

/** [A] 返回文本的上限。`rules` 那样的值会让输出到 ~9 KB，这里给足。 */
#define TEXT_MAX   (32 * 1024)

/** [B] 头部固定 14 字节，键值对从这里开始（见上面的格式说明）。 */
#define KV_START   14

static uint16_t be16(const unsigned char *p)
{
    return (uint16_t)((p[0] << 8) | p[1]);
}

/* [A]
 * 一个「看起来像键」的判断，只给**回退扫描**用。
 *
 * 为什么需要它：回退扫描要从一堆候选偏移里挑出真正的那个，而**值是任意可打印字节** ——
 * 实测从偏移 24 起也能「解出」6 条，因为那些值（`2410200`、`212.87474`）本身就可打印，
 * 于是被当成了键。⇒ 键必须是**纯字母标识符**，那一条就把数值和日期排除了。
 *
 * ⚠️ 主路径（偏移 14）**不依赖**这个判断 —— 它按文件的声明走。
 *    所以将来万一出现带数字的键，主路径照样能用，只是回退扫描会失效。
 */
static int looks_like_key(const unsigned char *p, size_t n)
{
    if (n < 3 || n > 24) return 0;
    for (size_t i = 0; i < n; i++) {
        unsigned char c = p[i];
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z'))) return 0;
    }
    return 1;
}

/* [A]
 * 从 `start` 起解析键值对，写进 out，返回**写成功的条数**。
 *
 * ⚠️ out 是**覆盖式**写入（每次从 o = 0 开始）—— 回退扫描要拿它重试，
 *    所以它不能依赖上一次调用的结果。
 *
 * ⭐ 每读一个就前进 value 的长度：**不能靠找分隔符**，因为值是任意字节
 *    （`rules` 里就是嵌套的 HJSON，里面什么字符都有）。
 */
static size_t parse_pairs(const unsigned char *buf, size_t len, size_t start,
                          char *out, size_t outlen)
{
    size_t o = 0;
    size_t p = start;
    size_t got = 0;

    while (p + 2 <= len) {
        size_t klen = be16(buf + p);
        p += 2;
        /* [B] 键长上限 64：真键最长的是 hasExternalAssets（17）。给足余量，
         * 同时把明显错位的读取挡住（错位时 klen 往往是几千）。 */
        if (klen == 0 || klen > 64 || p + klen + 2 > len) {
            break;
        }
        const unsigned char *key = buf + p;
        p += klen;

        size_t vlen = be16(buf + p);
        p += 2;
        if (p + vlen > len) {
            break;   /* 值被读取上限截断了 ⇒ 到这儿为止 */
        }
        const unsigned char *val = buf + p;
        p += vlen;
        got++;

        /* [B] 值太大就如实记下，而不是悄悄截断它 —— 截断过的 JSON 会看起来像坏数据。 */
        char line[128];
        int hn;
        /* ⚠️⚠️ `snprintf` 返回的是「**本该**写入的长度」，它**可能大于缓冲区**。
         * 拿它当 `memcpy` 的长度就会**读过 `line` 的末尾** —— 那是栈越界读。
         * ⇒ 必须夹到实际写入的长度。 */
        int cap = (int)sizeof(line) - 1;
        int kn = (int)(klen > 40 ? 40 : klen);
        if (vlen > VALUE_MAX) {
            hn = snprintf(line, sizeof(line), "%.*s=(omitted, %u bytes)\n",
                          kn, (const char *)key, (unsigned)vlen);
            if (hn > cap) hn = cap;
            if (hn > 0 && o + (size_t)hn < outlen) {
                memcpy(out + o, line, (size_t)hn);
                o += (size_t)hn;
            }
        } else {
            hn = snprintf(line, sizeof(line), "%.*s=", kn, (const char *)key);
            if (hn > cap) hn = cap;
            if (hn > 0 && o + (size_t)hn + vlen + 1 < outlen) {
                memcpy(out + o, line, (size_t)hn);
                o += (size_t)hn;
                memcpy(out + o, val, vlen);
                o += vlen;
                out[o++] = '\n';
            }
        }
    }

    out[o < outlen ? o : (outlen - 1)] = '\0';
    return got;
}

/* [A]
 * 只有这一个函数是承重的：把 `path` 的元数据解出来，写进 out。
 * 返回写进去的字节数（0 表示「读不出来」，调用方据此回空串）。
 */
static size_t read_save_meta(const char *path, char *out, size_t outlen)
{
    FILE *f = fopen(path, "rb");
    if (!f) {
        return 0;
    }

    unsigned char *in = (unsigned char *)malloc(INPUT_MAX);
    unsigned char *buf = (unsigned char *)malloc(OUT_MAX);
    if (!in || !buf) {
        free(in);
        free(buf);
        fclose(f);
        return 0;
    }

    size_t inlen = fread(in, 1, INPUT_MAX, f);
    fclose(f);

    /* [A] 解压。zlib 格式（前两字节 78 9c），不是 raw deflate。
     * ⚠️ 输入被截断时 inflate 会返回 Z_BUF_ERROR —— 那是**正常**的，
     * 因为我们本来就读了一部分。只要解出来的字节够用就行。 */
    z_stream s;
    memset(&s, 0, sizeof(s));
    if (inflateInit(&s) != Z_OK) {
        free(in);
        free(buf);
        return 0;
    }
    s.next_in = in;
    s.avail_in = (uInt)inlen;
    s.next_out = buf;
    s.avail_out = (uInt)OUT_MAX;
    int rc = inflate(&s, Z_NO_FLUSH);
    size_t outlen_dec = OUT_MAX - s.avail_out;
    inflateEnd(&s);
    free(in);

    /* [B] `Z_BUF_ERROR` 是**正常**的：输入按 INPUT_MAX 截断，inflate 到没数据就报它。
     * 真正要挡的是「解压失败且一个字节都没出来」—— 那不是存档，别往下走。 */
    if (outlen_dec == 0 && rc != Z_OK) {
        free(buf);
        return 0;
    }

    if (outlen_dec < 8) {
        free(buf);
        return 0;
    }

    /* [B] 魔数与格式版本。不是 MSAV 就不是存档。 */
    if (memcmp(buf, "MSAV", 4) != 0) {
        free(buf);
        return 0;
    }

    size_t got = parse_pairs(buf, outlen_dec, KV_START, out, outlen);

    /* [A] 自检 + 回退。
     *
     * 为什么需要：头部布局是我**从三个样本反推**出来的，不是从游戏的源码读来的。
     * 将来格式一变（或者出现第四个样本不符合），主路径会**静默地少读几条** ——
     * 那是最难发现的一类故障。⇒ 解出来的条数太少时，退到扫描。
     *
     * ⚠️ 扫描用 looks_like_key 过滤，因为**偏移 24 那样的假阳性也「解得出来」**
     *    （值是任意可打印字节，会被当成键）。见那个函数的说明。
     */
    if (got < 2) {
        for (size_t t = KV_START + 1; t < 48 && t + 4 <= outlen_dec; t++) {
            if (!looks_like_key(buf + t + 2, be16(buf + t))) {
                continue;
            }
            size_t n = parse_pairs(buf, outlen_dec, t, out, outlen);
            if (n >= 3) {
                got = n;
                break;
            }
        }
    }

    free(buf);
    return got == 0 ? 0 : strlen(out);
}

static napi_value SaveMetaText(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);

    napi_value out;
    napi_create_string_utf8(env, "", 0, &out);   /* 默认：空串 */
    if (argc < 1) return out;

    char path[1024];
    size_t n = 0;
    if (napi_get_value_string_utf8(env, argv[0], path, sizeof(path), &n) != napi_ok) return out;

    static char text[TEXT_MAX];
    size_t got = read_save_meta(path, text, sizeof(text));
    if (got == 0) return out;

    napi_create_string_utf8(env, text, NAPI_AUTO_LENGTH, &out);
    return out;
}

static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        { "saveMetaText", NULL, SaveMetaText, NULL, NULL, NULL, napi_default, NULL },
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

static napi_module savemeta_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = NULL,
    .nm_register_func = Init,
    .nm_modname = "savemeta",
    .nm_priv = ((void*)0),
    .reserved = { 0 },
};

void __attribute__((constructor)) RegisterSaveMetaModule(void)
{
    napi_module_register(&savemeta_module);
}
