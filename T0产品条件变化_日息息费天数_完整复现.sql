/*
===============================================================================
T0产品条件变化：日息、息费、天数的月度事件数与当天提单率

统计时间：2026-01-01 至 2026-09-27（含首尾两日）
统计单位：用户 × 严格T0获额通过事件
运行方式：在同一个 DataGrip 控制台中整段执行。

输出：
  1. 月度总览；
  2. 日息/息费/天数变化的长表明细，可透视为Excel的三个工作表；
  3. 月度产品匹配与有效样本质量表；
  4. 未匹配产品编号清单。
===============================================================================
*/

SET search_path TO wangchuanliang, public;
SET statement_timeout = 0;
SET query_dop = 1;


/* ============================================================================
   一、建立严格T0事件母表
   ============================================================================ */

DROP TABLE IF EXISTS tmp_t0_product_condition_event;

CREATE TEMP TABLE tmp_t0_product_condition_event AS
WITH
params AS
(
    SELECT
        DATE '2026-01-01' AS start_date,
        DATE '2026-09-28' AS end_date
),

/* 获额通过原始记录；多版本订单先保留最新记录 */
raw_offer AS
(
    SELECT DISTINCT ON (v.user_id, v.serial_id)
        v.user_id,
        v.serial_id AS credit_serial_id,
        v.vir_date::date AS vir_date,
        TO_TIMESTAMP(v.vir_unix) AS vir_time,
        v.max_credit_apply_amt::numeric AS current_credit_amt
    FROM wangchuanliang.order_vir_f_copy v
    JOIN wangchuanliang.side_recycle_type_copy r
      ON r.serial_id = v.serial_id
    CROSS JOIN params p
    WHERE v.is_pass1 = 1
      AND v.loan_type_code = 2
      AND r.recycle_type = 3
      /* 多取前一天，用于正确识别统计期首日的20秒批次边界 */
      AND v.vir_date >= p.start_date - 1
      AND v.vir_date <  p.end_date
    ORDER BY v.user_id, v.serial_id, v.vir_unix DESC
),

lagged_offer AS
(
    SELECT
        r.*,
        LAG(r.vir_time) OVER
        (
            PARTITION BY r.user_id
            ORDER BY r.vir_time, r.credit_serial_id
        ) AS prev_vir_time
    FROM raw_offer r
),

/* 相邻获额时间差不超过20秒，视为同一个获额批次 */
batched_offer AS
(
    SELECT
        l.*,
        SUM
        (
            CASE
                WHEN l.prev_vir_time IS NULL
                  OR l.vir_time - l.prev_vir_time > INTERVAL '20 seconds'
                THEN 1 ELSE 0
            END
        ) OVER
        (
            PARTITION BY l.user_id
            ORDER BY l.vir_time, l.credit_serial_id
            ROWS UNBOUNDED PRECEDING
        ) AS batch_id
    FROM lagged_offer l
),

/* 批次内按获额时间倒序、订单编号倒序取第一笔 */
dedup_offer AS
(
    SELECT
        user_id,
        credit_serial_id,
        vir_date,
        vir_time,
        current_credit_amt,
        batch_id
    FROM
    (
        SELECT
            b.*,
            ROW_NUMBER() OVER
            (
                PARTITION BY b.user_id, b.batch_id
                ORDER BY b.vir_time DESC, b.credit_serial_id DESC
            ) AS batch_rn
        FROM batched_offer b
    ) x
    CROSS JOIN params p
    WHERE x.batch_rn = 1
      AND x.vir_date >= p.start_date
      AND x.vir_date <  p.end_date
),

candidate_users AS
(
    SELECT DISTINCT user_id
    FROM dedup_offer
),

all_orders AS
(
    SELECT
        o.user_id,
        o.serial_id,
        o.apply_time,
        o.apply_date,
        o.remit_time,
        o.remit_amt,
        o.is_remit,
        o.repaid_time,
        o.repaid_date::date AS repaid_date,
        o.is_repaid,
        o.loan_status_code
    FROM wangchuanliang.order_loan_f_v2_copy o
    JOIN candidate_users u
      ON u.user_id = o.user_id
),

