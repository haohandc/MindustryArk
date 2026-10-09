/* 存储位置探针：用 native（裸 POSIX）验证目录能不能写。
 * 平台限制：ArkTS 的 fileIo 能写，不代表 native 能写 —— 鸿蒙 NEXT 上 native 只能 POSIX open()
 * 沙箱路径，公共目录需要授权 + 沙箱映射（AMCL 的 StorageProbe.ets 记过这条）。
 * ⇒ 切存储根之前先探，别切完才发现游戏起不来。
 * ⛔ 返回字符串不返回布尔：布尔会把「目录不存在」/「没权限」/「写了读不回来」/「能写」压成同一个
 * false，而它们是四种处境。同款判据见 shield.c 文件头（门不触发与门没查到长得一样）。
 * ⛔ 必须真的建文件、写、读回、删 —— 只 stat 证明不了「JVM 能建 settings.bin」。
 * ⚠️ 探针失败可能留下一个空文件（unlink 也失败）⇒ 那种情况单独报出来，不要静默吞掉。 */
#include <node_api.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <dirent.h>
#include <stdlib.h>

/* 沙箱前缀。⛔ 只用来判定「这不是外部」，不拼任何路径：外部根若落在沙箱里，
 * 这个功能就是自欺欺人（玩家看不见，界面却写「已切到外部存储」）。 */
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

/* =====================================================================
 * 递归复制一棵树 —— 搬「存储位置」用的迁移，故意放在 native 里
 *
 * ⛔ 为什么不用 ArkTS 的 fileIo.copyFileSync（项目里已有 FsTree.copyTreeInto）：2026-10-04 实测往
 *   同一个外部文件夹拷同一个文件，copyFileSync → EPERM（126 个文件全废），native 裸 POSIX → 成功；
 *   那个差异解释不了 ⇒ 迁移由 native 做，不依赖对它的解释（判据：走被证明的那条路）。
 * ⚠️ 只搬文件与目录；符号链接等特殊类型跳过（计入 skipped）：跟随链接会让 a→.. 的环钉死递归。
 * ⚠️ 目标已存在的文件被覆盖（O_TRUNC）：迁移是一次性搬家，不是合并。
 * ===================================================================== */

#define COPY_PATH_MAX 1024
#define COPY_MAX_DEPTH 32

/* mkdir -p（`mkdir` 本身不建父目录）。EEXIST 不算错。 */
static int mkdirs_all(const char *path)
{
    char buf[COPY_PATH_MAX];
    size_t n = strlen(path);
    if (n == 0 || n >= sizeof(buf)) {
        errno = ENAMETOOLONG;
        return -1;
    }
    memcpy(buf, path, n + 1);
    for (char *p = buf + 1; *p; p++) {
        if (*p != '/') {
            continue;
        }
        *p = 0;
        if (mkdir(buf, 0755) != 0 && errno != EEXIST) {
            return -1;
        }
        *p = '/';
    }
    if (mkdir(buf, 0755) != 0 && errno != EEXIST) {
        return -1;
    }
    return 0;
}

