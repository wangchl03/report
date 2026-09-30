/*
======================================================================
  首贷月份 × 渠道 × 累计观察窗口 Tableau 报表

  数据日期：CURRENT_DATE - 1
  观察窗口：30/60/90/.../360 天，均为自首贷申请日起的累计窗口
  成熟规则：
    1. 首贷申请月份的月末 + window_day <= data_date；
    2. 当前月与上个月不展示生命周期指标；
    3. 首贷人数、首贷放款金额、首贷件均、CPS 不受成熟规则限制。

  使用方法：
    A. 首次部署：执行“第一部分 + 第二部分”；
    B. 每日刷新：只执行“第二部分”；
    C. Tableau 只连接正式表 wangchuanliang.rpt_firstloan_channel_lifecycle。

  说明：dws.rpt_adjust_cost.cost_amt 已经是美元，不做汇率换算。
======================================================================
*/


/* ==================================================================
   第一部分：首次部署建表
   ================================================================== */

DROP TABLE IF EXISTS wangchuanliang.rpt_firstloan_channel_lifecycle_stg;
DROP TABLE IF EXISTS wangchuanliang.rpt_firstloan_channel_lifecycle;

CREATE TABLE wangchuanliang.rpt_firstloan_channel_lifecycle
(
    data_date                         date           NOT NULL,
    run_date                          date           NOT NULL,
    apply_month                       date           NOT NULL,
    channel_catgy                     varchar(100)   NOT NULL,
    window_day                        integer        NOT NULL,
    is_mature                         integer        NOT NULL,
    is_base_row                       integer        NOT NULL,

    /* 基础指标：仅 window_day=30 的记录参与 Tableau 汇总 */
    first_loan_order_count             bigint,
    first_loan_user_count              bigint,
    first_loan_amt_usd                 numeric(30, 6),
    marketing_cost_usd                 numeric(30, 6),

    /* 生命周期累计窗口的可加总原子指标 */
    repay_amt_usd                      numeric(30, 6),
    remit_amt_usd                      numeric(30, 6),
    profit_amt_usd                     numeric(30, 6),
    remit_reloan_amt_usd               numeric(30, 6),
    due_whole_order_count              bigint,
    overdue_whole_order_count          bigint,
    due_whole_order_remit_amt_usd      numeric(30, 6),
    overdue_term_remit_amt_usd         numeric(30, 6),
    whole_order_loan_days_sum          numeric(30, 6),
    whole_order_interest_amt_usd       numeric(30, 6),

    refresh_time                       timestamp      NOT NULL
)
WITH
(
    orientation = row
)
DISTRIBUTE BY REPLICATION;


CREATE TABLE wangchuanliang.rpt_firstloan_channel_lifecycle_stg
(
    data_date                         date           NOT NULL,
    run_date                          date           NOT NULL,
    apply_month                       date           NOT NULL,
    channel_catgy                     varchar(100)   NOT NULL,
    window_day                        integer        NOT NULL,
    is_mature                         integer        NOT NULL,
    is_base_row                       integer        NOT NULL,

    first_loan_order_count             bigint,
    first_loan_user_count              bigint,
    first_loan_amt_usd                 numeric(30, 6),
    marketing_cost_usd                 numeric(30, 6),

    repay_amt_usd                      numeric(30, 6),
    remit_amt_usd                      numeric(30, 6),
    profit_amt_usd                     numeric(30, 6),
    remit_reloan_amt_usd               numeric(30, 6),
    due_whole_order_count              bigint,
    overdue_whole_order_count          bigint,
    due_whole_order_remit_amt_usd      numeric(30, 6),
    overdue_term_remit_amt_usd         numeric(30, 6),
    whole_order_loan_days_sum          numeric(30, 6),
    whole_order_interest_amt_usd       numeric(30, 6),

    refresh_time                       timestamp      NOT NULL
)
WITH
(
    orientation = row
)
DISTRIBUTE BY REPLICATION;


/* ==================================================================
   第二部分：每日刷新
   ================================================================== */

SET query_dop = 1;

TRUNCATE TABLE wangchuanliang.rpt_firstloan_channel_lifecycle_stg;

