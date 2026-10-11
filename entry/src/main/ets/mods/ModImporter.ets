/* 应用在 Downloads 里的文件夹管理 */
import { bundleManager, common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs, picker, fileUri, Environment } from '@kit.CoreFileKit';

const DOMAIN = 0x0000;
const TAG = 'MindustryLauncher';

/* 文件夹路径和可选 URI。首行为路径。 */
interface ModFolder {
  path: string;
  uri: string;
}

/**
 * 读取存储的 Mod 文件夹信息。
 * @param statePath 存储文件路径
 * @returns ModFolder 对象，无效时 path/uri 为空
 */
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

/** 文件夹路径；为空则返回 ''。用于 user_dirs.txt 桥接。 */
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

/* 按优先级列出可访问的路径/URI。 */
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

/** 文件夹存在且可读时为 true。 */
function modFolderUsable(folder: ModFolder): boolean {
  if (folder.path === '' && folder.uri === '') {
    return false;
  }
  for (const target of listTargets(folder)) {
    try {
      fs.listFileSync(target);
      return true;
    } catch (e) {
      /* 试下一个 */
    }
  }
  return false;
}

/** 在 Downloads 中创建应用的文件夹，尝试平台目录和选择器两条路线。 */
async function createModFolder(ctx: common.UIAbilityContext): Promise<ModFolder> {
  const none: ModFolder = { path: '', uri: '' };

  /* A. 平台 Download 目录 + 子目录 */
  try {
    const base: string = Environment.getUserDownloadDir();
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

  /* B. DOWNLOAD 模式选择器 */
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

/** 确保文件夹存在，每次启动调用。 */
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