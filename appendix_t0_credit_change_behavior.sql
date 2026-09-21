-- =============================================================================
-- T0 7–8 月：额度变化 → 进提单页 → 页内行为 → 当天提单 / 额度使用率
-- 库：kaby_dw · 需 SELECT wangchuanliang.event_track_record
-- 区间：2026-07-01（含）～ 2026-09-01（不含），按周（周一为周起点）汇总
--
-- 思路
--   1) 升额 / 不变 / 降额：结清后当天进提单页占比，看额度变化会不会影响进页。
--   2) 只在进页用户里看改金额/期次、看合同/计划、选原因，以及这些行为下的当天提单率。
--   3) 额度使用率 = 当天提单订单 apply_amt / 本笔 max_credit_apply_amt，仅当天提过单的人。
--
-- 结果集
--   R1 漏斗合计
--   R2 全体（有上一笔额度）：进页率、全体提单率、进页后提单率、使用率
--   R3 进页用户：页内行为发生率、确认、提单、使用率
--   R4 进页用户中「有/无某行为」的提单率（行为对提单的影响）
--   R5 周 × 额度组：进页率、进页后提单率、使用率
--   R6 进页用户行为组合 TOP20 + 提单率 / 使用率
--   R7 进页用户：行为 × 额度组 的人数与提单率
-- =============================================================================

SET search_path TO wangchuanliang, public;
SET statement_timeout = 0;

