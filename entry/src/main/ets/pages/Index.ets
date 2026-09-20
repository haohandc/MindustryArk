import { abilityAccessCtrl, bundleManager, common, Permissions } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { KeyCode } from '@kit.InputKit';

const DOMAIN = 0x0000;
const TAG = 'MindustryLauncher';

/**
 * Request the Download directory permission, so the player can import save
 * files and game data from there.
 *
 * The game's data import/export reads files the player puts in Download, and
 * without this grant the app's own opendir() on that path fails with EPERM.
 *
 * Note that reinstalling resets the grant: the dialog comes back after every
 * deploy and has to be answered again.
 */
const WANTED: Permissions[] = [
  'ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY'
];

async function requestPerms(ctx: common.UIAbilityContext): Promise<void> {
  try {
    const atm = abilityAccessCtrl.createAtManager();
    const bundleInfo = await bundleManager.getBundleInfoForSelf(
      bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
    const tokenId = bundleInfo.appInfo.accessTokenId;

    for (const p of WANTED) {
      const state = atm.checkAccessTokenSync(tokenId, p);
      hilog.info(DOMAIN, TAG, 'permission %{public}s state before = %{public}d (0=granted,-1=not granted)', p, state);
    }

    const res = await atm.requestPermissionsFromUser(ctx, WANTED);
    for (let i = 0; i < res.permissions.length; i++) {
      hilog.info(DOMAIN, TAG, 'requestPermissionsFromUser: %{public}s -> %{public}d',
        res.permissions[i], res.authResults[i]);
    }
  } catch (e) {
    const err = e as BusinessError;
    hilog.error(DOMAIN, TAG, 'permission request failed: %{public}s (code=%{public}d)', err.message, err.code);
  }
}

/**
 * No runtime permissions are requested any more.
 *
 * An earlier revision asked for READ_WRITE_DOWNLOAD_DIRECTORY, because the plan
 * at that time was to keep the JDK in the user's Download area -- with the
 * comment "JDK 放在用户 Download 区时要读它". That plan was abandoned: the JDK
 * now ships inside the HAP and is copied into the app's own sandbox, so the
 * permission guarded a path nothing walks any more.
 *
 * Measured before removing it: denying the permission changes nothing about how
 * the game runs. Its data goes to the sandbox -- user.home is redirected there,
 * and files/.local/share/Mindustry/ holds saves, settings.bin, mods and cache --
 * its assets come out of the game jar, and the only feature that wants a
 * user-visible directory is the file picker, whose library cannot load here at
 * all (glibc-linked; see prep_arc.py). Nothing in the game references it.
 *
 * Removing it drops an authorisation prompt at startup. The reason string
 * perm_reason_DOWNLOAD is still in resources/ -- now unreferenced and harmless.
 */

@Entry
@Component
struct Index {
  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    requestPerms(ctx);
  }

  build() {
    Row() {
      Column() {
        XComponent({ id: 'SDL_XComponent', type: XComponentType.SURFACE, libraryname: 'SDL3' })
          .id('SDL_XComponent')
          /*
           * Keyboard input needs this component to hold focus.
           *
           * ArkUI delivers key events to the focused component only, and SDL
           * receives them through the callback registered by
           * OH_NativeXComponent_RegisterKeyEventCallback. With no focus set,
           * nothing is focused, so no key event ever reaches native code -- which
           * is silent: SDL never sees a keystroke to report, and the game simply
           * behaves as though the keyboard is not connected.
           *
           * defaultFocus makes it the focus target when the page is built, and
           * focusOnTouch re-takes focus if something else ever steals it.
           */
          .focusable(true)
          .defaultFocus(true)
          .focusOnTouch(true)
          /*
           * The earliest key hook, and it must DECLINE (return false).
           *
           * Consuming ESC here does fix the system behaviour, but it was measured
           * to swallow the key before native code ever sees it: SDL logged not
           * one byte for ESC while a non-ESC control key still arrived normally.
           * So the cut is specific to consuming, not a general keyboard breakage
           * -- but it still means the game never gets its ESC, which is not an
           * acceptable trade.
           */
          .onKeyPreIme((e: KeyEvent) => {
            hilog.info(DOMAIN, TAG, 'onKeyPreIme[X]: keyCode=%{public}d -> consumed=false (pass through)',
              e.keyCode);
            return false;
          })
      }
      .width('100%')
      /*
       * ESC must stop being the system Back button WITHOUT being taken away from
       * the game. Those two requirements pull in opposite directions, so the
       * handler is placed on this ANCESTOR rather than on the XComponent, and
       * that placement is the entire fix.
       *
       * The event chain, from one measured ESC press (hilog timestamps):
       *
       *   13.965  onKeyPreIme[X]        consumed=false   <- ours, declines
       *   13.971  onKeyEvent[Column]    consumed=true    <- ours, on the ancestor
       *   (previously: Ace: OnBackPressed called -- gone once this returned true)
       *
       * The order that matters: onKeyPreIme -> XComponent (its native callback
       * runs here, and this is where SDL takes the key) -> ancestors. Because
       * ancestors are reached only *after* the XComponent has dispatched to
       * native code, consuming here cannot deprive the game of anything.
       *
       * An `onKeyEvent` attached to the XComponent itself, by contrast, is never
       * invoked at all -- the native XComponent path takes precedence over it.
       * That is a dead end regardless of what it returns, and was measured as
       * such (its log line appeared zero times). Do not move this handler back.
       *
       * Callback semantics on the native side are worth recording too:
       * SDL_OpenHarmonyDispatchKeyEvent returns void, so native code has no way
       * to report "I consumed this". The decision can only be made in ArkUI,
       * which is why this is not solved in C.
       *
       * ONLY ESC is consumed; every other key returns false so gameplay input and
       * text entry (which needs the IME) are unaffected.
       *
       * The hilog lines are not decoration. A silently-never-called handler
       * already cost this project a round: an earlier attempt used the
       * nonexistent name `onBackPress`, which compiles, runs, and is invoked
       * exactly zero times, looking for all the world like a fix that simply did
       * not work. If these lines do not appear in hilog, the handler is not
       * running and the result means nothing.
       */
      .onKeyEvent((e: KeyEvent) => {
        const esc = e.keyCode === KeyCode.KEYCODE_ESCAPE;
        hilog.info(DOMAIN, TAG, 'onKeyEvent[Column]: keyCode=%{public}d -> consumed=%{public}s',
          e.keyCode, String(esc));
        return esc;
      })
    }
    .height('100%')
  }
}
