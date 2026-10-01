/* [A]
 * 启动器主界面 —— 没有游戏可加载时，或玩家主动要求时显示的那一屏。
 *
 * ⚠️⚠️ 它【替换】XComponent，不是盖在它上面，而这决定了这里能用什么控件。
 *   本项目有一条硬规则：凡是承载在【游戏 Surface 之上】的浮层，一律 focusable(false)
 *   且不含任何可获焦子组件 —— 因为 ArkUI 把按键只投递给聚焦的组件，一个可获焦的
 *   Button 会把键盘从 SDL 那里抢走，游戏于是完全收不到输入（踩过，且是无声的）。
 *
 *   ⇒ 这一屏不适用，因为它存在的时候【没有 Surface】。所以这里的 Button 和可获焦
 *     组件都是安全的。**但这条豁免是有条件的**：如果哪一天有人把它改成盖在游戏上，
 *     那条规则立刻生效，而症状会是「进了启动器之后键盘就废了」。
 *
 * 布局形态是 Navigation + 底部页签，这是被 API 约束推出来的，不是审美选择：
 *   沉浸光感（systemMaterial / uiMaterial）【不是】一个能贴在任何卡片上的背景模糊。
 *   官方文档原文：「其他组件仅在 Navigation/NavDestination 标题栏或横向 Tabs 中
 *   barPosition 为 BarPosition.End 的底部 TabBar 中生效。在其他区域中设置沉浸光感
 *   效果不生效。」
 *
 *   ⭐ 这条约束【顺带否掉了】「平板改成侧边竖向页签」这个方案：那段原文要的是
 *     **横向 Tabs + BarPosition.End**，换成竖向/侧边就没有沉浸光感了。
 *     平板的适配因此落在【内容】上，而不是换页签形态。
 *
 * 颜色分两套，别混：
 *   · 文字  -> $r('sys.color.*')，由系统按深浅色模式切换，而且**沉浸光感的 colorInvert
 *              只对这类特殊资源值生效**（官方原文：硬编码色如 Color.White、'#FFFFFFFF'
 *              不会触发自动反色）。
 *   · 表面色 -> $r('app.color.launcher_*')，在 resources/base 与 resources/dark 两处定义。
 *
 * ⭐⭐ 两条踩过的坑，改这个文件前先读：
 *   1. `.barOverlap(false)` 会让底部栏**不再悬浮** —— 悬浮观感就是靠它。
 *      官方示例 reference 项目 AMCL 也是 `barOverlap(true)`，并且他们的注释明说
 *      「旧 API 仍覆盖在全屏内容上，不退回挤占 TabContent 高度的布局」。
 *      ⇒ 所以防「栏压住按钮」要靠**给内容留底部空间**，不是关掉重叠。
 *   2. `@Builder` 的参数是**按值传递**。把一行列表项做成带 `chosen` 参数的 @Builder
 *      之后，`this.selected` 变化**不会让那个 @Builder 重新执行** —— 结果是点击
 *      其实成功了（文件也写了、native 也读到了），但 ✓ 不动，看起来像「点了没反应」。
 *      ⇒ 列表项**内联**写，不要抽 @Builder。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { uiMaterial } from '@kit.ArkUI';
import { GameJar, GameResolution, listGameJars, readSelection, writeSelection,
         resolveGame, gameJarDir, ensureGameJarDir } from '../games/GameLibrary';
/* [A] 界面偏好（内容宽度）。单独一个文件，因为它不是「游戏知识」——
 * 理由见那个文件的开头。 */
import { readWidthPct, writeWidthPct, WIDTH_PCT_MIN, WIDTH_PCT_MAX,
         WIDTH_PCT_DEFAULT } from '../settings/LauncherPrefs';

const DOMAIN = 0x0000;
const TAG = 'MindustryLauncher';

/** [A]
 * 内容占窗口宽度的**百分比下限**（按 vp 算）。
 *
 * 用户给的规格（2026-10-01）：**「内容本身占 30%，在最左边，像 AMCL 那样。
 * Mindustry 的电脑 UI 也是菜单在左边，而不是居中。」** 看过之后改成 **默认 40%**，
 * 并要一个滑条让玩家自己调。
 *
 * ⭐ 按**比例**算，不用固定值（900 那一版是拍的）。百分数存在
 * `settings/LauncherPrefs.ets`，滑条改的就是它。
 *
 * 下限的存在：手机上窗口只有 360–420 vp，40% 会得到一百多 vp 的窄条，没法用。
 * `max(360, 百分比)` 这个组合让**手机退回全宽、平板收成左栏** —— 同一个式子管两种设备，
 * 不需要断点。
 */
const CONTENT_MIN_VP = 360;

