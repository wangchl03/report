-- =============================================================================
-- 三层动态资质 × 图1四指标（当日提单率 / 息费 / 逾期 / 盈利率）
-- 库：kaby_dw  GaussDB
-- 分层：2025 训练样本预测风险 P30=0.3563149222988503、P60=0.3711136188813171，锁阈值后套 2026 T0
-- 图1口径：自然日首次提单；息费=当日首次提单且已放款；逾期/盈利=已放款且 due_date < CURRENT_DATE
-- 执行：可与 appendix_t0_tier_fig1.py 二选一。Python 会写出月度 CSV/JSON。
-- =============================================================================
SET statement_timeout = 0;

SET statement_timeout = 0;
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
DROP TABLE IF EXISTS tmp_repay;
CREATE TEMP TABLE tmp_repay AS
SELECT f.serial_id, SUM(r.amount) AS repay_amt
FROM tmp_first f
INNER JOIN wangchuanliang.repayment_record_copy r ON r.serial_id = f.serial_id
WHERE f.is_remit = 1 AND f.due_date < CURRENT_DATE AND COALESCE(f.remit_amt, 0) > 0
  AND r.payin_date >= f.apply_date AND r.payin_date <= f.due_date
GROUP BY f.serial_id;

DROP TABLE IF EXISTS tmp_score;
CREATE TEMP TABLE tmp_score AS
WITH feature_data AS (
-- ================================================================
-- 结清 0 在贷 T0 动态资质模型：特征快照与训练标签
-- 评分对象：2026-01-01 至 2026-08-31 的 T0 获额通过用户。
-- 训练样本：2024-01-01 至 2025-12-31 的 T0 样本，且后续成功放款订单
--          已于 2026-06-30 前到期；标签为该订单到期时是否逾期。
-- 所有 feature 均严格限制在 vir_time（获额通过时点）之前。
-- ================================================================
WITH params AS (
    SELECT
        DATE '2026-01-01' AS feature_start_date,
        DATE '2026-09-01' AS feature_end_date,
        DATE '2026-01-01' AS score_start_date,
        DATE '2025-12-31' AS train_end_date,
        DATE '2026-06-30' AS label_due_cutoff,
        DATE '2026-09-10' AS analysis_as_of_date
),
raw_offer AS (
    SELECT DISTINCT ON (v.user_id, v.serial_id)
        v.user_id,
        v.serial_id,
        v.vir_date::date AS vir_date,
        TO_TIMESTAMP(v.vir_unix) AS vir_time,
        v.max_credit_apply_amt,
        r.recycle_type
    FROM wangchuanliang.order_vir_f_copy AS v
    INNER JOIN wangchuanliang.side_recycle_type_copy AS r
        ON r.serial_id = v.serial_id
    CROSS JOIN params AS p
    WHERE v.is_pass1 = 1
      AND v.loan_type_code = 2
      AND v.vir_date >= p.feature_start_date - 1
      AND v.vir_date < p.feature_end_date
    ORDER BY v.user_id, v.serial_id, v.vir_unix DESC
),
offer_batch AS (
    SELECT
        x.*,
        SUM(CASE
                WHEN x.prev_vir_time IS NULL
                  OR x.vir_time - x.prev_vir_time > INTERVAL '20 seconds'
                THEN 1 ELSE 0
            END) OVER (
                PARTITION BY x.user_id
                ORDER BY x.vir_time, x.serial_id
                ROWS UNBOUNDED PRECEDING
            ) AS batch_id
    FROM (
        SELECT
            r.*,
            LAG(r.vir_time) OVER (
                PARTITION BY r.user_id
                ORDER BY r.vir_time, r.serial_id
            ) AS prev_vir_time
        FROM raw_offer AS r
    ) AS x
),
dedup_offer AS (
    SELECT user_id, serial_id, vir_date, vir_time, max_credit_apply_amt
    FROM (
        SELECT
            b.*,
            ROW_NUMBER() OVER (
                PARTITION BY b.user_id, b.batch_id
                ORDER BY b.serial_id DESC
            ) AS batch_rn
        FROM offer_batch AS b
        CROSS JOIN params AS p
        WHERE b.recycle_type = 3
          AND b.vir_date >= p.feature_start_date
          AND b.vir_date < p.feature_end_date
    ) AS x
    WHERE batch_rn = 1
),
candidate_users AS (
    SELECT DISTINCT user_id FROM dedup_offer
),
all_orders AS (
    SELECT
        o.user_id, o.serial_id, o.apply_time, o.apply_date,
        o.remit_amt, o.pre_amt, o.post_amt,
        o.due_date, o.repaid_time, o.repaid_date,
        o.is_remit, o.is_repaid, o.overdue_days, o.loan_status_code
    FROM wangchuanliang.order_loan_f_v2_copy AS o
    INNER JOIN candidate_users AS u ON u.user_id = o.user_id
),
clean_settlement AS (
    SELECT o.user_id, o.serial_id, o.repaid_time, o.repaid_date
    FROM all_orders AS o
    WHERE o.is_remit = 1
      AND (o.is_repaid = 1 OR o.loan_status_code = 7)
      AND o.repaid_time > TIMESTAMP '2000-01-01 00:00:00'
      AND NOT EXISTS (
          SELECT 1
          FROM all_orders AS x
          WHERE x.user_id = o.user_id
            AND x.serial_id <> o.serial_id
            AND x.apply_time < o.repaid_time
            AND (
                  x.loan_status_code IN (5, 8)
               OR (x.loan_status_code = 7 AND x.repaid_time > o.repaid_time)
            )
      )
),
t0_pairs AS (
    SELECT
        e.user_id,
        e.serial_id AS offer_serial_id,
        e.vir_date,
        e.vir_time,
        e.max_credit_apply_amt,
        s.serial_id AS settlement_serial_id,
        s.repaid_time AS settlement_time,
        ROW_NUMBER() OVER (
            PARTITION BY e.user_id, e.serial_id, e.vir_time
            ORDER BY s.repaid_time DESC, s.serial_id DESC
        ) AS settlement_rn
    FROM dedup_offer AS e
    INNER JOIN clean_settlement AS s
        ON s.user_id = e.user_id
       AND s.repaid_date = e.vir_date
       AND e.vir_time >= s.repaid_time
),
t0_events AS (
    SELECT *
    FROM (
        SELECT
            p.*,
            ROW_NUMBER() OVER (
                PARTITION BY p.user_id, p.vir_date
                ORDER BY p.vir_time, p.offer_serial_id DESC
            ) AS day_rn
        FROM t0_pairs AS p
        WHERE p.settlement_rn = 1
    ) AS x
    WHERE day_rn = 1
),
historical_features AS (
    SELECT
        t.user_id,
        t.offer_serial_id,
        t.vir_time,
        COUNT(DISTINCT CASE WHEN h.is_remit = 1 THEN h.serial_id END) AS hist_remit_cnt,
        COUNT(DISTINCT CASE
            WHEN h.is_remit = 1
             AND h.repaid_date > DATE '2000-01-01'
            THEN h.serial_id
        END) AS hist_settled_cnt,
        COUNT(DISTINCT CASE
            WHEN h.is_remit = 1
             AND (
                   h.repaid_date <= DATE '2000-01-01'
                OR h.repaid_date > h.due_date
             )
            THEN h.serial_id
        END) AS hist_overdue_order_cnt,
        COALESCE(MAX(CASE WHEN h.is_remit = 1 THEN h.overdue_days END), 0) AS hist_max_overdue_days,
        COALESCE(AVG(CASE WHEN h.is_remit = 1 THEN h.remit_amt END), 0) AS hist_avg_remit_amt,
        COALESCE(SUM(CASE WHEN h.is_remit = 1 THEN h.remit_amt END), 0) AS hist_total_remit_amt,
        COALESCE(
            SUM(CASE WHEN h.is_remit = 1 THEN h.pre_amt + h.post_amt ELSE 0 END)
            / NULLIF(SUM(CASE WHEN h.is_remit = 1 THEN h.remit_amt ELSE 0 END), 0),
            0
        ) AS hist_weighted_interest_rate,
        MIN(CASE WHEN h.is_remit = 1 THEN h.apply_date END) AS first_hist_apply_date,
        MAX(CASE WHEN h.is_remit = 1 THEN h.repaid_date END) AS last_hist_repaid_date
    FROM t0_events AS t
    LEFT JOIN all_orders AS h
        ON h.user_id = t.user_id
       AND h.apply_time < t.vir_time
    GROUP BY t.user_id, t.offer_serial_id, t.vir_time
),
feature_base AS (
    SELECT
        t.user_id,
        t.offer_serial_id,
        t.vir_date,
        t.vir_time,
        t.max_credit_apply_amt,
        t.settlement_serial_id,
        t.settlement_time,
        f.hist_remit_cnt,
        f.hist_settled_cnt,
        f.hist_overdue_order_cnt,
        f.hist_max_overdue_days,
        f.hist_avg_remit_amt,
        f.hist_total_remit_amt,
        f.hist_weighted_interest_rate,
        (t.vir_date - f.first_hist_apply_date) AS user_loan_tenure_days,
        (t.vir_date - f.last_hist_repaid_date) AS days_since_last_repaid,
        CASE WHEN f.hist_remit_cnt > 0
             THEN f.hist_overdue_order_cnt::numeric / f.hist_remit_cnt
             ELSE 0 END AS hist_overdue_order_rate,
        CASE WHEN prior.repaid_date > DATE '2000-01-01'
                   AND prior.repaid_date <= prior.due_date
             THEN 0 ELSE 1 END AS previous_order_overdue_flag,
        COALESCE(prior.remit_amt, 0) AS previous_remit_amt,
        CASE WHEN prior.remit_amt > 0
             THEN (prior.pre_amt + prior.post_amt) / prior.remit_amt
             ELSE 0 END AS previous_interest_rate,
        target.is_remit AS next_order_is_remit,
        CASE
            WHEN target.apply_time >= t.vir_time
             AND target.apply_date = t.vir_date
            THEN 1 ELSE 0
        END AS is_t0_apply,
        target.due_date AS next_order_due_date,
        CASE
            WHEN target.is_remit = 1
             AND target.due_date <= p.label_due_cutoff
            THEN 1 ELSE 0
        END AS is_mature_label_sample,
        CASE
            WHEN target.is_remit = 1
             AND target.due_date <= p.label_due_cutoff
             AND (
                   target.repaid_date <= DATE '2000-01-01'
                OR target.repaid_date > target.due_date
             )
            THEN 1
            WHEN target.is_remit = 1
             AND target.due_date <= p.label_due_cutoff
            THEN 0
            ELSE NULL
        END AS next_order_overdue_label,
        -- 报告中的实际订单逾期率：只统计 T0 当日真实提单且成功放款、
        -- 并在统计截止日已到期的整笔订单。
        CASE
            WHEN target.is_remit = 1
             AND target.apply_time >= t.vir_time
             AND target.apply_date = t.vir_date
             AND target.due_date <= p.analysis_as_of_date
            THEN 1 ELSE 0
        END AS is_actual_t0_mature_order,
        CASE
            WHEN target.is_remit = 1
             AND target.apply_time >= t.vir_time
             AND target.apply_date = t.vir_date
             AND target.due_date <= p.analysis_as_of_date
             AND (
                    target.repaid_date IS NULL
                 OR target.repaid_date <= DATE '2000-01-01'
                 OR target.repaid_date > target.due_date
             )
            THEN 1
            WHEN target.is_remit = 1
             AND target.apply_time >= t.vir_time
             AND target.apply_date = t.vir_date
             AND target.due_date <= p.analysis_as_of_date
            THEN 0
            ELSE NULL
        END AS actual_t0_order_overdue_label
    FROM t0_events AS t
    INNER JOIN historical_features AS f
        ON f.user_id = t.user_id
       AND f.offer_serial_id = t.offer_serial_id
       AND f.vir_time = t.vir_time
    LEFT JOIN all_orders AS prior
        ON prior.user_id = t.user_id
       AND prior.serial_id = t.settlement_serial_id
    LEFT JOIN all_orders AS target
        ON target.user_id = t.user_id
       AND target.serial_id = t.offer_serial_id
    CROSS JOIN params AS p
)
SELECT
    b.*,
    CASE WHEN b.vir_date BETWEEN p.feature_start_date AND p.train_end_date
         THEN 1 ELSE 0 END AS is_train_period,
    CASE WHEN b.vir_date >= p.score_start_date
          AND b.vir_date < p.feature_end_date
         THEN 1 ELSE 0 END AS is_score_period
FROM feature_base AS b
CROSS JOIN params AS p
)
SELECT
    user_id,
    vir_date,
    1.0 / (1.0 + EXP(-(
  -0.5652802238981256
  + (0.0182714389842564 * ((COALESCE(max_credit_apply_amt, 2000.0) - 3708.813462885154) / 4435.428746809324))
  + (-0.0356718241001912 * ((COALESCE(hist_remit_cnt, 2.0) - 3.0983018207282913) / 4.477071675286755))
  + (-0.0356718241001912 * ((COALESCE(hist_settled_cnt, 2.0) - 3.0983018207282913) / 4.477071675286755))
  + (0.010166844650504 * ((COALESCE(hist_overdue_order_cnt, 0.0) - 0.1287640056022408) / 0.4008468962367186))
  + (-0.0010884378745081 * ((COALESCE(hist_max_overdue_days, 0.0) - -1.3855042016806722) / 3.2734854877909365))
  + (-0.0897233469271387 * ((COALESCE(hist_avg_remit_amt, 1000.0) - 1642.5042745050282) / 1835.077924028703))
  + (-0.0648771907524624 * ((COALESCE(hist_total_remit_amt, 1800.0) - 8366.807598039215) / 23495.151922501816))
  + (0.0235588554139508 * ((COALESCE(hist_weighted_interest_rate, 0.4151226038513839) - 0.3830001672326967) / 0.1357819678071449))
  + (-0.0836188087025032 * ((COALESCE(user_loan_tenure_days, 22.0) - 53.39189425770308) / 95.45111751130464))
  + (-0.0240646425788879 * ((COALESCE(days_since_last_repaid, 0.0) - 2.0390406162464987) / 14.127627627627538))
  + (0.0162338489661254 * ((COALESCE(hist_overdue_order_rate, 0.0) - 0.0358033506570425) / 0.1354266535459552))
  + (0.0780277043361126 * ((COALESCE(previous_order_overdue_flag, 0.0) - 0.0340511204481792) / 0.181360529455565))
  + (0.1458843338381181 * ((COALESCE(previous_remit_amt, 1100.0) - 2249.5487570028013) / 2893.8625669892053))
  + (0.043155211445057 * ((COALESCE(previous_interest_rate, 0.4542857142857142) - 0.4200950330686726) / 0.1152955399117681))
))) AS predicted_overdue_risk
FROM feature_data
WHERE is_score_period = 1;

