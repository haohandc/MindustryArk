/*
 * Mindustry Launcher for HarmonyOS -- start a real JVM, then hand over to Java.
 *
 * The step the plan called "the biggest unknown": create a Java VM from native
 * code on HarmonyOS, on a thread SDL created rather than the process main thread.
 *
 * WHERE THINGS LIVE (current design)
 *   The JDK ships as plain directories under entry/libs/arm64-v8a/jdk21/ and is
 *   therefore unpacked by the HAP installer straight into the app's executable
 *   library area -- there is no runtime extraction step and no first-launch cost:
 *
 *       entry/libs/arm64-v8a/jdk21/lib/server/libjvm_real.so
 *           -> /data/storage/el1/bundle/libs/<abi>/jdk21/lib/server/libjvm_real.so
 *
 *   Only the HAP's own lib area is executable; the writable sandbox (el2) is not,
 *   even holding ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY. Shipping the
 *   JDK as libraries therefore solves the executable-mapping problem for free.
 *
 *   Nesting the real libjvm three levels deep is what makes HotSpot derive the
 *   correct java.home (it strips three path components and requires
 *   "<java.home>/lib/<module image>"); see prep_vendor.py for the full chain,
 *   including why an anchor library is needed to satisfy the bare-name
 *   DT_NEEDED that every other JDK library declares.
 *
 * ASCII ONLY -- clang decodes source as GBK on a Chinese Windows locale, so a
 * UTF-8 comment can decode into a literal "*" "/" that ends the comment early.
 */
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>

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

/*
 * THE JDK LIVES INSIDE THE HAP'S NATIVE-LIB AREA -- and that is the whole trick.
 *
 * Two rules had to be satisfied at once:
 *
 *   (a) Only the HAP's own lib area is executable. A library read out of the
 *       app's writable sandbox cannot be dlopen'd, even with
 *       ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY held. Measured:
 *           dlopen("<bundle>/libSDL3.so")                    -> OK
 *           dlopen("<sandbox>/.../libSDL3_copy.so")          -> fails
 *       (The permission covers anonymous executable memory only; AMCL gets
 *        around it with a hand-written ELF loader -- we do not need that.)
 *
 *   (b) HotSpot derives java.home from libjvm.so's own path: it strips three
 *       path components and then requires "<java.home>/lib/modules" to exist.
 *       -Djava.home is overwritten unconditionally (os_linux.cpp,
 *       Arguments::set_java_home).
 *
 * So the JDK is shipped as entry/libs/arm64-v8a/jdk21/ (recursively), landing at:
 *
 *     <bundle>/libs/arm64/jdk21/lib/server/libjvm.so
 *                            ^-- strip 1 -> .../jdk21/lib/server
 *                            ^-- strip 2 -> .../jdk21/lib
 *                            ^-- strip 3 -> .../jdk21   = java.home
 *     <bundle>/libs/arm64/jdk21/lib/modules      <- exists, so set_boot_path passes
 *
 * Everything is executable, java.home comes out right, and nothing has to be
 * unpacked at runtime. (Same layout AMCL's ELF loader produces, minus the
 * loader.)
 */
#define JDK_HOME    "/data/storage/el1/bundle/libs/arm64/jdk21"
#define JDK_LIB     JDK_HOME "/lib"
/* The REAL JVM, nested at <java.home>/lib/server/ so HotSpot derives the right
 * java.home. Its SONAME has been blanked and it is not on the loader's search
 * path -- reach it through the anchor (JDK_ANCHOR), which depends on it. */
#define JDK_LIBM        JDK_LIB "/server/libjvm_real.so"

/* An otherwise-empty libjvm.so sitting on the search path. See libjvm_anchor.c:
 * it exists only so the bare-name DT_NEEDED of the other JDK libraries resolves,
 * and it pulls the real JVM in through its own dependency chain. */
#define JDK_ANCHOR  BUNDLE_LIBS "/libjvm.so"
#define BUNDLE_LIBS "/data/storage/el1/bundle/libs/arm64"

/*
 * The game, delivered as a jar that is NAMED like a shared library.
 *
 * hvigor copies entry/libs/arm64-v8a/** into the HAP on one condition only: the
 * file name ends in ".so". Content is not inspected. Measured on the built HAP:
 * the 140,523,131-byte module image ships as lib/jdk21/lib/jimg.so, and the
 * 25,322,128-byte real JVM as libjvm_real.so -- both at exactly their project
 * sizes, byte for byte -- while every file under jdk21/conf/ was dropped without
 * a warning, because those names do not end in ".so".
 *
 * So the jar takes the same road. It is not an ELF any more than the module
 * image is, and it survives just as untouched.
 *
 * The JVM does not care about the extension either: a class path entry is opened
 * as an archive by content, not by name.
 *
 * The alternative -- writing it to the sandbox at first launch -- was rejected as
 * unnecessary: the bundle library area is readable by the app (the module image
 * is read from exactly there, and the VM cannot boot without it), so there is
 * nothing to copy and no first-launch cost. The sandbox is only unusable for
 * EXECUTABLE mappings, which this is not.
 *
 * It lives in a SUBDIRECTORY rather than directly beside libmain.so. The
 * top-level names in that directory are the ones the platform treats as native
 * libraries, and a jar is not an ELF; keeping it one level down matches where the
 * module image already sits and is known not to be touched.
 */
#define GAME_JAR    BUNDLE_LIBS "/game/mindustry.so"

/*
 * LWJGL, in two halves -- and they go to two different places for two different
 * reasons. See prep_lwjgl.py.
 *
 * The game jar does not contain LWJGL. Arc's SDL3 backend calls the platform
 * through org.lwjgl.opengl.* and org.lwjgl.sdl.*, and those classes came from
 * AMCL's libraries directory when the game ran under AMCL. This launcher has to
 * supply them itself or the backend cannot even be loaded.
 *
 *   LWJGL_LIBS  real ELF shared objects: the dyncall dispatch in liblwjgl.so and
 *               the OpenGL binding in liblwjgl_opengl.so. They need no disguise,
 *               but they must be in the executable area.
 *   LWJGL_JARS  not ELF at all; renamed to .so only because that is the sole
 *               condition on which hvigor copies a file into the HAP.
 *
 * THERE IS NO libSDL3.so IN LWJGL_LIBS, and that is deliberate -- see the note
 * on opt_lwjglpath below. There used to be one: LWJGL's own build of SDL3, on
 * the reasoning that LWJGL's sdl bindings are generated against a specific
 * symbol list while SDL's development branch renames things, so the matching
 * pair would avoid SDL drift. That reasoning is still sound in general, but it
 * was overtaken by a worse problem: a second libSDL3.so anywhere means two
 * independent mappings of SDL3 in one process, each with its own static
 * variables, and this project lost a round to exactly that -- two event queues,
 * a window created in one copy and surface callbacks delivered to the other.
 * So the loader is pointed at ONE SDL3, the one this project builds from
 * entry/src/main/cpp/SDL/, and nothing else provides that name.
 */
#define LWJGL_LIBS  BUNDLE_LIBS "/lwjgl"
#define LWJGL_JARS  BUNDLE_LIBS "/lwjgl-java"

/*
 * Arc's own natives, shipped here so they can be loaded at all.
 *
 * Arc reads them out of the jar, writes them under java.io.tmpdir, and calls
 * System.load on the copy -- and that copy cannot be dlopen'd, because the app's
 * writable areas are not executable on this platform while the read-only bundle
 * is. Measured with two libraries across six candidate directories, plus a
 * bundle control that passed: see probe_sandbox_exec().
 *
 * So they are loaded from here instead, before the game starts, and Arc is told
 * they are already loaded. setLoaded(String) is public and static, and load()
 * returns immediately for a marked name -- the same call Arc makes for itself.
 * This is not a workaround being smuggled in; it is the loader's own contract.
 */
#define ARC_LIBS    BUNDLE_LIBS "/arc"

/*
 * Our own class, which exists only so that System.load is called from Java.
 *
 * System.load is @CallerSensitive: it registers the library against the class
 * loader of its caller. Called through JNI there is no caller frame, so the
 * library ends up on the bootstrap loader and the game's classes cannot see its
 * symbols -- the library loads and is still unusable. See NativeLoader.java.
 */
#define HELPER_JAR  BUNDLE_LIBS "/launcher/helper.so"

/*
 * Where java.home has to be pointed before the first module-image lookup, and
 * why the module image has two names.
 *
 * The file is really named jimg.so, because hvigor only carries files whose name
 * ends in ".so" -- see patch_libjvm.py. That rename is enough for the VM, which
 * was told the new name when the string was rewritten inside libjvm. It is NOT
 * enough for java.base, which builds the path itself:
 *
 *     private static final Path BOOT_MODULES_JIMAGE =
 *             Paths.get(System.getProperty("java.home"), "lib", "modules");
 *
 * That is a static final read ONCE, when jdk.internal.jimage.ImageReaderFactory
 * is initialised -- and it is initialised lazily, on the first resource lookup
 * through the boot loader, which for this program is inside the game's main().
 * So there is a wide window in which java.home can still be changed, and the
 * override below is applied at the earliest possible moment after the VM exists.
 *
 * java.home cannot simply be passed as -Djava.home: HotSpot derives it from the
 * location of libjvm.so and overwrites whatever was passed (measured). So it is
 * rewritten from Java instead, after the VM is up but before anything reads it.
 *
 * The directory it is pointed at has to contain a real file named "modules",
 * which means materialising the 140 MB image into the sandbox on first launch.
 *
 * A SYMLINK would have been the obvious way to avoid that copy, and it was tried
 * first: symlink("/data/.../jdk21/lib/jimg.so", ".../jdk/lib/modules") fails with
 * EACCES. The sandbox does not permit creating symlinks at all. A hard link is
 * not an option either -- the image lives on a read-only mount, so it cannot be
 * linked into a writable one.
 *
 * So the copy is the only route, and it is done once: an existing file of the
 * right size is accepted as-is. It is written under a temporary name and renamed
 * into place, because a copy interrupted halfway would otherwise leave a file
 * that passes an existence check and fails inside the JVM instead.
 */