/** [A]
 * 底部悬浮栏的**目标宽度**上限。
 *
 * 为什么不是 `barWidth`
 *   `barWidth` 是三档 `FloatingTabBarWidth`，而**档位由 SDK 自己的断点决定** ——
 *   我既不能决定它选哪一档，也不能决定栏摆在哪儿。实测：给了三档宽度，用户仍报
 *   「悬浮了，但不居中」。
 *
 * 为什么是 `barSideMargin`
 *   它是**左右同一个值**。左右留白相等 ⇒ 栏必然居中，**由构造保证**，不需要知道
 *   SDK 内部怎么摆。代价是它不能用百分比，所以宽度得自己从窗口算 —— 见 sideMargin()。
 */
const BAR_MAX_VP = 480;

/** [B] 左右留白的下限，窄屏上不至于把栏挤没。 */
const BAR_MIN_SIDE_VP = 16;

/** [A]
 * 栏离底边多高。**这是「悬浮」的一半**：没有它，栏贴着屏幕下沿，看起来就是一条
 * 普通底栏；抬起来才像一片浮在内容上的玻璃。
 *
 * 参考 AMCL 的做法：他们用 `Math.max(bottomSafeHeight, 16) + 8`，并把这个数交给
 * `barBottomMargin`。这里不读安全区，取一个够用的常量 —— 平板上手势条那一条通常
 * 不到 16 vp。
 */
const BAR_BOTTOM_MARGIN_VP = 24;

/** [A]
 * 为悬浮栏让出的底部空间。
 *
 * ⚠️ 这是**估算**，不是量出来的：栏内容 52（见 TabItem 的 height）+ 离底 24 + 余量 20。
 * 它与本项目「测量不能当门」那条教训无关 —— 那说的是**闸门**；这里只是一段布局留白，
 * 多给一点没有任何副作用（只是底部空一点），少给才会压住按钮。
 * ⇒ 所以取偏大值。真要精确，得在设备上量一次栏的实际占位。
 */
const BAR_CLEARANCE_VP = 96;

/** [B] 圆角。卡片和列表项共用一个值，免得两处漂移。 */
const CARD_RADIUS_VP = 14;

/** [B] 按钮字号。**显式给**，因为不给的话按钮会按各自标签长度自适应，两个按钮的字
 * 会不一样大 —— 用户在设置页看到的正是这个。 */
const BUTTON_FONT_VP = 16;

/** [A]
 * 底部页签的材质。拿不到就返回 undefined，界面退回普通样式。
 *
 * ⚠️ 整件事包在 try 里，而且【判断本身】也在 try 里 —— `uiMaterial` 的起始版本是
 * 26.0.0，而本应用的 compatibleSdkVersion 是 6.1.1(24)。在 API 24 的设备上这个
 * 命名空间可能根本不存在，那时**抛异常的正是 isImmersiveMaterialSupported() 这一句**，
 * 而不是它的返回值。把判断放在 try 外面，等于把最该防的那一句漏在外面。
 */
function immersiveBarMaterial(): uiMaterial.Material | undefined {
  try {
    if (uiMaterial.isImmersiveMaterialSupported()) {
      return new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
      });
    }
    hilog.info(DOMAIN, TAG, 'launcher: the device reports no immersive material support');
  } catch (e) {
    const err = e as BusinessError;
    hilog.info(DOMAIN, TAG, 'launcher: immersive material unavailable (%{public}s)', err.message);
  }
  return undefined;
}

/** [B] 人类可读的大小。装上就是给人看的，所以用 MB/KB 而不是字节。 */
function formatSize(bytes: number): string {
  if (bytes >= 1048576) {
    return (bytes / 1048576).toFixed(1) + ' MB';
  }
  if (bytes >= 1024) {
    return (bytes / 1024).toFixed(0) + ' KB';
  }
  return String(bytes) + ' B';
}

/** [B] 只要日期。玩家分辨两个游戏版本靠的是文件名，日期只是辅助。 */
function formatDate(sec: number): string {
  const d: Date = new Date(sec * 1000);
  const p = (n: number): string => n < 10 ? '0' + String(n) : String(n);
  return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate());
}

@Component
export struct LauncherHome {
  /* [B] 两个都由 Index.ets 传进来 —— 它们是从 context 取的，而 context 只有页面拿得到。
   *
   * ⚠️ 它们【不能】带 private：ArkTS 会拒绝从组件构造器初始化私有属性（实测是一条
   * 警告：「Property 'filesDir' is private and can not be initialized through the
   * component constructor」），而**那条警告的后果是值根本传不进来** —— 组件照常渲染，
   * 只是两个路径都是空串。也就是说它会「构建成功、运行不正常」，比一个编译错误难查
   * 得多。 */
  filesDir: string = '';
  bundleCodeDir: string = '';

  /** [B] 玩家点了「启动游戏」。参数是最终决定要加载的那个 jar。 */
  onLaunch: (jarPath: string) => void = (jarPath: string) => {};
  /** [B] 玩家点了「仍然尝试启动」—— 逃生门，见下面空状态里的说明。 */
  onForceLaunch: () => void = () => {};

