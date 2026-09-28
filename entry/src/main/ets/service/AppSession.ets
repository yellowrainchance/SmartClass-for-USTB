import { common } from '@kit.AbilityKit';
import { Constants, DomainConfig } from '../common/Constants';
import { Logger } from '../common/Logger';
import { Prefs } from '../store/Prefs';
import { ConfigRepository } from '../repository/ConfigRepository';
import { HttpClient, NetError } from './HttpClient';
import { TokenService } from './TokenService';

export interface BootResult {
  ok: boolean;
  /** 是否走的本地缓存（首屏速度的关键） */
  fromCache: boolean;
  error: string;
}

/**
 * 应用级会话：持有 token 服务与 HTTP 客户端，负责启动引导。
 *
 * 引导顺序（**刻意修掉原网页的时序缺陷** —— 原页面会在元数据还没拿到时
 * 先发一次空参数请求）：
 *
 *   Prefs.init
 *     └─ 有缓存 → 立刻可用（fromCache=true），后台静默刷新 + 校时
 *     └─ 无缓存 → 拉 /config.json → AES 解密 → 写缓存 → 可用
 *
 * 校时永远是**后台**行为，绝不阻塞首屏。
 *
 * Context 由 EntryAbility 在 onCreate 时注入，页面无需自己获取
 * （ArkUI 的 getContext 已废弃，走 getUIContext 又拿不到 Ability 级上下文）。
 */
export class AppSession {
  private static instance: AppSession | null = null;

  /** 全局唯一实例。 */
  static get(): AppSession {
    if (AppSession.instance === null) {
      AppSession.instance = new AppSession();
    }
    return AppSession.instance;
  }

  readonly tokenService: TokenService = new TokenService();
  readonly http: HttpClient = new HttpClient();

  private context: common.Context | null = null;
  private domain: DomainConfig | null = null;
  private ready: boolean = false;
  private bootPromise: Promise<BootResult> | null = null;

  /** 由 EntryAbility.onCreate 调用。 */
  attach(context: common.Context): void {
    this.context = context;
  }

  /**
   * 开始引导。重复调用复用同一个 Promise，避免并发重复拉配置。
   * 建议在 EntryAbility.onCreate 里就调用，让配置在首页出现前先加载好。
   */
  boot(): Promise<BootResult> {
    if (this.bootPromise !== null) {
      return this.bootPromise;
    }
    this.bootPromise = this.doBoot();
    return this.bootPromise;
  }

  isReady(): boolean {
    return this.ready;
  }

  getDomain(): DomainConfig | null {
    return this.domain;
  }

  /** WebSocket 地址来源：优先用配置里的 aiAnalyseIp（**站点把它拼成了 attendace，少个 n**）。 */
  getAiAnalyseIp(): string {
    return this.domain === null ? '' : this.domain.aiAnalyseIp;
  }

  // ------------------------------------------------------------------ 内部

  private async doBoot(): Promise<BootResult> {
    if (this.context === null) {
      const msg: string = 'Context 尚未注入，无法引导';
      Logger.error(msg);
      return { ok: false, fromCache: false, error: msg };
    }

    try {
      await Prefs.init(this.context as common.Context);
    } catch (e) {
      // 缓存不可用不应阻断启动，后面直接走网络
      Logger.error(`Prefs 初始化失败: ${Logger.errText(e)}`);
    }

    // 1) 快路径：有缓存先用缓存
    const cached: DomainConfig | null = ConfigRepository.readCache();
    if (cached !== null) {
      this.applyConfig(cached);
      Logger.tag('Boot', `使用缓存配置（${ConfigRepository.cacheAgeText()}）`);
      this.backgroundRefresh();
      return { ok: true, fromCache: true, error: '' };
    }

    // 2) 慢路径：必须等网络
    Logger.tag('Boot', '无缓存，开始拉取 config.json');
    try {
      const cfg: DomainConfig = await ConfigRepository.fetch(this.http);
      this.applyConfig(cfg);
      this.backgroundRefresh();
      return { ok: true, fromCache: false, error: '' };
    } catch (e) {
      const msg: string = e instanceof NetError ? e.message : Logger.errText(e);
      Logger.error(`启动失败: ${msg}`);
      return { ok: false, fromCache: false, error: msg };
    }
  }

  /** 配置就绪后立刻可用，并让 token 服务开始工作。 */
  private applyConfig(cfg: DomainConfig): void {
    this.domain = cfg;
    this.tokenService.configure(cfg.csrkKey);
    this.http.configure(Constants.DEFAULT_BASE, cfg.generalEduIp, this.tokenService);
    this.ready = true;
  }

  /**
   * 后台做两件不阻塞的事：刷新配置（必要时）+ 校时。
   * 全部失败都不影响当前可用性。
   */
  private backgroundRefresh(): void {
    this.refreshConfigIfNeeded()
      .then(() => this.http.syncTime())
      .then((synced: boolean) => {
        Logger.tag('Boot', `后台任务完成，校时${synced ? '成功' : '跳过'} ${this.tokenService.debugInfo()}`);
      })
      .catch((e: Object) => {
        Logger.warn(`后台刷新失败（不影响使用）: ${Logger.errText(e)}`);
      });
  }

  private async refreshConfigIfNeeded(): Promise<void> {
    if (ConfigRepository.usedFallback) {
      // 本机没有真实加密能力（预览器），重拉也解不开，白费一次请求。
      // 等换到模拟器/真机后自然走正常路径。
      return;
    }
    if (!ConfigRepository.isCacheExpired()) {
      return;
    }
    try {
      const cfg: DomainConfig = await ConfigRepository.fetch(this.http);
      this.applyConfig(cfg);
      Logger.tag('Boot', '配置已在后台刷新');
    } catch (e) {
      // 保持旧值
      Logger.warn(`配置后台刷新失败，继续使用旧值: ${Logger.errText(e)}`);
    }
  }
}
