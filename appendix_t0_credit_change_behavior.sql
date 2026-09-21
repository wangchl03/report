-- =============================================================================
-- T0 当天结清获额 × 结清后当天页内行为 × 额度相对最晚放款笔变化
-- 库：kaby_dw · 账号需 SELECT wangchuanliang.event_track_record
-- 区间：2026-01-01（含）～ 2026-09-01（不含）即 1–8 月
-- 本脚本一次跑完，6 个结果集对应报告全部数字（卡片 / 结论 / 图1–图8 / 三张表）
--
-- 结果集对照
--   R1 漏斗          → 顶部 4 张卡片、结论 1
--   R2 升额/不变/降额 → 图1–图4、主表、结论 2–4（含样本内占比 share_pct）
--   R3 幅度五档      → 图5、幅度表、结论 5
--   R4 月度          → 图6 人数、图7 当天提单率、结论 6
--   R5 行为组合 TOP20 → 图8、组合表（报告表取前 12 行）
--   R6 组合×额度组    → 备用交叉（报告未单独制表，数字可复现）
--
-- 口径
--   T0：is_pass1=1 AND loan_type_code=2 AND recycle_type=3；20 秒获额批次去重；
--       结清日=获额日；vir_time>=repaid_time；结清时 0 在贷；用户×日最早一轮获额。
--   页内行为：wangchuanliang.event_track_record。必须带 create_date 分区。
--            create_date = 获额日 = 结清日；
--            create_time >= 刚结清 repaid_time（结清之后，含结清到获额之间）；
--            create_time < 获额日+1（当天内）。
--            不含确认提单、不含仅进页（Loan_newpage）。
--   上一笔放款：vir_time 之前 is_remit=1 且 remit_amt>0，remit_time 最晚一笔
--              （不必是刚结清那笔）；额度 = max_credit_apply_amt。
--   当天提单：apply_time>=vir_time 且 apply_date=vir_date，不卡放款。
--   分析样本：T0 ∩ 能对上上一笔获额额度 ∩ 结清后当天至少一类页内行为。
-- =============================================================================

SET search_path TO wangchuanliang, public;
SET statement_timeout = 0;

DROP TABLE IF EXISTS tmp_m_origin;
CREATE TEMP TABLE tmp_m_origin AS
WITH params AS (
    SELECT DATE '2026-01-01' AS start_date, DATE '2026-09-01' AS end_date
), raw_offer AS (
    SELECT DISTINCT ON (v.user_id, v.serial_id)
        v.user_id, v.serial_id, v.vir_date::date AS vir_date,
        TO_TIMESTAMP(v.vir_unix) AS vir_time, v.max_credit_apply_amt
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
    SELECT user_id, serial_id, vir_date, vir_time, max_credit_apply_amt
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
    SELECT e.user_id, e.serial_id AS credit_serial_id, e.vir_date, e.vir_time, e.max_credit_apply_amt,
           s.repaid_time,
           ROW_NUMBER() OVER (
               PARTITION BY e.user_id, e.vir_date, e.serial_id
               ORDER BY s.repaid_time DESC, s.serial_id DESC
           ) AS s_rn
    FROM dedup_offer e
    INNER JOIN clean_settlement s
        ON s.user_id = e.user_id AND s.repaid_date = e.vir_date AND e.vir_time >= s.repaid_time
), day_pick AS (
    SELECT p.*, ROW_NUMBER() OVER (PARTITION BY p.user_id, p.vir_date ORDER BY p.vir_time ASC, p.credit_serial_id DESC) AS day_rn
    FROM paired p
    WHERE s_rn = 1
)
SELECT user_id, credit_serial_id, vir_date, vir_time, repaid_time, max_credit_apply_amt AS this_amt
FROM day_pick WHERE day_rn = 1;

