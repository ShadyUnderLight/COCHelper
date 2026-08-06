#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}/.."
cd "$project_dir"

print "请输入 Clash of Clans API token。输入不会显示，也不会写入仓库。"
read -r -s token
print

if [[ -z "$token" ]]; then
    print -u2 "FAILED: token 不能为空"
    exit 2
fi

printf '%s' "$token" | swift run smoke-api --configure
unset token

print "Token 已保存到 macOS Keychain，开始验证官方 API 连通性。"
exec swift run smoke-api
