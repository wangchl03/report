-- =============================================================================
-- T0 结清0在贷获额后：当日5类行为 × 首次提单窗口 × 盈利率 / 息费 / 整笔逾期率
-- 库：kaby_dw（GaussDB）  统计日：CURRENT_DATE
-- 一次跑完 2026-01-01（含）～ 2026-09-01（不含），可复现报告全部月表与合计。
--
-- 口径
--   T0：is_pass1=1 AND loan_type_code=2 AND recycle_type=3；20秒获额批次去重；
--       同日结清且 vir_time>=repaid_time；结清时无其他在途/在贷；用户×结清日最早一轮获额。
--   有行为：获额当日、T 之后出现过改额/改期/看合同/看计划/选原因（不含确认提单、进页、停留）。
--   首次提单窗口（自然日，相对获额日）：当日 / 1-3日 / 4-7日 / 7日以后 / never。
--   月度提单率 = 1 - never/T0。
--   盈利率、逾期率：首次提单且已放款、due_date < CURRENT_DATE。
--   还款：repayment_record_copy.amount，payin_date ∈ [apply_date, due_date]。
--   盈利率 = Σamount/Σremit_amt - 1。
--   息费：已放款（未到期也算）Σ(pre_amt+post_amt)/Σremit_amt。
--   整笔逾期：repaid_date > due_date，或 repaid_date 空/≤2000-01-01。
-- 注意：event_track_record 必须带 create_date 分区条件。8月「7日以后/未提单」有右截断。
-- =============================================================================

SET statement_timeout = 420000;

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
    SELECT e.user_id, e.serial_id AS credit_serial_id, e.vir_date, e.vir_time,
           ROW_NUMBER() OVER (PARTITION BY e.user_id, e.vir_date ORDER BY e.vir_time ASC, e.serial_id DESC) AS day_rn
    FROM dedup_offer e
    INNER JOIN clean_settlement s
        ON s.user_id = e.user_id AND s.repaid_date = e.vir_date AND e.vir_time >= s.repaid_time
)
SELECT user_id, credit_serial_id, vir_date, vir_time FROM paired WHERE day_rn = 1;

DROP TABLE IF EXISTS tmp_first;
CREATE TEMP TABLE tmp_first AS
SELECT t.user_id, t.vir_date, t.vir_time,
       o.serial_id, o.apply_date, o.apply_time, o.due_date, o.is_remit, o.remit_amt,
       o.pre_amt, o.post_amt, o.repaid_date,
       CASE
         WHEN o.serial_id IS NULL THEN 'never'
         WHEN o.apply_date = t.vir_date THEN '当日'
         WHEN o.apply_date >= t.vir_date + 1 AND o.apply_date <= t.vir_date + 3 THEN '1-3日'
         WHEN o.apply_date >= t.vir_date + 4 AND o.apply_date <= t.vir_date + 7 THEN '4-7日'
         ELSE '7日以后'
       END AS bucket
FROM tmp_m_origin t
LEFT JOIN (
    SELECT user_id, vir_date, serial_id, apply_date, apply_time, due_date, is_remit, remit_amt, pre_amt, post_amt, repaid_date
    FROM (
        SELECT t.user_id, t.vir_date, a.serial_id, a.apply_date, a.apply_time, a.due_date, a.is_remit,
               a.remit_amt, a.pre_amt, a.post_amt, a.repaid_date,
               ROW_NUMBER() OVER (PARTITION BY t.user_id, t.vir_date ORDER BY a.apply_time, a.serial_id) AS rn
        FROM tmp_m_origin t
        INNER JOIN wangchuanliang.order_loan_f_v2_copy a
          ON a.user_id = t.user_id AND a.apply_time >= t.vir_time
    ) z WHERE rn = 1
) o ON o.user_id = t.user_id AND o.vir_date = t.vir_date;

DROP TABLE IF EXISTS tmp_beh;
CREATE TEMP TABLE tmp_beh AS
SELECT t.user_id, t.vir_date, 1 AS has_beh
FROM tmp_m_origin t
INNER JOIN wangchuanliang.event_track_record e
  ON e.user_id = t.user_id
 AND e.create_date >= DATE '2026-01-01'
 AND e.create_date <  DATE '2026-09-01'
 AND e.create_date = t.vir_date
 AND e.create_time >= t.vir_time
 AND e.create_time < t.vir_date + 1
 AND e.props_id IN (
   'amount_modification','loan_form_loan_amount_selectionn_new','loan_form_loan_amount_selectionn_new_select',
   'loan_form_term_selection_new','loan_form_term_selection_new_select',
   'Loan_contract_newdetails','Loan_contract_newdetails_select',
   'Loan_plan_newdetails','Loan_plan_newdetails_select',
   'Loan_purpose_newdetails','Loan_purpose_newdetails_select'
 )