DROP TABLE IF EXISTS tmp_prev;
CREATE TEMP TABLE tmp_prev AS
SELECT user_id, vir_date, prev_serial, prev_remit_time
FROM (
    SELECT t.user_id, t.vir_date, o.serial_id AS prev_serial, o.remit_time AS prev_remit_time,
           ROW_NUMBER() OVER (PARTITION BY t.user_id, t.vir_date ORDER BY o.remit_time DESC, o.serial_id DESC) AS rn
    FROM tmp_m_origin t
    INNER JOIN wangchuanliang.order_loan_f_v2_copy o
      ON o.user_id = t.user_id
     AND o.is_remit = 1 AND COALESCE(o.remit_amt, 0) > 0
     AND o.remit_time IS NOT NULL
     AND o.remit_time < t.vir_time
) z WHERE rn = 1;

DROP TABLE IF EXISTS tmp_prev_amt;
CREATE TEMP TABLE tmp_prev_amt AS
SELECT p.user_id, p.vir_date, p.prev_serial, p.prev_remit_time, v.max_credit_apply_amt AS prev_amt
FROM tmp_prev p
LEFT JOIN (
    SELECT DISTINCT ON (serial_id) serial_id, max_credit_apply_amt
    FROM wangchuanliang.order_vir_f_copy
    ORDER BY serial_id, vir_unix DESC
) v ON v.serial_id = p.prev_serial;

DROP TABLE IF EXISTS tmp_beh;
CREATE TEMP TABLE tmp_beh AS
SELECT
    t.user_id, t.vir_date,
    MAX(CASE WHEN e.props_id IN (
        'amount_modification','loan_form_loan_amount_selectionn_new','loan_form_loan_amount_selectionn_new_select'
    ) THEN 1 ELSE 0 END) AS f_amt,
    MAX(CASE WHEN e.props_id IN (
        'loan_form_term_selection_new','loan_form_term_selection_new_select'
    ) THEN 1 ELSE 0 END) AS f_term,
    MAX(CASE WHEN e.props_id IN (
        'Loan_contract_newdetails','Loan_contract_newdetails_select'
    ) THEN 1 ELSE 0 END) AS f_contract,
    MAX(CASE WHEN e.props_id IN (
        'Loan_plan_newdetails','Loan_plan_newdetails_select'
    ) THEN 1 ELSE 0 END) AS f_plan,
    MAX(CASE WHEN e.props_id IN (
        'Loan_purpose_newdetails','Loan_purpose_newdetails_select'
    ) THEN 1 ELSE 0 END) AS f_purpose,
    SUM(CASE WHEN e.props_id IN (
        'amount_modification','loan_form_loan_amount_selectionn_new','loan_form_loan_amount_selectionn_new_select'
    ) THEN 1 ELSE 0 END) AS n_amt,
    SUM(CASE WHEN e.props_id IN (
        'loan_form_term_selection_new','loan_form_term_selection_new_select'
    ) THEN 1 ELSE 0 END) AS n_term,
    SUM(CASE WHEN e.props_id IN (
        'Loan_contract_newdetails','Loan_contract_newdetails_select'
    ) THEN 1 ELSE 0 END) AS n_contract,
    SUM(CASE WHEN e.props_id IN (
        'Loan_plan_newdetails','Loan_plan_newdetails_select'
    ) THEN 1 ELSE 0 END) AS n_plan,
    SUM(CASE WHEN e.props_id IN (
        'Loan_purpose_newdetails','Loan_purpose_newdetails_select'
    ) THEN 1 ELSE 0 END) AS n_purpose
FROM tmp_m_origin t
INNER JOIN wangchuanliang.event_track_record e
  ON e.user_id = t.user_id
 AND e.create_date >= DATE '2026-01-01'
 AND e.create_date <  DATE '2026-09-01'
 AND e.create_date = t.vir_date
 AND e.create_time >= t.repaid_time
 AND e.create_time < t.vir_date + 1
 AND e.props_id IN (
   'amount_modification','loan_form_loan_amount_selectionn_new','loan_form_loan_amount_selectionn_new_select',
   'loan_form_term_selection_new','loan_form_term_selection_new_select',
   'Loan_contract_newdetails','Loan_contract_newdetails_select',
   'Loan_plan_newdetails','Loan_plan_newdetails_select',
   'Loan_purpose_newdetails','Loan_purpose_newdetails_select'
 )
