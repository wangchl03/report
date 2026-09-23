-- =============================================================================
-- 2026-01~08 降额 T0：D+1~D+5 放款订单 × 额度使用率档 × 结清时借款次数
-- 单位：每次 T0 后 D+1~D+5 内最早一笔成功放款订单；同月多次 T0 分别保留。
-- =============================================================================
SET search_path TO wangchuanliang, public;
SET statement_timeout = 0;
DROP TABLE IF EXISTS tmp_t0_down_util_loan_profit;
CREATE TEMP TABLE tmp_t0_down_util_loan_profit AS
WITH params AS (
    SELECT DATE '2026-01-01' AS start_date, DATE '2026-09-01' AS end_date
), raw_offer AS (
    SELECT DISTINCT ON (v.user_id, v.serial_id)
        v.user_id, v.serial_id, v.vir_date::date AS vir_date,
        TO_TIMESTAMP(v.vir_unix) AS vir_time, v.max_credit_apply_amt
    FROM wangchuanliang.order_vir_f_copy v
    JOIN wangchuanliang.side_recycle_type_copy r ON r.serial_id = v.serial_id
    CROSS JOIN params p
    WHERE v.is_pass1 = 1
      AND v.loan_type_code = 2
      AND r.recycle_type = 3
      AND v.vir_date >= p.start_date - 1
      AND v.vir_date < p.end_date
    ORDER BY v.user_id, v.serial_id, v.vir_unix DESC
), lagged AS (
    SELECT r.*, LAG(r.vir_time) OVER (PARTITION BY r.user_id ORDER BY r.vir_time, r.serial_id) AS prev_vir_time
    FROM raw_offer r
), batched AS (
    SELECT l.*,
      SUM(CASE WHEN l.prev_vir_time IS NULL OR l.vir_time-l.prev_vir_time > INTERVAL '20 seconds' THEN 1 ELSE 0 END)
        OVER (PARTITION BY l.user_id ORDER BY l.vir_time,l.serial_id ROWS UNBOUNDED PRECEDING) AS batch_id
    FROM lagged l
), dedup_offer AS (
    SELECT user_id, serial_id, vir_date, vir_time, max_credit_apply_amt
    FROM (
      SELECT b.*, ROW_NUMBER() OVER (PARTITION BY b.user_id,b.batch_id ORDER BY b.vir_time DESC,b.serial_id DESC) AS batch_rn
      FROM batched b
    ) x CROSS JOIN params p
    WHERE batch_rn=1 AND vir_date>=p.start_date AND vir_date<p.end_date
), candidate_users AS (
    SELECT DISTINCT user_id FROM dedup_offer
), all_orders AS (
    SELECT o.user_id,o.serial_id,o.apply_time,o.repaid_time,o.repaid_date::date AS repaid_date,
           o.loan_status_code,o.is_remit,o.is_repaid
    FROM wangchuanliang.order_loan_f_v2_copy o
    JOIN candidate_users u ON u.user_id=o.user_id
), clean_settlement AS (
    SELECT o.user_id,o.serial_id,o.repaid_time,o.repaid_date
    FROM all_orders o
    WHERE o.is_remit=1
      AND (o.is_repaid=1 OR o.loan_status_code=7)
      AND o.repaid_time>TIMESTAMP '2000-01-01 00:00:00'
      AND NOT EXISTS (
        SELECT 1 FROM all_orders x
        WHERE x.user_id=o.user_id AND x.serial_id<>o.serial_id AND x.apply_time<o.repaid_time
          AND (x.loan_status_code IN (5,8) OR (x.loan_status_code=7 AND x.repaid_time>o.repaid_time))
      )
), paired AS (
    SELECT e.user_id,e.serial_id AS credit_serial_id,e.vir_date,e.vir_time,e.max_credit_apply_amt,s.repaid_time,
      ROW_NUMBER() OVER (PARTITION BY e.user_id,e.vir_date,e.serial_id ORDER BY s.repaid_time DESC,s.serial_id DESC) AS s_rn
    FROM dedup_offer e
    JOIN clean_settlement s ON s.user_id=e.user_id AND s.repaid_date=e.vir_date AND e.vir_time>=s.repaid_time
), t0_origin AS (
    SELECT user_id,credit_serial_id,vir_date,vir_time,repaid_time,max_credit_apply_amt AS this_amt
    FROM (
      SELECT p.*, ROW_NUMBER() OVER (PARTITION BY p.user_id,p.vir_date ORDER BY p.vir_time,p.credit_serial_id DESC) AS day_rn
      FROM paired p WHERE s_rn=1
    ) x WHERE day_rn=1
), prev_orders AS (
    SELECT user_id,vir_date,prev_serial
    FROM (
      SELECT t.user_id,t.vir_date,o.serial_id AS prev_serial,
        ROW_NUMBER() OVER (PARTITION BY t.user_id,t.vir_date ORDER BY o.remit_time DESC,o.serial_id DESC) AS rn
      FROM t0_origin t
      JOIN wangchuanliang.order_loan_f_v2_copy o
        ON o.user_id=t.user_id
       AND o.is_remit=1 AND COALESCE(o.remit_amt,0)>0
       AND o.remit_time IS NOT NULL AND o.remit_time<t.vir_time
    ) x WHERE rn=1
), prev_amount AS (
    SELECT p.user_id,p.vir_date,v.max_credit_apply_amt AS prev_amt
    FROM prev_orders p
    LEFT JOIN (
      SELECT DISTINCT ON (serial_id) serial_id,max_credit_apply_amt
      FROM wangchuanliang.order_vir_f_copy
      ORDER BY serial_id,vir_unix DESC
    ) v ON v.serial_id=p.prev_serial
), down_t0 AS (
    SELECT t.*, p.prev_amt
    FROM t0_origin t
    JOIN prev_amount p ON p.user_id=t.user_id AND p.vir_date=t.vir_date
    WHERE t.this_amt IS NOT NULL AND p.prev_amt IS NOT NULL AND t.this_amt<p.prev_amt
), down_no_same_day_apply AS (
    SELECT d.*
    FROM down_t0 d
    WHERE NOT EXISTS (
      SELECT 1 FROM wangchuanliang.order_loan_f_v2_copy a
      WHERE a.user_id=d.user_id
        AND a.apply_time>=d.vir_time
        AND a.apply_date=d.vir_date
    )
), d1_d5_remit_orders AS (
    SELECT DISTINCT ON (o.serial_id)
      d.user_id,d.vir_date,d.vir_time,d.this_amt AS t0_credit_amt,
      o.serial_id,o.apply_time,o.remit_amt,o.due_date::date AS due_date
    FROM down_no_same_day_apply d
    JOIN wangchuanliang.order_loan_f_v2_copy o
      ON o.user_id=d.user_id
     AND o.apply_date BETWEEN d.vir_date+1 AND d.vir_date+5
     AND o.is_remit=1 AND COALESCE(o.remit_amt,0)>0
    ORDER BY o.serial_id,d.vir_time DESC
), matured_order_profit AS (
    SELECT o.*,
      COALESCE(SUM(CASE WHEN r.payin_date<=o.due_date THEN r.amount ELSE 0 END),0) AS repaid_by_due_amt
    FROM d1_d5_remit_orders o
    LEFT JOIN wangchuanliang.repayment_record_copy r ON r.serial_id=o.serial_id
    WHERE o.due_date<CURRENT_DATE
    GROUP BY o.user_id,o.vir_date,o.vir_time,o.t0_credit_amt,o.serial_id,o.apply_time,o.remit_amt,o.due_date
)
, successful_loan_count AS (
    SELECT
      d.user_id,
      d.vir_date,
      d.vir_time,
      COUNT(DISTINCT h.serial_id) AS successful_loan_n
    FROM down_no_same_day_apply d
    JOIN wangchuanliang.order_loan_f_v2_copy h
      ON h.user_id = d.user_id
     AND h.is_remit = 1
     AND COALESCE(h.remit_amt, 0) > 0
     AND h.remit_time IS NOT NULL
     AND h.remit_time <= d.repaid_time
    GROUP BY d.user_id, d.vir_date, d.vir_time
), first_d1_d5_remit_order AS (
    SELECT user_id, vir_date, vir_time, t0_credit_amt,
      serial_id, apply_time, remit_amt, due_date
    FROM (
      SELECT o.*,
        ROW_NUMBER() OVER (
          PARTITION BY o.user_id, o.vir_date, o.vir_time
          ORDER BY o.apply_time ASC NULLS LAST, o.serial_id ASC
        ) AS order_rn
      FROM d1_d5_remit_orders o
    ) x
    WHERE order_rn = 1
)
SELECT
  DATE_TRUNC('month', o.vir_date)::date AS t0_vir_month,
  o.user_id,
  o.vir_date,
  o.vir_time,
  o.t0_credit_amt,
  o.serial_id,
  o.apply_time,
  o.remit_amt,
  o.due_date,
  l.successful_loan_n,
  CASE
    WHEN l.successful_loan_n = 1 THEN '1次'
    WHEN l.successful_loan_n = 2 THEN '2次'
    WHEN l.successful_loan_n = 3 THEN '3次'
    WHEN l.successful_loan_n = 4 THEN '4次'
    WHEN l.successful_loan_n = 5 THEN '5次'
    ELSE '6次及以上'
  END AS loan_count_bucket,
  o.remit_amt / NULLIF(o.t0_credit_amt, 0) AS util_ratio,
  CASE
    WHEN o.remit_amt / NULLIF(o.t0_credit_amt, 0) < 0.800 THEN '<80%'
    WHEN o.remit_amt / NULLIF(o.t0_credit_amt, 0) < 0.999 THEN '80%-100%'
    WHEN o.remit_amt / NULLIF(o.t0_credit_amt, 0) <= 1.001 THEN '接近100%'
    ELSE '>100%'
  END AS util_band,
  CASE WHEN p.serial_id IS NOT NULL THEN 1 ELSE 0 END AS is_matured,
  CASE WHEN p.serial_id IS NOT NULL THEN p.remit_amt ELSE 0 END AS matured_remit_amt,
  CASE WHEN p.serial_id IS NOT NULL THEN p.repaid_by_due_amt ELSE 0 END AS repaid_by_due_amt
