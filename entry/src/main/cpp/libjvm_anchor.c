/* libjvm.so -- 一个锚（ANCHOR），不是 JVM。每个挨着它的 JDK 库（libjava、libnet、libnio…）都在裸名
 * "libjvm.so" 上声明 DT_NEEDED，而链接器只在 HAP 的扁平 native-lib 目录 <bundle>/libs/arm64/ 里搜，
 * 真正的 libjvm.so 却在 <bundle>/libs/arm64/jdk21/lib/server/，且不能挪到搜索路径上：HotSpot 靠
 * 剥掉自身路径三段分量推导 java.home（…/jdk21 = java.home），并要求 <java.home>/lib/<module image> 存在。
 * ⇒ 这个极小的库待在搜索路径【上】，好让 "libjvm.so" 解析得出来；其它库真正要的符号来自真正的
 * libjvm.so，本应用先用 RTLD_GLOBAL 把它加载起来，使其在全局符号作用域中可见。
 * 没有东西直接链接本目标文件；应用总是用完整路径 dlopen() 真正的那个。
 * （⚠️「仅限 ASCII」规则已于 2026-09-28 实测推翻，撤销提交 db403e5；中文注释没有问题。）
 */

/* 导出符号，令本文件是结构合法的共享对象且动态符号表非空
 * （也给了个可 dlsym 的东西，用来证明加载到的是哪一个）。 */
__attribute__((visibility("default")))
int libjvm_anchor_present(void)
{
    return 0x4a564d;   /* "JVM" */
}
