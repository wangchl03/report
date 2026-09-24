-- =============================================================================
-- T0额度变化与获额后当天提单率：用户 × T0事件母表
-- 时间：2026-01-01 至 2026-09-20（含）
-- 20秒批次：相邻获额时间差<=20秒归为同批，批内按获额时间、订单号倒序取第一笔。
-- 当天提单：apply_time >= vir_time 且早于T0自然日次日0点。
-- 多T0归属：同一订单归给其提单前最近一次T0事件，避免重复。
-- =============================================================================
SET search_path TO wangchuanliang, public;
SET statement_timeout = 0;
DROP TABLE IF EXISTS tmp_t0_credit_change_d0_apply;
CREATE TEMP TABLE tmp_t0_credit_change_d0_apply AS
WITH params AS (
    SELECT DATE '2026-01-01' AS start_date,
           DATE '2026-09-21' AS end_date
), raw_offer AS (
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
      AND v.vir_date >= p.start_date - 1
      AND v.vir_date < p.end_date
    ORDER BY v.user_id, v.serial_id, v.vir_unix DESC
), lagged_offer AS (
    SELECT r.*,
      LAG(r.vir_time) OVER (
        PARTITION BY r.user_id ORDER BY r.vir_time, r.credit_serial_id
      ) AS prev_vir_time
    FROM raw_offer r
), batched_offer AS (
    SELECT l.*,
      SUM(
        CASE WHEN l.prev_vir_time IS NULL
                   OR l.vir_time - l.prev_vir_time > INTERVAL '20 seconds'
             THEN 1 ELSE 0 END
      ) OVER (
        PARTITION BY l.user_id
        ORDER BY l.vir_time, l.credit_serial_id
        ROWS UNBOUNDED PRECEDING
      ) AS batch_id
    FROM lagged_offer l
), dedup_offer AS (
    SELECT user_id, credit_serial_id, vir_date, vir_time,
           current_credit_amt, batch_id
    FROM (
      SELECT b.*,
        ROW_NUMBER() OVER (
          PARTITION BY b.user_id, b.batch_id
          ORDER BY b.vir_time DESC, b.credit_serial_id DESC
        ) AS batch_rn
      FROM batched_offer b
    ) x
    CROSS JOIN params p
    WHERE x.batch_rn = 1
      AND x.vir_date >= p.start_date
      AND x.vir_date < p.end_date
), candidate_users AS (
    SELECT DISTINCT user_id FROM dedup_offer
), all_orders AS (
    SELECT o.user_id, o.serial_id, o.apply_time, o.apply_date,
           o.remit_time, o.remit_amt, o.is_remit,
           o.repaid_time, o.repaid_date::date AS repaid_date,
           o.is_repaid, o.loan_status_code
    FROM wangchuanliang.order_loan_f_v2_copy o
    JOIN candidate_users u ON u.user_id = o.user_id
), clean_settlement AS (
    SELECT o.user_id, o.serial_id AS settled_serial_id,
           o.remit_amt::numeric AS settled_remit_amt,
           o.repaid_time, o.repaid_date
    FROM all_orders o
    WHERE o.is_remit = 1
      AND COALESCE(o.remit_amt, 0) > 0
      AND (o.is_repaid = 1 OR o.loan_status_code = 7)
      AND o.repaid_time > TIMESTAMP '2000-01-01 00:00:00'
      AND NOT EXISTS (
        SELECT 1
        FROM all_orders x
        WHERE x.user_id = o.user_id
          AND x.serial_id <> o.serial_id
          AND x.apply_time < o.repaid_time
          AND (
            x.loan_status_code IN (5, 8)
            OR (x.loan_status_code = 7 AND x.repaid_time > o.repaid_time)
          )
      )
), offer_settlement_pair AS (
    SELECT e.user_id, e.credit_serial_id, e.vir_date, e.vir_time,
           e.current_credit_amt, e.batch_id,
           s.settled_serial_id, s.settled_remit_amt, s.repaid_time,
      ROW_NUMBER() OVER (
        PARTITION BY e.user_id, e.credit_serial_id, e.vir_time
        ORDER BY s.repaid_time DESC, s.settled_serial_id DESC
      ) AS settlement_rn
    FROM dedup_offer e
    JOIN clean_settlement s
      ON s.user_id = e.user_id
     AND s.repaid_date = e.vir_date
     AND e.vir_time >= s.repaid_time
), strict_t0 AS (
    SELECT user_id, credit_serial_id, vir_date, vir_time,
           current_credit_amt, batch_id,
           settled_serial_id, settled_remit_amt, repaid_time
    FROM offer_settlement_pair
    WHERE settlement_rn = 1
), previous_credit_ranked AS (
    SELECT s.user_id, s.credit_serial_id, s.vir_time, s.settled_serial_id,
           v.max_credit_apply_amt::numeric AS previous_credit_amt,
      ROW_NUMBER() OVER (
        PARTITION BY s.user_id, s.credit_serial_id, s.vir_time
        ORDER BY v.vir_unix DESC, v.serial_id DESC
      ) AS rn
    FROM strict_t0 s
    JOIN wangchuanliang.order_vir_f_copy v
      ON v.serial_id = s.settled_serial_id
     AND v.is_pass1 = 1
), previous_credit AS (
    SELECT user_id, credit_serial_id, vir_time, settled_serial_id,
           previous_credit_amt
    FROM previous_credit_ranked
    WHERE rn = 1
), loan_count_at_settlement AS (
    SELECT s.user_id, s.credit_serial_id, s.vir_time,
           COUNT(DISTINCT h.serial_id) AS successful_loan_n
    FROM strict_t0 s
    JOIN all_orders h
      ON h.user_id = s.user_id
     AND h.is_remit = 1
     AND COALESCE(h.remit_amt, 0) > 0
     AND h.remit_time IS NOT NULL
     AND h.remit_time <= s.repaid_time
    GROUP BY s.user_id, s.credit_serial_id, s.vir_time
), event_base AS (
    SELECT s.user_id, s.credit_serial_id, s.vir_date, s.vir_time,
           s.repaid_time, s.settled_serial_id,
           s.settled_remit_amt AS previous_remit_amt,
           p.previous_credit_amt,
           s.current_credit_amt,
           s.current_credit_amt - p.previous_credit_amt AS credit_change_amt,
           s.current_credit_amt / NULLIF(p.previous_credit_amt, 0) - 1
             AS credit_change_rate,
           s.settled_remit_amt / NULLIF(p.previous_credit_amt, 0)
             AS previous_util_ratio,
           l.successful_loan_n
    FROM strict_t0 s
    JOIN previous_credit p
      ON p.user_id = s.user_id
     AND p.credit_serial_id = s.credit_serial_id
     AND p.vir_time = s.vir_time
     AND p.settled_serial_id = s.settled_serial_id
    JOIN loan_count_at_settlement l
      ON l.user_id = s.user_id
     AND l.credit_serial_id = s.credit_serial_id
     AND l.vir_time = s.vir_time
    WHERE s.current_credit_amt > 0
      AND p.previous_credit_amt > 0
      AND s.settled_remit_amt > 0
), candidate_same_day_orders AS (
    SELECT e.user_id, e.credit_serial_id, e.vir_time,
           o.serial_id AS apply_serial_id, o.apply_time,
      ROW_NUMBER() OVER (
        PARTITION BY o.serial_id
        ORDER BY e.vir_time DESC, e.credit_serial_id DESC
      ) AS event_match_rn
    FROM event_base e
    JOIN all_orders o
      ON o.user_id = e.user_id
     AND o.apply_time >= e.vir_time
     AND o.apply_time < e.vir_date + 1
), assigned_same_day_orders AS (
    SELECT *
    FROM candidate_same_day_orders
    WHERE event_match_rn = 1
), first_same_day_apply AS (
    SELECT user_id, credit_serial_id, vir_time,
           apply_serial_id, apply_time
    FROM (
      SELECT a.*,
        ROW_NUMBER() OVER (
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
    e.credit_change_amt,
    e.credit_change_rate,
    CASE WHEN e.credit_change_amt < 0 THEN '额度降低'
         WHEN e.credit_change_amt = 0 THEN '额度不变'
         ELSE '额度增加' END AS credit_change_type,
    CASE
      WHEN e.credit_change_amt < -1000 THEN '降额>1000'
      WHEN e.credit_change_amt < 0 THEN '降额≤1000'
      WHEN e.credit_change_amt = 0 THEN '额度不变'
      WHEN e.credit_change_amt <= 150 THEN '提额≤150'
      WHEN e.credit_change_amt <= 1200 THEN '提额(150,1200]'
      ELSE '提额>1200'
    END AS change_amount_bucket,
    CASE
      WHEN e.credit_change_rate <= -0.50 THEN '降幅50%及以上'
      WHEN e.credit_change_rate <= -0.20 THEN '降幅20%-50%'
      WHEN e.credit_change_rate < 0 THEN '降幅0%-20%'
      WHEN e.credit_change_rate = 0 THEN '额度不变'
      WHEN e.credit_change_rate < 0.20 THEN '涨幅0%-20%'
      WHEN e.credit_change_rate < 0.50 THEN '涨幅20%-50%'
      ELSE '涨幅50%及以上'
    END AS change_rate_bucket,
    e.previous_remit_amt,
    e.previous_util_ratio,
    CASE WHEN e.previous_util_ratio < 0.800 THEN '<80%'
         WHEN e.previous_util_ratio < 0.999 THEN '80%-100%'
         WHEN e.previous_util_ratio <= 1.001 THEN '接近100%'
         ELSE '>100%' END AS previous_util_band,
    e.successful_loan_n,
    CASE WHEN e.successful_loan_n = 1 THEN '1次'
         WHEN e.successful_loan_n = 2 THEN '2次'
         WHEN e.successful_loan_n = 3 THEN '3次'
         WHEN e.successful_loan_n = 4 THEN '4次'
         WHEN e.successful_loan_n = 5 THEN '5次'
         ELSE '6次及以上' END AS loan_count_bucket,
    CASE WHEN a.apply_serial_id IS NULL THEN 0 ELSE 1 END AS has_d0_apply,
    a.apply_serial_id,
    a.apply_time AS d0_apply_time,
    CASE WHEN a.apply_time IS NULL THEN NULL
         ELSE EXTRACT(EPOCH FROM (a.apply_time - e.vir_time)) / 60.0
    END AS minutes_to_apply
FROM event_base e
LEFT JOIN first_same_day_apply a
  ON a.user_id = e.user_id
 AND a.credit_serial_id = e.credit_serial_id
 AND a.vir_time = e.vir_time;


-- =============================================================================
-- 指标集：overall
-- =============================================================================
SELECT 
  COUNT(*) AS event_n,
  COUNT(DISTINCT user_id) AS user_n,
  SUM(has_d0_apply) AS d0_apply_n,
  ROUND(100.0 * SUM(has_d0_apply) / NULLIF(COUNT(*), 0), 2)
    AS d0_apply_rate_pct,
  ROUND(AVG(previous_credit_amt), 2) AS avg_previous_credit_amt,
  ROUND(AVG(current_credit_amt), 2) AS avg_current_credit_amt,
  ROUND(AVG(credit_change_amt), 2) AS avg_credit_change_amt,
  ROUND(100.0 * AVG(credit_change_rate), 2) AS avg_credit_change_rate_pct,
  ROUND(100.0 * SUM(previous_remit_amt) / NULLIF(SUM(previous_credit_amt), 0), 2)
    AS previous_utilization_rate_pct,
  ROUND(AVG(CASE WHEN has_d0_apply=1 THEN minutes_to_apply END), 2)
    AS avg_minutes_to_apply
 FROM tmp_t0_credit_change_d0_apply;


-- =============================================================================
-- 指标集：monthly_overall
-- =============================================================================
SELECT TO_CHAR(t0_month, 'YYYY-MM') AS t0_month, 
  COUNT(*) AS event_n,
  COUNT(DISTINCT user_id) AS user_n,
  SUM(has_d0_apply) AS d0_apply_n,
  ROUND(100.0 * SUM(has_d0_apply) / NULLIF(COUNT(*), 0), 2)
    AS d0_apply_rate_pct,
  ROUND(AVG(previous_credit_amt), 2) AS avg_previous_credit_amt,
  ROUND(AVG(current_credit_amt), 2) AS avg_current_credit_amt,
  ROUND(AVG(credit_change_amt), 2) AS avg_credit_change_amt,
  ROUND(100.0 * AVG(credit_change_rate), 2) AS avg_credit_change_rate_pct,
  ROUND(100.0 * SUM(previous_remit_amt) / NULLIF(SUM(previous_credit_amt), 0), 2)
    AS previous_utilization_rate_pct,
  ROUND(AVG(CASE WHEN has_d0_apply=1 THEN minutes_to_apply END), 2)
    AS avg_minutes_to_apply
,
        ROUND(100.0 * SUM(has_d0_apply) / NULLIF(COUNT(*), 0)
          - LAG(100.0 * SUM(has_d0_apply) / NULLIF(COUNT(*), 0))
            OVER (ORDER BY t0_month), 2) AS mom_change_pp
      FROM tmp_t0_credit_change_d0_apply
      GROUP BY t0_month ORDER BY t0_month;


-- =============================================================================
-- 指标集：direction_overall
-- =============================================================================
SELECT credit_change_type, 
  COUNT(*) AS event_n,
  COUNT(DISTINCT user_id) AS user_n,
  SUM(has_d0_apply) AS d0_apply_n,
  ROUND(100.0 * SUM(has_d0_apply) / NULLIF(COUNT(*), 0), 2)
    AS d0_apply_rate_pct,
  ROUND(AVG(previous_credit_amt), 2) AS avg_previous_credit_amt,
  ROUND(AVG(current_credit_amt), 2) AS avg_current_credit_amt,
  ROUND(AVG(credit_change_amt), 2) AS avg_credit_change_amt,
  ROUND(100.0 * AVG(credit_change_rate), 2) AS avg_credit_change_rate_pct,
  ROUND(100.0 * SUM(previous_remit_amt) / NULLIF(SUM(previous_credit_amt), 0), 2)
    AS previous_utilization_rate_pct,
  ROUND(AVG(CASE WHEN has_d0_apply=1 THEN minutes_to_apply END), 2)
    AS avg_minutes_to_apply
,
        ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS event_share_pct,
        ROUND(100.0 * SUM(has_d0_apply) / SUM(SUM(has_d0_apply)) OVER (), 2)
          AS apply_share_pct
      FROM tmp_t0_credit_change_d0_apply
      GROUP BY credit_change_type ORDER BY CASE credit_change_type
  WHEN '额度降低' THEN 1 WHEN '额度不变' THEN 2 ELSE 3 END;


-- =============================================================================
-- 指标集：monthly_direction
-- =============================================================================
SELECT TO_CHAR(t0_month, 'YYYY-MM') AS t0_month,
        credit_change_type, 
  COUNT(*) AS event_n,
  COUNT(DISTINCT user_id) AS user_n,
  SUM(has_d0_apply) AS d0_apply_n,
  ROUND(100.0 * SUM(has_d0_apply) / NULLIF(COUNT(*), 0), 2)
    AS d0_apply_rate_pct,
  ROUND(AVG(previous_credit_amt), 2) AS avg_previous_credit_amt,
  ROUND(AVG(current_credit_amt), 2) AS avg_current_credit_amt,
  ROUND(AVG(credit_change_amt), 2) AS avg_credit_change_amt,
  ROUND(100.0 * AVG(credit_change_rate), 2) AS avg_credit_change_rate_pct,
  ROUND(100.0 * SUM(previous_remit_amt) / NULLIF(SUM(previous_credit_amt), 0), 2)
    AS previous_utilization_rate_pct,
  ROUND(AVG(CASE WHEN has_d0_apply=1 THEN minutes_to_apply END), 2)
    AS avg_minutes_to_apply
,
        ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY t0_month), 2)
          AS event_share_pct,
        ROUND(100.0 * SUM(has_d0_apply) / SUM(COUNT(*)) OVER (PARTITION BY t0_month), 2)
          AS contribution_to_overall_rate_pp
      FROM tmp_t0_credit_change_d0_apply
      GROUP BY t0_month, credit_change_type
      ORDER BY t0_month, CASE credit_change_type
  WHEN '额度降低' THEN 1 WHEN '额度不变' THEN 2 ELSE 3 END;


-- =============================================================================
-- 指标集：amount_bucket_overall
-- =============================================================================
SELECT change_amount_bucket, 
  COUNT(*) AS event_n,
  COUNT(DISTINCT user_id) AS user_n,
  SUM(has_d0_apply) AS d0_apply_n,
  ROUND(100.0 * SUM(has_d0_apply) / NULLIF(COUNT(*), 0), 2)
    AS d0_apply_rate_pct,
  ROUND(AVG(previous_credit_amt), 2) AS avg_previous_credit_amt,
  ROUND(AVG(current_credit_amt), 2) AS avg_current_credit_amt,
  ROUND(AVG(credit_change_amt), 2) AS avg_credit_change_amt,
  ROUND(100.0 * AVG(credit_change_rate), 2) AS avg_credit_change_rate_pct,
  ROUND(100.0 * SUM(previous_remit_amt) / NULLIF(SUM(previous_credit_amt), 0), 2)
    AS previous_utilization_rate_pct,
  ROUND(AVG(CASE WHEN has_d0_apply=1 THEN minutes_to_apply END), 2)
    AS avg_minutes_to_apply
,
        ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS event_share_pct
      FROM tmp_t0_credit_change_d0_apply
      GROUP BY change_amount_bucket ORDER BY CASE change_amount_bucket
  WHEN '提额≤150' THEN 1 WHEN '提额(150,1200]' THEN 2
  WHEN '提额>1200' THEN 3 WHEN '额度不变' THEN 4
  WHEN '降额≤1000' THEN 5 ELSE 6 END;


-- =============================================================================
-- 指标集：monthly_amount_bucket
-- =============================================================================
SELECT TO_CHAR(t0_month, 'YYYY-MM') AS t0_month,
        change_amount_bucket, 
  COUNT(*) AS event_n,
  COUNT(DISTINCT user_id) AS user_n,
  SUM(has_d0_apply) AS d0_apply_n,
  ROUND(100.0 * SUM(has_d0_apply) / NULLIF(COUNT(*), 0), 2)
    AS d0_apply_rate_pct,
  ROUND(AVG(previous_credit_amt), 2) AS avg_previous_credit_amt,
  ROUND(AVG(current_credit_amt), 2) AS avg_current_credit_amt,
  ROUND(AVG(credit_change_amt), 2) AS avg_credit_change_amt,
  ROUND(100.0 * AVG(credit_change_rate), 2) AS avg_credit_change_rate_pct,
  ROUND(100.0 * SUM(previous_remit_amt) / NULLIF(SUM(previous_credit_amt), 0), 2)
    AS previous_utilization_rate_pct,
  ROUND(AVG(CASE WHEN has_d0_apply=1 THEN minutes_to_apply END), 2)
    AS avg_minutes_to_apply
,
        ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY t0_month), 2)
          AS event_share_pct,
        ROUND(100.0 * SUM(has_d0_apply) / SUM(COUNT(*)) OVER (PARTITION BY t0_month), 2)
          AS contribution_to_overall_rate_pp
      FROM tmp_t0_credit_change_d0_apply
      GROUP BY t0_month, change_amount_bucket
      ORDER BY t0_month, CASE change_amount_bucket
  WHEN '提额≤150' THEN 1 WHEN '提额(150,1200]' THEN 2
  WHEN '提额>1200' THEN 3 WHEN '额度不变' THEN 4
  WHEN '降额≤1000' THEN 5 ELSE 6 END;


