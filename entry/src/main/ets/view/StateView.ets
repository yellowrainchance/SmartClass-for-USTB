import { LoadState } from '../model/Enums';

/**
 * 三态视图：加载（骨架屏）/ 空 / 错误。
 *
 * 设计取舍：
 *  - 加载态用**骨架屏**而不是转圈。列表类数据首次加载在 1~15 秒量级，
 *    转圈无法让用户估时；骨架屏提前画出结果形状，锚定期望、减少焦虑。
 *  - 空态与错误态必须给出**下一步动作**（重试），不能只显示一句话。
 */
@Component
export struct StateView {
  @Prop state: LoadState;
  @Prop message: string = '';
  onRetry?: () => void;

  build() {
    Column() {
      if (this.state === LoadState.Loading) {
        this.buildSkeleton()
      } else if (this.state === LoadState.Empty) {
        this.buildMessage('空', $r('app.string.state_empty'), false)
      } else if (this.state === LoadState.Error) {
        this.buildMessage('!', this.message.length > 0 ? this.message : '查询失败', true)
      }
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  /** 骨架屏：模拟「节次头 + 一行卡片」的形状，重复三组。 */
  @Builder
  buildSkeleton() {
    Column({ space: 14 }) {
      ForEach([1, 2, 3], (group: number) => {
        Column({ space: 8 }) {
          // 节次头占位
          Row() {
            Row().width(120).height(16).borderRadius(4)
              .backgroundColor($r('app.color.border'))
          }
          .width('100%')
          .height(44)
          .padding({ left: 12, right: 12 })
          .borderRadius(8)
          .backgroundColor($r('app.color.surface_alt'))

          // 卡片占位
          Row({ space: 8 }) {
            ForEach([1, 2, 3], (card: number) => {
              Column()
                .layoutWeight(1)
                .height(64)
                .borderRadius(10)
                .backgroundColor($r('app.color.surface_alt'))
            }, (card: number) => `sk-${group}-${card}`)
          }
          .width('100%')
        }
        .width('100%')
      }, (group: number) => `skg-${group}`)
    }
    .width('100%')
    .padding(16)
    .opacity(0.7)
  }

  @Builder
  buildMessage(glyph: string, text: ResourceStr, showRetry: boolean) {
    Column({ space: 12 }) {
      // 用一个简洁的圆形标记代替原站的 320x320 插画：
      // 手机上一张占半屏的插画信息量太低，且这里不需要额外图片资源。
      // 注意：不用 Circle().fill()，该接口要求 SDK 26，而本工程兼容 SDK 24。
      //
      // 字形区分「空」与「错误」：两者用同一个图标会让「查不到数据」和
      // 「查数据失败」看起来是一回事，而后者是可以通过重试解决的。
      Text(glyph)
        .fontSize(26)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_hint'))
        .width(72)
        .height(72)
        .textAlign(TextAlign.Center)
        .borderRadius(36)
        .backgroundColor($r('app.color.surface_alt'))

      Text(text)
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center)
        .padding({ left: 24, right: 24 })

      if (showRetry) {
        Button($r('app.string.action_retry'))
          .type(ButtonType.Capsule)
          .height(38)
          .fontSize(15)
          .backgroundColor($r('app.color.brand'))
          .onClick(() => {
            const cb = this.onRetry;
            if (cb !== undefined) {
              cb();
            }
          })
      }
    }
    .width('100%')
    .padding(24)
  }
}
