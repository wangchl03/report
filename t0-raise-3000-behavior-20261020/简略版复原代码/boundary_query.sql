SET TIME ZONE 'America/Belize';
-- Read-only: business timezone America/Belize; original confirmed event definitions.
WITH params AS (
    SELECT DATE '2026-10-01' AS start_date,
           DATE '2026-10-09' AS end_date
), raw_offer AS (
    SELECT DISTINCT ON (v.user_id, v.serial_id)
        v.user_id,
        v.serial_id AS credit_serial_id,
        v.vir_date::date AS vir_date,
        TO_TIMESTAMP(v.vir_unix) AS vir_time,
        v.max_credit_apply_amt::numeric AS current_credit_amt
    FROM wangchuanliang.order_vir_f_copy v
    CROSS JOIN params p
    WHERE v.is_pass1 = 1
      AND v.loan_type_code = 2
      AND EXISTS (SELECT 1 FROM wangchuanliang.side_recycle_type_copy r WHERE r.serial_id=v.serial_id AND r.recycle_type=3)
      AND v.vir_date >= p.start_date - 1
      AND v.vir_date < p.end_date + 1
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
           o.remit_time, o.remit_amt, o.is_remit, o.apply_amt, o.product_no,
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
),
t0_base AS (
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
 AND a.vir_time = e.vir_time
), cohort AS (
    SELECT t.*,MOD(t.user_id::bigint,10)::integer AS tail
    FROM t0_base t
), previous_order AS (
    SELECT c.user_id,c.credit_serial_id,c.vir_time,
           MAX(o.apply_amt)::numeric AS previous_apply_amt,
           MAX(NULLIF(BTRIM(o.product_no),'')) AS previous_product_no,
           COUNT(*) AS source_rows,
           COUNT(DISTINCT o.apply_amt) AS amount_versions,
           COUNT(DISTINCT NULLIF(BTRIM(o.product_no),'')) AS product_versions
    FROM cohort c JOIN all_orders o ON o.user_id=c.user_id AND o.serial_id=c.settled_serial_id
    GROUP BY c.user_id,c.credit_serial_id,c.vir_time
), current_offer AS (
    SELECT c.user_id,c.credit_serial_id,c.vir_time,
           MAX(v.risk_product) AS risk_product,
           COUNT(DISTINCT v.risk_product) AS product_versions
    FROM cohort c JOIN wangchuanliang.order_vir_f_copy v
      ON v.user_id=c.user_id AND v.serial_id=c.credit_serial_id
     AND v.is_pass1=1 AND TO_TIMESTAMP(v.vir_unix)=c.vir_time
    GROUP BY c.user_id,c.credit_serial_id,c.vir_time
), tokens AS (
    SELECT DISTINCT user_id,credit_serial_id,vir_time,
           BTRIM(REGEXP_SPLIT_TO_TABLE(COALESCE(risk_product,''),',')) AS product_no
    FROM current_offer
), current_product AS (
    SELECT t.user_id,t.credit_serial_id,t.vir_time,COUNT(*) AS product_n,
           SUM(CASE WHEN p.product_no IS NOT NULL THEN 1 ELSE 0 END) AS matched_n,
           SUM(CASE WHEN p.daily_fee IS NOT NULL AND p.daily_fee>=0 THEN 1 ELSE 0 END) AS daily_valid_n,
           MIN(p.daily_fee)::numeric AS min_daily_fee
    FROM tokens t LEFT JOIN wangchuanliang.product_info_copy p ON p.product_no=t.product_no
    WHERE t.product_no<>'' GROUP BY t.user_id,t.credit_serial_id,t.vir_time
), same_day_candidates AS (
    SELECT c.user_id,c.credit_serial_id,c.vir_time,o.apply_time,o.apply_amt,
           ROW_NUMBER() OVER(PARTITION BY c.user_id,c.credit_serial_id,c.vir_time
                             ORDER BY o.apply_time,o.apply_amt NULLS LAST) AS rn,
           DENSE_RANK() OVER(PARTITION BY c.user_id,c.credit_serial_id,c.vir_time
                            ORDER BY o.apply_time) AS time_rank
    FROM cohort c JOIN all_orders o
      ON o.user_id=c.user_id AND o.serial_id=c.credit_serial_id
     AND o.apply_time>=c.vir_time AND o.apply_time<c.vir_date+1
), same_day_order AS (
    SELECT * FROM same_day_candidates WHERE rn=1
), same_time_conflicts AS (
    SELECT user_id,credit_serial_id,vir_time FROM same_day_candidates
    WHERE time_rank=1 GROUP BY user_id,credit_serial_id,vir_time
    HAVING COUNT(DISTINCT apply_amt)>1
), features AS (
    SELECT c.*,
           CASE WHEN c.current_credit_amt<=4000 THEN 1
                WHEN c.current_credit_amt<=5000 THEN 2
                WHEN c.current_credit_amt<=6000 THEN 3 ELSE 4 END AS credit_band,
           CASE WHEN p.previous_apply_amt>0 THEN p.previous_apply_amt/c.previous_credit_amt END AS previous_usage,
           CASE WHEN s.apply_amt>0 THEN s.apply_amt/c.current_credit_amt END AS current_usage,
           CASE WHEN s.apply_time IS NOT NULL THEN 1 ELSE 0 END AS same_serial_d0,
           CASE WHEN s.apply_time IS NOT NULL AND (s.apply_amt IS NULL OR s.apply_amt<=0) THEN 1 ELSE 0 END AS invalid_current_amount,
           CASE WHEN cp.product_n>0 AND cp.matched_n=cp.product_n AND cp.daily_valid_n=cp.product_n
                THEN cp.min_daily_fee END AS current_daily,
           CASE WHEN pi.daily_fee>=0 THEN pi.daily_fee END AS previous_daily,
           p.previous_product_no,COALESCE(cp.product_n,0) AS current_product_n,
           CASE WHEN o.product_versions>1 THEN 1 ELSE 0 END AS current_offer_conflict,
           CASE WHEN p.amount_versions>1 OR p.product_versions>1 THEN 1 ELSE 0 END AS previous_order_conflict
    FROM cohort c
    LEFT JOIN previous_order p USING(user_id,credit_serial_id,vir_time)
    LEFT JOIN current_offer o USING(user_id,credit_serial_id,vir_time)
    LEFT JOIN current_product cp USING(user_id,credit_serial_id,vir_time)
    LEFT JOIN same_day_order s USING(user_id,credit_serial_id,vir_time)
    LEFT JOIN wangchuanliang.product_info_copy pi ON pi.product_no=p.previous_product_no
), classified AS (
    SELECT f.*,
       CASE WHEN current_daily IS NULL THEN 0
            WHEN current_daily<=.01 THEN 1 WHEN current_daily<=.015 THEN 2
            WHEN current_daily<=.02 THEN 3 WHEN current_daily<=.025 THEN 4
            WHEN current_daily<=.03 THEN 5 WHEN current_daily<=.04 THEN 6
            WHEN current_daily<=.05 THEN 7 ELSE 8 END AS current_daily_band,
       CASE WHEN previous_daily IS NULL THEN 0
            WHEN previous_daily<=.01 THEN 1 WHEN previous_daily<=.015 THEN 2
            WHEN previous_daily<=.02 THEN 3 WHEN previous_daily<=.025 THEN 4
            WHEN previous_daily<=.03 THEN 5 WHEN previous_daily<=.04 THEN 6
            WHEN previous_daily<=.05 THEN 7 ELSE 8 END AS previous_daily_band
    FROM features f
)
SELECT * FROM classified ORDER BY user_id,vir_time,credit_serial_id;