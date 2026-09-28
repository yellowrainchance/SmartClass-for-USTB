# 无课教室 · SmartClass for USTB

把北京科技大学「贝壳教学」的无课教室查询页，重写成一个 **HarmonyOS 原生应用**。

原站点是 PC 时代的 jQuery 页面：15 列硬栅格在手机上必然挤成一团，筛选栏与列表靠 DOM
字符串拼接联动。这个项目用 **ArkTS + ArkUI 从零重写**，不套 WebView，保留原有的查询
能力，同时把移动端体验补齐。

> 本项目为个人学习作品，**非学校官方应用**，与学校及其信息化部门无任何隶属或授权关系。
> 数据均来自学校对外公开的网页接口，仅供个人查询参考，不得用于任何商业用途。

---

## 功能

| 功能 | 说明 |
|---|---|
| 按节次查询 | 一天分六个大节次，逐节列出该时段空闲的教室 |
| 按时间段查询 | 全天 / 上午 / 下午 / 晚上四个时段，可**查询任意日期** |
| 实时空座率 | WebSocket 推送教室人数，卡片上的空座率随人走进教室而变 |
| 数据日期可见 | 列表上方的标题会写明「今日无课教室」或「2026-09-15 无课教室」 |
| 响应式栅格 | 窄屏 2 列 / 中屏 4 列 / 宽屏 6 列（原站是写死的 15 列） |
| 离线降级 | 刷新失败时保留上一份结果并给出提示，不会用错误页盖掉正看着的列表 |

## 技术要点

- **纯 ArkTS + ArkUI，零第三方依赖**（不加任何 `.har`）
- **严格单向分层**：View → ViewModel → Repository → platform
- 网络 `@kit.NetworkKit`（HTTP + WebSocket），持久化 `@kit.ArkData` 的 `preferences`
- 状态管理用 V1（`@State` / `@Link` / `@Observed` + `@ObjectLink`）
- 目标 SDK：HarmonyOS `26.0.0`（Stage 模型，`compatibleSdkVersion 6.1.1(24)`）

### 目录结构

```
entry/src/main/ets/
├── common/           常量、日志、字节与时间工具
├── model/            DTO、领域模型、枚举
├── service/          会话引导、HTTP 客户端、令牌、实时通道
├── repository/       元数据、教室查询、站点配置
├── viewmodel/        首页视图模型（唯一持有业务状态的地方）
├── view/             卡片与状态视图
└── pages/            首页、关于页
```

## 构建

需要 **DevEco Studio**（自带 HarmonyOS SDK 与 hvigor）。

```bash
# 命令行构建（Windows）
DEVECO_SDK_HOME="<DevEco Studio>/sdk" \
  "<DevEco Studio>/tools/node/node.exe" \
  "<DevEco Studio>/tools/hvigor/bin/hvigorw.js" \
  assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
```

产物：`entry/build/default/outputs/default/entry-default-unsigned.hap`

> **签名需要你自己配。** 本仓库的 `build-profile.json5` 里**没有** `signingConfigs`
> —— 原来那份指向个人证书路径与口令，已在上传前移除。
> 用 DevEco Studio 打开工程，`File → Project Structure → Signing Configs`
> 勾选「Automatically generate signature」即可；命令行构建只能产出未签名 HAP。

## 关于 Release 里的 HAP

Release 附带的 `SmartClass-for-USTB-v1.0.0-unsigned.hap` 是**未签名**产物，
由 `assembleHap` 生成（`buildMode=debug`）。请注意：

- **它不能直接安装。** HarmonyOS 要求 HAP 必须带签名才能通过 `hdc install`。
  未签名包只适合用来验证打包结果、查看资源与 `module.json`、或作为二次签名的输入。
- **自行签名的方式**：用 DevEco Studio 打开本工程 → 配好 Signing Configs →
  Build → Build Hap(s)。产出的 `entry-default-signed.hap` 才能装机。
- **包里没有个人隐私**：`ets/sourceMaps.map` 里全是相对路径（`src/main/ets/...`），
  `ets/modules.abc`、`module.json`、`pack.info` 中均不含用户名、主目录或设备信息。

校验（SHA-256）：

```
b77cfaa2d8cf5fecf8ea762241f98754393f49970ca27271bc35bc356e56cee0
```

`versionName=1.0.0` · `bundleName=com.example.smartclass` · `targetAPIVersion=26`

## 实现中的几个取舍

这些是逆向原站时踩过的坑，写下来免得后人（包括我自己）重犯：

1. **「按节次」接口不接受日期。** 它的请求体只有 `{buildingId, cycleTypeId, nodeId}`，
   响应里的日期部分是固定占位值 `2000-01-01` —— 这层数据结构根本不表达「哪一天」。
   所以「按节次」永远只反映当前时刻所在的这一天，界面上对应的日期控件会显式禁用并给出
   解释，而不是让它看起来能点。要查别的日期请用「全天 / 上午 / 下午 / 晚上」。

2. **楼栋与节次类型按原站白名单过滤。** 接口会多返回一个楼栋（教室名形如 `S302`）和
   一节「小节次」，但原站前端在特定学校分支下把这两个列表**整个覆盖**成写死的项，
   页面上从来选不到。本项目同样不展示它们。

3. **空座率在非上课时段会显示 `--`。** 服务端此时不返回该字段，原站的判定是
   `v.noSeatRate ? … : '--'`，本项目逐字照抄 —— 缺失就说缺失，不编数字。

4. **实时推送与 REST 是两条路径，缺失语义不同。** REST 路径缺失渲染 `--`，推送路径
   缺失渲染 `0%`（原站如此）。两条都照抄，并在 ViewModel 里归一到展示文案。

5. **日期标题是验收项，不是装饰。** 筛选条件生效却在界面上看不见，用户就会认定
   「这功能没用」—— 所以列表上方那行「哪天 + 无课教室」是必须有的。

## 关于接口

应用需要访问站点配置接口、元数据接口与教室查询接口，以及一条 WebSocket 实时通道。
站点已于 2026-09 停止服务，因此**本仓库不附带任何抓取下来的页面、脚本或接口快照**，
也不包含任何密钥、证书或账号信息。

代码里保留了 AES 参数与请求签名算法的实现（原站前端所用），仅供研究学习。
如果你要基于本项目接入别的部署实例，需要自行取得对应配置。

## 许可

以学习交流为目的开源。应用图标为本项目设计。原站页面及其第三方资源的版权归各自所有者。