GROUP BY t.user_id, t.vir_date;

DROP TABLE IF EXISTS tmp_confirm;
CREATE TEMP TABLE tmp_confirm AS
SELECT t.user_id, t.vir_date, 1 AS f_confirm
FROM tmp_m_origin t
INNER JOIN wangchuanliang.event_track_record e
  ON e.user_id = t.user_id
 AND e.create_date >= DATE '2026-01-01'
 AND e.create_date <  DATE '2026-09-01'
 AND e.create_date = t.vir_date
 AND e.create_time >= t.repaid_time
 AND e.create_time < t.vir_date + 1
 AND e.props_id IN ('Loan_newconfirm','Loan_newconfirm_select')
GROUP BY t.user_id, t.vir_date;

DROP TABLE IF EXISTS tmp_apply;
CREATE TEMP TABLE tmp_apply AS
SELECT t.user_id, t.vir_date, 1 AS f_apply
FROM tmp_m_origin t
INNER JOIN (
    SELECT z.user_id, z.vir_date
    FROM (
        SELECT t.user_id, t.vir_date,
               ROW_NUMBER() OVER (PARTITION BY t.user_id, t.vir_date ORDER BY a.apply_time, a.serial_id) AS rn
        FROM tmp_m_origin t
        INNER JOIN wangchuanliang.order_loan_f_v2_copy a
          ON a.user_id = t.user_id AND a.apply_time >= t.vir_time AND a.apply_date = t.vir_date
    ) z WHERE rn = 1
) s ON s.user_id = t.user_id AND s.vir_date = t.vir_date;

DROP TABLE IF EXISTS tmp_base;
CREATE TEMP TABLE tmp_base AS
SELECT
    t.user_id,
    t.vir_date,
    TO_CHAR(DATE_TRUNC('month', t.vir_date), 'YYYY-MM') AS ym,
    t.this_amt,
    p.prev_amt,
    (t.this_amt - p.prev_amt) AS amt_diff,
    CASE WHEN p.prev_amt IS NULL OR p.prev_amt = 0 THEN NULL
         ELSE ROUND(100.0 * (t.this_amt - p.prev_amt) / p.prev_amt, 2) END AS amt_pct,
    CASE
        WHEN t.this_amt IS NULL OR p.prev_amt IS NULL THEN '未知'
        WHEN t.this_amt > p.prev_amt THEN '升额'
        WHEN t.this_amt < p.prev_amt THEN '降额'
        ELSE '不变'
    END AS chg_grp,
    CASE
        WHEN t.this_amt IS NULL OR p.prev_amt IS NULL OR p.prev_amt = 0 THEN '未知'
        WHEN t.this_amt < p.prev_amt AND (p.prev_amt - t.this_amt) / p.prev_amt >= 0.20 THEN '降额≥20%'
        WHEN t.this_amt < p.prev_amt THEN '降额<20%'
        WHEN t.this_amt = p.prev_amt THEN '不变'
        WHEN (t.this_amt - p.prev_amt) / p.prev_amt >= 0.20 THEN '升额≥20%'
        ELSE '升额<20%'
    END AS chg_bin,
    COALESCE(b.f_amt, 0) AS f_amt,
    COALESCE(b.f_term, 0) AS f_term,
    COALESCE(b.f_contract, 0) AS f_contract,
    COALESCE(b.f_plan, 0) AS f_plan,
    COALESCE(b.f_purpose, 0) AS f_purpose,
    COALESCE(b.n_amt, 0) AS n_amt,
    COALESCE(b.n_term, 0) AS n_term,
    COALESCE(b.n_contract, 0) AS n_contract,
    COALESCE(b.n_plan, 0) AS n_plan,
    COALESCE(b.n_purpose, 0) AS n_purpose,
    COALESCE(c.f_confirm, 0) AS f_confirm,
    COALESCE(a.f_apply, 0) AS f_apply
