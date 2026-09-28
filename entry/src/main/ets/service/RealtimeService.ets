import { webSocket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Constants } from '../common/Constants';
import { Logger } from '../common/Logger';

/** 实时通道状态。 */
export enum WsState {
  Idle,
  Connecting,
  Open,
  Reconnecting,
  /** 连续握手失败达到上限，已放弃 —— 界面降级为「仅 REST + 手动刷新」 */
  Degraded
}

/**
 * 实时事件的出口。
 *
 * 刻意用接口而不是回调函数：实现方是 ViewModel，实例方法直接满足接口，
 * 不存在「lambda 挂在哪个对象上」的歧义，行为可预期。
 */
export interface RealtimeListener {
  /** 收到实时座位事件。allStuCnt 为该教室当前人数。 */
  onSeatUpdate(classroomId: number, allStuCnt: number): void;
  /** 实时通道可用性变化（false 表示已降级）。 */
  onAvailabilityChanged(available: boolean): void;
}

// ---------------------------------------------------------------- 帧结构

/**
 * setSessionUser 帧的 data 段。
 * 字段顺序照抄实测抓包，值除 schoolId 外全为原样（含 null 与空串）。
 */
interface SessionUserData {
  type: string;
  userType: string | null;
  userId: string | null;
  scheduleId: string | null;
  name: string;
  sex: number;
  imageFileUri: string;
  studentId: string | null;
  teacherId: string | null;
  classRoomId: string;
  schoolId: number;
}

interface SessionUserFrame {
  channel: string;
  requestID: string;
  token: string | null;
  data: SessionUserData;
  action: string;
}

/** ping 帧的 data 段恒为空对象。 */
interface PingData {
}

interface PingFrame {
  action: string;
  channel: string;
  data: PingData;
  requestID: number;
  token: string | null;
}

/**
 * 下行帧的 data 段。
 *
 * 两个字段都声明为可选：这是**未经校验的外部 JSON**，
 * 服务端在 1015/1016 帧里给的 data 形状并不一致，硬声明成必填是在骗自己。
 */
interface InboundSeatData {
  AllStuCnt?: number;
  ClassroomID?: number;
}

interface InboundFrame {
  code: number;
  msg?: string;
  data?: InboundSeatData;
}

// ---------------------------------------------------------------- 服务

/**
 * 实时空座率通道。
 *
 * 协议（全部来自对原站的抓包逆向，标准答案见 `参考网站/探测脚本/probe_ws.py`）：
 *
 *   connect(wss://<aiAnalyseIp 去协议>/attendance/api/ws, { header: {Origin} })
 *     └─ open  → 发 setSessionUser(schoolId=159, classRoomId='')
 *                  └─ 收 1016「请检查参数」——空 classRoomId 的良性提示，**忽略**
 *                  └─ 收 1015「操作成功」——会话注册成功
 *     └─ 每 10s 发一次 {"action":"ping", ...}，服务端回 {"code":1000}（心跳，静默）
 *     └─ 收 4005 {AllStuCnt, ClassroomID} → 交给 listener
 *     └─ close/error → 退避重连（3s 起，×2 递增，上限 30s）
 *
 * 两个刻意的取舍：
 *  1. `pingInterval: 0` **关闭框架层心跳**。服务端用的是应用层 ping/pong，
 *     框架层 Pong 帧服务端不认，留着它只会在 pongTimeout 后误断。
 *  2. 连续 3 次**都没能走到 open** 才降级；连上过又掉线的不算失败，
 *     那种情况网络恢复了自然会连回来。
 */
export class RealtimeService {
  private ws: webSocket.WebSocket | null = null;
  private state: WsState = WsState.Idle;
  private listener: RealtimeListener | null = null;
  private url: string = '';

  private pingTimerId: number = -1;
  private reconnectTimerId: number = -1;
  private retryDelay: number = Constants.WS_RECONNECT_BASE_MS;

