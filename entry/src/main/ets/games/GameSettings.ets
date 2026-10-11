/* 读写游戏 settings.bin（ARC 的 Settings 格式）。*/
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { nativePathExists } from '../settings/StorageRoot';
import { GameDisplayPref, GAME_EDGE_FACTORY, GAME_SCALE_FACTORY,
         writeAppliedGameDisplay } from '../settings/LauncherPrefs';

const DOMAIN = 0x0000;
const TAG = 'MindustryLauncher';

export const TYPE_BOOL: number = 0;
export const TYPE_INT: number = 1;
export const TYPE_LONG: number = 2;
export const TYPE_FLOAT: number = 3;
export const TYPE_STRING: number = 4;
export const TYPE_BYTES: number = 5;

/** 一条设置。key 仅用于比较，写回用 keyRaw。*/
export interface GameSetting {
  key: string;
  keyRaw: Uint8Array;
  type: number;
  num: number;
  raw: Uint8Array;
}

/** 读写游标。*/
class Cursor {
  buf: Uint8Array;
  at: number = 0;

  constructor(buf: Uint8Array) {
    this.buf = buf;
  }

  left(): number {
    return this.buf.length - this.at;
  }

  need(n: number): boolean {
    return this.left() >= n;
  }

  u8(): number {
    const v: number = this.buf[this.at];
    this.at += 1;
    return v;
  }

  u16(): number {
    const v: number = (this.buf[this.at] << 8) | this.buf[this.at + 1];
    this.at += 2;
    return v;
  }

  i32(): number {
    const v: number = (this.buf[this.at] << 24) | (this.buf[this.at + 1] << 16)
                    | (this.buf[this.at + 2] << 8) | this.buf[this.at + 3];
    this.at += 4;
    return v;
  }

  take(n: number): Uint8Array {
    const v: Uint8Array = this.buf.slice(this.at, this.at + n);
    this.at += n;
    return v;
  }
}

/* 把键名的字节按 ASCII 看成字符串（只给比较用） */
function asciiView(b: Uint8Array): string {
  let s: string = '';
  for (let i = 0; i < b.length; i++) {
    s += String.fromCharCode(b[i]);
  }
  return s;
}

/** 我们自己造的键名一律是 ASCII 字面量，逐字符取低字节。 */
function asciiBytes(s: string): Uint8Array {
  const b: Uint8Array = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) {
    b[i] = s.charCodeAt(i) & 0xff;
  }
  return b;
}

function isZlibHeader(a: number, b: number): boolean {
  return a === 0x78 && (b === 1 || b === 94 || b === 0x9c || b === 0xda);
}

/* ====================================================================
 * 读
 * ==================================================================== */

/** 解析 settings.bin。返回 null = 读不了/解不了。任何一步对不上就整体返回 null。 */
export function parseGameSettings(bytes: Uint8Array): GameSetting[] | null {
  let body: Uint8Array = bytes;
  if (bytes.length > 1 && isZlibHeader(bytes[0], bytes[1])) {
    /* 压缩的一律不碰，游戏永远写明文。 */
    hilog.warn(DOMAIN, TAG, 'gamesettings: the file is zlib-compressed; the game never writes that '
               + '-- refusing to touch it');
    return null;
  }

  const c: Cursor = new Cursor(body);
  if (!c.need(4)) {
    return null;
  }
  const count: number = c.i32();
  if (count <= 0) {
    return null;
  }
  const rows: GameSetting[] = [];
  for (let i = 0; i < count; i++) {
    if (!c.need(3)) {
      return null;
    }
    const klen: number = c.u16();
    if (!c.need(klen + 1)) {
      return null;
    }
    const keyRaw: Uint8Array = c.take(klen);
    const key: string = asciiView(keyRaw);
    const type: number = c.u8();
    const row: GameSetting = { key: key, keyRaw: keyRaw, type: type, num: 0,
                               raw: new Uint8Array(0) };
    if (type === TYPE_BOOL) {
      if (!c.need(1)) {
        return null;
      }
      row.num = c.u8() === 0 ? 0 : 1;
    } else if (type === TYPE_INT) {
      if (!c.need(4)) {
        return null;
      }
      row.num = c.i32();
    } else if (type === TYPE_LONG) {
      if (!c.need(8)) {
        return null;
      }
      row.raw = c.take(8);
    } else if (type === TYPE_FLOAT) {
      if (!c.need(4)) {
        return null;
      }
      row.raw = c.take(4);
    } else if (type === TYPE_STRING) {
      if (!c.need(2)) {
        return null;
      }
      const vlen: number = c.u16();
      if (!c.need(vlen)) {
        return null;
      }
      row.raw = c.take(vlen);
    } else if (type === TYPE_BYTES) {
      if (!c.need(4)) {
        return null;
      }
      const blen: number = c.i32();
      if (blen < 0 || !c.need(blen)) {
        return null;
      }
      row.raw = c.take(blen);
    } else {
      hilog.warn(DOMAIN, TAG, 'gamesettings: unknown type %{public}d for "%{public}s"', type, key);
      return null;
    }
    rows.push(row);
  }
  /* 必须恰好用完，多出来的字节说明格式理解有误。 */
  if (c.left() !== 0) {
    hilog.warn(DOMAIN, TAG, 'gamesettings: %{public}d trailing byte(s) -- refusing', c.left());
    return null;
  }
  return rows;
}

