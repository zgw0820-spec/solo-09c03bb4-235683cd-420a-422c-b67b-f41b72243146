"""网关日志分区运维台（FastAPI + PostgreSQL 16）

核心机制：
- 摘除旧月用 ALTER TABLE ... DETACH PARTITION ... CONCURRENTLY（两阶段）：
  第一阶段只拿父表 SHARE UPDATE EXCLUSIVE 锁，把分区标记为“待完成”
  (pg_inherits.inhdetachpending=true) 并提交——此后新查询即不再路由到该分区，
  但目录上仍挂接；第二阶段等待引用旧分区的老快照消失后，才真正删除目录行。
  父表锁不冲突读写，因此长查询拖住第二阶段时，本月日志照常写入。
- 待完成状态下重试走 DETACH ... FINALIZE（单事务原子完成第二阶段）；
  已摘下则直接返回，不再执行任何 SQL（幂等）。
- 本应用不保存任何分区状态，页面展示的 挂接中/待完成/已摘下 完全来自数据库
  系统目录，操作中断或服务重启后依然准确。

实测踩过的坑（本代码已规避，详见 README）：
1. 杀掉发起 DETACH CONCURRENTLY 的客户端（如重启服务）不会取消服务端
   第二阶段等待（PG 默认 client_connection_check_interval=0），快照条件
   满足后摘除仍会在服务端完成——所以重启后必须以目录状态为准。
2. FINALIZE 期间会对被摘分区持 ACCESS EXCLUSIVE 锁并等待老快照；任何
   “先持快照、再请求该分区锁”的事务（哪怕只是 pg_get_expr(relpartbound)
   或 count(*) 查该分区）都会与它形成死锁，且 FINALIZE 会自我了断。
   因此轮询接口一律不打开分区表：边界取自注册表，行数统计走独立连接并
   设置 lock_timeout=800ms（小于 deadlock_timeout=1s，保证退让的是自己）。
"""
import os
import re
import threading
import time
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timezone

import psycopg
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from psycopg.rows import dict_row
from pydantic import BaseModel

DB_DSN = os.environ.get("DATABASE_URL", "postgresql://ops:ops@localhost:5432/gateway")
PARENT = "gateway_logs"
REGISTRY = "partition_registry"
MONTH_RE = re.compile(r"^\d{4}-(0[1-9]|1[0-2])$")
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
# 轮询/查询连接的锁等待上限：必须小于 deadlock_timeout(默认1s)，
# 保证与 FINALIZE 竞争时永远是我们退让，摘除作业绝不当死锁牺牲品。
POLL_LOCK_TIMEOUT_MS = 800


# ---------------------------------------------------------------- 基础工具

def connect(autocommit: bool = True):
    """默认 autocommit：每条语句独立事务，避免持快照跨语句带来死锁风险。"""
    return psycopg.connect(DB_DSN, autocommit=autocommit, row_factory=dict_row)


def connect_txn():
    """需要显式多语句事务的场景（模拟长查询）。"""
    return psycopg.connect(DB_DSN, autocommit=False, row_factory=dict_row)


def check_month(month: str) -> str:
    if not MONTH_RE.match(month or ""):
        raise HTTPException(400, f"月份格式非法: {month!r}，应为 YYYY-MM")
    return month


def part_name(month: str) -> str:
    return f"{PARENT}_{month.replace('-', '_')}"


def month_of(part: str) -> str:
    return part[len(PARENT) + 1:].replace("_", "-")


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


# ---------------------------------------------------------------- 目录状态（唯一事实来源）

def partition_state(c, month: str) -> str:
    """attached / pending / detached / missing，完全由系统目录推导。"""
    name = part_name(month)
    row = c.execute(
        """
        SELECT i.inhdetachpending AS pending
        FROM pg_inherits i
        JOIN pg_class c  ON c.oid = i.inhrelid
        JOIN pg_class p  ON p.oid = i.inhparent
        JOIN pg_namespace n ON n.oid = p.relnamespace
        WHERE p.relname = %s AND c.relname = %s AND n.nspname = 'public'
        """,
        (PARENT, name),
    ).fetchone()
    if row:
        return "pending" if row["pending"] else "attached"
    exists = c.execute("SELECT to_regclass(%s) AS t", (f"public.{name}",)).fetchone()["t"]
    return "detached" if exists else "missing"


