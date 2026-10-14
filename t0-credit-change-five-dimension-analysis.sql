-- 完整只读PGSQL：6标签63非空子集×4范围=252投影；15组二维补零矩阵。
-- 时间2026-01-01至2026-10-11（含）；月份按T0获额事件，不按到期日。
-- 业务观察日固定2026-10-13，到期仅2000-01-01<due_date<2026-10-13。
-- 贷后仅D0实际首次提单订单；serial_*保留为诊断，不混进D0财务指标。
-- repaid_amt/status是执行时当前值，固定到期日期不能冻结或恢复历史账面/状态。
-- reference_snapshot识别已发布缓存，snapshot记录本次执行时间；两者不可混同。
-- 原获额成功规则与旧677排除保留；零目录价原值保留，不解释为实际免费。
-- GROUPING=1表示汇总；rate/share为小数，所有*_pp为百分点，0分母NULL。
-- 缺失还款/状态由missing_n携带，NULLguard不补0；repaid_additive仅为加总中间量。
-- 三类标准化均用共同完整单元：转化双方n>=20；财务双方due>=20且缺失数=0。
-- 转化Jan事件权重、盈利Jan本金权重、逾期Jan到期笔数权重；不是因果估计。
-- 六标签里的两评分来自同一410分，实际五因素；跨投影排行不得相加。
BEGIN TRANSACTION READ ONLY;
SET LOCAL TIME ZONE 'America/Belize';
SET LOCAL query_dop=1;
WITH params AS (
    SELECT DATE '2026-01-01' AS start_date,
           DATE '2026-10-12' AS end_date
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
           s.repaid_time, s.settled_serial_id, s.risk_product, s.settled_product_no,s.settled_loan_n,
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
    e.settled_serial_id, e.risk_product,e.settled_product_no,e.settled_loan_n,
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
    SELECT DATE '2026-10-13' AS business_observation_date,CURRENT_TIMESTAMP AS snapshot
), financial_keys AS (
    /* Both candidate definitions are extracted for explicit attribution QA.
       Neither can change T0 n or user D0 y. */
    SELECT user_id,apply_serial_id AS serial_id FROM labeled WHERE apply_serial_id IS NOT NULL
    UNION SELECT user_id,credit_serial_id FROM labeled
), financial_raw AS (
    SELECT o.user_id,o.serial_id,o.is_remit,o.remit_amt,o.repaid_amt,o.due_date,o.loan_status_code
    FROM all_orders o JOIN financial_keys k ON k.user_id=o.user_id AND k.serial_id=o.serial_id
), financial_orders AS (
    /* MAX is only a collapse of exact duplicates. Conflicts are independently
       flagged and cause the extraction to fail, not silently become an order. */
    SELECT user_id,serial_id,COUNT(*) AS source_n,
           MAX(is_remit) AS is_remit,MAX(remit_amt) AS remit_amt,MAX(repaid_amt) AS repaid_amt,
           MAX(due_date) AS due_date,MAX(loan_status_code) AS loan_status_code,
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
), cube AS (
    SELECT month,credit_type,amount_band,base_band,loan_band,score_band,score_new_band,fee_band,daily_band,
           COUNT(*) AS n,SUM(has_d0_apply) AS y,
           SUM(d0_funded_n) AS d0_funded_n,SUM(d0_due_n) AS d0_due_n,
           SUM(CASE WHEN d0_due_n=1 AND d0_status=8 THEN 1 ELSE 0 END) AS d0_overdue_n,
           SUM(CASE WHEN d0_due_n=1 THEN d0_remit ELSE 0 END) AS d0_remit_amt,
           SUM(CASE WHEN d0_due_n=1 THEN d0_repaid ELSE 0 END) AS d0_repaid_amt,
           SUM(CASE WHEN d0_due_n=1 AND d0_repaid IS NULL THEN 1 ELSE 0 END) AS d0_repaid_missing_n,
           SUM(CASE WHEN d0_due_n=1 AND d0_status IS NULL THEN 1 ELSE 0 END) AS d0_status_missing_n,
           SUM(serial_funded_n) AS serial_funded_n,SUM(serial_due_n) AS serial_due_n,
           SUM(CASE WHEN serial_due_n=1 AND serial_status=8 THEN 1 ELSE 0 END) AS serial_overdue_n,
           SUM(CASE WHEN serial_due_n=1 THEN serial_remit ELSE 0 END) AS serial_remit_amt,
           SUM(CASE WHEN serial_due_n=1 THEN serial_repaid ELSE 0 END) AS serial_repaid_amt,
           SUM(CASE WHEN serial_due_n=1 AND serial_repaid IS NULL THEN 1 ELSE 0 END) AS serial_repaid_missing_n,
           SUM(CASE WHEN serial_due_n=1 AND serial_status IS NULL THEN 1 ELSE 0 END) AS serial_status_missing_n
    FROM observed GROUP BY month,credit_type,amount_band,base_band,loan_band,score_band,score_new_band,fee_band,daily_band
), controls AS (
    SELECT month,COUNT(*) AS n,SUM(has_d0_apply) AS y,SUM(d0_funded_n) AS d0_funded_n,
           SUM(d0_due_n) AS d0_due_n,
           SUM(CASE WHEN d0_due_n=1 AND d0_status=8 THEN 1 ELSE 0 END) AS d0_overdue_n,
           SUM(CASE WHEN d0_due_n=1 THEN d0_remit ELSE 0 END) AS d0_remit_amt,
           SUM(CASE WHEN d0_due_n=1 THEN d0_repaid ELSE 0 END) AS d0_repaid_amt,
           SUM(serial_funded_n) AS serial_funded_n,SUM(serial_due_n) AS serial_due_n,
           SUM(CASE WHEN serial_due_n=1 AND serial_status=8 THEN 1 ELSE 0 END) AS serial_overdue_n,
           SUM(CASE WHEN serial_due_n=1 THEN serial_remit ELSE 0 END) AS serial_remit_amt,
           SUM(CASE WHEN serial_due_n=1 THEN serial_repaid ELSE 0 END) AS serial_repaid_amt
    FROM observed GROUP BY month
), audit AS (
    SELECT '严格T0事件数'::text AS key,COUNT(*)::bigint AS n FROM strict_t0
    UNION ALL SELECT '额度可分析T0事件数',COUNT(*) FROM t0_base
    UNION ALL SELECT '被原额度规则排除',(SELECT COUNT(*) FROM strict_t0)-(SELECT COUNT(*) FROM t0_base)
    UNION ALL SELECT '截至10月8日可分析T0',COUNT(*) FROM t0_base WHERE vir_date<DATE '2026-10-09'
    UNION ALL SELECT '截至10月8日D0',SUM(has_d0_apply) FROM t0_base WHERE vir_date<DATE '2026-10-09'
    UNION ALL SELECT '丰富字段后事件数',COUNT(*) FROM observed
    UNION ALL SELECT '重复事件键',COUNT(*) FROM (SELECT user_id,credit_serial_id,vir_time FROM observed GROUP BY user_id,credit_serial_id,vir_time HAVING COUNT(*)>1) z
    UNION ALL SELECT '重复提单归属',COUNT(*) FROM (SELECT apply_serial_id FROM t0_base WHERE has_d0_apply=1 GROUP BY apply_serial_id HAVING COUNT(*)>1) z
    UNION ALL SELECT 'D0窗口异常',COUNT(*) FROM t0_base WHERE has_d0_apply=1 AND (d0_apply_time<vir_time OR d0_apply_time>=vir_date+1)
    UNION ALL SELECT '财务同键额外行',COALESCE(SUM(source_n-1),0) FROM financial_orders
    UNION ALL SELECT '财务同键字段冲突',SUM(conflict) FROM financial_orders
    UNION ALL SELECT 'D0提单财务未匹配',COUNT(*) FROM observed WHERE has_d0_apply=1 AND d0_matched_serial IS NULL
    UNION ALL SELECT 'D0到期还款缺失',COUNT(*) FROM observed WHERE d0_due_n=1 AND d0_repaid IS NULL
    UNION ALL SELECT 'D0到期状态缺失',COUNT(*) FROM observed WHERE d0_due_n=1 AND d0_status IS NULL
    UNION ALL SELECT '原编号到期还款缺失',COUNT(*) FROM observed WHERE serial_due_n=1 AND serial_repaid IS NULL
    UNION ALL SELECT '原编号到期状态缺失',COUNT(*) FROM observed WHERE serial_due_n=1 AND serial_status IS NULL
    UNION ALL SELECT '410评分缺失',COUNT(*) FROM observed WHERE score_status='缺失'
    UNION ALL SELECT '410评分无效',COUNT(*) FROM observed WHERE score_status='无效'
    UNION ALL SELECT '410评分冲突',COUNT(*) FROM observed WHERE score_status='冲突'
    UNION ALL SELECT '上笔次数缺失无效',COUNT(*) FROM observed WHERE loan_band='缺失/无效'
    UNION ALL SELECT '当前产品未全部匹配',COUNT(*) FROM observed WHERE option_n IS NULL OR option_n<>matched_n
    UNION ALL SELECT '上一笔产品未匹配',COUNT(*) FROM observed WHERE previous_matched_product IS NULL
    UNION ALL SELECT '息费维度缺失',COUNT(*) FROM observed WHERE fee_band='缺失'
    UNION ALL SELECT '日息维度缺失',COUNT(*) FROM observed WHERE daily_band='缺失'
), months(month) AS (VALUES ('2026-01'),('2026-02'),('2026-03'),('2026-04'),('2026-05'),('2026-06'),('2026-07'),('2026-08'),('2026-09'),('2026-10')),
scope_contexts(scope,credit_type,amount_band,g_credit_type,g_amount_band) AS (VALUES
    ('overall',NULL::text,NULL::text,1,1),
    ('credit_type','增加',NULL::text,0,1),
    ('credit_type','降低',NULL::text,0,1),
    ('credit_type','不变',NULL::text,0,1),
    ('amount_band',NULL::text,'<500',1,0),
    ('amount_band',NULL::text,'500–1000',1,0),
    ('amount_band',NULL::text,'1000–2000',1,0),
    ('amount_band',NULL::text,'2000–3000',1,0),
    ('amount_band',NULL::text,'≥3000',1,0),
    ('credit_type_amount','增加','<500',0,0),
    ('credit_type_amount','增加','500–1000',0,0),
    ('credit_type_amount','增加','1000–2000',0,0),
    ('credit_type_amount','增加','2000–3000',0,0),
    ('credit_type_amount','增加','≥3000',0,0),
    ('credit_type_amount','降低','<500',0,0),
    ('credit_type_amount','降低','500–1000',0,0),
    ('credit_type_amount','降低','1000–2000',0,0),
    ('credit_type_amount','降低','2000–3000',0,0),
    ('credit_type_amount','降低','≥3000',0,0),
    ('credit_type_amount','不变','<500',0,0),
    ('credit_type_amount','不变','500–1000',0,0),
    ('credit_type_amount','不变','1000–2000',0,0),
    ('credit_type_amount','不变','2000–3000',0,0),
    ('credit_type_amount','不变','≥3000',0,0)),
dimension_levels(dimension,level,level_order) AS (VALUES
    ('base_band','0–1000',0),
    ('base_band','1000–2000',1),
    ('base_band','2000–5000',2),
    ('base_band','5000–10000',3),
    ('base_band','≥10000',4),
    ('loan_band','1次',0),
    ('loan_band','2次',1),
    ('loan_band','3次',2),
    ('loan_band','4次',3),
    ('loan_band','5次',4),
    ('loan_band','>5次',5),
    ('loan_band','缺失/无效',6),
    ('score_band','1–529',0),
    ('score_band','529–569',1),
    ('score_band','569–3000',2),
    ('score_band','缺失',3),
    ('score_band','无效',4),
    ('score_band','冲突',5),
    ('fee_band','增加0–5pp',0),
    ('fee_band','增加5–10pp',1),
    ('fee_band','增加≥10pp',2),
    ('fee_band','不变',3),
    ('fee_band','减少0–5pp',4),
    ('fee_band','减少5–10pp',5),
    ('fee_band','减少≥10pp',6),
    ('fee_band','缺失',7),
    ('daily_band','增加0–0.25pp',0),
    ('daily_band','增加0.25–0.5pp',1),
    ('daily_band','增加≥0.5pp',2),
    ('daily_band','不变',3),
    ('daily_band','减少0–0.25pp',4),
    ('daily_band','减少0.25–0.5pp',5),
    ('daily_band','减少≥0.5pp',6),
    ('daily_band','缺失',7),
    ('score_new_band','<505',0),
    ('score_new_band','505–535',1),
    ('score_new_band','≥535',2),
    ('score_new_band','缺失',3),
    ('score_new_band','无效',4),
    ('score_new_band','冲突',5)),
