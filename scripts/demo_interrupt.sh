#!/usr/bin/env bash
# 复现 2：摘除进行到一半服务重启（操作中断），重启后按数据库目录显示『待完成』，重试续做至摘下。
# 用法: BASE_URL=http://localhost:8000 ./scripts/demo_interrupt.sh
# 默认用 docker compose restart app 制造中断；可用 RESTART_CMD 覆盖（本地调试）。
set -euo pipefail
BASE="${BASE_URL:-http://localhost:8000}"
RESTART_CMD="${RESTART_CMD:-docker compose restart app}"

say()  { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
jget() { python3 -c "import sys,json;d=json.load(sys.stdin);print($1)"; }

old_month() {
  curl -s "$BASE/api/state" | python3 -c "
import sys,json
d=json.load(sys.stdin)
ms=sorted(p['month'] for p in d['partitions'])
print(ms[0] if ms else '')"
}
wait_state() {
  local m="$1" want="$2" got=""
  for _ in $(seq 1 90); do
    got=$(curl -s "$BASE/api/state" | python3 -c "
import sys,json
d=json.load(sys.stdin)
m='$m'
st=[p['state'] for p in d['partitions'] if p['month']==m]
if not st and any(a['month']==m for a in d['archives']): st=['detached']
print(st[0] if st else 'missing')" 2>/dev/null || echo unreachable)
    [ "$got" = "$want" ] && { echo "  -> $m 状态=$got"; return 0; }
    sleep 1
  done
  echo "  !! 等待 $m 变为 $want 超时（当前 $got）"; return 1
}
wait_up() {
  for _ in $(seq 1 60); do
    curl -sf "$BASE/api/health" >/dev/null 2>&1 && { echo "  -> 服务已恢复"; return 0; }
    sleep 1
  done
  echo "  !! 服务未恢复"; return 1
}

say "0. 复位：确保旧月挂接"
curl -s -X POST "$BASE/api/reset" | jget "d"
OLD=$(old_month); echo "旧月 = $OLD"

say "1. 启动长查询（300 秒）+ 发起摘除，使分区停在『待完成』"
curl -s -X POST "$BASE/api/simulate/long-query" -H 'Content-Type: application/json' \
  -d '{"seconds": 300}' | jget "d"
sleep 2
curl -s -X POST "$BASE/api/detach/$OLD" | jget "d"
wait_state "$OLD" pending

say "2. 制造中断：重启应用（客户端连接被掐断）"
echo "  执行: $RESTART_CMD"
eval "$RESTART_CMD" || true
wait_up

say "3. 重启后：内存作业已清空，分区状态仍由数据库目录给出"
curl -s "$BASE/api/state" | jget "[(p['month'],p['state']) for p in d['partitions']]"
curl -s "$BASE/api/state" | jget "'内存作业数: %d（重启即清）' % len(d['jobs'])"
echo "  注意：被杀客户端的服务端后端可能仍以僵尸会话存在（PG 默认不主动探活），"
echo "  后台活动里仍能看到它们在跑/在等："
curl -s "$BASE/api/state" | jget "[(a['app'],a['state'],a['wait_type'],a['wait']) for a in d['activity']]"

say "4. 清理僵尸长查询（按 application_name 取消服务端后端）"
curl -s -X POST "$BASE/api/simulate/long-query/cancel" | jget "d"

say "5. 重试摘除：若仍是待完成则走 FINALIZE；若僵尸摘除后端已抢先完成则幂等跳过"
curl -s -X POST "$BASE/api/detach/$OLD" | jget "d"
wait_state "$OLD" detached

say "6. 验证：在线查询不含旧月；归档月表仍在"
curl -s "$BASE/api/logs/online?limit=1" | jget "'父表总行数: %d' % d['total']"
curl -s "$BASE/api/logs/archive/$OLD?limit=1" | jget "'%s -> %d 行, 状态 %s' % (d['table'], d['total'], d['state'])"

say "完成：中断后状态以数据库为准，僵尸会话可清理，重试续做至摘下"
