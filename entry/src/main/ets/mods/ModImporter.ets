/* 应用在 Downloads 里的文件夹 —— 它已经【不再是】导入器了。
 * 三个自作主张往 mods 目录塞文件的旧职责（pickMods / scanModFolder / seedProbeMod）都已移除：scanModFolder
 * 只在 mods 目录已存在同大小文件时才跳过 ⇒ 玩家删掉一个 mod 后，下次启动就会把它带回来；它还和存档撞车
 * （同一文件夹正是游戏浏览器打开的根 -Darc.sdl.chooserPath，存档导出为 .zip 而扫描把 .zip 当 mod 接受）。
 * ⚠️ 游戏自己的导入按钮在设备上确认可用：别信「Platform.showFileChooser 默认实现抛 Not implemented」那条
 * 旧结论 —— 持有该按钮的 ModsDialog 用的是游戏【自己】的纯 Java 浏览器（RELEASE-MAINTENANCE.md 2.10）。
 * 保留的是文件夹本身（每次启动创建、路径发布给 native 让游戏浏览器落在玩家够得着的地方）：丢进来的 mod 仍
 * 可用，只是必须【手动挑中】——设备实测显示为 Download/<bundle name>/，user_dirs.txt 记为 `mods=`。
 */
import { bundleManager, common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs, picker, fileUri, Environment } from '@kit.CoreFileKit';

const DOMAIN = 0x0000;
const TAG = 'MindustryLauncher';

/* 文件夹在哪里：路径加上一个可选的 URI。是 URI 不是路径，因为 DOWNLOAD 模式发出的权限
 * 【跟着】URI 走 —— 把路径写下来以后再用它打开，只是碰巧指向同一个目录，不携带那份授权。
 * 【首行永远是路径】，这样 user_dirs.txt 桥接能取走第一行而不必知道后面的内容；有 URI 就留着
 * （手机上该文件夹只能靠选择器交回的授权够得着；平板上路径就够了）。 */
interface ModFolder {
  path: string;
  uri: string;
}

/** 读取已存储的文件夹位置；如果还没有，就返回一对空值。 */
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

/** 文件夹的路径；如果没有，就是 ''。导出是因为 user_dirs.txt 桥接要的正好是这个，而不该被迫知道本文件的格式
 * （它过去读 URI 再用 fileUri 解析，路径被直接存下来后那种做法就不对了）。
 * ⚠️ 这是剩下的唯一导出，也正是它让存档的导入/导出能工作：EntryAbility 把它写进桥接，launcher 把它作为
 * -Darc.sdl.chooserPath 传下去，游戏浏览器就在那里打开。 */
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

/* 到达这个文件夹的两条路，按值得尝试的顺序排列。
 * ⚠️ 路径在前是测量结果：手机上对 DOWNLOAD 模式刚建好的文件夹实测，/storage/Users/currentUser/Download/<bundle>
 * 能列出，而 file://docs/... 报 "No such file or directory"。URI 不是 fs.listFileSync 能直接接受的（要用
 * new fileUri.FileUri(uri).path 解析）；路径是可用形式，URI 只作回退，留给靠授权才够得着的设备。 */
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

/** 当文件夹存在、且本应用能读它时为 true。 */
function modFolderUsable(folder: ModFolder): boolean {
  if (folder.path === '' && folder.uri === '') {
    return false;
  }
  for (const target of listTargets(folder)) {
    try {
      fs.listFileSync(target);
      return true;
    } catch (e) {
      /* 试下一个目标 */
    }
  }
  return false;
}

/** 在 Downloads 里创建应用的文件夹，用这台设备支持的那一条路线。
 * 两条互补（单独任一条都不够）：平台 Download 目录 —— getUserDownloadDir() 平板上可用、手机上抛异常；
 * DOWNLOAD 模式选择器 —— 手机上可用、平板上失败，失败码 13900042。⚠️ getUserDownloadDir() 只返回【路径】、
 * 不检查权限，真正算数的是 mkdir 是否以 EPERM 失败；路线 B 不需要权限也没有 UI，URI 带持久化权限。 */
async function createModFolder(ctx: common.UIAbilityContext): Promise<ModFolder> {
  const none: ModFolder = { path: '', uri: '' };

  /* A. 平台自己的 Download 目录 + 我们自己的子目录。
   * 已经在就什么都不做（从第二次启动起是常态）—— 这个检查正是让「被手动删掉了」可恢复的原因。 */
  try {
    const base: string = Environment.getUserDownloadDir();
    /* 与下面的 mkdir 分开上报：「the platform Download directory is unusable」涵盖三种不同失败
     * （API 不受支持 / 目录够不着 / 写入被拒）。平板实测：API 有应答（返回
     * /storage/Users/currentUser/Download）而写入以 EPERM 被拒，与手机的 "no such api" 不是一回事。 */
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
            /* 用 INFO，不用 warn：在权限被拒的设备上（本项目的每一台都是）这是预期结果 ——
             * 下面那条选择器路线不需要权限，活儿由它来干；打 warning 会每次启动虚报狼来了。 */
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

  /* B. DOWNLOAD 模式下的选择器。 */
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

/** 确保这个文件夹存在，每次启动都如此。
 * ⚠️ 它是去【检查】，不是只靠【记住】：更早一版存一次位置就永远信任它，结果被玩家删掉的（或那台设备路线
 * 失败而从未创建的）文件夹一直是没的状态，功能悄无声息地什么都不做。这也是唯一能在卸载后幸存的行为。
 * ⚠️ 它不再扫描：那个调用让被删掉的 mod 复活（见文件头），不要把 scan 加回来。 */
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