INSERT INTO wangchuanliang.rpt_firstloan_channel_lifecycle_stg
(
    data_date,
    run_date,
    apply_month,
    channel_catgy,
    window_day,
    is_mature,
    is_base_row,
    first_loan_order_count,
    first_loan_user_count,
    first_loan_amt_usd,
    marketing_cost_usd,
    repay_amt_usd,
    remit_amt_usd,
    profit_amt_usd,
    remit_reloan_amt_usd,
    due_whole_order_count,
    overdue_whole_order_count,
    due_whole_order_remit_amt_usd,
    overdue_term_remit_amt_usd,
    whole_order_loan_days_sum,
    whole_order_interest_amt_usd,
    refresh_time
)
WITH
params AS
(
    SELECT
        CURRENT_DATE::date       AS run_date,
        (CURRENT_DATE - 1)::date AS data_date,
        DATE '2025-07-01'        AS cohort_start_date
),

window_days AS
(
    SELECT 30 AS window_day
    UNION ALL SELECT 60
    UNION ALL SELECT 90
    UNION ALL SELECT 120
    UNION ALL SELECT 150
    UNION ALL SELECT 180
    UNION ALL SELECT 210
    UNION ALL SELECT 240
    UNION ALL SELECT 270
    UNION ALL SELECT 300
    UNION ALL SELECT 330
    UNION ALL SELECT 360
),

/* 汇率：订单金额按业务发生日换算为美元；市场成本本身已是美元 */
fx_rates AS
(
    SELECT
        snap_date::date AS snap_date,
        MAX(local2usd)::numeric(30, 12) AS local2usd
    FROM wangchuanliang.exchange_rate_copy
    WHERE country = 'MXN'
    GROUP BY snap_date::date
),

/* 去除可能重复的订单风险标签 */
risk_orders AS
(
    SELECT DISTINCT b.serial_id
    FROM wangchuanliang.order_risk_label_copy b
    CROSS JOIN params p
    WHERE b.apply_date >= p.cohort_start_date
      AND b.apply_date <= p.data_date
),

/* 用户渠道；如注册表一人多行，保留一条确定结果 */
user_channel_raw AS
(
    SELECT
        u.user_id,
        CASE
            WHEN u.network_name = 'Facebook' AND u.campaign_name LIKE '%VO%' THEN 'FB-VO'
            WHEN u.network_name = 'Facebook' AND u.campaign_name LIKE '%register%' THEN 'FB-register'
            WHEN u.network_name = 'Facebook' THEN 'FB 2.5'
            WHEN u.network_name = 'Google' AND u.campaign_name LIKE '%Kaby-new-3.0%' THEN 'GG-kaby3.0'
            WHEN u.network_name = 'Google' AND u.campaign_name LIKE '%kaby-4-3.0%' THEN 'GG-kaby3.0_new'
            WHEN u.network_name = 'Google' AND u.campaign_name LIKE '%register%' THEN 'GG-register'
            WHEN u.network_name = 'Google' THEN 'GG-kaby2.5'
            WHEN u.network_name IN ('tiktok', 'TikTok SAN') AND u.campaign_name LIKE '%ROAS%' THEN 'TT-3.0'
            WHEN u.network_name IN ('tiktok', 'TikTok SAN') THEN 'TT'
            ELSE 'OTHERS'
        END AS channel_catgy,
        ROW_NUMBER() OVER
        (
            PARTITION BY u.user_id
            ORDER BY u.user_id
        ) AS rn
    FROM wangchuanliang.user_reg_i_copy u
),

user_channel AS
(
    SELECT user_id, channel_catgy
    FROM user_channel_raw
    WHERE rn = 1
),

/* 首贷成功放款 cohort */
base_orders AS
(
    SELECT
        o.serial_id,
        o.user_id,
        COALESCE(o.apply_time, o.apply_date::timestamp) AS apply_time,
        o.apply_date::date AS apply_date,
        DATE_TRUNC('month', o.apply_date)::date AS apply_month,
        COALESCE(uc.channel_catgy, '未知渠道') AS channel_catgy,
        COALESCE(o.remit_amt, 0)::numeric(30, 6) AS remit_amt_local,
        COALESCE(o.remit_amt, 0)::numeric(30, 6)
            * COALESCE(fx.local2usd, 0)::numeric(30, 12) AS remit_amt_usd
    FROM wangchuanliang.order_loan_f_v2_copy o
    CROSS JOIN params p
    INNER JOIN risk_orders ro
        ON ro.serial_id = o.serial_id
    LEFT JOIN user_channel uc
        ON uc.user_id = o.user_id
    LEFT JOIN fx_rates fx
        ON fx.snap_date = o.remit_date::date
    WHERE o.loan_type = 'firstloan'
      AND o.is_remit = 1
      AND COALESCE(o.remit_amt, 0) > 0
      AND o.apply_date >= p.cohort_start_date
      AND o.apply_date <= p.data_date
),

