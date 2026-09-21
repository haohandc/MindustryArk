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
 * Which control scheme the player chose, read by the launcher before the JVM
 * starts.
 *
 * Written next to user_dirs.txt deliberately: both are files this side writes in
 * filesDir and the native side reads at startup, and filesDir is the HAP-level
 * directory, NOT the application-level one the IME bridge uses above. Those two
 * directories look similar and are not interchangeable -- a file written to the
 * wrong one is simply never seen, with no error anywhere.
 */
const CONTROL_MODE_FILE_NAME = 'control_mode.txt';
const CONTROL_MODE_MOBILE = 'mobile';
const CONTROL_MODE_DESKTOP = 'desktop';

/*
 * The floating ball. It exists to host several functions, of which the control
 * scheme is the first, so it opens a menu rather than acting on tap.
 *
 * All sizes are vp. Touch coordinates arrive in vp too (TouchObject.windowX/Y are
 * documented as vp), which is also what .position() takes -- so nothing here needs
 * a px2vp conversion. The one place that does is the display size, which the
 * platform reports in px.
 */
/*
 * Ball size is derived from the window, not fixed.
 *
 * A fixed 44vp was measured as too small on this tablet. The size that is right
 * depends on the screen, and the screen's own short edge is the honest input: the
 * ball is a thumb target, and thumb targets scale with the device.
 *
 * Kept as a RATIO OF THE SHORT EDGE rather than a fraction of both dimensions, so a
 * landscape window does not produce a ball wider than a portrait one.
 *
 * The floor is set at 48 rather than at the old 44: 44 is the value that was found
 * too small, so the adaptive formula must never return to it. The ceiling stops a
 * very large display from producing a ball that covers the game.
 */
const BALL_SIZE_FALLBACK_VP = 48;   /* before onAreaChange has reported anything */
const BALL_SIZE_RATIO = 0.065;      /* of the window's short edge */
const BALL_SIZE_MIN_VP = 48;
const BALL_SIZE_MAX_VP = 76;
/*
 * How far the ball rests from the edge it has settled against.
 *
 * Applies on all four edges and on every path that settles it -- first placement, a
 * drag, and a position restored from disk -- so the gap does not depend on how the
 * ball got there. It was consulted only for the first placement once, which made a
 * dragged ball sit tangent while an untouched one kept its gap.
 */
const BALL_MARGIN_VP = 8;
/* How far a touch must travel before it counts as a drag rather than a tap. Without
 * this, the slightest finger movement while tapping would be read as a drag and the
 * menu would never open. */
const BALL_DRAG_SLOP_VP = 8;
const BALL_MENU_W_VP = 158;

/*
 * Auto half-hide.
 *
 * After the ball has settled against an edge it slides that much further outward so
 * only the remainder is still on screen, and drops to a lower opacity -- it should
 * stop competing with the game for attention while remaining findable.
 *
 * 0.6 hides about three fifths of the ball, as asked for, leaving the outer 40%.
 * Around 26vp of the ~66vp ball is still on screen at this tablet's density.
 *
 * That strip is the whole of the target, so this is the value that trades visibility
 * against being findable. It is workable because the tap that brings the ball back
 * only has to LAND on the strip, not be aimed at it -- and because that first tap now
 * only reveals (the menu needs a second tap), a mis-hit costs nothing but a repeat.
 * Raise this to hide more; it is the knob.
 */
const BALL_HIDE_MS = 3000;
const BALL_HIDE_FRACTION = 0.6;
const BALL_OPACITY_HIDDEN = 0.45;

/*
 * Where the ball was last parked. One line, "x,y", absolute vp.
 *
 * Absolute rather than "which edge plus a fraction" because the position is clamped
 * into the current window on restore, and a ball parked at the right edge of a wider
 * window clamps back to the right edge of a narrower one -- so the common case of a
 * changed window size corrects itself without storing anything extra.
 *
 * Lives beside control_mode.txt in the module filesDir. NOT the application-level
 * directory the IME bridge uses: those two look alike and a file written to the wrong
 * one is never seen, with no error anywhere.
 */
const BALL_POS_FILE_NAME = 'ball_pos.txt';

/*
 * How long the game's request is ignored after the user puts the keyboard away.
 *
 * Long enough for the forwarded ESC to reach the game and for the game to close
 * its dialog -- at which point the request stops on its own and this never
 * matters. Short enough that it cannot strand anyone.
 */