DROP TABLE IF EXISTS tmp_m_origin;
CREATE TEMP TABLE tmp_m_origin AS
WITH params AS (
    SELECT DATE '2026-07-01' AS start_date, DATE '2026-09-01' AS end_date
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
 AND e.create_date >= DATE '2026-07-01'
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
 AND e.create_date >= DATE '2026-07-01'
 AND e.create_date <  DATE '2026-09-01'
 AND e.create_date = t.vir_date
 AND e.create_time >= t.repaid_time
 AND e.create_time < t.vir_date + 1
 AND e.props_id IN ('Loan_newconfirm','Loan_newconfirm_select')
GROUP BY t.user_id, t.vir_date;

DROP TABLE IF EXISTS tmp_enter;
CREATE TEMP TABLE tmp_enter AS
SELECT t.user_id, t.vir_date, 1 AS f_enter
FROM tmp_m_origin t
INNER JOIN wangchuanliang.event_track_record e
  ON e.user_id = t.user_id
 AND e.create_date >= DATE '2026-07-01'
 AND e.create_date <  DATE '2026-09-01'
 AND e.create_date = t.vir_date
 AND e.create_time >= t.repaid_time
 AND e.create_time < t.vir_date + 1
 AND e.event_type = 'page_view_in'
 AND e.props_id IN ('Loan_newpage','Loan_newpage_select')
GROUP BY t.user_id, t.vir_date;

DROP TABLE IF EXISTS tmp_apply;
CREATE TEMP TABLE tmp_apply AS
SELECT z.user_id, z.vir_date, 1 AS f_apply, z.apply_amt
FROM (
    SELECT t.user_id, t.vir_date, a.apply_amt,
           ROW_NUMBER() OVER (PARTITION BY t.user_id, t.vir_date ORDER BY a.apply_time, a.serial_id) AS rn
    FROM tmp_m_origin t
    INNER JOIN wangchuanliang.order_loan_f_v2_copy a
      ON a.user_id = t.user_id AND a.apply_time >= t.vir_time AND a.apply_date = t.vir_date
) z WHERE rn = 1;

DROP TABLE IF EXISTS tmp_base;
CREATE TEMP TABLE tmp_base AS
SELECT
    t.user_id,
    t.vir_date,
    TO_CHAR(DATE_TRUNC('week', t.vir_date), 'YYYY-MM-DD') AS wk,
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
    COALESCE(en.f_enter, 0) AS f_enter,
    COALESCE(b.f_amt, 0) AS f_amt,
    COALESCE(b.f_term, 0) AS f_term,
    COALESCE(b.f_contract, 0) AS f_contract,
    COALESCE(b.f_plan, 0) AS f_plan,
    COALESCE(b.f_purpose, 0) AS f_purpose,
    COALESCE(b.n_amt, 0) AS n_amt,
    COALESCE(b.n_term, 0) AS n_term,
    COALESCE(c.f_confirm, 0) AS f_confirm,
    COALESCE(a.f_apply, 0) AS f_apply,
    a.apply_amt,
    CASE WHEN COALESCE(a.f_apply, 0) = 1 AND t.this_amt > 0
         THEN a.apply_amt / t.this_amt END AS util
FROM tmp_m_origin t
LEFT JOIN tmp_prev_amt p ON p.user_id = t.user_id AND p.vir_date = t.vir_date
LEFT JOIN tmp_enter en ON en.user_id = t.user_id AND en.vir_date = t.vir_date
LEFT JOIN tmp_beh b ON b.user_id = t.user_id AND b.vir_date = t.vir_date
LEFT JOIN tmp_confirm c ON c.user_id = t.user_id AND c.vir_date = t.vir_date
LEFT JOIN tmp_apply a ON a.user_id = t.user_id AND a.vir_date = t.vir_date;

DROP TABLE IF EXISTS tmp_univ;
CREATE TEMP TABLE tmp_univ AS
SELECT * FROM tmp_base
WHERE this_amt IS NOT NULL AND prev_amt IS NOT NULL AND chg_grp IN ('升额','不变','降额');

DROP TABLE IF EXISTS tmp_ent;
CREATE TEMP TABLE tmp_ent AS
SELECT * FROM tmp_univ WHERE f_enter = 1;

-- R1 漏斗
SELECT
    (SELECT COUNT(*) FROM tmp_m_origin) AS n_t0,
    (SELECT COUNT(*) FROM tmp_univ) AS n_univ,
    (SELECT COUNT(*) FROM tmp_ent) AS n_enter,
    (SELECT COUNT(*) FROM tmp_univ WHERE f_apply = 1) AS n_apply,
    (SELECT COUNT(*) FROM tmp_ent WHERE f_apply = 1) AS n_enter_apply,
    ROUND(100.0 * (SELECT COUNT(*) FROM tmp_ent) / NULLIF((SELECT COUNT(*) FROM tmp_univ), 0), 2) AS pct_enter,
    ROUND(100.0 * (SELECT COUNT(*) FROM tmp_univ WHERE f_apply = 1) / NULLIF((SELECT COUNT(*) FROM tmp_univ), 0), 2) AS pct_apply,
    ROUND(100.0 * (SELECT COUNT(*) FROM tmp_ent WHERE f_apply = 1) / NULLIF((SELECT COUNT(*) FROM tmp_ent), 0), 2) AS pct_apply_enter,
    ROUND(100.0 * (SELECT AVG(util) FROM tmp_univ WHERE f_apply = 1), 2) AS avg_util_pct;

-- R2 全体：额度变化 → 进页
SELECT
    chg_grp,
    COUNT(*) AS n,
    ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM tmp_univ), 2) AS share_pct,
    SUM(f_enter) AS n_enter,
    ROUND(100.0 * AVG(f_enter), 2) AS pct_enter,
    SUM(f_apply) AS n_apply,
    ROUND(100.0 * AVG(f_apply), 2) AS pct_apply,
    SUM(CASE WHEN f_enter = 1 THEN f_apply ELSE 0 END) AS n_enter_apply,
    ROUND(100.0 * SUM(CASE WHEN f_enter = 1 THEN f_apply ELSE 0 END) / NULLIF(SUM(f_enter), 0), 2) AS pct_apply_enter,
    ROUND(AVG(this_amt), 0) AS avg_this,
    ROUND(AVG(prev_amt), 0) AS avg_prev,
    ROUND(100.0 * AVG(util), 2) AS avg_util_pct
FROM tmp_univ
GROUP BY chg_grp
ORDER BY CASE chg_grp WHEN '降额' THEN 1 WHEN '不变' THEN 2 WHEN '升额' THEN 3 END;

