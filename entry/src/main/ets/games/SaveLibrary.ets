/* 存档按星球分组，非sector存档一文件一存档。 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
/* 从.msav读取元数据，用原生模块解压zlib。 */
import savemeta from 'libsavemeta.so';

const DOMAIN = 0x0000;
const TAG = 'MindustryLauncher';

/** 存档形态常量。 */
export const SAVE_KIND_SECTOR: string = 'sector';
export const SAVE_KIND_MANUAL: string = 'manual';

/** 存档列表项，不含元数据。 */
export interface SaveEntry {
  id: string;
  kind: string;
  label: string;
  groupKey: string;
  files: string[];
  sectors: number;
  bytes: number;
  mtime: number;
}

/** 是否是.msav文件。 */
function isMsav(n: string): boolean {
  return n.endsWith('.msav');
}

/** 是否是游戏自动备份。 */
function isBackup(n: string): boolean {
  return n.includes('-backup');
}

/** 提取基名，先剥-backup.msav再剥.msav。 */
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

/** 从去掉扩展名的名字提取星球名，否则返回''。 */
function sectorPlanet(base: string): string {
  if (!base.startsWith('sector-')) {
    return '';
  }
  const rest: string = base.substring('sector-'.length);
  const cut: number = rest.lastIndexOf('-');
  return cut <= 0 ? '' : rest.substring(0, cut);
}

/** 首字母大写。 */
function titleCase(s: string): string {
  return s.length === 0 ? s : (s.charAt(0).toUpperCase() + s.substring(1));
}

/** 列出存档，只读文件名+大小+时间，不读内容。目录不存在返回空数组。 */
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

  const groups: Map<string, SaveEntry> = new Map<string, SaveEntry>();

  for (const n of names) {
    if (!isMsav(n)) {
      continue;
    }
    const base: string = baseName(n);
    const planet: string = sectorPlanet(base);
    const isSector: boolean = planet !== '';
    const gk: string = isSector ? ('sector:' + planet) : ('manual:' + base);

    let st: fs.Stat | undefined = undefined;
    try {
      st = fs.statSync(savesDir + '/' + n);
    } catch (e) {
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
  /* 排序：战役置顶，组内按时间倒序。 */
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

/* 读存档元数据 */

/** 存档元数据，字段均为字符串。 */
export interface SaveMeta {
  ok: boolean;
  build: string;
  mapname: string;
  mods: string;
  saved: string;
  width: string;
  height: string;
  wave: string;
  playerteam: string;
  sectorPreset: string;
  playtime: string;
  fromFile: string;
}

const NO_META: SaveMeta = {
  ok: false, build: '', mapname: '', mods: '', saved: '', width: '', height: '',
  wave: '', playerteam: '', sectorPreset: '', playtime: '', fromFile: ''
};

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

/** 读一个.msav的元数据，失败返回NO_META。 */
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

/** 返回存档组中最新的非备份文件。 */
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
    }
  }
  return best;
}

/** 人类可读大小。 */
export function formatSaveSize(bytes: number): string {
  if (bytes >= 1048576) {
    return (bytes / 1048576).toFixed(1) + ' MB';
  }
  if (bytes >= 1024) {
    return (bytes / 1024).toFixed(0) + ' KB';
  }
  return String(bytes) + ' B';
}

/** Unix秒转日期字符串。 */
export function formatSaveDate(sec: number): string {
  const d: Date = new Date(sec * 1000);
  const p = (n: number): string => n < 10 ? '0' + String(n) : String(n);
  return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate());
}