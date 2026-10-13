-- 完整只读PGSQL。五维31子集×4范围=124投影；未纳入样本不加回。
-- g_字段=1表示该维度被汇总，=0表示该维度参与分组。
-- n/y为事件分母/当天首次提单分子；rate/share为小数；*_pp为百分点。
-- 同一父范围、同一互斥投影可加总；不同投影绝不能相加。
-- 新增/消失组合的率差为NULL，其净贡献归entry_exit。
-- CASE仅完全相等才不变；多产品MAX息费与MIN日息独立。
SET TIME ZONE 'America/Belize';
SET query_dop=1;
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
           o.is_repaid, o.loan_status_code, o.product_no, o.remit_succ_rnb
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
), cube AS (
    SELECT month,credit_type,amount_band,base_band,loan_band,score_band,fee_band,daily_band,
           COUNT(*) AS n,SUM(has_d0_apply) AS y
    FROM labeled GROUP BY month,credit_type,amount_band,base_band,loan_band,score_band,fee_band,daily_band
), controls AS (
    SELECT TO_CHAR(t0_month,'YYYY-MM') AS month,credit_change_type,COUNT(*) AS n,SUM(has_d0_apply) AS y
    FROM t0_base GROUP BY t0_month,credit_change_type
), audit AS (
    SELECT '严格T0事件数'::text AS key,COUNT(*)::bigint AS n FROM strict_t0
    UNION ALL SELECT '额度可分析T0事件数',COUNT(*) FROM t0_base
    UNION ALL SELECT '被原额度规则排除', (SELECT COUNT(*) FROM strict_t0)-(SELECT COUNT(*) FROM t0_base)
    UNION ALL SELECT '截至10月8日严格T0',COUNT(*) FROM strict_t0 WHERE vir_date<DATE '2026-10-09'
    UNION ALL SELECT '截至10月8日可分析T0',COUNT(*) FROM t0_base WHERE vir_date<DATE '2026-10-09'
    UNION ALL SELECT '截至10月8日D0',SUM(has_d0_apply) FROM t0_base WHERE vir_date<DATE '2026-10-09'
    UNION ALL SELECT '丰富字段后事件数',COUNT(*) FROM labeled
    UNION ALL SELECT '重复事件键',COUNT(*) FROM (SELECT user_id,credit_serial_id,vir_time FROM labeled GROUP BY user_id,credit_serial_id,vir_time HAVING COUNT(*)>1) q
    UNION ALL SELECT '重复提单归属',COUNT(*) FROM (SELECT apply_serial_id FROM t0_base WHERE has_d0_apply=1 GROUP BY apply_serial_id HAVING COUNT(*)>1) q
    UNION ALL SELECT '上笔次数与历史计数不同',COUNT(*) FROM labeled WHERE settled_loan_n<>successful_loan_n
    UNION ALL SELECT '上笔次数缺失无效',COUNT(*) FROM labeled WHERE loan_band='缺失/无效'
    UNION ALL SELECT '410评分缺失',COUNT(*) FROM labeled WHERE score_band='缺失'
    UNION ALL SELECT '410评分无效',COUNT(*) FROM labeled WHERE score_band='无效'
    UNION ALL SELECT '410评分冲突',COUNT(*) FROM labeled WHERE score_band='冲突'
    UNION ALL SELECT '同订单多条模型记录',COUNT(*) FROM labeled WHERE row_n>1
    UNION ALL SELECT '当前产品未全部匹配',COUNT(*) FROM labeled WHERE option_n IS NULL OR option_n<>matched_n
    UNION ALL SELECT '上一笔产品未匹配',COUNT(*) FROM labeled WHERE previous_matched_product IS NULL
    UNION ALL SELECT '息费维度缺失',COUNT(*) FROM labeled WHERE fee_band='缺失'
    UNION ALL SELECT '日息维度缺失',COUNT(*) FROM labeled WHERE daily_band='缺失'
    UNION ALL SELECT '当前息费为零',COUNT(*) FROM labeled WHERE current_fee=0
    UNION ALL SELECT '上笔息费为零',COUNT(*) FROM labeled WHERE previous_fee=0
    UNION ALL SELECT '当前日息为零',COUNT(*) FROM labeled WHERE current_daily=0
    UNION ALL SELECT '上笔日息为零',COUNT(*) FROM labeled WHERE previous_daily=0
    UNION ALL SELECT '多获额产品',COUNT(*) FROM labeled WHERE option_n>1
    UNION ALL SELECT '3个及以上获额产品',COUNT(*) FROM labeled WHERE option_n>=3
    UNION ALL SELECT '完整五维事件',COUNT(*) FROM labeled WHERE score_status='有效' AND loan_band<>'缺失/无效' AND fee_band<>'缺失' AND daily_band<>'缺失'
    UNION ALL SELECT 'D0窗口异常',COUNT(*) FROM t0_base WHERE has_d0_apply=1 AND (d0_apply_time<vir_time OR d0_apply_time>=vir_date+1)
), zero_catalog_audit AS (
    SELECT month,risk_product,settled_product_no,current_fee::text AS current_fee,
           previous_fee::text AS previous_fee,COUNT(*) AS n,SUM(has_d0_apply) AS y
    FROM labeled WHERE current_fee=0 OR previous_fee=0
    GROUP BY month,risk_product,settled_product_no,current_fee,previous_fee
), projection_monthly AS (
    SELECT month,credit_type,amount_band,base_band,loan_band,score_band,fee_band,daily_band,GROUPING(credit_type) AS g_credit_type,GROUPING(amount_band) AS g_amount_band,GROUPING(base_band) AS g_base_band,GROUPING(loan_band) AS g_loan_band,GROUPING(score_band) AS g_score_band,GROUPING(fee_band) AS g_fee_band,GROUPING(daily_band) AS g_daily_band,SUM(n) AS n,SUM(y) AS y
    FROM cube GROUP BY GROUPING SETS (
    (month,base_band),
    (month,credit_type,base_band),
    (month,amount_band,base_band),
    (month,credit_type,amount_band,base_band),
    (month,loan_band),
    (month,credit_type,loan_band),
    (month,amount_band,loan_band),
    (month,credit_type,amount_band,loan_band),
    (month,score_band),
    (month,credit_type,score_band),
    (month,amount_band,score_band),
    (month,credit_type,amount_band,score_band),
    (month,fee_band),
    (month,credit_type,fee_band),
    (month,amount_band,fee_band),
    (month,credit_type,amount_band,fee_band),
    (month,daily_band),
    (month,credit_type,daily_band),
    (month,amount_band,daily_band),
    (month,credit_type,amount_band,daily_band),
    (month,base_band,loan_band),
    (month,credit_type,base_band,loan_band),
    (month,amount_band,base_band,loan_band),
    (month,credit_type,amount_band,base_band,loan_band),
    (month,base_band,score_band),
    (month,credit_type,base_band,score_band),
    (month,amount_band,base_band,score_band),
    (month,credit_type,amount_band,base_band,score_band),
    (month,base_band,fee_band),
    (month,credit_type,base_band,fee_band),
    (month,amount_band,base_band,fee_band),
    (month,credit_type,amount_band,base_band,fee_band),
    (month,base_band,daily_band),
    (month,credit_type,base_band,daily_band),
    (month,amount_band,base_band,daily_band),
    (month,credit_type,amount_band,base_band,daily_band),
    (month,loan_band,score_band),
    (month,credit_type,loan_band,score_band),
    (month,amount_band,loan_band,score_band),
    (month,credit_type,amount_band,loan_band,score_band),
    (month,loan_band,fee_band),
    (month,credit_type,loan_band,fee_band),
    (month,amount_band,loan_band,fee_band),
    (month,credit_type,amount_band,loan_band,fee_band),
    (month,loan_band,daily_band),
    (month,credit_type,loan_band,daily_band),
    (month,amount_band,loan_band,daily_band),
    (month,credit_type,amount_band,loan_band,daily_band),
    (month,score_band,fee_band),
    (month,credit_type,score_band,fee_band),
    (month,amount_band,score_band,fee_band),
    (month,credit_type,amount_band,score_band,fee_band),
    (month,score_band,daily_band),
    (month,credit_type,score_band,daily_band),
    (month,amount_band,score_band,daily_band),
    (month,credit_type,amount_band,score_band,daily_band),
    (month,fee_band,daily_band),
    (month,credit_type,fee_band,daily_band),
    (month,amount_band,fee_band,daily_band),
    (month,credit_type,amount_band,fee_band,daily_band),
    (month,base_band,loan_band,score_band),
    (month,credit_type,base_band,loan_band,score_band),
    (month,amount_band,base_band,loan_band,score_band),
    (month,credit_type,amount_band,base_band,loan_band,score_band),
    (month,base_band,loan_band,fee_band),
    (month,credit_type,base_band,loan_band,fee_band),
    (month,amount_band,base_band,loan_band,fee_band),
    (month,credit_type,amount_band,base_band,loan_band,fee_band),
    (month,base_band,loan_band,daily_band),
    (month,credit_type,base_band,loan_band,daily_band),
    (month,amount_band,base_band,loan_band,daily_band),
    (month,credit_type,amount_band,base_band,loan_band,daily_band),
    (month,base_band,score_band,fee_band),
    (month,credit_type,base_band,score_band,fee_band),
    (month,amount_band,base_band,score_band,fee_band),
    (month,credit_type,amount_band,base_band,score_band,fee_band),
    (month,base_band,score_band,daily_band),
    (month,credit_type,base_band,score_band,daily_band),
    (month,amount_band,base_band,score_band,daily_band),
    (month,credit_type,amount_band,base_band,score_band,daily_band),
    (month,base_band,fee_band,daily_band),
    (month,credit_type,base_band,fee_band,daily_band),
    (month,amount_band,base_band,fee_band,daily_band),
    (month,credit_type,amount_band,base_band,fee_band,daily_band),
    (month,loan_band,score_band,fee_band),
    (month,credit_type,loan_band,score_band,fee_band),
    (month,amount_band,loan_band,score_band,fee_band),
    (month,credit_type,amount_band,loan_band,score_band,fee_band),
    (month,loan_band,score_band,daily_band),
    (month,credit_type,loan_band,score_band,daily_band),
    (month,amount_band,loan_band,score_band,daily_band),
    (month,credit_type,amount_band,loan_band,score_band,daily_band),
    (month,loan_band,fee_band,daily_band),
    (month,credit_type,loan_band,fee_band,daily_band),
    (month,amount_band,loan_band,fee_band,daily_band),
    (month,credit_type,amount_band,loan_band,fee_band,daily_band),
    (month,score_band,fee_band,daily_band),
    (month,credit_type,score_band,fee_band,daily_band),
    (month,amount_band,score_band,fee_band,daily_band),
    (month,credit_type,amount_band,score_band,fee_band,daily_band),
    (month,base_band,loan_band,score_band,fee_band),
    (month,credit_type,base_band,loan_band,score_band,fee_band),
    (month,amount_band,base_band,loan_band,score_band,fee_band),
    (month,credit_type,amount_band,base_band,loan_band,score_band,fee_band),
    (month,base_band,loan_band,score_band,daily_band),
    (month,credit_type,base_band,loan_band,score_band,daily_band),
    (month,amount_band,base_band,loan_band,score_band,daily_band),
    (month,credit_type,amount_band,base_band,loan_band,score_band,daily_band),
    (month,base_band,loan_band,fee_band,daily_band),
    (month,credit_type,base_band,loan_band,fee_band,daily_band),
    (month,amount_band,base_band,loan_band,fee_band,daily_band),
    (month,credit_type,amount_band,base_band,loan_band,fee_band,daily_band),
    (month,base_band,score_band,fee_band,daily_band),
    (month,credit_type,base_band,score_band,fee_band,daily_band),
    (month,amount_band,base_band,score_band,fee_band,daily_band),
    (month,credit_type,amount_band,base_band,score_band,fee_band,daily_band),
    (month,loan_band,score_band,fee_band,daily_band),
    (month,credit_type,loan_band,score_band,fee_band,daily_band),
    (month,amount_band,loan_band,score_band,fee_band,daily_band),
    (month,credit_type,amount_band,loan_band,score_band,fee_band,daily_band),
    (month,base_band,loan_band,score_band,fee_band,daily_band),
    (month,credit_type,base_band,loan_band,score_band,fee_band,daily_band),
    (month,amount_band,base_band,loan_band,score_band,fee_band,daily_band),
    (month,credit_type,amount_band,base_band,loan_band,score_band,fee_band,daily_band)
    )
), parent_monthly AS (
    SELECT month,credit_type,amount_band,GROUPING(credit_type) AS g_credit_type,
           GROUPING(amount_band) AS g_amount_band,SUM(n) AS parent_n
    FROM cube GROUP BY GROUPING SETS ((month),(month,credit_type),(month,amount_band),(month,credit_type,amount_band))
), projection_denominators AS (
    SELECT p.*,d.parent_n,p.y::numeric/NULLIF(p.n,0) AS rate,p.n::numeric/NULLIF(d.parent_n,0) AS share
    FROM projection_monthly p JOIN parent_monthly d ON d.month=p.month
      AND d.g_credit_type=p.g_credit_type AND d.g_amount_band=p.g_amount_band
      AND (p.g_credit_type=1 OR p.credit_type=d.credit_type)
      AND (p.g_amount_band=1 OR p.amount_band=d.amount_band)
), endpoints AS (
    SELECT credit_type,amount_band,base_band,loan_band,score_band,fee_band,daily_band,g_credit_type,g_amount_band,g_base_band,g_loan_band,g_score_band,g_fee_band,g_daily_band,
        SUM(CASE WHEN month='2026-01' THEN n ELSE 0 END) AS n_jan,
        SUM(CASE WHEN month='2026-09' THEN n ELSE 0 END) AS n_sep,
        SUM(CASE WHEN month='2026-01' THEN y ELSE 0 END) AS y_jan,
        SUM(CASE WHEN month='2026-09' THEN y ELSE 0 END) AS y_sep,
        MAX(CASE WHEN month='2026-01' THEN parent_n END) AS parent_seen_jan,
        MAX(CASE WHEN month='2026-09' THEN parent_n END) AS parent_seen_sep
    FROM projection_denominators GROUP BY credit_type,amount_band,base_band,loan_band,score_band,fee_band,daily_band,g_credit_type,g_amount_band,g_base_band,g_loan_band,g_score_band,g_fee_band,g_daily_band
), endpoint_rates AS (
    SELECT e.*,dj.parent_n AS parent_jan,ds.parent_n AS parent_sep,
        y_jan::numeric/NULLIF(n_jan,0) AS r_jan,y_sep::numeric/NULLIF(n_sep,0) AS r_sep,
        n_jan::numeric/NULLIF(dj.parent_n,0) AS w_jan,n_sep::numeric/NULLIF(ds.parent_n,0) AS w_sep
    FROM endpoints e
    LEFT JOIN parent_monthly dj ON dj.month='2026-01'
      AND dj.g_credit_type=e.g_credit_type AND dj.g_amount_band=e.g_amount_band
      AND (e.g_credit_type=1 OR e.credit_type=dj.credit_type)
      AND (e.g_amount_band=1 OR e.amount_band=dj.amount_band)
    LEFT JOIN parent_monthly ds ON ds.month='2026-09'
      AND ds.g_credit_type=e.g_credit_type AND ds.g_amount_band=e.g_amount_band
      AND (e.g_credit_type=1 OR e.credit_type=ds.credit_type)
      AND (e.g_amount_band=1 OR e.amount_band=ds.amount_band)
), comparisons AS (
    SELECT e.*,(r_sep-r_jan)*100 AS rate_change_pp,
        (y_sep::numeric/NULLIF(parent_sep,0)-y_jan::numeric/NULLIF(parent_jan,0))*100 AS context_net_pp,
        (y_sep::numeric/NULLIF((SELECT SUM(n) FROM cube WHERE month='2026-09'),0)
         -y_jan::numeric/NULLIF((SELECT SUM(n) FROM cube WHERE month='2026-01'),0))*100 AS global_net_pp,
        CASE WHEN n_jan>0 AND n_sep>0 THEN (w_jan+w_sep)/2*(r_sep-r_jan)*100 END AS within_pp,
        CASE WHEN n_jan>0 AND n_sep>0 THEN (r_jan+r_sep)/2*(w_sep-w_jan)*100 END AS mix_pp,
        CASE WHEN n_jan=0 OR n_sep=0 THEN
          (y_sep::numeric/NULLIF(parent_sep,0)-y_jan::numeric/NULLIF(parent_jan,0))*100 ELSE 0 END AS entry_exit_pp,
        CASE WHEN n_jan>=100 AND n_sep>=100 THEN 1 ELSE 0 END AS endpoint_sample_ge100
    FROM endpoint_rates e
)
SELECT 'cube'::text AS kind,ROW_TO_JSON(t)::text AS payload FROM cube t
UNION ALL SELECT 'control',ROW_TO_JSON(t)::text FROM controls t
UNION ALL SELECT 'audit',ROW_TO_JSON(t)::text FROM audit t
UNION ALL SELECT 'projection_monthly',ROW_TO_JSON(t)::text FROM projection_denominators t
UNION ALL SELECT 'comparison',ROW_TO_JSON(t)::text FROM comparisons t
UNION ALL SELECT 'zero_catalog_audit',ROW_TO_JSON(t)::text FROM zero_catalog_audit t
UNION ALL SELECT 'zero_catalog_product',ROW_TO_JSON(t)::text FROM catalog t
  WHERE product_no IN (SELECT DISTINCT risk_product FROM zero_catalog_audit WHERE current_fee::numeric=0)
UNION ALL SELECT 'metadata',ROW_TO_JSON(t)::text FROM (
    SELECT CURRENT_TIMESTAMP::text AS snapshot,'America/Belize'::text AS business_timezone,
           '2026-01-01'::text AS start_date,'2026-10-11'::text AS end_date_inclusive,
           '2026-10-01 through 2026-10-11, partial month'::text AS partial_month,
           'user x original analyzable T0 event; D0 earliest user application, not same-serial-only'::text AS metric,
           'exact-zero fee changes; current MAX total_fee and independent MIN daily_fee; previous actual product_no; both product_info_copy'::text AS product_contract,
           'current product catalog, not historical displayed-price snapshot; score table has no version timestamp'::text AS history_limit,
           'original credit exclusions retained; old 677 not added back'::text AS exclusion_contract
) t
;
RESET query_dop;
