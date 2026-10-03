/* 存储位置探针：**用 native 的方式**（裸 POSIX）验证一个目录能不能写。
 *
 * ── 它回答的那个问题 ────────────────────────────────────────────────────────
 * 「把游戏数据根从沙箱切到外部存储」这件事，成败取决于**JVM 的 native 代码**能不能在
 * 那个目录里读写 —— 而 **ArkTS 的 fileIo 能写，完全不代表 native 能写**。
 * 这是参考项目 AMCL 用一行注释记下的教训（它的 StorageProbe.ets 文件头）：
 * 鸿蒙 NEXT 上 native 只能 POSIX open() 沙箱路径，公共目录需要授权 + 沙箱映射路径。
 * ⇒ 切之前先探，别切完才发现游戏起不来。
 *
 * ⛔ **返回字符串，不返回布尔。** 布尔会把
 *      「目录不存在」/「没权限」/「写了读不回来」/「能写」**压成同一个 false**，
 *      而它们是**四种不同的处境**，处置完全不同。
 *    本项目已有同款判据（`shield.c` 的文件头）：**门从来不触发，和门查了但没查到，
 *    长得一模一样。**
 *
 * ⛔ **探针要能在外部根上真的写一个文件再删掉。** 只 stat 一下不算 —— 那只证明
 *    「看得见」，而我们要的是「JVM 能在那里建 settings.bin 和存档」。
 *
 * ⚠️ 探针失败时可能**留下一个空文件**（unlink 也失败的情况）⇒ 那种情况单独报出来，
 *    不要静默吞掉：一个留在玩家下载目录里的垃圾文件，比一条错误信息糟。
 */
#include <node_api.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>

/* 沙箱前缀。⛔ 只用来**判定「这不是外部」**，不用来拼任何路径。
 * 理由：如果外部根被解析成了沙箱里的某个目录，那这个功能就是自欺欺人 ——
 * 玩家在文件管理器里看不到任何东西，而界面上写着「已切到外部存储」。 */
#define SANDBOX_PREFIX "/data/storage/el2/base/files"

/* 探针文件名带 pid：多个进程（主进程 / 游戏进程）同时探不会互相踩。 */
static void probe_name(char *out, size_t outlen, const char *dir)
{
    snprintf(out, outlen, "%s/.write_probe_%d", dir, (int)getpid());
}

/** 真的写一个文件、读回来比对、再删掉。 */
static napi_value ProbeWritable(napi_env env, napi_callback_info info)
{
    char text[320];
    char *dir = NULL;
    size_t dir_len = 0;

    size_t argc = 1;
    napi_value argv[1] = { NULL };
    if (napi_get_cb_info(env, info, &argc, argv, NULL, NULL) != napi_ok || argc != 1) {
        snprintf(text, sizeof(text), "bad-args");
        goto done;
    }
    if (napi_get_value_string_utf8(env, argv[0], NULL, 0, &dir_len) != napi_ok) {
        snprintf(text, sizeof(text), "bad-args: not a string");
        goto done;
    }
    if (dir_len == 0 || dir_len > 1024) {
        snprintf(text, sizeof(text), "bad-args: len=%d", (int)dir_len);
        goto done;
    }
    /* +1 给结尾的 NUL；napi 的长度不含它。 */
    char dirbuf[1025];
    napi_get_value_string_utf8(env, argv[0], dirbuf, sizeof(dirbuf), &dir_len);
    dir = dirbuf;

    /* ① 它必须真的是外部 —— 否则这个功能在骗人。 */
    if (strncmp(dir, SANDBOX_PREFIX, sizeof(SANDBOX_PREFIX) - 1) == 0) {
        snprintf(text, sizeof(text), "inside-sandbox: %s", dir);
        goto done;
    }

    /* ② 目录必须在。用 stat 而不是「打开试试」—— 好把「不存在」和「没权限」分开。 */
    struct stat st;
    if (stat(dir, &st) != 0) {
        snprintf(text, sizeof(text), "no-dir: errno=%d (%s)", errno, strerror(errno));
        goto done;
    }
    if (!S_ISDIR(st.st_mode)) {
        snprintf(text, sizeof(text), "not-a-dir");
        goto done;
    }

    /* ③ 真的建一个文件。 */
    char probe[1200];
    probe_name(probe, sizeof(probe), dir);
    int fd = open(probe, O_CREAT | O_RDWR | O_TRUNC, 0600);
    if (fd < 0) {
        snprintf(text, sizeof(text), "open: errno=%d (%s)", errno, strerror(errno));
        goto done;
    }

    /* ④ 写进去。内容固定，便于读回来比对。 */
    static const char payload[] = "mindustryark storage probe\n";
    const ssize_t want = (ssize_t)(sizeof(payload) - 1);
    const ssize_t wrote = write(fd, payload, (size_t)want);
    if (wrote != want) {
        const int e = errno;
        close(fd);
        unlink(probe);           /* 尽量收干净；失败了也不改结论，下面照样报 write 失败 */
        snprintf(text, sizeof(text), "write: errno=%d (%s) wrote=%d want=%d",
                 e, strerror(e), (int)wrote, (int)want);
        goto done;
    }
    /* ⚠️ fsync：只写进页缓存不算「JVM 能持久化」，而游戏是要落盘的。 */
    if (fsync(fd) != 0) {
        const int e = errno;
        close(fd);
        unlink(probe);
        snprintf(text, sizeof(text), "fsync: errno=%d (%s)", e, strerror(e));
        goto done;
    }

    /* ⑤ 读回来比对 —— 一个只读的挂载点能通过写、通不过这一步。 */
    if (lseek(fd, 0, SEEK_SET) < 0) {
        const int e = errno;
        close(fd);
        unlink(probe);
        snprintf(text, sizeof(text), "seek: errno=%d (%s)", e, strerror(e));
        goto done;
    }
    char back[64];
    memset(back, 0, sizeof(back));
    const ssize_t got = read(fd, back, sizeof(back) - 1);
    close(fd);

    if (got != want || memcmp(back, payload, (size_t)want) != 0) {
        unlink(probe);
        snprintf(text, sizeof(text), "readback: got=%d want=%d", (int)got, (int)want);
        goto done;
    }

    /* ⑥ 收尾。⚠️ 这一步失败要单独说 —— 见文件头「可能留下一个空文件」。 */
    if (unlink(probe) != 0) {
        const int e = errno;
        snprintf(text, sizeof(text), "left-behind: %s (unlink errno=%d %s)",
                 probe, e, strerror(e));
        goto done;
    }

    snprintf(text, sizeof(text), "ok: %s", dir);

done:
    {
        napi_value result;
        napi_create_string_utf8(env, text, NAPI_AUTO_LENGTH, &result);
        return result;
    }
}

static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        { "probeWritable", NULL, ProbeWritable, NULL, NULL, NULL, napi_default, NULL },
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

static napi_module storprobe_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = NULL,
    .nm_register_func = Init,
    .nm_modname = "storprobe",
    .nm_priv = ((void*)0),
    .reserved = { 0 },
};

void __attribute__((constructor)) RegisterStorProbeModule(void)
{
    napi_module_register(&storprobe_module);
}
