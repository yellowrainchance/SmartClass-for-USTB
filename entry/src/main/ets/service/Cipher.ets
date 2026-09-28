import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { Constants } from '../common/Constants';
import { Logger } from '../common/Logger';
import { asciiToBytes, bytesToHex, bytesToUtf8, hexIllegalCount, hexToBytes, utf8ToBytes } from '../common/Bytes';

/**
 * config.json 的加解密。
 *
 * 站点用 AES-256-CBC / PKCS7，密文是 Hex，明文是 UTF-8 JSON。
 * 参数已用 Node 原生 crypto 正反双向复核（见 `参考网站/探测脚本/verify_aes.js`，
 * 反向加密得到的 Hex 与原密文逐字节一致）。
 *
 * ## 关于「解密为空」
 *
 * 实测在 **DevEco 预览器**里，cryptoFramework 的六个接口全部是 mock 实现：
 *
 *   W A03d00/JSAPP: The createSymKeyGenerator interface in the previewer is a
 *                   mocked implementation and may behave differently than on a real device.
 *   （createSymKeyGenerator / convertKeySync / createCipher / initSync / updateSync / doFinalSync 各一条）
 *
 * mock 不报错、不抛异常，只是**返回空**。所以「解密为空」至少有三种完全不同的成因：
 *   a) 运行环境不提供真实加密能力（预览器）—— 预期行为，不是 bug；
 *   b) 本机调用方式不对；
 *   c) 站点响应内容变了（拿到的根本不是那份密文）。
 * 三者现象一模一样。所以这里做了两件事：一是 `probe()` 逐步报告每一环的真实结果，
 * 二是不再把异常吞掉（早先版本吞掉异常后统一报「返回空」，把方向带偏过一次）。
 */

/**
 * 已知答案自检向量。
 *
 * 明文故意做成 **4 个分组**：CBC 下 `update()` 只吐整分组、余量必须由 `doFinal()` 收尾，
 * 单分组向量区分不出这个差异 —— 而官方短数据示例恰好只用了 1 个分组。
 * 这一对值由 `tools/verify-logic.js` 用同一套密钥离线算出并断言，
 * 改密钥就必须同步重算，否则自检会失败。
 */
const KAT_PLAIN: string = 'SmartClassKAT-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ';
const KAT_CIPHER_HEX: string =
  '36345d496a9daef95f2b9489ae5ea76093cd8365f801448d68b8f8a80c1f2694' +
  'e1e0de632a5582740b081aa9a0e27105e0f5ecf29c5c0af6cd51441035456748';

/** 一次尝试的结果。失败时**保留真实异常文本**，不再吞掉。 */
interface AttemptResult {
  bytes: Uint8Array | null;
  error: string;
}

/** 两条范式合起来的结论。 */
interface TransformResult {
  bytes: Uint8Array | null;
  /** 生效的调用范式：'update+doFinal' / 'doFinal' / 'none' */
  path: string;
  /** 两条都失败时的异常说明；成功时为空串。 */
  error: string;
}

export class Cipher {
  /** 最近一次成功的调用范式，供自检页展示（不同设备可能只吃其中一种）。 */
  static lastPath: string = '';
  /** 最近一次失败的异常说明。 */
  static lastError: string = '';

  /**
   * 本机是否具备真实（非 mock）加密能力。
   *
   * 预览器的 syscap 声明未必与真实实现一致，所以这个结果**只能作为参考**，
   * 不能单独用来判定可用性 —— `selfTest()` 才是判据。
   */
  static cryptoAvailable(): boolean {
    return Cipher.cap('SystemCapability.Security.CryptoFramework.Cipher')
      && Cipher.cap('SystemCapability.Security.CryptoFramework.Key.SymKey');
  }

  /** 解密 domainConfig（Hex 密文 → UTF-8 明文）。 */
  static decryptHex(hexCipher: string): string {
    const bytes: Uint8Array = Cipher.toCipherBytes(hexCipher);
    const r: TransformResult = Cipher.transform(cryptoFramework.CryptoMode.DECRYPT_MODE, bytes);
    Cipher.lastPath = r.path;
    Cipher.lastError = r.error;
    if (r.bytes === null || r.bytes.length === 0) {
      throw new Error(`解密未产出数据（密文 ${bytes.length} 字节；${r.error}）`);
    }
    return bytesToUtf8(r.bytes);
  }

  /**
   * 反向加密，仅用于自检。
   * 输入线上密文解出的明文，应能还原出**逐字节一致**的 Hex。
   */
  static encryptToHex(plainUtf8: string): string {
    const input: Uint8Array = utf8ToBytes(plainUtf8);
    const r: TransformResult = Cipher.transform(cryptoFramework.CryptoMode.ENCRYPT_MODE, input);
    Cipher.lastPath = r.path;
    Cipher.lastError = r.error;
    if (r.bytes === null || r.bytes.length === 0) {
      throw new Error(`加密未产出数据（${r.error}）`);
    }
    return bytesToHex(r.bytes);
  }