-- 分月 × 三层 图1四指标
SELECT
  TO_CHAR(f.vir_date, 'YYYY-MM') AS ym,
  CASE
    WHEN s.predicted_overdue_risk <= 0.3563149222988503 THEN '资质最好（P0-P30）'
    WHEN s.predicted_overdue_risk <= 0.3711136188813171 THEN '资质一般（P30-P60）'
    ELSE '资质较差（P60-P100）'
  END AS tier,
  COUNT(*) AS t0,
  ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY TO_CHAR(f.vir_date, 'YYYY-MM')), 2) AS share_pct,
  SUM(CASE WHEN f.bucket = '当日' THEN 1 ELSE 0 END) AS n_d0,
  ROUND(100.0 * SUM(CASE WHEN f.bucket = '当日' THEN 1 ELSE 0 END) / COUNT(*), 2) AS d0_apply_pct,
  SUM(CASE WHEN f.bucket = '当日' AND f.is_remit = 1 AND COALESCE(f.remit_amt,0) > 0 THEN 1 ELSE 0 END) AS n_remit_d0,
  ROUND(100.0 * SUM(CASE WHEN f.bucket = '当日' AND f.is_remit = 1 AND COALESCE(f.remit_amt,0) > 0 THEN COALESCE(f.pre_amt,0)+COALESCE(f.post_amt,0) ELSE 0 END)
              / NULLIF(SUM(CASE WHEN f.bucket = '当日' AND f.is_remit = 1 AND COALESCE(f.remit_amt,0) > 0 THEN f.remit_amt ELSE 0 END), 0), 2) AS d0_fee_pct,
  SUM(CASE WHEN f.bucket = '当日' AND f.is_remit = 1 AND f.due_date < CURRENT_DATE AND COALESCE(f.remit_amt,0) > 0 THEN 1 ELSE 0 END) AS n_due_d0,
  ROUND(100.0 * SUM(CASE WHEN f.bucket = '当日' AND f.is_remit = 1 AND f.due_date < CURRENT_DATE AND COALESCE(f.remit_amt,0) > 0
        AND (f.repaid_date IS NULL OR f.repaid_date <= DATE '2000-01-01' OR f.repaid_date > f.due_date) THEN 1 ELSE 0 END)
              / NULLIF(SUM(CASE WHEN f.bucket = '当日' AND f.is_remit = 1 AND f.due_date < CURRENT_DATE AND COALESCE(f.remit_amt,0) > 0 THEN 1 ELSE 0 END), 0), 2) AS d0_od_pct,
  ROUND(100.0 * (
    SUM(CASE WHEN f.bucket = '当日' AND f.is_remit = 1 AND f.due_date < CURRENT_DATE AND COALESCE(f.remit_amt,0) > 0 THEN COALESCE(rp.repay_amt,0) ELSE 0 END)
    / NULLIF(SUM(CASE WHEN f.bucket = '当日' AND f.is_remit = 1 AND f.due_date < CURRENT_DATE AND COALESCE(f.remit_amt,0) > 0 THEN f.remit_amt ELSE 0 END), 0)
    - 1
  ), 2) AS d0_profit_pct
FROM tmp_first f
INNER JOIN tmp_score s ON s.user_id = f.user_id AND s.vir_date = f.vir_date
LEFT JOIN tmp_repay rp ON rp.serial_id = f.serial_id
GROUP BY 1, 2
ORDER BY 2, 1;
