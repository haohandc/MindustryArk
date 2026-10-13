/* 启动器主界面 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';
import { HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit';
import { bundleManager, common, ConfigurationConstant } from '@kit.AbilityKit';
import { appLabel } from '../utils/AppLabel';
import { newTreeStat, copyTreeInto, removeTree, TreeStat, isDir, pathExists } from '../utils/FsTree';
import { externalRootPath, STORAGE_MODE_SANDBOX, STORAGE_MODE_EXTERNAL,
         readStorageMode, writeStorageMode, gameDataRoot, gameDataRootFor, ensureGameDataRoot,
         probeExternalRoot, usedUserHome, usedUserHomeReason,
         dumpStorageState } from '../settings/StorageRoot';
import { fileIo as fs } from '@kit.CoreFileKit';
import { picker } from '@kit.CoreFileKit';
import { fileUri } from '@kit.CoreFileKit';
import {
  packDataDir, ensureDir, readUriToFile, copyLocalFile, stampNow,
  unpackZip, locateDataRoot, validatePack, packableItems, countPackable,
} from '../games/DataPack';
import { GameJar, GameResolution, listGameJars, readSelection, writeSelection,
         resolveGame, gameJarDir, ensureGameJarDir,
         bundledGameVersion, hasBundledGame, bundledGamePath,
         gameVersionParts } from '../games/GameLibrary';
import { readLaunchMode, writeLaunchMode,
         LAUNCH_MODE_HOME, LAUNCH_MODE_GAME,
         AppearancePref, readAppearance, writeAppearance,
         SafePref, readSafePref, writeSafePref, SAFE_VP_MAX, SAFE_VP_STEP,
         readGameLocaleFollow, writeGameLocaleFollow,
         GameDisplayPref, readGameDisplay, writeGameDisplay, readAppliedGameDisplay,
         GAME_EDGE_FACTORY, GAME_SCALE_FACTORY } from '../settings/LauncherPrefs';
import { displayDensity, autoEdgePadding, systemGameScale } from '../games/GameAutoFit';
import { applyGameDisplay, readGameDisplayValues, GameDisplayValues } from '../games/GameSettings';
import { SafeInsets, detectInsets, uniformOf, edgesOf, dumpSafeArea } from '../utils/SafeArea';
import { enterFade, enterPop } from '../utils/Motion';
import { SaveEntry, listSaves, formatSaveSize, formatSaveDate,
         SaveMeta, readSaveMeta, newestFileOf } from '../games/SaveLibrary';
import { VaultEntry, vaultDelete, vaultPermanentDelete, listVault, vaultRestore, vaultPurge,
         vaultSetArchived, purgeExpired, describeExpiry, formatMs,
         readVaultDays, writeVaultDays, VAULT_DAYS_CHOICES } from '../games/SaveVault';
import { copySaveTo, moveSaveTo, duplicateSave, countSavesIn } from '../games/SaveTransfer';
import { GRANULARITY_OFF, GRANULARITY_NUMBER, GRANULARITY_BUILD, GRANULARITY_PATCH,
         readGranularity, writeGranularity,
         copyLiveDataInto, gameDataExists, liveGameDataDir, isolatedGameDataDir,
         GameDataCounts, countsOf, describeCounts,
         resolveGameDataDir, resolveGameDirAndKey, GameDirForKey,
         listInstanceKeys, granularityKey, KEY_UNKNOWN,
         setGameDataRoot, migrateGameData, MigrateOutcome, dumpDataDirs,
         hasUserMadeFiles, settingsLocaleIn,
         writeIsolationBridge } from '../settings/Isolation';

const DOMAIN = 0x0000;
const TAG = 'MindustryLauncher';

interface MetaRow {
  label: string;
  value: string;
}

const DUP_KEY: string = '#dup-same-version';

const NL: string = String.fromCharCode(10);

interface SaveRow {
  dir: string;
  entry: SaveEntry;
}

interface IsoGroup {
  key: string;
  versions: string[];
}

interface SaveGroup {
  dir: string;
  versions: VersionEntry[];
  saves: SaveEntry[];
  orphanKey: string;
}

interface CopyTarget {
  key: string;
  versions: VersionEntry[];
  hasData: boolean;
}

const SAVES_VIEW_SAVE: string = 'save';
const SAVES_VIEW_VERSION: string = 'version';

interface ImportOutcome {
  done: number;
  backups: number;
  anyBackupInSandbox: boolean;
  dirs: number;
  files: number;
  fails: string[];
}

function newImportOutcome(): ImportOutcome {
  return { done: 0, backups: 0, anyBackupInSandbox: false, dirs: 0, files: 0, fails: [] };
}

interface VersionEntry {
  path: string;
  source: string;
  label: string;
  version: string;
  key: string;
  dataDir: string;
  isCurrent: boolean;
  saveCount: number;
  hasData: boolean;
}

function formatMsDateTime(ms: number): string {
  const d: Date = new Date(ms);
  const p = (n: number): string => n < 10 ? '0' + String(n) : String(n);
  return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate())
       + ' ' + p(d.getHours()) + ':' + p(d.getMinutes());
}

function formatPlaytime(ms: number): string {
  const totalMin: number = Math.floor(ms / 60000);
  if (totalMin < 1) {
    return '不足 1 分钟';
  }
  if (totalMin < 60) {
    return '约 ' + String(totalMin) + ' 分钟';
  }
  return '约 ' + String(Math.floor(totalMin / 60)) + ' 小时 ' + String(totalMin % 60) + ' 分钟';
}

function rowValue(rows: MetaRow[], label: string): string {
  const hit: MetaRow | undefined = rows.find((r: MetaRow) => r.label === label);
  return hit === undefined ? '' : hit.value;
}

function metaRowsOf(m: SaveMeta, sv: SaveEntry): MetaRow[] {
  const rows: MetaRow[] = [];
  const add = (label: string, value: string): void => {
    if (value !== '') {
      rows.push({ label: label, value: value });
    }
  };

  const others: number = sv.sectors - 1;
  add('读取自', m.fromFile + (others > 0 ? ('（另有 ' + String(others) + ' 个区块文件未读）') : ''));
  add('写入时的构建号', m.build);
  add('地图', m.mapname);
  add('区块预置', m.sectorPreset);
  add('波次', m.wave);
  if (m.width !== '' && m.height !== '') {
    add('地图尺寸', m.width + ' × ' + m.height);
  }
  add('玩家队伍', m.playerteam);
  if (m.saved !== '') {
    add('保存时间', formatMsDateTime(Number(m.saved)));
  }
  if (m.playtime !== '') {
    add('游戏内时长', formatPlaytime(Number(m.playtime)));
  }
  add('模组', m.mods);
  return rows;
}

const CONTENT_MIN_VP = 360;

const GAMES_WIDTH_PCT = 30;

const NARROW_VP = 600;

const BAR_MAX_VP = 480;

const BAR_MIN_SIDE_VP = 16;

const BAR_BOTTOM_MARGIN_VP = 24;

const BAR_CLEARANCE_VP = 96;

const SAFE_REVEAL_VP = 46;

/** 圆角。卡片和列表项共用 */
const CARD_RADIUS_VP = 14;

const LIVE_TARGET_PATH: string = '__live__';

const NOTICE_MS: number = 4000;

const PERM_HOLD_MS: number = 900;
const PERM_TICK_MS: number = 30;
const PERM_BTN_H: number = 46;
const ASK_BTN_W: string = '64%';
const PERM_BTN_W: string = '50%';

const BUTTON_FONT_VP = 16;

const SAVE_SIZE_COL_VP = 74;
const SAVE_DATE_COL_VP = 92;
const SAVE_TICK_COL_VP = 16;

const FAULT_BOX_VP = 240;

const DIALOG_WIDTH_FRACTION = 0.5;
const DIALOG_MIN_VP = 320;

/* 次要动作底色与文字色 */
const SECONDARY_BG = '#2EFFFFFF';
const SECONDARY_FG = '#B0FFFFFF';

function formatSize(bytes: number): string {
  if (bytes >= 1048576) {
    return (bytes / 1048576).toFixed(1) + ' MB';
  }
  if (bytes >= 1024) {
    return (bytes / 1024).toFixed(0) + ' KB';
  }
  return String(bytes) + ' B';
}

function formatDate(sec: number): string {
  const d: Date = new Date(sec * 1000);
  const p = (n: number): string => n < 10 ? '0' + String(n) : String(n);
  return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate());
}

/* 开源许可：界面展示的组件与它对应的许可正文（rawfile/licenses/ 下）。 */
interface LicenseEntry {
  name: string;
  file: string;
}

const LICENSE_FILES: LicenseEntry[] = [
  { name: 'Mindustry · GPL-3.0', file: 'licenses/GPL-3.0.txt' },
  { name: 'Arc · Apache-2.0', file: 'licenses/Apache-2.0.txt' },
  { name: 'OpenJDK 21 · GPL-2.0 with Classpath Exception', file: 'licenses/OpenJDK-GPLv2-CE.txt' },
  { name: 'LWJGL · BSD-3-Clause', file: 'licenses/LWJGL-BSD-3.txt' },
  { name: 'SDL3 · Zlib', file: 'licenses/SDL3-Zlib.txt' },
  { name: '第三方组件与修改声明', file: 'licenses/THIRD-PARTY.md' },
];

@Component
export struct LauncherHome {
  filesDir: string = '';
  bundleCodeDir: string = '';

  @Prop @Watch('onFolderSettled') folderSettled: boolean = false;

  onLaunch: (jarPath: string) => void = (jarPath: string) => {};
  onForceLaunch: () => void = () => {};

  @State games: GameJar[] = [];
  @State selected: string = '';
  @State resolution: GameResolution = { path: '', source: 'none' };
  private currentTab: number = 0;

  @State jarDirHint: string = '';
  @State winW: number = 0;
  @State launchMode: string = LAUNCH_MODE_HOME;
  @State safeVp: number = 0;
  @State detectedSafeVp: number = 0;
  @State detectedEdges: string[] = [];
  @State safeAuto: boolean = true;
  @State darkFollow: boolean = true;
  @State darkOn: boolean = false;
  @State storageIntent: string = STORAGE_MODE_SANDBOX;
  @State storageUsed: string = '';
  @State storageUsedReason: string = '';
  private storageDumped: string = '';
  @State storageToggleOn: boolean = false;
  @State storageBusy: boolean = false;
  @State gameLocaleFollow: boolean = true;
  @State gameEdge: number = GAME_EDGE_FACTORY;
  @State gameScale: number = GAME_SCALE_FACTORY;
  @State gameAuto: boolean = false;
  private safeDetected: boolean = false;
  private gameEdgeSet: boolean = false;
  private gameScaleSet: boolean = false;
  @State gameDisplayNote: string = '';
  private gameDisplayTried: string = '';
  @State storageNote: string = '';
  @State faultAck: boolean = false;
  @State showAbout: boolean = false;
  @State showLicenses: boolean = false;
  @State licenseSel: string = '';
  @State licenseBody: string = '';
  @State granularity: string = GRANULARITY_OFF;
  @State saves: SaveEntry[] = [];
  @State saveGroups: SaveGroup[] = [];
  registerBack: (fn: () => boolean) => void = () => {};

  handleBack(): boolean {
    if (this.showMultiAsk) { this.stopPermHold(); this.showMultiAsk = false; return true; }
    if (this.multiMode) { this.exitMulti(); return true; }
    if (this.showDeleteAsk) { this.stopPermHold(); this.showDeleteAsk = false; return true; }
    if (this.showVaultClearAsk) { this.showVaultClearAsk = false; return true; }
    if (this.showGameDeleteAsk) { this.showGameDeleteAsk = false; return true; }
    if (this.importOpen) { this.importOpen = false; return true; }
    if (this.transferOp !== '') { this.transferOp = ''; this.transferNote = ''; return true; }
    if (this.isolationConfirm !== '') { this.isolationConfirm = ''; return true; }
    if (this.showIsolationAsk) {
      this.showIsolationAsk = false;
      this.pendingGranularity = '';
      this.isolationConfirm = '';
      return true;
    }
    if (this.launchFault !== '' && !this.faultAck) { this.faultAck = true; return true; }
    if (this.showAbout) { this.showAbout = false; return true; }
    if (this.showLicenses) { this.showLicenses = false; this.licenseSel = ''; this.licenseBody = ''; return true; }
    if (this.showVault) { this.closeVault(); return true; }
    if (this.panelOpen) { this.panelOpen = false; return true; }
    return false;
  }

  @State @Watch('onSaveSelected') selectedSave: string = '';
  @State savesDirShown: string = '';
  @State savesView: string = SAVES_VIEW_SAVE;
  @State @Watch('onVersionSelected') selectedVersion: string = '';
  @State versions: VersionEntry[] = [];
  @State versionSaves: SaveEntry[] = [];
  @State showVault: boolean = false;
  @State showVaultClearAsk: boolean = false;
  @State showGameDeleteAsk: boolean = false;
  @State showIsolationDetail: boolean = false;
  @State staleIgnored: boolean = false;
  @State gameDeletePath: string = '';
  @State gameDeleteLabel: string = '';
  @State gameDeleteDir: string = '';
  @State gamesNote: string = '';
  @State vaultEntries: VaultEntry[] = [];
  @State vaultDays: number = 7;
  @State vaultNote: string = '';
  @State showDeleteAsk: boolean = false;
  @State permHold: number = 0;
  private permTimer: number = -1;
  @State vaultPurgedLast: number = 0;
  @State transferOp: string = '';
  @State transferNote: string = '';
  @State transferPicked: string[] = [];
  @State transferTargetCounts: Map<string, number> = new Map<string, number>();
  @State importOpen: boolean = false;
  @State importRoot: string = '';
  @State importPicked: string[] = [];
  @State importNote: string = '';
  @State importLiveDir: string = '';
  @State importLiveHasData: boolean = false;
  @State importLiveCount: number = 0;
  @State importMsg: string = '';
  @State importToast: string = '';
  @State exportMsg: string = '';
  @State selMetaRows: MetaRow[] = [];
  @State selMetaNote: string = '';
  @State showIsolationAsk: boolean = false;
  @State pendingGranularity: string = '';
  @State staleCopyNote: string = '';
  @State multiMode: boolean = false;
  @State multiPicked: string[] = [];
  @State showMultiAsk: boolean = false;
  @State multiListOpen: boolean = false;
  @State savesNote: string = '';
  @State copyTargets: CopyTarget[] = [];
  @State copyPicked: string[] = [];
  @State isolationNote: string = '';
  @State pendingPreview: string = '';
  @State granularityHintText: string = '';
  @State pendingHint: string = '';
  @State pendingUsesBundled: boolean = false;
  @State pendingVersionName: string = '';
  @State isolationStale: boolean = false;
  @State isolationCounts: GameDataCounts = { sectorSaves: 0, manualSaves: 0, mods: 0, schematics: 0 };
  @State isolationConfirm: string = '';
  @State isRefreshing: boolean = false;
  @State bundledVer: string = '';
  @State hasBundled: boolean = false;
  @State jarDirHuman: string = '';
  private appName: string = '';
  @State appVersion: string = '';
  launchFault: string = '';

/* 底部页签换成 HdsTabs 之后，不再需要 canFloat 和 barMaterial。控制器必须配套使用 HdsTabsController。 */
  private tabController: HdsTabsController = new HdsTabsController();

  aboutToAppear(): void {
    this.launchMode = readLaunchMode(this.filesDir);
    this.granularity = readGranularity(this.filesDir);
    this.appName = this.resolveAppLabel();
    /* 异形屏避让异步处理，不阻塞初始化流程。 */
    this.initSafeArea();
    this.registerBack(() => this.handleBack());
    this.refresh();
  }

  /** 将生效的避让边翻译成中文，使用 effectiveEdges() 而不是 detectedEdges。 */
  private edgeNames(): string {
    const n: string[] = [];
    for (const e of this.effectiveEdges()) {
      n.push(e === 'top' ? '上' : (e === 'bottom' ? '下' : (e === 'left' ? '左' : '右')));
    }
    return n.join('/');
  }

/* 某条边最终避让的 vp 值。规则：避让量为 0 时四边都不让；探测无命中时只让上边；其余让命中边。 */
  private edgeVp(edge: string): number {
    if (this.safeVp <= 0) {
      return 0;
    }
    if (this.detectedEdges.length === 0) {
      return edge === 'top' ? this.safeVp : 0;
    }
    return this.detectedEdges.indexOf(edge) >= 0 ? this.safeVp : 0;
  }

  /* 异形屏避让初始化。玩家已设置则完全采用其值，否则用探测值播种。判断条件基于文件是否存在。 */
/* 将存储位置与自动适配信息写入诊断文件。仅在内容变化时写入，避免频繁写文件。 */
  private dumpStorageDiagnostics(): void {
    const dump: string = readStorageMode(this.filesDir) + '|' + this.storageUsed + '|'
                       + this.storageUsedReason + '|' + String(this.isolationStale)
                       + '|' + String(this.safeDetected) + '|' + String(this.gameAuto)
                       + '|' + String(this.gameEdge) + '|' + String(this.detectedSafeVp);
    if (dump === this.storageDumped) {
      return;
    }
    const dirs: string = dumpDataDirs(this.filesDir);
    const extra: string = 'autofit=on:' + (this.gameAuto ? '1' : '0')
                        + ' detected:' + String(this.safeDetected)
                        + ' insetVp:' + String(this.detectedSafeVp)
                        + ' density:' + String(displayDensity())
                        + ' edge:' + String(this.gameEdge) + NL;
    if (dumpStorageState(this.filesDir, this.storageIntent, this.storageUsed,
                                  this.storageUsedReason, this.isolationStale, extra, dirs)) {
      this.storageDumped = dump;
    }
  }

/* 系统字体缩放值，默认返回 1。 */
  private systemFontScale(): number {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
/* 按当前配置，此处读取值恒为 1，因未声明 configuration 标签。 */
      const v: number | undefined = ctx.config.fontSizeScale;
      if (v !== undefined && v > 0 && v <= 10 && Number.isFinite(v)) {
        return v;
      }
      return 1;
    } catch (e) {
      return 1;
    }
  }

/* 根据设备参数计算避让值并直接采用。探测未完成或无挖孔时返回 false，不修改现有值。 */
  private seedGameEdgeFromDevice(): boolean {
    if (!this.safeDetected) {
      return false;
    }
    const density: number = displayDensity();
    const insetPx: number = Math.round(this.detectedSafeVp * density);
    const v: number = autoEdgePadding(insetPx, density, this.gameScale);
    if (v <= 0) {
      return false;
    }
    this.gameEdge = v;
    return true;
  }

  private async initSafeArea(): Promise<void> {
    let ins: SafeInsets = { top: 0, right: 0, bottom: 0, left: 0 };
    try {
      ins = await detectInsets(getContext(this) as common.Context);
    } catch (e) {
    }
    this.detectedSafeVp = uniformOf(ins);
    this.detectedEdges = edgesOf(ins);

/* 自动/手动判定。若为 auto 且玩家未动过滑条，则每次启动重新采用探测结果。 */
    const pref: SafePref = readSafePref(this.filesDir);
    this.safeAuto = pref.auto;
    this.safeVp = pref.auto ? this.detectedSafeVp : pref.vp;

    writeSafePref(this.filesDir, this.safeAuto, this.safeVp);

    dumpSafeArea('\n--- prefs ---\nauto=' + this.safeAuto
                 + '  applied=' + this.safeVp + ' vp\nfile='
                 + (pref.auto ? 'auto' : 'user') + ' ' + pref.vp
                 + '\napplied edges=' + JSON.stringify(this.effectiveEdges()) + '\n', true);
    hilog.info(DOMAIN, TAG,
               'safearea: auto=%{public}s applied=%{public}d vp (detected %{public}d)',
               String(this.safeAuto), this.safeVp, this.detectedSafeVp);

    this.safeDetected = true;
    if (this.gameAuto && !this.gameEdgeSet) {
      this.seedGameEdgeFromDevice();
    }
    this.applyGameDisplayNow();
    this.dumpStorageDiagnostics();
  }

  /** 滑条实际作用边：探测为空时仅上边。 */
  private effectiveEdges(): string[] {
    return this.detectedEdges.length === 0 ? ['top'] : this.detectedEdges;
  }

  /* ====================================================================
   * 版本隔离
   * ==================================================================== */

  /** 返回某一档的名称，与设置页药丸名称保持一致。 */
  private granularityName(g: string): string {
    if (g === GRANULARITY_NUMBER) {
      return '按大版本';
    }
    if (g === GRANULARITY_BUILD) {
      return '按构建号';
    }
    if (g === GRANULARITY_PATCH) {
      return '按小版本';
    }
    return '不隔离';
  }

/* 按当前档位键分组已安装版本，用于说明文字。不在渲染路径中调用。 */
  private isolationGroups(g: string): IsoGroup[] {
    const out: IsoGroup[] = [];
    const at: Map<string, number> = new Map<string, number>();
    for (const v of this.versions) {
      const key: string = resolveGameDirAndKey(g, v.source, v.path, this.bundledJar()).key;
      const k: string = key === '' ? '（不隔离）' : key;
      const nm: string = (v.version === '' ? v.label : v.version)
                       + (v.source === 'bundled' ? '（内置）' : '');
      const i: number | undefined = at.get(k);
      if (i === undefined) {
        at.set(k, out.length);
        out.push({ key: k, versions: [nm] });
      } else {
        out[at.get(k) as number].versions.push(nm);
      }
    }
    return out;
  }

/* 键对应的版本槽位字符串；非槽位返回空串。基于形状判断（n/b 后跟数字）。 */
  private slotOfKey(key: string): string {
    return /^[nb][0-9]/.test(key) ? key.substring(1) : '';
  }