FROM tmp_m_origin t
LEFT JOIN tmp_prev_amt p ON p.user_id = t.user_id AND p.vir_date = t.vir_date
LEFT JOIN tmp_beh b ON b.user_id = t.user_id AND b.vir_date = t.vir_date
LEFT JOIN tmp_confirm c ON c.user_id = t.user_id AND c.vir_date = t.vir_date
LEFT JOIN tmp_apply a ON a.user_id = t.user_id AND a.vir_date = t.vir_date;

DROP TABLE IF EXISTS tmp_sample;
CREATE TEMP TABLE tmp_sample AS
SELECT *
FROM tmp_base
WHERE this_amt IS NOT NULL AND prev_amt IS NOT NULL
  AND (f_amt + f_term + f_contract + f_plan + f_purpose) >= 1;

-- ---------------------------------------------------------------------------
-- R1 漏斗：顶部卡片 + 结论1
-- ---------------------------------------------------------------------------
SELECT
    t0.n_t0,
    pv.n_with_prev,
    bh.n_with_beh,
    sm.n_sample,
    ROUND(100.0 * sm.n_sample / NULLIF(t0.n_t0, 0), 2) AS sample_of_t0_pct,
    ROUND(100.0 * bh.n_with_beh / NULLIF(t0.n_t0, 0), 2) AS beh_of_t0_pct
FROM (SELECT COUNT(*) AS n_t0 FROM tmp_m_origin) t0
CROSS JOIN (SELECT COUNT(*) AS n_with_prev FROM tmp_base WHERE prev_amt IS NOT NULL AND this_amt IS NOT NULL) pv
CROSS JOIN (SELECT COUNT(*) AS n_with_beh FROM tmp_base WHERE (f_amt + f_term + f_contract + f_plan + f_purpose) >= 1) bh
CROSS JOIN (SELECT COUNT(*) AS n_sample FROM tmp_sample) sm;

-- ---------------------------------------------------------------------------
-- R2 图1–图4 + 主表 + 结论2–4（share_pct = 分析样本内人数占比）
-- ---------------------------------------------------------------------------
SELECT
    chg_grp,
    COUNT(*) AS n,
    ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM tmp_sample), 2) AS share_pct,
    ROUND(AVG(this_amt), 0) AS avg_this,
    ROUND(AVG(prev_amt), 0) AS avg_prev,
    ROUND(AVG(amt_diff), 0) AS avg_diff,
    ROUND(AVG(amt_pct), 2) AS avg_pct,
    ROUND(100.0 * AVG(f_amt), 2) AS pct_amt,
    ROUND(100.0 * AVG(f_term), 2) AS pct_term,
    ROUND(100.0 * AVG(f_contract), 2) AS pct_contract,
    ROUND(100.0 * AVG(f_plan), 2) AS pct_plan,
    ROUND(100.0 * AVG(f_purpose), 2) AS pct_purpose,
    ROUND(AVG(n_amt), 2) AS avg_n_amt,
    ROUND(AVG(n_term), 2) AS avg_n_term,
    ROUND(AVG(n_contract), 2) AS avg_n_contract,
    ROUND(AVG(n_plan), 2) AS avg_n_plan,
    ROUND(AVG(n_purpose), 2) AS avg_n_purpose,
    ROUND(100.0 * AVG(f_confirm), 2) AS pct_confirm,
    ROUND(100.0 * AVG(f_apply), 2) AS pct_apply
FROM tmp_sample
GROUP BY chg_grp
ORDER BY CASE chg_grp WHEN '降额' THEN 1 WHEN '不变' THEN 2 WHEN '升额' THEN 3 ELSE 4 END;

