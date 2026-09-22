/*
 * Getting mod files into the directory the game reads them from.
 *
 * WHY THIS IS OURS AND NOT THE GAME'S
 *   Mindustry ships an "import mod" button, and on this platform it cannot work.
 *   It calls Platform.showFileChooser, whose default implementation in the game
 *   jar is:
 *
 *       throw new IllegalArgumentException("Not implemented on this platform!")
 *
 *   and the one backend that does implement it loads
 *   libarc-filedialogsarm64.so, which is tinyfiledialogs -- zenity/kdialog/
 *   popen -- and is glibc-linked, so it does not load here at all. Both
 *   measured. So the button is dead, and an entry has to exist somewhere.
 *
 * TWO WAYS IN, BOTH ASKED FOR
 *   A. the HarmonyOS document picker, from the floating ball's menu. No
 *      permission needed: the picker is a system UI and hands back a URI this
 *      app is allowed to read.
 *   B. a folder in Downloads, scanned at startup. Reuses the
 *      READ_WRITE_DOWNLOAD_DIRECTORY grant and the Environment API that
 *      user_dirs.txt already exercises. A is the discoverable one; B is the one
 *      that works when a picker is unavailable or refused.
 *
 *   B has to tolerate the permission being refused -- it is an ACL permission
 *   and the profile that grants it may change -- so a failure there is logged
 *   and returns empty rather than surfacing. A is unaffected.
 *
 * WHY THE MODS PATH IS AN ABSOLUTE LITERAL
 *   Same reason as the IME bridge in Index.ets: this is the APPLICATION-level
 *   directory native code shares, while ArkTS's context.filesDir is the
 *   module-level one. They look almost identical and are not interchangeable --
 *   a file written to the wrong one is never seen and reports no error.
 *
 *   The path is not a guess about layout. The launcher points user.home at its
 *   own sandbox, Arc's OS.getAppDataDirectoryString() builds
 *   "<user.home>/.local/share/Mindustry/", and Vars.modDirectory is
 *   dataDirectory.child("mods/"). Listed on the device.
 *
 * WHY A RESTART IS REQUIRED
 *   The game scans this directory exactly once, inside Vars.load(). Nothing
 *   watches it. So an imported mod is on disk and invisible until the process
 *   starts again, and the caller has to say so rather than let the player think
 *   the button did nothing.
 */
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs, picker, Environment } from '@kit.CoreFileKit';

const DOMAIN = 0x0000;
const TAG = 'MindustryLauncher';

/** The game's mods directory. See the note above on why this is a literal. */
export const MODS_DIR: string =
  '/data/storage/el2/base/files/.local/share/Mindustry/mods';

/*
 * Where the startup scan looks inside Downloads.
 *
 * A subdirectory rather than Downloads itself: Downloads on a real device is
 * full of unrelated files, and an app that silently swallows every .zip it
 * finds there would be doing something the player did not ask for.
 */
const DOWNLOAD_SUBDIR: string = 'MindustryMods';

/* What the game accepts. Mods.load() keeps files whose extension is "jar" or
 * "zip", or directories containing one of mod.json / mod.hjson / plugin.json /
 * plugin.hjson. A directory is not something a picker can hand over, so only
 * the two archive forms are offered. */
const MOD_SUFFIXES: Array<string> = ['.jar', '.zip'];

const MAX_PICK: number = 8;

/** One file that made it into the mods directory. */
export interface ModImport {
  name: string;
  bytes: number;
}

/** What a pick or a scan produced, for the caller to report. */
export interface ModImportReport {
  landed: Array<ModImport>;
  /** Set when the attempt failed for a reason worth showing. */
  error: string;
  /** True when the player cancelled the picker -- not an error, and silent. */
  cancelled: boolean;
}

export function isModFileName(name: string): boolean {
  const lower: string = name.toLowerCase();
  for (const suffix of MOD_SUFFIXES) {
    if (lower.endsWith(suffix)) {
      return true;
    }
  }
  return false;
}