/* 复制一个普通文件。返回 0 成功；-1 失败（errno 有效）。 */
static int copy_one_file(const char *s, const char *d)
{
    int in = open(s, O_RDONLY);
    if (in < 0) {
        return -1;
    }
    int out = open(d, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (out < 0) {
        const int saved = errno;
        close(in);
        errno = saved;
        return -1;
    }
    /* 64 KB 一读：这些文件最大也就几 MB（存档），够用且不占栈。 */
    char buf[65536];
    int rc = 0;
    for (;;) {
        ssize_t r = read(in, buf, sizeof(buf));
        if (r == 0) {
            break;
        }
        if (r < 0) {
            rc = -1;
            break;
        }
        ssize_t off = 0;
        while (off < r) {
            ssize_t w = write(out, buf + off, (size_t) (r - off));
            if (w <= 0) {
                rc = -1;
                break;
            }
            off += w;
        }
        if (rc != 0) {
            break;
        }
    }
    const int saved = errno;
    close(out);
    close(in);
    errno = saved;
    return rc;
}

/* 计数与第一条错误（带路径 —— 只报 errno 会把排查的第一步推给下一个人，
 * 而项目里已经因为「日志不写路径」返工过）。 */
typedef struct {
    int files;
    int dirs;
    int failed;
    int skipped;
    char first[512];
} CopyAcc;

static void note_fail(CopyAcc *acc, const char *what, const char *s, const char *d, int e)
{
    acc->failed++;
    if (acc->first[0] == 0) {
        snprintf(acc->first, sizeof(acc->first), "%s %s -> %s: errno=%d %s",
                 what, s, d, e, strerror(e));
    }
}

static void copy_tree(const char *s, const char *d, int depth, CopyAcc *acc)
{
    if (depth > COPY_MAX_DEPTH) {
        note_fail(acc, "too-deep", s, d, ELOOP);
        return;
    }
    if (mkdirs_all(d) != 0) {
        note_fail(acc, "mkdir", s, d, errno);
        return;
    }
    acc->dirs++;

    DIR *dir = opendir(s);
    if (dir == NULL) {
        note_fail(acc, "opendir", s, d, errno);
        return;
    }
    struct dirent *e;
    while ((e = readdir(dir)) != NULL) {
        if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) {
            continue;
        }
        char sp[COPY_PATH_MAX];
        char dp[COPY_PATH_MAX];
        if (snprintf(sp, sizeof(sp), "%s/%s", s, e->d_name) >= (int) sizeof(sp) ||
            snprintf(dp, sizeof(dp), "%s/%s", d, e->d_name) >= (int) sizeof(dp)) {
            note_fail(acc, "path-too-long", s, d, ENAMETOOLONG);
            continue;
        }
        /* ⛔⛔ 必须用 lstat，不能用 stat（跟随链接）：否则下面「符号链接跳过」是假的 ——
         *    指向目录的软链会走进 S_ISDIR 被递归复制，a→.. 的环会让同一棵树重复复制最多 32 次
         *    （靠 COPY_MAX_DEPTH 兜住，不死循环），搬存储位置时可能把目标盘写满。
         * ⭐ lstat 下软链自己落进 else 那支，与注释声称的行为一致（2026-10-05 审查发现）。 */
        struct stat st;
        if (lstat(sp, &st) != 0) {
            note_fail(acc, "lstat", sp, dp, errno);
            continue;
        }
        if (S_ISDIR(st.st_mode)) {
            copy_tree(sp, dp, depth + 1, acc);
        } else if (S_ISREG(st.st_mode)) {
            if (copy_one_file(sp, dp) != 0) {
                note_fail(acc, "copy", sp, dp, errno);
            } else {
                acc->files++;
            }
        } else {
            /* ⚠️ 符号链接 / 设备节点等：**跳过**。跟随链接会让 a→.. 把递归钉死。 */
            acc->skipped++;
        }
    }
    closedir(dir);
}

/** `copyTree(src, dst)` → 结果字符串。
 *  成功：`ok: N files, M dirs[, K skipped]`
 *  失败：`fail <N>: <第一条错误，带源与目标路径>`（**前几条**在同一条里，够定位）
 *  ⛔ 返回字符串不是布尔，同 `probeWritable`：不同失败指向不同处置。 */
static napi_value CopyTree(napi_env env, napi_callback_info info)
{
    char text[1200];
    char sbuf[COPY_PATH_MAX];
    char dbuf[COPY_PATH_MAX];
    size_t slen = 0;
    size_t dlen = 0;

    size_t argc = 2;
    napi_value argv[2] = { NULL, NULL };
    if (napi_get_cb_info(env, info, &argc, argv, NULL, NULL) != napi_ok || argc != 2) {
        snprintf(text, sizeof(text), "bad-args: want (src, dst)");
        goto done;
    }
    if (napi_get_value_string_utf8(env, argv[0], sbuf, sizeof(sbuf), &slen) != napi_ok ||
        napi_get_value_string_utf8(env, argv[1], dbuf, sizeof(dbuf), &dlen) != napi_ok) {
        snprintf(text, sizeof(text), "bad-args: not strings");
        goto done;
    }
    if (slen == 0 || dlen == 0) {
        snprintf(text, sizeof(text), "bad-args: empty path");
        goto done;
    }

    CopyAcc acc;
    memset(&acc, 0, sizeof(acc));
    copy_tree(sbuf, dbuf, 0, &acc);

    if (acc.failed > 0) {
        snprintf(text, sizeof(text), "fail %d: %s", acc.failed, acc.first);
    } else {
        snprintf(text, sizeof(text), "ok: %d files, %d dirs%s",
                 acc.files, acc.dirs, acc.skipped > 0 ? " (some skipped)" : "");
    }

done:
    {
        napi_value result;
        napi_create_string_utf8(env, text, NAPI_AUTO_LENGTH, &result);
        return result;
    }
}

