/*
 * Get a crash report out of the sandbox, to somewhere the player can send it.
 *
 * THE PROBLEM THIS SOLVES
 *   The native side already writes a good crash dump. launcher.c's
 *   on_fatal_signal() catches SIGSEGV/SIGABRT/SIGBUS/SIGILL/SIGFPE and records
 *   the signal, the fault address, the thread name, the mapping, the PC, the
 *   registers and the instruction, plus the raw code words in cc_dump.bin.
 *
 *   What is missing is not the dump, it is a way to get it OFF the device. On a
 *   release-signed install nothing outside the app can read the sandbox: hdc
 *   cannot, pidof cannot, the fault logger cannot -- all measured. So today a
 *   store user reporting "it crashes on launch" is a report with no evidence
 *   behind it, and that is the support case this exists for.
 *
 * TWO STEPS, BECAUSE TWO OPPOSITE CLOCKS ARE INVOLVED
 *   Step 1 must run as EARLY as possible. Step 2 must run as LATE as possible.
 *
 *   Step 1 -- stashIfAny(), from EntryAbility.onCreate.
 *     launcher.c unlinks crash.txt every time main() is entered, deliberately:
 *     the file is written with O_APPEND so a fatal signal -- which can strike
 *     before stdout is usable -- never loses its report, which also means it
 *     would otherwise accumulate several launches into one confusing report.
 *
 *     ArkTS onCreate runs BEFORE native main() (the ordering is visible in
 *     EntryAbility: provideArkTSObjects() is the handover, and main() is what
 *     it starts). So onCreate is the only window in which the previous launch's
 *     crash is still on disk. Read it there, or lose it.
 *     See the timeline comment at the call site.
 *
 *   Step 2 -- publish(), from the page, once the Download folder is known-good.
 *     Writing to Download/<bundle>/ is NOT a plain mkdir on every device.
 *     ModImporter.ets measured both routes and neither works alone: the platform
 *     Download directory works on the tablet and throws on the phone, while the
 *     DOWNLOAD-mode picker is the reverse and also needs a window. So the folder
 *     is only trustworthy after ensureModFolder() has succeeded on the page --
 *     which is exactly where Index.ets already rewrites the user-dirs bridge,
 *     so this rides along with that.
 *
 * WHY THE STASH GOES IN ctx.filesDir
 *   That is the HAP-level directory: it always exists and is always writable,
 *   with no grant involved. Note it is NOT /data/storage/el2/base/files -- that
 *   one is the native side's application-level directory. The two are different
 *   directories and using the wrong one fails silently; the IME bridge in
 *   Index.ets carries the same warning for the same reason.
 *
 * IDEMPOTENT, ON PURPOSE
 *   The published file is named after the crash, not after the launch, and an
 *   existing file of that name is left alone. So an app that crashes on every
 *   start produces ONE report, not one per attempt -- and two different crashes
 *   still produce two. Nothing here deletes anything.
 */
import { bundleManager } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';

const DOMAIN = 0x0000;
const TAG = 'MindustryLauncher';

/*
 * The native side's application-level directory. Written as a literal because
 * context.filesDir is a DIFFERENT directory -- see the note above.
 */
const NATIVE_FILES: string = '/data/storage/el2/base/files';
const NATIVE_CRASH: string = NATIVE_FILES + '/crash.txt';

/* Where the crash is parked between step 1 and step 2, relative to filesDir. */
const STASH_FILE: string = '/last-crash.txt';

/* First line of the stash, so step 2 can tell a real stash from junk. */
const STASH_MARKER: string = '#mindustryark-crash';

/* Subfolder of the app's Download folder, so this does not clutter the mod list. */
const OUT_SUBDIR: string = '/diagnostics';

function writeAll(path: string, text: string): void {
  const f: fs.File = fs.openSync(path,
    fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE);
  fs.writeSync(f.fd, text);
  fs.closeSync(f);
}