/* 内置版本在当前档位下应属的槽位键（不改变其实际使用 bundled）。不在渲染路径上。 */
  private bundledSlotKey(g: string): string {
    const p: string = bundledGamePath(this.bundleCodeDir);
    if (p === '') {
      return '';
    }
    return granularityKey(g, gameVersionParts(p));
  }

  /** 槽位键的显示文本：n8 → v8，b160 → b160。非槽位返回空串。 */
  private slotLabel(key: string): string {
    if (key === '' || key === KEY_UNKNOWN) {
      return '';
    }
    return key.charAt(0) === 'n' ? ('v' + key.substring(1)) : key;
  }

  /** 组标题显示文本。bundled/_unknown 特殊处理。 */
  private isoGroupTitle(g: string, key: string): string {
    if (key === 'bundled') {
      const sub: string = this.slotLabel(this.bundledSlotKey(g));
      return sub === '' ? '内置游戏' : ('内置游戏（' + sub + '）');
    }
    if (key === '_unknown') {
      return '未知版本';
    }
    const slot: string = this.slotOfKey(key);
    if (slot === '') {
      return key;
    }
    return key.charAt(0) === 'n' ? ('v' + slot + ' 系列') : (slot + ' 版本');
  }

  /* 说明行，内容来自 isolationGroups() 并动态生成。 */
  private granularityHint(g: string): string {
    if (g === GRANULARITY_OFF) {
      return '所有版本共用一份数据（默认）';
    }
    const groups: IsoGroup[] = this.isolationGroups(g);
    if (groups.length === 0) {
      return '';
    }
    if (g === GRANULARITY_PATCH) {
      return '每个版本各一份';
    }
    const slots: string[] = [];
    for (const gr of groups) {
      const s: string = this.slotOfKey(gr.key);
      if (s !== '' && slots.indexOf(s) < 0) {
        slots.push(s);
      }
    }
    if (slots.length === 0) {
      return g === GRANULARITY_NUMBER ? '同一个大版本共用一份' : '同一构建号的版本共用一份';
    }
    const parts: string[] = [];
    const cap: number = Math.min(slots.length, 2);
    for (let i = 0; i < cap; i += 1) {
      if (g === GRANULARITY_NUMBER) {
        parts.push('v' + slots[i] + ' 的所有版本共用一份');
      } else {
        parts.push('同一 ' + slots[i] + ' 的版本共用一份');
      }
    }
    if (slots.length > 2) {
      parts.push('其余同理');
    }
    return parts.join('；');
  }

  /* 玩家选择某一档。关掉直接执行，打开时先询问。 */
  private chooseGranularity(g: string): void {
    if (g === this.granularity) {
      return;
    }
    if (g === GRANULARITY_OFF) {
      this.granularity = g;
      writeGranularity(this.filesDir, g);
      this.isolationNote = '';
      this.refresh();
      return;
    }
    this.pendingGranularity = g;
    this.isolationCounts = countsOf(liveGameDataDir());
    this.pendingPreview = this.buildGranularityPreview(g);
    this.pendingHint = this.granularityHint(g);
    this.showIsolationDetail = false;
    this.copyTargets = this.buildCopyTargets(g);
    this.copyPicked = this.copyTargets.map((c: CopyTarget) => c.key);
    this.pendingUsesBundled = this.versions.some((v: VersionEntry) => v.source === 'bundled');
    const res: GameResolution = this.resolution;
    const hit: VersionEntry | undefined =
      this.versions.find((v: VersionEntry) => v.path === res.path);
    if (hit === undefined) {
      this.pendingVersionName = '（当前没有可用的游戏版本）';
    } else {
      this.pendingVersionName = hit.label + (hit.version === '' ? '' : ('  ·  ' + hit.version));
    }
    this.showIsolationAsk = true;
  }

  /* 按当前档位列出每个已装版本应属的目录。不在渲染路径上。 */
  private buildGranularityPreview(g: string): string {
    const groups: IsoGroup[] = this.isolationGroups(g);
    if (groups.length === 0) {
      return '（现在还没有可用的游戏版本）';
    }
    const lines: string[] = [];
    for (const gr of groups) {
      /* 小版本档不出标题，其余档显示组标题。 */
      if (g !== GRANULARITY_PATCH) {
        lines.push(this.isoGroupTitle(g, gr.key));
      }
      for (const nm of gr.versions) {
        lines.push('    ' + nm + '   →   ' + gr.key);
      }
    }
    return lines.join('\n');
  }

  private applyIsolationCopy(): void {
    const g: string = this.pendingGranularity;
    const res: GameResolution = resolveGame(this.filesDir, this.bundleCodeDir);
    const key: string = resolveGameDirAndKey(g, res.source, res.path, this.bundledJar()).key;
    if (key === '') {
      this.isolationNote = '现在没有可加载的游戏，先选一个游戏版本再开隔离';
      this.showIsolationAsk = false;
      this.pendingGranularity = '';
      return;
    }
    const note: string = copyLiveDataInto(key);
    if (note !== '') {
      this.isolationNote = note + '。隔离没有打开，你的数据还在原来的位置。';
      this.showIsolationAsk = false;
      this.pendingGranularity = '';
      this.refresh();
      return;
    }
    const extraFails: string[] = [];
    for (const c of this.copyTargets) {
      if (this.copyPicked.indexOf(c.key) < 0 || c.key === key || c.hasData) {
        continue;
      }
      const e: string = copyLiveDataInto(c.key);
      if (e !== '') {
        extraFails.push(c.key + '：' + e);
      }
    }
    this.granularity = g;
    writeGranularity(this.filesDir, g);
    this.isolationNote = extraFails.length > 0
      ? ('隔离已经打开，但有几个版本没能拿到这份数据：' + NL + extraFails.join(NL))
      : '';
    this.showIsolationAsk = false;
    this.pendingGranularity = '';
    this.copyTargets = [];
    this.copyPicked = [];
    this.refresh();
  }

  private applyIsolationEmpty(): void {
    this.granularity = this.pendingGranularity;
    writeGranularity(this.filesDir, this.granularity);
    this.isolationNote = '';
    this.showIsolationAsk = false;
    this.pendingGranularity = '';
    this.refresh();
  }

  private copyStaleCurrent(): void {
    if (this.storageBusy) {
      return;
    }
    this.staleCopyNote = '';
    const res: GameResolution = resolveGame(this.filesDir, this.bundleCodeDir);
    const key: string = resolveGameDirAndKey(this.granularity, res.source, res.path,
                                             this.bundledJar()).key;
    if (key === '') {
      this.staleCopyNote = '现在没有开启隔离，没有可以复制进去的分类';
      this.refresh();
      return;
    }
    this.storageBusy = true;
    setTimeout(() => {
      const note: string = copyLiveDataInto(key);
      this.storageBusy = false;
      if (note !== '') {
        this.staleCopyNote = note;
      } else {
        this.isolationNote = '已经把数据复制进这一档（' + key + '）。';
      }
      this.refresh();
    }, 50);
  }

  @Builder
  StaleCopyOffer() {
    Column() {
      Text('开启隔离后，数据未迁移到当前版本')
        .fontSize(14).fontColor($r('sys.color.font_primary'))
        .width('100%')
      if (this.staleCopyNote !== '') {
        Text(this.staleCopyNote)
          .fontSize(12).fontColor($r('sys.color.warning'))
          .width('100%').margin({ top: 6 })
      }
      Row() {
        Button('复制过去')
          .fontSize(14)
          .height(34)
          .padding({ left: 18, right: 18 })
          .enabled(!this.storageBusy)
          .onClick(() => { this.copyStaleCurrent(); })
        Button('忽略')
          .fontSize(14)
          .height(34)
          .padding({ left: 18, right: 18 })
          .fontColor($r('sys.color.font_secondary'))
          .backgroundColor($r('app.color.launcher_card'))
          .margin({ left: 8 })
          .enabled(!this.storageBusy)
          .onClick(() => { this.staleIgnored = true; })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
      .margin({ top: 10 })
    }
    .width('100%')
    .padding(14)
    .borderRadius(CARD_RADIUS_VP)
    .backgroundColor($r('app.color.launcher_bg'))
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: 16 })
  }

  onFolderSettled(): void {
    if (this.folderSettled) {
      this.refresh();
    }
  }

  private resolveAppLabel(): string {
    return appLabel(getContext(this) as common.Context);
  }

  private dialogWidthVp(): number {
    return Math.max(DIALOG_MIN_VP, this.winW * DIALOG_WIDTH_FRACTION);
  }

  private tabItem(symbol: Resource, label: string): BottomTabBarStyle {
    const marks: TabBarSymbol = {
      normal: new SymbolGlyphModifier(symbol).fontColor([$r('sys.color.font_secondary')]),
      selected: new SymbolGlyphModifier(symbol).fontColor([$r('sys.color.brand')]),
    };
    return new BottomTabBarStyle(marks, label);
  }

  private bundledJar(): string {
    return bundledGamePath(this.bundleCodeDir);
  }

  private applyColorMode(): void {
    const mode: ConfigurationConstant.ColorMode = this.darkFollow
      ? ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET
      : (this.darkOn ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
                     : ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
    const ctx: common.UIAbilityContext | undefined =
      this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (ctx === undefined) {
      hilog.warn(DOMAIN, TAG, 'appearance: no ability context yet -- color mode not applied');
      return;
    }
    try {
      ctx.getApplicationContext().setColorMode(mode);
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'appearance: setColorMode(%{public}d) failed (%{public}s)',
                 mode, err.message);
    }
  }

  private syncStorageToggle(): void {
    this.storageToggleOn = (this.storageIntent === STORAGE_MODE_EXTERNAL);
  }

  private askStorageSwitch(on: boolean): void {
    if (on === (this.storageIntent === STORAGE_MODE_EXTERNAL)) {
      this.syncStorageToggle();
      return;
    }
    this.storageToggleOn = on;
    if (on) {
      const p: string = probeExternalRoot(this.filesDir);
      if (!p.startsWith('ok')) {
        this.storageNote = '外置不可用：' + p;
        this.syncStorageToggle();
        return;
      }
    }
    this.storageNote = '';
    const from: string = gameDataRoot(this.filesDir);
    const to: string = gameDataRootFor(this.filesDir,
                                       on ? STORAGE_MODE_EXTERNAL : STORAGE_MODE_SANDBOX);
    this.storageBusy = true;
    setTimeout(() => {
      const out: MigrateOutcome = migrateGameData(from, to);
      this.storageBusy = false;
      if (out.error !== '') {
        this.storageNote = out.error;
        this.syncStorageToggle();
        return;
      }
      writeStorageMode(this.filesDir, on ? STORAGE_MODE_EXTERNAL : STORAGE_MODE_SANDBOX);
      this.refresh();
      if (out.warning !== '') {
        this.storageNote = out.warning;
      }
    }, 50);
  }

  /* ⚠️ 拨完开关就写桥，否则启动时仍是旧值。异常忽略。 */
  /* 松手时保存显示偏好并立刻写入游戏 settings.bin。 */
  private saveGameDisplay(): void {
/* 不更新 edgeSet/scaleSet 标志，只存当前值。 */
    const p: GameDisplayPref = { edge: this.gameEdge, scale: this.gameScale,
                            auto: this.gameAuto,
                            edgeSet: this.gameEdgeSet, scaleSet: this.gameScaleSet };
    writeGameDisplay(this.filesDir, p);
    this.gameDisplayTried = '';        /* 值变了 ⇒ 让下面那个缓存失效，立刻重算一次 */
    this.applyGameDisplayNow();
  }

  /* 将当前显示偏好写入游戏 settings.bin（用 resolveGameDataDir 计算目录）。 */
  private applyGameDisplayNow(): void {
    const dataDir: string = resolveGameDataDir(this.granularity, this.resolution.source,
                                              this.resolution.path, this.bundledJar());
    /* 只有一个避让值 gameEdge，自动模式也写入同一变量。 */
    const pref: GameDisplayPref = { edge: this.gameEdge, scale: this.gameScale,
                                   auto: this.gameAuto,
                                   edgeSet: this.gameEdgeSet, scaleSet: this.gameScaleSet };
    /* 缓存键包含 dataDir，切换版本时重新写入。 */
    const key: string = dataDir + '|' + String(pref.edge) + '|' + String(pref.scale);
    if (key === this.gameDisplayTried) {
      return;
    }
    this.gameDisplayTried = key;
    const note: string = applyGameDisplay(dataDir, this.filesDir, pref,
                                          readAppliedGameDisplay(this.filesDir));
    /* 仅出错时显示提示。 */
    if (note !== this.gameDisplayNote) {
      this.gameDisplayNote = note;
    }
  }

  private rewriteBridge(): void {
    try {
      const k: GameDirForKey = resolveGameDirAndKey(this.granularity, this.resolution.source,
                                                    this.resolution.path, this.bundledJar());
      writeIsolationBridge(this.filesDir, this.granularity, k.key);
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'bridge: rewriting it after a settings change failed (%{public}s)',
                 err.message);
    }
  }

  private refresh(): void {
/* 首先设置游戏数据根（必须在 resolveGameDataDir 之前）。 */
    setGameDataRoot(gameDataRoot(this.filesDir));
    /* 确保根目录存在，失败不阻塞。 */
    ensureGameDataRoot(this.filesDir);

    ensureGameJarDir(this.filesDir);
    this.games = listGameJars(this.filesDir);
    this.selected = readSelection(this.filesDir);
    this.resolution = resolveGame(this.filesDir, this.bundleCodeDir);
    this.bundledVer = bundledGameVersion(this.bundleCodeDir);
    this.hasBundled = hasBundledGame(this.bundleCodeDir);

    /* 读取并应用外观偏好，仅值变化时更新状态。 */
    const ap: AppearancePref = readAppearance(this.filesDir);
    if (ap.follow !== this.darkFollow) { this.darkFollow = ap.follow; }
    if (ap.dark !== this.darkOn) { this.darkOn = ap.dark; }
    this.applyColorMode();

    /* 读取存储位置意图和实际值，仅变化时落盘。 */
    this.storageIntent = readStorageMode(this.filesDir);
    /* 同步开关与意图，同时初始化进页面和切换成功后。 */
    this.syncStorageToggle();
    this.storageUsed = usedUserHome();
    this.storageUsedReason = usedUserHomeReason();

    /* 存档目录取决于隔离状态，使用同一套输入。 */
    const dataDir: string = resolveGameDataDir(this.granularity, this.resolution.source,
                                              this.resolution.path, this.bundledJar());
    const dir: string = dataDir + '/saves';
    this.savesDirShown = dir;
    this.saves = listSaves(dir);

/* 游戏语言：只需读偏好 */
    this.gameLocaleFollow = readGameLocaleFollow(this.filesDir);
    /* 游戏内显示：读偏好后落进游戏，必须在 dataDir 解出之后 */
    {
      const gd: GameDisplayPref = readGameDisplay(this.filesDir);
      if (gd.edge !== this.gameEdge) { this.gameEdge = gd.edge; }
      /* 缩放：设过用他的，否则走 systemGameScale 取初始值，不置 gameScaleSet */
      const wantScale: number = gd.scaleSet ? gd.scale : systemGameScale(this.systemFontScale());
      if (wantScale !== this.gameScale) { this.gameScale = wantScale; }
      if (gd.auto !== this.gameAuto) { this.gameAuto = gd.auto; }
      this.gameEdgeSet = gd.edgeSet;
      this.gameScaleSet = gd.scaleSet;

/* 显示以游戏实际值为准，修复外部数值未同步问题。读不到则原值不动 */
      const actual: GameDisplayValues | null = readGameDisplayValues(dataDir);
      const applied: GameDisplayPref | null = readAppliedGameDisplay(this.filesDir);
      if (actual !== null) {
        /* 判是否玩家自己改的：与 applyGameDisplay 三态判据一致 */
        const edgeIsYours: boolean = (actual.edge !== GAME_EDGE_FACTORY
            && (applied === null || actual.edge !== applied.edge));
        const scaleIsYours: boolean = (actual.scale !== GAME_SCALE_FACTORY
            && (applied === null || actual.scale !== applied.scale));

/* 回显只在玩家自己设的时进行，避免抹掉要写入的值（2026-10-05回归修复） */
        if (edgeIsYours) {
          if (actual.edge !== this.gameEdge) { this.gameEdge = actual.edge; }
          this.gameEdgeSet = true;
        }
        if (scaleIsYours) {
          if (actual.scale !== this.gameScale) { this.gameScale = actual.scale; }
          this.gameScaleSet = true;
        }
      }
      /* 自动开着且玩家没自己设避让时按本机算，避免每次 refresh 重算抹掉微调 */
      if (this.gameAuto && !this.gameEdgeSet) {
        this.seedGameEdgeFromDevice();
      }
/* 挖孔探测未完成时不可写 0，探测完成会自行再调 */
      if (!(this.gameAuto && !this.gameEdgeSet && !this.safeDetected)) {
        this.applyGameDisplayNow();
      }
    }

/* 隔离状态判定：隔离开着，蓝图/自制地图只在未隔离树中 */
    this.isolationStale = (this.granularity !== GRANULARITY_OFF)
                       && !hasUserMadeFiles(dataDir)
                       && hasUserMadeFiles(liveGameDataDir());
    /* 存储诊断落盘，排在 stale 之后，因为 hilog 读不到 */
    this.dumpStorageDiagnostics();

    /* 异常时记日志，正常时复位忽略和错误提示 */
    if (this.isolationStale) {
      hilog.error(DOMAIN, TAG, 'isolation: STALE -- %{public}s has no player data, '
                + 'but the un-isolated tree %{public}s does',
                dataDir, liveGameDataDir());
    } else {
      this.staleIgnored = false;
      this.staleCopyNote = '';
    }
    /* 版本列表在 resolution/hasBundled/games 算好后建，每轮 refresh 只建一次 */
    this.versions = this.buildVersions();
/* 设置页说明必须位于 this.versions 之后，保证用当前版本列表 */
    this.granularityHintText = this.granularityHint(readGranularity(this.filesDir));
    /* 选中版本不存在时退回当前版本 */
    if (this.selectedVersion === ''
        || !this.versions.some((v: VersionEntry) => v.path === this.selectedVersion)) {
      const cur: VersionEntry | undefined = this.versions.find((v: VersionEntry) => v.isCurrent);
      this.selectedVersion = cur === undefined ? '' : cur.path;
    }
    this.loadVersionSaves();
    /* 回收站清掉到期项 */
    this.reloadVault();
    this.vaultDays = readVaultDays(this.filesDir);
    /* 按存档视图数据源 */
    this.saveGroups = this.buildSaveGroups();
    /* 清失效的选中行 */
    if (this.selectedSave !== '' && this.selectedSaveRow() === undefined) {
      this.selectedSave = '';
    }
    /* 显式读元数据，处理 id 未变但存档实际已换的情况 */
    this.loadSelectedMeta();
    this.jarDirHint = gameJarDir(this.filesDir);
    /* 父文件夹名为 Download（单数），避免写复数误导 */
    this.jarDirHuman = this.jarDirHint === '' ? '' : ('Download/' + this.appName + '/games');
    hilog.info(DOMAIN, TAG, 'launcher: %{public}d jar(s), resolved=%{public}s (%{public}s)',
               this.games.length, this.resolution.path === '' ? '(none)' : this.resolution.path,
               this.resolution.source);
  }

  /** 选中存档行，无则 undefined。 */
  private selectedSaveRow(): SaveRow | undefined {
    if (this.selectedSave === '') {
      return undefined;
    }
    const cut: number = this.selectedSave.indexOf('|');
    if (cut < 0) {
      return undefined;
    }
    const dir: string = this.selectedSave.substring(0, cut);
    const id: string = this.selectedSave.substring(cut + 1);
    const g: SaveGroup | undefined = this.saveGroups.find((x: SaveGroup) => x.dir === dir);
    if (g === undefined) {
      return undefined;
    }
    const e: SaveEntry | undefined = g.saves.find((s: SaveEntry) => s.id === id);
    return e === undefined ? undefined : { dir: dir, entry: e };
  }

  private selectedSaveEntry(): SaveEntry | undefined {
    const r: SaveRow | undefined = this.selectedSaveRow();
    return r === undefined ? undefined : r.entry;
  }

  /** 选中存档所在目录。 */
  private selectedSaveDir(): string {
    const r: SaveRow | undefined = this.selectedSaveRow();
    return r === undefined ? '' : r.dir;
  }

  /** 存档列表一行选中键。 */
  private saveKey(dir: string, id: string): string {
    return dir + '|' + id;
  }

  /** 选中存档所属版本。 */
  private selectedSaveVersions(): VersionEntry[] {
    const r: SaveRow | undefined = this.selectedSaveRow();
    if (r === undefined) {
      return [];
    }
    const g: SaveGroup | undefined = this.saveGroups.find((x: SaveGroup) => x.dir === r.dir);
    return g === undefined ? [] : g.versions;
  }

  /** 选中存档显示名。 */
  private selectedSaveLabel(): string {
    const sv: SaveEntry | undefined = this.selectedSaveEntry();
    return sv === undefined ? '' : sv.label;
  }

  /** 格式化的摘要：区块数、文件数、大小。 */
  private selectedSaveSummary(): string {
    const sv: SaveEntry | undefined = this.selectedSaveEntry();
    if (sv === undefined) {
      return '';
    }
    const parts: string[] = [];
    if (sv.kind === 'sector') {
      parts.push(String(sv.sectors) + ' 个区块');
    }
    parts.push(String(sv.files.length) + ' 个文件');
    parts.push(formatSaveSize(sv.bytes));
    return parts.join(' · ');
  }

  /** 最后更新时间。 */
  private selectedSaveUpdated(): string {
    const sv: SaveEntry | undefined = this.selectedSaveEntry();
    return sv === undefined ? '' : ('最后更新 ' + formatSaveDate(sv.mtime));
  }

  /** 上次读取元数据的存档标识，用于去重。 */
  private metaLoadedKey: string = '';

  /** 选中变化时读取存档元数据。 */
  private onSaveSelected(): void {
    this.loadSelectedMeta();
  }

  /* ==================================================================
   * 「按版本」视图
   * ================================================================== */

  /** 构造版本项（会读 jar，只在 buildVersions 中调用）。 */
  private versionEntryOf(path: string, source: string,
                         label: string, version: string): VersionEntry {
    const rk: GameDirForKey = resolveGameDirAndKey(this.granularity, source, path, this.bundledJar());
    return {
      path: path,
      source: source,
      label: label,
      version: version,
      key: rk.key,
      dataDir: rk.dir,
      isCurrent: false,
      saveCount: 0,
      hasData: false,
    };
  }

  /** 列出已装版本（内置优先），按数据目录去重计数。 */
  private buildVersions(): VersionEntry[] {
    const out: VersionEntry[] = [];
    if (this.hasBundled) {
      out.push(this.versionEntryOf(bundledGamePath(this.bundleCodeDir), 'bundled',
                                   '内置游戏', this.bundledVer));
    }
    for (const g of this.games) {
      out.push(this.versionEntryOf(g.path, 'user', g.name, g.version));
    }
    for (const v of out) {
      v.isCurrent = (v.source === this.resolution.source && v.path === this.resolution.path);
    }

    const counted: Map<string, number> = new Map<string, number>();
    for (const v of out) {
      let n: number | undefined = counted.get(v.dataDir);
      if (n === undefined) {
        n = listSaves(v.dataDir + '/saves').length;
        counted.set(v.dataDir, n);
      }
      v.saveCount = n;
      v.hasData = gameDataExists(v.dataDir);
      hilog.info(DOMAIN, TAG, 'version: %{public}s | %{public}s | key=%{public}s | %{public}s',
                 v.label, v.version === '' ? '(unknown)' : v.version, v.key, v.dataDir);
    }
    hilog.info(DOMAIN, TAG, 'saves: %{public}d version(s), %{public}d distinct data dir(s)',
               out.length, counted.size);
    return out;
  }

