/* 把崩溃报告从沙箱里弄出来，送到玩家能把它发出去的地方。
 *
 * native 侧（launcher.c 的 on_fatal_signal()）已经写好转储；缺的是把它弄【出】设备的方法 ——
 * 发布签名安装下 hdc / pidof / 故障日志器都读不了沙箱（全实测过）。
 * 两步，两个时钟方向相反：第 1 步 stashIfAny() 尽量早 —— launcher.c 每次进 main() 都 unlink
 * crash.txt，而 ArkTS onCreate 在 native main() **之前**跑，所以那是「上次崩溃仍在磁盘上」的
 * 唯一窗口；第 2 步 publish() 尽量晚，在页面确认 Download 文件夹可用之后。
 * 幂等：发布文件按**崩溃**命名，同名已存在就放着不动 ⇒ 每次启动都崩也只产出一份。
 * ⚠️ 暂存放 ctx.filesDir（HAP 级，始终可写）；它【不是】/data/storage/el2/base/files。
 */
import { bundleManager } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';

const DOMAIN = 0x0000;
const TAG = 'MindustryLauncher';

/* native 侧的应用级目录 —— 写成字面量是因为 context.filesDir 是一个【不同的】目录（见文件头）。 */
const NATIVE_FILES: string = '/data/storage/el2/base/files';
const NATIVE_CRASH: string = NATIVE_FILES + '/crash.txt';

/* 在第 1 步和第 2 步之间停放崩溃的地方，相对于 filesDir。 */
const STASH_FILE: string = '/last-crash.txt';

/* 暂存文件的首行，这样第 2 步就能把真正的暂存和垃圾区分开。 */
const STASH_MARKER: string = '#mindustryark-crash';

/* 应用 Download 文件夹的子文件夹，这样它就不会把 mod 列表弄乱。 */
const OUT_SUBDIR: string = '/diagnostics';

function writeAll(path: string, text: string): void {
  const f: fs.File = fs.openSync(path,
    fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE);
  fs.writeSync(f.fd, text);
  fs.closeSync(f);
}

/** 一行环境信息，或者一个可见的、说明它为什么缺失的理由。 */
function envLines(): Array<string> {
  const lines: Array<string> = [];
  try {
    const info: bundleManager.BundleInfo =
      bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
    /* 运行时读取，而不是写死：一份写错版本号的报告比一份不写版本号的报告更糟，
     * 而手抄的常量正是这件事发生的方式。 */
    lines.push('app          : ' + info.versionName + ' (' + info.versionCode + ')');
    lines.push('bundle       : ' + info.name);
  } catch (e) {
    const err = e as BusinessError;
    lines.push('app          : <unavailable: ' + err.message + '>');
  }
  try {
    lines.push('device       : ' + deviceInfo.brand + ' ' + deviceInfo.productModel);
    lines.push('system       : ' + deviceInfo.osFullName + '  API ' + deviceInfo.sdkApiVersion);
  } catch (e) {
    const err = e as BusinessError;
    lines.push('device       : <unavailable: ' + err.message + '>');
  }
  return lines;
}

/** 第 1 步 —— 在 native main() 把它删掉之前，把上一次启动的崩溃从沙箱里读出来。
 * 每次启动调用都是安全的；没有崩溃时什么都不做，而这是常态。
 * ⚠️ 必须从 onCreate、在 provideArkTSObjects() 【之前】调用（顺序见文件头）。 */
