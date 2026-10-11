import { bundleManager } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';

const DOMAIN = 0x0000;
const TAG = 'MindustryLauncher';

const NATIVE_FILES: string = '/data/storage/el2/base/files';
const NATIVE_CRASH: string = NATIVE_FILES + '/crash.txt';

const STASH_FILE: string = '/last-crash.txt';

const STASH_MARKER: string = '#mindustryark-crash';

const OUT_SUBDIR: string = '/diagnostics';

function writeAll(path: string, text: string): void {
  const f: fs.File = fs.openSync(path,
    fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE);
  fs.writeSync(f.fd, text);
  fs.closeSync(f);
}

function envLines(): Array<string> {
  const lines: Array<string> = [];
  try {
    const info: bundleManager.BundleInfo =
      bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
    lines.push('app          : ' + info.versionName + ' (' + info.versionCode + ')');
    lines.push('bundle       : ' + info.name);
  } catch (e) {
    const err = e as BusinessError;
    lines.push('app          : <unavailable: ' + err.message + '>');
  }
  try {
    lines.push('device       : ' + deviceInfo.brand + ' ' + deviceInfo.productModel);
    lines.push('system       : ' + deviceInfo.osFullName + '  API ' + deviceInfo.sdkApiVersion);
  } catch (e) {
    const err = e as BusinessError;
    lines.push('device       : <unavailable: ' + err.message + '>');
  }
  return lines;
}

export function stashIfAny(filesDir: string): void {
  try {
    if (!fs.accessSync(NATIVE_CRASH)) {
      return;
    }
    const text: string = fs.readTextSync(NATIVE_CRASH);
    if (text.trim().length === 0) {
      return;
    }

    let crashedAt: number = Date.now();
    try {
      crashedAt = fs.statSync(NATIVE_CRASH).mtime;
    } catch (e) {
    }

    writeAll(filesDir + STASH_FILE,
             STASH_MARKER + '\n' +
             '#crashed-at=' + crashedAt + '\n' +
             text);

    hilog.warn(DOMAIN, TAG,
               'captured a crash report from the previous launch (%{public}d bytes) -- '
               + 'it will be published to Downloads once the folder is ready',
               text.length);
  } catch (e) {
    const err = e as BusinessError;
    hilog.error(DOMAIN, TAG, 'stashing the crash report failed: %{public}s', err.message);
  }
}

const LOG_TAIL_BYTES = 128 * 1024;

function readTail(path: string, limit: number): string {
  try {
    if (!fs.accessSync(path)) {
      return '(not present)';
    }
    const size: number = fs.statSync(path).size;
    if (size === 0) {
      return '(empty)';
    }
    if (size <= limit) {
      return fs.readTextSync(path);
    }
    return '... [truncated: last ' + limit + ' of ' + size + ' bytes] ...\n' +
           fs.readTextSync(path, { offset: size - limit, length: limit });
  } catch (e) {
    const err = e as BusinessError;
    return '(unreadable: ' + err.message + ')';
  }
}

export function readStartupLogTail(maxBytes: number): string {
  return readTail(NATIVE_FILES + '/stderr.log', maxBytes);
}

function banner(appName: string, what: string): string {
  const who: string = appName === '' ? 'unknown app' : appName;
  return who + ' -- ' + what + '\n' + '========================================\n';
}

export function exportNow(appName: string, modFolder: string, filesDir: string): string {
  try {
    if (modFolder === '') {
      hilog.error(DOMAIN, TAG, 'cannot export diagnostics: the Downloads folder is not known');
      return '';
    }
    const now: number = Date.now();
    const dir: string = modFolder + OUT_SUBDIR;
    try {
      fs.mkdirSync(dir, true);
    } catch (e) {
    }

    const stashPath: string = filesDir + STASH_FILE;
    const hasStash: boolean = fs.accessSync(stashPath);

    const report: string =
      banner(appName, 'diagnostics bundle') +
      envLines().join('\n') + '\n' +
      'collected at : ' + new Date(now).toString() + '\n' +
      '========================================\n' +
      '\n' +
      '## crash report from the previous launch\n' +
      '\n' +
      (hasStash ? fs.readTextSync(stashPath)
                : '(none -- the previous launch did not leave one)\n') +
      '\n' +
      '## crash.txt as it is on disk now\n' +
      '\n' +
      readTail(NATIVE_CRASH, LOG_TAIL_BYTES) + '\n' +
      '\n' +
      '## stderr.log (current session, tail)\n' +
      '\n' +
      readTail(NATIVE_FILES + '/stderr.log', LOG_TAIL_BYTES) + '\n' +
      '\n' +
      '## stdout.log (current session, tail)\n' +
      '\n' +
      readTail(NATIVE_FILES + '/stdout.log', LOG_TAIL_BYTES) + '\n';

    const target: string = dir + '/diagnostics-' + now + '.txt';
    writeAll(target, report);
    hilog.info(DOMAIN, TAG, 'exported a diagnostics bundle to %{public}s', target);
    return target;
  } catch (e) {
    const err = e as BusinessError;
    hilog.error(DOMAIN, TAG, 'exporting diagnostics failed: %{public}s', err.message);
    return '';
  }
}

function readCrashedAt(stash: string): number {
  const lines: Array<string> = stash.split('\n');
  if (lines.length < 2 || lines[0].trim() !== STASH_MARKER) {
    return 0;
  }
  const tag: string = '#crashed-at=';
  if (lines[1].indexOf(tag) !== 0) {
    return 0;
  }
  const value: number = Number.parseInt(lines[1].substring(tag.length).trim(), 10);
  return Number.isNaN(value) ? 0 : value;
}

export function publish(modFolder: string, filesDir: string, appName: string): void {
  try {
    if (modFolder === '') {
      return;
    }
    const stashPath: string = filesDir + STASH_FILE;
    if (!fs.accessSync(stashPath)) {
      return;
    }
    const stash: string = fs.readTextSync(stashPath);
    const crashedAt: number = readCrashedAt(stash);
    if (crashedAt === 0) {
      return;
    }

    const dir: string = modFolder + OUT_SUBDIR;
    try {
      fs.mkdirSync(dir, true);
    } catch (e) {
    }

    const target: string = dir + '/crash-' + crashedAt + '.txt';
    if (fs.accessSync(target)) {
      return;
    }

    const report: string =
      banner(appName, 'crash report') +
      envLines().join('\n') + '\n' +
      'crashed at   : ' + new Date(crashedAt).toString() + '\n' +
      'reported at  : ' + new Date().toString() + '\n' +
      '\n' +
      'Crash reports are collected from the device only when the app itself\n' +
      'writes them here; nothing is uploaded anywhere.\n' +
      '\n' +
      '========================================\n' +
      'raw crash dump follows\n' +
      '========================================\n\n' +
      stash;

    writeAll(target, report);
    hilog.warn(DOMAIN, TAG, 'published a crash report to %{public}s', target);
  } catch (e) {
    const err = e as BusinessError;
    hilog.error(DOMAIN, TAG, 'publishing the crash report failed: %{public}s', err.message);
  }
}