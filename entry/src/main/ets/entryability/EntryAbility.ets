import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { display, window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ImageDiskCache } from '../net/ImageDiskCache';
import { AppContext } from '../core/AppContext';

const TAG: string = 'LiteWM';

/**
 * 入口 Ability。
 *
 * 职责：
 *  1. 把 context 注入 AppContext（Prefs / 保存路径都靠它）；
 *  2. 全屏沉浸式布局，并把状态栏 / 导航条高度写进 AppStorage
 *     （相机页要顶到状态栏下，浮层控件要避开导航条）；
 *  3. 把前后台状态写进 AppStorage —— 相机句柄在后台会被系统回收，
 *     页面必须据此释放并重建会话；
 *  4. 加载首页。
 */
export default class EntryAbility extends UIAbility {
  private win: window.Window | null = null;
  private avoidCallback: ((data: window.AvoidAreaOptions) => void) | null = null;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    AppContext.init(this.context);
    // 图片磁盘缓存超容时在后台清一次（300MB → 80%），不挡启动
    ImageDiskCache.sweepIfNeeded();
    AppStorage.setOrCreate<boolean>('appForeground', true);
    hilog.info(0x0000, TAG, 'onCreate');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    try {
      const w: window.Window = windowStage.getMainWindowSync();
      this.win = w;
      w.setWindowLayoutFullScreen(true);
      this.publishInsets(w);
      this.avoidCallback = (data: window.AvoidAreaOptions): void => {
        if (this.win !== null) {
          this.publishInsets(this.win);
        }
      };
      w.on('avoidAreaChange', this.avoidCallback);
    } catch (e) {
      hilog.warn(0x0000, TAG, 'immersive setup failed');
    }
    AppStorage.setOrCreate<boolean>('systemDark',
      this.context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(0x0000, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(0x0000, TAG, 'loadContent ok');
    });
  }

  /** px2vp 已废弃，这里直接用屏幕密度换算，顺手把两处高度一起写进 AppStorage */
  private publishInsets(w: window.Window): void {
    try {
      const density: number = display.getDefaultDisplaySync().densityPixels;
      const sysArea: window.AvoidArea = w.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const navArea: window.AvoidArea = w.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      AppStorage.setOrCreate<number>('statusBarHeight', sysArea.topRect.height / density);
      AppStorage.setOrCreate<number>('navBarHeight', navArea.bottomRect.height / density);
    } catch (e) {
      AppStorage.setOrCreate<number>('statusBarHeight', 0);
      AppStorage.setOrCreate<number>('navBarHeight', 0);
    }
  }

  onForeground(): void {
    AppStorage.setOrCreate<boolean>('appForeground', true);
  }

  onBackground(): void {
    AppStorage.setOrCreate<boolean>('appForeground', false);
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    AppStorage.setOrCreate<boolean>('systemDark',
      newConfig.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
  }

  onWindowStageDestroy(): void {
    // 不注销监听，窗口销毁后回调还会拿着已释放的 Window 进来
    try {
      if (this.win !== null && this.avoidCallback !== null) {
        this.win.off('avoidAreaChange', this.avoidCallback);
      }
    } catch (e) {
      hilog.warn(0x0000, TAG, 'off avoidAreaChange failed');
    }
    this.avoidCallback = null;
    this.win = null;
  }

  onDestroy(): void {
    hilog.info(0x0000, TAG, 'onDestroy');
  }
}