/* 首贷月份 × 渠道的基础指标，不受观察窗口成熟度限制 */
cohort_summary AS
(
    SELECT
        apply_month,
        channel_catgy,
        COUNT(DISTINCT serial_id)::bigint AS first_loan_order_count,
        COUNT(DISTINCT user_id)::bigint   AS first_loan_user_count,
        SUM(remit_amt_usd)::numeric(30, 6) AS first_loan_amt_usd
    FROM base_orders
    GROUP BY apply_month, channel_catgy
),

/* 市场成本已是美元；按首贷申请月和渠道汇总 */
marketing_cost AS
(
    SELECT
        DATE_TRUNC('month', c.snap_date)::date AS apply_month,
        CASE
            WHEN c.network_name = 'Facebook' AND c.campaign_name LIKE '%VO%' THEN 'FB-VO'
            WHEN c.network_name = 'Facebook' AND c.campaign_name LIKE '%register%' THEN 'FB-register'
            WHEN c.network_name = 'Facebook' THEN 'FB 2.5'
            WHEN c.network_name = 'Google' AND c.campaign_name LIKE '%Kaby-new-3.0%' THEN 'GG-kaby3.0'
            WHEN c.network_name = 'Google' AND c.campaign_name LIKE '%kaby-4-3.0%' THEN 'GG-kaby3.0_new'
            WHEN c.network_name = 'Google' AND c.campaign_name LIKE '%register%' THEN 'GG-register'
            WHEN c.network_name = 'Google' THEN 'GG-kaby2.5'
            WHEN c.network_name IN ('tiktok', 'TikTok SAN') AND c.campaign_name LIKE '%ROAS%' THEN 'TT-3.0'
            WHEN c.network_name IN ('tiktok', 'TikTok SAN') THEN 'TT'
            ELSE 'OTHERS'
        END AS channel_catgy,
        SUM(COALESCE(c.cost_amt, 0))::numeric(30, 6) AS marketing_cost_usd
    FROM dws.rpt_adjust_cost c
    CROSS JOIN params p
    WHERE c.snap_date >= p.cohort_start_date
      AND c.snap_date <= p.data_date
    GROUP BY
        DATE_TRUNC('month', c.snap_date)::date,
        CASE
            WHEN c.network_name = 'Facebook' AND c.campaign_name LIKE '%VO%' THEN 'FB-VO'
            WHEN c.network_name = 'Facebook' AND c.campaign_name LIKE '%register%' THEN 'FB-register'
            WHEN c.network_name = 'Facebook' THEN 'FB 2.5'
            WHEN c.network_name = 'Google' AND c.campaign_name LIKE '%Kaby-new-3.0%' THEN 'GG-kaby3.0'
            WHEN c.network_name = 'Google' AND c.campaign_name LIKE '%kaby-4-3.0%' THEN 'GG-kaby3.0_new'
            WHEN c.network_name = 'Google' AND c.campaign_name LIKE '%register%' THEN 'GG-register'
            WHEN c.network_name = 'Google' THEN 'GG-kaby2.5'
            WHEN c.network_name IN ('tiktok', 'TikTok SAN') AND c.campaign_name LIKE '%ROAS%' THEN 'TT-3.0'
            WHEN c.network_name IN ('tiktok', 'TikTok SAN') THEN 'TT'
            ELSE 'OTHERS'
        END
),

/* 全部已放款订单，为生命周期累计窗口提供订单分子/分母 */
all_remit_orders AS
(
    SELECT
        o.serial_id,
        o.user_id,
        o.loan_type,
        COALESCE(o.apply_time, o.apply_date::timestamp) AS apply_time,
        o.apply_date::date AS apply_date,
        o.remit_date::date AS remit_date,
        o.due_date::date   AS due_date,
        o.repaid_date::date AS repaid_date,
        COALESCE(o.remit_amt, 0)::numeric(30, 6) AS remit_amt_local,
        COALESCE(o.remit_amt, 0)::numeric(30, 6)
            * COALESCE(fx.local2usd, 0)::numeric(30, 12) AS remit_amt_usd,
        COALESCE(o.pre_amt, 0)::numeric(30, 6)
            + COALESCE(o.post_amt, 0)::numeric(30, 6) AS interest_amt_local,
        (COALESCE(o.pre_amt, 0)::numeric(30, 6)
            + COALESCE(o.post_amt, 0)::numeric(30, 6))
            * COALESCE(fx.local2usd, 0)::numeric(30, 12) AS interest_amt_usd,
        COALESCE(o.loan_day, 0)::numeric(30, 6) AS loan_days
    FROM wangchuanliang.order_loan_f_v2_copy o
    CROSS JOIN params p
    LEFT JOIN fx_rates fx
        ON fx.snap_date = o.remit_date::date
    WHERE o.is_remit = 1
      AND COALESCE(o.remit_amt, 0) > 0
      AND o.apply_date >= p.cohort_start_date
      AND o.apply_date <= p.data_date
),

