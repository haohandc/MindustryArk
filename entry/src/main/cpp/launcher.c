/*
 * HarmonyOS 版 Mindustry 启动器 —— 先启一个真正的 JVM，再交给 Java。
 * 计划里被称作「最大的未知数」的那一步：在 SDL 创建出来的线程（而非进程主线程）里创建 JVM。
 *
 * JDK 以普通目录放在 entry/libs/arm64-v8a/jdk21/，由 HAP 安装器解包进可执行库区（无运行时
 * 解压、无首次启动开销）：只有 HAP 的 lib 区可执行，可写沙箱 el2 不行。真正的 libjvm 嵌套
 * 三层，正是 HotSpot 剥掉三层分量推导出正确 java.home 的原因；完整链路见 prep_vendor.py。
 */
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include <hilog/log.h>

#include "jni/jni.h"

#include <dirent.h>
#include <fcntl.h>
#include <pthread.h>
#include <sys/mman.h>
#include <signal.h>
#include <dlfcn.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
/* ⛔ 这一行别删：`setenv` 只在 <stdlib.h> 里声明，而本文件没有别的地方会带进它。
 *    删掉**不会**编译失败 —— 它会走 C99 已不允许的隐式声明，只报一条 -Wimplicit-function-declaration。
 *    同类的还有 `pthread_getname_np`，那个的修法在 CMakeLists.txt 的 `_GNU_SOURCE` 那段。 */
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <ucontext.h>
#include <sys/types.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>

/* JDK 住在 HAP 原生库区（整件事的关键）：只有 HAP 的 lib 区可执行，可写沙箱不行，即使持有
 * ALLOW_WRITABLE_CODE_MEMORY（2026-09-22：一台 API 24 设备跑 release 签名的商店包时
 * mmap(RWX) 被 errno=22 拒绝，该权限只覆盖匿名可执行内存，见 RELEASE-MAINTENANCE.md 2.11）。
 * HotSpot 从 libjvm.so 位置剥三层分量推 java.home（要 <java.home>/lib/modules；-Djava.home
 * 被无条件覆盖），所以 JDK 递归分发在 entry/libs/arm64-v8a/jdk21/，落点即 <java.home>。 */
#define JDK_HOME    "/data/storage/el1/bundle/libs/arm64/jdk21"
#define JDK_LIB     JDK_HOME "/lib"
/* 真正的 JVM，嵌套在 <java.home>/lib/server/ 下，好让 HotSpot 推导出正确 java.home。
 * SONAME 已清空、不在 loader 搜索路径上 —— 只能经依赖它的 anchor（JDK_ANCHOR）触达。 */
#define JDK_LIBM        JDK_LIB "/server/libjvm_real.so"

/* 一个除此之外空无一物的 libjvm.so，放在搜索路径上（见 libjvm_anchor.c）：唯一的目的是让
 * 其它 JDK 库的裸名 DT_NEEDED 得以解析，并经它的依赖链把真正的 JVM 拉进来。 */
#define JDK_ANCHOR  BUNDLE_LIBS "/libjvm.so"
#define BUNDLE_LIBS "/data/storage/el1/bundle/libs/arm64"

/* 游戏本体，以「名字看起来像共享库」的 jar 形式交付。hvigor 把 entry/libs/arm64-v8a/** 拷进
 * HAP 只有一个条件：文件名以 ".so" 结尾，内容不检查（实测 140,523,131 字节的 module image
 * 以 jimg.so 分发、25,322,128 字节的 JVM 以 libjvm_real.so 分发，都逐字节一致，而 jdk21/conf/
 * 下不以 .so 结尾的名字被无声丢弃）。JVM 按内容而非扩展名打开 classpath 条目。
 * 放在子目录里（与 module image 同级），免得被平台当作原生库对待。 */
#define GAME_JAR    BUNDLE_LIBS "/game/mindustry.so"

/* 我们的 Arc 修改，独立 jar，排在 classpath 的【最前】。JVM 按 classpath 顺序解析类、先命中
 * 者赢：这个条目排在游戏 jar 前面，里面的 26 个类因此压过游戏 jar 里的同名类。⚠️ 顺序【承重】——
 * 挪到后面补丁就完全不起作用，且不报任何错。2026-09-28 起游戏 jar 是上游原版、一字节不改。
 * 实测：设备上 Log 替身生效（NoSuchFieldError）、音频正常、同一 jar 驱动 160.4 与 160.5。 */
#define PATCH_JAR   BUNDLE_LIBS "/patchjar/arcpatch.so"

/* LWJGL 分两半，因为两个不同的原因去了两个地方（见 prep_lwjgl.py）：游戏 jar 不含 LWJGL，而
 * Arc 的 SDL3 后端要经 org.lwjgl.opengl.* 与 sdl.* 调平台。LWJGL_LIBS 是真 ELF（dyncall 分发与
 * GL 绑定），必须在可执行区；LWJGL_JARS 不是 ELF，改 .so 只为过 hvigor 的过滤。
 * ⛔ 这里【不放】libSDL3.so：一个进程两份独立 SDL3 映射会有两个事件队列（窗口建在一份、surface
 * 回调投给另一份），本项目栽过 —— loader 只指向本项目自建的那份。 */
#define LWJGL_LIBS  BUNDLE_LIBS "/lwjgl"
#define LWJGL_JARS  BUNDLE_LIBS "/lwjgl-java"

/* Arc 自己的 natives，在这里分发只为让它们能被加载。Arc 会把它们从 jar 解到 java.io.tmpdir
 * 再对副本 System.load，而副本无法 dlopen（可写区不可执行，只有 bundle 可执行）；两库×六候选
 * 目录外加 bundle 对照已实测，见 probe_sandbox_exec()。故改为启动前从这里加载并告诉 Arc 已
 * 加载：setLoaded(String) 是 public static，load() 对已标记名字立即返回 —— loader 自己的契约。 */
#define ARC_LIBS    BUNDLE_LIBS "/arc"

/* 我们自己的类，唯一目的是让 System.load 从 Java 里被调用。System.load 是 @CallerSensitive
 * 的：它把库注册到调用者的类加载器上；经 JNI 调用没有调用者栈帧，库落在 bootstrap loader 上，
 * 游戏的类看不见它的符号 —— 加载了却仍然不可用。见 NativeLoader.java。 */
#define HELPER_JAR  BUNDLE_LIBS "/launcher/helper.so"

/* java.home 必须在第一次 module-image 查找之前指向这里。镜像有两个名字：jimg.so 是 hvigor 过滤
 * 的产物（patch_libjvm.py），java.base 却硬拼 "<java.home>/lib/modules"（惰性初始化、只读一次的
 * static final）⇒ 要在 VM 起来后立刻从 Java 侧重写 java.home（-Djava.home 被 HotSpot 覆盖）。
 * 目标目录必须含真实 "modules"：首次启动拷 140 MB 镜像进沙箱（符号链接 EACCES、硬链接也不行），只做一次，先写临时名再 rename。 */
#define SANDBOX_JDK     DEST_ROOT "/jdk"
#define SANDBOX_MODULES SANDBOX_JDK "/lib/modules"
#define SANDBOX_TZDB    SANDBOX_JDK "/lib/tzdb.dat"
#define MODULE_IMAGE    BUNDLE_LIBS "/jdk21/lib/jimg.so"
#define TZDB_IMAGE      BUNDLE_LIBS "/jdk21/lib/tzdb.so"

/* <java.home> 还必须包含的其余东西，以整棵树分发（scripts/prep_jdkconf.py）。
 * conf/security/java.security 由 Security 的静态初始化器读取，而每次 defineClass() 都需要
 * ProtectionDomain → 需要 Security —— 少了那一个文件，运行时任何机制都无法加载任何类。
 * 用树而不是文件名清单：后者在对的时候完全正确，直到它不对 —— 已经两次（这次、lib/tzdb.dat）。 */
#define JDK_HOME_TREE   BUNDLE_LIBS "/jdkhome"

/* 可写位置，tmpdir 和捕获的 stdio 仍然需要 */
#define DEST_ROOT   "/data/storage/el2/base/files"
#define TMP_DIR     "/data/storage/el2/base/temp"

/* 告诉 ArkTS「游戏结束了，关掉 ability」。两边对路径常量并不一致：native 写在 DEST_ROOT
 * (/data/storage/el2/base/files) 下，而 ArkTS 的 context.filesDir 是模块作用域的
 * /data/storage/el2/base/haps/entry/files，所以标记写两处、ArkTS 也检查两处。
 * 非存在不可：直接杀进程会让系统把这次退出归档成 "Cpp Crash"（native 进程在 ability 仍活着时
 * 死掉）；先终止 ability、让框架把进程带下去，才是正常结束的唯一办法 —— 而 native 没有那个 API。 */
#define EXIT_MARKER_SANDBOX DEST_ROOT "/native_exit"
#define EXIT_MARKER_MODULE  "/data/storage/el2/base/haps/entry/files/native_exit"

/* 在 JVM 被创建之前写下，在它存在之后删除。JNI_CreateJavaVM 拿不到它需要的东西时，进程会当场
 * 停死、什么都不留下 —— 没有日志行、没有 faultlog、没有返回码（2026-09-22 商店签名包实测，
 * 唯一一种完全不留证据的失败）。能活到【下一次】启动的标记，是页面得知它发生过的唯一办法。
 * ⛔ 它不是对本次启动的判决：残留绝不能拦住一次本可以成功的运行。 */
#define JVM_INCOMPLETE_MARKER DEST_ROOT "/jvm_incomplete"

/* 探测这个应用到底能不能【读】平台称为用户可见的那些目录 —— 玩家往里丢存档文件的地方。路径
 * 不是猜的：ArkTS 问平台（getUserDownloadDir / getUserDocumentDir）后写进 USER_DIRS_FILE，但
 * 只有 native 能用与游戏相同的 libc 测可读性 ——「API 返回了路径」说明不了 open() 能否成功。
 * 这很重要：游戏的「导入存档」浏览器以从 user.home 推导的外部存储路径为根，而 user.home 是沙箱。 */
#define USER_DIRS_FILE "/data/storage/el2/base/haps/entry/files/user_dirs.txt"

/* ArkTS 在切到游戏树【之前】写下它，本文件在【找到游戏的入口方法之后】删掉。
 * ⭐ 不变量：**标记还在 ⟺ 从来没有走到游戏入口**。于是它覆盖两类旧标记都看不见的失败：JVM 根本
 * 没建起来；以及 JVM 建起来了但那个 jar 里【没有游戏】（玩家把 mod 当游戏选了，2026-10-01 实际
 * 遇到）—— 后者 FindClass 找不到主类是干净 return、不写 crash.txt。⛔ 删除点必须在拿到 main 之后。 */
#define LAUNCH_PENDING_FILE "/data/storage/el2/base/haps/entry/files/launch_pending"

/* ⭐⭐ 版本隔离的拨杆 —— 整个功能的心脏就这一个文件。玩家选「按版本隔离」后 ArkTS 把结果写
 * 在这里，native 启动时读它并据此算出 -Duser.home=；⛔ 游戏不知道这件事，它只看到一个 user.home。
 * 格式与 user_dirs.txt 同为 key=value：enabled / key（由 ArkTS 算，见 gameVersionOf）/
 * granularity（native 不用，只留痕）。⛔ 文件不在 ⇒ enabled=0 ⇒ 用 DEST_ROOT ⇒【与今天逐字节相同】。 */
#define ISOLATION_FILE "/data/storage/el2/base/haps/entry/files/isolation.txt"

/* 隔离根的那一层子目录。⛔ 在数据根之下、但在游戏那棵树【之外】：游戏的数据目录是 user.home
 * 拼上 ARC 强加的 ".local/share/Mindustry"，所以 instances/ 永远不会被游戏当成数据看。布局：
 *     <数据根>/instances/<粒度键>/sets/default/  ← -Duser.home 指到这里；游戏建的是 …/.local/share/Mindustry/
 * ⚠️ A 阶段 sets 恒为 default（界面看不见）；现在就铺这层，是为以后加「集合」时不必搬玩家数据。
 * ⛔ ISOLATION_SUBDIR / ISOLATION_SET 的字面必须与 ArkTS 侧逐字一致，改一处不会报错、只会落错地方。
 *
 * ⛔⛔ **这里曾经是一个编译期常量 `ISOLATION_ROOT = DEST_ROOT "/instances"`，2026-10-04 拆掉了。**
 *    存储根可以在运行期切到外置，而只要这个前缀还钉在 DEST_ROOT 上，就会出现：
 *      隔离开 + 外置 ⇒ launcher 在【沙箱】里 mkdir、把 user.home 指向【沙箱】那棵树，
 *      而 `record_user_home()` 照样写 `reason=on` ⇒ **界面上显示「外置、正常」，游戏却写在沙箱**。
 *    ⇒ 根改成运行期决定（`resolve_user_home` 里那个 `base`），这里只留那一段**相对**后缀。
 *    ⭐ 拆掉常量而不是「让调用点记得用 base」，是为了让**错误写法根本写不出来** ——
 *      留下那个宏，任何人（包括以后的我）都可能顺手再用它一次，而那一次是无声的。 */
#define ISOLATION_SUBDIR "/instances"
#define ISOLATION_SET    "sets/default"

/* read_kv 的定义在下面（与 read_user_dir 同处，共用解析规则）。这里先声明是因为
 * resolve_user_home() 要用它 —— ⚠️ 少了这一行会造出【非 static】的隐式声明，后面那个
 * `static int read_kv` 就变成「static 跟在非 static 之后」而编译失败。 */
static int read_kv(const char *path, const char *key, char *out, size_t outlen);

/*
 * 算出这次启动该用哪个 user.home，写进 out，并把结论记进 USERHOME_RECORD_FILE。
 * ⭐ 三条不变量：1) 隔离关着 ⇒ 结果【逐字节等于 DEST_ROOT】；2) 目录必须真的存在（不存在就 mkdir）；
 * 3) 任何一步失败 ⇒ 回退 DEST_ROOT 并说明原因（宁可回到不隔离，也不要起不来）。
 * ⚠️ 另写文件是为排障第一问「上次启动用的哪个数据目录」：稳定的两行，hdc 直接读走（订正 2026-10-02：它在 redirect_io() 【之后】跑）。 */
#define USERHOME_RECORD_FILE DEST_ROOT "/userhome_used.txt"

/** 把结论写进记录文件。失败静默放过 —— 记录不下来不该拦住启动。 */
static void record_user_home(const char *reason, const char *home)
{
    FILE *f = fopen(USERHOME_RECORD_FILE, "w");
    if (!f) {
        return;
    }
    fprintf(f, "reason=%s\nhome=%s\n", reason, home);
    fclose(f);
}

/* 一个数据根能不能用。⛔ 这是**native 自己的闸门** —— ArkTS 那边也校验，但那是防写坏，
 * 这里防读坏，与 `key` 的处理同一套道理（两边都要有）。
 * ⚠️ 判据故意**从严**：路径是我们自己拼出来的，没有任何理由出现相对形式或 `..`；
 *    一条不该出现的路径出现了，说明上游出了别的问题，回退沙箱比照着用更安全。 */
static int root_is_usable(const char *p)
{
    if (p[0] != '/') {
        return 0;                       /* 必须绝对 —— 相对路径会被当成 cwd 的兄弟 */
    }
    if (strstr(p, "..") != NULL) {
        return 0;
    }
    return 1;
}

/* 去掉结尾的斜杠。⛔ 不因为「有结尾斜杠」就**拒绝**这个根：拼后缀时双斜杠在 Linux 上合法，
 * 为这点小事把玩家的设置判死，代价不对等。 */
static void strip_trailing_slashes(char *p)
{
    size_t n = strlen(p);
    while (n > 1 && p[n - 1] == '/') {
        p[n - 1] = 0;
        n--;
    }
}

static void resolve_user_home(char *out, size_t outlen)
{
    char enabled[8];
    char key[128];
    /* ⚠️ root 用 512，**不是**像 key 那样的 128：外置路径本身就有 ~61 字符，再拼上
     * `/instances/<key>/sets/default` 会超过 128 —— 而 `read_kv` 遇到放不下的值是
     * 「整行当作不存在」（`n >= outlen` ⇒ break）⇒ **静默回退沙箱**。
     * ⭐ 一个尺寸写错、症状是「设置没生效」的洞。 */
    char root[512];

    enabled[0] = 0;
    key[0] = 0;
    root[0] = 0;
    read_kv(ISOLATION_FILE, "enabled", enabled, sizeof(enabled));
    read_kv(ISOLATION_FILE, "key", key, sizeof(key));
    read_kv(ISOLATION_FILE, "root", root, sizeof(root));

    /* ⭐⭐ **① 先定根，再进隔离分支。顺序是承重的。**
     * ⛔ 原来「隔离关着」那条早退直接返回 `DEST_ROOT`（编译期常量）。如果把读 root 塞进
     *    「隔离开着」那一支里，**隔离关着时外置就不生效** —— 而出厂就是不隔离，
     *    也就是说**最常见的那条路会静默忽略玩家的设置**。
     * ⚠️ root 缺省（老桥文件、或玩家选的就是沙箱）时 `base` 落回 DEST_ROOT
     *    ⇒ **与从前逐字节相同**（那条不变量：隔离关着 ⇒ 结果等于 DEST_ROOT）。 */
    const char *base = DEST_ROOT;
    if (root[0] != 0) {
        if (root_is_usable(root)) {
            strip_trailing_slashes(root);
            base = root;
        } else {
            SDL_Log("storage: rejecting root '%s' (not absolute, or contains '..') -- using %s",
                    root, DEST_ROOT);
        }
    }

    /* ⭐⭐ **先把根本身建出来。**
     * ⛔ `mkdir()` **不建父目录**，而外置的根是 `Download/<包名>/data` —— 它下面才是
     *    `instances/<键>/…`。不先建这一层，下面那几层会以 `ENOENT` 全部失败，
     *    于是回退 `DEST_ROOT`、记 `reason=mkdir-failed`，症状是「切到外置、重启又回到沙箱」。
     * ⚠️ ArkTS 那边（`ensureGameDataRoot`）也会建，但**这里也要建**：native 不该假设
     *    ArkTS 跑过 —— 这条路径在应用启动后第一次跑游戏时就要能用。
     * ⚠️ 失败即回退（`EEXIST` 不算失败）：建不出根就没有理由继续往下拼。 */
    if (mkdir(base, 0755) != 0 && errno != EEXIST) {
        SDL_Log("storage: cannot create root '%s' (errno=%d), falling back to %s",
                base, errno, DEST_ROOT);
        SDL_strlcpy(out, DEST_ROOT, outlen);
        record_user_home("root-mkdir-failed", out);
        return;
    }

    /* ② 隔离关着 ⇒ 就是根本身。 */
    if (strcmp(enabled, "1") != 0 || key[0] == 0) {
        SDL_strlcpy(out, base, outlen);
        SDL_Log("storage: isolation off, root=%s, user.home=%s", base, out);
        record_user_home("off", out);
        return;
    }

    /* ③ key 会进路径。只允许 [A-Za-z0-9._-]，别的一律回退 ——
     * 它由 ArkTS 从版本号拼出来，本该干净，但「本该」不是一道闸门。
     * ⚠️ 回退到 `base` 而不是 DEST_ROOT：这是「不隔离，但用你选的那个根」，
     *    比把玩家扔回沙箱更贴他的意图。 */
    for (const char *p = key; *p; p++) {
        int ok = (*p >= 'A' && *p <= 'Z') || (*p >= 'a' && *p <= 'z') ||
                 (*p >= '0' && *p <= '9') || *p == '.' || *p == '_' || *p == '-';
        if (!ok) {
            SDL_Log("isolation: rejecting key '%s' (bad character), user.home=%s", key, base);
            SDL_strlcpy(out, base, outlen);
            record_user_home("bad-key", out);
            return;
        }
    }

    /* ④ 拼路径，**显式查长度**。
     * ⛔⛔ `SDL_snprintf` 会**静默截断**成一个「看起来合法的短路径」，而下面紧接着就
     *    `mkdir` 那个被截断的路径、并把它当 `user.home` 返回 ⇒ **游戏在一个错的但存在的
     *    目录里启动，而记录里写着 `reason=on`**。量过：最坏 ~224 字符 vs 512 缓冲，
     *    **今天不会触发** —— 但这是「以后换个更深的路径就静默变错」的那种洞，所以现在就按住。
     * ⚠️ `SDL_snprintf` 返回的是**本该写入的长度**（同 snprintf）⇒ 拿它对比缓冲区大小即可。 */
    char home[512];
    {
        int n = SDL_snprintf(home, sizeof(home), "%s%s/%s/%s", base, ISOLATION_SUBDIR, key,
                             ISOLATION_SET);
        if (n < 0 || (size_t) n >= sizeof(home)) {
            SDL_Log("storage: user.home would need %d bytes (buffer %d) -- falling back to %s",
                    n, (int) sizeof(home), DEST_ROOT);
            SDL_strlcpy(out, DEST_ROOT, outlen);
            record_user_home("path-too-long", out);
            return;
        }
    }

    /* mkdir -p：连着建 instances、<key>、sets、default 四层（mkdir() 不建父目录）。
     * ⚠️ 前三层失败【不算错】—— 可能是刚被别处建好（EEXIST），最后那一层才说明问题。
     * ⚠️ 前两层建在 `base` 之下 ⇒ **外置时它们也建在外置**，这正是「根跟着走」的全部内容。 */
    {
        char partial[512];
        SDL_snprintf(partial, sizeof(partial), "%s%s", base, ISOLATION_SUBDIR);
        mkdir(partial, 0755);
        SDL_snprintf(partial, sizeof(partial), "%s%s/%s", base, ISOLATION_SUBDIR, key);
        mkdir(partial, 0755);
        SDL_snprintf(partial, sizeof(partial), "%s%s/%s/sets", base, ISOLATION_SUBDIR, key);
        mkdir(partial, 0755);
        if (mkdir(home, 0755) != 0 && errno != EEXIST) {
            SDL_Log("isolation: cannot create '%s' (errno=%d), falling back to %s",
                    home, errno, DEST_ROOT);
            SDL_strlcpy(out, DEST_ROOT, outlen);
            record_user_home("mkdir-failed", out);
            return;
        }
    }

    SDL_strlcpy(out, home, outlen);
    SDL_Log("isolation: on, root=%s, key=%s, user.home=%s", base, key, out);
    record_user_home("on", out);
}

