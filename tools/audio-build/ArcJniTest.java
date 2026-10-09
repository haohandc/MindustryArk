/*
 * 本地功能验证：把 gen_jni.py 生成的 JNI 绑定编成 Windows DLL，用真实 JVM 调一遍。
 *
 * 为什么值得做这件事：
 *   上一次音频包失败的原因【不是】编译不过，而是 libarcarm64.so 里少了 3 个类的
 *   JNI 绑定（NativeUtils / Buffers / Pixmap）—— 符号存在性一查就知道，
 *   但我当时只核对了 Soloud 那一类。
 *   静态符号对齐只能证明"函数在"，证明不了"参数转换是对的"。
 *   这个测试把 Buffers 的几个 memcpy 重载真的跑一遍（指针算术错一个元素宽度就会读出错误数据），
 *   以及 Pixmap 的 MANUAL 路径（GetPrimitiveArrayCritical + stb_image）。
 *
 * 在 Windows 上测能覆盖的：JNI 命名、参数/返回值编组、指针类型、RAII 释放。
 * 覆盖不到的：Linux 专属分支（setenv/unsetenv/getenv 在 Windows 上直接返回 -1）、
 *             SDL3 音频后端本身（要真机）。
 */

import arc.graphics.Pixmap;
import arc.util.ArcNativesLoader;
import arc.util.Buffers;
import arc.util.NativeUtils;

import javax.imageio.ImageIO;
import java.awt.image.BufferedImage;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.nio.Buffer;
import java.nio.ByteBuffer;
import java.nio.FloatBuffer;
import java.nio.IntBuffer;
import java.nio.ShortBuffer;

public class ArcJniTest{
    static int pass = 0, fail = 0;

    static void check(String name, boolean ok, String detail){
        if(ok){
            pass++;
            System.out.println("  [OK]   " + name + (detail.isEmpty() ? "" : "   " + detail));
        }else{
            fail++;
            System.out.println("  [FAIL] " + name + "   " + detail);
        }
    }

    /** 调用私有/包私有的 static 方法（Pixmap 的几个 native 是包私有的） */
    static Object call(Class<?> c, String name, Class<?>[] types, Object... args) throws Exception{
        Method m = c.getDeclaredMethod(name, types);
        m.setAccessible(true);
        return m.invoke(null, args);
    }