/* 每个 cohort 与累计观察窗口中的所有成功放款订单 */
eligible_orders AS
(
    SELECT
        b.apply_month,
        b.channel_catgy,
        b.serial_id AS first_loan_serial_id,
        b.user_id,
        b.apply_time AS first_apply_time,
        w.window_day,
        (b.apply_date + w.window_day)::date AS window_end_date,
        o.serial_id,
        o.loan_type,
        o.apply_date,
        o.remit_date,
        o.due_date,
        o.repaid_date,
        o.remit_amt_usd,
        o.interest_amt_usd,
        o.loan_days
    FROM base_orders b
    CROSS JOIN window_days w
    JOIN all_remit_orders o
      ON o.user_id = b.user_id
     AND o.apply_time >= b.apply_time
     AND o.apply_time <= b.apply_time + w.window_day * INTERVAL '1 day'
),

/* 还款流水按实际还款日汇率换算；窗口内累计 */
eligible_repayments AS
(
    SELECT
        e.apply_month,
        e.channel_catgy,
        e.window_day,
        e.first_loan_serial_id,
        e.serial_id,
        SUM
        (
            COALESCE(r.amount, 0)::numeric(30, 6)
            * COALESCE(fx.local2usd, 0)::numeric(30, 12)
        )::numeric(30, 6) AS repay_amt_usd
    FROM eligible_orders e
    JOIN wangchuanliang.repayment_plan_record_copy r
      ON r.serial_id = e.serial_id
     AND r.payin_date::date >= e.apply_date
     AND r.payin_date::date <= e.window_end_date
    LEFT JOIN fx_rates fx
      ON fx.snap_date = r.payin_date::date
    GROUP BY
        e.apply_month,
        e.channel_catgy,
        e.window_day,
        e.first_loan_serial_id,
        e.serial_id
),

/* 整笔订单在观察窗口截止日之前到期，才进入盈利与逾期口径 */
due_orders AS
(
    SELECT e.*
    FROM eligible_orders e
    WHERE e.due_date IS NOT NULL
      AND e.due_date >= e.first_apply_time::date
      AND e.due_date <= e.window_end_date
),

/* 分期本金快照：判断窗口截止日的未结清本金 */
period_risk AS
(
    SELECT
        d.apply_month,
        d.channel_catgy,
        d.window_day,
        d.first_loan_serial_id,
        d.serial_id,
        MAX
        (
            CASE
                WHEN p.repaid_date_period IS NULL
                  OR p.repaid_date_period < DATE '2000-01-01'
                  OR p.repaid_date_period > d.window_end_date
                THEN 1 ELSE 0
            END
        ) AS is_overdue_at_window,
        SUM
        (
            CASE
                WHEN p.repaid_date_period IS NULL
                  OR p.repaid_date_period < DATE '2000-01-01'
                  OR p.repaid_date_period > d.window_end_date
                THEN COALESCE(p.remit_amt_period, 0)::numeric(30, 6)
                     * COALESCE(fx.local2usd, 0)::numeric(30, 12)
                ELSE 0
            END
        )::numeric(30, 6) AS overdue_term_remit_amt_usd
    FROM due_orders d
    LEFT JOIN wangchuanliang.repayment_plan_v2_copy p
      ON p.serial_id = d.serial_id
     AND p.is_remit = 1
    LEFT JOIN fx_rates fx
      ON fx.snap_date = d.remit_date
    GROUP BY
        d.apply_month,
        d.channel_catgy,
        d.window_day,
        d.first_loan_serial_id,
        d.serial_id
),

