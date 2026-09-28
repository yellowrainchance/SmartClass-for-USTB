import { Constants } from '../common/Constants';
import { Logger } from '../common/Logger';
import { TimeUtil } from '../common/TimeUtil';
import { BuildingDto, ClassroomItemDto, FreeRoomGroupDto, NodeDto, NodeTypeDto } from '../model/ApiTypes';
import { DisplayGroup, RoomView } from '../model/DomainTypes';
import { CardState, LoadState, SearchType, TimeSlotId } from '../model/Enums';
import { ClassroomRepository } from '../repository/ClassroomRepository';
import { ConfigRepository } from '../repository/ConfigRepository';
import { MetaRepository } from '../repository/MetaRepository';
import { AppSession } from '../service/AppSession';
import { NetError, NetErrorKind } from '../service/HttpClient';
import { RealtimeListener, RealtimeService } from '../service/RealtimeService';
import { Prefs } from '../store/Prefs';

/** 错误分类 → 用户可读文案。 */
function errorText(e: Object): string {
  if (e instanceof NetError) {
    switch (e.kind) {
      case NetErrorKind.Network:
        return '网络不可用，请检查网络连接后重试';
      case NetErrorKind.Http:
        return `服务返回异常（HTTP ${e.httpCode}）`;
      case NetErrorKind.Token:
        return '鉴权失败，可能是站点配置已变更';
      case NetErrorKind.Parse:
        return '数据格式异常，站点接口可能已调整';
      default:
        return e.message;
    }
  }
  return Logger.errText(e);
}

/**
 * 首页视图模型。
 *
 * 关键设计：
 *  1. **串行初始化** —— 先拿元数据再发首次查询。原网页是「先 trigger change 发一次
 *     空参数请求、回调再发一次」，白白多一次无效请求，这里修掉。
 *  2. **请求序号防竞态** —— 快速切换筛选时，只采纳最新一次响应，旧响应直接丢弃。
 *  3. 视图层不直接接触 Repository / HttpClient，也不感知接口的两种形态，
 *     更不感知空座率有两个来源、两种单位（统一在这一层归一成展示文案）。
 */
@Observed
export class ClassroomViewModel implements RealtimeListener {
  private readonly session: AppSession = AppSession.get();
  private readonly realtime: RealtimeService = new RealtimeService();
  private meta: MetaRepository | null = null;
  private classroom: ClassroomRepository | null = null;

  /** 递增的请求序号，用于丢弃过期响应 */
  private reqSeq: number = 0;
  /**
   * 数据版本号，**每成功拿到一批新数据 +1**，并拼进列表键值。
   *
   * 存在的唯一理由是 ArkUI 的 ForEach 复用规则：非首次渲染时，键值已存在的数组项
   * **不会重新执行 itemGenerator**，而是直接复用上次那个组件实例。于是只要键值不随
   * 数据变化，界面就冻在第一次渲染的内容上 —— 换楼栋列表不刷新就是这么来的。
   * 详见 `DisplayGroup.key` 的注释。
   */
  private dataRev: number = 0;
  /** 页面是否在前台（决定引导完成后要不要立刻把实时通道接上） */
  private foreground: boolean = false;

  // ---------- 状态 ----------
  loadState: LoadState = LoadState.Loading;
  errorMsg: string = '';
  /**
   * 非阻塞提示（弱网/刷新失败但仍展示旧数据时用）。
   * 用空串表示无提示 —— 不要用 null，视图层会少写一层判断。
   */
  noticeMsg: string = '';

  // ---------- 筛选 ----------
  buildings: BuildingDto[] = [];
  buildingIndex: number = 0;
  nodeTypes: NodeTypeDto[] = [];
  nodeTypeIndex: number = 0;
  nodes: NodeDto[] = [];
  /** 0 = 全部节次；其余对应 nodes[index-1] */
  nodeIndex: number = 0;
  /**
   * 查询日期。
   * **在字段声明处就赋好值**，而不是等 init() 引导成功后再设 —— 否则引导一失败，
   * 筛选栏就会显示成一个空白控件，用户看不到任何可理解的信息。
   */
  dateStr: string = TimeUtil.formatDate(new Date());
  timeSlot: TimeSlotId = TimeSlotId.ByNode;

