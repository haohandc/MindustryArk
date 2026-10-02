/* [A]
 * HarmonyOS 版 Mindustry 启动器 —— 先启一个真正的 JVM，然后交给 Java。
 *
 * 计划里被称作「最大的未知数」的那一步：在 HarmonyOS 上、在 SDL 创建出来的线程（而非进程
 * 主线程）里，从 native 代码创建一个 Java VM。
 *
 * 东西都在哪（当前设计）
 *   JDK 以普通目录的形式放在 entry/libs/arm64-v8a/jdk21/ 下，因此由 HAP 安装器直接解包进
 *   应用的可执行库区 —— 没有运行时解压步骤，也没有首次启动开销：
 *
 *       entry/libs/arm64-v8a/jdk21/lib/server/libjvm_real.so
 *           -> /data/storage/el1/bundle/libs/<abi>/jdk21/lib/server/libjvm_real.so
 *
 *   只有 HAP 自己的 lib 区是可执行的；可写的沙箱（el2）不是，即使持有
 *   ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY 也一样。所以把 JDK 当作库来分发，
 *   顺带免费解决了可执行映射的问题。
 *
 *   把真正的 libjvm 嵌套三层，正是让 HotSpot 推导出正确 java.home 的原因（它剥掉三层路径
 *   分量，并要求 "<java.home>/lib/<module image>" 存在）；完整链路见 prep_vendor.py，
 *   其中包括为什么需要一个 anchor 库，来满足其它每个 JDK 库都声明的裸名 DT_NEEDED。
 *
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
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <ucontext.h>
#include <sys/types.h>
#include <unistd.h>
/* [A] 关于 probe_network：为什么网络是手工探测、而不是从游戏恰好打印的那条错误里推断，
 * 见它自己那处的说明。 */
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>

/* [A]
 * JDK 住在 HAP 的原生库区里 —— 这就是整件事的关键。
 *
 * 有两条规则必须同时满足：
 *
 *   (a) 只有 HAP 自己的 lib 区是可执行的。从应用可写沙箱里读出来的库无法被 dlopen，即使
 *       持有 ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY 也不行。实测：
 *           dlopen("<bundle>/libSDL3.so")                    -> OK
 *           dlopen("<sandbox>/.../libSDL3_copy.so")          -> fails
 *       （该权限只覆盖匿名可执行内存；AMCL 靠手写的 ELF loader 绕过去 —— 我们不需要。）
 *       ！！「匿名可执行内存」恰恰是 JIT 所需要的东西，而且它并非普遍可用：2026-09-22 实测，
 *       一台 HarmonyOS 6.1.1（API 24）设备在运行 release 签名的商店包时，用 errno=22 拒绝了
 *       mmap(RWX)。见 RELEASE-MAINTENANCE.md 2.11。
 *
 *   (b) HotSpot 从 libjvm.so 自身的路径推导 java.home：它剥掉三层路径分量，然后要求
 *       "<java.home>/lib/modules" 存在。-Djava.home 会被无条件覆盖（os_linux.cpp，
 *       Arguments::set_java_home）。
 *
 * 所以 JDK 以 entry/libs/arm64-v8a/jdk21/ 的形式（递归地）分发，落点为：
 *
 *     <bundle>/libs/arm64/jdk21/lib/server/libjvm.so
 *                            ^-- strip 1 -> .../jdk21/lib/server
 *                            ^-- strip 2 -> .../jdk21/lib
 *                            ^-- strip 3 -> .../jdk21   = java.home
 *     <bundle>/libs/arm64/jdk21/lib/modules      <- 存在，于是 set_boot_path 通过
 *
 * 一切都是可执行的，java.home 结果正确，运行时也无需解包任何东西。（与 AMCL 的 ELF loader
 * 产出的布局相同，只是没有那个 loader。）
 */
#define JDK_HOME    "/data/storage/el1/bundle/libs/arm64/jdk21"
#define JDK_LIB     JDK_HOME "/lib"
/* [A] 真正的 JVM，嵌套在 <java.home>/lib/server/ 下，好让 HotSpot 推导出正确的
 * java.home。它的 SONAME 已被清空，且不在 loader 的搜索路径上 —— 要通过依赖它的 anchor
 * （JDK_ANCHOR）来触达它。 */
#define JDK_LIBM        JDK_LIB "/server/libjvm_real.so"

/* [A] 一个除此之外空无一物的 libjvm.so，放在搜索路径上。见 libjvm_anchor.c：
 * 它存在的唯一目的，是让其它 JDK 库的裸名 DT_NEEDED 得以解析，并经由它自己的依赖链把
 * 真正的 JVM 拉进来。 */
#define JDK_ANCHOR  BUNDLE_LIBS "/libjvm.so"
#define BUNDLE_LIBS "/data/storage/el1/bundle/libs/arm64"

/* [A]
 * 游戏本体，以「名字看起来像共享库」的 jar 形式交付。
 *
 * hvigor 把 entry/libs/arm64-v8a/** 拷进 HAP 只有一个条件：文件名以 ".so" 结尾。内容不做
 * 检查。在构建出的 HAP 上实测：140,523,131 字节的 module image 以 lib/jdk21/lib/jimg.so 的
 * 形式分发，25,322,128 字节的真正 JVM 以 libjvm_real.so 的形式分发 —— 两者都恰好是项目里的
 * 尺寸，逐字节一致 —— 而 jdk21/conf/ 下的每个文件都被无声丢弃，因为那些名字不以 ".so" 结尾。
 *
 * 于是 jar 走同一条路。它并不比 module image 更像 ELF，也同样原封不动地活了下来。
 *
 * JVM 也不关心扩展名：class path 条目是按内容、而不是按名字被当作归档打开的。
 *
 * 另一条路 —— 首次启动时把它写进沙箱 —— 被认为没有必要而否决了：bundle 库区对应用可读
 * （module image 正是从那里读的，没有它 VM 无法启动），所以没什么要拷的，也没有首次启动开销。
 * 沙箱唯一不可用的地方是【可执行】映射，而这并不是。
 *
 * 它放在一个子目录里，而不是直接挨着 libmain.so。那个目录顶层的名字，是平台当作原生库对待的
 * 那些；而 jar 不是 ELF；让它低一层，正好与 module image 已经待的位置一致，且已知不会被碰。
 */
#define GAME_JAR    BUNDLE_LIBS "/game/mindustry.so"

/* [A]
 * 我们的 Arc 修改，做成一个独立的 jar，排在 classpath 的【最前面】。
 *
 * 为什么不写进游戏 jar 了（2026-09-28 改）
 *   以前靠 patch_mindustry.py 就地改写游戏 jar（把 arc/backend/sdl/** 整目录换掉）。
 *   那样每次跟进上游都要重开、重写那个 jar，而且包一出来就分不清哪些类是我们的。
 *   现在游戏 jar 就是上游原版、一个字节都不改，我们的类放这里。
 *
 * 为什么这个顺序就是全部
 *   JVM 按 classpath 顺序解析类，先命中的赢。这个条目排在 GAME_JAR 前面，它里面的
 *   26 个类因此压过游戏 jar 里的同名类。
 *   ⚠️ 这个顺序【是承重的】—— 挪到后面，补丁就完全不起作用，而应用看起来只是
 *   「行为不对」，不会报任何错。
 *
 * 已实测（设备，非推断）
 *   · 桌面 JVM 三组实验、两组互为对照 ⇒ 顺序确实决定结果
 *   · 设备：一个 arc/util/Log 替身排在最前 ⇒ 游戏加载的确实是替身（NoSuchFieldError）
 *   · 完整组合：上游原版 jar + 这个 jar + bundle 原生库 ⇒ 游戏起来、音频正常
 *   · 跨版本：同一份补丁 jar 同时驱动 160.4 与 160.5（后者实测 Version: 160.5）
 *
 * 由 make_patch_jar.py 产出，带三道闸门；verify_hap.py 第 6b 段在产物里再查一遍。
 */
#define PATCH_JAR   BUNDLE_LIBS "/patchjar/arcpatch.so"

/* [A]
 * LWJGL，分两半 —— 它们因为两个不同的原因去了两个不同的地方。见 prep_lwjgl.py。
 *
 * 游戏 jar 里不含 LWJGL。Arc 的 SDL3 后端通过 org.lwjgl.opengl.* 和 org.lwjgl.sdl.* 调用
 * 平台，而这些类在游戏跑在 AMCL 下时来自 AMCL 的 libraries 目录。这个启动器必须自己提供它们，
 * 否则那个后端根本加载不了。
 *
 *   LWJGL_LIBS  真正的 ELF 共享对象：liblwjgl.so 里的 dyncall 分发，以及
 *               liblwjgl_opengl.so 里的 OpenGL 绑定。它们不需要任何伪装，但必须待在可执行区。
 *   LWJGL_JARS  根本不是 ELF；改成 .so 只是因为那是 hvigor 把文件拷进 HAP 的唯一条件。
 *
 * LWJGL_LIBS 里【没有】libSDL3.so，这是刻意的 —— 见下面关于 opt_lwjglpath 的说明。曾经有过
 * 一个：LWJGL 自己构建的 SDL3，理由是 LWJGL 的 sdl 绑定是针对一份特定符号清单生成的，而 SDL 的
 * 开发分支会改名，所以这一对配套的能避免 SDL 漂移。那个理由总体上仍然成立，但被一个更糟的问题
 * 超越了：任何位置出现第二个 libSDL3.so，就意味着一个进程里有两份互相独立的 SDL3 映射，各自
 * 带自己的静态变量，而这个项目正好在这上面栽过一回 —— 两个事件队列，窗口在一个副本里创建，
 * surface 回调却投递给另一个。所以 loader 被指向【唯一】的 SDL3，也就是本项目从
 * entry/src/main/cpp/SDL/ 构建出来的那个，别的什么都不提供这个名字。
 */
#define LWJGL_LIBS  BUNDLE_LIBS "/lwjgl"
#define LWJGL_JARS  BUNDLE_LIBS "/lwjgl-java"

/* [A]
 * Arc 自己的 natives，之所以在这儿分发，是为了让它们至少能被加载。
 *
 * Arc 把它们从 jar 里读出来，写到 java.io.tmpdir 下，然后对副本调用 System.load ——
 * 而这个副本无法被 dlopen，因为在这个平台上应用的可写区域不可执行，只读的 bundle 才可执行。
 * 用两个库、跨六个候选目录实测过，外加一个通过的 bundle 对照：见 probe_sandbox_exec()。
 *
 * 所以改为在游戏启动前就从这里加载它们，并告诉 Arc 它们已经加载好了。setLoaded(String) 是
 * public static，而 load() 对已标记的名字会立即返回 —— 这和 Arc 为自己所做的调用相同。
 * 这不是偷偷塞进来的变通做法；这是 loader 自己的契约。
 */
#define ARC_LIBS    BUNDLE_LIBS "/arc"

/* [A]
 * 我们自己的类，它存在的唯一目的，是让 System.load 从 Java 里被调用。
 *
 * System.load 是 @CallerSensitive 的：它把库注册到调用者所在的类加载器上。通过 JNI 调用时
 * 没有调用者栈帧，于是库落在了 bootstrap loader 上，游戏的类看不见它的符号 —— 库加载了，
 * 却仍然不可用。见 NativeLoader.java。
 */
#define HELPER_JAR  BUNDLE_LIBS "/launcher/helper.so"

/* [A]
 * java.home 必须在第一次 module-image 查找之前被指向哪里，以及为什么 module image 有两个
 * 名字。
 *
 * 这个文件其实叫 jimg.so，因为 hvigor 只搬运文件名以 ".so" 结尾的文件 —— 见 patch_libjvm.py。
 * 对 VM 而言这个改名就够了，因为在重写 libjvm 里那个字符串时已经告诉了它新名字。但对 java.base
 * 来说【不够】，因为它是自己拼路径的：
 *
 *     private static final Path BOOT_MODULES_JIMAGE =
 *             Paths.get(System.getProperty("java.home"), "lib", "modules");
 *
 * 那是一个 static final，只在 jdk.internal.jimage.ImageReaderFactory 被初始化时读【一次】——
 * 而它是惰性初始化的，发生在经由 boot loader 的第一次资源查找时，对本程序而言就是在游戏的
 * main() 里面。所以有一个很宽的窗口，java.home 仍然可以被改，而下面这个覆盖就是在一个可能的
 * 最早时刻、在 VM 存在之后立刻施加的。
 *
 * java.home 不能简单地作为 -Djava.home 传入：HotSpot 从 libjvm.so 的位置推导它，并覆盖掉传入
 * 的任何值（实测）。所以它改为从 Java 侧重写，在 VM 起来之后、但在任何东西读它之前。
 *
 * 它被指向的那个目录，必须包含一个名为 "modules" 的真实文件，这意味着首次启动时要把这个
 * 140 MB 的镜像物化进沙箱。
 *
 * 用【符号链接】本该是避开这次拷贝的显而易见之法，而且也是最先尝试的：
 * symlink("/data/.../jdk21/lib/jimg.so", ".../jdk/lib/modules") 以 EACCES 失败。沙箱根本
 * 不允许创建符号链接。硬链接也不行 —— 镜像位于只读挂载上，无法链接进一个可写挂载。
 *
 * 所以拷贝是唯一的路，而且只做一次：已存在的、尺寸正确的文件被原样接受。它先以一个临时名字
 * 写入、再改名就位，因为一次中途被打断的拷贝否则会留下一个能通过存在性检查、却在 JVM 内部
 * 失败的文件。
 */
#define SANDBOX_JDK     DEST_ROOT "/jdk"
#define SANDBOX_MODULES SANDBOX_JDK "/lib/modules"
#define SANDBOX_TZDB    SANDBOX_JDK "/lib/tzdb.dat"
#define MODULE_IMAGE    BUNDLE_LIBS "/jdk21/lib/jimg.so"
#define TZDB_IMAGE      BUNDLE_LIBS "/jdk21/lib/tzdb.so"

/* [A]
 * <java.home> 还必须包含的其余东西，以一棵镜像它的目录树形式分发。由
 * scripts/prep_jdkconf.py 构建，那里解释了原因。
 *
 * 简而言之：JDK 会读取相对于 java.home 的文件，不只是 module image。
 * conf/security/java.security 由 Security 的静态初始化器读取，而每一次 defineClass() 都需要
 * 一个 ProtectionDomain，后者又需要 Security —— 所以少了那一个文件，运行时任何机制都无法加载
 * 任何类。模组加载只不过是最先需要它的那个功能。
 *
 * 之所以是一整棵树而不是一份文件名清单，是因为先前那份清单在对的时候完全正确，直到它不对为止 ——
 * 有过两次：这一次，以及 lib/tzdb.dat。
 */
#define JDK_HOME_TREE   BUNDLE_LIBS "/jdkhome"

/* [B] 可写位置，tmpdir 和捕获的 stdio 仍然需要 */
#define DEST_ROOT   "/data/storage/el2/base/files"
#define TMP_DIR     "/data/storage/el2/base/temp"

/* [A]
 * 这个启动器在这里告诉 ArkTS「游戏结束了，关掉 ability」。
 *
 * 两边对一个路径常量并不一致：native 写在 DEST_ROOT（/data/storage/el2/base/files）下，
 * 而 ArkTS 的 context.filesDir 是模块作用域的 /data/storage/el2/base/haps/entry/files。
 * 出于同样的原因，启动器本来就会从【两个】位置读 jvm.options，所以这个标记被写到两处，ArkTS
 * 也检查两处。关机时一次性写两个一字节文件，总好过搞错哪个目录才是共享的。
 *
 * 为什么它非存在不可
 *   直接杀进程，正是让系统把这次退出归档成 "Cpp Crash" 的原因：从框架的视角看，一个 native
 *   进程在它的 ability 仍在运行时死掉了。先终止 ability，让框架把进程带下去，才是正常结束的
 *   唯一办法。native 没有这个 API —— ability 对象是个 ArkTS 对象 —— 所以只能由 ArkTS 来做，
 *   而这个文件就是它得知的方式。
 */
#define EXIT_MARKER_SANDBOX DEST_ROOT "/native_exit"
#define EXIT_MARKER_MODULE  "/data/storage/el2/base/haps/entry/files/native_exit"

