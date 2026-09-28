import { bundleManager } from '@kit.AbilityKit';
import { Constants } from '../common/Constants';
import { Logger } from '../common/Logger';
import { TimeUtil } from '../common/TimeUtil';
import { DisplayGroup, RoomView } from '../model/DomainTypes';
import { CardState, LoadState, TimeSlotId } from '../model/Enums';
import { Prefs } from '../store/Prefs';
import { ClassroomViewModel } from '../viewmodel/ClassroomViewModel';
import { RoomCard } from '../view/RoomCard';
import { StateView } from '../view/StateView';
import { stateColor, stateLabel } from '../view/StateStyle';

interface SlotOption {
  id: TimeSlotId;
  /** 文案走 string.json（与 ViewModel.timeSlotLabel 同一份），view 里不再写字面量 */
  label: ResourceStr;
}

/**
 * 首页：筛选栏 + 按节次分组的长列表。
 *
 * 布局要点：
 *  - 节次头吸顶（List 的 sticky），当前时段那组自动滚动定位；
 *  - 教室卡片用 GridRow 断点自适应：xs 1 列 / sm 2 列 / md 4 列 / lg 6 列。
 *    原网页是写死的 `calc((100% - 130px) / 15)` 十五列，在手机上必然挤压截断；
 *    这里是本项目相对原站最主要的体验改进。
 *  - 状态用「颜色 + 文字标签」双编码，不依赖颜色单一通道。
 */
@Entry
@Component
struct Index {
  @State vm: ClassroomViewModel = new ClassroomViewModel();
  @State appVersion: string = '';
  /** 下拉刷新控件自己的状态（Refresh 需要双向绑定的布尔量） */
  @State refreshing: boolean = false;

  private timerId: number = -1;
  private listScroller: Scroller = new Scroller();
  /** 是否已做过「定位到当前节次」。只做一次，否则每次刷新都会把用户拽走。 */
  private located: boolean = false;

  aboutToAppear(): void {
    this.readVersion();
    this.vm.tickClock();
    this.startClock();
    this.vm.init()
      .then(() => {
        // Prefs 在引导过程中初始化，合规声明要等它可用之后才能判断"是否已弹过"
        this.maybeShowCompliance();
        this.autoLocateCurrent();
      })
      .catch((e: Object) => {
        Logger.error(`初始化异常: ${Logger.errText(e)}`);
      });
  }

  aboutToDisappear(): void {
    this.stopClock();
    this.vm.stopRealtime();
  }

  onPageShow(): void {
    this.startClock();
    this.vm.tickClock();
    // 实时通道只在页面可见时存在：后台常驻连接既耗电又无意义
    this.vm.startRealtime();
  }

  onPageHide(): void {
    this.stopClock();
    this.vm.stopRealtime();
  }

