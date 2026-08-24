#!/bin/zsh
# Issue #226 release acceptance gate：自动化门禁（不含真实村庄 JSON，那部分走 acceptance-runner）。
set -euo pipefail

project_dir="${0:A:h}/../.."
cd "$project_dir"

# P1/Blocking：证据必须对应可追溯的 clean commit。gate 写入任何输出前先 fail on dirty worktree。
# results 目录是本工具的输出产物，允许在 gate 运行期间被覆写，因此 dirty 检查排除该路径。
if ! git diff --quiet -- . ':!Tools/acceptance/results'; then
  echo "错误: working tree 有未提交的修改（git diff，不含 results），证据无法对应到 clean commit。请先提交。" >&2
  git status --short >&2
  exit 1
fi
if ! git diff --cached --quiet -- . ':!Tools/acceptance/results'; then
  echo "错误: index 有已暂存但未提交的修改（git diff --cached，不含 results），请先提交。" >&2
  git status --short >&2
  exit 1
fi
# 未跟踪文件同样视为 dirty，但本工具产生的 results 目录除外（首次生成时为 untracked）。
untracked="$(git status --porcelain --untracked-files=normal | grep -v "Tools/acceptance/results" || true)"
if [[ -n "$untracked" ]]; then
  echo "错误: 存在未跟踪/未提交文件（除 results 外），请先提交或加入 .gitignore：" >&2
  echo "$untracked" >&2
  exit 1
fi

commit_sha="$(git rev-parse HEAD)"
date_stamp="$(date +%Y-%m-%d)"
results_dir="Tools/acceptance/results/${date_stamp}"
mkdir -p "$results_dir"

log="$results_dir/automated-gate.md"
tmp_out="$(mktemp)"

{
  echo "# Issue #226 自动化验收门禁"
  echo
  echo "- commit: \`${commit_sha}\`"
  echo "- date: ${date_stamp}"
  echo "- working tree: clean（已验证 git diff / diff --cached / untracked，不含 results）"
  echo "- macOS: $(sw_vers -productVersion) ($(uname -m))"
  echo "- swift: $(swift --version | head -1)"
  echo
} >"$log"

run_step() {
  local title="$1"
  shift
  echo "## ${title}" >>"$log"
  echo >>"$log"
  if "$@" >"$tmp_out" 2>&1; then
    echo '```text' >>"$log"
    tail -n 8 "$tmp_out" >>"$log"
    echo '```' >>"$log"
    echo >>"$log"
    echo "结果: **通过**" >>"$log"
  else
    echo '```text' >>"$log"
    tail -n 40 "$tmp_out" >>"$log"
    echo '```' >>"$log"
    echo >>"$log"
    echo "结果: **失败**" >>"$log"
    rm -f "$tmp_out"
    exit 1
  fi
  echo >>"$log"
}

run_step "AppModelSnapshotHistoryTests" \
  swift test --filter AppModelSnapshotHistoryTests

run_step "全量单 worker 测试" \
  swift test --parallel --num-workers 1

run_step "Release build" \
  swift build -c release

run_step "App bundle 组装" \
  scripts/build_app.sh

run_step "git diff --check" \
  git diff --check -- . ':!Tools/acceptance/results'

echo "## 真实村庄验收（本地数据）" >>"$log"
echo >>"$log"
if [[ -f Tools/acceptance/local/village-a-1.json ]]; then
  if env ACCEPTANCE_COMMIT_SHA="${commit_sha}" \
    swift run acceptance-runner Tools/acceptance/local \
    >"${results_dir}/real-village-acceptance.json" 2>"$tmp_out"; then
    echo "acceptance-runner: **通过**" >>"$log"
    echo "已写入 \`${results_dir}/real-village-acceptance.json\`" >>"$log"
  else
    echo '```text' >>"$log"
    cat "$tmp_out" >>"$log"
    echo '```' >>"$log"
    echo "acceptance-runner: **失败**" >>"$log"
    rm -f "$tmp_out"
    exit 1
  fi
else
  echo "跳过：\`Tools/acceptance/local/village-a-1.json\` 不存在。" >>"$log"
  echo "将真实 JSON 放入 \`Tools/acceptance/local/\` 后重新运行本脚本。" >>"$log"
fi

rm -f "$tmp_out"
echo "门禁日志: $log"
