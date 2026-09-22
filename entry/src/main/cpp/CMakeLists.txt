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

# ---------------------------------------------------------------------------
# Keep the build machine's directory layout out of the shipped libraries.
#
# `__FILE__` (and the file-name argument of every assert macro) is recorded as
# the path the COMPILER was handed, so it lands in .rodata as an absolute path.
# Stripping does not remove it -- strip deletes .debug_* and .symtab, not
# loadable data -- which is why the release package carried it too.
#
# Measured before this was added, on the 0.3.0.1 build: 395 hits in four
# libraries, every one of them the developer's own machine --
#
#     libSDL3.so         372   <repo>/entry/src/main/cpp/SDL/...
#     libmain.so          10   <repo>/entry/src/main/cpp/launcher.c,
#                              <repo>/entry/.cxx/..., and the SDK sysroot
#     libarcarm64.so       7   <a Windows temp dir>/soloud-*
#     libcxxabi_shim.so    6   <a sibling project>/sdl-template/...
#
# (Written with placeholders on purpose. The literal paths are recorded in
# RELEASE-MAINTENANCE.md, which is where the checklist lives; putting drive
# letters here would trip this repository's own "no hard-coded absolute paths in
# text files" check, and a check that always reports FAIL is not a check.)
#
# What this covers: everything THIS file builds -- libmain.so and libSDL3.so,
# which together are 382 of those 395. It does not cover the other two, and they
# are not oversights:
#
#   libarcarm64.so     the command that compiles it is not in this repository.
#                      The .so is an intermediate built by hand in a temp tree
#                      (see scripts/build_variants.py, which consumes it through
#                      the AUDIO_SO override). Fixing it means first putting that
#                      build into the repository, which is a separate job.
#   libcxxabi_shim.so  built in a different project (sdl-template), and shipped
#                      byte-for-byte on purpose -- verify_hap.py checks its SHA-1
#                      against the original. Rewriting it to drop a path string
#                      would break that invariant to hide a path.
#
# The prefix is DERIVED, not written down: a literal SDK path here would be the
# very thing this is removing, and the repo forbids hard-coded absolute paths in
# text files for that reason.
# ---------------------------------------------------------------------------
# The REPOSITORY root, not this directory, and that is deliberate: one mapping
# then covers the sources AND every generated directory underneath it --
# entry/.cxx/... and entry/build/... both leaked their absolute paths too, and
# mapping only cpp/ left them behind (measured: 7 hits across libmain and
# libSDL3 for the build directories alone).
#
# Derived rather than written down. A literal path here would be the very thing
# this removes, and a hard-coded absolute path in a text file is something this
# repository checks for.
get_filename_component(_repo_root "${CMAKE_CURRENT_SOURCE_DIR}/../../.." ABSOLUTE)
file(TO_CMAKE_PATH "${_repo_root}" _repo_root)
add_compile_options("-ffile-prefix-map=${_repo_root}=.")

# Two more prefixes, and they were found by measuring rather than by reasoning:
# after the one above, 20 hits were left and every one of them was a path this
# file had not thought about.
#
#   <sdk>/default/hms/native/...   the COMPILER's own headers
#                                  (BiSheng/lib/clang/15.0.4/include). Note the
#                                  hms tree, not the openharmony one -- the
#                                  toolchain is BiSheng and the sysroot it is
#                                  pointed at is openharmony, so those are two
#                                  different roots and both need mapping.
#   <sdk>/default/openharmony/native/...   the sysroot the SDK headers come from
#
# ⚠️ Deriving the second from CMAKE_C_COMPILER does not work, and that is how
# this was got wrong the first time: the compiler lives under hms/native while
# the headers that leak are under openharmony/native, so the mapping matched
# nothing and 23 SDK paths stayed in the output. OHOS_SDK_NATIVE is the variable
# hvigor sets and the one the toolchain uses, so it names the right tree. Both
# arrive with BACKSLASHES and are normalised before use as textual prefixes.
if(DEFINED OHOS_SDK_NATIVE)
    file(TO_CMAKE_PATH "${OHOS_SDK_NATIVE}" _sdk_native)
    add_compile_options("-ffile-prefix-map=${_sdk_native}=<sdk>")
else()
    message(WARNING
        "OHOS_SDK_NATIVE is not set, so SDK paths will stay in __FILE__ strings "
        "and ship inside the native libraries. See docs/BUILDING.md.")
endif()

if(DEFINED HMOS_SDK_NATIVE)
    file(TO_CMAKE_PATH "${HMOS_SDK_NATIVE}" _hmos_native)
    add_compile_options("-ffile-prefix-map=${_hmos_native}=<sdk>")
endif()

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
# The two files that implemented it -- cxatls.c and scripts/make_cxxabi_real.py
# -- are NOT in this repository. They were removed once the approach was
# abandoned, so nothing here references them and a fresh clone does not carry
# them. If you are looking for the reasoning above and want the code as well, it
# is a small, self-contained pair: a TLS destructor list and an equal-length
# in-place .dynstr patch.
# ---------------------------------------------------------------------------


# libjvm.so (the anchor) and jdk21/lib/server/libjvm_real.so are produced by
# ../../../../../prep_vendor.py -- see that file for why they exist.

# This is libmain.so -- the library name must be "main"
add_library(main SHARED launcher.c)
# libhilog_ndk.z.so: the launcher mirrors its diagnostics there, because a
# RELEASE-signed build's sandbox log files cannot be read over hdc -- measured,
# "Permission denied", and with no faultlog entry either. Without this the store
# package is undiagnosable, which 2026-09-22 showed is exactly the package whose
# failures matter most.
target_link_libraries(main PUBLIC SDL3::SDL3 dl hilog_ndk.z)