  @State games: GameJar[] = [];
  @State selected: string = '';
  @State resolution: GameResolution = { path: '', source: 'none' };
  @State currentTab: number = 0;
  /** [B] 模组那个 Downloads 文件夹的路径提示；拿不到时为 ''。 */
  @State jarDirHint: string = '';

  /* [A]
   * 窗口宽度，从 onAreaChange 学来。
   *
   * ⚠️ 它存在只有一个理由：`barSideMargin` **不接受百分比**，所以给栏居中就必须知道
   * 屏幕多宽。0 表示还没量到，那时用下限兜着。
   */
  @State winW: number = 0;

  /** [A]
   * 内容占窗口宽度百分之几 —— **已经生效的**那个值。布局读的是它。
   *
   * ⚠️ 它与下面的 sliderPct **必须分开**，这是用户要的：
   * 「切换内容宽度现在是实时切换，看着比较奇怪，应该弄成我拖动完松开才切换宽度」。
   * 拖动过程中只动 sliderPct（数字标签跟着走，有反馈），松手才提升进 contentPct，
   * **布局到那一刻才变**。
   */
  @State contentPct: number = WIDTH_PCT_DEFAULT;

  /** [B] 滑条手柄当前的位置。拖动时只有它变。 */
  @State sliderPct: number = WIDTH_PCT_DEFAULT;

  /* [A]
   * 底部页签的悬浮样式（也就是沉浸光感生效的地方）是 @since 26.0.0。
   * 在更低的 API 上那个属性方法根本不存在，调用它会抛 —— 而那发生在 build() 里，
   * catch 不到。所以这里按运行期 API 级别分成两条分支，而不是靠 try。
   */
  private canFloat: boolean = deviceInfo.sdkApiVersion >= 26;
  private barMaterial: uiMaterial.Material | undefined = immersiveBarMaterial();

  aboutToAppear(): void {
    this.contentPct = readWidthPct(this.filesDir);
    this.sliderPct = this.contentPct;
    this.refresh();
  }

  @Builder
  TabItem(symbol: Resource, label: string, index: number) {
    Column() {
      /* [A]
       * **系统符号，不是 emoji。**
       *
       * 之前用的是 🎮 / ⚙️ —— 那是**字符**，不是图标：它们由字体决定长相，
       * 在有的设备上是彩色 emoji、有的是单色轮廓，而且**跟着系统字体漂移**。
       * 用户的原话是「现在的是不是字符当成图标？有没有扁平化的UI」—— 是的，就是字符。
       *
       * `SymbolGlyph` + `$r('sys.symbol.*')` 是鸿蒙自己的矢量图标，扁平、随主题变色、
       * **跟字体无关**。而且参考项目 AMCL 用的就是这一套
       * （他们的 TabBar 是 `$r('sys.symbol.gearshape_fill')`），所以这正是「通用样式」。
       *
       * ⚠️ 名字不是记来的，是在 SDK 的资源索引里核过的：`house_fill` 与
       * `gearshape_fill` 都在。而且**编译器会校验** —— 写错名字会报
       * `Unknown resource name`，这一条对 `sys.color.*` 已经实测过一次。
       */
      SymbolGlyph(symbol)
        .fontSize(24)
        /* [A] 用品牌色/次要色，让选中态和文字同步 —— 两处各写一套颜色必然会漂。 */
        .fontColor([this.currentTab === index
                      ? $r('sys.color.brand')
                      : $r('sys.color.font_secondary')])
      Text(label)
        .fontSize(11)
        .fontColor(this.currentTab === index ? $r('sys.color.brand') : $r('sys.color.font_secondary'))
        .margin({ top: 2 })
    }
    .justifyContent(FlexAlign.Center)
    .height(52)
    .width('100%')
  }

  /** [B] 重新读一遍磁盘。文件夹在这里【再确认一次】存在，因为玩家可能刚把它删掉。 */
  private refresh(): void {
    ensureGameJarDir(this.filesDir);
    this.games = listGameJars(this.filesDir);
    this.selected = readSelection(this.filesDir);
    this.resolution = resolveGame(this.filesDir, this.bundleCodeDir);
    this.jarDirHint = gameJarDir(this.filesDir);
    hilog.info(DOMAIN, TAG, 'launcher: %{public}d jar(s), resolved=%{public}s (%{public}s)',
               this.games.length, this.resolution.path === '' ? '(none)' : this.resolution.path,
               this.resolution.source);
  }

  /** [A] 玩家点了某个 jar。只是【记下来】，不在这里启动 —— 启动要重建整棵树。 */
  private pick(jarPath: string): void {
    this.selected = jarPath;
    writeSelection(this.filesDir, jarPath);
    this.resolution = resolveGame(this.filesDir, this.bundleCodeDir);
    hilog.info(DOMAIN, TAG, 'launcher: picked %{public}s', jarPath === '' ? '(bundled)' : jarPath);
  }

