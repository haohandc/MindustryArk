// 由 gen_jni.py 从 arc/audio/Soloud.java 生成 —— 请勿手工编辑。
// jnigen 的等价物：全局 JNI 块 + 每个 native 方法一个标准 JNI 导出函数。

#include <jni.h>

#include "soloud.h"
#include "soloud_file.h"
#include "soloud_wav.h"
#include "soloud_wavstream.h"
#include "soloud_bus.h"
#include "soloud_thread.h"
#include "soloud_filter.h"
#include "soloud_biquadresonantfilter.h"
#include "soloud_echofilter.h"
#include "soloud_lofifilter.h"
#include "soloud_flangerfilter.h"
#include "soloud_waveshaperfilter.h"
#include "soloud_bassboostfilter.h"
#include "soloud_robotizefilter.h"
#include "soloud_freeverbfilter.h"
#include <stdio.h>

using namespace SoLoud;

Soloud soloud;

void throwError(JNIEnv* env, int result){
    jclass excClass = env->FindClass("arc/util/ArcRuntimeException");
    env->ThrowNew(excClass, soloud.getErrorString(result));
}


namespace {
struct ArcJniRelease{
    JNIEnv* env; jstring ref; const char* ptr;
    ArcJniRelease(JNIEnv* e, jstring r, const char* p) : env(e), ref(r), ptr(p){}
    ~ArcJniRelease(){ if(ptr != 0) env->ReleaseStringUTFChars(ref, ptr); }
    ArcJniRelease(const ArcJniRelease&) = delete;
    ArcJniRelease& operator=(const ArcJniRelease&) = delete;
};

struct ArcJniReleaseArray{
    JNIEnv* env; jbyteArray ref; jbyte* ptr;
    ArcJniReleaseArray(JNIEnv* e, jbyteArray r, jbyte* p) : env(e), ref(r), ptr(p){}
    // JNI_ABORT: the buffer is only read, so there is nothing to copy back
    ~ArcJniReleaseArray(){ if(ptr != 0) env->ReleaseByteArrayElements(ref, ptr, JNI_ABORT); }
    ArcJniReleaseArray(const ArcJniReleaseArray&) = delete;
    ArcJniReleaseArray& operator=(const ArcJniReleaseArray&) = delete;
};
} // namespace