  // ---------- 结果 ----------
  groups: DisplayGroup[] = [];
  searchType: SearchType = SearchType.ByNode;

  // ---------- 时钟 ----------
  clockText: string = '';
  /** 当前时刻的当日秒数，驱动卡片配色与当前行高亮 */
  nowSec: number = 0;

  // ---------- 实时通道 ----------
  /** 实时空座率是否可用。false 表示已降级为「仅 REST + 手动刷新」。 */
  realtimeAvailable: boolean = true;

  /**
   * 是否在使用内置配置快照（本机无真实加密能力，如 DevEco 预览器）。
   * 为 true 时页脚给出提示 —— 数据本身仍是真的（走同一套线上接口），
   * 但 csrkKey 是快照值，站点轮换密钥后 token 会被拒。
   */
  degradedConfig: boolean = false;

  /** 需要显示「节次类型」选择器吗？（只有一个选项时隐藏，降低选择负担） */
  get showNodeTypePicker(): boolean {
    return this.nodeTypes.length > 1;
  }

  /** 需要显示「节次」选择器吗？（仅「按节次」模式有意义） */
  get showNodePicker(): boolean {
    return this.timeSlot === TimeSlotId.ByNode && this.nodes.length > 1;
  }

  get isByNode(): boolean {
    return this.searchType === SearchType.ByNode;
  }

  get totalRooms(): number {
    let n: number = 0;
    for (const g of this.groups) {
      n += g.rooms.length;
    }
    return n;
  }

  get currentBuildingName(): string {
    return this.buildingIndex >= 0 && this.buildingIndex < this.buildings.length
      ? this.buildings[this.buildingIndex].name : '';
  }

  // ---------------------------------------------------------------- 生命周期

  /** 串行引导 + 首次查询。 */
  async init(): Promise<void> {
    this.loadState = LoadState.Loading;
    this.errorMsg = '';

    const boot = await this.session.boot();
    if (!boot.ok) {
      this.loadState = LoadState.Error;
      this.errorMsg = boot.error.length > 0 ? boot.error : '初始化失败，请检查网络后重试';
      return;
    }

    // 引导过程里若因为本机没有加密能力而回退到了内置快照，这里要记下来。
    // ConfigRepository 已经打过 ERROR 日志，界面上再给一条提示 ——
    // 降级不该是静默的。
    this.degradedConfig = ConfigRepository.usedFallback;

    this.meta = new MetaRepository(this.session.http);
    this.classroom = new ClassroomRepository(this.session.http);

    this.dateStr = TimeUtil.formatDate(new Date());
    this.timeSlot = this.restoreTimeSlot();

    try {
      // 元数据：楼栋与节次类型可并行
      const results: Object[] = await Promise.all([
        this.meta.listBuildings(),
        this.meta.listNodeTypes()
      ]);
      this.buildings = results[0] as BuildingDto[];
      this.nodeTypes = results[1] as NodeTypeDto[];

      if (this.buildings.length === 0 || this.nodeTypes.length === 0) {
        this.loadState = LoadState.Empty;
        return;
      }
      this.buildingIndex = this.pickIndex(this.buildings.map((b: BuildingDto) => b.id),
        Prefs.getString(Constants.KEY_LAST_BUILDING, ''), 0);
      this.nodeTypeIndex = this.pickIndex(this.nodeTypes.map((t: NodeTypeDto) => t.id),
        Prefs.getString(Constants.KEY_LAST_NODE_TYPE, ''), 0);

      await this.reloadNodes();
    } catch (e) {
      this.loadState = LoadState.Error;
      this.errorMsg = errorText(e);
      Logger.error(`初始化失败: ${this.errorMsg}`);
      return;
    }

    await this.reload();

    // 配置到手了。如果页面已经在等这个通道，现在接上。
    this.attachRealtimeIfNeeded();
  }

  /** 加载当前节次类型下的节次列表。 */
  private async reloadNodes(): Promise<void> {
    if (this.meta === null || this.currentNodeTypeId().length === 0) {
      return;
    }
    this.nodes = await this.meta.listNodes(this.currentNodeTypeId());
    this.nodeIndex = 0;
  }

  // ---------------------------------------------------------------- 实时通道

