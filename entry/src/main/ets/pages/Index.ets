import { abilityAccessCtrl, bundleManager, common, Permissions } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { KeyCode } from '@kit.InputKit';
import { window } from '@kit.ArkUI';
/* `focusControl` needs no import: it is an ArkTS framework global, like
 * getContext. Importing it from @kit.ArkUI does not compile. */

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

/*
 * Where the native side looks for these. Deliberately literal paths: ArkTS's
 * context.filesDir is the HAP-level directory, which is NOT the application-level
 * one native code shares, so a file written there would never be seen.
 */
const IME_WANT_FILE = '/data/storage/el2/base/files/ime_want';
const IME_CMD_FILE = '/data/storage/el2/base/files/ime_cmd';
/*
 * Where the game's text field actually is, as "x y w h" in game pixels.
 *
 * Used to put our invisible field ON TOP of it, so that the framework's keyboard
 * avoidance moves the page by exactly the distance needed to reveal it. Asking
 * the framework is the whole point: it already knows how to keep a focused field
 * visible above the keyboard, and it does the move itself.
 */
const IME_RECT_FILE = '/data/storage/el2/base/files/ime_rect';

/*
 * How long the game's request is ignored after the user puts the keyboard away.
 *
 * Long enough for the forwarded ESC to reach the game and for the game to close
 * its dialog -- at which point the request stops on its own and this never
 * matters. Short enough that it cannot strand anyone.
 */
const IME_DISMISS_MS = 1500;

/*
 * How long the field must have held focus before losing it counts as the user
 * dismissing the keyboard rather than something stealing the focus. Comfortably
 * longer than the poll interval, so a steal is always seen as a steal.
 */
const IME_STABLE_MS = 800;

/*
 * Extra height given to the invisible field, over and above the game's own field.
 * This is the margin knob for the whole approach: the framework pushes the page up
 * only until the focused field is visible, so this is the only lever for keeping
 * the game's field from ending up flush against the keyboard's top edge.
 */
const IME_FIELD_MARGIN_VP = 24;

