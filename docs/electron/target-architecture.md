# Electron 重写目标架构（E0-02 冻结）

> Issue #265 交付物。本文冻结纯 Electron 终态的模块边界与现有 Swift 实现的对应关系，
> 作为 #266/#267/#268 及 E2-* 的引用基线。**本文不决定** SQLite、事件溯源、状态管理框架等
> 具体技术选型（Issue #265 非目标）。
>
> 契约章节编号规则：`WA-x`（wire/data）、`BE-x`（behavior）、`ER-x`（error）。
> 下游 issue 引用格式示例：「见 wire-contract-v1.md §WA-3」。

## 1. 终态形态定义

「纯 Electron」= 最终发布包与主分支不包含 Swift runtime、Swift helper、native addon 或旧 Swift
fallback（总控 Issue #264）。迁移期间旧 Swift 实现仅作为行为参考与 golden oracle，
不得进入终态运行链路。

## 2. 目标进程结构

```text
Electron Main（权威态）
├─ AppState / command handlers          ← 现 AppModel.swift 的编排职责
├─ file stores + journal recovery       ← 现 VillageStore / SnapshotHistoryStore /
│                                          ManualTrackerStore + *Transaction.swift
├─ API client / retry / cancellation    ← 现 CoAPIClient / EndpointRefresher / *Refresher
├─ secret store（safeStorage）          ← 现 CoAPITokenStore（Keychain）
└─ UtilityProcess                       ← 解析 / canonicalization / 投影等纯计算
Preload
└─ typed contextBridge API              ← renderer 无 Node.js、无裸 ipcRenderer
packages/
├─ wire        ← lossless JSON、BigInt、日期、canonical JSON、SHA-256、饱和算术（#267）
├─ domain      ← Clock/UUID seam + 投影、diff、对账、容量语义
├─ contracts   ← Result、错误/诊断、IPC 取消及本目录文档对应的类型定义
└─ testkit     ← Swift oracle / golden parity 框架（Issue #268）；含可重放 Clock/随机 seam
```

## 3. 现有 Swift 边界 → 终态归属映射

| 现有边界 | 规模职责 | 终态归属 |
|---|---|---|
| `Sources/COCHelperCore` | 解析、canonicalization、投影、对账、容量、分页合并等纯计算，**以及**文件持久化 store（SnapshotHistoryStore / ManualTrackerStore）与 URLSession HTTP client（CoAPIClient） | 纯计算部分 → `wire` + `domain`（UtilityProcess 可运行）；store 与网络层 → Main process application services |
| `Sources/COCHelperApp` | 编排：AppModel、UserDefaults store、事务 journal、资源加载 | Main process application services |
| `Sources/COCHelper` | SwiftUI UI | React renderer（E4-01，#277） |
| `Tools/`（Python 目录管线 + Swift 验收工具） | catalog 生成、验收 gate、perf seed | Node 工具链（E6-01，#281 迁移并删 Swift） |
| `Tests/` | ~1,880 XCTest（main@f513a35 实测基线） | E1-02（#268）golden parity + TS 测试迁移 |

## 4. 持久化拓扑（现状冻结）

| 存储 | 载体 | 键/路径 | schemaVersion |
|---|---|---|---|
| 村庄列表 | UserDefaults blob | `coc-helper.villages.v1`（恢复副本 `.recovery` 后缀键） | 裸数组无 envelope；未来版本靠顶层声明字段识别（§BE-1.1） |
| 快照历史 | 文件 | `Application Support/COCHelper/snapshot-history-v1.json` | envelope=1, entry=1, observation=6, fingerprint/integrity=1 |
| 手动升级 tracker | 文件 | `manual-tracker-v1.json` | envelope/store/village 全 =1 |
| 官方端点缓存 ×4 | UserDefaults blob | `coc-helper.clans.v1` / `clan-wars.v1` / `clan-war-logs.v1` / `clan-capitals.v1` | 无版本（fail-open 组，§BE-1.4） |
| 跟踪部落 | UserDefaults blob | `coc-helper.tracked-clans.v1` | 无版本（fail-open 组，§BE-1.5） |
| API token | Keychain | 不入 JSON / UserDefaults | — |

数据策略决策门（Issue #265）：默认不做长期兼容层、双写或双读。若必须保留旧 UserDefaults /
Application Support 文件 / Keychain token，另开一次性 importer；importer 不得进入正常运行路径。

## 5. 阶段依赖（引用本 epic 各 issue）

1. **E0-02（本 issue）**：冻结契约 + golden fixtures —— 下游一切验收的引用基线。
2. **E0-03（#266）**：Electron 工程、安全进程边界、CI bootstrap。
3. **E1-01（#267）**：实现 wire-contract-v1.md §WA-1…§WA-7，并冻结
   shared-primitives-v1.md 的跨层基础 seam。
4. **E1-02（#268)**：Swift oracle + golden parity 框架，直接消费 `Tests/Golden/` fixtures。
5. **E2-\*（#269–274）**：按 behavior-matrix.md / error-matrix.md 逐域迁移。

## 6. 验收锚点（对照 Issue #265 验收标准，本 PR 为阶段性状态）

| #265 验收标准 | 状态 | 说明 |
|---|---|---|
| 每个现有高风险状态有 confirmed output 或显式 unknown 处理 | ✅ 本 PR 完成 | behavior-matrix.md 各表含「盘上状态 × 行为」列；无法从代码确认的点标注 ⚠️ 待实证 |
| 关键 fixture 冻结 parser、**projection、diff**、**error** 和 encoded bytes | ⬜ **部分完成** | 已冻结：parser 指纹（F1/F2/F3）+ canonical encoded bytes + **HistoryEntryV1 / AccountSnapshot 的 JSONEncoder encoded bytes**（wire shape；snapshot 侧 `diagnostics[].id` 随机槽位按 §WA-5 掩码）+ catalog manifest 契约形状（§WA-9，活体 fixture = bundle 内 manifest.json）。**未冻结：projection / diff / error 场景 fixture**——由 E2-*（#269–274）在同一目录按域增量追加 |
| 数值/时间/fingerprint 正例、负例、边界例 | ✅ 本 PR 完成 | wire-contract-v1.md §WA 各节 + GoldenContractTests 用例分组 |
| 明确哪些旧 UI 只是历史实现、哪些用户可见语义必须保留 | ✅ 本 PR 完成 | behavior-matrix.md §BE-7 |

> **关闭门**：在 projection / diff / error 三类 golden fixture 补齐并冻结前，**不得关闭
> Issue #265**。本 PR 只主张上述表格中标记 ✅ 的部分。
