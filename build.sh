#!/usr/bin/env sh
# ============================================================================
# build.sh —— Linux / macOS / WSL / git-bash 构建：测试 -> 打包
#   sh build.sh
# ============================================================================
set -e
cd "$(dirname "$0")"

echo '== 1/2 主机侧测试 =='
sh tests/run_tests.sh

echo '== 2/2 打包 =='
PY=''
for c in "${PYTHON:-}" python3 python py; do
	[ -n "$c" ] || continue
	if command -v "$c" >/dev/null 2>&1; then
		PY=$c
		break
	fi
done
[ -n "$PY" ] || {
	echo '找不到 python3 / python / py。用 PYTHON=/path/to/python sh build.sh 指定'
	exit 1
}
"$PY" tools/pack.py

echo
echo '产物在 dist/，Magisk app 里「从本地安装」直接选这个 zip'
