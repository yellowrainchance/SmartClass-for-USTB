import { http } from '@kit.NetworkKit';
import { ApiEnvelope, Constants } from '../common/Constants';
import { Logger } from '../common/Logger';
import { TokenService } from './TokenService';

/** 错误分类，便于上层决定「重试 / 提示 / 空态」。 */
export enum NetErrorKind {
  /** 连不上、超时、DNS 失败等传输层问题 */
  Network = 'network',
  /** HTTP 状态码非 2xx */
  Http = 'http',
  /** 业务码非 0 */
  Biz = 'biz',
  /** JSON 解析失败或结构不符合预期 */
  Parse = 'parse',
  /** csrkToken 校验失败 */
  Token = 'token'
}

export class NetError extends Error {
  readonly kind: NetErrorKind;
  readonly httpCode: number;
  readonly bizCode: number;

  constructor(kind: NetErrorKind, message: string, httpCode: number = 0, bizCode: number = 0) {
    super(message);
    this.name = 'NetError';
    this.kind = kind;
    this.httpCode = httpCode;
    this.bizCode = bizCode;
  }
}

/** 原始响应（未拆壳），供 config.json / GettimeDif 这类非标准响应使用。 */
export interface RawResult {
  status: number;
  body: string;
}

/**
 * 统一 HTTP 客户端。
 *
 * 职责：
 *  1. 把 `/general/api/**` 解析成绝对 URL（generalEduIp 为空时回退同源）
 *  2. 自动追加 csrkToken
 *  3. 拆解 `{code, msg, data}` 外壳，非 0 抛 NetError
 *  4. token 失效时自动重新校时并重试一次
 *  5. **每个请求后都 destroy()**，避免句柄泄漏
 */
export class HttpClient {
  private base: string = Constants.DEFAULT_BASE;
  private generalEduIp: string = '';
  private tokens: TokenService | null = null;

  configure(base: string, generalEduIp: string, tokens: TokenService): void {
    this.base = base;
    this.generalEduIp = generalEduIp;
    this.tokens = tokens;
    Logger.tag('Http', `base=${base} generalEduIp="${generalEduIp}"`);
  }

  getBaseUrl(): string {
    return this.base;
  }

  /**
   * `/general/api` 的实际基址。
   * generalEduIp 为空（本校本部就是这样）或不是绝对地址时，回退到站点同源，
   * 否则直接拼会得到 `/general/api/...` 这种非法绝对 URL。
   */
  private resolveGeneralBase(): string {
    const v: string = this.generalEduIp.trim();
    if (v.startsWith('http://') || v.startsWith('https://')) {
      return v.endsWith('/') ? v.substring(0, v.length - 1) : v;
    }
    return this.base;
  }

  // ---------------------------------------------------------------- 原始请求

  /**
   * 发一个请求并返回原始响应文本。
   * @param url 完整 URL
   * @param method 请求方法
   * @param body 请求体（JSON 字符串），GET 传 null
   * @param signed 是否追加 csrkToken
   */
  async requestRaw(url: string, method: http.RequestMethod, body: string | null,
    signed: boolean = false): Promise<RawResult> {
    let finalUrl: string = url;
    if (signed) {
      if (this.tokens === null) {
        throw new NetError(NetErrorKind.Token, 'TokenService 未初始化');
      }
      finalUrl = this.tokens.sign(url);
    }

    const header: Record<string, string> = {
      'Referer': Constants.PAGE_REFERER,
      'Accept': 'application/json, text/plain, */*',
      'User-Agent': 'Mozilla/5.0 (Linux; HarmonyOS) AppleWebKit/537.36 SmartClassApp/1.0'
    };
    if (body !== null) {
      header['Content-Type'] = 'application/json;charset=utf8';
    }

    const options: http.HttpRequestOptions = {
      method: method,
      header: header,
      connectTimeout: Constants.CONNECT_TIMEOUT_MS,
      readTimeout: Constants.READ_TIMEOUT_MS,
      expectDataType: http.HttpDataType.STRING
    };
    if (body !== null) {
      options.extraData = body;
    }

    const request: http.HttpRequest = http.createHttp();
    try {
      const resp: http.HttpResponse = await request.request(finalUrl, options);
      const text: string = typeof resp.result === 'string' ? resp.result as string : '';
      if (resp.responseCode !== http.ResponseCode.OK) {
        throw new NetError(
          NetErrorKind.Http,
          `HTTP ${resp.responseCode}`,
          resp.responseCode as number
        );
      }
      return { status: resp.responseCode as number, body: text };
    } catch (e) {
      if (e instanceof NetError) {
        throw e;
      }
      throw new NetError(NetErrorKind.Network, `请求失败: ${Logger.errText(e)}`);
    } finally {
      // 官方文档明确要求：每次请求后释放，否则内存占用持续增长
      request.destroy();
    }
  }

