-- T7 召回看板 · 可复现 PGSQL
-- 库：kaby_dw · schema：wangchuanliang
-- 名单：wangchuanliang.t7recalllist_0917
-- 触达日：2026-09-17
-- 放款日：优先 o.remit_date::date（无该列时用 o.apply_date::date）
-- 本文件当前放款日表达式：o.remit_date::date
-- 本周：DATE_TRUNC('week', CURRENT_DATE)::date（周一）
-- 执行前：SET search_path TO wangchuanliang, public;

SET search_path TO wangchuanliang, public;

-- ---------------------------------------------------------------------------
-- 0) 放款日字段是否存在（结果有行则用 remit_date，否则用 apply_date）
-- ---------------------------------------------------------------------------
SELECT 1 AS has_remit_date
FROM information_schema.columns
WHERE table_schema = 'wangchuanliang'
  AND table_name = 'order_loan_f_v2_copy'
  AND column_name = 'remit_date';

-- ---------------------------------------------------------------------------
-- 1) 召回名单（去重用户）
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS tmp_t7_u;
CREATE TEMP TABLE tmp_t7_u AS
SELECT DISTINCT churn_user_id::bigint AS user_id,
       COALESCE(strat, 'NA') AS strat,
       churn_days
FROM wangchuanliang.t7recalllist_0917
WHERE churn_user_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 2) KPI（提单率、本周提单/新增提单、放款、到期盈利与逾期）
-- ---------------------------------------------------------------------------
WITH params AS (
    SELECT DATE '2026-09-17' AS recall_dt,
           DATE_TRUNC('week', CURRENT_DATE)::date AS week_start,
           CURRENT_DATE AS as_of
),
apply_u AS (
    SELECT DISTINCT o.user_id
    FROM tmp_t7_u u
    INNER JOIN order_loan_f_v2_copy o ON o.user_id = u.user_id
    CROSS JOIN params p
    WHERE o.apply_date >= p.recall_dt
),
first_apply AS (
    SELECT o.user_id, MIN(o.apply_date) AS first_dt
    FROM tmp_t7_u u
    INNER JOIN order_loan_f_v2_copy o ON o.user_id = u.user_id
    CROSS JOIN params p
    WHERE o.apply_date >= p.recall_dt
    GROUP BY 1
)
SELECT
    (SELECT COUNT(*) FROM tmp_t7_u) AS n_user,
    (SELECT COUNT(*) FROM apply_u) AS n_apply,
    ROUND(100.0 * (SELECT COUNT(*) FROM apply_u)
        / NULLIF((SELECT COUNT(*) FROM tmp_t7_u), 0), 2) AS apply_rate,
    (SELECT COUNT(DISTINCT o.user_id)
     FROM tmp_t7_u u
     INNER JOIN order_loan_f_v2_copy o ON o.user_id = u.user_id
     CROSS JOIN params p
     WHERE o.apply_date >= p.week_start AND o.apply_date <= p.as_of) AS n_apply_week,
    (SELECT COUNT(*) FROM first_apply f CROSS JOIN params p
     WHERE f.first_dt >= p.week_start AND f.first_dt <= p.as_of) AS n_first_week,
    (SELECT COUNT(*)
     FROM tmp_t7_u u
     INNER JOIN order_loan_f_v2_copy o ON o.user_id = u.user_id
     CROSS JOIN params p
     WHERE o.apply_date >= p.recall_dt AND o.is_remit = 1
       AND COALESCE(o.remit_amt, 0) > 0) AS n_remit,
    (SELECT COUNT(*)
     FROM tmp_t7_u u
     INNER JOIN order_loan_f_v2_copy o ON o.user_id = u.user_id
     CROSS JOIN params p
     WHERE o.apply_date >= p.recall_dt AND o.is_remit = 1
       AND COALESCE(o.remit_amt, 0) > 0
       AND o.remit_date::date >= p.week_start AND o.remit_date::date <= p.as_of) AS n_remit_week,
    (SELECT COUNT(*)
     FROM tmp_t7_u u
     INNER JOIN order_loan_f_v2_copy o ON o.user_id = u.user_id
     CROSS JOIN params p
     WHERE o.apply_date >= p.recall_dt AND o.is_due = 1 AND o.is_remit = 1
       AND COALESCE(o.remit_amt, 0) > 0) AS n_due,
    (SELECT COUNT(*)
     FROM tmp_t7_u u
     INNER JOIN order_loan_f_v2_copy o ON o.user_id = u.user_id
     CROSS JOIN params p
     WHERE o.apply_date >= p.recall_dt AND o.is_due = 1 AND o.is_remit = 1
       AND COALESCE(o.remit_amt, 0) > 0 AND o.loan_status_code = 8) AS n_due_od,
    (SELECT SUM(COALESCE(o.repaid_amt, 0))
     FROM tmp_t7_u u
     INNER JOIN order_loan_f_v2_copy o ON o.user_id = u.user_id
     CROSS JOIN params p
     WHERE o.apply_date >= p.recall_dt AND o.is_due = 1 AND o.is_remit = 1
       AND COALESCE(o.remit_amt, 0) > 0) AS due_repaid,
    (SELECT SUM(o.remit_amt)
     FROM tmp_t7_u u
     INNER JOIN order_loan_f_v2_copy o ON o.user_id = u.user_id
     CROSS JOIN params p
     WHERE o.apply_date >= p.recall_dt AND o.is_due = 1 AND o.is_remit = 1
       AND COALESCE(o.remit_amt, 0) > 0) AS due_remit,
    (SELECT week_start FROM params) AS week_start,
    (SELECT as_of FROM params) AS as_of;