/** 按数据目录分组，用于「按存档」视图。未隔离的独立数据也一并列出。 */
  private buildSaveGroups(): SaveGroup[] {
    const out: SaveGroup[] = [];
    const byDir: Map<string, SaveGroup> = new Map<string, SaveGroup>();
    for (const v of this.versions) {
      const dir: string = v.dataDir + '/saves';
      let g: SaveGroup | undefined = byDir.get(dir);
      if (g === undefined) {
        g = { dir: dir, versions: [], saves: listSaves(dir), orphanKey: '' };
        byDir.set(dir, g);
        out.push(g);
      }
      g.versions.push(v);
    }
    const liveDir: string = liveGameDataDir();
    const live: string = liveDir + '/saves';
    if (byDir.get(live) === undefined && gameDataExists(liveDir)) {
      const only: SaveGroup = { dir: live, versions: [], saves: listSaves(live), orphanKey: '' };
      if (only.saves.length > 0) {
        out.push(only);
      }
    }
    /* 列出 instances/ 下没有版本读但仍有存档的目录 */
    for (const k of listInstanceKeys()) {
      const d: string = isolatedGameDataDir(k);
      if (byDir.get(d + '/saves') !== undefined) {
        continue;
      }
      const saves: SaveEntry[] = listSaves(d + '/saves');
      if (saves.length === 0) {
        continue;
      }
      out.push({ dir: d + '/saves', versions: [], saves: saves, orphanKey: k });
      hilog.warn(DOMAIN, TAG, 'save group: %{public}s has %{public}d save(s) but no version reads it',
                 k, saves.length);
    }
    for (const g of out) {
      hilog.info(DOMAIN, TAG, 'save group: %{public}d save(s), %{public}d version(s), %{public}s',
                 g.saves.length, g.versions.length, g.dir);
    }
    return out;
  }

/** 组标题：版本号（去重） + 文件标签 */
  private groupTitle(g: SaveGroup): string {
    if (g.versions.length === 0) {
    return g.orphanKey === ''
      ? '未隔离的那一份'
      : ('没有版本读它（内部键 ' + g.orphanKey + '）');
    }
    const vers: string[] = [];
    const names: string[] = [];
    for (const v of g.versions) {
      const s: string = v.version === '' ? '未知版本' : v.version;
      if (vers.indexOf(s) < 0) {
        vers.push(s);
      }
      names.push(v.label);
    }
    return vers.join(' / ') + '（' + names.join(', ') + '）';
  }

  /** 组副标题：当前版本标记 + 共享版本数 */
  private groupSub(g: SaveGroup): string {
    if (g.versions.length === 0) {
      if (g.orphanKey !== '') {
        return '这是以前某一档隔离留下的数据，现在没有版本指向它了 —— '
             + '要接着玩，就从某一组里复制/移动一份过去（或者在「按版本」那边看看谁和它同版本）';
      }
      return '现在没有版本读它 —— 这是你数据最初的那一份，「复制过去」不会动它';
    }
    const cur: boolean = g.versions.some((v: VersionEntry) => v.isCurrent);
    const head: string = cur ? '当前版本在用 · ' : '';
    if (g.versions.length === 1) {
      return head + '只有这个版本读它';
    }
    return head + String(g.versions.length) + ' 个版本共用同一份数据';
  }

/* 存档行的键：唯一标识，包含可变字段以触发刷新。 */
  private saveRowKey(sv: SaveEntry): string {
    return sv.id + '|' + sv.label + '|' + sv.kind + '|' + String(sv.sectors)
         + '|' + String(sv.bytes) + '|' + String(sv.mtime);
  }

  /* 游戏行键，同理。 */
  private gameRowKey(g: GameJar): string {
    return g.path + '|' + g.name + '|' + g.version + '|' + String(g.size) + '|' + String(g.mtime);
  }

/* 按存档分组的外层键，覆盖子项内容。 */
  private groupKey(g: SaveGroup): string {
    const ids: string[] = [];
    for (const s of g.saves) {
      ids.push(this.saveRowKey(s));
    }
    return g.dir + '|' + this.groupTitle(g) + '|' + this.groupSub(g) + '|' + ids.join(',');
  }

  /* 按版本列表的键，包含 saveCount 以刷新。 */
  private versionRowKey(v: VersionEntry): string {
    return v.path + '|' + v.label + '|' + this.versionSavesLine(v);
  }

  /** 当前选中的版本项，不存在时返回 undefined。 */
  private selectedVersionEntry(): VersionEntry | undefined {
    if (this.selectedVersion === '') {
      return undefined;
    }
    return this.versions.find((v: VersionEntry) => v.path === this.selectedVersion);
  }

/* 读取选中版本的存档列表（不解压）。 */
  private loadVersionSaves(): void {
    const v: VersionEntry | undefined = this.selectedVersionEntry();
    if (v === undefined) {
      this.versionSaves = [];
      return;
    }
    this.versionSaves = listSaves(v.dataDir + '/saves');
  }

  /** @Watch 回调：切换版本时刷新存档列表。 */
  private onVersionSelected(): void {
    this.loadVersionSaves();
  }

  /** 与指定目录共享数据且除自身外的版本列表。 */
  private versionsSharingDir(dir: string, exceptPath: string): VersionEntry[] {
    return this.versions.filter((v: VersionEntry) =>
      v.dataDir === dir && v.path !== exceptPath);
  }

/* 哪些版本能看到当前存档（按目录匹配）。 */
  private savesSeenByText(): string {
    const seen: VersionEntry[] = this.selectedSaveVersions();
    if (seen.length === 0) {
      return '没有版本在读它 —— 这是你数据最初的那一份';
    }
    if (seen.length === this.versions.length) {
      return '全部 ' + String(seen.length) + ' 个版本';
    }
    const names: string[] = [];
    for (const v of seen) {
      names.push(v.label);
    }
    return names.join('、');
  }

  /** 头部视图行，根据不同视图显示不同内容。 */
  private savesHeaderLine(): string {
    if (this.savesView === SAVES_VIEW_VERSION) {
      return this.versions.length === 0 ? '（没有可用的版本）'
                                        : (String(this.versions.length) + ' 个版本');
    }
    return this.savesDirShown === '' ? '（还没读到目录）' : this.savesDirShown;
  }

private versionSavesLine(v: VersionEntry): string {
    if (!v.hasData) {
      return '还没有数据';
    }
    return v.saveCount === 0 ? '目录在，没有存档' : (String(v.saveCount) + ' 个存档');
  }

  private selectedVersionLabel(): string {
    const v: VersionEntry | undefined = this.selectedVersionEntry();
    if (v === undefined) {
      return '';
    }
    return v.version === '' ? '未知版本' : v.version;
  }

  private selectedVersionLine(): string {
    const v: VersionEntry | undefined = this.selectedVersionEntry();
    if (v === undefined) {
      return '';
    }
    return this.selectedVersionIsCurrent() ? (v.label + '  ·  当前版本') : v.label;
  }

  private selectedVersionIsCurrent(): boolean {
    const v: VersionEntry | undefined = this.selectedVersionEntry();
    return v === undefined ? false : v.isCurrent;
  }

  private selectedVersionDataLine(): string {
    const v: VersionEntry | undefined = this.selectedVersionEntry();
    if (v === undefined) {
      return '';
    }
    if (!v.hasData) {
      return '这个版本还没有数据目录 —— 启动过一次之后才会建出来。';
    }
    return v.saveCount === 0 ? '数据目录在，但里面还没有存档。'
                             : ('这个目录里有 ' + String(v.saveCount) + ' 个存档。');
  }

  private selectedVersionHasDataText(): string {
    const v: VersionEntry | undefined = this.selectedVersionEntry();
    if (v === undefined || !v.hasData) {
      return '还没有数据目录。';
    }
    return '还没有存档。';
  }

  private selectedVersionDir(): string {
    const v: VersionEntry | undefined = this.selectedVersionEntry();
    return v === undefined ? '' : (v.dataDir + '/saves');
  }

  private selectedVersionSharedText(): string {
    const v: VersionEntry | undefined = this.selectedVersionEntry();
    if (v === undefined) {
      return '';
    }
    const shared: VersionEntry[] = this.versionsSharingDir(v.dataDir, v.path);
    if (shared.length === 0) {
      return '';
    }
    if (shared.length === this.versions.length - 1) {
      return '它和其余 ' + String(shared.length) + ' 个版本共用同一份数据 —— 数据没有隔离。';
    }
    const names: string[] = [];
    for (const s of shared) {
      names.push(s.label);
    }
    return '它和这些版本共用同一份数据：' + names.join('、');
  }

/* 读当前选中存档的元数据，存进 `selMetaRows`。只读一次。 */
  private loadSelectedMeta(): void {
    const sv: SaveEntry | undefined = this.selectedSaveEntry();
    /* 去重，避免重复解压 .msav */
    const key: string = (sv === undefined ? '' : (sv.id + '@' + this.selectedSaveDir()));
    if (key === this.metaLoadedKey) {
      return;
    }
    this.metaLoadedKey = key;

    this.selMetaRows = [];
    this.selMetaNote = '';
    if (sv === undefined) {
      return;
    }
    const file: string = newestFileOf(sv, this.selectedSaveDir());
    if (file === '') {
      this.selMetaNote = '这个存档里没有可读的文件（只剩备份）。';
      hilog.info(DOMAIN, TAG, 'saves: %{public}s has no readable file', sv.id);
      return;
    }

    const m: SaveMeta = readSaveMeta(this.selectedSaveDir() + '/' + file);
    if (!m.ok) {
      this.selMetaRows = [{ label: '读取自', value: file }];
      this.selMetaNote = '这个文件读不出来，可能不是有效的存档，或已损坏。';
    } else {
      this.selMetaRows = metaRowsOf(m, sv);
    }
    hilog.info(DOMAIN, TAG, 'saves: meta of %{public}s ok=%{public}s build=%{public}s',
               file, String(m.ok), m.build);
  }

/* 点一行的落点。窄屏打开子页，宽屏不设 panelOpen。点击已选中的行取消选中 */
  private openSaveRow(dir: string, id: string): void {
    const key: string = this.saveKey(dir, id);
    if (this.selectedSave === key) {
      this.selectedSave = '';
      return;
    }
    this.selectedSave = key;
    if (this.isNarrow()) {
      this.panelOpen = true;
    }
  }

  /** 「按版本」面板里那个版本的 `saves/` 目录。 */
  private versionSavesDir(): string {
    const v: VersionEntry | undefined = this.selectedVersionEntry();
    return v === undefined ? '' : (v.dataDir + '/saves');
  }

  /** 版本列表同理。 */
  private openVersionRow(path: string): void {
    this.selectedVersion = path;
    if (this.isNarrow()) {
      this.panelOpen = true;
    }
  }

  /* ==================================================================
   * 回收站
   * ================================================================== */

/* ⭐ 回收站走单独短路，不依赖 refresh()。 */
  /** 回收站里**归档**的条数。 */
  private vaultArchivedCount(): number {
    let n: number = 0;
    for (const e of this.vaultEntries) {
      if (e.archived) {
        n += 1;
      }
    }
    return n;
  }

  private clearVaultAll(): void {
    this.showVaultClearAsk = false;
    const total: number = this.vaultEntries.length;
    let done: number = 0;
    const fails: string[] = [];
    for (const e of this.vaultEntries) {
      const err: string = vaultPurge(e.id);
      if (err === '') {
        done += 1;
      } else {
        fails.push(e.label + '：' + err);
      }
    }
    this.vaultNote = fails.length === 0
      ? ''
      : ('清掉了 ' + String(done) + ' 个；有 ' + String(fails.length) + ' 个没删掉：' + fails.join('；'));
    hilog.info(DOMAIN, TAG, 'vault: cleared %{public}d of %{public}d entry(ies)', done, total);
    this.reloadVault();
  }

  private reloadVault(): void {
    this.vaultPurgedLast = purgeExpired(Date.now());
    this.vaultEntries = listVault();
  }

  /** 打开关于对话框并读取版本号 */
  private openAbout(): void {
    this.showAbout = true;
    if (this.appVersion !== '') {
      return;
    }
    try {
      const info: bundleManager.BundleInfo =
        bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      this.appVersion = info.versionName;
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'about: version lookup failed: %{public}s', err.message);
    }
  }

  /** 打开开源许可。正文按需从 rawfile 读，不在 build 里同步读大文件。 */
  private openLicenses(): void {
    this.showLicenses = true;
    this.licenseSel = '';
    this.licenseBody = '';
  }

  private readLicense(file: string): string {
    try {
      const ctx = getContext(this) as common.Context;
      const data: Uint8Array = ctx.resourceManager.getRawFileContentSync(file);
      return util.TextDecoder.create('utf-8').decodeToString(data);
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'licenses: cannot read %{public}s: %{public}s', file, err.message);
      return '';
    }
  }

  private openVault(): void {
    this.showVault = true;
    this.vaultNote = '';
    this.refresh();
  }

  private closeVault(): void {
    this.showVault = false;
    this.vaultNote = '';
    this.refresh();
  }

  /* 构建复制目标列表 */
  private buildCopyTargets(g: string): CopyTarget[] {
    const out: CopyTarget[] = [];
    const byKey: Map<string, CopyTarget> = new Map<string, CopyTarget>();
    for (const v of this.versions) {
      const k: string = resolveGameDirAndKey(g, v.source, v.path, this.bundledJar()).key;
      if (k === '') {
        continue;
      }
      let one: CopyTarget | undefined = byKey.get(k);
      if (one === undefined) {
        one = { key: k, versions: [], hasData: gameDataExists(isolatedGameDataDir(k)) };
        byKey.set(k, one);
        out.push(one);
      }
      one.versions.push(v);
    }
    return out;
  }

  /* 分类显示名 */
  private copyTargetTitle(c: CopyTarget): string {
    const names: string[] = [];
    for (const v of c.versions) {
      names.push(v.label);
    }
    return names.join('  ·  ') + '   →   ' + c.key;
  }

  /* 分类副标题 */
  private copyTargetSub(c: CopyTarget): string {
    if (c.hasData) {
      return '已经有数据 —— 勾了也不会覆盖它';
    }
    return '还没有数据 —— 会复制一份当前数据进来';
  }

  /* 切换复制目标选择 */
  private toggleCopyPick(key: string): void {
    const i: number = this.copyPicked.indexOf(key);
    if (i >= 0) {
      const out: string[] = this.copyPicked.slice();
      out.splice(i, 1);
      this.copyPicked = out;
    } else {
      this.copyPicked = this.copyPicked.concat([key]);
    }
  }

  private isCopyPicked(key: string): boolean {
    return this.copyPicked.indexOf(key) >= 0;
  }

  /* ==================================================================
   * 长按多选
   * ================================================================== */

  /** 行是否选中：多选看 multiPicked，否则看 selectedSave。 */
  private rowHot(key: string): boolean {
    return this.multiMode ? (this.multiPicked.indexOf(key) >= 0) : (this.selectedSave === key);
  }

/* 长按与点击都需更新 selectedSave，保证详情与操作一致。 */
  private enterMulti(key: string): void {
    this.selectedSave = key;
    if (!this.multiMode) {
      this.multiMode = true;
      this.multiPicked = [key];
      return;
    }
    this.toggleMultiPick(key);
  }

  /** 勾选/取消，须赋新数组。 */
  private toggleMultiPick(key: string): void {
    this.selectedSave = key;
    const i: number = this.multiPicked.indexOf(key);
    if (i >= 0) {
      const out: string[] = this.multiPicked.slice();
      out.splice(i, 1);
      this.multiPicked = out;
    } else {
      this.multiPicked = this.multiPicked.concat([key]);
    }
/* 勾选数为 0 不退出多选，避免取消按钮失效。 */
  }

  /* 退出多选，清除相关状态。 */
  private exitMulti(): void {
    this.stopPermHold();
    this.multiMode = false;
    this.multiPicked = [];
    this.showMultiAsk = false;
    this.multiListOpen = false;
  }

  /** 勾选存档的名称，逗号分隔。 */
  private pickedNamesText(): string {
    const names: string[] = [];
    for (const r of this.pickedRows()) {
      names.push(r.entry.label);
    }
    return names.join('、');
  }

  /** 实际存在的勾选行，跳过已删除键。 */
  private pickedRows(): SaveRow[] {
    const out: SaveRow[] = [];
    for (const g of this.saveGroups) {
      for (const s of g.saves) {
        if (this.multiPicked.indexOf(this.saveKey(g.dir, s.id)) >= 0) {
          out.push({ dir: g.dir, entry: s });
        }
      }
    }
    return out;
  }

/* 勾选列表中实际存在的个数，不使用 multiPicked.length。 */
  private multiPickCount(): number {
    return this.pickedRows().length;
  }

/* 批量删除/归档。archived 决定去向。部分失败报错。 */
  private deleteMultiToVault(archived: boolean): void {
    this.stopPermHold();
    const rows: SaveRow[] = this.pickedRows();
    if (rows.length === 0) {
      return;
    }
    this.savesNote = '';
    const now: number = Date.now();
    const before: Set<string> = new Set<string>();
    if (archived) {
      for (const e of listVault()) {
        before.add(e.id);
      }
    }
    const fails: string[] = [];
    let done: number = 0;
    for (const r of rows) {
      const e: string = vaultDelete(r.entry, r.dir, this.vaultDays, now,
                                    this.ownerOfDir(r.dir), this.keyOfDir(r.dir));
      if (e === '') {
        done += 1;
      } else {
        fails.push(r.entry.label + '：' + e);
      }
    }
    if (archived) {
      let archFail: number = 0;
      for (const e of listVault()) {
        if (before.has(e.id)) {
          continue;
        }
        if (vaultSetArchived(e.id, true, this.vaultDays, now) !== '') {
          archFail += 1;
        }
      }
      if (archFail > 0) {
        fails.push('有 ' + String(archFail) + ' 个归档没设上（它们到期仍会被清理）');
      }
    }
    const what: string = archived ? '归档了' : '放进了回收站';
    this.savesNote = fails.length === 0
      ? (what + ' ' + String(done) + ' 个，可以在回收站里找回。')
      : (what + ' ' + String(done) + ' 个；有 ' + String(fails.length) + ' 个没成功：'
         + NL + fails.join(NL));
    this.showMultiAsk = false;
    this.exitMulti();
    this.selectedSave = '';
    this.refresh();
  }

  private askDelete(): void {
    if (this.selectedSave === '') {
      return;
    }
    this.showDeleteAsk = true;
  }

  /* 真删。archived=true:归档不自动清理。走搬进回收站，非抹掉。 */
  private doVaultDelete(archived: boolean): void {
    this.stopPermHold();
    const sv: SaveEntry | undefined = this.selectedSaveEntry();
    this.showDeleteAsk = false;
    if (sv === undefined) {
      return;
    }
    /* 清掉上一次那句话 */
    this.savesNote = '';
    const dir: string = this.selectedSaveDir();
    const now: number = Date.now();
    /* 记录来源（回收站需要区分版本） */
    const err: string = vaultDelete(sv, dir, this.vaultDays, now,
                                    this.ownerOfDir(dir), this.keyOfDir(dir));
    if (err !== '') {
      this.savesNote = err;
      this.refresh();
      return;
    }
    if (archived) {
      /* 刚搬进去的是最新的，用listVault获取 */
      const fresh: VaultEntry[] = listVault();
      if (fresh.length > 0) {
        const e2: string = vaultSetArchived(fresh[0].id, true, this.vaultDays, now);
        if (e2 !== '') {
          this.savesNote = '已搬进回收站但归档失败（到期仍会清理）：' + e2;
        }
      }
    }
    this.selectedSave = '';
    this.refresh();
  }

/* 永久删除（不进回收站，不可撤销） */
  private doPermanentDelete(): void {
    this.stopPermHold();
    const sv: SaveEntry | undefined = this.selectedSaveEntry();
    this.showDeleteAsk = false;
    if (sv === undefined) {
      return;
    }
    /* 清掉上一次错误，避免残留 */
    this.savesNote = '';
    const err: string = vaultPermanentDelete(sv, this.selectedSaveDir());
    this.selectedSave = '';
    if (err !== '') {
      this.savesNote = err;
    }
    this.refresh();
  }

  /* 批量永久删除（逐个删，无回滚） */
  private deleteMultiPermanent(): void {
    this.stopPermHold();
    const rows: SaveRow[] = this.pickedRows();
    if (rows.length === 0) {
      return;
    }
    this.savesNote = '';
    const fails: string[] = [];
    let done: number = 0;
    for (const r of rows) {
      const e: string = vaultPermanentDelete(r.entry, r.dir);
      if (e === '') {
        done += 1;
      } else {
        fails.push(r.entry.label + '：' + e);
      }
    }
    this.savesNote = fails.length === 0
      ? ('已永久删除 ' + String(done) + ' 个存档。')
      : ('永久删除了 ' + String(done) + ' 个；有 ' + String(fails.length) + ' 个没成功：'
         + NL + fails.join(NL));
    this.showMultiAsk = false;
    this.exitMulti();
    this.selectedSave = '';
    this.refresh();
  }

/* ---- 「长按永久删除」的计时器 ---- */

  /** 停表 + 归零。 */
  private stopPermHold(): void {
    if (this.permTimer !== -1) {
      clearInterval(this.permTimer);
      this.permTimer = -1;
    }
    if (this.permHold !== 0) {
      this.permHold = 0;
    }
  }

  /** 按住不放：进度走到 100 才动手。松手由 `stopPermHold` 取消。 */
  private startPermHold(): void {
    this.stopPermHold();
    const step: number = 100 / (PERM_HOLD_MS / PERM_TICK_MS);
    this.permTimer = setInterval(() => {
      if (!this.showDeleteAsk && !this.showMultiAsk) {
        this.stopPermHold();
        return;
      }
      this.permHold = Math.min(100, this.permHold + step);
      if (this.permHold >= 100) {
        this.stopPermHold();
        if (this.showMultiAsk) {
          this.deleteMultiPermanent();
        } else {
          this.doPermanentDelete();
        }
      }
    }, PERM_TICK_MS);
  }

