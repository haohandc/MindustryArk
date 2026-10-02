/* 读出一个 Mindustry jar 自带的版本号，给启动器的列表显示。
 * 版本号在 jar 的 `version.properties` 里，ZIP 中为 **raw deflate**：@ohos.zlib 只有
 * `inflateInit`（zlib 头 + adler32），ArkTS 侧没有 `inflateInit2(-15)`；而 NDK sysroot 里就有
 * libz（openharmony/native/sysroot/usr/lib/aarch64-linux-ohos/libz.so）⇒ 用真 zlib 的
 * `inflateInit2(-MAX_WBITS)` 一行搞定，毫秒级、不写任何临时文件。
 * 不用 java.util.zip.ZipFile：那一刻 JVM 还没建起来，而版本号要在启动器界面（游戏树之前）显示。
 * ⚠️ 输入是【玩家自己下载的文件】：每个从文件读出的偏移和长度都要先对文件大小校验过再使用；
 *    失败一律返回【空串】，不抛不崩 —— 那个 jar 照样能被选中、照样能启动。
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <zlib.h>
#include <node_api.h>

/* EOCD 记录的固定部分，末尾的注释长度可变，所以要先搜签名。 */
#define EOCD_SIG      0x06054b50u   /* "PK\005\006" */
#define EOCD_MIN      22
#define MAX_COMMENT   65535
/* 中央目录条目里我们需要的字段位置（全部是小端）。 */
#define CD_SIG        0x02014b50u   /* "PK\001\002" */
#define CD_FIXED      46
#define LF_SIG        0x04034b50u   /* "PK\003\004" */
#define LF_FIXED      30

#define WANT_ENTRY    "version.properties"

/* 单个条目允许的最大压缩长度。
 * ⚠️ 【安全】上限，不是性能优化：csize 是从文件里读出的 32 位字段，构造的 jar 可声称
 *    某个条目有 4 GB，没有它下面那次 malloc 会被文件牵着走（整机卡住，而非干净失败）。
 * ⚠️ 真值远小于它：version.properties 实测压缩后 127 字节。 */
#define MAX_ENTRY     65536

