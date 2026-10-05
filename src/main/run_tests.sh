#!/usr/bin/env bash
# WebDAV 客户端一键测试：
#   1. 启动 WebDAV 服务端（优先 brew 的 webdav，回退 testdata/verify_server.py）
#   2. 执行全套测试（moon test：单元 + 黑盒，Mock 传输层不触网）
#      与真实测试（moon run src/main：连接刚启动的服务端跑全流程 + 真实文件往返）
#   3. 关闭 WebDAV 服务端并汇总展示测试结果
#
# 用法：bash src/main/run_tests.sh
# 可用 WEBDAV_PORT 覆盖端口（默认 8082）。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

PORT="${WEBDAV_PORT:-8082}"
URL="http://127.0.0.1:$PORT/"
WORK="$(mktemp -d /tmp/webdav-test.XXXXXX)"
SERVER_PID=""
SERVER_KIND=""

cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    echo "▸ WebDAV 服务端（${SERVER_KIND}）已关闭"
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# ---------- 1. 启动 WebDAV 服务端 ----------
mkdir -p "$WORK/data"
if command -v webdav >/dev/null 2>&1; then
  SERVER_KIND="brew webdav (hacdias)"
  # 注意：v5 的权限字母是 C/R/U/D，旧版 R/W/D 会启动失败
  cat > "$WORK/server.yml" <<EOF
address: 127.0.0.1
port: $PORT
directory: $WORK/data
users:
  - username: demo
    password: demo
    permissions: CRUD
EOF
  webdav -c "$WORK/server.yml" > "$WORK/server.log" 2>&1 &
else
  SERVER_KIND="python3 verify_server"
  python3 "$SCRIPT_DIR/testdata/verify_server.py" "$PORT" "$WORK/data" \
    > "$WORK/server.log" 2>&1 &
fi
SERVER_PID=$!

ready=0
for _ in $(seq 1 30); do
  if curl -s --noproxy '*' -o /dev/null -X OPTIONS "$URL"; then
    ready=1
    break
  fi
  sleep 0.3
done
if [ "$ready" != 1 ]; then
  echo "✗ WebDAV 服务端未能启动（${SERVER_KIND}），日志："
  cat "$WORK/server.log"
  exit 1
fi
echo "▸ WebDAV 服务端已启动：$SERVER_KIND @ $URL"
echo

fail_count=0

# ---------- 2. 全套测试（Mock 传输层，不触网）----------
echo "──────── 阶段 1／2：全套单元与黑盒测试（moon test）────────"
MOON_TEST_OUT="$(moon test 2>&1 | grep -v 'libtool:')"
echo "$MOON_TEST_OUT" | tail -n 3
if echo "$MOON_TEST_OUT" | grep -q "failed: 0"; then
  echo "▸ 阶段 1 结果：PASS"
else
  echo "▸ 阶段 1 结果：FAIL"
  echo "$MOON_TEST_OUT" | tail -n 30
  fail_count=$((fail_count + 1))
fi
echo

# ---------- 3. 真实测试（连服务端跑全流程 + 真实文件往返）----------
echo "──────── 阶段 2／2：真实服务器全流程（moon run src/main）────────"
DEMO_OUT="$(WEBDAV_URL="$URL" WEBDAV_USER=demo WEBDAV_PASS=demo \
  WEBDAV_TESTDATA="$SCRIPT_DIR/testdata" \
  moon run src/main 2>&1 | grep -v 'libtool:')"
echo "$DEMO_OUT"
echo
if echo "$DEMO_OUT" | grep -q "✗"; then
  echo "▸ 阶段 2 结果：FAIL"
  fail_count=$((fail_count + 1))
else
  echo "▸ 阶段 2 结果：PASS"
fi

# ---------- 4. 汇总（服务端由 trap 在退出时关闭）----------
echo
if [ "$fail_count" -eq 0 ]; then
  echo "✔ 全部测试通过"
  exit 0
else
  echo "✘ 有 $fail_count 个阶段失败（详见上方输出）"
  exit 1
fi
