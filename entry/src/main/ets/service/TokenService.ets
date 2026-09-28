import { Logger } from '../common/Logger';

/**
 * csrkToken 生成与时间校准。
 *
 * 算法（复刻自站点 getcsrf()）：
 *   t = 当前毫秒时间戳 + TimeDif
 *   从 j = 10^12 逐级降到 1，共 13 轮：
 *       digit = floor(t / j)            // 取 t 的第 n 位十进制数字（0~9）
 *       token += csrkKey[digit]         // 用该数字当索引去密钥里取字符
 *       t %= j
 *
 * 两个必须保留的原站行为：
 *   1. 下标超出 csrkKey 长度时**静默丢弃**该位，token 可能短于 13 字符；
 *   2. 服务端只校验 token 是否由合法密钥推出，不校验时间窗口。
 *
 * 标准答案见 `参考网站/探测脚本/probe_api.py`，同一毫秒下应完全一致。
 */
export class TokenService {
  private csrkKey: string = '';
  private timeDifMs: number = 0;

  /** 配置解密后拿到的 csrkKey。 */
  configure(csrkKey: string): void {
    this.csrkKey = csrkKey;
    Logger.tag('Token', `csrkKey 已配置，长度 ${csrkKey.length}`);
  }

  isReady(): boolean {
    return this.csrkKey.length > 0;
  }

  /** TimeDif = 服务器时间 - 本地时间。失败时保持 0 即可（实测偏差极小）。 */
  setTimeDif(ms: number): void {
    this.timeDifMs = ms;
    Logger.tag('Token', `TimeDif = ${ms} ms`);
  }

  getTimeDif(): number {
    return this.timeDifMs;
  }

  /** 校时后的「服务器时间」（毫秒）。 */
  serverNowMs(): number {
    return new Date().getTime() + this.timeDifMs;
  }

  /** 生成 csrkToken。 */
  generate(): string {
    if (!this.isReady()) {
      throw new Error('csrkKey 未配置，无法生成 csrkToken');
    }
    let t: number = this.serverNowMs();
    let token: string = '';
    let j: number = 1000000000000; // 10^12 → 13 轮
    while (j !== 0) {
      const k: number = Math.floor(t / j);
      if (k >= 0 && k < this.csrkKey.length) {
        token += this.csrkKey.charAt(k);
      }
      t -= k * j;
      j = Math.floor(j / 10);
    }
    return token;
  }

  /** 往 URL 上追加 csrkToken 查询参数。 */
  sign(url: string): string {
    const query: string = `csrkToken=${this.generate()}`;
    return url.indexOf('?') !== -1 ? `${url}&${query}` : `${url}?${query}`;
  }

  /** 当前状态的简要描述，供日志排查用。 */
  debugInfo(): string {
    const len: number = this.isReady() ? this.generate().length : 0;
    return `tokenLen=${len} timeDif=${this.timeDifMs}ms`;
  }
}
