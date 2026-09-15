-- =============================================================================
-- T0 资质指标自建 + 好用户流失猜想验证
-- 库里没有现成的「好/差用户、资质分、流失标签」。
-- 本脚本只用订单/获额/循环类型/埋点，把指标全部现算出来。
-- 原始字段只用：
--   order_vir_f_copy: user_id, serial_id, vir_unix, vir_date, is_pass1, loan_type_code
--   side_recycle_type_copy: serial_id, recycle_type
--   order_loan_f_v2_copy: user_id, serial_id, apply_time, apply_date, remit_amt, pre_amt,
--     post_amt, is_remit, due_date, repaid_date, repaid_time, is_repaid, loan_status_code
--   event_track_record: user_id, create_date, create_time, props_id
-- 一次跑 2026-01-01（含）～ 2026-09-01（不含）
-- =============================================================================

SET statement_timeout = 420000;

-- -----------------------------------------------------------------------------
-- 0) T0 用户日，并留下「刚结清那一笔」订单号 settle_serial_id
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS tmp_m_origin;
CREATE TEMP TABLE tmp_m_origin AS
WITH params AS (
    SELECT DATE '2026-01-01' AS start_date, DATE '2026-09-01' AS end_date
), raw_offer AS (
    SELECT DISTINCT ON (v.user_id, v.serial_id)
        v.user_id, v.serial_id, v.vir_date::date AS vir_date, TO_TIMESTAMP(v.vir_unix) AS vir_time
    FROM wangchuanliang.order_vir_f_copy v
    INNER JOIN wangchuanliang.side_recycle_type_copy r ON r.serial_id = v.serial_id
    CROSS JOIN params p
    WHERE v.is_pass1 = 1 AND v.loan_type_code = 2 AND r.recycle_type = 3
      AND v.vir_date >= p.start_date - 1 AND v.vir_date < p.end_date
    ORDER BY v.user_id, v.serial_id, v.vir_unix DESC
), lagged AS (
    SELECT r.*, LAG(r.vir_time) OVER (PARTITION BY r.user_id ORDER BY r.vir_time, r.serial_id) AS prev_vir_time
    FROM raw_offer r
), batched AS (
    SELECT l.*, SUM(CASE WHEN l.prev_vir_time IS NULL OR l.vir_time - l.prev_vir_time > INTERVAL '20 seconds' THEN 1 ELSE 0 END)
      OVER (PARTITION BY l.user_id ORDER BY l.vir_time, l.serial_id ROWS UNBOUNDED PRECEDING) AS batch_id
    FROM lagged l
), dedup_offer AS (
    SELECT user_id, serial_id, vir_date, vir_time
    FROM (
        SELECT b.*, ROW_NUMBER() OVER (PARTITION BY b.user_id, b.batch_id ORDER BY b.vir_time DESC, b.serial_id DESC) AS batch_rn
        FROM batched b
    ) x
    CROSS JOIN params p
    WHERE batch_rn = 1 AND vir_date >= p.start_date AND vir_date < p.end_date
), candidate_users AS (SELECT DISTINCT user_id FROM dedup_offer),
all_orders AS (
    SELECT o.user_id, o.serial_id, o.apply_time, o.repaid_time, o.repaid_date::date AS repaid_date,
           o.loan_status_code, o.is_remit, o.is_repaid
    FROM wangchuanliang.order_loan_f_v2_copy o
    INNER JOIN candidate_users u ON u.user_id = o.user_id
), clean_settlement AS (
    SELECT o.user_id, o.serial_id, o.repaid_time, o.repaid_date
    FROM all_orders o
    WHERE o.is_remit = 1 AND (o.is_repaid = 1 OR o.loan_status_code = 7)
      AND o.repaid_time > TIMESTAMP '2000-01-01 00:00:00'
      AND NOT EXISTS (
          SELECT 1 FROM all_orders x
          WHERE x.user_id = o.user_id AND x.serial_id <> o.serial_id AND x.apply_time < o.repaid_time
            AND (x.loan_status_code IN (5, 8) OR (x.loan_status_code = 7 AND x.repaid_time > o.repaid_time))
      )
), paired AS (
    SELECT e.user_id, e.serial_id AS credit_serial_id, e.vir_date, e.vir_time, s.serial_id AS settle_serial_id,
           ROW_NUMBER() OVER (PARTITION BY e.user_id, e.vir_date, e.serial_id ORDER BY s.repaid_time DESC, s.serial_id DESC) AS s_rn
    FROM dedup_offer e
    INNER JOIN clean_settlement s
        ON s.user_id = e.user_id AND s.repaid_date = e.vir_date AND e.vir_time >= s.repaid_time
), day_pick AS (
    SELECT p.*, ROW_NUMBER() OVER (PARTITION BY p.user_id, p.vir_date ORDER BY p.vir_time ASC, p.credit_serial_id DESC) AS day_rn
    FROM paired p
    WHERE s_rn = 1
)
SELECT user_id, credit_serial_id, vir_date, vir_time, settle_serial_id
FROM day_pick WHERE day_rn = 1;