  // ---------------------------------------------------------------- 业务接口

  /** GET 一个走业务外壳的接口。 */
  async getEnvelope<T>(path: string): Promise<T> {
    return this.withTokenRetry(async () => {
      const raw: RawResult = await this.requestRaw(
        this.resolveGeneralBase() + path, http.RequestMethod.GET, null, true);
      return this.unwrap<T>(raw.body, path);
    });
  }

  /** POST 一个走业务外壳的接口。bodyJson 由调用方用显式类型对象序列化得到。 */
  async postEnvelope<T>(path: string, bodyJson: string): Promise<T> {
    return this.withTokenRetry(async () => {
      const raw: RawResult = await this.requestRaw(
        this.resolveGeneralBase() + path, http.RequestMethod.POST, bodyJson, true);
      return this.unwrap<T>(raw.body, path);
    });
  }

  /** 站点同源的原始 GET（config.json / GettimeDif 这类非外壳响应）。 */
  async getSiteRaw(path: string, signed: boolean = false): Promise<RawResult> {
    return this.requestRaw(this.base + path, http.RequestMethod.GET, null, signed);
  }

  // ---------------------------------------------------------------- 校时

  /**
   * 拉取服务器时间并更新 TimeDif。
   * 注意 /Home/GettimeDif **本身也要求合法 token**，所以调用前必须已 configure() 过 csrkKey。
   */
  async syncTime(): Promise<boolean> {
    if (this.tokens === null || !this.tokens.isReady()) {
      return false;
    }
    try {
      const raw: RawResult = await this.requestRaw(
        this.base + Constants.PATH_TIME_DIF, http.RequestMethod.GET, null, true);
      const serverMs: number = Number.parseInt(raw.body.trim(), 10);
      if (Number.isNaN(serverMs) || serverMs <= 0) {
        Logger.warn(`校时返回无法解析: ${raw.body.substring(0, 80)}`);
        return false;
      }
      this.tokens.setTimeDif(serverMs - new Date().getTime());
      return true;
    } catch (e) {
      // 校时失败不抛错：实测本机与服务器偏差为 0，用本地时间照样能通过校验
      Logger.warn(`校时失败（不阻塞）: ${Logger.errText(e)}`);
      return false;
    }
  }

  // ---------------------------------------------------------------- 内部

  /** 拆解 `{code, msg, data}` 外壳。 */
  private unwrap<T>(body: string, path: string): T {
    let env: ApiEnvelope<T> | null = null;
    try {
      env = JSON.parse(body) as ApiEnvelope<T>;
    } catch (e) {
      throw new NetError(NetErrorKind.Parse, `响应不是合法 JSON (${path}): ${body.substring(0, 120)}`);
    }
    if (env === null) {
      throw new NetError(NetErrorKind.Parse, `响应为空 (${path})`);
    }
    if (env.code !== Constants.CODE_OK) {
      const msg: string = env.msg === undefined || env.msg === null ? '' : env.msg;
      const lower: string = msg.toLowerCase();
      if (lower.indexOf('csrf') !== -1 || lower.indexOf('token') !== -1) {
        throw new NetError(NetErrorKind.Token, `鉴权失败: ${msg}`, 200, env.code);
      }
      throw new NetError(NetErrorKind.Biz, `业务错误: ${msg}`, 200, env.code);
    }
    if (env.data === null || env.data === undefined) {
      throw new NetError(NetErrorKind.Parse, `响应 data 为空 (${path})`);
    }
    return env.data;
  }

  /**
   * token 失效时自动重新校时并重试一次。
   * 只重试一次，避免密钥本身失效时陷入死循环。
   */
  private async withTokenRetry<T>(task: () => Promise<T>): Promise<T> {
    try {
      return await task();
    } catch (e) {
      if (e instanceof NetError && e.kind === NetErrorKind.Token) {
        Logger.warn('token 校验失败，重新校时后重试一次');
        await this.syncTime();
        return await task();
      }
      if (e instanceof NetError) {
        throw e;
      }
      throw new NetError(NetErrorKind.Network, `请求失败: ${Logger.errText(e)}`);
    }
  }
}