#define SANDBOX_JDK     DEST_ROOT "/jdk"
#define SANDBOX_MODULES SANDBOX_JDK "/lib/modules"
#define SANDBOX_TZDB    SANDBOX_JDK "/lib/tzdb.dat"
#define MODULE_IMAGE    BUNDLE_LIBS "/jdk21/lib/jimg.so"
#define TZDB_IMAGE      BUNDLE_LIBS "/jdk21/lib/tzdb.so"

/* writable places, still needed for tmpdir and the captured stdio */
#define DEST_ROOT   "/data/storage/el2/base/files"
#define TMP_DIR     "/data/storage/el2/base/temp"

/*
 * Where this launcher tells ArkTS "the game has finished, close the ability".
 *
 * The two sides do not agree on one path constant: native writes under
 * DEST_ROOT (/data/storage/el2/base/files), while ArkTS's context.filesDir is
 * the module-scoped /data/storage/el2/base/haps/entry/files. The launcher
 * already reads jvm.options from BOTH locations for the same reason, so the
 * marker is written to both and ArkTS checks both. Two one-byte files once, at
 * shutdown, is cheaper than being wrong about which directory is shared.
 *
 * WHY THIS EXISTS AT ALL
 *   Killing the process outright is what makes the system file the exit as
 *   "Cpp Crash": from the framework's point of view a native process died while
 *   its ability was still running. Terminating the ability first and letting the
 *   framework take the process down is the only way to end normally. Native has
 *   no API for that -- the ability object is an ArkTS object -- so ArkTS has to
 *   do it, and this file is how it finds out.
 */
#define EXIT_MARKER_SANDBOX DEST_ROOT "/native_exit"
#define EXIT_MARKER_MODULE  "/data/storage/el2/base/haps/entry/files/native_exit"

/*
 * Probe whether this app can actually READ the directories the platform calls
 * user-visible -- the ones a player could drop a save file into.
 *
 * The paths are not guessed here: ArkTS asks the platform
 * (environment.getUserDownloadDir / getUserDocumentDir) and writes them to
 * USER_DIRS_FILE, because only ArkTS can ask. But only native can test
 * readability with the same libc the game uses, and "the API returned a path"
 * says nothing about whether an open() on it succeeds. Both halves are needed.
 *
 * This matters because the game's "import save" browser roots itself at Arc's
 * external storage path, which SdlFiles derives from user.home -- and this
 * launcher points user.home at its own sandbox, so the browser opens inside the
 * app where the player can put nothing. Whether that is fixable at all depends
 * on the answer here.
 */
#define USER_DIRS_FILE "/data/storage/el2/base/haps/entry/files/user_dirs.txt"

/*
 * Look up one "key=value" line in the file ArkTS wrote.
 *
 * Returns the number of bytes copied (0 when the key is absent or the file is
 * unreadable), so a caller can leave a system property unset rather than pass
 * an empty value -- an empty -Darc.sdl.chooserPath would make the game's file
 * browser open at the filesystem root, which is worse than not trying.
 */