family_definitions(family,dimensions_text,effective_factors) AS (VALUES
    ('legacy_five','base_band|loan_band|score_band|fee_band|daily_band',5),
    ('new_score_five','base_band|loan_band|score_new_band|fee_band|daily_band',5),
    ('six_labels','base_band|loan_band|score_band|fee_band|daily_band|score_new_band',5)),
standard_specs(spec_id,family,scope,credit_type,amount_band) AS (VALUES
    ('legacy_five@overall:{}','legacy_five','overall',NULL::text,NULL::text),
    ('legacy_five@credit_type:{"credit_type":"增加"}','legacy_five','credit_type','增加',NULL::text),
    ('legacy_five@credit_type:{"credit_type":"降低"}','legacy_five','credit_type','降低',NULL::text),
    ('legacy_five@credit_type:{"credit_type":"不变"}','legacy_five','credit_type','不变',NULL::text),
    ('legacy_five@credit_type_amount:{"credit_type":"增加","amount_band":"≥3000"}','legacy_five','credit_type_amount','增加','≥3000'),
    ('legacy_five@credit_type_amount:{"credit_type":"降低","amount_band":"≥3000"}','legacy_five','credit_type_amount','降低','≥3000'),
    ('new_score_five@overall:{}','new_score_five','overall',NULL::text,NULL::text),
    ('new_score_five@credit_type:{"credit_type":"增加"}','new_score_five','credit_type','增加',NULL::text),
    ('new_score_five@credit_type:{"credit_type":"降低"}','new_score_five','credit_type','降低',NULL::text),
    ('new_score_five@credit_type:{"credit_type":"不变"}','new_score_five','credit_type','不变',NULL::text),
    ('new_score_five@credit_type_amount:{"credit_type":"增加","amount_band":"≥3000"}','new_score_five','credit_type_amount','增加','≥3000'),
    ('new_score_five@credit_type_amount:{"credit_type":"降低","amount_band":"≥3000"}','new_score_five','credit_type_amount','降低','≥3000'),
    ('six_labels@overall:{}','six_labels','overall',NULL::text,NULL::text),
    ('six_labels@credit_type:{"credit_type":"增加"}','six_labels','credit_type','增加',NULL::text),
    ('six_labels@credit_type:{"credit_type":"降低"}','six_labels','credit_type','降低',NULL::text),
    ('six_labels@credit_type:{"credit_type":"不变"}','six_labels','credit_type','不变',NULL::text),
    ('six_labels@credit_type_amount:{"credit_type":"增加","amount_band":"≥3000"}','six_labels','credit_type_amount','增加','≥3000'),
    ('six_labels@credit_type_amount:{"credit_type":"降低","amount_band":"≥3000"}','six_labels','credit_type_amount','降低','≥3000')),