def fetch_partitions(c):
    """仍挂接在父表上的分区（含待完成）。只读系统目录，绝不打开分区表。

    注意：不要用 pg_get_expr(relpartbound) 取边界——它会打开分区关系
    （AccessShareLock），与摘除操作的 ACCESS EXCLUSIVE 锁形成死锁。
    边界改从注册表取。
    """
    return c.execute(
        """
        SELECT c.relname AS name, i.inhdetachpending AS pending
        FROM pg_inherits i
        JOIN pg_class c  ON c.oid = i.inhrelid
        JOIN pg_class p  ON p.oid = i.inhparent
        JOIN pg_namespace n ON n.oid = p.relnamespace
        WHERE p.relname = %s AND n.nspname = 'public'
        ORDER BY c.relname
        """,
        (PARENT,),
    ).fetchall()


def fetch_archives(c):
    """已摘下、仍以独立表存在的月表（只读目录）。"""
    like = PARENT.replace("_", "\\_") + "\\_%"
    return c.execute(
        """
        SELECT c.relname AS name
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public' AND c.relkind = 'r'
          AND c.relname LIKE %s
          AND NOT EXISTS (SELECT 1 FROM pg_inherits i WHERE i.inhrelid = c.oid)
        ORDER BY c.relname
        """,
        (like,),
    ).fetchall()


def fetch_registry(c) -> dict:
    """注册表：month -> 边界字符串（用于展示和复位）。"""
    rows = c.execute(
        f"SELECT month, lower_bound, upper_bound FROM {REGISTRY}"
    ).fetchall()
    return {
        r["month"]: {
            "bounds": f"FOR VALUES FROM ('{r['lower_bound'].isoformat()}') "
                      f"TO ('{r['upper_bound'].isoformat()}')",
            "lower": r["lower_bound"], "upper": r["upper_bound"],
        }
        for r in rows
    }


def safe_count(c, name: str):
    """精确行数；拿不到锁（摘除进行中）就退让返回 None，绝不死等。"""
    try:
        return c.execute(f'SELECT count(*) AS n FROM "{name}"').fetchone()["n"]
    except Exception:
        return None


def ensure_current_partition(c):
    """保证本月分区存在（跨月重启/长跑时兜底）。autocommit 连接上逐条提交。"""
    row = c.execute(
        "SELECT date_trunc('month', now()) AS s, "
        "(date_trunc('month', now()) + interval '1 month')::timestamptz AS u"
    ).fetchone()
    s, u = row["s"], row["u"]
    name = "gateway_logs_" + s.strftime("%Y_%m")
    c.execute(
        f'CREATE TABLE IF NOT EXISTS "{name}" PARTITION OF {PARENT} '
        f"FOR VALUES FROM ('{s.isoformat()}') TO ('{u.isoformat()}')"
    )
    c.execute(
        f"INSERT INTO {REGISTRY} (month, lower_bound, upper_bound, seeded) "
        f"VALUES ('{s.strftime('%Y-%m')}', '{s.isoformat()}', '{u.isoformat()}', false) "
        "ON CONFLICT (month) DO NOTHING"
    )


# ---------------------------------------------------------------- 作业登记（仅内存，重启即清；状态以数据库为准）

JOBS: dict = {}
JOBS_LOCK = threading.Lock()


def new_job(kind: str, title: str) -> str:
    jid = uuid.uuid4().hex[:8]
    with JOBS_LOCK:
        JOBS[jid] = {
            "id": jid, "kind": kind, "title": title,
            "status": "queued", "detail": "", "pid": None,
            "started_at": now_iso(), "finished_at": None,
        }
    return jid


def set_job(jid: str, **fields):
    with JOBS_LOCK:
        if jid in JOBS:
            JOBS[jid].update(fields)
            if fields.get("status") in ("done", "error", "cancelled"):
                JOBS[jid]["finished_at"] = now_iso()


def job_list():
    with JOBS_LOCK:
        return sorted(JOBS.values(), key=lambda j: j["started_at"], reverse=True)[:20]


def running_job(kind: str):
    with JOBS_LOCK:
        return [j for j in JOBS.values() if j["kind"] == kind and j["status"] in ("queued", "running")]


# ---------------------------------------------------------------- 后台：摘除 / 长查询

def detach_worker(jid: str, month: str):
    name = part_name(month)
    try:
        c = psycopg.connect(DB_DSN, autocommit=True, row_factory=dict_row)
        c.execute("SET application_name = 'detach_job'")
        st = partition_state(c, month)
        if st == "detached":
            set_job(jid, status="done", detail="已摘下，重复请求未执行任何 SQL")
            return
        if st == "pending":
            sql = f'ALTER TABLE {PARENT} DETACH PARTITION "{name}" FINALIZE'
        elif st == "attached":
            sql = f'ALTER TABLE {PARENT} DETACH PARTITION "{name}" CONCURRENTLY'
        else:
            set_job(jid, status="error", detail=f"分区不存在: {name}")
            return
        set_job(jid, status="running", detail=f"执行: {sql}")
        c.execute(sql)  # 第二阶段会等待旧快照；期间父表读写不受阻
        set_job(jid, status="done", detail=f"{sql} → 当前状态 {partition_state(c, month)}")
        c.close()
    except Exception as e:  # 连接被杀/取消/死锁退让等：目录状态保持 pending，可重试
        set_job(jid, status="error", detail=str(e).strip())