/* 游戏语言（`-Duser.language=` / `-Duser.country=`），2026-10-04。
 *
 * ⭐⭐ **这是在补一个本来没有的能力，不是修缺陷**（用户 2026-10-04 纠正过：「这不是缺陷，
 *    正常 mindustry 就没有跟随」）。Mindustry **没有**「跟随系统」这个设置项：它的语言就是
 *    `settings.bin` 里那个值，而 **`default` 的含义是「用 JVM 的默认 locale」** ——
 *    桌面版看起来「跟着系统」，只是因为桌面 JVM 的默认 locale 跟着操作系统环境走。
 *    本启动器此前没给 JVM 传过 locale ⇒ HotSpot 的 C locale 是 `C` ⇒ 那个 `default` 落在
 *    **英文**上（随后 `LanguageDialog.findClosestLocale()` 还会把结果写死进 `settings.bin`）。
 *    这里做的就是**告诉 JVM 设备语言是什么**，出厂打开。
 *
 * ⭐ 局部实测（JDK17，宿主 zh_CN）：不给 `-D` ⇒ `zh_CN`（宿主）；`-Duser.language=ja -Duser.country=JP`
 *    ⇒ `ja_JP`；**只给 language** ⇒ `de_CN`（**地区跟着宿主走了**）⇒ **两个都要给，别只给一个。**
 * ⚠️ 值是 ArkTS 侧翻译好的（`GameLocale.systemGameLocale()`），已是游戏认得的写法（`zh_CN`）；
 *    这里只做**形状**校验，不重做翻译 —— 那份知识（游戏认哪些 locale）在 ArkTS 那边。
 * ⚠️ 空串 ⇒ 两个选项都留 NULL、由末尾那次压缩丢掉，**行为与本功能存在之前逐字节相同**。 */
static char opt_language[32];
/* ⛔⛔ **32，不是 16 —— 16 让这个功能【完全失效】，而它一声不响。**
 *    实测踩到：`-Duser.country=` 这个前缀本身 **15 个字符**，加 `CN` 再加结尾 NUL 需要 18。
 *    给 16 ⇒ `SDL_snprintf` **静默截断**成 `-Duser.country=`（值被切掉）⇒ JVM 收到一个国家为空的
 *     locale ⇒ `Locale("zh","")` ⇒ 游戏找 `bundle_zh.properties`（**不存在**）⇒ 落到英文根包。
 *    ⇒ 中文设备上照样是英文，而**日志看起来一切正常**（那句 `locale: …` 是我自己拼的，不经过缓冲区）。
 *    ⭐ 判据同 `read_kv` 那条：**缓冲区尺寸写错，症状是「设置没生效」，不是崩溃。** */
static char opt_country[32];

/* ⚠️⚠️ **诊断用，不是功能。** 在**游戏启动之前**把 `<user.home>/.local/share/Mindustry/settings.bin`
 * 里的两个值读出来打日志 —— 「游戏到底读到了什么」否则**只有它自己的设置界面能回答**，
 * 而那是玩家用眼睛看、我读不到的。有这一行之后，`stderr.log` 就能直接给出答案。
 *
 * ⛔⛔ **它故意只认 int 类型、遇到别的类型就跳过**（而不是完整实现 ARC 的格式）：
 *    完整的解析器在 ArkTS 那边（`GameSettings.ets`），已经用真实文件逐字节验证过。
 *    在这里再写一份完整的 = **两份会分叉的格式实现** —— 本项目为此付过代价。
 *    ⭐ 所以这里只做「够用的那一点」：读条目数，逐条读键名+类型，是 int 就记下来，
 *      不是 int 就按已知长度跳过。⚠️ 跳不过去（遇到字符串/字节数组）就**放弃并说出来** ——
 *      **半个解析结果比不解析更危险**（它会让人以为读到了真值）。
 *
 * 输出形如：`settings-probe: uiEdgePadding=89 uiscale=100 entries=19` */
static void log_game_settings_probe(const char *home)
{
    char path[768];
    /* ⚠️ ARC 的数据目录是 `<user.home>/.local/share/Mindustry`（见 `Vars.dataDirectory`）。 */
    SDL_snprintf(path, sizeof(path), "%s/.local/share/Mindustry/settings.bin", home);

    FILE *f = fopen(path, "rb");
    if (f == NULL) {
        SDL_Log("settings-probe: cannot open %s", path);
        return;
    }
    /* 头两字节是 zlib 魔数 ⇒ 压缩流（游戏自己从不写这种，见 GameSettings.ets）。
     * ⛔ 这里不解压：那种情况直接报出来，别装作读到了。 */
    int b0 = fgetc(f);
    int b1 = fgetc(f);
    if (b0 == 0x78 && (b1 == 1 || b1 == 94 || b1 == 0x9c || b1 == 0xda)) {
        fclose(f);
        SDL_Log("settings-probe: the file is zlib-compressed (the game never writes that) -- skipped");
        return;
    }
    /* ⛔ 回到开头：上面那两个字节就是条目数的前两字节。 */
    fseek(f, 0, SEEK_SET);

    unsigned char hdr[4];
    if (fread(hdr, 1, 4, f) != 4) {
        fclose(f);
        SDL_Log("settings-probe: the file is shorter than its own header");
        return;
    }
    const int count = (hdr[0] << 24) | (hdr[1] << 16) | (hdr[2] << 8) | hdr[3];
    if (count <= 0 || count > 4096) {
        fclose(f);
        SDL_Log("settings-probe: implausible entry count %d -- refused", count);
        return;
    }

    long edge = -1;
    long scale = -1;
    int  read_entries = 0;
    int  skipped_kinds = 0;

    for (int i = 0; i < count; i++) {
        int n0 = fgetc(f);
        int n1 = fgetc(f);
        if (n0 < 0 || n1 < 0) {
            break;
        }
        const int klen = (n0 << 8) | n1;
        if (klen <= 0 || klen > 200) {
            SDL_Log("settings-probe: implausible key length %d at entry %d -- stopped", klen, i);
            break;
        }
        char key[208];
        if ((int) fread(key, 1, (size_t) klen, f) != klen) {
            break;
        }
        key[klen] = 0;
        const int type = fgetc(f);
        if (type < 0) {
            break;
        }
        /* 类型字节（与 ARC 的 tableswitch 一致）：0 bool / 1 int / 2 long / 3 float / 4 UTF / 5 byte[] */
        if (type == 0) {
            fgetc(f);
        } else if (type == 1) {
            unsigned char v[4];
            if (fread(v, 1, 4, f) != 4) {
                break;
            }
            const long value = (long) ((v[0] << 24) | (v[1] << 16) | (v[2] << 8) | v[3]);
            if (strcmp(key, "uiEdgePadding") == 0) {
                edge = value;
            } else if (strcmp(key, "uiscale") == 0) {
                scale = value;
            }
        } else if (type == 2) {
            fseek(f, 8, SEEK_CUR);
        } else if (type == 3) {
            fseek(f, 4, SEEK_CUR);
        } else if (type == 4 || type == 5) {
            /* ⚠️ 变长的两种。**只读长度前缀再跳过** —— 这一步很小，但不做的话探针会停在
             *    第一个字符串上（本项目实测：文件里 `lastBuildString` 排在第 16 条，
             *    于是 `uiscale` 永远读不到、报 -1）。⛔ 别在这里解析字符串内容：
             *    那是「再实现一份格式」，而完整实现已经在 ArkTS 那边（`GameSettings.ets`）。
             *    这里只需要**知道有多长**：type 4 是 `writeUTF`（2 字节长度），
             *    type 5 是 `int` 长度 + 内容（4 字节）。 */
            unsigned char lb[4];
            if (type == 4) {
                if (fread(lb, 1, 2, f) != 2) {
                    break;
                }
                const int n = (lb[0] << 8) | lb[1];
                if (n < 0 || fseek(f, n, SEEK_CUR) != 0) {
                    skipped_kinds++;
                    break;
                }
            } else {
                if (fread(lb, 1, 4, f) != 4) {
                    break;
                }
                const long n = (long) ((lb[0] << 24) | (lb[1] << 16) | (lb[2] << 8) | lb[3]);
                if (n < 0 || fseek(f, n, SEEK_CUR) != 0) {
                    skipped_kinds++;
                    break;
                }
            }
        } else {
            SDL_Log("settings-probe: unknown type %d for '%s' -- stopped", type, key);
            break;
        }
        read_entries++;
    }
    fclose(f);

    if (skipped_kinds == 0 && read_entries == count) {
        SDL_Log("settings-probe: what the game will read -- uiEdgePadding=%ld uiscale=%ld (%d entries)",
                edge, scale, count);
    } else {
        /* ⚠️ 读到一半停下来时**照样报已知的那两个**，但**说清是残缺的** ——
         * 「89」与「只读到第 12 条所以 89 可能是旧的」是两件不同的事。 */
        SDL_Log("settings-probe: PARTIAL (%d of %d entries; the file is malformed or truncated) -- "
                "uiEdgePadding=%ld uiscale=%ld", read_entries, count, edge, scale);
    }
}

/* 算出这次启动要给 JVM 的 locale，写进 opt_language / opt_country（空串 = 不设）。
 *
 * ⭐ 值由 ArkTS 翻译好（`GameLocale.systemGameLocale()`）后写进同一个桥文件 ——
 *    「游戏认哪些 locale」那份知识（35 个 ID，抄自 jar 的 `locales` 资产）**只有一处**。
 *    ⚠️ **不要**把那份清单抄到这里来：两份清单会分叉，而分叉的症状是「某个语言静默变英文」。
 *    这里**只校验形状**，不重做翻译：重做一遍就是两份会分叉的实现。
 *
 * ⛔ 校验是必须的，虽然来源是我们自己：值要拼进 `-D` 字符串，而且它来自一个**文件**
 *    （可以被改、可以被写坏）。判据与 `key` 那里同款（那份要进路径，这份要进属性值）。
 * ⚠️ 只在**两个**部分都合法时才用：`zh` 这种没有地区的是合法的（`bundle_ja` / `bundle_en`
 *    这些确实是裸语言），但如果带了 `_` 而地区部分不合法，整条丢掉 —— 半个值会让
 *    `Locale("zh", "")` 与 ArkTS 那边的意图不符。 */
