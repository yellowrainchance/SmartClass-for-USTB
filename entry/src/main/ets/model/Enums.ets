/** 两套查询模式。原页面用 searchType 0/1 区分。 */
export enum SearchType {
  /** 按节次：POST freeClassRooms，返回**按节次分组**的教室列表 */
  ByNode = 'ByNode',
  /** 按时间段：POST freeJoinClassRooms，返回**扁平**教室列表 */
  ByTimeRange = 'ByTimeRange'
}

/** 时间段取值，与原页面 `<select id="selectTime">` 的 option value 一一对应。 */
export enum TimeSlotId {
  AllDay = 0,
  Morning = 1,
  Afternoon = 2,
  Evening = 3,
  /** 4 = 按节次（默认值，此时不走时间段接口） */
  ByNode = 4
}

/** 页面主状态机。 */
export enum LoadState {
  Loading = 'Loading',
  Ok = 'Ok',
  /** 请求成功但没有任何空闲教室 */
  Empty = 'Empty',
  /** 请求失败（网络/业务/解析） */
  Error = 'Error'
}

/** 教室卡片相对**当前时刻**的状态，决定卡片配色。 */
export enum CardState {
  /** 该节次已结束 → 灰 */
  Prev = 'Prev',
  /** 正在进行 → 蓝 */
  Current = 'Current',
  /** 尚未开始 → 橙红 */
  Next = 'Next'
}