-- =============================================================================
-- 指标集：monthly_target_bucket
-- =============================================================================
WITH bucketed AS (
        SELECT t.*, CASE
  WHEN credit_change_type='额度增加' AND credit_change_amt <= 150 THEN '提额≤150'
  WHEN credit_change_type='额度增加' AND credit_change_amt <= 1200 THEN '提额(150,1200]'
  WHEN credit_change_type='额度增加' THEN '提额>1200'
  WHEN credit_change_type='额度不变' THEN '额度不变'
  WHEN credit_change_type='额度降低' AND ABS(credit_change_amt) <= 1000 THEN '降额≤1000'
  ELSE '降额>1000' END AS target_bucket
        FROM tmp_t0_credit_change_d0_apply t
      )
      SELECT TO_CHAR(t0_month, 'YYYY-MM') AS t0_month,
        target_bucket, 
  COUNT(*) AS event_n,
  COUNT(DISTINCT user_id) AS user_n,
  SUM(has_d0_apply) AS d0_apply_n,
  ROUND(100.0 * SUM(has_d0_apply) / NULLIF(COUNT(*), 0), 2)
    AS d0_apply_rate_pct,
  ROUND(AVG(previous_credit_amt), 2) AS avg_previous_credit_amt,
  ROUND(AVG(current_credit_amt), 2) AS avg_current_credit_amt,
  ROUND(AVG(credit_change_amt), 2) AS avg_credit_change_amt,
  ROUND(100.0 * AVG(credit_change_rate), 2) AS avg_credit_change_rate_pct,
  ROUND(100.0 * SUM(previous_remit_amt) / NULLIF(SUM(previous_credit_amt), 0), 2)
    AS previous_utilization_rate_pct,
  ROUND(AVG(CASE WHEN has_d0_apply=1 THEN minutes_to_apply END), 2)
    AS avg_minutes_to_apply