/* ====================================================================
 * 写
 * ==================================================================== */

/** 序列化成明文字节。 */
export function serializeGameSettings(rows: GameSetting[]): Uint8Array {
  let size: number = 4;
  for (const r of rows) {
    size += 2 + r.keyRaw.length + 1;
    if (r.type === TYPE_BOOL) {
      size += 1;
    } else if (r.type === TYPE_INT) {
      size += 4;
    } else if (r.type === TYPE_STRING) {
      size += 2 + r.raw.length;
    } else if (r.type === TYPE_BYTES) {
      size += 4 + r.raw.length;
    } else {
      size += r.raw.length;
    }
  }
  const out: Uint8Array = new Uint8Array(size);
  let at: number = 0;
  const putI32 = (v: number): void => {
    out[at++] = (v >>> 24) & 0xff;
    out[at++] = (v >>> 16) & 0xff;
    out[at++] = (v >>> 8) & 0xff;
    out[at++] = v & 0xff;
  };
  const putU16 = (v: number): void => {
    out[at++] = (v >>> 8) & 0xff;
    out[at++] = v & 0xff;
  };
  const putBytes = (b: Uint8Array): void => {
    out.set(b, at);
    at += b.length;
  };

  putI32(rows.length);
  for (const r of rows) {
    putU16(r.keyRaw.length);
    putBytes(r.keyRaw);
    out[at++] = r.type;
    if (r.type === TYPE_BOOL) {
      out[at++] = r.num === 0 ? 0 : 1;
    } else if (r.type === TYPE_INT) {
      putI32(r.num);
    } else if (r.type === TYPE_STRING) {
      putU16(r.raw.length);
      putBytes(r.raw);
    } else if (r.type === TYPE_BYTES) {
      putI32(r.raw.length);
      putBytes(r.raw);
    } else {
      putBytes(r.raw);
    }
  }
  return out;
}

/** 读一个 int 设置。键不在或类型不是 int ⇒ fallback。 */
export function intSetting(rows: GameSetting[], key: string, fallback: number): number {
  for (const r of rows) {
    if (r.key === key && r.type === TYPE_INT) {
      return r.num;
    }
  }
  return fallback;
}

/** 键是否存在（任何类型）。 */
export function hasSetting(rows: GameSetting[], key: string): boolean {
  for (const r of rows) {
    if (r.key === key) {
      return true;
    }
  }
  return false;
}

/** 改一个 int 设置（不存在则追加）。返回是否真的有改动。 */
export function setIntSetting(rows: GameSetting[], key: string, value: number): boolean {
  for (const r of rows) {
    if (r.key === key) {
      if (r.type !== TYPE_INT) {
        hilog.warn(DOMAIN, TAG, 'gamesettings: "%{public}s" is type %{public}d, not int -- leaving it',
                   key, r.type);
        return false;
      }
      if (r.num === value) {
        return false;
      }
      r.num = value;
      return true;
    }
  }
  rows.push({ key: key, keyRaw: asciiBytes(key), type: TYPE_INT, num: value,
              raw: new Uint8Array(0) });
  return true;
}