static int read_user_dir(const char *key, char *out, size_t outlen)
{
    FILE *f = fopen(USER_DIRS_FILE, "r");
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
        /* 10 and 13 are LF and CR. Written as numbers rather than as character
         * escapes because this file has already been through one tool that ate
         * backslashes and left a literal newline inside a char literal. */
        while (n > 0 && (v[n - 1] == 10 || v[n - 1] == 13)) {
            n--;
        }
        /* "<threw>" is what ArkTS writes when the platform call failed; it is
         * not a path, so treat it as absent rather than passing it on. An empty
         * value is treated the same way: -Darc.sdl.chooserPath= (empty) would
         * make the game's file browser open at the filesystem root, which is
         * worse than leaving the property off entirely. */
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

        /* opendir is the question that matters: the game has to LIST the
         * directory before it can pick a file out of it.
         *
         * DIRECTORY ENTRIES ARE NOT FILES, and counting them as such is
         * misleading -- the first version of this tallied "the last dot
         * component" of every name, so a Download folder containing
         * com.huawei.browser/ and com.huawei.music/ reported extensions
         * "browser" and "music". They are not extensions; they are package
         * names. The counts are now split so the output says what it measured.
         *
         * stat() rather than dirent's d_type: d_type is allowed to be
         * DT_UNKNOWN depending on the filesystem, and silently misclassifying
         * everything as "not a directory" would reproduce the same wrong answer
         * this is fixing.
         *
         * The extension tally exists because "the browser opened here and showed
         * nothing" has two different causes: the app cannot see the directory, or
         * it can see it and the file does not match the filter the game asks for.
         * There are TWO import paths with DIFFERENT filters -- measured from the
         * jar's bytecode, LoadDialog passes {"msav"} for a single save while
         * SettingsMenuDialog passes {"zip"} for a whole data export -- so a file
         * can be perfectly readable and still absent from the dialog the player
         * happened to open. Counting extensions here answers that without
         * another build. */
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
                dirs++;   /* a package directory, .zip file, whatever -- not an extension */
                continue;
            }
            files++;

            const char *dot = strrchr(e->d_name, '.');
            if (!dot || dot == e->d_name) {
                continue;  /* no extension, or a dotfile like .nomedia */
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

            /* Distinct extensions only. Matched on token boundaries rather than
             * with strstr, so ".so" cannot be "found" inside ".something". */
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

/*
 * Native code may only be executed from the HAP's read-only area, never from
 * the app's writable sandbox. Measured on device:
 *   dlopen("/data/storage/el1/bundle/libs/arm64/libSDL3.so")            -> OK
 *   dlopen("/data/storage/el2/base/files/.../libcxxabi_shim.so")        -> FAIL
 *   ...and chmod 0755 on that file did NOT help.
 * That is the usual W^X rule: el2 (writable) is not executable.
 * So the ENTIRE JDK ships as prebuilt libraries under entry/libs/arm64-v8a/ and
 * lands in the executable area -- including the module image, which can only be
 * shipped because it was renamed to "jimg.so" (see patch_libjvm.py). Nothing is
 * written to the sandbox at startup.
 */

/*
 * Where libjvm.so must live, and why:
 *   HotSpot derives java.home from libjvm.so's own location --
 *   it strips three path components (see os::init_system_properties_values()
 *   in os_linux.cpp) and then requires "<java.home>/lib/modules" to exist:
 *
 *       Arguments::set_java_home(buf);          // unconditional, ignores -Djava.home
 *       if (!set_boot_path('/', ':'))
 *           vm_exit_during_initialization("Failed setting boot class path.");
 *
 *   With libjvm.so flattened into the ABI dir the derivation lands on .../bundle,
 *   which has no <module image> -> "Failed setting boot class path.".
 *
 *   So the real JVM stays nested at <JDK_HOME>/lib/server/libjvm_real.so, which
 *   makes java.home come out as <JDK_HOME> -- exactly where the module image and
 *   conf/ live.
 *
 *   Verified empirically, not assumed: an earlier attempt did dlopen the JVM from
 *   the writable sandbox (AMCL is known to run its JVM from /data/app/el2/...) and
 *   it did NOT work for us -- the copy that succeeded was the one inside the HAP.
 *   The bundle area is the only path this launcher relies on.
 */

static int g_files = 0;
static long long g_bytes = 0;

/*
 * ---------------------------------------------------------------------------
 * WHERE ARE WE? -- discovered at runtime, not assumed.
 *
 * The ABI directory name is NOT the same string in the two namespaces:
 *     inside the HAP            libs/arm64-v8a/...
 *     on the device             /data/storage/el1/bundle/libs/arm64/...
 * and getting it wrong is silent: every dlopen just fails with "no such file".
 *
 * We could hardcode it, but one of the strings is NOT ours to choose: the anchor
 * library's DT_NEEDED carries an absolute device path baked in at LINK time by
 * prep_vendor.py. If that string disagrees with reality, nothing else can
 * compensate. So instead of guessing, ask the loader for the path of the library
 * we are already running inside -- dladdr() on one of our own functions returns
 * libmain.so's real path, and its directory IS the lib dir.
 *
 * That makes the answer authoritative and self-correcting, and it gives the
 * build-time string something to be checked against.
 * ---------------------------------------------------------------------------
 */
#define ABI_DIR_GUESS "/data/storage/el1/bundle/libs/arm64"

static char g_root[1024];       /* <bundle>/libs/<abi>            */
static char g_jdkhome[1200];    /* <root>/jdk21                   */
static char g_jdklib[1400];     /* <jdkhome>/lib                  */
static char g_jvmreal[1500];    /* <jdklib>/server/libjvm_real.so */
static char g_anchor[1400];     /* <root>/libjvm.so               */

/* Defined further down, but diagnose_loading() wants them and comes first. */
static long g_exec_probe_result;
static long probe_exec_mem(void);
static void probe_icache(void);
static void report_mapping(unsigned long addr, char *out, size_t cap);

static void joinp(char *dst, size_t cap, const char *a, const char *b)
{
    SDL_snprintf(dst, cap, "%s%s", a, b);
}

/* returns 1 if dladdr gave us a usable directory */
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

    /* if discovery failed, fall back to the guess so we still get diagnostics */
    int discovered = (g_root[0] != '\0');
    if (!discovered) SDL_strlcpy(g_root, ABI_DIR_GUESS, sizeof(g_root));

    joinp(g_jdkhome, sizeof(g_jdkhome), g_root, "/jdk21");
    joinp(g_jdklib,  sizeof(g_jdklib),  g_jdkhome, "/lib");
    joinp(g_jvmreal, sizeof(g_jvmreal), g_jdklib, "/server/libjvm_real.so");
    joinp(g_anchor,  sizeof(g_anchor),  g_root, "/libjvm.so");

    /* did the compile-time choice agree? this is the one thing we cannot fix at
     * runtime, so say so plainly rather than failing later with a vague error */
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

/*
 * The unpacking machinery is gone: the JDK now runs straight out of the HAP's
 * lib area (see JDK_HOME above), so there is nothing to extract and no marker
 * to keep. That also removes the "165 MB written on first launch" cost and the
 * whole class of bugs that came with it (including one where a failed symlink
 * silently deleted every library).
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

/* ------------------------------------------------------------- JVM startup */

/* ---------------------------------------------------------- stdio + crashes */

/*
 * Redirect stdout/stderr into the writable sandbox.
 *   The JVM reports startup failures there and we cannot see them over hdc, so
 *   without this a failure is just "the process died". (AMCL does the same
 *   thing with its "[Phase 4] REDIRECT_IO".)
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

/* Report a fatal signal and, via dladdr, which library the address belongs to. */
/* the current thread's name, for crash reports -- see on_fatal_signal() */
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

    /*
     * For SIGILL, dump the bytes at the faulting instruction.
     *
     * This separates the two very different reasons code can trap here:
     *   - the bytes are NOT a valid aarch64 instruction  -> HotSpot generated
     *     code for CPU features this device does not have;
     *   - the bytes ARE a valid instruction               -> the write reached
     *     memory but not the instruction cache, i.e. a coherence problem.
     * The two have nothing in common as fixes, and the addresses alone cannot
     * tell them apart.
     *
     * Only read when the containing mapping is readable, so a bad guess cannot
     * turn one crash into two.
     */
    /*
     * Dump the CPU registers at fault time.
     *
     * This is the measurement the whole investigation was missing. The faulting
     * address alone cannot distinguish "code is wrong" from "control flow
     * arrived somewhere it should not have", and those have nothing in common
     * as fixes. The registers say which: on aarch64 HotSpot's interpreter
     * dispatches with
     *     adrp x21, <dispatch table page> ; add x21, x21, #off
     *     ldr  x9, [x21, w9, uxtw #3]     ; br x9
     * so x21 holds the dispatch table the code THINKS it has, and x9 (or
     * whatever register br used) holds where it actually went.
     */
    /*
     * Name the module the FAULTING INSTRUCTION is in, and the thread it ran on.
     *
     * si_addr says what was touched, not what touched it, and for a fault at a
     * small offset it is usually something like 0x20 that names nothing at all --
     * dladdr reports "in ?". The program counter is the opposite: it is always a
     * real address in a real mapping, so it answers "which library, or is this
     * JIT-generated code in the code cache", which is the first thing worth
     * knowing. The thread name separates a fault on the game thread from one on
     * SDL's UI-event path, and those point at completely different code.
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
        /*
         * Dump the surrounding CODE CACHE as raw bytes, not as text.
         *
         * The question this has to answer is whether HotSpot's model of the code
         * cache matches what is actually in memory. -XX:+PrintStubCode prints
         * every stub HotSpot believes it generated, with its address and bytes;
         * if the raw memory disagrees, something is writing to the code cache
         * that should not be, and no amount of JVM-flag tuning will fix that.
         *
         * A 160-byte hex window cannot answer it, and text makes the comparison
         * lossy. So write binary and read it with the same disassembler offline.
         */
        /*
         * Dump the WHOLE mapping, starting at its base.
         *
         * -XX:+PrintStubCode prints every stub with its address and bytes, and
         * the code-cache base is stable across runs with the same options, so
         * the printed addresses can be compared directly against these bytes.
         * That comparison is what separates the two explanations that matter:
         *   - memory matches the print  -> HotSpot generated exactly this and the
         *     anomaly is in how it is reached, not in what is stored;
         *   - memory differs            -> something wrote into the code cache
         *     that should not have, and no JVM flag will fix that.
         * A window around the PC cannot answer it, because the stubs worth
         * checking are elsewhere in the mapping.
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

/*
 * Why we preload:
 *   libjvm.so's DT_NEEDED is [libcxxabi_shim.so, libc.so]. That shim is a
 *   private library of this ad-hoc JDK build and lives in <java.home>/lib,
 *   which is NOT on the dynamic linker's search path. The first dlopen of
 *   libjvm.so therefore failed with musl's unhelpful "No error information".
 *
 *   Fix: dlopen every .so in <java.home>/lib ourselves with RTLD_GLOBAL, so
 *   that when the loader later resolves libjvm.so's DT_NEEDED it finds the
 *   already-loaded library by SONAME. libjvm.so itself goes last and global,
 *   because libjava.so (& friends) declare a NEEDED on it.
 *   This is the same trick mobile Java launchers use.
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

/* is this file an ELF shared object? (the dir also holds the jimage, named *.so) */
static bool is_elf(const char *path)
{
    int fd = open(path, O_RDONLY);
    if (fd < 0) return false;
    unsigned char m[4];
    ssize_t n = read(fd, m, 4);
    close(fd);
    return n == 4 && m[0] == 0x7f && m[1] == 'E' && m[2] == 'L' && m[3] == 'F';
}

/*
 * Load order matters. Every other JDK library (libjava, libnet, libnio,
 * libjimage, ...) declares DT_NEEDED on the bare name "libjvm.so", and this
 * directory is not on the loader's search path, so libjvm.so has to be brought
 * in FIRST with its full path and RTLD_GLOBAL. The others then resolve their
 * dependency against the already-loaded library. Doing it the other way round
 * was what produced a wall of "libjvm.so: (needed by ...)" failures.
 */
/*
 * NOTE: the preload loop is GONE, and that is a real change of substance.
 *
 * It existed for an older layout in which the real libjvm.so sat in
 * <java.home>/lib/server/ with a DT_NEEDED on the JDK's private C++ shim, which
 * was not on the loader's search path -- so every JDK library had to be dlopen'd
 * by hand, RTLD_GLOBAL, before libjvm.so could be loaded at all.
 *
 * The current layout already resolves that: libjvm_real.so's only needs are
 * libcxxabi_shim.so and libc.so, and our shim sits on the search path. The
 * remaining JDK libraries are ones the JVM loads itself, by full path, from
 * sun.boot.library.path -- the way it does on every other platform.
 *
 * Keeping the loop would not be harmless: it pushes 35 libraries into the global
 * symbol scope AHEAD of the JVM, so any name they share with libjvm.so can be
 * interposed onto hot spot's own calls. The JVM is not written to survive that,
 * and it is a plausible source of a jump into data.
 */
static void load_anchor_only(void)
{
    SDL_Log(" --- dlopen diagnostics ---");
    try_dlopen("libSDL3.so", "control: SDL3");
    try_dlopen(g_anchor, "anchor libjvm.so");
    SDL_Log(" --- end diagnostics ---");
}

/* option strings: the JVM may write into these, so they must be mutable */
static char opt_classpath[1024];   /* four entries; three would fit in 512 today */
static char opt_home[512];
static char opt_tmpdir[512];
static char opt_libpath[512];
static char opt_encoding[512];
static char opt_headless[512];
static char opt_bootlib[512];
static char opt_errfile[512];
static char opt_heap[512];
/* the two flags that decide whether the JVM starts at all -- see start_jvm() */
static char opt_unsve[512];
static char opt_sve[512];
/*
 * Three platform properties, supplied as VM creation options rather than in the
 * runtime options file because the game's platform detection reads them at
 * class-initialisation time, before anything we could set from Java would take
 * effect.
 *
 *   os.name      the JVM reports the host OS to Java through this. Every
 *                LWJGL/Arc native lookup in the game is keyed off it, and the
 *                known-good reference configuration on this device reports
 *                "Linux" here -- on the real value the game would look for
 *                HarmonyOS/Android natives that do not exist in this layout.
 *   user.home    where the game keeps saves and settings. Without it the JVM
 *                guesses from /etc/passwd, which does not exist here.
 *   user.dir     the working directory for relative paths at startup.
 *
 * Provenance: that these need setting was learned from a known-good reference
 * launcher running on this same device, not from any published source. Our own
 * notes disagree about how that reference supplies them -- as creation options,
 * or through System.setProperty once the VM is up -- which does not matter
 * here: they must be in place before class initialisation, so this launcher
 * passes them at creation. Only the os.name value mirrors the reference;
 * user.home and user.dir are this launcher's own sandbox paths (DEST_ROOT).
 */
static char opt_osname[512];
static char opt_userhome[512];
static char opt_userdir[512];
/* where LWJGL looks for the natives it dispatches through -- see LWJGL_LIBS */
static char opt_lwjglpath[512];
/*
 * Tell Arc's SDL backend to ask for the OpenGL ES profile.
 *
 * OpenHarmony ships OpenGL ES and Vulkan and no libGL.so at all, so a core or
 * compatibility request binds EGL_OPENGL_API, finds no config, and the window
 * cannot be created. Arc has no way to work this out for itself, so the choice
 * is made here. Read by SdlApplication.profile(); see arc.sdl.glEs there.
 */
static char opt_gles[512];
/*
 * Tell Arc this is a touch device.
 *
 * The backend answers isMobile() from getType(), which is android or iOS and so
 * false here, and Mindustry picks its entire input layer from that one bit:
 *
 *     input = Vars.mobile ? new MobileInput() : new DesktopInput();
 *
 * False means a tablet gets WASD bindings, no joystick and no on-screen buttons
 * -- a desktop build on a touch screen, which is exactly what it looked like.
 * Read by SdlApplication.isMobile(); see arc.sdl.mobile there.
 */
static char opt_mobile[512];

/*
 * Where the game's file browser should open.
 *
 * The game roots it at Arc's getExternalStoragePath(), which SdlFiles computes
 * from user.home -- and user.home is this launcher's own sandbox, the one place
 * the player cannot put a file. So "import save" could browse but never find
 * anything to import.
 *
 * The value is not hardcoded: ArkTS asks the platform for its real
 * user-visible directory (environment.getUserDownloadDir) and writes it to
 * user_dirs.txt, and this reads it back. That keeps a device-specific path out
 * of the launcher, and the permission behind it (granted at runtime) is what
 * makes the directory readable at all -- measured, see probe_user_dirs().
 */
static char opt_chooser[512];

/*
 * Ordered probe. "Error loading X: (needed by Y)" is ambiguous about WHERE in
 * the chain it broke, so ask each question separately and print the answer with
 * its own dlerror(). Everything here is read-only.
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
    /* same flags as the real load -- a probe that uses RTLD_NOW would report a
     * failure for a library that actually loads fine in lazy mode. */
    void *h = dlopen(path, RTLD_LAZY | RTLD_GLOBAL);
    if (h) {
        SDL_Log("   OK  %-20s %s", label, path);
    } else {
        SDL_Log("   NO  %-20s %s", label, path);
        SDL_Log("         -> %s", dlerror());
    }
}