/** The last path segment, percent-decoded. URIs arrive escaped. */
function baseName(uri: string): string {
  let s: string = uri;
  const query: number = s.indexOf('?');
  if (query >= 0) {
    s = s.substring(0, query);
  }
  const slash: number = s.lastIndexOf('/');
  if (slash >= 0) {
    s = s.substring(slash + 1);
  }
  if (s.length === 0) {
    return s;
  }
  try {
    return decodeURIComponent(s);
  } catch (e) {
    /* A name that is not valid percent-encoding is still a name. Better to land
     * the file under the raw text than to reject a working mod over it. */
    return s;
  }
}

/*
 * mkdir -p on the mods directory.
 *
 * It is normally there already -- the game creates it during its first run --
 * but an import can be attempted before the game has ever started, and on a
 * fresh install the whole .local/share/Mindustry chain is absent. Recursive
 * because of that chain, not just the leaf.
 */
function ensureModsDir(): boolean {
  try {
    if (!fs.accessSync(MODS_DIR)) {
      fs.mkdirSync(MODS_DIR, true);
      hilog.info(DOMAIN, TAG, 'mods: created %{public}s', MODS_DIR);
    }
    return true;
  } catch (e) {
    const err = e as BusinessError;
    hilog.error(DOMAIN, TAG, 'mods: cannot create %{public}s: %{public}s',
                MODS_DIR, err.message);
    return false;
  }
}

/*
 * Copy an already-open source into the mods directory.
 *
 * Takes a descriptor rather than a path so that both callers -- a picker URI and
 * a path under Downloads -- go through one implementation. copyFileSync accepts
 * either, but normalising here means the two entries cannot drift apart.
 */
function landFile(fd: number, name: string): ModImport | null {
  const dest: string = MODS_DIR + '/' + name;
  try {
    fs.copyFileSync(fd, dest);
    const bytes: number = fs.statSync(dest).size;
    hilog.info(DOMAIN, TAG, 'mods: imported %{public}s (%{public}d B)', name, bytes);
    return { name: name, bytes: bytes };
  } catch (e) {
    const err = e as BusinessError;
    hilog.error(DOMAIN, TAG, 'mods: copying to %{public}s failed: %{public}s',
                dest, err.message);
    return null;
  }
}

/**
 * Ask the system picker for mod files and copy whatever it returns.
 *
 * The picker is a system UI, so it takes the foreground and the game is not
 * being asked to keep focus -- which is the reason the compatibility notice in
 * Index.ets could not be a dialog. A picker is a different situation: the
 * player has deliberately left the game to choose a file.
 *
 * A cancelled pick resolves with an empty array rather than throwing, and is
 * reported as `cancelled` so the caller stays quiet about it.
 */
export async function pickMods(ctx: common.UIAbilityContext): Promise<ModImportReport> {
  const report: ModImportReport = { landed: [], error: '', cancelled: false };

  const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
  options.maxSelectNumber = MAX_PICK;
  options.fileSuffixFilters = MOD_SUFFIXES;

  let uris: Array<string> = [];
  try {
    const view: picker.DocumentViewPicker = new picker.DocumentViewPicker(ctx);
    uris = await view.select(options);
  } catch (e) {
    const err = e as BusinessError;
    hilog.error(DOMAIN, TAG, 'mods: picker failed: %{public}s (code=%{public}d)',
                err.message, err.code);
    report.error = '打开文件选择器失败';
    return report;
  }

  if (uris.length === 0) {
    report.cancelled = true;
    return report;
  }

  if (!ensureModsDir()) {
    report.error = '无法创建模组目录';
    return report;
  }

  for (const uri of uris) {
    const name: string = baseName(uri);
    if (!isModFileName(name)) {
      /* The picker was asked to filter, but a filter is a hint, not a promise.
       * Landing a .png in the mods directory would make the game report a mod
       * it cannot read, which reads as our bug. */
      hilog.warn(DOMAIN, TAG, 'mods: ignoring %{public}s -- not a .jar or .zip', name);
      continue;
    }
    try {
      const file: fs.File = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      try {
        const one: ModImport | null = landFile(file.fd, name);
        if (one !== null) {
          report.landed.push(one);
        }
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'mods: cannot read the picked %{public}s: %{public}s',
                  name, err.message);
    }
  }

  if (report.landed.length === 0 && report.error.length === 0) {
    report.error = '没有可用的模组文件';
  }
  return report;
}

