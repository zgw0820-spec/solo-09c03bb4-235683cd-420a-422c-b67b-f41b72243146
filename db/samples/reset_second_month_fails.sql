-- 复位失败样例：让复位在“第二个月”挂接时报错，验证整次复位回滚。
--
-- 做了什么：
--   1) 在注册表里补一个“再上个月”（若不存在），并建好它的月表；
--   2) 把“再上个月”和“上月”都从父表摘下（这里用普通 DETACH，便于一条脚本跑完）；
--   3) 给“上月”月表塞一行越界记录（ts 落到两个月后）。
--
-- 预期：点“复位”时，“再上个月”先挂回，轮到“上月”时因越界记录报错；
--       整次复位回滚——“再上个月”不会留在父表上，在线日志总行数不变，
--       页面红条显示出错月份（上月）和原因。
--
-- 用法（compose 已启动时）：
--   docker compose cp db/samples/reset_second_month_fails.sql db:/tmp/
--   docker compose exec -T db psql -U ops -d gateway -f /tmp/reset_second_month_fails.sql

DO $$
DECLARE
    prev_start timestamptz := date_trunc('month', now()) - interval '2 months';
    prev_name  text := 'gateway_logs_' || to_char(prev_start, 'YYYY_MM');
    prev_month text := to_char(prev_start, 'YYYY-MM');
    old_start  timestamptz := date_trunc('month', now()) - interval '1 month';
    old_name   text := 'gateway_logs_' || to_char(old_start, 'YYYY_MM');
    old_month  text := to_char(old_start, 'YYYY-MM');
BEGIN
    -- 1) 注册表补“再上个月”
    INSERT INTO partition_registry (month, lower_bound, upper_bound, seeded)
    VALUES (prev_month, prev_start, prev_start + interval '1 month', false)
    ON CONFLICT (month) DO NOTHING;

    -- 2) 确保两个月的物理月表都存在（不存在就按父表结构建空表，复位会负责挂回）
    IF to_regclass(prev_name) IS NULL THEN
        EXECUTE format('CREATE TABLE %I (LIKE gateway_logs INCLUDING ALL)', prev_name);
    END IF;
    IF to_regclass(old_name) IS NULL THEN
        EXECUTE format('CREATE TABLE %I (LIKE gateway_logs INCLUDING ALL)', old_name);
    END IF;

    -- 3) 摘下两个月（普通 DETACH 可在 DO 块里执行）
    IF EXISTS (SELECT 1 FROM pg_inherits i WHERE i.inhrelid = to_regclass(prev_name)) THEN
        EXECUTE format('ALTER TABLE gateway_logs DETACH PARTITION %I', prev_name);
    END IF;
    IF EXISTS (SELECT 1 FROM pg_inherits i WHERE i.inhrelid = to_regclass(old_name)) THEN
        EXECUTE format('ALTER TABLE gateway_logs DETACH PARTITION %I', old_name);
    END IF;

    -- 4) 给“上月”塞越界记录：先去掉表上的月界 CHECK，再写入越界行
    EXECUTE format('ALTER TABLE %I DROP CONSTRAINT IF EXISTS %I',
                   old_name, old_name || '_ts_check');
    EXECUTE format(
        'INSERT INTO %I (id, ts, gateway, level, message) '
        'OVERRIDING SYSTEM VALUE VALUES (990001, %L, %L, %L, %L)',
        old_name, old_start + interval '2 months' + interval '3 days',
        'gw-1', 'INFO', 'out-of-bounds sample for reset failure');

    RAISE NOTICE '样例就绪：% 为空表待挂回，% 含越界记录（月份 %，越界 ts = %）',
        prev_name, old_name, old_month, old_start + interval '2 months' + interval '3 days';
END $$;