/*
 * A short, ordered list of questions whose answers cannot be inferred from each
 * other: is the file there, what mode is it, does the CONTROL load, do the two
 * pieces of the JVM load. Earlier rounds of this launcher wasted a lot of time on
 * a single ambiguous message like
 *      Error loading shared library X: (needed by Y)
 * which is compatible with a dozen different causes.
 *
 * Kept deliberately narrow -- the A/B experiments that found the real bug (a
 * corrupted .dynamic table, see patch_libjvm.py) have done their job and their
 * probe files are gone.
 */
/*
 * Is a HAP resource file reachable as an ORDINARY FILESYSTEM PATH?
 *
 * This matters more than it looks. hvigor ships only `*.so` from entry/libs/, so
 * the JDK that way loses every data file -- `modules` (forcing the jimg.so
 * rename), `conf/`, `release`, `classlist`, `jvm.cfg`. A HAP's rawfile area has
 * no such filter: whatever is placed under resources/rawfile goes in verbatim,
 * names intact.
 *
 * If that area also exists as a real path under the app's bundle directory, then
 * the ENTIRE UNMODIFIED JDK can ship there -- which would remove the rename, the
 * missing configuration files, and the need for a custom ELF loader all at once.
 *
 * So: place `resources/rawfile/rawfile_probe.txt` in the project, build, and ask
 * the running app which of the plausible paths actually resolves. Only the app
 * can see its own bundle area; hdc cannot.
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

/*
 * Can this process reach the system's EGL/GLES at all?
 *
 * SDL's OpenHarmony video driver loads exactly two names, by bare name rather
 * than by path: DEFAULT_EGL "libEGL.so" and DEFAULT_OGL_ES2 "libGLESv3.so". Both
 * files exist on the device (/system/lib64), so SDL_CreateWindow failing with
 * "Could not initialize OpenGL / GLES library" means the load is being refused
 * rather than the file being absent -- and those are very different problems.
 *
 * The bare name matters: a bare name goes through the linker's search path for
 * this process, which for an app is a restricted namespace, whereas an absolute
 * path either resolves or does not. Asking for both forms at once separates
 * "not on the search path" from "not permitted at all".
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
    /*
     * Both binding modes, because SDL uses RTLD_NOW:
     *
     *     handle = dlopen(sofile, RTLD_NOW | RTLD_LOCAL);   // SDL_sysloadso.c
     *
     * LAZY resolves function relocations at first call, so a library with a
     * symbol nothing provides still loads. NOW resolves everything up front and
     * refuses. A library that loads lazily and fails eagerly is indistinguishable
     * from a missing library if only one mode is tested -- and this project has
     * already been fooled once by exactly that, with __cxa_thread_atexit.
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

/*
 * Aim the game's SDL at the system GLES library.
 *
 * Arc's SDL backend never asks for the ES profile -- it only ever sets CORE or
 * COMPATIBILITY -- and SDL's OpenHarmony driver loads libGLESv3.so ONLY when the
 * profile is ES and the major version is above 1:
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
 * OpenHarmony defines only DEFAULT_OGL_ES2, so with a CORE or COMPATIBILITY
 * profile nothing is loaded at all and the window creation fails with "Could not
 * initialize OpenGL / GLES library" -- which reads like a missing library and is
 * not one. Both libEGL.so and libGLESv3.so load fine from this process, by bare
 * name and by path, lazily and eagerly; that was measured before this was
 * written.
 *
 * SDL_HINT_OPENGL_LIBRARY is checked before any of that branching, so it is the
 * one lever that does not require changing Arc. SDL_HINT_OPENGL_ES_DRIVER, which
 * sounds like the right knob, is only consulted by the Windows, X11 and Cocoa
 * backends, never by the shared EGL path.
 *
 * The hint has to be set on the SDL instance the GAME will use, which is not the
 * one this launcher links against: the game reaches SDL through LWJGL, and LWJGL
 * loads the copy in LWJGL_LIBS. dlopen of that same path returns the same
 * mapping, so setting the hint through it reaches the right instance.
 */
