/*
 * Getting mod files into the directory the game reads them from.
 *
 * NOT THE ONLY WAY IN -- and getting that wrong is the point of this note.
 *
 *   An earlier revision of this file was built on the claim that the game's own
 *   "import mod" button cannot work here: it goes through
 *   Platform.showFileChooser, whose default implementation throws
 *
 *       throw new IllegalArgumentException("Not implemented on this platform!")
 *
 *   and the backend that implements it loads libarc-filedialogsarm64.so, which
 *   is tinyfiledialogs -- zenity/kdialog/popen, glibc-linked, does not load.
 *
 *   Every one of those measurements is true. The conclusion built from them was
 *   not. Read from the jar: `showFileChooser` is referenced only by
 *   DesktopLauncher, while ModsDialog -- which owns the import button --
 *   references mindustry/ui/FileChooser, the game's OWN in-game browser
 *   (FileChooserDialog), pure Java over Arc's Fi, needing no native dialog.
 *   Nothing on that path reaches the throwing default.
 *
 *   ✅ CONFIRMED ON THE DEVICE, by the user: the game's own button works. It
 *   reports a network error first, which is expected -- it offers to fetch
 *   community mods and networking is not ported yet (see the INTERNET note in
 *   module.json5) -- and then browses and imports fine. So mods have three ways
 *   in, and this file adds two of them.
 *
 *   The note is kept because "true measurements assembled into a false
 *   conclusion" is the failure mode worth remembering, and because a reader who
 *   finds only the thrown exception will reach the same wrong answer.
 *
 * WHAT THIS STILL ADDS
 *   The platform picker is the shorter path: pick a file from anywhere the
 *   system can reach, land it in the mods directory, no permission, no browsing
 *   through a dialog rooted at one folder. The app's own folder in Downloads is
 *   for putting a batch in ahead of time. Neither replaces the game's own button.
 *
 * TWO WAYS IN HERE
 *   A. the HarmonyOS document picker, from the floating ball's menu. No
 *      permission needed: the picker is a system UI and hands back a URI this
 *      app is allowed to read.
 *   B. the folder the app creates in Downloads (see chooseModFolder below),
 *      scanned at startup. Also no permission -- that is the whole point of the
 *      DOWNLOAD picker mode. A is the discoverable one; B is the one that lets a
 *      player drop a batch of files in with any file manager.
 *
 *   ⚠️ Neither uses Environment.getUserDownloadDir(), and neither uses
 *   READ_WRITE_DOWNLOAD_DIRECTORY. An earlier revision of B did, and it could
 *   never work on a phone: that API is 2in1-only. It also meant B failed
 *   whenever that ACL permission was not granted, which on the phone was always.
 *   Both of those are gone, not worked around.
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
import { fileIo as fs, picker, fileUri } from '@kit.CoreFileKit';

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
/*
 * Where the URI of the player's chosen mod folder is kept.
 *
 * A URI, not a path. The permission DOWNLOAD mode hands out travels WITH the
 * URI, so writing the path down and reopening it later would be a different
 * thing that happens to name the same directory -- and would not carry the
 * grant.
 */
const MOD_FOLDER_URI_FILE: string = 'mod_folder_uri';

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

export function scanModFolder(uriFilePath: string): ModImportReport {
  const report: ModImportReport = scanModFolderInner(uriFilePath);
  lastScan = report;
  return report;
}

function scanModFolderInner(uriFilePath: string): ModImportReport {
  const report: ModImportReport = { landed: [], error: '', cancelled: false };

  const uri: string = readModFolderUri(uriFilePath);
  if (uri === '') {
    hilog.info(DOMAIN, TAG, 'mods: no folder chosen yet -- nothing to scan');
    return report;
  }

  let dir: string = '';
  try {
    dir = new fileUri.FileUri(uri).path;
  } catch (e) {
    const err = e as BusinessError;
    hilog.error(DOMAIN, TAG, 'mods: stored folder URI is unusable (%{public}s)',
                err.message);
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
    hilog.info(DOMAIN, TAG, 'mods: %{public}d file(s) taken from the chosen folder',
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
             'mods: folder scan of %{public}s -- %{public}d seen, %{public}d imported',
             dir, names.length, report.landed.length);
  return report;
}


/* ---------------------------------------------------------------------------
 * The chosen mod folder -- what replaced reaching into Downloads.
 *
 * WHY THIS EXISTS AT ALL
 *   The first version of this file read the folder with
 *   Environment.getUserDownloadDir(). That API is documented as requiring
 *   SystemCapability.FileManagement.File.Environment.FolderObtain, which the
 *   docs state is "currently 2in1 devices only" -- and on the phone it throws
 *   "The device doesn't support this api" whether or not the permission is
 *   granted (measured with the permission granted by hand, so the grant is not
 *   the variable). So on a phone there was no way in at all.
 *
 *   The route that DOES work on phones is DocumentPickerMode.DOWNLOAD, and the
 *   official guide describes it in exactly the terms that were wanted:
 *
 *     模式特点
 *       * 自动创建在 Download/包名/ 目录。
 *       * 跳过文件选择界面直接保存。
 *       * 返回的 URI 已具备持久化权限，用户可在该 URI 下创建文件。
 *
 *   So: the app creates Download/<bundle name>/ once, off the back of a picker
 *   call that shows no UI, and gets back a directory URI it is allowed to use.
 *   The player then drops mod files into that folder with any file manager, and
 *   the startup scan picks them up. No permission in the manifest, and the
 *   bundle-name folder is exactly what the other apps on the phone are doing.
 *
 * ⚠️ WHAT IS NOT YET PROVEN HERE: that the URI survives an app restart. The
 *   DOWNLOAD-mode documentation says the returned URI "already has persistent
 *   permission", which is stronger than the temporary grant a normal picker
 *   returns -- but the separate 授权持久化 guide describes persistPermission /
 *   activatePermission, and those need ohos.permission.FILE_ACCESS_PERSIST.
 *   Whether DOWNLOAD mode's permissive wording means we can skip all of that is
 *   a question for the device, not for the documentation. The code copes with
 *   either answer: a stored URI that no longer works is logged with its error
 *   and the scan reports nothing rather than throwing.
 */

/** Read the stored folder URI, or '' if the player has not chosen one yet. */
function readModFolderUri(uriFilePath: string): string {
  try {
    if (!fs.accessSync(uriFilePath)) {
      return '';
    }
    const text: string = fs.readTextSync(uriFilePath).trim();
    return text;
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'mods: reading the stored folder URI failed: %{public}s',
               err.message);
    return '';
  }
}

