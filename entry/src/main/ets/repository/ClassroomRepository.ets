import { Constants } from '../common/Constants';
import { Logger } from '../common/Logger';
import { ClassroomItemDto, FreeByNodeReq, FreeByTimeReq, FreeRoomGroupDto } from '../model/ApiTypes';
import { HttpClient } from '../service/HttpClient';

/**
 * 无课教室查询仓库。两套查询模式对应两个接口：
 *
 *   按节次   POST /general/api/classroom/freeClassRooms      { buildingId, cycleTypeId, nodeId }
 *            → 按节次分组，每组带教室列表
 *
 *   按时间段 POST /general/api/classroom/freeJoinClassRooms  { buildingId, startTime, endTime }
 *            → 扁平教室列表，无节次分组
 *
 * 注意：nodeId 用**空字符串**表示「全部节次」，不要传 null。
 */
export class ClassroomRepository {
  private readonly http: HttpClient;

  constructor(http: HttpClient) {
    this.http = http;
  }

  /** 按节次查询。nodeId 传 Constants.ALL_NODES 表示全部节次。 */
  async queryByNode(buildingId: string, cycleTypeId: string, nodeId: string): Promise<FreeRoomGroupDto[]> {
    const body: FreeByNodeReq = {
      buildingId: buildingId,
      cycleTypeId: cycleTypeId,
      nodeId: nodeId
    };
    const groups: FreeRoomGroupDto[] = await this.http.postEnvelope<FreeRoomGroupDto[]>(
      Constants.PATH_FREE_BY_NODE, JSON.stringify(body));

    let rooms: number = 0;
    for (const g of groups) {
      rooms += g.classroomItems.length;
    }
    Logger.tag('Classroom',
      `按节次查询：${groups.length} 个节次 / ${rooms} 间空闲 (building=${buildingId} node="${nodeId}")`);
    return groups;
  }

  /** 按时间段查询。startTime/endTime 形如 '2026-09-15 12:00:01'。 */
  async queryByTimeRange(buildingId: string, startTime: string, endTime: string): Promise<ClassroomItemDto[]> {
    const body: FreeByTimeReq = {
      buildingId: buildingId,
      startTime: startTime,
      endTime: endTime
    };
    const rooms: ClassroomItemDto[] = await this.http.postEnvelope<ClassroomItemDto[]>(
      Constants.PATH_FREE_BY_TIME, JSON.stringify(body));
    Logger.tag('Classroom',
      `按时间段查询：${rooms.length} 间空闲 (${startTime} ~ ${endTime})`);
    return rooms;
  }
}
