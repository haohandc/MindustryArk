/*
 * libjvmfix.so -- supplies __cxa_thread_atexit for the bundled JDK's libjvm.so.
 *
 * WHY THIS EXISTS
 *   libjvm.so (from the ad-hoc aarch64/musl OpenJDK build) has an undefined
 *   symbol __cxa_thread_atexit. Measured facts:
 *
 *     - OHOS's libc.so does NOT export it (checked with llvm-readelf against
 *       the NDK sysroot's libc.so).
 *     - The JDK's own libcxxabi_shim.so does NOT export it either; that library
 *       only carries the __cxa_* exception-handling bits (__cxa_throw,
 *       __cxa_guard_acquire, __gxx_personality_v0, ...).
 *     - libc++_shared.so DOES export it. That library is already in the process
 *       (libSDL3.so depends on it), but it was loaded as an implicit dependency
 *       and our explicit dlopen(..., RTLD_GLOBAL) did NOT promote it into the
 *       global symbol scope -- libjvm.so still failed to relocate.
 *
 *   So we ship a tiny library that is definitely not loaded yet, load it with
 *   RTLD_GLOBAL before libjvm.so, and let the linker resolve the symbol here.
 *   It lives in the HAP's native-lib area because only that area is executable
 *   (the app's writable sandbox is not -- see the W^X note in myapp.c).
 *
 * WHAT IT DOES
 *   __cxa_thread_atexit registers a destructor to run when the *current thread*
 *   exits, for thread_local objects with non-trivial destructors. We keep a
 *   per-thread singly linked list, torn down from a pthread_key destructor.
 *
 * ASCII ONLY -- clang decodes source as GBK on a Chinese Windows locale, and a
 * UTF-8 comment can then accidentally produce a literal "*" "/" sequence that
 * ends the comment early.
 */
#include <pthread.h>
#include <stdlib.h>

struct tls_dtor {
    void (*func)(void *);
    void *arg;
    void *dso;
    struct tls_dtor *next;
};

static pthread_key_t g_key;
static pthread_once_t g_once = PTHREAD_ONCE_INIT;

static void run_dtors(void *p)
{
    struct tls_dtor *d = (struct tls_dtor *)p;
    while (d) {
        struct tls_dtor *next = d->next;
        d->func(d->arg);
        free(d);
        d = next;
    }
}

static void make_key(void)
{
    (void)pthread_key_create(&g_key, run_dtors);
}

/*
 * Returns 0 on success, non-zero on failure -- same contract as the real
 * __cxa_thread_atexit in libc++abi.
 */
int __cxa_thread_atexit(void (*func)(void *), void *arg, void *dso_handle)
{
    if (!func) return -1;

    (void)pthread_once(&g_once, make_key);

    struct tls_dtor *d = (struct tls_dtor *)malloc(sizeof(*d));
    if (!d) return -1;

    d->func = func;
    d->arg = arg;
    d->dso = dso_handle;
    d->next = (struct tls_dtor *)pthread_getspecific(g_key);

    if (pthread_setspecific(g_key, d) != 0) {
        free(d);
        return -1;
    }
    return 0;
}