,
        ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY t0_month), 2)
          AS event_share_pct
      FROM bucketed
      GROUP BY t0_month, target_bucket
      ORDER BY t0_month, CASE target_bucket
  WHEN '提额≤150' THEN 1 WHEN '提额(150,1200]' THEN 2
  WHEN '提额>1200' THEN 3 WHEN '额度不变' THEN 4
  WHEN '降额≤1000' THEN 5 ELSE 6 END;


-- =============================================================================
-- 指标集：target_bucket_contribution_vs_jan
-- =============================================================================
WITH bucketed AS (
        SELECT t.*, CASE
  WHEN credit_change_type='额度增加' AND credit_change_amt <= 150 THEN '提额≤150'
  WHEN credit_change_type='额度增加' AND credit_change_amt <= 1200 THEN '提额(150,1200]'
  WHEN credit_change_type='额度增加' THEN '提额>1200'
  WHEN credit_change_type='额度不变' THEN '额度不变'
  WHEN credit_change_type='额度降低' AND ABS(credit_change_amt) <= 1000 THEN '降额≤1000'
  ELSE '降额>1000' END AS target_bucket
        FROM tmp_t0_credit_change_d0_apply t
      ), monthly AS (
        SELECT t0_month, target_bucket,
          COUNT(*)::numeric AS n,
          SUM(has_d0_apply)::numeric AS apply_n,
          SUM(has_d0_apply)::numeric / NULLIF(COUNT(*),0) AS rate
        FROM bucketed
        GROUP BY t0_month, target_bucket
      ), total AS (
        SELECT t0_month, SUM(n) AS total_n,
          SUM(apply_n)/NULLIF(SUM(n),0) AS overall_rate
        FROM monthly GROUP BY t0_month
      ), weighted AS (
        SELECT m.*, m.n/t.total_n AS weight, t.overall_rate
        FROM monthly m JOIN total t USING (t0_month)
      ), jan AS (
        SELECT * FROM weighted WHERE t0_month=DATE '2026-01-01'
      ), paired AS (
        SELECT c.t0_month, c.target_bucket,
          j.n AS jan_n, c.n AS current_n,
          j.weight AS jan_weight, c.weight AS current_weight,
          j.rate AS jan_rate, c.rate AS current_rate,
          j.overall_rate AS jan_overall_rate
        FROM weighted c JOIN jan j USING(target_bucket)
      )
      SELECT TO_CHAR(t0_month,'YYYY-MM') AS t0_month, target_bucket,
        jan_n, current_n,
        ROUND(100*jan_weight,2) AS jan_share_pct,
        ROUND(100*current_weight,2) AS current_share_pct,
        ROUND(100*jan_rate,2) AS jan_rate_pct,
        ROUND(100*current_rate,2) AS current_rate_pct,
        ROUND(100*jan_weight*(current_rate-jan_rate),2) AS base_within_effect_pp,
        ROUND(100*(current_weight-jan_weight)*(jan_rate-jan_overall_rate),2)
          AS structure_effect_pp,
        ROUND(100*(current_weight-jan_weight)*(current_rate-jan_rate),2)
          AS interaction_effect_pp,
        ROUND(100*(
          jan_weight*(current_rate-jan_rate)
          +(current_weight-jan_weight)*(jan_rate-jan_overall_rate)
          +(current_weight-jan_weight)*(current_rate-jan_rate)
        ),2) AS total_attribution_pp
      FROM paired
      ORDER BY t0_month, CASE target_bucket
  WHEN '提额≤150' THEN 1 WHEN '提额(150,1200]' THEN 2
  WHEN '提额>1200' THEN 3 WHEN '额度不变' THEN 4
  WHEN '降额≤1000' THEN 5 ELSE 6 END;


-- =============================================================================
-- 指标集：target_bucket_summary_jan_aug
-- =============================================================================
WITH bucketed AS (
        SELECT t.*, CASE
  WHEN credit_change_type='额度增加' AND credit_change_amt <= 150 THEN '提额≤150'
  WHEN credit_change_type='额度增加' AND credit_change_amt <= 1200 THEN '提额(150,1200]'
  WHEN credit_change_type='额度增加' THEN '提额>1200'
  WHEN credit_change_type='额度不变' THEN '额度不变'
  WHEN credit_change_type='额度降低' AND ABS(credit_change_amt) <= 1000 THEN '降额≤1000'
  ELSE '降额>1000' END AS target_bucket
        FROM tmp_t0_credit_change_d0_apply t
        WHERE t0_month >= DATE '2026-01-01'
          AND t0_month < DATE '2026-09-01'
      ), period AS (
        SELECT target_bucket, credit_change_type,
          COUNT(*)::numeric AS event_n,
          SUM(has_d0_apply)::numeric AS apply_n
        FROM bucketed
        GROUP BY target_bucket, credit_change_type
      ), period_direction AS (
        SELECT credit_change_type, SUM(event_n) AS direction_event_n
        FROM period GROUP BY credit_change_type
      ), period_total AS (
        SELECT SUM(event_n) AS all_event_n FROM period
      ), monthly AS (
        SELECT t0_month, target_bucket, credit_change_type,
          COUNT(*)::numeric AS n,
          SUM(has_d0_apply)::numeric AS apply_n,
          SUM(has_d0_apply)::numeric / NULLIF(COUNT(*),0) AS rate
        FROM bucketed
        GROUP BY t0_month, target_bucket, credit_change_type
      ), monthly_total AS (
        SELECT t0_month, SUM(n) AS total_n,
          SUM(apply_n)/NULLIF(SUM(n),0) AS overall_rate
        FROM monthly GROUP BY t0_month
      ), weighted AS (
        SELECT m.*, m.n/t.total_n AS weight, t.overall_rate
        FROM monthly m JOIN monthly_total t USING (t0_month)
      ), paired AS (
        SELECT j.target_bucket, j.credit_change_type,
          j.n AS jan_event_n, a.n AS aug_event_n,
          j.rate AS jan_rate, a.rate AS aug_rate,
          j.weight AS jan_weight, a.weight AS aug_weight,
          j.overall_rate AS jan_overall_rate
        FROM weighted j
        JOIN weighted a USING (target_bucket, credit_change_type)
        WHERE j.t0_month=DATE '2026-01-01'
          AND a.t0_month=DATE '2026-08-01'
      ), attributed AS (
        SELECT p.*,
          100*(
            jan_weight*(aug_rate-jan_rate)
            +(aug_weight-jan_weight)*(jan_rate-jan_overall_rate)
            +(aug_weight-jan_weight)*(aug_rate-jan_rate)
          ) AS total_attribution_pp
        FROM paired p
      ), direction_attribution AS (
        SELECT credit_change_type,
          SUM(total_attribution_pp) AS direction_attribution_pp
        FROM attributed GROUP BY credit_change_type
      )
      SELECT p.target_bucket, p.credit_change_type,
        p.event_n,
        ROUND(100*p.event_n/d.direction_event_n,2) AS direction_share_pct,
        ROUND(100*p.event_n/t.all_event_n,2) AS overall_event_share_pct,
        ROUND(100*p.apply_n/NULLIF(p.event_n,0),2) AS overall_rate_pct,
        a.jan_event_n, a.aug_event_n,
        ROUND(100*a.jan_rate,2) AS jan_rate_pct,
        ROUND(100*a.aug_rate,2) AS aug_rate_pct,
        ROUND(100*(a.aug_rate-a.jan_rate),2) AS rate_change_pp,
        ROUND(a.total_attribution_pp,2) AS total_attribution_pp,
        ROUND(100*a.total_attribution_pp/NULLIF(da.direction_attribution_pp,0),2)
          AS direction_attribution_share_pct
      FROM period p
      JOIN period_direction d USING (credit_change_type)
      CROSS JOIN period_total t
      JOIN attributed a USING (target_bucket, credit_change_type)
      JOIN direction_attribution da USING (credit_change_type)
      ORDER BY CASE target_bucket
  WHEN '提额≤150' THEN 1 WHEN '提额(150,1200]' THEN 2
  WHEN '提额>1200' THEN 3 WHEN '额度不变' THEN 4
  WHEN '降额≤1000' THEN 5 ELSE 6 END;


