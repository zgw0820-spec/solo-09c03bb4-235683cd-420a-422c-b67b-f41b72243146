#!/usr/bin/env bash
# 复现 1：旧月长查询未结束时，本月日志照常写入；摘除并发推进，长查询结束后自动完成。
# 用法: BASE_URL=http://localhost:8000 ./scripts/demo_concurrent.sh
set -euo pipefail
BASE="${BASE_URL:-http://localhost:8000}"

say()  { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
jget() { python3 -c "import sys,json;d=json.load(sys.stdin);print($1)"; }

old_month() {  # 从状态接口取“非本月”的那个挂接月份
  curl -s "$BASE/api/state" | python3 -c "
import sys,json
d=json.load(sys.stdin)
ms=sorted(p['month'] for p in d['partitions'])
print(ms[0] if ms else '')"
}
wait_state() { # wait_state <month> <want> 轮询直到分区进入目标状态
  local m="$1" want="$2" got=""
  for _ in $(seq 1 60); do
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

say "0. 复位：确保旧月挂接、数据就绪"
curl -s -X POST "$BASE/api/reset" | jget "d"
OLD=$(old_month); echo "旧月 = $OLD"

say "1. 初始状态（旧月/本月均挂接）"
curl -s "$BASE/api/state" | jget "[(p['month'],p['state'],p['rows']) for p in d['partitions']]"
echo "在线查询（父表）总行数："
curl -s "$BASE/api/logs/online?limit=1" | jget "d['total']"

say "2. 模拟旧月长查询（90 秒，REPEATABLE READ 快照）"
curl -s -X POST "$BASE/api/simulate/long-query" -H 'Content-Type: application/json' \
  -d '{"seconds": 90}' | jget "d"
sleep 2

say "3. 长查询进行中发起旧月摘除（DETACH CONCURRENTLY）"
curl -s -X POST "$BASE/api/detach/$OLD" | jget "d"
wait_state "$OLD" pending

say "4. 摘除停在『待完成』期间，本月日志照常写入（关键验证：不应被阻塞）"
for i in 1 2 3; do
  curl -s -X POST "$BASE/api/logs/generate" -H 'Content-Type: application/json' \
    -d '{"count": 200}' | I=$i python3 -c "import sys,json,os;d=json.load(sys.stdin);print('  第%s次写入: inserted=%d, 服务端耗时=%.1fms' % (os.environ['I'], d['inserted'], d['elapsed_ms']))"
done
echo "  摘除会话正在等待旧快照（wait_event 应为 Timeout/VirtualXid 类等待）："
curl -s "$BASE/api/state" | jget "[(a['app'],a['state'],a['wait_type'],a['wait']) for a in d['activity']]"

say "5. 长查询结束（这里直接取消它），摘除第二阶段自动完成"
curl -s -X POST "$BASE/api/simulate/long-query/cancel" | jget "d"
wait_state "$OLD" detached

say "6. 摘下后：在线查询不再返回旧月，归档月表仍可单独查询"
echo "在线查询（父表）总行数 / 归档月表行数："
curl -s "$BASE/api/logs/online?limit=1" | jget "d['total']"
curl -s "$BASE/api/logs/archive/$OLD?limit=1" | jget "'%s -> %d 行, 状态 %s' % (d['table'], d['total'], d['state'])"

say "7. 幂等：已摘下的月份再次摘除，不再执行任何 SQL"
curl -s -X POST "$BASE/api/detach/$OLD" | jget "d"

say "完成：长查询不阻塞本月写入、摘除并发推进、摘下后在线/归档分离、重复摘除幂等"