static void configure_game_sdl(void)
{
    const char *sdlpath = BUNDLE_LIBS "/libSDL3.so";

    /*
     * There is more than one libSDL3.so in the bundle, and the obvious
     * assumption -- that the game uses the one next to the LWJGL jars -- is
     * worth checking before trusting it, because both copies are built with
     * -DCMAKE_PLATFORM_NO_VERSIONED_SONAME=1 and therefore both carry the SONAME
     * "libSDL3.so". A loader that resolves by SONAME returns whichever copy was
     * loaded first, which here is the launcher's own. Setting a hint on the
     * other mapping would then look like it worked and change nothing.
     *
     * SDL_GetHint's address answers it: same address means same instance.
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

    /*
     * Both routes, because which one matters depends on the answer above: the
     * direct call is the launcher's own SDL, the handle route is whatever that
     * path resolves to. Setting it on both costs nothing and removes the need to
     * have got the instance question right.
     *
     * priority 2 is SDL_HINT_OVERRIDE, the highest, so nothing running later can
     * quietly ignore it.
     */
    struct { const char *k, *v; } hints[] = {
        { "SDL_OPENGL_LIBRARY", "/system/lib64/libGLESv3.so" },
        { "SDL_EGL_LIBRARY",    "/system/lib64/libEGL.so"    },
    };
    typedef bool (*set_prio_t)(const char *, const char *, int);
    set_prio_t viaHandle = h ? (set_prio_t)dlsym(h, "SDL_SetHintWithPriority")
                             : NULL;

    for (unsigned i = 0; i < sizeof(hints) / sizeof(hints[0]); i++) {
        /* bool, not SDL_bool: SDL3 renamed it, and the old name now expands to a
         * deliberately undeclared identifier so that stale code fails to build
         * rather than silently mismatching. */
        bool direct = SDL_SetHintWithPriority(hints[i].k, hints[i].v,
                                              SDL_HINT_OVERRIDE);
        bool via = viaHandle ? viaHandle(hints[i].k, hints[i].v, 2) : false;
        SDL_Log("   %-20s = %-30s direct=%s handle=%s -> now reads '%s'",
                hints[i].k, hints[i].v, direct ? "ok" : "REFUSED",
                via ? "ok" : "-", SDL_GetHint(hints[i].k));
    }

    /*
     * Ask each instance to do the load the game's SDL does internally, and let
     * it say why if it cannot.
     *
     * The hint is set on both copies and read back correctly on both, and the
     * game still reports the same failure -- so the hint is not the thing that
     * matters here. This asks the question the hint was standing in for: can
     * THIS instance load the system GLES library at all? A library loaded
     * through one path can end up in a different linker namespace from one
     * loaded through another, and a namespace that cannot see /system/lib64
     * would explain everything while looking exactly like a missing file.
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

/* copy src to dst, creating dst with mode 0755 */
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

/*
 * Can this process dlopen a library that sits in its OWN writable area?
 *
 * This is the question the whole JDK-placement design turned on, and the answer
 * on record ("no, the sandbox is not executable") came from a single sample --
 * a hand-written shim that may have failed for its own reasons. That is not a
 * good enough basis, and the cost of being wrong is high: if libarcarm64.so can
 * be loaded from a writable directory, Arc's own extraction works and nothing
 * special is needed; if it cannot, the whole native layout has to change.
 *
 * Arc's loader puts the library in java.io.tmpdir. Under AMCL that directory was
 * the module-level files dir and the game ran; here it is the app-level temp dir
 * and the load fails with EINVAL. Both are writable, so the difference, if it is
 * real, is in how they are mounted -- and there are only a handful of candidates.
 *
 * So: two different libraries (one sample would not distinguish a platform rule
 * from a property of the file), copied into every candidate directory, each
 * dlopen'd and each reported with its own dlerror. The bundle copy is the
 * control: it must succeed, or the probe itself is broken.
 */
static void probe_sandbox_exec(void)
{
    static const char *srcs[] = {
        BUNDLE_LIBS "/lwjgl/liblwjgl.so",
        BUNDLE_LIBS "/libSDL3.so",
    };
    static const char *names[] = { "liblwjgl.so", "libSDL3.so" };
    static const char *dirs[] = {
        DEST_ROOT,                                    /* app-level files   */
        DEST_ROOT "/execprobe",
        TMP_DIR,                                      /* app-level temp    */
        TMP_DIR "/execprobe",
        "/data/storage/el2/base/haps/entry/files",    /* module-level files,
                                                       * which is where AMCL
                                                       * extracted to        */
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

/*
 * Extra JVM options, read at run time from a file in the app's own sandbox.
 *
 * Why this exists: trying one -XX flag used to cost a full rebuild, re-sign,
 * reinstall of a 171 MB HAP and a relaunch -- several minutes per guess, for a
 * question ("which flag stops the trap?") that needs many guesses. The sandbox
 * directory is writable by the app and readable over hdc, so a plain text file
 * pushed with `hdc file send` turns that loop into seconds.
 *
 * One option per line; blank lines and lines starting with # are ignored.
 */
/*
 * How many options this launcher supplies itself, before whatever the runtime
 * options file adds.
 *
 * It is a named constant because it is used as an array bound and as an index
 * origin in five places; when it was a bare 11, adding a built-in option meant
 * finding every one of them, and missing one would silently drop options or
 * read past the filled part of the array.
 */
#define BASE_OPTS 18
#define MAX_EXTRA_OPTS 32
static char g_extra[MAX_EXTRA_OPTS][256];

/* Candidate locations, tried in order. hdc can only WRITE to some of these (the
 * app's own sandbox is readable by shell but not writable), so the app reports
 * which one it actually opened and that becomes the iteration channel. */
static const char *OPTION_PATHS[] = {
    /* ArkTS writes here from the launch parameters -- see EntryAbility.ets.
     * context.filesDir resolves to the ability's own files dir, which is NOT the
     * same directory as DEST_ROOT (that one is the application-level files dir). */
    "/data/storage/el2/base/haps/entry/files/jvm.options",
    DEST_ROOT "/jvm.options",
    "/data/local/tmp/jvm.options",
};

static const char *open_options_file(void)
{
    for (unsigned i = 0; i < sizeof(OPTION_PATHS) / sizeof(OPTION_PATHS[0]); i++) {
        FILE *f = fopen(OPTION_PATHS[i], "r");
        if (f) { fclose(f); return OPTION_PATHS[i]; }
    }
    return NULL;
}

/* does any candidate options file contain this marker? (non-static: used in main) */
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

/*
 * Can this process actually RUN code it generated into anonymous memory?
 *
 * This is the one capability the whole ACL detour was about
 * (ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY). A JVM cannot start
 * without it: HotSpot writes stubs and trampolines into anonymous RWX memory and
 * then jumps into them. If those pages are not truly executable, or the write is
 * not visible to the instruction fetch, the CPU traps -- and the fault address
 * lies in no module at all, so dladdr() reports "in ?", which is exactly what
 * the SIGILL inside JNI_CreateJavaVM looked like.
 *
 * So ask the question directly instead of inferring it from a crash: map one RWX
 * page, write a two-instruction aarch64 function into it, flush the icache, call
 * it. Expected answer 42.
 */
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

/*
 * ---------------------------------------------------------------------------
 * SELF-MODIFYING CODE: does a store to an ALREADY-EXECUTABLE page take effect?
 *
 * WHY THIS IS THE RIGHT QUESTION NOW
 *   HarmonyOS blocks exactly two things related to executable memory -- mapping a
 *   FILE as executable, and memfd as executable -- while allowing anonymous
 *   executable memory freely. Both blocks are about "code that came from a file".
 *   (Measured previously on this project's probes: errno=13 for both.)
 *
 *   All of HotSpot's generated code lives in anonymous memory (our crash dump's
 *   mapping line has no file backing: `rwxp 00000000 00:00 0`), so those blocks do
 *   not stop the JVM from RUNNING generated code.
 *
 *   But they put the focus on the one property nobody has tested here: HotSpot's
 *   code cache is simultaneously writable and executable, and HotSpot PATCHES
 *   code in place -- it stores new instructions into a page that is already
 *   executable, with no mprotect round-trip. On ARM, the data cache and the
 *   instruction cache are not coherent, so such a store is only visible to the
 *   fetch unit after explicit cache maintenance. If that maintenance does not
 *   happen, or does not work in this sandbox, the CPU executes the PREVIOUS
 *   contents of those bytes.
 *
 *   That failure would look exactly like what we measured:
 *     - the memory matches what HotSpot printed at generation time (memory IS new)
 *     - the CPU nonetheless goes somewhere else (it is running the old bytes)
 *     - it is fully deterministic (same patch sequence every run)
 *     - -Xint and the code-cache sizing flags change the offset but never fix it
 *     - the fault sits immediately after a blr, at a patched constant -- the
 *       exact place a freshly patched site is first executed
 *
 * THE FOUR MEASUREMENTS
 *   1. write A, flush, run          -> expect 1   (baseline: exec works)
 *   2. write B, NO flush, run       -> 2 means the caches are coherent here and
 *                                      the hypothesis is dead; 1 means the fetch
 *                                      unit kept the old instruction
 *   3. write C, flush, run          -> expect 3   (does explicit maintenance work?)
 *   4. write D, mprotect RW then RX -> expect 4   (does the mprotect path work?)
 *
 *   Step 3 is the decisive one. Step 2 alone does not prove a platform defect:
 *   on most ARMv8 cores a store without maintenance is legitimately invisible, and
 *   HotSpot knows that. What would be damning is step 3 failing, because that is
 *   the very operation HotSpot relies on.
 * ---------------------------------------------------------------------------
 */
/*
 * One test case on its OWN fresh page.
 *
 * A shared page is what broke the previous revision of this probe: case 4 left
 * the page mapped RX, so case 5's memcpy faulted before its own mprotect could
 * run, and the resulting SIGSEGV looked like a platform finding when it was a
 * bug in the test. A page per case removes every interaction.
 *
 * mode:
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
    /* movz w0, #expect ; ret   -- the immediate lives in bits 20:5 */

    void *p = mmap(NULL, 4096, PROT_READ | PROT_WRITE | PROT_EXEC,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) { SDL_Log("    mmap failed errno=%d", errno); return -1; }

    long r = -1;
    /* every write happens while the page is still RWX or has been made RW */
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
        r = (a == b && b == c) ? a : -100 - (int)a;   /* encode instability */
        break;
    }
    }
    munmap(p, 4096);
    return r;
}

/*
 * Overwrite code that HAS ALREADY BEEN EXECUTED.
 *
 * This is the scenario that matters, and an earlier revision of this probe lost
 * it by giving each case a never-executed page: a write to a page whose
 * instructions have never been fetched is trivially fine, so every case passed
 * and the hypothesis looked dead for the wrong reason.
 *
 * HotSpot does exactly this: it generates code, the code runs, and later HotSpot
 * goes back and PATCHES those same instructions (writes an address into a site
 * that was already executed). So every case here does:
 *
 *     write v1 -> make it visible -> CALL it   (this populates the fetch unit)
 *     write v2 -> apply the mechanism under test -> CALL again
 *
 * and reports the SECOND call. A correct platform returns v2. Returning v1 means
 * the fetch unit kept the old instruction.
 *
 * mode (what happens between writing v2 and calling):
 *   0  nothing at all
 *   1  clear_cache                                  <- the CONTROL
 *   2  mprotect RW->RX
 *   3  mprotect RW->RX, then clear_cache
 *   4  clear_cache, then mprotect RW->RX
 */
static long icache_rewrite_case(int v1, int v2, int mode)
{
    unsigned int c1[2] = { 0x52800000u | ((unsigned)v1 << 5), 0xd65f03c0u };
    unsigned int c2[2] = { 0x52800000u | ((unsigned)v2 << 5), 0xd65f03c0u };

    void *p = mmap(NULL, 4096, PROT_READ | PROT_WRITE | PROT_EXEC,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) return -1;
    long (*fn)(void) = (long (*)(void))p;

    /* phase 1: install v1 and RUN it, so the fetch unit now holds v1 */
    SDL_memcpy(p, c1, 8);
    __builtin___clear_cache((char *)p, (char *)p + 8);
    long first = fn();
    if (first != v1) {
        SDL_Log("    (setup failed: wrote %d, got %ld)", v1, first);
        munmap(p, 4096);
        return -1000;
    }

    /* phase 2: overwrite with v2 using the mechanism under test */
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

/* which mapping (if any) contains this address? async-signal-unsafe on purpose:
 * we are already dying and the answer matters more than the rules. */
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

/*
 * Say out loud which of the shipped files actually arrived.
 *
 * hvigor drops anything under entry/libs/** whose name does not end in ".so", and
 * it does so silently -- that is how the JDK's conf/ directory disappeared, and
 * it is the reason the game jar and the LWJGL jars are renamed. A missing file
 * here would otherwise surface much later as a confusing class-loading or
 * dlopen error, so it is worth one line each and a plain size.
 */
/*
 * TEMPORARY DIAGNOSTIC -- remove once the window question is settled.
 *
 * Writes a marker into the SAME file the instrumented SDL writes its XComponent
 * surface events to, so the two timelines can be read in one place. The question
 * being asked is one of ORDER -- does the surface still exist by the time the
 * game asks for a window, seconds after the surface callback started us -- and
 * two separate logs cannot answer that.
 */
static void probe_mark(const char *what)
{
    FILE *f = fopen(DEST_ROOT "/sdl_surface.log", "a");
    if (f) {
        fprintf(f, "=== APP %s ===\n", what);
        fclose(f);
    }
}

/*
 * NOTE: an attempt to have SDL export a diagnostic getter for the launcher to
 * call did not link -- SDL's build restricts exports to its own symbol list, so
 * visibility("default") is not enough to add one. The surface-copy question is
 * answered from SDL's own log instead; see SDL_openharmonyvideo.c.
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
        /* stat() rather than fopen(): opening an 87 MB jar to answer "is it
         * there" would be silly, and this is the same call the loader makes. */
        struct stat st;
        if (stat(paths[i], &st) == 0) {
            SDL_Log("   %9ld  %s", (long)st.st_size, paths[i]);
        } else {
            SDL_Log("   MISSING            %s", paths[i]);
        }
    }
    SDL_Log(" --- end shipped files ---");
}