/* 找到结清后确实成为0在贷的放款订单 */
clean_settlement AS
(
    SELECT
        o.user_id,
        o.serial_id AS settled_serial_id,
        o.remit_amt::numeric AS settled_remit_amt,
        o.repaid_time,
        o.repaid_date
    FROM all_orders o
    WHERE o.is_remit = 1
      AND COALESCE(o.remit_amt, 0) > 0
      AND (o.is_repaid = 1 OR o.loan_status_code = 7)
      AND o.repaid_time > TIMESTAMP '2000-01-01 00:00:00'
      AND NOT EXISTS
      (
          SELECT 1
          FROM all_orders x
          WHERE x.user_id = o.user_id
            AND x.serial_id <> o.serial_id
            AND x.apply_time < o.repaid_time
            AND
            (
                x.loan_status_code IN (5, 8)
                OR (x.loan_status_code = 7 AND x.repaid_time > o.repaid_time)
            )
      )
),

/* 获额必须发生在同日结清之后；多笔候选时取最近结清的一笔 */
offer_settlement_pair AS
(
    SELECT
        e.user_id,
        e.credit_serial_id,
        e.vir_date,
        e.vir_time,
        e.current_credit_amt,
        e.batch_id,
        s.settled_serial_id,
        s.settled_remit_amt,
        s.repaid_time,
        ROW_NUMBER() OVER
        (
            PARTITION BY e.user_id, e.credit_serial_id, e.vir_time
            ORDER BY s.repaid_time DESC, s.settled_serial_id DESC
        ) AS settlement_rn
    FROM dedup_offer e
    JOIN clean_settlement s
      ON s.user_id = e.user_id
     AND s.repaid_date = e.vir_date
     AND e.vir_time >= s.repaid_time
),

strict_t0 AS
(
    SELECT
        user_id,
        credit_serial_id,
        vir_date,
        vir_time,
        current_credit_amt,
        batch_id,
        settled_serial_id,
        settled_remit_amt,
        repaid_time
    FROM offer_settlement_pair
    WHERE settlement_rn = 1
),

/* 上一笔结清订单对应的获额额度；用于保持严格T0母表与原分析一致 */
previous_credit_ranked AS
(
    SELECT
        s.user_id,
        s.credit_serial_id,
        s.vir_time,
        s.settled_serial_id,
        v.max_credit_apply_amt::numeric AS previous_credit_amt,
        ROW_NUMBER() OVER
        (
            PARTITION BY s.user_id, s.credit_serial_id, s.vir_time
            ORDER BY v.vir_unix DESC, v.serial_id DESC
        ) AS rn
    FROM strict_t0 s
    JOIN wangchuanliang.order_vir_f_copy v
      ON v.serial_id = s.settled_serial_id
     AND v.is_pass1 = 1
),

previous_credit AS
(
    SELECT
        user_id,
        credit_serial_id,
        vir_time,
        settled_serial_id,
        previous_credit_amt
    FROM previous_credit_ranked
    WHERE rn = 1
),

event_base AS
(
    SELECT
        s.user_id,
        s.credit_serial_id,
        s.vir_date,
        s.vir_time,
        s.repaid_time,
        s.settled_serial_id,
        s.settled_remit_amt,
        p.previous_credit_amt,
        s.current_credit_amt
    FROM strict_t0 s
    JOIN previous_credit p
      ON p.user_id = s.user_id
     AND p.credit_serial_id = s.credit_serial_id
     AND p.vir_time = s.vir_time
     AND p.settled_serial_id = s.settled_serial_id
    WHERE s.current_credit_amt > 0
      AND p.previous_credit_amt > 0
      AND s.settled_remit_amt > 0
),

/* 同一提单订单只归属提单前最近一次T0事件 */
candidate_same_day_orders AS
(
    SELECT
        e.user_id,
        e.credit_serial_id,
        e.vir_time,
        o.serial_id AS apply_serial_id,
        o.apply_time,
        ROW_NUMBER() OVER
        (
            PARTITION BY o.serial_id
            ORDER BY e.vir_time DESC, e.credit_serial_id DESC
        ) AS event_match_rn
    FROM event_base e
    JOIN all_orders o
      ON o.user_id = e.user_id
     AND o.apply_time >= e.vir_time
     AND o.apply_time <  e.vir_date + 1
),

