/* Node API 支持不完整；遇到「找不到接口」的编译错误时包含 "napi/native_api.h"。
 *
 * 在任何【需要可执行内存】的东西启动【之前】，先问平台是否处于坚盾守护模式：坚盾禁止申请
 * 匿名可执行内存，而 HotSpot 建启动 stub 在解释字节码之前 ⇒ 解释执行和 JIT 要的内存一样多，
 * 应用根本起不来，必须提前告知而不是在第一帧就死。
 * 用 dlopen 而非链接：链接期依赖会写成硬 DT_NEEDED，不附带该 Kit 的设备连本库都加载不起来。
 * 返回字符串而非布尔：布尔把「库没找到」「符号没找到」「不在坚盾」压成同一个 false，
 * 而前两件是【知识的缺口】、不是「设备受限」的证据。只有 'on' 才表示处于坚盾；
 * 另有 'no-lib: <dlerror>' / 'no-sym: <dlerror>' / 'mode=<N>'，调用方不能拿它们拒绝启动。
 */
#include <node_api.h>
#include <stdio.h>
#include <dlfcn.h>
#include <DeviceSecurityKit/device_security_mode.h>

static napi_value ShieldDiagnosis(napi_env env, napi_callback_info info)
{
    char text[256];

    void *lib = dlopen("libdevice_security_mode.z.so", RTLD_LAZY);
    if (lib == NULL) {
        const char *why = dlerror();
        snprintf(text, sizeof(text), "no-lib: %s", why ? why : "(no dlerror text)");
    } else {
        DSM_DeviceSecurityMode (*get_mode)(void) =
            (DSM_DeviceSecurityMode (*)(void)) dlsym(lib, "HMS_DSM_GetDeviceSecurityMode");
        if (get_mode == NULL) {
            const char *why = dlerror();
            snprintf(text, sizeof(text), "no-sym: %s", why ? why : "(no dlerror text)");
        } else {
            const DSM_DeviceSecurityMode mode = get_mode();
            if (mode == DSM_SECURE_SHIELD_MODE) {
                snprintf(text, sizeof(text), "on");
            } else if (mode == DSM_NORMAL_MODE) {
                snprintf(text, sizeof(text), "off");
            } else {
                /* 头文件没有命名的枚举值。不要把它读成 "off"。 */
                snprintf(text, sizeof(text), "mode=%d", (int)mode);
            }
        }
        /* 故意【不】dlclose()：该库在整个进程生命周期内保持映射，
         * 避免后续调用因重新加载而拿到一个不同的答案。 */
    }

    napi_value result;
    napi_create_string_utf8(env, text, NAPI_AUTO_LENGTH, &result);
    return result;
}


static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        { "shieldDiagnosis", NULL, ShieldDiagnosis, NULL, NULL, NULL, napi_default, NULL },
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

static napi_module shield_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = NULL,
    .nm_register_func = Init,
    .nm_modname = "shield",
    .nm_priv = ((void*)0),
    .reserved = { 0 },
};

void __attribute__((constructor)) RegisterShieldModule(void)
{
    napi_module_register(&shield_module);
}