-- R3 进页用户：页内行为 + 提单 + 使用率
SELECT
    chg_grp,
    COUNT(*) AS n,
    ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM tmp_ent), 2) AS share_pct,
    ROUND(100.0 * AVG(f_amt), 2) AS pct_amt,
    ROUND(100.0 * AVG(f_term), 2) AS pct_term,
    ROUND(100.0 * AVG(f_contract), 2) AS pct_contract,
    ROUND(100.0 * AVG(f_plan), 2) AS pct_plan,
    ROUND(100.0 * AVG(f_purpose), 2) AS pct_purpose,
    ROUND(AVG(n_amt), 2) AS avg_n_amt,
    ROUND(AVG(n_term), 2) AS avg_n_term,
    ROUND(100.0 * AVG(f_confirm), 2) AS pct_confirm,
    ROUND(100.0 * AVG(f_apply), 2) AS pct_apply,
    ROUND(100.0 * AVG(util), 2) AS avg_util_pct
FROM tmp_ent
GROUP BY chg_grp
ORDER BY CASE chg_grp WHEN '降额' THEN 1 WHEN '不变' THEN 2 WHEN '升额' THEN 3 END;

-- R4 进页用户：有/无某行为的当天提单率
SELECT * FROM (
    SELECT 1 AS ord, '改金额' AS beh,
           SUM(f_amt) AS n_yes, ROUND(100.0 * AVG(f_amt), 2) AS pct_yes,
           ROUND(100.0 * SUM(CASE WHEN f_amt = 1 THEN f_apply ELSE 0 END) / NULLIF(SUM(f_amt), 0), 2) AS pct_apply_yes,
           ROUND(100.0 * SUM(CASE WHEN f_amt = 0 THEN f_apply ELSE 0 END) / NULLIF(SUM(1 - f_amt), 0), 2) AS pct_apply_no,
           ROUND(100.0 * AVG(CASE WHEN f_amt = 1 AND f_apply = 1 THEN util END), 2) AS util_yes
    FROM tmp_ent
    UNION ALL
    SELECT 2, '改期次', SUM(f_term), ROUND(100.0 * AVG(f_term), 2),
           ROUND(100.0 * SUM(CASE WHEN f_term = 1 THEN f_apply ELSE 0 END) / NULLIF(SUM(f_term), 0), 2),
           ROUND(100.0 * SUM(CASE WHEN f_term = 0 THEN f_apply ELSE 0 END) / NULLIF(SUM(1 - f_term), 0), 2),
           ROUND(100.0 * AVG(CASE WHEN f_term = 1 AND f_apply = 1 THEN util END), 2)
    FROM tmp_ent
    UNION ALL
    SELECT 3, '看合同', SUM(f_contract), ROUND(100.0 * AVG(f_contract), 2),
           ROUND(100.0 * SUM(CASE WHEN f_contract = 1 THEN f_apply ELSE 0 END) / NULLIF(SUM(f_contract), 0), 2),
           ROUND(100.0 * SUM(CASE WHEN f_contract = 0 THEN f_apply ELSE 0 END) / NULLIF(SUM(1 - f_contract), 0), 2),
           ROUND(100.0 * AVG(CASE WHEN f_contract = 1 AND f_apply = 1 THEN util END), 2)
    FROM tmp_ent
    UNION ALL
    SELECT 4, '看计划', SUM(f_plan), ROUND(100.0 * AVG(f_plan), 2),
           ROUND(100.0 * SUM(CASE WHEN f_plan = 1 THEN f_apply ELSE 0 END) / NULLIF(SUM(f_plan), 0), 2),
           ROUND(100.0 * SUM(CASE WHEN f_plan = 0 THEN f_apply ELSE 0 END) / NULLIF(SUM(1 - f_plan), 0), 2),
           ROUND(100.0 * AVG(CASE WHEN f_plan = 1 AND f_apply = 1 THEN util END), 2)
    FROM tmp_ent
    UNION ALL
    SELECT 5, '选原因', SUM(f_purpose), ROUND(100.0 * AVG(f_purpose), 2),
           ROUND(100.0 * SUM(CASE WHEN f_purpose = 1 THEN f_apply ELSE 0 END) / NULLIF(SUM(f_purpose), 0), 2),
           ROUND(100.0 * SUM(CASE WHEN f_purpose = 0 THEN f_apply ELSE 0 END) / NULLIF(SUM(1 - f_purpose), 0), 2),
           ROUND(100.0 * AVG(CASE WHEN f_purpose = 1 AND f_apply = 1 THEN util END), 2)
    FROM tmp_ent
    UNION ALL
    SELECT 6, '确认提单', SUM(f_confirm), ROUND(100.0 * AVG(f_confirm), 2),
           ROUND(100.0 * SUM(CASE WHEN f_confirm = 1 THEN f_apply ELSE 0 END) / NULLIF(SUM(f_confirm), 0), 2),
           ROUND(100.0 * SUM(CASE WHEN f_confirm = 0 THEN f_apply ELSE 0 END) / NULLIF(SUM(1 - f_confirm), 0), 2),
           ROUND(100.0 * AVG(CASE WHEN f_confirm = 1 AND f_apply = 1 THEN util END), 2)
    FROM tmp_ent
) x ORDER BY ord;