extern "C" {

JNIEXPORT void JNICALL Java_arc_audio_Soloud_init(JNIEnv* env, jclass clazz){
    int result = soloud.init();

            if(result != 0) throwError(env, result);
}

JNIEXPORT void JNICALL Java_arc_audio_Soloud_deinit(JNIEnv* env, jclass clazz){
    soloud.deinit();
}

JNIEXPORT jstring JNICALL Java_arc_audio_Soloud_backendString(JNIEnv* env, jclass clazz){
    return env->NewStringUTF(soloud.getBackendString());
}

JNIEXPORT jint JNICALL Java_arc_audio_Soloud_backendId(JNIEnv* env, jclass clazz){
    return soloud.getBackendId();
}

JNIEXPORT jint JNICALL Java_arc_audio_Soloud_backendChannels(JNIEnv* env, jclass clazz){
    return soloud.getBackendChannels();
}

JNIEXPORT jint JNICALL Java_arc_audio_Soloud_backendSamplerate(JNIEnv* env, jclass clazz){
    return soloud.getBackendSamplerate();
}

JNIEXPORT jint JNICALL Java_arc_audio_Soloud_backendBufferSize(JNIEnv* env, jclass clazz){
    return soloud.getBackendBufferSize();
}

JNIEXPORT jint JNICALL Java_arc_audio_Soloud_version(JNIEnv* env, jclass clazz){
    return soloud.getVersion();
}

JNIEXPORT jint JNICALL Java_arc_audio_Soloud_activeVoiceCount(JNIEnv* env, jclass clazz){
    return soloud.getActiveVoiceCount();
}

JNIEXPORT void JNICALL Java_arc_audio_Soloud_stopAll(JNIEnv* env, jclass clazz){
    soloud.stopAll();
}

JNIEXPORT void JNICALL Java_arc_audio_Soloud_pauseAll(JNIEnv* env, jclass clazz, jboolean paused){
    soloud.setPauseAll(paused);
}

JNIEXPORT void JNICALL Java_arc_audio_Soloud_biquadSet(JNIEnv* env, jclass clazz, jlong handle, jint type, jfloat frequency, jfloat resonance){
    ((BiquadResonantFilter*)handle)->setParams(type, frequency, resonance);
}

JNIEXPORT void JNICALL Java_arc_audio_Soloud_echoSet(JNIEnv* env, jclass clazz, jlong handle, jfloat delay, jfloat decay, jfloat filter){
    ((EchoFilter*)handle)->setParams(delay, decay, filter);
}

JNIEXPORT void JNICALL Java_arc_audio_Soloud_lofiSet(JNIEnv* env, jclass clazz, jlong handle, jfloat sampleRate, jfloat bitDepth){
    ((LofiFilter*)handle)->setParams(sampleRate, bitDepth);
}

JNIEXPORT void JNICALL Java_arc_audio_Soloud_flangerSet(JNIEnv* env, jclass clazz, jlong handle, jfloat delay, jfloat frequency){
    ((FlangerFilter*)handle)->setParams(delay, frequency);
}

JNIEXPORT void JNICALL Java_arc_audio_Soloud_waveShaperSet(JNIEnv* env, jclass clazz, jlong handle, jfloat amount){
    ((WaveShaperFilter*)handle)->setParams(amount);
}

JNIEXPORT void JNICALL Java_arc_audio_Soloud_bassBoostSet(JNIEnv* env, jclass clazz, jlong handle, jfloat amount){
    ((BassboostFilter*)handle)->setParams( amount);
}

JNIEXPORT void JNICALL Java_arc_audio_Soloud_robotizeSet(JNIEnv* env, jclass clazz, jlong handle, jfloat freq, jint waveform){
    ((RobotizeFilter*)handle)->setParams(freq, waveform);
}

JNIEXPORT void JNICALL Java_arc_audio_Soloud_freeverbSet(JNIEnv* env, jclass clazz, jlong handle, jfloat mode, jfloat roomSize, jfloat damp, jfloat width){
    ((FreeverbFilter*)handle)->setParams(mode, roomSize, damp, width);
}

JNIEXPORT jlong JNICALL Java_arc_audio_Soloud_filterBiquad(JNIEnv* env, jclass clazz){
    return (jlong)(new BiquadResonantFilter());
}

JNIEXPORT jlong JNICALL Java_arc_audio_Soloud_filterEcho(JNIEnv* env, jclass clazz){
    return (jlong)(new EchoFilter());
}

JNIEXPORT jlong JNICALL Java_arc_audio_Soloud_filterLofi(JNIEnv* env, jclass clazz){
    return (jlong)(new LofiFilter());
}

JNIEXPORT jlong JNICALL Java_arc_audio_Soloud_filterFlanger(JNIEnv* env, jclass clazz){
    return (jlong)(new FlangerFilter());
}

JNIEXPORT jlong JNICALL Java_arc_audio_Soloud_filterBassBoost(JNIEnv* env, jclass clazz){
    return (jlong)(new BassboostFilter());
}

JNIEXPORT jlong JNICALL Java_arc_audio_Soloud_filterWaveShaper(JNIEnv* env, jclass clazz){
    return (jlong)(new WaveShaperFilter());
}

JNIEXPORT jlong JNICALL Java_arc_audio_Soloud_filterRobotize(JNIEnv* env, jclass clazz){
    return (jlong)(new RobotizeFilter());
}

JNIEXPORT jlong JNICALL Java_arc_audio_Soloud_filterFreeverb(JNIEnv* env, jclass clazz){
    return (jlong)(new FreeverbFilter());
}

JNIEXPORT void JNICALL Java_arc_audio_Soloud_setGlobalFilter(JNIEnv* env, jclass clazz, jint index, jlong handle){
    soloud.setGlobalFilter(index, ((Filter*)handle));
}

JNIEXPORT void JNICALL Java_arc_audio_Soloud_filterFade(JNIEnv* env, jclass clazz, jint voice, jint filter, jint attribute, jfloat value, jfloat timeSec){
    soloud.fadeFilterParameter(voice, filter, attribute, value, timeSec);
}

JNIEXPORT void JNICALL Java_arc_audio_Soloud_filterSet(JNIEnv* env, jclass clazz, jint voice, jint filter, jint attribute, jfloat value){
    soloud.setFilterParameter(voice, filter, attribute, value);
}

JNIEXPORT jlong JNICALL Java_arc_audio_Soloud_busNew(JNIEnv* env, jclass clazz){
    return (jlong)(new Bus());
}

JNIEXPORT void JNICALL Java_arc_audio_Soloud_idSeek(JNIEnv* env, jclass clazz, jint id, jfloat seconds){
    soloud.seek(id, seconds);
}

JNIEXPORT void JNICALL Java_arc_audio_Soloud_idVolume(JNIEnv* env, jclass clazz, jint id, jfloat volume){
    soloud.setVolume(id, volume);
}

JNIEXPORT jfloat JNICALL Java_arc_audio_Soloud_idGetVolume(JNIEnv* env, jclass clazz, jint id){
    return soloud.getVolume(id);
}

JNIEXPORT void JNICALL Java_arc_audio_Soloud_idPan(JNIEnv* env, jclass clazz, jint id, jfloat pan){
    soloud.setPan(id, pan);
}

JNIEXPORT void JNICALL Java_arc_audio_Soloud_idPitch(JNIEnv* env, jclass clazz, jint id, jfloat pitch){
    soloud.setRelativePlaySpeed(id, pitch);
}

JNIEXPORT void JNICALL Java_arc_audio_Soloud_idPause(JNIEnv* env, jclass clazz, jint id, jboolean pause){
    soloud.setPause(id, pause);
}

JNIEXPORT jboolean JNICALL Java_arc_audio_Soloud_idGetPause(JNIEnv* env, jclass clazz, jint voice){
    return soloud.getPause(voice);
}

JNIEXPORT void JNICALL Java_arc_audio_Soloud_idProtected(JNIEnv* env, jclass clazz, jint id, jboolean protect){
    soloud.setProtectVoice(id, protect);
}

JNIEXPORT void JNICALL Java_arc_audio_Soloud_idStop(JNIEnv* env, jclass clazz, jint voice){
    soloud.stop(voice);
}

JNIEXPORT void JNICALL Java_arc_audio_Soloud_idLooping(JNIEnv* env, jclass clazz, jint voice, jboolean looping){
    soloud.setLooping(voice, looping);
}

JNIEXPORT jboolean JNICALL Java_arc_audio_Soloud_idGetLooping(JNIEnv* env, jclass clazz, jint voice){
    return soloud.getLooping(voice);
}

JNIEXPORT jfloat JNICALL Java_arc_audio_Soloud_idPosition(JNIEnv* env, jclass clazz, jint voice){
    return (jfloat)soloud.getStreamPosition(voice);
}

JNIEXPORT jboolean JNICALL Java_arc_audio_Soloud_idValid(JNIEnv* env, jclass clazz, jint voice){
    return soloud.isValidVoiceHandle(voice);
}

JNIEXPORT jlong JNICALL Java_arc_audio_Soloud_wavLoadBytes(JNIEnv* env, jclass clazz, jbyteArray bytes_jni_, jint length){
    jbyte* bytes = env->GetByteArrayElements(bytes_jni_, 0);
    ArcJniReleaseArray _rela_bytes(env, bytes_jni_, bytes);
    Wav* wav = new Wav();

            int result = wav->loadMem((unsigned char*)bytes, length, true, true);

            if(result != 0) throwError(env, result);

            return (jlong)wav;
}

JNIEXPORT jlong JNICALL Java_arc_audio_Soloud_wavLoadFile(JNIEnv* env, jclass clazz, jstring path_jni_){
    const char* path = env->GetStringUTFChars(path_jni_, 0);
    ArcJniRelease _rel_path(env, path_jni_, path);
    Wav* wav = new Wav();

            int result = wav->load(path);

            if(result != 0) throwError(env, result);

            return (jlong)wav;
}

JNIEXPORT jlong JNICALL Java_arc_audio_Soloud_streamLoadBytes(JNIEnv* env, jclass clazz, jbyteArray bytes_jni_, jint length){
    jbyte* bytes = env->GetByteArrayElements(bytes_jni_, 0);
    ArcJniReleaseArray _rela_bytes(env, bytes_jni_, bytes);
    WavStream* stream = new WavStream();

            int result = stream->loadMem((unsigned char*)bytes, length, true, true);

            if(result != 0) throwError(env, result);

            return (jlong)stream;
}

JNIEXPORT jlong JNICALL Java_arc_audio_Soloud_streamLoadFile(JNIEnv* env, jclass clazz, jstring path_jni_){
    const char* path = env->GetStringUTFChars(path_jni_, 0);
    ArcJniRelease _rel_path(env, path_jni_, path);
    WavStream* stream = new WavStream();

            int result = stream->load(path);

            if(result != 0) throwError(env, result);

            return (jlong)stream;
}

JNIEXPORT jdouble JNICALL Java_arc_audio_Soloud_streamLength(JNIEnv* env, jclass clazz, jlong handle){
    WavStream* source = (WavStream*)handle;
            return (jdouble)source->getLength();
}

JNIEXPORT jdouble JNICALL Java_arc_audio_Soloud_wavLength(JNIEnv* env, jclass clazz, jlong handle){
    Wav* source = (Wav*)handle;
             return (jdouble)source->getLength();
}

JNIEXPORT void JNICALL Java_arc_audio_Soloud_sourceDestroy(JNIEnv* env, jclass clazz, jlong handle){
    AudioSource* source = (AudioSource*)handle;
            delete source;
}

JNIEXPORT void JNICALL Java_arc_audio_Soloud_sourceInaudible(JNIEnv* env, jclass clazz, jlong handle, jboolean tick, jboolean play){
    AudioSource* wav = (AudioSource*)handle;
            wav->setInaudibleBehavior(tick, play);
}

JNIEXPORT jint JNICALL Java_arc_audio_Soloud_sourcePlay__J(JNIEnv* env, jclass clazz, jlong handle){
    AudioSource* wav = (AudioSource*)handle;
            return soloud.play(*wav);
}

JNIEXPORT jint JNICALL Java_arc_audio_Soloud_sourceCount(JNIEnv* env, jclass clazz, jlong handle){
    AudioSource* wav = (AudioSource*)handle;
            return soloud.countAudioSource(*wav);
}

JNIEXPORT jint JNICALL Java_arc_audio_Soloud_sourcePlay__JFFFZ(JNIEnv* env, jclass clazz, jlong handle, jfloat volume, jfloat pitch, jfloat pan, jboolean loop){
    AudioSource* wav = (AudioSource*)handle;

            return soloud.play(*wav, volume, pan, pitch, false, loop);
}

JNIEXPORT jint JNICALL Java_arc_audio_Soloud_sourcePlayBus(JNIEnv* env, jclass clazz, jlong handle, jlong busHandle, jfloat volume, jfloat pitch, jfloat pan, jboolean loop){
    AudioSource* wav = (AudioSource*)handle;
            Bus* bus = (Bus*)busHandle;

            return bus->play(*wav, volume, pan, pitch, false, loop);
}

JNIEXPORT void JNICALL Java_arc_audio_Soloud_sourcePriority(JNIEnv* env, jclass clazz, jlong handle, jfloat priority){
    AudioSource* source = (AudioSource*)handle;
            source->setPriority(priority);
}

JNIEXPORT void JNICALL Java_arc_audio_Soloud_sourceMinConcurrentInterrupt(JNIEnv* env, jclass clazz, jlong handle, jfloat value){
    AudioSource* source = (AudioSource*)handle;
            source->setMinConcurrentInterrupt(value);
}

JNIEXPORT void JNICALL Java_arc_audio_Soloud_sourceMaxConcurrent(JNIEnv* env, jclass clazz, jlong handle, jint maxConcurrent){
    AudioSource* source = (AudioSource*)handle;
            source->setMaxConcurrent(maxConcurrent);
}

JNIEXPORT void JNICALL Java_arc_audio_Soloud_sourceConcurrentGroup(JNIEnv* env, jclass clazz, jlong handle, jint group){
    AudioSource* source = (AudioSource*)handle;
            source->setConcurrentGroup(group);
}

JNIEXPORT void JNICALL Java_arc_audio_Soloud_sourceLoop(JNIEnv* env, jclass clazz, jlong handle, jboolean loop){
    AudioSource* source = (AudioSource*)handle;
            source->setLooping(loop);
}

JNIEXPORT void JNICALL Java_arc_audio_Soloud_sourceSingleInstance(JNIEnv* env, jclass clazz, jlong handle, jboolean single){
    AudioSource* source = (AudioSource*)handle;
            source->setSingleInstance(single);
}

JNIEXPORT void JNICALL Java_arc_audio_Soloud_sourceStop(JNIEnv* env, jclass clazz, jlong handle){
    AudioSource* source = (AudioSource*)handle;
            source->stop();
}

JNIEXPORT void JNICALL Java_arc_audio_Soloud_sourceFilter(JNIEnv* env, jclass clazz, jlong handle, jint index, jlong filter){
    ((AudioSource*)handle)->setFilter(index, ((Filter*)filter));
}

JNIEXPORT jint JNICALL Java_arc_audio_Soloud_pauseDevice(JNIEnv* env, jclass clazz){
    return soloud.pause();
}

JNIEXPORT jint JNICALL Java_arc_audio_Soloud_resumeDevice(JNIEnv* env, jclass clazz){
    return soloud.resume();
}

} // extern "C"
