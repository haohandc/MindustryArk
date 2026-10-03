/* 整包数据：把一个版本的**全部游戏数据**打成一个 zip，或从 zip 恢复回来。
 *
 * ── 它替代的是什么 ──────────────────────────────────────────────────────────
 * 游戏自带的「导入存档」走的是它的文件浏览器，而那个浏览器在本平台是**坏的**
 * （Arc 的 `libarc-filedialogs` 是 glibc 链接，加载不了）⇒ 玩家换机 / 恢复备份没有路。
 * ⛔ 用户明确要的是「**导入完整的数据，不只是 msav**」—— 所以这是整包，不是单存档导入器。
 *
 * ── ⭐ 为什么整包能保住存档名，单存档不能 ────────────────────────────────────
 * Mindustry 的存档**显示名不在 `.msav` 里**，在 `settings.bin` 的 `save-<文件名>-name` 上
 * （反编译 `Saves$SaveSlot.getName()` 确认：`settings.getString(index + "-name", "untitled")`）。
 * ⇒ 只搬一个 `.msav` 进去，游戏显示 `untitled`；**整包带上 `settings.bin`，名字就跟着来了。**
 * ⇒ 这也是「不自己写 settings.bin」这条取舍成立的原因（见下）。
 *
 * ── 格式（都经 SDK 与实测核对）──────────────────────────────────────────────
 * · `.msav` = **纯 zlib 流**；解压后 `[0..3]="MSAV"` ⇒ `savemeta.c` 已经在查这个魔数，
 *   于是**校验器是现成的**（`readSaveMeta()` 给 `NO_META` = 不是存档）。
 * · ⛔ `compressFiles(paths[], out, opts)` **不能用来打数据包** —— 实测它把各目录的文件
 *   **全部拍平到 zip 根**（一个带 `/` 的条目都没有），层级全丢。详见 `packDataDir` 的说明。
 *   ⇒ 必须**先暂存成目录、再 `compressFile(目录, zip)`**。
 * · ⚠️ `decompressFile(inFile, outFile, …)` 的两个约束：`inFile` 扩展名**必须是 `.zip`**、
 *   `outFile` **必须已经存在**（它是解压目标目录）。
 * · ⚠️ 文档写明这些 API 要的是**应用沙箱路径**。⚠️ 所以**暂存一律在沙箱里做**，
 *   跨边界（用户选的位置）用 fd 拷 —— 与参考项目 AMCL 的做法一致。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';
import { readSaveMeta, SaveMeta } from './SaveLibrary';
import {
  isDir, pathExists, listFiles,
  newTreeStat, copyTreeInto, removeTree, TreeStat,
} from '../utils/FsTree';

const DOMAIN = 0x0000;
const TAG = 'MindustryLauncher';

/* ── 包里装什么 ──────────────────────────────────────────────────────────────
 * ⛔ **刻意不装** `cache/`、`previews/`、`assetCache/`：它们是可再生的（游戏会重建），
 *    而 `cache/` 里是几 MB 一个的 ogg，装进去会让包大出一大截、且对「恢复」毫无价值。
 * ⚠️ 这是**体积 vs 完整性**的取舍，不是遗漏。缺了它们游戏照样起得来（实测过多次：删掉
 *    `cache/` 之后游戏自己重新导出了音频缓存）。 */
const WANTED: string[] = [
  'saves',            /* 存档 —— 核心 */
  'mods',             /* 模组 —— 与存档强相关（存档会记录它用了哪些 mod） */
  'maps',             /* 自定义地图 */
  'schematics',       /* 蓝图 */
  'settings.bin',     /* ⭐ 设置 + **存档显示名**都在这（见文件头） */
  'server_list.json', /* 收藏的服务器 */
];

/** 给导出文件起名用的时间戳：`20261003-1745`。
 * ⭐ 用户 2026-10-03 的要求：「名称应该是 版本号 + 导出时间」。两个包放一起时，
 *    光看版本号分不出先后，而**时间能**。 */
