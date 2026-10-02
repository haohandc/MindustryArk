/* 「一个存档」是什么 —— 以及怎么从 `saves/` 目录里把它列出来。
 * ⭐⭐ 单位是**一个星球**，不是单个 `.msav`。分组靠**文件名**：`sector-<星球>-<区块 id>` 归到同一个
 * 存档，别的一文件一存档。实测（平板 saves/ 的 18 个真存档，已排除 21 个 -backup 与 1 个非存档文件）：
 * sector-serpulo-*.msav 14 个 -> 【1】个存档；sector-erekir-*.msav 1 个 -> 【1】个；0/1/2.msav -> 【3】个。
 * ⚠️ 为什么不用存档**内容**里的归属：`rules` 里确实有 `sector:erekir-10`（实测），但那要解压每个
 * 文件 —— 列表阶段不该做这件事，文件名是免费的且实测够用；内容归属留给「查看存档数据」那个弹窗。
 * ⚠️ `-backup` 文件**属于**它们那一组，但**不单独成组**，也不计入「有几个存档」—— 那是游戏自己的滚动备份。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
/* 从 `.msav` 里读出元数据，原生实现（cpp/savemeta.c）—— 存档是 **zlib 压缩**的，
 * 而 ArkTS 侧没有可用的流式解压。 */
import savemeta from 'libsavemeta.so';

const DOMAIN = 0x0000;
const TAG = 'MindustryLauncher';

/** 一个存档的形态。 */
export const SAVE_KIND_SECTOR: string = 'sector';
export const SAVE_KIND_MANUAL: string = 'manual';

/** 列表需要的一项。⚠️ 刻意**不含**元数据 —— 那是点开才读的，见下面。 */
export interface SaveEntry {
  /** 稳定标识；同一份目录下重复列出时用它比对。 */
  id: string;
  /** 'sector' 或 'manual'。 */
  kind: string;
  /** 给玩家看的名字。 */
  label: string;
  /** 结构：sector 是星球名（`serpulo`），manual 是文件基名（`0`）。 */
  groupKey: string;
  /** 这个存档用到的**全部文件**（含 `-backup`）。删除/归档要按这个清单来。 */
  files: string[];
  /** 真存档文件数（不含 `-backup`）；sector 存档这就是区块数。 */
  sectors: number;
  /** 全部文件字节数之和。 */
  bytes: number;
  /** 组内最新的修改时间（Unix 秒）。 */
  mtime: number;
}

/** 是不是一个 `.msav`。 */
function isMsav(n: string): boolean {
  return n.endsWith('.msav');
}

/** 游戏自动生成的滚动备份 —— 属于它那一组，但不单独成组。 */
function isBackup(n: string): boolean {
  return n.includes('-backup');
}

/* ⛔⛔ 这里错过了两次。实测文件名有 `0.msav` / `0.msav-backup.msav`（⭐ 原名自带 `.msav`）⇒ ⭐ **`-backup.msav`
 * 必须当整体先剥，再剥 `.msav`。**
 * ⚠️ 错法一（先剥 `.msav` 再剥 `-backup`）⇒ 与本体裂成两组；错法二（原串 `rfind('-')` 取星球）⇒ 星球变成
 * `serpulo-101.msav`，每样东西出现两次。⭐ 两次都是用脚本在**真实文件列表**上跑一遍才发现的。 */
/* 导出它是因为**转移**（SaveTransfer）要按基名改名复制。⛔ 别在那边再写一份 ——
 * 那两次搞错的就是这个函数（见上面那段记录）。 */
export function saveBaseName(n: string): string {
  return baseName(n);
}

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

/** 从一个**已去掉扩展名**的名字 `sector-<星球>-<区块 id>` 里取出星球名；不是这个形状时返回 ''。
 * ⚠️ 用**最后一个**连字符切区块 id，剩下整段做星球 —— 实测的形状是 `sector-serpulo-101` /
 * `sector-erekir-10`，星球名里没有连字符。将来若有带连字符的星球名，这里会把它整个当星球。 */
function sectorPlanet(base: string): string {
  if (!base.startsWith('sector-')) {
    return '';
  }
  const rest: string = base.substring('sector-'.length);
  const cut: number = rest.lastIndexOf('-');
  return cut <= 0 ? '' : rest.substring(0, cut);
}

/** 首字母大写，给 `serpulo` -> `Serpulo` 用。 */
function titleCase(s: string): string {
  return s.length === 0 ? s : (s.charAt(0).toUpperCase() + s.substring(1));
}