@Entry
@Component
struct Index {
  @State showIme: boolean = false;
  /*
   * What the game's text field is believed to hold. The native side feeds this
   * copy through SDL_SendKeyboardText, so the two start empty together and only
   * ever move by what is sent below.
   */
  private imeSent: string = '';
  private imeTimer: number = -1;
  private imeFieldFocused: boolean = false;
  /* When the field last took focus, so a blur can tell a deliberate dismissal
   * from a stolen focus. See the onBlur handler. */
  private imeFieldFocusedAt: number = 0;
  /*
   * Until when the game's request is ignored, having just been put away by the
   * user. Without it the game's continued request reopened what the user had
   * just closed.
   *
   * A DEADLINE, not a latch, and that distinction is the whole point. The game's
   * dialog, while it stays up, keeps its text field focused and therefore keeps
   * asking -- it sends no new request that could ever clear a latch. So a latch
   * would strand a user whose ESC did not close the dialog: no keyboard, and no
   * way to ask for one. A deadline always lets the keyboard back.
   */
  private imeDismissedUntil: number = 0;
  /*
   * The game's text field, in game pixels, so our invisible field can be placed
   * over it. Values already in vp, because that is what .position() takes and
   * converting once at read time keeps the render path free of arithmetic.
   */
  @State imeFieldX: number = 0;
  @State imeFieldY: number = 0;
  @State imeFieldW: number = 1;
  @State imeFieldH: number = 1;
  /* Held so the avoid-area listener can be removed when the page goes away. */
  private imeWindow: window.Window | undefined = undefined;

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    requestPerms(ctx);
    /*
     * Poll rather than be notified: the request is made by native code in the
     * other copy of libSDL3.so, which cannot call into this page. A file is the
     * only channel the two share, and this reuses the mechanism the exit
     * handshake already uses.
     */
    this.imeTimer = setInterval(() => { this.pollImeWant(); }, 200);
    this.watchKeyboardHeight();
  }

  /*
   * Report how tall the keyboard is, next to where the game's field is.
   *
   * This is the measurement the whole approach turns on. The framework moves the
   * page only until the focused field is visible, so the question is whether the
   * field ends up above (screen height - keyboard height). Logging the keyboard's
   * own height beside the field rectangle makes that arithmetic instead of a
   * judgement call.
   *
   * Two failure modes look identical on screen -- the field is still covered -- and
   * mean opposite things: the framework moved nothing (the placement was not
   * honoured at all, and no tweaking of it will help) or it moved but not far
   * enough (the margin constant is the lever). Only these numbers separate them.
   *
   * Wrapped in try/catch: if any of it is unavailable on this device, the right
   * outcome is "no measurements", not a page that fails to build.
   */
  async watchKeyboardHeight(): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const win = await window.getLastWindow(ctx);
      this.imeWindow = win;
      /*
       * Avoid areas are documented as measured in px, while the field rectangle is
       * converted to vp for .position(); both are logged in vp so the comparison
       * is apples to apples.
       */
      win.on('avoidAreaChange', (data: window.AvoidAreaOptions) => {
        if (data.type !== window.AvoidAreaType.TYPE_KEYBOARD) {
          return;
        }
        const kbVp: number = px2vp(data.area.bottomRect.height);
        hilog.info(DOMAIN, TAG,
          'ime rect/keys: keyboard=%{public}dvp | field x=%{public}dvp y=%{public}dvp w=%{public}dvp h=%{public}dvp',
          kbVp, this.imeFieldX, this.imeFieldY, this.imeFieldW, this.imeFieldH);
      });
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'ime: keyboard measurement unavailable: %{public}s', err.message);
    }
  }

  aboutToDisappear(): void {
    if (this.imeTimer >= 0) {
      clearInterval(this.imeTimer);
      this.imeTimer = -1;
    }
    if (this.imeWindow !== undefined) {
      this.imeWindow.off('avoidAreaChange');
      this.imeWindow = undefined;
    }
  }

  pollImeWant(): void {
    let want: boolean = false;
    try {
      /* accessSync returns a boolean; it does not throw for a missing file. */
      want = fs.accessSync(IME_WANT_FILE);
    } catch (e) {
      want = false;
    }
    /*
     * The request file says what the GAME wants, not what the USER wants, and
     * conflating the two is what made the keyboard impossible to close: the user
     * dismissed it, the game still wanted text, so the next tick put it back.
     *
     * Measured, before this was split: ESC closed the keyboard and it reappeared
     * immediately, and the game's field never gave up focus because ESC never
     * reached the game (our text field had eaten it).
     *
     * So `want` falling is a fresh start, and a dismissal latches until then.
     */
    if (!want) {
      if (this.showIme) {
        this.dismissIme();
      }
      this.imeDismissedUntil = 0;
      return;
    }
    if (Date.now() < this.imeDismissedUntil) {
      return;   /* just put away by the user; give the game a moment to react */
    }
    if (this.imeDismissedUntil !== 0) {
      /*
       * The deadline expired with the game STILL asking for text. That means the
       * ESC we forwarded did not close the game's dialog -- so this is the line
       * to look for in hilog when the keyboard "comes back by itself".
       */
      hilog.warn(DOMAIN, TAG, 'IME dismissed %{public}dms ago but the game still wants text; the forwarded ESC did not release it', IME_DISMISS_MS);
      this.imeDismissedUntil = 0;
    }
    /* The field may have moved, or this may be the first usable reading. */
    this.readImeRect();
    if (!this.showIme) {
      this.showIme = true;
      this.imeSent = '';
      /*
       * The field does not exist until the frame this state change triggers has
       * been built, so the first request has to wait for it. A single delayed
       * request is enough because the case below takes over from here.
       */
      setTimeout(() => {
        if (this.showIme) {
          focusControl.requestFocus('ime_ui_field');
        }
      }, 60);
    } else if (!this.imeFieldFocused) {
      /*
       * The game still wants text and the field is up, but does not hold focus --
       * something took it. Re-take it.
       *
       * This replaces a burst of five requests spread over ~450ms after showing,
       * which was the wrong shape: a steal landing after the burst ended left the
       * field up and permanently dead, and nothing would try again. Asking on
       * every poll instead is both simpler and self-correcting, and it cannot run
       * away because a poll is every 200ms, not a loop.
       *
       * It cannot reopen what the user closed either: a dismissal sets both
       * showIme (so this branch is not reached) and imeDismissedUntil (so the
       * branch above waits out the deadline).
       */
      focusControl.requestFocus('ime_ui_field');
    }
  }

  dismissIme(): void {
    this.imeDismissedUntil = Date.now() + IME_DISMISS_MS;
    this.showIme = false;
    /* Clear this here, before the unmount's onBlur arrives: otherwise that blur
     * sees a field that "had" focus and extends the deadline, which would push
     * the keyboard back by another 1.5s on the next request. */
    this.imeFieldFocused = false;
    /* Hand the keyboard back to the game, or ESC and WASD stop arriving. */
    focusControl.requestFocus('SDL_XComponent');
  }

  /*
   * Read the game's field rectangle and place our invisible field over it.
   *
   * Called on every poll while the keyboard is up, not just once when it appears:
   * the field can move (a dialog being dragged, the viewport shrinking), and the
   * native side republishes whenever it changes.
   *
   * A bad reading NEVER overwrites a good one. The native side only writes while
   * text input is active, so the file can hold a stale-but-usable rectangle at the
   * moment the keyboard comes up -- and writing pixels where the file says
   * "0 0 0 0" for one frame would yank the layout to the top-left and back. So a
   * zero or negative area is ignored and the previous placement stands.
   */
  readImeRect(): void {
    let text: string = '';
    try {
      text = fs.readTextSync(IME_RECT_FILE);
    } catch (e) {
      return;   /* not written yet; keep whatever we had */
    }
    const parts: string[] = text.trim().split(' ');
    if (parts.length !== 4) {
      return;
    }
    const x: number = Number.parseInt(parts[0], 10);
    const y: number = Number.parseInt(parts[1], 10);
    const w: number = Number.parseInt(parts[2], 10);
    const h: number = Number.parseInt(parts[3], 10);
    if (!Number.isFinite(x) || !Number.isFinite(y) || !Number.isFinite(w) || !Number.isFinite(h)) {
      return;
    }
    if (w <= 0 || h <= 0 || x < 0 || y < 0) {
      return;
    }
    /*
     * Game pixels -> vp. SDL's rect came from Arc's Core.graphics, which is in
     * pixels, while .position() is in vp; on a tablet these differ by the display
     * density, so this conversion is load-bearing rather than cosmetic.
     */
    const xvp: number = px2vp(x);
    const yvp: number = px2vp(y);
    const wvp: number = px2vp(w);
    const hvp: number = px2vp(h);
    if (xvp === this.imeFieldX && yvp === this.imeFieldY
        && wvp === this.imeFieldW && hvp === this.imeFieldH) {
      return;   /* unchanged: assigning anyway would redraw every poll */
    }
    this.imeFieldX = xvp;
    this.imeFieldY = yvp;
    this.imeFieldW = wvp;
    /* Deliberately a little taller than the field itself. The framework only
     * guarantees that a focused field is VISIBLE, not that it clears the keyboard
     * by any margin, so a field sitting exactly on the keyboard's top edge is an
     * acceptable outcome for the framework and a cramped one for the player. The
     * extra height is what buys the margin; it costs a few more pixels of the
     * game being pushed off the top while the keyboard is up. */
    this.imeFieldH = hvp + IME_FIELD_MARGIN_VP;
  }

  appendCmd(text: string): void {
    try {
      const f: fs.File = fs.openSync(IME_CMD_FILE, fs.OpenMode.CREATE | fs.OpenMode.APPEND | fs.OpenMode.READ_WRITE);
      fs.writeSync(f.fd, text);
      fs.closeSync(f);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'ime cmd write failed: %{public}s', err.message);
    }
  }

  sendDelta(next: string): void {
    const prev: string = this.imeSent;
    if (next === prev) {
      return;
    }
    let cmds: string = '';
    if (next.startsWith(prev)) {
      cmds = 'T' + next.substring(prev.length) + '\n';
    } else if (prev.startsWith(next)) {
      cmds = 'B' + (prev.length - next.length) + '\n';
    } else {
      /* An edit we cannot express as append/truncate. Retract what we own and
       * retype it: the field ends up right, and text the game already had before
       * this session is left untouched. */
      if (prev.length > 0) {
        cmds += 'B' + prev.length + '\n';
      }
      cmds += 'T' + next + '\n';
    }
    this.imeSent = next;
    this.appendCmd(cmds);
  }

  build() {
    /* A Stack so the text field floats over the game instead of reflowing the
     * game surface to make room for it. */
    Stack({ alignContent: Alignment.Top }) {
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
           * defaultFocus makes it the focus target when the page is built.
           *
           * focusOnTouch was here and is deliberately GONE. It made the component
           * re-take focus on every touch, which put it in a race with the focus
           * request the keyboard needs: tapping the game's text field produces a
           * touch on this surface, the request goes out after a poll delay, and if
           * the finger's remaining touch events land after it, focusOnTouch simply
           * took focus back. The field was then up but unfocused, so no keyboard.
           * That is exactly the reported symptom -- "sometimes one tap is enough,
           * sometimes it is not" -- and a race that depends on how the finger's
           * events interleave can only ever look intermittent.
           *
           * Losing it costs nothing: touch still reaches the game (ArkUI delivers
           * pointer events by coordinate, not by focus -- only KEY events follow
           * focus), initial focus still comes from defaultFocus, and every path
           * that dismisses the keyboard requests focus back explicitly.
           */
          .focusable(true)
          .defaultFocus(true)
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

      /*
       * Appears only while a text field inside the game is focused. Single-line:
       * the command protocol is line-based, and Mindustry's fields (a save name,
       * a filename) are single-line anyway.
       */
      if (this.showIme) {
        /*
         * Invisible on purpose: the user reads what they typed in the GAME's own
         * field, which updates as they type, so showing a second field was both
         * redundant and confusing. With this hidden, the visible result is the
         * system keyboard driving Mindustry directly.
         *
         * It still has to exist, be focusable, and hold the IME -- an invisible
         * component with focus is what keeps the keyboard up. If the input method
         * ever refuses to appear for a zero-opacity field, this is the line to
         * revisit: give it opacity 0.01 instead.
         *
         * It sits exactly over the GAME's field, rather than at the top of the
         * screen as it used to. That placement is the entire mechanism: the
         * framework's keyboard avoidance moves the page only until this focused
         * field is visible, so putting it where the player is actually looking
         * makes the framework move the game by precisely the amount that reveals
         * that spot. Anchored at the top it asked for nothing, so nothing moved and
         * the keyboard covered the field.
         */
        TextInput()
          .id('ime_ui_field')
          .position({ x: this.imeFieldX, y: this.imeFieldY })
          .width(this.imeFieldW)
          .height(this.imeFieldH)
          .opacity(0)
          .onChange((v: string) => {
            this.sendDelta(v.replace(/[\r\n]/g, ''));
          })
          .onFocus(() => {
            this.imeFieldFocused = true;
            this.imeFieldFocusedAt = Date.now();
          })
          .onBlur(() => {
            /*
             * Hold off before taking the focus back -- but only when the blur
             * looks deliberate. Two different things reach this handler:
             *
             *   the user put the keyboard away   -> respect it, wait the deadline
             *   something stole the focus        -> take it back on the next poll
             *
             * Both used to be treated as the first, which turned a steal into a
             * 1.5s dead window that read to the user as "the keyboard stopped
             * responding". The field being visibly keyboard-holding for a while is
             * what separates them: a steal lands right after we ask for focus,
             * while a dismissal comes once the user has been typing.
             *
             * Either way, the ordinary flow does not depend on this -- tapping
             * away from the game's field makes the game stop asking, and that path
             * goes through `want` instead.
             */
            const had: boolean = this.imeFieldFocused;
            const heldFor: number = Date.now() - this.imeFieldFocusedAt;
            this.imeFieldFocused = false;
            if (had && heldFor > IME_STABLE_MS) {
              this.imeDismissedUntil = Date.now() + IME_DISMISS_MS;
            }
          })
          .onSubmit(() => {
            /* Done on the keyboard: put the game back in charge of input. */
            this.dismissIme();
          })
      }
    }
    /*
     * ESC, at the Stack: the common ancestor of the game surface and our field,
     * and therefore the only node that sees the key whichever of the two is
     * focused.
     *
     * Focus is singular, and that is the whole reason BOTH hooks below exist:
     *
     *   field focused    -> the Column is not in the focus chain, so its handler
     *                       never runs, and the key must be caught here
     *   game focused     -> the Column IS in the chain, and its handler is enough
     *
     * onKeyPreIme has to come first because onKeyEvent on an ancestor was measured
     * NOT to fire while the TextInput holds focus -- the field consumes the key
     * before the ancestor sees it. So the onKeyEvent below is the fallback, not
     * the primary.
     *
     * Consumed ONLY while our field is up. Consuming it when the game has focus is
     * what once made SDL see nothing at all for ESC -- the XComponent's native
     * callback runs *after* this hook -- and that cost a round to find. Returning
     * false in that case lets it through untouched.
     *
     * What consuming does: forwards ESC into the game (so the game closes its own
     * dialog, which is what actually releases the field and stops the request),
     * and latches the dismissal locally so the next poll cannot undo it.
     *
     * Returning true matters separately from the forwarding: it is what stops
     * HarmonyOS from treating ESC as Back and dropping the app to the home screen.
     */
    .onKeyPreIme((e: KeyEvent) => {
      const esc: boolean = e.keyCode === KeyCode.KEYCODE_ESCAPE;
      /* Logged unconditionally. Whether an ancestor's onKeyPreIme fires while a
       * descendant TextInput holds focus is the premise this fix rests on, and it
       * is not obvious -- so if ESC misbehaves again, these lines say whether the
       * premise held, instead of leaving the failure ambiguous. */
      hilog.info(DOMAIN, TAG, 'onKeyPreIme[Stack]: keyCode=%{public}d showIme=%{public}s -> consumed=%{public}s',
        e.keyCode, String(this.showIme), String(esc && this.showIme));
      if (esc && this.showIme) {
        this.appendCmd('E' + '\n');
        this.dismissIme();
        return true;
      }
      return false;
    })
    .onKeyEvent((e: KeyEvent) => {
      const esc: boolean = e.keyCode === KeyCode.KEYCODE_ESCAPE;
      if (esc && this.showIme) {
        /* Same action as the hook above, kept as a net for the case where the
         * key arrives by a path that skips onKeyPreIme. Returning true either way,
         * because HarmonyOS must not treat ESC as Back. */
        this.appendCmd('E' + '\n');
        this.dismissIme();
        return true;
      }
      return esc;
    })
  }
}
