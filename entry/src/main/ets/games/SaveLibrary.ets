/* [A]
 * 「一个存档」是什么 —— 以及怎么从 `saves/` 目录里把它列出来。
 *
 * ⭐⭐ 单位是**一个星球**，不是单个 `.msav`
 *
 * 用户 2026-10-02 的描述，经实测成立：
 *   「msav 是按照区块分的。多个 msav 组合在一起是一个星球的存档。
 *     所以也就是所有 msav 在一块，属于一个存档。」
 *
 * 实测（平板 `saves/` 的 18 个真存档，已排除 21 个 `-backup` 与 1 个非存档文件）：
 *
 *     sector-serpulo-*.msav   14 个文件  ->  【1】个存档（Serpulo 战役）
 *     sector-erekir-*.msav     1 个文件  ->  【1】个存档（Erekir 战役）
 *     0.msav / 1.msav / 2.msav 各 1 个   ->  【3】个存档（手动存档）
 *
 * ⇒ 分组靠**文件名**：`sector-<星球>-<区块 id>` 归到同一个存档，别的一文件一存档。
 *
 * ⚠️ 为什么不用存档**内容**里的归属：`rules` 里确实有 `sector:erekir-10`（实测），
 *    但那要解压每个文件 —— 列表阶段不该做这件事。文件名是免费的，而且实测**够用**。
 *    ⭐ 内容里的归属留给「查看存档数据」那个弹窗，那里本来就要解压。
 *
 * ⚠️ `-backup` 文件**属于**它们那一组，但**不单独成组**，也不计入「有几个存档」——
 *    那是游戏自己的滚动备份（实测 21 个 vs 18 个真存档）。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
/* [A] 从 `.msav` 里读出元数据。原生实现（cpp/savemeta.c）—— 理由见那个文件的开头：
 * 存档是 **zlib 压缩**的，而 ArkTS 侧没有可用的流式解压。 */
import savemeta from 'libsavemeta.so';

const DOMAIN = 0x0000;
const TAG = 'MindustryLauncher';

/** [B] 一个存档的形态。 */
export const SAVE_KIND_SECTOR: string = 'sector';
export const SAVE_KIND_MANUAL: string = 'manual';

/** [B] 列表需要的一项。⚠️ 刻意**不含**元数据 —— 那是点开才读的，见下面。 */
export interface SaveEntry {
  /** [B] 稳定标识；同一份目录下重复列出时用它比对。 */
  id: string;
  /** [B] 'sector' 或 'manual'。 */
  kind: string;
  /** [B] 给玩家看的名字。 */
  label: string;
  /** [B] 结构：sector 是星球名（`serpulo`），manual 是文件基名（`0`）。 */
  groupKey: string;
  /** [B] 这个存档用到的**全部文件**（含 `-backup`）。删除/归档要按这个清单来。 */
  files: string[];
  /** [B] 真存档文件数（不含 `-backup`）；sector 存档这就是区块数。 */
  sectors: number;
  /** [B] 全部文件字节数之和。 */
  bytes: number;
  /** [B] 组内最新的修改时间（Unix 秒）。 */
  mtime: number;
}

/** [B] 是不是一个 `.msav`。 */
function isMsav(n: string): boolean {
  return n.endsWith('.msav');
}

/** [B] 游戏自动生成的滚动备份 —— 属于它那一组，但不单独成组。 */
function isBackup(n: string): boolean {
  return n.includes('-backup');
}