cube_inputs AS (
    SELECT c.month,c.credit_type,c.amount_band,c.base_band,c.loan_band,c.score_band,c.fee_band,c.daily_band,c.score_new_band,c.n,c.y,
           c.d0_funded_n AS funded_loan_n,c.d0_due_n AS matured_loan_n,c.d0_overdue_n AS overdue_loan_n,
           c.d0_remit_amt AS matured_remit_amt,
           COALESCE(c.d0_repaid_amt,0) AS repaid_additive,
           c.d0_repaid_missing_n AS matured_repaid_missing_n,c.d0_status_missing_n AS matured_status_missing_n
    FROM cube c
), cube_output AS (
    SELECT c.*,i.funded_loan_n,i.matured_loan_n,i.overdue_loan_n,i.matured_remit_amt,
           i.matured_repaid_missing_n,i.matured_status_missing_n,i.y::numeric/NULLIF(i.n,0) AS rate,
           i.funded_loan_n::numeric/NULLIF(i.y,0) AS funded_coverage,
           i.matured_loan_n::numeric/NULLIF(i.funded_loan_n,0) AS maturity_coverage,
           i.matured_loan_n::numeric/NULLIF(i.n,0) AS due_event_coverage,
           CASE WHEN i.matured_repaid_missing_n=0 THEN i.repaid_additive END AS matured_repaid_amt,
           CASE WHEN i.matured_repaid_missing_n=0 THEN i.repaid_additive-i.matured_remit_amt END AS profit_amt,
           CASE WHEN i.matured_repaid_missing_n=0 THEN
             (i.repaid_additive-i.matured_remit_amt)/NULLIF(i.matured_remit_amt,0) END AS profit_rate,
           CASE WHEN i.matured_status_missing_n=0 THEN
             i.overdue_loan_n::numeric/NULLIF(i.matured_loan_n,0) END AS overdue_rate
    FROM cube c JOIN cube_inputs i ON c.month=i.month AND c.credit_type IS NOT DISTINCT FROM i.credit_type
      AND c.amount_band IS NOT DISTINCT FROM i.amount_band
      AND c.base_band IS NOT DISTINCT FROM i.base_band
      AND c.loan_band IS NOT DISTINCT FROM i.loan_band
      AND c.score_band IS NOT DISTINCT FROM i.score_band
      AND c.fee_band IS NOT DISTINCT FROM i.fee_band
      AND c.daily_band IS NOT DISTINCT FROM i.daily_band
      AND c.score_new_band IS NOT DISTINCT FROM i.score_new_band
), parent_raw AS (
    SELECT month,credit_type,amount_band,CASE WHEN GROUPING(credit_type)=1 AND GROUPING(amount_band)=1 THEN 'overall' WHEN GROUPING(amount_band)=1 THEN 'credit_type' WHEN GROUPING(credit_type)=1 THEN 'amount_band' ELSE 'credit_type_amount' END AS scope,
           GROUPING(credit_type) AS g_credit_type,GROUPING(amount_band) AS g_amount_band,SUM(c.n) AS n,
           SUM(c.y) AS y,
           SUM(c.funded_loan_n) AS funded_loan_n,
           SUM(c.matured_loan_n) AS matured_loan_n,
           SUM(c.overdue_loan_n) AS overdue_loan_n,
           SUM(c.matured_remit_amt) AS matured_remit_amt,
           SUM(c.repaid_additive) AS repaid_additive,
           SUM(c.matured_repaid_missing_n) AS matured_repaid_missing_n,
           SUM(c.matured_status_missing_n) AS matured_status_missing_n
    FROM cube_inputs c GROUP BY GROUPING SETS ((month),(month,credit_type),(month,amount_band),(month,credit_type,amount_band))
), parent_counts AS (
    SELECT m.month,s.*,COALESCE(p.n,0) AS n,
           COALESCE(p.y,0) AS y,
           COALESCE(p.funded_loan_n,0) AS funded_loan_n,
           COALESCE(p.matured_loan_n,0) AS matured_loan_n,
           COALESCE(p.overdue_loan_n,0) AS overdue_loan_n,
           COALESCE(p.matured_remit_amt,0) AS matured_remit_amt,
           COALESCE(p.repaid_additive,0) AS repaid_additive,
           COALESCE(p.matured_repaid_missing_n,0) AS matured_repaid_missing_n,
           COALESCE(p.matured_status_missing_n,0) AS matured_status_missing_n
    FROM months m CROSS JOIN scope_contexts s
    LEFT JOIN parent_raw p ON p.month=m.month AND p.scope=s.scope
      AND p.credit_type IS NOT DISTINCT FROM s.credit_type AND p.amount_band IS NOT DISTINCT FROM s.amount_band
), parent_metrics AS (
    SELECT p.*,p.y::numeric/NULLIF(p.n,0) AS rate,
           p.funded_loan_n::numeric/NULLIF(p.y,0) AS funded_coverage,
           p.matured_loan_n::numeric/NULLIF(p.funded_loan_n,0) AS maturity_coverage,
           p.matured_loan_n::numeric/NULLIF(p.n,0) AS due_event_coverage,
           CASE WHEN p.matured_repaid_missing_n=0 THEN p.repaid_additive END AS matured_repaid_amt,
           CASE WHEN p.matured_repaid_missing_n=0 THEN p.repaid_additive-p.matured_remit_amt END AS profit_amt,
           CASE WHEN p.matured_repaid_missing_n=0 THEN
             (p.repaid_additive-p.matured_remit_amt)/NULLIF(p.matured_remit_amt,0) END AS profit_rate,
           CASE WHEN p.matured_status_missing_n=0 THEN
             p.overdue_loan_n::numeric/NULLIF(p.matured_loan_n,0) END AS overdue_rate FROM parent_counts p
), projection_raw AS (
    SELECT month,NULL::text AS credit_type,NULL::text AS amount_band,base_band,loan_band,score_band,fee_band,daily_band,score_new_band,1 AS g_credit_type,1 AS g_amount_band,GROUPING(base_band) AS g_base_band,GROUPING(loan_band) AS g_loan_band,GROUPING(score_band) AS g_score_band,GROUPING(fee_band) AS g_fee_band,GROUPING(daily_band) AS g_daily_band,GROUPING(score_new_band) AS g_score_new_band,
           SUM(c.n) AS n,
           SUM(c.y) AS y,
           SUM(c.funded_loan_n) AS funded_loan_n,
           SUM(c.matured_loan_n) AS matured_loan_n,
           SUM(c.overdue_loan_n) AS overdue_loan_n,
           SUM(c.matured_remit_amt) AS matured_remit_amt,
           SUM(c.repaid_additive) AS repaid_additive,
           SUM(c.matured_repaid_missing_n) AS matured_repaid_missing_n,
           SUM(c.matured_status_missing_n) AS matured_status_missing_n
    FROM cube_inputs c GROUP BY GROUPING SETS (
        (month,base_band),
        (month,loan_band),
        (month,score_band),
        (month,fee_band),
        (month,daily_band),
        (month,score_new_band),
        (month,base_band,loan_band),
        (month,base_band,score_band),
        (month,base_band,fee_band),
        (month,base_band,daily_band),
        (month,base_band,score_new_band),
        (month,loan_band,score_band),
        (month,loan_band,fee_band),
        (month,loan_band,daily_band),
        (month,loan_band,score_new_band),
        (month,score_band,fee_band),
        (month,score_band,daily_band),
        (month,score_band,score_new_band),
        (month,fee_band,daily_band),
        (month,fee_band,score_new_band),
        (month,daily_band,score_new_band),
        (month,base_band,loan_band,score_band),
        (month,base_band,loan_band,fee_band),
        (month,base_band,loan_band,daily_band),
        (month,base_band,loan_band,score_new_band),
        (month,base_band,score_band,fee_band),
        (month,base_band,score_band,daily_band),
        (month,base_band,score_band,score_new_band),
        (month,base_band,fee_band,daily_band),
        (month,base_band,fee_band,score_new_band),
        (month,base_band,daily_band,score_new_band),
        (month,loan_band,score_band,fee_band)
    ) UNION ALL SELECT month,NULL::text AS credit_type,NULL::text AS amount_band,base_band,loan_band,score_band,fee_band,daily_band,score_new_band,1 AS g_credit_type,1 AS g_amount_band,GROUPING(base_band) AS g_base_band,GROUPING(loan_band) AS g_loan_band,GROUPING(score_band) AS g_score_band,GROUPING(fee_band) AS g_fee_band,GROUPING(daily_band) AS g_daily_band,GROUPING(score_new_band) AS g_score_new_band,
           SUM(c.n) AS n,
           SUM(c.y) AS y,
           SUM(c.funded_loan_n) AS funded_loan_n,
           SUM(c.matured_loan_n) AS matured_loan_n,
           SUM(c.overdue_loan_n) AS overdue_loan_n,
           SUM(c.matured_remit_amt) AS matured_remit_amt,
           SUM(c.repaid_additive) AS repaid_additive,
           SUM(c.matured_repaid_missing_n) AS matured_repaid_missing_n,
           SUM(c.matured_status_missing_n) AS matured_status_missing_n
    FROM cube_inputs c GROUP BY GROUPING SETS (
        (month,loan_band,score_band,daily_band),
        (month,loan_band,score_band,score_new_band),
        (month,loan_band,fee_band,daily_band),
        (month,loan_band,fee_band,score_new_band),
        (month,loan_band,daily_band,score_new_band),
        (month,score_band,fee_band,daily_band),
        (month,score_band,fee_band,score_new_band),
        (month,score_band,daily_band,score_new_band),
        (month,fee_band,daily_band,score_new_band),
        (month,base_band,loan_band,score_band,fee_band),
        (month,base_band,loan_band,score_band,daily_band),
        (month,base_band,loan_band,score_band,score_new_band),
        (month,base_band,loan_band,fee_band,daily_band),
        (month,base_band,loan_band,fee_band,score_new_band),
        (month,base_band,loan_band,daily_band,score_new_band),
        (month,base_band,score_band,fee_band,daily_band),
        (month,base_band,score_band,fee_band,score_new_band),
        (month,base_band,score_band,daily_band,score_new_band),
        (month,base_band,fee_band,daily_band,score_new_band),
        (month,loan_band,score_band,fee_band,daily_band),
        (month,loan_band,score_band,fee_band,score_new_band),
        (month,loan_band,score_band,daily_band,score_new_band),
        (month,loan_band,fee_band,daily_band,score_new_band),
        (month,score_band,fee_band,daily_band,score_new_band),
        (month,base_band,loan_band,score_band,fee_band,daily_band),
        (month,base_band,loan_band,score_band,fee_band,score_new_band),
        (month,base_band,loan_band,score_band,daily_band,score_new_band),
        (month,base_band,loan_band,fee_band,daily_band,score_new_band),
        (month,base_band,score_band,fee_band,daily_band,score_new_band),
        (month,loan_band,score_band,fee_band,daily_band,score_new_band),
        (month,base_band,loan_band,score_band,fee_band,daily_band,score_new_band)
    ) UNION ALL SELECT month,credit_type,NULL::text AS amount_band,base_band,loan_band,score_band,fee_band,daily_band,score_new_band,GROUPING(credit_type) AS g_credit_type,1 AS g_amount_band,GROUPING(base_band) AS g_base_band,GROUPING(loan_band) AS g_loan_band,GROUPING(score_band) AS g_score_band,GROUPING(fee_band) AS g_fee_band,GROUPING(daily_band) AS g_daily_band,GROUPING(score_new_band) AS g_score_new_band,
           SUM(c.n) AS n,
           SUM(c.y) AS y,
           SUM(c.funded_loan_n) AS funded_loan_n,
           SUM(c.matured_loan_n) AS matured_loan_n,
           SUM(c.overdue_loan_n) AS overdue_loan_n,
           SUM(c.matured_remit_amt) AS matured_remit_amt,
           SUM(c.repaid_additive) AS repaid_additive,
           SUM(c.matured_repaid_missing_n) AS matured_repaid_missing_n,
           SUM(c.matured_status_missing_n) AS matured_status_missing_n
    FROM cube_inputs c GROUP BY GROUPING SETS (
        (month,credit_type,base_band),
        (month,credit_type,loan_band),
        (month,credit_type,score_band),
        (month,credit_type,fee_band),
        (month,credit_type,daily_band),
        (month,credit_type,score_new_band),
        (month,credit_type,base_band,loan_band),
        (month,credit_type,base_band,score_band),
        (month,credit_type,base_band,fee_band),
        (month,credit_type,base_band,daily_band),
        (month,credit_type,base_band,score_new_band),
        (month,credit_type,loan_band,score_band),
        (month,credit_type,loan_band,fee_band),
        (month,credit_type,loan_band,daily_band),
        (month,credit_type,loan_band,score_new_band),
        (month,credit_type,score_band,fee_band),
        (month,credit_type,score_band,daily_band),
        (month,credit_type,score_band,score_new_band),
        (month,credit_type,fee_band,daily_band),
        (month,credit_type,fee_band,score_new_band),
        (month,credit_type,daily_band,score_new_band),
        (month,credit_type,base_band,loan_band,score_band),
        (month,credit_type,base_band,loan_band,fee_band),
        (month,credit_type,base_band,loan_band,daily_band),
        (month,credit_type,base_band,loan_band,score_new_band),
        (month,credit_type,base_band,score_band,fee_band),
        (month,credit_type,base_band,score_band,daily_band),
        (month,credit_type,base_band,score_band,score_new_band),
        (month,credit_type,base_band,fee_band,daily_band),
        (month,credit_type,base_band,fee_band,score_new_band),
        (month,credit_type,base_band,daily_band,score_new_band),
        (month,credit_type,loan_band,score_band,fee_band)
    ) UNION ALL SELECT month,credit_type,NULL::text AS amount_band,base_band,loan_band,score_band,fee_band,daily_band,score_new_band,GROUPING(credit_type) AS g_credit_type,1 AS g_amount_band,GROUPING(base_band) AS g_base_band,GROUPING(loan_band) AS g_loan_band,GROUPING(score_band) AS g_score_band,GROUPING(fee_band) AS g_fee_band,GROUPING(daily_band) AS g_daily_band,GROUPING(score_new_band) AS g_score_new_band,
           SUM(c.n) AS n,
           SUM(c.y) AS y,
           SUM(c.funded_loan_n) AS funded_loan_n,
           SUM(c.matured_loan_n) AS matured_loan_n,
           SUM(c.overdue_loan_n) AS overdue_loan_n,
           SUM(c.matured_remit_amt) AS matured_remit_amt,
           SUM(c.repaid_additive) AS repaid_additive,
           SUM(c.matured_repaid_missing_n) AS matured_repaid_missing_n,
           SUM(c.matured_status_missing_n) AS matured_status_missing_n
    FROM cube_inputs c GROUP BY GROUPING SETS (
        (month,credit_type,loan_band,score_band,daily_band),
        (month,credit_type,loan_band,score_band,score_new_band),
        (month,credit_type,loan_band,fee_band,daily_band),
        (month,credit_type,loan_band,fee_band,score_new_band),
        (month,credit_type,loan_band,daily_band,score_new_band),
        (month,credit_type,score_band,fee_band,daily_band),
        (month,credit_type,score_band,fee_band,score_new_band),
        (month,credit_type,score_band,daily_band,score_new_band),
        (month,credit_type,fee_band,daily_band,score_new_band),
        (month,credit_type,base_band,loan_band,score_band,fee_band),
        (month,credit_type,base_band,loan_band,score_band,daily_band),
        (month,credit_type,base_band,loan_band,score_band,score_new_band),
        (month,credit_type,base_band,loan_band,fee_band,daily_band),
        (month,credit_type,base_band,loan_band,fee_band,score_new_band),
        (month,credit_type,base_band,loan_band,daily_band,score_new_band),
        (month,credit_type,base_band,score_band,fee_band,daily_band),
        (month,credit_type,base_band,score_band,fee_band,score_new_band),
        (month,credit_type,base_band,score_band,daily_band,score_new_band),
        (month,credit_type,base_band,fee_band,daily_band,score_new_band),
        (month,credit_type,loan_band,score_band,fee_band,daily_band),
        (month,credit_type,loan_band,score_band,fee_band,score_new_band),
        (month,credit_type,loan_band,score_band,daily_band,score_new_band),
        (month,credit_type,loan_band,fee_band,daily_band,score_new_band),
        (month,credit_type,score_band,fee_band,daily_band,score_new_band),
        (month,credit_type,base_band,loan_band,score_band,fee_band,daily_band),
        (month,credit_type,base_band,loan_band,score_band,fee_band,score_new_band),
        (month,credit_type,base_band,loan_band,score_band,daily_band,score_new_band),
        (month,credit_type,base_band,loan_band,fee_band,daily_band,score_new_band),
        (month,credit_type,base_band,score_band,fee_band,daily_band,score_new_band),
        (month,credit_type,loan_band,score_band,fee_band,daily_band,score_new_band),
        (month,credit_type,base_band,loan_band,score_band,fee_band,daily_band,score_new_band)
    ) UNION ALL SELECT month,NULL::text AS credit_type,amount_band,base_band,loan_band,score_band,fee_band,daily_band,score_new_band,1 AS g_credit_type,GROUPING(amount_band) AS g_amount_band,GROUPING(base_band) AS g_base_band,GROUPING(loan_band) AS g_loan_band,GROUPING(score_band) AS g_score_band,GROUPING(fee_band) AS g_fee_band,GROUPING(daily_band) AS g_daily_band,GROUPING(score_new_band) AS g_score_new_band,
           SUM(c.n) AS n,
           SUM(c.y) AS y,
           SUM(c.funded_loan_n) AS funded_loan_n,
           SUM(c.matured_loan_n) AS matured_loan_n,
           SUM(c.overdue_loan_n) AS overdue_loan_n,
           SUM(c.matured_remit_amt) AS matured_remit_amt,
           SUM(c.repaid_additive) AS repaid_additive,
           SUM(c.matured_repaid_missing_n) AS matured_repaid_missing_n,
           SUM(c.matured_status_missing_n) AS matured_status_missing_n
    FROM cube_inputs c GROUP BY GROUPING SETS (
        (month,amount_band,base_band),
        (month,amount_band,loan_band),
        (month,amount_band,score_band),
        (month,amount_band,fee_band),
        (month,amount_band,daily_band),
        (month,amount_band,score_new_band),
        (month,amount_band,base_band,loan_band),
        (month,amount_band,base_band,score_band),
        (month,amount_band,base_band,fee_band),
        (month,amount_band,base_band,daily_band),
        (month,amount_band,base_band,score_new_band),
        (month,amount_band,loan_band,score_band),
        (month,amount_band,loan_band,fee_band),
        (month,amount_band,loan_band,daily_band),
        (month,amount_band,loan_band,score_new_band),
        (month,amount_band,score_band,fee_band),
        (month,amount_band,score_band,daily_band),
        (month,amount_band,score_band,score_new_band),
        (month,amount_band,fee_band,daily_band),
        (month,amount_band,fee_band,score_new_band),
        (month,amount_band,daily_band,score_new_band),
        (month,amount_band,base_band,loan_band,score_band),
        (month,amount_band,base_band,loan_band,fee_band),
        (month,amount_band,base_band,loan_band,daily_band),
        (month,amount_band,base_band,loan_band,score_new_band),
        (month,amount_band,base_band,score_band,fee_band),
        (month,amount_band,base_band,score_band,daily_band),
        (month,amount_band,base_band,score_band,score_new_band),
        (month,amount_band,base_band,fee_band,daily_band),
        (month,amount_band,base_band,fee_band,score_new_band),
        (month,amount_band,base_band,daily_band,score_new_band),
        (month,amount_band,loan_band,score_band,fee_band)
    ) UNION ALL SELECT month,NULL::text AS credit_type,amount_band,base_band,loan_band,score_band,fee_band,daily_band,score_new_band,1 AS g_credit_type,GROUPING(amount_band) AS g_amount_band,GROUPING(base_band) AS g_base_band,GROUPING(loan_band) AS g_loan_band,GROUPING(score_band) AS g_score_band,GROUPING(fee_band) AS g_fee_band,GROUPING(daily_band) AS g_daily_band,GROUPING(score_new_band) AS g_score_new_band,
           SUM(c.n) AS n,
           SUM(c.y) AS y,
           SUM(c.funded_loan_n) AS funded_loan_n,
           SUM(c.matured_loan_n) AS matured_loan_n,
           SUM(c.overdue_loan_n) AS overdue_loan_n,
           SUM(c.matured_remit_amt) AS matured_remit_amt,
           SUM(c.repaid_additive) AS repaid_additive,
           SUM(c.matured_repaid_missing_n) AS matured_repaid_missing_n,
           SUM(c.matured_status_missing_n) AS matured_status_missing_n
    FROM cube_inputs c GROUP BY GROUPING SETS (
        (month,amount_band,loan_band,score_band,daily_band),
        (month,amount_band,loan_band,score_band,score_new_band),
        (month,amount_band,loan_band,fee_band,daily_band),
        (month,amount_band,loan_band,fee_band,score_new_band),
        (month,amount_band,loan_band,daily_band,score_new_band),
        (month,amount_band,score_band,fee_band,daily_band),
        (month,amount_band,score_band,fee_band,score_new_band),
        (month,amount_band,score_band,daily_band,score_new_band),
        (month,amount_band,fee_band,daily_band,score_new_band),
        (month,amount_band,base_band,loan_band,score_band,fee_band),
        (month,amount_band,base_band,loan_band,score_band,daily_band),
        (month,amount_band,base_band,loan_band,score_band,score_new_band),
        (month,amount_band,base_band,loan_band,fee_band,daily_band),
        (month,amount_band,base_band,loan_band,fee_band,score_new_band),
        (month,amount_band,base_band,loan_band,daily_band,score_new_band),
        (month,amount_band,base_band,score_band,fee_band,daily_band),
        (month,amount_band,base_band,score_band,fee_band,score_new_band),
        (month,amount_band,base_band,score_band,daily_band,score_new_band),
        (month,amount_band,base_band,fee_band,daily_band,score_new_band),
        (month,amount_band,loan_band,score_band,fee_band,daily_band),
        (month,amount_band,loan_band,score_band,fee_band,score_new_band),
        (month,amount_band,loan_band,score_band,daily_band,score_new_band),
        (month,amount_band,loan_band,fee_band,daily_band,score_new_band),
        (month,amount_band,score_band,fee_band,daily_band,score_new_band),
        (month,amount_band,base_band,loan_band,score_band,fee_band,daily_band),
        (month,amount_band,base_band,loan_band,score_band,fee_band,score_new_band),
        (month,amount_band,base_band,loan_band,score_band,daily_band,score_new_band),
        (month,amount_band,base_band,loan_band,fee_band,daily_band,score_new_band),
        (month,amount_band,base_band,score_band,fee_band,daily_band,score_new_band),
        (month,amount_band,loan_band,score_band,fee_band,daily_band,score_new_band),
        (month,amount_band,base_band,loan_band,score_band,fee_band,daily_band,score_new_band)
    ) UNION ALL SELECT month,credit_type,amount_band,base_band,loan_band,score_band,fee_band,daily_band,score_new_band,GROUPING(credit_type) AS g_credit_type,GROUPING(amount_band) AS g_amount_band,GROUPING(base_band) AS g_base_band,GROUPING(loan_band) AS g_loan_band,GROUPING(score_band) AS g_score_band,GROUPING(fee_band) AS g_fee_band,GROUPING(daily_band) AS g_daily_band,GROUPING(score_new_band) AS g_score_new_band,
           SUM(c.n) AS n,
           SUM(c.y) AS y,
           SUM(c.funded_loan_n) AS funded_loan_n,
           SUM(c.matured_loan_n) AS matured_loan_n,
           SUM(c.overdue_loan_n) AS overdue_loan_n,
           SUM(c.matured_remit_amt) AS matured_remit_amt,
           SUM(c.repaid_additive) AS repaid_additive,
           SUM(c.matured_repaid_missing_n) AS matured_repaid_missing_n,
           SUM(c.matured_status_missing_n) AS matured_status_missing_n
    FROM cube_inputs c GROUP BY GROUPING SETS (
        (month,credit_type,amount_band,base_band),
        (month,credit_type,amount_band,loan_band),
        (month,credit_type,amount_band,score_band),
        (month,credit_type,amount_band,fee_band),
        (month,credit_type,amount_band,daily_band),
        (month,credit_type,amount_band,score_new_band),
        (month,credit_type,amount_band,base_band,loan_band),
        (month,credit_type,amount_band,base_band,score_band),
        (month,credit_type,amount_band,base_band,fee_band),
        (month,credit_type,amount_band,base_band,daily_band),
        (month,credit_type,amount_band,base_band,score_new_band),
        (month,credit_type,amount_band,loan_band,score_band),
        (month,credit_type,amount_band,loan_band,fee_band),
        (month,credit_type,amount_band,loan_band,daily_band),
        (month,credit_type,amount_band,loan_band,score_new_band),
        (month,credit_type,amount_band,score_band,fee_band),
        (month,credit_type,amount_band,score_band,daily_band),
        (month,credit_type,amount_band,score_band,score_new_band),
        (month,credit_type,amount_band,fee_band,daily_band),
        (month,credit_type,amount_band,fee_band,score_new_band),
        (month,credit_type,amount_band,daily_band,score_new_band),
        (month,credit_type,amount_band,base_band,loan_band,score_band),
        (month,credit_type,amount_band,base_band,loan_band,fee_band),
        (month,credit_type,amount_band,base_band,loan_band,daily_band),
        (month,credit_type,amount_band,base_band,loan_band,score_new_band),
        (month,credit_type,amount_band,base_band,score_band,fee_band),
        (month,credit_type,amount_band,base_band,score_band,daily_band),
        (month,credit_type,amount_band,base_band,score_band,score_new_band),
        (month,credit_type,amount_band,base_band,fee_band,daily_band),
        (month,credit_type,amount_band,base_band,fee_band,score_new_band),
        (month,credit_type,amount_band,base_band,daily_band,score_new_band),
        (month,credit_type,amount_band,loan_band,score_band,fee_band)
    ) UNION ALL SELECT month,credit_type,amount_band,base_band,loan_band,score_band,fee_band,daily_band,score_new_band,GROUPING(credit_type) AS g_credit_type,GROUPING(amount_band) AS g_amount_band,GROUPING(base_band) AS g_base_band,GROUPING(loan_band) AS g_loan_band,GROUPING(score_band) AS g_score_band,GROUPING(fee_band) AS g_fee_band,GROUPING(daily_band) AS g_daily_band,GROUPING(score_new_band) AS g_score_new_band,
           SUM(c.n) AS n,
           SUM(c.y) AS y,
           SUM(c.funded_loan_n) AS funded_loan_n,
           SUM(c.matured_loan_n) AS matured_loan_n,
           SUM(c.overdue_loan_n) AS overdue_loan_n,
           SUM(c.matured_remit_amt) AS matured_remit_amt,
           SUM(c.repaid_additive) AS repaid_additive,
           SUM(c.matured_repaid_missing_n) AS matured_repaid_missing_n,
           SUM(c.matured_status_missing_n) AS matured_status_missing_n
    FROM cube_inputs c GROUP BY GROUPING SETS (
        (month,credit_type,amount_band,loan_band,score_band,daily_band),
        (month,credit_type,amount_band,loan_band,score_band,score_new_band),
        (month,credit_type,amount_band,loan_band,fee_band,daily_band),
        (month,credit_type,amount_band,loan_band,fee_band,score_new_band),
        (month,credit_type,amount_band,loan_band,daily_band,score_new_band),
        (month,credit_type,amount_band,score_band,fee_band,daily_band),
        (month,credit_type,amount_band,score_band,fee_band,score_new_band),
        (month,credit_type,amount_band,score_band,daily_band,score_new_band),
        (month,credit_type,amount_band,fee_band,daily_band,score_new_band),
        (month,credit_type,amount_band,base_band,loan_band,score_band,fee_band),
        (month,credit_type,amount_band,base_band,loan_band,score_band,daily_band),
        (month,credit_type,amount_band,base_band,loan_band,score_band,score_new_band),
        (month,credit_type,amount_band,base_band,loan_band,fee_band,daily_band),
        (month,credit_type,amount_band,base_band,loan_band,fee_band,score_new_band),
        (month,credit_type,amount_band,base_band,loan_band,daily_band,score_new_band),
        (month,credit_type,amount_band,base_band,score_band,fee_band,daily_band),
        (month,credit_type,amount_band,base_band,score_band,fee_band,score_new_band),
        (month,credit_type,amount_band,base_band,score_band,daily_band,score_new_band),
        (month,credit_type,amount_band,base_band,fee_band,daily_band,score_new_band),
        (month,credit_type,amount_band,loan_band,score_band,fee_band,daily_band),
        (month,credit_type,amount_band,loan_band,score_band,fee_band,score_new_band),
        (month,credit_type,amount_band,loan_band,score_band,daily_band,score_new_band),
        (month,credit_type,amount_band,loan_band,fee_band,daily_band,score_new_band),
        (month,credit_type,amount_band,score_band,fee_band,daily_band,score_new_band),
        (month,credit_type,amount_band,base_band,loan_band,score_band,fee_band,daily_band),
        (month,credit_type,amount_band,base_band,loan_band,score_band,fee_band,score_new_band),
        (month,credit_type,amount_band,base_band,loan_band,score_band,daily_band,score_new_band),
        (month,credit_type,amount_band,base_band,loan_band,fee_band,daily_band,score_new_band),
        (month,credit_type,amount_band,base_band,score_band,fee_band,daily_band,score_new_band),
        (month,credit_type,amount_band,loan_band,score_band,fee_band,daily_band,score_new_band),
        (month,credit_type,amount_band,base_band,loan_band,score_band,fee_band,daily_band,score_new_band)
    )
), projection_groups AS (
    SELECT DISTINCT credit_type,amount_band,base_band,loan_band,score_band,fee_band,daily_band,score_new_band,g_credit_type,g_amount_band,g_base_band,g_loan_band,g_score_band,g_fee_band,g_daily_band,g_score_new_band FROM projection_raw
    UNION
    SELECT s.credit_type,s.amount_band,CASE WHEN l.dimension='base_band' THEN l.level END AS base_band,CASE WHEN l.dimension='loan_band' THEN l.level END AS loan_band,CASE WHEN l.dimension='score_band' THEN l.level END AS score_band,CASE WHEN l.dimension='fee_band' THEN l.level END AS fee_band,CASE WHEN l.dimension='daily_band' THEN l.level END AS daily_band,CASE WHEN l.dimension='score_new_band' THEN l.level END AS score_new_band,s.g_credit_type,s.g_amount_band,CASE WHEN l.dimension='base_band' THEN 0 ELSE 1 END AS g_base_band,CASE WHEN l.dimension='loan_band' THEN 0 ELSE 1 END AS g_loan_band,CASE WHEN l.dimension='score_band' THEN 0 ELSE 1 END AS g_score_band,CASE WHEN l.dimension='fee_band' THEN 0 ELSE 1 END AS g_fee_band,CASE WHEN l.dimension='daily_band' THEN 0 ELSE 1 END AS g_daily_band,CASE WHEN l.dimension='score_new_band' THEN 0 ELSE 1 END AS g_score_new_band
    FROM scope_contexts s CROSS JOIN dimension_levels l
), projection_counts AS (
    SELECT m.month,g.*,COALESCE(a.n,0) AS n,
           COALESCE(a.y,0) AS y,
           COALESCE(a.funded_loan_n,0) AS funded_loan_n,
           COALESCE(a.matured_loan_n,0) AS matured_loan_n,
           COALESCE(a.overdue_loan_n,0) AS overdue_loan_n,
           COALESCE(a.matured_remit_amt,0) AS matured_remit_amt,
           COALESCE(a.repaid_additive,0) AS repaid_additive,
           COALESCE(a.matured_repaid_missing_n,0) AS matured_repaid_missing_n,
           COALESCE(a.matured_status_missing_n,0) AS matured_status_missing_n
    FROM months m CROSS JOIN projection_groups g
    LEFT JOIN projection_raw a ON a.month=m.month AND a.credit_type IS NOT DISTINCT FROM g.credit_type
      AND a.amount_band IS NOT DISTINCT FROM g.amount_band
      AND a.base_band IS NOT DISTINCT FROM g.base_band
      AND a.loan_band IS NOT DISTINCT FROM g.loan_band
      AND a.score_band IS NOT DISTINCT FROM g.score_band
      AND a.fee_band IS NOT DISTINCT FROM g.fee_band
      AND a.daily_band IS NOT DISTINCT FROM g.daily_band
      AND a.score_new_band IS NOT DISTINCT FROM g.score_new_band
      AND a.g_credit_type=g.g_credit_type
      AND a.g_amount_band=g.g_amount_band
      AND a.g_base_band=g.g_base_band
      AND a.g_loan_band=g.g_loan_band
      AND a.g_score_band=g.g_score_band
      AND a.g_fee_band=g.g_fee_band
      AND a.g_daily_band=g.g_daily_band
      AND a.g_score_new_band=g.g_score_new_band
), projection_identity AS (
    SELECT p.*,CASE WHEN g_credit_type=1 AND g_amount_band=1 THEN 'overall' WHEN g_amount_band=1 THEN 'credit_type' WHEN g_credit_type=1 THEN 'amount_band' ELSE 'credit_type_amount' END AS scope,CASE WHEN g_base_band=0 THEN ARRAY['base_band'] ELSE ARRAY[]::text[] END || CASE WHEN g_loan_band=0 THEN ARRAY['loan_band'] ELSE ARRAY[]::text[] END || CASE WHEN g_score_band=0 THEN ARRAY['score_band'] ELSE ARRAY[]::text[] END || CASE WHEN g_fee_band=0 THEN ARRAY['fee_band'] ELSE ARRAY[]::text[] END || CASE WHEN g_daily_band=0 THEN ARRAY['daily_band'] ELSE ARRAY[]::text[] END || CASE WHEN g_score_new_band=0 THEN ARRAY['score_new_band'] ELSE ARRAY[]::text[] END AS dimensions,
           ((g_base_band=1 OR base_band NOT IN ('缺失','无效','冲突','缺失/无效')) AND (g_loan_band=1 OR loan_band NOT IN ('缺失','无效','冲突','缺失/无效')) AND (g_score_band=1 OR score_band NOT IN ('缺失','无效','冲突','缺失/无效')) AND (g_fee_band=1 OR fee_band NOT IN ('缺失','无效','冲突','缺失/无效')) AND (g_daily_band=1 OR daily_band NOT IN ('缺失','无效','冲突','缺失/无效')) AND (g_score_new_band=1 OR score_new_band NOT IN ('缺失','无效','冲突','缺失/无效'))) AS known_complete,jsonb_strip_nulls(jsonb_build_object('base_band',p.base_band,'loan_band',p.loan_band,'score_band',p.score_band,'fee_band',p.fee_band,'daily_band',p.daily_band,'score_new_band',p.score_new_band)) AS group_key
    FROM projection_counts p
), projection_rates AS (
    SELECT p.*,ARRAY_TO_STRING(p.dimensions,'__')||'@'||p.scope AS projection_id,
           d.n AS parent_n,d.funded_loan_n AS parent_funded_loan_n,d.matured_loan_n AS parent_matured_loan_n,
           d.matured_remit_amt AS parent_matured_remit_amt,
           p.n::numeric/NULLIF(d.n,0) AS share,p.y::numeric/NULLIF(p.n,0) AS rate,
           p.funded_loan_n::numeric/NULLIF(p.y,0) AS funded_coverage,
           p.matured_loan_n::numeric/NULLIF(p.funded_loan_n,0) AS maturity_coverage,
           p.matured_loan_n::numeric/NULLIF(p.n,0) AS due_event_coverage,
           CASE WHEN p.matured_repaid_missing_n=0 THEN p.repaid_additive END AS matured_repaid_amt,
           CASE WHEN p.matured_repaid_missing_n=0 THEN p.repaid_additive-p.matured_remit_amt END AS profit_amt,
           CASE WHEN p.matured_repaid_missing_n=0 THEN
             (p.repaid_additive-p.matured_remit_amt)/NULLIF(p.matured_remit_amt,0) END AS profit_rate,
           CASE WHEN p.matured_status_missing_n=0 THEN
             p.overdue_loan_n::numeric/NULLIF(p.matured_loan_n,0) END AS overdue_rate,
           p.month='2026-10' AS is_partial
    FROM projection_identity p JOIN parent_counts d ON d.month=p.month AND d.scope=p.scope
      AND d.credit_type IS NOT DISTINCT FROM p.credit_type AND d.amount_band IS NOT DISTINCT FROM p.amount_band
), projection_monthly AS (
    SELECT p.*,
           100*(rate-MAX(CASE WHEN month='2026-01' THEN rate END) OVER (PARTITION BY credit_type,amount_band,base_band,loan_band,score_band,fee_band,daily_band,score_new_band,g_credit_type,g_amount_band,g_base_band,g_loan_band,g_score_band,g_fee_band,g_daily_band,g_score_new_band)) AS delta_jan,
           100*(profit_rate-MAX(CASE WHEN month='2026-01' THEN profit_rate END) OVER (PARTITION BY credit_type,amount_band,base_band,loan_band,score_band,fee_band,daily_band,score_new_band,g_credit_type,g_amount_band,g_base_band,g_loan_band,g_score_band,g_fee_band,g_daily_band,g_score_new_band)) AS profit_delta_jan,
           100*(overdue_rate-MAX(CASE WHEN month='2026-01' THEN overdue_rate END) OVER (PARTITION BY credit_type,amount_band,base_band,loan_band,score_band,fee_band,daily_band,score_new_band,g_credit_type,g_amount_band,g_base_band,g_loan_band,g_score_band,g_fee_band,g_daily_band,g_score_new_band)) AS overdue_delta_jan
    FROM projection_rates p
), endpoints AS (
    SELECT credit_type,amount_band,base_band,loan_band,score_band,fee_band,daily_band,score_new_band,g_credit_type,g_amount_band,g_base_band,g_loan_band,g_score_band,g_fee_band,g_daily_band,g_score_new_band,scope,dimensions,projection_id,known_complete,group_key,
           SUM(CASE WHEN month='2026-01' THEN n ELSE 0 END) AS n_jan,SUM(CASE WHEN month='2026-01' THEN y ELSE 0 END) AS y_jan,SUM(CASE WHEN month='2026-01' THEN funded_loan_n ELSE 0 END) AS funded_loan_n_jan,SUM(CASE WHEN month='2026-01' THEN matured_loan_n ELSE 0 END) AS matured_loan_n_jan,SUM(CASE WHEN month='2026-01' THEN overdue_loan_n ELSE 0 END) AS overdue_loan_n_jan,SUM(CASE WHEN month='2026-01' THEN matured_remit_amt ELSE 0 END) AS matured_remit_amt_jan,SUM(CASE WHEN month='2026-01' THEN repaid_additive ELSE 0 END) AS repaid_additive_jan,SUM(CASE WHEN month='2026-01' THEN matured_repaid_missing_n ELSE 0 END) AS matured_repaid_missing_n_jan,SUM(CASE WHEN month='2026-01' THEN matured_status_missing_n ELSE 0 END) AS matured_status_missing_n_jan,MAX(CASE WHEN month='2026-01' THEN rate END) AS rate_jan,MAX(CASE WHEN month='2026-01' THEN profit_rate END) AS profit_rate_jan,MAX(CASE WHEN month='2026-01' THEN overdue_rate END) AS overdue_rate_jan,MAX(CASE WHEN month='2026-01' THEN parent_n END) AS parent_n_jan,SUM(CASE WHEN month='2026-07' THEN n ELSE 0 END) AS n_jul,SUM(CASE WHEN month='2026-07' THEN y ELSE 0 END) AS y_jul,SUM(CASE WHEN month='2026-07' THEN funded_loan_n ELSE 0 END) AS funded_loan_n_jul,SUM(CASE WHEN month='2026-07' THEN matured_loan_n ELSE 0 END) AS matured_loan_n_jul,SUM(CASE WHEN month='2026-07' THEN overdue_loan_n ELSE 0 END) AS overdue_loan_n_jul,SUM(CASE WHEN month='2026-07' THEN matured_remit_amt ELSE 0 END) AS matured_remit_amt_jul,SUM(CASE WHEN month='2026-07' THEN repaid_additive ELSE 0 END) AS repaid_additive_jul,SUM(CASE WHEN month='2026-07' THEN matured_repaid_missing_n ELSE 0 END) AS matured_repaid_missing_n_jul,SUM(CASE WHEN month='2026-07' THEN matured_status_missing_n ELSE 0 END) AS matured_status_missing_n_jul,MAX(CASE WHEN month='2026-07' THEN rate END) AS rate_jul,MAX(CASE WHEN month='2026-07' THEN profit_rate END) AS profit_rate_jul,MAX(CASE WHEN month='2026-07' THEN overdue_rate END) AS overdue_rate_jul,MAX(CASE WHEN month='2026-07' THEN parent_n END) AS parent_n_jul,SUM(CASE WHEN month='2026-08' THEN n ELSE 0 END) AS n_aug,SUM(CASE WHEN month='2026-08' THEN y ELSE 0 END) AS y_aug,SUM(CASE WHEN month='2026-08' THEN funded_loan_n ELSE 0 END) AS funded_loan_n_aug,SUM(CASE WHEN month='2026-08' THEN matured_loan_n ELSE 0 END) AS matured_loan_n_aug,SUM(CASE WHEN month='2026-08' THEN overdue_loan_n ELSE 0 END) AS overdue_loan_n_aug,SUM(CASE WHEN month='2026-08' THEN matured_remit_amt ELSE 0 END) AS matured_remit_amt_aug,SUM(CASE WHEN month='2026-08' THEN repaid_additive ELSE 0 END) AS repaid_additive_aug,SUM(CASE WHEN month='2026-08' THEN matured_repaid_missing_n ELSE 0 END) AS matured_repaid_missing_n_aug,SUM(CASE WHEN month='2026-08' THEN matured_status_missing_n ELSE 0 END) AS matured_status_missing_n_aug,MAX(CASE WHEN month='2026-08' THEN rate END) AS rate_aug,MAX(CASE WHEN month='2026-08' THEN profit_rate END) AS profit_rate_aug,MAX(CASE WHEN month='2026-08' THEN overdue_rate END) AS overdue_rate_aug,MAX(CASE WHEN month='2026-08' THEN parent_n END) AS parent_n_aug,SUM(CASE WHEN month='2026-09' THEN n ELSE 0 END) AS n_sep,SUM(CASE WHEN month='2026-09' THEN y ELSE 0 END) AS y_sep,SUM(CASE WHEN month='2026-09' THEN funded_loan_n ELSE 0 END) AS funded_loan_n_sep,SUM(CASE WHEN month='2026-09' THEN matured_loan_n ELSE 0 END) AS matured_loan_n_sep,SUM(CASE WHEN month='2026-09' THEN overdue_loan_n ELSE 0 END) AS overdue_loan_n_sep,SUM(CASE WHEN month='2026-09' THEN matured_remit_amt ELSE 0 END) AS matured_remit_amt_sep,SUM(CASE WHEN month='2026-09' THEN repaid_additive ELSE 0 END) AS repaid_additive_sep,SUM(CASE WHEN month='2026-09' THEN matured_repaid_missing_n ELSE 0 END) AS matured_repaid_missing_n_sep,SUM(CASE WHEN month='2026-09' THEN matured_status_missing_n ELSE 0 END) AS matured_status_missing_n_sep,MAX(CASE WHEN month='2026-09' THEN rate END) AS rate_sep,MAX(CASE WHEN month='2026-09' THEN profit_rate END) AS profit_rate_sep,MAX(CASE WHEN month='2026-09' THEN overdue_rate END) AS overdue_rate_sep,MAX(CASE WHEN month='2026-09' THEN parent_n END) AS parent_n_sep,SUM(CASE WHEN month='2026-10' THEN n ELSE 0 END) AS n_oct,SUM(CASE WHEN month='2026-10' THEN y ELSE 0 END) AS y_oct,SUM(CASE WHEN month='2026-10' THEN funded_loan_n ELSE 0 END) AS funded_loan_n_oct,SUM(CASE WHEN month='2026-10' THEN matured_loan_n ELSE 0 END) AS matured_loan_n_oct,SUM(CASE WHEN month='2026-10' THEN overdue_loan_n ELSE 0 END) AS overdue_loan_n_oct,SUM(CASE WHEN month='2026-10' THEN matured_remit_amt ELSE 0 END) AS matured_remit_amt_oct,SUM(CASE WHEN month='2026-10' THEN repaid_additive ELSE 0 END) AS repaid_additive_oct,SUM(CASE WHEN month='2026-10' THEN matured_repaid_missing_n ELSE 0 END) AS matured_repaid_missing_n_oct,SUM(CASE WHEN month='2026-10' THEN matured_status_missing_n ELSE 0 END) AS matured_status_missing_n_oct,MAX(CASE WHEN month='2026-10' THEN rate END) AS rate_oct,MAX(CASE WHEN month='2026-10' THEN profit_rate END) AS profit_rate_oct,MAX(CASE WHEN month='2026-10' THEN overdue_rate END) AS overdue_rate_oct,MAX(CASE WHEN month='2026-10' THEN parent_n END) AS parent_n_oct
    FROM projection_monthly GROUP BY credit_type,amount_band,base_band,loan_band,score_band,fee_band,daily_band,score_new_band,g_credit_type,g_amount_band,g_base_band,g_loan_band,g_score_band,g_fee_band,g_daily_band,g_score_new_band,scope,dimensions,projection_id,known_complete,group_key
), endpoint_rates AS (
    -- Parent denominators are independent joins, never group-dependent
    -- parent_seen values; groups absent in January retain the correct N_Jan.
    SELECT e.*,dj.n AS parent_jan,ds.n AS parent_sep,
           e.n_jan::numeric/NULLIF(dj.n,0) AS w_jan,e.n_sep::numeric/NULLIF(ds.n,0) AS w_sep,
           e.rate_jan AS r_jan,e.rate_sep AS r_sep
    FROM endpoints e
    JOIN parent_counts dj ON dj.month='2026-01' AND dj.scope=e.scope
      AND dj.credit_type IS NOT DISTINCT FROM e.credit_type AND dj.amount_band IS NOT DISTINCT FROM e.amount_band
    JOIN parent_counts ds ON ds.month='2026-09' AND ds.scope=e.scope
      AND ds.credit_type IS NOT DISTINCT FROM e.credit_type AND ds.amount_band IS NOT DISTINCT FROM e.amount_band
), comparisons AS (
    SELECT e.*,(r_sep-r_jan)*100 AS rate_change_pp,
           (y_sep::numeric/NULLIF(parent_sep,0)-y_jan::numeric/NULLIF(parent_jan,0))*100 AS context_net_pp,
           (y_sep::numeric/NULLIF((SELECT n FROM parent_counts WHERE month='2026-09' AND scope='overall'),0)
            -y_jan::numeric/NULLIF((SELECT n FROM parent_counts WHERE month='2026-01' AND scope='overall'),0))*100 AS global_net_pp,
           CASE WHEN n_jan>0 AND n_sep>0 THEN (w_jan+w_sep)/2*(r_sep-r_jan)*100 END AS within_pp,
           CASE WHEN n_jan>0 AND n_sep>0 THEN (r_jan+r_sep)/2*(w_sep-w_jan)*100 END AS mix_pp,
           CASE WHEN n_jan=0 OR n_sep=0 THEN
             (y_sep::numeric/NULLIF(parent_sep,0)-y_jan::numeric/NULLIF(parent_jan,0))*100 ELSE 0 END AS entry_exit_pp,
           n_jan>=100 AND n_sep>=100 AS endpoint_sample_ge100,
           CASE WHEN n_jan=0 AND n_sep=0 THEN 'absent_at_both_endpoints' WHEN n_jan=0 THEN 'new'
                WHEN n_sep=0 THEN 'disappeared' ELSE 'shared' END AS state,
           CASE WHEN n_jan<100 OR n_jul<100 OR n_aug<100 OR n_sep<100 THEN 'insufficient_sample'
                WHEN rate_jul<r_jan-1e-10 AND rate_aug<r_jan-1e-10 AND rate_sep<r_jan-1e-10 THEN 'all_below_jan'
                WHEN rate_jul>r_jan+1e-10 AND rate_aug>r_jan+1e-10 AND rate_sep>r_jan+1e-10 THEN 'all_above_jan'
                ELSE 'mixed_or_flat' END AS review_status,
           (profit_rate_sep-profit_rate_jan)*100 AS profit_rate_change_pp,
           (overdue_rate_sep-overdue_rate_jan)*100 AS overdue_rate_change_pp
    FROM endpoint_rates e
), rank_inputs AS (
    SELECT c.*,n_jan AS "nJan",n_sep AS "nSep",y_jan AS "yJan",y_sep AS "ySep",
           r_jan AS "rJan",r_sep AS "rSep",rate_change_pp AS delta,context_net_pp AS net,
           known_complete AND endpoint_sample_ge100 AS conversion_rank_eligible,
           known_complete AND endpoint_sample_ge100 AND review_status='all_below_jan' AS confirmed_negative,
           known_complete AND endpoint_sample_ge100 AND review_status='all_above_jan' AS confirmed_positive,
           known_complete AND matured_loan_n_jan>=100 AND matured_loan_n_sep>=100
             AND matured_remit_amt_jan>0 AND matured_remit_amt_sep>0
             AND matured_repaid_missing_n_jan=0 AND matured_repaid_missing_n_sep=0 AS financial_profit_eligible,
           known_complete AND matured_loan_n_jan>=100 AND matured_loan_n_sep>=100
             AND matured_remit_amt_jan>0 AND matured_remit_amt_sep>0
             AND matured_status_missing_n_jan=0 AND matured_status_missing_n_sep=0 AS financial_overdue_eligible
    FROM comparisons c
), single_projection AS (
    SELECT p.*,COALESCE(base_band,loan_band,score_band,fee_band,daily_band,score_new_band) AS level,
           CASE WHEN g_base_band=0 THEN 'base_band' WHEN g_loan_band=0 THEN 'loan_band' WHEN g_score_band=0 THEN 'score_band' WHEN g_fee_band=0 THEN 'fee_band' WHEN g_daily_band=0 THEN 'daily_band' WHEN g_score_new_band=0 THEN 'score_new_band' END AS dimension
    FROM projection_monthly p WHERE ARRAY_LENGTH(dimensions,1)=1
), single_counts AS (
    SELECT p.month,p.scope,COALESCE(p.credit_type,'整体') AS credit_type,COALESCE(p.amount_band,'总计') AS amount_band,
           p.dimension,p.level,FALSE AS is_total,p.n,p.y,p.funded_loan_n,p.matured_loan_n,p.overdue_loan_n,p.matured_remit_amt,p.repaid_additive,p.matured_repaid_missing_n,p.matured_status_missing_n,p.parent_n
    FROM single_projection p
    UNION ALL
    SELECT p.month,p.scope,COALESCE(p.credit_type,'整体'),COALESCE(p.amount_band,'总计'),d.dimension,'全部',TRUE,
           p.n,p.y,p.funded_loan_n,p.matured_loan_n,p.overdue_loan_n,p.matured_remit_amt,p.repaid_additive,p.matured_repaid_missing_n,p.matured_status_missing_n,p.n AS parent_n
    FROM parent_counts p CROSS JOIN (SELECT DISTINCT dimension FROM dimension_levels) d
), single_rates AS (
    SELECT p.*,p.n::numeric/NULLIF(parent_n,0) AS share,p.y::numeric/NULLIF(p.n,0) AS rate,
           p.funded_loan_n::numeric/NULLIF(p.y,0) AS funded_coverage,
           p.matured_loan_n::numeric/NULLIF(p.funded_loan_n,0) AS maturity_coverage,
           p.matured_loan_n::numeric/NULLIF(p.n,0) AS due_event_coverage,
           CASE WHEN p.matured_repaid_missing_n=0 THEN p.repaid_additive END AS matured_repaid_amt,
           CASE WHEN p.matured_repaid_missing_n=0 THEN p.repaid_additive-p.matured_remit_amt END AS profit_amt,
           CASE WHEN p.matured_repaid_missing_n=0 THEN
             (p.repaid_additive-p.matured_remit_amt)/NULLIF(p.matured_remit_amt,0) END AS profit_rate,
           CASE WHEN p.matured_status_missing_n=0 THEN
             p.overdue_loan_n::numeric/NULLIF(p.matured_loan_n,0) END AS overdue_rate,p.month='2026-10' AS is_partial FROM single_counts p
), single_view AS (
    SELECT p.*,100*(rate-MAX(CASE WHEN month='2026-01' THEN rate END) OVER
      (PARTITION BY scope,credit_type,amount_band,dimension,level,is_total)) AS delta_jan,
      100*(profit_rate-MAX(CASE WHEN month='2026-01' THEN profit_rate END) OVER
      (PARTITION BY scope,credit_type,amount_band,dimension,level,is_total)) AS profit_delta_jan,
      100*(overdue_rate-MAX(CASE WHEN month='2026-01' THEN overdue_rate END) OVER
      (PARTITION BY scope,credit_type,amount_band,dimension,level,is_total)) AS overdue_delta_jan
    FROM single_rates p
), pair_specs(row_dimension,column_dimension) AS (VALUES
    ('base_band','loan_band'),
    ('base_band','score_band'),
    ('base_band','fee_band'),
    ('base_band','daily_band'),
    ('base_band','score_new_band'),
    ('loan_band','score_band'),
    ('loan_band','fee_band'),
    ('loan_band','daily_band'),
    ('loan_band','score_new_band'),
    ('score_band','fee_band'),
    ('score_band','daily_band'),
    ('score_band','score_new_band'),
    ('fee_band','daily_band'),
    ('fee_band','score_new_band'),
    ('daily_band','score_new_band')),
