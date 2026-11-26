#!/usr/bin/env bash
# 复位演练：
#   1) 正常复位（成功回执 reattached / recreated）；
#   2) 有“待完成”摘除时拒绝复位，提示先完成摘除；
#   3) 第二个月挂接失败样例：先挂回第一个月，第二个月因月界不符报错，
#      验证整次复位回滚、在线日志总行数不变。
# 用法: BASE_URL=http://localhost:8000 ./scripts/demo_reset.sh
set -euo pipefail
BASE="${BASE_URL:-http://localhost:8000}"
COMPOSE="${COMPOSE:-docker compose}"

say()  { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
jget() { python3 -c "import sys,json;d=json.load(sys.stdin);print($1)"; }
state() {
  curl -s "$BASE/api/state" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print('  挂接:', [(p['month'], p['state']) for p in d['partitions']])
print('  归档:', [(a['month'], a['rows']) for a in d['archives']])"
}
online_total() { curl -s "$BASE/api/logs/online?limit=1" | jget "d['total']"; }
old_month() {
  curl -s "$BASE/api/state" | python3 -c "
import sys,json
d=json.load(sys.stdin)
ms=sorted(p['month'] for p in d['partitions'] if p['month'] < d['now'][:7])
print(ms[0] if ms else '')"
}
wait_state() { # wait_state <month> <want>
  local m="$1" want="$2" got=""
  for _ in $(seq 1 40); do
    got=$(curl -s "$BASE/api/state" | python3 -c "
import sys,json
d=json.load(sys.stdin)
m='$m'
st=[p['state'] for p in d['partitions'] if p['month']==m]
if not st and any(a['month']==m for a in d['archives']): st=['detached']
print(st[0] if st else 'missing')")
    [ "$got" = "$want" ] && { echo "  -> $m 状态=$got"; return 0; }
    sleep 1
  done
  echo "  !! 等待 $m 变为 $want 超时（当前 $got）"; return 1
}

say "0. 初始状态"
state
OLD=$(old_month); echo "  旧月 = $OLD"

say "1. 摘除旧月后复位：成功回执保留 {reattached, recreated}"
curl -s -X POST "$BASE/api/detach/$OLD" >/dev/null
wait_state "$OLD" detached
echo "  复位回执：$(curl -s -X POST "$BASE/api/reset")"
state
[ "$(curl -s "$BASE/api/state" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(any(p['month']=='$OLD' and p['state']=='attached' for p in d['partitions']))")" = "True" ] \
  || { echo "  ✗ 旧月未重新挂接"; exit 1; }

say "2. 有“待完成”摘除时，复位应被拒绝（提示先完成摘除）"
curl -s -X POST "$BASE/api/simulate/long-query" -H 'Content-Type: application/json' \
  -d '{"seconds": 30}' >/dev/null
sleep 1
curl -s -X POST "$BASE/api/detach/$OLD" >/dev/null
wait_state "$OLD" pending
curl -s -w '\n  HTTP %{http_code}\n' -X POST "$BASE/api/reset"
curl -s -X POST "$BASE/api/simulate/long-query/cancel" >/dev/null
wait_state "$OLD" detached
curl -s -X POST "$BASE/api/reset" >/dev/null   # 让旧月挂回，为下一步准备

say "3. 造样例：给第二个月塞越界记录（第一个月为空表，先挂回它）"
$COMPOSE cp db/samples/reset_second_month_fails.sql db:/tmp/ >/dev/null
$COMPOSE exec -T db psql -U ops -d gateway -v ON_ERROR_STOP=1 \
  -f /tmp/reset_second_month_fails.sql
state
BEFORE=$(online_total); echo "  复位前在线总行数：$BEFORE"

say "4. 复位：应在第二个月挂接时报错，整次复位不生效"
HTTP=$(curl -s -o /tmp/reset_body.json -w '%{http_code}' -X POST "$BASE/api/reset")
echo "  HTTP $HTTP"; python3 -m json.tool /tmp/reset_body.json
state
AFTER=$(online_total); echo "  复位后在线总行数：$AFTER（应等于 $BEFORE）"
[ "$BEFORE" = "$AFTER" ] && echo "  ✓ 整次复位已回滚" || { echo "  ✗ 回滚失败"; exit 1; }

say "完成：正常复位保留原回执；待完成摘除时拒绝；第二个月失败时整次回滚并指明月份与原因"
