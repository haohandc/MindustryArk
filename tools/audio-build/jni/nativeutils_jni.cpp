// 由 gen_jni.py 从 NativeUtils.java 生成 —— 请勿手工编辑。
// jnigen 的等价物：全局 JNI 块 + 每个 native 方法一个标准 JNI 导出函数。

#include <jni.h>

#include <stdlib.h>


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

JNIEXPORT jint JNICALL Java_arc_util_NativeUtils_setEnv(JNIEnv* env, jclass clazz, jstring name_jni_, jstring value_jni_, jboolean overwrite){
    const char* name = env->GetStringUTFChars(name_jni_, 0);
    ArcJniRelease _rel_name(env, name_jni_, name);
    const char* value = env->GetStringUTFChars(value_jni_, 0);
    ArcJniRelease _rel_value(env, value_jni_, value);
    #if defined(__linux__) && !defined(__ANDROID__)
                return setenv(name, value, overwrite ? 1 : 0);
            #else
                return -1;
            #endif
}

JNIEXPORT jint JNICALL Java_arc_util_NativeUtils_unsetEnv(JNIEnv* env, jclass clazz, jstring name_jni_){
    const char* name = env->GetStringUTFChars(name_jni_, 0);
    ArcJniRelease _rel_name(env, name_jni_, name);
    #if defined(__linux__) && !defined(__ANDROID__)
                return unsetenv(name);
            #else
                return -1;
            #endif
}

JNIEXPORT jstring JNICALL Java_arc_util_NativeUtils_getEnv(JNIEnv* env, jclass clazz, jstring name_jni_){
    const char* name = env->GetStringUTFChars(name_jni_, 0);
    ArcJniRelease _rel_name(env, name_jni_, name);
    #if defined(__linux__) && !defined(__ANDROID__)
                char* val = getenv(name);
                if(val == NULL){
                    return env->NewStringUTF("");
                }
                return env->NewStringUTF(val);
            #else
                return env->NewStringUTF("");
            #endif
}

} // extern "C"
