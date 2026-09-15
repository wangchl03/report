-- ================================================================
-- 结清 0 在贷 T0 动态资质模型：特征快照与训练标签
-- 评分对象：2026-01-01 至 2026-08-31 的 T0 获额通过用户。
-- 训练样本：2024-01-01 至 2025-12-31 的 T0 样本，且后续成功放款订单
--          已于 2026-06-30 前到期；标签为该订单到期时是否逾期。
-- 所有 feature 均严格限制在 vir_time（获额通过时点）之前。
-- ================================================================
WITH params AS (
    SELECT
        DATE '2025-01-01' AS feature_start_date,
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
ORDER BY b.vir_time, b.user_id, b.offer_serial_id;
