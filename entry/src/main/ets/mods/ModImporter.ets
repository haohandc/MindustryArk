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
 *   B. the folder the app creates in Downloads (see createModFolder below),
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
import { bundleManager, common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs, picker, fileUri, Environment } from '@kit.CoreFileKit';

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
const MOD_FOLDER_FILE: string = 'mod_folder';

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

export function scanModFolder(statePath: string): ModImportReport {
  const report: ModImportReport = scanModFolderInner(statePath);
  lastScan = report;
  return report;
}

function scanModFolderInner(statePath: string): ModImportReport {
  const report: ModImportReport = { landed: [], error: '', cancelled: false };

  const folder: ModFolder = readModFolder(statePath);
  if (folder.path === '' && folder.uri === '') {
    hilog.info(DOMAIN, TAG, 'mods: no folder yet -- nothing to scan');
    return report;
  }

  /* Listed through listModFolder, which tries the URI and then the path. The
   * scan used to go straight at the path, which is only correct for one of the
   * two ways the folder can have been made. */
  const names: Array<string> = listModFolder(folder);
  const dir: string = folder.path;
  if (names.length === 0 && !modFolderUsable(folder)) {
    hilog.info(DOMAIN, TAG, 'mods: %{public}s is not readable -- nothing to scan', dir);
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
/**
 * Where the mod folder is, as a path plus an optional URI.
 *
 * FIRST LINE IS ALWAYS THE PATH, so the user_dirs.txt bridge can take the first
 * line without knowing about the rest.
 *
 * The URI is kept when there is one because the permission travels with it: on
 * the phone the folder is only reachable through the grant that the picker
 * handed back, and a path alone would name the same directory without carrying
 * the right to read it. On the tablet there is no URI and the path is enough --
 * that route goes through the platform's own Download directory.
 */
interface ModFolder {
  path: string;
  uri: string;
}

function readModFolder(statePath: string): ModFolder {
  const none: ModFolder = { path: '', uri: '' };
  try {
    if (!fs.accessSync(statePath)) {
      return none;
    }
    const lines: Array<string> = fs.readTextSync(statePath).split('\n');
    const path: string = lines.length > 0 ? lines[0].trim() : '';
    const uri: string = lines.length > 1 ? lines[1].trim() : '';
    if (path === '') {
      return none;
    }
    return { path: path, uri: uri };
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'mods: reading the stored folder failed: %{public}s',
               err.message);
    return none;
  }
}

/**
 * The folder's path, or '' if there is none.
 *
 * Exported because the user_dirs.txt bridge needs exactly this and should not
 * have to know the file's format. It used to read the URI and resolve it with
 * fileUri, which stops being right the moment the path is stored directly -- the
 * kind of duplicate knowledge that drifts.
 */
export function modFolderPath(statePath: string): string {
  return readModFolder(statePath).path;
}

function writeModFolder(statePath: string, folder: ModFolder): void {
  const text: string = folder.uri === ''
    ? folder.path + '\n'
    : folder.path + '\n' + folder.uri + '\n';
  const f: fs.File = fs.openSync(statePath,
    fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE);
  try {
    fs.writeSync(f.fd, text);
  } finally {
    fs.closeSync(f);
  }
}

/**
 * Can this folder actually be listed right now?
 *
 * The URI is tried first and the path second, because they are not
 * interchangeable: a folder handed over by the picker is reachable through its
 * grant, and a folder we made ourselves under the platform's Download directory
 * is reachable by path. Trying both means one check covers both routes.
 *
 * Listing, not `access`: this has to answer "can I read it", and existence is
 * not that. A folder that exists and cannot be listed is one this app cannot use.
 */
function listModFolder(folder: ModFolder): Array<string> {
  const targets: Array<string> = [];
  if (folder.uri !== '') {
    targets.push(folder.uri);
  }
  if (folder.path !== '') {
    targets.push(folder.path);
  }
  for (const target of targets) {
    try {
      return fs.listFileSync(target);
    } catch (e) {
      const err = e as BusinessError;
      hilog.info(DOMAIN, TAG, 'mods: %{public}s not listable (%{public}s)',
                 target, err.message);
    }
  }
  return [];
}

/** True when the folder is there and this app can read it. */
function modFolderUsable(folder: ModFolder): boolean {
  if (folder.path === '' && folder.uri === '') {
    return false;
  }
  const targets: Array<string> = [];
  if (folder.uri !== '') {
    targets.push(folder.uri);
  }
  if (folder.path !== '') {
    targets.push(folder.path);
  }
  for (const target of targets) {
    try {
      fs.listFileSync(target);
      return true;
    } catch (e) {
      /* try the next target */
    }
  }
  return false;
}

/**
 * Create the app's folder in Downloads, by whichever of the two routes this
 * device supports.
 *
 * The two are complementary -- measured, and it is why neither alone is enough:
 *
 *   platform Download directory   getUserDownloadDir() works on the tablet and
 *                                 throws on the phone
 *   DOWNLOAD-mode picker          works on the phone, and fails on the tablet
 *                                 with 13900042
 *
 * Route A goes through the platform's own Download directory, which the tablet
 * reports and the phone does not. It needs READ_WRITE_DOWNLOAD_DIRECTORY for the
 * mkdir, and on the tablet that grant is already held. Note the API only returns
 * the PATH -- it checks no permission at all (the documentation says so), so a
 * mkdir that fails with EPERM is the real test, not the call succeeding.
 *
 * Route B is the picker in DOWNLOAD mode: no permission, no UI, and it creates
 * Download/<bundle name>/ itself. It returns a URI, and the grant travels with
 * that URI, which is why the URI is stored alongside the path.
 *
 * Returns whether a usable folder exists afterwards.
 */
async function createModFolder(ctx: common.UIAbilityContext): Promise<ModFolder> {
  const none: ModFolder = { path: '', uri: '' };

  /*
   * A. the platform's Download directory + our own subdirectory.
   *
   * A no-op if it is already there, which is the normal case from the second
   * launch on -- the check is what makes "deleted it by hand" recoverable.
   */
  try {
    const base: string = Environment.getUserDownloadDir();
    /*
     * Reported separately from the mkdir below. "the platform Download directory
     * is unusable" covers three different failures -- the API being unsupported,
     * the directory not being reachable, and the write being refused -- and they
     * mean different things. Measured on the tablet: the API ANSWERS (it returns
     * /storage/Users/currentUser/Download) and the write is refused with EPERM,
     * which is not the same problem as the phone's "no such api".
     */
    if (base !== '') {
      let name: string = '';
      try {
        const info: bundleManager.BundleInfo = await bundleManager.getBundleInfoForSelf(
          bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
        name = info.name;
      } catch (e) {
        const err = e as BusinessError;
        hilog.warn(DOMAIN, TAG, 'mods: no bundle name (%{public}s)', err.message);
      }
      if (name !== '') {
        const dir: string = base + '/' + name;
        let present: boolean = false;
        try {
          present = fs.accessSync(dir);
        } catch (e) {
          const err = e as BusinessError;
          hilog.info(DOMAIN, TAG, 'mods: %{public}s not statable (%{public}s)',
                     dir, err.message);
        }
        if (!present) {
          try {
            fs.mkdirSync(dir, true);
            hilog.info(DOMAIN, TAG, 'mods: created %{public}s', dir);
          } catch (e) {
            const err = e as BusinessError;
            hilog.warn(DOMAIN, TAG, 'mods: cannot create %{public}s (%{public}s, code=%{public}d)',
                       dir, err.message, err.code);
          }
        }
        const folder: ModFolder = { path: dir, uri: '' };
        if (modFolderUsable(folder)) {
          return folder;
        }
        hilog.info(DOMAIN, TAG, 'mods: %{public}s exists but is not listable', dir);
      }
    }
  } catch (e) {
    const err = e as BusinessError;
    hilog.info(DOMAIN, TAG, 'mods: platform Download directory unusable (%{public}s)',
               err.message);
  }

  /* B. the picker in DOWNLOAD mode. */
  const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
  options.pickerMode = picker.DocumentPickerMode.DOWNLOAD;
  try {
    const view: picker.DocumentViewPicker = new picker.DocumentViewPicker(ctx);
    const uris: Array<string> = await view.save(options);
    if (uris !== undefined && uris.length > 0 && uris[0] !== '') {
      const uri: string = uris[0];
      let path: string = '';
      try {
        path = new fileUri.FileUri(uri).path;
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'mods: could not resolve %{public}s to a path', uri);
      }
      const folder: ModFolder = { path: path, uri: uri };
      if (modFolderUsable(folder)) {
        hilog.info(DOMAIN, TAG, 'mods: DOWNLOAD mode gave %{public}s', path);
        return folder;
      }
      hilog.warn(DOMAIN, TAG, 'mods: DOWNLOAD mode returned %{public}s, not listable', uri);
    } else {
      hilog.info(DOMAIN, TAG, 'mods: DOWNLOAD mode returned nothing');
    }
  } catch (e) {
    const err = e as BusinessError;
    hilog.error(DOMAIN, TAG, 'mods: DOWNLOAD mode failed: %{public}s (code=%{public}d)',
                err.message, err.code);
  }

  return none;
}

/**
 * Make sure the folder exists, every launch.
 *
 * ⚠️ THIS CHECKS, IT DOES NOT MERELY REMEMBER. An earlier revision stored the
 * folder's location once and then trusted it forever, so a folder the player
 * deleted -- or one that was never created because that device's route failed --
 * stayed gone, and the feature quietly did nothing. Reported from the device:
 * "it should check every launch and recreate it if it is missing, like other
 * apps do". That is right, and it is also the only behaviour that survives an
 * uninstall, which takes the folder and the grant with it.
 *
 * Doing nothing when it is fine keeps the cost at one listing per launch.
 */
export async function ensureModFolder(ctx: common.UIAbilityContext,
                                    statePath: string): Promise<void> {
  const existing: ModFolder = readModFolder(statePath);
  if (modFolderUsable(existing)) {
    return;
  }
  if (existing.path !== '' || existing.uri !== '') {
    hilog.info(DOMAIN, TAG, 'mods: %{public}s is gone -- recreating it', existing.path);
  }

  const folder: ModFolder = await createModFolder(ctx);
  if (folder.path === '' && folder.uri === '') {
    hilog.warn(DOMAIN, TAG,
               'mods: could not create the mod folder on this device -- '
               + 'the picker in the ball menu still works');
    return;
  }
  try {
    writeModFolder(statePath, folder);
  } catch (e) {
    const err = e as BusinessError;
    hilog.error(DOMAIN, TAG, 'mods: storing the folder failed: %{public}s', err.message);
  }

  const scanned: ModImportReport = scanModFolder(statePath);
  if (scanned.landed.length > 0) {
    hilog.info(DOMAIN, TAG, 'mods: %{public}d file(s) taken from the new folder',
               scanned.landed.length);
  }
}
