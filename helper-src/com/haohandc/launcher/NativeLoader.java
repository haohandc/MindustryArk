package com.haohandc.launcher;

/**
 * Loading a library on the launcher's behalf, from a class the application class
 * loader owns.
 *
 * WHY THIS CLASS EXISTS
 *
 * Runtime.load0() picks the loader that a native library is registered against
 * like this:
 *
 *     ClassLoader loader = (fromClass == null) ? null : fromClass.getClassLoader();
 *     NativeLibraries libs = libsFor(loader);
 *
 * and System.load() obtains fromClass from the caller frame, because it is
 * annotated @CallerSensitive.
 *
 * The launcher calls it through JNI, and a JNI call has no Java caller frame. So
 * fromClass comes out null, the library is registered against the BOOTSTRAP
 * loader (null), and every class loaded by the application loader then fails to
 * find its native methods -- even though the library loaded without error:
 *
 *     java.lang.UnsatisfiedLinkError:
 *         'int arc.util.NativeUtils.setEnv(java.lang.String, java.lang.String, boolean)'
 *         at arc.util.NativeUtils.setEnv(Native Method)
 *         at arc.backend.sdl.SdlApplication.init(SdlApplication.java:125)
 *
 * Both halves of that message are true and they look contradictory until the
 * loader is taken into account: the library IS loaded, just not for the classes
 * that need it.
 *
 * Calling System.load from here fixes it, because this class is loaded by the
 * same application class loader as the game, so the library lands in the same
 * place and the symbols resolve.
 *
 * Kept in its own jar rather than injected into the game jar, so that the game
 * jar stays the exact artifact it was verified as.
 */
public final class NativeLoader {

    private NativeLoader() {
    }

    /** System.load with this class as the caller, so the loader is the right one. */
    public static void load(String absolutePath) {
        System.load(absolutePath);
    }

    /**
     * Tell Arc a native is already loaded, so its own loader does not try.
     *
     * SharedLibraryLoader.setLoaded is public and static, and load(String)
     * returns immediately for a name that has been marked. Reached reflectively
     * because this jar deliberately has no compile-time dependency on the game.
     */
    public static void markLoaded(String name) throws Exception {
        Class.forName("arc.util.SharedLibraryLoader")
             .getMethod("setLoaded", String.class)
             .invoke(null, name);
    }
}
