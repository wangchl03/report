/*
T0人日统一口径：第1—5部分与第8部分共同取数。
统计单位：用户×获额日；20秒链式去重后，同一用户同一日仅保留最早一轮合格T0。
T0：续贷获额通过、recycle_type=3、获额当天干净结清，且获额不早于结清。
从该时刻起取首次提单；不要求成功放款，不在下一次获额时截断。
窗口按自然日差：当天=0，1—7天=1至7，8—30天=8至30。
窗口提单率分母为全部T0人日；窗口占比分母为30天内首次提单人日。
第2—3部分：9月1—30日、10月1—28日。第8部分：1月1日至9月30日。
每日410高分：score_410>当天Q80，同分不拆分；先按日筛选，再按月累计。
订单息费：SUM(pre_amt+post_amt)/SUM(remit_amt)。
产品息费：SUM(total_fee*remit_amt)/SUM(remit_amt)，total_fee为比例值。
息费要求remit_amt>0，不额外限定is_remit；产品缺失/冲突时同步排除其分子分母。
业务时区America/Belize；源表更新后重跑结果可能变化。
本查询沿用原第八部分的结清判定，不使用上一版按多获额事件归属及下一获额截断逻辑。
第6—7部分为独立召回汇总，不在本SQL内重算。
*/
SET TIME ZONE 'America/Belize';
SET query_dop=1;
WITH params AS (
    SELECT DATE '2026-01-01' AS start_date, DATE '2026-10-29' AS end_date,
           TIMESTAMP '2026-10-30 01:36:59.681680' AS data_cutoff_ts
), raw_offer AS (
    SELECT DISTINCT ON (v.user_id, v.serial_id)
        v.user_id, v.serial_id, v.vir_date::date AS vir_date, TO_TIMESTAMP(v.vir_unix) AT TIME ZONE 'America/Belize' AS vir_time
    FROM wangchuanliang.order_vir_f_copy v
    INNER JOIN wangchuanliang.side_recycle_type_copy r ON r.serial_id = v.serial_id
    CROSS JOIN params p
    WHERE v.is_pass1 = 1 AND v.loan_type_code = 2 AND r.recycle_type = 3
      AND v.user_id NOT IN (5101518)
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
           o.loan_status_code, o.is_remit, o.is_repaid, o.apply_date::date AS apply_date,
           o.pre_amt, o.post_amt, o.remit_amt, o.product_no, o.loan_day, o.total_term
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
    SELECT e.user_id, e.serial_id AS credit_serial_id, e.vir_date, e.vir_time, s.repaid_time,
           ROW_NUMBER() OVER (PARTITION BY e.user_id, e.vir_date ORDER BY e.vir_time ASC, e.serial_id DESC) AS day_rn
    FROM dedup_offer e
    INNER JOIN clean_settlement s
        ON s.user_id = e.user_id AND s.repaid_date = e.vir_date AND e.vir_time >= s.repaid_time
),
origin AS (
    SELECT user_id, credit_serial_id, vir_date, vir_time, repaid_time
    FROM paired WHERE day_rn = 1
),
-- 取每个人日获额后的首次提单；不在下一次获额时刻截断。
first_ranked AS (
    SELECT t.*, a.serial_id AS apply_serial_id, a.apply_time, a.apply_date,
           a.pre_amt, a.post_amt, a.remit_amt, a.product_no,
           a.loan_day, a.total_term, a.is_remit,
           ROW_NUMBER() OVER (
               PARTITION BY t.user_id, t.vir_date
               ORDER BY a.apply_time ASC NULLS LAST, a.serial_id ASC NULLS LAST
           ) AS apply_rn
    FROM origin t
    CROSS JOIN params p
    LEFT JOIN all_orders a
      ON a.user_id = t.user_id AND a.apply_time >= t.vir_time
     AND a.apply_time < p.data_cutoff_ts
),
labels AS (
    SELECT f.*, TO_CHAR(vir_date, 'YYYY-MM') AS event_month,
           apply_date - vir_date AS apply_d
    FROM first_ranked f WHERE apply_rn = 1
),
-- 同一份labels同时生成第2部分与第8部分的月度分子、分母。
monthly_windows AS (
    SELECT event_month, COUNT(*) AS all_t0_events,
           SUM(CASE WHEN apply_d = 0 THEN 1 ELSE 0 END) AS all_d0_events,
           SUM(CASE WHEN apply_d BETWEEN 1 AND 7 THEN 1 ELSE 0 END) AS d1_7_events,
           SUM(CASE WHEN apply_d BETWEEN 8 AND 30 THEN 1 ELSE 0 END) AS d8_30_events,
           SUM(CASE WHEN apply_d BETWEEN 0 AND 30 THEN 1 ELSE 0 END) AS within30_events,
           SUM(CASE WHEN apply_serial_id IS NULL THEN 1 ELSE 0 END) AS no_observed_apply_events,
           SUM(CASE WHEN apply_d > 30 THEN 1 ELSE 0 END) AS after30_events,
           MIN(vir_date) AS first_event_date, MAX(vir_date) AS last_event_date
    FROM labels GROUP BY event_month
),
-- 410及息费仅计算9月、10月；源人日与首次提单仍为同一份labels。
scoring_cohort AS (
    SELECT * FROM labels WHERE vir_date >= DATE '2026-09-01'
),
model_per_serial AS (
    SELECT m.serial_id, COUNT(*) AS model_rows,
           COUNT(DISTINCT m.user_id) AS user_versions,
           MIN(m.user_id) AS model_user_id,
           COUNT(DISTINCT CASE WHEN m.kabybmerge410fpd7cre IS NOT NULL
                                    AND m.kabybmerge410fpd7cre <> -9999999
                               THEN m.kabybmerge410fpd7cre END) AS score_versions,
           MIN(CASE WHEN m.kabybmerge410fpd7cre IS NOT NULL
                         AND m.kabybmerge410fpd7cre <> -9999999
                    THEN m.kabybmerge410fpd7cre END) AS score_value
    FROM wangchuanliang.model_result_copy m
    WHERE EXISTS (SELECT 1 FROM scoring_cohort c WHERE c.credit_serial_id = m.serial_id)
    GROUP BY m.serial_id
),
scored AS (
    SELECT c.*, m.model_rows, m.user_versions, m.score_versions,
           CASE WHEN m.user_versions = 1 AND m.model_user_id = c.user_id
                     AND m.score_versions = 1 THEN m.score_value END AS score_410
    FROM scoring_cohort c
    LEFT JOIN model_per_serial m ON m.serial_id = c.credit_serial_id
),
daily_thresholds AS (
    SELECT vir_date,
           PERCENTILE_CONT(0.8) WITHIN GROUP (ORDER BY score_410) AS q80
    FROM scored WHERE score_410 IS NOT NULL GROUP BY vir_date
),
classified AS (
    SELECT s.*, d.q80,
           CASE WHEN s.score_410 > d.q80 THEN 1 ELSE 0 END AS top20_flag
    FROM scored s LEFT JOIN daily_thresholds d ON d.vir_date = s.vir_date
),
monthly_population AS (
    SELECT event_month, COUNT(*) AS scored_population_events,
           COUNT(score_410) AS valid_score_events,
           SUM(CASE WHEN score_410 IS NULL THEN 1 ELSE 0 END) AS missing_or_invalid_score_events,
           SUM(CASE WHEN score_versions > 1 OR user_versions > 1 THEN 1 ELSE 0 END) AS score_conflict_events,
           COUNT(DISTINCT CASE WHEN score_410 IS NOT NULL THEN vir_date END) AS days_with_valid_scores,
           SUM(top20_flag) AS top20_events,
           SUM(CASE WHEN top20_flag = 1 AND apply_d = 0 THEN 1 ELSE 0 END) AS top20_d0_events
    FROM classified GROUP BY event_month
),
high_d0_orders AS (
    SELECT * FROM classified WHERE top20_flag = 1 AND apply_d = 0
),
product_catalog AS (
    SELECT BTRIM(product_no) AS product_no, COUNT(*) AS catalog_rows,
           COUNT(DISTINCT total_fee) AS fee_versions,
           CASE WHEN COUNT(total_fee) = COUNT(*) AND COUNT(DISTINCT total_fee) = 1
                THEN MIN(total_fee)::numeric END AS total_fee
    FROM wangchuanliang.product_info_copy
    WHERE NULLIF(BTRIM(product_no), '') IS NOT NULL GROUP BY BTRIM(product_no)
),
priced_orders AS (
    SELECT h.*, p.product_no AS matched_product_no, p.fee_versions, p.total_fee,
           CASE WHEN h.remit_amt > 0 AND p.total_fee IS NOT NULL AND p.total_fee >= 0
                THEN 1 ELSE 0 END AS product_fee_valid
    FROM high_d0_orders h
    LEFT JOIN product_catalog p ON p.product_no = NULLIF(BTRIM(h.product_no), '')
),
monthly_fees AS (
    SELECT event_month, COUNT(*) AS first_d0_order_rows,
           COUNT(DISTINCT apply_serial_id) AS first_d0_distinct_orders,
           SUM(CASE WHEN remit_amt > 0 THEN 1 ELSE 0 END) AS order_fee_orders,
           SUM(CASE WHEN remit_amt IS NULL OR remit_amt <= 0 THEN 1 ELSE 0 END) AS invalid_principal_orders,
           SUM(CASE WHEN remit_amt > 0 AND (pre_amt IS NULL OR post_amt IS NULL)
                    THEN 1 ELSE 0 END) AS missing_order_fee_fields,
           SUM(CASE WHEN remit_amt > 0 THEN COALESCE(pre_amt, 0) + COALESCE(post_amt, 0) END) AS order_fee_amt,
           SUM(CASE WHEN remit_amt > 0 THEN remit_amt END) AS order_principal_amt,
           SUM(product_fee_valid) AS product_fee_orders,
           SUM(CASE WHEN product_fee_valid = 1 THEN total_fee * remit_amt END) AS product_fee_amt,
           SUM(CASE WHEN product_fee_valid = 1 THEN remit_amt END) AS product_principal_amt,
           SUM(CASE WHEN matched_product_no IS NULL THEN 1 ELSE 0 END) AS unmatched_product_orders,
           SUM(CASE WHEN fee_versions > 1 THEN 1 ELSE 0 END) AS conflicting_product_fee_orders,
           SUM(CASE WHEN matched_product_no IS NOT NULL AND (total_fee IS NULL OR total_fee < 0)
                    THEN 1 ELSE 0 END) AS invalid_product_fee_orders,
           SUM(CASE WHEN product_fee_valid = 1 AND total_fee = 0 THEN 1 ELSE 0 END) AS zero_product_fee_orders
    FROM priced_orders GROUP BY event_month
),
event_audit AS (
    SELECT
        (SELECT COUNT(*) FROM (SELECT user_id,vir_date FROM origin GROUP BY user_id,vir_date HAVING COUNT(*) > 1) d)
            AS duplicate_user_days,
        SUM(CASE WHEN repaid_time > vir_time OR apply_time < vir_time OR apply_d < 0
                 THEN 1 ELSE 0 END) AS invalid_label_times,
        SUM(CASE WHEN apply_time::date <> apply_date OR vir_time::date <> vir_date
                 THEN 1 ELSE 0 END) AS date_time_mismatch_events,
        SUM(CASE WHEN user_id = 5101518 THEN 1 ELSE 0 END) AS blacklisted_events
    FROM labels
)
SELECT w.*,
       ROUND(100.0 * w.all_d0_events / NULLIF(w.all_t0_events, 0), 2) AS all_d0_rate_pct,
       ROUND(100.0 * w.d1_7_events / NULLIF(w.all_t0_events, 0), 2) AS d1_7_rate_pct,
       ROUND(100.0 * w.d8_30_events / NULLIF(w.all_t0_events, 0), 2) AS d8_30_rate_pct,
       ROUND(100.0 * w.within30_events / NULLIF(w.all_t0_events, 0), 2) AS within30_rate_pct,
       ROUND(100.0 * w.all_d0_events / NULLIF(w.within30_events, 0), 2) AS d0_share_pct,
       ROUND(100.0 * w.d1_7_events / NULLIF(w.within30_events, 0), 2) AS d1_7_share_pct,
       ROUND(100.0 * w.d8_30_events / NULLIF(w.within30_events, 0), 2) AS d8_30_share_pct,
       p.scored_population_events,p.valid_score_events,p.missing_or_invalid_score_events,
       p.score_conflict_events,p.days_with_valid_scores,p.top20_events,p.top20_d0_events,
       ROUND(100.0 * p.top20_d0_events / NULLIF(p.top20_events, 0), 2) AS top20_d0_rate_pct,
       ROUND(100.0 * p.top20_events / NULLIF(p.valid_score_events, 0), 2) AS top20_selected_share_pct,
       f.first_d0_order_rows,f.first_d0_distinct_orders,
       f.order_fee_orders,f.invalid_principal_orders,f.missing_order_fee_fields,
       f.order_fee_amt,f.order_principal_amt,
       ROUND(100.0 * f.order_fee_amt / NULLIF(f.order_principal_amt, 0), 2) AS order_fee_rate_pct,
       f.product_fee_orders,f.product_fee_amt,f.product_principal_amt,
       ROUND(100.0 * f.product_fee_amt / NULLIF(f.product_principal_amt, 0), 2) AS product_fee_rate_pct,
       f.unmatched_product_orders,f.conflicting_product_fee_orders,f.invalid_product_fee_orders,f.zero_product_fee_orders,
       a.duplicate_user_days,a.invalid_label_times,a.date_time_mismatch_events,a.blacklisted_events
FROM monthly_windows w
LEFT JOIN monthly_population p ON p.event_month = w.event_month
LEFT JOIN monthly_fees f ON f.event_month = w.event_month
CROSS JOIN event_audit a
ORDER BY w.event_month;
