import { curves } from '@kit.ArkUI';

/**
 * 全应用动效参数的唯一来源。
 *
 * 为什么集中成一个文件，而不是各页面自己写字面量：
 *  - 四类时长是**互相配合**的：出场如果比进场短，页面会像"急着走"；出栈收尾延迟比动画
 *    短，最后一帧会被截断，看起来是"滑到一半被抽掉"。只有放在一处，才能保证这层关系
 *    不被人单独改坏。
 *  - 曲线和时长必须成对看：openCurve 的尾巴很长（0.2,0,0,1 在前 20% 时间就走完 60%+
 *    的距离），短时长配它观感是"弹到位再停顿"；长时长才像"推上去自己吸附住"。
 *
 * 数值来源：docs/V2-UI-SPEC.md §3.7（ANIM_DURATION 400 / ANIM_STATE_RESET_MS 420 /
 * ANIM_DONE_DELAY_MS 200）以及详情页转场那套 350ms + 两条 cubicBezier。
 */
export class Motion {
  /** 状态类动效的基准时长（非页面转场：跟随、变形、渐显的默认值） */
  static readonly DURATION: number = 400;
  /** 页面栈推入 / 退出。进出同长，不对称会显得"进慢出快" */
  static readonly DETAIL: number = 350;
  /** 状态复位：底栏指示条、选中项缩放这类"走到新稳态"的动效 */
  static readonly STATE_RESET: number = 420;
  /** 收尾 / 次要动效：底栏淡出、按压回弹 */
  static readonly DONE_DELAY: number = 200;
  /** 门禁页（18+ 确认、应用锁）出现时的整页淡入 */
  static readonly GATE_IN: number = 300;

  /**
   * 推入曲线：cubicBezier(0.2, 0, 0, 1)。
   * 起步加速度极大、结尾极缓 —— 页面像被"推"进来之后自己吸附到位。这是鸿蒙系统页面
   * 转场的手感，也是参考工程详情页用的那条；换成 FastOutSlowIn 会明显"塑料"。
   */
  static readonly openCurve: curves.ICurve = curves.cubicBezierCurve(0.2, 0, 0, 1);

  /**
   * 退出曲线：cubicBezier(0.3, 0, 0.2, 1)。
   * 起步比 openCurve 更缓（x1 从 0.2 提到 0.3）：退出是"已经确定要走的动作"，一按就飞
   * 出去像被弹开；缓起步 + 长尾巴更像被收回去。
   */
  static readonly closeCurve: curves.ICurve = curves.cubicBezierCurve(0.3, 0, 0.2, 1);

  /** 通用曲线：非转场动效（缩放、宽度、透明度）统一用它，避免出现十几条不同曲线 */
  static readonly standard: Curve = Curve.FastOutSlowIn;

  /**
   * 统一的显式动画入口。
   *
   * 为什么要包一层：`animateTo` 只能从 UIContext 拿。页面里到处写
   * `this.getUIContext().animateTo({ duration: ..., curve: ... })` 有两个隐患 ——
   *  1. 时长和曲线散落各处，改一处漏三处；
   *  2. 将来要统一加 `expectedFrameRateRange`（高刷屏帧率对齐）时没有收口的地方。
   *
   * 这里刻意**不缓存** UIContext：它跟窗口绑定，缓存下来可能拿到已失效的实例。
   */
  static animate(ui: UIContext, duration: number, curve: Curve | curves.ICurve, fn: () => void): void {
    ui.animateTo({ duration: duration, curve: curve }, fn);
  }
}