static void resolve_game_locale(void)
{
    char loc[32];
    loc[0] = 0;
    opt_language[0] = 0;
    opt_country[0] = 0;

    if (read_kv(ISOLATION_FILE, "locale", loc, sizeof(loc)) <= 0) {
        return;                         /* 没写 / 空 / 读不出 —— 全部「不设」，与从前一致 */
    }

    /* 切成 language 与 country（可选）。格式 `ll` 或 `ll_CC`。 */
    char lang[16];
    char country[16];
    country[0] = 0;
    const char *us = strchr(loc, '_');
    if (us != NULL) {
        size_t llen = (size_t) (us - loc);
        if (llen == 0 || llen >= sizeof(lang)) {
            SDL_Log("locale: rejecting '%s' (bad language part)", loc);
            return;
        }
        memcpy(lang, loc, llen);
        lang[llen] = 0;
        SDL_strlcpy(country, us + 1, sizeof(country));
    } else {
        SDL_strlcpy(lang, loc, sizeof(lang));
    }

    /* 只允许 [A-Za-z] 于语言、[A-Za-z] 于地区（`id_ID` 里的 `ID` 也在这个集合里）。
     * ⛔ 不许数字、下划线、点 —— 游戏那 35 个 ID 一个都不需要它们，而多出来的字符
     *    只会让「这是不是我们生成的」变得说不清。 */
    for (const char *p = lang; *p; p++) {
        if (!((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z'))) {
            SDL_Log("locale: rejecting '%s' (bad character in language)", loc);
            return;
        }
    }
    const size_t langlen = strlen(lang);
    if (langlen < 2 || langlen > 3) {
        SDL_Log("locale: rejecting '%s' (language length %d)", loc, (int) langlen);
        return;
    }
    if (country[0] != 0) {
        const size_t clen = strlen(country);
        if (clen != 2) {
            SDL_Log("locale: rejecting '%s' (country length %d)", loc, (int) clen);
            return;
        }
        for (const char *p = country; *p; p++) {
            if (!((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z'))) {
                SDL_Log("locale: rejecting '%s' (bad character in country)", loc);
                return;
            }
        }
    }

    /* ⭐ 显式查截断返回值（`SDL_snprintf` 返回「本该写多少个字符」）。
     *    ⛔ 这不是防御性编程：**上面那个 16 字节的 bug 就是这个类别的**，而它的症状是静默失效。
     *    校验过的输入（2~3 + `_` + 2）撞不到这个上限，所以这里只该在有人改了校验时响。 */
    if (SDL_snprintf(opt_language, sizeof(opt_language), "-Duser.language=%s", lang)
            >= (int) sizeof(opt_language) ||
        (country[0] != 0 &&
         SDL_snprintf(opt_country, sizeof(opt_country), "-Duser.country=%s", country)
            >= (int) sizeof(opt_country))) {
        SDL_Log("locale: option string would be truncated -- NOT setting the locale");
        opt_language[0] = 0;
        opt_country[0] = 0;
        return;
    }
    /* ⚠️ 打**桥里那个原值**（`loc`），不要自己拿 lang+country 拼一个 ——
     *    第一版就是这么拼的，漏了 `_`，打出来 `zhCN`，**把上面那个截断 bug 藏了一轮**。
     *    原值同时也证明了「翻译出来的值是什么」。 */
    SDL_Log("locale: game language follows the system -- %s (-Duser.language=%s%s%s)",
            loc, lang, country[0] != 0 ? ", -Duser.country=" : "", country);
}

/* 在 ArkTS 写下的文件里查一行 "key=value"。返回拷贝的字节数（键不存在或文件不可读时为 0），
 * 这样调用方可以把系统属性留作未设置，而不是传一个空值 —— 空的 -Darc.sdl.chooserPath 会让
 * 游戏的文件浏览器打开在文件系统根，比干脆不试还糟。⚠️ 带 path 参数是因为 isolation.txt 要用
 * 【同一种】解析规则；"<threw>" 与空值的规则是踩出来的，复制一份就会分叉。 */
static int read_kv(const char *path, const char *key, char *out, size_t outlen)
{
    FILE *f = fopen(path, "r");
    if (!f) {
        return 0;
    }

    int found = 0;
    char line[1024];
    size_t klen = strlen(key);
    while (fgets(line, (int) sizeof(line), f)) {
        if (strncmp(line, key, klen) != 0 || line[klen] != '=') {
            continue;
        }
        const char *v = line + klen + 1;
        size_t n = strlen(v);
        /* 10 和 13 是 LF 和 CR。写成数字而不是字符转义，是因为这个文件已经过一次工具的
         * 处理，那个工具吃掉了反斜杠，在字符字面量里留下了一个真正的换行。 */
        while (n > 0 && (v[n - 1] == 10 || v[n - 1] == 13)) {
            n--;
        }
        /* "<threw>" 是平台调用失败时 ArkTS 写的东西，不是路径 ⇒ 当作不存在。空值同样对待：
         * -Darc.sdl.chooserPath= （空）会把浏览器开在文件系统根，比不设该属性还糟。 */
        if (n == 0 || n >= outlen) {
            break;
        }
        if (n == 7 && strncmp(v, "<threw>", 7) == 0) {
            break;
        }
        memcpy(out, v, n);
        out[n] = 0;
        found = (int) n;
        break;
    }
    fclose(f);
    return found;
}

/** 上面那个的薄包装：只读 USER_DIRS_FILE 里的一个键。 */
static int read_user_dir(const char *key, char *out, size_t outlen)
{
    return read_kv(USER_DIRS_FILE, key, out, outlen);
}

/* 加载【哪一个】游戏 jar —— 启动器形态的核心。`GAME_JAR` 是一个编译期常量，换版本就得
 * 重构建重签名再装 171 MB，所以「用哪个 jar」从编译期常量变成每次启动都要问一次的问题。复用
 * user_dirs.txt（已有解析，已处理键不存在与 "<threw>"；存路径而非索引 —— 来源只能是 ArkTS 一处）。
 * ⚠️ 两个分支都必须能【打开】才算数；规则与 Index.ets 的 gameAvailable() 是【同一条】，两处都要改。 */
static char game_jar_path[512];

/** 它存在、且头两字节是 'PK'（一个 ZIP/jar）时为真。 */
static int is_readable_jar(const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f) {
        return 0;
    }
    char magic[2] = { 0, 0 };
    int ok = (fread(magic, 1, 2, f) == 2 && magic[0] == 'P' && magic[1] == 'K');
    fclose(f);
    return ok;
}

/** 把要加载的 jar 解析进 game_jar_path。解析出来时为 1，两个来源都没有时为 0。 */
static int resolve_game_jar(void)
{
    if (read_user_dir("gamejar", game_jar_path, sizeof(game_jar_path)) > 0) {
        if (is_readable_jar(game_jar_path)) {
            SDL_Log("   game jar: %s  (chosen in the launcher)", game_jar_path);
            return 1;
        }
        SDL_Log(" !! the chosen game jar is gone or is not a jar: %s", game_jar_path);
        SDL_Log("    falling back to the bundled game");
    }
    if (is_readable_jar(GAME_JAR)) {
        SDL_strlcpy(game_jar_path, GAME_JAR, sizeof(game_jar_path));
        SDL_Log("   game jar: %s  (bundled)", game_jar_path);
        return 1;
    }
    game_jar_path[0] = 0;
    return 0;
}

/* 玩家选了哪种操作方案，跨启动持久化。Mindustry 用【一个 bit】决定整个输入层和 UI（Vars.mobile
 * = Core.app.isMobile() || Vars.testMobile）；游戏内开关不碰这个 bit（只调 control.setInput，
 * 输入处理器变了、UI 仍移动端）。字节码确认 Vars.mobile 只有一个写入者即 Vars.init() 那行，所以
 * 要在 Vars.init() 运行【之前】（JVM 启动前）设好 ⇒ 答案得先在磁盘上：ArkTS 写、native 只读；文件不存在 ⇒ 移动端。 */
#define CONTROL_MODE_FILE "/data/storage/el2/base/haps/entry/files/control_mode.txt"

static int read_control_mode_mobile(void)
{
    FILE *f = fopen(CONTROL_MODE_FILE, "r");
    if (!f) {
        return 1;                       /* 没记录：保持移动端 */
    }
    int mobile = 1;
    char line[32];
    if (fgets(line, (int) sizeof(line), f)) {
        /* "desktop" 是唯一能关掉它的值；其它任何东西（"mobile"、空文件、截断的写入）都让默认值
         * 保持不变 —— 损坏或只写了一半的文件不会悄悄换掉玩家的操作方式。 */
        if (strncmp(line, "desktop", 7) == 0) {
            mobile = 0;
        }
    }
    fclose(f);
    return mobile;
}

static void probe_user_dirs(void)
{
    FILE *f = fopen(USER_DIRS_FILE, "r");
    if (!f) {
        SDL_Log(" user_dirs.txt not readable -- ArkTS did not write it?");
        return;
    }

    SDL_Log(" ---- can the app read the user-visible directories? ----");
    char line[1024];
    while (fgets(line, (int) sizeof(line), f)) {
        size_t n = strlen(line);
        while (n > 0 && (line[n - 1] == '\n' || line[n - 1] == '\r')) {
            line[--n] = '\0';
        }
        const char *eq = strchr(line, '=');
        if (!eq || n == 0) {
            continue;
        }

        char label[64];
        size_t ll = (size_t) (eq - line);
        if (ll >= sizeof(label)) {
            ll = sizeof(label) - 1;
        }
        memcpy(label, line, ll);
        label[ll] = '\0';
        const char *path = eq + 1;

        /* opendir 才是关键问题：游戏必须先【列出】目录，才能挑文件。用 stat() 而非 dirent 的 d_type
         * —— d_type 允许是 DT_UNKNOWN，会把一切错分成「不是目录」。目录项不是文件，故计数拆开；
         * 扩展名统计有用：LoadDialog 用 {"msav"}、SettingsMenuDialog 用 {"zip"}（字节码实测），条件不同。 */
        DIR *d = opendir(path);
        if (!d) {
            SDL_Log("   %-9s NOT READABLE  errno=%d (%s)  %s",
                    label, errno, strerror(errno), path);
            continue;
        }

        int entries = 0;
        int dirs = 0;
        int files = 0;
        int save_like = 0;
        int zip_like = 0;
        char exts[256];
        int ext_off = 0;
        exts[0] = '\0';

        struct dirent *e;
        while ((e = readdir(d)) != NULL && entries < 2000) {
            entries++;

            char full[1200];
            SDL_snprintf(full, sizeof(full), "%s/%s", path, e->d_name);
            struct stat st;
            if (stat(full, &st) != 0) {
                continue;
            }
            if (S_ISDIR(st.st_mode)) {
                dirs++;   /* 一个包目录、.zip 文件，随便什么 —— 都不是扩展名 */
                continue;
            }
            files++;

            const char *dot = strrchr(e->d_name, '.');
            if (!dot || dot == e->d_name) {
                continue;  /* 没有扩展名，或者是像 .nomedia 这样的点文件 */
            }

            if (strcmp(dot, ".msav") == 0 || strcmp(dot, ".msch") == 0) {
                save_like++;
                SDL_Log("   %-9s   FOUND SAVE-CLASS FILE: %s", label, e->d_name);
            }
            if (strcmp(dot, ".zip") == 0) {
                zip_like++;
                SDL_Log("   %-9s   FOUND ZIP (this is what 'Game Data -> Import' wants): %s",
                        label, e->d_name);
            }

            /* 只记不重复的扩展名；按 token 边界匹配而非 strstr，这样 ".so" 不会在 ".something" 里被「找到」。 */
            int seen = 0;
            int off = 0;
            while (!seen && off < ext_off) {
                int len = 0;
                while (off + len < ext_off && exts[off + len] != ' ') {
                    len++;
                }
                if ((int) strlen(dot + 1) == len && strncmp(exts + off, dot + 1, (size_t) len) == 0) {
                    seen = 1;
                }
                off += len + 1;
            }
            if (!seen && ext_off + (int) strlen(dot + 1) + 2 < (int) sizeof(exts)) {
                ext_off += SDL_snprintf(exts + ext_off, sizeof(exts) - (size_t) ext_off,
                                        "%s%s", (ext_off > 0) ? " " : "", dot + 1);
            }
        }
        closedir(d);

        SDL_Log("   %-9s READABLE      %d entries = %d dirs + %d files; %d save-class, %d zip",
                label, entries, dirs, files, save_like, zip_like);
        SDL_Log("   %-9s   file extensions seen: %s", label, (exts[0] != '\0') ? exts : "(none)");
    }
    fclose(f);
    SDL_Log(" ---- end user-directory probe ----");
}

/* Native 代码只能从 HAP 的只读区执行，绝不能从应用可写沙箱执行。设备实测：
 *   dlopen("/data/storage/el1/bundle/libs/arm64/libSDL3.so")     -> OK
 *   dlopen("/data/storage/el2/base/files/.../libcxxabi_shim.so") -> FAIL（chmod 0755 也没用）
 * 即通常的 W^X：el2（可写）不可执行。所以整个 JDK 作为预构建库放在 entry/libs/arm64-v8a/。 */

/* libjvm.so 必须住在 <JDK_HOME>/lib/server/libjvm_real.so：HotSpot 从它的位置剥三层分量推
 * java.home（os_linux.cpp 的 os::init_system_properties_values），再要求 "<java.home>/lib/modules"
 * 存在，否则 "Failed setting boot class path."；被拍平到 ABI 目录就会落到 .../bundle 上而失败。
 * 经验验证过：从可写沙箱 dlopen JVM 对我们【没有】成功，成功的副本是 HAP 里的那份。 */

static int g_files = 0;
static long long g_bytes = 0;

/* 我们在哪？—— 运行时发现，而非假设。ABI 目录名在两个命名空间里【不是】同一个字符串（HAP 内
 * 是 libs/arm64-v8a/...，设备上是 /data/storage/el1/bundle/libs/arm64/...），搞错它是无声的
 * （dlopen 只报 "no such file"）。其中一条【不是】我们能选的：anchor 的 DT_NEEDED 带着
 * prep_vendor.py 在【链接时】烙进去的设备绝对路径 ⇒ 向 dladdr() 询问真正加载中的库的路径。 */
#define ABI_DIR_GUESS "/data/storage/el1/bundle/libs/arm64"

static char g_root[1024];       /* <bundle>/libs/<abi>            */
static char g_jdkhome[1200];    /* <root>/jdk21                   */
static char g_jdklib[1400];     /* <jdkhome>/lib                  */
static char g_jvmreal[1500];    /* <jdklib>/server/libjvm_real.so */
static char g_anchor[1400];     /* <root>/libjvm.so               */

/* 定义在下面更远处，但 diagnose_loading() 需要它们而它排在前头。 */
/* probe_exec_mem() 的结果：匿名 RWX 可用时为 42，mmap 被拒时为 -1，代码没跑起来时是别的值。
 * 刻意初始化成【不是 42】：选项组装会把「不是 42」当作拿不到可执行内存并强制 -Xint，所以探测
 * 万一没跑成，被采纳的是那个安全答案（出错代价是一个装得上、然后毫无解释地卡死的应用）。 */
static long g_exec_probe_result = -2;
static long probe_exec_mem(void);
static void probe_icache(void);
static void report_mapping(unsigned long addr, char *out, size_t cap);

static void joinp(char *dst, size_t cap, const char *a, const char *b)
{
    SDL_snprintf(dst, cap, "%s%s", a, b);
}

/* 如果 dladdr 给了我们一个可用的目录就返回 1 */
static int discover_paths(void)
{
    Dl_info dl;
    SDL_memset(&dl, 0, sizeof(dl));

    g_root[0] = '\0';
    if (dladdr((void *)(uintptr_t)&discover_paths, &dl) && dl.dli_fname) {
        SDL_strlcpy(g_root, dl.dli_fname, sizeof(g_root));
        char *slash = SDL_strrchr(g_root, '/');
        if (slash) *slash = '\0';
        SDL_Log(" dladdr says this library is      : %s", dl.dli_fname);
        SDL_Log(" -> so the native lib dir is      : %s", g_root);
    } else {
        SDL_Log(" !! dladdr failed -- falling back to the compile-time guess");
    }

    /* 发现失败就回退到那个猜测，好让我们仍然能拿到诊断信息 */
    int discovered = (g_root[0] != '\0');
    if (!discovered) SDL_strlcpy(g_root, ABI_DIR_GUESS, sizeof(g_root));

    joinp(g_jdkhome, sizeof(g_jdkhome), g_root, "/jdk21");
    joinp(g_jdklib,  sizeof(g_jdklib),  g_jdkhome, "/lib");
    joinp(g_jvmreal, sizeof(g_jvmreal), g_jdklib, "/server/libjvm_real.so");
    joinp(g_anchor,  sizeof(g_anchor),  g_root, "/libjvm.so");

    /* 编译时的选择对得上吗？这是运行时唯一无法修复的一件事，所以明明白白说出来 */
    struct stat st;
    int guess_ok = (stat(ABI_DIR_GUESS "/libjvm.so", &st) == 0);
    SDL_Log(" compile-time guess               : %s  [%s]",
            ABI_DIR_GUESS, guess_ok ? "exists" : "NOT PRESENT");
    if (!guess_ok) {
        SDL_Log(" !! the anchor's baked-in DT_NEEDED points at a path that does not");
        SDL_Log("    exist here. Re-run:  python prep_vendor.py  with DEVICE_JVM");
        SDL_Log("    rewritten to start with  %s/", g_root);
    }
    return discovered;
}

/* 解包机制没有了：JDK 直接从 HAP 的 lib 区运行（见 JDK_HOME）—— 移除了「首次启动写 165 MB」
 * 的开销，以及随之而来的一整类 bug（包括一个符号链接失败却悄悄删光所有库的）。 */

static void mkdirs(const char *path)
{
    char tmp[1200];
    size_t len = SDL_strlen(path);
    if (len >= sizeof(tmp)) return;
    SDL_memcpy(tmp, path, len + 1);
    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') { *p = '\0'; mkdir(tmp, 0755); *p = '/'; }
    }
    mkdir(tmp, 0755);
}

/* ------------------------------------------------------------- JVM 启动 */

/* ---------------------------------------------------------- stdio + 崩溃 */

/* 把 stdout/stderr 重定向进可写沙箱：JVM 在那里报告启动失败，没有它一次失败就只是「进程死了」。
 * （AMCL 用它的 "[Phase 4] REDIRECT_IO" 做同样的事。） */
static void redirect_io(void)
{
    int fo = open(DEST_ROOT "/stdout.log", O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fo >= 0) { dup2(fo, 1); if (fo > 2) close(fo); }
    int fe = open(DEST_ROOT "/stderr.log", O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fe >= 0) { dup2(fe, 2); if (fe > 2) close(fe); }
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
}

/* 报告一个致命信号，并通过 dladdr 报告该地址属于哪个库。 */
/* 当前线程的名字，用于崩溃报告 —— 见 on_fatal_signal() */
static const char *thread_name(void)
{
    static char tn[64];
    if (tn[0]) return tn;
    if (pthread_getname_np(pthread_self(), tn, sizeof(tn)) != 0 || !tn[0]) {
        SDL_strlcpy(tn, "(unnamed)", sizeof(tn));
    }
    return tn;
}

static void on_fatal_signal(int sig, siginfo_t *info, void *uctx)
{
    (void)uctx;
    const char *name = "?";
    Dl_info dl;
    SDL_memset(&dl, 0, sizeof(dl));
    if (info && dladdr(info->si_addr, &dl) && dl.dli_fname) name = dl.dli_fname;

    char buf[1600];
    char map[512];
    unsigned long pc = (unsigned long)(uintptr_t)(info ? info->si_addr : NULL);
    report_mapping(pc, map, sizeof(map));

    /* 对 SIGILL，dump 出错指令处的字节：能区分「字节不是合法 aarch64 指令」（HotSpot 为本设备
     * 没有的 CPU 特性生成代码）与「字节合法」（写入到了内存但没到指令缓存，即一致性问题）——
     * 两者修法毫无共同之处。只在映射可读时才读，免得把一次崩溃变成两次。 */
    /* dump 出错时刻的 CPU 寄存器：单看出错地址无法区分「代码是错的」与「控制流到了不该到的地方」。
     * aarch64 上 HotSpot 解释器这样分发（adrp x21,<dispatch table page> ; add x21,x21,#off ;
     * ldr x9,[x21,w9,uxtw #3] ; br x9），故 x21 是代码【以为】自己有的分发表、x9 是它实际去的地方。 */
    /* 说出【出错指令】所在的模块与线程：si_addr 说的是什么被碰了（小偏移处常是 0x20 之类、
     * dladdr 报 "in ?"），而程序计数器永远落在真实映射里，能回答「是哪个库、还是 JIT 代码」。
     * 线程名把游戏线程上的错误与 SDL UI 事件路径上的错误区分开。 */
    char pcinfo[600];
    pcinfo[0] = '\0';
    if (uctx) {
        ucontext_t *uc0 = (ucontext_t *)uctx;
        unsigned long faultpc = (unsigned long) uc0->uc_mcontext.pc;
        Dl_info pd;
        SDL_memset(&pd, 0, sizeof(pd));
        char pmap[512];
        report_mapping(faultpc, pmap, sizeof(pmap));
        SDL_snprintf(pcinfo, sizeof(pcinfo),
                     "    pc 0x%lx in %s\n    %s\n    thread %s\n",
                     faultpc,
                     (dladdr((void *)faultpc, &pd) && pd.dli_fname)
                        ? pd.dli_fname : "(no module -- JIT code?)",
                     pmap, thread_name());
    }

    char regs[1400];
    regs[0] = '\0';
    if (uctx) {
        ucontext_t *uc = (ucontext_t *)uctx;
        int n = SDL_snprintf(regs, sizeof(regs), "    regs:");
        for (int i = 0; i <= 30; i++) {
            if (n > (int)sizeof(regs) - 24) break;
            n += SDL_snprintf(regs + n, sizeof(regs) - n, " x%d=%lx",
                              i, (unsigned long)uc->uc_mcontext.regs[i]);
            if (i % 4 == 3) { n += SDL_snprintf(regs + n, sizeof(regs) - n, "\n         "); }
        }
        n += SDL_snprintf(regs + n, sizeof(regs) - n,
                          "\n    sp=%lx pc=%lx pstate=%lx  pc==si_addr? %s\n",
                          (unsigned long)uc->uc_mcontext.sp,
                          (unsigned long)uc->uc_mcontext.pc,
                          (unsigned long)uc->uc_mcontext.pstate,
                          ((unsigned long)uc->uc_mcontext.pc == pc) ? "YES" : "NO");
    }

    char insn[400];
    insn[0] = '\0';
    if (sig == SIGILL && pc && strstr(map, " r") && !strstr(map, "(no ")) {
        /* 从基址开始 dump 【整个】映射的原始字节而非文本，要回答「HotSpot 对 code cache 的模型与
         * 内存实际是否一致」：-XX:+PrintStubCode 打印每个 stub 的地址与字节，且基址跨运行稳定，
         * 故可直接对比 —— 一致 ⇒ 异常在「如何到达」；不同 ⇒ 有什么往 code cache 里写而本不该写。 */
        unsigned long lo = 0, hi = 0;
        if (sscanf(map, "%lx-%lx", &lo, &hi) == 2) {
            unsigned long base = lo;
            size_t len = (hi > lo) ? (size_t)(hi - lo) : 0;
            if (len > (size_t)4 * 1024 * 1024) len = 4 * 1024 * 1024;
            int fd = open(DEST_ROOT "/cc_dump.bin", O_WRONLY | O_CREAT | O_TRUNC, 0644);
            if (fd >= 0) {
                char hdr[128];
                int hn = SDL_snprintf(hdr, sizeof(hdr),
                    "PC=0x%lx BASE=0x%lx LEN=%llu MAP=%s\n",
                    (unsigned long)pc, base, (unsigned long long)len, map);
                /* ⛔⛔ `hn` 是**本该写入的长度**，⛔ 不是实际写进去的（标准 `vsnprintf` 语义，
                 *    见 `SDL_snprintf` → `SDL_vsnprintf`，以及本文件 283 行那段）——
                 *    **截断时它【大于】`sizeof(hdr)`**。直接拿它当 `write` 的长度，
                 *    就是从 `hdr` 后面**越界读**最多约 440 字节写进 `cc_dump.bin`
                 *    （`map` 可到 511，而这里只有 128）。
                 * ⭐ 内容长度取 `min(hn, sizeof(hdr) - 1)`：`snprintf` 保证最多写
                 *    `sizeof - 1` 个字符 + 一个 `NUL`，所以这个长度就是**实际有效内容**。 */
                if (hn > (int)sizeof(hdr) - 1) hn = (int)sizeof(hdr) - 1;
                ssize_t w = write(fd, hdr, (size_t)hn); (void)w;
                w = write(fd, (const void *)base, len); (void)w;
                close(fd);
                SDL_snprintf(insn, sizeof(insn),
                             "    wrote %llu raw bytes at 0x%lx to cc_dump.bin (PC offset +0x%lx)\n",
                             (unsigned long long)len, base, (unsigned long)(pc - base));
            } else {
                SDL_snprintf(insn, sizeof(insn),
                             "    !! could not open cc_dump.bin (errno=%d)\n", errno);
            }
        } else {
            SDL_snprintf(insn, sizeof(insn), "    !! could not parse the mapping line\n");
        }
    }

    int n = SDL_snprintf(buf, sizeof(buf),
        "*** FATAL SIGNAL %d (code=%d) at %p  -> in %s ***\n"
        "    mapping: %s\n%s%s%s",
        sig, info ? info->si_code : -1, info ? info->si_addr : NULL, name, map,
        pcinfo, regs, insn);
    if (n > 0) {
        /* ⛔⛔ **`n` 是「本该写入的长度」，⛔ 不是实际写进去的**（与上面 `hdr` 那处同一个坑）。
         *    这里拼进去的四段最坏是 `map` 511 + `pcinfo` 599 + `regs` 1399 + `insn` 399 ≈ 2900，
         *    而 `buf` 只有 1600 ⇒ 截断时 `n` 可达 2900
         *    ⇒ `write(fd, buf, 2900)` **从栈上越界读约 1.4 KB**，写进 `crash.txt` 与 stderr。
         * ⚠️ 为什么不是「反正已经崩了，无所谓」：
         *    ① 越界读是**未定义行为**，可能**二次崩溃** ⇒ 把本来要留下的那份报告一起弄丢；
         *    ② 本项目**崩溃是常态**（一口气抓过 18 条 faultlog），这条路不冷。
         * ⭐ 内容长度取 `min(n, sizeof(buf) - 1)` —— 理由同上面那一处。 */
        if (n > (int)sizeof(buf) - 1) n = (int)sizeof(buf) - 1;
        int fd = open(DEST_ROOT "/crash.txt", O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) { ssize_t w = write(fd, buf, (size_t)n); (void)w; close(fd); }
        ssize_t w2 = write(2, buf, (size_t)n); (void)w2;
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

static void install_crash_handlers(void)
{
    struct sigaction sa;
    SDL_memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = on_fatal_signal;
    sa.sa_flags = SA_SIGINFO | SA_RESETHAND;
    sigemptyset(&sa.sa_mask);
    const int sigs[] = { SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE };
    for (int i = 0; i < 5; i++) sigaction(sigs[i], &sa, NULL);
}

typedef jint (*CreateJavaVM_t)(JavaVM **pvm, void **penv, void *args);

/* libjvm_real.so 的 DT_NEEDED 是 [libcxxabi_shim.so, libc.so]，而 shim 曾住在 <java.home>/lib
 * 下（不在 loader 搜索路径上）⇒ 第一版 dlopen libjvm.so 以 musl 那句没用的 "No error information"
 * 失败。⛔ 当初的修法（对每个 .so 逐个 RTLD_GLOBAL dlopen）【已不再需要，也已被删】——
 * 当前布局直接把 shim 放进了搜索路径。别照那段历史把 preload 加回来。 */
static int try_dlopen(const char *path, const char *label)
{
    errno = 0;
    void *h = dlopen(path, RTLD_LAZY | RTLD_GLOBAL);
    if (h) {
        SDL_Log("   OK  %-28s %s", label, path);
        return 0;
    }
    SDL_Log("   NO  %-28s %s", label, path);
    SDL_Log("        dlerror: %s   errno=%d (%s)", dlerror(), errno, strerror(errno));
    return 1;
}

/* 这个文件是 ELF 共享对象吗？（该目录里还放着 jimage，名字也叫 *.so） */
static bool is_elf(const char *path)
{
    int fd = open(path, O_RDONLY);
    if (fd < 0) return false;
    unsigned char m[4];
    ssize_t n = read(fd, m, 4);
    close(fd);
    return n == 4 && m[0] == 0x7f && m[1] == 'E' && m[2] == 'L' && m[3] == 'F';
}

/* 加载顺序很重要：其它每个 JDK 库都声明了对裸名 "libjvm.so" 的 DT_NEEDED，而这个目录不在 loader
 * 搜索路径上，所以 libjvm.so 必须【最先】用完整路径 + RTLD_GLOBAL 带进来，其它库随后针对它解析
 * 依赖；反过来就是一整堵 "libjvm.so: (needed by ...)" 失败。 */
/* preload 循环【没有了】：它存在过是为了更老的布局（shim 不在搜索路径上时，每个 JDK 库都得手工
 * RTLD_GLOBAL dlopen）。当前布局已解决 —— libjvm_real.so 只有 libcxxabi_shim.so 和 libc.so 两个
 * 依赖，shim 就在搜索路径上，其余 JDK 库由 JVM 自己从 sun.boot.library.path 加载。
 * ⚠️ 留着它并非无害：会把 35 个库推进全局符号作用域、排在 JVM【前面】，可能覆盖 HotSpot 自己的调用。 */
static void load_anchor_only(void)
{
    SDL_Log(" --- dlopen diagnostics ---");
    try_dlopen("libSDL3.so", "control: SDL3");
    try_dlopen(g_anchor, "anchor libjvm.so");
    SDL_Log(" --- end diagnostics ---");
}

/* option 字符串：JVM 可能往这些里写，所以它们必须可修改 */
static char opt_classpath[1024];   /* 6 条：补丁 jar + 游戏 + 三个 LWJGL + helper */
static char opt_home[512];
static char opt_tmpdir[512];
static char opt_libpath[512];
static char opt_encoding[512];
static char opt_headless[512];
static char opt_bootlib[512];
static char opt_errfile[512];
static char opt_heap[512];
/* 决定 JVM 到底能不能启动的两个 flag —— 见 start_jvm() */
static char opt_unsve[512];
static char opt_sve[512];
/* 三个平台属性，作为 VM 创建选项而不是运行时选项文件：游戏的平台检测在类初始化时就读它们，早于
 * 任何从 Java 侧设置能生效的时机。os.name —— LWJGL/Arc 每次 native 查找都依据它，已知可用的参考
 * 配置报 "Linux"（真实值会让游戏去找这个布局里不存在的 HarmonyOS/Android natives）；user.home ——
 * 存档与设置的位置（没有它 JVM 会从 /etc/passwd 猜）；user.dir —— 工作目录。只有 os.name 照搬那个
 * 参考启动器；user.home/user.dir 是本启动器自己的沙箱路径（DEST_ROOT）。 */
static char opt_osname[512];
static char opt_userhome[512];
static char opt_userdir[512];
/* LWJGL 从哪里找它用来分发的 natives —— 见 LWJGL_LIBS */
static char opt_lwjglpath[512];
/* 告诉 Arc 的 SDL 后端去要 OpenGL ES profile：OpenHarmony 只带 GLES 和 Vulkan、根本没有
 * libGL.so，所以 core/compatibility 请求会绑定 EGL_OPENGL_API、找不到 config，窗口建不出来。
 * Arc 自己没法想明白这点，由这里替它选。由 SdlApplication.profile() 读取。 */
static char opt_gles[512];
/* 告诉 Arc 这是一台触屏设备：后端从 getType() 得的 isMobile() 只可能是 android 或 iOS，所以在
 * 这里是 false，于是 Mindustry 用那一个 bit 决定整个输入层（input = Vars.mobile ?
 * new MobileInput() : new DesktopInput()）—— false 意味着平板拿到 WASD 键位、没有摇杆和屏幕按钮。
 * 由 SdlApplication.isMobile() 读取。 */
static char opt_mobile[512];

/* 游戏的文件浏览器应该从哪里打开：游戏把它根植在 Arc 的 getExternalStoragePath() 上，而
 * SdlFiles 从 user.home 算它 —— 而 user.home 是本启动器自己的沙箱，正是玩家放不了文件的地方，
 * 所以「导入存档」能浏览却永远找不到东西。值不是硬编码：ArkTS 向平台问真实用户可见目录
 * （environment.getUserDownloadDir）写到 user_dirs.txt，这里读回；可读性实测见 probe_user_dirs()。 */
static char opt_chooser[512];

/* 有序探测。"Error loading X: (needed by Y)" 对「链条哪一环断了」是含糊的，所以把每个问题分开
 * 问、用各自的 dlerror() 打印答案。只读。 */
static void dump_dir(const char *label, const char *dirpath, int limit)
{
    DIR *d = opendir(dirpath);
    if (!d) {
        SDL_Log("   %-14s opendir FAILED (errno=%d %s)", label, errno, strerror(errno));
        return;
    }
    int n = 0;
    struct dirent *e;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        n++;
        if (n <= limit) SDL_Log("      %s", e->d_name);
    }
    closedir(d);
    SDL_Log("   %-14s %d entries", label, n);
}

static void probe_mode(const char *path)
{
    struct stat st;
    if (stat(path, &st) == 0)
        SDL_Log("     %06o %10lld  %s",
                (unsigned)st.st_mode, (long long)st.st_size, path);
    else
        SDL_Log("     ??     ----------  %s  (stat failed errno=%d %s)",
                path, errno, strerror(errno));
}

static void probe_dlopen(const char *label, const char *path)
{
    /* 与真正的加载用同样的 flag —— 用 RTLD_NOW 探测会把 lazy 下能正常加载的库报成失败。 */
    void *h = dlopen(path, RTLD_LAZY | RTLD_GLOBAL);
    if (h) {
        SDL_Log("   OK  %-20s %s", label, path);
    } else {
        SDL_Log("   NO  %-20s %s", label, path);
        SDL_Log("         -> %s", dlerror());
    }
}

/* 一份简短的、有序的问题清单，其答案彼此无法推断：文件在不在、是什么 mode、CONTROL 能不能
 * 加载、JVM 那两块能不能加载。早先几轮在一个像 "Error loading shared library X: (needed by Y)"
 * 的含混消息上浪费了大量时间，而它与十来种原因都相容。刻意保持窄小。 */
/* 一个 HAP 资源文件能否作为【普通文件系统路径】被访问到？hvigor 从 entry/libs/ 只分发 `*.so`，
 * 走那条路的 JDK 会丢掉每个数据文件（`modules` 逼出了 jimg.so 改名，还有 `conf/`、`classlist`、
 * `jvm.cfg`），而 HAP 的 rawfile 区没有这种过滤：放进去的原样进去、名字完好。问法：在项目里放
 * `resources/rawfile/rawfile_probe.txt`，构建后问运行中的应用哪条路径能解析到 —— 只有应用能看见
 * 自己的 bundle 区。若可行，【整个未修改的 JDK】都能在那里分发。 */
static void probe_rawfile(void)
{
    static const char *cands[] = {
        "/data/storage/el1/bundle/entry/resources/rawfile/rawfile_probe.txt",
        "/data/storage/el1/bundle/resources/rawfile/rawfile_probe.txt",
        "/data/storage/el1/bundle/entry/resources/rawfile_rawfile_probe.txt",
    };
    SDL_Log(" --- rawfile reachability ---");
    for (unsigned i = 0; i < sizeof(cands) / sizeof(cands[0]); i++) {
        struct stat st;
        int r = stat(cands[i], &st);
        SDL_Log("   %s  %s%s", (r == 0) ? "YES" : "no ", cands[i],
                (r == 0) ? "" : "  (stat failed)");
        if (r == 0) {
            int fd = open(cands[i], O_RDONLY);
            if (fd >= 0) {
                char buf[64];
                ssize_t n = read(fd, buf, sizeof(buf) - 1);
                close(fd);
                if (n > 0) { buf[n] = '\0'; SDL_Log("        content: %s", buf); }
            }
        }
    }
    SDL_Log(" ----------------------------");
}

/* 这个进程能不能访问系统的 EGL/GLES？SDL 的 OpenHarmony 视频驱动只用裸名加载两个名字：DEFAULT_EGL
 * "libEGL.so" 与 DEFAULT_OGL_ES2 "libGLESv3.so"。两者在设备上都存在（/system/lib64），所以
 * SDL_CreateWindow 报 "Could not initialize OpenGL / GLES library" 意味着加载被拒绝而非文件不存在。
 * 裸名走 linker 为进程设的受限搜索路径、绝对路径要么解析要么不能，同时问两种形式即可区分原因。 */
static void probe_gl_libs(void)
{
    static const char *names[] = {
        "libEGL.so",
        "libGLESv3.so",
        "libGLESv2.so",
        "/system/lib64/libEGL.so",
        "/system/lib64/libGLESv3.so",
    };
    /* 两种绑定模式都测，因为 SDL 用的是 RTLD_NOW（dlopen(sofile, RTLD_NOW|RTLD_LOCAL)，见
     * SDL_sysloadso.c）：LAZY 首次调用才解析重定位，带无人提供之符号的库仍能加载；NOW 提前全部
     * 解析并拒绝。只测一种，就分不清「懒成急败」与「库缺失」——本项目在 __cxa_thread_atexit 上被骗过一次。 */
    SDL_Log(" ==== GL library reachability ====");
    for (unsigned i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        void *lazy = dlopen(names[i], RTLD_LAZY | RTLD_LOCAL);
        SDL_Log("   %-27s lazy=%s%s", names[i], lazy ? "OK" : "FAIL",
                lazy ? "" : "  ");
        if (lazy) dlclose(lazy);

        void *now = dlopen(names[i], RTLD_NOW | RTLD_LOCAL);
        if (now) {
            SDL_Log("   %-27s now =OK", names[i]);
            dlclose(now);
        } else {
            SDL_Log("   %-27s now =FAIL  %s", names[i], dlerror());
        }
    }
    SDL_Log(" ==== end GL probe ====");
}

/* 把游戏的 SDL 瞄准系统的 GLES 库。Arc 的 SDL 后端从不索要 ES profile（只设 CORE/COMPATIBILITY），
 * 而 SDL 的 OpenHarmony 驱动【只有】在 profile 是 ES 且主版本 > 1 时才加载 libGLESv3.so；本平台只
 * 定义了 DEFAULT_OGL_ES2，所以这些 profile 下什么都不加载，窗口创建报 "Could not initialize
 * OpenGL / GLES library"。SDL_HINT_OPENGL_LIBRARY 在那之前被检查，是唯一不必改 Arc 的杠杆。 */
static void configure_game_sdl(void)
{
    const char *sdlpath = BUNDLE_LIBS "/libSDL3.so";

    /* bundle 里不止一个 libSDL3.so，而两份都是用 -DCMAKE_PLATFORM_NO_VERSIONED_SONAME=1 构建的，
     * 因此都带 SONAME "libSDL3.so" —— 按 SONAME 解析的 loader 返回先加载的那份（这里是启动器
     * 自己的），在另一个映射上设 hint 就会像生效了其实什么都没变。SDL_GetHint 地址相同 = 同一实例。 */
    void *h = dlopen(sdlpath, RTLD_LAZY | RTLD_GLOBAL);
    SDL_Log(" --- configuring SDL ---");
    SDL_Log("   launcher's SDL_GetHint = %p", (void *)(uintptr_t)&SDL_GetHint);
    if (!h) {
        SDL_Log(" !! cannot dlopen %s: %s", sdlpath, dlerror());
    } else {
        void *other = dlsym(h, "SDL_GetHint");
        SDL_Log("   %s", sdlpath);
        SDL_Log("     its SDL_GetHint      = %p  %s", other,
                other == (void *)(uintptr_t)&SDL_GetHint
                    ? "SAME instance as the launcher's"
                    : "DIFFERENT instance");
    }

    /* 两条路都走（直接调用 = 启动器自己的 SDL，句柄路 = 该路径实际解析到的）：两边都设没代价，
     * 免得必须把实例问题答对。priority 2 是 SDL_HINT_OVERRIDE，最高级，之后运行的东西无法无视它。 */
    struct { const char *k, *v; } hints[] = {
        { "SDL_OPENGL_LIBRARY", "/system/lib64/libGLESv3.so" },
        { "SDL_EGL_LIBRARY",    "/system/lib64/libEGL.so"    },
    };
    typedef bool (*set_prio_t)(const char *, const char *, int);
    set_prio_t viaHandle = h ? (set_prio_t)dlsym(h, "SDL_SetHintWithPriority")
                             : NULL;

    for (unsigned i = 0; i < sizeof(hints) / sizeof(hints[0]); i++) {
        /* 是 bool，不是 SDL_bool：SDL3 改名后旧名字展开成刻意未声明的标识符，好让过时代码构建失败。 */
        bool direct = SDL_SetHintWithPriority(hints[i].k, hints[i].v,
                                              SDL_HINT_OVERRIDE);
        bool via = viaHandle ? viaHandle(hints[i].k, hints[i].v, 2) : false;
        SDL_Log("   %-20s = %-30s direct=%s handle=%s -> now reads '%s'",
                hints[i].k, hints[i].v, direct ? "ok" : "REFUSED",
                via ? "ok" : "-", SDL_GetHint(hints[i].k));
    }

    /* 让每个实例去做游戏 SDL 内部会做的那个加载：hint 在两份副本上都设了也读回了，游戏仍报同样
     * 失败 ⇒ hint 在这里不要紧。真正的问题是【这个】实例能不能加载系统 GLES —— 经不同路径加载的
     * 库可能落在不同的 linker 命名空间里，而看不见 /system/lib64 的命名空间会活像一个缺失的文件。 */
    typedef void *(*loadobj_t)(const char *);
    typedef const char *(*geterr_t)(void);
    static const char *GL = "/system/lib64/libGLESv3.so";

    SDL_Log("   launcher's SDL_LoadObject(\"%s\") = %p  err='%s'",
            GL, SDL_LoadObject(GL), SDL_GetError());

    if (h) {
        loadobj_t lo = (loadobj_t)dlsym(h, "SDL_LoadObject");
        geterr_t  ge = (geterr_t)dlsym(h, "SDL_GetError");
        if (lo) {
            void *r = lo(GL);
            SDL_Log("   game's     SDL_LoadObject(\"%s\") = %p  err='%s'",
                    GL, r, ge ? ge() : "?");
        } else {
            SDL_Log("   !! the game's SDL has no SDL_LoadObject");
        }
    }
    SDL_Log(" --- end SDL configuration ---");
}

/* 把 src 拷到 dst，以 mode 0755 创建 dst */
static int copy_exec_file(const char *src, const char *dst)
{
    int in = open(src, O_RDONLY);
    if (in < 0) return -1;
    int out = open(dst, O_WRONLY | O_CREAT | O_TRUNC, 0755);
    if (out < 0) { close(in); return -2; }
    static char buf[65536];
    ssize_t n;
    int rc = 0;
    while ((n = read(in, buf, sizeof(buf))) > 0) {
        ssize_t off = 0;
        while (off < n) {
            ssize_t w = write(out, buf + off, (size_t)(n - off));
            if (w <= 0) { rc = -3; break; }
            off += w;
        }
        if (rc) break;
    }
    if (n < 0) rc = -4;
    close(in);
    close(out);
    return rc;
}

/* 这个进程能不能 dlopen 位于它【自己】可写区里的库？整个 JDK 放置设计系于此，而记录在案的答案
 * （「不能，沙箱不可执行」）只有单个样本 —— 一个可能因自身原因失败的手写 shim；若能，Arc 自己的
 * 解包就能工作、什么都不用特殊处理。Arc 把库放进 java.io.tmpdir：AMCL 下那目录是模块级 files、
 * 游戏能跑，这里它是应用级 temp、加载以 EINVAL 失败（两者都可写，差别只在挂载）。故用两个不同的库
 * 拷进每个候选目录各自 dlopen，bundle 那份作对照。 */
static void probe_sandbox_exec(void)
{
    static const char *srcs[] = {
        BUNDLE_LIBS "/lwjgl/liblwjgl.so",
        BUNDLE_LIBS "/libSDL3.so",
    };
    static const char *names[] = { "liblwjgl.so", "libSDL3.so" };
    static const char *dirs[] = {
        DEST_ROOT,                                    /* 应用级 files   */
        DEST_ROOT "/execprobe",
        TMP_DIR,                                      /* 应用级 temp    */
        TMP_DIR "/execprobe",
        "/data/storage/el2/base/haps/entry/files",    /* 模块级 files，也就是 AMCL 解包到的地方 */
        "/data/storage/el2/base/haps/entry/files/execprobe",
    };
    const unsigned NSRC = sizeof(srcs) / sizeof(srcs[0]);
    const unsigned NDIR = sizeof(dirs) / sizeof(dirs[0]);

    SDL_Log(" ==== dlopen from a writable area? ====");

    SDL_Log(" control: the same libraries, straight out of the bundle");
    for (unsigned s = 0; s < NSRC; s++) {
        void *h = dlopen(srcs[s], RTLD_LAZY);
        SDL_Log("   %-14s %s%s%s", names[s], h ? "OK" : "FAIL",
                h ? "" : " -- ", h ? "" : dlerror());
        if (h) dlclose(h);
    }

    for (unsigned d = 0; d < NDIR; d++) {
        char path[512];
        int made = 0;
        if (mkdir(dirs[d], 0755) == 0) made = 1;
        SDL_Log(" %s%s", dirs[d], made ? "  (created)" : "");
        for (unsigned s = 0; s < NSRC; s++) {
            SDL_snprintf(path, sizeof(path), "%s/probe_%s", dirs[d], names[s]);
            int rc = copy_exec_file(srcs[s], path);
            if (rc != 0) {
                SDL_Log("   %-14s copy failed (%s)", names[s], strerror(errno));
                continue;
            }
            chmod(path, 0755);
            void *h = dlopen(path, RTLD_LAZY);
            SDL_Log("   %-14s %s%s%s", names[s], h ? "OK" : "FAIL",
                    h ? "" : " -- ", h ? "" : dlerror());
            if (h) dlclose(h);
        }
    }
    SDL_Log(" ==== end dlopen probe ====");
}

static void diagnose_loading(void)
{
    char flat_sdl[1400], flat_shim[1400], sub_jvm[1500];

    joinp(flat_sdl,  sizeof(flat_sdl),  g_root, "/libSDL3.so");
    joinp(flat_shim, sizeof(flat_shim), g_root, "/libcxxabi_shim.so");
    joinp(sub_jvm,   sizeof(sub_jvm),   g_root, "/jdk21/lib/server/libjvm_real.so");

    SDL_Log(" ================ load diagnostics ================");
    probe_mode(flat_sdl);
    probe_mode(sub_jvm);
    probe_mode(flat_shim);
    probe_dlopen("control SDL3", flat_sdl);
    probe_dlopen("cxxabi shim", flat_shim);
    probe_dlopen("real JVM", sub_jvm);
    g_exec_probe_result = probe_exec_mem();
    probe_icache();
    SDL_Log(" =================================================");
}

/* 额外的 JVM 选项，运行时从应用自己沙箱里的一个文件读取 —— 试 -XX flag 本要付一整套重建、重签、
 * 重装 171 MB HAP 并重启的代价（每次猜测好几分钟），推一个纯文本文件进去就把循环变成几秒钟。
 * 每行一个选项；空行和以 # 开头的行被忽略。 */
/* 本启动器自己提供多少个选项，在运行时选项文件追加的东西之前。它被用作数组上界和索引基点，共
 * 五处，所以是具名常量：漏掉一处就会悄悄丢掉选项、或读过数组已填充的部分。 */
#define BASE_OPTS 20
#define MAX_EXTRA_OPTS 32
static char g_extra[MAX_EXTRA_OPTS][256];

/* 候选位置，按顺序尝试。这里【曾经】有第三个条目 "/data/local/tmp/jvm.options"，2026-09-22
 * 移除 —— 它不可能工作：文件推到了那里、从 shell 可读，启动器仍报 "no options file found; tried
 * 3 locations"，每次 fopen 都失败（该路径对应用的 uid 不可达），一个永远打不开的条目只会误导。
 * 真正管用的是第二个条目 DEST_ROOT：hdc 能【读】但不能写它，所以是应用写、shell 读。 */
static const char *OPTION_PATHS[] = {
    /* ArkTS 从启动参数写到这里（见 EntryAbility.ets）；context.filesDir 是 ability 自己的 files
     * 目录，【不是】DEST_ROOT。低于 API 26 的手机 JVM 拿不到匿名可执行内存、必须解释执行，故 ArkTS
     * 在此写 -Xint（RELEASE-MAINTENANCE.md 2.12），且每次启动必须【双向重写】，否则手机升过 26 后
     * -Xint 会留下、游戏永久以解释模式跑。⚠️ probe_exec_mem() 不可用时启动器也强制 -Xint（覆盖
     * API 26 商店签名机与无 ACL 平板）：文件是请求，探测才是权威。 */
    "/data/storage/el2/base/haps/entry/files/jvm.options",
    DEST_ROOT "/jvm.options",
};

static const char *open_options_file(void)
{
    for (unsigned i = 0; i < sizeof(OPTION_PATHS) / sizeof(OPTION_PATHS[0]); i++) {
        FILE *f = fopen(OPTION_PATHS[i], "r");
        if (f) { fclose(f); return OPTION_PATHS[i]; }
    }
    return NULL;
}

/* 任何一个候选选项文件里含有这个标记吗？（非 static：main 里要用） */
int options_contain(const char *needle)
{
    for (unsigned i = 0; i < sizeof(OPTION_PATHS) / sizeof(OPTION_PATHS[0]); i++) {
        FILE *f = fopen(OPTION_PATHS[i], "r");
        if (!f) continue;
        char line[256];
        while (fgets(line, sizeof(line), f)) {
            if (strstr(line, needle)) { fclose(f); return 1; }
        }
        fclose(f);
    }
    return 0;
}

static int load_extra_options(JavaVMOption *out, int base)
{
    const char *path = open_options_file();
    if (!path) {
        SDL_Log(" (no options file found; tried %d locations)",
                (int)(sizeof(OPTION_PATHS) / sizeof(OPTION_PATHS[0])));
        return 0;
    }
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    int n = 0;
    char line[256];
    while (n < MAX_EXTRA_OPTS && fgets(line, sizeof(line), f)) {
        size_t L = SDL_strlen(line);
        while (L && (line[L - 1] == '\n' || line[L - 1] == '\r'
                     || line[L - 1] == ' ' || line[L - 1] == '\t')) {
            line[--L] = '\0';
        }
        if (L == 0 || line[0] == '#') continue;
        SDL_strlcpy(g_extra[n], line, sizeof(g_extra[n]));
        out[base + n].optionString = g_extra[n];
        out[base + n].extraInfo = NULL;
        n++;
    }
    fclose(f);
    SDL_Log(" read %d extra option(s) from %s", n, path);
    return n;
}

/* 这个进程能不能【运行】它生成进匿名内存里的代码？这正是整个 ACL 绕行所围绕的能力
 * （ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY）：HotSpot 把 stub/trampoline 写进匿名
 * RWX 内存再跳进去，页并非真可执行或写入对取指不可见都会陷入陷阱、出错地址不在任何模块里
 * （dladdr 报 "in ?"，正是 JNI_CreateJavaVM 里那次 SIGILL 的样子）。直接测：写两指令函数、调，预期 42。 */
static long probe_exec_mem(void)
{
    /* mov w0, #42 ; ret */
    static const unsigned int code[2] = { 0x52800540u, 0xd65f03c0u };

    void *p = mmap(NULL, 4096, PROT_READ | PROT_WRITE | PROT_EXEC,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) {
        SDL_Log(" !! mmap(RWX) FAILED: errno=%d (%s)", errno, strerror(errno));
        return -1;
    }
    SDL_memcpy(p, code, sizeof(code));
    __builtin___clear_cache((char *)p, (char *)p + sizeof(code));

    long (*fn)(void) = (long (*)(void))p;
    long r = fn();

    SDL_Log(" executable anon memory: mmap=%p call->%ld  %s",
            p, r, (r == 42) ? "WORKS" : "WRONG RESULT");
    return r;
}

/* 自修改代码：对【已经可执行】的页做一次写入会生效吗？HarmonyOS 封锁「来自文件的代码」（把文件
 * 或 memfd 映射为可执行，实测都是 errno=13），却允许匿名可执行内存，而 HotSpot 生成的代码全在
 * 匿名内存里。要紧的是：HotSpot 的 code cache 同时可写可执行且【就地】打补丁、不做 mprotect
 * 往返 —— ARM 上数据/指令缓存不一致，写入需显式维护才可见，否则 CPU 跑旧字节。测量 1/2/3/4，
 * 第 3 步（flush 后写入）决定性；第 2 步不构成缺陷（多数 ARMv8 核上不做维护本就合法不可见）。 */
/* 每个测试用例都在它【自己】全新的页上（共用一页正是弄坏上一版的原因：用例 4 把页留在 RX 上，
 * 用例 5 的 memcpy 在自己的 mprotect 之前就出错，那个 SIGSEGV 看起来像平台发现、其实是测试 bug）。
 * mode：0 写+clear_cache+调 / 1 写+不维护+调 / 2 写+mprotect RW->RX+调 / 3 写+mprotect+clear_cache+调
 * / 4 写+clear_cache+mprotect+调 / 5 写+clear_cache+调+再调（稳定性）。 */
static long icache_case(int expect, int mode)
{
    unsigned int code[2] = { 0x52800000u | ((unsigned)expect << 5), 0xd65f03c0u };
    /* movz w0, #expect ; ret   —— 立即数位于 bit 20:5 */

    void *p = mmap(NULL, 4096, PROT_READ | PROT_WRITE | PROT_EXEC,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) { SDL_Log("    mmap failed errno=%d", errno); return -1; }

    long r = -1;
    /* 每一次写入都发生在页仍是 RWX、或者已被改成 RW 的时候 */
    SDL_memcpy(p, code, 8);

    long (*fn)(void) = (long (*)(void))p;
    switch (mode) {
    case 0:
        __builtin___clear_cache((char *)p, (char *)p + 8);
        r = fn();
        break;
    case 1:
        r = fn();
        break;
    case 2:
        mprotect(p, 4096, PROT_READ | PROT_WRITE);
        mprotect(p, 4096, PROT_READ | PROT_EXEC);
        r = fn();
        break;
    case 3:
        mprotect(p, 4096, PROT_READ | PROT_WRITE);
        mprotect(p, 4096, PROT_READ | PROT_EXEC);
        __builtin___clear_cache((char *)p, (char *)p + 8);
        r = fn();
        break;
    case 4:
        __builtin___clear_cache((char *)p, (char *)p + 8);
        mprotect(p, 4096, PROT_READ | PROT_WRITE);
        mprotect(p, 4096, PROT_READ | PROT_EXEC);
        r = fn();
        break;
    case 5: {
        __builtin___clear_cache((char *)p, (char *)p + 8);
        long a = fn();
        long b = fn();
        long c = fn();
        r = (a == b && b == c) ? a : -100 - (int)a;   /* 把不稳定性编码进去 */
        break;
    }
    }
    munmap(p, 4096);
    return r;
}

/* 覆盖【已经执行过】的代码 —— 这才是要紧的场景，上一版弄丢了它（给每个用例一个从未执行过的页，
 * 于是全都通过、假设因错误的原因显得死了）。HotSpot 做的正是这件事：生成代码、运行，之后回过头去
 * 【给】同样的指令打补丁。每个用例：写 v1 -> 可见 -> 【调用】（填上取指单元）-> 写 v2 -> 施加被测
 * 机制 -> 再调用，报告【第二次】结果（正确 v2，v1 = 保留旧指令）。mode：0 不做事 / 1 clear_cache
 * （对照）/ 2 mprotect RW->RX / 3 mprotect 后 clear_cache / 4 反之。 */
static long icache_rewrite_case(int v1, int v2, int mode)
{
    unsigned int c1[2] = { 0x52800000u | ((unsigned)v1 << 5), 0xd65f03c0u };
    unsigned int c2[2] = { 0x52800000u | ((unsigned)v2 << 5), 0xd65f03c0u };

    void *p = mmap(NULL, 4096, PROT_READ | PROT_WRITE | PROT_EXEC,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) return -1;
    long (*fn)(void) = (long (*)(void))p;

    /* 阶段 1：装入 v1 并【运行】它，于是取指单元现在持有 v1 */
    SDL_memcpy(p, c1, 8);
    __builtin___clear_cache((char *)p, (char *)p + 8);
    long first = fn();
    if (first != v1) {
        SDL_Log("    (setup failed: wrote %d, got %ld)", v1, first);
        munmap(p, 4096);
        return -1000;
    }

    /* 阶段 2：用被测机制覆盖成 v2 */
    SDL_memcpy(p, c2, 8);
    switch (mode) {
    case 0: break;
    case 1: __builtin___clear_cache((char *)p, (char *)p + 8); break;
    case 2: mprotect(p, 4096, PROT_READ | PROT_WRITE);
            mprotect(p, 4096, PROT_READ | PROT_EXEC); break;
    case 3: mprotect(p, 4096, PROT_READ | PROT_WRITE);
            mprotect(p, 4096, PROT_READ | PROT_EXEC);
            __builtin___clear_cache((char *)p, (char *)p + 8); break;
    case 4: __builtin___clear_cache((char *)p, (char *)p + 8);
            mprotect(p, 4096, PROT_READ | PROT_WRITE);
            mprotect(p, 4096, PROT_READ | PROT_EXEC); break;
    }

    long second = fn();
    munmap(p, 4096);
    return second;
}

static void probe_icache(void)
{
    SDL_Log(" ==== self-modifying code probe (rewrite after execution) ====");
    SDL_Log(" each case: write 11, run it, then overwrite with 22 and run again");
    SDL_Log(" correct result is 22; 11 means the CPU kept the OLD instruction");

    struct { int mode; const char *what; } cases[] = {
        { 1, "clear_cache                        (CONTROL)" },
        { 0, "nothing at all" },
        { 2, "mprotect RW->RX" },
        { 3, "mprotect RW->RX, then clear_cache" },
        { 4, "clear_cache, then mprotect RW->RX" },
    };

    for (unsigned i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        long got = icache_rewrite_case(11, 22, cases[i].mode);
        const char *verdict;
        if (got == -1000)      verdict = "setUp failed";
        else if (got == 22)    verdict = "ok      (new code visible)";
        else if (got == 11)    verdict = "STALE   (old code still executed)";
        else                   verdict = "unexpected";
        SDL_Log("  [%d] %-38s -> %ld   %s", cases[i].mode, cases[i].what, got, verdict);
    }

    SDL_Log(" ---- how to read this ----");
    SDL_Log("   [1] must be ok, otherwise nothing else here is meaningful");
    SDL_Log("   [0] stale is EXPECTED on ARM and is not a defect");
    SDL_Log("   [2] stale -> mprotect alone does not publish a rewrite");
    SDL_Log("   [3] ok    -> flushing after mprotect repairs it");
    SDL_Log("   [4] stale -> mprotect after a flush discards the flush");
    SDL_Log(" ============================================================");
}

/* 哪个映射（如果有）包含这个地址？刻意做成 async-signal-unsafe 的：我们已经在垂死，答案比规则更重要。 */
static void report_mapping(unsigned long addr, char *out, size_t cap)
{
    FILE *f = fopen("/proc/self/maps", "r");
    out[0] = '\0';
    if (!f) { SDL_snprintf(out, cap, "(no /proc/self/maps)"); return; }
    char line[512];
    while (fgets(line, sizeof(line), f)) {
        unsigned long lo = 0, hi = 0;
        if (sscanf(line, "%lx-%lx", &lo, &hi) == 2 && addr >= lo && addr < hi) {
            char *nl = strchr(line, '\n');
            if (nl) *nl = '\0';
            SDL_snprintf(out, cap, "%s", line);
            break;
        }
    }
    if (!out[0]) SDL_snprintf(out, cap, "(address is in NO mapping)");
    fclose(f);
}

/* 大声说出这些分发的文件里究竟哪些真的到了。hvigor 会无声地丢掉 entry/libs/** 下任何名字不以
 * ".so" 结尾的东西（JDK 的 conf/ 目录就是这么消失的，也是游戏 jar 和 LWJGL jars 改名的原因），
 * 一个缺失的文件否则会在很久之后表现为令人困惑的类加载或 dlopen 错误 —— 所以每个文件一行 + 尺寸。 */
/* 临时诊断 —— 窗口问题定下来后就移除。往【同一个】文件写标记，那文件也正是被插桩的 SDL 写它
 * XComponent surface 事件的地方，于是两条时间线能在一处读。问的是【顺序】：surface 回调启动我们
 * 之后过了几秒，游戏要窗口时那个 surface 是否还在 —— 两份分开的日志回答不了。 */
static void probe_mark(const char *what)
{
    FILE *f = fopen(DEST_ROOT "/sdl_surface.log", "a");
    if (f) {
        fprintf(f, "=== APP %s ===\n", what);
        fclose(f);
    }
}

/* 这个进程能不能访问网络？做 native 探测而不只看游戏：游戏已报 "SocketException: Operation not
 * permitted"（sun.nio.ch.Net.socket0），说明 socket() 可达且被拒 —— 但 ArcNet 全是 NIO
 * （Selector.open()、SocketChannel、DatagramChannel），能开 socket 却开不了 selector 的 JVM 跑不了
 * 服务器与客户端事件循环，差别是一周工作还是重写 37 个类。每次调用用它自己的 errno 报告；⚠️
 * 名字/连接两步经 DEST_ROOT/netprobe 选择加入 —— 它在 JNI_CreateJavaVM 之前跑、解析可能阻塞数秒。 */
static void probe_network(void)
{
    SDL_Log(" --- network syscalls ---");

    int tcp = socket(AF_INET, SOCK_STREAM, 0);
    SDL_Log("   socket(AF_INET, SOCK_STREAM) : %s",
            tcp >= 0 ? "OK" : "FAILED");
    if (tcp < 0) SDL_Log("        errno=%d (%s)", errno, strerror(errno));

    int udp = socket(AF_INET, SOCK_DGRAM, 0);
    SDL_Log("   socket(AF_INET, SOCK_DGRAM)  : %s",
            udp >= 0 ? "OK" : "FAILED");
    if (udp < 0) SDL_Log("        errno=%d (%s)", errno, strerror(errno));

    /* EPollSelectorImpl 架在这个之上。没有它 Selector.open() 会失败，每次 ArcNet 连接也会失败，
     * 包括那些已经有可用 socket 的。 */
    int ep = epoll_create1(0);
    SDL_Log("   epoll_create1(0)             : %s",
            ep >= 0 ? "OK" : "FAILED");
    if (ep < 0) SDL_Log("        errno=%d (%s)", errno, strerror(errno));

    /* Selector 唤醒。无法被唤醒的 selector，就是无法从另一个线程被注册的 selector。 */
    int ev = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
    SDL_Log("   eventfd(0, NONBLOCK|CLOEXEC) : %s",
            ev >= 0 ? "OK" : "FAILED");
    if (ev < 0) SDL_Log("        errno=%d (%s)", errno, strerror(errno));

    /* 名字解析分两步，因为「无法解析」与「无法到达」是不同的问题、有不同的修法，合并的测试区分
     * 不开。数字查找根本不需要 resolver：成功 ⇒ resolver 完好、只有名字查找在失败；同样失败 ⇒
     * 调用本身被封锁。 */
    struct addrinfo hints;
    struct addrinfo *res = NULL;

    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_NUMERICHOST;
    int num = getaddrinfo("20.205.243.166", "443", &hints, &res);
    SDL_Log("   getaddrinfo(<literal ip>)   : %s", num == 0 ? "OK" : "FAILED");
    if (num != 0) SDL_Log("        %s (EAI code %d)", gai_strerror(num), num);
    if (res) freeaddrinfo(res);
    res = NULL;

    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;

    /* 从【这个】进程读 resolver 自己的配置。它从 hdc shell 里可读（先是 114.114.114.114 然后是
     * 8.8.8.8），但 shell 与应用是不同的安全上下文，而问题正是【这个】进程能不能解析名字 —— 从
     * shell 测量再当作应用的答案，正是本项目在 bundle 路径的 `stat` 那里已记录在案的错误。 */
    {
        FILE *rc = fopen("/etc/resolv.conf", "r");
        if (!rc) {
            SDL_Log("   /etc/resolv.conf            : NOT READABLE (errno=%d %s)",
                    errno, strerror(errno));
        } else {
            char line[256];
            int shown = 0;
            SDL_Log("   /etc/resolv.conf            : readable");
            while (fgets(line, sizeof(line), rc) && shown < 4) {
                if (strncmp(line, "nameserver", 10) == 0) {
                    line[strcspn(line, "\r\n")] = '\0';
                    SDL_Log("        %s", line);
                    shown++;
                }
            }
            if (shown == 0) SDL_Log("        (no nameserver lines)");
            fclose(rc);
        }
    }

    /* ⚠️ 下面的网络 I/O 是选择加入的：上面每一样都是本地内核操作、立即返回，而 getaddrinfo 按
     * 顺序问 /etc/resolv.conf 里的 nameserver，第一个不可达时会卡到超时才试下一个。本函数在
     * JNI_CreateJavaVM【之前】跑，这里花的每一毫秒都是玩家盯着黑窗口的毫秒（实测手机上报黑屏、
     * 过了一段明显时间才开始加载，同样的构建在平板上没事）。所以可能阻塞的检查只在
     * hdc shell "touch /data/storage/el2/base/files/netprobe" 之后才跑。 */
    if (access(DEST_ROOT "/netprobe", F_OK) != 0) {
        SDL_Log("   (name resolution and connect skipped -- create %s to enable)",
                DEST_ROOT "/netprobe");
        goto done;
    }

    int gai = getaddrinfo("github.com", "443", &hints, &res);
    SDL_Log("   getaddrinfo(github.com:443) : %s", gai == 0 ? "OK" : "FAILED");
    if (gai != 0) SDL_Log("        %s (EAI code %d)", gai_strerror(gai), gai);
    if (res) freeaddrinfo(res);

    /* 可达性通过解析一个名字、再连接它返回的东西来测。刻意【不是】硬编码地址：早先那版连一个几
     * 分钟前采样的字面 IP 恰好只灵一次（地址会变，因数字过期而失败的探测比没有还糟）；先解析也正是
     * Java 所做的。失败不自动等于沙箱问题：上面的 getaddrinfo 与这里的 connect 只把「无法解析」与
     * 「无法到达」分开，而一台没有路由的设备两者都失败 —— 真正区分的是 errno，socket() 上的 EPERM
     * 或 EACCES 才意味着被策略拒绝。只解析【一次】（早先那版解析两遍，白白让最慢一步的代价翻倍）。 */
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    res = NULL;
    if (getaddrinfo("github.com", "443", &hints, &res) == 0 && res != NULL) {
        int s = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
        if (s < 0) {
            SDL_Log("   connect(github.com:443)     : socket failed");
            SDL_Log("        errno=%d (%s)", errno, strerror(errno));
        } else {
            int rc = connect(s, res->ai_addr, (socklen_t)res->ai_addrlen);
            SDL_Log("   connect(github.com:443)     : %s", rc == 0 ? "OK" : "failed");
            if (rc != 0) SDL_Log("        errno=%d (%s)", errno, strerror(errno));
            close(s);
        }
    } else {
        SDL_Log("   connect(github.com:443)     : skipped, nothing resolved");
    }
    if (res) freeaddrinfo(res);

done:
    if (tcp >= 0) close(tcp);
    if (udp >= 0) close(udp);
    if (ep  >= 0) close(ep);
    if (ev  >= 0) close(ev);
    SDL_Log(" --- end network syscalls ---");
}

/* 曾试图让 SDL 导出一个诊断 getter 供启动器调用，但没链接上 —— SDL 的构建把导出限制在它自己的
 * 符号清单里，visibility("default") 不足以加一个进去。surface 拷贝的问题改从 SDL 自己的日志回答；
 * 见 SDL_openharmonyvideo.c。 */

static void report_shipped_files(void)
{
    static const char *paths[] = {
        GAME_JAR,
        LWJGL_LIBS "/liblwjgl.so",
        LWJGL_LIBS "/liblwjgl_opengl.so",
        BUNDLE_LIBS "/libSDL3.so",
        LWJGL_JARS "/lwjgl.so",
        LWJGL_JARS "/lwjgl-opengl.so",
        LWJGL_JARS "/lwjgl-sdl.so",
    };
    SDL_Log(" --- shipped files ---");
    for (unsigned i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
        /* 用 stat() 而不是 fopen()：为了回答「它在不在」去打开一个 87 MB 的 jar 未免荒唐，
         * 而这是 loader 所做的同一个调用。 */
        struct stat st;
        if (stat(paths[i], &st) == 0) {
            SDL_Log("   %9ld  %s", (long)st.st_size, paths[i]);
        } else {
            SDL_Log("   MISSING            %s", paths[i]);
        }
    }
    SDL_Log(" --- end shipped files ---");
}

/* 把一个所分发的文件放到 java.home 预期找到它的地方，只做一次。以临时名字写入、再改名就位：
 * 中途被打断的拷贝否则会留下一个能通过存在性检查、却在 JVM 内部失败的文件。尺寸就是「它是否已经
 * 在那里」的整个测试 —— 一个尺寸正确的文件之所以能在场，唯一的方式就是一次已完成的改名。 */
static int materialise(const char *src, const char *dst)
{
    struct stat sb;
    if (stat(src, &sb) != 0) {
        SDL_Log(" !! not shipped: %s (%s)", src, strerror(errno));
        return 1;
    }

    struct stat sd;
    if (stat(dst, &sd) == 0 && sd.st_size == sb.st_size) {
        SDL_Log("   %-46s already in place (%lld bytes)",
                dst, (long long)sd.st_size);
        return 0;
    }

    SDL_Log("   %-46s materialising %lld bytes", dst, (long long)sb.st_size);

    char tmp[512];
    SDL_snprintf(tmp, sizeof(tmp), "%s.part", dst);

    int in = open(src, O_RDONLY);
    if (in < 0) {
        SDL_Log(" !! open %s: %s", src, strerror(errno));
        return 2;
    }
    int out = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (out < 0) {
        SDL_Log(" !! create %s: %s", tmp, strerror(errno));
        close(in);
        return 3;
    }

    static char buf[1 << 20];
    long long total = 0;
    int rc = 0;
    for (;;) {
        ssize_t n = read(in, buf, sizeof(buf));
        if (n == 0) break;
        if (n < 0) { SDL_Log(" !! read: %s", strerror(errno)); rc = 4; break; }
        ssize_t off = 0;
        while (off < n) {
            ssize_t w = write(out, buf + off, (size_t)(n - off));
            if (w <= 0) { SDL_Log(" !! write: %s", strerror(errno)); rc = 5; break; }
            off += w;
        }
        if (rc) break;
        total += n;
    }
    fsync(out);
    close(out);
    close(in);

    if (!rc && total != sb.st_size) {
        SDL_Log(" !! short copy: %lld of %lld", total, (long long)sb.st_size);
        rc = 6;
    }
    if (rc) {
        unlink(tmp);
        return rc;
    }
    /* rename() 是提交点 —— 见上面的说明。 */
    if (rename(tmp, dst) != 0) {
        SDL_Log(" !! rename %s: %s", tmp, strerror(errno));
        unlink(tmp);
        return 7;
    }
    return 0;
}

/* 把一棵所分发的目录树拷进沙箱，从每个文件名上剥掉一个结尾的 ".so"（为什么带 .so 见
 * scripts/prep_jdkconf.py：hvigor 会搬走 libs/ 里的 *.so、别的一言不发丢掉，实测）。
 * 刻意递归：替代方案是一份所需文件的清单，而那份清单在对的时候完全正确直到它不对 —— 有过两次，
 * 第二次就是这一次。尺寸正确的既有文件被 materialise() 放过，所以从第二次启动起很便宜。 */
static int copy_tree_strip_so(const char *src, const char *dst)
{
    DIR *d = opendir(src);
    if (!d) {
        SDL_Log(" !! opendir %s: %s", src, strerror(errno));
        return 1;
    }
    if (mkdir(dst, 0755) != 0 && errno != EEXIST) {
        SDL_Log(" !! mkdir %s: %s", dst, strerror(errno));
        closedir(d);
        return 2;
    }

    int rc = 0;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) continue;

        char s[1400], t[1400];
        SDL_snprintf(s, sizeof(s), "%s/%s", src, e->d_name);

        struct stat sb;
        if (stat(s, &sb) != 0) {
            SDL_Log(" !! stat %s: %s", s, strerror(errno));
            rc = 3;
            continue;
        }

        if (S_ISDIR(sb.st_mode)) {
            SDL_snprintf(t, sizeof(t), "%s/%s", dst, e->d_name);
            if (copy_tree_strip_so(s, t) != 0) rc = 4;
            continue;
        }

        /* 恰好剥一个结尾的 ".so" —— 就是 hvigor 需要看到的那个。真正以 .so 结尾的源名字会被作为
         * .so.so 分发、原封不动地出来，所以剥离永远是对称的。 */
        size_t n = strlen(e->d_name);
        size_t keep = (n > 3 && strcmp(e->d_name + n - 3, ".so") == 0) ? n - 3 : n;
        if (keep == 0) continue;

        char base[600];
        if (keep >= sizeof(base)) {
            SDL_Log(" !! name too long: %s", e->d_name);
            rc = 5;
            continue;
        }
        memcpy(base, e->d_name, keep);
        base[keep] = '\0';

        SDL_snprintf(t, sizeof(t), "%s/%s", dst, base);
        if (materialise(s, t) != 0) rc = 6;
    }
    closedir(d);
    return rc;
}

/* 构建 java.home 将被指向的那个目录。镜像与时区库必须以 java.base 所要找的名字待在那里：
 * lib/modules 是 module image，以 jimg.so 分发（patch_libjvm.py，hvigor 只搬 .so，而 java.base
 * 自己拼出 "modules"）；lib/tzdb.dat 以 tzdb.so 分发（prep_jdklib.py），缺失时不只是破坏时间戳 ——
 * ZoneInfoFile 初始化失败，程序里第一次请求 DateFormat 就抛异常（Saves.<clinit> 就会）。
 * 返回值只意味着 lib/modules 是否到位（它才决定 java.home 能否被重定向）；其余大声报告但不改返回值。 */
static int prepare_java_home(void)
{
    if (mkdir(DEST_ROOT "/jdk", 0755) != 0 && errno != EEXIST) {
        SDL_Log(" !! mkdir %s failed: %s", SANDBOX_JDK, strerror(errno));
        return 1;
    }
    if (mkdir(SANDBOX_JDK "/lib", 0755) != 0 && errno != EEXIST) {
        SDL_Log(" !! mkdir %s/lib failed: %s", SANDBOX_JDK, strerror(errno));
        return 2;
    }
    if (materialise(MODULE_IMAGE, SANDBOX_MODULES) != 0) return 3;
    if (materialise(TZDB_IMAGE,   SANDBOX_TZDB)    != 0) return 4;

    SDL_Log(" java.home tree, from %s:", JDK_HOME_TREE);
    if (copy_tree_strip_so(JDK_HOME_TREE, SANDBOX_JDK) != 0) {
        SDL_Log(" !! the java.home tree did not copy completely");
        SDL_Log(" !! run scripts/prep_jdkconf.py, then rebuild");
        SDL_Log(" !! without conf/security/java.security no class can be");
        SDL_Log(" !! defined at runtime -- mod loading dies inside defineClass");
    }
    return 0;
}

/* 从 VM 内部重写 java.home，在任何东西读它之前。HotSpot 推导出的值指向 bundle，而那里的 module
 * image 叫 jimg.so，java.base 却坚持要 "modules"。窗口真实且很宽 —— ImageReaderFactory 惰性初始化，
 * 第一个碰它的是游戏自己的资源查找 —— 所以在 VM 存在之后立刻做来得及，更晚就来不及。 */
static void override_java_home(JNIEnv *env)
{
    jclass syscls = (*env)->FindClass(env, "java/lang/System");
    if (!syscls) { SDL_Log(" !! cannot reach java/lang/System"); return; }

    jmethodID setp = (*env)->GetStaticMethodID(env, syscls, "setProperty",
                          "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;");
    if (!setp) { SDL_Log(" !! no System.setProperty"); return; }

    jstring k = (*env)->NewStringUTF(env, "java.home");
    jstring v = (*env)->NewStringUTF(env, SANDBOX_JDK);
    jstring old = (jstring)(*env)->CallStaticObjectMethod(env, syscls, setp, k, v);

    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
        SDL_Log(" !! java.home could not be rewritten");
        return;
    }
    SDL_Log(" java.home rewritten to %s", SANDBOX_JDK);
    if (old) {
        const char *cs = (*env)->GetStringUTFChars(env, old, NULL);
        if (cs) {
            SDL_Log("   (HotSpot had derived %s)", cs);
            (*env)->ReleaseStringUTFChars(env, old, cs);
        }
    }
}

