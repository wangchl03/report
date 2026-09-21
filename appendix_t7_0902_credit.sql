-- T7 召回看板 · 获额通过口径 · 可复现 PGSQL
-- 库：kaby_dw · schema：wangchuanliang
-- 名单：wangchuanliang.t7recalllist_0902
-- 触达日：2026-09-02
-- 获额：order_vir_f_copy.vir_date >= 召回日
-- 获额通过：is_pass1 = 1；首次通过时间 = MIN(COALESCE(TO_TIMESTAMP(vir_unix), vir_date::timestamp))
-- 提单：获额通过后 apply_time >= pass_time 且 apply_date >= 召回日
-- 提单率分母：获额通过人数
-- 放款/到期：仍为召回日后提单订单（与原看板一致）
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
FROM wangchuanliang.t7recalllist_0902
WHERE churn_user_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 2) KPI（获额、获额通过、通过后提单、放款、到期盈利与逾期）
-- ---------------------------------------------------------------------------
WITH params AS (
    SELECT DATE '2026-09-02' AS recall_dt,
           DATE_TRUNC('week', CURRENT_DATE)::date AS week_start,
           CURRENT_DATE AS as_of
),
vir_u AS (
    SELECT DISTINCT v.user_id
    FROM tmp_t7_u u
    INNER JOIN wangchuanliang.order_vir_f_copy v ON v.user_id = u.user_id
    CROSS JOIN params p
    WHERE v.vir_date >= p.recall_dt
),
pass_u AS (
    SELECT v.user_id,
           MIN(COALESCE(TO_TIMESTAMP(v.vir_unix), v.vir_date::timestamp)) AS pass_time
    FROM tmp_t7_u u
    INNER JOIN wangchuanliang.order_vir_f_copy v ON v.user_id = u.user_id
    CROSS JOIN params p
    WHERE v.vir_date >= p.recall_dt AND v.is_pass1 = 1
    GROUP BY v.user_id
),
apply_after AS (
    SELECT o.user_id, o.apply_date
    FROM pass_u pu
    INNER JOIN order_loan_f_v2_copy o ON o.user_id = pu.user_id
    CROSS JOIN params p
    WHERE o.apply_date >= p.recall_dt
      AND o.apply_time >= pu.pass_time
),
apply_u AS (
    SELECT DISTINCT user_id FROM apply_after
),
first_apply AS (
    SELECT user_id, MIN(apply_date) AS first_dt
    FROM apply_after
    GROUP BY user_id
)
SELECT
    (SELECT COUNT(*) FROM tmp_t7_u) AS n_user,
    (SELECT COUNT(*) FROM vir_u) AS n_vir,
    (SELECT COUNT(*) FROM pass_u) AS n_pass,
    ROUND(100.0 * (SELECT COUNT(*) FROM pass_u)
        / NULLIF((SELECT COUNT(*) FROM vir_u), 0), 2) AS pass_rate,
    (SELECT COUNT(*) FROM apply_u) AS n_apply,
    ROUND(100.0 * (SELECT COUNT(*) FROM apply_u)
        / NULLIF((SELECT COUNT(*) FROM pass_u), 0), 2) AS apply_rate,
    (SELECT COUNT(*) FROM apply_after) AS n_apply_order,
    (SELECT COUNT(DISTINCT aa.user_id)
     FROM apply_after aa
     CROSS JOIN params p
     WHERE aa.apply_date >= p.week_start AND aa.apply_date <= p.as_of) AS n_apply_week,
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

-- 获额通过率 = n_pass / n_vir
-- 提单率 = n_apply / n_pass
-- 盈利率 = (due_repaid - due_remit) / due_remit
-- 逾期率 = n_due_od / n_due

-- ---------------------------------------------------------------------------
-- 3) 获额通过后首次提单日分布（累计人数、累计提单率；分母=获额通过人数）
-- ---------------------------------------------------------------------------
WITH pass_u AS (
  SELECT v.user_id,
         MIN(COALESCE(TO_TIMESTAMP(v.vir_unix), v.vir_date::timestamp)) AS pass_time
  FROM tmp_t7_u u
  INNER JOIN wangchuanliang.order_vir_f_copy v ON v.user_id = u.user_id
  WHERE v.vir_date >= DATE '2026-09-02' AND v.is_pass1 = 1
  GROUP BY v.user_id
),
fa AS (
  SELECT o.user_id, MIN(o.apply_date) AS first_apply
  FROM pass_u pu
  INNER JOIN order_loan_f_v2_copy o
    ON o.user_id = pu.user_id
   AND o.apply_date >= DATE '2026-09-02'
   AND o.apply_time >= pu.pass_time
  GROUP BY o.user_id
)
SELECT first_apply::text AS d, COUNT(*) AS n
FROM fa
GROUP BY first_apply
ORDER BY first_apply;