/**
 * 写入游戏设置文件（原子替换，含自检与回读校验）。
 * @param targetPath 目标文件路径
 * @param settings   要写入的设置条目列表
 * @returns 成功返回空字符串，失败返回错误描述
 */
export function writeGameSettings(targetPath: string, settings: GameSetting[]): string {
  // 1. 序列化-解析自检
  const rawBytes: Uint8Array = serializeGameSettings(settings);
  const parsedRows: GameSetting[] | null = parseGameSettings(rawBytes);
  if (!parsedRows || parsedRows.length !== settings.length) {
    return '自检失败：序列化-解析不可逆（文件未修改）';
  }
  for (let i = 0; i < settings.length; i++) {
    if (parsedRows[i].key !== settings[i].key || parsedRows[i].type !== settings[i].type) {
      return `自检失败：第 ${i + 1} 条数据不一致（文件未修改）`;
    }
  }

  // 2. 写入临时文件
  const tempSuffix: string = '.launchertmp';
  const tempPath: string = targetPath + tempSuffix;
  try {
    const tempFile = fs.openSync(tempPath,
      fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE);
    try {
      fs.writeSync(tempFile.fd, rawBytes.buffer as ArrayBuffer);
    } finally {
      fs.closeSync(tempFile);
    }
  } catch (error) {
    return `写入临时文件失败：${(error as BusinessError).message}`;
  }

  // 3. 原子替换（重命名）
  try {
    fs.renameSync(tempPath, targetPath);
  } catch (error) {
    try { fs.unlinkSync(tempPath); } catch { /* 忽略 */ }
    return `替换文件失败：${(error as BusinessError).message}`;
  }

  // 4. 回读校验
  try {
    const expectedLength: number = rawBytes.length;
    const readBuffer = new ArrayBuffer(expectedLength);
    const readHandle = fs.openSync(targetPath, fs.OpenMode.READ_ONLY);
    let actualReadLength: number;
    try {
      actualReadLength = fs.readSync(readHandle.fd, readBuffer);
    } finally {
      fs.closeSync(readHandle);
    }
    if (actualReadLength !== expectedLength) {
      return `回读长度不符：期望 ${expectedLength}，实际 ${actualReadLength}`;
    }
    const readData = new Uint8Array(readBuffer, 0, actualReadLength);
    for (let i = 0; i < expectedLength; i++) {
      if (readData[i] !== rawBytes[i]) {
        return `回读字节验证失败，位置 ${i}`;
      }
    }
  } catch (error) {
    return `回读校验异常：${(error as BusinessError).message}`;
  }

  return ''; // 成功
}

/** 读并解析 `settings.bin`；无法读取或解析 ⇒ null。 */
export function loadGameSettings(path: string): GameSetting[] | null {
  try {
    if (!fs.accessSync(path)) {
      return null;
    }
    const size: number = fs.statSync(path).size;
    if (size <= 0 || size > 4 * 1024 * 1024) {
      hilog.warn(DOMAIN, TAG, 'gamesettings: refusing size %{public}d', size);
      return null;
    }
    const f: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
    const buf: ArrayBuffer = new ArrayBuffer(size);
    let got: number = 0;
    try {
      got = fs.readSync(f.fd, buf);
    } finally {
      fs.closeSync(f);
    }
    return parseGameSettings(new Uint8Array(buf, 0, got));
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'gamesettings: reading %{public}s failed (%{public}s)', path, err.message);
    return null;
  }
}

/* ====================================================================
 * 将启动器的显示偏好应用到游戏
 * ==================================================================== */

/** 游戏的两个键。 */
export const KEY_EDGE_PADDING: string = 'uiEdgePadding';
export const KEY_UI_SCALE: string = 'uiscale';

/** 游戏 settings.bin 里实际存的两个值。 */
export interface GameDisplayValues {
  edge: number;
  scale: number;
}

/** 读游戏里实际的避让与缩放。
 * @returns 读不到返回 null（与 0 区分）。 */
export function readGameDisplayValues(dataDir: string): GameDisplayValues | null {
  const rows: GameSetting[] | null = loadGameSettings(dataDir + '/settings.bin');
  if (rows === null) {
    return null;
  }
  return {
    edge: intSetting(rows, KEY_EDGE_PADDING, GAME_EDGE_FACTORY),
    scale: intSetting(rows, KEY_UI_SCALE, GAME_SCALE_FACTORY)
  };
}

