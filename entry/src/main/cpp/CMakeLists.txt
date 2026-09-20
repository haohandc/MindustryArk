# Mindustry launcher for HarmonyOS -- native build script
#
# Based on SDL's official openharmony-project template. Changes:
#   1. project(loopwave) -> project(mindustry_launcher)
#   2. include the jni/ dir (the NDK has no jni.h, so we carry our own)
#   3. link dl (we dlopen libjvm.so out of the bundled JDK)
#
# Two hard requirements from docs/README-harmonyos.md:
#   - the artifact MUST be a shared library named libmain.so (not an executable)
#   - SDL's source tree must be compiled into the project (add_subdirectory("SDL"))

cmake_minimum_required(VERSION 3.5.0)
project(mindustry_launcher)

set(NATIVEAPP_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

if(DEFINED PACKAGE_FIND_FILE)
    include(${PACKAGE_FIND_FILE})
endif()

# SDL source tree (copied into ./SDL)
add_subdirectory("SDL")

include_directories(${NATIVEAPP_ROOT_PATH}
                    ${NATIVEAPP_ROOT_PATH}/include
                    ${NATIVEAPP_ROOT_PATH}/jni
                    ${NATIVEAPP_ROOT_PATH}/SDL/include)

# ---------------------------------------------------------------------------
# A replacement libcxxabi_shim.so WAS built here. It is not any more, and the
# target has been deleted rather than left commented out -- a commented-out
# build rule is a claim about the build that is not true.
#
# WHAT IT WAS FOR
#   libjvm.so's DT_NEEDED is [libcxxabi_shim.so, libc.so]. The JDK's shim
#   provides 35 C++ ABI symbols but NOT __cxa_thread_atexit, which libjvm.so
#   declares as a strong undefined symbol (GLOBAL, not WEAK -- verified with
#   readelf --dyn-syms). Measured on device: OHOS's linker does not put
#   RTLD_GLOBAL libraries into the relocation scope of a newly dlopen'd library
#   (dlsym(RTLD_DEFAULT, ...) returned 0 right after we had dlopen'd an
#   exporter), so the symbol had to come from libjvm.so's own dependency list.
#   The replacement took the name libcxxabi_shim.so, exported
#   __cxa_thread_atexit, and depended on the original shim under a new name.
#
# WHY IT IS GONE
#   It did make libjvm.so loadable, so the reasoning held. What changed the
#   picture: another launcher for this platform, on the same device, loads the
#   SAME libjvm.so together with the UNMODIFIED shim from the JDK and works. A
#   working configuration therefore does not need our implementation -- and a
#   hand-written TLS destructor list sitting on the JVM's dependency chain is a
#   plausible source of exactly the kind of memory corruption being chased.
#
# SO WHAT SHIPS INSTEAD
#   The JDK's own shim, byte-for-byte, as entry/libs/arm64-v8a/libcxxabi_shim.so.
#   verify_hap.py checks that file's SHA-1 against the original, which is how
#   "we ship the unmodified one" is enforced rather than remembered.
#
# cxatls.c, the hand-written implementation, is still in this directory. It is
# not compiled. It is kept because it is the readable record of why
# __cxa_thread_atexit was a problem at all; delete it if that stops being worth
# anything.
# ---------------------------------------------------------------------------


# libjvm.so (the anchor) and jdk21/lib/server/libjvm_real.so are produced by
# ../../../../../prep_vendor.py -- see that file for why they exist.

# This is libmain.so -- the library name must be "main"
add_library(main SHARED myapp.c)
target_link_libraries(main PUBLIC SDL3::SDL3 dl)