/* 生命周期累计窗口的原子指标 */
lifecycle_metrics AS
(
    SELECT
        d.apply_month,
        d.channel_catgy,
        d.window_day,
        SUM(COALESCE(er.repay_amt_usd, 0))::numeric(30, 6) AS repay_amt_usd,
        SUM(d.remit_amt_usd)::numeric(30, 6) AS remit_amt_usd,
        (SUM(COALESCE(er.repay_amt_usd, 0)) - SUM(d.remit_amt_usd))::numeric(30, 6)
            AS profit_amt_usd,
        SUM
        (
            CASE WHEN d.loan_type = 'reloan' THEN d.remit_amt_usd ELSE 0 END
        )::numeric(30, 6) AS remit_reloan_amt_usd,
        COUNT(DISTINCT d.serial_id)::bigint AS due_whole_order_count,
        COUNT
        (
            DISTINCT CASE WHEN COALESCE(pr.is_overdue_at_window, 0) = 1
                          THEN d.serial_id END
        )::bigint AS overdue_whole_order_count,
        SUM(d.remit_amt_usd)::numeric(30, 6) AS due_whole_order_remit_amt_usd,
        SUM(COALESCE(pr.overdue_term_remit_amt_usd, 0))::numeric(30, 6)
            AS overdue_term_remit_amt_usd,
        SUM(d.loan_days)::numeric(30, 6) AS whole_order_loan_days_sum,
        SUM(d.interest_amt_usd)::numeric(30, 6) AS whole_order_interest_amt_usd
    FROM due_orders d
    LEFT JOIN eligible_repayments er
      ON er.apply_month = d.apply_month
     AND er.channel_catgy = d.channel_catgy
     AND er.window_day = d.window_day
     AND er.first_loan_serial_id = d.first_loan_serial_id
     AND er.serial_id = d.serial_id
    LEFT JOIN period_risk pr
      ON pr.apply_month = d.apply_month
     AND pr.channel_catgy = d.channel_catgy
     AND pr.window_day = d.window_day
     AND pr.first_loan_serial_id = d.first_loan_serial_id
     AND pr.serial_id = d.serial_id
    GROUP BY d.apply_month, d.channel_catgy, d.window_day
),

/* 补齐每个首贷月份 × 渠道 × 12个观察窗口 */
report_keys AS
(
    SELECT
        p.data_date,
        p.run_date,
        c.apply_month,
        c.channel_catgy,
        w.window_day,
        CASE
            WHEN
                (
                    (DATE_TRUNC('month', c.apply_month)
                     + INTERVAL '1 month' - INTERVAL '1 day')::date
                    + w.window_day
                ) <= p.data_date
                /* 显式业务规则：当前月和上个月不展示生命周期指标 */
                AND c.apply_month <=
                    (DATE_TRUNC('month', p.run_date) - INTERVAL '2 months')::date
            THEN 1 ELSE 0
        END AS is_mature,
        CASE WHEN w.window_day = 30 THEN 1 ELSE 0 END AS is_base_row
    FROM cohort_summary c
    CROSS JOIN window_days w
    CROSS JOIN params p
)
SELECT
    k.data_date,
    k.run_date,
    k.apply_month,
    k.channel_catgy,
    k.window_day,
    k.is_mature,
    k.is_base_row,

    /* 基础指标保持可见；Tableau 只取 is_base_row=1 */
    c.first_loan_order_count,
    c.first_loan_user_count,
    c.first_loan_amt_usd,
    COALESCE(mc.marketing_cost_usd, 0)::numeric(30, 6) AS marketing_cost_usd,

    /* 未成熟生命周期指标写 NULL，而不是 0 */
    CASE WHEN k.is_mature = 1 THEN COALESCE(l.repay_amt_usd, 0) END,
    CASE WHEN k.is_mature = 1 THEN COALESCE(l.remit_amt_usd, 0) END,
    CASE WHEN k.is_mature = 1 THEN COALESCE(l.profit_amt_usd, 0) END,
    CASE WHEN k.is_mature = 1 THEN COALESCE(l.remit_reloan_amt_usd, 0) END,
    CASE WHEN k.is_mature = 1 THEN COALESCE(l.due_whole_order_count, 0) END,
    CASE WHEN k.is_mature = 1 THEN COALESCE(l.overdue_whole_order_count, 0) END,
    CASE WHEN k.is_mature = 1 THEN COALESCE(l.due_whole_order_remit_amt_usd, 0) END,
    CASE WHEN k.is_mature = 1 THEN COALESCE(l.overdue_term_remit_amt_usd, 0) END,
    CASE WHEN k.is_mature = 1 THEN COALESCE(l.whole_order_loan_days_sum, 0) END,
    CASE WHEN k.is_mature = 1 THEN COALESCE(l.whole_order_interest_amt_usd, 0) END,

    CURRENT_TIMESTAMP AS refresh_time