const IME_DISMISS_MS = 1500;

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
  /*
   * The user put the keyboard away, and it must stay away until they ask for it
   * again -- even though the GAME is still asking for text the whole time.
   *
   * `ime_want` cannot answer this: it reports what the game wants, and the game
   * never learns the user hid the keyboard, because its own field is still
   * focused and SDL therefore never calls HideScreenKeyboard. So the poll has to
   * carry the distinction itself. See the onBlur handler for how it is set and
   * the `want` branch of pollImeWant for how it is cleared.
   */
  private imeUserHid: boolean = false;
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
  /* The control scheme currently recorded on disk. Shown on the switch so the
   * player can tell which one is in force, since the change only takes effect
   * on the next launch. */
  @State controlMode: string = CONTROL_MODE_MOBILE;
  /*
   * Where the ball is, and whether its menu is open.
   *
   * ballPlaced exists because the ball cannot be positioned before the window size
   * is known: it starts at the right edge, and until onAreaChange has reported a
   * width that would put it at x=0. Placement happens once, on the first size
   * report, and the player's chosen position is never overwritten afterwards.
   */
  @State ballX: number = 0;
  @State ballY: number = 0;
  @State ballPlaced: boolean = false;
  @State ballMenu: boolean = false;
  /*
   * Ball diameter, recomputed from the window. A @State field rather than a getter
   * because the render reads it: a plain field derived from winW/winH would change
   * without the component ever being told to re-render.
   */
  @State ballSizeVp: number = BALL_SIZE_FALLBACK_VP;
  /*
   * Whether the ball is currently slid out past the edge.
   *
   * This is a RENDER-TIME offset only -- ballX/ballY always hold the revealed
   * position. That is the load-bearing choice: dragging, clamping, snapping and
   * persistence all keep working on one set of coordinates, and hiding cannot drift
   * them. The alternative (moving ballX itself) would make every one of those
   * features rediscover where the ball "really" is.
   */
  @State ballHidden: boolean = false;
  /* Which edge it last snapped to, so the hide slides the right way. */
  private ballEdge: string = 'right';
  private ballHideTimer: number = -1;
  /*
   * A position read from disk, held until the window size is known.
   *
   * It cannot be applied at read time: the value has to be clamped against the
   * window, and onAreaChange has not reported one yet. -1 means "nothing stored".
   */
  private ballRestoreX: number = -1;
  private ballRestoreY: number = -1;
  /* Whether the ball was half-hidden at the moment of touch-down. See onBallTouch. */
  private ballWasHiddenOnDown: boolean = false;
  private winW: number = 0;
  private winH: number = 0;
  /* Anchor for a drag: the ball's position and the finger's position when the touch
   * began, so the ball does not jump to centre itself under the finger. */
  private dragBallX: number = 0;
  private dragBallY: number = 0;
  private dragTouchX: number = 0;
  private dragTouchY: number = 0;
  private dragMoved: boolean = false;

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
    this.readControlMode();
    /* Held, not applied: the value needs a window size to clamp against, and
     * onAreaChange has not reported one yet. */
    this.readBallPos();
    this.enterImmersive();
  }

  /*
   * Take the status bar and the navigation bar off the screen.
   *
   * WHY THIS IS A BUG FIX AND NOT A FLOURISH
   *   The ball half-hides by sliding past the window edge. On the left and right that
   *   is a real screen edge, so it works. On the top and bottom the ball only slides
   *   into the strip the system bars occupy -- which is still visible, so the ball
   *   stays on screen and the hiding visibly does nothing. Reported from the device.
   *
   *   With the bars gone, y=0 is the physical top of the display and sliding upward
   *   really does take the ball off it.
   *
   * WHY THE BARS CAN JUST GO
   *   They are the platform's chrome, not the game's. Mindustry draws its own
   *   full-screen UI, this app has no controls of its own in that strip, and the bars
   *   cost a band of the game at all times.
   *
   * WHAT IS DELIBERATELY NOT DONE
   *   The system's back and home GESTURES are not suppressed. Hiding the bars must not
   *   strand the player inside the app: not being able to get out is far worse than a
   *   visible bar. Only the bars are removed.
   *
   * THE ONE WARNING THIS FILE ACCEPTS
   *   setWindowSystemBarEnable([]) compiles to "This API is unavailable to 2in1", and
   *   this app does declare 2in1 among its device types, so that warning is about a
   *   real gap rather than noise -- on a PC these bars would stay put.
   *
   *   The per-bar form, setSpecificSystemBarEnabled, was tried first on the theory that
   *   it would avoid the warning. It does not; it carries the same 2in1 restriction and
   *   costs TWO warnings instead of one for the same coverage. So the one-call form is
   *   kept, and the warning is accepted knowingly.
   *
   *   The 2in1 case is survivable: the call is guarded, so on a PC it fails quietly and
   *   the layout below still goes full-screen. Tablet and phone -- what this is being
   *   built and tested on -- are unaffected.
   *
   * WHY THE PAGE IS ALSO TOLD TO GO FULL-SCREEN
   *   Hiding the bars alone leaves the layout still reserving their strip, so the ball
   *   would have somewhere visible to hide into and the defect would remain. The two
   *   jobs are separate and both are needed.
   *
   * FAILURE IS SURVIVABLE
   *   Everything is guarded and a failure is logged rather than thrown. Not being
   *   immersive is exactly the state this app shipped in until now, so there is
   *   nothing here worth failing to start over.
   */
  async enterImmersive(): Promise<void> {
    try {
      const ctx: common.UIAbilityContext | undefined = this.ballCtx();
      if (ctx === undefined) {
        return;
      }
      const win: window.Window = await window.getLastWindow(ctx);
      await win.setWindowSystemBarEnable([]);   /* an empty list means neither bar */
      await win.setWindowLayoutFullScreen(true);
      win.setImmersiveModeEnabledState(true);
      hilog.info(DOMAIN, TAG, 'immersive: bars hidden, layout full-screen');
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG,
                 'immersive: not available (%{public}s) -- keeping the bars', err.message);
      return;
    }
    /*
     * Read back separately, in its own guard: this is a measurement, and a throw here
     * would be reported as "immersive unavailable" when the calls above succeeded.
     */
    try {
      const ctx: common.UIAbilityContext | undefined = this.ballCtx();
      if (ctx === undefined) {
        return;
      }
      const win: window.Window = await window.getLastWindow(ctx);
      hilog.info(DOMAIN, TAG, 'immersive: read back = %{public}s',
                 win.getImmersiveModeEnabledState() ? 'on' : 'off');
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'immersive: read-back failed: %{public}s', err.message);
    }
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
    this.cancelBallHide();
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
      /* The game let the field go, so whatever the user did before is spent:
       * the next text field must be able to raise the keyboard by itself. */
      this.imeUserHid = false;
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
    } else if (!this.imeFieldFocused && !this.imeUserHid) {
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
       * `imeUserHid` IS THE WHOLE REASON THIS IS SAFE. Without it this branch
       * cannot tell "a steal to recover from" from "the user just hid the
       * keyboard", because both are exactly "field up, no focus, game still
       * asking" -- and it re-took the focus either way, which put the keyboard
       * straight back after the user had dismissed it. The flag is what the user
       * hiding the keyboard sets, and the comment on it above says why the
       * game's own request cannot stand in for it.
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

  /*
   * Read the recorded control scheme.
   *
   * An unreadable or empty file means mobile, matching what the launcher did
   * before this setting existed -- so the button shows the truth for a fresh
   * install rather than claiming a choice nobody made.
   */
  readControlMode(): void {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const text: string = fs.readTextSync(ctx.filesDir + '/' + CONTROL_MODE_FILE_NAME);
      this.controlMode = text.trim() === CONTROL_MODE_DESKTOP
        ? CONTROL_MODE_DESKTOP : CONTROL_MODE_MOBILE;
    } catch (e) {
      this.controlMode = CONTROL_MODE_MOBILE;   /* absent: the default */
    }
  }

  /*
   * Record the other scheme and tell the player it needs a restart.
   *
   * The restart is not laziness. Mindustry derives its entire input layer and UI
   * from one bit, Vars.mobile, and that bit is written exactly once, in
   * Vars.init() -- before the game exists. Its own in-game switch changes only
   * the input handler and leaves the bit alone, which is why that switch gives
   * desktop controls on a mobile UI. So the answer has to be on disk before the
   * JVM starts, and the honest thing to do is say so rather than change nothing
   * visible and let the player think the button is broken.
   */
  toggleControlMode(): void {
    const next: string = this.controlMode === CONTROL_MODE_MOBILE
      ? CONTROL_MODE_DESKTOP : CONTROL_MODE_MOBILE;
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const f: fs.File = fs.openSync(ctx.filesDir + '/' + CONTROL_MODE_FILE_NAME,
        fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE);
      fs.writeSync(f.fd, next);
      fs.closeSync(f);
      this.controlMode = next;
      hilog.info(DOMAIN, TAG, 'control mode set to %{public}s (restart to apply)', next);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'writing control mode failed: %{public}s', err.message);
      return;                                   /* do not claim a change that did not stick */
    }
    /*
     * Tell the player, in its own try.
     *
     * The write above already succeeded, so a toast that throws must not make a
     * successful switch look like a failed one -- and showToast is declared as
     * throwing, which is what the compiler warns about when it is left bare.
     *
     * Through the UIContext rather than the global `promptAction`: the global form
     * is deprecated, and this file has enough deprecation warnings already.
     */
    try {
      this.getUIContext().getPromptAction().showToast({
        message: next === CONTROL_MODE_DESKTOP
          ? '已切换为 PC 模式，重启游戏后生效'
          : '已切换为触屏模式，重启游戏后生效',
        duration: 2600
      });
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'toast failed (the switch itself did apply): %{public}s', err.message);
    }
  }

  /*
   * Record the window size, and put the ball at the right edge the first time we
   * hear it.
   *
   * The size comes from the component rather than from the display: a window is not
   * always the whole screen, and clamping the ball against the wrong rectangle would
   * let it sit off-screen. display.getDefaultDisplaySync() is not used at all for
   * that reason.
   */
  onWindowSize(w: number, h: number): void {
    if (w <= 0 || h <= 0) {
      return;
    }
    this.winW = w;
    this.winH = h;
    /* Recomputed on every report; the size follows the window. */
    this.ballSizeVp = Math.round(
      Math.min(Math.max(Math.min(w, h) * BALL_SIZE_RATIO, BALL_SIZE_MIN_VP), BALL_SIZE_MAX_VP));
    if (this.ballPlaced) {
      /*
       * Position is deliberately NOT re-clamped on later reports.
       *
       * onAreaChange also fires while the framework pushes the page up to clear the
       * keyboard. Clamping there would drag the ball upward and leave it there once
       * the keyboard closed -- a permanent, baffling move caused by an unrelated
       * feature. A resize that leaves the ball slightly proud of an edge is a much
       * smaller problem: the stored position is clamped on the next launch, and a
       * drag fixes it immediately.
       */
      return;
    }
    const s: number = this.ballSizeVp;
    if (this.ballRestoreX >= 0 && this.ballRestoreY >= 0) {
      /*
       * Clamped to the resting band, not merely into the window.
       *
       * Lower bound: an older build wrote flush positions, and without this a ball
       * restored from one would sit tangent to the edge until the player happened to
       * drag it -- the same inconsistency this change exists to remove.
       * Upper bound: a position stored on a wider screen must not put the ball past
       * the edge of a narrower one.
       * Math.max on the upper bound keeps the band non-inverted on a tiny window.
       */
      this.ballX = Math.min(Math.max(this.ballRestoreX, BALL_MARGIN_VP),
                            Math.max(BALL_MARGIN_VP, w - s - BALL_MARGIN_VP));
      this.ballY = Math.min(Math.max(this.ballRestoreY, BALL_MARGIN_VP),
                            Math.max(BALL_MARGIN_VP, h - s - BALL_MARGIN_VP));
    } else {
      this.ballX = w - s - BALL_MARGIN_VP;
      this.ballY = Math.round(h / 3);
    }
    this.ballEdge = this.nearestEdge();
    this.ballPlaced = true;
    hilog.info(DOMAIN, TAG, 'ball: %{public}dvp on a %{public}dvp x %{public}dvp window',
               s, w, h);
    this.scheduleBallHide();
  }

  onBallTouch(e: TouchEvent): void {
    const t: TouchObject = e.touches[0];
    if (e.type === TouchType.Down) {
      /*
       * Reveal FIRST, and without animation.
       *
       * The half-hidden ball sits somewhere the revealed ball is not, so a drag
       * anchored against the hidden coordinates would fling it out from under the
       * finger -- the reported "jumps out of the half ball". Revealing on touch-down
       * also means a tap brings the whole ball back at once, which is what was asked
       * for, rather than only on release.
       *
       * The previous hidden state is captured here because the release handler needs
       * it and cannot recover it afterwards: this line is what destroys it.
       */
      this.ballWasHiddenOnDown = this.ballHidden;
      this.cancelBallHide();
      this.ballHidden = false;
      this.dragBallX = this.ballX;
      this.dragBallY = this.ballY;
      this.dragTouchX = t.windowX;
      this.dragTouchY = t.windowY;
      this.dragMoved = false;
      return;
    }

    if (e.type === TouchType.Move) {
      const dx: number = t.windowX - this.dragTouchX;
      const dy: number = t.windowY - this.dragTouchY;
      if (!this.dragMoved && Math.abs(dx) < BALL_DRAG_SLOP_VP && Math.abs(dy) < BALL_DRAG_SLOP_VP) {
        return;   /* still within tap tolerance -- do not move yet */
      }
      this.dragMoved = true;
      this.ballMenu = false;   /* dragging closes the menu */
      const s: number = this.ballSizeVp;
      /* Clamped to the window, so the ball cannot be pushed off the edge and lost. */
      this.ballX = Math.min(Math.max(this.dragBallX + dx, 0), Math.max(0, this.winW - s));
      this.ballY = Math.min(Math.max(this.dragBallY + dy, 0), Math.max(0, this.winH - s));
      return;
    }

    if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
      if (this.dragMoved) {
        this.snapBallToEdge();
        this.saveBallPos();
        this.scheduleBallHide();
      } else if (this.ballWasHiddenOnDown) {
        /*
         * The first tap only brings the ball back; the menu needs a second one.
         *
         * Without this split, tapping the half-hidden ball does two things at once:
         * it restores the ball AND opens the menu, so a player who only wanted to see
         * where the ball had gone gets a menu they did not ask for -- and has to
         * dismiss it before doing anything else. Separating the two makes the reveal
         * its own, undoable, action.
         *
         * The countdown restarts: otherwise the ball would stay out for good after
         * one tap, and the half-hide would stop being the resting state.
         */
        this.scheduleBallHide();
      } else {
        this.ballMenu = !this.ballMenu;
        /*
         * A hidden ball with an open menu would be a menu floating beside nothing, and
         * the player is mid-interaction anyway -- so the countdown restarts only once
         * the menu is dismissed.
         */
        if (!this.ballMenu) {
          this.scheduleBallHide();
        }
      }
      this.dragMoved = false;
    }
  }

  /*
   * Which edge the ball is closest to.
   *
   * Shared with the hide direction on purpose: if the snap and the hide each worked
   * it out separately they could disagree, and the ball would slide off the wrong
   * side of the screen -- visible, but well away from where anyone would look.
   */
  nearestEdge(): string {
    const s: number = this.ballSizeVp;
    const cx: number = this.ballX + s / 2;
    const cy: number = this.ballY + s / 2;
    const dLeft: number = cx;
    const dRight: number = this.winW - cx;
    const dTop: number = cy;
    const dBottom: number = this.winH - cy;
    const m: number = Math.min(dLeft, dRight, dTop, dBottom);
    if (m === dLeft) {
      return 'left';
    }
    if (m === dRight) {
      return 'right';
    }
    if (m === dTop) {
      return 'top';
    }
    return 'bottom';
  }

  /*
   * Send the ball to whichever edge is nearest.
   *
   * All four, not just left and right: the ball is small and the player may want it
   * along the top or bottom, where a left/right-only snap would fight them.
   *
   * Animated rather than jumped -- an object this size teleporting across the screen
   * reads as a glitch. animateTo closes over the assignment, so the position is set
   * once inside the callback rather than before it.
   */
  snapBallToEdge(): void {
    if (this.winW <= 0 || this.winH <= 0) {
      return;
    }
    const s: number = this.ballSizeVp;
    const edge: string = this.nearestEdge();
    /*
     * Stopped at BALL_MARGIN_VP short of the edge, not flush against it.
     *
     * Flush was the original behaviour and it disagreed with where a freshly placed
     * ball sits, which is the margin in from the edge. So a ball the player had never
     * touched kept its gap, and a ball dragged once lost it permanently. Reported from
     * the device.
     *
     * The margin is now the resting inset on every edge, for both paths.
     */
    let x: number = this.ballX;
    let y: number = this.ballY;
    if (edge === 'left') {
      x = BALL_MARGIN_VP;
    } else if (edge === 'right') {
      x = this.winW - s - BALL_MARGIN_VP;
    } else if (edge === 'top') {
      y = BALL_MARGIN_VP;
    } else {
      y = this.winH - s - BALL_MARGIN_VP;
    }
    this.ballEdge = edge;
    this.getUIContext().animateTo({ duration: 180, curve: Curve.Friction }, () => {
      this.ballX = x;
      this.ballY = y;
    });
  }

  /*
   * How far the ball is slid past its edge while hidden, as a render-time offset.
   *
   * 0 while revealed, which is the important part: ballX/ballY are the only
   * coordinates anything writes, so hiding can never be mistaken for a move.
   *
   * BALL_MARGIN_VP IS PART OF THE OFFSET, not an accident. The ball now rests a
   * margin in from the edge, so sliding by the ball's own fraction alone would leave
   * that margin on screen as well -- 40% of the ball plus 8vp, i.e. hiding noticeably
   * less than the three fifths that were asked for. Adding the margin back pins the
   * hidden position to the SCREEN edge, which is what "leave 40% visible" means.
   */
  ballHideDx(): number {
    if (!this.ballHidden) {
      return 0;
    }
    const off: number = this.ballSizeVp * BALL_HIDE_FRACTION + BALL_MARGIN_VP;
    if (this.ballEdge === 'left') {
      return -off;
    }
    return this.ballEdge === 'right' ? off : 0;
  }

  ballHideDy(): number {
    if (!this.ballHidden) {
      return 0;
    }
    const off: number = this.ballSizeVp * BALL_HIDE_FRACTION + BALL_MARGIN_VP;
    if (this.ballEdge === 'top') {
      return -off;
    }
    return this.ballEdge === 'bottom' ? off : 0;
  }

  cancelBallHide(): void {
    if (this.ballHideTimer >= 0) {
      clearTimeout(this.ballHideTimer);
      this.ballHideTimer = -1;
    }
  }

  /* Start the countdown to half-hide. Called whenever the ball settles or is let go. */
  scheduleBallHide(): void {
    this.cancelBallHide();
    if (this.ballMenu || !this.ballPlaced) {
      return;
    }
    this.ballHideTimer = setTimeout(() => {
      this.ballHideTimer = -1;
      if (this.ballMenu) {
        return;
      }
      this.getUIContext().animateTo({ duration: 260, curve: Curve.Friction }, () => {
        this.ballHidden = true;
      });
    }, BALL_HIDE_MS);
  }

  /*
   * The ability context, by the route that is not deprecated.
   *
   * getContext() still works and is what the older code here uses, but it is
   * deprecated and this file is already carrying a warning for every call. New code
   * should not add more. getHostContext() can return undefined, so it is checked
   * rather than assumed -- and "no context" means the file cannot be reached, which
   * is what both callers already do nothing about.
   *
   * Only these two call sites use it. The other four calls are left alone on purpose:
   * they fetch the context to reach permissions and the keyboard, where a change that
   * behaved even slightly differently would cost far more than a warning line.
   */
  ballCtx(): common.UIAbilityContext | undefined {
    return this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
  }

  /* Where the ball was parked, so the next launch can put it back. */
  saveBallPos(): void {
    try {
      const ctx: common.UIAbilityContext | undefined = this.ballCtx();
      if (ctx === undefined) {
        return;
      }
      const f: fs.File = fs.openSync(ctx.filesDir + '/' + BALL_POS_FILE_NAME,
        fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE);
      fs.writeSync(f.fd, Math.round(this.ballX) + ',' + Math.round(this.ballY));
      fs.closeSync(f);
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'ball: saving the position failed: %{public}s', err.message);
    }
  }

  /*
   * Read the stored position into ballRestoreX/Y. It is NOT applied here: applying it
   * needs a window size to clamp against, and onAreaChange has not reported one yet.
   *
   * Junk is rejected rather than clamped. A corrupt line would otherwise park the ball
   * in a corner with no explanation, and the default position is a perfectly good
   * answer for a file that cannot be read.
   */
  readBallPos(): void {
    try {
      const ctx: common.UIAbilityContext | undefined = this.ballCtx();
      if (ctx === undefined) {
        return;
      }
      const text: string = fs.readTextSync(ctx.filesDir + '/' + BALL_POS_FILE_NAME);
      const parts: string[] = text.trim().split(',');
      if (parts.length !== 2) {
        return;
      }
      const x: number = Number(parts[0]);
      const y: number = Number(parts[1]);
      if (!Number.isFinite(x) || !Number.isFinite(y) || x < 0 || y < 0) {
        return;
      }
      this.ballRestoreX = x;
      this.ballRestoreY = y;
    } catch (e) {
      /* No file on a first run, which is the normal case, not an error. */
    }
  }

  /* Where the menu goes: beside the ball, opening inward. */
  ballMenuX(): number {
    const right: number = this.ballX + this.ballSizeVp + 8;
    if (right + BALL_MENU_W_VP > this.winW) {
      return Math.max(0, this.ballX - BALL_MENU_W_VP - 8);
    }
    return right;
  }

  /* Vertically aligned with the ball, but never past the window edge. */
  ballMenuY(): number {
    const below: number = this.ballY + this.ballSizeVp - 40;
    return Math.min(Math.max(below, 0), Math.max(0, this.winH - 64));
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

  /*
   * The system Back gesture goes up one level inside the game. It never leaves the app.
   *
   * Mindustry's "back" is ESC -- it closes the current dialog or menu and returns to the
   * previous screen -- so the gesture is forwarded as ESC through the same file channel
   * the on-screen keyboard already uses. That channel is read every frame with no guard,
   * so it works whether or not a text field is up.
   *
   * Returning true means "this page handled it": the default return logic does not run
   * and the app stays on screen. So a Back that used to close the app now closes a menu.
   *
   * LEAVING THE APP IS THE GAME'S OWN EXIT, NOT OURS
   *   Quitting is done from the game's main menu. That path already ends cleanly: the
   *   native side drops the exit marker and this page's poll closes the ability, which
   *   is the arrangement verified earlier to be a clean exit rather than a crash.
   *
   *   A double-press-to-exit was built first and taken back out. Telling "the player is
   *   at the main menu" from "the player is three dialogs deep" needs the game's UI
   *   state, and there is no channel for it -- so the rule would have been a timing
   *   window standing in for information we do not have, exiting early from anywhere
   *   deep in the UI. A time-based guess about intent is the wrong kind of thing to
   *   ship. The game has a real exit; use that.
   *
   * ⚠️ The cost, accepted: at the main menu Back does nothing, because ESC has nowhere
   *   to go there. Escape hatches are unaffected -- the system Home gesture and the
   *   recents menu are untouched, and neither is suppressed anywhere in this project.
   */
  onBackPress(): boolean {
    /* 'E' is the whole ESC command; the native side consumes whole lines, so the
     * newline is part of it, not decoration. */
    this.appendCmd('E\n');
    hilog.info(DOMAIN, TAG, 'back: forwarded as ESC (one level up)');
    return true;
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
            /* The user asked for the keyboard -- by tapping this field, which is
             * still on screen over the game's field precisely so that it can be
             * tapped again. Whatever they did before is spent. */
            this.imeUserHid = false;
          })
          .onBlur(() => {
            /*
             * The keyboard was put away. Pressing the system keyboard's own hide
             * button and tapping away from the field both land here, and both
             * mean the same thing: it is not to come back on its own.
             *
             * WHY THE GAME'S REQUEST CANNOT DECIDE THIS
             *   `ime_want` says what the GAME wants, and the game never learns
             *   that the user hid the keyboard: its own field is still focused, so
             *   SDL never calls HideScreenKeyboard and the request file stays on
             *   disk. Measured symptom, before this flag existed: dismissing the
             *   keyboard brought it straight back -- the poll saw "field up, no
             *   focus, game still asking" and took the focus again.
             *
             * Our own dismissals never reach here: dismissIme() clears
             * imeFieldFocused before the field is unmounted, so this test is
             * false. That is what keeps the two paths apart.
             *
             * A stolen focus is indistinguishable from a hide and is now treated
             * as one. That is recoverable rather than fatal, which is the reason
             * it is acceptable: this field is still sitting over the game's field,
             * so one tap raises the keyboard again, where the burst-of-five that
             * this replaced could leave it permanently dead.
             *
             * Clearing is deliberately NOT time-based. The user is not asked to
             * act within any window -- they can leave the keyboard down for as
             * long as they like and a tap still brings it back.
             */
            if (this.imeFieldFocused) {
              this.imeUserHid = true;
            }
            this.imeFieldFocused = false;
          })
          .onSubmit(() => {
            /* Done on the keyboard: put the game back in charge of input. */
            this.dismissIme();
          })
      }

      /*
       * The floating ball, and the menu it opens.
       *
       * It is a ball rather than a labelled button for a practical reason: it has to
       * sit on top of a game, and a small circle is the least it can possibly cover.
       * A fixed button in a corner would either be in the way or too small to hit.
       *
       * It opens a menu rather than acting on tap because it is meant to carry
       * several functions; the control scheme is the first, so the tap has to mean
       * "show me what you can do" rather than "do the one thing".
       *
       * WHY focusable(false) -- this is load-bearing, not cosmetic. ArkUI delivers
       * key events to the focused component only, and the XComponent needs that focus
       * or SDL never sees a keystroke and the keyboard stops working entirely. A
       * focusable ball in this Stack would take it. Click and touch still work
       * without focus; only keyboard focus is withheld.
       *
       * Drawn as a bordered circle rather than with the Circle shape component so the
       * label can live inside it without a second layout pass.
       */
      Stack() {
        /*
         * The game's own turret, not a glyph.
         *
         * A gear was tried and rendered -- but it is a font character, so its weight
         * and its teeth depend on whichever font the device happens to supply, and it
         * reads as "settings" for what is really a menu of several functions.
         *
         * This is the same 32x32 turret the app icon is built from, so the ball
         * matches the icon the player tapped to get here. It is a bitmap, so it also
         * stops depending on the device's fonts at all.
         *
         * Interpolation.None is what keeps it from going soft: the source is an exact
         * integer multiple of the sprite's own 34px, and nearest-neighbour scaling is
         * what keeps pixel art looking drawn rather than blurred.
         *
         * draggable(false): the ball's drag is handled by the Stack's onTouch. A
         * draggable image inside it would start its own drag and fight that.
         */
        Image($r('app.media.ball_icon'))
          .width(Math.round(this.ballSizeVp * 0.62))
          .height(Math.round(this.ballSizeVp * 0.62))
          .interpolation(ImageInterpolation.None)
          .draggable(false)
      }
      .width(this.ballSizeVp)
      .height(this.ballSizeVp)
      .borderRadius(this.ballSizeVp / 2)
      .backgroundColor(this.ballMenu ? '#cc1d2733' : '#99101820')
      .borderWidth(1)
      .borderColor('#66ffffff')
      /*
       * The half-hide lives HERE and nowhere else. ballX/ballY keep holding the
       * revealed position, so dragging, clamping, snapping and the saved file all
       * agree on one set of coordinates -- moving ballX instead would make every one
       * of them have to reason about how hidden the ball currently is.
       */
      .position({ x: this.ballX + this.ballHideDx(), y: this.ballY + this.ballHideDy() })
      .opacity(this.ballHidden ? BALL_OPACITY_HIDDEN : 1)
      .focusable(false)
      .onTouch((e: TouchEvent) => { this.onBallTouch(e); })

      if (this.ballMenu) {
        Column() {
          /*
           * Entry: which control scheme is in force, and the switch.
           *
           * A real choice has to be made before the game starts: Mindustry derives
           * its entire input layer AND its UI from one bit, Vars.mobile, written once
           * in Vars.init(). Its own in-game switch changes only the input handler, so
           * it gives desktop controls on a mobile UI -- measured on the tablet, and
           * confirmed in the bytecode. Hence the restart, which is stated plainly
           * rather than hidden.
           */
          Row() {
            Text(this.controlMode === CONTROL_MODE_DESKTOP ? 'PC 模式' : '触屏模式')
              .fontSize(14)
              .fontColor('#eef2f9')
            Blank()
            Text('切换').fontSize(13).fontColor('#8fb4ff')
          }
          .width('100%')
          .onClick(() => { this.toggleControlMode(); })
        }
        .width(BALL_MENU_W_VP)
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
        .backgroundColor('#e6161c26')
        .borderRadius(10)
        .borderWidth(1)
        .borderColor('#44ffffff')
        .position({ x: this.ballMenuX(), y: this.ballMenuY() })
        .focusable(false)
      }
    }
    /* The only job of this modifier is to learn the window size, once, so the ball
     * can be placed and clamped against the right rectangle. */
    .onAreaChange((_o: Area, n: Area) => {
      this.onWindowSize(Number(n.width), Number(n.height));
    })
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
