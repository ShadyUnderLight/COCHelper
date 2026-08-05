# 渲染路径决策（Issue #30 Task 0）

> 日期：2026-08-05 ｜ 分支：`feat/issue30-render-path`
> 关联：Issue #27（spike + 契约，已合并 #29）、#25（逐级图标 UI 接入，被本决策解锁）
> 本文件记录路径选择的**证据**与**结论**；渲染链实现与样本验证见本分支其余提交。

## 候选与依据

### A：路径 C——构建时使用 ClashKing CDN（assets.clashk.ing）

| 项 | 证据（2026-08-05 实测） |
|---|---|
| CDN 可用性 | `https://assets.clashk.ing/manifest.json` 可访问，2585 个资产（webp 2027 / png 544），有可编程 manifest（path/display_name/category/url） |
| **key 映射覆盖率** | catalog 381 个唯一 `(container, exportName)` 引用，3 种映射策略全部 **0 命中**：① exportName 精确匹配 display_name/path；② 去前缀（`icon_unit_barbarian`→`barbarian`）；③ level 归一化（`fireplace_lvl1`→`fireplace/level_1`） |
| 命名体系 | CDN 用用户可读展示名（`troops/archer/icon.webp`、`buildings/builder-base/air_bombs/level_1.webp`）；catalog 用内部 export 名（`BB_xbow_lvl1`、`Freeze_trap_armed`、`_th18_upgrade_lvl1_idle1`）——需要额外建立 display_name↔export 名映射（依赖 APK 文本表），且映射成本不可控 |
| 覆盖度 | CDN buildings 796 / troops 96 / heroes 8 / pets 12，明显是 ClashKing 网站精选资产集，非完整导出；catalog 引用中 `Freeze_trap_armed`、`Shrink_trap_armed`、`_th18_upgrade_lvl1_idle1` 等动态/过渡外观大概率缺失 |
| 版本对应 | CDN 资产对应哪个游戏版本未公开声明；18.400.13 对齐无法验证 |
| 其他 | 构建时网络依赖（与"本地优先"方向相悖）；CDN 资产同为 Supercell 版权，许可边界与自渲染相同但多一层来源不确定性 |

### B：路径 B——仓库内原生渲染链（选中）

| 项 | 证据 |
|---|---|
| 可行性 | #27 spike（#29）已打通 SC2 V6 容器解析：头/descriptor/export 名/zstd body/6 chunk；引用链 100% 指向 MovieClip 已确认（ui.sc 3018/3018、buildings.sc 3130/3130） |
| 公开参考 | sc-workshop/SupercellFlash（MIT）schema + C++ 参考已拉取；MovieClip/Shape/DataStorage/Textures 结构已知（partial 支持，以真实字节对拍） |
| 工作量可控 | 唯一渲染键仅 **381 个**（item 级唯一引用口径；level 级唯一键 1269，catalog 5479 条 level 记录去重后，口径差异见契约 §12.1），ASTC 局部解码避免整张 4096×4096 大纹理全解码 |
| 双阻塞可解 | 阻塞 1（MovieClip 引用链）→ 本分支实现帧解析；阻塞 2（ASTC/KTX/SCTX）→ 本分支实现解码器 |
| 契约冻结 | renderedPath 契约 R1–R12 已冻结，渲染无关条目生效；本分支只需实测回写 R3/R4 |

### B'：仅 UI icon 子集 + 建筑外观 deferred（否决）

- 建筑/陷阱等级外观（`fireplace_lvl1`、`blacksmith_lvl1` 等）是 #25 验收标准「逐级 levelVisual」的必需部分，拆出去不省实现成本（解析链/ASTC 解码器是同一套），反而增加两次契约回写。

## 投票结论

**reject A（路径 C），选 B（仓库内渲染链）**。

- 否决理由核心：CDN key 映射覆盖率 **0/381**（2026-08-05 实测，方法见下），映射/版本/覆盖度三重不可控，且引入构建时网络依赖。
- B 的剩余工作是已明确的技术任务：MovieClip 帧解析、ASTC/KTX/SCTX 解码、bounds 光栅化——均有公开参考与真实数据可对拍。

## 复现证据

方法（`/tmp/cdn_coverage.py`，一次性脚本，未入库）：

```python
# 输入：catalog.json 唯一 (container, exportName) 集合 = 381
#       clashking manifest.json = 2585 资产（path/display_name）
# 策略 1：exportName.lower() in {display_name.lower()} ∪ {path.lower()}  → 0 命中
# 策略 2：去 icon_/img_/visual_/upgrade_/skin_ 前缀后再匹配              → 0 命中
# 策略 3：`^(.+?)_lvl(\d+)$` 归一化（base/level_N/level_N.webp）        → 0 命中
# 结果：381/381 未命中（0.0%）
```

未命中样例：`('sc/buildings.sc', 'BB_xbow_lvl1')`、`('sc/buildings.sc', 'Freeze_trap_armed')`、`('sc/buildings.sc', '_th18_upgrade_lvl1_idle1')`、`('sc/buildings.sc', 'blacksmith_lvl1')`。

## 非目标（沿用 issue #30）

- 不修改 `UpgradeDisplayRow`、`LevelDetailSheet` 等 SwiftUI 页面（#25 范围）
- 不提交 APK / 原始游戏资源包；/tmp 输出不入库
- 不修改账号解码、村庄投影、升级计时、Builder/Lab 语义
