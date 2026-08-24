# Issue #246 Release App 内存证据

## 证据范围（合并声明）

本文件**只证明**：

- Release App 进程加载 24 条历史后，idle `phys_footprint` 从约 15.8 GB 降到约 100 MB。
- 1005 Wall 经 AppModel 导入路径写入 history 后，Release App 再 load 的 idle `phys_footprint` 约 90–100 MB。
- 连续两次相同 load 没有涨到 GB。

本文件**不证明** Issue #246 原文中的这些条款，也不把它们当作本 PR 的合并门禁：

- 账号数据页真实点击导入
- Diff / UI 展开
- 导入或完整 UI 流程的 peak `phys_footprint`

Accessibility 对隔离启动的进程报告 `windows=0`，因此没有账号数据页点击样本。

## 环境

- 实测 commit：`68bc8d593c0bdf3ea0d121ce8fbe957d07533b4f`（该 commit 含 `Sources/` / `Tests/` 修复）
- 其后的 `f1af617`、`0822dc2` 以及本报告提交只改 CI / 工具 / 证据，不改 `Sources/` 或 `Tests/`，因此上述数字仍对应当前修复后的 App 二进制
- App：`.build/COCHelper.app`（`com.local.coc-helper`）
- 二进制：`.build/COCHelper.app/Contents/MacOS/COCHelper`（`swift build -c release` 组装）
- macOS：26.6.2 / arm64
- Swift：Apple Swift version 6.3.3
- 采样：启动后至少 idle 5 秒再采 `footprint`（idle，不是导入 peak）
- 24 条历史：24 entries，4586265 bytes（从本机 Application Support 复制到隔离 HOME，未入库）
- 1005 Wall：仓库内 paired fixture `perf_account_snapshot_large_walls_{before,after}.json`

隔离 `HOME` / `CFFIXED_USER_HOME`。不提交真实历史 JSON / tag / token。

## 方法

1. 24 条历史 load（两次）

   把本地 24 条 `snapshot-history-v1.json` 拷进隔离 HOME，启动 Release App 进程，idle 后采 `phys_footprint`，退出后再启动一次。

2. 1005 Wall import + load（两次）

   导入走 `AppModel.parseAccountText` + `applyPendingAccountSnapshot`（与「解析文本 / 应用快照」同一代码路径），写入隔离 HOME。顺序：before → after → after（第二次 after 覆盖 duplicate / 连续 import）。再启动 Release App 加载该历史并 idle，连续两次。

原始 `footprint` JSON 只留在本机临时目录。入库文件只有脱敏摘要。

## 24 条历史 load（Release App 进程 → idle ≥5s）

| pass | phys_footprint | RSS |
|---|---:|---:|
| 1 | 105.6 MB | 194.8 MB |
| 2 | 103.0 MB | 192.2 MB |

相对 base ~15.8 GB：约 150× 下降。两次 load 没有单调涨到 GB。

## 1005 Wall（AppModel 导入后 Release App 加载 → idle ≥5s）

- 导入：`AppModel.parseAccountText` + `applyPendingAccountSnapshot`（before / after / after-duplicate）
- 加载：Release App 进程读隔离 HOME 中的 history 文件
- 未覆盖：账号数据页点击、Diff、UI 展开、导入过程 peak

| pass | phys_footprint | RSS |
|---|---:|---:|
| 1 | 89.2 MB | 185.2 MB |
| 2 | 100.6 MB | 200.7 MB |

两次 load 差约 11 MB，不是 GB 级泄漏。

## 门禁对照

- [x] 24 条历史 Release App idle `phys_footprint` 远低于 2 GB，且不是两位数 GB
- [x] 连续两次相同 load 不单调涨到 GB
- [x] 1005 Wall 经 AppModel 导入后，Release App load 的 idle `phys_footprint` 远低于 2 GB
- [x] 不提交账号原文、token、cookie、原始 Tag
- [ ] 账号数据页点击导入
- [ ] Diff / UI 展开
- [ ] 导入或完整 UI 流程的 peak `phys_footprint`

复现：`Tools/perf/measure_issue246_release_app_memory.sh`