GROUP BY t.user_id, t.vir_date;

DROP TABLE IF EXISTS tmp_base;
CREATE TEMP TABLE tmp_base AS
SELECT
  f.user_id,
  f.vir_date,
  DATE_TRUNC('month', f.vir_date)::date AS ym,
  f.bucket,
  CASE WHEN b.has_beh = 1 THEN 1 ELSE 0 END AS has_beh,
  f.serial_id,
  f.apply_date,
  f.due_date,
  f.is_remit,
  f.remit_amt,
  f.pre_amt,
  f.post_amt,
  f.repaid_date
FROM tmp_first f
LEFT JOIN tmp_beh b ON b.user_id = f.user_id AND b.vir_date = f.vir_date;

-- -----------------------------------------------------------------------------
-- A1 有/无行为结构（分月 + 合计）
-- -----------------------------------------------------------------------------
SELECT
  COALESCE(TO_CHAR(ym, 'YYYY-MM'), '合计') AS ym,
  COUNT(*) AS t0,
  SUM(has_beh) AS n_beh,
  ROUND(100.0 * SUM(has_beh) / COUNT(*), 2) AS beh_pct,
  SUM(1 - has_beh) AS n_nobeh,
  ROUND(100.0 * SUM(1 - has_beh) / COUNT(*), 2) AS nobeh_pct
FROM tmp_base
GROUP BY ROLLUP (ym)
ORDER BY 1;

-- -----------------------------------------------------------------------------
-- A2 首次提单窗口占 T0（分月 + 合计）
-- 月度提单率 = 100 - never_pct
-- -----------------------------------------------------------------------------
SELECT
  COALESCE(TO_CHAR(ym, 'YYYY-MM'), '合计') AS ym,
  COUNT(*) AS t0,
  ROUND(100.0 * SUM(CASE WHEN bucket <> 'never' THEN 1 ELSE 0 END) / COUNT(*), 2) AS apply_rate_pct,
  ROUND(100.0 * SUM(CASE WHEN bucket = '当日' THEN 1 ELSE 0 END) / COUNT(*), 2) AS d0_pct,
  ROUND(100.0 * SUM(CASE WHEN bucket = '1-3日' THEN 1 ELSE 0 END) / COUNT(*), 2) AS d1_3_pct,
  ROUND(100.0 * SUM(CASE WHEN bucket = '4-7日' THEN 1 ELSE 0 END) / COUNT(*), 2) AS d4_7_pct,
  ROUND(100.0 * SUM(CASE WHEN bucket = '7日以后' THEN 1 ELSE 0 END) / COUNT(*), 2) AS d8p_pct,
  ROUND(100.0 * SUM(CASE WHEN bucket = 'never' THEN 1 ELSE 0 END) / COUNT(*), 2) AS never_pct,
  SUM(CASE WHEN bucket = '当日' THEN 1 ELSE 0 END) AS n_d0,
  SUM(CASE WHEN bucket = '1-3日' THEN 1 ELSE 0 END) AS n_d1_3,
  SUM(CASE WHEN bucket = '4-7日' THEN 1 ELSE 0 END) AS n_d4_7,
  SUM(CASE WHEN bucket = '7日以后' THEN 1 ELSE 0 END) AS n_d8p,
  SUM(CASE WHEN bucket = 'never' THEN 1 ELSE 0 END) AS n_never
FROM tmp_base
GROUP BY ROLLUP (ym)
ORDER BY 1;

-- -----------------------------------------------------------------------------
-- A3 有行为组内窗口率
-- -----------------------------------------------------------------------------
SELECT
  COALESCE(TO_CHAR(ym, 'YYYY-MM'), '合计') AS ym,
  COUNT(*) AS t0_beh,
  ROUND(100.0 * SUM(CASE WHEN bucket <> 'never' THEN 1 ELSE 0 END) / COUNT(*), 2) AS apply_rate_pct,
  ROUND(100.0 * SUM(CASE WHEN bucket = '当日' THEN 1 ELSE 0 END) / COUNT(*), 2) AS d0_pct,
  ROUND(100.0 * SUM(CASE WHEN bucket = '1-3日' THEN 1 ELSE 0 END) / COUNT(*), 2) AS d1_3_pct,
  ROUND(100.0 * SUM(CASE WHEN bucket = '4-7日' THEN 1 ELSE 0 END) / COUNT(*), 2) AS d4_7_pct,
  ROUND(100.0 * SUM(CASE WHEN bucket = '7日以后' THEN 1 ELSE 0 END) / COUNT(*), 2) AS d8p_pct,
  ROUND(100.0 * SUM(CASE WHEN bucket = 'never' THEN 1 ELSE 0 END) / COUNT(*), 2) AS never_pct
FROM tmp_base
WHERE has_beh = 1
GROUP BY ROLLUP (ym)
ORDER BY 1;