-- =============================================================================
-- 指标集：large_increase_drilldown_summary
-- =============================================================================
WITH membership AS (
  SELECT t.*, 1 AS group_order, '层级节点'::text AS group_kind,
    '提额>1200父群'::text AS group_name
  FROM tmp_t0_credit_change_d0_apply t
  WHERE t.t0_month>=DATE '2026-01-01' AND t.t0_month<DATE '2026-09-01'
    AND t.credit_change_type='额度增加' AND t.credit_change_amt>1200
  UNION ALL
  SELECT t.*, 2, '层级节点', '借款≤2次'
  FROM tmp_t0_credit_change_d0_apply t
  WHERE t.t0_month>=DATE '2026-01-01' AND t.t0_month<DATE '2026-09-01'
    AND t.credit_change_type='额度增加' AND t.credit_change_amt>1200
    AND t.successful_loan_n<=2
  UNION ALL
  SELECT t.*, 3, '层级节点', '借款≤2次且提额>2400'
  FROM tmp_t0_credit_change_d0_apply t
  WHERE t.t0_month>=DATE '2026-01-01' AND t.t0_month<DATE '2026-09-01'
    AND t.credit_change_type='额度增加' AND t.credit_change_amt>2400
    AND t.successful_loan_n<=2
  UNION ALL
  SELECT t.*, 4, '层级节点', '三个优先叶子合集'
  FROM tmp_t0_credit_change_d0_apply t
  WHERE t.t0_month>=DATE '2026-01-01' AND t.t0_month<DATE '2026-09-01'
    AND t.credit_change_type='额度增加' AND t.credit_change_amt>1200
    AND t.successful_loan_n<=2
    AND (
      (t.credit_change_amt<=2400 AND t.previous_util_ratio<=0.90)
      OR (t.credit_change_amt>2400 AND t.credit_change_amt<=4500
          AND t.credit_change_rate>1.50)
      OR t.credit_change_amt>4500
    )
  UNION ALL
  SELECT t.*, 5, '目标叶子', 'A｜低幅提额＋低历史使用'
  FROM tmp_t0_credit_change_d0_apply t
  WHERE t.t0_month>=DATE '2026-01-01' AND t.t0_month<DATE '2026-09-01'
    AND t.credit_change_type='额度增加' AND t.credit_change_amt>1200
    AND t.successful_loan_n<=2 AND t.credit_change_amt<=2400
    AND t.previous_util_ratio<=0.90
  UNION ALL
  SELECT t.*, 6, '目标叶子', 'B｜中幅提额＋高提额倍数'
  FROM tmp_t0_credit_change_d0_apply t
  WHERE t.t0_month>=DATE '2026-01-01' AND t.t0_month<DATE '2026-09-01'
    AND t.credit_change_type='额度增加' AND t.successful_loan_n<=2
    AND t.credit_change_amt>2400 AND t.credit_change_amt<=4500
    AND t.credit_change_rate>1.50
  UNION ALL
  SELECT t.*, 7, '目标叶子', 'C｜超大额提额'
  FROM tmp_t0_credit_change_d0_apply t
  WHERE t.t0_month>=DATE '2026-01-01' AND t.t0_month<DATE '2026-09-01'
    AND t.credit_change_type='额度增加' AND t.successful_loan_n<=2
    AND t.credit_change_amt>4500
), period AS (
        SELECT group_order, group_kind, group_name,
          COUNT(*)::numeric AS event_n,
          COUNT(DISTINCT user_id)::numeric AS user_n
        FROM membership GROUP BY group_order, group_kind, group_name
      ), monthly AS (
        SELECT group_order, group_kind, group_name, t0_month,
          COUNT(*)::numeric AS n,
          SUM(has_d0_apply)::numeric AS apply_n,
          AVG(has_d0_apply::numeric) AS rate
        FROM membership
        GROUP BY group_order, group_kind, group_name, t0_month
      ), overall_monthly AS (
        SELECT t0_month, COUNT(*)::numeric AS n,
          SUM(has_d0_apply)::numeric AS apply_n,
          AVG(has_d0_apply::numeric) AS rate
        FROM tmp_t0_credit_change_d0_apply
        WHERE t0_month IN (DATE '2026-01-01',DATE '2026-08-01')
        GROUP BY t0_month
      ), paired AS (
        SELECT j.group_order, j.group_kind, j.group_name,
          j.n AS jan_event_n, a.n AS aug_event_n,
          j.rate AS jan_rate, a.rate AS aug_rate,
          j.n/oj.n AS jan_weight, a.n/oa.n AS aug_weight,
          oj.rate AS jan_overall_rate,
          100*(oa.rate-oj.rate) AS overall_change_pp
        FROM monthly j JOIN monthly a USING(group_order,group_kind,group_name)
        CROSS JOIN overall_monthly oj CROSS JOIN overall_monthly oa
        WHERE j.t0_month=DATE '2026-01-01'
          AND a.t0_month=DATE '2026-08-01'
          AND oj.t0_month=DATE '2026-01-01'
          AND oa.t0_month=DATE '2026-08-01'
      ), attributed AS (
        SELECT p.*,
          100*(
            jan_weight*(aug_rate-jan_rate)
            +(aug_weight-jan_weight)*(jan_rate-jan_overall_rate)
            +(aug_weight-jan_weight)*(aug_rate-jan_rate)
          ) AS total_attribution_pp
        FROM paired p
      ), reference AS (
        SELECT total_attribution_pp AS parent_attribution_pp
        FROM attributed WHERE group_order=1
      ), period_total AS (
        SELECT COUNT(*)::numeric AS all_event_n
        FROM tmp_t0_credit_change_d0_apply
        WHERE t0_month>=DATE '2026-01-01' AND t0_month<DATE '2026-09-01'
      ), parent_period AS (
        SELECT event_n AS parent_event_n FROM period WHERE group_order=1
      )
      SELECT p.group_order,p.group_kind,p.group_name,
        p.event_n,p.user_n,a.jan_event_n,a.aug_event_n,
        ROUND(100*a.jan_rate,2) AS jan_rate_pct,
        ROUND(100*a.aug_rate,2) AS aug_rate_pct,
        ROUND(100*(a.aug_rate-a.jan_rate),2) AS rate_change_pp,
        ROUND(a.total_attribution_pp,3) AS total_attribution_pp,
        ROUND(100*p.event_n/t.all_event_n,2) AS all_event_share_pct,
        ROUND(100*a.total_attribution_pp/a.overall_change_pp,2)
          AS overall_decline_share_pct,
        ROUND(100*p.event_n/pp.parent_event_n,2) AS parent_event_share_pct,
        ROUND(100*a.total_attribution_pp/r.parent_attribution_pp,2)
          AS parent_attribution_share_pct,
        ROUND(
          (a.total_attribution_pp/a.overall_change_pp)
          /(p.event_n/t.all_event_n),2
        ) AS concentration_multiple
      FROM period p JOIN attributed a USING(group_order,group_kind,group_name)
      CROSS JOIN reference r CROSS JOIN period_total t CROSS JOIN parent_period pp
      ORDER BY p.group_order;


