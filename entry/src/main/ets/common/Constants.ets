/**
 * 全局常量。
 *
 * ⚠️ 这里的每一个值都来自对站点的实测逆向，标准答案存放在
 *    `参考网站/探测脚本/` 下。改动前请先用脚本复核。
 */

export class Constants {
  // ---------------- 站点 ----------------

  /** 站点基址。本期仅面向北京科技大学（ustb）单校。 */
  static readonly DEFAULT_BASE: string = 'https://ustb.smartclass.cn';

  /** 页面级 Referer。实测不带也能通，带上更稳。 */
  static readonly PAGE_REFERER: string = 'https://ustb.smartclass.cn/ustb/Classroom.aspx';

  /** 站点标识，取自 hostname 首段。 */
  static readonly SCHOOL_FLAG: string = 'ustb';

  /** 站点主机（不带协议），WebSocket 同源兜底时要用。 */
  static readonly SCHOOL_HOST: string = 'ustb.smartclass.cn';

  // ---------------- 加密（AES-256-CBC / PKCS7） ----------------

  /** 32 字节 UTF-8 密钥，用于解密 config.json 的 domainConfig。 */
  static readonly AES_KEY_UTF8: string = '80bdbdbaf7494add99198960d715d41b';

  /** 16 字节 UTF-8 IV。 */
  static readonly AES_IV_UTF8: string = 'bdbaf7494add9919';

  /** cryptoFramework 的算法串。 */
  static readonly CIPHER_ALG: string = 'AES256|CBC|PKCS7';

  /** 对称密钥生成器算法（密钥长度 256 位）。 */
  static readonly KEY_GEN_ALG: string = 'AES256';

  // ---------------- 内置配置快照（降级用） ----------------

  /**
   * 内置配置快照。
   *
   * 为什么需要它：**DevEco 预览器的 cryptoFramework 全部是 mock 实现** ——
   * createSymKeyGenerator / convertKeySync / createCipher / initSync / updateSync /
   * doFinalSync 六个接口都会打日志说 "mocked implementation" 并返回空结果，
   * 于是 config.json 解不开、应用根本起不来。而预览器里 http 是**真实可用**的
   * （实测拿到了 3422 字节的真实响应），也就是说除加密之外其它都能跑通 ——
   * 为这一个环节断掉整个 UI 迭代不划算。
   *
   * 这份快照是 2026-09-14 从 ustb.smartclass.cn 实测解出的真实内容，只在
   * **解密无法进行**时启用；绝不覆盖解密成功的结果，也绝不写入缓存。
   * 启用时会打 ERROR 日志，并在界面页脚给出提示。
   *
   * `tools/verify-logic.js` 会用仓库里缓存的线上密文重新解一遍并与这里的
   * csrkKey 比对 —— 站点轮换密钥时会立刻报出来。
   */
  static readonly FALLBACK_SNAPSHOT_DATE: string = '2026-09-14';
  static readonly FALLBACK_CSRK_KEY: string = 's0k6e5a1t3i46kglaz9';
  static readonly FALLBACK_AI_ANALYSE_IP: string = 'https://attendace.smartclass.cn:9090';
  static readonly FALLBACK_GENERAL_EDU_IP: string = '';
  static readonly FALLBACK_IP: string = 'https://www.smartclass.cn:443';

  // ---------------- 接口路径 ----------------

  static readonly PATH_CONFIG: string = '/config.json';
  static readonly PATH_TIME_DIF: string = '/Home/GettimeDif';
  static readonly PATH_NODE_TYPES: string = '/general/api/open/teachingCycle/listNodeTypes';
  static readonly PATH_NODES: string = '/general/api/open/teachingCycle/listNodes';
  static readonly PATH_BUILDINGS: string = '/general/api/open/building/listBuildings';
  static readonly PATH_FREE_BY_NODE: string = '/general/api/classroom/freeClassRooms';
  static readonly PATH_FREE_BY_TIME: string = '/general/api/classroom/freeJoinClassRooms';

  /** 所有 /general/api 请求的公共前缀（当 generalEduIp 为空时走同源）。 */
  static readonly GENERAL_API_PREFIX: string = '/general/api';

  // ---------------- WebSocket ----------------