-- -----------------------------------------------------------------------------
-- A4 无行为组内窗口率
-- -----------------------------------------------------------------------------
SELECT
  COALESCE(TO_CHAR(ym, 'YYYY-MM'), '合计') AS ym,
  COUNT(*) AS t0_nobeh,
  ROUND(100.0 * SUM(CASE WHEN bucket <> 'never' THEN 1 ELSE 0 END) / COUNT(*), 2) AS apply_rate_pct,
  ROUND(100.0 * SUM(CASE WHEN bucket = '当日' THEN 1 ELSE 0 END) / COUNT(*), 2) AS d0_pct,
  ROUND(100.0 * SUM(CASE WHEN bucket = '1-3日' THEN 1 ELSE 0 END) / COUNT(*), 2) AS d1_3_pct,
  ROUND(100.0 * SUM(CASE WHEN bucket = '4-7日' THEN 1 ELSE 0 END) / COUNT(*), 2) AS d4_7_pct,
  ROUND(100.0 * SUM(CASE WHEN bucket = '7日以后' THEN 1 ELSE 0 END) / COUNT(*), 2) AS d8p_pct,
  ROUND(100.0 * SUM(CASE WHEN bucket = 'never' THEN 1 ELSE 0 END) / COUNT(*), 2) AS never_pct
FROM tmp_base
WHERE has_beh = 0
GROUP BY ROLLUP (ym)
ORDER BY 1;

-- -----------------------------------------------------------------------------
-- A5 有行为提单人数占总提单人数（总体 + 分窗口）
-- -----------------------------------------------------------------------------
SELECT
  COALESCE(TO_CHAR(ym, 'YYYY-MM'), '合计') AS ym,
  ROUND(100.0 * SUM(CASE WHEN bucket <> 'never' AND has_beh = 1 THEN 1 ELSE 0 END)
              / NULLIF(SUM(CASE WHEN bucket <> 'never' THEN 1 ELSE 0 END), 0), 2) AS beh_share_all_apply,
  ROUND(100.0 * SUM(CASE WHEN bucket = '当日' AND has_beh = 1 THEN 1 ELSE 0 END)
              / NULLIF(SUM(CASE WHEN bucket = '当日' THEN 1 ELSE 0 END), 0), 2) AS beh_share_d0,
  ROUND(100.0 * SUM(CASE WHEN bucket = '1-3日' AND has_beh = 1 THEN 1 ELSE 0 END)
              / NULLIF(SUM(CASE WHEN bucket = '1-3日' THEN 1 ELSE 0 END), 0), 2) AS beh_share_d1_3,
  ROUND(100.0 * SUM(CASE WHEN bucket = '4-7日' AND has_beh = 1 THEN 1 ELSE 0 END)
              / NULLIF(SUM(CASE WHEN bucket = '4-7日' THEN 1 ELSE 0 END), 0), 2) AS beh_share_d4_7,
  ROUND(100.0 * SUM(CASE WHEN bucket = '7日以后' AND has_beh = 1 THEN 1 ELSE 0 END)
              / NULLIF(SUM(CASE WHEN bucket = '7日以后' THEN 1 ELSE 0 END), 0), 2) AS beh_share_d8p
FROM tmp_base
GROUP BY ROLLUP (ym)
ORDER BY 1;

-- -----------------------------------------------------------------------------
-- B 盈利率：已放款且整笔已到期；还款 = repayment_record_copy.amount
-- 盈利率 = repay_sum / remit_sum - 1
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS tmp_repay;
CREATE TEMP TABLE tmp_repay AS
SELECT f.serial_id, SUM(r.amount) AS repay_amt
FROM tmp_first f
INNER JOIN wangchuanliang.repayment_record_copy r ON r.serial_id = f.serial_id
WHERE f.is_remit = 1 AND f.due_date < CURRENT_DATE AND COALESCE(f.remit_amt, 0) > 0
  AND r.payin_date >= f.apply_date AND r.payin_date <= f.due_date
GROUP BY f.serial_id;