-- =============================================================================
-- 指标集：large_increase_drilldown_monthly
-- =============================================================================
WITH membership AS (
  SELECT t.*, 1 AS group_order, '层级节点'::text AS group_kind,
    '提额>1200父群'::text AS group_name
  FROM tmp_t0_credit_change_d0_apply t
  WHERE t.t0_month>=DATE '2026-01-01' AND t.t0_month<DATE '2026-09-01'
    AND t.credit_change_type='额度增加' AND t.credit_change_amt>1200
  UNION ALL
  SELECT t.*, 2, '层级节点', '借款≤2次'
  FROM tmp_t0_credit_change_d0_apply t
  WHERE t.t0_month>=DATE '2026-01-01' AND t.t0_month<DATE '2026-09-01'
    AND t.credit_change_type='额度增加' AND t.credit_change_amt>1200
    AND t.successful_loan_n<=2
  UNION ALL
  SELECT t.*, 3, '层级节点', '借款≤2次且提额>2400'
  FROM tmp_t0_credit_change_d0_apply t
  WHERE t.t0_month>=DATE '2026-01-01' AND t.t0_month<DATE '2026-09-01'
    AND t.credit_change_type='额度增加' AND t.credit_change_amt>2400
    AND t.successful_loan_n<=2
  UNION ALL
  SELECT t.*, 4, '层级节点', '三个优先叶子合集'
  FROM tmp_t0_credit_change_d0_apply t
  WHERE t.t0_month>=DATE '2026-01-01' AND t.t0_month<DATE '2026-09-01'
    AND t.credit_change_type='额度增加' AND t.credit_change_amt>1200
    AND t.successful_loan_n<=2
    AND (
      (t.credit_change_amt<=2400 AND t.previous_util_ratio<=0.90)
      OR (t.credit_change_amt>2400 AND t.credit_change_amt<=4500
          AND t.credit_change_rate>1.50)
      OR t.credit_change_amt>4500
    )
  UNION ALL
  SELECT t.*, 5, '目标叶子', 'A｜低幅提额＋低历史使用'
  FROM tmp_t0_credit_change_d0_apply t
  WHERE t.t0_month>=DATE '2026-01-01' AND t.t0_month<DATE '2026-09-01'
    AND t.credit_change_type='额度增加' AND t.credit_change_amt>1200
    AND t.successful_loan_n<=2 AND t.credit_change_amt<=2400
    AND t.previous_util_ratio<=0.90
  UNION ALL
  SELECT t.*, 6, '目标叶子', 'B｜中幅提额＋高提额倍数'
  FROM tmp_t0_credit_change_d0_apply t
  WHERE t.t0_month>=DATE '2026-01-01' AND t.t0_month<DATE '2026-09-01'
    AND t.credit_change_type='额度增加' AND t.successful_loan_n<=2
    AND t.credit_change_amt>2400 AND t.credit_change_amt<=4500
    AND t.credit_change_rate>1.50
  UNION ALL
  SELECT t.*, 7, '目标叶子', 'C｜超大额提额'
  FROM tmp_t0_credit_change_d0_apply t
  WHERE t.t0_month>=DATE '2026-01-01' AND t.t0_month<DATE '2026-09-01'
    AND t.credit_change_type='额度增加' AND t.successful_loan_n<=2
    AND t.credit_change_amt>4500
)
      SELECT TO_CHAR(t0_month,'YYYY-MM') AS t0_month,
        group_order,group_kind,group_name,
        COUNT(*) AS event_n,COUNT(DISTINCT user_id) AS user_n,
        SUM(has_d0_apply) AS d0_apply_n,
        ROUND(100.0*AVG(has_d0_apply::numeric),2) AS d0_apply_rate_pct
      FROM membership
      GROUP BY t0_month,group_order,group_kind,group_name
      ORDER BY group_order,t0_month;


-- =============================================================================
-- 指标集：decrease_drilldown_summary
-- =============================================================================
WITH membership AS (
  SELECT t.*, 1 AS group_order, '层级节点'::text AS group_kind,
    '全部降额父群'::text AS group_name
  FROM tmp_t0_credit_change_d0_apply t
  WHERE t.t0_month>=DATE '2026-01-01' AND t.t0_month<DATE '2026-09-01'
    AND t.credit_change_type='额度降低'
  UNION ALL
  SELECT t.*, 2, '层级节点', '降额金额≤1000'
  FROM tmp_t0_credit_change_d0_apply t
  WHERE t.t0_month>=DATE '2026-01-01' AND t.t0_month<DATE '2026-09-01'
    AND t.credit_change_type='额度降低'
    AND ABS(t.credit_change_amt)<=1000
  UNION ALL
  SELECT t.*, 3, '层级节点', '降额≤1000且降额比例≤20%'
  FROM tmp_t0_credit_change_d0_apply t
  WHERE t.t0_month>=DATE '2026-01-01' AND t.t0_month<DATE '2026-09-01'
    AND t.credit_change_type='额度降低'
    AND ABS(t.credit_change_amt)<=1000 AND ABS(t.credit_change_rate)<=0.20
  UNION ALL
  SELECT t.*, 4, '层级节点', '三个高归因叶子合集'
  FROM tmp_t0_credit_change_d0_apply t
  WHERE t.t0_month>=DATE '2026-01-01' AND t.t0_month<DATE '2026-09-01'
    AND t.credit_change_type='额度降低'
    AND ABS(t.credit_change_amt)<=1000
    AND (
      (ABS(t.credit_change_rate)<=0.08 AND t.successful_loan_n<=4)
      OR (ABS(t.credit_change_rate)>0.08 AND ABS(t.credit_change_rate)<=0.12
          AND t.successful_loan_n<=4)
      OR (ABS(t.credit_change_rate)>0.12 AND ABS(t.credit_change_rate)<=0.20
          AND t.successful_loan_n<=2)
    )
  UNION ALL
  SELECT t.*, 5, '目标叶子', 'A｜降额比例≤8%＋借款≤4次'
  FROM tmp_t0_credit_change_d0_apply t
  WHERE t.t0_month>=DATE '2026-01-01' AND t.t0_month<DATE '2026-09-01'
    AND t.credit_change_type='额度降低'
    AND ABS(t.credit_change_amt)<=1000 AND ABS(t.credit_change_rate)<=0.08
    AND t.successful_loan_n<=4
  UNION ALL
  SELECT t.*, 6, '目标叶子', 'B｜降额比例8%—12%＋借款≤4次'
  FROM tmp_t0_credit_change_d0_apply t
  WHERE t.t0_month>=DATE '2026-01-01' AND t.t0_month<DATE '2026-09-01'
    AND t.credit_change_type='额度降低'
    AND ABS(t.credit_change_amt)<=1000
    AND ABS(t.credit_change_rate)>0.08 AND ABS(t.credit_change_rate)<=0.12
    AND t.successful_loan_n<=4
  UNION ALL
  SELECT t.*, 7, '目标叶子', 'C｜降额比例12%—20%＋借款≤2次'
  FROM tmp_t0_credit_change_d0_apply t
  WHERE t.t0_month>=DATE '2026-01-01' AND t.t0_month<DATE '2026-09-01'
    AND t.credit_change_type='额度降低'
    AND ABS(t.credit_change_amt)<=1000
    AND ABS(t.credit_change_rate)>0.12 AND ABS(t.credit_change_rate)<=0.20
    AND t.successful_loan_n<=2
), period AS (
        SELECT group_order, group_kind, group_name,
          COUNT(*)::numeric AS event_n,
          COUNT(DISTINCT user_id)::numeric AS user_n
        FROM membership GROUP BY group_order, group_kind, group_name
      ), monthly AS (
        SELECT group_order, group_kind, group_name, t0_month,
          COUNT(*)::numeric AS n,
          SUM(has_d0_apply)::numeric AS apply_n,
          AVG(has_d0_apply::numeric) AS rate
        FROM membership
        GROUP BY group_order, group_kind, group_name, t0_month
      ), overall_monthly AS (
        SELECT t0_month, COUNT(*)::numeric AS n,
          SUM(has_d0_apply)::numeric AS apply_n,
          AVG(has_d0_apply::numeric) AS rate
        FROM tmp_t0_credit_change_d0_apply
        WHERE t0_month IN (DATE '2026-01-01',DATE '2026-08-01')
        GROUP BY t0_month
      ), paired AS (
        SELECT j.group_order, j.group_kind, j.group_name,
          j.n AS jan_event_n, a.n AS aug_event_n,
          j.rate AS jan_rate, a.rate AS aug_rate,
          j.n/oj.n AS jan_weight, a.n/oa.n AS aug_weight,
          oj.rate AS jan_overall_rate,
          100*(oa.rate-oj.rate) AS overall_change_pp
        FROM monthly j JOIN monthly a USING(group_order,group_kind,group_name)
        CROSS JOIN overall_monthly oj CROSS JOIN overall_monthly oa
        WHERE j.t0_month=DATE '2026-01-01'
          AND a.t0_month=DATE '2026-08-01'
          AND oj.t0_month=DATE '2026-01-01'
          AND oa.t0_month=DATE '2026-08-01'
      ), attributed AS (
        SELECT p.*,
          100*(
            jan_weight*(aug_rate-jan_rate)
            +(aug_weight-jan_weight)*(jan_rate-jan_overall_rate)
            +(aug_weight-jan_weight)*(aug_rate-jan_rate)
          ) AS total_attribution_pp
        FROM paired p
      ), reference AS (
        SELECT total_attribution_pp AS parent_attribution_pp
        FROM attributed WHERE group_order=1
      ), ratio_reference AS (
        SELECT total_attribution_pp AS ratio_parent_attribution_pp
        FROM attributed WHERE group_order=3
      ), period_total AS (
        SELECT COUNT(*)::numeric AS all_event_n
        FROM tmp_t0_credit_change_d0_apply
        WHERE t0_month>=DATE '2026-01-01' AND t0_month<DATE '2026-09-01'
      ), parent_period AS (
        SELECT event_n AS parent_event_n FROM period WHERE group_order=1
      ), ratio_parent_period AS (
        SELECT event_n AS ratio_parent_event_n FROM period WHERE group_order=3
      )
      SELECT p.group_order,p.group_kind,p.group_name,
        p.event_n,p.user_n,a.jan_event_n,a.aug_event_n,
        ROUND(100*a.jan_rate,2) AS jan_rate_pct,
        ROUND(100*a.aug_rate,2) AS aug_rate_pct,
        ROUND(100*(a.aug_rate-a.jan_rate),2) AS rate_change_pp,
        ROUND(a.total_attribution_pp,3) AS total_attribution_pp,
        ROUND(100*p.event_n/t.all_event_n,2) AS all_event_share_pct,
        ROUND(100*a.total_attribution_pp/a.overall_change_pp,2)
          AS overall_decline_share_pct,
        ROUND(100*p.event_n/pp.parent_event_n,2) AS parent_event_share_pct,
        ROUND(100*a.total_attribution_pp/r.parent_attribution_pp,2)
          AS parent_attribution_share_pct,
        CASE WHEN p.group_order>=4 THEN
          ROUND(100*p.event_n/rpp.ratio_parent_event_n,2) END
          AS ratio_parent_event_share_pct,
        CASE WHEN p.group_order>=4 THEN
          ROUND(100*a.total_attribution_pp/rr.ratio_parent_attribution_pp,2) END
          AS ratio_parent_attribution_share_pct,
        ROUND(
          (a.total_attribution_pp/a.overall_change_pp)
          /(p.event_n/t.all_event_n),2
        ) AS concentration_multiple
      FROM period p JOIN attributed a USING(group_order,group_kind,group_name)
      CROSS JOIN reference r CROSS JOIN ratio_reference rr
      CROSS JOIN period_total t CROSS JOIN parent_period pp
      CROSS JOIN ratio_parent_period rpp
      ORDER BY p.group_order;


