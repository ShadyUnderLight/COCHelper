# Native install 环境收口

## 背景

`fs-xattr` 与 `macos-alias` 是 DMG maker 的 native build 依赖。它们不属于应用运行时，也不应在普通 `pnpm install` 阶段执行编译；install 阶段的 node-gyp 日志可能记录完整进程环境。

## 规则

- `pnpm install` 只允许 Electron 与 esbuild 等必要安装脚本；
- `fs-xattr` / `macos-alias` 不进入 `allowBuilds`；
- `release:prepare` 在 DMG 构建前显式执行 node-gyp，并使用固定 allowlist 环境；
- 回归测试锁定 native addon 不得重新进入 install build allowlist。

## 验收

- clean install 不启动两个 native addon 的 install build；
- release prepare 的显式 native rebuild 仍可生成 `volume.node` / `xattr.node`；
- 日志不包含 runner 的凭据环境变量。