-- R5 周 × 额度组
SELECT
    wk,
    chg_grp,
    COUNT(*) AS n,
    SUM(f_enter) AS n_enter,
    ROUND(100.0 * AVG(f_enter), 2) AS pct_enter,
    ROUND(100.0 * SUM(CASE WHEN f_enter = 1 THEN f_apply ELSE 0 END) / NULLIF(SUM(f_enter), 0), 2) AS pct_apply_enter,
    ROUND(100.0 * AVG(f_apply), 2) AS pct_apply,
    ROUND(100.0 * AVG(util), 2) AS avg_util_pct
FROM tmp_univ
GROUP BY wk, chg_grp
ORDER BY wk, CASE chg_grp WHEN '降额' THEN 1 WHEN '不变' THEN 2 WHEN '升额' THEN 3 END;

-- R6 进页用户行为组合
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
    ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM tmp_ent), 2) AS share_pct,
    ROUND(100.0 * AVG(f_confirm), 2) AS pct_confirm,
    ROUND(100.0 * AVG(f_apply), 2) AS pct_apply,
    ROUND(100.0 * AVG(util), 2) AS avg_util_pct
FROM tmp_ent
GROUP BY f_amt, f_term, f_contract, f_plan, f_purpose
ORDER BY n DESC
LIMIT 20;

-- R7 进页用户：行为 × 额度组
SELECT
    chg_grp, beh, n_yes,
    ROUND(100.0 * n_yes / NULLIF(n_grp, 0), 2) AS pct_yes,
    ROUND(100.0 * n_apply_yes / NULLIF(n_yes, 0), 2) AS pct_apply_yes
FROM (
    SELECT chg_grp, COUNT(*) AS n_grp,
           SUM(f_amt) AS n_yes, SUM(CASE WHEN f_amt = 1 THEN f_apply ELSE 0 END) AS n_apply_yes,
           '改金额' AS beh FROM tmp_ent GROUP BY chg_grp
    UNION ALL
    SELECT chg_grp, COUNT(*), SUM(f_term), SUM(CASE WHEN f_term = 1 THEN f_apply ELSE 0 END), '改期次' FROM tmp_ent GROUP BY chg_grp
    UNION ALL
    SELECT chg_grp, COUNT(*), SUM(f_plan), SUM(CASE WHEN f_plan = 1 THEN f_apply ELSE 0 END), '看计划' FROM tmp_ent GROUP BY chg_grp
    UNION ALL
    SELECT chg_grp, COUNT(*), SUM(f_purpose), SUM(CASE WHEN f_purpose = 1 THEN f_apply ELSE 0 END), '选原因' FROM tmp_ent GROUP BY chg_grp
    UNION ALL
    SELECT chg_grp, COUNT(*), SUM(f_confirm), SUM(CASE WHEN f_confirm = 1 THEN f_apply ELSE 0 END), '确认提单' FROM tmp_ent GROUP BY chg_grp
) z
ORDER BY CASE chg_grp WHEN '降额' THEN 1 WHEN '不变' THEN 2 WHEN '升额' THEN 3 END,
         CASE beh WHEN '改金额' THEN 1 WHEN '改期次' THEN 2 WHEN '看计划' THEN 3 WHEN '选原因' THEN 4 ELSE 5 END;