-- =============================================================================
-- 指标集：decrease_drilldown_monthly
-- =============================================================================
WITH membership AS (
  SELECT t.*, 1 AS group_order, '层级节点'::text AS group_kind,
    '全部降额父群'::text AS group_name
  FROM tmp_t0_credit_change_d0_apply t
  WHERE t.t0_month>=DATE '2026-01-01' AND t.t0_month<DATE '2026-09-01'
    AND t.credit_change_type='额度降低'
  UNION ALL
  SELECT t.*, 2, '层级节点', '降额金额≤1000'
  FROM tmp_t0_credit_change_d0_apply t
  WHERE t.t0_month>=DATE '2026-01-01' AND t.t0_month<DATE '2026-09-01'
    AND t.credit_change_type='额度降低'
    AND ABS(t.credit_change_amt)<=1000
  UNION ALL
  SELECT t.*, 3, '层级节点', '降额≤1000且降额比例≤20%'
  FROM tmp_t0_credit_change_d0_apply t
  WHERE t.t0_month>=DATE '2026-01-01' AND t.t0_month<DATE '2026-09-01'
    AND t.credit_change_type='额度降低'
    AND ABS(t.credit_change_amt)<=1000 AND ABS(t.credit_change_rate)<=0.20
  UNION ALL
  SELECT t.*, 4, '层级节点', '三个高归因叶子合集'
  FROM tmp_t0_credit_change_d0_apply t
  WHERE t.t0_month>=DATE '2026-01-01' AND t.t0_month<DATE '2026-09-01'
    AND t.credit_change_type='额度降低'
    AND ABS(t.credit_change_amt)<=1000
    AND (
      (ABS(t.credit_change_rate)<=0.08 AND t.successful_loan_n<=4)
      OR (ABS(t.credit_change_rate)>0.08 AND ABS(t.credit_change_rate)<=0.12
          AND t.successful_loan_n<=4)
      OR (ABS(t.credit_change_rate)>0.12 AND ABS(t.credit_change_rate)<=0.20
          AND t.successful_loan_n<=2)
    )
  UNION ALL
  SELECT t.*, 5, '目标叶子', 'A｜降额比例≤8%＋借款≤4次'
  FROM tmp_t0_credit_change_d0_apply t
  WHERE t.t0_month>=DATE '2026-01-01' AND t.t0_month<DATE '2026-09-01'
    AND t.credit_change_type='额度降低'
    AND ABS(t.credit_change_amt)<=1000 AND ABS(t.credit_change_rate)<=0.08
    AND t.successful_loan_n<=4
  UNION ALL
  SELECT t.*, 6, '目标叶子', 'B｜降额比例8%—12%＋借款≤4次'
  FROM tmp_t0_credit_change_d0_apply t
  WHERE t.t0_month>=DATE '2026-01-01' AND t.t0_month<DATE '2026-09-01'
    AND t.credit_change_type='额度降低'
    AND ABS(t.credit_change_amt)<=1000
    AND ABS(t.credit_change_rate)>0.08 AND ABS(t.credit_change_rate)<=0.12
    AND t.successful_loan_n<=4
  UNION ALL
  SELECT t.*, 7, '目标叶子', 'C｜降额比例12%—20%＋借款≤2次'
  FROM tmp_t0_credit_change_d0_apply t
  WHERE t.t0_month>=DATE '2026-01-01' AND t.t0_month<DATE '2026-09-01'
    AND t.credit_change_type='额度降低'
    AND ABS(t.credit_change_amt)<=1000
    AND ABS(t.credit_change_rate)>0.12 AND ABS(t.credit_change_rate)<=0.20
    AND t.successful_loan_n<=2
)
      SELECT TO_CHAR(t0_month,'YYYY-MM') AS t0_month,
        group_order,group_kind,group_name,
        COUNT(*) AS event_n,COUNT(DISTINCT user_id) AS user_n,
        SUM(has_d0_apply) AS d0_apply_n,
        ROUND(100.0*AVG(has_d0_apply::numeric),2) AS d0_apply_rate_pct
      FROM membership
      GROUP BY t0_month,group_order,group_kind,group_name
      ORDER BY group_order,t0_month;


-- =============================================================================
-- 指标集：rate_bucket_overall
-- =============================================================================
SELECT change_rate_bucket, 
  COUNT(*) AS event_n,
  COUNT(DISTINCT user_id) AS user_n,
  SUM(has_d0_apply) AS d0_apply_n,
  ROUND(100.0 * SUM(has_d0_apply) / NULLIF(COUNT(*), 0), 2)
    AS d0_apply_rate_pct,
  ROUND(AVG(previous_credit_amt), 2) AS avg_previous_credit_amt,
  ROUND(AVG(current_credit_amt), 2) AS avg_current_credit_amt,
  ROUND(AVG(credit_change_amt), 2) AS avg_credit_change_amt,
  ROUND(100.0 * AVG(credit_change_rate), 2) AS avg_credit_change_rate_pct,
  ROUND(100.0 * SUM(previous_remit_amt) / NULLIF(SUM(previous_credit_amt), 0), 2)
    AS previous_utilization_rate_pct,
  ROUND(AVG(CASE WHEN has_d0_apply=1 THEN minutes_to_apply END), 2)
    AS avg_minutes_to_apply
,
        ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS event_share_pct
      FROM tmp_t0_credit_change_d0_apply
      GROUP BY change_rate_bucket
      ORDER BY MIN(credit_change_rate);


-- =============================================================================
-- 指标集：transition_overall
-- =============================================================================
SELECT previous_credit_amt, current_credit_amt, credit_change_type,
        previous_credit_amt::text || '→' || current_credit_amt::text AS transition_label,
        
  COUNT(*) AS event_n,
  COUNT(DISTINCT user_id) AS user_n,
  SUM(has_d0_apply) AS d0_apply_n,
  ROUND(100.0 * SUM(has_d0_apply) / NULLIF(COUNT(*), 0), 2)
    AS d0_apply_rate_pct,
  ROUND(AVG(previous_credit_amt), 2) AS avg_previous_credit_amt,
  ROUND(AVG(current_credit_amt), 2) AS avg_current_credit_amt,
  ROUND(AVG(credit_change_amt), 2) AS avg_credit_change_amt,
  ROUND(100.0 * AVG(credit_change_rate), 2) AS avg_credit_change_rate_pct,
  ROUND(100.0 * SUM(previous_remit_amt) / NULLIF(SUM(previous_credit_amt), 0), 2)
    AS previous_utilization_rate_pct,
  ROUND(AVG(CASE WHEN has_d0_apply=1 THEN minutes_to_apply END), 2)
    AS avg_minutes_to_apply
,
        ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS event_share_pct
      FROM tmp_t0_credit_change_d0_apply
      GROUP BY previous_credit_amt, current_credit_amt, credit_change_type
      HAVING COUNT(*) >= 20
      ORDER BY event_n DESC, previous_credit_amt, current_credit_amt;


