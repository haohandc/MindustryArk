import { abilityAccessCtrl, AbilityConstant, common, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { window } from '@kit.ArkUI';
import { i18n } from '@kit.LocalizationKit';
import { inputMethod } from '@kit.IMEKit';
import { fileIo as fs, Environment } from '@kit.CoreFileKit';
import { scanDownloadMods } from '../mods/ModImporter';
import pointer from "@ohos.multimodalInput.pointer"
import sdl from 'libSDL3.so';

const DOMAIN = 0x0000;

/**
 * Write JVM options passed on the command line into a file the native side reads.
 *
 * WHY THIS EXISTS
 *   Trying one JVM flag used to cost a rebuild, a re-sign, a 171 MB reinstall and
 *   a relaunch -- minutes per guess. Nothing on the host can write into the app's
 *   sandbox directly: hdc can READ /data/app/el2/.../files but not write it, the
 *   app cannot read /data/local/tmp, and the Download directory is off limits to
 *   both. So the only way in is through the app itself, via launch parameters:
 *
 *     hdc shell aa start -a EntryAbility -b com.haohandc.mindustryark \
 *         --ps jvmopt1 -Xint --ps jvmopt2 -XX:TieredStopAtLevel=1
 *
 *   Keys must start with "jvmopt" so ordinary launch parameters are ignored.
 */
function writeJvmOptions(want: Want, filesDir: string): void {
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
        // 'aa start' rejects a --ps value that begins with '-', so the dash is
        // added here rather than supplied on the command line. Callers pass the
        // option without it:  --ps jvmopt1 Xint   ->   -Xint
        lines.push('-' + value);
      }
    }
    if (lines.length === 0) {
      return;
    }
    const path = filesDir + '/jvm.options';
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

/**
 * Record the platform's idea of the user-visible directories, for the native
 * side to probe.
 *
 * WHY
 *   The game's built-in file browser (mindustry/ui/FileChooser, used by "import
 *   save") roots itself at Arc's external storage path, which SdlFiles computes
 *   as user.home + separator -- and this launcher points user.home at its own
 *   sandbox. So the browser opens inside the app, where the player cannot put
 *   anything. To fix that we need a directory that is BOTH user-writable and
 *   readable by the app, and the authority on where that is is this API, not a
 *   guess about path layouts.
 *
 *   ArkTS is the only side that can ask; native is the only side that can test
 *   readability with the same libc the game uses. So ArkTS writes them down and
 *   native reads them back. A wrong guess would cost a build and a 171 MB
 *   install, so this is deliberately two-sided rather than assumed.
 */