FROM first_d1_d5_remit_order o
JOIN successful_loan_count l
  ON l.user_id = o.user_id
 AND l.vir_date = o.vir_date
 AND l.vir_time = o.vir_time
LEFT JOIN matured_order_profit p ON p.serial_id = o.serial_id
WHERE o.t0_credit_amt > 0;

-- =============================================================================
-- R1 总体校验
-- =============================================================================
SELECT COUNT(*) AS order_n,
          COUNT(DISTINCT (t0_vir_month, user_id)) AS user_month_n,
          SUM(is_matured) AS matured_order_n,
          SUM(matured_remit_amt) AS matured_remit_amt,
          SUM(repaid_by_due_amt) AS repaid_by_due_amt,
          ROUND(100.0 * SUM(remit_amt) / SUM(t0_credit_amt), 2) AS utilization_rate_pct,
          ROUND(100.0 * SUM(repaid_by_due_amt) / SUM(matured_remit_amt) - 100, 2)
            AS maturity_profit_rate_pct
        FROM tmp_t0_down_util_loan_profit;

-- =============================================================================
-- R2 额度使用率档汇总
-- =============================================================================
SELECT util_band, COUNT(*) AS order_n, COUNT(DISTINCT user_id) AS user_n,
          ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS order_share_pct,
          ROUND(100.0 * SUM(remit_amt) / SUM(t0_credit_amt), 2) AS utilization_rate_pct,
          SUM(is_matured) AS matured_order_n,
          SUM(matured_remit_amt) AS matured_remit_amt,
          SUM(repaid_by_due_amt) AS repaid_by_due_amt,
          ROUND(100.0 * SUM(repaid_by_due_amt) / NULLIF(SUM(matured_remit_amt), 0) - 100, 2)
            AS maturity_profit_rate_pct
        FROM tmp_t0_down_util_loan_profit
        GROUP BY util_band ORDER BY CASE util_band
  WHEN '<80%' THEN 1 WHEN '80%-100%' THEN 2
  WHEN '接近100%' THEN 3 ELSE 4 END;