assigned_same_day_orders AS
(
    SELECT *
    FROM candidate_same_day_orders
    WHERE event_match_rn = 1
),

/* 每个T0事件只保留最早一笔当天提单 */
first_same_day_apply AS
(
    SELECT
        user_id,
        credit_serial_id,
        vir_time,
        apply_serial_id,
        apply_time
    FROM
    (
        SELECT
            a.*,
            ROW_NUMBER() OVER
            (
                PARTITION BY a.user_id, a.credit_serial_id, a.vir_time
                ORDER BY a.apply_time, a.apply_serial_id
            ) AS rn
        FROM assigned_same_day_orders a
    ) x
    WHERE rn = 1
)
SELECT
    DATE_TRUNC('month', e.vir_date)::date AS t0_month,
    e.user_id,
    e.credit_serial_id,
    e.vir_date,
    e.vir_time,
    e.repaid_time,
    e.settled_serial_id,
    e.previous_credit_amt,
    e.current_credit_amt,
    CASE WHEN a.apply_serial_id IS NULL THEN 0 ELSE 1 END AS has_d0_apply,
    a.apply_serial_id,
    a.apply_time AS d0_apply_time
FROM event_base e
LEFT JOIN first_same_day_apply a
  ON a.user_id = e.user_id
 AND a.credit_serial_id = e.credit_serial_id
 AND a.vir_time = e.vir_time;

ANALYZE tmp_t0_product_condition_event;


/* ============================================================================
   二、关联本次产品与上一笔结清放款订单
   ============================================================================ */

DROP TABLE IF EXISTS tmp_t0_product_condition_base;

CREATE TEMP TABLE tmp_t0_product_condition_base AS
WITH
current_offer AS
(
    SELECT
        user_id,
        credit_serial_id,
        vir_time,
        risk_product
    FROM
    (
        SELECT
            t.user_id,
            t.credit_serial_id,
            t.vir_time,
            v.risk_product,
            ROW_NUMBER() OVER
            (
                PARTITION BY t.user_id, t.credit_serial_id, t.vir_time
                ORDER BY v.vir_unix DESC, v.serial_id DESC
            ) AS rn
        FROM tmp_t0_product_condition_event t
        LEFT JOIN wangchuanliang.order_vir_f_copy v
          ON v.user_id = t.user_id
         AND v.serial_id = t.credit_serial_id
         AND v.is_pass1 = 1
    ) x
    WHERE rn = 1
),

/* risk_product按英文逗号拆分；同一事件的重复产品编号只保留一次 */
product_tokens AS
(
    SELECT DISTINCT
        c.user_id,
        c.credit_serial_id,
        c.vir_time,
        BTRIM
        (
            REGEXP_SPLIT_TO_TABLE(COALESCE(c.risk_product, ''), ',')
        ) AS product_no
    FROM current_offer c
    WHERE BTRIM(COALESCE(c.risk_product, '')) <> ''
),

/* 三个当前产品指标独立选择，不要求来自同一产品 */
current_product_metrics AS
(
    SELECT
        p.user_id,
        p.credit_serial_id,
        p.vir_time,
        COUNT(*)::bigint AS listed_product_n,
        SUM(CASE WHEN i.product_no IS NOT NULL THEN 1 ELSE 0 END)::bigint
            AS matched_product_n,
        MIN(i.daily_interest)::numeric AS current_daily_rate,
        MIN(i.interest_fees)::numeric AS current_fee_rate,
        MAX(i.loan_day)::numeric AS current_loan_day
    FROM product_tokens p
    LEFT JOIN wangchuanliang.product_info i
      ON i.product_no = p.product_no
    GROUP BY p.user_id, p.credit_serial_id, p.vir_time
)
SELECT
    t.t0_month,
    t.user_id,
    t.credit_serial_id,
    t.vir_date,
    t.vir_time,
    t.settled_serial_id,
    t.has_d0_apply,
    c.risk_product,
    COALESCE(m.listed_product_n, 0)::bigint AS listed_product_n,
    COALESCE(m.matched_product_n, 0)::bigint AS matched_product_n,
    m.current_daily_rate,
    m.current_fee_rate,
    m.current_loan_day,
    o.remit_amt::numeric AS previous_remit_amt,
    o.pre_amt::numeric AS previous_pre_amt,
    o.post_amt::numeric AS previous_post_amt,
    o.loan_day::numeric AS previous_loan_day,
    CASE
        WHEN o.remit_amt > 0
         AND o.pre_amt IS NOT NULL
         AND o.post_amt IS NOT NULL
        THEN (o.pre_amt::numeric + o.post_amt::numeric) / o.remit_amt::numeric
    END AS previous_fee_rate,
    CASE
        WHEN o.remit_amt > 0
         AND o.pre_amt IS NOT NULL
         AND o.post_amt IS NOT NULL
         AND o.loan_day > 0
        THEN
            ((o.pre_amt::numeric + o.post_amt::numeric) / o.remit_amt::numeric)
            / o.loan_day::numeric
    END AS previous_daily_rate
