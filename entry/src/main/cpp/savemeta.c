/* 从 Mindustry 存档（`.msav`）里读出元数据：文件是 zlib 压缩的，ArkTS 侧没有可用的流式解压。
 * 格式（2026-10-02 用真存档实测）：整个文件是 **zlib** 流（前两字节 `78 9c`，⚠️ 不是 raw deflate
 * ⇒ 用标准 `inflateInit()`）；解压后头部**固定 14 字节**，KV 对从**偏移 14** 起，文件在第 12..13 字节
 * 自带条目数（实测 16/20/16）。KV 为 `[u16 大端长度][UTF-8 内容]`，键值各一次前缀（如
 * `\x00\x08 playtime \x00\x05 59932`）；⚠️ 大端 —— `\x00\x08` 就是 8，写反会一直错位。
 * 返回**原始文本**（每行 `key=value`），显示格式交给 ArkTS；不合法 msav ⇒ 返回空串，不抛。
 * ⚠️ INPUT_MAX / OUT_MAX / VALUE_MAX（防解压炸弹与超大值）⛔ 不能删。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <zlib.h>
#include <node_api.h>

/** 只读压缩文件的前这么多字节；元数据在解压流的头几 KB 内。 */
#define INPUT_MAX  (256 * 1024)

/** 解压输出的上限：`rules` 一个字段就有 5822 字节，留够余量，同时把解压炸弹挡在门外。 */
#define OUT_MAX    (32 * 1024)

/** 单个值的上限；超过就整条略过并如实记下字节数。 */
#define VALUE_MAX  (8 * 1024)

/** 返回文本的上限；`rules` 那样的值会让输出到 ~9 KB，这里给足。 */
#define TEXT_MAX   (32 * 1024)

/** 头部固定 14 字节，键值对从这里开始。 */
#define KV_START   14

static uint16_t be16(const unsigned char *p)
{
    return (uint16_t)((p[0] << 8) | p[1]);
}

/* 一个「看起来像键」的判断，只给**回退扫描**用：值是任意可打印字节，实测从偏移 24 起也能
 * 「解出」6 条（`2410200`、`212.87474` 本身可打印，被当成了键）⇒ 键必须是**纯字母标识符**。
 * ⚠️ 主路径（偏移 14）不依赖它 —— 将来若有带数字的键，主路径照样能用，只是回退扫描会失效。 */
static int looks_like_key(const unsigned char *p, size_t n)
{
    if (n < 3 || n > 24) return 0;
    for (size_t i = 0; i < n; i++) {
        unsigned char c = p[i];
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z'))) return 0;
    }
    return 1;
}

/* 从 `start` 起解析键值对，写进 out，返回**写成功的条数**。
 * ⚠️ out 是**覆盖式**写入（每次从 o = 0 开始）—— 回退扫描要拿它重试，不能依赖上次结果。
 * ⭐ 每读一个就前进 value 的长度：**不能靠找分隔符**，值是任意字节（`rules` 里是嵌套 HJSON）。 */
static size_t parse_pairs(const unsigned char *buf, size_t len, size_t start,
                          char *out, size_t outlen)
{
    size_t o = 0;
    size_t p = start;
    size_t got = 0;

    while (p + 2 <= len) {
        size_t klen = be16(buf + p);
        p += 2;
        /* 键长上限 64：真键最长的是 hasExternalAssets（17）。给足余量，
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

        /* 值太大就如实记下，而不是悄悄截断它 —— 截断过的 JSON 会看起来像坏数据。 */
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

/* 把 `path` 的元数据解出来写进 out。返回写进去的字节数（0 表示读不出来，调用方据此回空串）。 */
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

    /* 解压：zlib 格式（前两字节 78 9c），不是 raw deflate。
     * ⚠️ 输入被截断时 inflate 返回 Z_BUF_ERROR 是**正常**的（本来只读了一部分），够用就行。 */
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

    /* `Z_BUF_ERROR` 是**正常**的：输入按 INPUT_MAX 截断，inflate 到没数据就报它。
     * 真正要挡的是「解压失败且一个字节都没出来」—— 那不是存档，别往下走。 */
    if (outlen_dec == 0 && rc != Z_OK) {
        free(buf);
        return 0;
    }

    if (outlen_dec < 8) {
        free(buf);
        return 0;
    }

    /* 魔数与格式版本。不是 MSAV 就不是存档。 */
    if (memcmp(buf, "MSAV", 4) != 0) {
        free(buf);
        return 0;
    }

    size_t got = parse_pairs(buf, outlen_dec, KV_START, out, outlen);

    /* 自检 + 回退：头部布局是从三个样本反推的，不是读游戏源码来的。将来格式一变，
     * 主路径会**静默地少读几条** —— 那是最难发现的一类故障 ⇒ 条数太少时退到扫描。
     * ⚠️ 扫描用 looks_like_key 过滤，因为偏移 24 那样的假阳性也「解得出来」（见该函数）。 */
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