-- =============================================================================
-- R3 借款次数汇总
-- =============================================================================
SELECT loan_count_bucket, COUNT(*) AS order_n, COUNT(DISTINCT user_id) AS user_n,
          ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS order_share_pct,
          ROUND(AVG(successful_loan_n), 2) AS avg_successful_loan_n,
          ROUND(100.0 * SUM(remit_amt) / SUM(t0_credit_amt), 2) AS utilization_rate_pct,
          SUM(is_matured) AS matured_order_n,
          SUM(matured_remit_amt) AS matured_remit_amt,
          SUM(repaid_by_due_amt) AS repaid_by_due_amt,
          ROUND(100.0 * SUM(repaid_by_due_amt) / NULLIF(SUM(matured_remit_amt), 0) - 100, 2)
            AS maturity_profit_rate_pct
        FROM tmp_t0_down_util_loan_profit
        GROUP BY loan_count_bucket ORDER BY CASE loan_count_bucket
  WHEN '1次' THEN 1 WHEN '2次' THEN 2 WHEN '3次' THEN 3
  WHEN '4次' THEN 4 WHEN '5次' THEN 5 ELSE 6 END;

-- =============================================================================
-- R4 借款次数 × 使用率档交叉汇总
-- =============================================================================
SELECT loan_count_bucket, util_band, COUNT(*) AS order_n,
          COUNT(DISTINCT user_id) AS user_n,
          ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY loan_count_bucket), 2)
            AS band_share_within_loan_pct,
          ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS order_share_pct,
          ROUND(100.0 * SUM(remit_amt) / SUM(t0_credit_amt), 2) AS utilization_rate_pct,
          SUM(is_matured) AS matured_order_n,
          SUM(matured_remit_amt) AS matured_remit_amt,
          SUM(repaid_by_due_amt) AS repaid_by_due_amt,
          ROUND(100.0 * SUM(repaid_by_due_amt) / NULLIF(SUM(matured_remit_amt), 0) - 100, 2)
            AS maturity_profit_rate_pct
        FROM tmp_t0_down_util_loan_profit
        GROUP BY loan_count_bucket, util_band
        ORDER BY CASE loan_count_bucket
  WHEN '1次' THEN 1 WHEN '2次' THEN 2 WHEN '3次' THEN 3
  WHEN '4次' THEN 4 WHEN '5次' THEN 5 ELSE 6 END, CASE util_band
  WHEN '<80%' THEN 1 WHEN '80%-100%' THEN 2
  WHEN '接近100%' THEN 3 ELSE 4 END;