-- -----------------------------------------------------------------------------
-- 1) 获额后首次提单窗口
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS tmp_first;
CREATE TEMP TABLE tmp_first AS
SELECT t.user_id, t.vir_date, t.vir_time, t.settle_serial_id, t.credit_serial_id,
       o.serial_id, o.apply_date, o.is_remit, o.remit_amt, o.pre_amt, o.post_amt, o.due_date, o.repaid_date,
       CASE
         WHEN o.serial_id IS NULL THEN 'never'
         WHEN o.apply_date = t.vir_date THEN '当日'
         WHEN o.apply_date >= t.vir_date + 1 AND o.apply_date <= t.vir_date + 3 THEN '1-3日'
         WHEN o.apply_date >= t.vir_date + 4 AND o.apply_date <= t.vir_date + 7 THEN '4-7日'
         ELSE '7日以后'
       END AS bucket
FROM tmp_m_origin t
LEFT JOIN (
    SELECT user_id, vir_date, serial_id, apply_date, is_remit, remit_amt, pre_amt, post_amt, due_date, repaid_date
    FROM (
        SELECT t.user_id, t.vir_date, a.serial_id, a.apply_date, a.is_remit, a.remit_amt, a.pre_amt, a.post_amt,
               a.due_date, a.repaid_date,
               ROW_NUMBER() OVER (PARTITION BY t.user_id, t.vir_date ORDER BY a.apply_time, a.serial_id) AS rn
        FROM tmp_m_origin t
        INNER JOIN wangchuanliang.order_loan_f_v2_copy a
          ON a.user_id = t.user_id AND a.apply_time >= t.vir_time
    ) z WHERE rn = 1
) o ON o.user_id = t.user_id AND o.vir_date = t.vir_date;

-- -----------------------------------------------------------------------------
-- 2) 自建资质指标（全部从订单表现算，不用任何现成资质字段）
--    prev_od     刚结清那一笔是否整笔逾期
--    prev_fee    刚结清那一笔息费 = (pre_amt+post_amt)/remit_amt
--    prev_remit  刚结清那一笔放款额
--    hist_n      获额日之前已到期放款笔数
--    hist_od_n   其中整笔逾期笔数
--    hist_ever_od 历史是否曾逾期
--    remit_n     获额时刻之前成功放款次数（账龄代理）
--    this_od     本笔首次提单（已放款已到期）是否逾期——只用于结果，不用于定义资质
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS tmp_metric;
CREATE TEMP TABLE tmp_metric AS
SELECT
  f.user_id,
  f.vir_date,
  DATE_TRUNC('month', f.vir_date)::date AS ym,
  f.bucket,
  f.serial_id AS this_serial_id,
  f.is_remit AS this_is_remit,
  f.remit_amt AS this_remit,
  f.due_date AS this_due,
  f.repaid_date AS this_repaid,
  CASE WHEN f.is_remit = 1 AND f.due_date < CURRENT_DATE AND COALESCE(f.remit_amt, 0) > 0 THEN 1 ELSE 0 END AS this_due_flag,
  CASE WHEN f.is_remit = 1 AND f.due_date < CURRENT_DATE AND COALESCE(f.remit_amt, 0) > 0
        AND (f.repaid_date IS NULL OR f.repaid_date <= DATE '2000-01-01' OR f.repaid_date > f.due_date)
       THEN 1 ELSE 0 END AS this_od,
  s.remit_amt AS prev_remit,
  CASE WHEN COALESCE(s.remit_amt, 0) > 0
       THEN (COALESCE(s.pre_amt, 0) + COALESCE(s.post_amt, 0)) / s.remit_amt END AS prev_fee,
  CASE WHEN s.repaid_date IS NULL OR s.repaid_date <= DATE '2000-01-01' OR s.repaid_date > s.due_date
       THEN 1 ELSE 0 END AS prev_od,
  COALESCE(h.hist_n, 0) AS hist_n,
  COALESCE(h.hist_od_n, 0) AS hist_od_n,
  CASE WHEN COALESCE(h.hist_od_n, 0) > 0 THEN 1 ELSE 0 END AS hist_ever_od,
  COALESCE(r.remit_n, 0) AS remit_n
