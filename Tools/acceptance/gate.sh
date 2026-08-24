#!/bin/zsh
# Issue #226 release acceptance gate：自动化门禁（不含真实村庄 JSON，那部分走 acceptance-runner）。
set -euo pipefail

project_dir="${0:A:h}/../.."
cd "$project_dir"

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
  git diff --check

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