/* [A] ⛔⛔ **这一段我错了两次，两个错法都不一样。记下来。**
 *
 * 实测的真实文件名（平板 `saves/`）：
 *
 *     0.msav                          手动存档本体
 *     0.msav-backup.msav              ⭐ 它的备份 —— **原名里本身就带 `.msav`**
 *     sector-serpulo-101.msav         区块本体
 *     sector-serpulo-101.msav-backup.msav
 *
 * ⇒ ⭐ **`-backup.msav` 必须当作一个整体剥掉，之后再剥 `.msav`。**
 *
 *     0.msav-backup.msav            -> 剥 -backup.msav -> 0.msav          -> 剥 .msav -> 0
 *     sector-serpulo-101.msav-backup -> (同上)        -> sector-serpulo-101.msav -> -> sector-serpulo-101
 *     0.msav                        -> （无备份后缀）                       -> 剥 .msav -> 0
 *
 * ⚠️ 错法一：**先剥 `.msav`、再剥 `-backup`** ⇒ `0.msav-backup.msav` 得到 `0.msav`，
 *    而本体得到 `0` ⇒ **同一个存档裂成两组**。
 * ⚠️ 错法二：**直接在原串上 `rfind('-')` 取星球** ⇒ 找到的是 `msav` 前面那个连字符
 *    ⇒ 星球名变成 `serpulo-101.msav` ⇒ **每样东西又在列表里出现两次**。
 *
 * ⭐ 两次都是把这段逻辑用脚本在**真实文件列表**上跑一遍才发现的 —— 光读代码看不出来，
 *    而且两种错法的症状都是「条数看起来还算合理」。
 */
function baseName(n: string): string {
  let s: string = n;
  if (s.endsWith('-backup.msav')) {
    s = s.substring(0, s.length - '-backup.msav'.length);
  }
  if (s.endsWith('.msav')) {
    s = s.substring(0, s.length - '.msav'.length);
  }
  return s;
}

/** [A]
 * 从一个**已去掉扩展名**的名字 `sector-<星球>-<区块 id>` 里取出星球名；不是这个形状时返回 ''。
 *
 * ⚠️ 用**最后一个**连字符来切区块 id，剩下的整段做星球 —— 实测的形状是
 * `sector-serpulo-101` / `sector-erekir-10`，星球名里没有连字符。
 * 若将来出现带连字符的星球名，这里会把它整个当成星球（那仍然自洽，只是分组会变粗）。
 */
function sectorPlanet(base: string): string {
  if (!base.startsWith('sector-')) {
    return '';
  }
  const rest: string = base.substring('sector-'.length);
  const cut: number = rest.lastIndexOf('-');
  return cut <= 0 ? '' : rest.substring(0, cut);
}

/** [B] 首字母大写，给 `serpulo` -> `Serpulo` 用。 */
function titleCase(s: string): string {
  return s.length === 0 ? s : (s.charAt(0).toUpperCase() + s.substring(1));
}

/* [A]
 * 列出 `savesDir` 里的存档。
 *
 * ⭐ **只读文件名 + 大小 + 时间**，不读文件内容 —— 列表不需要元数据，而解压 18 个文件
 *    是几十 MB 的 CPU。元数据在「查看存档数据」时才读（那时只读一个）。
 *
 * ⚠️ 目录不存在 ⇒ 返回空数组，不是错误。全新安装就是这样。
 */