SELECT
  COALESCE(TO_CHAR(b.ym, 'YYYY-MM'), '合计') AS ym,
  b.bucket,
  SUM(CASE WHEN b.is_remit = 1 AND b.due_date < CURRENT_DATE AND COALESCE(b.remit_amt, 0) > 0 THEN 1 ELSE 0 END) AS n_due,
  ROUND(100.0 * (
    SUM(CASE WHEN b.is_remit = 1 AND b.due_date < CURRENT_DATE AND COALESCE(b.remit_amt, 0) > 0 THEN COALESCE(rp.repay_amt, 0) ELSE 0 END)
    / NULLIF(SUM(CASE WHEN b.is_remit = 1 AND b.due_date < CURRENT_DATE AND COALESCE(b.remit_amt, 0) > 0 THEN b.remit_amt ELSE 0 END), 0)
    - 1
  ), 2) AS profit_all_pct,
  ROUND(100.0 * (
    SUM(CASE WHEN b.has_beh = 1 AND b.is_remit = 1 AND b.due_date < CURRENT_DATE AND COALESCE(b.remit_amt, 0) > 0 THEN COALESCE(rp.repay_amt, 0) ELSE 0 END)
    / NULLIF(SUM(CASE WHEN b.has_beh = 1 AND b.is_remit = 1 AND b.due_date < CURRENT_DATE AND COALESCE(b.remit_amt, 0) > 0 THEN b.remit_amt ELSE 0 END), 0)
    - 1
  ), 2) AS profit_beh_pct,
  ROUND(100.0 * (
    SUM(CASE WHEN b.has_beh = 0 AND b.is_remit = 1 AND b.due_date < CURRENT_DATE AND COALESCE(b.remit_amt, 0) > 0 THEN COALESCE(rp.repay_amt, 0) ELSE 0 END)
    / NULLIF(SUM(CASE WHEN b.has_beh = 0 AND b.is_remit = 1 AND b.due_date < CURRENT_DATE AND COALESCE(b.remit_amt, 0) > 0 THEN b.remit_amt ELSE 0 END), 0)
    - 1
  ), 2) AS profit_nobeh_pct
FROM tmp_base b
LEFT JOIN tmp_repay rp ON rp.serial_id = b.serial_id
WHERE b.bucket <> 'never'
GROUP BY ROLLUP (b.ym), b.bucket
ORDER BY 1, 2;

-- -----------------------------------------------------------------------------
-- C 息费：已放款（含未到期）= Σ(pre_amt+post_amt)/Σremit_amt
-- -----------------------------------------------------------------------------
SELECT
  COALESCE(TO_CHAR(ym, 'YYYY-MM'), '合计') AS ym,
  bucket,
  SUM(CASE WHEN is_remit = 1 AND COALESCE(remit_amt, 0) > 0 THEN 1 ELSE 0 END) AS n_remit,
  ROUND(100.0 * SUM(CASE WHEN is_remit = 1 AND COALESCE(remit_amt, 0) > 0 THEN COALESCE(pre_amt, 0) + COALESCE(post_amt, 0) ELSE 0 END)
              / NULLIF(SUM(CASE WHEN is_remit = 1 AND COALESCE(remit_amt, 0) > 0 THEN remit_amt ELSE 0 END), 0), 2) AS fee_all_pct,
  ROUND(100.0 * SUM(CASE WHEN has_beh = 1 AND is_remit = 1 AND COALESCE(remit_amt, 0) > 0 THEN COALESCE(pre_amt, 0) + COALESCE(post_amt, 0) ELSE 0 END)
              / NULLIF(SUM(CASE WHEN has_beh = 1 AND is_remit = 1 AND COALESCE(remit_amt, 0) > 0 THEN remit_amt ELSE 0 END), 0), 2) AS fee_beh_pct,
  ROUND(100.0 * SUM(CASE WHEN has_beh = 0 AND is_remit = 1 AND COALESCE(remit_amt, 0) > 0 THEN COALESCE(pre_amt, 0) + COALESCE(post_amt, 0) ELSE 0 END)
              / NULLIF(SUM(CASE WHEN has_beh = 0 AND is_remit = 1 AND COALESCE(remit_amt, 0) > 0 THEN remit_amt ELSE 0 END), 0), 2) AS fee_nobeh_pct
FROM tmp_base
WHERE bucket <> 'never'
GROUP BY ROLLUP (ym), bucket
ORDER BY 1, 2;

-- -----------------------------------------------------------------------------
-- D 整笔订单逾期率：已放款且已到期
-- -----------------------------------------------------------------------------
SELECT
  COALESCE(TO_CHAR(ym, 'YYYY-MM'), '合计') AS ym,
  bucket,
  SUM(CASE WHEN is_remit = 1 AND due_date < CURRENT_DATE AND COALESCE(remit_amt, 0) > 0 THEN 1 ELSE 0 END) AS n_due,
  ROUND(100.0 * SUM(CASE WHEN is_remit = 1 AND due_date < CURRENT_DATE AND COALESCE(remit_amt, 0) > 0
        AND (repaid_date IS NULL OR repaid_date <= DATE '2000-01-01' OR repaid_date > due_date) THEN 1 ELSE 0 END)
              / NULLIF(SUM(CASE WHEN is_remit = 1 AND due_date < CURRENT_DATE AND COALESCE(remit_amt, 0) > 0 THEN 1 ELSE 0 END), 0), 2) AS od_all_pct,
  ROUND(100.0 * SUM(CASE WHEN has_beh = 1 AND is_remit = 1 AND due_date < CURRENT_DATE AND COALESCE(remit_amt, 0) > 0
        AND (repaid_date IS NULL OR repaid_date <= DATE '2000-01-01' OR repaid_date > due_date) THEN 1 ELSE 0 END)
              / NULLIF(SUM(CASE WHEN has_beh = 1 AND is_remit = 1 AND due_date < CURRENT_DATE AND COALESCE(remit_amt, 0) > 0 THEN 1 ELSE 0 END), 0), 2) AS od_beh_pct,
  ROUND(100.0 * SUM(CASE WHEN has_beh = 0 AND is_remit = 1 AND due_date < CURRENT_DATE AND COALESCE(remit_amt, 0) > 0
        AND (repaid_date IS NULL OR repaid_date <= DATE '2000-01-01' OR repaid_date > due_date) THEN 1 ELSE 0 END)
              / NULLIF(SUM(CASE WHEN has_beh = 0 AND is_remit = 1 AND due_date < CURRENT_DATE AND COALESCE(remit_amt, 0) > 0 THEN 1 ELSE 0 END), 0), 2) AS od_nobeh_pct