/* 从 bundle 加载 Arc 的 natives 并标记为已加载，好让 Arc 自己的 loader 无事可做（为什么不能按
 * Arc 打算的方式加载，见 ARC_LIBS）。设计上尽力而为：加载不了的会被报告并跳过而不是中止启动，
 * 因为游戏自己针对缺失 native 的错误会点名库和调用者，比在这里失败更有用。绝不能发生半状态 ——
 * 所以只有 System.load 真的无异常返回【之后】才标记为已加载。 */
static void preload_arc_natives(JNIEnv *env)
{
    static const char *keys[]  = { "arc", "arc-freetype", "arc-filedialogs" };
    static const char *files[] = { "libarcarm64.so",
                                   "libarc-freetypearm64.so",
                                   "libarc-filedialogsarm64.so" };
    const unsigned N = sizeof(keys) / sizeof(keys[0]);

    /* 一切都走我们自己的类而不是直接 System.load：从这里调用会把库注册到错误的类加载器上，游戏
     * 随后找不到它的 native 方法，即使那次加载报告成功 —— 见 NativeLoader.java。 */
    jclass helper = (*env)->FindClass(env, "com/haohandc/launcher/NativeLoader");
    if (!helper) {
        SDL_Log(" !! com.haohandc.launcher.NativeLoader is not on the classpath");
        if ((*env)->ExceptionCheck(env)) (*env)->ExceptionDescribe(env);
        if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
        return;
    }
    jmethodID loadm = (*env)->GetStaticMethodID(env, helper, "load",
                            "(Ljava/lang/String;)V");
    jmethodID markm = (*env)->GetStaticMethodID(env, helper, "markLoaded",
                            "(Ljava/lang/String;)V");
    if (!loadm || !markm) {
        SDL_Log(" !! NativeLoader does not have the methods this expects");
        return;
    }

    SDL_Log(" --- Arc natives, preloaded from the bundle ---");
    for (unsigned i = 0; i < N; i++) {
        char path[512];
        SDL_snprintf(path, sizeof(path), ARC_LIBS "/%s", files[i]);

        struct stat st;
        if (stat(path, &st) != 0) {
            SDL_Log("   %-30s not shipped, skipping", files[i]);
            continue;
        }

        (*env)->CallStaticVoidMethod(env, helper, loadm,
                                     (*env)->NewStringUTF(env, path));
        if ((*env)->ExceptionCheck(env)) {
            SDL_Log("   %-30s LOAD FAILED", files[i]);
            (*env)->ExceptionDescribe(env);
            (*env)->ExceptionClear(env);
            continue;                    /* 刻意不标记 */
        }

        (*env)->CallStaticVoidMethod(env, helper, markm,
                                     (*env)->NewStringUTF(env, keys[i]));
        if ((*env)->ExceptionCheck(env)) {
            SDL_Log("   %-30s loaded, but could not be marked", files[i]);
            (*env)->ExceptionDescribe(env);
            (*env)->ExceptionClear(env);
            continue;
        }
        SDL_Log("   %-30s loaded and marked as \"%s\"", files[i], keys[i]);
    }
    SDL_Log(" --- end Arc natives ---");
}