-- =============================================================================
-- R5 月度 × 借款次数 × 使用率档完整交叉明细
-- =============================================================================
SELECT TO_CHAR(t0_vir_month, 'YYYY-MM') AS t0_vir_month,
          loan_count_bucket, util_band, COUNT(*) AS order_n,
          COUNT(DISTINCT user_id) AS user_n,
          ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER
            (PARTITION BY t0_vir_month, loan_count_bucket), 2) AS band_share_within_month_loan_pct,
          ROUND(100.0 * SUM(remit_amt) / SUM(t0_credit_amt), 2) AS utilization_rate_pct,
          SUM(is_matured) AS matured_order_n,
          SUM(matured_remit_amt) AS matured_remit_amt,
          SUM(repaid_by_due_amt) AS repaid_by_due_amt,
          ROUND(100.0 * SUM(repaid_by_due_amt) / NULLIF(SUM(matured_remit_amt), 0) - 100, 2)
            AS maturity_profit_rate_pct
        FROM tmp_t0_down_util_loan_profit
        GROUP BY t0_vir_month, loan_count_bucket, util_band
        ORDER BY t0_vir_month, CASE loan_count_bucket
  WHEN '1次' THEN 1 WHEN '2次' THEN 2 WHEN '3次' THEN 3
  WHEN '4次' THEN 4 WHEN '5次' THEN 5 ELSE 6 END, CASE util_band
  WHEN '<80%' THEN 1 WHEN '80%-100%' THEN 2
  WHEN '接近100%' THEN 3 ELSE 4 END;