  static readonly WS_PATH: string = '/attendance/api/ws';
  static readonly WS_CHANNEL: string = 'attendance';
  /** 握手 Origin。实测服务端会校验：不带或带错，握手响应里不会有 Allow-Origin。 */
  static readonly WS_ORIGIN: string = 'https://ustb.smartclass.cn';
  /** 未登录时的匿名 schoolId，取自页面 userInfo[0].SchoolID。 */
  static readonly WS_SCHOOL_ID: number = 159;
  /**
   * setSessionUser 的 requestID。原页面**写死**成这个值，不是当前时间戳。
   * 建会话这一步保持与已知可用实现逐字节一致，没有理由去"优化"它。
   */
  static readonly WS_SESSION_REQUEST_ID: string = '1692088104704910721';
  /** 应用层心跳间隔（毫秒）。服务器用它，而不是协议层 Ping/Pong 帧。 */
  static readonly WS_PING_INTERVAL_MS: number = 10000;
  /** 断线重连初始间隔（毫秒）。 */
  static readonly WS_RECONNECT_BASE_MS: number = 3000;
  /** 重连退避上限（毫秒）。 */
  static readonly WS_RECONNECT_MAX_MS: number = 30000;
  /** 连续握手失败多少次后降级为「仅 REST + 手动刷新」。 */
  static readonly WS_FAIL_LIMIT: number = 3;
  /** 服务端实时座位推送的业务码。 */
  static readonly WS_CODE_SEAT_UPDATE: number = 4005;
  /** 会话注册成功。 */
  static readonly WS_CODE_SESSION_OK: number = 1015;
  /** 空 classRoomId 导致的良性提示，忽略即可。 */
  static readonly WS_CODE_BENIGN_PARAM: number = 1016;
  /**
   * 心跳回包。
   *
   * 服务端对我们每 10s 发一次的 `{"action":"ping"}` **不是**回裸字符串 `pong`，
   * 而是回一个 `{"code":1000,…}` 的 JSON 帧（实测，见设备 hilog）。不认识它就会
   * 每 10 秒在日志里留一条「未处理的下行帧 code=1000」，把真正的异常淹掉。
   */
  static readonly WS_CODE_PONG: number = 1000;

  // ---------------- 网络 ----------------

  static readonly CONNECT_TIMEOUT_MS: number = 10000;
  static readonly READ_TIMEOUT_MS: number = 15000;
  /** token 校验失败时自动重试的次数上限。 */
  static readonly TOKEN_RETRY_LIMIT: number = 1;

  // ---------------- 持久化 ----------------

  static readonly PREF_STORE: string = 'smartclass_prefs';
  static readonly KEY_DOMAIN_CONFIG: string = 'domain_config';
  static readonly KEY_DOMAIN_TS: string = 'domain_config_ts';
  static readonly KEY_TIME_DIF: string = 'time_dif';
  static readonly KEY_LAST_BUILDING: string = 'last_building_id';
  static readonly KEY_LAST_NODE_TYPE: string = 'last_node_type_id';
  static readonly KEY_LAST_TIME_ID: string = 'last_time_id';
  /** 是否已确认过首次启动的合规声明。1 = 已确认。 */
  static readonly KEY_ACK_COMPLIANCE: string = 'ack_compliance';

  /** 配置缓存有效期：24 小时。过期后台刷新，但**仍先用旧值**。 */
  static readonly DOMAIN_CONFIG_TTL_MS: number = 24 * 3600 * 1000;

  // ---------------- 展示白名单（逐字对齐原站） ----------------

  /**
   * 楼栋白名单（**有序**，顺序即下拉里的顺序）。
   *
   * 原站源码 `参考网站/贝壳教学-无课教室.html` 里，`schoolFlag == 'ustb'` 时
   * **把 listBuildings 的返回值整个覆盖**成这四项 —— 接口实际返回 5 栋，
   * 多出来的一个是「南楼」（`7daa6fdcb6664d03a745006e4c4e5d21`，47 间以
   * `S302`/`S303`/`S4xx` 命名的教室），原站不展示它。
   *
   * ⚠️ 立项时曾把这条判为「原站的缺陷」，理由是"接口里有、页面上却选不到"，
   *    于是刻意保留了南楼。**该判断已按用户要求撤销**：本项目的目标是忠实还原
   *    原站，不是替校方做产品决策。原站给什么就显示什么，原站不给的就不显示。
   */
  static readonly BUILDING_WHITELIST_IDS: string[] = [
    '1cd73be1e256a7405516501e94e892ac', // 教学楼
    '38af86134b65d0f10fe33d30dd76442e', // 逸夫楼
    '8d3215ae97598264ad6529613774a038', // 智慧教室
    'ef72d53990bc4805684c9b61fa64a102'  // 学院楼
  ];

  /**
   * 节次类型白名单。原站在同一处把 `sectionList` 覆盖成只剩「默认节次」一项
   * （接口实际返回「小节次」与「默认节次」两个），页面上因此没有节次类型可选。
   * 来源与楼栋白名单同一行代码，故一并处理。
   */
  static readonly NODE_TYPE_WHITELIST_IDS: string[] = [
    '49c166931e8a70ff2a57a5780dcbb892'  // 默认节次
  ];

  // ---------------- 默认筛选 ----------------

  /** 时间段枚举里的「按节次」。 */
  static readonly DEFAULT_TIME_ID: number = 4;
  /** 节次传空串表示「全部节次」，不要传 null。 */
  static readonly ALL_NODES: string = '';

  // ---------------- 业务码 ----------------

  static readonly CODE_OK: number = 0;
}

/** 服务端统一响应外壳：{ code, msg, data } */
export interface ApiEnvelope<T> {
  code: number;
  msg: string;
  data: T | null;
}

/** 解密后的域名配置（只声明本项目实际用到的字段）。 */
export interface DomainConfig {
  csrkKey: string;
  aiAnalyseIp: string;
  generalEduIp: string;
  Ip: string;
}