export function listSaves(savesDir: string): SaveEntry[] {
  if (savesDir === '') {
    return [];
  }
  let names: string[] = [];
  try {
    if (!fs.accessSync(savesDir)) {
      return [];
    }
    names = fs.listFileSync(savesDir);
  } catch (e) {
    const err = e as BusinessError;
    hilog.info(DOMAIN, TAG, 'saves: cannot list %{public}s (%{public}s)', savesDir, err.message);
    return [];
  }

  /* [B] 先按组归并。用 Map 而不是对象字面量 —— ArkTS 对无类型对象字面量是拒绝的。 */
  const groups: Map<string, SaveEntry> = new Map<string, SaveEntry>();

  for (const n of names) {
    if (!isMsav(n)) {
      continue;   /* ⚠️ 实测目录里有 `steam_autocloud.vdf`，它不是存档 */
    }
    /* ⚠️⭐ 一定要先剥扩展名 —— 顺序错了整组就散了，见 baseName 上的说明。 */
    const base: string = baseName(n);
    const planet: string = sectorPlanet(base);
    const isSector: boolean = planet !== '';
    /* [B] 组键：sector 用星球，manual 用基础名 —— 这样 `0.msav` 与
     * `0.msav-backup.msav` 会落进同一组。 */
    const gk: string = isSector ? ('sector:' + planet) : ('manual:' + base);

    let st: fs.Stat | undefined = undefined;
    try {
      st = fs.statSync(savesDir + '/' + n);
    } catch (e) {
      /* [B] 单个文件读不到就跳过它 —— 别让一个坏文件毁掉整个列表。 */
      continue;
    }
    const size: number = st.size;
    const mt: number = Math.floor(st.mtime);

    const cur: SaveEntry | undefined = groups.get(gk);
    if (cur === undefined) {
      const label: string = isSector
        ? (titleCase(planet) + ' 战役')
        : (gk.substring('manual:'.length) + '.msav');
      groups.set(gk, {
        id: gk,
        kind: isSector ? SAVE_KIND_SECTOR : SAVE_KIND_MANUAL,
        label: label,
        groupKey: isSector ? planet : gk.substring('manual:'.length),
        files: [n],
        sectors: isBackup(n) ? 0 : 1,
        bytes: size,
        mtime: mt,
      });
    } else {
      cur.files.push(n);
      cur.bytes += size;
      if (!isBackup(n)) {
        cur.sectors += 1;
      }
      if (mt > cur.mtime) {
        cur.mtime = mt;
      }
    }
  }

  const out: SaveEntry[] = [];
  groups.forEach((v: SaveEntry) => { out.push(v); });
  /* [A] 排序：⭐ **战役存档置顶**（用户 2026-10-02：「Serpulo 和 Erekir 要置顶，
   * 玩家其他的再放下面」），组内新的在前。
   *
   * ⚠️ 为什么这个顺序有道理，不只是用户偏好：战役存档是**游戏进度**，一个星球一份、
   *    通常一次就那两份；手动存档是玩家随手存的，会越积越多。把「固定的两份」放在
   *    增长的那一堆上面，列表就不用随存档数量变动而重新找。
   */
  out.sort((a: SaveEntry, b: SaveEntry) => {
    const ak: number = a.kind === SAVE_KIND_SECTOR ? 0 : 1;
    const bk: number = b.kind === SAVE_KIND_SECTOR ? 0 : 1;
    if (ak !== bk) {
      return ak - bk;
    }
    return b.mtime - a.mtime;
  });
  return out;
}

/* ====================================================================
 * 读一个存档的元数据
 * ==================================================================== */

/** [B] 一个存档的元数据。字段全部是**字符串**，因为 native 返回的就是原始文本。 */
export interface SaveMeta {
  /** [B] 读到没有。false 时其余字段都是空串。 */
  ok: boolean;
  /** [B] ⭐ 写这个存档时的游戏构建号（整数，如 `160`）。**不是**「哪些版本能读它」。 */
  build: string;
  mapname: string;
  /** [B] 当时的模组清单，形如 `[]` 或 `[a, b]`。 */
  mods: string;
  /** [B] Unix 毫秒时间戳（字符串）。 */
  saved: string;
  width: string;
  height: string;
  wave: string;
  playerteam: string;
  /** [B] 区块预置名（如 `onset`）—— 只有 sector 存档有。 */
  sectorPreset: string;
  /* [A] 游戏内时长，单位是**毫秒**（字符串）。
   * ⛔ 这里原先写的是「tick 数」—— **错的**，2026-10-02 核单位时订正。
   *    依据（两条独立证据）见 `LauncherHome.formatPlaytime` 的注释：
   *    游戏自己在 `Saves.update()` 里按 `Time.timeSinceMillis()` 累加，
   *    并交给 `Strings.formatMillis()` 显示；平板真存档的取值也只有按毫秒才合理。 */
  playtime: string;
  /** [B] 这个字段来自哪个文件 —— 一个 sector 存档有很多 msav，必须说清读的是哪一个。 */
  fromFile: string;
}

/** [B] 空结果。读不出来时用它，而不是抛。 */
const NO_META: SaveMeta = {
  ok: false, build: '', mapname: '', mods: '', saved: '', width: '', height: '',
  wave: '', playerteam: '', sectorPreset: '', playtime: '', fromFile: ''
};

/* [A]
 * 从 native 返回的 `key=value` 文本里取一个字段。
 *
 * ⚠️ **必须连同 `=` 一起匹配**，不能只匹配键名 —— 实测 `wave` 是 `wavetime` 的前缀，
 *    而 `wavetime` 在文本里**排在 `wave` 前面**（见 savemeta.c 的解压样本）。
 *    只匹配键名会先命中 `wavetime`，于是 `wave` 永远读到空。
 *    ⭐ 同一个坑在 `GameLibrary.propField` 里也记着（那次是 `build` vs `buildDate`）。
 *
 * ⚠️ 取【第一个】`=` 切分：值里可能有 `=`（`rules` 那种嵌套数据），键里不会有。
 */