FROM tmp_t0_product_condition_event t
LEFT JOIN current_offer c
  ON c.user_id = t.user_id
 AND c.credit_serial_id = t.credit_serial_id
 AND c.vir_time = t.vir_time
LEFT JOIN current_product_metrics m
  ON m.user_id = t.user_id
 AND m.credit_serial_id = t.credit_serial_id
 AND m.vir_time = t.vir_time
LEFT JOIN wangchuanliang.order_loan_f_v2_copy o
  ON o.user_id = t.user_id
 AND o.serial_id = t.settled_serial_id;

ANALYZE tmp_t0_product_condition_base;


/* ============================================================================
   三、建立日息/息费/天数变化的统一分类明细
   ============================================================================ */

DROP TABLE IF EXISTS tmp_t0_product_condition_classified;

CREATE TEMP TABLE tmp_t0_product_condition_classified AS
WITH
eligible AS
(
    SELECT
        t0_month,
        user_id,
        credit_serial_id,
        vir_time,
        has_d0_apply,
        '日息变化'::text AS metric,
        current_daily_rate - previous_daily_rate AS change_value,
        current_daily_rate AS current_value,
        CASE
            WHEN current_daily_rate - previous_daily_rate >= 0.0005 THEN '日息增加'
            WHEN current_daily_rate - previous_daily_rate <= -0.0005 THEN '日息减少'
            ELSE '日息不变'
        END AS change_type
    FROM tmp_t0_product_condition_base
    WHERE listed_product_n > 0
      AND listed_product_n = matched_product_n
      AND current_daily_rate IS NOT NULL
      AND previous_daily_rate IS NOT NULL

    UNION ALL

    SELECT
        t0_month,
        user_id,
        credit_serial_id,
        vir_time,
        has_d0_apply,
        '息费变化'::text,
        current_fee_rate - previous_fee_rate,
        current_fee_rate,
        CASE
            WHEN current_fee_rate - previous_fee_rate >= 0.01 THEN '息费增加'
            WHEN current_fee_rate - previous_fee_rate <= -0.01 THEN '息费减少'
            ELSE '息费不变'
        END
    FROM tmp_t0_product_condition_base
    WHERE listed_product_n > 0
      AND listed_product_n = matched_product_n
      AND current_fee_rate IS NOT NULL
      AND previous_fee_rate IS NOT NULL

    UNION ALL

    SELECT
        t0_month,
        user_id,
        credit_serial_id,
        vir_time,
        has_d0_apply,
        '天数变化'::text,
        current_loan_day - previous_loan_day,
        current_loan_day,
        CASE
            WHEN current_loan_day > previous_loan_day THEN '天数增加'
            WHEN current_loan_day < previous_loan_day THEN '天数减少'
            ELSE '天数不变'
        END
    FROM tmp_t0_product_condition_base
    WHERE listed_product_n > 0
      AND listed_product_n = matched_product_n
      AND current_loan_day IS NOT NULL
      AND previous_loan_day IS NOT NULL
)
SELECT
    e.*,
    CASE
        WHEN metric = '日息变化' AND change_type IN ('日息增加', '日息减少') THEN
            CASE
                WHEN ABS(change_value) < 0.002 THEN '0.2个百分点以下'
                WHEN ABS(change_value) < 0.004 THEN '0.2-0.4个百分点'
                WHEN ABS(change_value) < 0.005 THEN '0.4-0.5个百分点'
                WHEN ABS(change_value) < 0.006 THEN '0.5-0.6个百分点'
                WHEN ABS(change_value) < 0.010 THEN '0.6-1个百分点'
                ELSE '1个百分点及以上'
            END
        WHEN metric = '日息变化' AND change_type = '日息不变' THEN
            CASE
                WHEN current_value < 0.020 THEN '2%以下'
                WHEN current_value < 0.025 THEN '2%-2.5%'
                WHEN current_value < 0.030 THEN '2.5%-3%'
                WHEN current_value < 0.035 THEN '3%-3.5%'
                WHEN current_value < 0.040 THEN '3.5%-4%'
                ELSE '4%及以上'
            END
        WHEN metric = '息费变化' AND change_type IN ('息费增加', '息费减少') THEN
            CASE
                WHEN ABS(change_value) < 0.05 THEN '5个百分点以下'
                WHEN ABS(change_value) < 0.10 THEN '5-10个百分点'
                WHEN ABS(change_value) < 0.15 THEN '10-15个百分点'
                WHEN ABS(change_value) < 0.20 THEN '15-20个百分点'
                WHEN ABS(change_value) < 0.25 THEN '20-25个百分点'
                WHEN ABS(change_value) < 0.30 THEN '25-30个百分点'
                ELSE '30个百分点及以上'
            END
        WHEN metric = '息费变化' AND change_type = '息费不变' THEN
            CASE
                WHEN current_value < 0.30 THEN '30%以下'
                WHEN current_value < 0.40 THEN '30%-40%'
                WHEN current_value < 0.50 THEN '40%-50%'
                WHEN current_value < 0.60 THEN '50%-60%'
                WHEN current_value < 0.70 THEN '60%-70%'
                ELSE '70%及以上'
            END
        WHEN metric = '天数变化' AND change_type IN ('天数增加', '天数减少') THEN
            CASE
                WHEN ABS(change_value) = 7 THEN '7天'
                WHEN ABS(change_value) = 14 THEN '14天'
                WHEN ABS(change_value) = 21 THEN '21天'
                WHEN ABS(change_value) = 28 THEN '28天'
                WHEN ABS(change_value) > 28 THEN '28天以上'
                ELSE '其他天数'
            END
        WHEN metric = '天数变化' AND change_type = '天数不变' THEN
            CASE
                WHEN current_value = 7 THEN '7天'
                WHEN current_value = 14 THEN '14天'
                WHEN current_value = 21 THEN '21天'
                WHEN current_value = 28 THEN '28天'
                WHEN current_value > 28 THEN '28天以上'
                ELSE '其他天数'
            END
    END AS bucket
