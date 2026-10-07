// 由 gen_jni.py 从 Pixmap.java 生成 —— 请勿手工编辑。
// jnigen 的等价物：全局 JNI 块 + 每个 native 方法一个标准 JNI 导出函数。

#include <jni.h>

#include <stdlib.h>
#include <stdint.h>

#include <stdlib.h>
#define STB_IMAGE_IMPLEMENTATION
#define STBI_FAILURE_USERMSG
#define STBI_NO_STDIO
#ifdef __APPLE__
#define STBI_NO_THREAD_LOCALS
#endif
#include "stb_image.h"


namespace {
// String / byte[] 等参数用完要释放。jnigen 是在实现体之后显式插 Release 调用，
// 这里用 RAII 达到同样效果 —— 好处是不必改写实现体里的 return（实现体里可能有多个 return）。
struct ArcJniRelease{
    JNIEnv* env; jstring ref; const char* ptr;
    ArcJniRelease(JNIEnv* e, jstring r, const char* p) : env(e), ref(r), ptr(p){}
    ~ArcJniRelease(){ if(ptr != 0) env->ReleaseStringUTFChars(ref, ptr); }
    ArcJniRelease(const ArcJniRelease&) = delete;
    ArcJniRelease& operator=(const ArcJniRelease&) = delete;
};
} // namespace

extern "C" {

JNIEXPORT jobject JNICALL Java_arc_graphics_Pixmap_loadJni(JNIEnv* env, jclass clazz, jlongArray nativeData, jbyteArray buffer, jint offset, jint len){

            const unsigned char* p_buffer = (const unsigned char*)env->GetPrimitiveArrayCritical(buffer, 0);

            int32_t width, height, format;

            //always use STBI_rgb_alpha (4) as the format, since that's the only thing pixmaps support
            //RGB images are generally uncommon and the memory savings don't really matter; formats have to be converted to RGBA for drawing anyway
            const unsigned char* pixels = stbi_load_from_memory(p_buffer + offset, len, &width, &height, &format, STBI_rgb_alpha);

            env->ReleasePrimitiveArrayCritical(buffer, (char*)p_buffer, 0);

            if(pixels == NULL) return NULL;

            jobject pixel_buffer = env->NewDirectByteBuffer((void*)pixels, width * height * 4);
            jlong* p_native_data = (jlong*)env->GetPrimitiveArrayCritical(nativeData, 0);
            p_native_data[0] = (jlong)pixels;
            p_native_data[1] = width;
            p_native_data[2] = height;
            env->ReleasePrimitiveArrayCritical(nativeData, p_native_data, 0);

            return pixel_buffer;
}

JNIEXPORT jobject JNICALL Java_arc_graphics_Pixmap_createJni(JNIEnv* env, jclass clazz, jlongArray nativeData, jint width, jint height){

            const unsigned char* pixels = (unsigned char*)malloc(width * height * 4);

            if(!pixels) return 0;

            //fill pixel array with 0s
            //TODO use calloc insted?
            memset((void*)pixels, 0, width * height * 4);

            jobject pixel_buffer = env->NewDirectByteBuffer((void*)pixels, width * height * 4);
            jlong* p_native_data = (jlong*)env->GetPrimitiveArrayCritical(nativeData, 0);
            p_native_data[0] = (jlong)pixels;
            p_native_data[1] = width;
            p_native_data[2] = height;
            env->ReleasePrimitiveArrayCritical(nativeData, p_native_data, 0);

            return pixel_buffer;
}

JNIEXPORT void JNICALL Java_arc_graphics_Pixmap_free(JNIEnv* env, jclass clazz, jlong buffer){
    free((void*)buffer);
}

JNIEXPORT jstring JNICALL Java_arc_graphics_Pixmap_getFailureReason(JNIEnv* env, jclass clazz){
    return env->NewStringUTF(stbi_failure_reason());
}

} // extern "C"
