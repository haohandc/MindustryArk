import { abilityAccessCtrl, AbilityConstant, common, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { window } from '@kit.ArkUI';
import { i18n } from '@kit.LocalizationKit';
import { inputMethod } from '@kit.IMEKit';
import { fileIo as fs, Environment } from '@kit.CoreFileKit';
import { modFolderPath } from '../mods/ModImporter';
import { GameResolution, readSelection, resolveGame, bundledGamePath } from '../games/GameLibrary';
import { computeKey, readGranularity, writeIsolationBridge } from '../settings/Isolation';
import { SANDBOX_ROOT } from '../settings/StorageRoot';
import { stashIfAny } from '../diagnostics/ExportDiagnostics';
import pointer from "@ohos.multimodalInput.pointer"
import sdl from 'libSDL3.so';

const DOMAIN = 0x0000;

/** 把命令行JVM选项写入文件，供native侧读取。键必须以"jvmopt"开头。 */
function writeJvmOptions(want: Want): void {
  try {
    const params = want.parameters;
    if (!params) {
      return;
    }
    const lines: string[] = [];
    for (const key of Object.keys(params)) {
      if (key.indexOf('jvmopt') !== 0) {
        continue;
      }
      const value = params[key];
      if (typeof value === 'string' && value.length > 0) {
        lines.push('-' + value);
      }
    }
    if (lines.length === 0) {
      return;
    }
    const path = SANDBOX_ROOT + '/jvm.options';
    const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE);
    fs.writeSync(file.fd, lines.join('\n') + '\n');
    fs.closeSync(file);
    hilog.info(DOMAIN, 'SDL/STARTUP', 'wrote %{public}d jvm option(s) to %{public}s',
               lines.length, path);
  } catch (e) {
    hilog.error(DOMAIN, 'SDL/STARTUP', 'writing jvm options failed: %{public}s',
                JSON.stringify(e));
  }
}

/** 记录用户可见目录，供native侧探测。 */
export function writeUserDirs(filesDir: string): void {
  const lines: string[] = [];
  try {
    lines.push('download=' + Environment.getUserDownloadDir());
  } catch (e) {
    lines.push('download=<threw>');
  }
  try {
    lines.push('document=' + Environment.getUserDocumentDir());
  } catch (e) {
    lines.push('document=<threw>');
  }
  try {
    lines.push('filesdir=' + filesDir);
  } catch (e) {
    lines.push('filesdir=<threw>');
  }
  try {
    const where: string = modFolderPath(filesDir + '/mod_folder');
    if (where !== '') {
      lines.push('mods=' + where);
    }
  } catch (e) {
    lines.push('mods=<threw>');
  }

  try {
    const chosen: string = readSelection(filesDir);
    if (chosen !== '') {
      lines.push('gamejar=' + chosen);
    }
  } catch (e) {
    lines.push('gamejar=<threw>');
  }

  for (const line of lines) {
    hilog.info(DOMAIN, 'SDL/STARTUP', 'user dir: %{public}s', line);
  }

  try {
    const path = filesDir + '/user_dirs.txt';
    const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE);
    fs.writeSync(file.fd, lines.join('\n') + '\n');
    fs.closeSync(file);
  } catch (e) {
    hilog.error(DOMAIN, 'SDL/STARTUP', 'writing user_dirs.txt failed: %{public}s', JSON.stringify(e));
  }
}

export default class EntryAbility extends UIAbility {
  private exitWatchTimer: number = -1;

  /** 轮询native exit标记，体面关闭ability。 */
  private startExitWatch(ctx: common.UIAbilityContext): void {
    const markers: string[] = [
      ctx.filesDir + '/native_exit',
      '/data/storage/el2/base/files/native_exit'
    ];
    let ticks = 0;

    for (const path of markers) {
      try {
        fs.unlinkSync(path);
      } catch (e) {
      }
    }

    const timer = setInterval(() => {
      ticks++;
      for (const path of markers) {
        try {
          if (!fs.accessSync(path)) {
            continue;
          }
          hilog.info(DOMAIN, 'SDL/STARTUP',
                     'native exit marker seen (%{public}s) -- terminating ability', path);
          clearInterval(timer);
          this.exitWatchTimer = -1;
          ctx.terminateSelf().catch((err: BusinessError) => {
            hilog.error(DOMAIN, 'SDL/STARTUP',
                        'terminateSelf failed: %{public}s (code=%{public}d)', err.message, err.code);
          });
          return;
        } catch (e) {
        }
      }
      if (ticks > 2400) {
        clearInterval(timer);
        this.exitWatchTimer = -1;
      }
    }, 250);
    this.exitWatchTimer = timer;
  }

  onDestroy(): void {
    if (this.exitWatchTimer !== -1) {
      clearInterval(this.exitWatchTimer);
      this.exitWatchTimer = -1;
      hilog.info(DOMAIN, 'SDL/STARTUP', 'exit watch stopped with the ability');
    }
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'SDL/STARTUP', '%{public}s', 'Handing control from ArkTS to native SDL.');
    stashIfAny(this.context.filesDir);
    writeJvmOptions(want);
    writeUserDirs(this.context.filesDir);
    try {
      const g: string = readGranularity(this.context.filesDir);
      const res: GameResolution = resolveGame(this.context.filesDir, this.context.bundleCodeDir);
      const key: string = computeKey(g, res.source, res.path,
                                    bundledGamePath(this.context.bundleCodeDir));
      writeIsolationBridge(this.context.filesDir, g, key);
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, 'SDL/STARTUP', 'isolation: could not decide (%{public}s)', err.message);
    }
    this.startExitWatch(this.context);
    try {
        sdl.provideArkTSObjects(this, abilityAccessCtrl.createAtManager(), i18n.System, pointer.setPointerVisibleSync, inputMethod.getController());
    } catch (e) {
        hilog.info(DOMAIN, 'SDL/STARTUP', '%{public}s', 'Exception thrown! App will not start.');
    }
  }
}