/* ====================================================================
 * 列一棵树（诊断用）
 * ====================================================================
 * ⛔ 为什么必须 native 做：外置文件夹 ArkTS 侧读不一定行（同一条路上 fileIo 报 EPERM、
 *    native 成功），而 hdc shell 连 /storage/Users 都看不见（实测 ls /storage 只有 cloud
 *    media）⇒ 外置那棵树在排查里不存在（2026-10-04 为这盲区付过几轮）。
 * ⭐ 输出每个文件的大小：拿它对比沙箱里同一份的字节数，「复制把文件截短了吗」从推测变成数。 */

#define LIST_NAME_MAX    256
#define LIST_MAX_ENTRIES 512
#define LIST_MAX_LINES   400
#define LIST_BUF_MAX     65536

typedef struct {
    char *buf;
    size_t used;
    size_t cap;
    int lines;
    int maxlines;
    int truncated;
} ListAcc;

/* 追加一行：`<相对路径><后缀>`。后缀由调用点拼（`/` 表示目录、` 1234` 表示文件大小）。 */
static void list_emit(ListAcc *a, const char *rel, const char *suffix)
{
    if (a->lines >= a->maxlines) {
        a->truncated = 1;
        return;
    }
    const int room = (int) (a->cap - a->used);
    if (room < 64) {
        a->truncated = 1;
        return;
    }
    const int n = snprintf(a->buf + a->used, (size_t) room, "%s%s\n", rel, suffix);
    if (n > 0) {
        a->used += (size_t) n;
        a->lines++;
    }
}

static int list_cmp(const void *x, const void *y)
{
    return strcmp((const char *) x, (const char *) y);
}

/* 印出 `dir` 之下 `maxdepth` 层，路径相对于 `base`（那样输出短、可比）。 */
static void list_walk(const char *base, const char *dir, int depth, int maxdepth, ListAcc *a)
{
    char sfx[80];
    if (a->truncated || depth > maxdepth) {
        return;
    }
    DIR *d = opendir(dir);
    if (d == NULL) {
        const int e = errno;
        snprintf(sfx, sizeof(sfx), "/ <opendir-errno=%d>", e);
        list_emit(a, dir + strlen(base), sfx);
        return;
    }
    /* ⛔ **先收名字、排序再印。** readdir 的顺序不保证，而不排序时两次运行的输出
     *    无法逐行对比 —— 而「逐行对比」正是这个函数存在的理由。 */
    char *names = (char *) malloc((size_t) LIST_NAME_MAX * (size_t) LIST_MAX_ENTRIES);
    if (names == NULL) {
        closedir(d);
        return;
    }
    int cnt = 0;
    struct dirent *e;
    while ((e = readdir(d)) != NULL && cnt < LIST_MAX_ENTRIES) {
        if (e->d_name[0] == '.' && (e->d_name[1] == 0 ||
            (e->d_name[1] == '.' && e->d_name[2] == 0))) {
            continue;
        }
        snprintf(names + (size_t) LIST_NAME_MAX * (size_t) cnt, LIST_NAME_MAX, "%s", e->d_name);
        cnt++;
    }
    closedir(d);

    qsort(names, (size_t) cnt, (size_t) LIST_NAME_MAX, list_cmp);
    for (int i = 0; i < cnt && !a->truncated; i++) {
        char p[COPY_PATH_MAX];
        if (snprintf(p, sizeof(p), "%s/%s", dir,
                     names + (size_t) LIST_NAME_MAX * (size_t) i) >= (int) sizeof(p)) {
            continue;
        }
        struct stat st;
        /* ⛔ lstat，与 copy_tree 一致：用 stat 会跟随软链、让指向目录的软链递归进去，既与
         *    「跳过软链」不符，也让清单莫名膨胀。⚠️ 这处是 2026-10-05 审查查出我自己造成的不一致
         *    （当时只在 copy_tree 改了 lstat，却在 pathExists 注释里声称两边一致）。 */
        if (lstat(p, &st) != 0) {
            const int e = errno;
            snprintf(sfx, sizeof(sfx), " <lstat-errno=%d>", e);
            list_emit(a, p + strlen(base), sfx);
            continue;
        }
        if (S_ISDIR(st.st_mode)) {
            list_emit(a, p + strlen(base), "/");
            list_walk(base, p, depth + 1, maxdepth, a);
        } else if (S_ISREG(st.st_mode)) {
            snprintf(sfx, sizeof(sfx), " %lld", (long long) st.st_size);
            list_emit(a, p + strlen(base), sfx);
        } else {
            list_emit(a, p + strlen(base), " <not-regular>");
        }
    }
    free(names);
}

