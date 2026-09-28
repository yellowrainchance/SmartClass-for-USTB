import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Constants } from '../common/Constants';
import { Logger } from '../common/Logger';

/**
 * preferences 的薄封装。
 *
 * 只存三类东西：解密后的域名配置、校时差、用户上次的筛选选择。
 * 读写都是同步的（数据量极小），落盘走 flush() 异步，失败不影响功能。
 */
export class Prefs {
  private static store: preferences.Preferences | null = null;

  static async init(context: common.Context): Promise<void> {
    if (Prefs.store !== null) {
      return;
    }
    const options: preferences.Options = { name: Constants.PREF_STORE };
    Prefs.store = await preferences.getPreferences(context, options);
    Logger.tag('Prefs', '初始化完成');
  }

  static isReady(): boolean {
    return Prefs.store !== null;
  }

  static getString(key: string, def: string = ''): string {
    if (Prefs.store === null) {
      return def;
    }
    try {
      const v: preferences.ValueType = Prefs.store.getSync(key, def);
      return typeof v === 'string' ? v as string : def;
    } catch (e) {
      Logger.warn(`读 ${key} 失败: ${Logger.errText(e)}`);
      return def;
    }
  }

  static putString(key: string, value: string): void {
    if (Prefs.store === null) {
      return;
    }
    try {
      Prefs.store.putSync(key, value);
      Prefs.flush();
    } catch (e) {
      Logger.warn(`写 ${key} 失败: ${Logger.errText(e)}`);
    }
  }

  static getNumber(key: string, def: number): number {
    if (Prefs.store === null) {
      return def;
    }
    try {
      const v: preferences.ValueType = Prefs.store.getSync(key, def);
      return typeof v === 'number' ? v as number : def;
    } catch (e) {
      Logger.warn(`读 ${key} 失败: ${Logger.errText(e)}`);
      return def;
    }
  }

  static putNumber(key: string, value: number): void {
    if (Prefs.store === null) {
      return;
    }
    try {
      Prefs.store.putSync(key, value);
      Prefs.flush();
    } catch (e) {
      Logger.warn(`写 ${key} 失败: ${Logger.errText(e)}`);
    }
  }

  private static flush(): void {
    if (Prefs.store === null) {
      return;
    }
    Prefs.store.flush().catch((e: Object) => {
      Logger.warn(`flush 失败: ${Logger.errText(e)}`);
    });
  }
}