-- ---------------------------------------------------------------------------
-- 4) 每日提单用户（获额通过后当日有过提单的去重用户）与当日提单订单数
-- ---------------------------------------------------------------------------
WITH pass_u AS (
  SELECT v.user_id,
         MIN(COALESCE(TO_TIMESTAMP(v.vir_unix), v.vir_date::timestamp)) AS pass_time
  FROM tmp_t7_u u
  INNER JOIN wangchuanliang.order_vir_f_copy v ON v.user_id = u.user_id
  WHERE v.vir_date >= DATE '2026-09-02' AND v.is_pass1 = 1
  GROUP BY v.user_id
)
SELECT o.apply_date::text AS d,
       COUNT(*) AS n_order,
       COUNT(DISTINCT o.user_id) AS n_user
FROM pass_u pu
INNER JOIN order_loan_f_v2_copy o
  ON o.user_id = pu.user_id
 AND o.apply_date >= DATE '2026-09-02'
 AND o.apply_time >= pu.pass_time
GROUP BY o.apply_date
ORDER BY o.apply_date;

-- ---------------------------------------------------------------------------
-- 5) 每日放款单量
-- ---------------------------------------------------------------------------
SELECT o.remit_date::date::text AS d, COUNT(*) AS n
FROM tmp_t7_u u
INNER JOIN order_loan_f_v2_copy o ON o.user_id = u.user_id
WHERE o.apply_date >= DATE '2026-09-02'
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
WHERE o.apply_date >= DATE '2026-09-02'
  AND o.is_due = 1 AND o.is_remit = 1 AND COALESCE(o.remit_amt, 0) > 0
  AND o.due_date IS NOT NULL
GROUP BY 1
ORDER BY 1;

-- ---------------------------------------------------------------------------
-- 7) 分层 strat：获额通过人数与通过后提单率
-- ---------------------------------------------------------------------------
WITH pass_u AS (
  SELECT v.user_id,
         MIN(COALESCE(TO_TIMESTAMP(v.vir_unix), v.vir_date::timestamp)) AS pass_time
  FROM tmp_t7_u u
  INNER JOIN wangchuanliang.order_vir_f_copy v ON v.user_id = u.user_id
  WHERE v.vir_date >= DATE '2026-09-02' AND v.is_pass1 = 1
  GROUP BY v.user_id
),
apply_u AS (
  SELECT DISTINCT o.user_id
  FROM pass_u pu
  INNER JOIN order_loan_f_v2_copy o
    ON o.user_id = pu.user_id
   AND o.apply_date >= DATE '2026-09-02'
   AND o.apply_time >= pu.pass_time
)
SELECT u.strat,
       COUNT(*) AS n_pass,
       COUNT(a.user_id) AS n_apply
FROM tmp_t7_u u
INNER JOIN pass_u p ON p.user_id = u.user_id
LEFT JOIN apply_u a ON a.user_id = u.user_id
GROUP BY u.strat
ORDER BY n_pass DESC;

-- ---------------------------------------------------------------------------
-- 8) 流失天数分箱：获额通过人数与通过后提单率
-- ---------------------------------------------------------------------------
WITH pass_u AS (
  SELECT v.user_id,
         MIN(COALESCE(TO_TIMESTAMP(v.vir_unix), v.vir_date::timestamp)) AS pass_time
  FROM tmp_t7_u u
  INNER JOIN wangchuanliang.order_vir_f_copy v ON v.user_id = u.user_id
  WHERE v.vir_date >= DATE '2026-09-02' AND v.is_pass1 = 1
  GROUP BY v.user_id
),
apply_u AS (
  SELECT DISTINCT o.user_id
  FROM pass_u pu
  INNER JOIN order_loan_f_v2_copy o
    ON o.user_id = pu.user_id
   AND o.apply_date >= DATE '2026-09-02'
   AND o.apply_time >= pu.pass_time
)
SELECT
  CASE
    WHEN u.churn_days <= 15 THEN '7-15d'
    WHEN u.churn_days <= 30 THEN '16-30d'
    WHEN u.churn_days <= 60 THEN '31-60d'
    WHEN u.churn_days <= 90 THEN '61-90d'
    WHEN u.churn_days <= 180 THEN '91-180d'
    ELSE '180d+'
  END AS bin,
  COUNT(*) AS n_pass,
  COUNT(a.user_id) AS n_apply
FROM tmp_t7_u u
INNER JOIN pass_u p ON p.user_id = u.user_id
LEFT JOIN apply_u a ON a.user_id = u.user_id
GROUP BY
  CASE
    WHEN u.churn_days <= 15 THEN '7-15d'
    WHEN u.churn_days <= 30 THEN '16-30d'
    WHEN u.churn_days <= 60 THEN '31-60d'
    WHEN u.churn_days <= 90 THEN '61-90d'
    WHEN u.churn_days <= 180 THEN '91-180d'
    ELSE '180d+'
  END;