  /**
   * 不依赖网络的已知答案自检：本机的密钥装配、IV 装配与加解密调用方式是否真的可用。
   * 返回 'OK'，或一段能直接显示给开发者看的失败说明。
   */
  static selfTest(): string {
    try {
      const plain: string = Cipher.decryptHex(KAT_CIPHER_HEX);
      if (plain !== KAT_PLAIN) {
        return `解密结果不符（得到 "${plain}"）`;
      }
      const reHex: string = Cipher.encryptToHex(KAT_PLAIN);
      if (reHex !== KAT_CIPHER_HEX) {
        return '反向加密结果不符';
      }
      return 'OK';
    } catch (e) {
      return Logger.errText(e);
    }
  }

  /**
   * 逐步探针：把加密链路的每一环单独跑一遍并报告真实结果。
   *
   * 这是被「mock 返回空、不报错」逼出来的 —— 综合自检只会说「不行」，
   * 但说不出**卡在哪一步**。逐环报告能直接指出是 syscap 缺失、密钥装配失败、
   * 还是 init 阶段就被拒。
   *
   * ⚠️ **当前没有界面入口**（自检页已移除）。保留原因同
   *    `ConfigRepository.selfCheck()`：换设备排查时这是唯一能指出故障环节的东西。
   */
  static probe(): string[] {
    const out: string[] = [];
    out.push(`syscap CryptoFramework = ${Cipher.capText('SystemCapability.Security.CryptoFramework')}`);
    out.push(`syscap CryptoFramework.Cipher = ${Cipher.capText('SystemCapability.Security.CryptoFramework.Cipher')}`);

    // ① 密钥生成器
    let key: cryptoFramework.SymKey | null = null;
    try {
      cryptoFramework.createSymKeyGenerator(Constants.KEY_GEN_ALG);
      out.push(`① createSymKeyGenerator('${Constants.KEY_GEN_ALG}') → 成功`);
    } catch (e) {
      out.push(`① createSymKeyGenerator → 失败：${Logger.errText(e)}`);
      out.push('（后续步骤无法继续）');
      return out;
    }

    // ② 密钥装配 + 回读校验
    try {
      const gen: cryptoFramework.SymKeyGenerator =
        cryptoFramework.createSymKeyGenerator(Constants.KEY_GEN_ALG);
      key = gen.convertKeySync({ data: asciiToBytes(Constants.AES_KEY_UTF8) });
      const back: Uint8Array = key.getEncoded().data;
      const same: boolean = bytesToHex(back) === Constants.AES_KEY_UTF8;
      out.push(`② convertKeySync → 成功，密钥回读 ${back.length} 字节，与源文${same ? '一致' : '不一致'}`);
      if (!same) {
        out.push(`   回读值 ${bytesToHex(back)}`);
      }
    } catch (e) {
      out.push(`② convertKeySync → 失败：${Logger.errText(e)}`);
      return out;
    }

    // ③ createCipher
    let cipher: cryptoFramework.Cipher;
    try {
      cipher = cryptoFramework.createCipher(Constants.CIPHER_ALG);
      out.push(`③ createCipher('${Constants.CIPHER_ALG}') → 成功`);
    } catch (e) {
      out.push(`③ createCipher → 失败：${Logger.errText(e)}`);
      return out;
    }

    // ④ initSync
    const ivSpec: cryptoFramework.IvParamsSpec = {
      algName: 'IvParamsSpec',
      iv: { data: asciiToBytes(Constants.AES_IV_UTF8) }
    };
    try {
      cipher.initSync(cryptoFramework.CryptoMode.DECRYPT_MODE, key, ivSpec);
      out.push(`④ initSync(DECRYPT, key ${Constants.AES_KEY_UTF8.length} 字节, iv ${Constants.AES_IV_UTF8.length} 字节) → 成功`);
    } catch (e) {
      out.push(`④ initSync → 失败：${Logger.errText(e)}`);
      return out;
    }

    // ⑤ / ⑥ 解密一个分组，看两步各自吐多少字节
    const probeInput: Uint8Array = hexToBytes(KAT_CIPHER_HEX.substring(0, 32));
    try {
      const head: cryptoFramework.DataBlob | null = cipher.updateSync({ data: probeInput });
      const headLen: number = head === null || head.data === undefined ? -1 : head.data.length;
      out.push(`⑤ updateSync(16 字节密文) → 返回 ${headLen} 字节`);
      const tail: cryptoFramework.DataBlob | null = cipher.doFinalSync(null);
      const tailLen: number = tail === null || tail.data === undefined ? -1 : tail.data.length;
      out.push(`⑥ doFinalSync(null) → 返回 ${tailLen} 字节`);
    } catch (e) {
      out.push(`⑤⑥ 分段解密 → 失败：${Logger.errText(e)}`);
    }

    // ⑦ 综合结论
    const verdict: string = Cipher.selfTest();
    out.push(`⑦ 已知答案自检 → ${verdict}（范式 ${Cipher.lastPath}）`);
    return out;
  }

  // ------------------------------------------------------------------ 内部