/**
 * Copy anything in <Downloads>/MindustryMods into the mods directory.
 *
 * Runs at startup, before the game scans, so a mod dropped in Downloads is live
 * on the next launch with no further ceremony.
 *
 * A file already present with the same size is left alone: re-copying it every
 * launch would be pointless work, and leaving it alone keeps the mtime
 * meaningful. A different size means the player replaced it, so it is copied.
 *
 * Fails soft, always. The Downloads grant is an ACL permission and a profile
 * without it is a configuration this project has already shipped once, so a
 * refusal here must not affect anything else -- the picker entry still works.
 */
/*
 * The last startup scan's result, for the page to report.
 *
 * KEPT IN MEMORY RATHER THAN LOGGED, because this app's own hilog lines are not
 * reliably readable: the game writes thousands of lines a second into a ring
 * buffer of a few thousand, so anything logged at startup is gone within
 * seconds -- measured, zero hits for this app's tag in a full buffer dump. The
 * project already works around that for native logs by reading files out of the
 * sandbox. Here there is a better answer than either: a player cannot read
 * hilog, but a player can read a toast.
 */
let lastScan: ModImportReport = { landed: [], error: '', cancelled: false };

/** What the startup scan did, so the page can say so. */
export function lastDownloadScan(): ModImportReport {
  return lastScan;
}

export function scanDownloadMods(): ModImportReport {
  const report: ModImportReport = scanDownloadModsInner();
  lastScan = report;
  return report;
}

function scanDownloadModsInner(): ModImportReport {
  const report: ModImportReport = { landed: [], error: '', cancelled: false };

  let dir: string = '';
  try {
    dir = Environment.getUserDownloadDir() + '/' + DOWNLOAD_SUBDIR;
  } catch (e) {
    const err = e as BusinessError;
    hilog.info(DOMAIN, TAG, 'mods: no Downloads directory (%{public}s)', err.message);
    return report;
  }

  let names: Array<string> = [];
  try {
    names = fs.listFileSync(dir);
  } catch (e) {
    /* Not an error worth showing: this is the normal state on a device where
     * the permission was refused, and on every device until the folder is made.
     * Logged at info so it is still findable when someone asks why B did
     * nothing. */
    const err = e as BusinessError;
    hilog.info(DOMAIN, TAG, 'mods: %{public}s not readable (%{public}s) -- skipping',
               dir, err.message);
    return report;
  }

  if (!ensureModsDir()) {
    report.error = '无法创建模组目录';
    return report;
  }

  for (const name of names) {
    if (!isModFileName(name)) {
      continue;
    }
    const src: string = dir + '/' + name;
    const dest: string = MODS_DIR + '/' + name;
    try {
      const srcSize: number = fs.statSync(src).size;
      if (fs.accessSync(dest) && fs.statSync(dest).size === srcSize) {
        continue;
      }
      const file: fs.File = fs.openSync(src, fs.OpenMode.READ_ONLY);
      try {
        const one: ModImport | null = landFile(file.fd, name);
        if (one !== null) {
          report.landed.push(one);
        }
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'mods: %{public}s failed: %{public}s', src, err.message);
    }
  }

  if (report.landed.length > 0) {
    hilog.info(DOMAIN, TAG, 'mods: %{public}d file(s) taken from Downloads',
               report.landed.length);
  }
  /*
   * Logged even when nothing was found: a scan that says nothing is
   * indistinguishable from one that never ran, and the two states a player hits
   * first -- no folder, or an empty one -- were both silent.
   *
   * This line is a convenience, not the report. See the note on lastScan: the
   * page is what tells the player, because startup logs in this app survive
   * only a few seconds.
   */
  hilog.info(DOMAIN, TAG,
             'mods: Downloads scan of %{public}s -- %{public}d seen, %{public}d imported',
             dir, names.length, report.landed.length);
  return report;
}
