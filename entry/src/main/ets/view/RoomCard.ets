import { CardState } from '../model/Enums';
import { stateColor } from './StateStyle';

/**
 * 单张教室卡片。
 *
 * 纯展示组件：只吃 props，不发请求、不持有业务状态。
 * 卡片底色由所属**节次**的状态决定（同组卡片同色），沿用原站的配色语汇。
 */
@Component
export struct RoomCard {
  /** 教室名，如「主楼323」 */
  @Prop roomName: string = '';
  /** 空座率文案，如「50%」或「--」 */
  @Prop seatText: string = '--';
  /** 所属节次相对当前时刻的状态 */
  @Prop cardState: CardState = CardState.Current;

  build() {
    Column({ space: 2 }) {
      Text(this.roomName)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_on_brand'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      // ⚠️ 不要把 $r() 塞进模板串。`${$r('app.string.x')}` 会调用 Resource 对象的
      // toString()，渲染出来是字面量 "[object Object]"（实测就是这样），文案本身
      // 一个字都看不到。Text() 组件接受 Resource，但一旦参与字符串拼接，它就只是
      // 个普通对象了 —— 用 Span 承载资源、普通字符串承载数值，各走各的通道。
      Text() {
        Span($r('app.string.label_seat_free'))
        Span(` ${this.seatText}`)
      }
        .fontSize(12)
        .fontColor($r('app.color.text_on_brand'))
        .opacity(0.88)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .justifyContent(FlexAlign.Center)
    .width('100%')
    .height(64)
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .borderRadius(10)
    .backgroundColor(stateColor(this.cardState))
    .shadow({
      radius: this.cardState === CardState.Current ? 8 : 0,
      color: $r('app.color.shadow'),
      offsetX: 0,
      offsetY: 2
    })
  }
}