FROM eligible e;

ANALYZE tmp_t0_product_condition_classified;


/* ============================================================================
   四、结果集1：月度总览
   ============================================================================ */

SELECT
    TO_CHAR(t0_month, 'YYYY-MM') AS t0_month,
    COUNT(*)::bigint AS t0_event_n,
    SUM(has_d0_apply)::bigint AS d0_apply_n,
    SUM(has_d0_apply)::numeric / NULLIF(COUNT(*), 0) AS d0_apply_rate,
    SUM(CASE WHEN listed_product_n = 1 THEN 1 ELSE 0 END)::bigint AS one_product_n,
    SUM(CASE WHEN listed_product_n = 2 THEN 1 ELSE 0 END)::bigint AS two_product_n,
    SUM(CASE WHEN listed_product_n >= 3 THEN 1 ELSE 0 END)::bigint AS three_plus_product_n,
    SUM(CASE WHEN listed_product_n > 0 AND matched_product_n = listed_product_n
             THEN 1 ELSE 0 END)::numeric / NULLIF(COUNT(*), 0) AS all_product_match_rate,
    SUM(CASE WHEN listed_product_n > 0 AND matched_product_n = listed_product_n
              AND current_daily_rate IS NOT NULL AND previous_daily_rate IS NOT NULL
             THEN 1 ELSE 0 END)::bigint AS eligible_daily_n,
    SUM(CASE WHEN listed_product_n > 0 AND matched_product_n = listed_product_n
              AND current_fee_rate IS NOT NULL AND previous_fee_rate IS NOT NULL
             THEN 1 ELSE 0 END)::bigint AS eligible_fee_n,
    SUM(CASE WHEN listed_product_n > 0 AND matched_product_n = listed_product_n
              AND current_loan_day IS NOT NULL AND previous_loan_day IS NOT NULL
             THEN 1 ELSE 0 END)::bigint AS eligible_days_n