  /** 连续「连不上」的次数（成功 open 过就清零）。 */
  private consecutiveFailures: number = 0;
  /** 本次尝试是否成功走到过 open。 */
  private opened: boolean = false;
  /** 应用层是否希望保持连接。stop() 后置 false，重连调度前都要看它。 */
  private wantOpen: boolean = false;
  /** 本次掉线是否已处理，避免 error + close 双触发导致重复调度重连。 */
  private dropHandled: boolean = false;

  setListener(listener: RealtimeListener): void {
    this.listener = listener;
  }

  getState(): WsState {
    return this.state;
  }

  /**
   * 由 ViewModel 在拿到 aiAnalyseIp 后调用。
   * 传空串表示拿不到配置，退回同源。
   */
  configureEndpoint(aiAnalyseIp: string): void {
    this.url = RealtimeService.buildUrl(aiAnalyseIp);
  }

  /**
   * 从配置拼 WebSocket 地址。
   *
   * 原站写法是 `aiAnalyseIp.split('//')[1]`：既剥掉协议，也**保留了端口**，
   * 然后强行换成 wss。这里做同样的事，但不用 split —— 配置里可能只有一段，
   * split 越界会静默变成空串，从而拼出 `wss:///attendance/api/ws` 这种废地址。
   */
  static buildUrl(aiAnalyseIp: string): string {
    const idx: number = aiAnalyseIp.indexOf('//');
    if (idx >= 0 && aiAnalyseIp.length > idx + 2) {
      return `wss://${aiAnalyseIp.substring(idx + 2)}${Constants.WS_PATH}`;
    }
    return `wss://${Constants.SCHOOL_HOST}${Constants.WS_PATH}`;
  }

  /** 建连（幂等）。已在连接中/已连上时重复调用不会重复建连。 */
  start(): void {
    if (this.wantOpen && this.state !== WsState.Idle) {
      return;
    }
    if (this.state === WsState.Degraded) {
      // 用户重新回到页面 = 一次主动的"再试试"，给他这个重试机会。
      // 降级只用于"别再自己反复重连"，不该变成需要重启应用才能恢复的死状态。
      Logger.tag('Realtime', '页面重新可见，重置降级状态并重试');
    }
    this.wantOpen = true;
    this.consecutiveFailures = 0;
    this.retryDelay = Constants.WS_RECONNECT_BASE_MS;
    this.state = WsState.Idle;
    this.connect();
  }

  /** 断开并清理（页面不可见时必须调用，避免后台常驻耗电与连接泄漏）。 */
  stop(): void {
    this.wantOpen = false;
    this.clearReconnectTimer();
    this.stopPing();
    this.closeSocket();
    this.state = WsState.Idle;
    Logger.tag('Realtime', '已停止');
  }

  // ---------------------------------------------------------------- 连接

  private connect(): void {
    if (!this.wantOpen || this.state === WsState.Degraded) {
      return;
    }
    if (this.url.length === 0) {
      this.configureEndpoint('');
    }

    this.releaseSocket();
    this.state = WsState.Connecting;
    this.opened = false;
    this.dropHandled = false;

    const ws: webSocket.WebSocket = webSocket.createWebSocket();
    this.ws = ws;
    this.bindEvents(ws);

    const options: webSocket.WebSocketRequestOptions = {
      header: { 'Origin': Constants.WS_ORIGIN },
      // 关掉框架层心跳：服务端只认应用层 {"action":"ping"}
      pingInterval: 0,
      pongTimeout: 0
    };

    Logger.tag('Realtime', `连接 ${this.url}`);
    ws.connect(this.url, options, (err: BusinessError) => {
      // 这里的 err 只代表「建连请求发起失败」，不代表握手结果。
      // 真正的成功看 on('open')，所以这里只记日志，不在这里调度重连 ——
      // 否则会和随之而来的 on('error') 重复调度。
      if (err) {
        Logger.warn(`实时通道建连请求失败: ${err.code} ${err.message}`);
      }
    });
  }