export function stampNow(): string {
  const d: Date = new Date();
  const two = (n: number): string => (n < 10 ? '0' + String(n) : String(n));
  return String(d.getFullYear()) + two(d.getMonth() + 1) + two(d.getDate())
       + '-' + two(d.getHours()) + two(d.getMinutes());
}

/** 临时目录名（在应用沙箱里）—— 打包与解包都在这里做。 */
export const TMP_DIR_NAME: string = 'datapack';

/** 确保一个目录存在。⚠️ `mkdirSync(p, true)` 在目录已存在时**仍会抛 EEXIST**
 *  （参考项目 AMCL 记过这个坑），所以统一用 best-effort + 事后 `pathExists` 判定。 */
export function ensureDir(path: string): boolean {
  if (pathExists(path)) {
    return true;
  }
  try {
    fs.mkdirSync(path, true);
  } catch (e) {
    /* 目录已存在也会走到这里 —— 交给下面那行确认，不要在这里下结论。 */
  }
  return pathExists(path);
}

/** 把一个沙箱文件拷到**另一个沙箱路径**（两边都是路径，不是 URI）。
 *
 * ⭐ 导出用它，**不按 picker 返回的 URI 当文件写**：`DOWNLOAD` 模式的 picker 返回的是**目录** URI，
 *    文件名得我们自己拼上去 —— 所以拿到的已经是「目录路径」，剩下就是普通文件复制。
 * ⚠️ 仍然是分块读写而不是 `fs.copyFileSync`：这个文件可能几百 MB，
 *    而 `copyFileSync` 没有进度、也没有失败位置。 */
export function copyLocalFile(srcPath: string, dstPath: string): string {
  let out: fs.File | undefined = undefined;
  try {
    const inF: fs.File = fs.openSync(srcPath, fs.OpenMode.READ_ONLY);
    out = fs.openSync(dstPath, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE);
    try {
      const buf: ArrayBuffer = new ArrayBuffer(64 * 1024);
      let n: number = fs.readSync(inF.fd, buf);
      while (n > 0) {
        fs.writeSync(out.fd, buf, { length: n });
        n = fs.readSync(inF.fd, buf);
      }
    } finally {
      fs.closeSync(inF);
    }
    return '';
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'datapack: copying to %{public}s failed (%{public}s)',
               dstPath, err.message);
    return '写到导出位置失败：' + err.message;
  } finally {
    if (out !== undefined) {
      try { fs.closeSync(out); } catch (e) { /* 已经关了 */ }
    }
  }
}

/** 把一个 picker URI 拷进沙箱 —— **因为 zlib 只吃沙箱路径**（见文件头）。 */
export function readUriToFile(uri: string, dstPath: string): string {
  let src: fs.File | undefined = undefined;
  try {
    src = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    const out: fs.File = fs.openSync(dstPath,
      fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE);
    try {
      const buf: ArrayBuffer = new ArrayBuffer(64 * 1024);
      let n: number = fs.readSync(src.fd, buf);
      while (n > 0) {
        /* ⛔ **必须带 `length`**：不带的话会把整个 64KB 缓冲区写出去。 */
        fs.writeSync(out.fd, buf, { length: n });
        n = fs.readSync(src.fd, buf);
      }
    } finally {
      fs.closeSync(out);
    }
    return '';
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'datapack: copying the picked uri failed (%{public}s)', err.message);
    return '读取选定文件失败：' + err.message;
  } finally {
    if (src !== undefined) {
      try { fs.closeSync(src); } catch (e) { /* 已经关了 */ }
    }
  }
}

/** 这个数据目录里**实际存在**的、该入包的东西。
 * ⚠️ 返回空数组 = 目录是空的 ⇒ 调用方必须**拒绝打包**，不要产出一个空 zip
 *    （`compressFiles` 对空目录会报错，而报错信息读起来像「输入非法」、不像「没数据」）。 */