FROM tmp_first f
LEFT JOIN wangchuanliang.order_loan_f_v2_copy s
  ON s.serial_id = f.settle_serial_id
LEFT JOIN (
  SELECT t.user_id, t.vir_date,
         COUNT(*) AS hist_n,
         SUM(CASE WHEN o.repaid_date IS NULL OR o.repaid_date <= DATE '2000-01-01' OR o.repaid_date > o.due_date THEN 1 ELSE 0 END) AS hist_od_n
  FROM tmp_m_origin t
  INNER JOIN wangchuanliang.order_loan_f_v2_copy o
    ON o.user_id = t.user_id AND o.is_remit = 1 AND COALESCE(o.remit_amt, 0) > 0
   AND o.due_date < t.vir_date AND o.apply_time < t.vir_time
  GROUP BY t.user_id, t.vir_date
) h ON h.user_id = f.user_id AND h.vir_date = f.vir_date
LEFT JOIN (
  SELECT t.user_id, t.vir_date, COUNT(*) AS remit_n
  FROM tmp_m_origin t
  INNER JOIN wangchuanliang.order_loan_f_v2_copy o
    ON o.user_id = t.user_id AND o.is_remit = 1 AND COALESCE(o.remit_amt, 0) > 0
   AND o.remit_time < t.vir_time
  GROUP BY t.user_id, t.vir_date
) r ON r.user_id = f.user_id AND r.vir_date = f.vir_date;

-- 指标字典（跑完可核对覆盖率）
SELECT
  COUNT(*) AS t0,
  SUM(CASE WHEN prev_od IS NOT NULL THEN 1 ELSE 0 END) AS n_prev_od,
  SUM(CASE WHEN prev_fee IS NOT NULL THEN 1 ELSE 0 END) AS n_prev_fee,
  SUM(CASE WHEN prev_remit IS NOT NULL THEN 1 ELSE 0 END) AS n_prev_remit
FROM tmp_metric;

-- 【块Q1】刚结清是否逾期 × 月：当日提单率 / 月度提单率 / 未提单率
SELECT
  TO_CHAR(ym, 'YYYY-MM') AS ym,
  prev_od AS 刚结清逾期,
  COUNT(*) AS t0,
  ROUND(100.0 * SUM(CASE WHEN bucket = '当日' THEN 1 ELSE 0 END) / COUNT(*), 2) AS 当日提单率,
  ROUND(100.0 * SUM(CASE WHEN bucket <> 'never' THEN 1 ELSE 0 END) / COUNT(*), 2) AS 月度提单率,
  ROUND(100.0 * SUM(CASE WHEN bucket = 'never' THEN 1 ELSE 0 END) / COUNT(*), 2) AS 未提单率
FROM tmp_metric
GROUP BY ym, prev_od
ORDER BY 1, 2;