  /** [A] 退回内置的那一份。写一个【空的】选择，那是明确的「用包里的」，不是清除。 */
  private pickBundled(): void {
    this.selected = '';
    writeSelection(this.filesDir, '');
    this.resolution = resolveGame(this.filesDir, this.bundleCodeDir);
    hilog.info(DOMAIN, TAG, 'launcher: picked (bundled)');
  }

  /** [A]
   * 内容一栏的宽度（vp）。**靠左**摆，见 CONTENT_MIN_VP。
   *
   * ⚠️⚠️ 它返回的是一个**数值 width**，而不是配 `width('100%')` 用的 `constraintSize` ——
   * 这个选择是为动画服务的，别改回去。
   *
   * 用户报「松手后切换的速度太快了」，我第一版用 `animateTo` 包住 `constraintSize` 的变化，
   * 他说「**还是**太快了」—— 那个「还是」说明动画根本没跑。
   *
   * 原因：`animateTo` 动的是**渲染属性**（width / height / opacity / translate / …），
   * 而 `constraintSize` 是**布局约束**。约束变了，布局直接重排，没有中间帧。
   *
   * ⇒ 改成真正的数值 `width`。宽度是渲染属性，`animateTo` 能对它插值。
   *
   * ⚠️ 窗口宽度还没量到时给下限；`winW <= 0` 只出现在第一帧。
   */
  private contentWidthVp(): number {
    if (this.winW <= 0) {
      return CONTENT_MIN_VP;
    }
    const want: number = this.winW * (this.contentPct / 100);
    return want > CONTENT_MIN_VP ? want : CONTENT_MIN_VP;
  }

  /** [A]
   * 栏左右各留多少。**同一个值给两边 ⇒ 栏必然居中**（见 BAR_MAX_VP 的注释）。
   *
   * 窗口宽度还没量到时返回下限 —— 那时栏会宽一点，下一帧就正了。宁可先宽后正，
   * 也不要先给一个可能算出负数的值。
   */
  private sideMargin(): number {
    if (this.winW <= 0) {
      return BAR_MIN_SIDE_VP;
    }
    const want: number = Math.min(BAR_MAX_VP, this.winW - 2 * BAR_MIN_SIDE_VP);
    const side: number = (this.winW - want) / 2;
    return side > BAR_MIN_SIDE_VP ? side : BAR_MIN_SIDE_VP;
  }

