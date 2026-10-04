/* 读写**游戏自己的** `settings.bin`（ARC 的 Settings 格式）。
 *
 * ── 为什么需要它 ────────────────────────────────────────────────────────────
 * 用户要的是「启动器默认帮用户调好**游戏内**的异形屏避让与 UI 缩放」。而这两件事
 * **只存在于游戏的数据里**，没有任何跨进程接口：
 *   · `uiEdgePadding`（int，0~100）—— `mindustry.core.UI.updateMargins()` 把它加进
 *     `Scene.marginTop/Bottom`。⭐ 它是**唯一**可用的游戏侧避让旋钮：
 *     `arc.Graphics.getSafeInsets()` 在这个包里**恒返回 `{0,0,0,0}`**，而全包
 *     **没有任何类覆写它** ⇒ 游戏自己那套安全区机制是空转的（2026-10-04 反编译核实）。
 *   · `uiscale`（int，百分数；25~300）—— 界面整体缩放。
 * ⇒ 只能由启动器**写这个文件**。
 *
 * ── 格式（全部来自 `arc.Settings.loadValues` / `saveValues` 的字节码，不是猜的）──
 * ```
 * 头两字节是 0x78 且第二字节 ∈ {1, 94, 0x9c, 0xda}  ⇒ 整个流是 zlib 压缩的（⛔ 这种我们【不碰】，见 parseGameSettings）
 * 否则                                              ⇒ 明文（直接 DataInputStream）—— **游戏实际写的就是这种**
 * 然后：  int   条目数           （≤ 0 游戏会抛 "0 values are not allowed."）
 *        每条： readUTF 键名
 *               byte   类型      —— 0=bool 1=int 2=long 3=float 4=String 5=byte[]
 *               <按类型取值>      （bool 1 字节；int 4；long 8；float 4；String=readUTF；byte[]=int 长度 + 内容）
 * ```
 * ⭐ **序列化在本地被逐字节验证过**：拿设备上真实的 390 字节文件往返一次，输出与输入
 *    `逐字节相等`；改一个 int（`uiEdgePadding` 0→40）再写回，字节数不变、其余 18 条逐一相同。
 *    ⇒ 这份规范是**被证明的**，不是「看起来对」。
 *
 * ⛔ **写出去的一律是明文**，不重新压缩。理由是游戏两种都读（上面那个魔数分支就是为此存在的），
 *    而压缩要再引一层 zlib。⚠️ 代价：文件会大一点（几 KB 级），游戏下次自己保存时又会压回去。
 *
 * ⛔⛔ **type 2/3/5（long/float/字节数组）我们【不解释】，原样保留字节。**
 *    理由：float 的字面量格式化与 long 的解析各有坑（`-0.0`、精度、端序），而我们**一个都不需要**
 *    —— 要改的只有两个 int。⇒ 判据：**凡是不用改的东西，就原样搬，别解释它。**
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
/* ⭐ 「游戏内显示」那两个偏好存在启动器这边（LauncherPrefs），本文件负责把它落进游戏。 */
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
 *
 * ⛔⛔ **键与值都保留【原样字节】，只有 bool 与 int 会被解释。**
 *    理由是 ARC 用的是 `writeUTF`（**modified UTF-8**），与标准 UTF-8 在补充平面字符
 *    （U+10000 以上）和 NUL 上不同 ⇒ **「解码再编码」不是恒等变换**。
 *    ⭐ 而我们**一个字符串都不用解释**（要改的只有两个 int）⇒ 原样搬字节，
 *    这条风险整个消失：无论键或值里是什么编码、什么字符，往返都逐字节相同。
 *      `key` 只是给比较用的**视图**（按 ASCII 解），⛔ 写回去一律用 `keyRaw`。 */
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
 * ⛔ 刻意不用 `util.TextDecoder`：那会按标准 UTF-8 解，而 ARC 写的是 modified UTF-8；
 *    两者对 ASCII 相同、对别的字符不同，而**我们不需要那个精确性**
 *    （要比的键名全是 ASCII 字面量：`uiEdgePadding` / `uiscale`）。
 * ⚠️ 非 ASCII 的键会在这里变成一串「对不上任何东西」的字符 —— 那是**无副作用**的：
 *    它只是匹配不到，于是我们不动那个键，而写回时用的是 `keyRaw` 原样字节。 */
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
     * ⭐ 依据（反编译核实，不是猜）：`arc.Settings` 的构造函数里 `writeCompressed = false`，
     *    而**全包没有任何类调用 `setWriteCompressed(boolean)`** ⇒ 游戏**永远写明文**
     *    （设备上那份 390 字节的实测文件也是明文，与这条吻合）。
     * ⇒ 这条分支在现实里到不了；真遇到只可能是「别的工具写了一个压缩的」——
     *   那时**不动它**才是对的（我们的序列化只输出明文，混着写会把格式搞成两边都不是）。
     * ⚠️ 返回值 `null` = 「读不了」，调用方据此**不写**。 */
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

/* ====================================================================
 * 落盘
 * ==================================================================== */