  /**
   * 页面进入前台。建连是幂等的，重复调用无害。
   *
   * 冷启动时 onPageShow 常常早于 boot() 完成（配置里的 aiAnalyseIp 还没拿到），
   * 此时只记下「想连」，等 init() 拿到配置后再接上 —— 否则会拼出同源兜底地址，
   * 连到错误的主机上。
   */
  startRealtime(): void {
    this.foreground = true;
    this.attachRealtimeIfNeeded();
  }

  /** 页面离开前台。必须断开，避免后台常驻连接与定时器。 */
  stopRealtime(): void {
    this.foreground = false;
    this.realtime.stop();
  }

  private attachRealtimeIfNeeded(): void {
    if (!this.foreground || !this.session.isReady()) {
      return;
    }
    this.realtime.setListener(this);
    // aiAnalyseIp 为空时 buildUrl 会退回同源，不再额外判断
    this.realtime.configureEndpoint(this.session.getAiAnalyseIp());
    this.realtime.start();
  }

  /** RealtimeListener：收到实时座位事件。 */
  onSeatUpdate(classroomId: number, allStuCnt: number): void {
    this.applySeatUpdate(classroomId, allStuCnt);
  }

  /** RealtimeListener：通道可用性变化（false = 已降级）。 */
  onAvailabilityChanged(available: boolean): void {
    if (this.realtimeAvailable !== available) {
      this.realtimeAvailable = available;
      Logger.tag('ViewModel', `实时通道可用性 → ${available}`);
    }
  }

  /**
   * 把实时人数落到对应卡片上。
   *
   * 换算公式照抄原站的 4005 分支：
   *   `noRate = seatCount ? round((seatCount - AllStuCnt) / seatCount * 100) : 0`
   *
   * 与原站的两处**刻意**差异：
   *  1. 原站只在「按节次」模式生效 —— 那是它的 DOM id 只在分组视图里拼了组下标的
   *     副作用。这里按 classroomId 在任意模式匹配，同一教室出现在多个节次分组时
   *     每个都会更新（原站的 `map` 也是全更新，没有 break）。
   *  2. 只在**查看今天**时应用。推送反映的是「此刻」，如果用户正在看明天的空教室，
   *     把此刻的人数贴上去是误导。
   *
   * 任意一个教室都可能在当前列表里不存在（属于别的楼栋/时段），直接丢弃即可。
   */
  private applySeatUpdate(classroomId: number, allStuCnt: number): void {
    if (this.groups.length === 0) {
      return;
    }
    if (this.dateStr !== TimeUtil.formatDate(new Date())) {
      return;
    }

    let changed: boolean = false;
    const nextGroups: DisplayGroup[] = [];
    for (const g of this.groups) {
      const hit: number = this.indexOfRoom(g.rooms, classroomId);
      if (hit < 0) {
        nextGroups.push(g);
        continue;
      }
      const room: RoomView = g.rooms[hit];
      const text: string = ClassroomViewModel.liveSeatText(room.seatCount, allStuCnt);
      if (text === room.seatText) {
        nextGroups.push(g);
        continue;
      }
      // @State 只观测第一层：改 room.seatText 是第三层变更，不会触发刷新，
      // 必须重建 rooms 数组与该分组对象。
      const rooms: RoomView[] = [];
      for (let i = 0; i < g.rooms.length; i++) {
        rooms.push(i === hit
          ? {
            classroomId: room.classroomId,
            classroomName: room.classroomName,
            seatText: text,
            seatCount: room.seatCount
          }
          : g.rooms[i]);
      }
      nextGroups.push({
        key: g.key,
        // 组键值里没有东西会因推送而变化 —— 必须靠 rev 把这一组"推"醒，
        // 否则组内那层 ForEach 不会被重新求值，卡片上的数字纹丝不动。
        rev: g.rev + 1,
        title: g.title,
        timeText: g.timeText,
        rawStart: g.rawStart,
        rawEnd: g.rawEnd,
        state: g.state,
        showStateLabel: g.showStateLabel,
        rooms: rooms
      });
      changed = true;
    }

    if (changed) {
      this.groups = nextGroups;
    }
  }

  private indexOfRoom(rooms: RoomView[], classroomId: number): number {
    for (let i = 0; i < rooms.length; i++) {
      if (rooms[i].classroomId === classroomId) {
        return i;
      }
    }
    return -1;
  }

