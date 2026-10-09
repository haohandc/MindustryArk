/* 读写**游戏自己的** `settings.bin`（ARC 的 Settings 格式）—— 避让与 UI 缩放只存在于游戏数据里，
 * 没有跨进程接口 ⇒ 只能由启动器写这个文件。
 *
 * ── 格式（来自 `arc.Settings.loadValues`/`saveValues` 字节码）──
 * 头两字节 `0x78` 且第二 ∈ {1, 94, 0x9c, 0xda} ⇒ zlib 压缩（⛔ 我们不碰）；否则明文。
 * 然后 int 条目数；每条 `readUTF` 键名 + byte 类型（0=bool 1=int 2=long 3=float 4=String 5=byte[]）+ 值。
 * ⭐ 逐字节验证过：设备上真实的 390 字节文件往返一次逐字节相等。
 * ⛔ 写出去的一律明文（游戏两种都读）、不重压缩；⛔ type 2/3/5 不解释、原样保留字节。 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
/* ⭐ 只为 `pathExistsAnyChannel` 里的第二通道。⚠️ 不成环：`StorageRoot` 的依赖图
 * 只到 `ModImporter` 与 `libstorprobe.so`，⛔ 不碰本文件（而 `Isolation` 碰，所以不能从它借）。 */
import { nativePathExists } from '../settings/StorageRoot';
import { GameDisplayPref, GAME_EDGE_FACTORY, GAME_SCALE_FACTORY,
         writeAppliedGameDisplay } from '../settings/LauncherPrefs';

const DOMAIN = 0x0000;
const TAG = 'MindustryLauncher';

/** 类型字节 —— ⛔ 与 ARC 的 `loadValues` tableswitch 一一对应，改这里必须同时改那边。 */
export const TYPE_BOOL: number = 0;
export const TYPE_INT: number = 1;
export const TYPE_LONG: number = 2;
export const TYPE_FLOAT: number = 3;
export const TYPE_STRING: number = 4;
export const TYPE_BYTES: number = 5;

/** 一条设置。
 * ⛔⛔ **键与值都保留【原样字节】**，只解释 bool 与 int：ARC 用 modified UTF-8（`writeUTF`），
 *    「解码再编码」不是恒等变换，而我们一个字符串都不用解释 ⇒ 原样搬字节，这条风险整个消失。
 *    `key` 只是比较用的 ASCII **视图**，⛔ 写回一律用 `keyRaw`。 */
export interface GameSetting {
  /** 比较用的键名视图（逐字节按 ASCII 解）。⛔ **不用于写回**。 */
  key: string;
  /** 键名的原样字节 —— 写回时用它。 */
  keyRaw: Uint8Array;
  type: number;
  /** type 0/1 的数值（bool 用 0/1）。别的类型没有意义。 */
  num: number;
  /** type 2/3/4/5 的**原样字节**（long 8、float 4、String 的值、byte[] 的内容）。 */
  raw: Uint8Array;
}

/** 一个读写游标。⚠️ 不用 `DataView` 是为了同时管「越界就报错」这一件事。 */
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

/* 把键名的字节按 ASCII 看成字符串 —— **只给比较用**。
 * ⛔ 刻意不用 `util.TextDecoder`：它按标准 UTF-8 解，而 ARC 写的是 modified UTF-8
 *    —— 两者对 ASCII 相同，而**要比的键名全是 ASCII 字面量**。非 ASCII 的键只是匹配不到，
 *    我们不动它，写回用的是 `keyRaw` 原样字节。 */
function asciiView(b: Uint8Array): string {
  let s: string = '';
  for (let i = 0; i < b.length; i++) {
    s += String.fromCharCode(b[i]);
  }
  return s;
}

/** 我们自己造的键名一律是 ASCII 字面量 ⇒ 逐字符取低字节即可。 */
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

/** 解析 `settings.bin`。返回 `null` = 读不了/解不了（**不是**「空文件」）。
 * ⛔ 任何一步对不上就整体返回 `null`：这是一个**游戏拥有的文件**，半个解析结果拿去写回去
 *    就是把玩家的设置搞坏。判据：**读不全就别写。** */