/* 列出 `savesDir` 里的存档。
 * ⭐ **只读文件名 + 大小 + 时间**，不读内容 —— 列表不需要元数据，解压 18 个文件是几十 MB 的 CPU；
 *    元数据在「查看存档数据」时才读（那时只读一个）。
 * ⚠️ 目录不存在 ⇒ 返回空数组，不是错误。全新安装就是这样。 */
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

  /* 先按组归并。用 Map 而不是对象字面量 —— ArkTS 对无类型对象字面量是拒绝的。 */
  const groups: Map<string, SaveEntry> = new Map<string, SaveEntry>();

  for (const n of names) {
    if (!isMsav(n)) {
      continue;   /* ⚠️ 实测目录里有 `steam_autocloud.vdf`，它不是存档 */
    }
    /* ⚠️⭐ 一定要先剥扩展名 —— 顺序错了整组就散了，见 baseName 上的说明。 */
    const base: string = baseName(n);
    const planet: string = sectorPlanet(base);
    const isSector: boolean = planet !== '';
    /* 组键：sector 用星球，manual 用基础名 —— 这样 `0.msav` 与
     * `0.msav-backup.msav` 会落进同一组。 */
    const gk: string = isSector ? ('sector:' + planet) : ('manual:' + base);

    let st: fs.Stat | undefined = undefined;
    try {
      st = fs.statSync(savesDir + '/' + n);
    } catch (e) {
      /* 单个文件读不到就跳过它 —— 别让一个坏文件毁掉整个列表。 */
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
  /* 排序：⭐ **战役存档置顶**（用户 2026-10-02「Serpulo 和 Erekir 要置顶，玩家其他的再放下面」），
   * 组内新的在前。⚠️ 这不只是用户偏好：战役存档是**游戏进度**，一个星球一份、通常就那两份；
   * 手动存档会越积越多 —— 把「固定的两份」放在增长的那堆上面，列表就不用随数量变动而重新找。 */
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

/** 一个存档的元数据。字段全部是**字符串**，因为 native 返回的就是原始文本。 */
export interface SaveMeta {
  /** 读到没有。false 时其余字段都是空串。 */
  ok: boolean;
  /** ⭐ 写这个存档时的游戏构建号（整数，如 `160`）。**不是**「哪些版本能读它」。 */
  build: string;
  mapname: string;
  /** 当时的模组清单，形如 `[]` 或 `[a, b]`。 */
  mods: string;
  /** Unix 毫秒时间戳（字符串）。 */
  saved: string;
  width: string;
  height: string;
  wave: string;
  playerteam: string;
  /** 区块预置名（如 `onset`）—— 只有 sector 存档有。 */
  sectorPreset: string;
  /* 游戏内时长，单位是**毫秒**（字符串）。
   * ⛔ 原先写的是「tick 数」—— **错的**，2026-10-02 订正：游戏自己在 `Saves.update()` 里按
   *    `Time.timeSinceMillis()` 累加并交给 `Strings.formatMillis()` 显示（另见 LauncherHome.formatPlaytime）。 */
  playtime: string;
  /** 这个字段来自哪个文件 —— 一个 sector 存档有很多 msav，必须说清读的是哪一个。 */
  fromFile: string;
}

/** 空结果。读不出来时用它，而不是抛。 */
const NO_META: SaveMeta = {
  ok: false, build: '', mapname: '', mods: '', saved: '', width: '', height: '',
  wave: '', playerteam: '', sectorPreset: '', playtime: '', fromFile: ''
};

/* 从 native 返回的 `key=value` 文本里取一个字段。
 * ⚠️ **必须连同 `=` 一起匹配**，不能只匹配键名 —— 实测 `wave` 是 `wavetime` 的前缀而 `wavetime`
 *    排在 `wave` 前面，只匹配键名会先命中 `wavetime`（同坑见 GameLibrary.propField 的 build vs buildDate）。
 * ⚠️ 取【第一个】`=` 切分：值里可能有 `=`（`rules` 那种嵌套数据），键里不会有。 */
/* 换行用 fromCharCode 取，不在源码里写字面转义：直接写转义会被写文件的工具改坏
 * （本文件的换行是 CRLF，工具会把「反斜杠 + n」当成真实换行写进去 —— 报错是「未闭合字符串」）。 */
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

/* 读一个 `.msav` 的元数据。读不出来时返回 `NO_META`（`ok === false`），**不抛**。
 * ⚠️ 这是**解压**操作（存档是 zlib 的），比列表那一步贵得多；列表刻意不调它 ——
 *    只在一个存档被点开看详情时才调，而且一次只读一个文件。 */
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

/* 一个存档组里**最新的那个** `.msav` 文件 —— 详情弹窗读它。
 * ⚠️ 为什么不是全部：一个 Serpulo 战役有 **14 个** `.msav`，全部解压是几 MB 的 CPU，而玩家问「这是什么
 *    版本写的」通常想知道**最近在玩的那一个** ⇒ 读一个并**在界面上写明读的是哪个文件**。
 * ⚠️ 跳过 `-backup`：那是游戏的滚动备份，不代表当前状态。 */
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
      /* 单个文件读不到就跳过 —— 与列表那一步同样的处置。 */
    }
  }
  return best;
}

/** 人类可读的大小。与 jars 列表同一套口径。 */
export function formatSaveSize(bytes: number): string {
  if (bytes >= 1048576) {
    return (bytes / 1048576).toFixed(1) + ' MB';
  }
  if (bytes >= 1024) {
    return (bytes / 1024).toFixed(0) + ' KB';
  }
  return String(bytes) + ' B';
}

/** 只要日期。Unix 秒。 */
export function formatSaveDate(sec: number): string {
  const d: Date = new Date(sec * 1000);
  const p = (n: number): string => n < 10 ? '0' + String(n) : String(n);
  return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate());
}