/* [A] 换行用 fromCharCode 取，不在源码里写字面转义。
 * ⚠️ 直接写转义会被写文件的工具改坏：本文件的换行是 CRLF，而工具会把
 *    「反斜杠 + n」这种两字符序列当成真实换行写进去 —— 报错是「未闭合字符串」。
 */
const LF: string = String.fromCharCode(10);
const CR: string = String.fromCharCode(13);

function metaField(text: string, key: string): string {
  const prefix: string = key + '=';
  const lines: string[] = text.split(LF);
  for (const raw of lines) {
    const line: string = raw.endsWith(CR) ? raw.substring(0, raw.length - 1) : raw;
    if (line.startsWith(prefix)) {
      return line.substring(prefix.length).trim();
    }
  }
  return '';
}

/* [A]
 * 读一个 `.msav` 的元数据。读不出来时返回 `NO_META`（`ok === false`），**不抛**。
 *
 * ⚠️ 这是**解压**操作（存档是 zlib 的），所以它比列表那一步贵得多。
 *    列表刻意不调它 —— 只在一个存档被点开看详情时才调，而且一次只读一个文件。
 */
export function readSaveMeta(filePath: string): SaveMeta {
  let text: string = '';
  try {
    text = savemeta.saveMetaText(filePath);
  } catch (e) {
    const err = e as BusinessError;
    hilog.info(DOMAIN, TAG, 'saves: saveMetaText(%{public}s) failed (%{public}s)', filePath, err.message);
    return NO_META;
  }
  if (text === '') {
    return NO_META;
  }
  const name: string = filePath.substring(filePath.lastIndexOf('/') + 1);
  return {
    ok: true,
    build: metaField(text, 'build'),
    mapname: metaField(text, 'mapname'),
    mods: metaField(text, 'mods'),
    saved: metaField(text, 'saved'),
    width: metaField(text, 'width'),
    height: metaField(text, 'height'),
    wave: metaField(text, 'wave'),
    playerteam: metaField(text, 'playerteam'),
    sectorPreset: metaField(text, 'sectorPreset'),
    playtime: metaField(text, 'playtime'),
    fromFile: name,
  };
}

/* [A]
 * 一个存档组里**最新的那个** `.msav` 文件 —— 详情弹窗读它。
 *
 * ⚠️ 为什么是「最新的那个」而不是全部：一个 Serpulo 战役有 **14 个** `.msav`（每个区块一个），
 *    全部解压是几 MB 的 CPU，而玩家问「这个存档是什么版本写的」通常想知道的是
 *    **最近在玩的那一个**。⇒ 读一个，并**在界面上写明读的是哪个文件**，
 *    这样「其他区块可能不同」这件事是看得见的，而不是被藏起来。
 *
 * ⚠️ 跳过 `-backup`：那是游戏的滚动备份，不代表当前状态。
 */
export function newestFileOf(entry: SaveEntry, savesDir: string): string {
  let best: string = '';
  let bestMt: number = -1;
  for (const f of entry.files) {
    if (isBackup(f)) {
      continue;
    }
    try {
      const st: fs.Stat = fs.statSync(savesDir + '/' + f);
      const mt: number = Math.floor(st.mtime);
      if (mt > bestMt) {
        bestMt = mt;
        best = f;
      }
    } catch (e) {
      /* [B] 单个文件读不到就跳过 —— 与列表那一步同样的处置。 */
    }
  }
  return best;
}

/** [B] 人类可读的大小。与 jars 列表同一套口径。 */
export function formatSaveSize(bytes: number): string {
  if (bytes >= 1048576) {
    return (bytes / 1048576).toFixed(1) + ' MB';
  }
  if (bytes >= 1024) {
    return (bytes / 1024).toFixed(0) + ' KB';
  }
  return String(bytes) + ' B';
}

/** [B] 只要日期。Unix 秒。 */
export function formatSaveDate(sec: number): string {
  const d: Date = new Date(sec * 1000);
  const p = (n: number): string => n < 10 ? '0' + String(n) : String(n);
  return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate());
}