export function packableItems(dataDir: string): string[] {
  const out: string[] = [];
  for (const name of WANTED) {
    const p: string = dataDir + '/' + name;
    if (pathExists(p)) {
      out.push(p);
    }
  }
  return out;
}

/** 打包一个数据目录。返回 `''` = 成功，否则是可读的失败原因。
 *
 * ⛔⛔ **必须「先暂存、再压目录」，不能用 `compressFiles(paths[])`。**
 *    我第一版用的就是 `compressFiles`，理由是「它能只挑想要的子目录、省一次拷贝」——
 *    **那是错的**：实测（把包拉下来 `unzip -l`）它把 `saves/`、`mods/`、`schematics/` 的
 *    文件**全部拍平到 zip 根**，**一个带 `/` 的条目都没有** ⇒ 目录层级全丢
 *    ⇒ 导入端再也分不出哪个 `.msav` 属于 `saves/`、哪个 `.msch` 属于 `schematics/`
 *    ⇒ **包不可恢复**。而且 `settings.bin` 与别的同名文件会互相覆盖。
 *    ⇒ 现在：把想要的项**按名字拷进暂存目录**，再 `compressFile(暂存目录, zip)`
 *       —— 压「一个目录」才会保留它内部的层级。
 *
 * ⚠️ 暂存的代价很小：要的东西合起来约 3 MB（实测），而 `cache/` 单独就 28 MB。
 *
 * ⚠️ 耗时 ⇒ 调用方**必须**在异步上下文里调它，且给进度提示。
 *    ⛔ 不要在 UI 线程里同步做（本项目刚为「探针在 UI 线程写文件」吃过亏）。 */
export async function packDataDir(dataDir: string, tmpDir: string, outZip: string): Promise<string> {
  if (!isDir(dataDir)) {
    return '数据目录不存在：' + dataDir;
  }
  const items: string[] = packableItems(dataDir);
  if (items.length === 0) {
    return '这个版本没有任何可打包的数据（saves / mods / 地图 / 蓝图 全都不在）。';
  }
  if (!ensureDir(tmpDir)) {
    return '建不出临时目录：' + tmpDir;
  }
  /* ⛔⛔ **暂存目录必须与导入用的那个分开** —— 这是踩过的真 bug，不是洁癖：
   *    导入把 zip 解压到 `<tmp>/incoming`，而打包原先也用 `<tmp>/staging` 当暂存。
   *    于是「目标已有数据 ⇒ 先备份」那条路上：`packDataDir` 一进来就
   *    `removeTree(自己的暂存)` ⇒ **把刚解压好的导入数据删掉** ⇒ 随后从那个已不存在的
   *    路径复制 ⇒ 报「列目录失败 <路径>」。
   *    ⭐ 症状看起来像「路径不对」，病根是**两个动作抢同一个目录**。
   *    ⇒ 打包用 `packing`，导入用 `incoming`，两者永不交叉。 */
  const staging: string = tmpDir + '/packing';
  /* 每次重来：残留的旧暂存/旧 zip 会让「打包失败」看起来像成功（文件在、但是上一次的）。 */
  const accWipe: TreeStat = newTreeStat();
  removeTree(staging, 0, accWipe);
  if (!ensureDir(staging)) {
    return '建不出暂存目录：' + staging;
  }
  if (pathExists(outZip)) {
    try { fs.unlinkSync(outZip); } catch (e) { /* 删不掉就交给下面那步自己报错 */ }
  }

  /* ① 暂存：按**原名字**拷进去，层级就此保住。 */
  const acc: TreeStat = newTreeStat();
  for (const src of items) {
    const name: string = src.substring(src.lastIndexOf('/') + 1);
    const dst: string = staging + '/' + name;
    if (isDir(src)) {
      copyTreeInto(src, dst, 0, acc);
    } else {
      try {
        /* ⚠️ 用 `fs.copyFileSync`：`FsTree` 没导出它（它自己在递归里用）。 */
        fs.copyFileSync(src, dst);
        acc.files += 1;
      } catch (e) {
        acc.failed += 1;
        if (acc.firstError === '') {
          const err = e as BusinessError;
          acc.firstError = src + ' -> ' + dst + ': ' + err.message;
        }
      }
    }
  }
  if (acc.failed > 0) {
    /* ⚠️ 把**路径**和第一个错误都报出来 —— 一条不写路径的日志等于把排查推给下一个人
     * （`Isolation.copyLiveDataInto` 有同款注释）。 */
    hilog.error(DOMAIN, TAG, 'datapack: staging had %{public}d failure(s), first: %{public}s',
                acc.failed, acc.firstError);
    return '暂存失败（' + String(acc.failed) + ' 项）：' + acc.firstError;
  }

  try {
    /* ⭐ `BEST_SPEED` 而不是 `BEST_COMPRESSION`：**包里的大部分内容已经是压缩过的**
     * （`.msav` 是 zlib 流、`mods/*.zip` 是 zip），再压一遍几乎榨不出体积 ⇒ 高级别纯等。
     * ⚠️ `CompressLevel` 只有 `NO_COMPRESSION=0 / BEST_SPEED=1 / BEST_COMPRESSION=9`
     *   三个成员（核过 SDK）—— ⛔ 没有 `DEFAULT_COMPRESSION`，别照直觉写那个名字。 */
    await zlib.compressFile(staging, outZip, {
      level: zlib.CompressLevel.COMPRESS_LEVEL_BEST_SPEED,
    });
    if (!pathExists(outZip)) {
      return '压缩没有产出文件。';
    }
    hilog.info(DOMAIN, TAG,
               'datapack: packed %{public}d dir(s) / %{public}d file(s) into %{public}s',
               acc.dirs, acc.files, outZip);
    /* 成功才清暂存；失败时留着，便于下一个人直接看它长什么样。 */
    const accClean: TreeStat = newTreeStat();
    removeTree(staging, 0, accClean);
    return '';
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'datapack: compressFile failed (%{public}s, code=%{public}d)',
               err.message, err.code);
    return '压缩失败：' + err.message + ' (code=' + err.code + ')';
  }
}