function writeModFolderUri(uriFilePath: string, uri: string): void {
  const f: fs.File = fs.openSync(uriFilePath,
    fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE);
  try {
    fs.writeSync(f.fd, uri);
  } finally {
    fs.closeSync(f);
  }
}

/**
 * Create (or re-find) the app's own folder in Downloads, and remember it.
 *
 * pickerMode = DOWNLOAD makes save() skip its UI entirely -- there is no dialog
 * to answer, the system creates Download/<bundle name>/ and hands back the
 * directory URI. That is why this can be offered as a menu item rather than a
 * first-run wizard.
 *
 * NOTE: with DOWNLOAD mode the other DocumentSaveOptions fields are ignored --
 * newFileNames and fileSuffixChoices have no effect (stated in the guide, and
 * repeated in every write-up of the mode). Setting them here would read as if
 * they did something.
 */
export async function chooseModFolder(ctx: common.UIAbilityContext,
                                    uriFilePath: string): Promise<ModImportReport> {
  const report: ModImportReport = { landed: [], error: '', cancelled: false };

  const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
  options.pickerMode = picker.DocumentPickerMode.DOWNLOAD;

  let uris: Array<string> = [];
  try {
    const view: picker.DocumentViewPicker = new picker.DocumentViewPicker(ctx);
    uris = await view.save(options);
  } catch (e) {
    const err = e as BusinessError;
    hilog.error(DOMAIN, TAG, 'mods: DOWNLOAD-mode save failed: %{public}s (code=%{public}d)',
                err.message, err.code);
    report.error = '无法创建模组文件夹';
    return report;
  }

  if (uris === undefined || uris.length === 0 || uris[0] === '') {
    report.cancelled = true;
    return report;
  }

  let where: string = '';
  try {
    where = new fileUri.FileUri(uris[0]).path;
  } catch (e) {
    where = '(unresolved)';
  }
  hilog.info(DOMAIN, TAG, 'mods: mod folder is %{public}s', where);

  try {
    writeModFolderUri(uriFilePath, uris[0]);
  } catch (e) {
    const err = e as BusinessError;
    hilog.error(DOMAIN, TAG, 'mods: storing the folder URI failed: %{public}s', err.message);
    report.error = '无法保存模组文件夹位置';
    return report;
  }

  const scanned: ModImportReport = scanModFolder(uriFilePath);
  return scanned;
}


/**
 * Make sure the app's folder in Downloads exists, creating it if this is a
 * fresh install. Safe to call on every launch.
 *
 * WHY THIS IS NOT A BUTTON ANY MORE
 *   It was one -- a "模组文件夹" row in the ball's menu -- and the user is right
 *   that it should not be: creating a folder is not something to make a player
 *   ask for. It is also needed EARLIER than any menu could provide it, because
 *   the launcher points the game's file browser at that folder when the JVM
 *   starts, and the folder has to exist by then.
 *
 * So it runs at startup, before the browser is told where to open. DOWNLOAD mode
 * shows no UI, so there is nothing to answer and nothing to wait for.
 *
 * If a URI is already stored, the folder was created on an earlier launch --
 * this returns without touching the picker. If the stored URI has gone stale the
 * scan is what notices, and this will not silently replace it with a new one:
 * re-creating a folder the player may have filled is a worse failure than
 * reporting nothing.
 */
export async function ensureModFolder(ctx: common.UIAbilityContext,
                                    uriFilePath: string): Promise<void> {
  if (readModFolderUri(uriFilePath) !== '') {
    return;
  }
  const report: ModImportReport = await chooseModFolder(ctx, uriFilePath);
  if (report.error !== '') {
    hilog.warn(DOMAIN, TAG, 'mods: could not create the mod folder: %{public}s',
               report.error);
  }
}