static uint16_t rd16(const unsigned char *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t rd32(const unsigned char *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8)
         | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

/* 按偏移读，不动文件指针的共享状态；读不满就返回 0。 */
static int read_at(FILE *f, long off, void *buf, size_t n)
{
    if (off < 0) return 0;
    if (fseek(f, off, SEEK_SET) != 0) return 0;
    return fread(buf, 1, n, f) == n;
}

/* 这一层**不解析**，只把 version.properties 的原文交给 ArkTS：显示格式会变，
 * 而改显示不该需要动 C 再重编译一个 .so。
 * ⚠️ 解析那侧有个坑：文件里同时有 `build=` 和 `buildDate=`，
 *    得用「这一行是否以 build= 开头」判断才不会先命中 buildDate —— 见 GameLibrary.ets。 */

/* 在中央目录里找 version.properties，返回（压缩方式, 压缩长度, 本地头偏移）；找到返回 1，否则 0。 */
static int find_entry(FILE *f, long cd_off, long cd_size, long file_size,
                      size_t *method, size_t *csize, long *lho)
{
    unsigned char hdr[CD_FIXED];
    long pos = cd_off;
    long end = cd_off + cd_size;

    if (cd_off <= 0 || cd_size <= 0 || end > file_size) return 0;

    while (pos + CD_FIXED <= end) {
        if (!read_at(f, pos, hdr, CD_FIXED)) return 0;
        if (rd32(hdr) != CD_SIG) return 0;               /* 不该发生；宁可放弃 */

        size_t name_len  = rd16(hdr + 28);
        size_t extra_len = rd16(hdr + 30);
        size_t cmt_len   = rd16(hdr + 32);
        long   next      = pos + CD_FIXED + (long)name_len + (long)extra_len + (long)cmt_len;
        if (next <= pos || next > end) return 0;         /* 防死循环与越界 */

        if (name_len == sizeof(WANT_ENTRY) - 1) {
            char name[sizeof(WANT_ENTRY)];
            if (read_at(f, pos + CD_FIXED, name, name_len)) {
                name[name_len] = '\0';
                if (strcmp(name, WANT_ENTRY) == 0) {
                    *method = rd16(hdr + 10);
                    *csize  = rd32(hdr + 20);
                    *lho    = (long)rd32(hdr + 42);
                    return 1;
                }
            }
        }
        pos = next;
    }
    return 0;
}

/* 返回 1 且把文本写进 out；任何一步不对就返回 0。 */
static int read_entry_text(FILE *f, long file_size, size_t method, size_t csize,
                           long lho, char *out, size_t outsz)
{
    unsigned char lf[LF_FIXED];

    if (lho <= 0 || lho + LF_FIXED > file_size) return 0;
    if (!read_at(f, lho, lf, LF_FIXED)) return 0;
    if (rd32(lf) != LF_SIG) return 0;
    if (csize == 0 || csize > MAX_ENTRY) return 0;

    /* ⚠️ 用【本地头】里的名字/扩展长度，不是中央目录里的：两者可以不一样，
     *    ZIP 规范允许。用错一个，数据起点就偏了。 */
    size_t lname = rd16(lf + 26);
    size_t lext  = rd16(lf + 28);
    long data = lho + LF_FIXED + (long)lname + (long)lext;

    /* ⚠️⚠️ 【必须】分成两个条件写，不能写成 `(size_t)(file_size - data) < csize`：
     *    data 是 long，若大于 file_size，`file_size - data` 是负数，转 size_t 变成极大正数 ⇒
     *    那个看似严格的比较恰好放行最该拦下的情况，紧接着就是一次越界读。 */
    if (data <= 0 || data > file_size) return 0;
    if ((long)csize > file_size - data) return 0;

    unsigned char *raw = (unsigned char *)malloc(csize ? csize : 1);
    if (raw == NULL) return 0;
    if (!read_at(f, data, raw, csize)) { free(raw); return 0; }

    int ok = 0;
    if (method == 0) {
        /* 没压缩：直接就是文本。 */
        size_t n = csize < outsz - 1 ? csize : outsz - 1;
        memcpy(out, raw, n);
        out[n] = '\0';
        ok = (n > 0);
    } else if (method == 8) {
        /* raw deflate —— 负的 windowBits 就是「没有 zlib 头」。 */
        z_stream s;
        memset(&s, 0, sizeof(s));
        if (inflateInit2(&s, -MAX_WBITS) == Z_OK) {
            char *text = (char *)malloc(outsz);
            if (text != NULL) {
                s.next_in  = raw;
                s.avail_in = (uInt)csize;
                s.next_out  = (Bytef *)text;
                s.avail_out = (uInt)outsz - 1;
                int r = inflate(&s, Z_FINISH);
                if (r == Z_STREAM_END || r == Z_OK) {
                    size_t n = ((size_t)outsz - 1) - s.avail_out;
                    text[n] = '\0';
                    memcpy(out, text, n + 1);
                    ok = (n > 0);
                }
                free(text);
            }
            inflateEnd(&s);
        }
    }
    free(raw);
    return ok;
}

/* 入口。path 是 jar 的绝对路径；读不出返回空串。 */
static char *jar_version_text(const char *path)
{
    static char result[1024];
    result[0] = '\0';

    FILE *f = fopen(path, "rb");
    if (f == NULL) return result;

    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return result; }
    long file_size = ftell(f);
    if (file_size < EOCD_MIN) { fclose(f); return result; }

    /* EOCD 在末尾，后面可能跟着最多 65535 字节的注释 —— 从后往前搜签名。 */
    long scan = file_size - EOCD_MIN;
    long scan_from = file_size - EOCD_MIN - MAX_COMMENT;
    if (scan_from < 0) scan_from = 0;
    long eocd = -1;
    for (long p = scan; p >= scan_from; p--) {
        unsigned char sig[4];
        if (!read_at(f, p, sig, 4)) break;
        if (rd32(sig) == EOCD_SIG) { eocd = p; break; }
    }
    if (eocd < 0) { fclose(f); return result; }

    unsigned char e[EOCD_MIN];
    if (!read_at(f, eocd, e, EOCD_MIN)) { fclose(f); return result; }
    long cd_size = (long)rd32(e + 12);
    long cd_off  = (long)rd32(e + 16);
    if (cd_off <= 0 || cd_size <= 0) { fclose(f); return result; }

    size_t method = 0, csize = 0;
    long lho = 0;
    char text[1024];
    if (find_entry(f, cd_off, cd_size, file_size, &method, &csize, &lho)
        && read_entry_text(f, file_size, method, csize, lho, text, sizeof(text))) {
        /* 已经用 '\0' 结尾过；strncpy 会把结尾丢掉，所以逐字节限长拷。 */
        memcpy(result, text, sizeof(result) - 1);
        result[sizeof(result) - 1] = '\0';
    }

    fclose(f);
    return result;
}

static napi_value JarVersionText(napi_env env, napi_callback_info info)
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

    const char *v = jar_version_text(path);
    if (v[0] == '\0') return out;
    napi_create_string_utf8(env, v, NAPI_AUTO_LENGTH, &out);
    return out;
}

static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        { "jarVersionText", NULL, JarVersionText, NULL, NULL, NULL, napi_default, NULL },
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

static napi_module jarver_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = NULL,
    .nm_register_func = Init,
    .nm_modname = "jarver",
    .nm_priv = ((void*)0),
    .reserved = { 0 },
};

void __attribute__((constructor)) RegisterJarVerModule(void)
{
    napi_module_register(&jarver_module);
}