-- ---------------------------------------------------------------------------
-- R3 图5 + 幅度表 + 结论5
-- ---------------------------------------------------------------------------
SELECT
    chg_bin,
    COUNT(*) AS n,
    ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM tmp_sample), 2) AS share_pct,
    ROUND(100.0 * AVG(f_amt), 2) AS pct_amt,
    ROUND(100.0 * AVG(f_term), 2) AS pct_term,
    ROUND(100.0 * AVG(f_contract), 2) AS pct_contract,
    ROUND(100.0 * AVG(f_plan), 2) AS pct_plan,
    ROUND(100.0 * AVG(f_purpose), 2) AS pct_purpose,
    ROUND(100.0 * AVG(f_confirm), 2) AS pct_confirm,
    ROUND(100.0 * AVG(f_apply), 2) AS pct_apply
FROM tmp_sample
GROUP BY chg_bin
ORDER BY CASE chg_bin
    WHEN '降额≥20%' THEN 1 WHEN '降额<20%' THEN 2 WHEN '不变' THEN 3
    WHEN '升额<20%' THEN 4 WHEN '升额≥20%' THEN 5 ELSE 6 END;

-- ---------------------------------------------------------------------------
-- R4 图6 各月人数、图7 各月当天提单率 + 结论6
-- ---------------------------------------------------------------------------
SELECT
    ym,
    chg_grp,
    COUNT(*) AS n,
    ROUND(100.0 * AVG(f_apply), 2) AS pct_apply,
    ROUND(100.0 * AVG(f_confirm), 2) AS pct_confirm,
    ROUND(100.0 * AVG(f_amt), 2) AS pct_amt,
    ROUND(100.0 * AVG(f_term), 2) AS pct_term,
    ROUND(100.0 * AVG(f_plan), 2) AS pct_plan
FROM tmp_sample
GROUP BY ym, chg_grp
ORDER BY ym, CASE chg_grp WHEN '降额' THEN 1 WHEN '不变' THEN 2 WHEN '升额' THEN 3 ELSE 4 END;

-- ---------------------------------------------------------------------------
-- R5 图8 + 组合表（combo_name 与报告表一致，取人数最多的 20 组）
-- ---------------------------------------------------------------------------
SELECT
    TRIM(BOTH '+' FROM
        (CASE WHEN f_amt = 1 THEN '金额+' ELSE '' END) ||
        (CASE WHEN f_term = 1 THEN '期次+' ELSE '' END) ||
        (CASE WHEN f_contract = 1 THEN '合同+' ELSE '' END) ||
        (CASE WHEN f_plan = 1 THEN '计划+' ELSE '' END) ||
        (CASE WHEN f_purpose = 1 THEN '原因+' ELSE '' END)
    ) AS combo_name,
    f_amt, f_term, f_contract, f_plan, f_purpose,
    COUNT(*) AS n,
    ROUND(100.0 * AVG(f_confirm), 2) AS pct_confirm,
    ROUND(100.0 * AVG(f_apply), 2) AS pct_apply
FROM tmp_sample
GROUP BY f_amt, f_term, f_contract, f_plan, f_purpose
ORDER BY n DESC
LIMIT 20;

-- ---------------------------------------------------------------------------
-- R6 组合 × 额度组（交叉人数，报告未单独制表）
-- ---------------------------------------------------------------------------
SELECT
    chg_grp,
    TRIM(BOTH '+' FROM
        (CASE WHEN f_amt = 1 THEN '金额+' ELSE '' END) ||
        (CASE WHEN f_term = 1 THEN '期次+' ELSE '' END) ||
        (CASE WHEN f_contract = 1 THEN '合同+' ELSE '' END) ||
        (CASE WHEN f_plan = 1 THEN '计划+' ELSE '' END) ||
        (CASE WHEN f_purpose = 1 THEN '原因+' ELSE '' END)
    ) AS combo_name,
    f_amt, f_term, f_contract, f_plan, f_purpose,
    COUNT(*) AS n
FROM tmp_sample
GROUP BY chg_grp, f_amt, f_term, f_contract, f_plan, f_purpose
ORDER BY chg_grp, n DESC;