/* 单删与多选确认窗共用此按钮。 */
  @Builder
  PermanentDeleteButton() {
    Stack({ alignContent: Alignment.Start }) {
      Row()
        .width(String(this.permHold) + '%').height(PERM_BTN_H)
        .backgroundColor('#66FFFFFF')
      Text('长按永久删除')
        .fontSize(15).fontColor(Color.White)
        .width('100%').height(PERM_BTN_H)
        .textAlign(TextAlign.Center)
    }
    .width(PERM_BTN_W)
    .height(PERM_BTN_H)
    .alignSelf(ItemAlign.Center)
    .margin({ top: 16 })
    .backgroundColor($r('app.color.danger'))
    .borderRadius(PERM_BTN_H / 2)
    .clip(true)
    .onTouch((e: TouchEvent) => {
      if (e.type === TouchType.Down) {
        this.startPermHold();
      } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
        this.stopPermHold();
      }
    })
  }

  private ownerOfDir(dir: string): string {
    const g: SaveGroup | undefined = this.saveGroups.find((x: SaveGroup) => x.dir === dir);
    return g === undefined || g.versions.length === 0 ? '' : this.groupTitle(g);
  }

  private keyOfDir(dir: string): string {
    const g: SaveGroup | undefined = this.saveGroups.find((x: SaveGroup) => x.dir === dir);
    return g === undefined || g.versions.length === 0 ? '' : g.versions[0].key;
  }

  private vaultOwnerText(e: VaultEntry): string {
    if (e.owner !== '') {
      return e.owner + (e.key === '' ? '' : ('（' + e.key + '）'));
    }
    const now: string = this.ownerOfDir(e.from);
    if (now !== '') {
      return now;
    }
    return e.from === '' ? '不知道原来属于哪个版本' : ('目录 ' + e.from);
  }

  /** 放回。 */
  private doVaultRestore(e: VaultEntry): void {
    this.vaultNote = vaultRestore(e, this.savesDirShown);
    this.reloadVault();
    this.refresh();
  }

  /** 彻底删掉。 */
  private doVaultPurge(e: VaultEntry): void {
    this.vaultNote = vaultPurge(e.id);
    this.reloadVault();
    this.refresh();
  }

  /** 归档 / 取消归档。取消时重新起算保留期。 */
  private doVaultToggleArchive(e: VaultEntry): void {
    this.vaultNote = vaultSetArchived(e.id, !e.archived, this.vaultDays, Date.now());
    this.reloadVault();
    this.refresh();
  }

  private setVaultDays(d: number): void {
    this.vaultDays = d;
    writeVaultDays(this.filesDir, d);
    this.refresh();
  }

  private deleteExpiryText(): string {
    return formatMs(Date.now() + this.vaultDays * 24 * 60 * 60 * 1000);
  }

  private vaultDaysLabel(d: number): string {
    return d >= 30 ? '1 个月' : (String(d) + ' 天');
  }

  /* ---- 复制 / 移动 ---- */

  private transferSourceRows(): SaveRow[] {
    if (this.multiMode) {
      return this.pickedRows();
    }
    const r: SaveRow | undefined = this.selectedSaveRow();
    return r === undefined ? [] : [r];
  }

  private transferSourceDirs(): string[] {
    const out: string[] = [];
    for (const r of this.transferSourceRows()) {
      if (out.indexOf(r.dir) < 0) {
        out.push(r.dir);
      }
    }
    return out;
  }

  /** 源是否全部为手动存档？多选时有一个不是则返回 false。 */
  private transferAllManual(): boolean {
    const rows: SaveRow[] = this.transferSourceRows();
    if (rows.length === 0) {
      return false;
    }
    for (const r of rows) {
      if (r.entry.kind !== 'manual') {
        return false;
      }
    }
    return true;
  }

  private askTransfer(op: string): void {
    if (this.transferSourceRows().length === 0) {
      return;
    }
    /* 先算目标计数再开窗（避免渲染期读盘），顺序在设置 transferOp 之前。 */
    this.cacheTransferCounts();
    this.transferOp = op;
    this.transferNote = '';
    this.transferPicked = []; // 每次打开重置选择
  }

  private closeTransferDialog(): void {
    this.transferOp = '';
    this.transferNote = '';
    this.transferPicked = [];
    this.transferTargetCounts = new Map<string, number>();
  }

  /* 目标存档数，事件中算好，渲染只查表。 */
  private cacheTransferCounts(): void {
    const m: Map<string, number> = new Map<string, number>();
    for (const v of this.versions) {
      m.set(v.dataDir, countSavesIn(v.dataDir + '/saves'));
    }
    this.transferTargetCounts = m;
  }

  /** 该项是否被选中。 */
  private isTransferPicked(key: string): boolean {
    return this.transferPicked.indexOf(key) >= 0;
  }

  /* 切换选择，必须赋新数组以触发重绘。移动时单选，复制时多选。 */
  private toggleTransferPick(key: string): void {
    const i: number = this.transferPicked.indexOf(key);
    if (this.transferOp === 'move') {
      this.transferPicked = (i >= 0) ? [] : [key];
      return;
    }
    if (i >= 0) {
      const out: string[] = this.transferPicked.slice();
      out.splice(i, 1);
      this.transferPicked = out;
    } else {
      this.transferPicked = this.transferPicked.concat([key]);
    }
  }

  /* 返回可用的目标版本，排除所有源目录。 */
  private transferTargets(): VersionEntry[] {
    const dirs: string[] = this.transferSourceDirs();
    return this.versions.filter((v: VersionEntry) => dirs.indexOf(v.dataDir + '/saves') < 0);
  }

  /** 目标的后果说明。 */
  private transferTargetNote(v: VersionEntry): string {
    const looked: number | undefined = this.transferTargetCounts.get(v.dataDir);
    const n: number = looked === undefined ? 0 : looked;
    const head: string = n === 0
      ? '它还没有存档'
      : ('它现在有 ' + String(n) + ' 个存档');
    const m: number = this.transferSourceRows().length;
    if (this.transferOp === 'move') {
      return m > 1
        ? (head + '；移过去之后，这 ' + String(m) + ' 个存档只在「' + v.label + '」下有。')
        : (head + '；移过去之后，这个存档只在「' + v.label + '」下有。');
    }
    return m > 1
      ? (head + '；复制 ' + String(m) + ' 份过去，两边都有。')
      : (head + '；复制一份过去，两边都有。');
  }

  /* 失败行：多源时携带存档名。 */
  private transferFailLine(src: SaveRow, where: string, why: string): string {
    if (this.transferSourceRows().length > 1) {
      return src.entry.label + ' → ' + where + '：' + why;
    }
    return where + '：' + why;
  }

  /* 对话框标题：单源用名字，多源用个数。 */
  private transferSourceTitle(): string {
    const m: number = this.transferSourceRows().length;
    const verb: string = this.transferOp === 'move' ? '移动' : '复制';
    if (m > 1) {
      return verb + ' ' + String(m) + ' 个存档';
    }
    return verb + '「' + this.selectedSaveLabel() + '」';
  }

  /** 副标题，说明源的变化。 */
  private transferSourceSubtitle(): string {
    const m: number = this.transferSourceRows().length;
    if (this.transferOp === 'move') {
      return m > 1
        ? ('原版本会看不到这 ' + String(m) + ' 个。选一个目标。')
        : '原版本会看不到它。选一个目标。';
    }
    return m > 1
      ? ('原来那 ' + String(m) + ' 份不动。可以选多个目标。')
      : '原来那一份不动。可以选多个目标。';
  }

  /* 确认执行：N×M 操作，不中断，失败行上限6条。 */
  private confirmTransfer(): void {
    const srcs: SaveRow[] = this.transferSourceRows();
    if (srcs.length === 0 || this.transferPicked.length === 0) {
      return;
    }
    const fails: string[] = [];
    let okCount: number = 0;

    if (this.transferOp === 'move') {
      const v: VersionEntry | undefined =
        this.transferTargets().find((x: VersionEntry) => x.path === this.transferPicked[0]);
      if (v === undefined) {
        fails.push('选中的目标已经不在了');
      } else {
        for (const src of srcs) {
          const e: string = moveSaveTo(src.entry, src.dir, v.dataDir + '/saves');
          if (e === '') {
            okCount += 1;
          } else {
            fails.push(this.transferFailLine(src, v.label, e));
          }
        }
      }
    } else {
      for (const key of this.transferPicked) {
        if (key === DUP_KEY) {
          for (const src of srcs) {
            const e: string = duplicateSave(src.entry, src.dir);
            if (e === '') {
              okCount += 1;
            } else {
              fails.push(this.transferFailLine(src, '再存一份', e));
            }
          }
          continue;
        }
        const v: VersionEntry | undefined =
          this.transferTargets().find((x: VersionEntry) => x.path === key);
        if (v === undefined) {
          fails.push('有个选中的目标已经不在了');
          continue;
        }
        for (const src of srcs) {
          const e: string = copySaveTo(src.entry, src.dir, v.dataDir + '/saves');
          if (e === '') {
            okCount += 1;
          } else {
            fails.push(this.transferFailLine(src, v.label, e));
          }
        }
      }
    }

    if (fails.length === 0) {
      const wasMove: boolean = this.transferOp === 'move';
      this.closeTransferDialog();
      /* 移动后退出多选态，复制不动。 */
      if (wasMove && this.multiMode) {
        this.exitMulti();
        this.selectedSave = '';
      }
    } else {
      const head: string = this.transferOp === 'move' ? '移动失败' : '复制失败';
      const okLine: string = okCount > 0 ? ('成功了 ' + String(okCount) + ' 个。\n') : '';
      const CAP: number = 6;
      const shown: string[] = fails.slice(0, CAP);
      const rest: string = fails.length > CAP
        ? ('\n…还有 ' + String(fails.length - CAP) + ' 条')
        : '';
      this.transferNote = okLine + head + '：\n' + shown.join('\n') + rest;
      this.transferPicked = [];
    }
    this.refresh();
  }

  /* 窄屏判定：winW <= 0 时当作宽屏（防平板闪子页）。 */
  private isNarrow(): boolean {
    return this.winW > 0 && this.winW < NARROW_VP;
  }

  /** 手机详情子页开关。宽屏恒 false。 */
  @State panelOpen: boolean = false;

  /** 排除头条三项（构建号/地图/保存时间）后的元数据行。 */
  private metaRowsExcept(): MetaRow[] {
    const skip: string[] = ['写入时的构建号', '地图', '保存时间'];
    return this.selMetaRows.filter((r: MetaRow) => skip.indexOf(r.label) < 0);
  }

  /** 选中一个 jar，记录选择。 */
  private pick(jarPath: string): void {
    this.selected = jarPath;
    writeSelection(this.filesDir, jarPath);
    this.resolution = resolveGame(this.filesDir, this.bundleCodeDir);
    hilog.info(DOMAIN, TAG, 'launcher: picked %{public}s', jarPath === '' ? '(bundled)' : jarPath);
  }

  /** 退回内置 jar。写空字符串表示用包内的。 */
  private pickBundled(): void {
    this.selected = '';
    writeSelection(this.filesDir, '');
    this.resolution = resolveGame(this.filesDir, this.bundleCodeDir);
    hilog.info(DOMAIN, TAG, 'launcher: picked (bundled)');
  }

/** 打开确认窗。*/
private openGameDeleteAsk(g: GameJar): void {
    this.gameDeletePath = g.path;
    /* 文件名在前，版本号在后。 */
    this.gameDeleteLabel = g.version === '' ? g.name : (g.name + '  ·  ' + g.version);
    this.gameDeleteDir = resolveGameDirAndKey(this.granularity, 'user', g.path,
                                              this.bundledJar()).dir;
    this.gamesNote = '';
    this.showGameDeleteAsk = true;
}

/** 是否有自己的隔离数据？未隔离的不能删。 */
private jarHasOwnData(): boolean {
    return this.gameDeleteDir !== '' && this.gameDeleteDir !== liveGameDataDir();
}

/** 除它之外，还有哪些版本读同一个数据目录。 */
private otherVersionsOnSelectedDir(): VersionEntry[] {
    const out: VersionEntry[] = [];
    if (this.gameDeletePath === '' || this.gameDeleteDir === '') {
      return out;
    }
    for (const v of this.versions) {
      if (v.dataDir === this.gameDeleteDir && v.path !== this.gameDeletePath) {
        out.push(v);
      }
    }
    return out;
}

/** 那些版本的名字，超过三个截断。 */
private otherVersionsText(): string {
    const names: string[] = [];
    for (const v of this.otherVersionsOnSelectedDir()) {
      names.push(v.version === '' ? v.label : v.version);
    }
    if (names.length <= 3) {
      return names.join('、');
    }
    return names.slice(0, 3).join('、') + ' 等 ' + String(names.length) + ' 个';
}

/** 这份数据里现在有几个存档。 */
private jarDataSaveCount(): number {
    if (this.gameDeleteDir === '') {
      return 0;
    }
    return countSavesIn(this.gameDeleteDir + '/saves');
}

/* 删除一个版本。先数据后 jar，数据没删干净就停下。 */
private deleteGame(withData: boolean): void {
    const path: string = this.gameDeletePath;
    this.showGameDeleteAsk = false;
    if (path === '') {
      return;
    }
    const dir: string = this.gameDeleteDir;

    /* 未隔离的再拦一次。 */
    if (withData && (dir === '' || dir === liveGameDataDir())) {
      this.gamesNote = '那份是全应用唯一的未隔离数据，不能这样删。';
      this.refresh();
      return;
    }

    if (withData) {
      const rm: TreeStat = newTreeStat();
      removeTree(dir, 0, rm);
      if (rm.failed > 0) {
        this.gamesNote = '数据没删干净，游戏也先没删（可以再试一次）：' + rm.firstError;
        this.refresh();
        return;
      }
      hilog.info(DOMAIN, TAG, 'games: removed data dir %{public}s', dir);
    }

    try {
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
    } catch (e) {
      const err = e as BusinessError;
      this.gamesNote = '删除失败：' + err.message;
      this.refresh();
      return;
    }

    /* 删掉的是选中版本 ⇒ 退回内置。 */
    if (this.selected === path) {
      writeSelection(this.filesDir, '');
    }
    this.gameDeletePath = '';
    this.gameDeleteLabel = '';
    this.gameDeleteDir = '';
    this.gamesNote = withData ? '已删除这个版本和它的数据。' : '已删除这个版本（保留数据）。';
    hilog.info(DOMAIN, TAG, 'games: deleted %{public}s withData=%{public}s',
               path, String(withData));
    this.refresh();
}

/** 内容栏宽度（vp）。窄屏铺满，宽屏取比例和下限。 */
private gamesWidthVp(): number {
    if (this.winW <= 0) {
      return CONTENT_MIN_VP;
    }
    if (this.isNarrow()) {
      return this.winW;
    }
    const want: number = this.winW * (GAMES_WIDTH_PCT / 100);
    return want > CONTENT_MIN_VP ? want : CONTENT_MIN_VP;
}

/* sideMargin 不再使用右侧非界面区。 */
private sideMargin(): number {
    if (this.winW <= 0) {
      return BAR_MIN_SIDE_VP;
    }
    const want: number = Math.min(BAR_MAX_VP, this.winW - 2 * BAR_MIN_SIDE_VP);
    const side: number = (this.winW - want) / 2;
    return side > BAR_MIN_SIDE_VP ? side : BAR_MIN_SIDE_VP;
}

@Builder
GamesTab() {
    Column() {
      Refresh({ refreshing: $$this.isRefreshing }) {
        Scroll() {
          Row() {
            Column() {
              if (this.games.length === 0) {
          /* 空状态 + 逃生门。先分叉：有无运行时。 */
          Column() {
            if (this.resolution.source === 'no-runtime') {
              Text('这个包不能运行游戏')
                .fontSize(18).fontColor($r('sys.color.font_primary'))
              Text('它只能管理存档与数据包 —— 包里没有游戏运行时。')
                .fontSize(13).fontColor($r('sys.color.font_secondary'))
                .margin({ top: 8 })
                .textAlign(TextAlign.Center)
              Text('要玩 Mindustry，请安装带游戏的完整版本；\n这个版本可以用「导入数据」接管它的存档。')
                .fontSize(13).fontColor($r('sys.color.font_secondary'))
                .margin({ top: 12 })
                .textAlign(TextAlign.Center)
            } else {
            Text(this.hasBundled ? '还没有导入其他游戏版本' : '没有找到游戏')
              .fontSize(18).fontColor($r('sys.color.font_primary'))
            if (this.hasBundled) {
              Text('内置的那一份可以直接玩，点下面的「启动游戏」就行')
                .fontSize(13).fontColor($r('sys.color.font_secondary'))
                .margin({ top: 8 })
                .textAlign(TextAlign.Center)
            }
            Text('把 Mindustry 的 .jar 放进下面这个文件夹，然后下拉刷新（或到「设置」里点「重新扫描」）：')
              .fontSize(13).fontColor($r('sys.color.font_secondary'))
              .margin({ top: 12 })
              .textAlign(TextAlign.Center)
            Text(this.jarDirHuman === '' ? '　' : this.jarDirHuman)
              .fontSize(13).fontColor($r('sys.color.font_secondary'))
              .margin({ top: 8 })
              .textAlign(TextAlign.Center)
            Text(this.jarDirHint === '' ? '（这个设备上还拿不到 Download 文件夹）' : this.jarDirHint)
              .fontSize(12).fontColor($r('sys.color.font_tertiary'))
              .margin({ top: 2 })
              .textAlign(TextAlign.Center)
              .copyOption(CopyOptions.LocalDevice)
            Text('内置游戏：' + (this.hasBundled ? '有' : '无'))
              .fontSize(12).fontColor($r('sys.color.font_secondary'))
              .margin({ top: 12 })
            }
          }
          .width('100%')
          .padding({ left: 24, right: 24, top: 40, bottom: 24 })
          .alignItems(HorizontalAlign.Center)
        } else {
          /* 列表项内联，不是 @Builder：this.selected 变化会重新渲染。 */
          List({ space: 8 }) {
            /* 必须有守卫：lite 分支无游戏。 */
            if (this.hasBundled) {
              ListItem() {
                Row() {
                  Column() {
                    Text('内置游戏')
                      .fontSize(16).fontColor($r('sys.color.font_primary'))
                    Text(this.bundledVer === '' ? '未知版本' : this.bundledVer)
                      .fontSize(12).fontColor($r('sys.color.font_secondary')).margin({ top: 2 })
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                  if (this.selected === '') {
                    Text('✓').fontSize(18).fontColor($r('sys.color.brand'))
                  }
                }
                .width('100%')
                .padding({ left: 16, right: 16, top: 14, bottom: 14 })
              }
              .backgroundColor($r('app.color.launcher_card'))
              .borderRadius(CARD_RADIUS_VP)
              .onClick(() => { this.pickBundled(); })
            }

            ForEach(this.games, (g: GameJar) => {
              ListItem() {
                Row() {
                  Column() {
                    // 第一行版本号，第二行文件名·大小·日期
                    Text(g.version === '' ? '未知版本' : g.version)
                      .fontSize(16).fontColor($r('sys.color.font_primary'))
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(g.name + '  ·  ' + formatSize(g.size) + '  ·  ' + formatDate(g.mtime))
                      .fontSize(12).fontColor($r('sys.color.font_secondary')).margin({ top: 2 })
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                  if (this.selected === g.path) {
                    Text('✓').fontSize(18).fontColor($r('sys.color.brand'))
                  }
                }
                .width('100%')
                .padding({ left: 16, right: 16, top: 14, bottom: 14 })
                // 白底圆角在内容层，swipeAction 在 ListItem
                .backgroundColor($r('app.color.launcher_card'))
                .borderRadius(CARD_RADIUS_VP)
              }
              .onClick(() => { this.pick(g.path); })
              // 左滑删除，使用系统 swipeAction
              .swipeAction({ end: { builder: () => { this.SwipeDeleteAction(g) } },
                             edgeEffect: SwipeEdgeEffect.Spring })
            }, (g: GameJar): string => this.gameRowKey(g))
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 16 })
            }
            }
            .width(this.gamesWidthVp())
            .animation({ duration: 300, curve: Curve.FastOutSlowIn })
          }
          // 靠左靠上，height('100%') 防止垂直居中
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Start)
          .alignItems(VerticalAlign.Top)
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
      }
      .layoutWeight(1)
      .width('100%')
      .onRefreshing(() => {
        this.refresh();
        this.isRefreshing = false;
      })

      // 删除结果提示
      if (this.gamesNote !== '') {
        Text(this.gamesNote)
          .fontSize(12).fontColor($r('sys.color.font_secondary'))
          .width(this.gamesWidthVp())
          .padding({ left: 16, right: 16, top: 12 })
      }

      Column() {
        Button('启动游戏')
          .width('100%')
          .height(44)
          .fontSize(BUTTON_FONT_VP)
          .enabled(this.resolution.path !== '')
          .onClick(() => { this.onLaunch(this.resolution.path); })
      }
      .width(this.gamesWidthVp())
      .animation({ duration: 300, curve: Curve.FastOutSlowIn })
      .padding({ left: 16, right: 16, top: 12 })
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ bottom: BAR_CLEARANCE_VP })
  }