/** 一个数据目录里有多少东西 —— 给界面写「这个包值不值得导」用。
 * ⚠️ 只数**该入包的那些**，与 `packableItems` 同一份清单，不要各写一遍。 */
export function countPackable(dataDir: string): string {
  const parts: string[] = [];
  for (const name of WANTED) {
    const p: string = dataDir + '/' + name;
    if (isDir(p)) {
      try {
        parts.push(name + ' ' + listFiles(p).length);
      } catch (e) {
        parts.push(name + ' ?');
      }
    } else if (pathExists(p)) {
      parts.push(name);
    }
  }
  return parts.join('  ');
}

/* ==========================================================================
 * 导入
 * ========================================================================== */

/** 解压到一个**已经存在**的目录。
 * ⚠️ `decompressFile` 的两个硬约束（核过 SDK）：`inFile` 扩展名**必须是 `.zip`**、
 *    `outFile` **必须已经存在**（它是目标目录，不是要创建的文件）。
 *    ⇒ 所以调用方先 `ensureDir(staging)`，别指望它替你建。 */
export async function unpackZip(zipPath: string, stagingDir: string): Promise<string> {
  if (!pathExists(zipPath)) {
    return '找不到压缩包：' + zipPath;
  }
  /* ⚠️ 扩展名必须逐字是 .zip —— 用户选的文件名里可能没有它，我们在拷进沙箱时就该改成 .zip。 */
  if (!zipPath.endsWith('.zip')) {
    return '压缩包路径必须以 .zip 结尾。';
  }
  if (!ensureDir(stagingDir)) {
    return '建不出解压目录：' + stagingDir;
  }
  try {
    await zlib.decompressFile(zipPath, stagingDir, {});
    return '';
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'datapack: decompressFile failed (%{public}s, code=%{public}d)',
               err.message, err.code);
    /* ⚠️ 900003 = 「不是 ZIP 格式或已损坏」—— 这是**最可能**的一种，单独给一句人话。 */
    if (err.code === 900003) {
      return '这个文件不是 zip，或者已经损坏。';
    }
    return '解压失败：' + err.message + ' (code=' + err.code + ')';
  }
}