FROM tmp_base
WHERE bucket <> 'never'
GROUP BY ROLLUP (ym), bucket
ORDER BY 1, 2;

-- =============================================================================
-- E 交叉分析（第五部分）：提单率 × 息费 × 逾期 × 盈利率 同表复现
-- =============================================================================

DROP TABLE IF EXISTS tmp_cross_month;
CREATE TEMP TABLE tmp_cross_month AS
SELECT
  b.ym,
  COUNT(*) AS t0,
  SUM(b.has_beh) AS n_beh,
  ROUND(100.0 * SUM(b.has_beh) / COUNT(*), 2) AS beh_pct,
  ROUND(100.0 * SUM(CASE WHEN b.bucket <> 'never' THEN 1 ELSE 0 END) / COUNT(*), 2) AS apply_rate_pct,
  ROUND(100.0 * SUM(CASE WHEN b.bucket = '当日' THEN 1 ELSE 0 END) / COUNT(*), 2) AS d0_apply_pct,
  ROUND(100.0 * SUM(CASE WHEN b.bucket = '1-3日' THEN 1 ELSE 0 END) / COUNT(*), 2) AS d1_3_pct,
  ROUND(100.0 * SUM(CASE WHEN b.bucket = '4-7日' THEN 1 ELSE 0 END) / COUNT(*), 2) AS d4_7_pct,
  ROUND(100.0 * SUM(CASE WHEN b.bucket = '7日以后' THEN 1 ELSE 0 END) / COUNT(*), 2) AS d8p_pct,
  ROUND(100.0 * SUM(CASE WHEN b.bucket = 'never' THEN 1 ELSE 0 END) / COUNT(*), 2) AS never_pct,
  ROUND(100.0 * SUM(CASE WHEN b.has_beh = 1 AND b.bucket = '当日' THEN 1 ELSE 0 END)
              / NULLIF(SUM(b.has_beh), 0), 2) AS beh_d0_apply_pct,
  ROUND(100.0 * SUM(CASE WHEN b.has_beh = 0 AND b.bucket = '当日' THEN 1 ELSE 0 END)
              / NULLIF(SUM(1 - b.has_beh), 0), 2) AS nobeh_d0_apply_pct,
  ROUND(100.0 * SUM(CASE WHEN b.has_beh = 1 AND b.bucket = 'never' THEN 1 ELSE 0 END)
              / NULLIF(SUM(b.has_beh), 0), 2) AS beh_never_pct,
  ROUND(100.0 * SUM(CASE WHEN b.has_beh = 0 AND b.bucket = 'never' THEN 1 ELSE 0 END)
              / NULLIF(SUM(1 - b.has_beh), 0), 2) AS nobeh_never_pct,
  ROUND(100.0 * SUM(CASE WHEN b.has_beh = 1 AND b.bucket = '1-3日' THEN 1 ELSE 0 END)
              / NULLIF(SUM(b.has_beh), 0), 2) AS beh_d1_3_pct,
  ROUND(100.0 * SUM(CASE WHEN b.has_beh = 1 AND b.bucket = '4-7日' THEN 1 ELSE 0 END)
              / NULLIF(SUM(b.has_beh), 0), 2) AS beh_d4_7_pct,
  ROUND(100.0 * SUM(CASE WHEN b.bucket <> 'never' AND b.has_beh = 1 THEN 1 ELSE 0 END)
              / NULLIF(SUM(CASE WHEN b.bucket <> 'never' THEN 1 ELSE 0 END), 0), 2) AS beh_share_apply,
  ROUND(100.0 * SUM(CASE WHEN b.bucket = '当日' AND b.has_beh = 1 THEN 1 ELSE 0 END)
              / NULLIF(SUM(CASE WHEN b.bucket = '当日' THEN 1 ELSE 0 END), 0), 2) AS beh_share_d0,
  ROUND(100.0 * SUM(CASE WHEN b.bucket = '1-3日' AND b.has_beh = 1 THEN 1 ELSE 0 END)
              / NULLIF(SUM(CASE WHEN b.bucket = '1-3日' THEN 1 ELSE 0 END), 0), 2) AS beh_share_d1_3,
  ROUND(100.0 * SUM(CASE WHEN b.is_remit = 1 AND b.bucket = '当日' AND COALESCE(b.remit_amt, 0) > 0
                    THEN COALESCE(b.pre_amt, 0) + COALESCE(b.post_amt, 0) ELSE 0 END)
              / NULLIF(SUM(CASE WHEN b.is_remit = 1 AND b.bucket = '当日' AND COALESCE(b.remit_amt, 0) > 0 THEN b.remit_amt ELSE 0 END), 0), 2) AS d0_fee_pct,
  ROUND(100.0 * SUM(CASE WHEN b.is_remit = 1 AND b.bucket = '当日' AND b.due_date < CURRENT_DATE AND COALESCE(b.remit_amt, 0) > 0
                    AND (b.repaid_date IS NULL OR b.repaid_date <= DATE '2000-01-01' OR b.repaid_date > b.due_date) THEN 1 ELSE 0 END)
              / NULLIF(SUM(CASE WHEN b.is_remit = 1 AND b.bucket = '当日' AND b.due_date < CURRENT_DATE AND COALESCE(b.remit_amt, 0) > 0 THEN 1 ELSE 0 END), 0), 2) AS d0_od_pct,
  ROUND(100.0 * (
    SUM(CASE WHEN b.is_remit = 1 AND b.bucket = '当日' AND b.due_date < CURRENT_DATE AND COALESCE(b.remit_amt, 0) > 0 THEN COALESCE(rp.repay_amt, 0) ELSE 0 END)
    / NULLIF(SUM(CASE WHEN b.is_remit = 1 AND b.bucket = '当日' AND b.due_date < CURRENT_DATE AND COALESCE(b.remit_amt, 0) > 0 THEN b.remit_amt ELSE 0 END), 0)
    - 1
  ), 2) AS d0_profit_pct