FROM tmp_t0_product_condition_base
GROUP BY t0_month
ORDER BY t0_month;


/* ============================================================================
   五、结果集2：三项指标的月度事件数与当天提单率（长表）
   将月份放到列，即可复现Excel的“日息变化/息费变化/天数变化”三个表。
   ============================================================================ */

WITH
result_rows AS
(
    SELECT
        metric,
        t0_month,
        '汇总'::text AS row_group,
        '汇总'::text AS bucket,
        0 AS row_level,
        0 AS group_order,
        0 AS bucket_order,
        COUNT(*)::bigint AS event_n,
        SUM(has_d0_apply)::bigint AS apply_n
    FROM tmp_t0_product_condition_classified
    GROUP BY metric, t0_month

    UNION ALL

    SELECT
        metric,
        t0_month,
        change_type || '总计',
        '总计'::text,
        1,
        CASE
            WHEN change_type IN ('日息增加', '息费增加', '天数增加') THEN 10
            WHEN change_type IN ('日息减少', '息费减少', '天数减少') THEN 20
            ELSE 30
        END,
        0,
        COUNT(*)::bigint,
        SUM(has_d0_apply)::bigint
    FROM tmp_t0_product_condition_classified
    GROUP BY metric, t0_month, change_type

    UNION ALL

    SELECT
        metric,
        t0_month,
        change_type,
        bucket,
        2,
        CASE
            WHEN change_type IN ('日息增加', '息费增加', '天数增加') THEN 10
            WHEN change_type IN ('日息减少', '息费减少', '天数减少') THEN 20
            ELSE 30
        END,
        CASE
            WHEN change_type IN ('日息增加', '日息减少') THEN
                CASE bucket
                    WHEN '0.2个百分点以下' THEN 1
                    WHEN '0.2-0.4个百分点' THEN 2
                    WHEN '0.4-0.5个百分点' THEN 3
                    WHEN '0.5-0.6个百分点' THEN 4
                    WHEN '0.6-1个百分点' THEN 5
                    ELSE 6
                END
            WHEN change_type = '日息不变' THEN
                CASE bucket
                    WHEN '2%以下' THEN 1
                    WHEN '2%-2.5%' THEN 2
                    WHEN '2.5%-3%' THEN 3
                    WHEN '3%-3.5%' THEN 4
                    WHEN '3.5%-4%' THEN 5
                    ELSE 6
                END
            WHEN change_type IN ('息费增加', '息费减少') THEN
                CASE bucket
                    WHEN '5个百分点以下' THEN 1
                    WHEN '5-10个百分点' THEN 2
                    WHEN '10-15个百分点' THEN 3
                    WHEN '15-20个百分点' THEN 4
                    WHEN '20-25个百分点' THEN 5
                    WHEN '25-30个百分点' THEN 6
                    ELSE 7
                END
            WHEN change_type = '息费不变' THEN
                CASE bucket
                    WHEN '30%以下' THEN 1
                    WHEN '30%-40%' THEN 2
                    WHEN '40%-50%' THEN 3
                    WHEN '50%-60%' THEN 4
                    WHEN '60%-70%' THEN 5
                    ELSE 6
                END
            ELSE
                CASE bucket
                    WHEN '7天' THEN 1
                    WHEN '14天' THEN 2
                    WHEN '21天' THEN 3
                    WHEN '28天' THEN 4
                    WHEN '28天以上' THEN 5
                    ELSE 6
                END
        END,
        COUNT(*)::bigint,
        SUM(has_d0_apply)::bigint
    FROM tmp_t0_product_condition_classified
    GROUP BY metric, t0_month, change_type, bucket
)
SELECT
    metric,
    TO_CHAR(t0_month, 'YYYY-MM') AS t0_month,
    row_group,
    bucket,
    row_level,
    group_order,
    bucket_order,
    event_n,
    apply_n,
    apply_n::numeric / NULLIF(event_n, 0) AS d0_apply_rate