/*
 * Build the directory java.home will be pointed at: <sandbox>/jdk/lib/modules as
 * a symlink to the shipped module image. See SANDBOX_JDK for why.
 *
 * An existing link is removed first. Keeping it would be faster, but a stale link
 * pointing at a target that no longer exists is indistinguishable from a working
 * one until the module lookup fails, which is the failure this exists to avoid.
 */
/*
 * Put one shipped file where java.home expects to find it, once.
 *
 * Written under a temporary name and renamed into place: a copy interrupted
 * halfway would otherwise leave a file that passes an existence check and fails
 * inside the JVM instead. Size is the whole "is it already there" test, because
 * the only way a file of the right size can be present is a completed rename.
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
    /* rename() is the commit point -- see the note above. */
    if (rename(tmp, dst) != 0) {
        SDL_Log(" !! rename %s: %s", tmp, strerror(errno));
        unlink(tmp);
        return 7;
    }
    return 0;
}

/*
 * Build the directory java.home will be pointed at.
 *
 * Two files have to be there, under the names java.base looks for:
 *   lib/modules    the module image. Shipped as jimg.so (patch_libjvm.py) because
 *                  hvigor only carries names ending in ".so"; java.base builds
 *                  the name "modules" itself and will not accept anything else.
 *   lib/tzdb.dat   the time-zone database. Shipped as tzdb.so (prep_jdklib.py)
 *                  for the same reason. Missing, it does not merely spoil
 *                  timestamps -- sun.util.calendar.ZoneInfoFile fails to
 *                  initialise, and the first DateFormat request anywhere in the
 *                  program throws. Mindustry asks for one in Saves.<clinit>.
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
    return 0;
}

/*
 * Rewrite java.home from inside the VM, before anything reads it.
 *
 * This is not belt-and-braces: the value HotSpot derived points at the bundle,
 * where the module image is called jimg.so, and java.base insists on "modules".
 * The window is real and wide -- ImageReaderFactory is a lazily initialised
 * class, and the first thing that touches it in this program is the game's own
 * resource lookup -- so doing it here, immediately after the VM exists, is in
 * time. Anything later would not be.
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

/*
 * Load Arc's natives from the bundle and mark them loaded, so Arc's own loader
 * has nothing left to do. See ARC_LIBS for why they cannot be loaded the way Arc
 * intends to load them.
 *
 * Best-effort by design: a native that will not load is reported and skipped
 * rather than aborting the launch, because the game's own error for a missing
 * native names the library and the caller, and that is more useful than a
 * failure here. What must not happen is a half-state -- so a library is marked
 * loaded ONLY after System.load has actually returned without an exception.
 */
