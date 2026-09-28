import { CardState } from '../model/Enums';

/**
 * 节次状态的视觉映射。
 *
 * 设计决策：**颜色不是唯一的状态载体**。
 * 原网页只用灰/蓝/橙三种底色区分「已结束 / 进行中 / 未开始」，
 * 色盲用户与强光环境下无法分辨。这里把状态同时映射成颜色与文字标签，
 * 文字标签由分组头承载（一色 + 一标签，双编码），不额外增加卡片上的元素。
 */
export function stateColor(state: CardState): ResourceColor {
  switch (state) {
    case CardState.Prev:
      return $r('app.color.room_prev');
    case CardState.Next:
      return $r('app.color.room_next');
    case CardState.Current:
    default:
      return $r('app.color.room_current');
  }
}

/** 状态文字标签，与 stateColor 一一对应。 */
export function stateLabel(state: CardState): Resource {
  switch (state) {
    case CardState.Prev:
      return $r('app.string.state_label_prev');
    case CardState.Next:
      return $r('app.string.state_label_next');
    case CardState.Current:
    default:
      return $r('app.string.state_label_current');
  }
}