FROM result_rows
ORDER BY metric, group_order, row_level, bucket_order, t0_month;


/* ============================================================================
   六、结果集3：月度数据质量
   ============================================================================ */

SELECT
    TO_CHAR(t0_month, 'YYYY-MM') AS t0_month,
    COUNT(*)::bigint AS strict_t0_event_n,
    SUM(CASE WHEN risk_product IS NULL OR BTRIM(risk_product) = '' THEN 1 ELSE 0 END)::bigint
        AS missing_risk_product_n,
    SUM(CASE WHEN listed_product_n = 1 THEN 1 ELSE 0 END)::bigint AS one_product_n,
    SUM(CASE WHEN listed_product_n = 2 THEN 1 ELSE 0 END)::bigint AS two_product_n,
    SUM(CASE WHEN listed_product_n >= 3 THEN 1 ELSE 0 END)::bigint AS three_plus_product_n,
    SUM(CASE WHEN listed_product_n > 0 AND matched_product_n = listed_product_n
             THEN 1 ELSE 0 END)::bigint AS all_products_matched_n,
    SUM(CASE WHEN listed_product_n > 0 AND matched_product_n < listed_product_n
             THEN 1 ELSE 0 END)::bigint AS incomplete_product_match_n,
    SUM(CASE WHEN listed_product_n > 0 AND matched_product_n = listed_product_n
              AND current_daily_rate IS NOT NULL AND previous_daily_rate IS NOT NULL
             THEN 1 ELSE 0 END)::bigint AS eligible_daily_n,
    SUM(CASE WHEN listed_product_n > 0 AND matched_product_n = listed_product_n
              AND current_fee_rate IS NOT NULL AND previous_fee_rate IS NOT NULL
             THEN 1 ELSE 0 END)::bigint AS eligible_fee_n,
    SUM(CASE WHEN listed_product_n > 0 AND matched_product_n = listed_product_n
              AND current_loan_day IS NOT NULL AND previous_loan_day IS NOT NULL
             THEN 1 ELSE 0 END)::bigint AS eligible_days_n,
    SUM(has_d0_apply)::bigint AS d0_apply_n,
    SUM(has_d0_apply)::numeric / NULLIF(COUNT(*), 0) AS overall_d0_apply_rate
FROM tmp_t0_product_condition_base
GROUP BY t0_month
ORDER BY t0_month;


/* ============================================================================
   七、结果集4：未匹配产品编号
   正常情况下返回0行。
   ============================================================================ */

WITH
current_offer AS
(
    SELECT user_id, credit_serial_id, vir_time, risk_product
    FROM
    (
        SELECT
            t.user_id,
            t.credit_serial_id,
            t.vir_time,
            v.risk_product,
            ROW_NUMBER() OVER
            (
                PARTITION BY t.user_id, t.credit_serial_id, t.vir_time
                ORDER BY v.vir_unix DESC, v.serial_id DESC
            ) AS rn
        FROM tmp_t0_product_condition_event t
        LEFT JOIN wangchuanliang.order_vir_f_copy v
          ON v.user_id = t.user_id
         AND v.serial_id = t.credit_serial_id
         AND v.is_pass1 = 1
    ) x
    WHERE rn = 1
),
tokens AS
(
    SELECT DISTINCT
        c.user_id,
        c.credit_serial_id,
        c.vir_time,
        BTRIM(REGEXP_SPLIT_TO_TABLE(COALESCE(c.risk_product, ''), ',')) AS product_no
    FROM current_offer c
    WHERE BTRIM(COALESCE(c.risk_product, '')) <> ''
)
SELECT
    p.product_no,
    COUNT(*)::bigint AS event_n
FROM tokens p
LEFT JOIN wangchuanliang.product_info i
  ON i.product_no = p.product_no
WHERE i.product_no IS NULL
GROUP BY p.product_no
ORDER BY event_n DESC, p.product_no;

RESET query_dop;