-- =============================================================================
-- 指标集：monthly_transition
-- =============================================================================
WITH retained AS (
        SELECT previous_credit_amt, current_credit_amt, credit_change_type
        FROM tmp_t0_credit_change_d0_apply
        GROUP BY previous_credit_amt, current_credit_amt, credit_change_type
        HAVING COUNT(*) >= 100
      )
      SELECT TO_CHAR(t.t0_month, 'YYYY-MM') AS t0_month,
        previous_credit_amt, current_credit_amt, credit_change_type,
        previous_credit_amt::text || '→' || current_credit_amt::text AS transition_label,
        
  COUNT(*) AS event_n,
  COUNT(DISTINCT user_id) AS user_n,
  SUM(has_d0_apply) AS d0_apply_n,
  ROUND(100.0 * SUM(has_d0_apply) / NULLIF(COUNT(*), 0), 2)
    AS d0_apply_rate_pct,
  ROUND(AVG(previous_credit_amt), 2) AS avg_previous_credit_amt,
  ROUND(AVG(current_credit_amt), 2) AS avg_current_credit_amt,
  ROUND(AVG(credit_change_amt), 2) AS avg_credit_change_amt,
  ROUND(100.0 * AVG(credit_change_rate), 2) AS avg_credit_change_rate_pct,
  ROUND(100.0 * SUM(previous_remit_amt) / NULLIF(SUM(previous_credit_amt), 0), 2)
    AS previous_utilization_rate_pct,
  ROUND(AVG(CASE WHEN has_d0_apply=1 THEN minutes_to_apply END), 2)
    AS avg_minutes_to_apply
,
        ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY t0_month), 2)
          AS event_share_pct,
        ROUND(100.0 * SUM(has_d0_apply) / SUM(COUNT(*)) OVER (PARTITION BY t0_month), 2)
          AS contribution_to_overall_rate_pp
      FROM tmp_t0_credit_change_d0_apply t
      JOIN retained r USING(previous_credit_amt,current_credit_amt,credit_change_type)
      GROUP BY t0_month, previous_credit_amt, current_credit_amt, credit_change_type
      ORDER BY t0_month, event_n DESC, previous_credit_amt, current_credit_amt;


-- =============================================================================
-- 指标集：direction_contribution_vs_jan
-- =============================================================================
WITH monthly AS (
        SELECT t0_month, credit_change_type,
          COUNT(*)::numeric AS n,
          SUM(has_d0_apply)::numeric AS apply_n,
          SUM(has_d0_apply)::numeric / NULLIF(COUNT(*),0) AS rate
        FROM tmp_t0_credit_change_d0_apply
        GROUP BY t0_month, credit_change_type
      ), total AS (
        SELECT t0_month, SUM(n) AS total_n,
          SUM(apply_n)/NULLIF(SUM(n),0) AS overall_rate
        FROM monthly GROUP BY t0_month
      ), m AS (
        SELECT x.*, x.n/t.total_n AS weight, t.overall_rate
        FROM monthly x JOIN total t USING (t0_month)
      ), jan AS (
        SELECT * FROM m WHERE t0_month=DATE '2026-01-01'
      ), months AS (
        SELECT DISTINCT t0_month FROM m
      ), types AS (
        SELECT DISTINCT credit_change_type FROM m
      ), grid AS (
        SELECT mo.t0_month, ty.credit_change_type FROM months mo CROSS JOIN types ty
      ), paired AS (
        SELECT g.t0_month, g.credit_change_type,
          COALESCE(j.n,0) AS jan_n, COALESCE(c.n,0) AS current_n,
          COALESCE(j.weight,0) AS jan_weight, COALESCE(c.weight,0) AS current_weight,
          COALESCE(j.rate,c.rate,0) AS jan_rate,
          COALESCE(c.rate,j.rate,0) AS current_rate,
          j.overall_rate AS jan_overall_rate
        FROM grid g
        LEFT JOIN jan j USING (credit_change_type)
        LEFT JOIN m c ON c.t0_month=g.t0_month AND c.credit_change_type=g.credit_change_type
      )
      SELECT TO_CHAR(t0_month,'YYYY-MM') AS t0_month, credit_change_type,
        jan_n, current_n,
        ROUND(100*jan_weight,2) AS jan_share_pct,
        ROUND(100*current_weight,2) AS current_share_pct,
        ROUND(100*jan_rate,2) AS jan_rate_pct,
        ROUND(100*current_rate,2) AS current_rate_pct,
        ROUND(100*jan_weight*(current_rate-jan_rate),2)
          AS base_within_effect_pp,
        ROUND(100*(current_weight-jan_weight)*(jan_rate-jan_overall_rate),2)
          AS structure_effect_pp,
        ROUND(100*(current_weight-jan_weight)*(current_rate-jan_rate),2)
          AS interaction_effect_pp,
        ROUND(100*current_weight*(current_rate-jan_rate),2)
          AS result_within_effect_pp,
        ROUND(100*(
          jan_weight*(current_rate-jan_rate)
          +(current_weight-jan_weight)*(jan_rate-jan_overall_rate)
          +(current_weight-jan_weight)*(current_rate-jan_rate)
        ),2) AS total_attribution_pp,
        ROUND(100*(current_weight*current_rate-jan_weight*jan_rate),2)
          AS direct_weighted_change_pp
      FROM paired
      ORDER BY t0_month,
        CASE credit_change_type WHEN '额度降低' THEN 1 WHEN '额度不变' THEN 2 ELSE 3 END;


-- =============================================================================
-- 指标集：transition_contribution_vs_jan
-- =============================================================================
WITH monthly AS (
        SELECT t0_month, previous_credit_amt, current_credit_amt, credit_change_type,
          COUNT(*)::numeric AS n,
          SUM(has_d0_apply)::numeric / NULLIF(COUNT(*),0) AS rate
        FROM tmp_t0_credit_change_d0_apply
        GROUP BY t0_month, previous_credit_amt, current_credit_amt, credit_change_type
      ), retained AS (
        SELECT previous_credit_amt,current_credit_amt,credit_change_type
        FROM monthly
        GROUP BY previous_credit_amt,current_credit_amt,credit_change_type
        HAVING SUM(n) >= 100
      ), total AS (
        SELECT t0_month, SUM(n) AS total_n,
          SUM(n*rate)/NULLIF(SUM(n),0) AS overall_rate
        FROM monthly GROUP BY t0_month
      ), m AS (
        SELECT x.*, x.n/t.total_n AS weight, t.overall_rate
        FROM monthly x JOIN total t USING (t0_month)
        JOIN retained r USING(previous_credit_amt,current_credit_amt,credit_change_type)
      ), jan AS (
        SELECT * FROM m WHERE t0_month=DATE '2026-01-01'
      ), months AS (
        SELECT DISTINCT t0_month FROM m
      ), paths AS (
        SELECT DISTINCT previous_credit_amt, current_credit_amt, credit_change_type FROM m
      ), grid AS (
        SELECT mo.t0_month, p.* FROM months mo CROSS JOIN paths p
      ), paired AS (
        SELECT g.*,
          COALESCE(j.n,0) AS jan_n, COALESCE(c.n,0) AS current_n,
          COALESCE(j.weight,0) AS jan_weight, COALESCE(c.weight,0) AS current_weight,
          COALESCE(j.rate,c.rate,0) AS jan_rate,
          COALESCE(c.rate,j.rate,0) AS current_rate,
          (SELECT overall_rate FROM total WHERE t0_month=DATE '2026-01-01')
            AS jan_overall_rate
        FROM grid g
        LEFT JOIN jan j USING (previous_credit_amt,current_credit_amt,credit_change_type)
        LEFT JOIN m c ON c.t0_month=g.t0_month
          AND c.previous_credit_amt=g.previous_credit_amt
          AND c.current_credit_amt=g.current_credit_amt
          AND c.credit_change_type=g.credit_change_type
      )
      SELECT TO_CHAR(t0_month,'YYYY-MM') AS t0_month,
        previous_credit_amt, current_credit_amt, credit_change_type,
        previous_credit_amt::text || '→' || current_credit_amt::text AS transition_label,
        jan_n, current_n,
        ROUND(100*jan_weight,2) AS jan_share_pct,
        ROUND(100*current_weight,2) AS current_share_pct,
        ROUND(100*jan_rate,2) AS jan_rate_pct,
        ROUND(100*current_rate,2) AS current_rate_pct,
        ROUND(100*jan_weight*(current_rate-jan_rate),3)
          AS base_within_effect_pp,
        ROUND(100*(current_weight-jan_weight)*(jan_rate-jan_overall_rate),3)
          AS structure_effect_pp,
        ROUND(100*(current_weight-jan_weight)*(current_rate-jan_rate),3)
          AS interaction_effect_pp,
        ROUND(100*current_weight*(current_rate-jan_rate),3)
          AS result_within_effect_pp,
        ROUND(100*(
          jan_weight*(current_rate-jan_rate)
          +(current_weight-jan_weight)*(jan_rate-jan_overall_rate)
          +(current_weight-jan_weight)*(current_rate-jan_rate)
        ),3) AS total_attribution_pp,
        ROUND(100*(current_weight*current_rate-jan_weight*jan_rate),3)
          AS direct_weighted_change_pp
      FROM paired
      ORDER BY t0_month, total_attribution_pp, current_n DESC;


