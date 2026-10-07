/* Minimal Linux/OHOS flavour of jni_md.h.
 * The JDK ships only the win32 variant here, but jni.h itself is platform independent;
 * only these few typedefs/attributes differ. Verified against the JDK's linux/include/jni_md.h. */
#ifndef _JAVASOFT_JNI_MD_H_
#define _JAVASOFT_JNI_MD_H_

#define JNIEXPORT __attribute__((visibility("default")))
#define JNIIMPORT __attribute__((visibility("default")))
#define JNICALL

typedef int jint;
#ifdef _LP64
typedef long jlong;
#else
typedef long long jlong;
#endif

typedef signed char jbyte;

#endif