/* 不覆盖玩家在游戏里改过的值：
 * 游戏值 == 出厂默认 或 == 我们上次写的 才写；否则保留。
 * settings.bin 不存在时自己建一个。
 * 路径存在性检查走双通道（fs.accessSync + nativePathExists），
 * 避免外部根误判。 */
function pathExistsAnyChannel(path: string): boolean {
  try {
    if (fs.accessSync(path)) {
      return true;
    }
  } catch (e) {
    /* 忽略 */
  }
  try {
    return nativePathExists(path) !== 0;
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'gamesettings: cannot tell whether %{public}s exists (%{public}s) '
               + '-- assuming it does and leaving it alone', path, err.message);
    return true;
  }
}

export function applyGameDisplay(dataDir: string, filesDir: string,
                                 pref: GameDisplayPref, applied: GameDisplayPref | null): string {
  const path: string = dataDir + '/settings.bin';
  const exists: boolean = pathExistsAnyChannel(path);
  let rows: GameSetting[] | null = loadGameSettings(path);
  if (rows === null) {
    if (exists) {
      /* 存在但读不了（解析失败/权限等）⇒ 不动 */
      return '';
    }
    /* 不存在 ⇒ 从空表建，先建目录 */
    try {
      fs.mkdirSync(dataDir, true);
    } catch (e) {
      /* 忽略 */
    }
    rows = [];
    hilog.info(DOMAIN, TAG, 'gamesettings: %{public}s does not exist yet -- creating it with '
               + 'the launcher\'s two keys', path);
  }

  let changed: boolean = false;
  /* 记录我们实际写入的值 */
  const next: GameDisplayPref = {
    edge: (applied !== null) ? applied.edge : pref.edge,
    scale: (applied !== null) ? applied.scale : pref.scale,
    auto: pref.auto, edgeSet: false, scaleSet: false
  };

  {
    const cur: number = intSetting(rows, KEY_EDGE_PADDING, GAME_EDGE_FACTORY);
    const ours: boolean = (applied !== null && cur === applied.edge);
    const untouched: boolean = (cur === GAME_EDGE_FACTORY);
    if ((ours || untouched) && cur !== pref.edge) {
      if (setIntSetting(rows, KEY_EDGE_PADDING, pref.edge)) {
        changed = true;
        next.edge = pref.edge;
        hilog.info(DOMAIN, TAG, 'gamesettings: %{public}s %{public}d -> %{public}d',
                   KEY_EDGE_PADDING, cur, pref.edge);
      }
    } else if (!ours && !untouched) {
      hilog.info(DOMAIN, TAG, 'gamesettings: %{public}s is %{public}d (the player set it in game) '
                 + '-- leaving it alone', KEY_EDGE_PADDING, cur);
    }
  }

  {
    const cur: number = intSetting(rows, KEY_UI_SCALE, GAME_SCALE_FACTORY);
    const ours: boolean = (applied !== null && cur === applied.scale);
    const untouched: boolean = (cur === GAME_SCALE_FACTORY);
    if ((ours || untouched) && cur !== pref.scale) {
      if (setIntSetting(rows, KEY_UI_SCALE, pref.scale)) {
        changed = true;
        next.scale = pref.scale;
        hilog.info(DOMAIN, TAG, 'gamesettings: %{public}s %{public}d -> %{public}d',
                   KEY_UI_SCALE, cur, pref.scale);
      }
    } else if (!ours && !untouched) {
      hilog.info(DOMAIN, TAG, 'gamesettings: %{public}s is %{public}d (the player set it in game) '
                 + '-- leaving it alone', KEY_UI_SCALE, cur);
    }
  }

  if (!changed) {
    return '';
  }

  const err: string = writeGameSettings(path, rows);
  if (err !== '') {
    hilog.error(DOMAIN, TAG, 'gamesettings: %{public}s', err);
    return err;
  }
  writeAppliedGameDisplay(filesDir, next);
  hilog.info(DOMAIN, TAG, 'gamesettings: wrote the launcher display values into %{public}s', path);
  return '';
}
