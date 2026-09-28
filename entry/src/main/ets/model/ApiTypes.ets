/**
 * 接口数据模型（DTO）。
 *
 * 全部写成显式 interface —— ArkTS 禁止结构化类型推断，JSON.parse 的结果
 * 必须 cast 到一个具名类型才能安全访问字段。
 *
 * 字段语义（实测）：
 *  - noSeatRate  空座率，0~1 浮点或 null。展示时 round(v*100)+'%'，null/0 视为无数据。
 *  - seatCount   教室总座位数，是实时空座率换算的除数。**实测可为 null** ——
 *                2026-09-14 实测：智慧教室有 8 间为 null（另有已从界面移除的「南楼」
 *                整栋 47 间）。不要因为声明成 number 就当它一定有位数值。
 *  - scheduleId  空课场景恒为 null，应用内忽略。
 *  - startTime/endTime 形如 '2000-01-01 07:58:00'，**日期部分是无意义的占位**，只取 HH:mm。
 */

/** 节次类型，如「默认节次」「小结次」。 */
export interface NodeTypeDto {
  id: string;
  name: string;
}

/** 节次，如「第一大节」。 */
export interface NodeDto {
  id: string;
  name: string;
  startTime: string;
  endTime: string;
}

/** 楼栋。接口返回 5 个（含原网页硬编码漏掉的「南楼」）。 */
export interface BuildingDto {
  id: string;
  name: string;
}

/** 单个教室条目。 */
export interface ClassroomItemDto {
  classroomId: number;
  classroomName: string;
  scheduleId: string | null;
  noSeatRate: number | null;
  /** 总座位数。**可为 null**（实测智慧教室 8 间、南楼整栋），用前必须判空。 */
  seatCount: number | null;
}

/** 「按节次」查询返回的分组：一个节次 + 该节次下所有空闲教室。 */
export interface FreeRoomGroupDto {
  nodeId: string;
  nodeName: string;
  startTime: string;
  endTime: string;
  classroomItems: ClassroomItemDto[];
}

/** 「按节次」查询请求体。nodeId 传空串表示全部节次（不要传 null）。 */
export interface FreeByNodeReq {
  buildingId: string;
  cycleTypeId: string;
  nodeId: string;
}

/** 「按时间段」查询请求体。时间格式 'yyyy-MM-dd HH:mm:ss'。 */
export interface FreeByTimeReq {
  buildingId: string;
  startTime: string;
  endTime: string;
}