-- 【块Q2】谁不提：当日 vs 未提单 的自建资质结构
SELECT
  TO_CHAR(ym, 'YYYY-MM') AS ym,
  ROUND(100.0 * AVG(prev_od), 2) AS 全体刚结清逾期占比,
  ROUND(100.0 * SUM(CASE WHEN bucket = '当日' THEN prev_od ELSE 0 END)
              / NULLIF(SUM(CASE WHEN bucket = '当日' THEN 1 ELSE 0 END), 0), 2) AS 当日组刚结清逾期占比,
  ROUND(100.0 * SUM(CASE WHEN bucket = 'never' THEN prev_od ELSE 0 END)
              / NULLIF(SUM(CASE WHEN bucket = 'never' THEN 1 ELSE 0 END), 0), 2) AS 未提单组刚结清逾期占比,
  ROUND(100.0 * AVG(hist_ever_od), 2) AS 全体历史曾逾期占比,
  ROUND(AVG(prev_fee) * 100, 2) AS 全体上一笔息费,
  ROUND(100.0 * SUM(CASE WHEN bucket = '当日' THEN prev_fee ELSE 0 END)
              / NULLIF(SUM(CASE WHEN bucket = '当日' THEN 1 ELSE 0 END), 0), 2) AS 当日组上一笔息费,
  ROUND(100.0 * SUM(CASE WHEN bucket = 'never' THEN prev_fee ELSE 0 END)
              / NULLIF(SUM(CASE WHEN bucket = 'never' THEN 1 ELSE 0 END), 0), 2) AS 未提单组上一笔息费,
  ROUND(AVG(prev_remit), 0) AS 全体上一笔放款额,
  ROUND(SUM(CASE WHEN bucket = '当日' THEN prev_remit ELSE 0 END)
              / NULLIF(SUM(CASE WHEN bucket = '当日' THEN 1 ELSE 0 END), 0), 0) AS 当日组上一笔放款额,
  ROUND(SUM(CASE WHEN bucket = 'never' THEN prev_remit ELSE 0 END)
              / NULLIF(SUM(CASE WHEN bucket = 'never' THEN 1 ELSE 0 END), 0), 0) AS 未提单组上一笔放款额,
  ROUND(AVG(remit_n), 2) AS 全体历史放款次数,
  ROUND(SUM(CASE WHEN bucket = '当日' THEN remit_n ELSE 0 END) * 1.0
              / NULLIF(SUM(CASE WHEN bucket = '当日' THEN 1 ELSE 0 END), 0), 2) AS 当日组放款次数,
  ROUND(SUM(CASE WHEN bucket = 'never' THEN remit_n ELSE 0 END) * 1.0
              / NULLIF(SUM(CASE WHEN bucket = 'never' THEN 1 ELSE 0 END), 0), 2) AS 未提单组放款次数
FROM tmp_metric
GROUP BY ym
ORDER BY 1;

-- 【块Q3】上一笔息费三分位（当月内 NTILE，低=1）× 当日提单 / 未提单
SELECT
  TO_CHAR(ym, 'YYYY-MM') AS ym,
  fee_g AS 上一笔息费三分位,
  COUNT(*) AS t0,
  ROUND(100.0 * SUM(CASE WHEN bucket = '当日' THEN 1 ELSE 0 END) / COUNT(*), 2) AS 当日提单率,
  ROUND(100.0 * SUM(CASE WHEN bucket = 'never' THEN 1 ELSE 0 END) / COUNT(*), 2) AS 未提单率
FROM (
  SELECT m.*, NTILE(3) OVER (PARTITION BY ym ORDER BY prev_fee NULLS LAST) AS fee_g
  FROM tmp_metric m
  WHERE prev_fee IS NOT NULL
) x
GROUP BY ym, fee_g
ORDER BY 1, 2;

-- 【块Q4】历史是否曾逾期 × 当日提单 / 未提单
SELECT
  TO_CHAR(ym, 'YYYY-MM') AS ym,
  hist_ever_od AS 历史曾逾期,
  COUNT(*) AS t0,
  ROUND(100.0 * SUM(CASE WHEN bucket = '当日' THEN 1 ELSE 0 END) / COUNT(*), 2) AS 当日提单率,
  ROUND(100.0 * SUM(CASE WHEN bucket <> 'never' THEN 1 ELSE 0 END) / COUNT(*), 2) AS 月度提单率,
  ROUND(100.0 * SUM(CASE WHEN bucket = 'never' THEN 1 ELSE 0 END) / COUNT(*), 2) AS 未提单率