  /** 密文文本 → 字节，并在源头辨明「这根本不是密文」。 */
  private static toCipherBytes(hexCipher: string): Uint8Array {
    const clean: string = hexCipher.trim();
    const illegal: number = hexIllegalCount(clean);
    if (illegal > 0 || clean.length % 2 !== 0 || clean.length < 32) {
      throw new Error(
        `不像 AES 密文（长度 ${clean.length}，非法字符 ${illegal}，开头 "${clean.substring(0, 32)}"）`);
    }
    return hexToBytes(clean);
  }

  private static cap(name: string): boolean {
    try {
      return canIUse(name);
    } catch (e) {
      return false;
    }
  }

  private static capText(name: string): string {
    try {
      return canIUse(name) ? '支持' : '不支持';
    } catch (e) {
      return `检查异常（${Logger.errText(e)}）`;
    }
  }

  /**
   * 两种官方范式各试一次，谁出结果用谁。
   *
   * cryptoFramework 的同步接口对**多分组**数据的行为在不同设备/SDK 上并不一致：
   *   范式 A：`update(data)` 取走整分组 → `doFinal(null)` 收尾并去填充（官方多分组流程）
   *   范式 B：`doFinal(data)` 一次吃下（官方同步示例，但它的范例只有 1 个分组）
   * 只写一种，就有在部分设备上拿到空结果的实测风险，所以两条都留着。
   * 哪条生效会记进 `lastPath`，自检页与报错信息都会带上。
   */
  private static transform(mode: cryptoFramework.CryptoMode,
    input: Uint8Array): TransformResult {
    const a: AttemptResult = Cipher.attempt(mode, input, true);
    if (a.bytes !== null && a.bytes.length > 0) {
      return { bytes: a.bytes, path: 'update+doFinal', error: '' };
    }
    const b: AttemptResult = Cipher.attempt(mode, input, false);
    if (b.bytes !== null && b.bytes.length > 0) {
      return { bytes: b.bytes, path: 'doFinal', error: '' };
    }
    return {
      bytes: null,
      path: 'none',
      error: `update+doFinal → ${a.error}；doFinal → ${b.error}`
    };
  }

  /**
   * 一次尝试。异常**必须带出去** —— 早先版本在这里静默返回 null，
   * 于是真实的 BusinessError 被统一显示成「返回空」，把排查方向带偏过。
   */
  private static attempt(mode: cryptoFramework.CryptoMode, input: Uint8Array,
    useUpdate: boolean): AttemptResult {
    const label: string = useUpdate ? 'update+doFinal' : 'doFinal';
    try {
      const cipher: cryptoFramework.Cipher = Cipher.createCipher(mode);
      if (!useUpdate) {
        const only: cryptoFramework.DataBlob | null = cipher.doFinalSync({ data: input });
        if (only === null || only.data === undefined) {
          return { bytes: null, error: `${label} 返回空对象` };
        }
        return { bytes: only.data, error: '' };
      }
      const head: cryptoFramework.DataBlob | null = cipher.updateSync({ data: input });
      const tail: cryptoFramework.DataBlob | null = cipher.doFinalSync(null);
      const bytes: Uint8Array = Cipher.concat(head, tail);
      if (bytes.length === 0) {
        return { bytes: null, error: `${label} 两段输出合计 0 字节` };
      }
      return { bytes: bytes, error: '' };
    } catch (e) {
      const msg: string = Logger.errText(e);
      Logger.warn(`AES ${label} 路径失败: ${msg}`);
      return { bytes: null, error: msg };
    }
  }

  /** 拼接 update 与 doFinal 的两段输出。 */
  private static concat(head: cryptoFramework.DataBlob | null,
    tail: cryptoFramework.DataBlob | null): Uint8Array {
    const hd: Uint8Array = Cipher.bytesOf(head);
    const td: Uint8Array = Cipher.bytesOf(tail);
    const out: Uint8Array = new Uint8Array(hd.length + td.length);
    out.set(hd, 0);
    out.set(td, hd.length);
    return out;
  }

  private static bytesOf(blob: cryptoFramework.DataBlob | null): Uint8Array {
    if (blob === null || blob.data === undefined) {
      return new Uint8Array(0);
    }
    return blob.data;
  }

  private static createCipher(mode: cryptoFramework.CryptoMode): cryptoFramework.Cipher {
    const keyBytes: Uint8Array = asciiToBytes(Constants.AES_KEY_UTF8);
    if (keyBytes.length !== 32) {
      throw new Error(`AES-256 密钥必须为 32 字节，当前 ${keyBytes.length} 字节`);
    }

    const symKeyBlob: cryptoFramework.DataBlob = { data: keyBytes };
    const symKey: cryptoFramework.SymKey =
      cryptoFramework.createSymKeyGenerator(Constants.KEY_GEN_ALG).convertKeySync(symKeyBlob);

    const ivSpec: cryptoFramework.IvParamsSpec = {
      algName: 'IvParamsSpec',
      iv: { data: asciiToBytes(Constants.AES_IV_UTF8) }
    };

    const cipher: cryptoFramework.Cipher = cryptoFramework.createCipher(Constants.CIPHER_ALG);
    cipher.initSync(mode, symKey, ivSpec);
    return cipher;
  }
}
