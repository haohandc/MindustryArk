# Mindustry launcher for HarmonyOS -- native build script
#
# Based on SDL's official openharmony-project template. Changes:
#   1. project(loopwave) -> project(mindustry_launcher)
#   2. include the jni/ dir (the NDK has no jni.h, so we carry our own)
#   3. link dl (we dlopen libjvm.so out of the bundled JDK)
#   4. build a replacement libcxxabi_shim.so (see cxatls.c / make_cxxabi_real.py)
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
# Replacement libcxxabi_shim.so
#
# libjvm.so's DT_NEEDED is [libcxxabi_shim.so, libc.so]. The JDK's shim provides
# 35 C++ ABI symbols but NOT __cxa_thread_atexit, which libjvm.so also needs.
# Measured on device: OHOS's linker does not put RTLD_GLOBAL libraries into the
# relocation scope of a newly dlopen'd library (dlsym(RTLD_DEFAULT, ...) returned
# 0 right after we had dlopen'd an exporter). So the symbol must come from
# libjvm.so's own dependency list.
#
# Hence: we produce a library that takes the NAME libcxxabi_shim.so, exports
# __cxa_thread_atexit (cxatls.c), and depends on libcxxabi_real.so -- the
# original shim, renamed by make_cxxabi_real.py -- so the other 35 symbols
# still resolve through the dependency chain.
#
# Run `python make_cxxabi_real.py` once (it creates libcxxabi_real.so and
# removes the original name from entry/libs/).
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# DISABLED 2026-09-19: the C++ shim replacement is no longer built.
#
# It existed to supply __cxa_thread_atexit, which libjvm.so declares as a strong
# undefined symbol (GLOBAL, not WEAK -- verified with readelf --dyn-syms) and
# which neither the JDK's own shim nor OHOS libc exports. So the reasoning was
# sound, and the replacement did make libjvm.so loadable.
#
# What changed the picture: another launcher for this platform, running on the
# same device, loads the SAME libjvm.so together with the UNMODIFIED shim from
# the JDK and works. So a working configuration does not need our hand-written
# implementation, and a hand-written TLS destructor list sitting on the JVM's
# dependency chain is a plausible source of exactly the kind of memory
# corruption we are chasing.
#
# So: ship the JDK's own shim (copied into entry/libs/arm64-v8a/) and drop this
# target entirely. If libjvm.so turns out to genuinely require the symbol at
# load time, the load will fail loudly and this file can be restored.
#
# To restore: re-create libcxxabi_real.so with `python make_cxxabi_real.py`,
# put it back under entry/libs/arm64-v8a/, and un-comment the block below.
# ---------------------------------------------------------------------------
# set(CXXABI_REAL ${NATIVEAPP_ROOT_PATH}/libcxxabi_real.so)
# if(EXISTS ${CXXABI_REAL})
#     add_library(cxxshim SHARED cxatls.c)
#     set_target_properties(cxxshim PROPERTIES OUTPUT_NAME cxxabi_shim)
#     target_link_options(cxxshim PRIVATE
#         "-Wl,--no-as-needed" ${CXXABI_REAL} "-Wl,--as-needed")
# endif()


# libjvm.so (the anchor) and jdk21/lib/server/libjvm_real.so are produced by
# ../../../../../prep_vendor.py -- see that file for why they exist.

# This is libmain.so -- the library name must be "main"
add_library(main SHARED myapp.c)
target_link_libraries(main PUBLIC SDL3::SDL3 dl)