// 存档页详情面板，零参 @Builder
  @Builder
  SaveDataPanel() {
    Column() {
      if (this.selectedSave === '') {
        Text(this.saves.length === 0 ? '还没有存档' : '从左边选一个存档')
          .fontSize(13).fontColor($r('sys.color.font_tertiary'))
      } else {
        // 「这个存档对哪些版本可见」与标题同行靠右，内部2:1分
        Row() {
          Column() {
            Text(this.selectedSaveLabel())
              .fontSize(16).fontColor($r('sys.color.font_primary'))
              .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.selectedSaveSummary())
              .fontSize(12).fontColor($r('sys.color.font_tertiary'))
              .margin({ top: 6 })
            Text(this.selectedSaveUpdated())
              .fontSize(12).fontColor($r('sys.color.font_tertiary'))
              .margin({ top: 4 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(2)

          if (this.savesSeenByText() !== '') {
            Column() {
              Text('这个存档对哪些版本可见')
                .fontSize(12).fontColor($r('sys.color.font_tertiary'))
                .textAlign(TextAlign.End)
              Text(this.savesSeenByText())
                .fontSize(12).fontColor($r('sys.color.font_secondary'))
                .margin({ top: 2 })
                .textAlign(TextAlign.End)
            }
            .alignItems(HorizontalAlign.End)
            .layoutWeight(1)
            .margin({ left: 12 })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)

        Divider()
          .strokeWidth(1).color($r('app.color.launcher_border'))
          .margin({ top: 14, bottom: 14 })

        if (this.selMetaNote !== '') {
          Text(this.selMetaNote)
            .fontSize(12).fontColor($r('sys.color.font_secondary'))
        } else {
          Text('写入时的游戏构建号')
            .fontSize(12).fontColor($r('sys.color.font_tertiary'))
          Text(rowValue(this.selMetaRows, '写入时的构建号') === ''
               ? '—' : rowValue(this.selMetaRows, '写入时的构建号'))
            .fontSize(22).fontColor($r('sys.color.font_primary'))
            .margin({ top: 2 })

          if (rowValue(this.selMetaRows, '地图') !== '') {
            Text('地图  ' + rowValue(this.selMetaRows, '地图'))
              .fontSize(12).fontColor($r('sys.color.font_secondary'))
              .margin({ top: 10 })
          }
          if (rowValue(this.selMetaRows, '保存时间') !== '') {
            Text('保存于  ' + rowValue(this.selMetaRows, '保存时间'))
              .fontSize(12).fontColor($r('sys.color.font_secondary'))
              .margin({ top: 4 })
          }

          Divider()
            .strokeWidth(1).color($r('app.color.launcher_border'))
            .margin({ top: 14, bottom: 14 })

          Scroll() {
            Column() {
              ForEach(this.metaRowsExcept(), (r: MetaRow) => {
                Row() {
                  Text(r.label)
                    .fontSize(12).fontColor($r('sys.color.font_tertiary'))
                    .constraintSize({ minWidth: 88 })
                  Text(r.value)
                    .fontSize(12).fontColor($r('sys.color.font_primary'))
                    .layoutWeight(1)
                    .copyOption(CopyOptions.LocalDevice)
                }
                .width('100%')
                .margin({ bottom: 8 })
                .alignItems(VerticalAlign.Top)
              }, (r: MetaRow) => r.label + '|' + r.value)
            }
            .width('100%')
          }
          .width('100%')
          .layoutWeight(1)
          .align(Alignment.TopStart)
          .scrollBar(BarState.Off)
        }

        if (!this.multiMode) {
          Divider()
            .strokeWidth(1).color($r('app.color.launcher_border'))
            .margin({ top: 14, bottom: 12 })

          this.SaveActionRow()
        }
      }
    }
    .width('100%').height('100%')
    .padding({ left: 8, right: 16, top: 12 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  MultiBar() {
    if (this.isNarrow()) {
      Column() {
        Text('已选 ' + String(this.multiPickCount()) + ' 项 · 删除只是放进回收站，可以找回')
          .fontSize(12).fontColor($r('sys.color.font_secondary'))
          .width('100%')
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        Row() {
          this.MultiBarButtons()
        }
        .width('100%')
        .justifyContent(FlexAlign.End)
        .margin({ top: 8 })
      }
      .width('100%')
      .margin({ top: 10 })
      .alignItems(HorizontalAlign.Start)
    } else {
      Row() {
        Text('已选 ' + String(this.multiPickCount()) + ' 项 · 删除只是放进回收站，可以找回')
          .fontSize(12).fontColor($r('sys.color.font_secondary'))
          .layoutWeight(1)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        this.MultiBarButtons()
      }
      .width('100%')
      .margin({ top: 10 })
      .alignItems(VerticalAlign.Center)
    }
  }

/* 多选条按钮，零参，两分支共用，顺序与 SaveActionRow 对齐 */
  @Builder
  MultiBarButtons() {
    Row() {
      Button('删除')
        .fontSize(BUTTON_FONT_VP)
        .fontColor($r('sys.color.warning'))
        .backgroundColor($r('app.color.btn_neutral'))
        .enabled(this.multiPickCount() > 0)
        .onClick(() => { this.showMultiAsk = true; this.multiListOpen = false; })
      Button('复制')
        .fontSize(BUTTON_FONT_VP)
        .fontColor(Color.White)
        .backgroundColor($r('sys.color.brand'))
        .margin({ left: 8 })
        .enabled(this.multiPickCount() > 0)
        .onClick(() => { this.askTransfer('copy'); })
      Button('移动')
        .fontSize(BUTTON_FONT_VP)
        .fontColor(Color.White)
        .backgroundColor($r('sys.color.brand'))
        .margin({ left: 8 })
        .enabled(this.multiPickCount() > 0)
        .onClick(() => { this.askTransfer('move'); })
      Button('取消')
        .fontSize(BUTTON_FONT_VP)
        .backgroundColor($r('app.color.btn_neutral'))
        .margin({ left: 8 })
        .onClick(() => { this.exitMulti(); })
    }
  }

  @Builder
  SaveActionRow() {
    Row() {
      Button('删除')
        .fontSize(BUTTON_FONT_VP)
        .fontColor($r('sys.color.warning'))
        .backgroundColor($r('app.color.btn_neutral'))
        .onClick(() => { this.askDelete(); })
      Button('复制')
        .fontSize(BUTTON_FONT_VP)
        .fontColor(Color.White)
        .backgroundColor($r('sys.color.brand'))
        .margin({ left: 8 })
        .onClick(() => { this.askTransfer('copy'); })
      Button('移动')
        .fontSize(BUTTON_FONT_VP)
        .fontColor(Color.White)
        .backgroundColor($r('sys.color.brand'))
        .margin({ left: 8 })
        .onClick(() => { this.askTransfer('move'); })
    }
    .width('100%')
    .justifyContent(FlexAlign.End)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  VersionDataPanel() {
    Column() {
      if (this.selectedVersionEntry() === undefined) {
        Text('从左边选一个版本')
          .fontSize(13).fontColor($r('sys.color.font_tertiary'))
      } else {
        Text(this.selectedVersionLabel())
          .fontSize(16).fontColor($r('sys.color.font_primary'))
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.selectedVersionLine())
          .fontSize(12).fontColor($r('sys.color.font_tertiary'))
          .margin({ top: 6 })

        Divider()
          .strokeWidth(1).color($r('app.color.launcher_border'))
          .margin({ top: 14, bottom: 14 })

        Text(this.selectedVersionDataLine())
          .fontSize(12).fontColor($r('sys.color.font_secondary'))
        Text(this.selectedVersionDir())
          .fontSize(11).fontColor($r('sys.color.font_tertiary'))
          .margin({ top: 4 })
          .copyOption(CopyOptions.LocalDevice)

        if (this.selectedVersionSharedText() !== '') {
          Text(this.selectedVersionSharedText())
            .fontSize(11).fontColor($r('sys.color.font_tertiary'))
            .margin({ top: 10 })
        }

        if (!this.selectedVersionIsCurrent()) {
          Text('这还不是当前版本。要操作这份数据，先在「首页」把它切过去。')
            .fontSize(11).fontColor($r('sys.color.font_tertiary'))
            .margin({ top: 10 })
        }

        Divider()
          .strokeWidth(1).color($r('app.color.launcher_border'))
          .margin({ top: 14, bottom: 14 })

        Text('这个目录里的存档')
          .fontSize(12).fontColor($r('sys.color.font_tertiary'))

        if (this.multiMode) {
          this.MultiBar()
        }

        Scroll() {
          Column() {
            if (this.versionSaves.length === 0) {
              Text(this.selectedVersionHasDataText())
                .fontSize(12).fontColor($r('sys.color.font_secondary'))
                .margin({ top: 8 })
            }
            ForEach(this.versionSaves, (sv: SaveEntry) => {
              Row() {
                Text(sv.label)
                  .fontSize(14)
                  .fontColor(this.rowHot(this.saveKey(this.versionSavesDir(), sv.id))
                             ? $r('sys.color.brand') : $r('sys.color.font_primary'))
                  .layoutWeight(1)
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })

                Text(formatSaveSize(sv.bytes))
                  .fontSize('12vp').fontColor($r('sys.color.font_tertiary'))
                  .width(SAVE_SIZE_COL_VP).textAlign(TextAlign.End)

                Text(formatSaveDate(sv.mtime))
                  .fontSize('12vp').fontColor($r('sys.color.font_tertiary'))
                  .width(SAVE_DATE_COL_VP).textAlign(TextAlign.End)
                  .margin({ left: 10 })

                Text('✓')
                  .fontSize('14vp').fontColor($r('sys.color.brand'))
                  .width(SAVE_TICK_COL_VP).textAlign(TextAlign.End)
                  .margin({ left: 6 })
                  .visibility(this.rowHot(this.saveKey(this.versionSavesDir(), sv.id))
                              ? Visibility.Visible : Visibility.Hidden)
              }
              .width('100%')
              .padding({ left: 12, right: 12, top: 11, bottom: 11 })
              .borderRadius(CARD_RADIUS_VP)
              .backgroundColor($r('app.color.launcher_card'))
              .margin({ top: 6 })
              .gesture(LongPressGesture({ repeat: false, duration: 400 })
                .onAction(() => { this.enterMulti(this.saveKey(this.versionSavesDir(), sv.id)); }))
              .onClick(() => {
                if (this.multiMode) {
                  this.toggleMultiPick(this.saveKey(this.versionSavesDir(), sv.id));
                  return;
                }
                this.openSaveRow(this.versionSavesDir(), sv.id);
              })
            }, (sv: SaveEntry) => this.saveRowKey(sv))
          }
          .width('100%')
        }
        .width('100%')
        .layoutWeight(1)
        .align(Alignment.TopStart)
        .scrollBar(BarState.Off)

        if (!this.multiMode && this.selectedSave !== ''
            && this.selectedSaveDir() === this.versionSavesDir()) {
          Divider()
            .strokeWidth(1).color($r('app.color.launcher_border'))
            .margin({ top: 14, bottom: 12 })
          this.SaveActionRow()
        }
      }
    }
    .width('100%').height('100%')
    .padding({ left: 8, right: 16, top: 12 })
    .alignItems(HorizontalAlign.Start)
  }

@Builder
TransferDialog() {
    Column() {
      Column() {
        Text(this.transferSourceTitle())
          .fontSize(17).fontColor($r('sys.color.font_primary'))
          .width('100%').textAlign(TextAlign.Center)

        Text(this.transferSourceSubtitle())
          .fontSize(13).fontColor($r('sys.color.font_secondary'))
          .width('100%').textAlign(TextAlign.Center)
          .margin({ top: 10 })

        Divider().strokeWidth(1).color($r('app.color.launcher_border')).margin({ top: 14 })

        Scroll() {
          Column() {
            /* 同版本复制（仅手动存档） */
            if (this.transferOp === 'copy' && this.transferAllManual()) {
              Row() {
                Column() {
                  Text('在这个版本里再复制一份')
                    .fontSize(15)
                    .fontColor(this.isTransferPicked(DUP_KEY)
                               ? $r('sys.color.brand') : $r('sys.color.font_primary'))
                    .width('100%')
                  Text('会多出一个 `-copy`。⚠️ 游戏里它显示成「untitled」——'
                       + '存档名存在游戏设置里，改名要进游戏做。')
                    .fontSize(12).fontColor($r('sys.color.font_tertiary'))
                    .width('100%').margin({ top: 4 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                if (this.isTransferPicked(DUP_KEY)) {
                  Text('✓').fontSize(16).fontColor($r('sys.color.brand'))
                }
              }
              .width('100%').padding(14)
              .borderRadius(CARD_RADIUS_VP)
              .backgroundColor($r('app.color.launcher_bg'))
              .margin({ bottom: 8 })
              .onClick(() => { this.toggleTransferPick(DUP_KEY); })
            }

            /* 混选时提示不可复制 */
            if (this.transferOp === 'copy'
                && !this.transferAllManual() && this.transferSourceRows().length > 0) {
              Text('⚠️ 战役存档不能在同一个版本里复制 —— 一个区块出现两份存档，游戏会认不出来。'
                   + '要备份它，请复制到别的版本。')
                .fontSize(12).fontColor($r('sys.color.warning'))
                .width('100%').margin({ bottom: 10 })
            }

            /* 别的版本 */
            ForEach(this.transferTargets(), (v: VersionEntry) => {
              Row() {
                Column() {
                  Text(v.label)
                    .fontSize(15)
                    .fontColor(this.isTransferPicked(v.path)
                               ? $r('sys.color.brand') : $r('sys.color.font_primary'))
                    .width('100%')
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(this.transferTargetNote(v))
                    .fontSize(12).fontColor($r('sys.color.font_tertiary'))
                    .width('100%').margin({ top: 4 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                if (this.isTransferPicked(v.path)) {
                  Text('✓').fontSize(16).fontColor($r('sys.color.brand'))
                }
              }
              .width('100%').padding(14)
              .borderRadius(CARD_RADIUS_VP)
              .backgroundColor($r('app.color.launcher_bg'))
              .margin({ bottom: 8 })
              .onClick(() => { this.toggleTransferPick(v.path); })
            }, (v: VersionEntry) => v.path)

            if (this.transferTargets().length === 0
                && !(this.transferOp === 'copy' && this.transferAllManual())) {
              Text('没有可以选的目标 —— 先在「首页」导入另一个游戏版本。')
                .fontSize(12).fontColor($r('sys.color.font_tertiary'))
                .width('100%').margin({ top: 8 })
            }
          }
          .width('100%')
        }
        .width('100%')
        .constraintSize({ maxHeight: 320 })
        .align(Alignment.TopStart)
        .margin({ top: 12 })

        /* 上次操作结果 */
        if (this.transferNote !== '') {
          Text(this.transferNote)
            .fontSize(12).fontColor($r('sys.color.warning'))
            .width('100%').margin({ top: 10 })
        }

        Divider().strokeWidth(1).color($r('app.color.launcher_border')).margin({ top: 8 })
        Row() {
          Button(this.transferOp === 'move' ? '确定移动' : '确定复制')
            .fontSize(15)
            .layoutWeight(1)
            .enabled(this.transferPicked.length > 0)
            .onClick(() => { this.confirmTransfer(); })
          Button('取消')
            .fontSize(14)
            .layoutWeight(1)
            .margin({ left: 12 })
            .onClick(() => { this.closeTransferDialog(); })
        }
        .width('100%')
        .margin({ top: 14 })
      }
      .width('100%')
      .constraintSize({ maxWidth: this.dialogWidthVp() })
      .padding(20)
      .backgroundColor($r('app.color.launcher_card'))
      .borderRadius(CARD_RADIUS_VP)
      .alignItems(HorizontalAlign.Start)
      .onClick(() => {})
    }
    .width('100%').height('100%')
    .backgroundColor('#80000000')
    .justifyContent(FlexAlign.Center)
    .padding({ left: 32 + this.edgeVp('left'), right: 32 + this.edgeVp('right'),
               top: this.edgeVp('top'), bottom: this.edgeVp('bottom') })
    .transition(enterFade())
  }

  @Builder
  VaultView() {
    Column() {
      Row() {
        // 返回按钮，增大可点击区域
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(26).fontColor([$r('sys.color.brand')])
          .padding({ left: 10, right: 14, top: 10, bottom: 10 })
          .onClick(() => { this.closeVault(); })
        Text('回收站')
          .fontSize(18).fontColor($r('sys.color.font_primary'))
          .layoutWeight(1)
        Text(this.vaultEntries.length === 0 ? '空' : (String(this.vaultEntries.length) + ' 项'))
          .fontSize(12).fontColor($r('sys.color.font_tertiary'))
        // 清空按钮，有内容时显示，点击打开确认对话框
        if (this.vaultEntries.length > 0) {
          Text('清空')
            .fontSize(13).fontColor($r('sys.color.warning'))
            .padding({ left: 14, right: 4, top: 6, bottom: 6 })
            .onClick(() => { this.showVaultClearAsk = true; })
        }
      }
      .width('100%')
      .padding({ left: 12, right: 16, top: 16, bottom: 8 })
      .alignItems(VerticalAlign.Center)

      // 保留期设置，全局生效
      Row() {
        Text('保留')
          .fontSize(12).fontColor($r('sys.color.font_tertiary'))
        ForEach(VAULT_DAYS_CHOICES, (d: number) => {
          Text(this.vaultDaysLabel(d))
            .fontSize(13)
            .fontColor(this.vaultDays === d
                       ? $r('sys.color.font_primary') : $r('sys.color.font_secondary'))
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(9)
            .backgroundColor(this.vaultDays === d
                             ? $r('app.color.launcher_border') : $r('app.color.launcher_bg'))
            .margin({ left: 8 })
            .onClick(() => { this.setVaultDays(d); })
        }, (d: number) => String(d))
      }
      .width('100%')
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)

      // 操作结果提示
      if (this.vaultNote !== '') {
        Text(this.vaultNote)
          .fontSize(12).fontColor($r('sys.color.warning'))
          .width('100%').margin({ top: 10 }).padding({ left: 16, right: 16 })
      }
      // 清理到期条目提示
      if (this.vaultPurgedLast > 0) {
        Text('上次清理删掉了 ' + String(this.vaultPurgedLast) + ' 个到期的存档。')
          .fontSize(12).fontColor($r('sys.color.font_tertiary'))
          .width('100%').margin({ top: 10 }).padding({ left: 16, right: 16 })
      }

      Scroll() {
        Row() {
          Column() {
            if (this.vaultEntries.length === 0) {
              Text('回收站是空的')
                .fontSize(15).fontColor($r('sys.color.font_secondary'))
                .margin({ top: 20 })
              Text('删掉的存档会先放到这里，到期才真正清理')
                .fontSize(12).fontColor($r('sys.color.font_tertiary'))
                .margin({ top: 8 })
            }
            ForEach(this.vaultEntries, (e: VaultEntry) => {
              Column() {
                Row() {
                  Column() {
                    Text(e.label === '' ? e.id : e.label)
                      .fontSize(15).fontColor($r('sys.color.font_primary'))
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text('删除于 ' + formatMs(e.deletedMs) + '  ·  '
                         + String(e.count) + ' 个文件  ·  ' + formatSaveSize(e.bytes))
                      .fontSize(12).fontColor($r('sys.color.font_tertiary'))
                      .margin({ top: 4 })
                    Text('原来属于 ' + this.vaultOwnerText(e))
                      .fontSize(12).fontColor($r('sys.color.font_secondary'))
                      .margin({ top: 2 })
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(describeExpiry(e, Date.now()))
                      .fontSize(12)
                      .fontColor(e.archived
                                 ? $r('sys.color.font_secondary') : $r('sys.color.warning'))
                      .margin({ top: 2 })
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                }
                .width('100%')

                Row() {
                  Button('放回')
                    .fontSize(13)
                    .onClick(() => { this.doVaultRestore(e); })
                  Button(e.archived ? '取消归档' : '归档')
                    .fontSize(13)
                    .margin({ left: 8 })
                    .onClick(() => { this.doVaultToggleArchive(e); })
                  Button('彻底删除')
                    .fontSize(13)
                    .fontColor($r('sys.color.warning'))
                    .backgroundColor($r('app.color.launcher_bg'))
                    .margin({ left: 8 })
                    .onClick(() => { this.doVaultPurge(e); })
                }
                .width('100%')
                .margin({ top: 10 })
              }
              .width('100%')
              .padding(14)
              .borderRadius(CARD_RADIUS_VP)
              .backgroundColor($r('app.color.launcher_card'))
              .margin({ bottom: 8 })
              .alignItems(HorizontalAlign.Start)
// key 包含归档状态和到期时间，确保UI刷新
            }, (e: VaultEntry) => e.id + '|' + (e.archived ? 'a' : 'n') + '|' + String(e.expiresMs))
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 12 })
        }
        .width('100%')
        .justifyContent(FlexAlign.Start)
        .alignItems(VerticalAlign.Top)
      }
      .width('100%')
      .layoutWeight(1)
// 设置Scroll对齐方式为TopStart，避免条目居中
      .align(Alignment.TopStart)
      .scrollBar(BarState.Off)

      // 与悬浮底栏之间的留白
      Blank().height(BAR_CLEARANCE_VP)
    }
    .width('100%').height('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /* 多选删除确认框：标题为个数，名字可展开，可选回收/归档/永久删除。 */
  @Builder
  MultiDeleteAskDialog() {
    Column() {
      Column() {
        Text('删除这 ' + String(this.multiPicked.length) + ' 个存档')
          .fontSize(17).fontColor($r('sys.color.font_primary'))
          .width('100%').textAlign(TextAlign.Center)

        /* 名字行，▾/▴ 指示可展开。 */
        Row() {
          Text(this.pickedNamesText())
            .fontSize(13).fontColor($r('sys.color.font_secondary'))
            .layoutWeight(1)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.multiListOpen ? '▴' : '▾')
            .fontSize(13).fontColor($r('sys.color.brand'))
            .margin({ left: 8 })
        }
        .width('100%')
        .margin({ top: 12 })
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
        .borderRadius(9)
        .backgroundColor($r('app.color.launcher_bg'))
        .alignItems(VerticalAlign.Center)
        .onClick(() => { this.multiListOpen = !this.multiListOpen; })

        if (this.multiListOpen) {
          Scroll() {
            Column() {
              ForEach(this.pickedRows(), (r: SaveRow) => {
                Column() {
                  Text(r.entry.label)
                    .fontSize(13).fontColor($r('sys.color.font_primary'))
                    .width('100%')
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text('原来属于 ' + this.ownerOfDir(r.dir))
                    .fontSize(11).fontColor($r('sys.color.font_tertiary'))
                    .width('100%').margin({ top: 2 })
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)
                .margin({ bottom: 10 })
              }, (r: SaveRow) => this.saveKey(r.dir, r.entry.id))
            }
            .width('100%')
          }
          .width('100%')
          .constraintSize({ maxHeight: 220 })
          .align(Alignment.TopStart)
          .margin({ top: 10 })
        }

        Divider().strokeWidth(1).color($r('app.color.launcher_border')).margin({ top: 14 })

        /* 永久删除按钮（与单删共用 Builder）。 */
        this.PermanentDeleteButton()

        /* 回收/归档等宽。 */
        Row({ space: 8 }) {
          Button('回收')
            .fontSize(15)
            .layoutWeight(1)
            .constraintSize({ maxWidth: '100%' })
            .onClick(() => { this.deleteMultiToVault(false); })
          Button('归档')
            .fontSize(15)
            .layoutWeight(1)
            .constraintSize({ maxWidth: '100%' })
            .onClick(() => { this.deleteMultiToVault(true); })
        }
        .width(ASK_BTN_W)
        .alignSelf(ItemAlign.Center)
        .margin({ top: 10 })

        Text('回收：将在 ' + this.deleteExpiryText() + ' 后删除')
          .fontSize(11).fontColor($r('sys.color.font_tertiary'))
          .width('100%').margin({ top: 8 })

        Divider().strokeWidth(1).color($r('app.color.launcher_border')).margin({ top: 14 })
        Button('取消')
          .fontSize(14)
          .constraintSize({ maxWidth: '100%' }).alignSelf(ItemAlign.Center)
          .margin({ top: 12 })
          .onClick(() => { this.stopPermHold(); this.showMultiAsk = false; })
      }
      .width('100%')
      .constraintSize({ maxWidth: this.dialogWidthVp() })
      .padding(20)
      .backgroundColor($r('app.color.launcher_card'))
      .borderRadius(CARD_RADIUS_VP)
      .alignItems(HorizontalAlign.Start)
      .onClick(() => {})
    }
    .width('100%').height('100%')
    .backgroundColor('#80000000')
    .justifyContent(FlexAlign.Center)
    .padding({ left: 32 + this.edgeVp('left'), right: 32 + this.edgeVp('right'),
               top: this.edgeVp('top'), bottom: this.edgeVp('bottom') })
    .transition(enterFade())
  }

/** 清空回收站的二次确认：说明不可撤销。 */
  @Builder
  VaultClearAskDialog() {
    Column() {
      Column() {
        Text('清空回收站？')
          .fontSize(17).fontColor($r('sys.color.font_primary'))
          .width('100%').textAlign(TextAlign.Center)

        Text('这 ' + String(this.vaultEntries.length) + ' 个存档会被永久删除，不能撤销。'
             + '\n回收站之外没有第二份。')
          .fontSize(13).fontColor($r('sys.color.font_secondary'))
          .width('100%').margin({ top: 12 })

        if (this.vaultArchivedCount() > 0) {
          Text('其中 ' + String(this.vaultArchivedCount())
               + ' 个是归档的 —— 归档本来不会自动清理，只有你手动删它才会消失。')
            .fontSize(12).fontColor($r('sys.color.font_tertiary'))
            .width('100%').margin({ top: 8 })
        }

        Divider().strokeWidth(1).color($r('app.color.launcher_border')).margin({ top: 14 })

        Button('永久删除这 ' + String(this.vaultEntries.length) + ' 个')
          .fontSize(15)
          .constraintSize({ maxWidth: '100%' }).alignSelf(ItemAlign.Center)
          .margin({ top: 16 })
          .onClick(() => { this.clearVaultAll(); })

        Divider().strokeWidth(1).color($r('app.color.launcher_border')).margin({ top: 14 })
        Button('取消')
          .fontSize(14)
          .constraintSize({ maxWidth: '100%' }).alignSelf(ItemAlign.Center)
          .margin({ top: 12 })
          .onClick(() => { this.showVaultClearAsk = false; })
      }
      .width('100%')
      .constraintSize({ maxWidth: this.dialogWidthVp() })
      .padding(20)
      .backgroundColor($r('app.color.launcher_card'))
      .borderRadius(CARD_RADIUS_VP)
      .alignItems(HorizontalAlign.Start)
      .onClick(() => {})
    }
    .width('100%').height('100%')
    .backgroundColor('#80000000')
    .justifyContent(FlexAlign.Center)
    .padding({ left: 32 + this.edgeVp('left'), right: 32 + this.edgeVp('right'),
               top: this.edgeVp('top'), bottom: this.edgeVp('bottom') })
    .transition(enterFade())
  }

/* 「删除这个版本」的确认窗：代价写进按钮标签，但共用数据需单独说明。 */
/* 左滑露出的图标：只画一个图标，不画底色，避免圆角问题。 */
  @Builder
  SwipeDeleteAction(g: GameJar) {
    Row() {
      SymbolGlyph($r('sys.symbol.ohos_trash_circle'))
        .fontSize(26)
        .fontColor([$r('app.color.danger')])
    }
    .height('100%')
    .padding({ left: 16, right: 20 })
    .justifyContent(FlexAlign.Center)
    .onClick(() => { this.openGameDeleteAsk(g); })
  }


/* 原 storageSwitchLine() 已删除（用户要求）。 */

  @Builder
  GameDeleteAskDialog() {
    Column() {
      Column() {
/* 标题两行：第一行「永久删除」，第二行文件名。 */
        Text('永久删除')
          .fontSize(17).fontColor($r('app.color.danger'))
          .width('100%').textAlign(TextAlign.Center)
        Text(this.gameDeleteLabel)
          .fontSize(13).fontColor($r('sys.color.font_secondary'))
          .width('100%').textAlign(TextAlign.Center)
          .margin({ top: 6 })

        if (!this.jarHasOwnData()) {
          /* 隔离关着时只有「只删除游戏」选项。 */
          Text('这个版本用的是「未隔离」的那一份数据 —— 全应用只有那一份，'
               + '删它会把所有未隔离版本的数据一起清掉。\n所以这里只提供「只删除游戏」。')
            .fontSize(12).fontColor($r('sys.color.font_secondary'))
            .width('100%').margin({ top: 10 })
        } else if (this.otherVersionsOnSelectedDir().length > 0) {
          /* 共用数据需警告。 */
          Text('这份数据还有 ' + String(this.otherVersionsOnSelectedDir().length)
               + ' 个版本在读（' + this.otherVersionsText() + '），'
               + '里面现在有 ' + String(this.jarDataSaveCount()) + ' 个存档。'
               + '\n连数据一起删，它们也会一起没有。')
            .fontSize(12).fontColor($r('sys.color.warning'))
            .width('100%').margin({ top: 10 })
        }

        Divider().strokeWidth(1).color($r('app.color.launcher_border')).margin({ top: 14 })

        Button('只删除游戏（保留数据）')
          .fontSize(15)
          .constraintSize({ maxWidth: '100%' }).alignSelf(ItemAlign.Center)
          .margin({ top: 16 })
          .onClick(() => { this.deleteGame(false); })

        /* 数据不能删时按钮不出现。 */
        if (this.jarHasOwnData()) {
          Button('删除游戏和数据')
            .fontSize(15)
            .fontColor($r('sys.color.warning'))
            .backgroundColor($r('app.color.launcher_bg'))
            .constraintSize({ maxWidth: '100%' }).alignSelf(ItemAlign.Center)
            .margin({ top: 10 })
            .onClick(() => { this.deleteGame(true); })
        }

        Divider().strokeWidth(1).color($r('app.color.launcher_border')).margin({ top: 14 })
        Button('取消')
          .fontSize(14)
          .constraintSize({ maxWidth: '100%' }).alignSelf(ItemAlign.Center)
          .margin({ top: 12 })
          .onClick(() => { this.showGameDeleteAsk = false; })
      }
      .width('100%')
      .constraintSize({ maxWidth: this.dialogWidthVp() })
      .padding(20)
      .backgroundColor($r('app.color.launcher_card'))
      .borderRadius(CARD_RADIUS_VP)
      .alignItems(HorizontalAlign.Start)
      .onClick(() => {})
    }
    .width('100%').height('100%')
    .backgroundColor('#80000000')
    .justifyContent(FlexAlign.Center)
    .padding({ left: 32 + this.edgeVp('left'), right: 32 + this.edgeVp('right'),
               top: this.edgeVp('top'), bottom: this.edgeVp('bottom') })
    .transition(enterFade())
  }

  @Builder
  DeleteAskDialog() {
    Column() {
      Column() {
        Text('删除「' + this.selectedSaveLabel() + '」')
          .fontSize(17).fontColor($r('sys.color.font_primary'))
          .width('100%').textAlign(TextAlign.Center)

        // 说明文字在按钮下的小字里；三个去向并排：永久删除、回收、归档
        Divider().strokeWidth(1).color($r('app.color.launcher_border')).margin({ top: 14 })

        // ① 永久删除——独占一行
        this.PermanentDeleteButton()

        // ② 回收 / 归档——并列一行
        Row({ space: 8 }) {
          Button('回收')
            .fontSize(15)
            .layoutWeight(1)
            .constraintSize({ maxWidth: '100%' })
            .onClick(() => { this.doVaultDelete(false); })
          Button('归档')
            .fontSize(15)
            .layoutWeight(1)
            .constraintSize({ maxWidth: '100%' })
            .onClick(() => { this.doVaultDelete(true); })
        }
        .width(ASK_BTN_W)
        .alignSelf(ItemAlign.Center)
        .margin({ top: 10 })

        // 回收到期说明（用户 2026-10-05 指定位置与措辞）
        Text('回收：将在 ' + this.deleteExpiryText() + ' 后删除')
          .fontSize(11).fontColor($r('sys.color.font_tertiary'))
          .width('100%').margin({ top: 8 })

        Divider().strokeWidth(1).color($r('app.color.launcher_border')).margin({ top: 14 })
        Button('取消')
          .fontSize(14)
          .constraintSize({ maxWidth: '100%' }).alignSelf(ItemAlign.Center)
          .margin({ top: 12 })
          .onClick(() => { this.stopPermHold(); this.showDeleteAsk = false; })
      }
      .width('100%')
      .constraintSize({ maxWidth: this.dialogWidthVp() })
      .padding(20)
      .backgroundColor($r('app.color.launcher_card'))
      .borderRadius(CARD_RADIUS_VP)
      .alignItems(HorizontalAlign.Start)
      .onClick(() => {})
    }
    .width('100%').height('100%')
    .backgroundColor('#80000000')
    .justifyContent(FlexAlign.Center)
    .padding({ left: 32 + this.edgeVp('left'), right: 32 + this.edgeVp('right'),
               top: this.edgeVp('top'), bottom: this.edgeVp('bottom') })
    .transition(enterFade())
  }

  /* ====================================================================
   * 整包导入 / 导出
   * ==================================================================== */

  /** 临时目录（沙箱内），打包和解包用。必须钉在 NATIVE_FILES 路径上。 */
  private packTmpDir(): string {
    return '/data/storage/el2/base/files/.temp/datapack';
  }

/** 应用在 Download 里的数据根，即包名文件夹。与 games/ 并列。拿不到时返回 ''。 */
  private packRoot(): string {
    const base: string = externalRootPath(this.filesDir);
    if (base === '') {
      return '';
    }
    return isDir(base) ? base : '';
  }

  /** 导出数据包存放目录，用户可见。 */
  private exportsDir(): string {
    const root: string = this.packRoot();
    if (root === '') {
      return '';
    }
    const dir: string = root + '/exports';
    return ensureDir(dir) ? dir : '';
  }

/** 覆盖导入前的自动备份目录（用户可见 backup/），恢复方式即重新导入。 */
  private backupsDir(): string {
    const root: string = this.packRoot();
    if (root === '') {
      return '';
    }
    const dir: string = root + '/backups';
    return ensureDir(dir) ? dir : '';
  }

  /** 导入：选 zip → 拷入沙箱 → 解压 → 定位数据根 → 校验 → 问目标。每一步失败即停。 */
  private async startImport(): Promise<void> {
    this.importMsg = '';
    let uri: string = '';
    try {
      const opts: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      opts.fileSuffixFilters = ['.zip'];
      opts.maxSelectNumber = 1;
      const view: picker.DocumentViewPicker = new picker.DocumentViewPicker(getContext(this) as common.Context);
      const uris: Array<string> = await view.select(opts);
      if (uris === undefined || uris.length === 0 || uris[0] === '') {
        return;
      }
      uri = uris[0];
    } catch (e) {
      const err = e as BusinessError;
      this.showNotice('打不开文件选择器：' + err.message + ' (code=' + err.code + ')', 'import');
      return;
    }

    const tmp: string = this.packTmpDir();
    if (!ensureDir(tmp)) {
      this.showNotice('建不出临时目录。', 'import');
      return;
    }
    const localZip: string = tmp + '/import.zip';
    const staging: string = tmp + '/incoming';
    this.importMsg = '正在读取压缩包…';

    const copyErr: string = await readUriToFile(uri, localZip);
    if (copyErr !== '') { this.showNotice(copyErr, 'import'); return; }

    const acc: TreeStat = newTreeStat();
    removeTree(staging, 0, acc);
    this.importMsg = '正在解压…';
    const unErr: string = await unpackZip(localZip, staging);
    if (unErr !== '') { this.showNotice(unErr, 'import'); return; }

    this.importMsg = '正在检查内容…';
    const root: string = locateDataRoot(staging);
    if (root === '') {
      this.showNotice('这个包里找不到游戏数据（既没有 saves/，也没有 mods/ 或 settings.bin），'
                      + '或者里面有好几个候选目录、分不清哪个才是。', 'import');
      return;
    }
    const vErr: string = validatePack(root);
    if (vErr !== '') { this.showNotice(vErr, 'import'); return; }

    // 到这一步才允许问「放到哪」
    this.importRoot = root;
    this.importNote = countPackable(root);
    this.importMsg = '';
    // 每次打开清空勾选（防止上次取消后残留覆盖目标）
    this.importPicked = [];
    // 计算 live 目标信息
    const live: VersionEntry = this.liveImportTarget();
    this.importLiveDir = live.dataDir;
    this.importLiveHasData = live.hasData;
    this.importLiveCount = live.saveCount;
    this.importOpen = true;
  }

  private async importIntoOne(t: VersionEntry, index: number,
                              out: ImportOutcome): Promise<void> {
    const label: string = t.version === '' ? t.label : ('v' + t.version);
    if (t.dataDir === '') {
      out.fails.push(t.label + '：没有数据目录（读不出隔离键）');
      return;
    }
    if (!ensureDir(t.dataDir)) {
      out.fails.push(t.label + '：建不出目标目录');
      return;
    }

    if (packableItems(t.dataDir).length > 0) {
      this.importMsg = '正在备份「' + t.label + '」…';
      const bak: string = this.backupPathFor(label, index);
      const err: string = await packDataDir(t.dataDir, this.packTmpDir(), bak);
      if (err !== '') {
        out.fails.push(t.label + '：备份失败，已跳过（它的数据没动）—— ' + err);
        return;
      }
      out.backups += 1;
      out.anyBackupInSandbox = out.anyBackupInSandbox || (this.backupsDir() === '');
    }

    this.importMsg = '正在写入「' + t.label + '」…';
    const acc: TreeStat = newTreeStat();
    copyTreeInto(this.importRoot, t.dataDir, 0, acc);
    out.dirs += acc.dirs;
    out.files += acc.files;
    if (acc.failed > 0) {
      out.fails.push(t.label + '：' + acc.firstError);
      return;
    }
    out.done += 1;
  }

  private async confirmImport(): Promise<void> {
    const targets: VersionEntry[] = this.pickedTargets();
    if (targets.length === 0) {
      return;
    }
    this.importOpen = false;
    this.importMsg = '正在导入…';

    const out: ImportOutcome = newImportOutcome();
    for (let i: number = 0; i < targets.length; i += 1) {
      await this.importIntoOne(targets[i], i, out);
    }

    const clean: TreeStat = newTreeStat();
    removeTree(this.importRoot, 0, clean);
    this.importRoot = '';
    this.importMsg = '';
    this.importPicked = [];
    this.refresh();

    const head: string = out.done === 0
      ? '没有一处导入成功。'
      : ('已导入到 ' + String(out.done) + ' 处（合计 '
         + String(out.dirs) + ' 个目录 / ' + String(out.files) + ' 个文件）');
    const bakNote: string = out.backups === 0 ? ''
      : ('\n覆盖前的备份有 ' + String(out.backups) + ' 份，在 '
         + (out.anyBackupInSandbox
            ? '⚠️ 应用沙箱里（外面拿不到），「导入数据」也够不着它'
            : this.backupsDir())
         + ' —— 要恢复就用「导入数据」再选那个文件。');
    const failNote: string = out.fails.length === 0 ? ''
      : ('\n有 ' + String(out.fails.length) + ' 处没成功：' + out.fails.join('；'));
    this.showNotice(head + bakNote + failNote + '\n需要重启游戏才看得到。', 'toast');
  }

  private pickedTargets(): VersionEntry[] {
    const all: VersionEntry[] = [this.liveImportTarget()];
    for (const v of this.versions) {
      all.push(v);
    }
    const out: VersionEntry[] = [];
    const seen: string[] = [];
    for (const t of all) {
      if (this.importPicked.indexOf(t.dataDir) < 0) {
        continue;
      }
      if (t.dataDir === '' || seen.indexOf(t.dataDir) >= 0) {
        continue;
      }
      seen.push(t.dataDir);
      out.push(t);
    }
    return out;
  }

  private isImportPicked(dir: string): boolean {
    return dir !== '' && this.importPicked.indexOf(dir) >= 0;
  }

  private toggleImportPick(dir: string): void {
    if (dir === '') {
      return;
    }
    const i: number = this.importPicked.indexOf(dir);
    if (i < 0) {
      this.importPicked = this.importPicked.concat([dir]);
      return;
    }
    const next: string[] = this.importPicked.slice();
    next.splice(i, 1);
    this.importPicked = next;
  }

  private pickAllImportTargets(): void {
    const all: VersionEntry[] = [this.liveImportTarget()];
    for (const v of this.versions) {
      all.push(v);
    }
    const out: string[] = [];
    for (const t of all) {
      if (t.dataDir !== '' && out.indexOf(t.dataDir) < 0) {
        out.push(t.dataDir);
      }
    }
    this.importPicked = out;
  }

  private backupPathFor(label: string, index: number): string {
    const base: string = 'Mindustry-' + label + '-' + stampNow()
                         + (index > 0 ? '-' + String(index + 1) : '');
    const dir: string = this.backupsDir();
    if (dir === '') {
      return this.packTmpDir() + '/' + base + '-backup.zip';
    }
    let p: string = dir + '/' + base + '-backup.zip';
    for (let n: number = 2; pathExists(p) && n < 1000; n += 1) {
      p = dir + '/' + base + '-' + String(n) + '-backup.zip';
    }
    return p;
  }

  private closePackNotice(): void {
    this.importMsg = '';
    this.exportMsg = '';
    this.importToast = '';
  }

  private showNotice(text: string, kind: string): void {
    if (kind === 'import') { this.importMsg = text; }
    else if (kind === 'toast') { this.importToast = text; }
    else { this.exportMsg = text; }
    setTimeout(() => {
      if (kind === 'import') {
        if (this.importMsg === text) { this.importMsg = ''; }
      } else if (kind === 'toast') {
        if (this.importToast === text) { this.importToast = ''; }
      } else {
        if (this.exportMsg === text) { this.exportMsg = ''; }
      }
    }, NOTICE_MS);
  }

  private async exportVersion(v: VersionEntry): Promise<void> {
    this.exportMsg = '';
    const tmp: string = this.packTmpDir();
    const zip: string = tmp + '/export.zip';
    this.exportMsg = '正在打包…';
    const err: string = await packDataDir(v.dataDir, tmp, zip);
    if (err !== '') { this.exportMsg = err; return; }

    const who: string = v.version === '' ? v.label : v.version;
    const outName: string = 'Mindustry-' + who + '-' + stampNow() + '.zip';

    const dir: string = this.exportsDir();
    if (dir === '') {
      this.showNotice('导出失败：拿不到用户可见的文件夹（下载目录里本应用的那个）。'
                      + '如果这个提示反复出现，请把它截图发我 —— 我需要知道是「文件夹不存在」'
                      + '还是「不允许写」。', 'export');
      return;
    }
    const outPath: string = dir + '/' + outName;
    const wErr: string = await copyLocalFile(zip, outPath);
    this.showNotice(wErr === '' ? '已导出：' + outPath : wErr, 'export');
  }

  private liveImportTarget(): VersionEntry {
    const dir: string = liveGameDataDir();
    const c: GameDataCounts = countsOf(dir);
    return {
      path: LIVE_TARGET_PATH,
      source: 'live',
      label: '未隔离的那一份',
      version: '',
      key: '',
      dataDir: dir,
      isCurrent: false,
      saveCount: c.sectorSaves + c.manualSaves,
      hasData: gameDataExists(dir),
    };
  }

  @Builder
  ImportTargetDialog() {
    Column() {
      Column() {
        Text('导入到哪一份数据？')
          .fontSize(17).fontColor($r('sys.color.font_primary'))
          .width('100%').textAlign(TextAlign.Center)

        Text('这个包里是：' + (this.importNote === '' ? '（读不出内容清单）' : this.importNote))
          .fontSize(12).fontColor($r('sys.color.font_secondary'))
          .width('100%').textAlign(TextAlign.Center)
          .margin({ top: 8 })

        Scroll() {
          Column() {
            Row() {
              Column() {
                Text('未隔离的那一份')
                  .fontSize(15)
                  .fontColor(this.isImportPicked(this.importLiveDir)
                             ? $r('sys.color.brand') : $r('sys.color.font_primary'))
                  .width('100%')
                Text('所有版本共用它（隔离关着时就是这里）'
                     + (this.importLiveHasData
                        ? '　已有 ' + String(this.importLiveCount) + ' 个存档'
                        : '　还没有数据'))
                  .fontSize(12)
                  .fontColor(this.importLiveHasData
                             ? $r('sys.color.font_secondary') : $r('sys.color.brand'))
                  .width('100%').margin({ top: 3 })
              }
              .alignItems(HorizontalAlign.Start).layoutWeight(1)
              if (this.isImportPicked(this.importLiveDir)) {
                Text('✓').fontSize(16).fontColor($r('sys.color.brand'))
              }
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })
            .backgroundColor($r('app.color.launcher_card'))
            .borderRadius(CARD_RADIUS_VP)
            .margin({ top: 8 })
            .onClick(() => { this.toggleImportPick(this.importLiveDir); })

            ForEach(this.versions, (v: VersionEntry) => {
              Row() {
                Column() {
                  Text(v.label + (v.version === '' ? '' : '  ' + v.version))
                    .fontSize(15)
                    .fontColor(this.isImportPicked(v.dataDir)
                               ? $r('sys.color.brand') : $r('sys.color.font_primary'))
                    .width('100%')
                  Text(v.hasData
                       ? ('已有数据（' + String(v.saveCount) + ' 个存档）—— 会先备份再覆盖')
                       : '没有数据 —— 会新建一份')
                    .fontSize(12)
                    .fontColor(v.hasData ? $r('sys.color.font_secondary') : $r('sys.color.brand'))
                    .width('100%').margin({ top: 3 })
                }
                .alignItems(HorizontalAlign.Start).layoutWeight(1)
                if (v.isCurrent) {
                  Text('当前').fontSize(12).fontColor($r('sys.color.font_tertiary'))
                }
                if (this.isImportPicked(v.dataDir)) {
                  Text('✓').fontSize(16).fontColor($r('sys.color.brand'))
                }
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 12, bottom: 12 })
              .backgroundColor($r('app.color.launcher_card'))
              .borderRadius(CARD_RADIUS_VP)
              .margin({ top: 8 })
              .onClick(() => { this.toggleImportPick(v.dataDir); })
            }, (v: VersionEntry) => v.path)
          }
          .width('100%')
        }
        .height(300)
        .scrollBar(BarState.Off)
        .align(Alignment.TopStart)
        .margin({ top: 10 })

        Row() {
          Text('全选')
            .fontSize(13).fontColor($r('sys.color.brand'))
            .padding({ top: 12, bottom: 6, right: 20 })
            .onClick(() => { this.pickAllImportTargets(); })
          Text('全不选')
            .fontSize(13).fontColor($r('sys.color.font_secondary'))
            .padding({ top: 12, bottom: 6 })
            .onClick(() => { this.importPicked = []; })
        }
        .width('100%')
        .justifyContent(FlexAlign.Start)

        Text(this.importPicked.length === 0
             ? '请先选目标'
             : ('导入到 ' + String(this.importPicked.length) + ' 处'))
          .fontSize(15)
          .fontColor(this.importPicked.length === 0
                     ? $r('sys.color.font_tertiary') : $r('sys.color.brand'))
          .padding({ top: 14, bottom: 6 })
          .onClick(() => {
            if (this.importPicked.length > 0) {
              this.confirmImport();
            }
          })

        Text('取消')
          .fontSize(14).fontColor($r('sys.color.font_secondary'))
          .padding({ top: 8, bottom: 4 })
          .onClick(() => { this.importOpen = false; })
      }
      .width('86%')
      .constraintSize({ maxWidth: 460 })
      .padding(16)
      .backgroundColor($r('app.color.launcher_bg'))
      .borderRadius(CARD_RADIUS_VP)
    }
    .width('100%').height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#F01C1C1C')
    .padding({ left: 32 + this.edgeVp('left'), right: 32 + this.edgeVp('right'),
               top: this.edgeVp('top'), bottom: this.edgeVp('bottom') })
    .transition(enterFade())
  }

  @Builder
  PackNotice() {
    Row() {
      Text(this.importToast !== '' ? this.importToast
           : (this.importMsg !== '' ? this.importMsg : this.exportMsg))
        .fontSize(13).fontColor($r('sys.color.font_primary'))
        .layoutWeight(1)
      Text('✕')
        .fontSize(15).fontColor($r('sys.color.font_secondary'))
        .padding({ left: 14, right: 2, top: 2, bottom: 2 })
        .onClick(() => { this.closePackNotice(); })
    }
    .width('86%')
    .constraintSize({ maxWidth: 420 })
    .padding({ left: 16, right: 12, top: 12, bottom: 12 })
    .backgroundColor($r('app.color.launcher_card'))
    .borderRadius(CARD_RADIUS_VP)
    .margin({ top: this.edgeVp('top') + 12 })
    .transition(enterFade())
  }

  @Builder
  SavesTab() {
    Column() {
      if (this.showVault) {
        this.VaultView()
      } else if (this.isNarrow() && this.panelOpen) {
        Row() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(26).fontColor([$r('sys.color.brand')])
            .padding({ left: 10, right: 14, top: 10, bottom: 10 })
            .onClick(() => { this.panelOpen = false; })
          Text(this.savesView === SAVES_VIEW_VERSION
               ? this.selectedVersionLabel() : this.selectedSaveLabel())
            .fontSize(18).fontColor($r('sys.color.font_primary'))
            .layoutWeight(1)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .padding({ left: 12, right: 16, top: 16, bottom: 8 })
        .alignItems(VerticalAlign.Center)

        Column() {
          if (this.savesView === SAVES_VIEW_VERSION) {
            this.VersionDataPanel()
          } else {
            this.SaveDataPanel()
          }
        }
        .width('100%')
        .layoutWeight(1)
      } else {
        Column() {
          Row() {
            Text('按存档')
              .fontSize(13)
              .fontColor(this.savesView === SAVES_VIEW_SAVE
                         ? $r('sys.color.font_primary') : $r('sys.color.font_secondary'))
              .padding({ left: 12, right: 12, top: 7, bottom: 7 })
              .borderRadius(9)
              .backgroundColor(this.savesView === SAVES_VIEW_SAVE
                               ? $r('app.color.launcher_border') : $r('app.color.launcher_bg'))
              .onClick(() => {
                this.savesView = SAVES_VIEW_SAVE;
                this.panelOpen = false;
              })
            Text('按版本')
              .fontSize(13)
              .fontColor(this.savesView === SAVES_VIEW_VERSION
                         ? $r('sys.color.font_primary') : $r('sys.color.font_secondary'))
              .padding({ left: 12, right: 12, top: 7, bottom: 7 })
              .borderRadius(9)
              .backgroundColor(this.savesView === SAVES_VIEW_VERSION
                               ? $r('app.color.launcher_border') : $r('app.color.launcher_bg'))
              .margin({ left: 8 })
              .onClick(() => {
                this.savesView = SAVES_VIEW_VERSION;
                this.panelOpen = false;
              })
            Blank()
            if (this.savesView === SAVES_VIEW_VERSION && this.selectedVersionEntry() !== undefined) {
              Text('导出')
                .fontSize(13).fontColor($r('sys.color.brand'))
                .padding({ left: 4, right: 12, top: 7, bottom: 7 })
                .onClick(() => {
                  const v: VersionEntry | undefined = this.selectedVersionEntry();
                  if (v !== undefined) { this.exportVersion(v); }
                })
            }
            Text('导入数据')
              .fontSize(13).fontColor($r('sys.color.brand'))
              .padding({ left: 12, right: 12, top: 7, bottom: 7 })
              .onClick(() => { this.startImport(); })
            Text(this.vaultEntries.length === 0
                 ? '回收站'
                 : ('回收站 ' + String(this.vaultEntries.length)))
              .fontSize(13).fontColor($r('sys.color.brand'))
              .padding({ left: 12, right: 4, top: 7, bottom: 7 })
              .onClick(() => { this.openVault(); })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Text(this.savesHeaderLine())
            .fontSize(11).fontColor($r('sys.color.font_tertiary'))
            .margin({ top: 8 })
            .copyOption(CopyOptions.LocalDevice)

          if (this.multiMode && this.savesView === SAVES_VIEW_SAVE) {
            this.MultiBar()
          }
          if (this.savesNote !== '') {
            Text(this.savesNote)
              .fontSize(12).fontColor($r('sys.color.font_secondary'))
              .width('100%').margin({ top: 8 })
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 20 })
        .alignItems(HorizontalAlign.Start)

        Row() {
          Scroll() {
            Row() {
              Column() {
                if (this.savesView === SAVES_VIEW_VERSION) {
                  if (this.versions.length === 0) {
                    Text('没有可用的游戏版本')
                      .fontSize(14).fontColor($r('sys.color.font_secondary'))
                      .margin({ top: 20 })
                  }
                  ForEach(this.versions, (v: VersionEntry) => {
                    Row() {
                      Column() {
                        Text(v.version === '' ? '未知版本' : v.version)
                          .fontSize(15)
                          .fontColor(this.selectedVersion === v.path
                                     ? $r('sys.color.brand') : $r('sys.color.font_primary'))
                          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                        Text(v.label + '  ·  ' + this.versionSavesLine(v))
                          .fontSize(12).fontColor($r('sys.color.font_tertiary'))
                          .margin({ top: 4 })
                          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                      }
                      .alignItems(HorizontalAlign.Start)
                      .layoutWeight(1)

                      if (this.selectedVersion === v.path) {
                        Text('✓')
                          .fontSize(16).fontColor($r('sys.color.brand'))
                      }
                    }
                    .width('100%')
                    .padding(14)
                    .borderRadius(CARD_RADIUS_VP)
                    .backgroundColor($r('app.color.launcher_card'))
                    .margin({ bottom: 8 })
                    .onClick(() => { this.openVersionRow(v.path); })
                  }, (v: VersionEntry) => this.versionRowKey(v))
                } else if (this.saveGroups.length === 0) {
                  Text('没有存档')
                    .fontSize(15).fontColor($r('sys.color.font_secondary'))
                    .margin({ top: 20 })
                  Text('进游戏玩一局，存档会出现在这里')
                    .fontSize(12).fontColor($r('sys.color.font_tertiary'))
                    .margin({ top: 8 })
                } else {
                  if (this.isolationStale && !this.staleIgnored) {
                    this.StaleCopyOffer()
                  }
                  ForEach(this.saveGroups, (g: SaveGroup) => {
                    Column() {
                      Text(this.groupTitle(g))
                        .fontSize(13).fontColor($r('sys.color.font_secondary'))
                        .width('100%')
                        .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                      Text(this.groupSub(g))
                        .fontSize(11).fontColor($r('sys.color.font_tertiary'))
                        .width('100%').margin({ top: 2 })

                      if (g.saves.length === 0) {
                        Text('这个目录还没有存档')
                          .fontSize(12).fontColor($r('sys.color.font_tertiary'))
                          .width('100%').margin({ top: 8 })
                      }
                      ForEach(g.saves, (sv: SaveEntry) => {
                        Row() {
                          Column() {
                            Text(sv.label)
                              .fontSize(15)
                              .fontColor(this.rowHot(this.saveKey(g.dir, sv.id))
                                         ? $r('sys.color.brand') : $r('sys.color.font_primary'))
                              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                            Text((sv.kind === 'sector' ? (sv.sectors + ' 个区块 · ') : '')
                                 + formatSaveSize(sv.bytes) + ' · ' + formatSaveDate(sv.mtime))
                              .fontSize(12).fontColor($r('sys.color.font_tertiary'))
                              .margin({ top: 4 })
                          }
                          .alignItems(HorizontalAlign.Start)
                          .layoutWeight(1)

                          if (this.rowHot(this.saveKey(g.dir, sv.id))) {
                            Text('✓')
                              .fontSize(16).fontColor($r('sys.color.brand'))
                          }
                        }
                        .width('100%')
                        .padding(14)
                        .borderRadius(CARD_RADIUS_VP)
                        .backgroundColor($r('app.color.launcher_card'))
                        .margin({ top: 8 })
                        .gesture(LongPressGesture({ repeat: false, duration: 400 })
                          .onAction(() => { this.enterMulti(this.saveKey(g.dir, sv.id)); }))
                        .onClick(() => {
                          if (this.multiMode) {
                            this.toggleMultiPick(this.saveKey(g.dir, sv.id));
                            return;
                          }
                          this.openSaveRow(g.dir, sv.id);
                        })
                      }, (sv: SaveEntry) => this.saveRowKey(sv))
                    }
                    .width('100%')
                    .margin({ bottom: 16 })
                    .alignItems(HorizontalAlign.Start)
                  }, (g: SaveGroup) => this.groupKey(g))
                }
              }
              .width('100%')
              .padding({ left: 16, right: 8, top: 12 })
            }
            .width('100%')
            .justifyContent(FlexAlign.Start)
            .alignItems(VerticalAlign.Top)
          }
          .layoutWeight(3)
          .height('100%')
          .align(Alignment.TopStart)
          .scrollBar(BarState.Off)

          if (!this.isNarrow()) {
            Column() {
              if (this.savesView === SAVES_VIEW_VERSION) {
                this.VersionDataPanel()
              } else {
                this.SaveDataPanel()
              }
            }
            .width('100%')
            .height('100%')
            .layoutWeight(7)
          }
        }
        .width('100%')
        .layoutWeight(1)
        .alignItems(VerticalAlign.Top)
      }

      Blank().height(BAR_CLEARANCE_VP)
    }
    .width('100%').height('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  SettingsTab() {
    Scroll() {
      Column() {
        Text('游戏')
          .fontSize(13).fontColor($r('sys.color.font_secondary'))
          .width('100%')
        Column() {
          Text('游戏 jar 目录')
            .fontSize(14).fontColor($r('sys.color.font_primary'))
          Text(this.jarDirHuman === '' ? '　' : this.jarDirHuman)
            .fontSize(13).fontColor($r('sys.color.font_secondary'))
            .margin({ top: 4 })
          Text(this.jarDirHint === '' ? '（本设备上拿不到）' : this.jarDirHint)
            .fontSize(12).fontColor($r('sys.color.font_tertiary'))
            .margin({ top: 2 })
            .copyOption(CopyOptions.LocalDevice)

          Divider().strokeWidth(1).color($r('app.color.launcher_border'))
            .margin({ top: 14, bottom: 14 })

          Row() {
            Column() {
              Text('本次启动将加载')
                .fontSize(14).fontColor($r('sys.color.font_primary'))
              Text(this.resolution.path === ''
                     ? '（没有可加载的游戏）'
                     : (this.resolution.source === 'user' ? '（玩家选择的）' : '（包内自带的）'))
                .fontSize(12).fontColor($r('sys.color.font_tertiary'))
                .margin({ top: 4 })
              Text(this.resolution.path === '' ? '—' : this.resolution.path)
                .fontSize(12).fontColor($r('sys.color.font_tertiary'))
                .margin({ top: 4 })
                .copyOption(CopyOptions.LocalDevice)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Button('重新扫描')
              .fontSize(BUTTON_FONT_VP)
              .margin({ left: 12 })
              .onClick(() => { this.refresh(); })
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        }
        .width('100%').padding(16)
        .backgroundColor($r('app.color.launcher_card'))
        .borderRadius(CARD_RADIUS_VP)
        .alignItems(HorizontalAlign.Start)
        .margin({ top: 8 })

        /* ================= 外观 ================= */
        Text('外观')
          .fontSize(13).fontColor($r('sys.color.font_secondary'))
          .width('100%')
          .margin({ top: 20 })
        /* 两个开关：深色模式 + 跟随系统。跟随系统开启时不渲染第二个开关（用户要求）。 */
        Column() {
          Row() {
            Text('跟随系统深色模式')
              .fontSize(14).fontColor($r('sys.color.font_primary'))
              .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.darkFollow })
              .onChange((on: boolean) => {
                this.darkFollow = on;
                writeAppearance(this.filesDir, this.darkFollow, this.darkOn);
                this.applyColorMode();
              })
          }
          .width('100%')

          if (!this.darkFollow) {
            Row() {
              Text('深色模式')
                .fontSize(14).fontColor($r('sys.color.font_primary'))
                .layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.darkOn })
                .onChange((on: boolean) => {
                  this.darkOn = on;
                  writeAppearance(this.filesDir, this.darkFollow, this.darkOn);
                  this.applyColorMode();
                })
            }
            .width('100%')
            .margin({ top: 18 })
          }
        }
        .width('100%').padding(16)
        .backgroundColor($r('app.color.launcher_card'))
        .borderRadius(CARD_RADIUS_VP)
        .margin({ top: 8 })

        /* --- 异形屏避让 --- */
        /* 卡片容器必须独立（用户曾指出贴在一起的问题）。格式与“启动时直接进游戏”一致。 */
        Column() {
          Row() {
            Column() {
              Text('异形屏避让')
                .fontSize(14).fontColor($r('sys.color.font_primary'))
              /* 副标题一行说明自动/手动及当前值。不再分开两行（用户要求精简）。 */
              Text(this.safeAuto
                   ? (this.detectedSafeVp === 0 ? '自动 · 无需避让'
                      : ('自动 · ' + this.edgeNames() + ' ' + this.safeVp + ' vp'))
                   : ('手动 · ' + this.edgeNames() + ' ' + this.safeVp + ' vp'))
                .fontSize(12).fontColor($r('sys.color.font_tertiary'))
                .margin({ top: 4 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Toggle({ type: ToggleType.Switch, isOn: this.safeAuto })
              .onChange((on: boolean) => {
                this.getUIContext().animateTo(
                  { duration: 200, curve: Curve.FastOutSlowIn }, () => {
                    this.safeAuto = on;
                    if (on) {
                      this.safeVp = this.detectedSafeVp;
                    }
                  });
                writeSafePref(this.filesDir, this.safeAuto, this.safeVp);
              })
          }
          .width('100%')
          /* 滑条区域用高度控制显隐（而非 if）以保证动画流畅。开关本身必须一直在。 */
          Column() {
            Slider({
              value: this.safeVp,
              min: 0,
              max: SAFE_VP_MAX,
              step: SAFE_VP_STEP,
              style: SliderStyle.OutSet
            })
              .width('100%')
              .margin({ top: 6 })
              .onChange((v: number, mode: SliderChangeMode) => {
                const nv: number = Math.round(v);
                const end: boolean = (mode === SliderChangeMode.End
                                      || mode === SliderChangeMode.Click);
                /* 防止无变化更新，但写盘路径必须跳过这个守卫。 */
                if (nv === this.safeVp && !this.safeAuto && !end) {
                  return;
                }
                this.safeAuto = false;
                this.safeVp = nv;
                if (end) {
                  writeSafePref(this.filesDir, false, nv);
                  dumpSafeArea('\n--- slide ---\nwrote user ' + nv + ' vp\n', true);
                }
              })
          }
          .width('100%')
          .height(this.safeAuto ? 0 : SAFE_REVEAL_VP)
          .clip(true)
        }
        /* 卡片内边距统一为16（与其它卡片一致）。滑条与标题的间距由滑条自己的 margin 控制。 */
        .width('100%').padding(16)
        .backgroundColor($r('app.color.launcher_card'))
        .borderRadius(CARD_RADIUS_VP)
        .margin({ top: 8 })

        /* ================= 数据 ================= */
        Text('数据')
          .fontSize(13).fontColor($r('sys.color.font_secondary'))
          .width('100%')
          .margin({ top: 20 })
        Column() {
          Text('数据隔离')
            .fontSize(14).fontColor($r('sys.color.font_primary'))
          Text('把不同游戏版本的存档、蓝图、模组、研究进度分开保存')
            .fontSize(12).fontColor($r('sys.color.font_tertiary'))
            .margin({ top: 4 })

          /* 四个选项并列一行（互斥四选一），支持换行，间距用右边+下边。选中/未选中背景色区分。 */
          Flex({ wrap: FlexWrap.Wrap }) {
            Text('不隔离')
              .fontSize(13)
              .fontColor(this.granularity === GRANULARITY_OFF
                         ? $r('sys.color.font_primary') : $r('sys.color.font_secondary'))
              .padding({ left: 12, right: 12, top: 7, bottom: 7 })
              .borderRadius(9)
              .backgroundColor(this.granularity === GRANULARITY_OFF
                               ? $r('app.color.launcher_border') : $r('app.color.launcher_bg'))
              .margin({ right: 8, bottom: 8 })
              .onClick(() => { this.chooseGranularity(GRANULARITY_OFF); })
            Text('大版本')
              .fontSize(13)
              .fontColor(this.granularity === GRANULARITY_NUMBER
                         ? $r('sys.color.font_primary') : $r('sys.color.font_secondary'))
              .padding({ left: 12, right: 12, top: 7, bottom: 7 })
              .borderRadius(9)
              .backgroundColor(this.granularity === GRANULARITY_NUMBER
                               ? $r('app.color.launcher_border') : $r('app.color.launcher_bg'))
              .margin({ right: 8, bottom: 8 })
              .onClick(() => { this.chooseGranularity(GRANULARITY_NUMBER); })
            Text('构建号')
              .fontSize(13)
              .fontColor(this.granularity === GRANULARITY_BUILD
                         ? $r('sys.color.font_primary') : $r('sys.color.font_secondary'))
              .padding({ left: 12, right: 12, top: 7, bottom: 7 })
              .borderRadius(9)
              .backgroundColor(this.granularity === GRANULARITY_BUILD
                               ? $r('app.color.launcher_border') : $r('app.color.launcher_bg'))
              .margin({ right: 8, bottom: 8 })
              .onClick(() => { this.chooseGranularity(GRANULARITY_BUILD); })
            Text('小版本')
              .fontSize(13)
              .fontColor(this.granularity === GRANULARITY_PATCH
                         ? $r('sys.color.font_primary') : $r('sys.color.font_secondary'))
              .padding({ left: 12, right: 12, top: 7, bottom: 7 })
              .borderRadius(9)
              .backgroundColor(this.granularity === GRANULARITY_PATCH
                               ? $r('app.color.launcher_border') : $r('app.color.launcher_bg'))
              .margin({ right: 8, bottom: 8 })
              .onClick(() => { this.chooseGranularity(GRANULARITY_PATCH); })
          }
          .width('100%').margin({ top: 12 })

          Text(this.granularityHintText)
            .fontSize(12).fontColor($r('sys.color.font_secondary'))
            .margin({ top: 10 })

          /* 残留状态的出口（诊断而非错误提醒）。 */
          if (this.isolationStale && !this.staleIgnored) {
            this.StaleCopyOffer()
          }

          /* 迁移问题的提示，与上方用分隔线隔开。 */
          if (this.isolationNote !== '') {
            Divider().strokeWidth(1).color($r('app.color.launcher_border')).margin({ top: 10 })
            Text(this.isolationNote)
              .fontSize(12).fontColor($r('sys.color.font_tertiary'))
              .width('100%').margin({ top: 8 })
          }
        }
        .width('100%').padding(16)
        .backgroundColor($r('app.color.launcher_card'))
        .borderRadius(CARD_RADIUS_VP)
        .alignItems(HorizontalAlign.Start)
        .margin({ top: 8 })

        /* --- 存储位置 --- */
        /* 第一步只展示，不提供切换（用户确认）。两行分开报：意图与实际。 */
        Column() {
          Row() {
            Column() {
              Text('使用外置存储')
                .fontSize(14).fontColor($r('sys.color.font_primary'))
              Text(this.storageIntent === STORAGE_MODE_EXTERNAL
                   ? '游戏数据放在「下载」里的应用文件夹（data 子目录）'
                   : '游戏数据放在应用内部（沙箱）')
                .fontSize(12).fontColor($r('sys.color.font_tertiary'))
                .margin({ top: 4 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            /* isOn 绑独立 State（避免取消后开关状态不变），搬移期间置灰。 */
            Toggle({ type: ToggleType.Switch, isOn: this.storageToggleOn })
              .enabled(!this.storageBusy)
              .onChange((on: boolean) => { this.askStorageSwitch(on); })
          }
          .width('100%')

          /* 搬移提示 */
          if (this.storageBusy) {
            Text('正在搬移，请勿退出…')
              .fontSize(12).fontColor($r('sys.color.font_secondary'))
              .width('100%').margin({ top: 8 })
          }

          /* 删除了“上次启动”提示（切换时游戏进程已关闭，无需重启立即生效）。 */

          /* 出错提示：原样显示探针消息。 */
          if (this.storageNote !== '') {
            Text(this.storageNote)
              .fontSize(12).fontColor($r('sys.color.warning'))
              .width('100%').margin({ top: 8 })
          }
        }
        .width('100%').padding(16)
        .backgroundColor($r('app.color.launcher_card'))
        .borderRadius(CARD_RADIUS_VP)
        .margin({ top: 8 })

        /* ===== 启动 ===== */
        Text('启动')
          .fontSize(13).fontColor($r('sys.color.font_secondary'))
          .width('100%')
          .margin({ top: 20 })
        Column() {
          /* 启动后进哪里 */
          Row() {
            Column() {
              Text('启动时直接进游戏')
                .fontSize(14).fontColor($r('sys.color.font_primary'))
              Text(this.launchMode === LAUNCH_MODE_GAME
                   ? '跳过这个界面，直接开始游戏'
                   : '先停在这个界面，由你点「启动游戏」')
                .fontSize(12).fontColor($r('sys.color.font_tertiary'))
                .margin({ top: 4 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Toggle({ type: ToggleType.Switch,
                     isOn: this.launchMode === LAUNCH_MODE_GAME })
              .onChange((on: boolean) => {
                this.launchMode = on ? LAUNCH_MODE_GAME : LAUNCH_MODE_HOME;
                writeLaunchMode(this.filesDir, this.launchMode);
              })
          }
          .width('100%')

          /* 游戏语言跟随系统 */
          Row() {
            Text('游戏语言跟随系统')
              .fontSize(14).fontColor($r('sys.color.font_primary'))
              .layoutWeight(1)

            Toggle({ type: ToggleType.Switch, isOn: this.gameLocaleFollow })
              .onChange((on: boolean) => {
                this.gameLocaleFollow = on;
                writeGameLocaleFollow(this.filesDir, on);
                this.rewriteBridge();
              })
          }
          .width('100%')
          .margin({ top: 18 })
        }
        .width('100%').padding(16)
        .backgroundColor($r('app.color.launcher_card'))
        .borderRadius(CARD_RADIUS_VP)
        .margin({ top: 8 })

        /* ===== 游戏内显示 ===== */
        Text('游戏内显示')
          .fontSize(13).fontColor($r('sys.color.font_secondary'))
          .width('100%')
          .margin({ top: 20 })
        Column() {
          /* 自动异形屏适配（实验性） */
          Row() {
            Text('自动异形屏适配（实验性）')
              .fontSize(14).fontColor($r('sys.color.font_primary'))
              .layoutWeight(1)

            Toggle({ type: ToggleType.Switch, isOn: this.gameAuto })
              .onChange((on: boolean) => {
                this.gameAuto = on;
                if (on) {
                  this.seedGameEdgeFromDevice();
                }
                this.saveGameDisplay();
              })
          }
          .width('100%')

          /* 只覆盖默认设置 */
          Text('只覆盖默认设置')
            .fontSize(12).fontColor($r('sys.color.font_tertiary'))
            .width('100%').margin({ top: 10 })

          if (this.gameAuto) {
            Text('UI 内边距 ' + String(this.gameEdge)
                 + '　界面缩放比例 ' + String(this.gameScale) + '%')
              .fontSize(12).fontColor($r('sys.color.font_tertiary'))
              .width('100%')
              .margin({ top: 6 })
          }
          if (this.gameDisplayNote !== '') {
            Text(this.gameDisplayNote)
              .fontSize(12).fontColor($r('sys.color.warning'))
              .width('100%').margin({ top: 6 })
          }
        }
        .width('100%').padding(16)
        .backgroundColor($r('app.color.launcher_card'))
        .borderRadius(CARD_RADIUS_VP)
        .alignItems(HorizontalAlign.Start)
        .margin({ top: 8 })

        /* ===== 关于 ===== */
        Text('关于')
          .fontSize(13).fontColor($r('sys.color.font_secondary'))
          .width('100%')
          .margin({ top: 20 })
        Column() {
          Row() {
            Column() {
              Text('版本与许可')
                .fontSize(14).fontColor($r('sys.color.font_primary'))
              Text(this.appName === ''
                   ? (this.appVersion === '' ? ' ' : this.appVersion)
                   : (this.appVersion === '' ? this.appName : (this.appName + '  ' + this.appVersion)))
                .fontSize(12).fontColor($r('sys.color.font_tertiary'))
                .margin({ top: 4 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(16).fontColor([$r('sys.color.font_tertiary')])
          }
          .width('100%')
        }
        .width('100%').padding(16)
        .backgroundColor($r('app.color.launcher_card'))
        .borderRadius(CARD_RADIUS_VP)
        .margin({ top: 8 })
        .onClick(() => { this.openAbout(); })

        /* ===== 开源许可 ===== */
        Column() {
          Row() {
            Text('开源许可')
              .fontSize(14).fontColor($r('sys.color.font_primary'))
              .layoutWeight(1)
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(16).fontColor([$r('sys.color.font_tertiary')])
          }
          .width('100%')
        }
        .width('100%').padding(16)
        .backgroundColor($r('app.color.launcher_card'))
        .borderRadius(CARD_RADIUS_VP)
        .margin({ top: 8 })
        .onClick(() => { this.openLicenses(); })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 20, bottom: BAR_CLEARANCE_VP })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%').height('100%')
    .align(Alignment.TopStart)
    .scrollBar(BarState.Off)
  }

  build() {
    Stack() {
    Navigation() {
      HdsTabs({ barPosition: BarPosition.End, controller: this.tabController }) {
        TabContent() { this.GamesTab() }.tabBar(this.tabItem($r('sys.symbol.house_fill'), '首页'))
        TabContent() { this.SavesTab() }.tabBar(this.tabItem($r('sys.symbol.doc_text'), '存档'))
        TabContent() { this.SettingsTab() }.tabBar(this.tabItem($r('sys.symbol.gearshape_fill'), '设置'))
      }
      .vertical(false)
      .barFloatingStyle({
        barSideMargin: this.sideMargin(),
        barBottomMargin: BAR_BOTTOM_MARGIN_VP,
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE,
        },
      })
      .barOverlap(true)
      .cachedMaxCount(2, TabsCacheMode.CACHE_BOTH_SIDE)
      .animationDuration(300)
      .barBackgroundColor(Color.Transparent)
      .onAnimationStart((_index: number, targetIndex: number) => {
        this.currentTab = targetIndex;
      })
      .onChange((index: number) => { this.currentTab = index; })
      .width('100%')
      .height('100%')
    }
    .title(this.appName)
    .titleMode(NavigationTitleMode.Mini)
    .mode(NavigationMode.Stack)
    .hideBackButton(true)
    .padding({ top: this.edgeVp('top'), bottom: this.edgeVp('bottom'),
               left: this.edgeVp('left'), right: this.edgeVp('right') })
    .width('100%')
    .height('100%')
    .onAreaChange((_o: Area, n: Area) => {
      this.winW = Number(n.width);
    })
    .backgroundColor($r('app.color.launcher_bg'))

    if (this.showIsolationAsk) {
      Column() {
        Column() {
          Text('按「' + this.granularityName(this.pendingGranularity) + '」进行数据隔离')
            .fontSize(18).fontColor($r('sys.color.font_primary'))

          Text(this.pendingVersionName)
            .fontSize(13).fontColor($r('sys.color.font_secondary'))
            .width('100%').margin({ top: 6 })

          Divider().strokeWidth(1).color($r('app.color.launcher_border')).margin({ top: 14 })

          /* 显示详情 */
          Row() {
            Text(this.showIsolationDetail ? '收起详情' : '显示详情')
              .fontSize(13).fontColor($r('sys.color.font_secondary'))
              .layoutWeight(1)
            Text(this.showIsolationDetail ? '▴' : '▾')
              .fontSize(13).fontColor($r('sys.color.brand'))
              .margin({ left: 8 })
          }
          .width('100%')
          .margin({ top: 12 })
          .padding({ left: 12, right: 12, top: 10, bottom: 10 })
          .borderRadius(9)
          .backgroundColor($r('app.color.launcher_bg'))
          .alignItems(VerticalAlign.Center)
          .onClick(() => { this.showIsolationDetail = !this.showIsolationDetail; })

          if (this.showIsolationDetail) {
            Text(this.pendingHint)
              .fontSize(12).fontColor($r('sys.color.font_secondary'))
              .width('100%').margin({ top: 10 })
            Text(this.pendingPreview)
              .fontSize(12).fontColor($r('sys.color.font_tertiary'))
              .width('100%').textAlign(TextAlign.Start).margin({ top: 8 })
              .copyOption(CopyOptions.LocalDevice)
          }

          Divider().strokeWidth(1).color($r('app.color.launcher_border')).margin({ top: 14 })

          if (this.hasBundled) {
            Text('注意：内置游戏永远使用 bundled 目录存放数据')
              .fontSize(12).fontColor($r('sys.color.warning'))
              .width('100%').margin({ top: 12 })
          }

          Text('当前数据：' + describeCounts(this.isolationCounts))
            .fontSize(12).fontColor($r('sys.color.font_secondary'))
            .width('100%').margin({ top: 12 })

          Divider().strokeWidth(1).color($r('app.color.launcher_border')).margin({ top: 14 })
          Button('复制过去')
            .fontSize(13)
            .height(34)
            .constraintSize({ maxWidth: '100%' }).alignSelf(ItemAlign.Center)
            .margin({ top: 12 })
            .onClick(() => { this.isolationConfirm = 'copy'; })

          Button('不复制')
            .fontSize(13)
            .height(34)
            .constraintSize({ maxWidth: '100%' }).alignSelf(ItemAlign.Center)
            .margin({ top: 8 })
            .onClick(() => { this.isolationConfirm = 'empty'; })

          Button('取消')
            .fontSize(13)
            .height(34)
            .constraintSize({ maxWidth: '100%' }).alignSelf(ItemAlign.Center)
            .margin({ top: 8 })
            .onClick(() => {
              this.showIsolationAsk = false;
              this.pendingGranularity = '';
              this.isolationConfirm = '';
            })
        }
        .width('100%')
        .constraintSize({ maxWidth: this.dialogWidthVp() })
        .padding(20)
        .backgroundColor($r('app.color.launcher_card'))
        .borderRadius(CARD_RADIUS_VP)
        .alignItems(HorizontalAlign.Start)
        .onClick(() => {})
      }
      .width('100%').height('100%')
      .backgroundColor('#80000000')
      .justifyContent(FlexAlign.Center)
    .padding({ left: 32 + this.edgeVp('left'), right: 32 + this.edgeVp('right'),
               top: this.edgeVp('top'), bottom: this.edgeVp('bottom') })
    .transition(enterFade())
    }

    /* 二次确认。后声明的在上层，避免被主弹窗盖住。出口清空 isolationConfirm。 */
    if (this.isolationConfirm !== '') {
      Column() {
        Column() {
          Text(this.isolationConfirm === 'copy'
               ? '复制到哪些分类' : '再确认一次')
            .fontSize(17).fontColor($r('sys.color.font_primary'))

          /* 复制时列出可选分类，默认全勾。 */
          if (this.isolationConfirm === 'copy') {
            Scroll() {
              Column() {
                ForEach(this.copyTargets, (c: CopyTarget) => {
                  Row() {
                    Column() {
                      Text(this.copyTargetTitle(c))
                        .fontSize(14)
                        .fontColor(this.isCopyPicked(c.key)
                                   ? $r('sys.color.font_primary') : $r('sys.color.font_secondary'))
                        .width('100%')
                        .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                      Text(this.copyTargetSub(c))
                        .fontSize(12).fontColor($r('sys.color.font_tertiary'))
                        .width('100%').margin({ top: 4 })
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)

                    if (this.isCopyPicked(c.key)) {
                      Text('✓').fontSize(16).fontColor($r('sys.color.brand'))
                    }
                  }
                  .width('100%')
                  .padding(12)
                  .borderRadius(CARD_RADIUS_VP)
                  .backgroundColor($r('app.color.launcher_bg'))
                  .margin({ top: 8 })
                  .onClick(() => { this.toggleCopyPick(c.key); })
                }, (c: CopyTarget) => c.key)

                if (this.copyTargets.length === 0) {
                  Text('这一档下没有可复制的分类。')
                    .fontSize(12).fontColor($r('sys.color.font_tertiary'))
                    .width('100%').margin({ top: 8 })
                }
              }
              .width('100%')
            }
            .width('100%')
            .constraintSize({ maxHeight: 300 })
            .align(Alignment.TopStart)
            .margin({ top: 12 })
          } else {
            Text('这个版本会是空的，相当于新建一个存档。')
              .fontSize(13).fontColor($r('sys.color.font_secondary'))
              .margin({ top: 10 })
          }

          Row() {
            Button(this.isolationConfirm === 'copy' ? '复制' : '确定')
              .fontSize(15)
              .layoutWeight(1)
              .enabled(this.isolationConfirm !== 'copy' || this.copyPicked.length > 0)
              .onClick(() => {
                const what: string = this.isolationConfirm;
                this.isolationConfirm = '';
                if (what === 'copy') {
                  this.applyIsolationCopy();
                } else {
                  this.applyIsolationEmpty();
                }
              })
            Button('取消')
              .fontSize(14)
              .layoutWeight(1)
              .margin({ left: 12 })
              .onClick(() => { this.isolationConfirm = ''; })
          }
          .width('100%')
          .margin({ top: 16 })
        }
        .width('100%')
        .constraintSize({ maxWidth: this.dialogWidthVp() })
        .padding(20)
        .backgroundColor($r('app.color.launcher_card'))
        .borderRadius(CARD_RADIUS_VP)
        .alignItems(HorizontalAlign.Start)
        .onClick(() => {})
      }
      .width('100%').height('100%')
      .backgroundColor('#80000000')
      .justifyContent(FlexAlign.Center)
      /* 异形屏避让：padding加在遮罩上，32为卡片边距。 */
    .padding({ left: 32 + this.edgeVp('left'), right: 32 + this.edgeVp('right'),
               top: this.edgeVp('top'), bottom: this.edgeVp('bottom') })
    .transition(enterFade())
    }

    if (this.showAbout) {
      Column() {
        Column() {
          Row() {
            Text('关于')
              .fontSize(18).fontColor($r('sys.color.font_primary'))
              .layoutWeight(1)
            Text('✕')
              .fontSize(18).fontColor($r('sys.color.font_secondary'))
              .padding({ left: 14, right: 4, top: 2, bottom: 2 })
              .onClick(() => { this.showAbout = false; })
          }
          .width('100%')

          Text(this.appName + (this.appVersion === '' ? '' : ('  ' + this.appVersion)))
            .fontSize(14).fontColor($r('sys.color.font_secondary'))
            .margin({ top: 14 })
          Text('在 HarmonyOS / OpenHarmony 上运行 Mindustry')
            .fontSize(13).fontColor($r('sys.color.font_secondary'))
            .margin({ top: 8 })
          Text('以 GPL-3.0 分发。')
            .fontSize(13).fontColor($r('sys.color.font_secondary'))
            .margin({ top: 4 })

          Text('上游')
            .fontSize(12).fontColor($r('sys.color.font_tertiary'))
            .margin({ top: 16 })
          Text('https://github.com/Anuken/Mindustry')
            .fontSize(12).fontColor($r('sys.color.brand'))
            .margin({ top: 2 }).copyOption(CopyOptions.LocalDevice)
          Text('本仓库')
            .fontSize(12).fontColor($r('sys.color.font_tertiary'))
            .margin({ top: 10 })
          Text('https://github.com/haohandc/MindustryArk')
            .fontSize(12).fontColor($r('sys.color.brand'))
            .margin({ top: 2 }).copyOption(CopyOptions.LocalDevice)
          Text('问题反馈')
            .fontSize(12).fontColor($r('sys.color.font_tertiary'))
            .margin({ top: 10 })
          Text('https://github.com/haohandc/MindustryArk/issues')
            .fontSize(12).fontColor($r('sys.color.brand'))
            .margin({ top: 2 }).copyOption(CopyOptions.LocalDevice)

          Text('非官方项目。与 Mindustry 及其作者 Anuken 无隶属关系，未获其认可或支持。以 GPL-3.0 分发。')
            .fontSize(12).fontColor($r('sys.color.font_tertiary'))
            .margin({ top: 16 })
        }
        .width('100%')
        .constraintSize({ maxWidth: this.dialogWidthVp() })
        .padding(20)
        .backgroundColor($r('app.color.launcher_card'))
        .borderRadius(CARD_RADIUS_VP)
        .alignItems(HorizontalAlign.Start)
        /* 吞掉卡片上的点击，避免冒泡到遮罩。空处理器有意。 */
        .onClick(() => {})
      }
      .width('100%').height('100%')
      .backgroundColor('#80000000')
      .justifyContent(FlexAlign.Center)
    .padding({ left: 32 + this.edgeVp('left'), right: 32 + this.edgeVp('right'),
               top: this.edgeVp('top'), bottom: this.edgeVp('bottom') })
    .transition(enterFade())
      .onClick(() => { this.showAbout = false; })
    }

    if (this.showLicenses) {
      Column() {
        Column() {
          Row() {
            if (this.licenseSel === '') {
              Text('开源许可')
                .fontSize(18).fontColor($r('sys.color.font_primary'))
                .layoutWeight(1)
            } else {
              Text('返回')
                .fontSize(15).fontColor($r('sys.color.brand'))
                .layoutWeight(1)
                .onClick(() => { this.licenseSel = ''; this.licenseBody = ''; })
            }
            Text('✕')
              .fontSize(18).fontColor($r('sys.color.font_secondary'))
              .padding({ left: 14, right: 4, top: 2, bottom: 2 })
              .onClick(() => {
                this.showLicenses = false;
                this.licenseSel = '';
                this.licenseBody = '';
              })
          }
          .width('100%')

          if (this.licenseSel === '') {
            List() {
              ForEach(LICENSE_FILES, (item: LicenseEntry) => {
                ListItem() {
                  Row() {
                    Text(item.name)
                      .fontSize(14).fontColor($r('sys.color.font_primary'))
                      .layoutWeight(1)
                    SymbolGlyph($r('sys.symbol.chevron_right'))
                      .fontSize(16).fontColor([$r('sys.color.font_tertiary')])
                  }
                  .width('100%').padding({ top: 14, bottom: 14 })
                  .onClick(() => {
                    this.licenseSel = item.file;
                    this.licenseBody = this.readLicense(item.file);
                  })
                }
              }, (item: LicenseEntry) => item.file)
            }
            .width('100%').layoutWeight(1)
            .margin({ top: 8 })
            .scrollBar(BarState.Off)
          } else {
            Scroll() {
              Text(this.licenseBody)
                .fontSize(11).fontColor($r('sys.color.font_secondary'))
                .width('100%')
                .copyOption(CopyOptions.LocalDevice)
            }
            .width('100%').layoutWeight(1)
            .margin({ top: 8 })
            .align(Alignment.TopStart)
            .scrollBar(BarState.Off)
          }
        }
        .width('100%')
        .constraintSize({ maxWidth: this.dialogWidthVp() })
        .height('80%')
        .padding(20)
        .backgroundColor($r('app.color.launcher_card'))
        .borderRadius(CARD_RADIUS_VP)
        .alignItems(HorizontalAlign.Start)
        /* 吞掉卡片上的点击，避免冒泡到遮罩。空处理器有意。 */
        .onClick(() => {})
      }
      .width('100%').height('100%')
      .backgroundColor('#80000000')
      .justifyContent(FlexAlign.Center)
      .padding({ left: 32 + this.edgeVp('left'), right: 32 + this.edgeVp('right'),
                 top: this.edgeVp('top'), bottom: this.edgeVp('bottom') })
      .transition(enterFade())
      .onClick(() => {
        this.showLicenses = false;
        this.licenseSel = '';
        this.licenseBody = '';
      })
    }

    /* 复制/移动目标选择。 */
    if (this.transferOp !== '') {
      this.TransferDialog()
    }

    /* 整包导入目标选择。 */
    if (this.importOpen) {
      this.ImportTargetDialog()
    }

    /* 导入/导出/进行中提示。只读，放浮层最下层。 */
    if (this.importMsg !== '' || this.exportMsg !== '' || this.importToast !== '') {
      this.PackNotice()
    }

    /* 删除确认。排在启动失败前面，避免被盖住。 */
    if (this.showDeleteAsk) {
      this.DeleteAskDialog()
    }

    /* 多选删除确认。与单删互斥，防御性顺序。 */
    if (this.showMultiAsk) {
      this.MultiDeleteAskDialog()
    }

    /* 清空回收站确认。防御性顺序。 */
    if (this.showVaultClearAsk) {
      this.VaultClearAskDialog()
    }

    /* 删除版本确认。防御性顺序。 */
    if (this.showGameDeleteAsk) {
      this.GameDeleteAskDialog()
    }

    if (this.launchFault !== '' && !this.faultAck) {
      /* 遮罩+盒子两层，不要合并。 */
      Column() {
        Column() {
          Text('上次没能启动成功')
            .fontSize(20).fontColor($r('sys.color.font_primary'))
          /* 日志可滚动，避免撑高弹窗。不截断。 */
          Scroll() {
            Text(this.launchFault)
              .fontSize(12).fontColor($r('sys.color.font_secondary'))
              .width('100%')
              .textAlign(TextAlign.Start)
          }
          .width('100%')
          .constraintSize({ maxHeight: FAULT_BOX_VP })
          .align(Alignment.TopStart)
          .margin({ top: 12 })

          Text('若你确认设备本可以运行游戏，可以用「仍然尝试启动」绕开这次判定。')
            .fontSize(12).fontColor($r('sys.color.font_tertiary'))
            .margin({ top: 10 })

          /* 按钮并排各占一半。不禁用重试按钮。 */
          Row({ space: 12 }) {
            Button('仍然尝试启动')
              .fontSize(BUTTON_FONT_VP).height(44)
              .layoutWeight(1)
              .fontColor(SECONDARY_FG)
              .backgroundColor(SECONDARY_BG)
              .onClick(() => {
                this.faultAck = true;
                this.onForceLaunch();
              })
            Button('知道了')
              .fontSize(BUTTON_FONT_VP).height(44)
              .layoutWeight(1)
              .onClick(() => { this.faultAck = true; })
          }
          .width('100%')
          .margin({ top: 18 })
        }
        .width('100%')
        .constraintSize({ maxWidth: this.dialogWidthVp() })
        .padding(20)
        .backgroundColor('#F01C1C1C')
        .borderRadius(CARD_RADIUS_VP)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%').height('100%')
      .backgroundColor('#B0000000')
      .justifyContent(FlexAlign.Center)
    .padding({ left: 32 + this.edgeVp('left'), right: 32 + this.edgeVp('right'),
               top: this.edgeVp('top'), bottom: this.edgeVp('bottom') })
    .transition(enterFade())
    }
    }
  }
}