  /**
   * 实时人数 → 空座率文案。
   *
   * 座位数缺失（接口给 null）时返回 **`0%`** —— 照抄原站。原站的 4005 分支是：
   *
   *     var noRate = subitem.seatCount
   *       ? Number(((subitem.seatCount - (recv.AllStuCnt || 0)) / subitem.seatCount * 100).toFixed(0))
   *       : 0
   *     $('#rate_' + id + '_' + index).html('(空座率:' + noRate + '%)')
   *
   * 座位数缺失 → 取 `0` → 渲染「空座率 0%」。
   *
   * ⚠️ 这里曾经刻意改成 `--`（理由：「不知道座位数」显示成 0% 是在撒谎）。
   * **该偏离已按「忠实还原优先」撤销**，两个具体理由：
   *   1. 这条分支**真的会被走到**：实测智慧教室有 8 间教室 `seatCount` 为 null。
   *      上一轮以为只有（已移除的）南楼如此，据此判成"几乎不可达" —— 那个前提是错的。
   *   2. 原站在这里的行为确定且可复现；而"更诚实"的版本会让同一间教室在本应用里
   *      永远停在 `--`、在原站却是 `0%`，又多一处需要解释的差异。
   *
   * 保留的唯一加固：原站不夹取范围，人数超过座位数时会显示「空座率 -5%」。
   * 负的空座率对用户没有意义，这里夹到 [0, 100]。
   */
  private static liveSeatText(seatCount: number, allStuCnt: number): string {
    if (seatCount <= 0) {
      return '0%';
    }
    let pct: number = Math.round((seatCount - allStuCnt) / seatCount * 100);
    if (pct < 0) {
      pct = 0;
    }
    if (pct > 100) {
      pct = 100;
    }
    return `${pct}%`;
  }

  // ---------------------------------------------------------------- 查询

  /** 按当前筛选条件重新查询。 */
  async reload(): Promise<void> {
    if (this.classroom === null || this.buildings.length === 0) {
      return;
    }
    const seq: number = ++this.reqSeq;
    this.loadState = LoadState.Loading;
    this.errorMsg = '';
    this.persistSelections();

    const buildingId: string = this.buildings[this.buildingIndex].id;

    try {
      if (this.timeSlot === TimeSlotId.ByNode) {
        await this.loadByNode(seq, buildingId);
      } else {
        await this.loadByTimeRange(seq, buildingId);
      }
    } catch (e) {
      if (seq !== this.reqSeq) {
        return; // 过期响应，静默丢弃
      }
      const text: string = errorText(e);
      Logger.error(`查询失败: ${text}`);
      if (this.hasData()) {
        // 手上有数据就别用错误页把它盖掉 —— 学生正看着的教室列表比一句
        // 「查询失败」有用得多。改成一条非阻塞提示，数据继续可读。
        this.loadState = LoadState.Ok;
        this.noticeMsg = `刷新失败，当前显示的是上次结果（${text}）`;
      } else {
        this.loadState = LoadState.Error;
        this.errorMsg = text;
      }
    }
  }

  /** 当前是否有可展示的数据。 */
  private hasData(): boolean {
    return this.totalRooms > 0;
  }

  private async loadByNode(seq: number, buildingId: string): Promise<void> {
    const repo = this.classroom;
    if (repo === null) {
      return;
    }
    const nodeId: string = this.selectedNodeId();
    const groups: FreeRoomGroupDto[] = await repo.queryByNode(
      buildingId, this.currentNodeTypeId(), nodeId);
    if (seq !== this.reqSeq) {
      Logger.tag('ViewModel', `丢弃过期响应 seq=${seq} current=${this.reqSeq}`);
      return;
    }
    this.searchType = SearchType.ByNode;
    this.dataRev++;
    this.groups = this.toDisplayGroups(groups);
    this.loadState = this.totalRooms === 0 ? LoadState.Empty : LoadState.Ok;
    this.noticeMsg = '';
  }

