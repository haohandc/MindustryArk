// 由 gen_jni.py 从 Buffers.java 生成 —— 请勿手工编辑。
// jnigen 的等价物：全局 JNI 块 + 每个 native 方法一个标准 JNI 导出函数。

#include <jni.h>

	#include <stdio.h>
	#include <stdlib.h>
	#include <string.h>


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

struct ArcJniReleaseByteArray{
    JNIEnv* env; jbyteArray ref; jbyte* ptr;
    ArcJniReleaseByteArray(JNIEnv* e, jbyteArray r, jbyte* p) : env(e), ref(r), ptr(p){}
    // JNI_ABORT: 这里只读不写回
    ~ArcJniReleaseByteArray(){ if(ptr != 0) env->ReleaseByteArrayElements(ref, ptr, JNI_ABORT); }
    ArcJniReleaseByteArray(const ArcJniReleaseByteArray&) = delete;
    ArcJniReleaseByteArray& operator=(const ArcJniReleaseByteArray&) = delete;
};

struct ArcJniReleaseFloatArray{
    JNIEnv* env; jfloatArray ref; jfloat* ptr;
    ArcJniReleaseFloatArray(JNIEnv* e, jfloatArray r, jfloat* p) : env(e), ref(r), ptr(p){}
    // JNI_ABORT: 这里只读不写回
    ~ArcJniReleaseFloatArray(){ if(ptr != 0) env->ReleaseFloatArrayElements(ref, ptr, JNI_ABORT); }
    ArcJniReleaseFloatArray(const ArcJniReleaseFloatArray&) = delete;
    ArcJniReleaseFloatArray& operator=(const ArcJniReleaseFloatArray&) = delete;
};

struct ArcJniReleaseIntArray{
    JNIEnv* env; jintArray ref; jint* ptr;
    ArcJniReleaseIntArray(JNIEnv* e, jintArray r, jint* p) : env(e), ref(r), ptr(p){}
    // JNI_ABORT: 这里只读不写回
    ~ArcJniReleaseIntArray(){ if(ptr != 0) env->ReleaseIntArrayElements(ref, ptr, JNI_ABORT); }
    ArcJniReleaseIntArray(const ArcJniReleaseIntArray&) = delete;
    ArcJniReleaseIntArray& operator=(const ArcJniReleaseIntArray&) = delete;
};

struct ArcJniReleaseShortArray{
    JNIEnv* env; jshortArray ref; jshort* ptr;
    ArcJniReleaseShortArray(JNIEnv* e, jshortArray r, jshort* p) : env(e), ref(r), ptr(p){}
    // JNI_ABORT: 这里只读不写回
    ~ArcJniReleaseShortArray(){ if(ptr != 0) env->ReleaseShortArrayElements(ref, ptr, JNI_ABORT); }
    ArcJniReleaseShortArray(const ArcJniReleaseShortArray&) = delete;
    ArcJniReleaseShortArray& operator=(const ArcJniReleaseShortArray&) = delete;
};
} // namespace

extern "C" {

JNIEXPORT void JNICALL Java_arc_util_Buffers_freeMemory(JNIEnv* env, jclass clazz, jobject buffer_jni_){
    char* buffer = (char*)env->GetDirectBufferAddress(buffer_jni_);
    free(buffer);
}

JNIEXPORT jobject JNICALL Java_arc_util_Buffers_newDisposableByteBuffer(JNIEnv* env, jclass clazz, jint numBytes){
    return env->NewDirectByteBuffer((char*)malloc(numBytes), numBytes);
}

JNIEXPORT jlong JNICALL Java_arc_util_Buffers_getBufferAddress(JNIEnv* env, jclass clazz, jobject buffer_jni_){
    char* buffer = (char*)env->GetDirectBufferAddress(buffer_jni_);
    return (jlong) buffer;
}

JNIEXPORT void JNICALL Java_arc_util_Buffers_clear(JNIEnv* env, jclass clazz, jobject buffer_jni_, jint numBytes){
    char* buffer = (char*)env->GetDirectBufferAddress(buffer_jni_);
    memset(buffer, 0, numBytes);
}

JNIEXPORT void JNICALL Java_arc_util_Buffers_copyJni___3FLjava_nio_Buffer_2II(JNIEnv* env, jclass clazz, jfloatArray src_jni_, jobject dst_jni_, jint numFloats, jint offset){
    jfloat* src = env->GetFloatArrayElements(src_jni_, 0);
    ArcJniReleaseFloatArray _rela_src(env, src_jni_, src);
    char* dst = (char*)env->GetDirectBufferAddress(dst_jni_);
    memcpy(dst, src + offset, numFloats << 2 );
}

JNIEXPORT void JNICALL Java_arc_util_Buffers_copyJni___3BILjava_nio_Buffer_2II(JNIEnv* env, jclass clazz, jbyteArray src_jni_, jint srcOffset, jobject dst_jni_, jint dstOffset, jint numBytes){
    jbyte* src = env->GetByteArrayElements(src_jni_, 0);
    ArcJniReleaseByteArray _rela_src(env, src_jni_, src);
    char* dst = (char*)env->GetDirectBufferAddress(dst_jni_);
    memcpy(dst + dstOffset, src + srcOffset, numBytes);
}

JNIEXPORT void JNICALL Java_arc_util_Buffers_copyJni___3SILjava_nio_Buffer_2II(JNIEnv* env, jclass clazz, jshortArray src_jni_, jint srcOffset, jobject dst_jni_, jint dstOffset, jint numBytes){
    jshort* src = env->GetShortArrayElements(src_jni_, 0);
    ArcJniReleaseShortArray _rela_src(env, src_jni_, src);
    char* dst = (char*)env->GetDirectBufferAddress(dst_jni_);
    memcpy(dst + dstOffset, src + srcOffset, numBytes);
}

JNIEXPORT void JNICALL Java_arc_util_Buffers_copyJni___3IILjava_nio_Buffer_2II(JNIEnv* env, jclass clazz, jintArray src_jni_, jint srcOffset, jobject dst_jni_, jint dstOffset, jint numBytes){
    jint* src = env->GetIntArrayElements(src_jni_, 0);
    ArcJniReleaseIntArray _rela_src(env, src_jni_, src);
    char* dst = (char*)env->GetDirectBufferAddress(dst_jni_);
    memcpy(dst + dstOffset, src + srcOffset, numBytes);
}

JNIEXPORT void JNICALL Java_arc_util_Buffers_copyJni___3FILjava_nio_Buffer_2II(JNIEnv* env, jclass clazz, jfloatArray src_jni_, jint srcOffset, jobject dst_jni_, jint dstOffset, jint numBytes){
    jfloat* src = env->GetFloatArrayElements(src_jni_, 0);
    ArcJniReleaseFloatArray _rela_src(env, src_jni_, src);
    char* dst = (char*)env->GetDirectBufferAddress(dst_jni_);
    memcpy(dst + dstOffset, src + srcOffset, numBytes);
}

JNIEXPORT void JNICALL Java_arc_util_Buffers_copyJni__Ljava_nio_Buffer_2ILjava_nio_Buffer_2II(JNIEnv* env, jclass clazz, jobject src_jni_, jint srcOffset, jobject dst_jni_, jint dstOffset, jint numBytes){
    char* src = (char*)env->GetDirectBufferAddress(src_jni_);
    char* dst = (char*)env->GetDirectBufferAddress(dst_jni_);
    memcpy(dst + dstOffset, src + srcOffset, numBytes);
}

} // extern "C"
