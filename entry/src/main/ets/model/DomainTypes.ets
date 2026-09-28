import { CardState } from './Enums';

/**
 * 教室卡片的视图模型。
 *
 * 存在的理由：空座率有**两个来源、两种单位** ——
 *  - REST 快照：`noSeatRate` 是 0~1 的浮点；
 *  - 实时推送：4005 帧给的是 `round((seatCount - AllStuCnt)/seatCount*100)` 整数百分比。
 *
 * 让视图层去分辨「这个数是小数还是百分数」迟早出错，所以在这里就把两者
 * 归一成同一个**展示字符串**（如 `'50%'` / `'--'`），视图只管渲染。
 * 这也顺带修掉了原站的一个瑕疵：REST 首次渲染与推送更新后的单位处理不一致。
 */
export interface RoomView {
  /** 教室 id。实时推送靠它匹配，也是列表 key 的一部分。 */
  classroomId: number;
  /** 教室名，如「主楼323」 */
  classroomName: string;
  /** 空座率展示文案，如 `'50%'` / `'--'`。单位换算已在此前的转换中完成。 */
  seatText: string;
  /**
   * 总座位数，实时空座率换算的除数。
   * **接口可能给 null**（实测智慧教室 8 间），转换时归一成 0，视图不显示它。
   * 归一成 0 之后 `liveSeatText` 会走"座位数缺失"那条分支 —— 该分支**照抄原站**
   * 渲染 `0%`，别再改成 `--`（理由见 `liveSeatText` 的注释）。
   */
  seatCount: number;
}

/**
 * 视图层的分组结构。
 *
 * 存在的理由：接口的两种形态不一致 —— 「按节次」返回 `{nodeId, nodeName, ...}` 分组，
 * 「按时间段」返回扁平数组。视图层不该为此写两套渲染逻辑，所以在这里统一。
 */
export interface DisplayGroup {
  /**
   * 列表 key —— **决定 ArkUI 复不复用旧组件，写错就等于界面不刷新**。
   *
   * ArkUI 的 ForEach 在非首次渲染时按「键值是否已存在」决策：键值已存在就直接复用
   * 上次的组件实例、**不再执行 itemGenerator**，props 也就不会被重新赋值。
   * 所以这个字段必须体现「数据身份」：任何会让本组内容变化的东西（楼栋/节次类型/
   * 节次/日期/时间段）变了，它就得跟着变。实现见 `ClassroomViewModel.groupKeyOf`。
   *
   * 视图层还会在它后面拼上 `state` 与 `rev`（那两个是渲染期才变的）。
   */
  key: string;
  /**
   * 本组的**渲染期版本号**，只被实时推送推进（见 `ClassroomViewModel.applySeatUpdate`）。
   *
   * 为什么需要它：实时推送只改 `rooms[i].seatText` 这一个字段，`key` 完全没变。
   * 而 ForEach 的规则是「键值已存在 → 复用组件实例、**不再执行 itemGenerator**」，
   * 于是组内那层 `ForEach(g.rooms, …)` 根本不会被重新求值 —— 推送到了、ViewModel
   * 也换了新数组，界面却一个数字都不动。把 rev 拼进组键值，受影响的组才会重建；
   * 未受影响的组键值不变，仍然复用（156 张卡片不会因为一次推送全量重建）。
   *
   * 注意 **不要**把它拼进教室键值：那会让同组内所有教室一起重建，白白丢掉复用。
   */
  rev: number;
  /**
   * 分组标题：按节次时是接口返回的节次名（`string`），按时间段时是本地的时间段名
   * （`Resource`，指向 string.json）—— 所以这里必须是 `ResourceStr`。
   */
  title: ResourceStr;
  /** 副标题：按节次时是 `07:58-09:35`，按时间段时是完整时间范围 */
  timeText: string;
  /** 原始起始时间（`2000-01-01 07:58:00`），**时间跨分钟时需要用它重算状态**，不能拿 timeText 反解 */
  rawStart: string;
  /** 原始结束时间 */
  rawEnd: string;
  /** 该组卡片的配色依据 */
  state: CardState;
  /** 是否展示状态文字标签（按时间段模式下无单一节次状态，不展示） */
  showStateLabel: boolean;
  rooms: RoomView[];
}
