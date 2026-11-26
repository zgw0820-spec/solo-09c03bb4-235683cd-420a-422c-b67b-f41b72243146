-- 网关日志按月分区：初始化脚本（容器首次启动时由 docker-entrypoint-initdb.d 执行）
-- 预置：一个不再补写的旧月分区 + 本月分区，并灌入样例数据。

CREATE TABLE gateway_logs (
    id       bigint GENERATED ALWAYS AS IDENTITY,
    ts       timestamptz NOT NULL,
    gateway  text NOT NULL,
    level    text NOT NULL,
    message  text NOT NULL,
    PRIMARY KEY (ts, id)
) PARTITION BY RANGE (ts);

-- 月份注册表：记录每个预置月份的边界，供“复位/重新挂接”等运维动作使用。
-- 注意：分区的真实状态（挂接/待完成/已摘下）一律以系统目录 pg_inherits 为准，本表只存边界。
CREATE TABLE partition_registry (
    month       text PRIMARY KEY,            -- 'YYYY-MM'
    lower_bound timestamptz NOT NULL,
    upper_bound timestamptz NOT NULL,
    seeded      boolean NOT NULL DEFAULT true
);

DO $$
DECLARE
    cur_start timestamptz := date_trunc('month', now());
    old_start timestamptz := date_trunc('month', now()) - interval '1 month';
    old_name  text := 'gateway_logs_' || to_char(old_start, 'YYYY_MM');
    cur_name  text := 'gateway_logs_' || to_char(cur_start, 'YYYY_MM');
BEGIN
    -- 旧月分区（不再补写）与本月分区
    EXECUTE format('CREATE TABLE %I PARTITION OF gateway_logs FOR VALUES FROM (%L) TO (%L)',
                   old_name, old_start, old_start + interval '1 month');
    EXECUTE format('CREATE TABLE %I PARTITION OF gateway_logs FOR VALUES FROM (%L) TO (%L)',
                   cur_name, cur_start, cur_start + interval '1 month');

    INSERT INTO partition_registry (month, lower_bound, upper_bound, seeded) VALUES
        (to_char(old_start, 'YYYY-MM'), old_start, old_start + interval '1 month', true),
        (to_char(cur_start, 'YYYY-MM'), cur_start, cur_start + interval '1 month', true);

    -- 旧月样例数据 3000 行（落在旧月前 28 天内，保证不越界）
    INSERT INTO gateway_logs (ts, gateway, level, message)
    SELECT old_start + (random() * interval '28 days'),
           'gw-' || (i % 4),
           (ARRAY['INFO','WARN','ERROR'])[1 + i % 3],
           'seeded old-month log ' || i
    FROM generate_series(1, 3000) AS i;

    -- 本月样例数据 800 行（落在本月已过去的时间内）
    INSERT INTO gateway_logs (ts, gateway, level, message)
    SELECT cur_start + (random() * (now() - cur_start)),
           'gw-' || (i % 4),
           (ARRAY['INFO','WARN','ERROR'])[1 + i % 3],
           'seeded current-month log ' || i
    FROM generate_series(1, 800) AS i;
END $$;