/** 一个目录看起来像不像「游戏数据根」。
 * 判据刻意宽：只要有 `saves/`、`settings.bin`、`mods/` 里的**任意一个**就算。
 * ⛔ 不要要求「必须有 saves/」—— 一个只有模组的数据包也是合法的。 */
function looksLikeDataRoot(dir: string): boolean {
  return isDir(dir + '/saves') || isDir(dir + '/mods') || pathExists(dir + '/settings.bin');
}

/** 在解压结果里**定位数据根**。
 *
 * ⭐ 为什么要它：包是我们自己打的（根就是数据根），但**别人的包形态不定** ——
 *    可能外面套着 `Mindustry/`、也可能套着 `.local/share/Mindustry/`。
 * ⛔ **找不到就返回 `''`（拒绝），不要猜。** 猜错 = 把数据放错地方，而且看起来像成功。
 * ⚠️ 往下走只在「恰好只有一个子目录」时进行，且限深 —— 否则会把 `saves/` 里面的目录
 *    当成新的根一路钻下去。 */
export function locateDataRoot(dir: string, depth: number = 0): string {
  if (looksLikeDataRoot(dir)) {
    return dir;
  }
  if (depth > 4) {
    return '';
  }
  let children: string[] = [];
  try {
    children = listFiles(dir);
  } catch (e) {
    return '';
  }
  const dirs: string[] = [];
  for (const name of children) {
    if (isDir(dir + '/' + name)) {
      dirs.push(name);
    }
  }
  if (dirs.length !== 1) {
    /* 0 个 ⇒ 是个空壳；≥2 个 ⇒ 分不清哪个是数据根。两种都拒绝。 */
    return '';
  }
  return locateDataRoot(dir + '/' + dirs[0], depth + 1);
}

/** 校验一个候选数据根。返回 `''` = 可以导入，否则是拒绝理由。
 *
 * ⭐ **校验器是现成的**：`.msav` 是纯 zlib 流、解压后以 `MSAV` 开头，
 *    而 `savemeta.c` 已经在查这个魔数（`readSaveMeta` 给 `NO_META`）。
 *    ⇒ 拿一个真存档验一次，就能把「随便一个 zip」和「Mindustry 数据包」分开。 */
export function validatePack(root: string): string {
  const savesDir: string = root + '/saves';
  if (!looksLikeDataRoot(root)) {
    return '这个包里没有 saves/、mods/ 或 settings.bin —— 它不像是 Mindustry 的数据。';
  }
  if (!isDir(savesDir)) {
    /* 没有 saves/ 但有 mods/ 之类：合法，只是没有存档可恢复。 */
    return '';
  }
  let files: string[] = [];
  try {
    files = listFiles(savesDir);
  } catch (e) {
    return '读不出 saves/ 目录。';
  }
  const msav: string[] = files.filter((n: string) => n.endsWith('.msav'));
  if (msav.length === 0) {
    return 'saves/ 里没有 .msav 文件。';
  }
  /* ⭐ 只要**有一个**能读出元数据，就认定这是真存档 —— 而不是要求全部都过：
   * 备份文件（`-backup.msav`）与个别损坏的存档不该让整包被拒。 */
  for (const name of msav) {
    const meta: SaveMeta = readSaveMeta(savesDir + '/' + name);
    if (meta.ok) {
      return '';
    }
  }
  return 'saves/ 里有 ' + String(msav.length) + ' 个 .msav，但没有一个能读出存档元数据 —— 可能不是存档文件。';
}
