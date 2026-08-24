# Trace artifact manifest

## Durable exports

本机 durable export root：

`/Users/lmz/Documents/Vibe Coding/COCHelper-perf-artifacts/issue-209/2026-08-24`

本目录包含 26 个 trace label 的 TOC/导出表副本，共 110 个文件、约 14MB。目录名与下面的 label 一一对应：

- scenario traces：`base-s01-cold`、`base-s01-hot`、`base-s02-cold`、`base-s02-hot`、`base-s03-cold`、`base-s03-hot`、`base-s04-cold`、`base-s04-hot`、`base-s05-cold`、`base-s05-hot`、`post-s01-cold`、`post-s01-hot`、`post-s02-cold`、`post-s02-hot`、`post-s03-cold`、`post-s03-hot`、`post-s04-cold`、`post-s04-hot`、`post-s05-cold`、`post-s05-hot`
- trigger traces：`trigger-60s`、`trigger-import`、`trigger-pagination`、`trigger-pagination-after`
- memory attempts：`allocations-attach`、`allocations-launch`

每个目录按可用性包含 `toc.xml`、`hitches-summary.xml`、`hitches.xml`、`signposts.xml` 和/或 `time-profile.xml`。缺失的表没有被补造。

## Raw trace source

完整 `.trace` package 仍保留在本机 `/var/folders/6d/67gyq_097bs4x6hrk22c_s040000gn/T/` 下，以每个 label 对应的 `cochelper-209-final-*` 目录命名，review 期间不删除。由于单个 package 可达 GB 级，本 PR 不把 raw package 提交 Git，也不把它复制成重复的大文件。

## Re-audit commands

对仍存在的 raw package，可重新导出 TOC 和目标表：

```bash
xcrun xctrace export --input "$TRACE" --toc --output "$ROOT/toc.xml"
xcrun xctrace export --input "$TRACE" \
  --xpath '/trace-toc/run[1]/data/table[@schema="hitches"]' \
  --output "$ROOT/hitches-summary.xml"
xcrun xctrace export --input "$TRACE" \
  --xpath '/trace-toc/run[1]/data/table[@schema="hitches-frame-lifetimes"]' \
  --output "$ROOT/hitches.xml"
xcrun xctrace export --input "$TRACE" \
  --xpath '/trace-toc/run[1]/data/table[@schema="os-signpost-interval"]' \
  --output "$ROOT/signposts.xml"
```

`hitches-summary.xml` 的最长 hitch 只从 `hitches/duration` 读取；`hitches-frame-lifetimes` 最大值不能替代 longest hitch。