  @Builder
  GamesTab() {
    Column() {
      Column() {
        if (this.games.length === 0) {
          /* [A]
           * 空状态，而它同时是【逃生门】。
           *
           * 「判定没有游戏」有三个完全不同的来源：真的没有、内置那份的路径我算错了、
           * 以及那个 Downloads 文件夹在这台设备上还没被创建出来。三者在界面上长得
           * 一模一样，而其中两个是【我的】问题。
           *
           * ⇒ 所以这里必须能出去：一个「仍然尝试启动」的入口。没有它，一次路径判断
           *   失误就把应用变成永远打不开游戏的启动器，而玩家没有任何办法绕过去。
           *   本项目为「门关上了却没有开的路径」付过代价（jvm_incomplete），不再犯。
           */
          Column() {
            Text('没有找到游戏')
              .fontSize(18).fontColor($r('sys.color.font_primary'))
            Text('把 Mindustry 的 .jar 放进下面这个文件夹，然后点「重新扫描」：')
              .fontSize(13).fontColor($r('sys.color.font_secondary'))
              .margin({ top: 12 })
              .textAlign(TextAlign.Center)
            Text(this.jarDirHint === '' ? '（这个设备上还拿不到 Download 文件夹）' : this.jarDirHint)
              .fontSize(12).fontColor($r('sys.color.font_tertiary'))
              .margin({ top: 8 })
              .textAlign(TextAlign.Center)
              .copyOption(CopyOptions.LocalDevice)
            Text('内置游戏：' + (this.resolution.source === 'bundled' ? '有' : '无'))
              .fontSize(12).fontColor($r('sys.color.font_secondary'))
              .margin({ top: 12 })
          }
          .width('100%')
          .padding({ left: 24, right: 24, top: 40, bottom: 24 })
          .alignItems(HorizontalAlign.Center)
        } else {
          /* [A]
           * ⚠️ 列表项是【内联】写的，不是 @Builder。这里踩过一次，见文件头第 2 条：
           *    @Builder 的参数按值传递 ⇒ `this.selected` 变化不会让它重新执行
           *    ⇒ 点击其实成功了（日志里 source=user 是对的），但 ✓ 不动，
           *      看起来就是「点了没反应」。
           */
          List({ space: 8 }) {
            ListItem() {
              Row() {
                Column() {
                  Text('内置游戏')
                    .fontSize(16).fontColor($r('sys.color.font_primary'))
                  Text(this.resolution.source === 'bundled' ? '正在使用' : '包里的那一份')
                    .fontSize(12).fontColor($r('sys.color.font_secondary')).margin({ top: 2 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                if (this.selected === '') {
                  Text('✓').fontSize(18).fontColor($r('sys.color.brand'))
                }
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 14, bottom: 14 })
            }
            .backgroundColor($r('app.color.launcher_card'))
            .borderRadius(CARD_RADIUS_VP)
            .onClick(() => { this.pickBundled(); })

            ForEach(this.games, (g: GameJar) => {
              ListItem() {
                Row() {
                  Column() {
                    Text(g.name)
                      .fontSize(16).fontColor($r('sys.color.font_primary'))
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(formatSize(g.size) + '  ·  ' + formatDate(g.mtime))
                      .fontSize(12).fontColor($r('sys.color.font_secondary')).margin({ top: 2 })
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                  if (this.selected === g.path) {
                    Text('✓').fontSize(18).fontColor($r('sys.color.brand'))
                  }
                }
                .width('100%')
                .padding({ left: 16, right: 16, top: 14, bottom: 14 })
              }
              .backgroundColor($r('app.color.launcher_card'))
              .borderRadius(CARD_RADIUS_VP)
              .onClick(() => { this.pick(g.path); })
            }, (g: GameJar): string => g.path)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 16 })
        }
      }
      .width(this.contentWidthVp())
      .animation({ duration: 300, curve: Curve.FastOutSlowIn })
      .layoutWeight(1)

      /* [A]
       * 主按钮。它被禁用的唯一理由是「确实没有任何可加载的东西」——
       * 由 resolveGame 判定，而它已经确认过文件真的能打开。
       */
      Column() {
        Button('启动游戏')
          .width('100%')
          .height(44)
          .fontSize(BUTTON_FONT_VP)
          .enabled(this.resolution.path !== '')
          .onClick(() => { this.onLaunch(this.resolution.path); })

        if (this.resolution.path === '') {
          Text('仍然尝试启动')
            .fontSize(13).fontColor($r('sys.color.brand'))
            .margin({ top: 12 })
            .onClick(() => { this.onForceLaunch(); })
        }
      }
      .width(this.contentWidthVp())
      .animation({ duration: 300, curve: Curve.FastOutSlowIn })
      .padding({ left: 16, right: 16, top: 12 })
    }
    .width('100%')
    .height('100%')
    /* [A] ⭐ **Start，不是 Center** —— 内容靠左，这是用户给的规格：
     * 「内容本身占 30%，在最左边，像 AMCL 那样。」见 CONTENT_FRACTION。 */
    .alignItems(HorizontalAlign.Start)
    /* [A] 给悬浮栏让位，见 BAR_CLEARANCE_VP。 */
    .padding({ bottom: BAR_CLEARANCE_VP })
  }

  @Builder
  SettingsTab() {
    Column() {
      Column() {
        Text('游戏 jar 目录')
          .fontSize(14).fontColor($r('sys.color.font_secondary'))
        Text(this.jarDirHint === '' ? '（本设备上拿不到）' : this.jarDirHint)
          .fontSize(12).fontColor($r('sys.color.font_tertiary'))
          .margin({ top: 4 })
          .copyOption(CopyOptions.LocalDevice)
      }
      .width(this.contentWidthVp())
      .animation({ duration: 300, curve: Curve.FastOutSlowIn }).alignItems(HorizontalAlign.Start)
      .padding({ left: 16, right: 16, top: 20 })

      /* [A]
       * 内容宽度的滑条。用户要的：「加一个滑条让用户自由调整」。
       *
       * ⚠️ 只在 `End` / `Click` 时**写盘**，拖动过程中只改内存里的 @State。
       * `onChange` 在拖动时每帧都会触发 —— 每帧写一次文件既没必要，也会让磁盘
       * 每帧就动一下。界面本身在拖动时是实时更新的（@State 变了就重绘）。
       */
      Column() {
        Row() {
          Text('内容宽度')
            .fontSize(14).fontColor($r('sys.color.font_secondary'))
          Blank()
          Text(String(Math.round(this.sliderPct)) + '%')
            .fontSize(14).fontColor($r('sys.color.font_secondary'))
        }
        .width('100%')

        Slider({
          value: this.sliderPct,
          min: WIDTH_PCT_MIN,
          max: WIDTH_PCT_MAX,
          /* [A]
           * ⚠️ step 同时决定两件事，所以不能随便改：
           *   ① 拖动的吸附粒度  ② `showSteps(true)` 那些小圆点画在哪
           *
           * 用户 2026-10-01 定的是：**范围 20–60，每 10% 一个挡位** ⇒
           * 圆点落在 20 / 30 / 40 / 50 / 60，正好五个。
           *
           * 代价：吸附到挡位 ⇒ 中间值取不到（比如 35%）。
           * ⚠️ 这与用户更早说的「自由调整」有张力 —— 但后来他明确改成了固定挡位，
           * 以近的一次为准。若哪天要两者兼得，得**自己画标记而不动 step**（要算轨道内边距）。
           */
          step: 10,
          style: SliderStyle.OutSet,
        })
          .width('100%')
          .margin({ top: 4 })
          .showSteps(true)
          /* [A]
           * ⚠️ 拖动中**只动 sliderPct**（数字标签跟着走，给反馈），
           * 松手（End / Click）才提升进 contentPct 并写盘。
           *
           * 之前是每帧都改 contentPct ⇒ 布局跟着手指实时重排，用户的原话是
           * 「看着比较奇怪」。而且每帧写一次文件也没必要。
           *
           * ⚠️⚠️ 松手那一下包在 **animateTo** 里 —— 用户报「松手后切换的速度太快了，
           * 看着很不舒服」。那说的不是「太快」而是「**瞬间跳变**」：宽度从旧值直接
           * 闪到新值，中间没有任何过渡。
           *
           * ⚠️⚠️ **`this.getUIContext().animateTo(...)`，不是全局的 `animateTo(...)`** ——
           * 这一条踩了两次，别再改回去。
           *
           * SDK 原文（common.d.ts 的全局 animateTo）：
           *
           *     @since 7
           *     @deprecated since 18
           *     @useinstead ohos.arkui.UIContext.UIContext#animateTo
           *
           * ⛔ **全局那个自 API 18 起弃用，在本设备（API 26）上【静默不生效】** ——
           * 不报错、不警告，就是没动画。这正是「用户说『还是太快了』」的原因：
           * 我一直在调时长，而那条路根本就是死的。
           *
           * ⭐ 答案在参考项目 AMCL 里 —— 他们的注释写着：
           *     「2026-05-23 API NEXT 迁移：全局 mediaquery / px2vp / promptAction /
           *       router / animateTo 均已弃用，本页全部改走 this.getUIContext().XXX(...)」
           *   而他们每一处动画都是 `this.getUIContext().animateTo(...)`。
           *
           * ⚠️ 属性选错的教训也在：第一版包的是 `constraintSize`（布局约束）⇒ 同样没动画。
           * 见 contentWidthVp()。
           *
           * ⛔ 而现在**连 `animateTo` 都不用了** —— 改走声明式的 `.animation()`。
           * 理由：它紧跟在 `.width(...)` 后面，作用域就是它前面那些属性，而且**不涉及
           * 「用哪个 animateTo」这个坑**。参考项目 AMCL 给尺寸/位置做动画就是这么写的
           * （见 GameControls.ets 的 `Text(...).width(this.w)....animation({duration:50})`）。
           *
           * ⇒ 所以这里只改状态，动画由布局上的 `.animation()` 负责。
           */
          .onChange((value: number, mode: SliderChangeMode) => {
            this.sliderPct = value;
            if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
              const next: number = Math.round(value);
              this.contentPct = next;
              writeWidthPct(this.filesDir, next);
            }
          })

        Text('窗口较窄时自动占满整行 —— 这个百分比只在宽屏（平板）上才起作用。')
          .fontSize(11).fontColor($r('sys.color.font_tertiary'))
          .margin({ top: 4 })
      }
      .width(this.contentWidthVp())
      .animation({ duration: 300, curve: Curve.FastOutSlowIn }).alignItems(HorizontalAlign.Start)
      .padding({ left: 16, right: 16, top: 24 })

      Column() {
        Text('本次启动将加载')
          .fontSize(14).fontColor($r('sys.color.font_secondary'))
        Text(this.resolution.path === ''
               ? '（没有可加载的游戏）'
               : (this.resolution.source === 'user' ? '（玩家选择的）' : '（包内自带的）'))
          .fontSize(12).fontColor($r('sys.color.font_tertiary'))
          .margin({ top: 4 })
        Text(this.resolution.path === '' ? '—' : this.resolution.path)
          .fontSize(12).fontColor($r('sys.color.font_tertiary'))
          .margin({ top: 4 })
          .copyOption(CopyOptions.LocalDevice)
      }
      .width(this.contentWidthVp())
      .animation({ duration: 300, curve: Curve.FastOutSlowIn }).alignItems(HorizontalAlign.Start)
      .padding({ left: 16, right: 16, top: 24 })

      /* [A]
       * ⚠️ 两个按钮**上下堆叠**，不是并排。
       *
       * 用户实测反馈：「字号一致，但**分配的左边区域太小了，导致字挤在一起**」。
       * 并排时每个只拿到一半宽度，而「仍然尝试启动」有六个字 —— 16 vp 下约 96 vp，
       * 再算上按钮自己的内边距就紧张。
       *
       * ⇒ 堆叠之后**每个都占满整行**，这一类挤压在结构上不可能发生。
       *   代价是纵向多占一行，而设置页本来就空着（下面有个 Blank()）。
       *   本项目在别处（`barOverlap`）刚学到同一条：**能靠结构解决的，不要靠调数值**。
       */
      Column() {
        /* [A] 两个按钮的字号【都要给】。不给的话按钮会按各自标签长度自适应，
         * 长的那个被缩小 —— 那正是用户报的「两个按钮字体大小不一样」。 */
        Button('重新扫描')
          .fontSize(BUTTON_FONT_VP)
          .width('100%')
          .onClick(() => { this.refresh(); })
        Button('仍然尝试启动')
          .fontSize(BUTTON_FONT_VP)
          .width('100%')
          .margin({ top: 12 })
          .onClick(() => { this.onForceLaunch(); })
      }
      .width(this.contentWidthVp())
      .animation({ duration: 300, curve: Curve.FastOutSlowIn })
      .padding({ left: 16, right: 16, top: 28 })

      Blank()
    }
    .width('100%')
    .height('100%')
    /* [A] 同上：内容靠左。 */
    .alignItems(HorizontalAlign.Start)
    .padding({ bottom: BAR_CLEARANCE_VP })
  }

  build() {
    Navigation() {
      /* [A]
       * 两条分支只差悬浮样式那一块，理由见 canFloat 的注释。
       * ⚠️ 页签内容走 @Builder，所以这里没有重复第二份内容。
       */
      if (this.canFloat) {
        Tabs({ barPosition: BarPosition.End }) {
          TabContent() { this.GamesTab() }.tabBar(this.TabItem($r('sys.symbol.house_fill'), '首页', 0))
          TabContent() { this.SettingsTab() }.tabBar(this.TabItem($r('sys.symbol.gearshape_fill'), '设置', 1))
        }
        .barFloatingStyle({
          /* [A] 左右同一个留白 ⇒ 居中由构造保证。见 BAR_MAX_VP 的注释。 */
          barSideMargin: this.sideMargin(),
          /* [A] 把栏从屏幕下沿抬起来 —— 悬浮观感的另一半。 */
          barBottomMargin: BAR_BOTTOM_MARGIN_VP,
          systemMaterial: this.barMaterial,
          maskColor: Color.Transparent,
        })
        /* [A]
         * ⚠️⚠️ 这一行 = 「悬浮」本身，**不要改成 false**。
         *
         * 我改过一次，理由是「栏压住『启动游戏』」，结果用户报回来的第一句就是
         * 「底栏现在不悬浮，和左边融为一体了」—— 因为悬浮样式就是靠它生效的。
         *
         * 官方示例（SDK 文档）与参考项目 AMCL 都是 true，而且 AMCL 的注释明说
         * 「旧 API 仍覆盖在全屏内容上，不退回挤占 TabContent 高度的布局」。
         *
         * ⇒ 「栏压住按钮」的正解是**给内容留出底部空间**（BAR_CLEARANCE_VP），
         *   不是关掉重叠。关掉重叠 = 同时失去悬浮观感，代价比问题本身大。
         */
        .barOverlap(true)
        /* [A]
         * ⚠️ 这一行是「首页 / 设置 两页之间切换跳变」的修复，参考项目 AMCL 同款。
         *
         * SDK 文档说自定义 tabBar 不设时默认就是 300 —— 但实测是跳的。显式写上，
         * 与 AMCL 完全对齐（他们 `.animationDuration(300)` 就写在 `.barOverlap(true)`
         * 的下一行）。
         *
         * ⛔ 而**更关键的是上面那处改动**：Tabs 的 `index` 绑定已经去掉。
         * 原来写的是 `Tabs({ index: this.currentTab })`，而 `onAnimationStart` 里会回写
         * `this.currentTab` ⇒ **把值灌回 `index`** ⇒ 等于在动画中途重新请求一次切换，
         * 那一下就是「跳」。AMCL 用控制器，`currentTab` 只喂底栏高亮，两边互不干涉。
         *
         * ⚠️ 注意 `animationCurve` 不设时，滑动切换的时长由默认曲线
         * `interpolatingSpring(-1, 1, 228, 30)` 自己决定 —— 也就是说这一行对
         * 「点击页签」和「滑动」的作用方式不完全一样，别以为它是一个万能旋钮。
         */
        .animationDuration(300)
        .barBackgroundColor(Color.Transparent)
        /* [A]
         * ⚠️ 这里要的是 onAnimationStart，**不是 onChange** ——
         * 这一行就是「滑动换页时底栏高亮有延迟」的修复。
         *
         * onChange【在切换完成之后】才触发，所以手指滑动的那一整段时间里，高亮还停在
         * 旧页签上，看起来就是「慢半拍」（用户原话）。
         * onAnimationStart【在动画一开始】就给出 targetIndex，高亮跟着手势走。
         *
         * ⭐ 这不是我猜的：参考项目 AMCL 用的就是它 ——
         *     .onAnimationStart((_index, targetIndex) => { this.currentTab = targetIndex })
         *   而用户报的正是「AMCL 就没有」这个延迟。
         *
         * onChange 保留作兜底：如果动画被跳过（系统关了动效等），它仍会把值纠正回来。
         * 两者都写同一个字段、都是幂等的，不冲突。
         */
        .onAnimationStart((_index: number, targetIndex: number) => {
          this.currentTab = targetIndex;
        })
        .onChange((index: number) => { this.currentTab = index; })
        .width('100%')
        .height('100%')
      } else {
        /* [A]
         * 低于 API 26 的退路。没有悬浮材质，但**仍然重叠**（同上），
         * 用 `barBackgroundBlurStyle` 换个毛玻璃 —— 它从 API 7 就有。
         * 同一个做法见 AMCL 的 LauncherTabsStyle.ets。
         */
        Tabs({ barPosition: BarPosition.End }) {
          TabContent() { this.GamesTab() }.tabBar(this.TabItem($r('sys.symbol.house_fill'), '首页', 0))
          TabContent() { this.SettingsTab() }.tabBar(this.TabItem($r('sys.symbol.gearshape_fill'), '设置', 1))
        }
        .barOverlap(true)
        /* [A] 同上：显式给切换时长，与 AMCL 的写法对齐。 */
        .animationDuration(300)
        .barBackgroundBlurStyle(BlurStyle.COMPONENT_THICK)
        /* [A]
         * ⚠️ 这里要的是 onAnimationStart，**不是 onChange** ——
         * 这一行就是「滑动换页时底栏高亮有延迟」的修复。
         *
         * onChange【在切换完成之后】才触发，所以手指滑动的那一整段时间里，高亮还停在
         * 旧页签上，看起来就是「慢半拍」（用户原话）。
         * onAnimationStart【在动画一开始】就给出 targetIndex，高亮跟着手势走。
         *
         * ⭐ 这不是我猜的：参考项目 AMCL 用的就是它 ——
         *     .onAnimationStart((_index, targetIndex) => { this.currentTab = targetIndex })
         *   而用户报的正是「AMCL 就没有」这个延迟。
         *
         * onChange 保留作兜底：如果动画被跳过（系统关了动效等），它仍会把值纠正回来。
         * 两者都写同一个字段、都是幂等的，不冲突。
         */
        .onAnimationStart((_index: number, targetIndex: number) => {
          this.currentTab = targetIndex;
        })
        .onChange((index: number) => { this.currentTab = index; })
        .width('100%')
        .height('100%')
      }
    }
    .title('Mindustry Ark')
    .titleMode(NavigationTitleMode.Mini)
    /* [A]
     * ⚠️⚠️ 必须显式写 Stack，**不能靠默认的 Auto** —— 这一行同时是两个缺陷的根因。
     *
     * SDK 原文（`NavigationMode.Auto`）：
     *
     *     In API version 10 and later versions: If the window width is greater than or equal
     *     to 600 vp, the **Split** mode is used; otherwise, the Stack mode is used.
     *     600 vp = minNavBarWidth (240 vp) + minContentWidth (360 vp).
     *
     * 平板远超 600 vp ⇒ Auto 把 Navigation 切成 **Split** ⇒ **左边多出一个 240 vp 的
     * 导航栏**，而 Tabs（连同它的悬浮底栏）住在**右侧的内容区**里。
     *
     * 后果正是用户报的那两条：
     *   · 「底栏不居中」—— 它在内容区里居中，相对整屏就偏了。
     *     用户的描述非常准：「你应该是把底栏当成左边窗口的一个控件之类的了」。
     *   · 「界面太窄」—— 那 240 vp 白给了，内容区根本没占满。
     *
     * Stack 模式下导航页与内容区**互相独立、等价于两页**，本页因此拿到整个窗口宽度，
     * 底栏也就在【总窗口】的正中间。
     *
     * ⚠️ 本页没有任何 NavDestination，Split 的那个导航栏里本来就什么都没有 ——
     * 所以关掉它不损失任何东西。
     */
    .mode(NavigationMode.Stack)
    /* [A]
     * ⚠️ 必须关掉：Navigation 默认在左上角画一个返回箭头，而**这一页不在任何
     * NavPathStack 里**，所以它没有任何可返回的东西 —— 点它什么都不会发生。
     * 用户看到的就是「一个空按钮」。这不是缺陷，是默认值用错了地方。
     */
    .hideBackButton(true)
    .width('100%')
    .height('100%')
    /* [A] 唯一的任务是把窗口宽度学回来，好让底部栏能算出对称的左右留白。
     * 见 sideMargin()。 */
    .onAreaChange((_o: Area, n: Area) => {
      this.winW = Number(n.width);
    })
    .backgroundColor($r('app.color.launcher_bg'))
  }
}
