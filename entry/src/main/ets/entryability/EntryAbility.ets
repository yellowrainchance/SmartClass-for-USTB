import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../common/Logger';
import { AppSession, BootResult } from '../service/AppSession';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    Logger.tag('Ability', 'onCreate');

    // 把上下文交给会话层，并在首页出现前就开始引导：
    // 有缓存则立刻可用，无缓存则尽早开始拉 config.json。
    AppSession.get().attach(this.context);
    AppSession.get().boot()
      .then((r: BootResult) => {
        Logger.tag('Ability', `引导${r.ok ? '成功' : '失败'} fromCache=${r.fromCache}`);
      })
      .catch((e: Object) => {
        Logger.error(`引导异常: ${Logger.errText(e)}`);
      });
  }

  onDestroy(): void {
    Logger.tag('Ability', 'onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    Logger.tag('Ability', 'onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err.code) {
        Logger.error(`加载首页失败: ${JSON.stringify(err)}`);
        return;
      }
      Logger.tag('Ability', '首页加载完成');
    });

    // 跟随系统深浅色，不强制覆盖
    try {
      this.context.getApplicationContext()
        .setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (e) {
      Logger.error(`设置颜色模式失败: ${Logger.errText(e)}`);
    }
  }

  onWindowStageDestroy(): void {
    Logger.tag('Ability', 'onWindowStageDestroy');
  }

  onForeground(): void {
    Logger.tag('Ability', 'onForeground');
  }

  onBackground(): void {
    Logger.tag('Ability', 'onBackground');
  }
}