/* [A]
 * 在 JVM 被创建之前写下，在它存在之后删除。
 *
 * 为什么：当 JNI_CreateJavaVM 拿不到它需要的东西时，进程会当场停死，哪儿都不会写下任何东西 ——
 * 没有日志行，没有 faultlog，没有返回码。2026-09-22 在一个商店签名的包上实测到，而这是唯一一种
 * 完全不留证据的失败。一个能存活到【下一次】启动的标记，是页面得知它发生过的唯一办法，因为页面
 * 永远只能读到上一次运行留下的东西。
 *
 * 它【不是】什么：对【本次】启动的判决。没有东西读它来决定是否启动；页面显示一条提示，由玩家来
 * 选择。一次性失败留下的残留，绝不能拦住一次本可以成功的运行。
 */
#define JVM_INCOMPLETE_MARKER DEST_ROOT "/jvm_incomplete"

/* [A]
 * 探测这个应用到底能不能【读】平台称为用户可见的那些目录 —— 也就是玩家可以往里丢存档文件的
 * 那些。
 *
 * 这里的路径不是猜的：ArkTS 去问平台（environment.getUserDownloadDir /
 * getUserDocumentDir）并把它们写到 USER_DIRS_FILE，因为只有 ArkTS 能问。但只有 native 能用
 * 与游戏相同的 libc 去测试可读性，而「这个 API 返回了一个路径」丝毫不能说明对它 open() 能否
 * 成功。两半都需要。
 *
 * 这很重要，因为游戏的「导入存档」浏览器以 Arc 的外部存储路径为根，而 SdlFiles 是从 user.home
 * 推导出它的 —— 本启动器却把 user.home 指向自己的沙箱，于是浏览器打开在应用内部，玩家在那儿
 * 什么都放不了。这到底能不能修，取决于此处的答案。
 */
#define USER_DIRS_FILE "/data/storage/el2/base/haps/entry/files/user_dirs.txt"

/* [A] ArkTS 在切到游戏树【之前】写下它，本文件在【找到游戏的入口方法之后】删掉它。
 *
 * ⭐ 判据是这个不变量：**标记还在 ⟺ 从来没有走到游戏入口**。于是它同时覆盖两类
 * 现有的标记都看不见的失败：
 *   · JVM 根本没建起来（jvm_incomplete 能看到的那一类）
 *   · JVM 建起来了，但那个 jar 里【没有游戏】—— 这正是「玩家把一个 mod 当游戏选了」
 *     的情形，也是 2026-10-01 用户实际遇到的
 *
 * ⚠️ 第二类为什么两个旧标记都看不见：FindClass 找不到主类时这里是**干净地 return 1**，
 * 不是崩溃 ⇒ 不写 crash.txt；而 JVM 创建成功 ⇒ jvm_incomplete 已经在上面被 unlink 了。
 * 两条证据都不存在，而应用已经闪退过一次。
 *
 * ⚠️ 所以删除点必须在【拿到 main 方法之后】，不能在更早处：那之前的每一个
 * `return` 都表示「这个 jar 不是一个能跑的游戏」。
 */
#define LAUNCH_PENDING_FILE "/data/storage/el2/base/haps/entry/files/launch_pending"

/* [A] ⭐⭐ 版本隔离的拨杆 —— 整个功能的心脏就这一个文件。
 *
 * 玩家在启动器里选了「按版本隔离」之后，ArkTS 把结果写在这里，native 启动时读它、
 * 据此算出 -Duser.home=。⛔ 游戏不知道这件事存在：它只看到一个 user.home。
 *
 * 格式（与 user_dirs.txt 同一种 key=value，解析复用 read_kv）：
 *
 *     enabled=1
 *     key=b160.5
 *     granularity=build        ← ⛔ native 不用它，只为排障留痕
 *
 * ⭐ key 由 ArkTS 算，不在这里算：版本号的读取逻辑（version.properties 的解析）已经在 ArkTS
 * 里（短期 18 的 gameVersionOf）。让 native 再实现一遍 = 同一件事两份实现，
 * 而那正是本项目反复付代价的形态。
 *
 * ⛔ 文件不在时（全新安装、老版本升级上来）⇒ enabled 读到 0 ⇒ 用 DEST_ROOT ⇒
 * 【与今天逐字节相同】。这条是「默认不隔离」的落地证据，别让它失效。
 */
#define ISOLATION_FILE "/data/storage/el2/base/haps/entry/files/isolation.txt"

/* [A]
 * 隔离根。⛔ 它在 DEST_ROOT 之下、但在游戏那棵树【之外】 ——
 * 游戏的数据目录是 user.home 拼上 ARC 强加的 ".local/share/Mindustry"，
 * 所以 instances/ 永远不会被游戏当成数据看，粒度键与集合名都由我们说了算。
 *
 * 布局（A 阶段 sets 恒为 default，界面上看不见它）：
 *
 *     DEST_ROOT/instances/<粒度键>/sets/default/       ← -Duser.home 指到这里
 *                  …/.local/share/Mindustry/           ← 游戏自己建的那层
 *
 * ⚠️ 为什么现在就铺 sets/default 这一层：以后加「集合」功能时，若那时才加，
 * 就要把玩家数据从 <粒度键>/ 搬进 <粒度键>/sets/default/ —— 又一次「搬走玩家存档」。
 * 一层目录现在不花钱。
 */
#define ISOLATION_ROOT  DEST_ROOT "/instances"
#define ISOLATION_SET   "sets/default"

/* [B] read_kv 的定义在下面（与 read_user_dir 放在一起，因为两者共用同一套解析规则）。
 * 这里先声明，是因为下面的 resolve_user_home() 要用它 —— ⚠️ 少了这一行，
 * 那次调用会造出一个隐式声明（隐式声明是【非 static】的），于是后面那个
 * `static int read_kv` 变成「static 声明跟在非 static 声明之后」而编译失败。 */
static int read_kv(const char *path, const char *key, char *out, size_t outlen);

/*
 * 算出这次启动该用哪个 user.home，写进 out，并把结论记进 USERHOME_RECORD_FILE。
 *
 * ⭐ 三条不变量，改动时别破坏：
 *   1. 隔离关着 ⇒ 结果【逐字节等于 DEST_ROOT】。不是「等价」，是逐字节相同。
 *   2. 目录必须真的存在（不存在就 mkdir 出来）。让游戏在一个不存在的 user.home 上起，
 *      是「门关上了却没有开的路径」的同族。
 *   3. 任何一步失败 ⇒ 回退 DEST_ROOT 并说明原因。宁可回到不隔离，也不要起不来。
 *
 * ⚠️⚠️ 为什么还要写一个【文件】，而不是只 SDL_Log：
 *   这个函数在 `redirect_io()` **之前**运行（选项要早于 CreateJavaVM 备好，而重定向在更后面），
 *   所以这里的 SDL_Log 落在进程自己的 stderr 上、**不会进 DEST_ROOT/stderr.log**。
 *   ⇒ 只留日志的话，这个功能在设备上**没法验证** —— 而那正是最需要验证的一处。
 *   一个一行文件既能被 hdc 直接读走，也回答了排障时的第一个问题：「上次数据用的哪个目录」。
 */
#define USERHOME_RECORD_FILE DEST_ROOT "/userhome_used.txt"

/** [B] 把结论写进记录文件。失败就静默放过 —— 记录不下来不该拦住启动。 */
static void record_user_home(const char *reason, const char *home)
{
    FILE *f = fopen(USERHOME_RECORD_FILE, "w");
    if (!f) {
        return;
    }
    fprintf(f, "reason=%s\nhome=%s\n", reason, home);
    fclose(f);
}