export function stashIfAny(filesDir: string): void {
  try {
    /* accessSync 【返回一个布尔值】；文件不在时它不抛异常。
     * 把「没有异常」当成「它存在」在这个代码库里以前造成过一个真实缺陷
     * （见 EntryAbility.startExitWatch）。 */
    if (!fs.accessSync(NATIVE_CRASH)) {
      return;
    }
    const text: string = fs.readTextSync(NATIVE_CRASH);
    if (text.trim().length === 0) {
      return;
    }

    /* 优先用崩溃文件自己的 mtime：它说的是崩溃【何时被写入】，这才是「crashed at」应有的
     * 含义 —— Date.now() 只会说下一次启动碰巧注意到它是什么时候。stat 失败时回退。 */
    let crashedAt: number = Date.now();
    try {
      crashedAt = fs.statSync(NATIVE_CRASH).mtime;
    } catch (e) {
      /* 保留回退 */
    }

    writeAll(filesDir + STASH_FILE,
             STASH_MARKER + '\n' +
             '#crashed-at=' + crashedAt + '\n' +
             text);

    hilog.warn(DOMAIN, TAG,
               'captured a crash report from the previous launch (%{public}d bytes) -- '
               + 'it will be published to Downloads once the folder is ready',
               text.length);
  } catch (e) {
    const err = e as BusinessError;
    hilog.error(DOMAIN, TAG, 'stashing the crash report failed: %{public}s', err.message);
  }
}

/** 一个日志文件保留多少：这些日志每次启动都被从头改写（launcher 以 O_TRUNC 打开它们），
 * 所以这限定的是一次会话的尾部 —— 大到足以容纳一次启动，小到足以附在一条消息里。 */
const LOG_TAIL_BYTES = 128 * 1024;

/** 一个文件的尾部，或者一个可见的、说明为什么没有的理由。 */
function readTail(path: string, limit: number): string {
  try {
    if (!fs.accessSync(path)) {
      return '(not present)';
    }
    const size: number = fs.statSync(path).size;
    if (size === 0) {
      return '(empty)';
    }
    if (size <= limit) {
      return fs.readTextSync(path);
    }
    /* 只读尾部：fs.readTextSync 接受 offset/length，几兆字节的日志不必为了被丢掉
     * 先整个拉进一个字符串。 */
    return '... [truncated: last ' + limit + ' of ' + size + ' bytes] ...\n' +
           fs.readTextSync(path, { offset: size - limit, length: limit });
  } catch (e) {
    const err = e as BusinessError;
    return '(unreadable: ' + err.message + ')';
  }
}

/** native 侧 stderr.log 的尾巴，给「上次没能启动成功」那个弹窗用。
 * ⚠️ 这一条往往就是**原因本身**：启动器把每处失败都写在这里，例如把 mod 当成游戏选中时日志里就是
 *    `!! mindustry.core.Vars is NOT on the classpath` ⇒ 与其自己编一句「可能是不兼容的 jar」，不如把它
 *    已经写下的那句话交出去。复用 readTail：三种坏情况（不存在 / 空 / 读不了）都返回说明而不是抛异常。 */
export function readStartupLogTail(maxBytes: number): string {
  return readTail(NATIVE_FILES + '/stderr.log', maxBytes);
}

/** 支持包：我们会向用户索要的一切，按需写出。
 * 为什么在自动路径之外：自动导出只在【确实有】崩溃时触发，而最难处理的是根本没崩的（「它起不来」「行为怪异」），
 * 且发布签名安装下也无法从外部读 stderr.log / stdout.log。⚠️ 日志属于【当前】会话（launcher 每次启动截断）。
 * 它【不是】幂等的：刻意的按下应每次都产出文件，所以名字里带着按下的那一刻。返回写入路径，写不出返回 ''。 */