FROM tmp_base b
LEFT JOIN tmp_repay rp ON rp.serial_id = b.serial_id
GROUP BY b.ym;

-- 【块E1】图8 / 表5.7 当日：提单率、息费、逾期、盈利率、有行为当日提单率
SELECT
  TO_CHAR(ym, 'YYYY-MM') AS ym,
  d0_apply_pct AS 当日提单率,
  d0_fee_pct AS 当日息费,
  d0_od_pct AS 当日逾期,
  d0_profit_pct AS 当日盈利率,
  beh_d0_apply_pct AS 有行为当日提单率,
  nobeh_d0_apply_pct AS 无行为当日提单率,
  ROUND(d0_fee_pct - d0_profit_pct, 2) AS 当日息费与盈利缺口pp,
  apply_rate_pct AS 月度提单率,
  never_pct AS 未提单率,
  beh_pct AS 有行为覆盖
FROM tmp_cross_month
ORDER BY ym;

-- 【块E2】窗口合计交叉：占T0、息费、逾期、盈利率、缺口、有/无行为质量
SELECT
  b.bucket,
  COUNT(*) AS n_t0,
  ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM tmp_base), 2) AS 占T0,
  ROUND(100.0 * SUM(CASE WHEN b.is_remit = 1 AND COALESCE(b.remit_amt, 0) > 0 THEN COALESCE(b.pre_amt, 0) + COALESCE(b.post_amt, 0) ELSE 0 END)
              / NULLIF(SUM(CASE WHEN b.is_remit = 1 AND COALESCE(b.remit_amt, 0) > 0 THEN b.remit_amt ELSE 0 END), 0), 2) AS 息费,
  ROUND(100.0 * SUM(CASE WHEN b.is_remit = 1 AND b.due_date < CURRENT_DATE AND COALESCE(b.remit_amt, 0) > 0
                    AND (b.repaid_date IS NULL OR b.repaid_date <= DATE '2000-01-01' OR b.repaid_date > b.due_date) THEN 1 ELSE 0 END)
              / NULLIF(SUM(CASE WHEN b.is_remit = 1 AND b.due_date < CURRENT_DATE AND COALESCE(b.remit_amt, 0) > 0 THEN 1 ELSE 0 END), 0), 2) AS 逾期,
  ROUND(100.0 * (
    SUM(CASE WHEN b.is_remit = 1 AND b.due_date < CURRENT_DATE AND COALESCE(b.remit_amt, 0) > 0 THEN COALESCE(rp.repay_amt, 0) ELSE 0 END)
    / NULLIF(SUM(CASE WHEN b.is_remit = 1 AND b.due_date < CURRENT_DATE AND COALESCE(b.remit_amt, 0) > 0 THEN b.remit_amt ELSE 0 END), 0)
    - 1
  ), 2) AS 盈利率,
  ROUND(
    100.0 * SUM(CASE WHEN b.is_remit = 1 AND COALESCE(b.remit_amt, 0) > 0 THEN COALESCE(b.pre_amt, 0) + COALESCE(b.post_amt, 0) ELSE 0 END)
              / NULLIF(SUM(CASE WHEN b.is_remit = 1 AND COALESCE(b.remit_amt, 0) > 0 THEN b.remit_amt ELSE 0 END), 0)
    - 100.0 * (
      SUM(CASE WHEN b.is_remit = 1 AND b.due_date < CURRENT_DATE AND COALESCE(b.remit_amt, 0) > 0 THEN COALESCE(rp.repay_amt, 0) ELSE 0 END)
      / NULLIF(SUM(CASE WHEN b.is_remit = 1 AND b.due_date < CURRENT_DATE AND COALESCE(b.remit_amt, 0) > 0 THEN b.remit_amt ELSE 0 END), 0)
      - 1
    )
  , 2) AS 息费减盈利率缺口pp,
  ROUND(100.0 * SUM(CASE WHEN b.has_beh = 1 AND b.is_remit = 1 AND b.due_date < CURRENT_DATE AND COALESCE(b.remit_amt, 0) > 0
                    AND (b.repaid_date IS NULL OR b.repaid_date <= DATE '2000-01-01' OR b.repaid_date > b.due_date) THEN 1 ELSE 0 END)
              / NULLIF(SUM(CASE WHEN b.has_beh = 1 AND b.is_remit = 1 AND b.due_date < CURRENT_DATE AND COALESCE(b.remit_amt, 0) > 0 THEN 1 ELSE 0 END), 0), 2) AS 有行为逾期,
  ROUND(100.0 * SUM(CASE WHEN b.has_beh = 0 AND b.is_remit = 1 AND b.due_date < CURRENT_DATE AND COALESCE(b.remit_amt, 0) > 0
                    AND (b.repaid_date IS NULL OR b.repaid_date <= DATE '2000-01-01' OR b.repaid_date > b.due_date) THEN 1 ELSE 0 END)
              / NULLIF(SUM(CASE WHEN b.has_beh = 0 AND b.is_remit = 1 AND b.due_date < CURRENT_DATE AND COALESCE(b.remit_amt, 0) > 0 THEN 1 ELSE 0 END), 0), 2) AS 无行为逾期,
  ROUND(100.0 * (
    SUM(CASE WHEN b.has_beh = 1 AND b.is_remit = 1 AND b.due_date < CURRENT_DATE AND COALESCE(b.remit_amt, 0) > 0 THEN COALESCE(rp.repay_amt, 0) ELSE 0 END)
    / NULLIF(SUM(CASE WHEN b.has_beh = 1 AND b.is_remit = 1 AND b.due_date < CURRENT_DATE AND COALESCE(b.remit_amt, 0) > 0 THEN b.remit_amt ELSE 0 END), 0)
    - 1
  ), 2) AS 有行为盈利率,
  ROUND(100.0 * (
    SUM(CASE WHEN b.has_beh = 0 AND b.is_remit = 1 AND b.due_date < CURRENT_DATE AND COALESCE(b.remit_amt, 0) > 0 THEN COALESCE(rp.repay_amt, 0) ELSE 0 END)
    / NULLIF(SUM(CASE WHEN b.has_beh = 0 AND b.is_remit = 1 AND b.due_date < CURRENT_DATE AND COALESCE(b.remit_amt, 0) > 0 THEN b.remit_amt ELSE 0 END), 0)
    - 1
  ), 2) AS 无行为盈利率