function writeUserDirs(filesDir: string): void {
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
  /**
   * Watch for the native side finishing, then close the ability properly.
   *
   * WHY THE ABILITY HAS TO BE THE ONE TO END IT
   *   The launcher used to kill its own process once the game's main() returned.
   *   From the framework's side that is a native process dying while its ability
   *   is still running, which the system records as "Cpp Crash" -- with no signal
   *   and no crash dump, which is how we know it is a classification of an
   *   abnormal-looking exit rather than a real fault.
   *
   *   Ending normally means the ABILITY is destroyed first and the framework
   *   takes the process down afterwards. Native code has no way to do that: the
   *   ability object is an ArkTS object. So the native side drops a marker file
   *   and this polls for it -- polling rather than a callback because the two
   *   sides already share a filesystem and nothing else, and because a callback
   *   would need a native->ArkTS call on a non-JS thread.
   *
   * TWO PATHS, BOTH CHECKED
   *   Native writes under /data/storage/el2/base/files; context.filesDir is the
   *   module-scoped /data/storage/el2/base/haps/entry/files. Those are different
   *   directories, and rather than guess which one both sides can reach, the
   *   marker is written to both and both are checked here. The launcher already
   *   reads jvm.options from two locations for the same reason.
   *
   *   A marker left over from a previous run would close the app a quarter
   *   second after launch, so the native side unlinks both at startup. Do not
   *   remove that unlink.
   */
  private startExitWatch(ctx: common.UIAbilityContext): void {
    const markers: string[] = [
      ctx.filesDir + '/native_exit',
      '/data/storage/el2/base/files/native_exit'
    ];
    let ticks = 0;

    // Clear anything left over from a previous session BEFORE watching.
    //
    // The native side unlinks these too, but it does so later than we get here
    // (its main() runs after onCreate), and until it does, a stale marker is
    // indistinguishable from a fresh one -- which means an app that was
    // force-stopped mid-exit would shut itself down on the next launch. So the
    // watcher clears its own trigger first.
    for (const path of markers) {
      try {
        fs.unlinkSync(path);
      } catch (e) {
        // unlinkSync throws when there is nothing to delete, which is the
        // normal case. Nothing to do either way.
      }
    }

    const timer = setInterval(() => {
      ticks++;
      for (const path of markers) {
        try {
          // THE RETURN VALUE IS THE ANSWER. accessSync does NOT throw when the
          // file is absent -- it returns false. An earlier revision of this
          // called it and treated "no exception" as "the marker exists", which
          // made the app shut itself down on the very first tick, within a
          // quarter second of launch, every time. The hilog line said "native
          // exit marker seen" while ls showed no such file, which is what
          // finally settled it.
          if (!fs.accessSync(path)) {
            continue;  // not there yet -- the normal case until the game closes
          }
          hilog.info(DOMAIN, 'SDL/STARTUP',
                     'native exit marker seen (%{public}s) -- terminating ability', path);
          clearInterval(timer);
          ctx.terminateSelf().catch((err: BusinessError) => {
            hilog.error(DOMAIN, 'SDL/STARTUP',
                        'terminateSelf failed: %{public}s (code=%{public}d)', err.message, err.code);
          });
          return;
        } catch (e) {
          // A genuine error (bad path, no permission) -- treat as "not there"
          // and keep polling; the native side still exits on its own timeout.
        }
      }
      // Safety valve only. 2400 ticks at 250 ms is ten minutes -- far longer than
      // any session, so in practice this never fires; it exists so a bug here
      // cannot leave a timer running forever.
      if (ticks > 2400) {
        clearInterval(timer);
      }
    }, 250);
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'SDL/STARTUP', '%{public}s', 'Handing control from ArkTS to native SDL.');
    writeJvmOptions(want, this.context.filesDir);
    writeUserDirs(this.context.filesDir);
    /*
     * Before the game scans its mods directory -- which happens exactly once,
     * inside Vars.load(), and downstream of the XComponent mounting. So
     * anything the player leaves in <Downloads>/MindustryMods is live on this
     * launch, with no further ceremony.
     *
     * Fails soft by design: the Downloads grant is an ACL permission, and a
     * profile without it must not affect anything else. See ModImporter.
     */
    scanDownloadMods();
    this.startExitWatch(this.context);
    try {
        // This hands stuff to SDL's C code that it needs to deal with ArkTS interfaces. We are trying not to write scripting code, if we can
        //  handle it awkwardly in C through NAPI calls, so we have a _tiny_ surface area of risk where the script and the native code can go
        //  out of sync. This function call will add methods to `this`, such as onWindowStageCreate(), so we can drive everything from C and
        //  have almost no ArkTS code at all.
        // Which is to say: if this function call fails, your app won't actually start.
        //
        // ONLY EVER ADD PARAMETERS TO THIS FUNCTION CALL. THE C CODE WILL ABORT IF IT DOESN'T GET THE EXACT NUMBER IT EXPECTS.
        sdl.provideArkTSObjects(this, abilityAccessCtrl.createAtManager(), i18n.System, pointer.setPointerVisibleSync, inputMethod.getController());
    } catch (e) {
        hilog.info(DOMAIN, 'SDL/STARTUP', '%{public}s', 'Exception thrown! App will not start.');
    }
  }

  /*
   * There used to be an `onBackPress(): boolean` here that returned true,
   * intended to stop the back key from closing the app.
   *
   * It was dead code, and it was dead in the worst way: `onBackPress` is not a
   * UIAbility method -- the name the framework looks for is `onBackPressed` --
   * so this was never invoked. It compiles, it runs, and it does nothing, which
   * is indistinguishable from "the fix did not work" unless you go looking.
   * Measured at the time: zero hits in hilog, i.e. never called once.
   *
   * It has been removed rather than renamed, because the real fix is elsewhere
   * and this hook is not a lever anyway: `onBackPressed` returning true means
   * "move to background instead of destroying", not "cancel the back".
   *
   * ESC is handled in pages/Index.ets, where the key dispatch chain is:
   *   onKeyPreIme (declines) -> XComponent (native, SDL takes the key)
   *                          -> ancestor node (consumes, so the system does not)
   * See the comments there for the measurements behind that ordering.
   */
}