static void resolve_user_home(char *out, size_t outlen)
{
    char enabled[8];
    char key[128];

    enabled[0] = 0;
    key[0] = 0;
    read_kv(ISOLATION_FILE, "enabled", enabled, sizeof(enabled));
    read_kv(ISOLATION_FILE, "key", key, sizeof(key));

    if (strcmp(enabled, "1") != 0 || key[0] == 0) {
        SDL_strlcpy(out, DEST_ROOT, outlen);
        SDL_Log("isolation: off, user.home=%s", out);
        record_user_home("off", out);
        return;
    }

    /* ⚠️ key 会进路径。只允许 [A-Za-z0-9._-]，别的一律回退 ——
     * 它由 ArkTS 从版本号拼出来，本该干净，但「本该」不是一道闸门。 */
    for (const char *p = key; *p; p++) {
        int ok = (*p >= 'A' && *p <= 'Z') || (*p >= 'a' && *p <= 'z') ||
                 (*p >= '0' && *p <= '9') || *p == '.' || *p == '_' || *p == '-';
        if (!ok) {
            SDL_Log("isolation: rejecting key '%s' (bad character), user.home=%s", key, DEST_ROOT);
            SDL_strlcpy(out, DEST_ROOT, outlen);
            record_user_home("bad-key", out);
            return;
        }
    }

    char home[512];
    SDL_snprintf(home, sizeof(home), "%s/%s/%s", ISOLATION_ROOT, key, ISOLATION_SET);

    /* mkdir -p：连着建 instances、<key>、sets、default 四层。
     * 逐段建，因为 mkdir() 不会替你建父目录。
     * ⚠️ 前三层失败【不算错】—— 可能是别的进程刚建好（EEXIST），而最后那一层会说明问题。 */
    {
        char partial[512];
        SDL_snprintf(partial, sizeof(partial), "%s", ISOLATION_ROOT);
        mkdir(partial, 0755);
        SDL_snprintf(partial, sizeof(partial), "%s/%s", ISOLATION_ROOT, key);
        mkdir(partial, 0755);
        SDL_snprintf(partial, sizeof(partial), "%s/%s/sets", ISOLATION_ROOT, key);
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
    SDL_Log("isolation: on, key=%s, user.home=%s", key, out);
    record_user_home("on", out);
}

/* [A]
 * 在 ArkTS 写下的文件里查一行 "key=value"。
 *
 * 返回拷贝的字节数（键不存在或文件不可读时为 0），这样调用方可以把一个系统属性留作未设置，
 * 而不是传一个空值 —— 一个空的 -Darc.sdl.chooserPath 会让游戏的文件浏览器打开在文件系统根，
 * 那比干脆不试还糟。
 *
 * ⚠️ 它带一个 path 参数（原先是硬编码 USER_DIRS_FILE），因为 isolation.txt 要用【同一种】
 * 解析规则。下面那条 "<threw>" 与空值的规则是踩出来的，复制一份就会分叉 ——
 * 本项目为「同一件事存在两处、其中一处先跑偏」付过好几次代价。
 */
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
        /* [A] 10 和 13 是 LF 和 CR。写成数字而不是字符转义，是因为这个文件已经过一次工具的
         * 处理，那个工具吃掉了反斜杠，在字符字面量里留下了一个真正的换行。 */
        while (n > 0 && (v[n - 1] == 10 || v[n - 1] == 13)) {
            n--;
        }
        /* [A] "<threw>" 是平台调用失败时 ArkTS 写的东西；它不是路径，所以当作不存在处理，
         * 而不是把它传下去。空值同样对待：-Darc.sdl.chooserPath= （空）会让游戏的文件浏览器
         * 打开在文件系统根，那比彻底不设这个属性还糟。 */
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

/** [B] 上面那个的薄包装：只读 USER_DIRS_FILE 里的一个键。 */
static int read_user_dir(const char *key, char *out, size_t outlen)
{
    return read_kv(USER_DIRS_FILE, key, out, outlen);
}

/* [A]
 * 加载【哪一个】游戏 jar —— 这是启动器形态的核心，所以这里写清楚它为什么是这样。
 *
 * 为什么它必须是一个运行期的决定
 *   自带的那份固定在 bundle 里（GAME_JAR），换一个游戏版本就意味着重新构建、重新
 *   签名、再装一遍 171 MB。而启动器要做的是：玩家自己把若干个版本的 jar 丢进
 *   Downloads 里本应用的那个文件夹，在界面上挑一个。于是「用哪个 jar」从一个编译期
 *   常量，变成一个每次启动都要问一次的问题。
 *
 * 为什么复用 user_dirs.txt，而不是另开一个文件
 *   那个文件已经在了，它的解析（read_user_dir）已经写好、已经在设备上跑过，而且它
 *   已经在处理两种边界：键不存在（返回 0）、以及值不可用（ArkTS 写下的 "<threw>"）。
 *   另开一个文件等于把这三件事再实现一遍 —— 本项目因为「同一份知识存在两处、其中
 *   一处先跑偏」栽过好几次，不值得为一行格式再冒一次。
 *
 * 为什么存的是【路径】而不是索引或名字
 *   两侧对「有哪些 jar」的看法必须只有一个来源。界面是 ArkTS 画的，所以那个来源是
 *   ArkTS；它把选中的绝对路径写下来，native 只负责打开它，不去自己重扫一遍那个目录。
 *
 * ⚠️ 两个分支都必须能【打开】才算数
 *   选中项 → 自带的 → 都没有（调用方据此拒绝启动）。
 *   一条写在那里、但文件已经被删掉或根本不是 jar 的路径，必须【落回】自带游戏，
 *   而不是让启动失败：玩家删掉一个 jar 文件是常事，那不该把应用变成起不来。
 *
 * ⚠️ 这里的规则与 Index.ets 的 gameAvailable() 是【同一条】。它那份存在，只是因为
 *   ArkTS 必须在挂载 XComponent【之前】就决定要不要走启动器界面，而 native 那个
 *   时刻还没有跑。两处都要改。
 */
static char game_jar_path[512];

/** [B] 它存在、而且头两个字节是 'PK'（一个 ZIP/jar）时为真。 */
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

/** [A] 把要加载的 jar 解析进 game_jar_path。解析出来时为 1，两个来源都没有时为 0。 */
static int resolve_game_jar(void)
{
    if (read_user_dir("gamejar", game_jar_path, sizeof(game_jar_path)) > 0) {
        if (is_readable_jar(game_jar_path)) {
            SDL_Log("   game jar: %s  (chosen in the launcher)", game_jar_path);
            return 1;
        }
        /* [A] 值得单独一行：这一条正是「玩家删了一个 jar」在日志里留下的样子，
         * 而它后面的那行说清了接下来会发生什么。 */
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

/* [A]
 * 玩家选了哪种操作方案，跨启动持久化。
 *
 * Mindustry 用【一个 bit】决定它整个输入层和 UI：
 *
 *     Vars.mobile = Core.app.isMobile() || Vars.testMobile;
 *
 * 而它游戏内的开关并不碰这个 bit —— 它只调用 control.setInput(...)，于是输入处理器变了、
 * UI 却仍旧是移动端。用户在平板上实测到，并在字节码里得到确认：Vars.mobile 恰好只有一个写入者，
 * 就是 Vars.init() 里的那一行。
 *
 * 所以要让玩家有真正的选择，必须在 Vars.init() 运行【之前】就设好这个 bit —— 也就是在 JVM
 * 启动之前 —— 这意味着到那时答案必须已经在磁盘上了。玩家点按钮时由 ArkTS 写这个文件；native
 * 从不写它，所以启动时一次单纯读取就够了。
 *
 * 文件不存在意味着移动端：这是本启动器在该设置存在之前硬编码的行为，所以一个从不碰那个按钮的
 * 安装，行为与它一向完全一致。
 */
#define CONTROL_MODE_FILE "/data/storage/el2/base/haps/entry/files/control_mode.txt"

static int read_control_mode_mobile(void)
{
    FILE *f = fopen(CONTROL_MODE_FILE, "r");
    if (!f) {
        return 1;                       /* [B] 没记录：保持移动端 */
    }
    int mobile = 1;
    char line[32];
    if (fgets(line, (int) sizeof(line), f)) {
        /* [A] "desktop" 是唯一能关掉它的值。其它任何东西 —— "mobile" 这个词、空文件、
         * 截断的写入 —— 都让默认值保持不变，这样一个损坏或只写了一半的文件，不会在玩家不知情的
         * 情况下悄悄换掉他的操作方式。 */
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

        /* [A] opendir 才是关键问题：游戏必须先【列出】目录，才能从里面挑出一个文件。
         *
         * 目录项不是文件，把它们当成文件来计数会误导 —— 这个的第一版统计了每个名字「最后一个点
         * 之后的部分」，于是一个含有 com.huawei.browser/ 和 com.huawei.music/ 的 Download 文件夹
         * 报出了扩展名 "browser" 和 "music"。它们不是扩展名，是包名。现在计数被拆开，
         * 输出如实说明它测量了什么。
         *
         * 用 stat() 而不是 dirent 的 d_type：d_type 依文件系统不同允许是 DT_UNKNOWN，而悄悄把
         * 一切都错分成「不是目录」，会复现出这正是要修的那个错误答案。
         *
         * 扩展名统计之所以存在，是因为「浏览器开到这儿却什么都没显示」有两个不同的原因：应用
         * 看不见这个目录，或者它看得见、但文件不匹配游戏要求的过滤条件。有【两条】导入路径，
         * 各自的过滤条件【不同】—— 从 jar 的字节码里实测到，LoadDialog 传 {"msav"} 取单个存档，
         * 而 SettingsMenuDialog 传 {"zip"} 取整份数据导出 —— 所以一个文件可以完全可读，却仍然
         * 不出现在玩家恰好打开的那个对话框里。在这里统计扩展名，无需再构建一次就能回答这点。 */
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
                dirs++;   /* [B] 一个包目录、.zip 文件，随便什么 —— 都不是扩展名 */
                continue;
            }
            files++;

            const char *dot = strrchr(e->d_name, '.');
            if (!dot || dot == e->d_name) {
                continue;  /* [B] 没有扩展名，或者是像 .nomedia 这样的点文件 */
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

            /* [A] 只记不重复的扩展名。按 token 边界匹配而不是用 strstr，这样 ".so" 不会在
             * ".something" 里被「找到」。 */
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

/* [A]
 * Native 代码只能从 HAP 的只读区执行，绝不能从应用的可写沙箱执行。设备上实测：
 *   dlopen("/data/storage/el1/bundle/libs/arm64/libSDL3.so")            -> OK
 *   dlopen("/data/storage/el2/base/files/.../libcxxabi_shim.so")        -> FAIL
 *   ……而且对该文件 chmod 0755 也【没有】帮助。
 * 这就是通常的 W^X 规则：el2（可写）不可执行。
 * 所以【整个】JDK 都作为预构建库放在 entry/libs/arm64-v8a/ 下，并落进可执行区 —— 包括
 * module image，它能被分发只是因为被改名成了 "jimg.so"（见 patch_libjvm.py）。启动时什么都不
 * 写进沙箱。
 */

/* [A]
 * libjvm.so 必须住在哪，以及为什么：
 *   HotSpot 从 libjvm.so 自身的位置推导 java.home ——
 *   它剥掉三层路径分量（见 os_linux.cpp 里的 os::init_system_properties_values()），
 *   然后要求 "<java.home>/lib/modules" 存在：
 *
 *       Arguments::set_java_home(buf);          // 无条件，忽略 -Djava.home
 *       if (!set_boot_path('/', ':'))
 *           vm_exit_during_initialization("Failed setting boot class path.");
 *
 *   如果 libjvm.so 被拍平到 ABI 目录里，推导结果会落到 .../bundle 上，那里没有
 *   <module image> -> "Failed setting boot class path."。
 *
 *   所以真正的 JVM 保持嵌套在 <JDK_HOME>/lib/server/libjvm_real.so，这让 java.home 得到
 *   <JDK_HOME> —— 正是 module image 和 conf/ 所在的地方。
 *
 *   这是经验验证过的，不是假设：早先的尝试确实从可写沙箱里 dlopen 了 JVM（已知 AMCL 就是
 *   从 /data/app/el2/... 跑它的 JVM 的），而对我们【没有】成功 —— 成功的那份副本是 HAP 里的
 *   那份。bundle 区是本启动器唯一依赖的路径。
 */

static int g_files = 0;
static long long g_bytes = 0;

/* [A]
 * ---------------------------------------------------------------------------
 * 我们在哪？—— 运行时发现，而非假设。
 *
 * ABI 目录名在两个命名空间里【不是】同一个字符串：
 *     在 HAP 内                 libs/arm64-v8a/...
 *     在设备上                  /data/storage/el1/bundle/libs/arm64/...
 * 搞错它是无声的：每次 dlopen 都只是以 "no such file" 失败。
 *
 * 我们本可以硬编码它，但其中有一个字符串【不是】我们能选的：anchor 库的 DT_NEEDED 里带着一条
 * 由 prep_vendor.py 在【链接时】烙进去的设备绝对路径。如果那个字符串与现实不符，别的什么都无法
 * 补偿。所以与其猜，不如向 loader 询问我们此刻正运行在其中的这个库的路径 —— 对我们自己的某个
 * 函数做 dladdr() 会返回 libmain.so 的真实路径，而它的目录【就是】lib 目录。
 *
 * 这让答案权威且能自我纠正，并且给构建时的那个字符串一个可供对照的东西。
 * ---------------------------------------------------------------------------
 */
#define ABI_DIR_GUESS "/data/storage/el1/bundle/libs/arm64"

static char g_root[1024];       /* [B] <bundle>/libs/<abi>            */
static char g_jdkhome[1200];    /* <root>/jdk21                   */
static char g_jdklib[1400];     /* <jdkhome>/lib                  */
static char g_jvmreal[1500];    /* <jdklib>/server/libjvm_real.so */
static char g_anchor[1400];     /* <root>/libjvm.so               */

/* [B] 定义在下面更远处，但 diagnose_loading() 需要它们而它排在前头。 */
/* [A]
 * probe_exec_mem() 的结果：匿名 RWX 内存可用时为 42，mmap 被拒时为 -1，映射成功但里面的代码
 * 没跑起来时是别的值。
 *
 * 刻意初始化成一个【不是 42】的值。选项组装会把「不是 42」当作「JVM 拿不到可执行内存」并强制
 * -Xint，所以万一探测没跑成，被采纳的就是那个安全的答案。今天这不会发生 —— diagnose_loading()
 * 会调用该探测，且远在选项被组装之前就运行 —— 但在另一个方向上出错的代价，是一个装得上、
 * 然后毫无解释地卡死的应用，而这正是这一整套安排存在的意义所在。
 */
static long g_exec_probe_result = -2;
static long probe_exec_mem(void);
static void probe_icache(void);
static void report_mapping(unsigned long addr, char *out, size_t cap);

static void joinp(char *dst, size_t cap, const char *a, const char *b)
{
    SDL_snprintf(dst, cap, "%s%s", a, b);
}

/* [B] 如果 dladdr 给了我们一个可用的目录就返回 1 */
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

    /* [B] 如果发现失败，就回退到那个猜测，好让我们仍然能拿到诊断信息 */
    int discovered = (g_root[0] != '\0');
    if (!discovered) SDL_strlcpy(g_root, ABI_DIR_GUESS, sizeof(g_root));

    joinp(g_jdkhome, sizeof(g_jdkhome), g_root, "/jdk21");
    joinp(g_jdklib,  sizeof(g_jdklib),  g_jdkhome, "/lib");
    joinp(g_jvmreal, sizeof(g_jvmreal), g_jdklib, "/server/libjvm_real.so");
    joinp(g_anchor,  sizeof(g_anchor),  g_root, "/libjvm.so");

    /* [A] 编译时的选择对得上吗？这是我们在运行时唯一无法修复的一件事，所以把它明明白白说出来，
     * 而不是稍后以一条含糊的错误失败 */
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

/* [A]
 * 解包机制没有了：JDK 现在直接从 HAP 的 lib 区运行（见上面的 JDK_HOME），所以没什么要解压的，
 * 也没有标记要留。这也移除了「首次启动写入 165 MB」的开销以及随之而来的整整一类 bug（其中包括
 * 一个符号链接失败却悄悄删光所有库的）。
 */

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

/* [B] ------------------------------------------------------------- JVM 启动 */

/* [B] ---------------------------------------------------------- stdio + 崩溃 */

/* [A]
 * 把 stdout/stderr 重定向进可写沙箱。
 *   JVM 在那里报告启动失败，而我们无法通过 hdc 看到它们，所以没有这个，一次失败就只是
 *   「进程死了」。（AMCL 用它的 "[Phase 4] REDIRECT_IO" 做同样的事。）
 */
static void redirect_io(void)
{
    int fo = open(DEST_ROOT "/stdout.log", O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fo >= 0) { dup2(fo, 1); if (fo > 2) close(fo); }
    int fe = open(DEST_ROOT "/stderr.log", O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fe >= 0) { dup2(fe, 2); if (fe > 2) close(fe); }
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
}

/* [B] 报告一个致命信号，并通过 dladdr 报告该地址属于哪个库。 */
/* [B] 当前线程的名字，用于崩溃报告 —— 见 on_fatal_signal() */
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

    /* [A]
     * 对 SIGILL，把出错指令处的字节 dump 出来。
     *
     * 这能区分代码在这里陷入陷阱的两种截然不同的原因：
     *   - 这些字节【不是】合法的 aarch64 指令 -> HotSpot 为本设备没有的 CPU 特性生成了代码；
     *   - 这些字节【是】合法指令                -> 写入到达了内存但没有到达指令缓存，也就是
     *     一致性问题。
     * 两者作为修复毫无共同之处，而单看地址无法把它们区分开。
     *
     * 只在所属映射可读时才读取，这样一个糟糕的猜测不会把一次崩溃变成两次。
     */
    /* [A]
     * dump 出错时刻的 CPU 寄存器。
     *
     * 这是整个调查一直缺失的那次测量。单看出错地址，无法区分「代码是错的」和「控制流到达了
     * 它不该到的地方」，而这两者作为修复毫无共同之处。寄存器能说明是哪种：在 aarch64 上，
     * HotSpot 的解释器这样分发
     *     adrp x21, <dispatch table page> ; add x21, x21, #off
     *     ldr  x9, [x21, w9, uxtw #3]     ; br x9
     * 所以 x21 持有代码【以为】自己有的分发表，而 x9（或者 br 实际用的那个寄存器）持有它实际
     * 去的地方。
     */
    /* [A]
     * 说出【出错指令】所在的那个模块，以及它跑在哪个线程上。
     *
     * si_addr 说的是什么被碰了，而不是什么碰的它，对于一个位于小偏移处的错误，它通常就是
     * 0x20 之类、什么都指不出来的值 —— dladdr 会报 "in ?"。程序计数器正好相反：它永远是一个
     * 真实映射里的真实地址，所以它能回答「是哪个库，还是 code cache 里 JIT 生成的代码」，
     * 这才是第一个值得知道的事。线程名把游戏线程上的错误和 SDL UI 事件路径上的错误区分开，
     * 而这两者指向完全不同的代码。
     */
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
        /* [A]
         * 把周围的 CODE CACHE 作为原始字节 dump，而不是文本。
         *
         * 它要回答的问题是：HotSpot 对 code cache 的模型，是否与内存里实际的东西一致。
         * -XX:+PrintStubCode 会打印 HotSpot 相信自己生成的每一个 stub，连同它的地址和字节；
         * 如果原始内存与之不符，那就是有什么正在往 code cache 里写、而本不该写，这不是调多少
         * JVM flag 能修好的。
         *
         * 一个 160 字节的十六进制窗口回答不了这个问题，而文本又让对比变得有损。所以写二进制，
         * 离线用同一个反汇编器去读。
         */
        /* [A]
         * 从基址开始 dump 【整个】映射。
         *
         * -XX:+PrintStubCode 会打印每一个 stub 及其地址和字节，而在相同选项下 code-cache 的
         * 基址跨运行是稳定的，所以打印出的地址可以直接与这些字节对比。正是这个对比，才能区分开
         * 两种要紧的解释：
         *   - 内存与打印一致  -> HotSpot 生成的正是这个，异常出在「如何到达它」上，而不是
         *     「存了什么」上；
         *   - 内存与打印不同  -> 有什么往 code cache 里写了、而本不该写，没有任何 JVM flag 能
         *     修好它。
         * PC 周围的一个窗口回答不了它，因为值得检查的那些 stub 在这个映射的别处。
         */
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

/* [C]
 * 我们为什么要 preload：
 *   libjvm.so 的 DT_NEEDED 是 [libcxxabi_shim.so, libc.so]。那个 shim 是这个临时拼装 JDK
 *   构建的私有库，住在 <java.home>/lib 下，而那里【不在】动态链接器的搜索路径上。所以第一次
 *   dlopen libjvm.so 时，以 musl 那句没用的 "No error information" 失败了。
 *
 *   修法：我们自己对 <java.home>/lib 下的每个 .so 用 RTLD_GLOBAL 做 dlopen，这样当 loader
 *   稍后解析 libjvm.so 的 DT_NEEDED 时，能按 SONAME 找到已经加载的库。libjvm.so 自己放在最后
 *   并且 global，因为 libjava.so（及其同类）声明了对它的 NEEDED。
 *   这和移动端 Java 启动器用的是同一个招数。
 */
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

/* [B] 这个文件是 ELF 共享对象吗？（该目录里还放着 jimage，名字也叫 *.so） */
static bool is_elf(const char *path)
{
    int fd = open(path, O_RDONLY);
    if (fd < 0) return false;
    unsigned char m[4];
    ssize_t n = read(fd, m, 4);
    close(fd);
    return n == 4 && m[0] == 0x7f && m[1] == 'E' && m[2] == 'L' && m[3] == 'F';
}

/* [A]
 * 加载顺序很重要。其它每个 JDK 库（libjava、libnet、libnio、libjimage……）都声明了对裸名
 * "libjvm.so" 的 DT_NEEDED，而这个目录不在 loader 的搜索路径上，所以 libjvm.so 必须【最先】
 * 用完整路径加 RTLD_GLOBAL 被带进来。其它库随后针对已加载的那个库解析各自的依赖。反过来做，
 * 就是产生一整堵 "libjvm.so: (needed by ...)" 失败的根源。
 */
/* [A]
 * 注意：preload 循环【没有了】，这是一次有实质意义的改动。
 *
 * 它存在过，是为了一个更老的布局：那时真正的 libjvm.so 坐在 <java.home>/lib/server/ 下，带着
 * 对 JDK 私有 C++ shim 的 DT_NEEDED，而那个 shim 不在 loader 的搜索路径上 —— 所以在 libjvm.so
 * 能被加载之前，每个 JDK 库都必须手工用 RTLD_GLOBAL 做 dlopen。
 *
 * 当前布局已经解决了这一点：libjvm_real.so 只有 libcxxabi_shim.so 和 libc.so 这两个依赖，而
 * 我们的 shim 就在搜索路径上。剩下的那些 JDK 库，是 JVM 自己按完整路径、从 sun.boot.library.path
 * 加载的 —— 和其它平台上的做法一样。
 *
 * 留着这个循环并非无害：它会把 35 个库推进全局符号作用域，排在 JVM【前面】，于是它们与
 * libjvm.so 共享的任何名字都可能被插入覆盖到 HotSpot 自己的调用上。JVM 不是照着能扛住这种情况
 * 写的，而这很可能是「跳进数据里」的一个来源。
 */
static void load_anchor_only(void)
{
    SDL_Log(" --- dlopen diagnostics ---");
    try_dlopen("libSDL3.so", "control: SDL3");
    try_dlopen(g_anchor, "anchor libjvm.so");
    SDL_Log(" --- end diagnostics ---");
}

/* [A] option 字符串：JVM 可能往这些里写，所以它们必须可修改 */
static char opt_classpath[1024];   /* [C] 四条；今天 512 够放三条 */
static char opt_home[512];
static char opt_tmpdir[512];
static char opt_libpath[512];
static char opt_encoding[512];
static char opt_headless[512];
static char opt_bootlib[512];
static char opt_errfile[512];
static char opt_heap[512];
/* [A] 决定 JVM 到底能不能启动的两个 flag —— 见 start_jvm() */
static char opt_unsve[512];
static char opt_sve[512];
/* [A]
 * 三个平台属性，作为 VM 创建选项提供，而不是放进运行时选项文件，因为游戏的平台检测在类初始化
 * 时就读它们，早于任何我们能从 Java 侧设置、并且能生效的东西。
 *
 *   os.name      JVM 通过它向 Java 报告宿主 OS。游戏里每一次 LWJGL/Arc 的 native 查找都以它为
 *                依据，而本设备上已知可用的参考配置在这里报 "Linux" —— 若用真实值，游戏会去找
 *                这个布局里并不存在的 HarmonyOS/Android natives。
 *   user.home    游戏存放存档和设置的地方。没有它，JVM 会从 /etc/passwd 猜，而这里并没有那个
 *                文件。
 *   user.dir     启动时相对路径的工作目录。
 *
 * 出处：这些需要设置，是从一个在同一设备上运行、已知可用的参考启动器里学到的，不是来自任何公开
 * 来源。我们自己的笔记对「那个参考如何提供它们」说法不一 —— 是作为创建选项，还是在 VM 起来后
 * 通过 System.setProperty —— 但在这里无关紧要：它们必须在类初始化之前就位，所以本启动器在创建
 * 时传入。只有 os.name 的值照搬参考；user.home 和 user.dir 是本启动器自己的沙箱路径
 * （DEST_ROOT）。
 */
static char opt_osname[512];
static char opt_userhome[512];
static char opt_userdir[512];
/* [B] LWJGL 从哪里找它用来分发的 natives —— 见 LWJGL_LIBS */
static char opt_lwjglpath[512];
/* [A]
 * 告诉 Arc 的 SDL 后端去要 OpenGL ES profile。
 *
 * OpenHarmony 只带 OpenGL ES 和 Vulkan，根本没有 libGL.so，所以一个 core 或 compatibility
 * 请求会绑定 EGL_OPENGL_API、找不到任何 config，窗口就创建不出来。Arc 自己没法想明白这点，
 * 所以在这里替它做选择。由 SdlApplication.profile() 读取；见那里的 arc.sdl.glEs。
 */
static char opt_gles[512];
/* [A]
 * 告诉 Arc 这是一台触屏设备。
 *
 * 后端从 getType() 得到 isMobile() 的答案，而它只可能是 android 或 iOS，所以在这里是 false，
 * 于是 Mindustry 从那一个 bit 决定它整个输入层：
 *
 *     input = Vars.mobile ? new MobileInput() : new DesktopInput();
 *
 * false 意味着平板拿到的是 WASD 键位、没有摇杆、也没有屏幕按钮 —— 一个跑在触屏上的桌面版，
 * 而这正是它当时看起来的样子。由 SdlApplication.isMobile() 读取；见那里的 arc.sdl.mobile。
 */
static char opt_mobile[512];

/* [A]
 * 游戏的文件浏览器应该从哪里打开。
 *
 * 游戏把它根植在 Arc 的 getExternalStoragePath() 上，而 SdlFiles 是从 user.home 算出它的 ——
 * 而 user.home 是本启动器自己的沙箱，正是玩家放不了文件的那个地方。所以「导入存档」能浏览，
 * 却永远找不到任何可导入的东西。
 *
 * 这个值不是硬编码的：ArkTS 向平台要它真实的用户可见目录（environment.getUserDownloadDir），
 * 写到 user_dirs.txt，这里再读回来。这样就把一个设备相关的路径挡在启动器之外，而它背后的那个
 * 权限（运行时授予）才是让该目录变得可读的原因 —— 实测过，见 probe_user_dirs()。
 */
static char opt_chooser[512];

/* [A]
 * 有序探测。"Error loading X: (needed by Y)" 对于「链条的哪一环断了」是含糊的，所以把每个
 * 问题分开问，并用各自的 dlerror() 打印答案。这里的一切都是只读的。
 */
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
    /* [A] 与真正的加载用同样的 flag —— 一个用 RTLD_NOW 的探测，会把一个在 lazy 模式下其实能
     * 正常加载的库报成失败。 */
    void *h = dlopen(path, RTLD_LAZY | RTLD_GLOBAL);
    if (h) {
        SDL_Log("   OK  %-20s %s", label, path);
    } else {
        SDL_Log("   NO  %-20s %s", label, path);
        SDL_Log("         -> %s", dlerror());
    }
}

/* [A]
 * 一份简短的、有序的问题清单，它们的答案彼此无法推断：文件在不在，它是什么 mode，CONTROL 能
 * 不能加载，JVM 的那两块能不能加载。本启动器早先的几轮，在一个像
 *      Error loading shared library X: (needed by Y)
 * 这样的含混消息上浪费了大量时间，而它与十来种不同原因都相容。
 *
 * 刻意保持窄小 —— 那些找出真正 bug 的 A/B 实验（一张损坏的 .dynamic 表，见 patch_libjvm.py）
 * 已经完成了它们的使命，它们的探测文件也没了。
 */
/* [A]
 * 一个 HAP 资源文件，能否作为一个【普通文件系统路径】被访问到？
 *
 * 这比它看起来更重要。hvigor 从 entry/libs/ 只分发 `*.so`，所以走那条路的 JDK 会丢掉每一个
 * 数据文件 —— `modules`（逼出了 jimg.so 这个改名）、`conf/`、`release`、`classlist`、
 * `jvm.cfg`。而 HAP 的 rawfile 区没有这种过滤：凡是放在 resources/rawfile 下的都原样进去，
 * 名字完好。
 *
 * 如果那个区在应用的 bundle 目录下也以一个真实路径存在，那么【整个未修改的 JDK】都能在那里
 * 分发 —— 这会一下子去掉改名、缺失的配置文件，以及对自定义 ELF loader 的需要。
 *
 * 所以：在项目里放一个 `resources/rawfile/rawfile_probe.txt`，构建，然后问正在运行的应用，
 * 那些看似合理的路径里究竟哪一条能解析到。只有应用能看见它自己的 bundle 区；hdc 不能。
 */
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

/* [A]
 * 这个进程到底能不能访问到系统的 EGL/GLES？
 *
 * SDL 的 OpenHarmony 视频驱动恰好加载两个名字，用的是裸名而不是路径：DEFAULT_EGL "libEGL.so"
 * 和 DEFAULT_OGL_ES2 "libGLESv3.so"。两个文件在设备上都存在（/system/lib64），所以
 * SDL_CreateWindow 以 "Could not initialize OpenGL / GLES library" 失败，意味着加载被拒绝，
 * 而不是文件不存在 —— 这是两个非常不同的问题。
 *
 * 裸名很关键：裸名会走 linker 为这个进程设置的搜索路径，而对一个应用而言那是一个受限命名空间，
 * 而绝对路径要么能解析、要么不能。同时问这两种形式，就能把「不在搜索路径上」与「根本不被允许」
 * 区分开。
 */
static void probe_gl_libs(void)
{
    static const char *names[] = {
        "libEGL.so",
        "libGLESv3.so",
        "libGLESv2.so",
        "/system/lib64/libEGL.so",
        "/system/lib64/libGLESv3.so",
    };
    /* [A]
     * 两种绑定模式都测，因为 SDL 用的是 RTLD_NOW：
     *
     *     handle = dlopen(sofile, RTLD_NOW | RTLD_LOCAL);   // SDL_sysloadso.c
     *
     * LAZY 在首次调用时才解析函数重定位，所以一个带有无人提供之符号的库仍然能加载。NOW 则
     * 把所有东西都提前解析并拒绝。如果只测一种模式，一个懒加载能成、急加载失败的库，就与一个
     * 缺失的库无从区分 —— 而这个项目已经被这点骗过一次了，就在 __cxa_thread_atexit 上。
     */
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

/* [A]
 * 把游戏的 SDL 瞄准系统的 GLES 库。
 *
 * Arc 的 SDL 后端从不索要 ES profile —— 它只会设 CORE 或 COMPATIBILITY —— 而 SDL 的
 * OpenHarmony 驱动【只有】在 profile 是 ES 且主版本号大于 1 时才加载 libGLESv3.so：
 *
 *     if (_this->gl_config.profile_mask == SDL_GL_CONTEXT_PROFILE_ES) {
 *         if (_this->gl_config.major_version > 1) {
 *     #ifdef DEFAULT_OGL_ES2          // "libGLESv3.so" on OpenHarmony
 *             opengl_dll_handle = SDL_LoadObject(path);
 *     #endif
 *         } else {
 *     #ifdef DEFAULT_OGL_ES           // not defined on OpenHarmony
 *     #endif
 *         }
 *     } else {
 *     #ifdef DEFAULT_OGL              // not defined on OpenHarmony
 *     #endif
 *     }
 *
 * OpenHarmony 只定义了 DEFAULT_OGL_ES2，所以用 CORE 或 COMPATIBILITY profile 时什么都
 * 不加载，窗口创建以 "Could not initialize OpenGL / GLES library" 失败 —— 那读起来像是缺库，
 * 但并不是。libEGL.so 和 libGLESv3.so 从这个进程里都能正常加载，按裸名和按路径、懒加载和
 * 急加载都行；这在这段代码写下之前就测过了。
 *
 * SDL_HINT_OPENGL_LIBRARY 在上述任何分支之前就被检查，所以它是唯一一个不需要改动 Arc 的
 * 杠杆。SDL_HINT_OPENGL_ES_DRIVER 听起来像是对的那个旋钮，但它只被 Windows、X11 和 Cocoa
 * 后端查询，共享的 EGL 路径从不看它。
 *
 * 这个 hint 必须设在【游戏】将要使用的那个 SDL 实例上，而不是本启动器链接的那个：游戏通过
 * LWJGL 到达 SDL，而 LWJGL 加载的是 LWJGL_LIBS 里的那份副本。dlopen 同一个路径返回的是同一个
 * 映射，所以经由它设置 hint 能到达正确的实例。
 */
static void configure_game_sdl(void)
{
    const char *sdlpath = BUNDLE_LIBS "/libSDL3.so";

    /* [A]
     * bundle 里不止一个 libSDL3.so，而那个显而易见的假设 —— 游戏用的是 LWJGL jars 旁边的那
     * 一个 —— 值得在信任它之前先验证，因为两份副本都是用
     * -DCMAKE_PLATFORM_NO_VERSIONED_SONAME=1 构建的，因此都带着 SONAME "libSDL3.so"。一个
     * 按 SONAME 解析的 loader 会返回先加载的那份副本，而在这里那就是启动器自己的。那么在另一个
     * 映射上设置 hint 就会显得像是生效了，其实什么都没变。
     *
     * SDL_GetHint 的地址能回答它：地址相同就意味着是同一个实例。
     */
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

    /* [A]
     * 两条路都走，因为哪条要紧取决于上面的答案：直接调用是启动器自己的 SDL，句柄那条路是那个
     * 路径实际解析到的东西。两边都设没有代价，还免去了必须把实例问题答对的需要。
     *
     * priority 2 是 SDL_HINT_OVERRIDE，最高级，所以之后运行的任何东西都无法悄悄无视它。
     */
    struct { const char *k, *v; } hints[] = {
        { "SDL_OPENGL_LIBRARY", "/system/lib64/libGLESv3.so" },
        { "SDL_EGL_LIBRARY",    "/system/lib64/libEGL.so"    },
    };
    typedef bool (*set_prio_t)(const char *, const char *, int);
    set_prio_t viaHandle = h ? (set_prio_t)dlsym(h, "SDL_SetHintWithPriority")
                             : NULL;

    for (unsigned i = 0; i < sizeof(hints) / sizeof(hints[0]); i++) {
        /* [A] 是 bool，不是 SDL_bool：SDL3 改了名，而旧名字现在展开成一个刻意未声明的标识符，
         * 好让过时的代码构建失败，而不是悄悄类型不匹配。 */
        bool direct = SDL_SetHintWithPriority(hints[i].k, hints[i].v,
                                              SDL_HINT_OVERRIDE);
        bool via = viaHandle ? viaHandle(hints[i].k, hints[i].v, 2) : false;
        SDL_Log("   %-20s = %-30s direct=%s handle=%s -> now reads '%s'",
                hints[i].k, hints[i].v, direct ? "ok" : "REFUSED",
                via ? "ok" : "-", SDL_GetHint(hints[i].k));
    }

    /* [A]
     * 让每个实例去做游戏 SDL 内部会做的那个加载，做不到就让它说明原因。
     *
     * hint 在两份副本上都设了，也在两边都正确读回，而游戏仍然报同样的失败 —— 所以 hint 在这里
     * 不是要紧的东西。这里问的是 hint 当初替它顶着的那个问题：【这个】实例到底能不能加载系统
     * GLES 库？通过一条路径加载的库，可能与通过另一条加载的落在不同的 linker 命名空间里，而一个
     * 看不见 /system/lib64 的命名空间，会解释一切，同时看起来活像一个缺失的文件。
     */
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

/* [B] 把 src 拷到 dst，以 mode 0755 创建 dst */
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

/* [A]
 * 这个进程能不能 dlopen 一个位于它【自己】可写区里的库？
 *
 * 这是整个 JDK 放置设计所系的那个问题，而记录在案的答案（「不能，沙箱不可执行」）来自单个样本
 * —— 一个可能因为自身原因而失败的手写 shim。那不是一个足够好的依据，而出错的代价很高：如果
 * libarcarm64.so 能从一个可写目录加载，Arc 自己的解包就能工作，什么都不用特殊处理；如果不能，
 * 整个 native 布局都得改。
 *
 * Arc 的 loader 把这个库放进 java.io.tmpdir。在 AMCL 下那个目录是模块级 files 目录，游戏能跑；
 * 这里它是应用级 temp 目录，加载以 EINVAL 失败。两者都是可写的，所以差别如果真实存在，就在它们
 * 如何被挂载上 —— 而候选只有屈指可数的几个。
 *
 * 所以：用两个不同的库（单个样本无法区分一条平台规则和一个文件自身的属性），拷进每一个候选
 * 目录，各自 dlopen，各自用它自己的 dlerror 报告。bundle 里的那份是对照：它必须成功，否则探测
 * 本身就坏了。
 */
static void probe_sandbox_exec(void)
{
    static const char *srcs[] = {
        BUNDLE_LIBS "/lwjgl/liblwjgl.so",
        BUNDLE_LIBS "/libSDL3.so",
    };
    static const char *names[] = { "liblwjgl.so", "libSDL3.so" };
    static const char *dirs[] = {
        DEST_ROOT,                                    /* [B] 应用级 files   */
        DEST_ROOT "/execprobe",
        TMP_DIR,                                      /* [B] 应用级 temp    */
        TMP_DIR "/execprobe",
        "/data/storage/el2/base/haps/entry/files",    /* [B] 模块级 files，
                                                       * 也就是 AMCL 解包
                                                       * 到的地方           */
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

/* [A]
 * 额外的 JVM 选项，运行时从应用自己沙箱里的一个文件读取。
 *
 * 为什么有它：试一个 -XX flag 过去要付出一整套重建、重签、重装 171 MB HAP 并重启的代价 ——
 * 每次猜测好几分钟，而这个问题（「哪个 flag 能止住陷阱？」）需要猜很多次。沙箱目录应用可写、
 * hdc 可读，所以用 `hdc file send` 推一个纯文本文件进去，就把那个循环变成几秒钟。
 *
 * 每行一个选项；空行和以 # 开头的行被忽略。
 */
/* [A]
 * 本启动器自己提供多少个选项，在运行时选项文件追加的任何东西之前。
 *
 * 它是一个具名常量，因为它被用作数组上界和索引基点，共五处；当它还是一个光秃秃的 11 时，
 * 加一个内置选项就意味着要把它们每一处都找出来，漏掉一处就会悄悄丢掉选项、或者读过数组已填充的
 * 部分。
 */
#define BASE_OPTS 18
#define MAX_EXTRA_OPTS 32
static char g_extra[MAX_EXTRA_OPTS][256];

/* [A] 候选位置，按顺序尝试。
 *
 * 警告：这里【曾经】有第三个条目 —— "/data/local/tmp/jvm.options" —— 它已于 2026-09-22 被
 * 移除，因为它不可能工作。实测：文件用 `hdc file send` 推到了那里，从 shell 里可读，而启动器
 * 仍然报告 "no options file found; tried 3 locations" —— 每一次 fopen 都失败。
 * /data/local/tmp 对这个应用的 uid 不可达。周围的注释把它描述成「不用重建就能调 flag」的迭代
 * 通道，所以一个永远打不开的条目起到了实实在在的误导作用：它让「该 flag 没有效果」看起来像是
 * 关于该 flag 的结论。
 *
 * 真正管用的迭代通道是第二个条目 DEST_ROOT —— 而且方向与旧注释所称的相反：hdc 能【读】它
 * （它在沙箱的公开视图上）但不能写它，所以是应用写、shell 读。 */
static const char *OPTION_PATHS[] = {
    /* [A] ArkTS 从启动参数写到这里 —— 见 EntryAbility.ets。
     * context.filesDir 解析到 ability 自己的 files 目录，它【不是】DEST_ROOT 那个目录
     * （那一个是应用级 files 目录）。
     *
     *  平台版本回退就是这样工作的：在低于 API 26 的手机上，JVM 拿不到匿名可执行内存，必须解释
     *  执行，所以 ArkTS 在这里写 -Xint。见 RELEASE-MAINTENANCE.md 2.12。这个文件必须在每次启动时
     *  【双向重写】—— 一次条件写入加一次对应的删除，会在手机升级过 26 之后把 -Xint 留在那里，
     *  游戏于是永久以解释模式运行，而没有任何东西能解释为什么。
     *
     *  警告：当 probe_exec_mem() 说内存不可用时，启动器【也】会自己强制 -Xint，这覆盖了
     *  API 版本规则覆盖不到的情形：一台带商店签名、处于 API 26 的手机，以及一台没有 ACL 的
     *  平板。这个文件是请求；那个探测才是权威。 */
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

/* [B] 任何一个候选选项文件里含有这个标记吗？（非 static：main 里要用） */
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

/* [A]
 * 这个进程到底能不能【运行】它生成进匿名内存里的代码？
 *
 * 这正是整个 ACL 绕行所围绕的那一项能力（ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY）。
 * 没有它 JVM 无法启动：HotSpot 把 stub 和 trampoline 写进匿名 RWX 内存，然后跳进去。如果那些页
 * 并非真的可执行，或者写入对指令取指不可见，CPU 就会陷入陷阱 —— 而出错地址根本不在任何模块里，
 * 所以 dladdr() 报 "in ?"，这正是 JNI_CreateJavaVM 里面那次 SIGILL 的样子。
 *
 * 所以直接问这个问题，而不是从一次崩溃里推断它：映射一个 RWX 页，往里面写一个两指令的 aarch64
 * 函数，刷新 icache，调用它。预期答案是 42。
 */
static long probe_exec_mem(void)
{
    /* [B] mov w0, #42 ; ret */
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

/* [C]
 * ---------------------------------------------------------------------------
 * 自修改代码：对一个【已经可执行】的页做一次写入，会生效吗？
 *
 * 为什么现在这是对的问题
 *   HarmonyOS 恰好封锁与可执行内存有关的两件事 —— 把一个【文件】映射为可执行，以及把 memfd
 *   映射为可执行 —— 同时却自由地允许匿名可执行内存。两条封锁都是关于「来自文件的代码」的。
 *   （本项目早先的探测里实测过：两者都是 errno=13。）
 *
 *   HotSpot 生成的全部代码都住在匿名内存里（我们的崩溃 dump 里那行映射没有文件支撑：
 *   `rwxp 00000000 00:00 0`），所以那些封锁并不能阻止 JVM【运行】生成的代码。
 *
 *   但它们把焦点引到了这里没人测过的那一个属性上：HotSpot 的 code cache 同时可写且可执行，
 *   而 HotSpot 会【就地】打补丁 —— 它把新指令写进一个已经可执行的页，不做 mprotect 往返。
 *   在 ARM 上，数据缓存与指令缓存并不一致，所以这样一次写入只有在显式的缓存维护之后才对取指单元
 *   可见。如果那次维护没有发生、或者在这个沙箱里不起作用，CPU 就会执行那些字节【先前】的内容。
 *
 *   那种失败看起来会和我们测到的完全一样：
 *     - 内存与 HotSpot 在生成时打印的一致（内存【是】新的）
 *     - CPU 却仍然去了别处（它在跑旧字节）
 *     - 它完全确定（每次运行都是同样的补丁序列）
 *     - -Xint 和 code-cache 尺寸相关的 flag 会改变偏移，但从不修复它
 *     - 出错点紧跟在一次 blr 之后，位于一个被打补丁的常量处 —— 正是新打上补丁的位置第一次被
 *       执行的地方
 *
 * 四次测量
 *   1. 写 A，flush，运行          -> 预期 1   （基线：执行能正常工作）
 *   2. 写 B，【不】flush，运行     -> 2 意味着这里的缓存是一致的、假设已死；1 意味着取指单元
 *                                      保留了旧指令
 *   3. 写 C，flush，运行          -> 预期 3   （显式维护起作用吗？）
 *   4. 写 D，mprotect RW 再 RX    -> 预期 4   （mprotect 这条路起作用吗？）
 *
 *   第 3 步是决定性的。单看第 2 步并不能证明平台缺陷：在大多数 ARMv8 核上，不做维护的写入本就
 *   合法地不可见，HotSpot 也知道这点。真正会定罪的是第 3 步失败，因为那正是 HotSpot 依赖的那
 *   个操作。
 * ---------------------------------------------------------------------------
 */
/* [A]
 * 每个测试用例都在它【自己】全新的页上。
 *
 * 共用一页，正是弄坏这个探测上一版的原因：用例 4 把页留在了 RX 映射上，于是用例 5 的 memcpy
 * 在它自己的 mprotect 有机会跑之前就出错了，而由此产生的 SIGSEGV 看起来像一个平台层面的发现，
 * 其实那是测试自身的 bug。每个用例一页，消除了所有相互作用。
 *
 * mode：
 *   0  write, clear_cache, call
 *   1  write, no maintenance, call
 *   2  write, mprotect RW->RX, call
 *   3  write, mprotect RW->RX, clear_cache, call
 *   4  write, clear_cache, mprotect RW->RX, call
 *   5  write, clear_cache, call, call again (stability)
 */
static long icache_case(int expect, int mode)
{
    unsigned int code[2] = { 0x52800000u | ((unsigned)expect << 5), 0xd65f03c0u };
    /* [B] movz w0, #expect ; ret   —— 立即数位于 bit 20:5 */

    void *p = mmap(NULL, 4096, PROT_READ | PROT_WRITE | PROT_EXEC,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) { SDL_Log("    mmap failed errno=%d", errno); return -1; }

    long r = -1;
    /* [B] 每一次写入都发生在页仍是 RWX、或者已被改成 RW 的时候 */
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
        r = (a == b && b == c) ? a : -100 - (int)a;   /* [B] 把不稳定性编码进去 */
        break;
    }
    }
    munmap(p, 4096);
    return r;
}

/* [A]
 * 覆盖【已经执行过】的代码。
 *
 * 这才是有意义的场景，而这个探测的上一版弄丢了它，因为它给每个用例一个从未执行过的页：对一个
 * 指令从未被取指过的页做写入，是显然没问题的，于是每个用例都通过，假设就因为错误的原因显得死了。
 *
 * HotSpot 做的正是这件事：它生成代码，代码运行，之后 HotSpot 回过头去【给】那些同样的指令
 * 打补丁（把地址写进一个已经被执行过的位置）。所以这里每个用例都做：
 *
 *     写 v1 -> 让它可见 -> 【调用】它   （这会把取指单元填上）
 *     写 v2 -> 施加被测机制 -> 再【调用】一次
 *
 * 并报告【第二次】调用的结果。一个正确的平台返回 v2。返回 v1 意味着取指单元保留了旧指令。
 *
 * mode（写 v2 与调用之间发生什么）：
 *   0  什么都不做
 *   1  clear_cache                                  <- 对照组
 *   2  mprotect RW->RX
 *   3  mprotect RW->RX，然后 clear_cache
 *   4  clear_cache，然后 mprotect RW->RX
 */
static long icache_rewrite_case(int v1, int v2, int mode)
{
    unsigned int c1[2] = { 0x52800000u | ((unsigned)v1 << 5), 0xd65f03c0u };
    unsigned int c2[2] = { 0x52800000u | ((unsigned)v2 << 5), 0xd65f03c0u };

    void *p = mmap(NULL, 4096, PROT_READ | PROT_WRITE | PROT_EXEC,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) return -1;
    long (*fn)(void) = (long (*)(void))p;

    /* [B] 阶段 1：装入 v1 并【运行】它，于是取指单元现在持有 v1 */
    SDL_memcpy(p, c1, 8);
    __builtin___clear_cache((char *)p, (char *)p + 8);
    long first = fn();
    if (first != v1) {
        SDL_Log("    (setup failed: wrote %d, got %ld)", v1, first);
        munmap(p, 4096);
        return -1000;
    }

    /* [B] 阶段 2：用被测机制覆盖成 v2 */
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

/* [A] 哪个映射（如果有）包含这个地址？刻意做成 async-signal-unsafe 的：
 * 我们已经在垂死，答案比规则更重要。 */
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

/* [A]
 * 大声说出这些分发的文件里，究竟哪些真的到了。
 *
 * hvigor 会丢掉 entry/libs/** 下任何名字不以 ".so" 结尾的东西，而且是无声地丢 —— JDK 的 conf/
 * 目录就是这么消失的，也正是游戏 jar 和 LWJGL jars 被改名的原因。这里一个缺失的文件，否则会在
 * 很久之后表现为一个令人困惑的类加载或 dlopen 错误，所以值得每个文件一行、外加一个朴素的尺寸。
 */
/* [B]
 * 临时诊断 —— 窗口问题定下来后就移除。
 *
 * 往【同一个】文件里写一个标记，那个文件也正是被插桩的 SDL 写它 XComponent surface 事件的地方，
 * 这样两条时间线能在一处读。这里问的问题是【顺序】的问题 —— 在 surface 回调启动我们之后过了几秒，
 * 游戏要窗口时那个 surface 是否还存在 —— 两份分开的日志回答不了它。
 */
static void probe_mark(const char *what)
{
    FILE *f = fopen(DEST_ROOT "/sdl_surface.log", "a");
    if (f) {
        fprintf(f, "=== APP %s ===\n", what);
        fclose(f);
    }
}

/* [A]
 * 这个进程到底能不能访问网络？
 *
 * 为什么要一个 native 探测，而不只是盯着游戏看
 *   游戏在这条路径上已经报过失败 —— "SocketException: Operation not permitted" 在
 *   sun.nio.ch.Net.socket0 —— 那说明 socket() 可达且被拒。那有用，但还不够，因为 ArcNet 全是
 *   NIO：Selector.open()、SocketChannel、DatagramChannel。一个能开 socket 却开不了 selector 的
 *   JVM，能连接，却跑不了服务器、也跑不了客户端自己的事件循环，而这个差别决定了这是一周的工作，
 *   还是重写 37 个类。所以这个区分必须被测量，而不是从游戏恰好打印的那一条错误里推断。
 *
 *   在这里做而不是在 Java 里做，也意味着它不依赖 JVM、不依赖 Arc，也不依赖哪个功能恰好被先试。
 *
 * 每次调用都用它自己的 errno 报告。一句笼统的「联网：不行」会正是这个项目反复重学的那同一个错误：
 * 有意思的信息是【哪一环】断了。
 *
 * connect() 会被尝试，但不要求成功 —— 它取决于设备是否真的有一条路由，而这不是这里要测的东西。
 * 之所以包含它，是因为「socket() 成功而 connect() 报 ENETUNREACH」与「connect() 收到连接被拒」
 * 是非常不同的答案，而其中只有一个意味着沙箱才是问题。
 *
 * 警告：绝不能让它拖慢一次启动。它在 JVM 被创建之前运行，而在一个首选 nameserver 不应答的网络上，
 * 名字解析可能阻塞数秒。所以名字/连接这两步通过 DEST_ROOT/netprobe 选择加入；它们上方的 syscall
 * 检查是本地的、瞬时的、始终开启的。见那处分支的说明。
 */
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

    /* [A] EPollSelectorImpl 就是架在这个之上的。没有它，Selector.open() 会失败，每一次
     * ArcNet 连接也会失败，包括那些已经有可用 socket 的。 */
    int ep = epoll_create1(0);
    SDL_Log("   epoll_create1(0)             : %s",
            ep >= 0 ? "OK" : "FAILED");
    if (ep < 0) SDL_Log("        errno=%d (%s)", errno, strerror(errno));

    /* [A] Selector 唤醒。一个无法被唤醒的 selector，就是一个无法从另一个线程被注册的
     * selector。 */
    int ev = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
    SDL_Log("   eventfd(0, NONBLOCK|CLOEXEC) : %s",
            ev >= 0 ? "OK" : "FAILED");
    if (ev < 0) SDL_Log("        errno=%d (%s)", errno, strerror(errno));

    /* [A]
     * 名字解析，分两步，因为「无法解析」和「无法到达」是不同的问题、有不同的修法，而一个合并的
     * 测试无法把它们区分开。
     *
     * 数字查找根本不需要 resolver：它要么成功，那就说明 resolver 这条路是完好的、只有名字查找
     * 在失败，要么它也同样失败，那就说明调用本身被封锁了。
     */
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

    /* [A]
     * 从【这个】进程读取 resolver 自己的配置。
     *
     * 它从 hdc shell 里可读 —— 先是 114.114.114.114 然后是 8.8.8.8 —— 但 shell 和应用是不同的
     * 安全上下文，而这里的整个问题就是【这个】进程能不能解析名字。从 shell 里测量它、再把它当作
     * 应用的答案，正是这个项目在 bundle 路径上的 `stat` 那里已经记录在案的那个错误。
     */
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

    /* [A]
     * 警告：下面的网络 I/O 是选择加入的，而这不是风格问题。
     *
     * 这一行之上的每一样都是本地内核操作，会立即返回。解析和连接不是：`getaddrinfo` 按顺序询问
     * /etc/resolv.conf 里的 nameserver，而在一个第一个就不可达的网络上，调用会卡在那里，直到那个
     * resolver 的超时到期，才会去试下一个。连接还要在上面再加一次 TCP 握手。
     *
     * 这个函数在 JNI_CreateJavaVM 【之前】运行，所以在这里花掉的每一毫秒，都是玩家盯着一块除了
     * 悬浮球以外什么都没有的黑窗口度过的毫秒。实测到的后果，从手机上报来的：应用打开后是黑屏，
     * 而且过了一段明显的时间才开始加载。同样的构建在平板上没事，因为那里的 resolver 会应答。
     *
     * 一个让它所测量的东西变得更糟的诊断，不是诊断。所以那些快的检查始终运行，而那两个可能阻塞的
     * 只在这个文件存在时才运行：
     *
     *     hdc shell "touch /data/storage/el2/base/files/netprobe"
     *
     * 删掉它，下一次启动就又快了。这与 jvm.options 里的 NOHANDLERS 是同一种形式 —— 一个会改变
     * 时序的东西，用一个选择加入的开关。
     */
    if (access(DEST_ROOT "/netprobe", F_OK) != 0) {
        SDL_Log("   (name resolution and connect skipped -- create %s to enable)",
                DEST_ROOT "/netprobe");
        goto done;
    }

    int gai = getaddrinfo("github.com", "443", &hints, &res);
    SDL_Log("   getaddrinfo(github.com:443) : %s", gai == 0 ? "OK" : "FAILED");
    if (gai != 0) SDL_Log("        %s (EAI code %d)", gai_strerror(gai), gai);
    if (res) freeaddrinfo(res);

    /* [A]
     * 可达性，通过解析一个名字、并连接它返回的东西来测。
     *
     * 刻意【不是】一个硬编码地址。早先的一版连接到一个几分钟前从设备上采样到的字面 IP，那种做法
     * 恰好只灵一次：地址会变，而一个因为数字过期而失败的探测，比没有探测还糟。先解析也正是 Java
     * 所做的，所以这里以同样的顺序演练同样的两步。
     *
     * 这里的失败不自动等于沙箱问题。上面的 `getaddrinfo` 和这里的 `connect` 把「无法解析」与
     * 「无法到达」分开，而两者都不能把沙箱与网络区分开 —— 一台没有路由的设备两者都失败。真正能
     * 区分它们的是 errno：socket() 上的 EPERM 或 EACCES 意味着被策略拒绝，而这才是这个探测真正
     * 要查的东西。
     *
     * 只解析【一次】。早先的一版在此处和上面都解析了名字，白白让最慢那一步的代价翻倍 —— 两次拿到
     * 的地址是一样的。
     */
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

/* [A]
 * 注意：曾试图让 SDL 导出一个诊断 getter 供启动器调用，但没链接上 —— SDL 的构建把导出限制
 * 在它自己的符号清单里，所以 visibility("default") 不足以加一个进去。surface 拷贝的问题改为
 * 从 SDL 自己的日志里回答；见 SDL_openharmonyvideo.c。
 */

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
        /* [B] 用 stat() 而不是 fopen()：为了回答「它在不在」去打开一个 87 MB 的 jar 未免
         * 荒唐，而这是 loader 所做的同一个调用。 */
        struct stat st;
        if (stat(paths[i], &st) == 0) {
            SDL_Log("   %9ld  %s", (long)st.st_size, paths[i]);
        } else {
            SDL_Log("   MISSING            %s", paths[i]);
        }
    }
    SDL_Log(" --- end shipped files ---");
}

/* [C]
 * 构建 java.home 将被指向的那个目录：<sandbox>/jdk/lib/modules，作为指向所分发 module image
 * 的符号链接。为什么见 SANDBOX_JDK。
 *
 * 已存在的链接会先被移除。留着它会更快，但一条指向已不存在目标的陈旧链接，在模块查找失败之前与
 * 一条能用的链接无从区分，而这正是它存在要避免的那种失败。
 */
/* [A]
 * 把一个所分发的文件放到 java.home 预期找到它的地方，只做一次。
 *
 * 以一个临时名字写入、再改名就位：一次中途被打断的拷贝，否则会留下一个能通过存在性检查、却在
 * JVM 内部失败的文件。尺寸就是「它是否已经在那里」的整个测试，因为一个尺寸正确的文件之所以能
 * 在场，唯一的方式就是一次已完成的改名。
 */
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
    /* [B] rename() 是提交点 —— 见上面的说明。 */
    if (rename(tmp, dst) != 0) {
        SDL_Log(" !! rename %s: %s", tmp, strerror(errno));
        unlink(tmp);
        return 7;
    }
    return 0;
}

/* [A]
 * 把一棵所分发的目录树拷进沙箱，从每个文件名上剥掉一个结尾的 ".so"。
 *
 * 名字为什么带 ".so" 见 scripts/prep_jdkconf.py：hvigor 会从 libs/ 里搬走 *.so，别的一言不发
 * 地丢掉。实测。
 *
 * 刻意做成递归的。替代方案是一份 java.home 所需文件的清单，而那份清单在对的时候完全正确，直到
 * 它不对为止 —— 有过两次，第二次就是这一次。遍历 JDK 实际分发的东西，不会因为某个功能用到另一个
 * 条目而过时。尺寸正确的既有文件会被 materialise() 放过，所以从第二次启动起，这很便宜。
 */
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

        /* [A] 恰好一个结尾的 ".so" —— 就是 hvigor 需要看到的那个。一个真正以 .so 结尾的源
         * 名字会被作为 .so.so 分发，并原封不动地出来，所以这个剥离永远是对称的。 */
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

/* [A]
 * 构建 java.home 将被指向的那个目录。
 *
 * module image 和时区数据库必须以 java.base 所要找的名字待在那里：
 *   lib/modules    module image。以 jimg.so 分发（patch_libjvm.py），因为 hvigor 只搬运
 *                  以 ".so" 结尾的名字；java.base 自己拼出 "modules" 这个名字，不接受别的。
 *   lib/tzdb.dat   时区数据库。出于同样的原因以 tzdb.so 分发（prep_jdklib.py）。缺失时，它
 *                  不只是破坏时间戳 —— sun.util.calendar.ZoneInfoFile 初始化失败，而程序里
 *                  任何地方第一次请求 DateFormat 都会抛异常。Mindustry 在 Saves.<clinit> 里
 *                  就会请求一次。
 *
 * 而 JDK_HOME_TREE 把 JDK 相对 java.home 读取的其余东西放到位 —— 这个必要性的来由见那个宏上的
 * 说明。
 *
 * 返回值只意味着一件事：lib/modules 到位了吗？这才是决定 java.home 到底能不能被重定向的东西
 * （见调用方）。其余部分会被大声报告，但刻意【不】改变它 —— 把一个缺失的文本文件折进来，会让
 * 「module image 未到位」以一个并非如此的原因冒出来，那是一个比没有错误更糟的错误。
 */
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

/* [A]
 * 从 VM 内部重写 java.home，在任何东西读它之前。
 *
 * 这不是多此一举：HotSpot 推导出的值指向 bundle，而那里的 module image 叫 jimg.so，java.base
 * 却坚持要 "modules"。这个窗口真实且很宽 —— ImageReaderFactory 是一个惰性初始化的类，而这个
 * 程序里第一个碰它的东西就是游戏自己的资源查找 —— 所以在这里做、在 VM 存在之后立刻做，是来得及
 * 的。任何更晚的做法都来不及。
 */
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

/* [A]
 * 从 bundle 加载 Arc 的 natives 并把它们标记为已加载，好让 Arc 自己的 loader 无事可做。为什么
 * 不能按 Arc 打算的方式来加载它们，见 ARC_LIBS。
 *
 * 设计上就是尽力而为：一个加载不了的 native 会被报告并跳过，而不是中止这次启动，因为游戏自己
 * 针对缺失 native 的错误会点名那个库和调用者，那比在这里失败更有用。绝不能发生的是半状态 ——
 * 所以一个库只有【在】System.load 真的无异常返回【之后】才被标记为已加载。
 */
static void preload_arc_natives(JNIEnv *env)
{
    static const char *keys[]  = { "arc", "arc-freetype", "arc-filedialogs" };
    static const char *files[] = { "libarcarm64.so",
                                   "libarc-freetypearm64.so",
                                   "libarc-filedialogsarm64.so" };
    const unsigned N = sizeof(keys) / sizeof(keys[0]);

    /* [A]
     * 一切都走我们自己的类，而不是直接走 System.load。从这里调用 System.load 会把库注册到错误的
     * 类加载器上，游戏随后就找不到它的 native 方法，即使那次加载报告成功 —— 见 NativeLoader.java。
     */
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
            continue;                    /* [B] 刻意不标记 */
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

/* [A]
 * 蓝图第 4 步：以反射方式调用游戏的入口点。
 *
 * 什么算通过
 *   蓝图对这一步的验收线是「Mindustry 启动了 —— 即使屏幕上没有画面」。所以通过条件是【游戏
 *   自己的】代码运行了，这可以观测为它自己在 stdout 上的输出。窗口明确【不】属于这一步（那是
 *   第 5 步），所以 main() 开始之后的一次 SDL 或 GL 失败，仍算作「它启动了」，并作为一个独立的
 *   结果报告，而不是作为这一步的失败。
 *
 * 为什么用反射，以及为什么在这里
 *   入口点是经由 JNI 被调用的，而不是把一个 main class 交给启动器，因为没有启动器：这个就是
 *   启动器。启动 VM 然后我们自己调用 main，就是整个设计。
 *
 *   调用发生在这个线程上 —— SDL 为 SDL_main 创建的那个 —— 并且它会阻塞到游戏返回。这是有意
 *   的：一个游戏的 main() 跑它自己的循环，在退出时才返回。
 */
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

    /* [B] 一个空的 String[] —— 游戏自己提供它的默认值 */
    jclass strcls = (*env)->FindClass(env, "java/lang/String");
    jobjectArray argv = (*env)->NewObjectArray(env, 0, strcls, NULL);
    if (!argv) {
        SDL_Log(" !! could not build the argument array");
        return 3;
    }

    /* [A] 到这里，游戏的入口方法确实存在 —— 那个 jar 是个能跑的游戏。把「正在尝试启动」
     * 的标记清掉，见 LAUNCH_PENDING_FILE 上的说明。
     *
     * ⚠️ 位置是重点，卡在【拿到 main 方法之后、调用它之前】的最后一刻：
     *   上面的三个失败路径（主类不在 classpath / 类里没有 main / 参数数组建不出来）
     *   每一个都 return，而它们全都意味着「这个 jar 不是游戏」—— 那些情况下标记必须留着。
     *   而一旦走到这里，任何后续的失败（main 自己抛异常、游戏跑到一半崩了）都【不再】是
     *   「选错了 jar」，所以不该再算作启动失败。
     */
    unlink(LAUNCH_PENDING_FILE);

    SDL_Log("   -> calling %s.main(new String[0]) ...", MAIN_CLASS);
    (*env)->CallStaticVoidMethod(env, cls, mid, argv);

    /* [B] 走到这一行意味着 main() 返回了。对游戏而言那要么是一次干净退出，要么是启动内部的一次
     * 失败 —— 此处仍有未决异常能把两者区分开，所以把它报告出来，而不是两边都靠猜。 */
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

    /* [A]
     * 在其它一切之前把「加载哪一个」定下来 —— classpath 在下面才拼，而它要的正是这个
     * 结果。
     *
     * ⚠️ 没有游戏就【不创建 VM】。正常情况下走不到这里：ArkTS 在挂载 XComponent 之前
     * 就拦住了，而没有 XComponent 就没有 libmain.so、也就没有 main()。这一条是纵深
     * 防御 —— `aa start` 之类的路径绕过界面时，宁可在这里明确地失败、留下一条能查的
     * 日志，也不要起一个没有游戏可跑、却白占内存和表面的 VM。
     */
    if (!resolve_game_jar()) {
        SDL_Log(" !! no game jar: nothing is bundled, and none was chosen in the launcher");
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

    /* [A]
     * 刻意用 RTLD_LAZY —— 不是作为 RTLD_NOW 失败后的回退。
     *
     * libjvm.so 把 __cxa_thread_atexit 声明为一个【强】未定义符号（GLOBAL，不是 WEAK ——
     * readelf --dyn-syms），而这个平台上【没有任何东西】提供它：JDK 自己的 libcxxabi_shim.so
     * 不导出它，OHOS libc 也不导出。所以 RTLD_NOW 在这里永远不可能成功。
     *
     * 懒绑定绕过了它：函数重定位在首次调用时才解析，所以加载成功，而那个符号只在真的被用到时
     * 才要紧。这也正是这个库本该被加载的方式 —— libjvm.so 不带 DF_BIND_NOW flag，所以懒绑定是
     * 它的正常模式。
     *
     * 支持这是正确选择的证据：AMCL 在本设备上跑着【同一个】libjvm.so 和【未修改的】shim，它必然
     * 也是以同样方式解析的。我们先前的变通做法 —— 一个手工编写、提供 __cxa_thread_atexit 的
     * shim —— 已经没了，而移除它并没有改变失败的任何方面，正是一条误导线索该有的表现。
     */
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

    /* [A]
     * 补丁 jar 必须在，而且必须是个能打开的 jar。
     *
     * ⚠️ 为什么这值得【中止启动】而不是继续：少了它，游戏 jar 里那份上游 SDL2 后端就会
     * 生效，而那个后端在本平台加载不了自己的 libSDL2 —— 失败长相与「补丁 jar 丢了」毫无
     * 相似之处，排查会从完全错误的方向开始。这里失败，至少让人一眼看到真因。
     *
     * 半状态绝不接受：宁可不起，也不要起一个「少了我们一半改动」的应用。
     */
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

    /* [A]
     * class path 是补丁 jar + 游戏 + LWJGL。LWJGL 在这里不是可选项：游戏自己的后端类，
     * 没有 org.lwjgl.* 就无法链接，所以找不到它们会在加载 application 的时候暴露出来，
     * 而不是在加载游戏 main class 的时候。
     * ⚠️ 第一个条目是补丁 jar，顺序承重 —— 见 PATCH_JAR 的注释。
     * ⚠️ 第二个条目【不是】GAME_JAR 那个常量，而是它解析出来的结果 —— 玩家可能选了
     *    别的版本。见 resolve_game_jar()。走到这一行时它必定非空，上面已经拒绝过。
     */
    SDL_snprintf(opt_classpath, sizeof(opt_classpath),
                 "-Djava.class.path=%s:%s:%s/lwjgl.so:%s/lwjgl-opengl.so:%s/lwjgl-sdl.so:%s",
                 PATCH_JAR, game_jar_path, LWJGL_JARS, LWJGL_JARS, LWJGL_JARS, HELPER_JAR);
    /* [A]
     * bundle 库目录放在【最前】，而这个顺序正是关键。
     *
     * bundle 里有两份 libSDL3.so：本启动器自己的那份在顶层，LWJGL 的那份在 LWJGL_LIBS 里。
     * ArkTS 的 XComponent 在被创建时报出 "SDL3"，这会加载顶层那份并把 native 窗口交给它；而
     * 游戏通过 LWJGL 到达 SDL，那会加载另一份。每份副本各保留自己的全局量，于是创建窗口的那份
     * 副本，并不是被赋予窗口的那份副本，窗口创建以
     *
     *     OpenHarmony host has no ready NativeWindow lease
     *
     * 失败 —— 这条消息存在于 LWJGL 的构建里、而不在启动器的构建里，两者就是这样区分开的。
     *
     * 把 bundle 列在最前，让 LWJGL 找到启动器的那份副本，于是只有一个实例，而且正是持有窗口的
     * 那一个。启动器的副本仍然从 LWJGL_LIBS 提供 liblwjgl.so 和 liblwjgl_opengl.so。
     */
    SDL_snprintf(opt_lwjglpath, sizeof(opt_lwjglpath),
                 "-Dorg.lwjgl.librarypath=%s:%s", BUNDLE_LIBS, LWJGL_LIBS);
    /* [A]
     * java.home 指向【沙箱】里的那份拷贝，而不是 bundle，而且它从 VM 被创建的那一刻起就必须正确。
     *
     * 有两个 java.base 按名字打开的文件无法随 bundle 旅行：hvigor 只搬运以 ".so" 结尾的名字，
     * 所以 module image 以 jimg.so 分发、时区数据库以 tzdb.so 分发。它们被拷进 <sandbox>/jdk/lib/
     * 下、以 java.base 真正拼出的名字 —— "modules" 和 "tzdb.dat" —— 而 java.home 就瞄向那里。
     *
     * 从 Java 侧、在 VM 起来之后再去纠正 java.home 【不】够，这是实测而非假设的：
     * sun.util.calendar.ZoneInfoFile 一直去读 "<bundle>/jdk21/lib/tzdb.dat"，并抛出
     * FileNotFoundException，即使 System.setProperty 已经成功、并且读回了新值。JDK 把这个属性
     * 缓存在 VM 启动期间初始化的 static final 里，所以之后改的值对它们不可见。
     *
     * 备此一说：早先「HotSpot 会覆盖 -Djava.home」那个结论，是从「所传的值恰好与 HotSpot 会推导
     * 出的值相同」的那些运行里得出的，所以两者无从区分。这是第一次能真正把它们区分开的运行。
     */
    SDL_snprintf(opt_home,      sizeof(opt_home),      "-Djava.home=%s", SANDBOX_JDK);
    SDL_snprintf(opt_tmpdir,    sizeof(opt_tmpdir),    "-Djava.io.tmpdir=%s", TMP_DIR);
    SDL_snprintf(opt_libpath,   sizeof(opt_libpath),   "-Djava.library.path=%s/server:%s", g_jdklib, g_jdklib);
    SDL_strlcpy(opt_encoding,   "-Dfile.encoding=UTF-8", sizeof(opt_encoding));
    SDL_strlcpy(opt_headless,   "-Djava.awt.headless=true", sizeof(opt_headless));
    /* [A] JVM 在这里找 libjava.so 及其同类，而不是在 java.home/lib 里 */
    SDL_snprintf(opt_bootlib,   sizeof(opt_bootlib), "-Dsun.boot.library.path=%s:%s/server", g_jdklib, g_jdklib);
    /* [B] 让 JVM 把它的崩溃报告放到我们能通过 hdc 读到的地方 */
    SDL_snprintf(opt_errfile,   sizeof(opt_errfile), "-XX:ErrorFile=%s/hs_err_%%p.log", DEST_ROOT);
    SDL_strlcpy(opt_heap,       "-Xmx512m", sizeof(opt_heap));

    /* [A]
     * ---------- 决定这个启动器成败的两个选项 ----------
     *
     * -XX:UseSVE=0  在 JIT 中禁用 ARM Scalable Vector Extension。
     *
     * 没有它，JVM 会在 JNI_CreateJavaVM 期间以 SIGILL 死掉，确定性地，在解释器的
     * native-method entry codelet 里的同一个地址上。这里实测为一次干净的交替 A/B，五轮：
     * 基线在 0x5edf41fc68 处 5/5 崩溃，UseSVE=0 则 5/5 成功。有该 flag 时整条启动路径跑完，
     * Java 代码得以运行：
     *     JNI_CreateJavaVM returned 0 / *** JVM CREATED ***
     *     currentTimeMillis、availableProcessors、maxMemory 都读回成功
     *     stdout: *** HELLO FROM THE JVM ***
     *
     * SVE 不能用的确切原因并没有被这次测量确立：被确立的是，CPU 在 JIT 于「相信 SVE 可用」时
     * 生成的代码上陷入陷阱，而关掉 SVE 会让 JIT 发出能运行的代码。最强的外部佐证是 AMCL ——
     * 那个明显能在同一设备、用同一个 libjvm.so 跑起一个 JVM 的启动器 —— 它的选项里就传了
     * -XX:UseSVE=0。它的源码拿不到，但它的选项清单拿得到，而这个 flag 就在里面。
     *
     * 必须先有 -XX:+UnlockDiagnosticVMOptions：UseSVE 是一个诊断 flag，没有它会直接被拒。
     *
     * 这些不是调参旋钮。它们是一个能启动的 JVM 与一个会死掉的 JVM 之间的差别，所以它们作为默认值
     * 待在这里，而不是放在运行时选项文件里。
     */
    SDL_strlcpy(opt_unsve,  "-XX:+UnlockDiagnosticVMOptions", sizeof(opt_unsve));
    SDL_strlcpy(opt_sve,    "-XX:UseSVE=0", sizeof(opt_sve));

    /* [B] 那三个平台属性 —— 为什么见声明处 */
    SDL_strlcpy(opt_osname,   "-Dos.name=Linux", sizeof(opt_osname));
    /* [A] user.home 由 resolve_user_home() 决定 —— 隔离关着时它【逐字节等于 DEST_ROOT】，
     * 与隔离功能出现之前完全一样。见那个函数上方的三条不变量。 */
    {
        char home[512];
        resolve_user_home(home, sizeof(home));
        SDL_snprintf(opt_userhome, sizeof(opt_userhome), "-Duser.home=%s", home);
    }
    /* ⚠️ user.dir 刻意【不】跟着隔离走：它是进程的工作目录，而游戏中没有东西从它派生数据路径
     * （数据走 user.home）。真需要改的时候再说，别顺手改 —— 那会让两个属性不一致这件事
     * 从「刻意」变成「碰巧」。 */
    SDL_snprintf(opt_userdir,  sizeof(opt_userdir),  "-Duser.dir=%s",  DEST_ROOT);
    SDL_strlcpy(opt_gles, "-Darc.sdl.glEs=true", sizeof(opt_gles));
    /* [B] 去问那个文件，而不是用常量：玩家可能自上次启动以来已切到桌面操作方案。
     * 见 read_control_mode_mobile()。 */
    SDL_snprintf(opt_mobile, sizeof(opt_mobile), "-Darc.sdl.mobile=%s",
                 read_control_mode_mobile() ? "true" : "false");

    {
        /* [A] 读平台自己的答案，而不是猜一个路径。
         *
         * 没有答案时，这个选项被完全略去，而这是一处纠正，不是一个细节。
         *
         * 这个分支过去会传空字面量 "-Darc.sdl.chooserPath="，底下一条注释声称空结果「使该属性
         * 保持未设置」。它并没有。该属性被【设置】成了 ""，而
         *
         *     SdlFiles.chooserPath = System.getProperty("arc.sdl.chooserPath", externalPath)
         *
         * 只在属性【不存在】时才回退到 externalPath。所以空值是一个决定，不是一个空操作 ——
         * 而且是一个错误的决定。本文件早先关于 read_user_dir() 的说明已经讲了：空的 chooserPath
         * 会让游戏的文件浏览器打开在文件系统根，「那比干脆不试还糟」。两条注释互相矛盾，而代码
         * 跟了错的那一条。
         *
         * 略去之后，chooserPath 回退到 externalPath，而 SdlFiles 把它算作 user.home + 分隔符
         * —— 而本启动器把 user.home 指向自己的沙箱。于是浏览器打开在玩家的 mods、saves、
         * schematics 和 maps 实际所在之处。那才是一个能用的浏览器。
         *
         * 旧行为实测到的后果：在一台 ArkTS 无法报告 Download 目录的设备上（见 probe_user_dirs），
         * 游戏的浏览器打开在某个毫无用处的地方，而不是沙箱里。 */
        char dl[512];
        /* [A]
         * 应用自己的文件夹，别的【什么都不要】。
         *
         * 这里曾经有一个对普通平台 Download 目录的回退，用于应用那个文件夹还不存在的启动。实测
         * 它让那些启动变得【更糟】而不是更好 —— 上面的探测把那个目录报告为
         *
         *     download  NOT READABLE  errno=1 (Operation not permitted)
         *
         * 所以把浏览器指向它，会打开在一个本应用无法列出的目录上：一个空浏览器，读起来像是一个
         * 坏掉的功能。让 chooserPath 保持【未设置】既诚实、又严格更好 —— 浏览器于是打开在沙箱里，
         * 也就是 mods/、saves/ 和 schematics/ 所在的地方，那至少是本应用读得到的地方。
         *
         * 注意：这个文件夹恰好只可能在【一次】启动中合法地缺失 —— 安装或卸载之后的第一次。它由
         * 页面创建，因为 DOWNLOAD 模式的选取器需要一个窗口（实测：来自 onCreate 的 13900042），
         * 而这段代码跑得比那更早。页面一拿到那个文件夹就会重写这座桥，所以那些启动里的多数也是对
         * 的；而从第二次启动起，它总是对的。
         *
         * 不要再把回退加回来。「没有可用的目录」和「一个读不了的目录」是不同的答案，而在这里只有
         * 其中一个是真的。
         */
        if (read_user_dir("mods", dl, sizeof(dl)) > 0) {
            SDL_snprintf(opt_chooser, sizeof(opt_chooser), "-Darc.sdl.chooserPath=%s", dl);
            SDL_Log(" file browser will open at the mod folder: %s", dl);
        } else {
            opt_chooser[0] = '\0';       /* [C] 空意味着未设置 —— 见 option_slot() */
            SDL_Log(" no mod folder in the bridge yet -- the browser will open in the");
            SDL_Log(" sandbox instead (where mods/ and saves/ are)");
        }
    }

    /* [A] BASE_OPTS 计的是下面填进去的条目数；额外的条目追加在它们之后，所以让两者保持同步。 */
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
    /* [A] 一个构造出来为【空】的选项意味着「这一个别传」，它被表达为 NULL，好让下面的压缩把它
     * 丢掉。传空字符串会设置该属性，那不是同一回事 —— 见 opt_chooser 上的说明。 */
    options[17].optionString = (opt_chooser[0] != '\0') ? opt_chooser : NULL;
    options[17].extraInfo = NULL;

    /* [C]
     * 最小模式 —— 运行时选项文件里的一行开关。
     *
     * 那九个内置 -D flag 里有几个告诉 HotSpot 一些它本来自己会算出来的东西（java.home、
     * sun.boot.library.path、java.library.path）。加它们是为了让 JDK 的库能从一个非标准位置被
     * 找到，但提供它们本身就是对「一个正常启动器如何启动 VM」的一种偏离 —— 而我们已知在本设备上
     * 可行的那一个配置（AMCL），是在 VM 起来【之后】才经由 System.setProperty 设置它大多数属性
     * 的，不是作为创建选项。
     *
     * 所以这个模式几乎什么都不传，让 VM 自己做推导。如果崩溃变了，那我们的选项清单就有嫌疑。如果
     * 没变，选项就被洗清，差别在别处。
     *
     * 触发条件：jvm.options 里一行恰好写着  MINIMAL。
     */
    int nExtra = 0;
    {
        /* [B] 一次性读进额外的选项，放到数组尾部 */
        nExtra = load_extra_options(options, BASE_OPTS);
    }

    int minimal = 0;
    int force_noexec = 0;
    int w = BASE_OPTS;
    for (int i = BASE_OPTS; i < BASE_OPTS + nExtra; i++) {
        /* [A] ArkTS 给每个启动参数值都加上 '-' 前缀，所以标记到达时可能是 NAME、也可能是
         * -NAME，取决于它们是怎么被发送的。它们在这里被消费掉，绝不到达 JVM —— 一个未知选项会让
         * 严格模式拒掉整份清单，这就是发现这点的原因。 */
        const char *o = options[i].optionString;
        if (SDL_strcmp(o, "MINIMAL") == 0 || SDL_strcmp(o, "-MINIMAL") == 0) {
            minimal = 1;
            continue;
        }
        if (SDL_strcmp(o, "NOHANDLERS") == 0 || SDL_strcmp(o, "-NOHANDLERS") == 0) {
            continue;                    /* [B] 已在 main() 里处理过 */
        }
        /* [A] CLEAROPT 的存在只是为了让 ArkTS 侧重写 jvm.options；它的出现意味着「本次运行没有
         * 选项」，所以它被消费并丢弃。没有它，一次不带选项的运行会保留【上一次】运行的文件，
         * 从而静默地继承它的 flag。 */
        if (SDL_strcmp(o, "CLEAROPT") == 0 || SDL_strcmp(o, "-CLEAROPT") == 0) {
            continue;
        }
        /* [A] NOGAME 在 VM 起来之后才处理，不在这里；这里消费它只是为了让它绝不到达 JVM ——
         * 一个未知选项会让严格模式拒掉整份清单，那会掩盖真正结果。 */
        if (SDL_strcmp(o, "NOGAME") == 0 || SDL_strcmp(o, "-NOGAME") == 0) {
            continue;
        }
        /* [A]
         * 测试钩子，与 MINIMAL、NOHANDLERS 和 NOGAME 一脉相承：让启动器表现得好像
         * 可执行内存探测失败了一样。
         *
         * 为什么值得一提着它
         *   -Xint 回退，是一个手机包与一个「装得上、然后卡死在 JNI_CreateJavaVM 里」的应用之间
         *   唯一的一道屏障。本项目拥有的每台设备都【授予】匿名 RWX 内存，所以那条回退的代码路径
         *   在它们任何一台上都到不了 —— 这意味着它会一次都没跑过就被发出去。「代码看起来是对的」
         *   和「这条回退被亲眼见过能工作」不是一回事，而这个项目已经被这个差别咬过不止一次。
         *
         * 有这个标记时，那个分支会在平板上运行，-Xint 选项被加在一个其实成功的探测之上，而游戏
         * 能以其解释加载（大约慢 5 倍）被观察，作为证据。
         *
         * 在这里消费掉，绝不传下去：一个未知选项会让严格模式拒掉整份清单。
         */
        if (SDL_strcmp(o, "NOEXEC") == 0 || SDL_strcmp(o, "-NOEXEC") == 0) {
            force_noexec = 1;
            continue;
        }
        options[w++] = options[i];       /* [B] 就地压缩清单 */
    }
    nExtra = w - BASE_OPTS;

    int nOpts;
    if (minimal) {
        SDL_Log(" ** MINIMAL option set requested: classpath/tmpdir/Xmx only **");
        JavaVMOption kept[3 + MAX_EXTRA_OPTS];
        kept[0] = options[0];                       /* [B] -Djava.class.path */
        kept[1] = options[2];                       /* -Djava.io.tmpdir */
        kept[2] = options[8];                       /* -Xmx             */
        for (int i = 0; i < nExtra; i++) kept[3 + i] = options[BASE_OPTS + i];
        nOpts = 3 + nExtra;
        for (int i = 0; i < nOpts; i++) options[i] = kept[i];
    } else {
        nOpts = BASE_OPTS + nExtra;
    }

    /* [A]
     * 当 JVM 拿不到可执行内存时，强制 -Xint。
     *
     * 这是选项文件那副背带的皮带，它之所以存在，是因为一条设备类型规则回答不了这个问题。ArkTS
     * 侧在低于 API 26 的手机上请求 -Xint，那对那台被测设备是对的，但总体上不对：
     *
     *   - 一台【处于】API 26、带商店签名且没有 ACL 的手机，被拒绝匿名 RWX 内存，于是 JIT 无法
     *     启动，启动器卡死在 JNI_CreateJavaVM 里，而设备类型规则从不触发，因为 API 版本看起来
     *     没问题。这正是 AppGallery 审核员撞上的那个「装得上、起不来」，而在分包的方案下，手机
     *     .app 会做的恰好就是这件事。
     *   - 一台 DEBUG 签名的手机【确实】能拿到那块内存（实测），所以仅凭设备类型强制 -Xint 会在
     *     唯一能用的那一个配置上白白扔掉 JIT，换来 4 倍变慢却什么都没买到。
     *   - 一台没有 ACL 的【平板】也被拒绝，而没有任何设备类型规则覆盖这一点。
     *
     * 这个探测测量的是那件事本身，而不是从一个代理去猜，一个答案覆盖以上三种。probe_exec_mem()
     * 在此点之前已经在 diagnose_loading() 里跑过了。
     *
     * 只会【添加】这个选项：如果选项文件已经请求了 -Xint（API 版本那种情形），这就是一个空操作，
     * 并且会说明。
     */
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
            /* [A] 除非 MAX_EXTRA_OPTS 被耗尽，否则不可能发生，而那将意味着 jvm.options
             * 填满了每一个槽位。之所以大声喊，是因为另一种可能就是在 JNI_CreateJavaVM 里静默
             * 卡死。 */
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

    /* [A]
     * 把判决留在 UI 读得到的地方。
     *
     * 为什么有它
     *   JVM 是否以解释方式运行，现在由【这里】、由测量来决定。页面必须把这件事告诉玩家 ——
     *   慢而没有任何解释，读起来像是一个坏掉的移植 —— 但页面做不了这个测量（它没有 mmap），
     *   也读不了这些日志：游戏每秒通过一个环形缓冲区推几千行，本应用自己的输出几秒内就没了。
     *   所以这个判决以文件传递，与 IME 桥已经在用的同一个通道。
     *
     * 为什么它连试都不试跟本次启动同步
     *   页面在 XComponent 挂载之前就写下了它的提示决定，而 XComponent 挂载正是启动 SDL_main
     *   的东西 —— 也就是这里跑的地方。所以页面永远只能读到【上一次】启动的答案。这是可以接受的，
     *   因为这个答案是这次安装的属性，而不是这次启动的属性：它不会从一次运行到下一次运行改变。
     *
     * 警告：以及那个看起来会打破上述说法的情形
     *   如果 JVM 根本起不来，玩家是否会卡在毫无解释的首次启动上？不会：这个在
     *   JNI_CreateJavaVM 【之前】运行，所以 JVM 卡住时，写着 "interp" 的文件已经在磁盘上了。
     *   杀掉应用，再打开一次，提示就在那里 —— 就在那条回退也生效、游戏真的启动起来的启动上。
     *
     * 用 "interp" 和 "jit" 而不是原始数字：调用方需要的是决定，不是实验，而数字已经在日志里了。
     *
     * 警告：报告的是能力，不是选项清单。这一点头一版弄错了，而那个错误值得这一段，因为它让判决
     * 永远无法自我纠正：
     *
     *     这个块过去问的是「选项清单里有 -Xint 吗？」
     *
     *   页面在它【认为】JIT 不可用时会把 -Xint 写进 jvm.options，于是一个陈旧请求被直接当作
     *   新鲜判决喂回来：判决 interp -> 页面写 -Xint -> 启动器看到 -Xint -> 判决 interp，永远
     *   如此。实测，在一台探测一直返回 42 的手机上：它跨多次启动一直以 12239 ms 保持解释模式，
     *   而探测一直说内存没问题。
     *
     *   改为问探测就打破了循环：页面的请求不再是它自己判决的输入，所以能力出现之后的下一次启动，
     *   判决就翻成 "jit"，页面随即把 -Xint 拿走。
     */
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

    /* [A]
     * 丢掉那些被刻意留作未设置的选项。
     *
     * 在这里做而不是在每个构造点做，是因为计数必须与实际交出去的那份清单对得上，而在一处做意味着
     * 之后某个选项可以以同样方式变成有条件的，而不必知道 nOpts 是怎么拼出来的。上面两个分支到
     * 现在都已经结束，包括那个按索引重建清单的 MINIMAL 分支。
     */
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

    /* [A]
     * 先严格，后宽松 —— 因为「文件被读了」并不能证明某个 flag 被理解了。
     *
     * 这里过去无条件用 JNI_TRUE（忽略不认识的）。这么做的代价，直到为了定位一次崩溃而试 JVM
     * flag 时才变得清楚：日志对每个 flag 都说 "read 1 extra option(s)"，但一个拼错的、或者根本
     * 不存在的 flag 产生的是完全相同的一行，然后被静默丢弃。以那种方式得出的每一个「那个 flag
     * 没用」的结论都站不住脚，因为我们分不清「flag 没有效果」与「flag 根本没到达 VM」。
     *
     * 所以：先试严格。一个未知选项会让 JVM 明确说出来 —— 要么是返回的错误码，要么是 stderr 上的
     * 一条消息，两者我们都会捕获。然后再试宽松，这样选项文件里的一个坏 flag 无法让启动器彻底
     * 无法运行。
     */
    args.ignoreUnrecognized = JNI_FALSE;

    SDL_Log(" calling JNI_CreateJavaVM (strict) ...");
    for (int i = 0; i < args.nOptions; i++) SDL_Log("   opt: %s", options[i].optionString);

    JavaVM *vm = NULL;
    JNIEnv *env = NULL;
    /* [A] 在调用【之前】，绝不在之后：如果 create() 不返回，这是附近唯一一条曾经跑过的
     * 语句。 */
    {
        FILE *mf = fopen(JVM_INCOMPLETE_MARKER, "w");
        if (mf != NULL) { fputs("incomplete\n", mf); fclose(mf); }
    }
    jint rc = create(&vm, (void **)&env, &args);
    SDL_Log(" JNI_CreateJavaVM (strict) returned %d", (int)rc);
    
    /* [A] JVM 存在了，于是问题有了答案。刻意在【此处】而不是在 start_jvm() 末尾清除：此点
     * 之后的失败 —— 一个缺失的类、一个死掉的 surface —— 会返回一个码并打印一行，所以它已经
     * 可见，绝不能被报告成「没有 JVM」。 */
    unlink(JVM_INCOMPLETE_MARKER);
    
    if (rc != JNI_OK && nOpts > BASE_OPTS) {
        /* [C] 额外的选项是唯一说得通的元凶 —— 那九个内置的是已知好的。把它们点名，因为有用的
         * 信息是【哪一个】flag 被 JVM 拒绝了。 */
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

    /* [A] 在任何东西向 boot loader 索要资源【之前】：见 SANDBOX_JDK。只在镜像真的过来了的时候
     * 才做 —— 把 java.home 指向一个里面没有 lib/modules 的目录，会把 VM 自己那条准确的错误消息，
     * 换成一条信息量更少、却说着同一件事的消息。 */
    if (modok == 0) {
        override_java_home(env);
    } else {
        SDL_Log(" !! java.home left alone: the module image is not in place");
    }

    /* [B] --- 证明它能用：从 native 调用 System.out.println --- */
    jclass syscls = (*env)->FindClass(env, "java/lang/System");
    if (!syscls) { SDL_Log(" !! FindClass(System) failed"); return 4; }

    jfieldID outId = (*env)->GetStaticFieldID(env, syscls, "out", "Ljava/io/PrintStream;");
    jobject out = (*env)->GetStaticObjectField(env, syscls, outId);
    jclass pscls = (*env)->FindClass(env, "java/io/PrintStream");
    jmethodID println = (*env)->GetMethodID(env, pscls, "println", "(Ljava/lang/String;)V");

    (*env)->CallVoidMethod(env, out, println,
        (*env)->NewStringUTF(env, "*** HELLO FROM THE JVM ***"));

    /* [B] 几个只有从 VM 内部才知道的事实 */
    jmethodID curTime = (*env)->GetStaticMethodID(env, syscls, "currentTimeMillis", "()J");
    jlong ms = (*env)->CallStaticLongMethod(env, syscls, curTime);

    jclass rtcls = (*env)->FindClass(env, "java/lang/Runtime");
    jmethodID getRt = (*env)->GetStaticMethodID(env, rtcls, "getRuntime", "()Ljava/lang/Runtime;");
    jobject rt = (*env)->CallStaticObjectMethod(env, rtcls, getRt);
    jmethodID avail = (*env)->GetMethodID(env, rtcls, "availableProcessors", "()I");
    jint cpus = (*env)->CallIntMethod(env, rt, avail);

    /* [A]
     * maxMemory() 放在这里，是对选项通道的一次【正向检查】。
     *
     * 日志行 "read N extra option(s) from <file>" 只证明那个【文件】被读了 —— 它对 JVM 是否
     * 接受了那些 flag 只字不提。传一个 -Xmx256m 并看到这个数字改变，才是那个通道真的到达 VM 的
     * 廉价、端到端的证明。没有它，「那个 flag 没有效果」和「那个 flag 从没被看到」无从区分，
     * 而这正是本轮掉进去的那个陷阱。
     */
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

    /* [A]
     * 上面的检查是第 3 步的验收，保持原样 —— 它们是 VM 自身健康唯一的廉价证明，并且把「VM 没有
     * 启动」与「游戏没有启动」区分开。只有当它们全都通过之后，才把控制权交给游戏。
     *
     * NOGAME 跳过这次交接，这样第 4 步的回归就能与第 3 步的回归区分开，而无需重建。
     */
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

/* [A]
 * ---------------------------------------------------------------------------
 * 把每一条 SDL_Log 都镜像到 HILOG。
 *
 * 为什么有它，而这不是图方便。
 *
 *   本启动器的全部诊断都走 SDL_Log，它写到 stdout/stderr，而启动过程把它重定向进应用沙箱里的
 *   文件。那对 DEBUG 签名的构建有效，本项目里每一次测量都是这样取得的。
 *
 *   它对 release 签名的构建【不】有效。设备上实测，装着一个 internaltesting（release）包时：
 *
 *       hdc shell cat <sandbox>/files/stderr.log   -> Permission denied
 *       hdc shell pidof <bundle>                   -> (empty)
 *       hdc shell ps -A | grep <bundle>            -> (empty)
 *       faultlog                                    -> 没有它的条目
 *
 *   所以一个商店签名的包第一次被运行时 —— 2026-09-22，在一台 profile 不授予任何可执行内存的
 *   手机上 —— 它回退到 -Xint，然后【崩溃了】，而什么都读不到。在那个状态下，关于商店包做了什么
 *   的每一个问题都无从回答，对一个要发给用户的构建而言，那是最糟的处境。
 *
 *   hilog 对任何应用都可读，不管它由什么签名，所以诊断也必须去那里。
 *
 * 为什么用回调，而不是在每个调用点外面包一层宏
 *   SDL3 允许进程替换它的日志汇聚点，所以一个函数就能接住本文件里的每一条 SDL_Log【以及】SDL
 *   自己记录的一切 —— 包括那些只在失败的路径上才出现的 SDL 和 linker 消息。替换调用点会漏掉
 *   那些，而它们有几百个。
 *
 * 为什么用 %{public}s 而不是直接传消息
 *   hilog 会把未标记的格式说明符掩码成 <private>，所以把 SDL 的格式串直接传过去，会产出一个
 *   满是 <private> 而不是值的日志。消息到达时已经格式化好了，所以它被当作单一 public 字符串
 *   传入。
 *
 * 默认输出也保留，这样对能读取它们的 debug 构建而言，沙箱文件仍然拿到一切。
 * ---------------------------------------------------------------------------
 */
#define MX_LOG_DOMAIN 0x0000
#define MX_LOG_TAG    "MindustryLauncher"

static SDL_LogOutputFunction g_prev_log_output = NULL;
static void *g_prev_log_userdata = NULL;

static void SDLCALL mirror_log_to_hilog(void *userdata, int category,
                                        SDL_LogPriority priority, const char *message)
{
    /* [B] 先保留原来的行为：万一这里出什么岔子，文件里仍然有那一行。 */
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
    /* [B] 一次调用，一个 public 字符串 —— 见上面关于 %{private} 的说明。 */
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

    /* [A]
     * 阻止 SDL 把触摸变成鼠标事件。
     *
     * SDL 默认就这么做（SDL_HINT_TOUCH_MOUSE_EVENTS）。后果是每一次触摸都到达两次 —— 一次
     * 作为模拟鼠标，一次作为真实手指 —— 而 Arc 只理解鼠标那一半。这就是为什么触摸点击能用、
     * 却永远捏合不了：一个模拟鼠标永远只是 pointer 0，而捏合是由第二个接触点定义的。
     *
     * 通过环境变量设置而不是 SDL_SetHint，因为本进程里有两份 libSDL3.so 映射，而其中只有一份
     * 分发触摸事件。环境变量由两者共享；SDL_SetHint 只会到达本启动器恰好链接的那份副本。
     *
     * 让这生效的是时序：要紧的那份副本是 LWJGL 加载的那份，而它发生在 JVM 启动游戏的时候 ——
     * 稳稳地在这行之后。触摸探测在分发时把 hint 读回来并打印它，所以「设置没生效」是可见的，
     * 而不是每一次输入都无声地重复投递。
     */
    setenv("SDL_TOUCH_MOUSE_EVENTS", "0", 1);

    SDL_Log("==================================================");
    SDL_Log(" Mindustry Launcher -- start the JVM");
    redirect_io();
    /* [A]
     * SDL 的 XComponent 回调记录的一切，都发生在这个标记【之前】；它之后的一切，都发生在我们
     * 启动 JVM 和游戏的时候。见 probe_mark()。
     *
     * 这个文件刻意【不】在这里截断。surface 回调在这个函数运行之前就触发了 —— 它正是启动这个
     * 函数的东西 —— 所以在此点清空日志会删掉恰好要紧的那些条目。它改为跨启动累积；在运行前从
     * PC 侧清空它。
     */
    probe_mark("main() entered: JVM not started yet");
    /* [B] surface 拷贝的探测已移除：SDL 不导出它 */
    /* [A] crash.txt 以 O_APPEND 写入，这样一个致命信号 —— 它可能在 stdout 可用之前就袭来 ——
     * 永远不会丢失报告。这也意味着它跨启动累积，而不先清空就读它，会静默地把好几次运行混在一起。
     * 每次运行都从空开始。 */
    unlink(DEST_ROOT "/crash.txt");
    /* [A] 退出标记绝不能活过一次启动。ArkTS 轮询它们，一出现就关掉 ability，所以上一次运行留下
     * 的标记会在本次启动后四分之一秒内把这次运行关掉 —— 而它看起来会像一次自发崩溃，而不是一个
     * 陈旧文件。 */
    unlink(EXIT_MARKER_SANDBOX);
    unlink(EXIT_MARKER_MODULE);
    SDL_Log(" stdout/stderr -> %s/{stdout,stderr}.log", DEST_ROOT);
    /* [A] PID 对 TID 解决了一个真问题：SDL 在它自己 pthread_create() 出来的线程上运行
     * SDL_main，而不是在进程主线程上。如果两者不同，那 JVM 就是在非主线程上被创建的 —— 这正是
     * 构建计划所说的那个最大的未知数。
     * （早先的一版两次打印 getpid()，所以从那份日志得出的「两者不同」结论，是那次打印的产物，
     * 而不是一次测量。已在此修正。） */
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

    /* [A]
     * 崩溃处理器【只有】在选项文件不要求放过它们时才安装。
     *
     * 为什么这变成了一个变量：它们从最初那一版起就一直被安装，所以在这里做过的每一个实验里它们
     * 都是一个常量 —— 而它们覆盖 SIGILL，那恰恰是我们正在死于其上的信号。
     *
     * HotSpot 在 JNI_CreateJavaVM 期间安装【它自己的】处理器，并用一套链式方案：如果它不把某个
     * 错误认作自己的，它就把信号转给先前安装的处理器。我们看到【我们的】处理器在跑，这意味着
     * HotSpot 转发了它 —— 也就是说，HotSpot 没有把这次错误认作自己的。
     *
     * 这要紧，因为 HotSpot 刻意把非法指令当作陷阱来执行、并自己捕获它们。如果它的处理器认不出
     * 那个陷阱，一个本该隐形的内部机制就会变成致命的。从一开始就坐在那条路径前面，是造成我们
     * 现有的这个症状的一个说得通的方式。
     *
     * 所以：把 "NOHANDLERS" 放进 jvm.options，本启动器就什么都不安装，从而让 HotSpot 的信号
     * 处理完全不受打扰。
     */
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

    /* [A]
     * 这里曾经有一个 20 秒的 "staying alive 20s ..." 睡眠循环。它是早期留下的诊断脚手架，加它是
     * 为了观察 main() 返回之后发生了什么，而它一直没被移除。
     *
     * 它同时也是「退出会卡住，几秒后应用才退出」那个抱怨的全部原因。过程是：
     *
     *   游戏的 main() 返回  -> 不再渲染任何东西，所以画面在那一刻冻住
     *   这个循环睡 20 秒     -> 期间进程还活着，所以启动器还没有接管
     *   循环结束，我们返回   -> 拆除，直到这时应用才走
     *
     * 所以那个延迟从来不在 SDL 里、也不在 JVM 的 shutdown hook 里；2026-09-20 用 quit_timing.sh
     * 实测为点击与进程消失之间约 20 秒，恰好与这个循环自身的时长吻合。
     *
     * 已移除。没有用任何东西替换它：这里已经没有活了，游戏早就返回了，我们越早返回，系统就能越早
     * 把应用拆掉。
     */
    SDL_Log("==================================================");
    /* [A]
     * 用 _exit 终止，而不是 return。
     *
     * 从 main 返回会运行 C 运行时的 atexit 处理器和每一个静态析构函数，而那次拆除会【中止】——
     * 实测，每一次退出都是：
     *
     *   *** FATAL SIGNAL 6 (code=-6) at ... pc 0x5acff84ef4
     *       in /lib/ld-musl-aarch64.so.1     thread SDL_main
     *
     * 而系统照章把它归档成一次崩溃：
     *
     *   AppMS: ... reason=Cpp Crash ... exitSigno = 6
     *   HiView-CrashValidator: exitSigno = 6
     *
     * 应用反正都要走了，所以这个信号对结果毫无改变 —— 但它意味着每一次正常退出都被报告给 OS 为
     * 一次崩溃，那会生成一份崩溃报告，并可能在用户面前弹出一个对话框。对于一个用户按下的按钮，
     * 这是一个错误的说法。
     *
     * 崩溃式的拆除在这一点上不是我们能修的：它发生在游戏的 main() 已经返回之后，那时 libjvm 和
     * SDL 正以这个平台上两者都不支持的顺序被卸载。运行它得不到任何东西 —— 进程正在退出，OS 反正
     * 会回收那些映射。所以跳过它。
     *
     * 先 flush：_exit 不运行 stdio 清理，而 stdout.log/stderr.log 被重定向到的文件，其尾部是我们
     * 最有用的证据。
     *
     * 游戏自身的持久化不受影响 —— Arc 在 application shutdown 期间保存它的设置，而那在 main()
     * 返回时已经完成（紧挨着上面记录的音频 deinit 就是它的标志）。这次改动之后已通过确认退出时
     * settings.bin 仍被重写来验证。
     *
     * ---------------------------------------------------------------------
     * 退出之前，把关机交给 ArkTS。
     *
     * 单靠 _exit 会在 ability 仍然活着的时候结束进程，而系统把那记录为 "Cpp Crash"
     * （AppMS: reason=Cpp Crash, killId=2004）—— 即使没有信号、没有崩溃 dump 也一样，我们就是
     * 靠这点知道它是对一次看起来异常之退出的分类，而不是一次真正的错误。见 quit_timing.sh 和
     * 桌面版文章里的笔记。
     *
     * 所以改为：放下一个标记，给 ArkTS 一个短窗口调用 terminateSelf()，如果它没有调用就自己退出。
     * 当它生效时，框架把 ability 拆掉并杀掉进程 —— 一次正常结束，路径里也没有我们的 C 运行时
     * 拆除。
     *
     * 这个窗口很短，而且刻意有界。如果这个握手不生效，应用仍然必须退出；在这里卡死，会远比它试图
     * 修的那条被错标的日志行糟糕得多。走回退时实测的代价：约 1.2 秒（quit_timing.sh）。
     */
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