export function exportNow(modFolder: string, filesDir: string): string {
  try {
    if (modFolder === '') {
      hilog.error(DOMAIN, TAG, 'cannot export diagnostics: the Downloads folder is not known');
      return '';
    }
    const now: number = Date.now();
    const dir: string = modFolder + OUT_SUBDIR;
    try {
      fs.mkdirSync(dir, true);
    } catch (e) {
      /* 已经在那儿了 —— 下面那次写入才是真正的测试 */
    }

    const stashPath: string = filesDir + STASH_FILE;
    const hasStash: boolean = fs.accessSync(stashPath);

    const report: string =
      'Ark Launcher -- diagnostics bundle\n' +
      '========================================\n' +
      envLines().join('\n') + '\n' +
      'collected at : ' + new Date(now).toString() + '\n' +
      '========================================\n' +
      '\n' +
      '## crash report from the previous launch\n' +
      '\n' +
      (hasStash ? fs.readTextSync(stashPath)
                : '(none -- the previous launch did not leave one)\n') +
      '\n' +
      '## crash.txt as it is on disk now\n' +
      '\n' +
      readTail(NATIVE_CRASH, LOG_TAIL_BYTES) + '\n' +
      '\n' +
      '## stderr.log (current session, tail)\n' +
      '\n' +
      readTail(NATIVE_FILES + '/stderr.log', LOG_TAIL_BYTES) + '\n' +
      '\n' +
      '## stdout.log (current session, tail)\n' +
      '\n' +
      readTail(NATIVE_FILES + '/stdout.log', LOG_TAIL_BYTES) + '\n';

    const target: string = dir + '/diagnostics-' + now + '.txt';
    writeAll(target, report);
    hilog.info(DOMAIN, TAG, 'exported a diagnostics bundle to %{public}s', target);
    return target;
  } catch (e) {
    const err = e as BusinessError;
    hilog.error(DOMAIN, TAG, 'exporting diagnostics failed: %{public}s', err.message);
    return '';
  }
}

/** 从暂存里把 #crashed-at 提回来；它不在时就返回 0。 */
function readCrashedAt(stash: string): number {
  const lines: Array<string> = stash.split('\n');
  if (lines.length < 2 || lines[0].trim() !== STASH_MARKER) {
    return 0;
  }
  const tag: string = '#crashed-at=';
  if (lines[1].indexOf(tag) !== 0) {
    return 0;
  }
  const value: number = Number.parseInt(lines[1].substring(tag.length).trim(), 10);
  return Number.isNaN(value) ? 0 : value;
}

/** 第 2 步 —— 把暂存复制进玩家可见的 Download 文件夹。
 * modFolder 是【路径】形式（modFolderPath() 返回的就是路径；URI 在这里不可用）。
 * 在 ensureModFolder() 完成之后从页面上调用它 —— 见文件头。 */
export function publish(modFolder: string, filesDir: string): void {
  try {
    if (modFolder === '') {
      return;  // 文件夹还不知道在哪儿；下次启动会再试
    }
    const stashPath: string = filesDir + STASH_FILE;
    if (!fs.accessSync(stashPath)) {
      return;  // 没有崩溃要报告，而这是常态
    }
    const stash: string = fs.readTextSync(stashPath);
    const crashedAt: number = readCrashedAt(stash);
    if (crashedAt === 0) {
      return;  // 不是我们写的东西
    }

    const dir: string = modFolder + OUT_SUBDIR;
    try {
      fs.mkdirSync(dir, true);   // 递归；EEXIST 是常态
    } catch (e) {
      /* 已经在那儿了，或者是并发创建的 —— 下面那次写入才是真正的测试 */
    }

    const target: string = dir + '/crash-' + crashedAt + '.txt';
    if (fs.accessSync(target)) {
      /* 这一次崩溃已经发布过了。这里什么都不做，正是让「每次启动都崩」
       * 不至于用一堆副本把这个文件夹塞满的原因。 */
      return;
    }

    const report: string =
      'Ark Launcher -- crash report\n' +
      '========================================\n' +
      envLines().join('\n') + '\n' +
      'crashed at   : ' + new Date(crashedAt).toString() + '\n' +
      'reported at  : ' + new Date().toString() + '\n' +
      '\n' +
      'Crash reports are collected from the device only when the app itself\n' +
      'writes them here; nothing is uploaded anywhere.\n' +
      '\n' +
      '========================================\n' +
      'raw crash dump follows\n' +
      '========================================\n\n' +
      stash;

    writeAll(target, report);
    hilog.warn(DOMAIN, TAG, 'published a crash report to %{public}s', target);
  } catch (e) {
    const err = e as BusinessError;
    hilog.error(DOMAIN, TAG, 'publishing the crash report failed: %{public}s', err.message);
  }
}