  private async loadByTimeRange(seq: number, buildingId: string): Promise<void> {
    const repo = this.classroom;
    if (repo === null) {
      return;
    }
    const range = TimeUtil.rangeOf(this.timeSlot, this.dateStr);
    const rooms: ClassroomItemDto[] = await repo.queryByTimeRange(
      buildingId, range.startTime, range.endTime);
    if (seq !== this.reqSeq) {
      Logger.tag('ViewModel', `丢弃过期响应 seq=${seq} current=${this.reqSeq}`);
      return;
    }
    this.searchType = SearchType.ByTimeRange;
    this.dataRev++;
    this.groups = [{
      key: this.groupKeyOf(`slot-${this.timeSlot as number}`),
      rev: 0,
      title: this.timeSlotLabel(),
      timeText: `${this.hhmm(range.startTime)} - ${this.hhmm(range.endTime)}`,
      rawStart: range.startTime,
      rawEnd: range.endTime,
      state: CardState.Current,
      showStateLabel: false,
      rooms: ClassroomViewModel.toRoomViews(rooms)
    }];
    this.loadState = rooms.length === 0 ? LoadState.Empty : LoadState.Ok;
    this.noticeMsg = '';
  }

  /**
   * 接口分组 → 视图分组。
   *
   * 空座率在这里就算成展示文案：接口给的是 0~1 的浮点，实时推送给的是整数百分数，
   * 让视图层去分辨迟早出错。
   */
  private toDisplayGroups(groups: FreeRoomGroupDto[]): DisplayGroup[] {
    const now: number = this.nowSec;
    const out: DisplayGroup[] = [];
    for (const g of groups) {
      const state: CardState = TimeUtil.cardStateOf(g.startTime, g.endTime, now);
      out.push({
        key: this.groupKeyOf(g.nodeId),
        rev: 0,
        title: g.nodeName,
        timeText: `${TimeUtil.hhmmOf(g.startTime)} - ${TimeUtil.hhmmOf(g.endTime)}`,
        rawStart: g.startTime,
        rawEnd: g.endTime,
        state: state,
        showStateLabel: true,
        rooms: ClassroomViewModel.toRoomViews(g.classroomItems)
      });
    }
    return out;
  }

  /**
   * 列表键值 —— **不是装饰，是 ArkUI 刷新的开关**。
   *
   * ArkUI 的 `ForEach` 在非首次渲染时按「键值是否已存在」决定怎么处理每一项：
   * 键值存在就直接复用上次那个组件实例、**不会再执行一次 itemGenerator**。
   * 也就是说：组件的 props 只在这行键值变化时才会被重新赋值，键值不变 = 界面冻结。
   *
   * 所以键值必须覆盖「数据身份」——任何会让列表内容变化的东西（楼栋、节次类型、
   * 节次、日期、时间段）都得体现在里面。这里用自增的 `dataRev`：每成功拿到一批
   * 新数据它就 +1，一次到位，不必逐个字段去枚举（漏一个就是一类"点了没反应"）。
   *
   * 视图层还会在末尾拼上 `state` 与教室自身的 `seatText` —— 那两个是渲染期才会
   * 变的东西，见 `Index.ets` 的注释。
   */
  private groupKeyOf(nodeKey: string): string {
    return `${this.dataRev}|${nodeKey}`;
  }

  private static toRoomViews(items: ClassroomItemDto[]): RoomView[] {
    const out: RoomView[] = [];
    for (const c of items) {
      out.push({
        classroomId: c.classroomId,
        classroomName: c.classroomName,
        seatText: TimeUtil.seatFreeText(c.noSeatRate),
        // 接口对部分教室返回 seatCount: null（实测智慧教室 8 间，另有已移除的南楼
        // 整栋 47 间）。它只是实时换算的除数，这里归一成 0，由 liveSeatText 决定
        // 「算不出」时显示什么（照抄原站：0%）。
        seatCount: c.seatCount === null ? 0 : c.seatCount
      });
    }
    return out;
  }

  // ---------------------------------------------------------------- 时钟

  /** 每秒调用。时间跨过整点/节次边界时需要重算卡片状态。 */
  tickClock(): void {
    const d: Date = new Date();
    this.clockText = TimeUtil.formatClock(d);
    const prev: number = this.nowSec;
    const next: number = TimeUtil.nowSeconds();
    this.nowSec = next;
    // 跨分钟时重算分组状态（每分钟最多一次，避免每秒重建整个列表）
    if (Math.floor(prev / 60) !== Math.floor(next / 60) && this.searchType === SearchType.ByNode) {
      this.recomputeGroupStates();
    }
  }