FROM tmp_metric
GROUP BY ym, hist_ever_od
ORDER BY 1, 2;

-- 【块Q5】本笔当日单逾期（结果）按刚结清逾期拆开，用于结构 vs 组内分解
SELECT
  TO_CHAR(ym, 'YYYY-MM') AS ym,
  prev_od AS 刚结清逾期,
  SUM(this_due_flag) AS 当日已到期笔数,
  ROUND(100.0 * SUM(CASE WHEN this_due_flag = 1 THEN this_od ELSE 0 END) / NULLIF(SUM(this_due_flag), 0), 2) AS 当日整笔逾期率
FROM tmp_metric
WHERE bucket = '当日'
GROUP BY ym, prev_od
ORDER BY 1, 2;

-- 【块Q6】当日已到期样本的客群结构（刚结清逾期占比）+ 总体逾期率
SELECT
  TO_CHAR(ym, 'YYYY-MM') AS ym,
  SUM(this_due_flag) AS 当日已到期笔数,
  ROUND(100.0 * SUM(CASE WHEN this_due_flag = 1 THEN prev_od ELSE 0 END) / NULLIF(SUM(this_due_flag), 0), 2) AS 到期样本刚结清逾期占比,
  ROUND(100.0 * SUM(CASE WHEN this_due_flag = 1 THEN this_od ELSE 0 END) / NULLIF(SUM(this_due_flag), 0), 2) AS 当日整笔逾期率
FROM tmp_metric
WHERE bucket = '当日'
GROUP BY ym
ORDER BY 1;

-- -----------------------------------------------------------------------------
-- Q7 当日未提拆开：刚逾期未提 vs 高额未提（互斥），看 7/30 天是否回来
-- 高额 = 当月上一笔 remit_amt 最高三分位，且刚结清未逾期
-- 刚逾期未提 = 当日未提且刚结清逾期（含高额）
-- 只统计 vir_date+30 < CURRENT_DATE，保证 30 天观察期完整
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS tmp_ret;
CREATE TEMP TABLE tmp_ret AS
SELECT
  t.user_id, t.vir_date, DATE_TRUNC('month', t.vir_date)::date AS ym,
  CASE WHEN s.repaid_date IS NULL OR s.repaid_date <= DATE '2000-01-01' OR s.repaid_date > s.due_date THEN 1 ELSE 0 END AS prev_od,
  s.remit_amt AS prev_remit,
  f.apply_time, f.is_remit, f.due_date, f.repaid_date, f.remit_amt AS this_remit,
  CASE WHEN f.serial_id IS NULL THEN 0 WHEN f.apply_date = t.vir_date THEN 1 ELSE 0 END AS d0_apply,
  CASE WHEN f.serial_id IS NOT NULL AND f.apply_time < t.vir_time + INTERVAL '7 days' THEN 1 ELSE 0 END AS apply_7d,
  CASE WHEN f.serial_id IS NOT NULL AND f.apply_time < t.vir_time + INTERVAL '30 days' THEN 1 ELSE 0 END AS apply_30d,
  CASE WHEN f.serial_id IS NOT NULL AND f.is_remit = 1 AND f.apply_time < t.vir_time + INTERVAL '30 days' THEN 1 ELSE 0 END AS remit_30d,
  CASE WHEN t.vir_date + 30 < CURRENT_DATE THEN 1 ELSE 0 END AS full_30d
FROM tmp_m_origin t
LEFT JOIN wangchuanliang.order_loan_f_v2_copy s ON s.serial_id = t.settle_serial_id
LEFT JOIN (
    SELECT user_id, vir_date, serial_id, apply_time, apply_date, is_remit, due_date, repaid_date, remit_amt
    FROM (
        SELECT t.user_id, t.vir_date, a.serial_id, a.apply_time, a.apply_date, a.is_remit, a.due_date, a.repaid_date, a.remit_amt,
               ROW_NUMBER() OVER (PARTITION BY t.user_id, t.vir_date ORDER BY a.apply_time, a.serial_id) AS rn
        FROM tmp_m_origin t
        INNER JOIN wangchuanliang.order_loan_f_v2_copy a
          ON a.user_id = t.user_id AND a.apply_time >= t.vir_time
    ) z WHERE rn = 1
) f ON f.user_id = t.user_id AND f.vir_date = t.vir_date;