/** 把整份设置写回。返回 `''` 成功，否则一句给日志用的话。
 *
 * ⛔⛔ **三道闸门，缺一不可**（这是**玩家的游戏数据**）：
 *   ① **写之前**先把自己序列化出来的字节**重新解析一遍**，逐条比对 ⇒ 保证「我要写的东西
 *      我读得回来」。这一步把「格式理解错了」挡在磁盘之外。
 *   ② 写**临时文件**再 `rename` 覆盖 ⇒ 中途失败不会留下半个文件（同目录 rename 是原子的）。
 *   ③ 写完**读回来**再验一次那个键的值。
 * ⚠️ 游戏的 `settings_backups/` 是它自己管的，这里**不碰**；也别往游戏目录里塞我们自己
 *    的备份文件（那是给游戏看的目录）。可恢复性靠上面 ②③ 与游戏自己的备份机制。 */
export function writeGameSettings(path: string, rows: GameSetting[]): string {
  const bytes: Uint8Array = serializeGameSettings(rows);
  const check: GameSetting[] | null = parseGameSettings(bytes);
  if (check === null || check.length !== rows.length) {
    return '写回前的自检没过（序列化出来的东西读不回来）—— 没有动文件';
  }
  for (let i = 0; i < rows.length; i++) {
    if (check[i].key !== rows[i].key || check[i].type !== rows[i].type) {
      return '写回前的自检没过（第 ' + String(i + 1) + ' 条对不上）—— 没有动文件';
    }
  }

  const tmp: string = path + '.launchertmp';
  try {
    const f: fs.File = fs.openSync(tmp,
      fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE);
    try {
      fs.writeSync(f.fd, bytes.buffer as ArrayBuffer);
    } finally {
      fs.closeSync(f);
    }
  } catch (e) {
    const err = e as BusinessError;
    return '写临时文件失败：' + err.message;
  }
  try {
    fs.renameSync(tmp, path);
  } catch (e) {
    const err = e as BusinessError;
    /* ⚠️ 收尾清掉临时文件，别在游戏目录里留垃圾 —— 那个目录是给游戏看的。 */
    try {
      fs.unlinkSync(tmp);
    } catch (e2) {
      /* 收不掉也只能算了；下面那句已经把病因说清楚了。 */
    }
    return '替换失败：' + err.message;
  }
  return '';
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

/* ⛔⛔ **不覆盖玩家在游戏里改过的值**（用户 2026-10-04 定的规则）。
 *
 * 判据靠三个数相比 —— 「游戏里现在的值」对「出厂默认」与「我们上次写的」：
 * ```
 *   == 出厂默认   ⇒ 玩家没碰过          ⇒ 写
 *   == 我们写的   ⇒ 那是我们的值，归我们管 ⇒ 写
 *   其它          ⇒ 玩家在游戏里改过了   ⇒ 不碰
 * ```
 * ⚠️ 第二行是承重的：少了它，**启动器写过一次之后就再也改不动了**
 *    （值既不是默认、也不被认作我们的 ⇒ 永远被当成「玩家改的」）。
 *
 * @returns `''` = 不需要动 / 动成功了；否则一句给人看的话。
 * ⚠️ **`settings.bin` 不存在时静默返回 `''`** —— 那是「游戏还没跑过」，不是错误。
 *    用户在游戏里跑一次之后，下一次启动启动器就会写进去（这正是「值仍是出厂默认就写」那条）。 */
export function applyGameDisplay(dataDir: string, filesDir: string,
                                 pref: GameDisplayPref, applied: GameDisplayPref | null): string {
  const path: string = dataDir + '/settings.bin';
  const rows: GameSetting[] | null = loadGameSettings(path);
  if (rows === null) {
    return '';                     /* 还没跑过游戏 / 读不了 —— 两种都「什么都不做」 */
  }

  let changed: boolean = false;
  const next: GameDisplayPref = { edge: pref.edge, scale: pref.scale };

  /* 边距。 */
  {
    const cur: number = intSetting(rows, KEY_EDGE_PADDING, GAME_EDGE_FACTORY);
    const ours: boolean = (applied !== null && cur === applied.edge);
    const untouched: boolean = (cur === GAME_EDGE_FACTORY);
    if ((ours || untouched) && cur !== pref.edge) {
      if (setIntSetting(rows, KEY_EDGE_PADDING, pref.edge)) {
        changed = true;
        hilog.info(DOMAIN, TAG, 'gamesettings: %{public}s %{public}d -> %{public}d',
                   KEY_EDGE_PADDING, cur, pref.edge);
      }
    } else if (!ours && !untouched) {
      /* 玩家在游戏里调过 ⇒ 不仅不写，还要**记住他那个值**，否则下次启动我们会以为自己没写过、
       * 又拿「默认」去比 —— 而它已经不等于默认，于是每次都白算一遍（结果一样，但日志会吵）。 */
      next.edge = cur;
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
        hilog.info(DOMAIN, TAG, 'gamesettings: %{public}s %{public}d -> %{public}d',
                   KEY_UI_SCALE, cur, pref.scale);
      }
    } else if (!ours && !untouched) {
      next.scale = cur;
      hilog.info(DOMAIN, TAG, 'gamesettings: %{public}s is %{public}d (the player set it in game) '
                 + '-- leaving it alone', KEY_UI_SCALE, cur);
    }
  }

  if (!changed) {
    /* 没改动也要把 `next` 记回去（它可能把「玩家自己设的值」记了下来）—— 但只在真的不同时才写文件。 */
    if (applied === null || applied.edge !== next.edge || applied.scale !== next.scale) {
      writeAppliedGameDisplay(filesDir, next);
    }
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