-- 盈利率 = (due_repaid - due_remit) / due_remit
-- 逾期率 = n_due_od / n_due

-- ---------------------------------------------------------------------------
-- 3) 召回后首次提单日分布（累计人数、累计提单率）
-- ---------------------------------------------------------------------------
WITH fa AS (
  SELECT o.user_id, MIN(o.apply_date) AS first_apply
  FROM tmp_t7_u u
  INNER JOIN order_loan_f_v2_copy o
    ON o.user_id = u.user_id AND o.apply_date >= DATE '2026-09-17'
  GROUP BY 1
)
SELECT first_apply::text AS d, COUNT(*) AS n
FROM fa
GROUP BY 1
ORDER BY 1;

-- ---------------------------------------------------------------------------
-- 4) 每日提单用户（当日有过提单的去重用户）与当日提单订单数
-- ---------------------------------------------------------------------------
SELECT o.apply_date::text AS d,
       COUNT(*) AS n_order,
       COUNT(DISTINCT o.user_id) AS n_user
FROM tmp_t7_u u
INNER JOIN order_loan_f_v2_copy o
  ON o.user_id = u.user_id AND o.apply_date >= DATE '2026-09-17'
GROUP BY 1
ORDER BY 1;

-- ---------------------------------------------------------------------------
-- 5) 每日放款单量
-- ---------------------------------------------------------------------------
SELECT o.remit_date::date::text AS d, COUNT(*) AS n
FROM tmp_t7_u u
INNER JOIN order_loan_f_v2_copy o ON o.user_id = u.user_id
WHERE o.apply_date >= DATE '2026-09-17'
  AND o.is_remit = 1 AND COALESCE(o.remit_amt, 0) > 0
  AND o.remit_date::date IS NOT NULL
GROUP BY 1
ORDER BY 1;

-- ---------------------------------------------------------------------------
-- 6) 按到期日的盈利率、逾期率
-- ---------------------------------------------------------------------------
SELECT o.due_date::text AS d,
       COUNT(*) AS n_due,
       SUM(CASE WHEN o.loan_status_code = 8 THEN 1 ELSE 0 END) AS n_od,
       SUM(COALESCE(o.repaid_amt, 0)) AS repaid,
       SUM(o.remit_amt) AS remit
FROM tmp_t7_u u
INNER JOIN order_loan_f_v2_copy o ON o.user_id = u.user_id
WHERE o.apply_date >= DATE '2026-09-17'
  AND o.is_due = 1 AND o.is_remit = 1 AND COALESCE(o.remit_amt, 0) > 0
  AND o.due_date IS NOT NULL
GROUP BY 1
ORDER BY 1;

-- ---------------------------------------------------------------------------
-- 7) 分层 strat 名单人数与提单率
-- ---------------------------------------------------------------------------
SELECT u.strat,
       COUNT(*) AS n_user,
       COUNT(a.user_id) AS n_apply
FROM tmp_t7_u u
LEFT JOIN (
  SELECT DISTINCT o.user_id
  FROM tmp_t7_u u
  INNER JOIN order_loan_f_v2_copy o
    ON o.user_id = u.user_id AND o.apply_date >= DATE '2026-09-17'
) a ON a.user_id = u.user_id
GROUP BY 1
ORDER BY n_user DESC;

-- ---------------------------------------------------------------------------
-- 8) 流失天数分箱名单人数与提单率
-- ---------------------------------------------------------------------------
SELECT
  CASE
    WHEN churn_days <= 15 THEN '7-15d'
    WHEN churn_days <= 30 THEN '16-30d'
    WHEN churn_days <= 60 THEN '31-60d'
    WHEN churn_days <= 90 THEN '61-90d'
    WHEN churn_days <= 180 THEN '91-180d'
    ELSE '180d+'
  END AS bin,
  COUNT(*) AS n_user,
  COUNT(a.user_id) AS n_apply
FROM tmp_t7_u u
LEFT JOIN (
  SELECT DISTINCT o.user_id
  FROM tmp_t7_u u
  INNER JOIN order_loan_f_v2_copy o
    ON o.user_id = u.user_id AND o.apply_date >= DATE '2026-09-17'
) a ON a.user_id = u.user_id
GROUP BY 1;
