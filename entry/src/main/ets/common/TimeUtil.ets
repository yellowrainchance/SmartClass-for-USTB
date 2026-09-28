import { CardState, TimeSlotId } from '../model/Enums';

/** 一段查询时间窗口。isByNode 为 true 时表示应该走「按节次」接口。 */
export interface TimeRange {
  startTime: string;
  endTime: string;
  isByNode: boolean;
}

const WEEKDAYS_CN: string[] = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];

function pad2(n: number): string {
  return n < 10 ? `0${n}` : `${n}`;
}

/**
 * 时间换算工具。
 *
 * ⚠️ 两个「照抄原站、不要自作聪明」的点：
 *   1. 节次时间的日期部分是占位值（2000-01-01），**只有 HH:mm 有意义**；
 *   2. 时间段边界是 `12:00:01` 与 `19:00:01`（不是整点），必须原样保留。
 */
export class TimeUtil {
  /** 'YYYY-MM-DD' */
  static formatDate(d: Date): string {
    return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
  }

  /** 'HH:mm:ss' */
  static formatHms(d: Date): string {
    return `${pad2(d.getHours())}:${pad2(d.getMinutes())}:${pad2(d.getSeconds())}`;
  }

  /** '2026年09月14日 周一 20:05:07' */
  static formatClock(d: Date): string {
    const day: number = d.getDay();
    const week: string = day >= 0 && day < WEEKDAYS_CN.length ? WEEKDAYS_CN[day] : '';
    return `${d.getFullYear()}年${pad2(d.getMonth() + 1)}月${pad2(d.getDate())}日 ${week} ${TimeUtil.formatHms(d)}`;
  }

  /** '2026-09-14 07:58:00' —— 节次接口用的格式 */
  static toDateTime(dateStr: string, hms: string): string {
    return `${dateStr} ${hms}`;
  }

  /**
   * 从 '2000-01-01 07:58:00' 取出 '07:58'。
   * 日期部分无意义，不要拿去当真正的时间解析。
   */
  static hhmmOf(dateTime: string): string {
    const idx: number = dateTime.indexOf(' ');
    const timePart: string = idx >= 0 ? dateTime.substring(idx + 1) : dateTime;
    return timePart.length >= 5 ? timePart.substring(0, 5) : timePart;
  }

  /** 'HH:mm' 或 'HH:mm:ss' → 当日秒数。 */
  static hhmmToSeconds(hhmm: string): number {
    const parts: string[] = hhmm.split(':');
    if (parts.length < 2) {
      return 0;
    }
    const h: number = Number.parseInt(parts[0], 10);
    const m: number = Number.parseInt(parts[1], 10);
    if (Number.isNaN(h) || Number.isNaN(m)) {
      return 0;
    }
    return h * 3600 + m * 60;
  }

  /** 当前时刻的当日秒数。 */
  static nowSeconds(): number {
    const d: Date = new Date();
    return d.getHours() * 3600 + d.getMinutes() * 60 + d.getSeconds();
  }

  /** 当前时刻是否落在 [startTime, endTime] 内 —— 决定该行是否高亮。 */
  static isInRange(startDateTime: string, endDateTime: string, nowSec: number): boolean {
    const s: number = TimeUtil.hhmmToSeconds(TimeUtil.hhmmOf(startDateTime));
    const e: number = TimeUtil.hhmmToSeconds(TimeUtil.hhmmOf(endDateTime));
    return nowSec >= s && nowSec <= e;
  }

  /** 该节次相对当前时刻的状态 —— 决定卡片配色。 */
  static cardStateOf(startDateTime: string, endDateTime: string, nowSec: number): CardState {
    const s: number = TimeUtil.hhmmToSeconds(TimeUtil.hhmmOf(startDateTime));
    const e: number = TimeUtil.hhmmToSeconds(TimeUtil.hhmmOf(endDateTime));
    if (nowSec > e) {
      return CardState.Prev;
    }
    if (nowSec >= s) {
      return CardState.Current;
    }
    return CardState.Next;
  }

  /**
   * 时间段换算（**逐条对照原站 switch(timeID)，边界值不要改**）。
   *
   *   0 全天   00:00:00 → 23:59:59
   *   1 上午   00:00:00 → 12:00:00
   *   2 下午   12:00:01 → 19:00:00
   *   3 晚上   19:00:01 → 23:59:59
   *   4 按节次 不传时间，走另一个接口
   */
  static rangeOf(slot: TimeSlotId, dateStr: string): TimeRange {
    switch (slot) {
      case TimeSlotId.AllDay:
        return { startTime: `${dateStr} 00:00:00`, endTime: `${dateStr} 23:59:59`, isByNode: false };
      case TimeSlotId.Morning:
        return { startTime: `${dateStr} 00:00:00`, endTime: `${dateStr} 12:00:00`, isByNode: false };
      case TimeSlotId.Afternoon:
        return { startTime: `${dateStr} 12:00:01`, endTime: `${dateStr} 19:00:00`, isByNode: false };
      case TimeSlotId.Evening:
        return { startTime: `${dateStr} 19:00:01`, endTime: `${dateStr} 23:59:59`, isByNode: false };
      case TimeSlotId.ByNode:
      default:
        return { startTime: '', endTime: '', isByNode: true };
    }
  }

  /** 空座率 → 展示文案。null / 0 视为无数据。 */
  static seatFreeText(noSeatRate: number | null): string {
    if (noSeatRate === null || noSeatRate === undefined || noSeatRate <= 0) {
      return '--';
    }
    const pct: number = Math.round(noSeatRate * 100);
    return `${pct}%`;
  }
}