  private bindEvents(ws: webSocket.WebSocket): void {
    ws.on('open', (err: BusinessError) => {
      if (err) {
        this.handleDrop('open');
        return;
      }
      this.opened = true;
      this.state = WsState.Open;
      this.consecutiveFailures = 0;
      this.retryDelay = Constants.WS_RECONNECT_BASE_MS;
      Logger.tag('Realtime', '已连接，发送 setSessionUser');
      this.notifyAvailability(true);
      this.sendSessionUser();
      this.startPing();
    });

    ws.on('message', (err: BusinessError, value: string | ArrayBuffer) => {
      if (err) {
        Logger.warn(`实时通道收帧异常: ${err.code} ${err.message}`);
        return;
      }
      if (typeof value !== 'string') {
        return; // 服务端只发文本帧
      }
      this.handleMessage(value);
    });

    ws.on('close', (err: BusinessError, value: webSocket.CloseResult) => {
      if (err) {
        return;
      }
      this.handleDrop('close');
    });

    ws.on('error', (err: BusinessError) => {
      Logger.warn(`实时通道出错: ${err.code} ${err.message}`);
      this.handleDrop('error');
    });
  }

  private handleDrop(reason: string): void {
    if (this.dropHandled) {
      return; // error 与 close 常常一起到，只处理第一次
    }
    this.dropHandled = true;

    this.stopPing();
    this.releaseSocket();

    if (!this.wantOpen) {
      this.state = WsState.Idle;
      return;
    }

    if (!this.opened) {
      this.consecutiveFailures++;
      Logger.warn(`实时通道连不上（${reason}），第 ${this.consecutiveFailures} 次`);
      if (this.consecutiveFailures >= Constants.WS_FAIL_LIMIT) {
        this.state = WsState.Degraded;
        this.wantOpen = false;
        this.notifyAvailability(false);
        Logger.warn('实时通道连续失败，降级为「仅 REST + 手动刷新」');
        return;
      }
    } else {
      // 连上过再掉线：不算失败，退避重置
      this.consecutiveFailures = 0;
      this.state = WsState.Reconnecting;
      Logger.tag('Realtime', `连接断开（${reason}），准备重连`);
    }

    this.scheduleReconnect();
  }

  private scheduleReconnect(): void {
    this.clearReconnectTimer();
    const delay: number = this.retryDelay;
    this.retryDelay = Math.min(this.retryDelay * 2, Constants.WS_RECONNECT_MAX_MS);
    Logger.tag('Realtime', `${delay}ms 后重连`);
    this.reconnectTimerId = setTimeout(() => {
      this.reconnectTimerId = -1;
      this.connect();
    }, delay);
  }

  private clearReconnectTimer(): void {
    if (this.reconnectTimerId !== -1) {
      clearTimeout(this.reconnectTimerId);
      this.reconnectTimerId = -1;
    }
  }

  /** 摘掉事件并置空引用，不发 close —— 用于已经断掉的连接。 */
  private releaseSocket(): void {
    const ws: webSocket.WebSocket | null = this.ws;
    this.ws = null;
    if (ws === null) {
      return;
    }
    try {
      ws.off('open');
      ws.off('message');
      ws.off('close');
      ws.off('error');
    } catch (e) {
      Logger.warn(`摘除实时通道回调失败: ${Logger.errText(e)}`);
    }
  }

  /** 主动关闭并丢弃引用。 */
  private closeSocket(): void {
    const ws: webSocket.WebSocket | null = this.ws;
    this.ws = null;
    if (ws === null) {
      return;
    }
    this.dropHandled = true; // 主动关不算掉线，不要再触发重连
    try {
      ws.off('open');
      ws.off('message');
      ws.off('close');
      ws.off('error');
      const opts: webSocket.WebSocketCloseOptions = { code: 1000, reason: 'page hide' };
      ws.close(opts, (err: BusinessError) => {
        if (err) {
          Logger.tag('Realtime', `关闭实时通道返回: ${err.code} ${err.message}`);
        }
      });
    } catch (e) {
      Logger.warn(`关闭实时通道失败: ${Logger.errText(e)}`);
    }
  }

