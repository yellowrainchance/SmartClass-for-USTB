import { Constants, DomainConfig } from '../common/Constants';
import { Logger } from '../common/Logger';
import { Prefs } from '../store/Prefs';
import { Cipher } from '../service/Cipher';
import { HttpClient, NetErrorKind, NetError, RawResult } from '../service/HttpClient';

/** config.json 的原始结构（域名为 AES 密文）。 */
interface RawConfigFile {
  domainConfig: string;
  attendanceSource: string;
  location: string;
}

/**
 * 取响应开头一小段用于报错，顺手压掉换行 —— 报错信息必须是单行，
 * 否则会撑破提示框。站点响应本身是带 \r\n 的格式化 JSON。
 */
function headOf(body: string): string {
  let one: string = '';
  for (let i = 0; i < body.length && one.length < 60; i++) {
    const c: string = body.charAt(i);
    if (c === '\r' || c === '\n' || c === '\t') {
      if (one.length > 0 && one.charAt(one.length - 1) !== ' ') {
        one += ' ';
      }
    } else {
      one += c;
    }
  }
  return `"${one}"`;
}

/** JSON 能解析但缺字段时，列出顶层字段名 —— 直接回答「站点到底返回了什么」。 */
function fieldNamesOf(body: string): string {
  try {
    const obj: Record<string, Object> = JSON.parse(body) as Record<string, Object>;
    return `[${Object.keys(obj).join(',')}]`;
  } catch (e) {
    return '(无法解析)';
  }
}

/**
 * 站点域名配置的获取、解密与缓存。
 *
 * 这是整条链路的**第一块多米诺**：只有拿到 csrkKey 才能生成 csrkToken，
 * 也才能调任何 /general/api 接口。所以它必须在最前面且必须稳。
 *
 * 缓存策略（刻意设计成「不阻塞首屏」）：
 *   - 有缓存 → 立刻返回旧值，后台静默刷新；
 *   - 无缓存 → 只能等网络，此时由上层显示加载态；
 *   - 缓存过期（24h）→ 仍然先用旧值，后台刷新。
 *   这样即使配置服务抖动，应用也不会打不开。
 */
export class ConfigRepository {
  /** 读缓存。无缓存或解析失败返回 null。 */
  static readCache(): DomainConfig | null {
    const text: string = Prefs.getString(Constants.KEY_DOMAIN_CONFIG, '');
    if (text.length === 0) {
      return null;
    }
    try {
      const cfg: DomainConfig = JSON.parse(text) as DomainConfig;
      if (cfg.csrkKey === undefined || cfg.csrkKey.length === 0) {
        Logger.warn('缓存中的 csrkKey 为空，视为无效缓存');
        return null;
      }
      return cfg;
    } catch (e) {
      Logger.warn(`缓存解析失败: ${Logger.errText(e)}`);
      return null;
    }
  }

  /** 缓存是否已超过有效期。 */
  static isCacheExpired(): boolean {
    const ts: number = Prefs.getNumber(Constants.KEY_DOMAIN_TS, 0);
    if (ts <= 0) {
      return true;
    }
    return new Date().getTime() - ts > Constants.DOMAIN_CONFIG_TTL_MS;
  }

  static cacheAgeText(): string {
    const ts: number = Prefs.getNumber(Constants.KEY_DOMAIN_TS, 0);
    if (ts <= 0) {
      return '无缓存';
    }
    const min: number = Math.floor((new Date().getTime() - ts) / 60000);
    return min < 1 ? '刚刚' : `${min} 分钟前`;
  }