  build() {
    Column() {
      this.Header()
      this.FilterBar()
      this.Content()
      this.Footer()
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
  }

  // ================================================================ 顶部

  /**
   * 数据日期标题 —— 对齐原站的 `<span class="q-dt">`。
   *
   * 原站默认写「今日无课教室」，改日期后由 `GetDailyReport()` 覆写成
   * 「2026-09-15无课教室」。这个标题看着不起眼，却是**界面上唯一能确认
   * 「这屏是哪天的数据」的地方** —— 少了它，切日期有没有生效完全不可见，
   * 会被直接误判成「切日期没用、服务器不给别的日期的数据」。
   *
   * 用 `Span` 拼资源：`$r()` 返回 Resource 对象，一旦进模板串就会渲染成
   * `[object Object]`（本项目已经栽过一次，见 `verify-logic.js` 的全仓扫描）。
   * 日期用 `this.vm.dateStr` 原样显示（YYYY-MM-DD，与原站的 dateFmt 一致）。
   */
  @Builder
  Headline() {
    Text() {
      if (this.vm.isViewingToday()) {
        Span($r('app.string.headline_today'))
      } else {
        Span(this.vm.dateStr)
        Span(' ')
        Span($r('app.string.app_title'))
      }
    }
    .fontSize(20)
    .fontWeight(FontWeight.Bold)
    .fontColor($r('app.color.text_primary'))
  }

  @Builder
  Header() {
    Row() {
      Column({ space: 2 }) {
        this.Headline()
        Text(this.vm.clockText.length > 0 ? this.vm.clockText : ' ')
          .fontSize(12)
          .fontColor($r('app.color.text_hint'))
      }
      .alignItems(HorizontalAlign.Start)

      Blank()

      if (this.vm.loadState === LoadState.Loading) {
        LoadingProgress().width(20).height(20).color($r('app.color.brand'))
          .margin({ right: 14 })
      } else {
        Text($r('app.string.action_refresh'))
          .fontSize(14)
          .fontColor($r('app.color.brand_text'))
          .padding({ left: 12, right: 12, top: 10, bottom: 10 })
          .onClick(() => this.refresh())
      }

      Text($r('app.string.action_about'))
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
        .onClick(() => this.openAbout())
    }
    .width('100%')
    .padding({ left: 16, right: 6, top: 10, bottom: 4 })
  }

  // ================================================================ 筛选栏

  @Builder
  FilterBar() {
    Column({ space: 8 }) {
      // 第 1 行：教学楼 + 日期
      Row({ space: 8 }) {
        Select(this.buildingOptions())
          .selected(this.vm.buildingIndex)
          .value(this.buildingLabel())
          .enabled(this.vm.buildings.length > 0)
          .font({ size: 14 })
          .optionFont({ size: 14 })
          .layoutWeight(1)
          .onSelect((index: number) => {
            this.vm.selectBuilding(index).catch((e: Object) => this.onActionError(e));
          })

        // 日期只在「按时间段」模式下有效（「按节次」接口没有日期参数）。
        // 不能用就置灰 + 点击给解释 —— 不再替用户自动切模式。
        //
        // 置灰的做法是**虚线边框 + 次级文字色**，不是整体降透明度：这一格上的日期
        // 是"这屏数据是哪天"的唯一凭据（上一轮特意加的），压暗它等于把这个凭据也废掉。
        Row({ space: 4 }) {
          Text(this.vm.dateStr)
            .fontSize(14)
            .fontColor(this.vm.canPickDate
              ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
        }
        .height(36)
        .padding({ left: 12, right: 12 })
        .borderRadius(8)
        .backgroundColor($r('app.color.chip_bg'))
        .border({
          width: 1,
          color: $r('app.color.chip_border'),
          style: this.vm.canPickDate ? BorderStyle.Solid : BorderStyle.Dashed
        })
        .onClick(() => {
          if (this.vm.canPickDate) {
            this.pickDate();
          } else {
            this.toast($r('app.string.toast_date_locked'));
          }
        })
      }
      .width('100%')

      // 第 2 行：时间段。横向可滚，窄屏也不挤压
      Scroll() {
        Row({ space: 6 }) {
          ForEach(this.slotOptions(), (opt: SlotOption) => {
            Text(opt.label)
              .fontSize(13)
              .height(30)
              .padding({ left: 14, right: 14 })
              .borderRadius(15)
              .textAlign(TextAlign.Center)
              .fontColor(this.vm.timeSlot === opt.id
                ? $r('app.color.text_on_brand') : $r('app.color.text_secondary'))
              .backgroundColor(this.vm.timeSlot === opt.id
                ? $r('app.color.brand') : $r('app.color.chip_bg'))
              .onClick(() => {
                this.applyTimeSlot(opt.id);
              })
          }, (opt: SlotOption) => `slot-${opt.id}`)
        }
        .padding({ right: 8 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')

      // 第 3 行：节次。**渐进披露** —— 单校场景下节次类型通常只有一个选项，
      // 此时不显示该控件；节次选择器只在「按节次」模式下才有意义。
      if (this.vm.showNodeTypePicker || this.vm.showNodePicker) {
        Row({ space: 8 }) {
          if (this.vm.showNodeTypePicker) {
            Select(this.nodeTypeOptions())
              .selected(this.vm.nodeTypeIndex)
              .value(this.nodeTypesLabel())
              .font({ size: 13 })
              .optionFont({ size: 13 })
              .layoutWeight(1)
              .onSelect((index: number) => {
                this.vm.selectNodeType(index).catch((e: Object) => this.onActionError(e));
              })
          }
          if (this.vm.showNodePicker) {
            Select(this.nodeOptions())
              .selected(this.vm.nodeIndex)
              .value(this.nodeLabel())
              .font({ size: 13 })
              .optionFont({ size: 13 })
              .layoutWeight(1)
              .onSelect((index: number) => {
                this.vm.selectNode(index).catch((e: Object) => this.onActionError(e));
              })
          }
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 10 })
  }

  // ================================================================ 内容

  @Builder
  Content() {
    if (this.vm.groups.length > 0 && this.vm.loadState !== LoadState.Error) {
      // 下拉刷新挂在 List 外面。Refresh 的手势需要子节点处于滚动起始位置，
      // 直接包 List 是最稳的用法。
      Refresh({ refreshing: $$this.refreshing }) {
        this.GroupList()
      }
      .layoutWeight(1)
      .width('100%')
      .onRefreshing(() => {
        this.doRefresh();
      })
    } else if (this.vm.loadState === LoadState.Empty || this.vm.loadState === LoadState.Error) {
      StateView({
        state: this.vm.loadState,
        message: this.vm.errorMsg,
        onRetry: () => this.refresh()
      })
    } else {
      StateView({ state: LoadState.Loading, message: '' })
    }
  }

  @Builder
  GroupList() {
    List({ scroller: this.listScroller }) {
      // ⚠️ 键值决定刷新，不是随手加的。ArkUI 的 ForEach 在非首次渲染时：键值已存在
      // 就**直接复用上次那个组件实例，不会再执行一次 itemGenerator**，于是 @Prop
      // 不会被重新赋值 —— 键值不变 = 界面冻结在第一次渲染的内容上。
      //
      // 这里曾经只用 `g.key`（= 节次 id）当键值，而节次 id 与楼栋/日期无关：换楼栋
      // 后 6 个键值一模一样，整棵列表子树被原样复用，表现就是「选什么楼都是同一批
      // 教室」。所以键值必须把**所有影响渲染的东西**都包进来：
      //   · g.key  —— 数据身份（dataRev|节次，见 ClassroomViewModel.groupKeyOf）
      //   · g.state —— 组的配色/状态标签，跨节次边界时要跟着变
      //   · g.rev  —— 本组被实时推送改过几次。少了它，推送改的是组内某个教室的
      //               seatText、组键值却原封不动，组内那层 ForEach 不会被重新求值，
      //               界面上的数字就永远不动（"推送到了但没反应"）。
      ForEach(this.vm.groups, (g: DisplayGroup) => {
        ListItemGroup({ header: this.SectionHeader(g) }) {
          ListItem() {
            Column() {
              GridRow({
                columns: { xs: 1, sm: 2, md: 4, lg: 6 },
                gutter: { x: 8, y: 8 },
                breakpoints: {
                  value: ['320vp', '600vp', '840vp'],
                  reference: BreakpointsReference.WindowSize
                }
              }) {
                ForEach(g.rooms, (room: RoomView) => {
                  GridCol({ span: 1 }) {
                    RoomCard({
                      roomName: room.classroomName,
                      seatText: room.seatText,
                      cardState: g.state
                    })
                  }
                }, (room: RoomView) => `${g.key}|${room.classroomId}|${room.seatText}`)
              }
              .width('100%')
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 4, bottom: 12 })
          }
        }
      }, (g: DisplayGroup) => `${g.key}|${g.state}|${g.rev}`)
    }
    .sticky(StickyStyle.Header)
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  /** 吸顶的节次头：状态色条 + 节次名 + 时间 + 状态标签 + 空闲间数。 */
  @Builder
  SectionHeader(g: DisplayGroup) {
    Row({ space: 8 }) {
      // 状态色条（颜色通道）
      Row()
        .width(4)
        .height(18)
        .borderRadius(2)
        .backgroundColor(stateColor(g.state))

      Text(g.title)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))

      Text(g.timeText)
        .fontSize(12)
        .fontColor($r('app.color.text_hint'))

      Blank()

      // 状态文字标签（文字通道，保证不依赖颜色也能分辨）
      if (g.showStateLabel) {
        Text(stateLabel(g.state))
          .fontSize(11)
          .height(20)
          .padding({ left: 7, right: 7 })
          .borderRadius(4)
          .textAlign(TextAlign.Center)
          .fontColor($r('app.color.text_on_brand'))
          .backgroundColor(stateColor(g.state))
      }

      // 数字与单位分两条 Span：单位是文案，走资源；数字是数据，走字符串。
      // 顺带说明为什么不写成 `Text(`${n}间空闲`)` —— 那样就把文案硬编码进了视图层，
      // 与「文案全部收在 string.json」的约定不一致。
      Text() {
        Span(`${g.rooms.length} `)
        Span($r('app.string.label_room_unit'))
      }
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .height(42)
    .padding({ left: 16, right: 16 })
    .backgroundColor($r('app.color.page_bg'))
  }

  // ================================================================ 底部

  @Builder
  Footer() {
    Column({ space: 2 }) {
      // 弱网/刷新失败但仍有旧数据：一条非阻塞的提示，不动列表本身
      if (this.vm.noticeMsg.length > 0) {
        Text(this.vm.noticeMsg)
          .fontSize(11)
          .fontColor($r('app.color.room_next'))
          .textAlign(TextAlign.Center)
          .width('100%')
          .maxLines(2)
      }
      if (!this.vm.realtimeAvailable) {
        Text($r('app.string.ws_unavailable'))
          .fontSize(11)
          .fontColor($r('app.color.room_next'))
      }
      // 本机没有真实加密能力（预览器），csrkKey 走的是内置快照。
      // 数据本身仍是真的（同一套线上接口），但站点轮换密钥后 token 会被拒 ——
      // 降级不该是静默的，所以这里明说。
      if (this.vm.degradedConfig) {
        Text($r('app.string.notice_degraded_config'))
          .fontSize(11)
          .fontColor($r('app.color.room_next'))
          .textAlign(TextAlign.Center)
          .width('100%')
          .maxLines(2)
      }
      Row({ space: 8 }) {
        Text(this.footerText())
          .fontSize(11)
          .fontColor($r('app.color.text_hint'))
          .layoutWeight(1)
        // 首屏会自动定位到当前节次；之后用户滚走了，用这个按钮找回来
        if (this.vm.currentGroupIndex() > 0) {
          Text($r('app.string.action_locate'))
            .fontSize(11)
            .fontColor($r('app.color.brand_text'))
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .onClick(() => this.scrollToGroup(this.vm.currentGroupIndex()))
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 4, bottom: 8 })
  }

  private footerText(): string {
    const total: number = this.vm.totalRooms;
    const ver: string = this.appVersion.length > 0 ? ` · v${this.appVersion}` : '';
    return total > 0
      ? `${this.vm.currentBuildingName} · 共 ${total} 间空闲 · 数据来自学校公开页面${ver}`
      : `数据来自学校公开页面${ver}`;
  }

  // ================================================================ 交互

  private refresh(): void {
    this.vm.reload().catch((e: Object) => this.onActionError(e));
  }

  /**
   * 切换时间段。
   *
   * 只有一件事需要在这里处理：从「看别的日期」切回「按节次」时，日期会被拉回今天
   * （那个接口只反映当前时刻，详见 `ClassroomViewModel.selectTimeSlot`）。
   * 日期控件本身会跟着变，但如果不同时说明一句，用户看到的就是"日期自己跳了"。
   */
  private applyTimeSlot(slot: TimeSlotId): void {
    const hadOtherDate: boolean = !this.vm.isViewingToday();
    this.vm.selectTimeSlot(slot)
      .then(() => {
        if (slot === TimeSlotId.ByNode && hadOtherDate) {
          this.toast($r('app.string.toast_date_reset'));
        }
      })
      .catch((e: Object) => this.onActionError(e));
  }

  private toast(message: ResourceStr): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2600 });
    } catch (e) {
      Logger.warn(`提示弹窗失败: ${Logger.errText(e)}`);
    }
  }

  /** 下拉刷新：手要负责把 refreshing 复位，否则转圈不会停。 */
  private doRefresh(): void {
    this.vm.reload()
      .then(() => {
        this.refreshing = false;
      })
      .catch((e: Object) => {
        this.onActionError(e);
        this.refreshing = false;
      });
  }

  /**
   * 首次拿到数据后，把列表滚到「当前节次」那一组。
   *
   * 一天里大部分节次已经过去，列表默认从第一大节开始 —— 不定位的话，
   * 学生每次打开都要先往下翻好几屏才能看到「现在」。只做一次，
   * 之后的刷新不再自动滚动（否则等于把正在看的用户拽走）。
   */
  private autoLocateCurrent(): void {
    if (this.located) {
      return;
    }
    this.located = true;
    const idx: number = this.vm.currentGroupIndex();
    if (idx > 0) {
      this.scrollToGroup(idx);
    }
  }

  private scrollToGroup(index: number): void {
    if (index < 0) {
      return;
    }
    // 数据刚落到 @State 上，列表还没完成布局，等一帧再滚
    setTimeout(() => {
      try {
        this.listScroller.scrollToIndex(index, true, ScrollAlign.START);
      } catch (e) {
        Logger.warn(`定位到第 ${index} 个分组失败: ${Logger.errText(e)}`);
      }
    }, 150);
  }

  private onActionError(e: Object): void {
    Logger.error(`操作失败: ${Logger.errText(e)}`);
  }

  private pickDate(): void {
    const now: Date = new Date();
    // 用 UIContext 上的版本：DatePickerDialog.show 自 API 18 起已废弃
    this.getUIContext().showDatePickerDialog({
      start: new Date(2020, 0, 1),
      end: new Date(2035, 11, 31),
      selected: this.parseDate(this.vm.dateStr, now),
      onDateAccept: (value: Date) => {
        this.vm.selectDate(TimeUtil.formatDate(value))
          .catch((e: Object) => this.onActionError(e));
      }
    });
  }

  private parseDate(s: string, fallback: Date): Date {
    const parts: string[] = s.split('-');
    if (parts.length !== 3) {
      return fallback;
    }
    const y: number = Number.parseInt(parts[0], 10);
    const m: number = Number.parseInt(parts[1], 10);
    const d: number = Number.parseInt(parts[2], 10);
    if (Number.isNaN(y) || Number.isNaN(m) || Number.isNaN(d)) {
      return fallback;
    }
    return new Date(y, m - 1, d);
  }

  private openAbout(): void {
    this.getUIContext().getRouter().pushUrl({ url: 'pages/About' })
      .catch((e: Object) => {
        Logger.error(`打开关于页失败: ${Logger.errText(e)}`);
      });
  }

  /**
   * 首次启动时把合规声明摆到用户面前，只弹一次。
   *
   * 不做成那种「必须点同意才能用」的启动门槛 —— 本应用不涉及账号、不收集个人信息，
   * 强制同意只是无谓的摩擦。但也绝不能只在关于页里埋一段没人会看的文字：
   * 用户有权在第一次看到数据的同时就知道它从哪来。
   */
  private maybeShowCompliance(): void {
    if (Prefs.getNumber(Constants.KEY_ACK_COMPLIANCE, 0) === 1) {
      return;
    }
    Prefs.putNumber(Constants.KEY_ACK_COMPLIANCE, 1);
    this.getUIContext().showAlertDialog({
      title: $r('app.string.about_title'),
      message: $r('app.string.about_compliance'),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      confirm: {
        value: $r('app.string.action_known'),
        action: () => {
          this.openAbout();
        }
      }
    });
  }

  private startClock(): void {
    if (this.timerId !== -1) {
      return;
    }
    this.timerId = setInterval(() => {
      this.vm.tickClock();
    }, 1000);
  }

  private stopClock(): void {
    if (this.timerId !== -1) {
      clearInterval(this.timerId);
      this.timerId = -1;
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

  // ================================================================ 选项构造

  /**
   * 教学楼选择器的显示文案。
   *
   * 引导失败时 buildings 为空，若直接把楼名绑上去，Select 会渲染成一个**空白下拉框** ——
   * 用户看到两个空控件，既不知道是什么也不知道为什么空。给一句能读懂的兜底文案。
   */
  private buildingLabel(): ResourceStr {
    const name: string = this.vm.currentBuildingName;
    if (name.length > 0) {
      return name;
    }
    return this.vm.loadState === LoadState.Loading
      ? $r('app.string.filter_building_hint')
      : $r('app.string.filter_building_empty');
  }

  private buildingOptions(): SelectOption[] {
    const out: SelectOption[] = [];
    for (const b of this.vm.buildings) {
      out.push({ value: b.name });
    }
    return out;
  }

  private nodeTypeOptions(): SelectOption[] {
    const out: SelectOption[] = [];
    for (const t of this.vm.nodeTypes) {
      out.push({ value: t.name });
    }
    return out;
  }

  private nodeOptions(): SelectOption[] {
    const out: SelectOption[] = [];
    for (const label of this.vm.nodeOptionLabels()) {
      out.push({ value: label });
    }
    return out;
  }

  private nodeTypesLabel(): string {
    const i: number = this.vm.nodeTypeIndex;
    return i >= 0 && i < this.vm.nodeTypes.length ? this.vm.nodeTypes[i].name : '';
  }

  private nodeLabel(): ResourceStr {
    const labels: ResourceStr[] = this.vm.nodeOptionLabels();
    const i: number = this.vm.nodeIndex;
    return i >= 0 && i < labels.length ? labels[i] : '';
  }

  private slotOptions(): SlotOption[] {
    return [
      { id: TimeSlotId.ByNode, label: $r('app.string.time_by_node') },
      { id: TimeSlotId.AllDay, label: $r('app.string.time_all') },
      { id: TimeSlotId.Morning, label: $r('app.string.time_morning') },
      { id: TimeSlotId.Afternoon, label: $r('app.string.time_afternoon') },
      { id: TimeSlotId.Evening, label: $r('app.string.time_evening') }
    ];
  }
}
