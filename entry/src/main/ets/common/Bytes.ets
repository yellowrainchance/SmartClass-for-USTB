import { buffer } from '@kit.ArkTS';

/**
 * 字节 / 十六进制 / 编码转换工具。
 *
 * 注意：不要用 `new Uint8Array(buffer.from(s,'utf-8').buffer)` 这种写法取密钥字节——
 * Buffer 可能来自共享内存池，其 .buffer 长度会大于字符串实际长度。密钥长度必须精确，
 * 所以 ASCII 场景一律走 asciiToBytes()。
 */

/** 十六进制字符串 → 字节数组。非法字符（如空格）会被跳过，长度按字符数向下取整。 */
export function hexToBytes(hex: string): Uint8Array {
  const clean: string = hex.trim();
  const len: number = Math.floor(clean.length / 2);
  const out: Uint8Array = new Uint8Array(len);
  for (let i = 0; i < len; i++) {
    const byteStr: string = clean.substring(i * 2, i * 2 + 2);
    const v: number = parseInt(byteStr, 16);
    out[i] = Number.isNaN(v) ? 0 : v;
  }
  return out;
}

/**
 * 统计非十六进制字符的个数。
 *
 * 用来在解密之前就分辨出「拿到的根本不是密文」——
 * 这种情况如果直接丢给 AES，会以"解密结果为空"或"填充错误"的形式暴露，
 * 报错信息完全指不到真正的原因（响应内容变了）。
 */
export function hexIllegalCount(hex: string): number {
  const clean: string = hex.trim();
  let bad: number = 0;
  for (let i = 0; i < clean.length; i++) {
    const c: string = clean.charAt(i).toLowerCase();
    const ok: boolean = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
    if (!ok) {
      bad++;
    }
  }
  return bad;
}

/** 字节数组 → 小写十六进制字符串（主要用于测试比对）。 */
export function bytesToHex(bytes: Uint8Array): string {
  let out: string = '';
  for (let i = 0; i < bytes.length; i++) {
    const h: string = bytes[i].toString(16);
    out += h.length === 1 ? `0${h}` : h;
  }
  return out;
}

/**
 * ASCII 字符串 → 字节数组。
 * 长度与字符数严格一致，适合 AES 密钥/IV 这类对长度敏感的场合。
 */
export function asciiToBytes(s: string): Uint8Array {
  const out: Uint8Array = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) {
    out[i] = s.charCodeAt(i) & 0xff;
  }
  return out;
}

/** UTF-8 字符串 → 字节数组（长度精确，逐字节读取，不受 Buffer 内存池影响）。 */
export function utf8ToBytes(s: string): Uint8Array {
  const b = buffer.from(s, 'utf-8');
  const out: Uint8Array = new Uint8Array(b.length);
  for (let i = 0; i < b.length; i++) {
    out[i] = b.readUInt8(i);
  }
  return out;
}

/** 字节数组 → UTF-8 字符串。 */
export function bytesToUtf8(bytes: Uint8Array): string {
  return buffer.from(bytes).toString('utf-8');
}
