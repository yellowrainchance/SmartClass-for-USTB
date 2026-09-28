import { Constants } from '../common/Constants';
import { Logger } from '../common/Logger';
import { BuildingDto, NodeDto, NodeTypeDto } from '../model/ApiTypes';
import { HttpClient } from '../service/HttpClient';

/** 只用来表达「这个 DTO 有 id」——给白名单过滤器用。 */
interface HasId {
  id: string;
}

/**
 * 元数据仓库：节次类型 / 节次 / 楼栋。
 *
 * ⚠️ **楼栋与节次类型按白名单过滤，不是接口给什么就显示什么。**
 *
 * 原站（`schoolFlag == 'ustb'`）在初始化下拉时把这两个列表**整个覆盖**成写死的
 * 几项：楼栋只有教学楼/逸夫楼/智慧教室/学院楼，节次类型只有「默认节次」。
 * 接口里多出来的「南楼」与「小节次」在网页上从来不会出现。
 *
 * 本项目照此处理（见 `Constants.BUILDING_WHITELIST_IDS` 的注释）：
 * 目标是忠实还原原站，不做"比原站更全"的改造。
 * 唯一的加固是**回退**：白名单一个都没匹配上时用接口全量，避免站点换 id 后
 * 应用直接变空壳 —— "多显示几栋楼"只是不够忠实，空列表是彻底不能用。
 */
export class MetaRepository {
  private readonly http: HttpClient;

  constructor(http: HttpClient) {
    this.http = http;
  }

  async listNodeTypes(): Promise<NodeTypeDto[]> {
    const all: NodeTypeDto[] = await this.http.getEnvelope<NodeTypeDto[]>(Constants.PATH_NODE_TYPES);
    const list: NodeTypeDto[] = MetaRepository.applyWhitelist(all, Constants.NODE_TYPE_WHITELIST_IDS);
    Logger.tag('Meta',
      `节次类型 ${list.length}/${all.length} 个: ${list.map((t: NodeTypeDto) => t.name).join('/')}`);
    return list;
  }

  /** nodeTypeId 为空时服务端返回全部节次。 */
  async listNodes(nodeTypeId: string): Promise<NodeDto[]> {
    const path: string = `${Constants.PATH_NODES}?nodeTypeId=${encodeURIComponent(nodeTypeId)}`;
    const list: NodeDto[] = await this.http.getEnvelope<NodeDto[]>(path);
    Logger.tag('Meta', `节次 ${list.length} 个 (nodeTypeId=${nodeTypeId})`);
    return list;
  }

  async listBuildings(): Promise<BuildingDto[]> {
    const all: BuildingDto[] = await this.http.getEnvelope<BuildingDto[]>(Constants.PATH_BUILDINGS);
    const list: BuildingDto[] = MetaRepository.applyWhitelist(all, Constants.BUILDING_WHITELIST_IDS);
    Logger.tag('Meta',
      `楼栋 ${list.length}/${all.length} 个: ${list.map((b: BuildingDto) => b.name).join('/')}`);
    return list;
  }

  /**
   * 按白名单过滤，并**按白名单顺序**重排（顺序即界面上的下拉顺序，原站是写死的）。
   *
   * 白名单为空、或一项都没匹配上 → 原样返回全量。理由见类注释。
   */
  private static applyWhitelist<T extends HasId>(all: T[], order: string[]): T[] {
    if (order.length === 0) {
      return all;
    }
    const out: T[] = [];
    for (const id of order) {
      for (const item of all) {
        if (item.id === id) {
          out.push(item);
          break;
        }
      }
    }
    return out.length > 0 ? out : all;
  }
}