def long_query_worker(jid: str, seconds: int):
    """模拟旧月长查询：REPEATABLE READ 快照 + pg_sleep，持有快照期间会拖住摘除的第二阶段。"""
    c = None
    try:
        c = connect_txn()
        c.isolation_level = psycopg.IsolationLevel.REPEATABLE_READ
        c.execute("SET application_name = 'long_query_sim'")
        row = c.execute(f"SELECT count(*) AS n FROM {PARENT}").fetchone()
        set_job(jid, status="running", pid=c.info.backend_pid,
                detail=f"快照已建立（父表可见 {row['n']} 行），pg_sleep({seconds}) 中")
        c.execute("SELECT pg_sleep(%s)", (seconds,))
        c.commit()
        set_job(jid, status="done", detail="长查询正常结束")
    except Exception as e:
        msg = str(e).strip()
        status = "cancelled" if "cancel" in msg.lower() else "error"
        set_job(jid, status=status, detail=msg)
    finally:
        if c is not None:
            c.close()


# ---------------------------------------------------------------- 应用生命周期

def wait_for_db():
    deadline = time.time() + 90
    while True:
        try:
            with connect() as c:
                if c.execute("SELECT to_regclass('public.gateway_logs') AS t").fetchone()["t"]:
                    return
        except Exception:
            pass
        if time.time() > deadline:
            raise RuntimeError("等待数据库就绪超时")
        time.sleep(1)


@asynccontextmanager
async def lifespan(app: FastAPI):
    wait_for_db()
    with connect() as c:
        ensure_current_partition(c)
    yield


app = FastAPI(title="网关日志分区运维台", lifespan=lifespan)


# ---------------------------------------------------------------- API

@app.get("/", response_class=FileResponse)
def index():
    return FileResponse(os.path.join(BASE_DIR, "static", "index.html"))


@app.get("/api/health")
def health():
    with connect() as c:
        c.execute("SELECT 1")
    return {"ok": True}


@app.get("/api/state")
def state():
    # 目录与注册表：普通连接（只读目录，不碰分区表，绝不会与摘除死锁）
    with connect() as c:
        registry = fetch_registry(c)
        parts = fetch_partitions(c)
        archives = fetch_archives(c)
        activity = c.execute(
            """
            SELECT pid, application_name AS app, state,
                   wait_event_type AS wait_type, wait_event AS wait,
                   EXTRACT(EPOCH FROM now() - xact_start)::int AS xact_age_s,
                   left(query, 72) AS query
            FROM pg_stat_activity
            WHERE application_name IN ('long_query_sim', 'detach_job')
            ORDER BY application_name
            """
        ).fetchall()
    # 行数统计：独立连接 + lock_timeout 退让（会打开分区表，必须自我限制）
    names = [p["name"] for p in parts] + [a["name"] for a in archives]
    counts = {}
    if names:
        with connect() as cc:
            cc.execute(f"SET lock_timeout = '{POLL_LOCK_TIMEOUT_MS}ms'")
            for n in names:
                counts[n] = safe_count(cc, n)
    return {
        "now": now_iso(), "parent": PARENT,
        "partitions": [{
            "name": p["name"], "month": month_of(p["name"]),
            "bounds": registry.get(month_of(p["name"]), {}).get("bounds", ""),
            "state": "pending" if p["pending"] else "attached",
            "rows": counts.get(p["name"]),
        } for p in parts],
        "archives": [{
            "name": a["name"], "month": month_of(a["name"]),
            "state": "detached", "rows": counts.get(a["name"]),
        } for a in archives],
        "jobs": job_list(), "activity": activity,
    }


@app.post("/api/detach/{month}")
def detach(month: str):
    check_month(month)
    with connect() as c:
        st = partition_state(c, month)
    if st == "missing":
        raise HTTPException(404, f"分区 {part_name(month)} 不存在")
    if st == "detached":
        return {"executed": False, "state": st,
                "message": f"{part_name(month)} 已摘下，不再执行"}
    if running_job("detach"):
        raise HTTPException(409, "已有摘除作业进行中，稍后再试")
    jid = new_job("detach", f"摘除 {part_name(month)}（当前 {st}）")
    threading.Thread(target=detach_worker, args=(jid, month), daemon=True).start()
    return {"executed": True, "job_id": jid, "state": st,
            "message": "已发起摘除，轮询 /api/state 查看进度"}


