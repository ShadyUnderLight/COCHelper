# Issue #246 Release App 内存证据

状态：已在 **Release `.build/COCHelper.app` 进程**上实测，不是 Core 层 probe。隔离 `HOME` / `CFFIXED_USER_HOME`，**不提交**真实历史 JSON / tag / token。

对照：issue 描述的 base 探针约为 **15.8 GB** `phys_footprint`（24 条历史 `load()`）。本 PR 的 Release App 进程在 idle 后约为 **100 MB** 量级。

## 环境

- commit：`68bc8d593c0bdf3ea0d121ce8fbe957d07533b4f`
- App：`.build/COCHelper.app`（`com.local.coc-helper`）
- 二进制：`.build/COCHelper.app/Contents/MacOS/COCHelper`（`swift build -c release` 组装）
- macOS：26.6.2 / arm64
- Swift：Apple Swift version 6.3.3
- idle：启动后至少 5 秒再采样 `footprint`
- 24 条历史：24 entries，4 586 265 bytes（仅从本机 Application Support **复制到隔离 HOME**，未入库）
- 1005 Wall：仓库内 paired fixture `perf_account_snapshot_large_walls_{before,after}.json`

## 方法

1. **24 条历史 load（两次）**  
   把本地 24 条 `snapshot-history-v1.json` 拷进隔离 HOME，启动 Release App 进程，idle 后采 `phys_footprint`，退出后再启动一次。
2. **1005 Wall import + load（两次）**  
   Accessibility 点击账号数据页在本机无窗口索引（`osascript` 看不到 window），因此导入改走 **AppModel.parseAccountText + applyPendingAccountSnapshot**（与「解析文本 / 应用快照」同一代码路径），写入隔离 HOME；再启动 Release App 加载该历史并 idle。导入顺序：before → after → after（第二次 after 覆盖 duplicate/连续 import）。然后 App load 连续两次。

原始 `footprint` JSON 只留在本机临时目录，不入库。入库文件只有脱敏摘要。

## 24 条历史 load（Release App 进程 → idle ≥5s）

| pass | phys_footprint | RSS |
|---|---:|---:|
| 1 | 105.6 MB | 194.8 MB |
| 2 | 103.0 MB | 192.2 MB |

相对 base ~15.8 GB：约 **150×** 下降。两次 load 没有单调涨到 GB。

## 1005 Wall（AppModel 导入后 Release App 加载 → idle ≥5s）

- 导入：`AppModel.parseAccountText` + `applyPendingAccountSnapshot`（before / after / after-duplicate）
- 加载：Release App 进程读隔离 HOME 中的 history 文件

| pass | phys_footprint | RSS |
|---|---:|---:|
| 1 | 89.2 MB | 185.2 MB |
| 2 | 100.6 MB | 200.7 MB |

两次 load 差约 11 MB，不是 GB 级泄漏。

## 门禁对照

- [x] 24 条历史 Release App `phys_footprint` 远低于 2 GB，且不是两位数 GB
- [x] 连续两次相同 load 不单调涨到 GB
- [x] 1005 Wall 导入 + Release App 加载峰值远低于 2 GB
- [x] 不提交账号原文、token、cookie、原始 Tag
- [ ] Accessibility 驱动的账号数据页点击导入：本机 System Events 对隔离启动的进程 `windows=0`，未作为本次证据

复现：`Tools/perf/measure_issue246_release_app_memory.sh`