FROM tmp_base b
LEFT JOIN tmp_repay rp ON rp.serial_id = b.serial_id
WHERE b.bucket <> 'never'
GROUP BY b.bucket
ORDER BY CASE b.bucket WHEN '当日' THEN 1 WHEN '1-3日' THEN 2 WHEN '4-7日' THEN 3 ELSE 4 END;

-- 【块E3】表5.6：1月→6月当日提单流失去向
WITH jan AS (SELECT * FROM tmp_cross_month WHERE ym = DATE '2026-01-01'),
     jun AS (SELECT * FROM tmp_cross_month WHERE ym = DATE '2026-06-01'),
     pairs AS (
       SELECT '当日' AS 窗口, j.d0_apply_pct AS 一月, u.d0_apply_pct AS 六月, j.d0_apply_pct AS d0_jan, u.d0_apply_pct AS d0_jun FROM jan j CROSS JOIN jun u
       UNION ALL SELECT '1-3日', j.d1_3_pct, u.d1_3_pct, j.d0_apply_pct, u.d0_apply_pct FROM jan j CROSS JOIN jun u
       UNION ALL SELECT '4-7日', j.d4_7_pct, u.d4_7_pct, j.d0_apply_pct, u.d0_apply_pct FROM jan j CROSS JOIN jun u
       UNION ALL SELECT '7日以后', j.d8p_pct, u.d8p_pct, j.d0_apply_pct, u.d0_apply_pct FROM jan j CROSS JOIN jun u
       UNION ALL SELECT '未提单', j.never_pct, u.never_pct, j.d0_apply_pct, u.d0_apply_pct FROM jan j CROSS JOIN jun u
       UNION ALL SELECT '月度提单率', j.apply_rate_pct, u.apply_rate_pct, j.d0_apply_pct, u.d0_apply_pct FROM jan j CROSS JOIN jun u
     )