static void preload_arc_natives(JNIEnv *env)
{
    static const char *keys[]  = { "arc", "arc-freetype", "arc-filedialogs" };
    static const char *files[] = { "libarcarm64.so",
                                   "libarc-freetypearm64.so",
                                   "libarc-filedialogsarm64.so" };
    const unsigned N = sizeof(keys) / sizeof(keys[0]);

    /*
     * Everything goes through our own class rather than System.load directly.
     * Calling System.load from here registers the library against the wrong
     * class loader and the game then cannot find its native methods even though
     * the load reported success -- see NativeLoader.java.
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
            continue;                    /* deliberately not marked */
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

/*
 * Step 4 of the blueprint: reflectively call the game's entry point.
 *
 * WHAT COUNTS AS PASSING
 *   The blueprint's acceptance line for this step is "Mindustry starts -- even
 *   with no picture on screen". So the pass condition is that the GAME'S OWN
 *   code runs, which is observable as its own output on stdout. A window is
 *   explicitly NOT part of this step (that is step 5), so an SDL or GL failure
 *   after main() has begun still counts as "it started" and is reported as a
 *   distinct outcome rather than as a failure of this step.
 *
 * WHY REFLECTIVE, AND WHY HERE
 *   The entry point is invoked through JNI rather than by handing a main class
 *   to the launcher, because there is no launcher: this is the launcher. Starting
 *   the VM and then calling main ourselves is the whole design.
 *
 *   The call is made on this thread -- the one SDL created for SDL_main -- and it
 *   blocks until the game returns. That is intended: a game's main() runs its own
 *   loop and returns at exit.
 */
static int launch_game(JNIEnv *env)
{
    static const char *MAIN_CLASS = "mindustry/desktop/DesktopLauncher";
    static const char *MAIN_DESC  = "([Ljava/lang/String;)V";

    SDL_Log(" --- step 4: launching the game ---");

    SDL_Log(" classpath: %s", GAME_JAR);

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

    /* an empty String[] -- the game supplies its own defaults */
    jclass strcls = (*env)->FindClass(env, "java/lang/String");
    jobjectArray argv = (*env)->NewObjectArray(env, 0, strcls, NULL);
    if (!argv) {
        SDL_Log(" !! could not build the argument array");
        return 3;
    }

    SDL_Log("   -> calling %s.main(new String[0]) ...", MAIN_CLASS);
    (*env)->CallStaticVoidMethod(env, cls, mid, argv);

    /* Reaching this line means main() returned. For a game that is either a
     * clean exit or a failure inside startup -- an exception still pending here
     * tells the two apart, so report it rather than assuming either way. */
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
    probe_gl_libs();
    probe_sandbox_exec();
    probe_user_dirs();
    int modok = prepare_java_home();
    diagnose_loading();
    load_anchor_only();

    char libjvm[1400];
    SDL_snprintf(libjvm, sizeof(libjvm), "%s", g_anchor);

    /*
     * RTLD_LAZY, deliberately -- not as a fallback after RTLD_NOW fails.
     *
     * libjvm.so declares __cxa_thread_atexit as a STRONG undefined symbol
     * (GLOBAL, not WEAK -- readelf --dyn-syms), and NOTHING on this platform
     * provides it: the JDK's own libcxxabi_shim.so does not export it, and neither
     * does OHOS libc. So RTLD_NOW cannot ever succeed here.
     *
     * Lazy binding sidesteps it: function relocations are resolved at first call,
     * so the load succeeds and the symbol only matters if it is actually used.
     * That is also how the library is meant to be loaded -- libjvm.so carries no
     * DF_BIND_NOW flag, so lazy binding is its normal mode.
     *
     * Evidence this is the right call: AMCL, which runs on this device with the
     * SAME libjvm.so and the UNMODIFIED shim, must be resolving it the same way.
     * Our previous workaround -- a hand-written shim that supplied
     * __cxa_thread_atexit -- is gone, and removing it changed nothing about the
     * failure, which is exactly what a red herring should do.
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

    /*
     * The class path is the game plus LWJGL. LWJGL is not optional here: the
     * game's own backend classes cannot be linked without org.lwjgl.*, so a
     * failure to find them shows up while loading the application, not while
     * loading the game's main class.
     */
    SDL_snprintf(opt_classpath, sizeof(opt_classpath),
                 "-Djava.class.path=%s:%s/lwjgl.so:%s/lwjgl-opengl.so:%s/lwjgl-sdl.so:%s",
                 GAME_JAR, LWJGL_JARS, LWJGL_JARS, LWJGL_JARS, HELPER_JAR);
    /*
     * The bundle library directory comes FIRST, and that ordering is the whole
     * point.
     *
     * There are two copies of libSDL3.so in the bundle: this launcher's own, at
     * the top level, and LWJGL's, in LWJGL_LIBS. The ArkTS XComponent names
     * "SDL3" when it is created, which loads the top-level one and hands it the
     * native window; the game reaches SDL through LWJGL, which would load the
     * other one. Each copy keeps its own globals, so the copy that creates the
     * window is not the copy that was given the window, and window creation
     * fails with
     *
     *     OpenHarmony host has no ready NativeWindow lease
     *
     * -- a message that exists in LWJGL's build and not in the launcher's, which
     * is how the two were told apart.
     *
     * Listing the bundle first makes LWJGL find the launcher's copy, so there is
     * one instance and it is the one holding the window. The launcher's copy
     * still provides liblwjgl.so and liblwjgl_opengl.so from LWJGL_LIBS.
     */
    SDL_snprintf(opt_lwjglpath, sizeof(opt_lwjglpath),
                 "-Dorg.lwjgl.librarypath=%s:%s", BUNDLE_LIBS, LWJGL_LIBS);
    /*
     * java.home points at the SANDBOX copy, not at the bundle, and it has to be
     * right from the moment the VM is created.
     *
     * Two files java.base opens by name cannot travel in the bundle: hvigor
     * carries only names ending in ".so", so the module image ships as jimg.so
     * and the time-zone database as tzdb.so. They are copied into
     * <sandbox>/jdk/lib/ under the names java.base actually builds --
     * "modules" and "tzdb.dat" -- and java.home is aimed there.
     *
     * Correcting java.home from Java, after the VM is up, is NOT enough, and
     * that was measured rather than assumed: sun.util.calendar.ZoneInfoFile kept
     * reading "<bundle>/jdk21/lib/tzdb.dat" and threw FileNotFoundException even
     * though System.setProperty had already succeeded and read back the new
     * value. The JDK caches this property in static finals initialised during VM
     * startup, so a value changed afterwards is invisible to them.
     *
     * NOTE for the record: the earlier conclusion that HotSpot overwrites
     * -Djava.home was drawn from runs where the value passed was the same one
     * HotSpot would derive, so the two were indistinguishable. This is the first
     * run that can actually tell them apart.
     */
    SDL_snprintf(opt_home,      sizeof(opt_home),      "-Djava.home=%s", SANDBOX_JDK);
    SDL_snprintf(opt_tmpdir,    sizeof(opt_tmpdir),    "-Djava.io.tmpdir=%s", TMP_DIR);
    SDL_snprintf(opt_libpath,   sizeof(opt_libpath),   "-Djava.library.path=%s/server:%s", g_jdklib, g_jdklib);
    SDL_strlcpy(opt_encoding,   "-Dfile.encoding=UTF-8", sizeof(opt_encoding));
    SDL_strlcpy(opt_headless,   "-Djava.awt.headless=true", sizeof(opt_headless));
    /* the JVM looks for libjava.so & friends here, not in java.home/lib */
    SDL_snprintf(opt_bootlib,   sizeof(opt_bootlib), "-Dsun.boot.library.path=%s:%s/server", g_jdklib, g_jdklib);
    /* make the JVM put its crash report somewhere we can read it via hdc */
    SDL_snprintf(opt_errfile,   sizeof(opt_errfile), "-XX:ErrorFile=%s/hs_err_%%p.log", DEST_ROOT);
    SDL_strlcpy(opt_heap,       "-Xmx512m", sizeof(opt_heap));

    /*
     * ---------- THE TWO OPTIONS THAT MAKE OR BREAK THIS LAUNCHER ----------
     *
     * -XX:UseSVE=0  disables the ARM Scalable Vector Extension in the JIT.
     *
     * Without it the JVM dies during JNI_CreateJavaVM with SIGILL, deterministically,
     * at the same address in the interpreter's native-method entry codelet. Measured
     * here as a clean alternating A/B, five rounds: baseline crashed 5/5 at
     * 0x5edf41fc68, UseSVE=0 succeeded 5/5. With the flag the whole startup path
     * completes and Java code runs:
     *     JNI_CreateJavaVM returned 0 / *** JVM CREATED ***
     *     currentTimeMillis, availableProcessors, maxMemory all read back
     *     stdout: *** HELLO FROM THE JVM ***
     *
     * The precise reason SVE cannot be used is not established by this measurement:
     * what IS established is that the CPU faults on code the JIT generated while
     * believing SVE was available, and that turning SVE off makes the JIT emit code
     * that runs. The strongest external corroboration is AMCL -- the launcher that
     * demonstrably runs a JVM on this same device, with the same libjvm.so -- which
     * passes -XX:UseSVE=0 among its options. Its source is not available, but its
     * option list is, and this flag is in it.
     *
     * -XX:+UnlockDiagnosticVMOptions is required first: UseSVE is a diagnostic flag
     * and is rejected outright without it.
     *
     * These are not tuning knobs. They are the difference between a JVM that starts
     * and one that dies, so they live here as defaults rather than in the runtime
     * options file.
     */
    SDL_strlcpy(opt_unsve,  "-XX:+UnlockDiagnosticVMOptions", sizeof(opt_unsve));
    SDL_strlcpy(opt_sve,    "-XX:UseSVE=0", sizeof(opt_sve));

    /* the three platform properties -- see the declaration for why */
    SDL_strlcpy(opt_osname,   "-Dos.name=Linux", sizeof(opt_osname));
    SDL_snprintf(opt_userhome, sizeof(opt_userhome), "-Duser.home=%s", DEST_ROOT);
    SDL_snprintf(opt_userdir,  sizeof(opt_userdir),  "-Duser.dir=%s",  DEST_ROOT);
    SDL_strlcpy(opt_gles, "-Darc.sdl.glEs=true", sizeof(opt_gles));
    SDL_strlcpy(opt_mobile, "-Darc.sdl.mobile=true", sizeof(opt_mobile));

    {
        /* Read the platform's own answer rather than guessing a path. Empty
         * result leaves the property unset, and SdlFiles then keeps its old
         * behaviour -- a browser rooted in the sandbox. Browsing still works;
         * only importing is impossible, which is exactly what it was before. */
        char dl[512];
        if (read_user_dir("download", dl, sizeof(dl)) > 0) {
            SDL_snprintf(opt_chooser, sizeof(opt_chooser), "-Darc.sdl.chooserPath=%s", dl);
            SDL_Log(" file browser will open at: %s", dl);
        } else {
            SDL_strlcpy(opt_chooser, "-Darc.sdl.chooserPath=", sizeof(opt_chooser));
            SDL_Log(" no user download dir available -- file browser stays in the sandbox");
        }
    }

    /* BASE_OPTS counts the entries filled in below; the extras are appended
     * after them, so keep the two in step. */
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
    options[17].optionString = opt_chooser;   options[17].extraInfo = NULL;

    /*
     * MINIMAL MODE -- a one-line switch in the runtime options file.
     *
     * Several of the nine built-in -D flags tell HotSpot things it normally works
     * out for itself (java.home, sun.boot.library.path, java.library.path). They
     * were added to get the JDK's libraries found from a non-standard location,
     * but supplying them is itself a deviation from how a normal launcher starts
     * a VM -- and the one configuration we know works on this device (AMCL) sets
     * most of its properties AFTER the VM is up, via System.setProperty, not as
     * creation options.
     *
     * So this mode passes almost nothing and lets the VM do its own derivation.
     * If the crash changes, our option list is implicated. If it does not, the
     * options are exonerated and the difference is elsewhere.
     *
     * Trigger: a line reading exactly  MINIMAL  in jvm.options.
     */
    int nExtra = 0;
    {
        /* read the extras once, into the tail of the array */
        nExtra = load_extra_options(options, BASE_OPTS);
    }

    int minimal = 0;
    int w = BASE_OPTS;
    for (int i = BASE_OPTS; i < BASE_OPTS + nExtra; i++) {
        /* ArkTS prefixes every launch-parameter value with '-', so markers
         * arrive as either NAME or -NAME depending on how they were sent.
         * They are consumed here and never reach the JVM -- an unknown option
         * makes strict mode refuse the whole list, which is how this was found. */
        const char *o = options[i].optionString;
        if (SDL_strcmp(o, "MINIMAL") == 0 || SDL_strcmp(o, "-MINIMAL") == 0) {
            minimal = 1;
            continue;
        }
        if (SDL_strcmp(o, "NOHANDLERS") == 0 || SDL_strcmp(o, "-NOHANDLERS") == 0) {
            continue;                    /* already acted on in main() */
        }
        /* CLEAROPT exists only to make the ArkTS side rewrite jvm.options; its
         * presence means "no options this run", so it is consumed and dropped.
         * Without it, a run with no options keeps the PREVIOUS run's file and
         * silently inherits its flags. */
        if (SDL_strcmp(o, "CLEAROPT") == 0 || SDL_strcmp(o, "-CLEAROPT") == 0) {
            continue;
        }
        /* NOGAME is acted on after the VM is up, not here; it is consumed only
         * so that it never reaches the JVM -- an unknown option makes strict
         * mode refuse the entire list, which would mask the real result. */
        if (SDL_strcmp(o, "NOGAME") == 0 || SDL_strcmp(o, "-NOGAME") == 0) {
            continue;
        }
        options[w++] = options[i];       /* compact the list in place */
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

    JavaVMInitArgs args;
    SDL_memset(&args, 0, sizeof(args));
    args.version = JNI_VERSION_1_8;
    args.nOptions = nOpts;
    args.options = options;

    /*
     * STRICT FIRST, THEN LENIENT -- because "the file was read" is not evidence
     * that a flag was understood.
     *
     * This used to be unconditionally JNI_TRUE (ignore unrecognized). The cost of
     * that only became clear while trying JVM flags to localise a crash: the log
     * said "read 1 extra option(s)" for every flag, but a misspelt or
     * non-existent flag produced exactly the same line and was then silently
     * dropped. Every "that flag does not help" conclusion drawn that way was
     * unsupported, because we could not tell "flag had no effect" from "flag
     * never reached the VM".
     *
     * So: try strict first. An unknown option makes the JVM say so explicitly --
     * either as a returned error code or as a message on stderr, both of which we
     * capture. Then retry lenient so one bad flag in the options file cannot stop
     * the launcher from running at all.
     */
    args.ignoreUnrecognized = JNI_FALSE;

    SDL_Log(" calling JNI_CreateJavaVM (strict) ...");
    for (int i = 0; i < args.nOptions; i++) SDL_Log("   opt: %s", options[i].optionString);

    JavaVM *vm = NULL;
    JNIEnv *env = NULL;
    jint rc = create(&vm, (void **)&env, &args);
    SDL_Log(" JNI_CreateJavaVM (strict) returned %d", (int)rc);

    if (rc != JNI_OK && nOpts > BASE_OPTS) {
        /* The extra options are the only plausible culprits -- the nine built-in
         * ones are known good. Name them, because the useful information is
         * WHICH flag the JVM refused. */
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

    /* Before ANYTHING asks the boot loader for a resource: see SANDBOX_JDK.
     * Only if the image actually made it across -- pointing java.home at a
     * directory without lib/modules in it would replace the VM's own, accurate
     * error message with a less informative one saying the same thing. */
    if (modok == 0) {
        override_java_home(env);
    } else {
        SDL_Log(" !! java.home left alone: the module image is not in place");
    }

    /* --- prove it works: System.out.println from native --- */
    jclass syscls = (*env)->FindClass(env, "java/lang/System");
    if (!syscls) { SDL_Log(" !! FindClass(System) failed"); return 4; }

    jfieldID outId = (*env)->GetStaticFieldID(env, syscls, "out", "Ljava/io/PrintStream;");
    jobject out = (*env)->GetStaticObjectField(env, syscls, outId);
    jclass pscls = (*env)->FindClass(env, "java/io/PrintStream");
    jmethodID println = (*env)->GetMethodID(env, pscls, "println", "(Ljava/lang/String;)V");

    (*env)->CallVoidMethod(env, out, println,
        (*env)->NewStringUTF(env, "*** HELLO FROM THE JVM ***"));

    /* a couple of facts that are only knowable from inside the VM */
    jmethodID curTime = (*env)->GetStaticMethodID(env, syscls, "currentTimeMillis", "()J");
    jlong ms = (*env)->CallStaticLongMethod(env, syscls, curTime);

    jclass rtcls = (*env)->FindClass(env, "java/lang/Runtime");
    jmethodID getRt = (*env)->GetStaticMethodID(env, rtcls, "getRuntime", "()Ljava/lang/Runtime;");
    jobject rt = (*env)->CallStaticObjectMethod(env, rtcls, getRt);
    jmethodID avail = (*env)->GetMethodID(env, rtcls, "availableProcessors", "()I");
    jint cpus = (*env)->CallIntMethod(env, rt, avail);

    /*
     * maxMemory() is here as a POSITIVE CHECK on the option channel.
     *
     * The log line "read N extra option(s) from <file>" only proves the FILE was
     * read -- it says nothing about whether the JVM accepted the flags. Passing
     * -Xmx256m and seeing this number change is the cheap, end-to-end proof that
     * the channel actually reaches the VM. Without it, "that flag had no effect"
     * and "that flag was never seen" are indistinguishable, which is exactly the
     * trap this round fell into.
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

    /*
     * The checks above are step 3's acceptance and stay as they are -- they are
     * the only cheap proof that the VM itself is healthy, and they distinguish
     * "the VM did not start" from "the game did not start". Only once they have
     * all passed is the game handed control.
     *
     * NOGAME skips the handover, so a regression in step 4 can be told apart from
     * a regression in step 3 without a rebuild.
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

int main(int argc, char *argv[])
{
    (void)argc; (void)argv;

    /*
     * Stop SDL from turning touches into mouse events.
     *
     * SDL does this by default (SDL_HINT_TOUCH_MOUSE_EVENTS). The consequence was
     * that every touch arrived twice -- once as an emulated mouse, once as a real
     * finger -- and Arc only understood the mouse half. That is why touch worked
     * for taps but could never pinch: an emulated mouse is only ever pointer 0,
     * and a pinch is defined by the second contact.
     *
     * Set through the environment rather than SDL_SetHint because there are TWO
     * mappings of libSDL3.so in this process and only one of them dispatches the
     * touch events. The environment is shared by both; SDL_SetHint would only
     * reach whichever copy this launcher happens to be linked against.
     *
     * Timing is what makes this work: the copy that matters is the one LWJGL
     * loads, and that happens while the JVM starts the game -- comfortably after
     * this line. The touch probe reads the hint back at dispatch time and prints
     * it, so "the setting did not take" is visible rather than an invisible
     * double-delivery of every input.
     */
    setenv("SDL_TOUCH_MOUSE_EVENTS", "0", 1);

    SDL_Log("==================================================");
    SDL_Log(" Mindustry Launcher -- start the JVM");
    redirect_io();
    /*
     * Everything SDL's XComponent callbacks logged happened BEFORE this mark;
     * everything after it happened while we were starting the JVM and the game.
     * See probe_mark().
     *
     * This file is deliberately NOT truncated here. The surface callback fires
     * before this function runs -- it is what starts it -- so clearing the log at
     * this point would delete exactly the entries that matter. It accumulates
     * across launches instead; clear it from the PC side before a run.
     */
    probe_mark("main() entered: JVM not started yet");
    /* surface-copy probe removed: SDL does not export it */
    /* crash.txt is written with O_APPEND so that a fatal signal -- which can
     * strike before stdout is usable -- never loses the report. That also means
     * it accumulates across launches, and reading it without clearing it first
     * silently mixes several runs together. Start each run empty. */
    unlink(DEST_ROOT "/crash.txt");
    /* The exit markers must not survive a launch. ArkTS polls for them and
     * closes the ability the moment one appears, so a marker left behind by the
     * previous run would shut this run down within a quarter second of start --
     * and it would look like a spontaneous crash rather than a stale file. */
    unlink(EXIT_MARKER_SANDBOX);
    unlink(EXIT_MARKER_MODULE);
    SDL_Log(" stdout/stderr -> %s/{stdout,stderr}.log", DEST_ROOT);
    /* PID vs TID settles a real question: SDL runs SDL_main on a thread it
     * pthread_create()d, not on the process main thread. If they differ, the
     * JVM is being created off the main thread -- which is exactly the case the
     * build plan called the biggest unknown.
     * (The earlier revision printed getpid() twice, so the "they differ"
     * conclusion from that log was an artifact of the print, not a measurement.
     * Fixed here.) */
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

    /*
     * Crash handlers are installed ONLY when the options file does not ask for
     * them to be left alone.
     *
     * Why this became a variable: they have been installed since the very first
     * revision, so they are a constant in every experiment ever run here -- and
     * they cover SIGILL, which is precisely the signal we are dying on.
     *
     * HotSpot installs its OWN handlers during JNI_CreateJavaVM and uses a
     * chaining scheme: if it does not recognise a fault as one of its own, it
     * forwards the signal to whatever handler was installed previously. We see
     * OUR handler run, which means HotSpot forwarded it -- i.e. HotSpot did not
     * claim the fault as its own.
     *
     * That matters because HotSpot deliberately executes illegal instructions as
     * traps and catches them itself. If its handler cannot recognise the trap, an
     * internal mechanism that is supposed to be invisible becomes fatal. Sitting
     * in front of that path from the very beginning is a plausible way to cause
     * exactly the symptom we have.
     *
     * So: put "NOHANDLERS" in jvm.options and this launcher installs nothing,
     * leaving HotSpot's signal handling undisturbed.
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

    /*
     * A 20-second "staying alive 20s ..." sleep loop used to sit here. It was
     * diagnostic scaffolding from the early days, added to watch what happened
     * after main() returned, and it was never removed.
     *
     * It was also the entire cause of the "Quit freezes, then the app exits
     * several seconds later" complaint. The sequence is:
     *
     *   the game's main() returns  -> nothing renders any more, so the picture
     *                                 freezes at that instant
     *   this loop sleeps 20 s      -> during which the process is still alive,
     *                                 so the launcher has not taken over
     *   the loop ends, we return   -> teardown, and only now does the app go
     *
     * So the delay was never in SDL or in a JVM shutdown hook; measured 2026-09-20
     * with quit_timing.sh as ~20 s between the click and the process
     * disappearing, matching this loop's own duration exactly.
     *
     * Removed. Nothing replaced it: there is no work left to do here, the game
     * has already returned, and the sooner we return the sooner the system can
     * tear the app down.
     */
    SDL_Log("==================================================");
    /*
     * Terminate with _exit rather than returning.
     *
     * Returning from main runs the C runtime's atexit handlers and every static
     * destructor, and that teardown ABORTS -- measured, on every single quit:
     *
     *   *** FATAL SIGNAL 6 (code=-6) at ... pc 0x5acff84ef4
     *       in /lib/ld-musl-aarch64.so.1     thread SDL_main
     *
     * and the system duly files it as a crash:
     *
     *   AppMS: ... reason=Cpp Crash ... exitSigno = 6
     *   HiView-CrashValidator: exitSigno = 6
     *
     * The app is on its way out either way, so the signal changes nothing about
     * the outcome -- but it means every normal quit is reported to the OS as a
     * crash, which raises a crash report and can put a dialog in front of the
     * user. That is the wrong story to tell about a button the user pressed.
     *
     * The crashing teardown is not ours to fix at this point: it happens after
     * the game's main() has already returned, while libjvm and SDL are unloaded
     * in an order neither supports on this platform. Nothing is gained by
     * running it -- the process is exiting and the OS reclaims the mappings
     * regardless. So skip it.
     *
     * Flush first: _exit does not run stdio cleanup, and stdout.log/stderr.log
     * are redirected to files whose tail is the most useful evidence we have.
     *
     * The game's own persistence is not affected -- Arc saves its settings
     * during application shutdown, which has already completed by the time
     * main() returns (the audio deinit logged just above marks it). Verified
     * after this change by confirming settings.bin is still rewritten on quit.
     *
     * ---------------------------------------------------------------------
     * Before exiting, hand the shutdown to ArkTS.
     *
     * _exit alone ends the process while the ability is still alive, and that is
     * what the system records as "Cpp Crash" (AppMS: reason=Cpp Crash,
     * killId=2004) -- even with no signal and no crash dump, which is how we know
     * it is a classification of an abnormal-looking exit rather than an actual
     * fault. See quit_timing.sh and the notes in the desktop write-up.
     *
     * So instead: drop a marker, give ArkTS a short window to call
     * terminateSelf(), and exit ourselves if it does not. When it works, the
     * framework tears the ability down and kills the process -- a normal end,
     * with no C runtime teardown of ours in the path either.
     *
     * The window is short and deliberately bounded. If the handshake does not
     * work the app must still exit; a hang here would be far worse than the
     * mislabelled log line this is trying to fix. Measured cost when the
     * fallback is taken: ~1.2 s (quit_timing.sh).
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