pair_counts AS (
    SELECT m.month,s.row_dimension,s.column_dimension,r.level AS row_level,l.level AS column_level,
           s.row_dimension||'__'||s.column_dimension||'@overall' AS projection_id,
           COALESCE(p.n,0) AS n,
           COALESCE(p.y,0) AS y,
           COALESCE(p.funded_loan_n,0) AS funded_loan_n,
           COALESCE(p.matured_loan_n,0) AS matured_loan_n,
           COALESCE(p.overdue_loan_n,0) AS overdue_loan_n,
           COALESCE(p.matured_remit_amt,0) AS matured_remit_amt,
           COALESCE(p.repaid_additive,0) AS repaid_additive,
           COALESCE(p.matured_repaid_missing_n,0) AS matured_repaid_missing_n,
           COALESCE(p.matured_status_missing_n,0) AS matured_status_missing_n,d.n AS parent_n
    FROM months m CROSS JOIN pair_specs s
    JOIN dimension_levels r ON r.dimension=s.row_dimension
    JOIN dimension_levels l ON l.dimension=s.column_dimension
    JOIN parent_counts d ON d.month=m.month AND d.scope='overall'
    LEFT JOIN projection_monthly p ON p.month=m.month AND p.scope='overall'
      AND p.dimensions=ARRAY[s.row_dimension,s.column_dimension]
      AND p.group_key->>s.row_dimension=r.level AND p.group_key->>s.column_dimension=l.level
), pair_rates AS (
    SELECT p.*,p.n::numeric/NULLIF(parent_n,0) AS share,p.y::numeric/NULLIF(p.n,0) AS rate,
           p.funded_loan_n::numeric/NULLIF(p.y,0) AS funded_coverage,
           p.matured_loan_n::numeric/NULLIF(p.funded_loan_n,0) AS maturity_coverage,
           p.matured_loan_n::numeric/NULLIF(p.n,0) AS due_event_coverage,
           CASE WHEN p.matured_repaid_missing_n=0 THEN p.repaid_additive END AS matured_repaid_amt,
           CASE WHEN p.matured_repaid_missing_n=0 THEN p.repaid_additive-p.matured_remit_amt END AS profit_amt,
           CASE WHEN p.matured_repaid_missing_n=0 THEN
             (p.repaid_additive-p.matured_remit_amt)/NULLIF(p.matured_remit_amt,0) END AS profit_rate,
           CASE WHEN p.matured_status_missing_n=0 THEN
             p.overdue_loan_n::numeric/NULLIF(p.matured_loan_n,0) END AS overdue_rate,month='2026-10' AS is_partial FROM pair_counts p
), pair_monthly AS (
    SELECT p.*,100*(rate-MAX(CASE WHEN month='2026-01' THEN rate END) OVER
       (PARTITION BY row_dimension,column_dimension,row_level,column_level)) AS delta_jan,
       100*(profit_rate-MAX(CASE WHEN month='2026-01' THEN profit_rate END) OVER
       (PARTITION BY row_dimension,column_dimension,row_level,column_level)) AS profit_delta_jan,
       100*(overdue_rate-MAX(CASE WHEN month='2026-01' THEN overdue_rate END) OVER
       (PARTITION BY row_dimension,column_dimension,row_level,column_level)) AS overdue_delta_jan
    FROM pair_rates p
), family_cells_raw AS (
    SELECT 'legacy_five' AS family,c.month,c.credit_type,c.amount_band,jsonb_build_object('base_band',c.base_band,'loan_band',c.loan_band,'score_band',c.score_band,'fee_band',c.fee_band,'daily_band',c.daily_band) AS cell_key,
           (c.base_band NOT IN ('缺失','无效','冲突','缺失/无效') AND c.loan_band NOT IN ('缺失','无效','冲突','缺失/无效') AND c.score_band NOT IN ('缺失','无效','冲突','缺失/无效') AND c.fee_band NOT IN ('缺失','无效','冲突','缺失/无效') AND c.daily_band NOT IN ('缺失','无效','冲突','缺失/无效')) AS known_complete,SUM(c.n) AS n,
           SUM(c.y) AS y,
           SUM(c.funded_loan_n) AS funded_loan_n,
           SUM(c.matured_loan_n) AS matured_loan_n,
           SUM(c.overdue_loan_n) AS overdue_loan_n,
           SUM(c.matured_remit_amt) AS matured_remit_amt,
           SUM(c.repaid_additive) AS repaid_additive,
           SUM(c.matured_repaid_missing_n) AS matured_repaid_missing_n,
           SUM(c.matured_status_missing_n) AS matured_status_missing_n
    FROM cube_inputs c GROUP BY c.month,c.credit_type,c.amount_band,c.base_band,c.loan_band,c.score_band,c.fee_band,c.daily_band UNION ALL SELECT 'new_score_five' AS family,c.month,c.credit_type,c.amount_band,jsonb_build_object('base_band',c.base_band,'loan_band',c.loan_band,'score_new_band',c.score_new_band,'fee_band',c.fee_band,'daily_band',c.daily_band) AS cell_key,
           (c.base_band NOT IN ('缺失','无效','冲突','缺失/无效') AND c.loan_band NOT IN ('缺失','无效','冲突','缺失/无效') AND c.score_new_band NOT IN ('缺失','无效','冲突','缺失/无效') AND c.fee_band NOT IN ('缺失','无效','冲突','缺失/无效') AND c.daily_band NOT IN ('缺失','无效','冲突','缺失/无效')) AS known_complete,SUM(c.n) AS n,
           SUM(c.y) AS y,
           SUM(c.funded_loan_n) AS funded_loan_n,
           SUM(c.matured_loan_n) AS matured_loan_n,
           SUM(c.overdue_loan_n) AS overdue_loan_n,
           SUM(c.matured_remit_amt) AS matured_remit_amt,
           SUM(c.repaid_additive) AS repaid_additive,
           SUM(c.matured_repaid_missing_n) AS matured_repaid_missing_n,
           SUM(c.matured_status_missing_n) AS matured_status_missing_n
    FROM cube_inputs c GROUP BY c.month,c.credit_type,c.amount_band,c.base_band,c.loan_band,c.score_new_band,c.fee_band,c.daily_band UNION ALL SELECT 'six_labels' AS family,c.month,c.credit_type,c.amount_band,jsonb_build_object('base_band',c.base_band,'loan_band',c.loan_band,'score_band',c.score_band,'fee_band',c.fee_band,'daily_band',c.daily_band,'score_new_band',c.score_new_band) AS cell_key,
           (c.base_band NOT IN ('缺失','无效','冲突','缺失/无效') AND c.loan_band NOT IN ('缺失','无效','冲突','缺失/无效') AND c.score_band NOT IN ('缺失','无效','冲突','缺失/无效') AND c.fee_band NOT IN ('缺失','无效','冲突','缺失/无效') AND c.daily_band NOT IN ('缺失','无效','冲突','缺失/无效') AND c.score_new_band NOT IN ('缺失','无效','冲突','缺失/无效')) AS known_complete,SUM(c.n) AS n,
           SUM(c.y) AS y,
           SUM(c.funded_loan_n) AS funded_loan_n,
           SUM(c.matured_loan_n) AS matured_loan_n,
           SUM(c.overdue_loan_n) AS overdue_loan_n,
           SUM(c.matured_remit_amt) AS matured_remit_amt,
           SUM(c.repaid_additive) AS repaid_additive,
           SUM(c.matured_repaid_missing_n) AS matured_repaid_missing_n,
           SUM(c.matured_status_missing_n) AS matured_status_missing_n
    FROM cube_inputs c GROUP BY c.month,c.credit_type,c.amount_band,c.base_band,c.loan_band,c.score_band,c.fee_band,c.daily_band,c.score_new_band
), standard_cells_raw AS (
    SELECT s.spec_id,s.family,s.scope,s.credit_type,s.amount_band,c.cell_key,c.known_complete,c.month,SUM(c.n) AS n,
           SUM(c.y) AS y,
           SUM(c.funded_loan_n) AS funded_loan_n,
           SUM(c.matured_loan_n) AS matured_loan_n,
           SUM(c.overdue_loan_n) AS overdue_loan_n,
           SUM(c.matured_remit_amt) AS matured_remit_amt,
           SUM(c.repaid_additive) AS repaid_additive,
           SUM(c.matured_repaid_missing_n) AS matured_repaid_missing_n,
           SUM(c.matured_status_missing_n) AS matured_status_missing_n
    FROM standard_specs s JOIN family_cells_raw c ON c.family=s.family AND c.month IN ('2026-01','2026-09')
      AND (s.credit_type IS NULL OR c.credit_type=s.credit_type) AND (s.amount_band IS NULL OR c.amount_band=s.amount_band)
    GROUP BY s.spec_id,s.family,s.scope,s.credit_type,s.amount_band,c.cell_key,c.known_complete,c.month
), standard_cell_endpoints AS (
    SELECT spec_id,family,scope,credit_type,amount_band,cell_key,known_complete,
      SUM(CASE WHEN month='2026-01' THEN n ELSE 0 END) AS n_jan,SUM(CASE WHEN month='2026-01' THEN y ELSE 0 END) AS y_jan,SUM(CASE WHEN month='2026-01' THEN funded_loan_n ELSE 0 END) AS funded_loan_n_jan,SUM(CASE WHEN month='2026-01' THEN matured_loan_n ELSE 0 END) AS matured_loan_n_jan,SUM(CASE WHEN month='2026-01' THEN overdue_loan_n ELSE 0 END) AS overdue_loan_n_jan,SUM(CASE WHEN month='2026-01' THEN matured_remit_amt ELSE 0 END) AS matured_remit_amt_jan,SUM(CASE WHEN month='2026-01' THEN repaid_additive ELSE 0 END) AS repaid_additive_jan,SUM(CASE WHEN month='2026-01' THEN matured_repaid_missing_n ELSE 0 END) AS matured_repaid_missing_n_jan,SUM(CASE WHEN month='2026-01' THEN matured_status_missing_n ELSE 0 END) AS matured_status_missing_n_jan,SUM(CASE WHEN month='2026-09' THEN n ELSE 0 END) AS n_sep,SUM(CASE WHEN month='2026-09' THEN y ELSE 0 END) AS y_sep,SUM(CASE WHEN month='2026-09' THEN funded_loan_n ELSE 0 END) AS funded_loan_n_sep,SUM(CASE WHEN month='2026-09' THEN matured_loan_n ELSE 0 END) AS matured_loan_n_sep,SUM(CASE WHEN month='2026-09' THEN overdue_loan_n ELSE 0 END) AS overdue_loan_n_sep,SUM(CASE WHEN month='2026-09' THEN matured_remit_amt ELSE 0 END) AS matured_remit_amt_sep,SUM(CASE WHEN month='2026-09' THEN repaid_additive ELSE 0 END) AS repaid_additive_sep,SUM(CASE WHEN month='2026-09' THEN matured_repaid_missing_n ELSE 0 END) AS matured_repaid_missing_n_sep,SUM(CASE WHEN month='2026-09' THEN matured_status_missing_n ELSE 0 END) AS matured_status_missing_n_sep
    FROM standard_cells_raw GROUP BY spec_id,family,scope,credit_type,amount_band,cell_key,known_complete
), standard_eligible AS (
    SELECT c.*,known_complete AND n_jan>=20 AND n_sep>=20 AS conversion_common,
       known_complete AND matured_loan_n_jan>=20 AND matured_loan_n_sep>=20
        AND matured_remit_amt_jan>0 AND matured_remit_amt_sep>0
        AND matured_repaid_missing_n_jan=0 AND matured_repaid_missing_n_sep=0
        AND matured_status_missing_n_jan=0 AND matured_status_missing_n_sep=0 AS financial_common
    FROM standard_cell_endpoints c
), standard_common_totals AS (
    SELECT spec_id,
       SUM(CASE WHEN conversion_common THEN 1 ELSE 0 END) AS strata,
       SUM(CASE WHEN conversion_common THEN n_jan ELSE 0 END) AS n_jan_common,
       SUM(CASE WHEN conversion_common THEN n_sep ELSE 0 END) AS n_sep_common,
       SUM(CASE WHEN conversion_common THEN y_jan ELSE 0 END) AS y_jan_common,
       SUM(CASE WHEN financial_common THEN 1 ELSE 0 END) AS financial_strata,
       SUM(CASE WHEN financial_common THEN matured_loan_n_jan ELSE 0 END) AS due_jan_common,
       SUM(CASE WHEN financial_common THEN matured_loan_n_sep ELSE 0 END) AS due_sep_common,
       SUM(CASE WHEN financial_common THEN matured_remit_amt_jan ELSE 0 END) AS remit_jan_common,
       SUM(CASE WHEN financial_common THEN matured_remit_amt_sep ELSE 0 END) AS remit_sep_common,
       SUM(CASE WHEN financial_common THEN repaid_additive_jan ELSE 0 END) AS repaid_jan_common,
       SUM(CASE WHEN financial_common THEN overdue_loan_n_jan ELSE 0 END) AS overdue_jan_common
    FROM standard_eligible GROUP BY spec_id
), standardized_cell AS (
    SELECT c.*,t.strata,t.financial_strata,
       CASE WHEN conversion_common THEN c.n_jan::numeric/NULLIF(t.n_jan_common,0) END AS "wJan",
       c.y_jan::numeric/NULLIF(c.n_jan,0) AS "rJan",c.y_sep::numeric/NULLIF(c.n_sep,0) AS "rSep",
       CASE WHEN financial_common THEN c.matured_remit_amt_jan/NULLIF(t.remit_jan_common,0) END AS remit_weight_jan,
       CASE WHEN financial_common THEN c.matured_loan_n_jan::numeric/NULLIF(t.due_jan_common,0) END AS due_weight_jan,
       CASE WHEN c.matured_repaid_missing_n_jan=0 THEN
        (c.repaid_additive_jan-c.matured_remit_amt_jan)/NULLIF(c.matured_remit_amt_jan,0) END AS profit_rate_jan,
       CASE WHEN c.matured_repaid_missing_n_sep=0 THEN
        (c.repaid_additive_sep-c.matured_remit_amt_sep)/NULLIF(c.matured_remit_amt_sep,0) END AS profit_rate_sep,
       CASE WHEN c.matured_status_missing_n_jan=0 THEN c.overdue_loan_n_jan::numeric/NULLIF(c.matured_loan_n_jan,0) END AS overdue_rate_jan,
       CASE WHEN c.matured_status_missing_n_sep=0 THEN c.overdue_loan_n_sep::numeric/NULLIF(c.matured_loan_n_sep,0) END AS overdue_rate_sep
    FROM standard_eligible c JOIN standard_common_totals t ON t.spec_id=c.spec_id
), standard_weighted AS (
    SELECT spec_id,
      SUM(CASE WHEN conversion_common THEN "wJan"*"rSep" END) AS r_sep_standardized,
      SUM(CASE WHEN financial_common THEN remit_weight_jan*profit_rate_sep END) AS profit_sep_standardized,
      SUM(CASE WHEN financial_common THEN due_weight_jan*overdue_rate_sep END) AS overdue_sep_standardized
    FROM standardized_cell GROUP BY spec_id
), standard_summary_base AS (
    SELECT s.*,STRING_TO_ARRAY(f.dimensions_text,'|') AS dimensions,f.effective_factors,
      COALESCE(t.strata,0) AS strata,COALESCE(t.n_jan_common,0) AS "nJan_common",COALESCE(t.n_sep_common,0) AS "nSep_common",
      t.n_jan_common::numeric/NULLIF(j.n,0) AS "coverageJan",t.n_sep_common::numeric/NULLIF(e.n,0) AS "coverageSep",
      t.y_jan_common::numeric/NULLIF(t.n_jan_common,0) AS "rJan_common",w.r_sep_standardized AS "rSep_standardized",
      100*(w.r_sep_standardized-t.y_jan_common::numeric/NULLIF(t.n_jan_common,0)) AS delta_pp,
      20 AS cell_min_n,COALESCE(t.financial_strata,0) AS financial_strata,
      COALESCE(t.due_jan_common,0) AS due_jan_common,COALESCE(t.due_sep_common,0) AS due_sep_common,
      COALESCE(t.remit_jan_common,0) AS remit_jan_common,COALESCE(t.remit_sep_common,0) AS remit_sep_common,
      t.due_jan_common::numeric/NULLIF(j.matured_loan_n,0) AS coverage_due_jan,
      t.due_sep_common::numeric/NULLIF(e.matured_loan_n,0) AS coverage_due_sep,
      t.remit_jan_common/NULLIF(j.matured_remit_amt,0) AS coverage_remit_jan,
      t.remit_sep_common/NULLIF(e.matured_remit_amt,0) AS coverage_remit_sep,
      (t.repaid_jan_common-t.remit_jan_common)/NULLIF(t.remit_jan_common,0) AS profit_jan_common,
      w.profit_sep_standardized,
      100*(w.profit_sep_standardized-(t.repaid_jan_common-t.remit_jan_common)/NULLIF(t.remit_jan_common,0)) AS profit_delta_pp,
      t.overdue_jan_common::numeric/NULLIF(t.due_jan_common,0) AS overdue_jan_common,w.overdue_sep_standardized,
      100*(w.overdue_sep_standardized-t.overdue_jan_common::numeric/NULLIF(t.due_jan_common,0)) AS overdue_delta_pp
    FROM standard_specs s JOIN family_definitions f ON f.family=s.family
    LEFT JOIN standard_common_totals t ON t.spec_id=s.spec_id LEFT JOIN standard_weighted w ON w.spec_id=s.spec_id
    JOIN parent_counts j ON j.month='2026-01' AND j.scope=s.scope AND j.credit_type IS NOT DISTINCT FROM s.credit_type AND j.amount_band IS NOT DISTINCT FROM s.amount_band
    JOIN parent_counts e ON e.month='2026-09' AND e.scope=s.scope AND e.credit_type IS NOT DISTINCT FROM s.credit_type AND e.amount_band IS NOT DISTINCT FROM s.amount_band
), standardized_summary AS (
    SELECT s.*,jsonb_strip_nulls(jsonb_build_object('credit_type',s.credit_type,'amount_band',s.amount_band)) AS filters,
      jsonb_build_object('strata',financial_strata,'dueJan_common',due_jan_common,'dueSep_common',due_sep_common,
       'remitJan_common',remit_jan_common,'remitSep_common',remit_sep_common,'coverage_dueJan',coverage_due_jan,
       'coverage_dueSep',coverage_due_sep,'coverage_remitJan',coverage_remit_jan,'coverage_remitSep',coverage_remit_sep,
       'profitJan_common',profit_jan_common,'profitSep_standardized',profit_sep_standardized,'profit_delta_pp',profit_delta_pp,
       'overdueJan_common',overdue_jan_common,'overdueSep_standardized',overdue_sep_standardized,'overdue_delta_pp',overdue_delta_pp) AS finance
    FROM standard_summary_base s
), zero_catalog_audit AS (
    SELECT month,risk_product,settled_product_no,current_fee::text AS current_fee,previous_fee::text AS previous_fee,
      COUNT(*) AS n,SUM(has_d0_apply) AS y FROM labeled WHERE current_fee=0 OR previous_fee=0
    GROUP BY month,risk_product,settled_product_no,current_fee,previous_fee
), zero_products AS (
    SELECT DISTINCT t.product_no FROM product_tokens t JOIN enriched e
      ON e.user_id=t.user_id AND e.credit_serial_id=t.credit_serial_id AND e.vir_time=t.vir_time WHERE e.current_fee=0
    UNION SELECT DISTINCT BTRIM(settled_product_no) FROM enriched WHERE previous_fee=0
), compatibility_audit AS (
    SELECT '上笔次数与历史计数不同'::text AS key,COUNT(*)::bigint AS n FROM observed WHERE settled_loan_n<>successful_loan_n
    UNION ALL SELECT '完整五维事件',COUNT(*) FROM observed WHERE score_status='有效' AND loan_band<>'缺失/无效' AND fee_band<>'缺失' AND daily_band<>'缺失'
    UNION ALL SELECT '完整六标签事件',COUNT(*) FROM observed WHERE score_status='有效' AND loan_band<>'缺失/无效' AND fee_band<>'缺失' AND daily_band<>'缺失' AND score_new_band NOT IN ('缺失','无效','冲突')
    UNION ALL SELECT '当前息费为零',COUNT(*) FROM observed WHERE current_fee=0
    UNION ALL SELECT '上笔息费为零',COUNT(*) FROM observed WHERE previous_fee=0
    UNION ALL SELECT '当前日息为零',COUNT(*) FROM observed WHERE current_daily=0
    UNION ALL SELECT '上笔日息为零',COUNT(*) FROM observed WHERE previous_daily=0
    UNION ALL SELECT '前后任一息费为零',COUNT(*) FROM observed WHERE current_fee=0 OR previous_fee=0
    UNION ALL SELECT '多获额产品',COUNT(*) FROM observed WHERE option_n>1
    UNION ALL SELECT '3个及以上获额产品',COUNT(*) FROM observed WHERE option_n>=3
    UNION ALL SELECT '原始合格获额去订单重后',COUNT(*) FROM raw_offer
    UNION ALL SELECT '20秒合批保留获额',COUNT(*) FROM dedup_offer
    UNION ALL SELECT '同日结清0在贷配对',COUNT(*) FROM offer_settlement_pair
    UNION ALL SELECT '产品目录重复键',COUNT(*) FROM (SELECT product_no FROM catalog GROUP BY product_no HAVING COUNT(*)>1) q
), source_metadata AS (
    SELECT CURRENT_TIMESTAMP::text AS snapshot,'2026-10-13T20:09:05.673903-06:00'::text AS reference_snapshot,
      '2026-10-13'::text AS business_observation_date,'America/Belize'::text AS timezone,
      '2026-01-01'::text AS start_date,'2026-10-11'::text AS end_date,'2026-10-12'::text AS exclusive_end,
      '口径1｜用户获额后当天首次提单'::text AS definition,'d0'::text AS postloan_attribution_key,
      '口径1当天首次实际提单订单(user_id+apply_serial_id)，成功放款且已到期'::text AS postloan_attribution,
      'due_date>2000-01-01 and due_date<2026-10-13; T0 event month'::text AS due_date_condition,
      'MXN'::text AS currency,TRUE AS original_exclusion_rule_preserved,
      '{"credit_type":["增加","降低","不变"],"amount_band":["<500","500–1000","1000–2000","2000–3000","≥3000"],"base_band":["0–1000","1000–2000","2000–5000","5000–10000","≥10000"],"loan_band":["1次","2次","3次","4次","5次",">5次","缺失/无效"],"score_band":["1–529","529–569","569–3000","缺失","无效","冲突"],"fee_band":["增加0–5pp","增加5–10pp","增加≥10pp","不变","减少0–5pp","减少5–10pp","减少≥10pp","缺失"],"daily_band":["增加0–0.25pp","增加0.25–0.5pp","增加≥0.5pp","不变","减少0–0.25pp","减少0.25–0.5pp","减少≥0.5pp","缺失"],"score_new_band":["<505","505–535","≥535","缺失","无效","冲突"]}'::jsonb AS labels,
      63 AS nonempty_subsets,252 AS scope_projections,24 AS scope_contexts,15 AS pair_count,18 AS standardization_specs,
      'repaid_amt and loan_status_code are current; fixed maturity cutoff cannot restore a historical ledger/status snapshot; product catalog and model also unversioned'::text AS history_limit,
      'October covers T0 Jan1-Oct11; maturity subset only, not historical D7 risk'::text AS partial_month_limit,
      'Only mutually exclusive groups within one projection/context add; cross projections/rankings overlap'::text AS addition_policy,
      'legacy_five/new_score_five: five factors; six_labels combines both cuts of one score, not six independent factors'::text AS factor_limit
)
SELECT 'cube'::text AS kind,ROW_TO_JSON(t)::text AS payload FROM cube_output t
UNION ALL SELECT 'control',ROW_TO_JSON(t)::text FROM controls t
UNION ALL SELECT 'audit',ROW_TO_JSON(t)::text FROM audit t
UNION ALL SELECT 'audit',ROW_TO_JSON(t)::text FROM compatibility_audit t
UNION ALL SELECT 'scope_control',ROW_TO_JSON(t)::text FROM parent_metrics t
UNION ALL SELECT 'projection_monthly',ROW_TO_JSON(t)::text FROM projection_monthly t
UNION ALL SELECT 'comparison',ROW_TO_JSON(t)::text FROM comparisons t
UNION ALL SELECT 'rank_input',ROW_TO_JSON(t)::text FROM rank_inputs t
UNION ALL SELECT 'single_view',ROW_TO_JSON(t)::text FROM single_view t
UNION ALL SELECT 'pair_monthly',ROW_TO_JSON(t)::text FROM pair_monthly t
UNION ALL SELECT 'standardized_cell',ROW_TO_JSON(t)::text FROM standardized_cell t
UNION ALL SELECT 'standardized_summary',ROW_TO_JSON(t)::text FROM standardized_summary t
UNION ALL SELECT 'zero_catalog_audit',ROW_TO_JSON(t)::text FROM zero_catalog_audit t
UNION ALL SELECT 'zero_catalog_product',ROW_TO_JSON(t)::text FROM catalog t WHERE product_no IN (SELECT product_no FROM zero_products)
UNION ALL SELECT 'metadata',ROW_TO_JSON(t)::text FROM source_metadata t;
COMMIT;