SELECT
  窗口, 一月, 六月, ROUND(六月 - 一月, 2) AS 变化pp,
  ROUND(CASE WHEN 窗口 = '当日' THEN NULL ELSE 100.0 * (六月 - 一月) / NULLIF(d0_jan - d0_jun, 0) END, 1) AS 占当日流失份额pct
FROM pairs;

-- 【块E4】分月交叉环比：息费升 vs 当日提单降 vs 逾期升 vs 盈利率
SELECT
  TO_CHAR(ym, 'YYYY-MM') AS ym,
  d0_apply_pct,
  ROUND(d0_apply_pct - LAG(d0_apply_pct) OVER (ORDER BY ym), 2) AS 当日提单率环比pp,
  d0_fee_pct,
  ROUND(d0_fee_pct - LAG(d0_fee_pct) OVER (ORDER BY ym), 2) AS 当日息费环比pp,
  d0_od_pct,
  ROUND(d0_od_pct - LAG(d0_od_pct) OVER (ORDER BY ym), 2) AS 当日逾期环比pp,
  d0_profit_pct,
  ROUND(d0_profit_pct - LAG(d0_profit_pct) OVER (ORDER BY ym), 2) AS 当日盈利率环比pp,
  beh_d0_apply_pct,
  ROUND(beh_d0_apply_pct - LAG(beh_d0_apply_pct) OVER (ORDER BY ym), 2) AS 有行为当日环比pp,
  never_pct,
  nobeh_never_pct
FROM tmp_cross_month
ORDER BY ym;

-- 【块E5】有/无行为 × 窗口：息费、逾期、盈利率
SELECT
  CASE WHEN b.has_beh = 1 THEN '有行为' ELSE '无行为' END AS 行为,
  b.bucket,
  COUNT(*) AS n,
  ROUND(100.0 * SUM(CASE WHEN b.is_remit = 1 AND COALESCE(b.remit_amt, 0) > 0 THEN COALESCE(b.pre_amt, 0) + COALESCE(b.post_amt, 0) ELSE 0 END)
              / NULLIF(SUM(CASE WHEN b.is_remit = 1 AND COALESCE(b.remit_amt, 0) > 0 THEN b.remit_amt ELSE 0 END), 0), 2) AS 息费,
  ROUND(100.0 * SUM(CASE WHEN b.is_remit = 1 AND b.due_date < CURRENT_DATE AND COALESCE(b.remit_amt, 0) > 0
                    AND (b.repaid_date IS NULL OR b.repaid_date <= DATE '2000-01-01' OR b.repaid_date > b.due_date) THEN 1 ELSE 0 END)
              / NULLIF(SUM(CASE WHEN b.is_remit = 1 AND b.due_date < CURRENT_DATE AND COALESCE(b.remit_amt, 0) > 0 THEN 1 ELSE 0 END), 0), 2) AS 逾期,
  ROUND(100.0 * (
    SUM(CASE WHEN b.is_remit = 1 AND b.due_date < CURRENT_DATE AND COALESCE(b.remit_amt, 0) > 0 THEN COALESCE(rp.repay_amt, 0) ELSE 0 END)
    / NULLIF(SUM(CASE WHEN b.is_remit = 1 AND b.due_date < CURRENT_DATE AND COALESCE(b.remit_amt, 0) > 0 THEN b.remit_amt ELSE 0 END), 0)
    - 1
  ), 2) AS 盈利率
FROM tmp_base b
LEFT JOIN tmp_repay rp ON rp.serial_id = b.serial_id
WHERE b.bucket <> 'never'
GROUP BY CASE WHEN b.has_beh = 1 THEN '有行为' ELSE '无行为' END, b.bucket
ORDER BY 1, CASE b.bucket WHEN '当日' THEN 1 WHEN '1-3日' THEN 2 WHEN '4-7日' THEN 3 ELSE 4 END;
