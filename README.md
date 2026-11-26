# 网关日志分区运维台（FastAPI + PostgreSQL 16）

网关日志按月分区（PostgreSQL 声明式分区）。旧月退出在线查询时，用
`ALTER TABLE ... DETACH PARTITION ... CONCURRENTLY` 把旧月分区从父表摘除：
在线查询立即不再返回旧月，原月表保留为独立表供故障追溯，摘除过程不阻塞本月写入。

## 快速启动

```bash
docker compose up --build
# 运维页面: http://localhost:8000
# PostgreSQL: localhost:5432 (ops/ops, 库 gateway)
```

首次启动时 `db/init/01_init.sql` 自动：

- 创建分区父表 `gateway_logs`（按 `ts` 范围分区）；
- 预置**一个不再补写的旧月分区**（上月，3000 行样例）和**本月分区**（800 行样例）；
- 创建 `partition_registry` 注册表，记录各月边界（供复位/重新挂接使用）。

## 运维页面功能

- **分区状态**：挂接中 / 待完成 / 已摘下，每 3 秒刷新，完全来自数据库系统目录
  （`pg_inherits.inhdetachpending`），应用重启后依然准确。
- **摘除旧月**：点击"摘除该月"发起 `DETACH ... CONCURRENTLY`；停在"待完成"时
  按钮变为"重试完成摘除"（走 `DETACH ... FINALIZE`）；已摘下的月份不再提供操作。
- **写入本月日志**：验证摘除等待期间本月写入不受阻（页面显示服务端耗时）。
- **模拟旧月长查询 / 取消**：复现"长查询拖住摘除第二阶段"的场景。
- **在线查询**：`SELECT ... FROM gateway_logs`（父表，只含仍挂接的分区）。
- **归档查询**：直接查某月物理表（如 `gateway_logs_2026_10`），摘下后仍可追溯。
- **复位**：把已摘下的月份重新 `ATTACH` 回去，便于反复演练。

## 状态与数据库目录的对应

| 页面状态 | 数据库实际状态 | 摘除按钮行为 |
|---|---|---|
| 挂接中 attached | `pg_inherits` 有行且 `inhdetachpending=false` | 执行 `DETACH ... CONCURRENTLY` |
| 待完成 pending | `pg_inherits` 有行且 `inhdetachpending=true` | 执行 `DETACH ... FINALIZE`（重试续做） |
| 已摘下 detached | `pg_inherits` 无行，物理表仍在 | 不执行任何 SQL，直接返回（幂等） |

注意："待完成"状态下新查询就已经查不到旧月（分区描述符已将其排除），
但目录上仍挂接，需重试完成摘除才算彻底退出。

## 复现脚本

```bash
# 复现 1：旧月长查询未结束时，本月日志照常写入；摘除并发推进
./scripts/demo_concurrent.sh

# 复现 2：摘除中途重启服务（操作中断），重启后按目录显示"待完成"，重试续做
./scripts/demo_interrupt.sh
```

脚本默认打 `http://localhost:8000`，可用 `BASE_URL` 覆盖；
`demo_interrupt.sh` 默认用 `docker compose restart app` 制造中断，可用 `RESTART_CMD` 覆盖。

## 关键机制与实测发现

1. **DETACH CONCURRENTLY 是两阶段提交**（PG 14+）：
   第一阶段以 `SHARE UPDATE EXCLUSIVE` 锁父表（不阻塞读写），把分区标记为
   `inhdetachpending=true` 后提交；第二阶段等待所有可能引用旧分区的老快照消失，
   再删除目录行。实测：长查询（REPEATABLE READ 快照）期间，摘除停在"待完成"，
   本月 200 行写入约 7~16ms 返回，完全不受阻；`pg_stat_activity` 中可见
   摘除会话等待 `Lock/virtualxid`、长查询等待 `Timeout/PgSleep`。

2. **杀掉客户端 ≠ 取消服务端操作**：PG 默认 `client_connection_check_interval=0`，
   发起摘除的客户端（应用进程）被杀后，处于第二阶段等待中的服务端后端不会察觉，
   快照条件满足后摘除**仍会在服务端完成**。同理，长查询后端也会作为"僵尸会话"
   继续存活。因此重启后必须以数据库目录状态为准（本应用正是这样做的），
   页面"后台活动"面板能看到这些僵尸会话，并可用"取消长查询"清理
   （按 `application_name` 定位，不依赖应用内存）。

3. **FINALIZE 与轮询的死锁坑（已规避）**：`FINALIZE` 等待老快照时持有被摘分区的
   `ACCESS EXCLUSIVE` 锁；任何"先持快照、再请求该分区锁"的事务都会与它死锁，
   且死锁检测会牺牲 FINALIZE。实测发现连 `pg_get_expr(relpartbound, oid)`
   （查看分区边界）都会打开分区表加 `AccessShareLock`。规避措施：
   - 状态轮询只读系统目录，分区边界改从 `partition_registry` 取，绝不打开分区表；
   - 行数统计走独立连接并设 `lock_timeout=800ms`（小于 `deadlock_timeout=1s`），
     拿不到锁就退让显示"—"，保证与摘除竞争时永远是轮询方退出；
   - 归档查询同样带 `lock_timeout`，撞锁时返回 409 提示稍后重试。

4. **幂等重试**：是否执行、执行哪种 SQL 完全由当前目录状态决定
   （attached→CONCURRENTLY，pending→FINALIZE，detached→不执行），
   因此中断重试、重复点击、僵尸后端抢先完成等时序都能安全收敛。

## API 一览

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/state` | 分区/归档/作业/后台活动总览（目录为准） |
| POST | `/api/detach/{month}` | 摘除或续做摘除（幂等） |
| POST | `/api/logs/generate` | 写入本月日志 `{count}` |
| GET | `/api/logs/online` | 在线查询（父表） |
| GET | `/api/logs/archive/{month}` | 归档查询（指定月物理表） |
| POST | `/api/simulate/long-query` | 模拟旧月长查询 `{seconds}` |
| POST | `/api/simulate/long-query/cancel` | 取消长查询（含僵尸会话） |
| POST | `/api/reset` | 复位：重新挂接已摘月份 |

## 目录结构

```
compose.yaml              # db(postgres:16) + app(FastAPI)
db/init/01_init.sql       # 建分区表、预置旧月+本月分区与样例数据
app/Dockerfile            # python:3.12-slim + uvicorn
app/main.py               # 运维 API 与后台摘除/长查询作业
app/static/index.html     # 运维页面（中文，3 秒轮询）
scripts/demo_concurrent.sh  # 复现：长查询不阻塞写入、并发摘除
scripts/demo_interrupt.sh   # 复现：中断后按目录显示、重试续做
```

## 说明与限制

- 月份边界按数据库服务器时区（容器内 UTC）计算；生产环境可按业务时区调整。
- 行数统计在摘除进行中会主动退让显示"—"，稍候刷新即可看到精确值。
- `partition_registry` 只存月份边界用于复位展示；分区真实状态一律以系统目录为准。
- 如需强制清理僵尸会话，可用页面"取消长查询"或 `pg_terminate_backend`；
  生产环境可考虑设置 `client_connection_check_interval`。
