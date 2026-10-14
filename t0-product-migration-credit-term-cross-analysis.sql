-- T0产品迁移：先在原事件明细补属性，再联合汇总。只读，无DDL。
-- 事件2026-01-01至2026-10-11；due_date>2000-01-01且<2026-10-13。
-- D0用户首次实际提单，金额MXN，repaid_amt账面、状态当前快照。
-- 产品缺失不筛事件；旧六维/旧账期/旧排除规则保持。
-- 运行后分别保存kind=cube/audit的JSON数据；产品目录为第二个SELECT。
-- 规范组合、MAX账期、产品迁移、联合宽表与全部交叉投影由附带Python程序复现。
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL TIME ZONE 'America/Belize';
SET LOCAL query_dop=1;
SET LOCAL statement_timeout=1200000;
WITH params AS (
    SELECT DATE '2026-01-01' AS start_date,
           DATE '2026-10-12' AS end_date,
           DATE '2026-10-13' AS business_observation_date
), raw_offer AS (
    SELECT DISTINCT ON (v.user_id, v.serial_id)
        v.user_id,
        v.serial_id AS credit_serial_id,
        v.vir_date::date AS vir_date,
        TO_TIMESTAMP(v.vir_unix) AS vir_time,
        v.max_credit_apply_amt::numeric AS current_credit_amt, v.risk_product
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
           current_credit_amt, batch_id, risk_product
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
           o.is_repaid, o.loan_status_code, o.product_no, o.remit_succ_rnb, o.due_date, o.repaid_amt
    FROM wangchuanliang.order_loan_f_v2_copy o
    JOIN candidate_users u ON u.user_id = o.user_id
), clean_settlement AS (
    SELECT o.user_id, o.serial_id AS settled_serial_id,
           o.remit_amt::numeric AS settled_remit_amt,
           o.repaid_time, o.repaid_date, o.product_no AS settled_product_no,
           o.remit_succ_rnb AS settled_loan_n
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
           e.current_credit_amt, e.batch_id, e.risk_product,
           s.settled_serial_id, s.settled_remit_amt, s.repaid_time,
           s.settled_product_no,s.settled_loan_n,
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
           current_credit_amt, batch_id, risk_product,
           settled_serial_id, settled_remit_amt, repaid_time, settled_product_no,settled_loan_n
    FROM offer_settlement_pair
    WHERE settlement_rn = 1
), previous_credit_ranked AS (
    SELECT s.user_id, s.credit_serial_id, s.vir_time, s.settled_serial_id,
           v.max_credit_apply_amt::numeric AS previous_credit_amt,
           v.risk_product AS previous_risk_product,v.user_id AS previous_offer_user_id,
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
           previous_credit_amt,previous_risk_product,previous_offer_user_id
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
           s.repaid_time, s.settled_serial_id, s.risk_product, s.settled_product_no,s.settled_loan_n,
           s.settled_remit_amt AS previous_remit_amt,
           p.previous_credit_amt,p.previous_risk_product,p.previous_offer_user_id,
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
    e.settled_serial_id, e.risk_product,e.settled_product_no,e.settled_loan_n,
    e.previous_risk_product,e.previous_offer_user_id,
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

), catalog AS (
    SELECT BTRIM(product_no) AS product_no,loan_term,days,
           daily_fee::numeric AS daily_rate,total_fee::numeric AS fee_rate
    FROM wangchuanliang.product_info_copy
), split_products AS (
    SELECT user_id,credit_serial_id,vir_time,
           BTRIM(REGEXP_SPLIT_TO_TABLE(COALESCE(risk_product,''),',')) AS product_no
    FROM t0_base
), product_tokens AS (
    SELECT DISTINCT user_id,credit_serial_id,vir_time,product_no
    FROM split_products WHERE product_no<>''
), current_conditions AS (
    SELECT t.user_id,t.credit_serial_id,t.vir_time,COUNT(*) AS option_n,
           SUM(CASE WHEN c.product_no IS NOT NULL THEN 1 ELSE 0 END) AS matched_n,
           SUM(CASE WHEN c.daily_rate IS NOT NULL AND c.daily_rate>=0 THEN 1 ELSE 0 END) AS daily_valid_n,
           SUM(CASE WHEN c.fee_rate IS NOT NULL AND c.fee_rate>=0 THEN 1 ELSE 0 END) AS fee_valid_n,
           MIN(c.daily_rate) AS daily_rate,MAX(c.fee_rate) AS fee_rate
    FROM product_tokens t LEFT JOIN catalog c ON c.product_no=t.product_no
    GROUP BY t.user_id,t.credit_serial_id,t.vir_time
), model_agg AS (
    SELECT m.user_id,m.serial_id,COUNT(*) AS row_n,
           COUNT(m.kabybmerge410fpd7cre) AS nonnull_n,
           COUNT(DISTINCT m.kabybmerge410fpd7cre) AS distinct_n,
           MIN(m.kabybmerge410fpd7cre) AS score_410
    FROM wangchuanliang.model_result_copy m
    JOIN t0_base t ON t.user_id=m.user_id AND t.credit_serial_id=m.serial_id
    GROUP BY m.user_id,m.serial_id
), enriched AS (
    SELECT t.*,c.option_n,c.matched_n,
           CASE WHEN c.option_n=c.fee_valid_n THEN c.fee_rate END AS current_fee,
           CASE WHEN c.option_n=c.daily_valid_n THEN c.daily_rate END AS current_daily,
           CASE WHEN p.fee_rate>=0 THEN p.fee_rate END AS previous_fee,
           CASE WHEN p.daily_rate>=0 THEN p.daily_rate END AS previous_daily,
           p.product_no AS previous_matched_product,
           m.score_410,m.distinct_n,m.row_n,
           CASE WHEN m.row_n IS NULL OR m.nonnull_n=0 THEN '缺失'
                WHEN m.distinct_n>1 THEN '冲突'
                WHEN m.score_410 BETWEEN 1 AND 3000 THEN '有效'
                ELSE '无效' END AS score_status
    FROM t0_base t
    LEFT JOIN current_conditions c ON c.user_id=t.user_id AND c.credit_serial_id=t.credit_serial_id AND c.vir_time=t.vir_time
    LEFT JOIN catalog p ON p.product_no=BTRIM(t.settled_product_no)
    LEFT JOIN model_agg m ON m.user_id=t.user_id AND m.serial_id=t.credit_serial_id
), changes AS (
    SELECT e.*,current_fee-previous_fee AS fee_delta,current_daily-previous_daily AS daily_delta
    FROM enriched e
), labeled AS (
    SELECT c.*,TO_CHAR(t0_month,'YYYY-MM') AS month,
      CASE WHEN credit_change_amt>0 THEN '增加' WHEN credit_change_amt<0 THEN '降低' ELSE '不变' END AS credit_type,
      CASE WHEN (CASE WHEN credit_change_amt=0 THEN current_credit_amt ELSE ABS(credit_change_amt) END)<500 THEN '<500'
           WHEN (CASE WHEN credit_change_amt=0 THEN current_credit_amt ELSE ABS(credit_change_amt) END)<1000 THEN '500–1000'
           WHEN (CASE WHEN credit_change_amt=0 THEN current_credit_amt ELSE ABS(credit_change_amt) END)<2000 THEN '1000–2000'
           WHEN (CASE WHEN credit_change_amt=0 THEN current_credit_amt ELSE ABS(credit_change_amt) END)<3000 THEN '2000–3000'
           ELSE '≥3000' END AS amount_band,
      CASE WHEN previous_credit_amt<1000 THEN '0–1000'
           WHEN previous_credit_amt<2000 THEN '1000–2000'
           WHEN previous_credit_amt<5000 THEN '2000–5000'
           WHEN previous_credit_amt<10000 THEN '5000–10000' ELSE '≥10000' END AS base_band,
      CASE WHEN settled_loan_n IS NULL OR settled_loan_n<1 THEN '缺失/无效'
           WHEN settled_loan_n=1 THEN '1次' WHEN settled_loan_n=2 THEN '2次'
           WHEN settled_loan_n=3 THEN '3次' WHEN settled_loan_n=4 THEN '4次'
           WHEN settled_loan_n=5 THEN '5次' ELSE '>5次' END AS loan_band,
      CASE WHEN score_status<>'有效' THEN score_status
           WHEN score_410<529 THEN '1–529' WHEN score_410<569 THEN '529–569' ELSE '569–3000' END AS score_band,
      CASE WHEN score_status<>'有效' THEN score_status
           WHEN score_410<505 THEN '<505' WHEN score_410<535 THEN '505–535' ELSE '≥535' END AS score_new_band,
      CASE WHEN fee_delta IS NULL THEN '缺失' WHEN fee_delta=0 THEN '不变'
           WHEN fee_delta>0 AND fee_delta<0.05 THEN '增加0–5pp'
           WHEN fee_delta>=0.05 AND fee_delta<0.10 THEN '增加5–10pp'
           WHEN fee_delta>=0.10 THEN '增加≥10pp'
           WHEN fee_delta<0 AND fee_delta>-0.05 THEN '减少0–5pp'
           WHEN fee_delta<=-0.05 AND fee_delta>-0.10 THEN '减少5–10pp' ELSE '减少≥10pp' END AS fee_band,
      CASE WHEN daily_delta IS NULL THEN '缺失' WHEN daily_delta=0 THEN '不变'
           WHEN daily_delta>0 AND daily_delta<0.0025 THEN '增加0–0.25pp'
           WHEN daily_delta>=0.0025 AND daily_delta<0.005 THEN '增加0.25–0.5pp'
           WHEN daily_delta>=0.005 THEN '增加≥0.5pp'
           WHEN daily_delta<0 AND daily_delta>-0.0025 THEN '减少0–0.25pp'
           WHEN daily_delta<=-0.0025 AND daily_delta>-0.005 THEN '减少0.25–0.5pp' ELSE '减少≥0.5pp' END AS daily_band
    FROM changes c

), observation AS (
    SELECT p.business_observation_date,CURRENT_TIMESTAMP AS snapshot FROM params p
), financial_keys AS (
    /* Both candidate definitions are extracted for explicit attribution QA.
       Neither can change T0 n or user D0 y. */
    SELECT user_id,apply_serial_id AS serial_id FROM labeled WHERE apply_serial_id IS NOT NULL
    UNION SELECT user_id,credit_serial_id FROM labeled
), financial_raw AS (
    SELECT o.user_id,o.serial_id,o.is_remit,o.remit_amt,o.repaid_amt,o.due_date,o.loan_status_code,o.product_no
    FROM all_orders o JOIN financial_keys k ON k.user_id=o.user_id AND k.serial_id=o.serial_id
), financial_orders AS (
    /* MAX is only a collapse of exact duplicates. Conflicts are independently
       flagged and cause the extraction to fail, not silently become an order. */
    SELECT user_id,serial_id,COUNT(*) AS source_n,
           MAX(is_remit) AS is_remit,MAX(remit_amt) AS remit_amt,MAX(repaid_amt) AS repaid_amt,
           MAX(due_date) AS due_date,MAX(loan_status_code) AS loan_status_code,
           MAX(NULLIF(BTRIM(product_no),'')) AS actual_product_candidate,
           COUNT(DISTINCT NULLIF(BTRIM(product_no),'')) AS actual_product_distinct_n,
           COUNT(NULLIF(BTRIM(product_no),'')) AS actual_product_nonnull_n,
           CASE WHEN COUNT(DISTINCT is_remit)>1 OR COUNT(DISTINCT remit_amt)>1
                  OR COUNT(DISTINCT repaid_amt)>1 OR COUNT(DISTINCT due_date)>1
                  OR COUNT(DISTINCT loan_status_code)>1
                  OR COUNT(is_remit) NOT IN (0,COUNT(*)) OR COUNT(remit_amt) NOT IN (0,COUNT(*))
                  OR COUNT(repaid_amt) NOT IN (0,COUNT(*)) OR COUNT(due_date) NOT IN (0,COUNT(*))
                  OR COUNT(loan_status_code) NOT IN (0,COUNT(*)) THEN 1 ELSE 0 END AS conflict
    FROM financial_raw GROUP BY user_id,serial_id
), attached AS (
    SELECT l.*,o.business_observation_date,
           d.serial_id AS d0_matched_serial,d.source_n AS d0_source_n,d.conflict AS d0_conflict,
           d.is_remit AS d0_is_remit,d.remit_amt AS d0_remit,d.repaid_amt AS d0_repaid,
           d.due_date AS d0_due_date,d.loan_status_code AS d0_status,
           d.actual_product_candidate,d.actual_product_distinct_n,d.actual_product_nonnull_n,
           q.serial_id AS serial_matched_serial,q.source_n AS serial_source_n,q.conflict AS serial_conflict,
           q.is_remit AS serial_is_remit,q.remit_amt AS serial_remit,q.repaid_amt AS serial_repaid,
           q.due_date AS serial_due_date,q.loan_status_code AS serial_status
    FROM labeled l CROSS JOIN observation o
    LEFT JOIN financial_orders d ON d.user_id=l.user_id AND d.serial_id=l.apply_serial_id
    LEFT JOIN financial_orders q ON q.user_id=l.user_id AND q.serial_id=l.credit_serial_id
), observed AS (
    SELECT a.*,
           CASE WHEN d0_is_remit=1 AND d0_remit>0 AND COALESCE(d0_conflict,0)=0
                THEN 1 ELSE 0 END AS d0_funded_n,
           CASE WHEN d0_is_remit=1 AND d0_remit>0 AND COALESCE(d0_conflict,0)=0
                       AND d0_due_date>DATE '2000-01-01' AND d0_due_date<business_observation_date
                THEN 1 ELSE 0 END AS d0_due_n,
           CASE WHEN serial_is_remit=1 AND serial_remit>0 AND COALESCE(serial_conflict,0)=0
                THEN 1 ELSE 0 END AS serial_funded_n,
           CASE WHEN serial_is_remit=1 AND serial_remit>0 AND COALESCE(serial_conflict,0)=0
                       AND serial_due_date>DATE '2000-01-01' AND serial_due_date<business_observation_date
                THEN 1 ELSE 0 END AS serial_due_n
    FROM attached a


), product_observed AS (
    SELECT o.*,
           previous_offer_user_id=user_id AS previous_owner_matches,
           CASE WHEN has_d0_apply=1 AND actual_product_distinct_n=1 AND actual_product_nonnull_n=d0_source_n
                THEN actual_product_candidate END AS d0_actual_product_no,
           CASE WHEN has_d0_apply=0 THEN '未提单'
                WHEN COALESCE(actual_product_distinct_n,0)=0 THEN '产品缺失'
                WHEN actual_product_distinct_n>1 THEN '产品冲突'
                WHEN actual_product_nonnull_n<>d0_source_n THEN '部分缺失' ELSE '有效' END AS d0_product_quality,
           CASE WHEN has_d0_apply=0 THEN '未提单'
                WHEN apply_serial_id=credit_serial_id THEN '原获额订单'
                ELSE '其他获额订单' END AS d0_offer_origin
    FROM observed o
), product_cube AS (
    SELECT month,credit_type,amount_band,base_band,loan_band,score_band,fee_band,daily_band,score_new_band,risk_product,previous_risk_product,settled_product_no,d0_actual_product_no,d0_product_quality,d0_offer_origin,previous_owner_matches,COUNT(*) AS n,SUM(has_d0_apply) AS y,
           SUM(d0_funded_n) AS d0_funded_n,SUM(d0_due_n) AS d0_due_n,
           SUM(CASE WHEN d0_due_n=1 AND d0_status=8 THEN 1 ELSE 0 END) AS d0_overdue_n,
           SUM(CASE WHEN d0_due_n=1 THEN d0_remit ELSE 0 END) AS d0_remit_amt,
           SUM(CASE WHEN d0_due_n=1 THEN d0_repaid ELSE 0 END) AS d0_repaid_amt,
           SUM(CASE WHEN d0_due_n=1 AND d0_repaid IS NULL THEN 1 ELSE 0 END) AS d0_repaid_missing_n,
           SUM(CASE WHEN d0_due_n=1 AND d0_status IS NULL THEN 1 ELSE 0 END) AS d0_status_missing_n
    FROM product_observed GROUP BY month,credit_type,amount_band,base_band,loan_band,score_band,fee_band,daily_band,score_new_band,risk_product,previous_risk_product,settled_product_no,d0_actual_product_no,d0_product_quality,d0_offer_origin,previous_owner_matches
), source_audit AS (
    SELECT '严格T0'::text AS key,COUNT(*)::bigint AS n FROM strict_t0
    UNION ALL SELECT '可分析T0',COUNT(*) FROM t0_base
    UNION ALL SELECT '产品补齐后T0',COUNT(*) FROM product_observed
    UNION ALL SELECT '重复事件键',COUNT(*) FROM (SELECT user_id,credit_serial_id,vir_time FROM product_observed GROUP BY user_id,credit_serial_id,vir_time HAVING COUNT(*)>1) q
    UNION ALL SELECT '重复提单归属',COUNT(*) FROM (SELECT apply_serial_id FROM t0_base WHERE has_d0_apply=1 GROUP BY apply_serial_id HAVING COUNT(*)>1) q
    UNION ALL SELECT 'D0财务字段冲突',COUNT(*) FROM product_observed WHERE COALESCE(d0_conflict,0)>0
    UNION ALL SELECT 'D0财务未匹配',COUNT(*) FROM product_observed WHERE has_d0_apply=1 AND d0_matched_serial IS NULL
    UNION ALL SELECT '上一笔获额归属异常',COUNT(*) FROM product_observed WHERE previous_offer_user_id IS DISTINCT FROM user_id
)
SELECT 'cube'::text AS kind,ROW_TO_JSON(q)::text AS payload FROM product_cube q
UNION ALL SELECT 'audit',ROW_TO_JSON(q)::text FROM source_audit q
;
SELECT product_no,loan_term,days,daily_fee,total_fee FROM wangchuanliang.product_info_copy ORDER BY BTRIM(product_no);
ROLLBACK;