  // ---------------------------------------------------------------- 收发

  private sendSessionUser(): void {
    const data: SessionUserData = {
      type: 'EmptyClassroom',
      userType: null,
      userId: null,
      scheduleId: null,
      name: '',
      sex: 0,
      imageFileUri: '',
      studentId: null,
      teacherId: null,
      // 空串是原站行为。**不要**为了消掉服务端的 1016 提示而乱填教室 id。
      classRoomId: '',
      schoolId: Constants.WS_SCHOOL_ID
    };
    const frame: SessionUserFrame = {
      channel: Constants.WS_CHANNEL,
      requestID: Constants.WS_SESSION_REQUEST_ID,
      token: null,
      data: data,
      action: 'setSessionUser'
    };
    this.sendRaw(JSON.stringify(frame));
  }

  private startPing(): void {
    this.stopPing();
    this.pingTimerId = setInterval(() => {
      this.sendPing();
    }, Constants.WS_PING_INTERVAL_MS);
  }

  private stopPing(): void {
    if (this.pingTimerId !== -1) {
      clearInterval(this.pingTimerId);
      this.pingTimerId = -1;
    }
  }

  private sendPing(): void {
    const frame: PingFrame = {
      action: 'ping',
      channel: Constants.WS_CHANNEL,
      data: {},
      // 原页面把 requestID 也写死成一个常量。这里用当前毫秒时间戳 ——
      // 形状一致（数值型毫秒时间戳），且排查问题时能看出心跳真的在发。
      requestID: Date.now(),
      token: null
    };
    this.sendRaw(JSON.stringify(frame));
  }

  private sendRaw(text: string): void {
    const ws: webSocket.WebSocket | null = this.ws;
    if (ws === null) {
      return;
    }
    ws.send(text, (err: BusinessError) => {
      if (err) {
        Logger.warn(`实时通道发送失败: ${err.code} ${err.message}`);
      }
    });
  }

  private handleMessage(text: string): void {
    if (text === 'pong') {
      return; // 心跳回包是裸字符串，不是 JSON
    }

    let frame: InboundFrame;
    try {
      frame = JSON.parse(text) as InboundFrame;
    } catch (e) {
      Logger.warn(`实时帧不是合法 JSON: ${text.substring(0, 120)}`);
      return;
    }

    if (frame.code === Constants.WS_CODE_SEAT_UPDATE) {
      const data: InboundSeatData | undefined = frame.data;
      if (data === undefined) {
        return;
      }
      const classroomId: number | undefined = data.ClassroomID;
      if (classroomId === undefined) {
        return;
      }
      const allStuCnt: number = data.AllStuCnt === undefined ? 0 : data.AllStuCnt;
      const listener: RealtimeListener | null = this.listener;
      if (listener !== null) {
        listener.onSeatUpdate(classroomId, allStuCnt);
      }
      return;
    }

    if (frame.code === Constants.WS_CODE_SESSION_OK) {
      Logger.tag('Realtime', '会话注册成功（1015）');
      return;
    }

    if (frame.code === Constants.WS_CODE_BENIGN_PARAM) {
      // 1016「请检查参数」：空 classRoomId 导致的良性提示，原站也会收到。
      // 刻意不处理，也不去"修"参数 —— 会话注册并不受影响（紧接着就是 1015）。
      Logger.tag('Realtime', '收到 1016（空 classRoomId 的良性提示，按设计忽略）');
      return;
    }

    if (frame.code === Constants.WS_CODE_PONG) {
      // 心跳回包。每 10s 一次，**不记日志** —— 记了就是每分钟六行噪音，
      // 把真正的异常淹掉（之前就是这么把 4005 推送藏起来的）。
      return;
    }

    Logger.tag('Realtime', `未处理的下行帧 code=${frame.code}`);
  }

  private notifyAvailability(available: boolean): void {
    const listener: RealtimeListener | null = this.listener;
    if (listener !== null) {
      listener.onAvailabilityChanged(available);
    }
  }
}