-- =============================================================================
-- R6 高使用率候选客群盈利与月度稳定性
-- =============================================================================
WITH monthly AS (
          SELECT t0_vir_month, loan_count_bucket, util_band,
            SUM(is_matured) AS matured_order_n,
            SUM(matured_remit_amt) AS matured_remit_amt,
            SUM(repaid_by_due_amt) AS repaid_by_due_amt,
            100.0 * SUM(repaid_by_due_amt) / NULLIF(SUM(matured_remit_amt), 0) - 100
              AS maturity_profit_rate_pct
          FROM tmp_t0_down_util_loan_profit
          GROUP BY t0_vir_month, loan_count_bucket, util_band
        ), total AS (
          SELECT loan_count_bucket, util_band, COUNT(*) AS order_n,
            COUNT(DISTINCT user_id) AS user_n,
            ROUND(100.0 * SUM(remit_amt) / SUM(t0_credit_amt), 2) AS utilization_rate_pct,
            SUM(is_matured) AS matured_order_n,
            ROUND(100.0 * SUM(repaid_by_due_amt) / NULLIF(SUM(matured_remit_amt), 0) - 100, 2)
              AS all_month_profit_pct,
            ROUND(100.0 * SUM(CASE WHEN t0_vir_month < DATE '2026-08-01' THEN repaid_by_due_amt ELSE 0 END)
              / NULLIF(SUM(CASE WHEN t0_vir_month < DATE '2026-08-01' THEN matured_remit_amt ELSE 0 END), 0) - 100, 2)
              AS jan_jul_profit_pct
          FROM tmp_t0_down_util_loan_profit
          GROUP BY loan_count_bucket, util_band
        )
        SELECT t.*, COUNT(m.t0_vir_month) AS observed_month_n,
          SUM(CASE WHEN m.t0_vir_month < DATE '2026-08-01' THEN 1 ELSE 0 END) AS jan_jul_month_n,
          SUM(CASE WHEN m.t0_vir_month < DATE '2026-08-01'
                    AND m.maturity_profit_rate_pct > 0 THEN 1 ELSE 0 END) AS jan_jul_positive_month_n,
          ROUND(MIN(CASE WHEN m.t0_vir_month < DATE '2026-08-01'
                         THEN m.maturity_profit_rate_pct END), 2) AS jan_jul_min_month_profit_pct,
          ROUND(MAX(CASE WHEN m.t0_vir_month < DATE '2026-08-01'
                         THEN m.maturity_profit_rate_pct END), 2) AS jan_jul_max_month_profit_pct
        FROM total t
        JOIN monthly m USING (loan_count_bucket, util_band)
        GROUP BY t.loan_count_bucket, t.util_band, t.order_n, t.user_n, t.utilization_rate_pct,
          t.matured_order_n, t.all_month_profit_pct, t.jan_jul_profit_pct
        ORDER BY CASE WHEN t.util_band IN ('接近100%', '>100%') THEN 0 ELSE 1 END,
          t.jan_jul_profit_pct DESC, t.matured_order_n DESC,
          CASE loan_count_bucket
  WHEN '1次' THEN 1 WHEN '2次' THEN 2 WHEN '3次' THEN 3
  WHEN '4次' THEN 4 WHEN '5次' THEN 5 ELSE 6 END, CASE util_band
  WHEN '<80%' THEN 1 WHEN '80%-100%' THEN 2
  WHEN '接近100%' THEN 3 ELSE 4 END;