/* 蓝图第 4 步：以反射方式调用游戏的入口点。通过条件是【游戏自己的】代码运行了（可观测为它自己
 * 在 stdout 上的输出）—— 窗口明确【不】属于这一步（那是第 5 步），所以 main() 开始之后的一次 SDL
 * 或 GL 失败仍算「它启动了」，作为独立结果报告。入口点经 JNI 调用而不是把 main class 交给启动器，
 * 因为没有启动器：这个就是。调用发生在 SDL 为 SDL_main 创建的那个线程上并阻塞到游戏返回（有意：
 * 游戏的 main() 跑自己的循环，退出时才返回）。 */
static int launch_game(JNIEnv *env)
{
    static const char *MAIN_CLASS = "mindustry/desktop/DesktopLauncher";
    static const char *MAIN_DESC  = "([Ljava/lang/String;)V";

    SDL_Log(" --- step 4: launching the game ---");

    SDL_Log(" classpath: %s", game_jar_path);

    jclass cls = (*env)->FindClass(env, MAIN_CLASS);
    if (!cls) {
        SDL_Log(" !! %s is NOT on the classpath", MAIN_CLASS);
        if ((*env)->ExceptionCheck(env)) (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
        return 1;
    }
    SDL_Log("   -> class found");

    jmethodID mid = (*env)->GetStaticMethodID(env, cls, "main", MAIN_DESC);
    if (!mid) {
        SDL_Log(" !! the class has no main([Ljava/lang/String;)V");
        if ((*env)->ExceptionCheck(env)) (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
        return 2;
    }

    /* 一个空的 String[] —— 游戏自己提供它的默认值 */
    jclass strcls = (*env)->FindClass(env, "java/lang/String");
    jobjectArray argv = (*env)->NewObjectArray(env, 0, strcls, NULL);
    if (!argv) {
        SDL_Log(" !! could not build the argument array");
        return 3;
    }

    /* 到这里游戏的入口方法确实存在 —— 那个 jar 是个能跑的游戏，故清掉「正在尝试启动」的标记
     * （见 LAUNCH_PENDING_FILE）。⚠️ 位置是重点，必须在【拿到 main 之后、调用它之前】：上面三个
     * 失败路径（主类不在 classpath / 类里没有 main / 参数数组建不出来）各自 return，全都意味着
     * 「这个 jar 不是游戏」，标记必须留着；而走到这里之后任何失败都不再是「选错了 jar」。 */
    unlink(LAUNCH_PENDING_FILE);

    SDL_Log("   -> calling %s.main(new String[0]) ...", MAIN_CLASS);
    (*env)->CallStaticVoidMethod(env, cls, mid, argv);

    /* 走到这一行意味着 main() 返回了：要么干净退出，要么是启动内部的一次失败。此处仍有未决异常
     * 能把两者区分开，所以报出来而不是两边都靠猜。 */
    if ((*env)->ExceptionCheck(env)) {
        SDL_Log(" !! the game threw while starting up:");
        (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
        return 4;
    }
    SDL_Log("   -> main() returned normally");
    SDL_Log(" *** STEP 4 OK: the game entry point ran ***");
    return 0;
}

static int start_jvm(void)
{
    probe_rawfile();
    report_shipped_files();

    /* 在其它一切之前把「加载哪一个」定下来 —— 下面的 classpath 要的正是这个结果。
     * ⚠️ 没有游戏就【不创建 VM】。正常走不到这里（ArkTS 在挂载 XComponent 之前就拦住，而没有
     * XComponent 就没有 libmain.so、没有 main()），这是纵深防御：`aa start` 之类绕过界面的路径
     * 宁可在这里明确失败、留下能查的日志，也不要起一个没有游戏可跑、却白占内存和表面的 VM。 */
    if (!resolve_game_jar()) {
        SDL_Log(" !! no game jar: none was chosen in the launcher, and the package has no copy");
        SDL_Log("    bundle slot: %s", GAME_JAR);
        SDL_Log("    refusing to create the JVM -- there would be nothing to run");
        return 5;
    }

    probe_gl_libs();
    probe_sandbox_exec();
    probe_user_dirs();
    probe_network();
    int modok = prepare_java_home();
    diagnose_loading();
    load_anchor_only();

    char libjvm[1400];
    SDL_snprintf(libjvm, sizeof(libjvm), "%s", g_anchor);

    /* 刻意用 RTLD_LAZY，不是 RTLD_NOW 失败后的回退：libjvm.so 把 __cxa_thread_atexit 声明为【强】
     * 未定义符号（GLOBAL 不是 WEAK），本平台【没有任何东西】提供它（JDK 的 shim 与 OHOS libc 都不
     * 导出），故 RTLD_NOW 永不可能成功；懒绑定首次调用才解析。AMCL 跑着同一个 libjvm.so 也必如此。 */
    SDL_Log(" dlopen(%s)", libjvm);
    void *h = dlopen(libjvm, RTLD_LAZY | RTLD_GLOBAL);
    if (!h) {
        SDL_Log(" !! RTLD_LAZY failed: %s", dlerror());
        SDL_Log("    retrying with RTLD_NOW (would need every symbol present) ...");
        h = dlopen(libjvm, RTLD_NOW | RTLD_GLOBAL);
        if (!h) SDL_Log("    RTLD_NOW also failed: %s", dlerror());
    }
    if (!h) return 1;
    SDL_Log("   -> handle = %p", h);

    CreateJavaVM_t create = (CreateJavaVM_t)dlsym(h, "JNI_CreateJavaVM");
    if (!create) {
        SDL_Log(" !! JNI_CreateJavaVM not found: %s", dlerror());
        return 2;
    }
    SDL_Log("   -> JNI_CreateJavaVM = %p", (void *)create);

    /* 补丁 jar 必须在且必须是能打开的 jar。⚠️ 值得【中止启动】：少了它，游戏 jar 里那份上游 SDL2
     * 后端就会生效，而它在本平台加载不了自己的 libSDL2，失败长相与「补丁 jar 丢了」毫无相似之处，
     * 排查会从错误方向开始。半状态绝不接受：宁可不起，也不要起一个「少了我们一半改动」的应用。 */
    {
        struct stat st_patch;
        if (stat(PATCH_JAR, &st_patch) != 0) {
            SDL_Log(" !! the Arc patch jar is NOT SHIPPED: %s", PATCH_JAR);
            SDL_Log("    the game jar alone would run upstream's SDL2 backend, which cannot");
            SDL_Log("    load its own libSDL2 here -- refusing to start rather than fail vaguely.");
            SDL_Log("    build it with: python scripts/make_patch_jar.py");
            return 3;
        }
        FILE *f_patch = fopen(PATCH_JAR, "rb");
        char magic[2] = { 0, 0 };
        if (!f_patch || fread(magic, 1, 2, f_patch) != 2 || magic[0] != 'P' || magic[1] != 'K') {
            if (f_patch) fclose(f_patch);
            SDL_Log(" !! the Arc patch jar is not a readable jar: %s", PATCH_JAR);
            SDL_Log("    (expected a ZIP: first two bytes 'PK')");
            SDL_Log("    build it with: python scripts/make_patch_jar.py");
            return 4;
        }
        fclose(f_patch);
        SDL_Log("   patch jar: %s (%ld bytes) OK", PATCH_JAR, (long)st_patch.st_size);
    }

    /* classpath 是补丁 jar + 游戏 + LWJGL。LWJGL 不是可选项：游戏后端类没有 org.lwjgl.* 无法链接，
     * 找不到会在加载 application 时暴露而不是加载 main class 时。⚠️ 第一个条目是补丁 jar，顺序
     * 承重（见 PATCH_JAR）；第二个【不是】GAME_JAR 常量而是它解析出来的结果（玩家可能选了别的版本，
     * 见 resolve_game_jar()，走到这里时必定非空）。 */
    SDL_snprintf(opt_classpath, sizeof(opt_classpath),
                 "-Djava.class.path=%s:%s:%s/lwjgl.so:%s/lwjgl-opengl.so:%s/lwjgl-sdl.so:%s",
                 PATCH_JAR, game_jar_path, LWJGL_JARS, LWJGL_JARS, LWJGL_JARS, HELPER_JAR);
    /* bundle 库目录放在【最前】，顺序正是关键：bundle 里有两份 libSDL3.so（启动器的在顶层，LWJGL
     * 的在 LWJGL_LIBS 里），ArkTS 的 XComponent 创建时报 "SDL3" 加载顶层那份并拿到 native 窗口，
     * 而游戏经 LWJGL 到达 SDL 会加载另一份 ⇒ 创建窗口的副本不是被赋予窗口的副本，窗口创建以
     * "OpenHarmony host has no ready NativeWindow lease" 失败（该消息只存在于 LWJGL 的构建里）。 */
    SDL_snprintf(opt_lwjglpath, sizeof(opt_lwjglpath),
                 "-Dorg.lwjgl.librarypath=%s:%s", BUNDLE_LIBS, LWJGL_LIBS);
    /* java.home 指向【沙箱】里的拷贝而不是 bundle，且从 VM 创建那一刻起就必须正确：两个 java.base
     * 按名字打开的文件无法随 bundle 旅行（hvigor 只搬 .so），它们被拷进 <sandbox>/jdk/lib/ 并恢复成
     * "modules"/"tzdb.dat"。从 Java 侧在 VM 起来后再纠正【不】够（实测）：ZoneInfoFile 仍去读
     * "<bundle>/jdk21/lib/tzdb.dat" 并抛 FileNotFoundException，即使 setProperty 已成功读回新值。 */
    SDL_snprintf(opt_home,      sizeof(opt_home),      "-Djava.home=%s", SANDBOX_JDK);
    SDL_snprintf(opt_tmpdir,    sizeof(opt_tmpdir),    "-Djava.io.tmpdir=%s", TMP_DIR);
    SDL_snprintf(opt_libpath,   sizeof(opt_libpath),   "-Djava.library.path=%s/server:%s", g_jdklib, g_jdklib);
    SDL_strlcpy(opt_encoding,   "-Dfile.encoding=UTF-8", sizeof(opt_encoding));
    SDL_strlcpy(opt_headless,   "-Djava.awt.headless=true", sizeof(opt_headless));
    /* JVM 在这里找 libjava.so 及其同类，而不是在 java.home/lib 里 */
    SDL_snprintf(opt_bootlib,   sizeof(opt_bootlib), "-Dsun.boot.library.path=%s:%s/server", g_jdklib, g_jdklib);
    /* 让 JVM 把它的崩溃报告放到我们能通过 hdc 读到的地方 */
    SDL_snprintf(opt_errfile,   sizeof(opt_errfile), "-XX:ErrorFile=%s/hs_err_%%p.log", DEST_ROOT);
    SDL_strlcpy(opt_heap,       "-Xmx512m", sizeof(opt_heap));

    /* -XX:UseSVE=0 在 JIT 中禁用 ARM SVE（必须先有 -XX:+UnlockDiagnosticVMOptions，它是诊断 flag）：
     * 没有它 JVM 会在 JNI_CreateJavaVM 期间以 SIGILL 确定性地死掉，在解释器 native-method entry
     * codelet 的同一个地址上。实测交替 A/B 五轮：基线在 0x5edf41fc68 处 5/5 崩溃，UseSVE=0 则 5/5
     * 成功。佐证是 AMCL（同设备、同 libjvm.so）的选项清单里就传了它。它们不是调参旋钮，而是能启动
     * 与会死掉的 JVM 之间的差别，故作为默认值待在这里。 */
    SDL_strlcpy(opt_unsve,  "-XX:+UnlockDiagnosticVMOptions", sizeof(opt_unsve));
    SDL_strlcpy(opt_sve,    "-XX:UseSVE=0", sizeof(opt_sve));

    /* 那三个平台属性 —— 为什么见声明处 */
    SDL_strlcpy(opt_osname,   "-Dos.name=Linux", sizeof(opt_osname));
    /* user.home 由 resolve_user_home() 决定 —— 隔离关着时它【逐字节等于 DEST_ROOT】，与隔离功能
     * 出现之前完全一样（见那个函数上方的三条不变量）。 */
    {
        char home[512];
        resolve_user_home(home, sizeof(home));
        SDL_snprintf(opt_userhome, sizeof(opt_userhome), "-Duser.home=%s", home);
    }
    /* ⚠️ user.dir 刻意【不】跟着隔离走：它是进程的工作目录，游戏中没有东西从它派生数据路径（数据
     * 走 user.home）。真需要改时再说，别顺手改 —— 那会让两个属性不一致从「刻意」变成「碰巧」。 */
    SDL_snprintf(opt_userdir,  sizeof(opt_userdir),  "-Duser.dir=%s",  DEST_ROOT);
    SDL_strlcpy(opt_gles, "-Darc.sdl.glEs=true", sizeof(opt_gles));
    /* 去问那个文件而不是用常量：玩家可能自上次启动以来已切到桌面操作方案。见 read_control_mode_mobile()。 */
    SDL_snprintf(opt_mobile, sizeof(opt_mobile), "-Darc.sdl.mobile=%s",
                 read_control_mode_mobile() ? "true" : "false");
    /* 游戏语言。⚠️ 必须在 `create()` **之前**填好 —— 与 user.home 同理：JVM 在启动那一刻读。 */
    resolve_game_locale();
    /* 诊断：把**游戏即将读到的那两个值**打进日志。 */
    {
        char probe_home[512];
        resolve_user_home(probe_home, sizeof(probe_home));
        log_game_settings_probe(probe_home);
    }

    {
        /* 读平台自己的答案而不是猜路径；没有答案时【完全略去】这个选项。过去传空字面量
         * "-Darc.sdl.chooserPath="，而 SdlFiles 的 System.getProperty("arc.sdl.chooserPath",
         * externalPath) 只在属性【不存在】时才回退 —— 空值是决定而非空操作。略去后回退到
         * user.home+分隔符 = 沙箱，即玩家的 mods/saves/schematics/maps 实际所在处。 */
        char dl[512];
        /* 应用自己的文件夹，别的什么都不要。这里曾有一个对普通平台 Download 目录的回退，实测让
         * 那些启动【更糟】：探测报 "download NOT READABLE errno=1 (Operation not permitted)"，指向
         * 它会打开在本应用无法列出的目录上。保持【未设置】更诚实也更好。⚠️ 不要再加回来。该文件夹只
         * 可能在安装/卸载后的第一次启动合法缺失（由页面创建，DOWNLOAD 选取器需要窗口 —— 实测 13900042）。 */
        if (read_user_dir("mods", dl, sizeof(dl)) > 0) {
            SDL_snprintf(opt_chooser, sizeof(opt_chooser), "-Darc.sdl.chooserPath=%s", dl);
            SDL_Log(" file browser will open at the mod folder: %s", dl);
        } else {
            opt_chooser[0] = '\0';       /* 空意味着未设置 —— 见 option_slot() */
            SDL_Log(" no mod folder in the bridge yet -- the browser will open in the");
            SDL_Log(" sandbox instead (where mods/ and saves/ are)");
        }
    }

    /* BASE_OPTS 计的是下面填进去的条目数；额外的条目追加在它们之后，所以让两者保持同步。 */
    JavaVMOption options[BASE_OPTS + MAX_EXTRA_OPTS];
    options[0].optionString = opt_classpath; options[0].extraInfo = NULL;
    options[1].optionString = opt_home;      options[1].extraInfo = NULL;
    options[2].optionString = opt_tmpdir;    options[2].extraInfo = NULL;
    options[3].optionString = opt_libpath;   options[3].extraInfo = NULL;
    options[4].optionString = opt_encoding;  options[4].extraInfo = NULL;
    options[5].optionString = opt_headless;  options[5].extraInfo = NULL;
    options[6].optionString = opt_bootlib;   options[6].extraInfo = NULL;
    options[7].optionString = opt_errfile;   options[7].extraInfo = NULL;
    options[8].optionString = opt_heap;      options[8].extraInfo = NULL;
    options[9].optionString = opt_unsve;     options[9].extraInfo = NULL;
    options[10].optionString = opt_sve;      options[10].extraInfo = NULL;
    options[11].optionString = opt_osname;   options[11].extraInfo = NULL;
    options[12].optionString = opt_userhome; options[12].extraInfo = NULL;
    options[13].optionString = opt_userdir;  options[13].extraInfo = NULL;
    options[14].optionString = opt_lwjglpath; options[14].extraInfo = NULL;
    options[15].optionString = opt_gles;      options[15].extraInfo = NULL;
    options[16].optionString = opt_mobile;    options[16].extraInfo = NULL;
    /* 一个构造出来为【空】的选项意味着「这一个别传」，用 NULL 表达好让下面的压缩丢掉它。传空
     * 字符串会设置该属性，那不是同一回事 —— 见 opt_chooser 上的说明。 */
    options[17].optionString = (opt_chooser[0] != '\0') ? opt_chooser : NULL;
    options[17].extraInfo = NULL;
    /* ⭐ 游戏语言（`-Duser.language` / `-Duser.country`，2026-10-04）。
     * ⛔⛔ **刻意追加在【末尾】（18、19），不是插进中间**：下面那条最小模式用的是
     *    **写死的下标**（`options[0]` / `[2]` / `[8]`），插进中间会让那三个下标全部错位、
     *    而错位的后果是**最小模式静默换掉了它传的参数**。追加则 0..17 的含义完全不变。
     * ⚠️ 两个都可能为空（关掉「跟随系统」时）⇒ 用 NULL 交给末尾那次压缩丢掉。 */
    options[18].optionString = (opt_language[0] != '\0') ? opt_language : NULL;
    options[18].extraInfo = NULL;
    options[19].optionString = (opt_country[0] != '\0') ? opt_country : NULL;
    options[19].extraInfo = NULL;

    /* 最小模式 —— 运行时选项文件里的一行开关（一行恰好写着 MINIMAL）。有几个内置 -D flag 是在告诉
     * HotSpot 它本会自己算出的东西（java.home、sun.boot.library.path、java.library.path）；提供它们
     * 本身偏离了「正常启动器如何启动 VM」，而已知在本设备可行的 AMCL 是在 VM 起来【之后】才经
     * System.setProperty 设置大多数属性的。所以这个模式几乎什么都不传，让 VM 自己推导：崩溃变了 ⇒
     * 我们的选项清单有嫌疑；没变 ⇒ 选项被洗清。 */
    int nExtra = 0;
    {
        /* 一次性读进额外的选项，放到数组尾部 */
        nExtra = load_extra_options(options, BASE_OPTS);
    }

    int minimal = 0;
    int force_noexec = 0;
    int w = BASE_OPTS;
    for (int i = BASE_OPTS; i < BASE_OPTS + nExtra; i++) {
        /* ArkTS 给每个启动参数值都加上 '-' 前缀，所以标记到达时可能是 NAME 也可能是 -NAME。它们在
         * 这里被消费掉、绝不到达 JVM —— 一个未知选项会让严格模式拒掉整份清单，这就是发现这点的原因。 */
        const char *o = options[i].optionString;
        if (SDL_strcmp(o, "MINIMAL") == 0 || SDL_strcmp(o, "-MINIMAL") == 0) {
            minimal = 1;
            continue;
        }
        if (SDL_strcmp(o, "NOHANDLERS") == 0 || SDL_strcmp(o, "-NOHANDLERS") == 0) {
            continue;                    /* 已在 main() 里处理过 */
        }
        /* CLEAROPT 的存在只是为了让 ArkTS 侧重写 jvm.options；它意味着「本次运行没有选项」，被消费
         * 并丢弃。没有它，一次不带选项的运行会保留【上一次】运行的文件、静默继承它的 flag。 */
        if (SDL_strcmp(o, "CLEAROPT") == 0 || SDL_strcmp(o, "-CLEAROPT") == 0) {
            continue;
        }
        /* NOGAME 在 VM 起来之后才处理；这里消费它只是为了让它绝不到达 JVM —— 一个未知选项会让
         * 严格模式拒掉整份清单，那会掩盖真正结果。 */
        if (SDL_strcmp(o, "NOGAME") == 0 || SDL_strcmp(o, "-NOGAME") == 0) {
            continue;
        }
        /* 测试钩子：让启动器表现得好像可执行内存探测失败了一样。-Xint 回退是手机包与「装得上、然后
         * 卡死在 JNI_CreateJavaVM 里」之间唯一的屏障，而本项目每台设备都【授予】匿名 RWX，那条路径
         * 在它们任何一台上都到不了 —— 意味着它会一次都没跑过就发出去，而「代码看起来是对的」与
         * 「这条回退被亲眼见过」不是一回事。有这个标记时该分支会在平板上运行（游戏约慢 5 倍）。 */
        if (SDL_strcmp(o, "NOEXEC") == 0 || SDL_strcmp(o, "-NOEXEC") == 0) {
            force_noexec = 1;
            continue;
        }
        options[w++] = options[i];       /* 就地压缩清单 */
    }
    nExtra = w - BASE_OPTS;

    int nOpts;
    if (minimal) {
        SDL_Log(" ** MINIMAL option set requested: classpath/tmpdir/Xmx only **");
        JavaVMOption kept[3 + MAX_EXTRA_OPTS];
        kept[0] = options[0];                       /* -Djava.class.path */
        kept[1] = options[2];                       /* -Djava.io.tmpdir */
        kept[2] = options[8];                       /* -Xmx             */
        for (int i = 0; i < nExtra; i++) kept[3 + i] = options[BASE_OPTS + i];
        nOpts = 3 + nExtra;
        for (int i = 0; i < nOpts; i++) options[i] = kept[i];
    } else {
        nOpts = BASE_OPTS + nExtra;
    }

    /* 当 JVM 拿不到可执行内存时强制 -Xint。设备类型规则回答不了这个问题：API 26 + 商店签名且无 ACL
     * 的手机被拒匿名 RWX ⇒ JIT 起不来、卡死在 JNI_CreateJavaVM，而规则从不触发（正是审核员撞上的
     * 「装得上、起不来」）；DEBUG 签名手机【确实】能拿到（实测），仅凭设备类型会白白扔掉 JIT；无 ACL
     * 的平板也被拒且无规则覆盖。probe_exec_mem() 测的正是这件事本身，一个答案覆盖以上三种。 */
    if (force_noexec || g_exec_probe_result != 42) {
        int already = 0;
        for (int i = 0; i < nOpts; i++) {
            if (options[i].optionString != NULL
                && SDL_strcmp(options[i].optionString, "-Xint") == 0) {
                already = 1;
                break;
            }
        }
        if (already) {
            SDL_Log(" executable memory unavailable (probe=%ld) and -Xint is already set",
                    g_exec_probe_result);
        } else if (nOpts < BASE_OPTS + MAX_EXTRA_OPTS) {
            static char forced_xint[] = "-Xint";
            options[nOpts++].optionString = forced_xint;
            SDL_Log(" !! executable memory unavailable (probe=%ld) -- FORCING -Xint; "
                    "the game will be slow but will start", g_exec_probe_result);
        } else {
            /* 除非 MAX_EXTRA_OPTS 被耗尽否则不可能发生（那意味着 jvm.options 填满每个槽位）。大声喊
             * 是因为另一种可能是静默卡死在 JNI_CreateJavaVM 里。 */
            SDL_Log(" !! executable memory unavailable (probe=%ld) and there is NO ROOM "
                    "to add -Xint -- the JVM will probably fail to start",
                    g_exec_probe_result);
        }
    } else {
        SDL_Log(" executable memory works (probe=42) -- JIT kept");
    }
    if (force_noexec) {
        SDL_Log(" NOTE: NOEXEC was set, so the probe result above was IGNORED and the "
                "fallback was taken on purpose -- this is a test, not a real condition");
    }

    /* 把判决留给 UI 读：是否以解释方式运行由【这里】测量决定，而页面做不了这个测量、也读不到日志
     * （游戏每秒推几千行），所以结论经文件传递（与 IME 桥同一通道）。页面在 XComponent 挂载之前就
     * 写下提示决定 ⇒ 只能读到【上一次】启动的答案。⚠️ 报告的是【能力】而不是选项清单 —— 过去问
     * 「清单里有 -Xint 吗」，于是页面的陈旧请求被当作新鲜判决喂回来（实测一台探测一直返回 42 的手机
     * 以 12239 ms 保持解释模式）；改为问探测就打破了循环，且它在 JNI_CreateJavaVM【之前】跑。 */
    {
        const int incapable = (force_noexec || g_exec_probe_result != 42);
        FILE *vf = fopen(DEST_ROOT "/execmem", "w");
        if (vf == NULL) {
            SDL_Log(" !! cannot write %s -- the UI cannot tell the player the game is "
                    "running interpreted", DEST_ROOT "/execmem");
        } else {
            fputs(incapable ? "interp\n" : "jit\n", vf);
            fclose(vf);
            SDL_Log(" wrote the verdict for the UI: %s (probe=%ld%s)",
                    incapable ? "interp" : "jit", g_exec_probe_result,
                    force_noexec ? ", NOEXEC set" : "");
        }
    }

    /* 丢掉那些被刻意留作未设置的选项：在这里做而不是在每个构造点做，是因为计数必须与实际交出去的
     * 清单对得上，且在一处做意味着之后某个选项可以同样变成有条件的，而不必知道 nOpts 怎么拼出来。 */
    {
        int kept = 0;
        for (int i = 0; i < nOpts; i++) {
            if (options[i].optionString != NULL) options[kept++] = options[i];
        }
        if (kept != nOpts) SDL_Log(" %d option(s) left unset and not passed", nOpts - kept);
        nOpts = kept;
    }

    JavaVMInitArgs args;
    SDL_memset(&args, 0, sizeof(args));
    args.version = JNI_VERSION_1_8;
    args.nOptions = nOpts;
    args.options = options;

    /* 先严格，后宽松 —— 因为「文件被读了」并不能证明某个 flag 被理解了。这里过去无条件用 JNI_TRUE
     * （忽略不认识的）：日志对每个 flag 都说 "read 1 extra option(s)"，而一个拼错的、或不存在的
     * flag 产生完全相同的一行然后被静默丢弃，于是「那个 flag 没用」的每个结论都站不住脚 —— 分不清
     * 「flag 没有效果」与「flag 根本没到达 VM」。先试严格（未知选项会让 JVM 明确说出来，报错码或
     * stderr 一条消息都会被捕获），再试宽松，这样选项文件里的一个坏 flag 无法让启动器彻底无法运行。 */
    args.ignoreUnrecognized = JNI_FALSE;

    SDL_Log(" calling JNI_CreateJavaVM (strict) ...");
    for (int i = 0; i < args.nOptions; i++) SDL_Log("   opt: %s", options[i].optionString);

    JavaVM *vm = NULL;
    JNIEnv *env = NULL;
    /* 在调用【之前】，绝不在之后：如果 create() 不返回，这是附近唯一一条曾经跑过的语句。 */
    {
        FILE *mf = fopen(JVM_INCOMPLETE_MARKER, "w");
        if (mf != NULL) { fputs("incomplete\n", mf); fclose(mf); }
    }
    jint rc = create(&vm, (void **)&env, &args);
    SDL_Log(" JNI_CreateJavaVM (strict) returned %d", (int)rc);
    
    /* JVM 存在了，于是问题有了答案。刻意在【此处】而不是 start_jvm() 末尾清除：此点之后的失败
     * （缺失的类、死掉的 surface）会返回一个码并打印一行，已经可见，绝不能被报告成「没有 JVM」。 */
    unlink(JVM_INCOMPLETE_MARKER);
    
    if (rc != JNI_OK && nOpts > BASE_OPTS) {
        /* 额外的选项是唯一说得通的元凶；点名它们，因为有用的信息是【哪一个】flag 被 JVM 拒绝了。 */
        SDL_Log(" !! strict mode refused the options; the extras were:");
        for (int i = BASE_OPTS; i < nOpts; i++) SDL_Log("      %s", options[i].optionString);
        SDL_Log("    (an \"Unrecognized\" message above names the offender)");
        SDL_Log("    retrying lenient so the launcher still runs ...");
        args.ignoreUnrecognized = JNI_TRUE;
        rc = create(&vm, (void **)&env, &args);
        SDL_Log(" JNI_CreateJavaVM (lenient) returned %d", (int)rc);
    }

    if (rc != JNI_OK || !env) {
        SDL_Log(" !! JVM creation failed (rc=%d)", (int)rc);
        return 3;
    }
    SDL_Log(" *** JVM CREATED *** vm=%p env=%p", (void *)vm, (void *)env);

    /* 在任何东西向 boot loader 索要资源【之前】（见 SANDBOX_JDK）。只在镜像真的过来了的时候才做：
     * 把 java.home 指向没有 lib/modules 的目录，只会把 VM 那条准确的错误消息换成更差的一条。 */
    if (modok == 0) {
        override_java_home(env);
    } else {
        SDL_Log(" !! java.home left alone: the module image is not in place");
    }

    /* --- 证明它能用：从 native 调用 System.out.println --- */
    jclass syscls = (*env)->FindClass(env, "java/lang/System");
    if (!syscls) { SDL_Log(" !! FindClass(System) failed"); return 4; }

    jfieldID outId = (*env)->GetStaticFieldID(env, syscls, "out", "Ljava/io/PrintStream;");
    jobject out = (*env)->GetStaticObjectField(env, syscls, outId);
    jclass pscls = (*env)->FindClass(env, "java/io/PrintStream");
    jmethodID println = (*env)->GetMethodID(env, pscls, "println", "(Ljava/lang/String;)V");

    (*env)->CallVoidMethod(env, out, println,
        (*env)->NewStringUTF(env, "*** HELLO FROM THE JVM ***"));

    /* 几个只有从 VM 内部才知道的事实 */
    jmethodID curTime = (*env)->GetStaticMethodID(env, syscls, "currentTimeMillis", "()J");
    jlong ms = (*env)->CallStaticLongMethod(env, syscls, curTime);

    jclass rtcls = (*env)->FindClass(env, "java/lang/Runtime");
    jmethodID getRt = (*env)->GetStaticMethodID(env, rtcls, "getRuntime", "()Ljava/lang/Runtime;");
    jobject rt = (*env)->CallStaticObjectMethod(env, rtcls, getRt);
    jmethodID avail = (*env)->GetMethodID(env, rtcls, "availableProcessors", "()I");
    jint cpus = (*env)->CallIntMethod(env, rt, avail);

    /* maxMemory() 是对选项通道的一次【正向检查】：日志行 "read N extra option(s) from <file>" 只
     * 证明【文件】被读了，对 JVM 是否接受那些 flag 只字不提；传 -Xmx256m 并看到数字改变，才是该
     * 通道真的到达 VM 的廉价端到端证明 —— 没有它，「flag 没有效果」与「flag 从没被看到」无从区分。 */
    jmethodID maxmem = (*env)->GetMethodID(env, rtcls, "maxMemory", "()J");
    jlong maxheap = (*env)->CallLongMethod(env, rt, maxmem);

    SDL_Log(" currentTimeMillis = %lld", (long long)ms);
    SDL_Log(" availableProcessors = %d", (int)cpus);
    SDL_Log(" runtime maxMemory = %lld bytes (%.0f MB)  <- reflects -Xmx",
            (long long)maxheap, (double)maxheap / (1024.0 * 1024.0));
    SDL_Log(" *** JAVA IS RUNNING ON HARMONYOS ***");

    if ((*env)->ExceptionCheck(env)) {
        SDL_Log(" !! a Java exception is pending");
        (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
    }

    /* 上面的检查是第 3 步的验收，保持原样 —— 它们是 VM 自身健康唯一的廉价证明，把「VM 没有启动」
     * 与「游戏没有启动」区分开；全都通过后才把控制权交给游戏。NOGAME 跳过交接，好让第 4 步的回归
     * 与第 3 步的区分开而无需重建。 */
    if (options_contain("NOGAME")) {
        SDL_Log(" ** NOGAME requested: stopping before the game is launched **");
        return 0;
    }

    probe_mark("JVM up: about to launch the game");

    preload_arc_natives(env);

    configure_game_sdl();

    (void)launch_game(env);
    return 0;
}

/* 把每一条 SDL_Log 都镜像到 HILOG。诊断全走 SDL_Log → stdout/stderr → 沙箱文件，那对 DEBUG 签名
 * 有效，但对 release 签名【不】有效：设备实测 internaltesting 包下 `hdc shell cat
 * <sandbox>/files/stderr.log` -> Permission denied、pidof/ps 皆空、faultlog 无条目 —— 2026-09-22 一个
 * 商店签名包回退到 -Xint 后崩溃，什么都读不到；hilog 对任何签名都可读，诊断也必须去那里。用回调
 * 而非在调用点包宏（SDL3 允许替换汇聚点，一个函数接住本文件每条 SDL_Log 及 SDL 自己记录的一切）；⚠️ 用 %{public}s。 */
#define MX_LOG_DOMAIN 0x0000
#define MX_LOG_TAG    "MindustryLauncher"

static SDL_LogOutputFunction g_prev_log_output = NULL;
static void *g_prev_log_userdata = NULL;

static void SDLCALL mirror_log_to_hilog(void *userdata, int category,
                                        SDL_LogPriority priority, const char *message)
{
    /* 先保留原来的行为：万一这里出岔子，文件里仍然有那一行。 */
    if (g_prev_log_output != NULL) {
        g_prev_log_output(g_prev_log_userdata, category, priority, message);
    }

    LogLevel level;
    switch (priority) {
        case SDL_LOG_PRIORITY_VERBOSE:
        case SDL_LOG_PRIORITY_DEBUG:   level = LOG_DEBUG; break;
        case SDL_LOG_PRIORITY_WARN:    level = LOG_WARN;  break;
        case SDL_LOG_PRIORITY_ERROR:
        case SDL_LOG_PRIORITY_CRITICAL: level = LOG_ERROR; break;
        default:                        level = LOG_INFO;  break;
    }
    /* 一次调用，一个 public 字符串 —— 见上面关于 %{private} 的说明。 */
    OH_LOG_Print(LOG_APP, level, MX_LOG_DOMAIN, MX_LOG_TAG, "%{public}s", message);
}

static void install_hilog_mirror(void)
{
    SDL_GetLogOutputFunction(&g_prev_log_output, &g_prev_log_userdata);
    SDL_SetLogOutputFunction(mirror_log_to_hilog, NULL);
}

int main(int argc, char *argv[])
{
    (void)argc; (void)argv;

    install_hilog_mirror();

    /* 阻止 SDL 把触摸变成鼠标事件（SDL 默认这么做，SDL_HINT_TOUCH_MOUSE_EVENTS）：否则每次触摸
     * 到达两次 —— 一次模拟鼠标、一次真实手指 —— 而 Arc 只理解鼠标那一半，所以点击能用却永远捏合
     * 不了（模拟鼠标永远是 pointer 0，捏合由第二个接触点定义）。用环境变量而不是 SDL_SetHint：
     * 本进程有两份 libSDL3.so 映射而只有一份分发触摸事件，环境变量两者共享。 */
    setenv("SDL_TOUCH_MOUSE_EVENTS", "0", 1);

    SDL_Log("==================================================");
    SDL_Log(" Mindustry Launcher -- start the JVM");
    redirect_io();
    /* SDL 的 XComponent 回调记录的一切都发生在这个标记【之前】，之后的一切发生在我们启动 JVM 和
     * 游戏时（见 probe_mark()）。这个文件刻意【不】在这里截断：surface 回调在本函数运行之前就触发
     * 了（它正是启动本函数的东西），清空会删掉恰好要紧的条目；它改为跨启动累积，在运行前从 PC 侧清。 */
    probe_mark("main() entered: JVM not started yet");
    /* surface 拷贝的探测已移除：SDL 不导出它 */
    /* crash.txt 以 O_APPEND 写入，这样一个致命信号（可能在 stdout 可用之前就袭来）永远不会丢失
     * 报告；它也因此跨启动累积，不先清空就读会静默混起好几次运行 —— 所以每次运行都从空开始。 */
    unlink(DEST_ROOT "/crash.txt");
    /* 退出标记绝不能活过一次启动：ArkTS 轮询它们、一出现就关掉 ability，所以上次运行留下的标记会
     * 在本次启动后四分之一秒内把这次运行关掉，看起来像自发崩溃而不是陈旧文件。 */
    unlink(EXIT_MARKER_SANDBOX);
    unlink(EXIT_MARKER_MODULE);
    SDL_Log(" stdout/stderr -> %s/{stdout,stderr}.log", DEST_ROOT);
    /* PID 对 TID 解决了一个真问题：SDL 在它自己 pthread_create() 出来的线程上运行 SDL_main，而
     * 不是进程主线程；两者不同就意味着 JVM 是在非主线程上被创建的 —— 正是计划里那个最大的未知数。
     * （早先一版两次打印 getpid()，那份日志得出的「两者不同」是打印的产物，不是测量。） */
    SDL_Log(" PID=%d TID=%ld", (int)getpid(), (long)syscall(SYS_gettid));
    SDL_Log("--------------------------------------------------");
    discover_paths();
    SDL_Log(" jdk home    : %s", g_jdkhome);
    SDL_Log(" jdk lib dir : %s", g_jdklib);
    SDL_Log(" anchor      : %s", g_anchor);
    {
        struct stat s1, s2, s3;
        SDL_Log(" exists?  anchor=%d  jdkhome=%d  libdir=%d",
                (int)(stat(g_anchor,  &s1) == 0),
                (int)(stat(g_jdkhome, &s2) == 0),
                (int)(stat(g_jdklib,  &s3) == 0));
    }
    SDL_Log("--------------------------------------------------");

    /* 崩溃处理器【只有】在选项文件不要求放过它们时才安装（把 "NOHANDLERS" 放进 jvm.options 就
     * 什么都不装）。为什么成了变量：它们从最初那版起就一直安装，覆盖 SIGILL —— 恰恰是我们正死于其上
     * 的信号；而 HotSpot 在 JNI_CreateJavaVM 期间装【它自己的】处理器并用链式方案（认不出就转给先前
     * 安装的），我们看到【我们的】在跑 ⇒ HotSpot 没把这次错误认作自己的。HotSpot 刻意把非法指令当
     * 陷阱执行并自己捕获，从一开始就坐在那条路径前面，是造成现有症状的一个说得通的方式。 */
    extern int options_contain(const char *needle);
    if (options_contain("NOHANDLERS")) {
        SDL_Log(" ** NOHANDLERS: not installing crash handlers -- HotSpot's signal");
        SDL_Log("    handling is left completely undisturbed");
    } else {
        install_crash_handlers();
    }
    int rc = start_jvm();
    SDL_Log("--------------------------------------------------");
    SDL_Log(" result = %d", rc);

    /* 这里曾有一个 20 秒的 "staying alive 20s ..." 睡眠循环（早期诊断脚手架，用来观察 main() 返回
     * 之后发生什么，一直没被移除），它也是「退出会卡住、几秒后应用才退出」那个抱怨的全部原因：
     * 游戏 main() 返回后画面冻住，循环睡 20 秒期间进程还活着，循环结束我们返回才拆除。所以延迟从来
     * 不在 SDL 里、也不在 JVM 的 shutdown hook 里 —— 2026-09-20 用 quit_timing.sh 实测点击到进程
     * 消失约 20 秒，恰好与循环时长吻合。已移除且不替换：越早返回，系统越早拆掉应用。 */
    SDL_Log("==================================================");
    /* 用 _exit 终止，而不是 return：从 main 返回会运行 C 运行时的 atexit 处理器与每一个静态析构
     * 函数，而那次拆除会【中止】—— 实测每次退出都是 "*** FATAL SIGNAL 6 (code=-6) at ... pc
     * 0x5acff84ef4  in /lib/ld-musl-aarch64.so.1  thread SDL_main"，系统照章把它归档成
     * "AppMS: reason=Cpp Crash ... exitSigno = 6"。应用反正都要走，这个信号对结果毫无改变，却意味着
     * 每一次正常退出都被报告给 OS 为一次崩溃（会生成崩溃报告、可能弹对话框）—— 对一个用户按下的
     * 按钮这是错误的说法。跳过拆除也毫无损失（它发生在游戏 main() 已返回之后，libjvm 和 SDL 正以
     * 本平台都不支持的顺序被卸载）。先 flush：_exit 不运行 stdio 清理，而 stdout.log/stderr.log 的
     * 尾部是最有用的证据；游戏持久化不受影响（Arc 在 application shutdown 保存设置，main() 返回时
     * 已完成，已确认 settings.bin 仍被重写）。
     * ---------------------------------------------------------------------
     * 退出之前，把关机交给 ArkTS。单靠 _exit 会在 ability 仍然活着的时候结束进程，而系统把那记录为
     * "Cpp Crash"（AppMS: reason=Cpp Crash, killId=2004）—— 即使没有信号、没有崩溃 dump 也一样，
     * 我们就是靠这点知道它是对一次看起来异常之退出的分类，而不是一次真正的错误。所以改为：放下一个
     * 标记，给 ArkTS 一个短窗口调用 terminateSelf()，如果它没有调用就自己退出；当它生效时，框架把
     * ability 拆掉并杀掉进程 —— 一次正常结束，路径里也没有我们的 C 运行时拆除。窗口刻意有界：握手
     * 不生效时应用仍必须退出，在这里卡死远比它试图修的那条被错标的日志行糟糕得多；走回退实测约 1.2 秒。 */
    {
        const char *paths[2] = { EXIT_MARKER_SANDBOX, EXIT_MARKER_MODULE };
        for (int i = 0; i < 2; i++) {
            FILE *f = fopen(paths[i], "wb");
            if (f) {
                fputc('1', f);
                fclose(f);
            } else {
                SDL_Log(" exit marker not writable: %s", paths[i]);
            }
        }
        SDL_Log(" exit marker written -- waiting up to 1.2s for ArkTS to terminateSelf()");
    }
    for (int i = 0; i < 12; i++) {
        SDL_Delay(100);
    }
    SDL_Log(" ArkTS did not take over; exiting directly");
    fflush(NULL);
    _exit(rc);
}
