/*
 * The app's folder in Downloads -- and NOT an importer any more.
 *
 * ⚠️ READ THIS BEFORE ADDING ANYTHING BACK.
 *
 * WHAT THIS FILE USED TO DO, AND WHY NONE OF IT IS HERE
 *   It had three jobs, and all three put files into the game's mods directory on
 *   the app's own initiative:
 *
 *     pickMods()       the floating ball's "导入模组" row: system picker, copy
 *     scanModFolder()  every launch: copy anything in this Downloads folder
 *     seedProbeMod()   every launch: plant probe-mod.jar unconditionally
 *                      (that one lived in Index.ets)
 *
 *   The middle one was the damaging one. It skipped a file only when the mods
 *   directory already held one of the same size, so DELETING A MOD IN THE GAME
 *   -- which deletes it from the sandbox -- brought it back on the next launch,
 *   forever. There was no way to make a mod stay gone, because the copy in
 *   Downloads outlived every deletion inside the game.
 *
 *   It also collided with saves. This same folder is the root the game's own file
 *   browser opens in (-Darc.sdl.chooserPath), saves are exported as .zip, and the
 *   scan accepted .zip as a mod -- so a save sitting here was swept into the mods
 *   directory as though it were a mod.
 *
 *   ⇒ All three are REMOVED at the user's direction. Nothing in this app writes
 *     into the mods directory now. The only thing that does is the game itself,
 *     when the player uses the game's own import button -- which is manual by
 *     construction and needs no code from us.
 *
 * WHY THE GAME'S OWN BUTTON IS ENOUGH
 *   It works here, confirmed on the device. An earlier revision of this file was
 *   built on the opposite claim, and the way it got there is worth keeping: the
 *   measurements were all true --
 *
 *       Platform.showFileChooser's default implementation throws
 *           throw new IllegalArgumentException("Not implemented on this platform!")
 *       the backend that implements it loads libarc-filedialogsarm64.so, which is
 *       tinyfiledialogs (zenity/kdialog/popen), glibc-linked, does not load
 *
 *   -- and the conclusion built from them was false. Read from the jar:
 *   `showFileChooser` is referenced only by DesktopLauncher, while ModsDialog --
 *   which owns the import button -- uses mindustry/ui/FileChooser, the game's OWN
 *   in-game browser, pure Java over Arc's Fi. Nothing on that path reaches the
 *   throwing default. "True measurements assembled into a false conclusion" is
 *   the failure mode this project keeps having to re-learn; see 2.10 in
 *   RELEASE-MAINTENANCE.md.
 *
 * WHAT IS LEFT, AND WHY IT STILL EXISTS
 *   The folder itself. It is created on every launch and its path is published to
 *   the native side, because:
 *
 *     - the game's file browser opens there, which is what makes "import mod" and
 *       save import/export land somewhere the player can actually reach. Without
 *       it the browser opens inside the sandbox and can see nothing the player
 *       put in Downloads.
 *
 *   ⇒ So a mod dropped here is still usable -- it just has to be PICKED in the
 *     game's browser rather than being taken automatically. Measured on the
 *     device: the folder appears in the file manager as
 *     Download/<bundle name>/, and user_dirs.txt carries its path as `mods=`.
 *
 * ⚠️ THE NAME HAS NOT KEPT UP. The file, the function and the on-disk state file
 *   are all still called mod_folder / ensureModFolder, while the thing is now the
 *   browser's root. Renaming it would mean touching the bridge format and every
 *   comment that references it, which is a bigger change than the correction is
 *   worth; the honest record is this paragraph.
 */
import { bundleManager, common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs, picker, fileUri, Environment } from '@kit.CoreFileKit';

const DOMAIN = 0x0000;
const TAG = 'MindustryLauncher';

/*
 * Where the URI of the player's chosen folder is kept.
 *
 * A URI, not a path. The permission DOWNLOAD mode hands out travels WITH the
 * URI, so writing the path down and reopening it later would be a different
 * thing that happens to name the same directory -- and would not carry the
 * grant.
 */
/*
 * Where the folder is, as a path plus an optional URI.
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

/** Read the stored folder location, or an empty pair if there is none yet. */
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
 *
 * ⚠️ THIS IS THE ONLY EXPORT LEFT, and it is now what makes save import/export
 * work: EntryAbility writes this to the bridge, the launcher passes it as
 * -Darc.sdl.chooserPath, and that is where the game's browser opens.
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

/*
 * Which of the two ways to reach the folder, in the order worth trying.
 *
 * ⚠️ THE PATH GOES FIRST, and that is a measurement, not a preference. Measured
 * on the phone, on the folder DOWNLOAD mode had just made for us:
 *
 *     /storage/Users/currentUser/Download/<bundle>        lists fine
 *     file://docs/storage/Users/currentUser/Download/...  "No such file or directory"
 *
 * The URI is not something fs.listFileSync will take as-is -- the guide resolves
 * it with new fileUri.FileUri(uri).path, which is exactly how the path above was
 * obtained. So the path is the usable form and the URI is the fallback, for a
 * device where the grant is what makes the folder reachable rather than the
 * path itself.
 *
 * An earlier revision tried the URI first, which worked only because the second
 * attempt rescued it -- and logged a failure on every launch while doing so.
 */
function listTargets(folder: ModFolder): Array<string> {
  const targets: Array<string> = [];
  if (folder.path !== '') {
    targets.push(folder.path);
  }
  if (folder.uri !== '') {
    targets.push(folder.uri);
  }
  return targets;
}

/** True when the folder is there and this app can read it. */
function modFolderUsable(folder: ModFolder): boolean {
  if (folder.path === '' && folder.uri === '') {
    return false;
  }
  for (const target of listTargets(folder)) {
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
 * reports and the phone does not. Note the API only returns the PATH -- it checks
 * no permission at all (the documentation says so), so a mkdir that fails with
 * EPERM is the real test, not the call succeeding.
 *
 * Route B is the picker in DOWNLOAD mode: no permission, no UI, and it creates
 * Download/<bundle name>/ itself. It returns a URI, and the grant travels with
 * that URI, which is why the URI is stored alongside the path.
 *
 * The mode's documented behaviour, which is why this is the route that works on a
 * phone at all (官方 save-user-file.md, DOWNLOAD 模式):
 *
 *     模式特点
 *       * 自动创建在 Download/包名/ 目录。
 *       * 跳过文件选择界面直接保存。
 *       * 返回的 URI 已具备持久化权限，用户可在该 URI 下创建文件。
 *
 * Returns the folder, or an empty pair if neither route worked.
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
            /* INFO, not warn. On a device where the permission is denied -- which
             * is every device this project owns -- this is the expected outcome,
             * not a problem: the picker route below needs no permission and does
             * the work. A warning here would cry wolf on every launch. */
            hilog.info(DOMAIN, TAG, 'mods: cannot create %{public}s (%{public}s)',
                       dir, err.message);
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
 * ⚠️ AND IT NO LONGER SCANS. It used to end by calling scanModFolder(), which is
 * the call that resurrected deleted mods; see the file header. Nothing reads this
 * folder's contents now. Do not add that back without deciding what should happen
 * when the player deletes a mod inside the game -- the old answer was "it comes
 * back", which is why the feature is gone.
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
               'mods: could not create the folder in Downloads on this device -- '
               + 'the game\'s file browser will open inside the sandbox instead');
    return;
  }
  try {
    writeModFolder(statePath, folder);
  } catch (e) {
    const err = e as BusinessError;
    hilog.error(DOMAIN, TAG, 'mods: storing the folder failed: %{public}s', err.message);
  }
}