  private recomputeGroupStates(): void {
    if (this.groups.length === 0) {
      return;
    }
    const now: number = this.nowSec;
    // 注意：必须**整体重建数组**。@State 只观测第一层属性，
    // 直接改 g.state 属于二级属性变更，不会触发 UI 刷新。
    const next: DisplayGroup[] = [];
    for (const g of this.groups) {
      const state: CardState = TimeUtil.cardStateOf(g.rawStart, g.rawEnd, now);
      if (state === g.state) {
        next.push(g);
      } else {
        next.push({
          key: g.key,
          rev: g.rev,
          title: g.title,
          timeText: g.timeText,
          rawStart: g.rawStart,
          rawEnd: g.rawEnd,
          state: state,
          showStateLabel: g.showStateLabel,
          rooms: g.rooms
        });
      }
    }
    this.groups = next;
  }

  /** 当前时刻所在的分组下标（找不到返回 -1），用于自动滚动定位。 */
  currentGroupIndex(): number {
    for (let i = 0; i < this.groups.length; i++) {
      if (this.groups[i].state === CardState.Current) {
        return i;
      }
    }
    return -1;
  }

  // ---------------------------------------------------------------- 选择

  selectedNodeId(): string {
    if (this.nodeIndex <= 0 || this.nodeIndex > this.nodes.length) {
      return Constants.ALL_NODES;
    }
    return this.nodes[this.nodeIndex - 1].id;
  }

  /** 当前节次类型 id。元数据没到手时返回空串 —— 宁可变出一次无效请求，也不能在这里崩。 */
  private currentNodeTypeId(): string {
    const i: number = this.nodeTypeIndex;
    return i >= 0 && i < this.nodeTypes.length ? this.nodeTypes[i].id : '';
  }

  /** 节次下拉的选项文案。首项「全部节次」走资源，其余是接口返回的节次名。 */
  nodeOptionLabels(): ResourceStr[] {
    const labels: ResourceStr[] = [$r('app.string.all_nodes')];
    for (const n of this.nodes) {
      labels.push(n.name);
    }
    return labels;
  }

  /**
   * 时间段的中文名。
   *
   * 返回 `ResourceStr` 而不是 `string`：这句话在两处出现（筛选栏的 chip 与按时间段
   * 模式的列表标题），以前两边各写一遍字面量、资源文件里还躺着第三份 ——
   * 一处改了另两处不改就是"同一个概念两种叫法"。现在统一指向 string.json。
   */
  timeSlotLabel(): ResourceStr {
    switch (this.timeSlot) {
      case TimeSlotId.AllDay:
        return $r('app.string.time_all');
      case TimeSlotId.Morning:
        return $r('app.string.time_morning');
      case TimeSlotId.Afternoon:
        return $r('app.string.time_afternoon');
      case TimeSlotId.Evening:
        return $r('app.string.time_evening');
      case TimeSlotId.ByNode:
      default:
        return $r('app.string.time_by_node');
    }
  }

  /** 切换楼栋。保持当前查询模式（对齐原站联动规则）。 */
  async selectBuilding(index: number): Promise<void> {
    if (index === this.buildingIndex) {
      return;
    }
    this.buildingIndex = index;
    await this.reload();
  }

  /** 切换节次类型：强制回到「按节次」模式（对齐原站联动规则）。 */
  async selectNodeType(index: number): Promise<void> {
    if (index === this.nodeTypeIndex || index < 0 || index >= this.nodeTypes.length) {
      return;
    }
    this.nodeTypeIndex = index;
    this.timeSlot = TimeSlotId.ByNode;
    try {
      await this.reloadNodes();
    } catch (e) {
      this.loadState = LoadState.Error;
      this.errorMsg = errorText(e);
      return;
    }
    await this.reload();
  }

  /** 切换节次：强制回到「按节次」模式。 */
  async selectNode(index: number): Promise<void> {
    if (index === this.nodeIndex) {
      return;
    }
    this.nodeIndex = index;
    this.timeSlot = TimeSlotId.ByNode;
    await this.reload();
  }

