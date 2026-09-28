import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x9527;
const TAG: string = 'SmartClass';

/**
 * hilog 的薄封装。
 *
 * 统一 TAG 便于 `hdc shell hilog | grep SmartClass` 过滤；
 * 统一走 `%{public}s` 格式串，避免日志内容里的 `%` 被当成格式符。
 */
export class Logger {
  static debug(msg: string): void {
    hilog.debug(DOMAIN, TAG, '%{public}s', msg);
  }

  static info(msg: string): void {
    hilog.info(DOMAIN, TAG, '%{public}s', msg);
  }

  static warn(msg: string): void {
    hilog.warn(DOMAIN, TAG, '%{public}s', msg);
  }

  static error(msg: string): void {
    hilog.error(DOMAIN, TAG, '%{public}s', msg);
  }

  /** 带前缀的信息日志，用于按模块分段排查。 */
  static tag(scope: string, msg: string): void {
    hilog.info(DOMAIN, TAG, '%{public}s', `[${scope}] ${msg}`);
  }

  /** 把异常统一转成可读字符串，避免各处重复写 instanceof 判断。 */
  static errText(e: Object): string {
    if (e instanceof Error) {
      return `${e.name}: ${e.message}`;
    }
    return JSON.stringify(e);
  }
}