FROM report_keys k
JOIN cohort_summary c
  ON c.apply_month = k.apply_month
 AND c.channel_catgy = k.channel_catgy
LEFT JOIN marketing_cost mc
  ON mc.apply_month = k.apply_month
 AND mc.channel_catgy = k.channel_catgy
LEFT JOIN lifecycle_metrics l
  ON l.apply_month = k.apply_month
 AND l.channel_catgy = k.channel_catgy
 AND l.window_day = k.window_day;


/* ==================================================================
   第三部分：刷新前质量检查
   正常结果：duplicate_key_count=0、invalid_window_count=0、
             immature_non_null_count=0。
   自动调度时，应将这三项配置为发布前置校验；任何一项非0则停止换表。
   ================================================================== */

SELECT COUNT(*) AS duplicate_key_count
FROM
(
    SELECT apply_month, channel_catgy, window_day, COUNT(*) AS cnt
    FROM wangchuanliang.rpt_firstloan_channel_lifecycle_stg
    GROUP BY apply_month, channel_catgy, window_day
    HAVING COUNT(*) > 1
) t;

SELECT COUNT(*) AS invalid_window_count
FROM wangchuanliang.rpt_firstloan_channel_lifecycle_stg
WHERE window_day NOT IN (30,60,90,120,150,180,210,240,270,300,330,360);

SELECT COUNT(*) AS immature_non_null_count
FROM wangchuanliang.rpt_firstloan_channel_lifecycle_stg
WHERE is_mature = 0
  AND
  (
      profit_amt_usd IS NOT NULL
      OR due_whole_order_count IS NOT NULL
      OR overdue_whole_order_count IS NOT NULL
  );

/* 正常结果均为0；如非0，应先补齐汇率再发布 */
SELECT COUNT(DISTINCT o.serial_id) AS missing_remit_fx_order_count
FROM wangchuanliang.order_loan_f_v2_copy o
WHERE o.is_remit = 1
  AND o.apply_date >= DATE '2025-07-01'
  AND o.apply_date <= CURRENT_DATE - 1
  AND NOT EXISTS
      (
          SELECT 1
          FROM wangchuanliang.exchange_rate_copy fx
          WHERE fx.country = 'MXN'
            AND fx.snap_date = o.remit_date
      );

SELECT COUNT(*) AS missing_payin_fx_record_count
FROM wangchuanliang.repayment_plan_record_copy r
WHERE r.payin_date >= DATE '2025-07-01'
  AND r.payin_date <= CURRENT_DATE - 1
  AND NOT EXISTS
      (
          SELECT 1
          FROM wangchuanliang.exchange_rate_copy fx
          WHERE fx.country = 'MXN'
            AND fx.snap_date = r.payin_date
      );

SELECT
    MIN(apply_month) AS first_apply_month,
    MAX(apply_month) AS last_apply_month,
    COUNT(*) AS report_rows,
    COUNT(DISTINCT window_day) AS window_count,
    MAX(data_date) AS data_date
FROM wangchuanliang.rpt_firstloan_channel_lifecycle_stg;


/* ==================================================================
   第四部分：用已通过校验的暂存表替换正式表
   DELETE 和 INSERT 处于同一事务；失败会回滚，正式表不会被清空。
   ================================================================== */

BEGIN;

DELETE FROM wangchuanliang.rpt_firstloan_channel_lifecycle;

INSERT INTO wangchuanliang.rpt_firstloan_channel_lifecycle
SELECT *
FROM wangchuanliang.rpt_firstloan_channel_lifecycle_stg;

COMMIT;

ANALYZE wangchuanliang.rpt_firstloan_channel_lifecycle;


/* ==================================================================
   第五部分：正式表发布后检查
   ================================================================== */

SELECT
    data_date,
    apply_month,
    channel_catgy,
    window_day,
    is_mature,
    is_base_row,
    first_loan_user_count,
    first_loan_amt_usd,
    marketing_cost_usd,
    profit_amt_usd,
    due_whole_order_count,
    overdue_whole_order_count,
    refresh_time
FROM wangchuanliang.rpt_firstloan_channel_lifecycle
ORDER BY apply_month DESC, channel_catgy, window_day
LIMIT 200;

RESET query_dop;