-- =============================================================================
-- 指标集：transition_diagnostics
-- =============================================================================
WITH monthly AS (
        SELECT t0_month, previous_credit_amt, current_credit_amt, credit_change_type,
          COUNT(*) AS event_n,
          100.0*SUM(has_d0_apply)/NULLIF(COUNT(*),0) AS rate_pct
        FROM tmp_t0_credit_change_d0_apply
        GROUP BY t0_month, previous_credit_amt, current_credit_amt, credit_change_type
      ), total AS (
        SELECT previous_credit_amt, current_credit_amt, credit_change_type,
          COUNT(*) AS total_event_n,
          COUNT(DISTINCT user_id) AS total_user_n,
          100.0*SUM(has_d0_apply)/NULLIF(COUNT(*),0) AS overall_rate_pct
        FROM tmp_t0_credit_change_d0_apply
        GROUP BY previous_credit_amt, current_credit_amt, credit_change_type
        HAVING COUNT(*) >= 100
      ), contribution AS (
        WITH monthly2 AS (
          SELECT t0_month, previous_credit_amt, current_credit_amt, credit_change_type,
            COUNT(*)::numeric AS n,
            SUM(has_d0_apply)::numeric/NULLIF(COUNT(*),0) AS rate
          FROM tmp_t0_credit_change_d0_apply
          GROUP BY t0_month, previous_credit_amt, current_credit_amt, credit_change_type
        ), retained2 AS (
          SELECT previous_credit_amt,current_credit_amt,credit_change_type
          FROM monthly2 GROUP BY previous_credit_amt,current_credit_amt,credit_change_type
          HAVING SUM(n) >= 100
        ), mt AS (
          SELECT t0_month,SUM(n) AS total_n FROM monthly2 GROUP BY t0_month
        ), m AS (
          SELECT x.*,x.n/mt.total_n AS weight FROM monthly2 x JOIN mt USING(t0_month)
          JOIN retained2 r USING(previous_credit_amt,current_credit_amt,credit_change_type)
        ), jan AS (SELECT * FROM m WHERE t0_month=DATE '2026-01-01')
        SELECT c.previous_credit_amt,c.current_credit_amt,c.credit_change_type,
          100*(c.weight*c.rate-COALESCE(j.weight,0)*COALESCE(j.rate,c.rate)) AS sep_contribution_pp
        FROM m c LEFT JOIN jan j USING(previous_credit_amt,current_credit_amt,credit_change_type)
        WHERE c.t0_month=DATE '2026-09-01'
      )
      SELECT t.*,
        t.previous_credit_amt::text || '→' || t.current_credit_amt::text AS transition_label,
        ROUND(t.overall_rate_pct,2) AS overall_rate_pct,
        COALESCE(MAX(CASE WHEN m.t0_month=DATE '2026-01-01' THEN m.event_n END),0) AS jan_event_n,
        COALESCE(MAX(CASE WHEN m.t0_month=DATE '2026-09-01' THEN m.event_n END),0) AS sep_event_n,
        ROUND(MAX(CASE WHEN m.t0_month=DATE '2026-01-01' THEN m.rate_pct END),2) AS jan_rate_pct,
        ROUND(MAX(CASE WHEN m.t0_month=DATE '2026-09-01' THEN m.rate_pct END),2) AS sep_rate_pct,
        ROUND(MAX(CASE WHEN m.t0_month=DATE '2026-09-01' THEN m.rate_pct END)
             - MAX(CASE WHEN m.t0_month=DATE '2026-01-01' THEN m.rate_pct END),2)
          AS sep_vs_jan_change_pp,
        COUNT(*) AS observed_month_n,
        SUM(CASE WHEN m.event_n>=50 THEN 1 ELSE 0 END) AS month_n_ge50,
        ROUND(MIN(CASE WHEN m.event_n>=50 THEN m.rate_pct END),2) AS min_rate_pct_ge50,
        ROUND(MAX(CASE WHEN m.event_n>=50 THEN m.rate_pct END),2) AS max_rate_pct_ge50,
        ROUND(COALESCE(c.sep_contribution_pp,0),3) AS sep_contribution_change_pp
      FROM total t
      LEFT JOIN monthly m USING(previous_credit_amt,current_credit_amt,credit_change_type)
      LEFT JOIN contribution c USING(previous_credit_amt,current_credit_amt,credit_change_type)
      GROUP BY t.previous_credit_amt,t.current_credit_amt,t.credit_change_type,
        t.total_event_n,t.total_user_n,t.overall_rate_pct,c.sep_contribution_pp
      ORDER BY t.total_event_n DESC;


-- =============================================================================
-- 指标集：standardized_direction_overall
-- =============================================================================
WITH expanded AS (
        SELECT e.*,
          CASE WHEN previous_credit_amt < 500 THEN '<500'
               WHEN previous_credit_amt < 1000 THEN '500-999'
               WHEN previous_credit_amt < 2000 THEN '1000-1999'
               WHEN previous_credit_amt < 3000 THEN '2000-2999'
               WHEN previous_credit_amt < 5000 THEN '3000-4999'
               ELSE '5000及以上' END AS previous_credit_band
        FROM tmp_t0_credit_change_d0_apply e
      ), cell AS (
        SELECT t0_month, previous_credit_band, loan_count_bucket, previous_util_band,
          credit_change_type, COUNT(*) AS n, AVG(has_d0_apply::numeric) AS rate
        FROM expanded
        GROUP BY t0_month, previous_credit_band, loan_count_bucket,
          previous_util_band, credit_change_type
      ), common AS (
        SELECT t0_month, previous_credit_band, loan_count_bucket, previous_util_band
        FROM cell
        GROUP BY t0_month, previous_credit_band, loan_count_bucket, previous_util_band
        HAVING COUNT(DISTINCT credit_change_type)=3 AND MIN(n)>=20
      ), supported AS (
        SELECT c.* FROM cell c JOIN common s USING
          (t0_month,previous_credit_band,loan_count_bucket,previous_util_band)
      ), weights AS (
        SELECT t0_month,previous_credit_band,loan_count_bucket,previous_util_band,
          SUM(n)::numeric / SUM(SUM(n)) OVER () AS ref_weight
        FROM supported
        GROUP BY t0_month,previous_credit_band,loan_count_bucket,previous_util_band
      ), coverage AS (
        SELECT COUNT(*) AS all_n,
          SUM(CASE WHEN c.t0_month IS NOT NULL THEN 1 ELSE 0 END) AS supported_n
        FROM expanded e
        LEFT JOIN common c USING(t0_month,previous_credit_band,loan_count_bucket,previous_util_band)
      )
      SELECT s.credit_change_type,
        SUM(s.n) AS supported_event_n,
        ROUND(100*SUM(w.ref_weight*s.rate),2) AS standardized_d0_apply_rate_pct,
        ROUND(100.0*MAX(c.supported_n)/MAX(c.all_n),2) AS common_support_coverage_pct
      FROM supported s
      JOIN weights w USING(t0_month,previous_credit_band,loan_count_bucket,previous_util_band)
      CROSS JOIN coverage c
      GROUP BY s.credit_change_type
      ORDER BY CASE s.credit_change_type WHEN '额度降低' THEN 1 WHEN '额度不变' THEN 2 ELSE 3 END;


-- =============================================================================
-- 指标集：standardized_direction_monthly
-- =============================================================================
WITH expanded AS (
        SELECT e.*,
          CASE WHEN previous_credit_amt < 500 THEN '<500'
               WHEN previous_credit_amt < 1000 THEN '500-999'
               WHEN previous_credit_amt < 2000 THEN '1000-1999'
               WHEN previous_credit_amt < 3000 THEN '2000-2999'
               WHEN previous_credit_amt < 5000 THEN '3000-4999'
               ELSE '5000及以上' END AS previous_credit_band
        FROM tmp_t0_credit_change_d0_apply e
      ), cell AS (
        SELECT t0_month, previous_credit_band, loan_count_bucket, previous_util_band,
          credit_change_type, COUNT(*) AS n, AVG(has_d0_apply::numeric) AS rate
        FROM expanded
        GROUP BY t0_month, previous_credit_band, loan_count_bucket,
          previous_util_band, credit_change_type
      ), common AS (
        SELECT t0_month, previous_credit_band, loan_count_bucket, previous_util_band
        FROM cell
        GROUP BY t0_month, previous_credit_band, loan_count_bucket, previous_util_band
        HAVING COUNT(DISTINCT credit_change_type)=3 AND MIN(n)>=20
      ), supported AS (
        SELECT c.* FROM cell c JOIN common s USING
          (t0_month,previous_credit_band,loan_count_bucket,previous_util_band)
      ), weights AS (
        SELECT t0_month,previous_credit_band,loan_count_bucket,previous_util_band,
          SUM(n)::numeric / SUM(SUM(n)) OVER (PARTITION BY t0_month) AS ref_weight
        FROM supported
        GROUP BY t0_month,previous_credit_band,loan_count_bucket,previous_util_band
      ), total AS (
        SELECT t0_month,COUNT(*) AS all_n FROM expanded GROUP BY t0_month
      ), supported_total AS (
        SELECT e.t0_month,COUNT(*) AS supported_n
        FROM expanded e JOIN common c USING
          (t0_month,previous_credit_band,loan_count_bucket,previous_util_band)
        GROUP BY e.t0_month
      )
      SELECT TO_CHAR(s.t0_month,'YYYY-MM') AS t0_month,s.credit_change_type,
        SUM(s.n) AS supported_event_n,
        ROUND(100*SUM(w.ref_weight*s.rate),2) AS standardized_d0_apply_rate_pct,
        ROUND(100.0*MAX(st.supported_n)/MAX(t.all_n),2) AS common_support_coverage_pct
      FROM supported s
      JOIN weights w USING(t0_month,previous_credit_band,loan_count_bucket,previous_util_band)
      JOIN total t USING(t0_month) JOIN supported_total st USING(t0_month)
      GROUP BY s.t0_month,s.credit_change_type
      ORDER BY s.t0_month,
        CASE s.credit_change_type WHEN '额度降低' THEN 1 WHEN '额度不变' THEN 2 ELSE 3 END;
