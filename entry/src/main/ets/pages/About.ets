import { pasteboard } from '@kit.BasicServicesKit';
import { bundleManager } from '@kit.AbilityKit';
import { Logger } from '../common/Logger';

/** 用于展示的来源页面地址。改这里时同步改 about_source_url 字符串资源。 */
const SOURCE_URL: string = 'https://ustb.smartclass.cn/ustb/Classroom.aspx';

/**
 * 关于页。
 *
 * 这里承担的不是「版权页」式的装饰，而是两件**必须让用户知道**的事：
 *  1. 这不是学校官方应用（合规声明）—— 用户有权在第一时间知道数据从哪来；
 *  2. 数据可能不准、可能延迟，以学校官方渠道为准（免责说明）。
 */
@Entry
@Component
struct About {
  @State appVersion: string = '';

  aboutToAppear(): void {
    this.readVersion();
  }

  build() {
    Column() {
      this.Header()

      Scroll() {
        Column({ space: 12 }) {
          this.Identity()
          this.Compliance()
          this.DataSource()
          this.Disclaimer()
          Text($r('app.string.about_footer'))
            .fontSize(11)
            .fontColor($r('app.color.text_hint'))
            .textAlign(TextAlign.Center)
            .width('100%')
            .padding({ top: 8, bottom: 20 })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 16, right: 16, bottom: 8 })
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
      .align(Alignment.TopStart)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
  }

  @Builder
  Header() {
    Row({ space: 8 }) {
      Text($r('app.string.action_back'))
        .fontSize(14)
        .fontColor($r('app.color.brand_text'))
        .padding({ right: 10, top: 10, bottom: 10 })
        .onClick(() => this.getUIContext().getRouter().back())
      Text($r('app.string.about_title'))
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
      Blank()
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 4 })
  }

  @Builder
  Identity() {
    Column({ space: 4 }) {
      Text($r('app.string.app_title'))
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
      // 同 RoomCard：$r() 不能进模板串，否则渲染成 "[object Object]"
      Text() {
        Span($r('app.string.about_version'))
        Span(` ${this.appVersion.length > 0 ? this.appVersion : '—'}`)
      }
        .fontSize(13)
        .fontColor($r('app.color.text_hint'))
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  /** 合规声明。措辞不要软化 —— 这是用户判断"能不能信这个应用"的唯一依据。 */
  @Builder
  Compliance() {
    Text($r('app.string.about_compliance'))
      .fontSize(13)
      .lineHeight(21)
      .fontColor($r('app.color.text_primary'))
      .width('100%')
      .padding(12)
      .borderRadius(8)
      .backgroundColor($r('app.color.brand_light'))
  }

  @Builder
  DataSource() {
    Column({ space: 6 }) {
      Text($r('app.string.about_data_source'))
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')

      Row({ space: 8 }) {
        Text($r('app.string.about_source_url'))
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
          .layoutWeight(1)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text($r('app.string.about_action_copy'))
          .fontSize(12)
          .fontColor($r('app.color.brand_text'))
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .onClick(() => this.copySource())
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding(12)
      .borderRadius(8)
      .backgroundColor($r('app.color.surface_alt'))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  Disclaimer() {
    Column({ space: 6 }) {
      Text($r('app.string.about_disclaimer_title'))
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      Text($r('app.string.about_disclaimer'))
        .fontSize(13)
        .lineHeight(21)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      Text($r('app.string.about_build_note'))
        .fontSize(12)
        .fontColor($r('app.color.text_hint'))
        .width('100%')
        .padding({ top: 2 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // ---------------------------------------------------------------- 内部

  private copySource(): void {
    try {
      const data: pasteboard.PasteData =
        pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, SOURCE_URL);
      pasteboard.getSystemPasteboard().setDataSync(data);
      this.getUIContext().getPromptAction().showToast({
        message: $r('app.string.about_copied')
      });
    } catch (e) {
      Logger.warn(`复制来源链接失败: ${Logger.errText(e)}`);
    }
  }

  private readVersion(): void {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      this.appVersion = info.versionName;
    } catch (e) {
      Logger.warn(`读取版本号失败: ${Logger.errText(e)}`);
    }
  }
}