/** One line of environment, or a visible reason why it is missing. */
function envLines(): Array<string> {
  const lines: Array<string> = [];
  try {
    const info: bundleManager.BundleInfo =
      bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
    /*
     * Read at runtime rather than written down: a report that names the wrong
     * version is worse than one that names none, and a hand-copied constant is
     * exactly how that happens.
     */
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

/**
 * Step 1 -- read the previous launch's crash out of the sandbox before native
 * main() deletes it. Safe to call on every launch; it does nothing when there
 * was no crash, which is the normal case.
 *
 * MUST BE CALLED FROM onCreate, BEFORE provideArkTSObjects(). See the file
 * header for why that ordering is not a detail.
 */
export function stashIfAny(filesDir: string): void {
  try {
    /* accessSync RETURNS a boolean; it does not throw when the file is absent.
     * Treating "no exception" as "it exists" has caused a real defect in this
     * codebase before (see EntryAbility.startExitWatch). */
    if (!fs.accessSync(NATIVE_CRASH)) {
      return;
    }
    const text: string = fs.readTextSync(NATIVE_CRASH);
    if (text.trim().length === 0) {
      return;
    }

    /*
     * Prefer the crash file's own mtime: it says when the crash was WRITTEN,
     * which is what "crashed at" should mean. Date.now() would only say when
     * the next launch happened to notice it. Fall back if stat fails.
     */
    let crashedAt: number = Date.now();
    try {
      crashedAt = fs.statSync(NATIVE_CRASH).mtime;
    } catch (e) {
      /* keep the fallback */
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

/**
 * How much of a log file to keep. The logs are rewritten from scratch on every
 * launch (the launcher opens them O_TRUNC), so this bounds a single session's
 * tail -- large enough to contain a boot, small enough to attach to a message.
 */
const LOG_TAIL_BYTES = 128 * 1024;

/** The tail of a file, or a visible reason why there is none. */
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
    /*
     * Read only the tail. fs.readTextSync takes offset/length, so a multi-megabyte
     * log does not have to be pulled into a string just to be thrown away.
     */
    return '... [truncated: last ' + limit + ' of ' + size + ' bytes] ...\n' +
           fs.readTextSync(path, { offset: size - limit, length: limit });
  } catch (e) {
    const err = e as BusinessError;
    return '(unreadable: ' + err.message + ')';
  }
}

/**
 * The support bundle: everything we would ask a user for, written on demand.
 *
 * WHY THIS EXISTS SEPARATELY FROM THE AUTOMATIC PATH
 *   The automatic export above fires only when there IS a crash report. But the
 *   case that is hardest to act on has no crash at all -- "it will not start",
 *   "it behaves oddly" -- and on a release-signed install we cannot read
 *   stderr.log or stdout.log from outside either. So this packs the current
 *   session's logs plus any crash, and needs no crash to be useful.
 *
 * ⚠️ The logs belong to the CURRENT session, because the launcher truncates them
 *    at every start. That is the right thing for "it is misbehaving right now",
 *    which is when someone reaches for this.
 *
 * Unlike the automatic path this is NOT idempotent: a deliberate press should
 * produce a file each time, so its name carries the moment of the press.
 *
 * Returns the path written, or '' if nothing could be written.
 */
export function exportNow(modFolder: string, filesDir: string): string {
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
      /* already there -- the write below is the real test */
    }

    const stashPath: string = filesDir + STASH_FILE;
    const hasStash: boolean = fs.accessSync(stashPath);

    const report: string =
      'Mindustry Ark -- diagnostics bundle\n' +
      '========================================\n' +
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

/** Lift #crashed-at back out of a stash. Returns 0 when it is not there. */
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

/**
 * Step 2 -- copy the stash into the player-visible Download folder.
 *
 * modFolder is the app's folder in Downloads as a PATH (modFolderPath() returns
 * one; a URI is not usable here). Call it from the page, after ensureModFolder()
 * has resolved -- see the file header.
 */
export function publish(modFolder: string, filesDir: string): void {
  try {
    if (modFolder === '') {
      return;  // the folder is not known yet; the next launch will try again
    }
    const stashPath: string = filesDir + STASH_FILE;
    if (!fs.accessSync(stashPath)) {
      return;  // no crash to report, which is the normal case
    }
    const stash: string = fs.readTextSync(stashPath);
    const crashedAt: number = readCrashedAt(stash);
    if (crashedAt === 0) {
      return;  // not something we wrote
    }

    const dir: string = modFolder + OUT_SUBDIR;
    try {
      fs.mkdirSync(dir, true);   // recursive; EEXIST is the normal case
    } catch (e) {
      /* already there, or created concurrently -- the write below is the real test */
    }

    const target: string = dir + '/crash-' + crashedAt + '.txt';
    if (fs.accessSync(target)) {
      /* This exact crash is already published. Doing nothing here is what keeps
       * a crash-on-every-launch from filling the folder with copies. */
      return;
    }

    const report: string =
      'Mindustry Ark -- crash report\n' +
      '========================================\n' +
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