class GenReq(BaseModel):
    count: int = 200


@app.post("/api/logs/generate")
def generate(req: GenReq):
    count = max(1, min(req.count, 100000))
    t0 = time.time()
    with connect() as c:
        ensure_current_partition(c)
        c.execute(
            """
            INSERT INTO gateway_logs (ts, gateway, level, message)
            SELECT now() - (random() * interval '10 minutes'),
                   'gw-' || (i %% 4),
                   (ARRAY['INFO','WARN','ERROR'])[1 + i %% 3],
                   'live log ' || i
            FROM generate_series(1, %s) AS i
            """,
            (count,),
        )
    return {"inserted": count, "elapsed_ms": round((time.time() - t0) * 1000, 1)}


@app.get("/api/logs/online")
def online(limit: int = 20):
    """在线查询：只查父表（规划器只展开仍挂接的分区，待完成/已摘下的不含）。"""
    limit = max(1, min(limit, 200))
    with connect() as c:
        total = c.execute(f"SELECT count(*) AS n FROM {PARENT}").fetchone()["n"]
        rows = c.execute(
            f"SELECT id, ts, gateway, level, message FROM {PARENT} "
            "ORDER BY ts DESC LIMIT %s", (limit,),
        ).fetchall()
    return {"table": PARENT, "total": total, "rows": rows}


@app.get("/api/logs/archive/{month}")
def archive(month: str, limit: int = 20):
    """归档查询：直接查某个月的物理表（无论挂接、待完成还是已摘下）。"""
    check_month(month)
    limit = max(1, min(limit, 200))
    name = part_name(month)
    try:
        with connect() as c:
            c.execute(f"SET lock_timeout = '{POLL_LOCK_TIMEOUT_MS}ms'")
            st = partition_state(c, month)
            if st == "missing":
                raise HTTPException(404, f"月表 {name} 不存在")
            total = c.execute(f'SELECT count(*) AS n FROM "{name}"').fetchone()["n"]
            rows = c.execute(
                f'SELECT id, ts, gateway, level, message FROM "{name}" '
                "ORDER BY ts DESC LIMIT %s", (limit,),
            ).fetchall()
    except psycopg.errors.LockTimeout:
        raise HTTPException(409, f"月表 {name} 正被摘除操作锁定，请稍后重试")
    return {"table": name, "state": st, "total": total, "rows": rows}


class LongQueryReq(BaseModel):
    seconds: int = 120


@app.post("/api/simulate/long-query")
def long_query(req: LongQueryReq):
    seconds = max(1, min(req.seconds, 3600))
    if running_job("long_query"):
        raise HTTPException(409, "已有模拟长查询在跑")
    jid = new_job("long_query", f"模拟旧月长查询 {seconds}s")
    threading.Thread(target=long_query_worker, args=(jid, seconds), daemon=True).start()
    return {"job_id": jid, "seconds": seconds}


@app.post("/api/simulate/long-query/cancel")
def cancel_long_query():
    """按 application_name 取消长查询后端。

    服务重启后内存作业记录丢失，但被杀客户端的服务端后端可能仍作为
    “僵尸会话”在跑（PG 默认 client_connection_check_interval=0），
    因此直接以 pg_stat_activity 为准查找并取消。
    """
    with connect() as c:
        rows = c.execute(
            "SELECT pid, pg_cancel_backend(pid) AS ok FROM pg_stat_activity "
            "WHERE application_name = 'long_query_sim' AND pid <> pg_backend_pid()"
        ).fetchall()
    return {"cancelled": sum(1 for r in rows if r["ok"])}


@app.post("/api/reset")
def reset():
    """把注册表中已摘下的月份重新挂接回去（演示复位用）。有待完成摘除时拒绝。"""
    with connect() as c:
        pend = [p["name"] for p in fetch_partitions(c) if p["pending"]]
        if pend:
            raise HTTPException(409, "存在待完成摘除: " + ", ".join(pend) +
                                "，请先重试完成（FINALIZE）再复位")
        registry = fetch_registry(c)
        reattached, recreated = [], []
        for month in sorted(registry):
            name, st = part_name(month), partition_state(c, month)
            lo = registry[month]["lower"].isoformat()
            up = registry[month]["upper"].isoformat()
            if st == "detached":
                c.execute(f'ALTER TABLE {PARENT} ATTACH PARTITION "{name}" '
                          f"FOR VALUES FROM ('{lo}') TO ('{up}')")
                reattached.append(name)
            elif st == "missing":
                c.execute(f'CREATE TABLE "{name}" PARTITION OF {PARENT} '
                          f"FOR VALUES FROM ('{lo}') TO ('{up}')")
                recreated.append(name)
    return {"reattached": reattached, "recreated": recreated}