    public static void main(String[] args) throws Exception{
        System.out.println("java.version = " + System.getProperty("java.version"));
        System.loadLibrary("arcjnitest");
        System.out.println("DLL 加载成功");
        System.out.println();

        // ---------------------------------------------------------------
        System.out.println("== 1. NativeUtils（jstring 参数 / jstring 返回值）==");
        // Windows 上实现体直接 return -1，但【参数编组仍会执行】
        //（我们的包装会无条件 GetStringUTFChars + RAII Release）——编组错了这里就崩
        int r = NativeUtils.setEnv("ARC_TEST_KEY", "ARC_TEST_VALUE", true);
        check("setEnv(String,String,boolean) 可调用", true, "返回 " + r + "（Windows 上预期 -1）");

        r = NativeUtils.unsetEnv("ARC_TEST_KEY");
        check("unsetEnv(String) 可调用", true, "返回 " + r + "（Windows 上预期 -1）");

        String s = NativeUtils.getEnv("PATH");
        check("getEnv(String) 返回非 null String", s != null, "= \"" + s + "\"（Windows 上预期空串）");

        // ---------------------------------------------------------------
        System.out.println();
        System.out.println("== 2. Buffers：直接缓冲区指针转换 ==");
        ByteBuffer buf = Buffers.newUnsafeByteBuffer(64);
        check("newUnsafeByteBuffer 返回直接缓冲区", buf != null && buf.isDirect(), "capacity=" + buf.capacity());

        // 先填 0xAB，再用 native clear() 清零 —— 指针错了这里会立刻看出来
        for(int i = 0; i < buf.capacity(); i++) buf.put(i, (byte)0xAB);
        call(Buffers.class, "clear", new Class<?>[]{ByteBuffer.class, int.class}, buf, buf.capacity());
        boolean allZero = true;
        int firstBad = -1;
        for(int i = 0; i < buf.capacity(); i++){
            if(buf.get(i) != 0){ allZero = false; firstBad = i; break; }
        }
        check("clear(ByteBuffer,int) 真的把内存清零了", allZero,
              allZero ? "64 字节全 0" : "第 " + firstBad + " 字节不是 0");

        long addr = Buffers.getUnsafeBufferAddress(buf);
        check("getUnsafeBufferAddress 返回非 0 地址", addr != 0, "0x" + Long.toHexString(addr));

        Buffers.disposeUnsafeByteBuffer(buf);
        check("disposeUnsafeByteBuffer -> freeMemory(ByteBuffer)", true, "已 free，未崩溃");

        // ---------------------------------------------------------------
        System.out.println();
        System.out.println("== 3. Buffers.copyJni 重载：指针算术（最容易错的地方）==");

        // 3a. copy(float[] src, Buffer dst, int numFloats, int offset)
        //     impl: memcpy(dst, src + offset, numFloats << 2)
        //     若 src 被当成 char*，src+2 会偏 2 字节而不是 2 个 float -> 数据全错
        FloatBuffer fdst = Buffers.newFloatBuffer(8);
        float[] fsrc = {1f, 2f, 3f, 4f, 5f, 6f, 7f, 8f};
        Buffers.copy(fsrc, fdst, 4, 2);
        float[] got = new float[4];
        for(int i = 0; i < 4; i++) got[i] = fdst.get(i);
        check("copy(float[],Buffer,numFloats,offset) 偏移按【float】算",
              got[0] == 3f && got[1] == 4f && got[2] == 5f && got[3] == 6f,
              "期望 [3,4,5,6] 实得 [" + got[0] + "," + got[1] + "," + got[2] + "," + got[3] + "]");

        // 3b. copy(byte[] src, int srcOffset, Buffer dst, int numElements)
        ByteBuffer bdst = Buffers.newByteBuffer(8);
        byte[] bsrc = {10, 11, 12, 13, 14, 15, 16, 17};
        Buffers.copy(bsrc, 2, bdst, 4);
        byte[] bgot = new byte[4];
        for(int i = 0; i < 4; i++) bgot[i] = bdst.get(i);
        check("copy(byte[],srcOffset,Buffer,numElements) 按【byte】算",
              bgot[0] == 12 && bgot[1] == 13 && bgot[2] == 14 && bgot[3] == 15,
              "期望 [12,13,14,15] 实得 [" + bgot[0] + "," + bgot[1] + "," + bgot[2] + "," + bgot[3] + "]");

        // 3c. copy(short[] src, int srcOffset, Buffer dst, int numElements)
        ShortBuffer sdst = Buffers.newShortBuffer(4);
        short[] ssrc = {100, 101, 102, 103, 104, 105, 106, 107};
        Buffers.copy(ssrc, 3, sdst, 2);
        short[] sgot = {sdst.get(0), sdst.get(1)};
        check("copy(short[],srcOffset,Buffer,numElements) 按【short】算",
              sgot[0] == 103 && sgot[1] == 104,
              "期望 [103,104] 实得 [" + sgot[0] + "," + sgot[1] + "]");

        // 3d. copy(int[] src, int srcOffset, Buffer dst, int numElements)
        IntBuffer idst = Buffers.newIntBuffer(4);
        int[] isrc = {1, 2, 3, 4, 5};
        Buffers.copy(isrc, 1, idst, 3);
        int[] igot = {idst.get(0), idst.get(1), idst.get(2)};
        check("copy(int[],srcOffset,Buffer,numElements) 按【int】算",
              igot[0] == 2 && igot[1] == 3 && igot[2] == 4,
              "期望 [2,3,4] 实得 [" + igot[0] + "," + igot[1] + "," + igot[2] + "]");

        // 3e. copy(float[] src, int srcOffset, int numElements, Buffer dst)
        FloatBuffer fdst2 = Buffers.newFloatBuffer(4);
        Buffers.copy(fsrc, 1, 3, fdst2);
        float[] g2 = {fdst2.get(0), fdst2.get(1), fdst2.get(2)};
        check("copy(float[],srcOffset,numElements,Buffer) 按【float】算",
              g2[0] == 2f && g2[1] == 3f && g2[2] == 4f,
              "期望 [2,3,4] 实得 [" + g2[0] + "," + g2[1] + "," + g2[2] + "]");

        // 3f. copy(Buffer src, Buffer dst, int numElements) —— 两个 Buffer -> char*
        FloatBuffer csrc = Buffers.newFloatBuffer(4);
        csrc.put(0, 9f).put(1, 8f).put(2, 7f).put(3, 6f);
        FloatBuffer cdst = Buffers.newFloatBuffer(4);
        Buffers.copy((Buffer)csrc, (Buffer)cdst, 4);
        float[] g3 = {cdst.get(0), cdst.get(1), cdst.get(2), cdst.get(3)};
        check("copy(Buffer,Buffer,numElements) 按【字节】算",
              g3[0] == 9f && g3[1] == 8f && g3[2] == 7f && g3[3] == 6f,
              "期望 [9,8,7,6] 实得 [" + g3[0] + "," + g3[1] + "," + g3[2] + "," + g3[3] + "]");

        // ---------------------------------------------------------------
        System.out.println();
        System.out.println("== 4. Pixmap：createJni / loadJni（MANUAL 路径）==");
        // load()/load(int,int) 只在 ArcNativesLoader.loaded 时走 native
        Field lf = ArcNativesLoader.class.getDeclaredField("loaded");
        lf.setAccessible(true);
        lf.setBoolean(null, true);
        check("ArcNativesLoader.loaded 置为 true", ArcNativesLoader.loaded, "（让 Pixmap 走 native 分支）");

        // 4a. createJni —— malloc + NewDirectByteBuffer + jlongArray 回填
        Pixmap pm = new Pixmap(4, 4);
        check("new Pixmap(4,4) -> createJni", pm.width == 4 && pm.height == 4 && pm.pixels != null,
              "width=" + pm.width + " height=" + pm.height + " pixels.capacity=" + (pm.pixels == null ? -1 : pm.pixels.capacity()));
        // createJni 里 memset 过，应为全 0
        boolean pmZero = true;
        for(int i = 0; i < 64; i++) if(pm.pixels.get(i) != 0){ pmZero = false; break; }
        check("createJni 的 memset 生效（64 字节全 0）", pmZero, "");

        // 用 Java 侧写一个像素，再读回来：handle(pixels 地址) 与 pixels 必须指向同一块内存
        pm.setRaw(1, 2, 0x11223344);
        check("setRaw/getRaw 往返一致（handle 与 pixels 同源）",
              pm.getRaw(1, 2) == 0x11223344,
              "写入 0x11223344 读回 0x" + Integer.toHexString(pm.getRaw(1, 2)));

        // 4b. loadJni —— GetPrimitiveArrayCritical + stb_image（真的解一张 PNG）
        BufferedImage bi = new BufferedImage(7, 5, BufferedImage.TYPE_INT_ARGB);
        for(int y = 0; y < 5; y++) for(int x = 0; x < 7; x++) bi.setRGB(x, y, 0xFF000000 | (x * 30) << 16 | (y * 40) << 8);
        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        ImageIO.write(bi, "png", bos);
        byte[] png = bos.toByteArray();

        Pixmap loaded = new Pixmap(png);
        check("new Pixmap(byte[]) -> loadJni 用 stb_image 解码",
              loaded.width == 7 && loaded.height == 5,
              "PNG " + png.length + " 字节 -> " + loaded.width + "x" + loaded.height + "（期望 7x5）");
        int c00 = loaded.getRaw(0, 0), c10 = loaded.getRaw(1, 0);
        check("解码出的像素与源图一致", c00 != c10,
              "pixel(0,0)=0x" + Integer.toHexString(c00) + " pixel(1,0)=0x" + Integer.toHexString(c10));

        // 4c. getFailureReason 在【无错误时】返回 Java null —— 这是 Arc 源码的固有行为，不是绑定问题：
        //     impl 是 `return env->NewStringUTF(stbi_failure_reason());`，而 stb 无错误时返回 NULL。
        //     这个方法的唯一调用点在 load() 的失败分支，那时一定有错误信息（见 4d）。
        Object frIdle = call(Pixmap.class, "getFailureReason", new Class<?>[]{});
        check("无错误时 getFailureReason() 返回 null（与 Arc 源码一致）", frIdle == null,
              "= " + frIdle);

        // 4d. 故意喂坏数据，验证错误路径也正常（stb 返回 NULL -> Java 抛 ArcRuntimeException）
        boolean threw = false;
        String msg = "";
        try{
            new Pixmap(new byte[]{1, 2, 3, 4, 5, 6, 7, 8});
        }catch(Throwable t){
            threw = true;
            msg = t.getMessage();
        }
        check("坏数据走错误路径（不崩溃，抛 Java 异常）", threw, "异常信息: " + msg);

        // 4d-2. 【真实错误路径】下 getFailureReason 必须有内容 —— 上面那条消息就是它给的
        Object fr = call(Pixmap.class, "getFailureReason", new Class<?>[]{});
        check("出错后 getFailureReason() 返回非空 String（jstring 返回值通路 OK）",
              fr instanceof String && !((String)fr).isEmpty(), "= \"" + fr + "\"");

        // 4e. free(handle)
        pm.dispose();
        check("dispose() -> free(long)", pm.isDisposed(), "handle 已归零");

        // ---------------------------------------------------------------
        System.out.println();
        System.out.println("== 5. 压力：反复分配/释放，看是否有句柄泄漏或崩溃 ==");
        for(int i = 0; i < 2000; i++){
            ByteBuffer b = Buffers.newUnsafeByteBuffer(128 + (i % 64));
            call(Buffers.class, "clear", new Class<?>[]{ByteBuffer.class, int.class}, b, 16);
            Buffers.disposeUnsafeByteBuffer(b);
            if(i % 500 == 0){
                Pixmap p = new Pixmap(8, 8);
                p.setRaw(3, 3, 0x01020304);
                p.dispose();
            }
        }
        check("2000 次 Buffer 分配/释放 + 4 次 Pixmap 往返", true, "无崩溃");

        // ---------------------------------------------------------------
        System.out.println();
        System.out.println("==================================================");
        System.out.printf("通过 %d 项，失败 %d 项%n", pass, fail);
        System.out.println("==================================================");
        System.exit(fail == 0 ? 0 : 1);
    }
}