export function parseGameSettings(bytes: Uint8Array): GameSetting[] | null {
  let body: Uint8Array = bytes;
  if (bytes.length > 1 && isZlibHeader(bytes[0], bytes[1])) {
    /* ⛔⛔ **压缩的一律不碰，而不是去实现一个解压器。**
     * ⭐ `arc.Settings` 的 `writeCompressed = false` 且全包无人调 `setWriteCompressed(boolean)`
     *    ⇒ 游戏**永远写明文**（实测那份 390 字节文件也是明文）；真遇到压缩的只可能是别的工具写的。 */
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
      row.raw = c.take(vlen);          /* ⛔ 原样，不解码 —— 见接口那段 */
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
  /* ⛔ 必须**恰好**用完：多出来的字节说明我们对格式的理解漏了什么，
   *    而带着误解写回去就是静默损坏。 */
  if (c.left() !== 0) {
    hilog.warn(DOMAIN, TAG, 'gamesettings: %{public}d trailing byte(s) -- refusing', c.left());
    return null;
  }
  return rows;
}

/* ====================================================================
 * 写
 * ==================================================================== */

/** 序列化成**明文**字节。⛔ 不说「压缩」，见文件头。 */
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
    /* ⛔ 写**原样字节**，不是把 `key` 重新编码 —— 那会毁掉非 ASCII 的键（见接口那段）。 */
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

/** 读一个 int 设置。键不在、或类型不是 int ⇒ `fallback`。
 * ⚠️ 返回 `fallback` 的两种情形**分不开**是有意的：调用方（「值是不是还是出厂默认」）
 *    只关心那个数，而「键不存在」在语义上就是「还没被写过 = 出厂值」。 */
export function intSetting(rows: GameSetting[], key: string, fallback: number): number {
  for (const r of rows) {
    if (r.key === key && r.type === TYPE_INT) {
      return r.num;
    }
  }
  return fallback;
}

/** 该键在不在（**任何**类型）。⭐ 用来区分「没被写过」与「写过一个 int」——
 *  写默认值时要判断，而 `intSetting` 把这两种情形压成同一个返回值。 */
export function hasSetting(rows: GameSetting[], key: string): boolean {
  for (const r of rows) {
    if (r.key === key) {
      return true;
    }
  }
  return false;
}

/** 改一个 int 设置（不存在就追加）。返回有没有真的改到。 */
export function setIntSetting(rows: GameSetting[], key: string, value: number): boolean {
  for (const r of rows) {
    if (r.key === key) {
      if (r.type !== TYPE_INT) {
        hilog.warn(DOMAIN, TAG, 'gamesettings: "%{public}s" is type %{public}d, not int -- leaving it',
                   key, r.type);
        return false;
      }
      if (r.num === value) {
        return false;                /* 没变化 ⇒ 调用方不必写盘 */
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
 * 写入游戏设置文件（原子替换写入，含自检与回读校验）。
 * 实际写入Mindustry中直接生效的`Mindustry/settings.bin`文件，
 * 目录`settings_backups/`，`Mindustry/settings_backup.bin`与该函数无关。
 * **两处的文件用于兜底，防止设置出现错误，启动器无需处理。**
 * @param targetPath 目标文件路径
 * @param settings   要写入的设置条目列表
 * @returns 成功返回空字符串，失败返回错误描述
 */
export function writeGameSettings(targetPath: string, settings: GameSetting[]): string {
  // 1. 序列化-解析自检：保证可逆
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
    // 清理残留的临时文件，避免污染游戏目录
    try { fs.unlinkSync(tempPath); } catch { /* 清除失败可忽略 */ }
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

/** 读并解析一个 `settings.bin`；打不开/解析不了 ⇒ `null`。 */
export function loadGameSettings(path: string): GameSetting[] | null {
  try {
    if (!fs.accessSync(path)) {
      return null;                 /* 文件不存在 = 游戏还没跑过，不是错误 */
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
 * 把启动器的「游戏内显示」偏好落到游戏里
 * ==================================================================== */

/** 游戏的两个键。⛔ 名字与量程都抄自 `SettingsMenuDialog`，见 `LauncherPrefs` 那段。 */
export const KEY_EDGE_PADDING: string = 'uiEdgePadding';
export const KEY_UI_SCALE: string = 'uiscale';

/** 游戏那份 `settings.bin` 里**实际**存着的两个值。 */
export interface GameDisplayValues {
  edge: number;
  scale: number;
}

/** 读游戏里**实际**的避让与缩放。
 * ⭐⭐ 用途：**启动器界面的显示口径以它为准** —— 原来滑块只读启动器自己那份偏好文件，
 *    玩家在游戏里改完后两边显示的数是**不一样的**。
 * @returns 读不到（不存在/解析不了/被压过）⇒ `null`；⛔ `null` 与「读到 0」必须分开。 */
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

/* ⛔⛔ **不覆盖玩家在游戏里改过的值**（用户 2026-10-04 定）：游戏现值 == 出厂默认 ⇒ 写；
 * 「== 我们上次写的」⇒ 写（少了这条，启动器写过一次就再也改不动）；其它 ⇒ 玩家改过，不碰。
 * ⭐ `settings.bin` 不存在时**自己建一个**，否则全新安装第一次启动必然用不上我们的设置。
 * ⚠️⚠️ 未验证风险：建出的文件缺 `lastBuild`；若将来「第一次启动行为怪」，先怀疑这里。 */
/* ⛔⛔ **「这个路径存在吗」必须走双通道 —— 任何一路说有，就算有。** 原来只问 `fs.accessSync`，
 * 而它**在外部数据根上会误报读不到**（实测：native 列出 24 个文件而 ArkTS 一个都读不出）⇒ 会被当成
 * 「不存在」⇒ 拿只有两个键的表覆盖玩家整份设置。
 * ⚠️ 判据复制自 `Isolation.gameDataExists`（import 它会成环），`nativePathExists` 借自 `StorageRoot`。 */
function pathExistsAnyChannel(path: string): boolean {
  try {
    if (fs.accessSync(path)) {
      return true;
    }
  } catch (e) {
    /* `accessSync` 本来就「返回布尔不抛」；这个 catch 只兜住极端情况（如路径非法）。 */
  }
  try {
    return nativePathExists(path) !== 0;
  } catch (e) {
    const err = e as BusinessError;
    /* ⚠️⚠️ **两路都问不到 ⇒ 保守地当作「存在」。** 代价不对称：误判「存在」只是什么都不做，
     *    误判「不存在」是**把玩家的设置写没** ⇒ 方向不能反（同 `Isolation.gameDataExists`）。 */
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
      /* ⭐ **存在但读不了**（解析失败 / 被压过 / 权限 / **外部根上 ArkTS 读不到**）⇒ 什么都不做。
       * ⛔ 与「不存在」相反：那是「照我们的建一份」，这是「别碰它」。
       * ⚠️ 外置存储下这是**正常**结果（本应用读不到外部根、native 读得到），不是故障。 */
      return '';
    }
    /* ⭐ 不存在 ⇒ 从空表开始建；先建目录（`fs.openSync` **不建父目录**）。
     * ⛔⛔ `mkdirSync(dataDir)` —— 收到的 `dataDir` **本身已经是** `…/.local/share/Mindustry`
     *    （见 `Isolation.liveGameDataDir()`），再拼一次会造一棵没人读的 `…/Mindustry/.local/share/Mindustry`。 */
    try {
      fs.mkdirSync(dataDir, true);
    } catch (e) {
      /* 建不出来也不立刻返回 —— 下面 openSync 会给出真正的错误，而它比这里的一句更具体。 */
    }
    rows = [];
    hilog.info(DOMAIN, TAG, 'gamesettings: %{public}s does not exist yet -- creating it with '
               + 'the launcher\'s two keys', path);
  }

  let changed: boolean = false;
  /* ⛔⛔ `next` **只承载「我们真的写进游戏的值」**：初始化沿用上次记录（无则用本次偏好），只在**真的写成功
   *    的那一支**更新。⛔ 绝不在「玩家在游戏里改过」那支写 `next.edge = cur` —— 那会把玩家的值冒充成
   *    「我们写的」，下次启动就改回去（2026-10-05 修复）。⚠️ `*Set` 标志对这里无意义，补 `false`。 */
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
        next.edge = pref.edge;   /* ⭐ 只有**真的写成功**才记 —— 这是第 2 条修复的另一半。 */
        hilog.info(DOMAIN, TAG, 'gamesettings: %{public}s %{public}d -> %{public}d',
                   KEY_EDGE_PADDING, cur, pref.edge);
      }
    } else if (!ours && !untouched) {
      /* 玩家在游戏里调过 ⇒ **不碰它**，`next.edge` 保持上次的记录。 */
      hilog.info(DOMAIN, TAG, 'gamesettings: %{public}s is %{public}d (the player set it in game) '
                 + '-- leaving it alone', KEY_EDGE_PADDING, cur);
    }
  }

  /* UI 缩放。⚠️ 与边距同一套判据，但默认值是 100 而不是 0。 */
  {
    const cur: number = intSetting(rows, KEY_UI_SCALE, GAME_SCALE_FACTORY);
    const ours: boolean = (applied !== null && cur === applied.scale);
    const untouched: boolean = (cur === GAME_SCALE_FACTORY);
    if ((ours || untouched) && cur !== pref.scale) {
      if (setIntSetting(rows, KEY_UI_SCALE, pref.scale)) {
        changed = true;
        next.scale = pref.scale;   /* ⭐ 同上：只有真的写成功才记。 */
        hilog.info(DOMAIN, TAG, 'gamesettings: %{public}s %{public}d -> %{public}d',
                   KEY_UI_SCALE, cur, pref.scale);
      }
    } else if (!ours && !untouched) {
      /* ⛔ 同避让那一条：**不写 `next.scale = cur`**（理由见上面 `next` 的定义处）。 */
      hilog.info(DOMAIN, TAG, 'gamesettings: %{public}s is %{public}d (the player set it in game) '
                 + '-- leaving it alone', KEY_UI_SCALE, cur);
    }
  }

  if (!changed) {
    /* ⛔⛔ 一个都没写 ⇒ **`applied` 保持原样，连文件都不必重写**（2026-10-05 之前这里记回 `next`，
     *    而那时的 `next` 会把玩家自己设的值冒充成「我们写的」）。
     * ⛔ 「没写」的原因一律【不】在这里报文字 —— 用户定的规矩：**默认不加提示**，他同意了才加。 */
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