DROP TABLE IF EXISTS tmp_g;
CREATE TEMP TABLE tmp_g AS
SELECT r.*,
       NTILE(3) OVER (PARTITION BY ym ORDER BY prev_remit NULLS LAST) AS remit_g,
       CASE
         WHEN d0_apply = 1 THEN '当日已提'
         WHEN prev_od = 1 THEN '刚逾期未提'
         WHEN NTILE(3) OVER (PARTITION BY ym ORDER BY prev_remit NULLS LAST) = 3 THEN '高额未提'
         ELSE '其他未提'
       END AS grp
FROM tmp_ret r;

-- 【块Q7】分月：当日未提三类 7天/30天回归率（满30天样本）
SELECT
  TO_CHAR(ym, 'YYYY-MM') AS ym,
  grp,
  SUM(full_30d) AS n_满30天,
  ROUND(100.0 * SUM(CASE WHEN full_30d = 1 THEN apply_7d ELSE 0 END) / NULLIF(SUM(full_30d), 0), 2) AS 七日提单率,
  ROUND(100.0 * SUM(CASE WHEN full_30d = 1 THEN apply_30d ELSE 0 END) / NULLIF(SUM(full_30d), 0), 2) AS 三十日提单率,
  ROUND(100.0 * SUM(CASE WHEN full_30d = 1 THEN remit_30d ELSE 0 END) / NULLIF(SUM(full_30d), 0), 2) AS 三十日放款率
FROM tmp_g
WHERE grp <> '当日已提'
GROUP BY ym, grp
ORDER BY 1, CASE grp WHEN '刚逾期未提' THEN 1 WHEN '高额未提' THEN 2 ELSE 3 END;

-- 【块Q8】合计 + 交叉（刚逾期 × 是否高额），仅当日未提、满30天
SELECT
  CASE WHEN prev_od = 1 THEN '刚逾期' ELSE '未逾期' END AS 刚结清,
  CASE WHEN remit_g = 3 THEN '高额' ELSE '非高额' END AS 上一笔放款,
  SUM(full_30d) AS n_满30天,
  ROUND(100.0 * SUM(CASE WHEN full_30d = 1 THEN apply_7d ELSE 0 END) / NULLIF(SUM(full_30d), 0), 2) AS 七日提单率,
  ROUND(100.0 * SUM(CASE WHEN full_30d = 1 THEN apply_30d ELSE 0 END) / NULLIF(SUM(full_30d), 0), 2) AS 三十日提单率,
  ROUND(100.0 * SUM(CASE WHEN full_30d = 1 THEN remit_30d ELSE 0 END) / NULLIF(SUM(full_30d), 0), 2) AS 三十日放款率
FROM tmp_g
WHERE d0_apply = 0
GROUP BY 1, 2
ORDER BY 1, 2;

-- 【块Q9】30天内回来且已放款已到期：本笔整笔逾期率
SELECT
  grp,
  SUM(CASE WHEN full_30d = 1 AND apply_30d = 1 AND is_remit = 1 AND due_date < CURRENT_DATE AND COALESCE(this_remit, 0) > 0 THEN 1 ELSE 0 END) AS n_到期,
  ROUND(100.0 * SUM(CASE WHEN full_30d = 1 AND apply_30d = 1 AND is_remit = 1 AND due_date < CURRENT_DATE AND COALESCE(this_remit, 0) > 0
        AND (repaid_date IS NULL OR repaid_date <= DATE '2000-01-01' OR repaid_date > due_date) THEN 1 ELSE 0 END)
        / NULLIF(SUM(CASE WHEN full_30d = 1 AND apply_30d = 1 AND is_remit = 1 AND due_date < CURRENT_DATE AND COALESCE(this_remit, 0) > 0 THEN 1 ELSE 0 END), 0), 2) AS 回归后逾期率
FROM tmp_g
WHERE grp <> '当日已提'
GROUP BY grp
ORDER BY CASE grp WHEN '刚逾期未提' THEN 1 WHEN '高额未提' THEN 2 ELSE 3 END;