  /**
   * 拉取线上配置、解密并写缓存。
   * config.json 在同源根路径下，**不需要 csrkToken**。
   */
  static async fetch(http: HttpClient): Promise<DomainConfig> {
    const raw: RawResult = await http.getSiteRaw(Constants.PATH_CONFIG, false);
    if (raw.body.length === 0) {
      throw new NetError(NetErrorKind.Parse, 'config.json 响应为空');
    }

    let file: RawConfigFile;
    try {
      file = JSON.parse(raw.body) as RawConfigFile;
    } catch (e) {
      throw new NetError(NetErrorKind.Parse,
        `config.json 不是合法 JSON（${raw.body.length} 字节，开头 ${headOf(raw.body)}）`);
    }
    if (file.domainConfig === undefined || file.domainConfig.length === 0) {
      throw new NetError(NetErrorKind.Parse,
        `config.json 缺少 domainConfig 字段（${raw.body.length} 字节，字段 ${fieldNamesOf(raw.body)}）`);
    }

    // 先验**本机加密能力**（不依赖网络），再解密业务密文。
    // 顺序很关键：「解密为空」既可能是本机 cryptoFramework 的问题，也可能是响应内容变了，
    // 不先跑 KAT 就只能靠猜，而两者都表现为同一句话。
    const kat: string = ConfigRepository.katVerdict();
    if (kat !== 'OK') {
      // 本机根本没有真实加密能力 —— 已实测确认 DevEco 预览器的 cryptoFramework
      // 六个接口全是 mock 实现（返回空、不报错），此时解密无解。
      // 与其让整个应用打不开（预览器里 http 是好的，除加密外都能跑通），
      // 不如回退到内置快照继续运行。**不写缓存**，避免污染真机上的正常结果。
      Logger.error(`本机加密不可用，回退内置配置快照（快照日期 ${Constants.FALLBACK_SNAPSHOT_DATE}）：${kat}`);
      Logger.error('若在 DevEco 预览器中运行，这是预期行为（预览器不提供真实加密能力）；'
        + '请在模拟器或真机上验证加密链路。');
      return ConfigRepository.loadFallback();
    }

    // 解密（AES-256-CBC / PKCS7 / Hex 密文）
    let plain: string = '';
    try {
      plain = Cipher.decryptHex(file.domainConfig);
    } catch (e) {
      throw new NetError(NetErrorKind.Parse,
        `${Logger.errText(e)}；密文 ${file.domainConfig.length} 字符，响应 ${raw.body.length} 字节，AES 自检=OK，范式=${Cipher.lastPath}`);
    }

    let cfg: DomainConfig;
    try {
      cfg = JSON.parse(plain) as DomainConfig;
    } catch (e) {
      throw new NetError(NetErrorKind.Parse,
        `domainConfig 解密后不是合法 JSON: ${plain.substring(0, 120)}`);
    }
    if (cfg.csrkKey === undefined || cfg.csrkKey.length === 0) {
      throw new NetError(NetErrorKind.Parse, '解密结果缺少 csrkKey');
    }

    ConfigRepository.writeCache(cfg);
    Logger.tag('Config', `解密成功 csrkKey=${cfg.csrkKey} aiAnalyseIp=${cfg.aiAnalyseIp} generalEduIp="${cfg.generalEduIp}"`);
    return cfg;
  }

  /** 本机 AES 已知答案自检结果，只跑一次。 */
  private static kat: string = '';

  /** 是否因本机加密不可用而使用了内置快照（供界面提示）。 */
  static usedFallback: boolean = false;

  /**
   * 内置配置快照：本机无真实加密能力时的降级方案。
   *
   * 内容取自 2026-09-14 对 ustb.smartclass.cn 的实测解密结果。
   * 刻意**不写缓存** —— 缓存是给真机走的正常路径用的，
   * 在里面塞一份降级数据会让后续判断（缓存年龄、是否过期）全部失真。
   */
  static loadFallback(): DomainConfig {
    ConfigRepository.usedFallback = true;
    const cfg: DomainConfig = {
      csrkKey: Constants.FALLBACK_CSRK_KEY,
      aiAnalyseIp: Constants.FALLBACK_AI_ANALYSE_IP,
      generalEduIp: Constants.FALLBACK_GENERAL_EDU_IP,
      Ip: Constants.FALLBACK_IP
    };
    return cfg;
  }

  private static katVerdict(): string {
    if (ConfigRepository.kat.length === 0) {
      ConfigRepository.kat = Cipher.selfTest();
      Logger.tag('Config', `AES KAT 自检 = ${ConfigRepository.kat}（范式 ${Cipher.lastPath}）`);
    }
    return ConfigRepository.kat;
  }

  private static writeCache(cfg: DomainConfig): void {
    Prefs.putString(Constants.KEY_DOMAIN_CONFIG, JSON.stringify(cfg));
    Prefs.putNumber(Constants.KEY_DOMAIN_TS, new Date().getTime());
  }

  /**
   * 端到端自检：把解出的明文重新加密回 Hex，应与线上密文逐字节一致。
   *
   * 这比 `katVerdict()`（离线已知答案）强一档 —— KAT 验的是「本机加密调用能不能
   * 用」，这里验的是「本机解出来的东西跟站点发的是不是同一份」。它是加密链路
   * 唯一能拿到的确证（设备端实测过 `HEX_MATCH=true`）。
   *
   * ⚠️ **当前没有界面入口**：关于页的「网络自检」已按要求移除。这个方法保留下来
   *    是因为它只在这一个地方验证得出来，删了下次换设备就要从头再写一遍。
   *    需要时在 `Index.aboutToAppear()` 里临时 `await ConfigRepository.selfCheck(...)`
   *    看 hilog 即可 —— 注意它比 KAT 多一次真实的 config.json 请求，别留在正式路径上。
   */
  static async selfCheck(http: HttpClient): Promise<boolean> {
    const raw: RawResult = await http.getSiteRaw(Constants.PATH_CONFIG, false);
    const file: RawConfigFile = JSON.parse(raw.body) as RawConfigFile;
    const plain: string = Cipher.decryptHex(file.domainConfig);
    const reEncrypted: string = Cipher.encryptToHex(plain);
    const match: boolean = reEncrypted === file.domainConfig;
    Logger.tag('Config', `AES 自检 HEX_MATCH=${match}`);
    return match;
  }
}
