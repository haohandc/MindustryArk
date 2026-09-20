/*
 * libjvm.so -- an ANCHOR, not a JVM.
 *
 * WHY THIS EXISTS
 *   Every JDK library next to libjvm.so (libjava, libnet, libnio, libjimage, ...)
 *   declares DT_NEEDED on the BARE name "libjvm.so". The dynamic linker
 *   satisfies that by searching its library paths, which contain only the HAP's
 *   flat native-lib directory -- not the subdirectory the real libjvm.so lives
 *   in:
 *
 *       real libjvm.so : <bundle>/libs/arm64/jdk21/lib/server/libjvm.so
 *       search path    : <bundle>/libs/arm64/
 *
 *   ...and it could not be moved to the search path, because HotSpot derives
 *   java.home by stripping three components off libjvm.so's own path and then
 *   requiring "<java.home>/lib/<module image>" to exist:
 *
 *       <bundle>/libs/arm64/jdk21/lib/server/libjvm.so
 *                                ^^^^^^^ lib/server -> lib -> jdk21 = java.home
 *
 *   So the two requirements pull in opposite directions, and this tiny library
 *   is the compromise: it sits ON the search path so "libjvm.so" resolves, and
 *   it does nothing except exist. The symbols the other JDK libraries are
 *   actually after come from the REAL libjvm.so, which this app loads first
 *   with RTLD_GLOBAL so it is visible in the global symbol scope.
 *
 *   Nothing links against this object directly; the app always dlopen()s the
 *   real one by full path.
 *
 * ASCII ONLY -- clang decodes source as GBK on a Chinese Windows locale, and a
 * UTF-8 comment can then decode into a literal "*" "/" pair that ends the
 * comment early.
 */

/* one exported symbol so the file is a well-formed shared object with a
 * non-empty dynamic symbol table (the linker is happier, and it gives us
 * something to dlsym to prove which one got loaded) */
__attribute__((visibility("default")))
int libjvm_anchor_present(void)
{
    return 0x4a564d;   /* "JVM" */
}