  /** 切换时间段。 */
  async selectTimeSlot(slot: TimeSlotId): Promise<void> {
    if (slot === this.timeSlot) {
      return;
    }
    // 反向约束：「按节次」接口没有日期参数，它反映的永远是**当前时刻**。若此刻
    // 筛选栏上挂着别的日期，界面就会显示一个与数据无关的日期 —— 把日期拉回今天。
    // 界面会为此弹一条提示（`Index.applyTimeSlot`），不是静默改参数。
    if (slot === TimeSlotId.ByNode && !this.isToday(this.dateStr)) {
      this.dateStr = TimeUtil.formatDate(new Date());
      Logger.tag('ViewModel', '「按节次」只反映当前时刻 → 日期回到今天');
    }
    this.timeSlot = slot;
    await this.reload();
  }

  /**
   * 现在能不能改日期。
   *
   * 「按节次」接口的请求体只有 `{buildingId, cycleTypeId, nodeId}`，**不吃日期**
   * —— 所以按节次模式下日期控件没有意义。
   *
   * 这里曾经的做法是「选了非今天的日期就自动切到全天」，原意是别让用户白点一下，
   * 结果适得其反：**筛选栏在用户没碰它的时候自己跳了一格**，看起来像应用出了毛病。
   * 现在改成「不能用就明确禁用」—— 控件置灰、点击给一句解释，不做任何隐式切换。
   */
  get canPickDate(): boolean {
    return this.timeSlot !== TimeSlotId.ByNode;
  }

  /**
   * 切换日期。
   *
   * 只负责「改日期并重新查询」，**不再顺带改查询模式** —— 模式是被用户选中的状态，
   * 不该被另一个控件的操作悄悄改掉。非「按节次」模式下日期才是有效输入，
   * 这一点由 `canPickDate` 在界面上表达。
   */
  async selectDate(dateStr: string): Promise<void> {
    if (dateStr === this.dateStr) {
      return;
    }
    if (!this.canPickDate) {
      // 界面已经禁用了这个入口，走到这里说明是别的调用方漏了判断。
      // 静默忽略会掩盖 bug，所以留一条日志。
      Logger.tag('ViewModel', '「按节次」模式下日期不可改，忽略本次选择');
      return;
    }
    this.dateStr = dateStr;
    await this.reload();
  }

  private isToday(dateStr: string): boolean {
    return dateStr === TimeUtil.formatDate(new Date());
  }

  /**
   * 当前查看的是否为今天。
   *
   * 界面用它决定头部标题显示「今日无课教室」还是「2026-09-15 无课教室」
   * （对齐原站的 `.q-dt`）。日期切换是否生效，用户就靠这一行字确认 ——
   * 所以它不是装饰，是**验收项**。
   */
  isViewingToday(): boolean {
    return this.isToday(this.dateStr);
  }

  // ---------------------------------------------------------------- 内部

  private pickIndex(ids: string[], saved: string, fallback: number): number {
    if (saved.length === 0) {
      return fallback;
    }
    for (let i = 0; i < ids.length; i++) {
      if (ids[i] === saved) {
        return i;
      }
    }
    return fallback;
  }

  private persistSelections(): void {
    if (this.buildingIndex >= 0 && this.buildingIndex < this.buildings.length) {
      Prefs.putString(Constants.KEY_LAST_BUILDING, this.buildings[this.buildingIndex].id);
    }
    if (this.nodeTypeIndex >= 0 && this.nodeTypeIndex < this.nodeTypes.length) {
      Prefs.putString(Constants.KEY_LAST_NODE_TYPE, this.nodeTypes[this.nodeTypeIndex].id);
    }
    Prefs.putNumber(Constants.KEY_LAST_TIME_ID, this.timeSlot as number);
  }

  private restoreTimeSlot(): TimeSlotId {
    const saved: number = Prefs.getNumber(Constants.KEY_LAST_TIME_ID, Constants.DEFAULT_TIME_ID);
    if (saved === TimeSlotId.AllDay || saved === TimeSlotId.Morning
      || saved === TimeSlotId.Afternoon || saved === TimeSlotId.Evening) {
      return saved as TimeSlotId;
    }
    return TimeSlotId.ByNode;
  }

  private hhmm(dateTime: string): string {
    return TimeUtil.hhmmOf(dateTime);
  }
}