/** `listTree(dir[, maxDepth])` → 一棵树的清单。
 *  缺失：`absent: errno=N <strerror>`｜不是目录：`not-a-dir`｜其余为若干行。
 *  ⚠️ 截断时会**显式写出** `...(truncated)` —— 本项目为「测量工具自己截断、看起来像
 *     结果就是这么多」付过代价（见教训 #93），所以这里不静默。 */
static napi_value ListTree(napi_env env, napi_callback_info info)
{
    char dirbuf[COPY_PATH_MAX];
    char *out = (char *) malloc(LIST_BUF_MAX);
    size_t dlen = 0;
    int maxdepth = 2;

    if (out == NULL) {
        napi_value r;
        napi_create_string_utf8(env, "fail: out of memory", NAPI_AUTO_LENGTH, &r);
        return r;
    }

    size_t argc = 2;
    napi_value argv[2] = { NULL, NULL };
    if (napi_get_cb_info(env, info, &argc, argv, NULL, NULL) != napi_ok || argc < 1 ||
        napi_get_value_string_utf8(env, argv[0], dirbuf, sizeof(dirbuf), &dlen) != napi_ok ||
        dlen == 0) {
        snprintf(out, LIST_BUF_MAX, "bad-args: want (dir[, maxDepth])");
        goto ret;
    }
    if (argc >= 2) {
        int32_t d = 0;
        if (napi_get_value_int32(env, argv[1], &d) == napi_ok && d >= 0 && d <= 8) {
            maxdepth = (int) d;
        }
    }

    struct stat st;
    if (stat(dirbuf, &st) != 0) {
        snprintf(out, LIST_BUF_MAX, "absent: errno=%d %s", errno, strerror(errno));
        goto ret;
    }
    if (!S_ISDIR(st.st_mode)) {
        snprintf(out, LIST_BUF_MAX, "not-a-dir");
        goto ret;
    }

    ListAcc a;
    memset(&a, 0, sizeof(a));
    a.buf = out;
    a.cap = LIST_BUF_MAX;
    a.maxlines = LIST_MAX_LINES;
    list_walk(dirbuf, dirbuf, 0, maxdepth, &a);
    if (a.truncated) {
        list_emit(&a, "", "...(truncated)");
    }

ret:
    {
        napi_value result;
        napi_create_string_utf8(env, out, NAPI_AUTO_LENGTH, &result);
        free(out);
        return result;
    }
}

/** `pathExists(p)` → 1 / 0。
 *  ⭐ 单独有它：调用方在渲染期每个粒度键问一次，只需一次 stat，而非 listTree 的整树遍历。
 *  ⚠️ 用 lstat（软链含断链都算存在），与 copyTree 一致。
 *  ⛔ 与 ArkTS 的 fs.accessSync 不是重复品：那个在外部根上实测会误报。 */
static napi_value PathExists(napi_env env, napi_callback_info info)
{
    char buf[COPY_PATH_MAX];
    size_t len = 0;
    int32_t r = 0;

    size_t argc = 1;
    napi_value argv[1] = { NULL };
    /* ⛔⛔ 两段式取长（同 ProbeWritable）：单段式返回的是已拷入字节数而非真实长度 ⇒ 超长路径
     *    被静默截断，若前缀存在就会对不存在的路径返回「存在」。⭐ 2026-10-05 审查查出（本文件
     *    里 ProbeWritable 本就是正确示范，copyTree 曾经不是）。 */
    size_t need = 0;
    if (napi_get_cb_info(env, info, &argc, argv, NULL, NULL) == napi_ok && argc >= 1
        && napi_get_value_string_utf8(env, argv[0], NULL, 0, &need) == napi_ok
        && need > 0 && need < sizeof(buf)
        && napi_get_value_string_utf8(env, argv[0], buf, sizeof(buf), &len) == napi_ok) {
        struct stat st;
        r = (lstat(buf, &st) == 0) ? 1 : 0;
    }
    /* 走到这里而 `r == 0` 的三种情形（空参 / 路径超长 / 真的不存在）在**调用方**眼里
     * 是同一件事：「别把这个路径当成有东西」—— 而调用方 `gameDataExists` 对「问不到」
     * 另有保守分支（当作存在）。⛔ 所以这里不细分，但**不细分的前提是长度已经挡住了**。 */

    napi_value result;
    napi_create_int32(env, r, &result);
    return result;
}

static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        { "probeWritable", NULL, ProbeWritable, NULL, NULL, NULL, napi_default, NULL },
        { "copyTree", NULL, CopyTree, NULL, NULL, NULL, napi_default, NULL },
        { "listTree", NULL, ListTree, NULL, NULL, NULL, napi_default, NULL },
        { "pathExists", NULL, PathExists, NULL, NULL, NULL, napi_default, NULL },
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
