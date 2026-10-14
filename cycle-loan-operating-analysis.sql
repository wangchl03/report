/* 循环贷经营分析：完整只读SQL。每模块返回result_kind/payload两列JSON。
   各模块使用其本次实际取数时刻，归属月份和分母在注释内分别说明。
   原始表为当前快照；日后重跑历史时点过滤，不能还原当时的当前逾期状态。
   精确重建本报告请使用同时提供的聚合sources.json与analysis.py。 */
SET TIME ZONE 'America/Belize';
SET query_dop=1;


-- MODULE: activity
/* 只读：资格供给、新老循环贷放款、借款次数与结清节奏。
   统计期2026-01-01至2026-10-13（含），10月仅1—13日。
   新开通代理=全量可观测历史首次通过的type2获额；不是官方开通日志。
   月度频次按活跃获额用户/实际借款用户计算，固定老借款用户另列。
   字段校验已完成；运行会话须为America/Belize、query_dop=1、只读事务。
*/
WITH params AS (
  SELECT DATE '2026-01-01' AS start_date,DATE '2026-10-14' AS end_date,
         TIMESTAMP '2026-10-14 08:51:44.700928' AS snapshot_time
), tags AS (
  SELECT serial_id,COUNT(DISTINCT recycle_type) AS type_n,MIN(recycle_type) AS recycle_type
  FROM wangchuanliang.side_recycle_type_copy GROUP BY serial_id
), cycle_offer_history AS (
  SELECT DISTINCT ON (v.user_id,v.serial_id)
         v.user_id,v.serial_id,v.vir_date::date AS vir_date,v.vir_unix,
         TO_TIMESTAMP(v.vir_unix) AT TIME ZONE 'America/Belize' AS vir_time
  FROM wangchuanliang.order_vir_f_copy v JOIN tags t ON t.serial_id=v.serial_id CROSS JOIN params p
  WHERE v.is_pass1=1 AND v.loan_type_code=2 AND v.vir_unix>0
    AND t.type_n=1 AND t.recycle_type=2
    AND TO_TIMESTAMP(v.vir_unix) AT TIME ZONE 'America/Belize'<p.snapshot_time
    AND v.user_id IS NOT NULL AND v.serial_id IS NOT NULL
  ORDER BY v.user_id,v.serial_id,v.vir_unix DESC
), first_qualification AS (
  SELECT user_id,MIN(vir_time) AS first_qualification_time
  FROM cycle_offer_history GROUP BY user_id
), buffered_offer AS (
  SELECT v.* FROM cycle_offer_history v CROSS JOIN params p
  WHERE v.vir_date>=p.start_date-1 AND v.vir_date<p.end_date+1
), offer_lag AS (
  SELECT v.*,LAG(vir_time) OVER(PARTITION BY user_id ORDER BY vir_time,serial_id) AS previous_time
  FROM buffered_offer v
), offer_batch AS (
  SELECT v.*,SUM(CASE WHEN previous_time IS NULL OR vir_time-previous_time>INTERVAL '20 seconds'
                       THEN 1 ELSE 0 END) OVER(PARTITION BY user_id ORDER BY vir_time,serial_id ROWS UNBOUNDED PRECEDING) AS batch_id
  FROM offer_lag v
), offer_rank AS (
  SELECT v.*,ROW_NUMBER() OVER(PARTITION BY user_id,batch_id ORDER BY vir_time DESC,serial_id DESC) AS rn
  FROM offer_batch v
), eligible_offers AS (
  SELECT v.*,DATE_TRUNC('month',v.vir_date)::date AS month_start,q.first_qualification_time
  FROM offer_rank v JOIN first_qualification q ON q.user_id=v.user_id CROSS JOIN params p
  WHERE v.rn=1 AND v.vir_date>=p.start_date AND v.vir_date<p.end_date
), offer_monthly AS (
  SELECT TO_CHAR(month_start,'YYYY-MM') AS month,COUNT(*) AS eligible_orders,
    COUNT(DISTINCT user_id) AS eligible_users,
    COUNT(DISTINCT CASE WHEN first_qualification_time>=month_start::timestamp THEN user_id END) AS new_qualified_active_users,
    COUNT(DISTINCT CASE WHEN first_qualification_time<month_start::timestamp THEN user_id END) AS old_qualified_active_users,
    SUM(CASE WHEN first_qualification_time>=month_start::timestamp THEN 1 ELSE 0 END) AS new_qualified_orders,
    SUM(CASE WHEN first_qualification_time<month_start::timestamp THEN 1 ELSE 0 END) AS old_qualified_orders
  FROM eligible_offers GROUP BY month_start
), first_qualification_monthly AS (
  SELECT TO_CHAR(DATE_TRUNC('month',q.first_qualification_time),'YYYY-MM') AS month,
         COUNT(*) AS first_observed_qualification_users
  FROM first_qualification q CROSS JOIN params p
  WHERE q.first_qualification_time>=p.start_date::timestamp AND q.first_qualification_time<p.end_date::timestamp
  GROUP BY DATE_TRUNC('month',q.first_qualification_time)
), funded_history AS (
  SELECT DISTINCT ON (o.user_id,o.serial_id)
    o.user_id,o.serial_id,o.apply_time,o.remit_amt,o.remit_date,o.remit_time,
    o.loan_type,o.remit_succ_rnb,o.loan_day,o.total_term,o.due_date,
    o.repaid_date,o.repaid_time,o.is_repaid,o.loan_status_code
  FROM wangchuanliang.order_loan_f_v2_copy o CROSS JOIN params p
  WHERE o.is_remit=1 AND o.remit_amt>0
    AND (o.remit_time<p.snapshot_time OR o.remit_time IS NULL OR o.remit_time<=TIMESTAMP '2000-01-01')
  ORDER BY o.user_id,o.serial_id,o.apply_time ASC NULLS LAST
), funded_labeled AS (
  SELECT o.*,t.type_n,t.recycle_type,
    CASE WHEN t.type_n>1 OR (t.type_n=1 AND t.recycle_type=2 AND o.loan_type='firstloan') THEN 'unknown'
         WHEN t.type_n=1 AND t.recycle_type=2 AND o.loan_type='reloan' THEN 'cycle'
         WHEN o.loan_type='firstloan' THEN 'firstloan'
         WHEN t.type_n=1 AND t.recycle_type=3 AND o.loan_type='reloan' THEN 'settled_reloan'
         ELSE 'unknown' END AS order_type,
    CASE WHEN o.remit_succ_rnb=1 THEN '1次' WHEN o.remit_succ_rnb=2 THEN '2次'
         WHEN o.remit_succ_rnb=3 THEN '3次' WHEN o.remit_succ_rnb=4 THEN '4次'
         WHEN o.remit_succ_rnb=5 THEN '5次' WHEN o.remit_succ_rnb>=6 THEN '6次及以上' ELSE '缺失/无效' END AS loan_band,
    CASE WHEN o.loan_day=7 THEN '7天' WHEN o.loan_day=14 THEN '14天' WHEN o.loan_day=21 THEN '21天'
         WHEN o.loan_day=28 THEN '28天' WHEN o.loan_day>28 THEN '28天以上'
         WHEN o.loan_day>0 THEN '其他天数' ELSE '缺失/无效' END AS day_band
  FROM funded_history o LEFT JOIN tags t ON t.serial_id=o.serial_id
), first_cycle_fund AS (
  SELECT user_id,MIN(remit_time) AS first_cycle_fund_time
  FROM funded_labeled WHERE order_type='cycle' AND remit_time>TIMESTAMP '2000-01-01' GROUP BY user_id
), period_funded AS (
  SELECT o.*,DATE_TRUNC('month',o.remit_date)::date AS month_start,c.first_cycle_fund_time,
         q.first_qualification_time
  FROM funded_labeled o LEFT JOIN first_cycle_fund c ON c.user_id=o.user_id
  LEFT JOIN first_qualification q ON q.user_id=o.user_id CROSS JOIN params p
  WHERE o.remit_date>=p.start_date AND o.remit_date<p.end_date
    AND o.remit_time>TIMESTAMP '2000-01-01' AND o.remit_time<p.end_date::timestamp
), funded_monthly AS (
  SELECT TO_CHAR(month_start,'YYYY-MM') AS month,COUNT(*) AS all_funded_orders,
    SUM(CASE WHEN order_type='cycle' THEN 1 ELSE 0 END) AS cycle_funded_orders,
    SUM(CASE WHEN order_type='settled_reloan' THEN 1 ELSE 0 END) AS settled_reloan_funded_orders,
    SUM(CASE WHEN order_type='firstloan' THEN 1 ELSE 0 END) AS firstloan_funded_orders,
    SUM(CASE WHEN order_type='unknown' THEN 1 ELSE 0 END) AS unknown_funded_orders,
    COUNT(DISTINCT CASE WHEN order_type='cycle' THEN user_id END) AS cycle_borrowers,
    COUNT(DISTINCT CASE WHEN order_type='cycle' AND first_cycle_fund_time>=month_start::timestamp THEN user_id END) AS new_cycle_borrowers,
    COUNT(DISTINCT CASE WHEN order_type='cycle' AND first_cycle_fund_time<month_start::timestamp THEN user_id END) AS old_cycle_borrowers,
    SUM(CASE WHEN order_type='cycle' AND first_cycle_fund_time>=month_start::timestamp THEN 1 ELSE 0 END) AS new_cycle_funded_orders,
    SUM(CASE WHEN order_type='cycle' AND first_cycle_fund_time<month_start::timestamp THEN 1 ELSE 0 END) AS old_cycle_funded_orders,
    SUM(CASE WHEN order_type='cycle' THEN remit_amt ELSE 0 END) AS cycle_remit_amt,
    SUM(remit_amt) AS all_remit_amt,
    SUM(CASE WHEN remit_time::date<>remit_date THEN 1 ELSE 0 END) AS remit_date_time_mismatch_orders
  FROM period_funded GROUP BY month_start
), funded_sequence AS (
  SELECT TO_CHAR(month_start,'YYYY-MM') AS month,order_type,loan_band,COUNT(*) AS funded_orders,
    COUNT(DISTINCT user_id) AS borrowers,SUM(remit_amt) AS remit_amt
  FROM period_funded GROUP BY month_start,order_type,loan_band
), funded_tenor AS (
  SELECT TO_CHAR(month_start,'YYYY-MM') AS month,order_type,day_band,COUNT(*) AS funded_orders,
    SUM(CASE WHEN loan_day>0 THEN loan_day ELSE 0 END) AS scheduled_day_sum,
    SUM(CASE WHEN loan_day>0 THEN 1 ELSE 0 END) AS scheduled_day_known_orders
  FROM period_funded GROUP BY month_start,order_type,day_band
), fixed_old_cycle_cohort AS (
  SELECT user_id FROM first_cycle_fund WHERE first_cycle_fund_time<TIMESTAMP '2026-01-01'
), fixed_old_monthly AS (
  SELECT TO_CHAR(o.month_start,'YYYY-MM') AS month,COUNT(*) AS cycle_funded_orders,
    COUNT(DISTINCT o.user_id) AS active_cycle_borrowers,
    (SELECT COUNT(*) FROM fixed_old_cycle_cohort) AS fixed_old_cohort_users
  FROM period_funded o JOIN fixed_old_cycle_cohort c ON c.user_id=o.user_id
  WHERE o.order_type='cycle' GROUP BY o.month_start
), settlements AS (
  SELECT o.*,DATE_TRUNC('month',o.repaid_date)::date AS month_start,
    CASE WHEN o.due_date>DATE '2000-01-01' AND o.repaid_date<o.due_date THEN 1 ELSE 0 END AS early_settled,
    CASE WHEN o.due_date>DATE '2000-01-01' THEN 1 ELSE 0 END AS due_date_known,
    CASE WHEN o.remit_date>DATE '2000-01-01' AND o.remit_date<=o.repaid_date THEN o.repaid_date-o.remit_date END AS held_days,
    CASE WHEN o.due_date>DATE '2000-01-01' AND o.repaid_date<o.due_date THEN o.due_date-o.repaid_date ELSE 0 END AS early_days
  FROM funded_labeled o CROSS JOIN params p
  WHERE (o.is_repaid=1 OR o.loan_status_code=7) AND o.repaid_time>TIMESTAMP '2000-01-01'
    AND o.repaid_date>=p.start_date AND o.repaid_date<p.end_date AND o.repaid_time<p.end_date::timestamp
), settlement_monthly AS (
  SELECT TO_CHAR(month_start,'YYYY-MM') AS month,order_type,COUNT(*) AS settled_orders,
    COUNT(DISTINCT user_id) AS settled_users,SUM(early_settled) AS early_settled_orders,
    SUM(due_date_known) AS due_date_known_orders,SUM(early_days) AS early_day_sum,
    SUM(CASE WHEN loan_day>0 THEN loan_day ELSE 0 END) AS scheduled_day_sum,
    SUM(CASE WHEN loan_day>0 THEN 1 ELSE 0 END) AS scheduled_day_known_orders,
    SUM(held_days) AS held_day_sum,COUNT(held_days) AS held_day_known_orders,
    SUM(CASE WHEN total_term>0 THEN total_term ELSE 0 END) AS term_sum,
    SUM(CASE WHEN total_term>0 THEN 1 ELSE 0 END) AS term_known_orders,
    SUM(CASE WHEN repaid_time::date<>repaid_date THEN 1 ELSE 0 END) AS repaid_date_time_mismatch_orders,
    SUM(CASE WHEN held_days IS NULL THEN 1 ELSE 0 END) AS invalid_holding_date_orders
  FROM settlements GROUP BY month_start,order_type
), settlement_cross AS (
  SELECT TO_CHAR(month_start,'YYYY-MM') AS month,order_type,loan_band,day_band,COUNT(*) AS settled_orders,
    SUM(early_settled) AS early_settled_orders,SUM(due_date_known) AS due_date_known_orders,
    SUM(early_days) AS early_day_sum,SUM(held_days) AS held_day_sum,COUNT(held_days) AS held_day_known_orders
  FROM settlements GROUP BY month_start,order_type,loan_band,day_band
), settlement_origin AS (
  SELECT TO_CHAR(month_start,'YYYY-MM') AS month,order_type,TO_CHAR(DATE_TRUNC('month',remit_date),'YYYY-MM') AS remit_month,
    COUNT(*) AS settled_orders,SUM(early_settled) AS early_settled_orders
  FROM settlements GROUP BY month_start,order_type,DATE_TRUNC('month',remit_date)
), source_audit AS (
  SELECT MIN(c.vir_time) AS first_observed_cycle_offer_time,MAX(c.vir_time) AS last_observed_cycle_offer_time,
         COUNT(*) AS observed_cycle_offer_serials,COUNT(DISTINCT c.user_id) AS observed_qualified_users,
         (SELECT MIN(remit_time) FROM funded_history WHERE remit_time>TIMESTAMP '2000-01-01') AS earliest_observed_funded_time,
         (SELECT COUNT(*) FROM funded_history WHERE remit_time IS NULL OR remit_time<=TIMESTAMP '2000-01-01') AS invalid_funded_time_orders,
         (SELECT COUNT(*) FROM period_funded WHERE order_type='cycle' AND remit_succ_rnb<2) AS cycle_sequence_below_two_orders,
         (SELECT COUNT(*) FROM tags WHERE type_n>1) AS source_type_conflicting_serials,
         (SELECT COUNT(*) FROM eligible_offers WHERE vir_time::date<>vir_date) AS eligible_offer_date_mismatch_orders
  FROM cycle_offer_history c
)
SELECT 'offer_monthly'::text AS result_kind,ROW_TO_JSON(x)::text AS payload FROM offer_monthly x
UNION ALL SELECT 'new_qualification_monthly',ROW_TO_JSON(x)::text FROM first_qualification_monthly x
UNION ALL SELECT 'funded_monthly',ROW_TO_JSON(x)::text FROM funded_monthly x
UNION ALL SELECT 'funded_sequence',ROW_TO_JSON(x)::text FROM funded_sequence x
UNION ALL SELECT 'funded_tenor',ROW_TO_JSON(x)::text FROM funded_tenor x
UNION ALL SELECT 'fixed_old_monthly',ROW_TO_JSON(x)::text FROM fixed_old_monthly x
UNION ALL SELECT 'settlement_monthly',ROW_TO_JSON(x)::text FROM settlement_monthly x
UNION ALL SELECT 'settlement_cross',ROW_TO_JSON(x)::text FROM settlement_cross x
UNION ALL SELECT 'settlement_origin',ROW_TO_JSON(x)::text FROM settlement_origin x
UNION ALL SELECT 'source_audit',ROW_TO_JSON(x)::text FROM source_audit x;
-- END MODULE: activity


-- MODULE: funnel
WITH params AS (
    SELECT DATE '2026-01-01' AS base_start_date,
           DATE '2026-01-01' AS output_start_date,
           DATE '2026-10-14' AS output_end_date,
           TIMESTAMP '2026-10-14 08:51:44.700928' AS data_cutoff_ts
), raw_pass_offer AS (
    SELECT v.user_id, v.serial_id, v.vir_date::date AS vir_date,
           v.vir_unix,
           TO_TIMESTAMP(v.vir_unix) AT TIME ZONE 'America/Belize' AS vir_time
    FROM wangchuanliang.order_vir_f_copy v CROSS JOIN params p
    WHERE v.is_pass1 = 1 AND v.loan_type_code = 2 AND v.vir_unix > 0
      AND v.vir_date >= p.base_start_date - 1
      AND v.vir_date < p.data_cutoff_ts::date + 1
      AND TO_TIMESTAMP(v.vir_unix) AT TIME ZONE 'America/Belize' < p.data_cutoff_ts
), qualified_offer AS (
    SELECT v.* FROM raw_pass_offer v
    WHERE EXISTS (
        SELECT 1 FROM wangchuanliang.side_recycle_type_copy r
        WHERE r.serial_id = v.serial_id AND r.recycle_type = 3
    )
), serial_latest AS (
    SELECT DISTINCT ON (user_id, serial_id) * FROM qualified_offer
    ORDER BY user_id, serial_id, vir_unix DESC
), lagged AS (
    SELECT v.*, LAG(vir_time) OVER (
        PARTITION BY user_id ORDER BY vir_time, serial_id
    ) AS previous_time
    FROM serial_latest v
), batched AS (
    SELECT v.*, SUM(CASE WHEN previous_time IS NULL
                              OR vir_time - previous_time > INTERVAL '20 seconds'
                        THEN 1 ELSE 0 END) OVER (
        PARTITION BY user_id ORDER BY vir_time, serial_id ROWS UNBOUNDED PRECEDING
    ) AS batch_id
    FROM lagged v
), batch_ranked AS (
    SELECT v.*, ROW_NUMBER() OVER (
        PARTITION BY user_id, batch_id ORDER BY vir_time DESC, serial_id DESC
    ) AS batch_rn
    FROM batched v
), dedup_offer AS (
    SELECT v.* FROM batch_ranked v CROSS JOIN params p
    WHERE batch_rn = 1 AND vir_date >= p.base_start_date
), candidate_users AS (
    SELECT DISTINCT user_id FROM dedup_offer
), funded_orders AS (
    SELECT DISTINCT ON (o.user_id, o.serial_id)
           o.user_id, o.serial_id, o.apply_time, o.remit_time,
           o.remit_amt, o.is_remit, o.repaid_time, o.repaid_date,
           o.is_repaid, o.loan_status_code, o.loan_type
    FROM wangchuanliang.order_loan_f_v2_copy o
    WHERE o.is_remit = 1 AND o.remit_amt > 0
    ORDER BY o.user_id, o.serial_id, o.apply_time ASC NULLS LAST
), clean_settlement AS (
    SELECT o.* FROM funded_orders o CROSS JOIN params p
    WHERE (o.is_repaid = 1 OR o.loan_status_code = 7)
      AND o.repaid_time > TIMESTAMP '2000-01-01'
      AND o.repaid_date >= p.base_start_date
      AND o.repaid_time < p.data_cutoff_ts
      AND NOT EXISTS (
          SELECT 1 FROM funded_orders x
          WHERE x.user_id = o.user_id AND x.serial_id <> o.serial_id
            AND x.remit_time <= o.repaid_time
            AND (x.repaid_time IS NULL
                 OR x.repaid_time <= TIMESTAMP '2000-01-01'
                 OR x.repaid_time > o.repaid_time)
      )
), settlement_matched AS (
    SELECT e.*, s.serial_id AS settled_serial_id, s.repaid_time,
           s.loan_type AS settled_loan_type,
           ROW_NUMBER() OVER (
               PARTITION BY e.user_id, e.serial_id
               ORDER BY s.repaid_time DESC, s.serial_id DESC
           ) AS settlement_rn
    FROM dedup_offer e JOIN clean_settlement s
      ON s.user_id = e.user_id AND s.repaid_date = e.vir_date
     AND s.repaid_time <= e.vir_time
), strict_t0_all AS (
    SELECT e.*, LEAD(vir_time) OVER (
        PARTITION BY user_id ORDER BY vir_time, serial_id
    ) AS next_t0_time
    FROM settlement_matched e WHERE settlement_rn = 1
), cohort AS (
    SELECT e.*, p.data_cutoff_ts FROM strict_t0_all e CROSS JOIN params p
    WHERE e.vir_date >= p.output_start_date AND e.vir_date < p.output_end_date


), tags AS (
  SELECT serial_id,COUNT(DISTINCT recycle_type) AS type_n,MIN(recycle_type) AS recycle_type
  FROM wangchuanliang.side_recycle_type_copy GROUP BY serial_id
), settled_scope AS (
  SELECT s.* FROM funded_orders s CROSS JOIN params p
  WHERE (s.is_repaid=1 OR s.loan_status_code=7) AND s.repaid_time>TIMESTAMP '2000-01-01'
    AND s.repaid_date>=p.output_start_date AND s.repaid_date<p.output_end_date
    AND s.repaid_time<p.output_end_date::timestamp
), zero_scope AS (
  SELECT s.* FROM clean_settlement s CROSS JOIN params p
  WHERE s.repaid_date>=p.output_start_date AND s.repaid_date<p.output_end_date
    AND s.repaid_time<p.output_end_date::timestamp
), scene_rank AS (
  SELECT s.*,ROW_NUMBER() OVER(PARTITION BY user_id,repaid_time ORDER BY serial_id DESC) AS scene_rn
  FROM zero_scope s
), clean_scenes AS (
  SELECT s.*,LEAD(repaid_time) OVER(PARTITION BY user_id ORDER BY repaid_time,serial_id) AS next_scene_time
  FROM scene_rank s WHERE scene_rn=1
), raw_reloan_offers AS (
  SELECT v.user_id,v.serial_id,v.vir_date,v.is_pass1,
    TO_TIMESTAMP(v.vir_unix) AT TIME ZONE 'America/Belize' AS vir_time,
    t.type_n AS offer_type_n,t.recycle_type AS offer_type
  FROM wangchuanliang.order_vir_f_copy v CROSS JOIN params p LEFT JOIN tags t ON t.serial_id=v.serial_id
  WHERE v.loan_type_code=2 AND v.vir_unix>0 AND v.vir_date>=p.output_start_date AND v.vir_date<p.output_end_date
    AND TO_TIMESTAMP(v.vir_unix) AT TIME ZONE 'America/Belize'<p.output_end_date::timestamp
), scene_flags AS (
  SELECT s.user_id,s.serial_id,
    MAX(CASE WHEN o.serial_id IS NOT NULL THEN 1 ELSE 0 END) AS has_same_day_offer,
    MAX(CASE WHEN o.is_pass1=1 THEN 1 ELSE 0 END) AS has_same_day_pass,
    MAX(CASE WHEN o.is_pass1=1 AND o.offer_type_n=1 AND o.offer_type=3 THEN 1 ELSE 0 END) AS has_same_day_type3_pass
  FROM clean_scenes s LEFT JOIN raw_reloan_offers o
    ON o.user_id=s.user_id AND o.vir_date=s.repaid_date AND o.vir_time>=s.repaid_time
    AND (s.next_scene_time IS NULL OR o.vir_time<s.next_scene_time)
  GROUP BY s.user_id,s.serial_id
), event_counts_per_settled AS (
  SELECT user_id,settled_serial_id,COUNT(*) AS t0_events
  FROM cohort GROUP BY user_id,settled_serial_id
), settlement_funnel_base AS (
  SELECT s.*,DATE_TRUNC('month',s.repaid_date)::date AS month_start,
    CASE WHEN t.type_n>1 OR (t.type_n=1 AND t.recycle_type=2 AND s.loan_type='firstloan') THEN 'unknown'
         WHEN t.type_n=1 AND t.recycle_type=2 AND s.loan_type='reloan' THEN 'cycle'
         WHEN s.loan_type='firstloan' THEN 'firstloan'
         WHEN t.type_n=1 AND t.recycle_type=3 AND s.loan_type='reloan' THEN 'settled_reloan'
         ELSE 'unknown' END AS order_type,
    CASE WHEN z.serial_id IS NOT NULL THEN 1 ELSE 0 END AS is_zero_outstanding,
    CASE WHEN c.serial_id IS NOT NULL THEN 1 ELSE 0 END AS is_canonical_clean_scene,
    COALESCE(f.has_same_day_offer,0) AS has_same_day_offer,
    COALESCE(f.has_same_day_pass,0) AS has_same_day_pass,
    COALESCE(f.has_same_day_type3_pass,0) AS has_same_day_type3_pass,
    CASE WHEN e.settled_serial_id IS NOT NULL THEN 1 ELSE 0 END AS has_strict_t0,
    COALESCE(e.t0_events,0) AS t0_events
  FROM settled_scope s LEFT JOIN tags t ON t.serial_id=s.serial_id
  LEFT JOIN zero_scope z ON z.user_id=s.user_id AND z.serial_id=s.serial_id
  LEFT JOIN clean_scenes c ON c.user_id=s.user_id AND c.serial_id=s.serial_id
  LEFT JOIN scene_flags f ON f.user_id=s.user_id AND f.serial_id=s.serial_id
  LEFT JOIN event_counts_per_settled e ON e.user_id=s.user_id AND e.settled_serial_id=s.serial_id
), monthly_funnel AS (
  SELECT TO_CHAR(month_start,'YYYY-MM') AS month,order_type,
    COUNT(*) AS all_settled_orders,SUM(is_zero_outstanding) AS zero_outstanding_settled_orders,
    SUM(is_canonical_clean_scene) AS canonical_clean_scenes,
    SUM(has_same_day_offer) AS same_day_offer_scenes,SUM(has_same_day_pass) AS same_day_pass_scenes,
    SUM(has_same_day_type3_pass) AS same_day_type3_pass_scenes,
    SUM(has_strict_t0) AS strict_t0_settled_orders,SUM(t0_events) AS strict_t0_events,
    SUM(CASE WHEN has_strict_t0=1 AND is_canonical_clean_scene=0 THEN 1 ELSE 0 END) AS t0_outside_scene_orders,
    SUM(CASE WHEN has_strict_t0=1 AND has_same_day_type3_pass=0 THEN 1 ELSE 0 END) AS t0_without_type3_pass_orders
  FROM settlement_funnel_base GROUP BY month_start,order_type
), t0_type_counts AS (
  SELECT TO_CHAR(DATE_TRUNC('month',e.vir_date),'YYYY-MM') AS month,
    COUNT(*) AS strict_t0_events,
    SUM(CASE WHEN t.type_n=1 AND t.recycle_type=2 AND e.settled_loan_type='reloan' THEN 1 ELSE 0 END) AS cycle_t0_events,
    COUNT(DISTINCT e.settled_serial_id) AS strict_t0_settled_orders,
    SUM(CASE WHEN e.repaid_time>e.vir_time OR e.vir_time::date<>e.vir_date THEN 1 ELSE 0 END) AS t0_time_error_events
  FROM cohort e LEFT JOIN tags t ON t.serial_id=e.settled_serial_id GROUP BY DATE_TRUNC('month',e.vir_date)
), funnel_audit AS (
  SELECT (SELECT COUNT(*) FROM cohort) AS strict_t0_events,
    (SELECT COUNT(*) FROM settled_scope) AS all_settled_orders,
    (SELECT COUNT(*) FROM zero_scope) AS zero_outstanding_settled_orders,
    (SELECT COUNT(*) FROM clean_scenes) AS canonical_clean_scenes,
    (SELECT COUNT(*) FROM funded_orders) AS global_funded_histories,
    (SELECT COUNT(*)-COUNT(DISTINCT serial_id) FROM cohort) AS duplicate_t0_serials,
    (SELECT SUM(t0_events) FROM settlement_funnel_base) AS funnel_t0_events,
    (SELECT COUNT(*) FROM settled_scope WHERE repaid_time::date<>repaid_date) AS settlement_time_date_mismatch_orders
)
SELECT 'monthly_funnel'::text AS result_kind,ROW_TO_JSON(x)::text AS payload FROM monthly_funnel x
UNION ALL SELECT 't0_type_counts',ROW_TO_JSON(x)::text FROM t0_type_counts x
UNION ALL SELECT 'funnel_audit',ROW_TO_JSON(x)::text FROM funnel_audit x;
-- END MODULE: funnel


-- MODULE: lifecycle
/* 只读汇总。整笔成功放款按serial_id去重；首次循环贷查全量可观测历史。
   同时输出“期间内首次循环贷”和“期间内有循环贷”两种用户样本。
   15/30/60天无新成功放款是可观测静默，不等于永久停止借款。
   风险只看首笔循环贷及其后的成功放款；0天不是逾期。
   分期逾期发生日仅据due_date_period+1还原到日期，无法恢复精确时刻。
*/
WITH params AS (
  SELECT DATE '2025-07-01' AS start_date,
         TIMESTAMP '2026-10-14 09:21:51.893707' AS snapshot_time
), tags AS (
  SELECT serial_id, COUNT(DISTINCT recycle_type) AS type_n, MIN(recycle_type) AS recycle_type
  FROM wangchuanliang.side_recycle_type_copy GROUP BY serial_id
), funds AS (
  SELECT DISTINCT ON (o.user_id,o.serial_id)
    o.user_id,o.serial_id,o.remit_time,o.remit_date,o.apply_time,o.loan_type,
    o.repaid_time,o.repaid_date,o.loan_status_code,o.is_repaid,o.total_term
  FROM wangchuanliang.order_loan_f_v2_copy o CROSS JOIN params p
  WHERE o.is_remit=1 AND o.remit_amt>0 AND o.user_id IS NOT NULL
    AND o.remit_time>TIMESTAMP '2000-01-01' AND o.remit_time<=p.snapshot_time
  ORDER BY o.user_id,o.serial_id,o.apply_time ASC NULLS LAST
), labeled AS (
  SELECT o.*,t.type_n,t.recycle_type,
    CASE WHEN t.type_n=1 AND t.recycle_type=2 AND o.loan_type='reloan' THEN 'cycle'
         WHEN t.type_n=1 AND t.recycle_type=3 AND o.loan_type='reloan' THEN 'type3'
         WHEN o.loan_type='firstloan' AND COALESCE(t.recycle_type,0)<>2 AND COALESCE(t.type_n,0)<=1 THEN 'firstloan'
         ELSE 'unknown' END AS order_type,
    ROW_NUMBER() OVER(PARTITION BY o.user_id ORDER BY o.remit_time,o.serial_id) AS loan_seq
  FROM funds o LEFT JOIN tags t ON t.serial_id=o.serial_id
), first_seq AS (
  SELECT user_id,MIN(loan_seq) AS first_cycle_seq,
    MAX(CASE WHEN remit_time>=p.start_date::timestamp THEN 1 ELSE 0 END) AS active_in_period
  FROM labeled CROSS JOIN params p WHERE order_type='cycle' GROUP BY user_id
), first_cycle AS (
  SELECT o.user_id,o.loan_seq AS first_cycle_seq,o.remit_time AS first_cycle_time,
    f.active_in_period
  FROM labeled o JOIN first_seq f ON f.user_id=o.user_id AND f.first_cycle_seq=o.loan_seq
), cohort AS (
  SELECT c.*,CASE WHEN c.first_cycle_time>=p.start_date::timestamp THEN 1 ELSE 0 END AS first_in_period
  FROM first_cycle c CROSS JOIN params p WHERE c.active_in_period=1
), post AS (
  SELECT o.*,c.first_cycle_time,c.first_cycle_seq,c.first_in_period
  FROM labeled o JOIN cohort c ON c.user_id=o.user_id WHERE o.loan_seq>=c.first_cycle_seq
), periods AS (
  SELECT rp.serial_id,rp.current_term,COUNT(*) AS source_rows,
    MAX(rp.overdue_days_period) AS overdue_days_period,
    MIN(rp.overdue_days_period) AS min_overdue_days_period,
    MIN(CASE WHEN rp.overdue_days_period>0 AND rp.due_date_period>DATE '2000-01-01'
                  AND rp.due_date_period<p.snapshot_time::date THEN rp.due_date_period+1 END) AS overdue_start_date
  FROM wangchuanliang.repayment_plan_v2_copy rp JOIN post o ON o.serial_id=rp.serial_id
  CROSS JOIN params p WHERE rp.current_term>0 GROUP BY rp.serial_id,rp.current_term
), period_order AS (
  SELECT serial_id,COUNT(*) AS periods_seen,
    SUM(CASE WHEN overdue_days_period IS NOT NULL THEN 1 ELSE 0 END) AS known_overdue_periods,
    SUM(CASE WHEN overdue_days_period>0 THEN 1 ELSE 0 END) AS positive_overdue_periods,
    MIN(overdue_start_date) AS first_overdue_date,
    SUM(source_rows-1) AS duplicate_source_period_rows,
    SUM(CASE WHEN min_overdue_days_period<>overdue_days_period THEN 1 ELSE 0 END) AS conflicting_periods
  FROM periods GROUP BY serial_id
), user_raw AS (
  SELECT o.user_id,MIN(o.first_cycle_time) AS first_cycle_time,MAX(o.first_in_period) AS first_in_period,
    COUNT(*) AS post_funded_orders,
    SUM(CASE WHEN o.order_type='cycle' THEN 1 ELSE 0 END) AS cycle_orders,
    SUM(CASE WHEN o.order_type='type3' THEN 1 ELSE 0 END) AS type3_orders,
    SUM(CASE WHEN o.order_type NOT IN ('cycle','type3') THEN 1 ELSE 0 END) AS other_orders,
    MIN(CASE WHEN o.order_type='type3' THEN o.loan_seq END) AS first_type3_seq,
    MAX(CASE WHEN o.order_type='cycle' THEN o.loan_seq END) AS last_cycle_seq,
    MAX(o.remit_time) AS last_fund_time,
    SUM(CASE WHEN o.loan_status_code=8 THEN 1 ELSE 0 END) AS current_overdue_orders,
    SUM(CASE WHEN o.loan_status_code=7 THEN 1 ELSE 0 END) AS closed_status7_orders,
    SUM(CASE WHEN o.loan_status_code NOT IN (7,8) OR o.loan_status_code IS NULL THEN 1 ELSE 0 END) AS other_current_status_orders,
    SUM(COALESCE(r.positive_overdue_periods,0)) AS overdue_periods,
    MIN(r.first_overdue_date) AS first_overdue_date,
    SUM(CASE WHEN o.total_term>0 AND r.periods_seen>=o.total_term
                   AND r.known_overdue_periods=r.periods_seen AND COALESCE(r.conflicting_periods,0)=0 THEN 0 ELSE 1 END) AS incomplete_period_orders,
    MIN(CASE WHEN o.order_type='cycle' AND (o.is_repaid=1 OR o.loan_status_code=7)
                  AND o.repaid_time>TIMESTAMP '2000-01-01' AND o.repaid_time<=p.snapshot_time
                  AND o.repaid_time>=o.remit_time THEN o.repaid_time END) AS first_cycle_close_time
  FROM post o LEFT JOIN period_order r ON r.serial_id=o.serial_id CROSS JOIN params p GROUP BY o.user_id
), user_state AS (
  SELECT u.*,t.apply_time AS first_type3_apply_time,
    CASE WHEN u.first_type3_seq IS NOT NULL AND u.first_cycle_close_time<=t.apply_time THEN 1 ELSE 0 END AS verified_cycle_close_before_type3,
    CASE WHEN u.other_orders>0 THEN '其他或缺失标签路径'
         WHEN u.type3_orders=0 THEN '首笔循环贷后全部循环贷'
         WHEN u.last_cycle_seq>u.first_type3_seq THEN '转结清续贷后又回循环贷'
         ELSE '转结清续贷后未再循环贷' END AS path,
    CASE WHEN u.current_overdue_orders>0 THEN '当前有整笔状态8订单'
         WHEN u.closed_status7_orders=u.post_funded_orders AND u.overdue_periods>0 THEN '全部状态7但曾有分期逾期'
         WHEN u.closed_status7_orders=u.post_funded_orders AND u.incomplete_period_orders=0 THEN '全部状态7且分期无逾期'
         WHEN u.closed_status7_orders=u.post_funded_orders THEN '全部状态7但分期数据不完整'
         WHEN u.other_current_status_orders>0 THEN '其他在途或状态不完整'
         ELSE '待核验' END AS risk_status
  FROM user_raw u LEFT JOIN post t ON t.user_id=u.user_id AND t.loan_seq=u.first_type3_seq
), cohort_users AS (
  SELECT '期间内曾有循环贷放款'::text AS cohort_name,u.* FROM user_state u
  UNION ALL SELECT '期间内首次循环贷放款',u.* FROM user_state u WHERE u.first_in_period=1
), totals AS (
  SELECT cohort_name,COUNT(*) AS users,MIN(first_cycle_time) AS earliest_first_cycle_time,
    SUM(post_funded_orders) AS post_funded_orders,
    SUM(CASE WHEN post_funded_orders=1 THEN 1 ELSE 0 END) AS only_one_cycle_order_users,
    SUM(CASE WHEN first_type3_seq IS NOT NULL THEN 1 ELSE 0 END) AS ever_type3_users,
    SUM(verified_cycle_close_before_type3) AS verified_type3_transition_users,
    SUM(CASE WHEN first_type3_seq IS NOT NULL AND verified_cycle_close_before_type3=0 THEN 1 ELSE 0 END) AS unverified_type3_transition_users
  FROM cohort_users GROUP BY cohort_name
), paths AS (
  SELECT cohort_name,path,COUNT(*) AS users,
    SUM(CASE WHEN post_funded_orders=1 THEN 1 ELSE 0 END) AS single_order_users,
    SUM(CASE WHEN verified_cycle_close_before_type3=1 THEN 1 ELSE 0 END) AS verified_transition_users,
    SUM(CASE WHEN p.snapshot_time-last_fund_time>=INTERVAL '30 days' THEN 1 ELSE 0 END) AS silent30_users
  FROM cohort_users CROSS JOIN params p GROUP BY cohort_name,path
), silence AS (
  SELECT u.cohort_name,u.path,w.silent_days,u.risk_status,COUNT(*) AS users
  FROM cohort_users u CROSS JOIN params p CROSS JOIN (VALUES (15),(30),(60)) w(silent_days)
  WHERE p.snapshot_time-u.last_fund_time>=w.silent_days*INTERVAL '1 day'
  GROUP BY u.cohort_name,u.path,w.silent_days,u.risk_status
), monthly_paths AS (
  SELECT cohort_name,TO_CHAR(first_cycle_time,'YYYY-MM') AS first_cycle_month,path,COUNT(*) AS users
  FROM cohort_users GROUP BY cohort_name,TO_CHAR(first_cycle_time,'YYYY-MM'),path
), cycle_grant AS (
  SELECT o.serial_id,MAX(TO_TIMESTAMP(v.vir_unix) AT TIME ZONE 'America/Belize') AS last_pass_time_before_apply
  FROM post o JOIN wangchuanliang.order_vir_f_copy v ON v.serial_id=o.serial_id
  WHERE o.order_type='cycle' AND v.is_pass1=1 AND v.vir_unix>0
    AND TO_TIMESTAMP(v.vir_unix) AT TIME ZONE 'America/Belize'<=o.apply_time
  GROUP BY o.serial_id
), overdue_followup AS (
  SELECT u.user_id,
    MAX(CASE WHEN o.order_type='cycle' AND o.remit_time::date>u.first_overdue_date THEN 1 ELSE 0 END) AS funded_after_overdue_date,
    MAX(CASE WHEN o.order_type='cycle' AND g.last_pass_time_before_apply::date>u.first_overdue_date THEN 1 ELSE 0 END) AS newly_approved_after_overdue_date,
    MAX(CASE WHEN o.order_type='cycle' AND g.last_pass_time_before_apply::date=u.first_overdue_date THEN 1 ELSE 0 END) AS approval_same_overdue_date,
    MAX(CASE WHEN o.order_type='cycle' AND o.remit_time::date>u.first_overdue_date AND g.last_pass_time_before_apply IS NULL THEN 1 ELSE 0 END) AS later_fund_missing_grant
  FROM user_state u JOIN post o ON o.user_id=u.user_id LEFT JOIN cycle_grant g ON g.serial_id=o.serial_id
  WHERE u.overdue_periods>0 GROUP BY u.user_id
), cancellation_audit AS (
  SELECT u.cohort_name,COUNT(*) AS users_with_positive_period_overdue,
    SUM(CASE WHEN u.first_overdue_date IS NULL THEN 1 ELSE 0 END) AS overdue_date_missing_users,
    SUM(a.funded_after_overdue_date) AS users_cycle_funded_after_overdue_date,
    SUM(a.newly_approved_after_overdue_date) AS users_cycle_newly_approved_after_overdue_date,
    SUM(a.approval_same_overdue_date) AS users_approval_on_same_overdue_date,
    SUM(a.later_fund_missing_grant) AS users_later_fund_missing_grant
  FROM cohort_users u JOIN overdue_followup a ON a.user_id=u.user_id GROUP BY u.cohort_name
), audit AS (
  SELECT (SELECT COUNT(*) FROM tags WHERE type_n>1) AS conflicting_type_serials,
    (SELECT COUNT(*) FROM funds) AS valid_funded_history_orders,
    (SELECT COUNT(*) FROM cohort) AS active_cohort_users,
    (SELECT COUNT(*) FROM cohort WHERE first_in_period=1) AS new_cycle_cohort_users,
    (SELECT SUM(duplicate_source_period_rows) FROM period_order) AS duplicate_period_rows,
    (SELECT SUM(conflicting_periods) FROM period_order) AS conflicting_overdue_periods,
    (SELECT COUNT(*) FROM post WHERE loan_status_code=7 AND (repaid_time<=TIMESTAMP '2000-01-01' OR repaid_time IS NULL)) AS status7_missing_close_time_orders,
    (SELECT COUNT(*) FROM post WHERE repaid_time>TIMESTAMP '2000-01-01' AND repaid_time<remit_time) AS negative_holding_time_orders,
    (SELECT COUNT(*) FROM user_state WHERE risk_status='待核验') AS unmapped_risk_users
)
SELECT 'lifecycle_totals'::text AS result_kind,ROW_TO_JSON(x)::text AS payload FROM totals x
UNION ALL SELECT 'lifecycle_paths',ROW_TO_JSON(x)::text FROM paths x
UNION ALL SELECT 'lifecycle_silence_risk',ROW_TO_JSON(x)::text FROM silence x
UNION ALL SELECT 'lifecycle_monthly_paths',ROW_TO_JSON(x)::text FROM monthly_paths x
UNION ALL SELECT 'cancellation_audit',ROW_TO_JSON(x)::text FROM cancellation_audit x
UNION ALL SELECT 'lifecycle_source_audit',ROW_TO_JSON(x)::text FROM audit x;
-- END MODULE: lifecycle


-- MODULE: duration
/* 只读：循环贷可提单获额订单的有效窗口及实际使用/失效时长。
   入样条件is_pass1=1且recycle_type唯一为2。保持既往20秒相邻获额批次去重：
   同一serial先取最新记录，再每用户相邻间隔<=20秒视为一批，取批次最后时刻/最大serial。
   下一次分期或整笔结清，即使新获额失败或不可提单，也作为原未使用获额的覆盖终点。
   15天沿用原提单窗口D0~D14，过期时刻=获额日期+15日的00:00；并另给滚动360小时敏感性。
   可用窗口=min(下一次结清,15天过期)-获额时刻，独立于是否已提单。
   实际存续=min(本serial首次提单,下一次结清,15天过期)-获额时刻。
   提单只按同serial匹配，不限制成功放款；早于获额/过期后提单独立审计。
   日分组为终点日期-获额日期；满24小时分组另列。当前仍有效为右删失，不冒充完整时长。
*/
WITH params AS (
  SELECT DATE '2025-07-01' AS start_date,
         TIMESTAMP '2026-10-14 09:21:51.893707' AS snapshot_time
), tags AS (
  SELECT serial_id,COUNT(DISTINCT recycle_type) AS type_n,MIN(recycle_type) AS recycle_type
  FROM wangchuanliang.side_recycle_type_copy GROUP BY serial_id
), valid_offers AS (
  SELECT DISTINCT ON (v.user_id,v.serial_id)
    v.user_id,v.serial_id,v.vir_date,
    TO_TIMESTAMP(v.vir_unix) AT TIME ZONE 'America/Belize' AS vir_time
  FROM wangchuanliang.order_vir_f_copy v JOIN tags t ON t.serial_id=v.serial_id CROSS JOIN params p
  WHERE v.is_pass1=1 AND t.type_n=1 AND t.recycle_type=2
    AND v.user_id IS NOT NULL AND v.serial_id IS NOT NULL AND v.vir_unix>0
    AND TO_TIMESTAMP(v.vir_unix) AT TIME ZONE 'America/Belize'>=p.start_date::timestamp-INTERVAL '1 day'
    AND TO_TIMESTAMP(v.vir_unix) AT TIME ZONE 'America/Belize'<=p.snapshot_time
  ORDER BY v.user_id,v.serial_id,v.vir_unix DESC
), offer_lag AS (
  SELECT v.*,LAG(vir_time) OVER(PARTITION BY user_id ORDER BY vir_time,serial_id) AS previous_time FROM valid_offers v
), offer_batch AS (
  SELECT v.*,SUM(CASE WHEN previous_time IS NULL OR vir_time-previous_time>INTERVAL '20 seconds' THEN 1 ELSE 0 END)
    OVER(PARTITION BY user_id ORDER BY vir_time,serial_id ROWS UNBOUNDED PRECEDING) AS batch_id FROM offer_lag v
), offer_rank AS (
  SELECT v.*,ROW_NUMBER() OVER(PARTITION BY user_id,batch_id ORDER BY vir_time DESC,serial_id DESC) AS rn FROM offer_batch v
), offers AS (
  SELECT v.*,TO_CHAR(v.vir_time,'YYYY-MM') AS month,
    v.vir_time::date+15 AS expiry_date,
    (v.vir_time::date+15)::timestamp AS expiry_time,
    v.vir_time+INTERVAL '15 days' AS rolling_expiry_time
  FROM offer_rank v CROSS JOIN params p WHERE v.rn=1 AND v.vir_time>=p.start_date::timestamp
), funded AS (
  SELECT DISTINCT ON (o.user_id,o.serial_id) o.user_id,o.serial_id,o.remit_time,o.repaid_time,o.repaid_date,o.is_repaid,o.loan_status_code
  FROM wangchuanliang.order_loan_f_v2_copy o CROSS JOIN params p
  WHERE o.is_remit=1 AND o.remit_amt>0 AND o.remit_time>TIMESTAMP '2000-01-01'
    AND o.remit_time<=p.snapshot_time
  ORDER BY o.user_id,o.serial_id,o.apply_time ASC NULLS LAST
), close_events AS (
  SELECT user_id,close_time,MAX(is_whole) AS includes_whole,MAX(is_period) AS includes_period
  FROM (
    SELECT f.user_id,f.repaid_time AS close_time,1 AS is_whole,0 AS is_period
    FROM funded f CROSS JOIN params p
    WHERE (f.is_repaid=1 OR f.loan_status_code=7) AND f.repaid_time>=p.start_date::timestamp-INTERVAL '1 day'
      AND f.repaid_time<=p.snapshot_time AND f.repaid_time>=f.remit_time
    UNION ALL
    SELECT f.user_id,rp.repaid_time_period,0,1
    FROM wangchuanliang.repayment_plan_v2_copy rp JOIN funded f ON f.serial_id=rp.serial_id CROSS JOIN params p
    WHERE (rp.is_repaid_period=1 OR rp.loan_status_code_period=7)
      AND rp.repaid_time_period>=p.start_date::timestamp-INTERVAL '1 day'
      AND rp.repaid_time_period<=p.snapshot_time AND rp.repaid_time_period>=f.remit_time
  ) q GROUP BY user_id,close_time
), timeline AS (
  SELECT user_id,vir_time AS event_time,1 AS event_kind,serial_id FROM offers
  UNION ALL SELECT user_id,close_time,0,NULL::bigint FROM close_events
), timeline_windows AS (
  SELECT e.*,
    MIN(CASE WHEN event_kind=0 THEN event_time END)
      OVER(PARTITION BY user_id ORDER BY event_time,event_kind,serial_id
           ROWS BETWEEN 1 FOLLOWING AND UNBOUNDED FOLLOWING) AS next_close_time,
    MAX(CASE WHEN event_kind=0 THEN event_time END)
      OVER(PARTITION BY user_id ORDER BY event_time,event_kind,serial_id
           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS previous_close_time
  FROM timeline e
), offer_bound AS (
  SELECT o.*,t.next_close_time,t.previous_close_time,
    LEAST(COALESCE(t.next_close_time,o.expiry_time),o.expiry_time) AS available_end_time,
    LEAST(COALESCE(t.next_close_time,o.rolling_expiry_time),o.rolling_expiry_time) AS rolling_available_end_time,
    CASE WHEN t.next_close_time IS NOT NULL AND t.next_close_time<o.expiry_time THEN '下次结清覆盖失效' ELSE '15自然日到期' END AS available_end_reason,
    CASE WHEN t.previous_close_time::date=o.vir_time::date THEN 1 ELSE 0 END AS same_day_close_origin,
    CASE WHEN o.vir_time-t.previous_close_time BETWEEN INTERVAL '0 seconds' AND INTERVAL '20 seconds' THEN 1 ELSE 0 END AS close_origin_within20s
  FROM offers o JOIN timeline_windows t ON t.user_id=o.user_id AND t.serial_id=o.serial_id AND t.event_kind=1
), first_apply AS (
  SELECT o.serial_id,MIN(a.apply_time) AS apply_time,
    COUNT(DISTINCT a.user_id) AS apply_user_n,
    SUM(CASE WHEN a.user_id<>o.user_id THEN 1 ELSE 0 END) AS user_mismatch_rows
  FROM offers o JOIN wangchuanliang.order_loan_f_v2_copy a ON a.serial_id=o.serial_id CROSS JOIN params p
  WHERE a.apply_time>TIMESTAMP '2000-01-01' AND a.apply_time<=p.snapshot_time
  GROUP BY o.serial_id
), bound_apply AS (
  SELECT b.*,a.apply_time,COALESCE(a.user_mismatch_rows,0) AS user_mismatch_rows,
    CASE WHEN a.apply_time<b.vir_time THEN 1 ELSE 0 END AS apply_before_offer,
    CASE WHEN a.apply_time>=b.available_end_time THEN 1 ELSE 0 END AS apply_at_or_after_end,
    CASE WHEN a.apply_time>=b.vir_time AND a.apply_time<b.available_end_time AND COALESCE(a.user_mismatch_rows,0)=0 THEN 1 ELSE 0 END AS valid_apply,
    CASE WHEN a.apply_time>=b.vir_time AND a.apply_time<b.available_end_time AND COALESCE(a.user_mismatch_rows,0)=0
         THEN a.apply_time ELSE b.available_end_time END AS actual_end_time
  FROM offer_bound b LEFT JOIN first_apply a ON a.serial_id=b.serial_id
), measured AS (
  SELECT b.*,
    CASE WHEN b.apply_before_offer=1 OR b.user_mismatch_rows>0 THEN '提单关联或时间异常'
         WHEN b.valid_apply=1 THEN '有效窗内已提单'
         WHEN b.available_end_time>p.snapshot_time THEN '截至取数仍有效未提单'
         ELSE b.available_end_reason END AS actual_end_reason,
    CASE WHEN b.available_end_time<=p.snapshot_time THEN 1 ELSE 0 END AS completed_available_window,
    CASE WHEN (b.valid_apply=1 OR b.available_end_time<=p.snapshot_time) AND b.apply_before_offer=0 AND b.user_mismatch_rows=0 THEN 1 ELSE 0 END AS completed_actual_duration,
    LEAST(b.available_end_time,p.snapshot_time) AS available_observed_end_time,
    LEAST(b.actual_end_time,p.snapshot_time) AS actual_observed_end_time
  FROM bound_apply b CROSS JOIN params p
), monthly AS (
  SELECT month,COUNT(*) AS eligible_orders,
    SUM(same_day_close_origin) AS same_day_close_origin_orders,
    SUM(close_origin_within20s) AS close_origin_within20s_orders,
    SUM(completed_available_window) AS completed_available_orders,
    SUM(completed_actual_duration) AS completed_actual_orders,
    SUM(valid_apply) AS valid_applied_orders,
    SUM(CASE WHEN actual_end_reason='下次结清覆盖失效' THEN 1 ELSE 0 END) AS overwritten_unapplied_orders,
    SUM(CASE WHEN actual_end_reason='15自然日到期' THEN 1 ELSE 0 END) AS expired_unapplied_orders,
    SUM(CASE WHEN actual_end_reason='截至取数仍有效未提单' THEN 1 ELSE 0 END) AS still_valid_unapplied_orders,
    SUM(CASE WHEN actual_end_reason='提单关联或时间异常' THEN 1 ELSE 0 END) AS anomalous_orders,
    AVG(CASE WHEN completed_available_window=1 THEN EXTRACT(EPOCH FROM (available_end_time-vir_time))/86400.0 END) AS completed_available_mean_days,
    AVG(CASE WHEN completed_actual_duration=1 THEN EXTRACT(EPOCH FROM (actual_end_time-vir_time))/86400.0 END) AS completed_actual_mean_days,
    SUM(CASE WHEN available_end_reason='下次结清覆盖失效' AND completed_available_window=1 THEN 1 ELSE 0 END) AS completed_potential_overwritten_orders,
    SUM(CASE WHEN rolling_available_end_time<>available_end_time THEN 1 ELSE 0 END) AS affected_by_calendar_vs_rolling15_orders,
    SUM(CASE WHEN rolling_available_end_time>available_end_time AND apply_time>=available_end_time
                  AND apply_time<rolling_available_end_time THEN 1 ELSE 0 END) AS extra_apply_if_rolling15_orders
  FROM measured GROUP BY month
), raw_monthly AS (
  SELECT TO_CHAR(v.vir_time,'YYYY-MM') AS month,COUNT(*) AS serial_dedup_before20s_orders
  FROM valid_offers v CROSS JOIN params p WHERE v.vir_time>=p.start_date::timestamp GROUP BY TO_CHAR(v.vir_time,'YYYY-MM')
), available_days AS (
  SELECT month,(available_end_time::date-vir_time::date) AS day_group,available_end_reason,
    COUNT(*) AS orders,AVG(EXTRACT(EPOCH FROM (available_end_time-vir_time))/86400.0) AS mean_elapsed_days
  FROM measured WHERE completed_available_window=1
  GROUP BY month,(available_end_time::date-vir_time::date),available_end_reason
), actual_days AS (
  SELECT month,(actual_end_time::date-vir_time::date) AS day_group,actual_end_reason,COUNT(*) AS orders,
    AVG(EXTRACT(EPOCH FROM (actual_end_time-vir_time))/86400.0) AS mean_elapsed_days
  FROM measured WHERE completed_actual_duration=1
  GROUP BY month,(actual_end_time::date-vir_time::date),actual_end_reason
), elapsed_days AS (
  SELECT month,FLOOR(EXTRACT(EPOCH FROM (available_end_time-vir_time))/86400.0)::integer AS full24h_days,
    available_end_reason,COUNT(*) AS orders
  FROM measured WHERE completed_available_window=1
  GROUP BY month,FLOOR(EXTRACT(EPOCH FROM (available_end_time-vir_time))/86400.0)::integer,available_end_reason
), censored_days AS (
  SELECT month,(p.snapshot_time::date-vir_time::date) AS observed_day_group,COUNT(*) AS orders
  FROM measured CROSS JOIN params p WHERE actual_end_reason='截至取数仍有效未提单'
  GROUP BY month,(p.snapshot_time::date-vir_time::date)
), grant_scenes AS (
  SELECT DISTINCT v.user_id,TO_TIMESTAMP(v.vir_unix) AT TIME ZONE 'America/Belize' AS vir_time
  FROM wangchuanliang.order_vir_f_copy v CROSS JOIN params p
  WHERE v.vir_unix>0 AND TO_TIMESTAMP(v.vir_unix) AT TIME ZONE 'America/Belize'>=p.start_date::timestamp
    AND TO_TIMESTAMP(v.vir_unix) AT TIME ZONE 'America/Belize'<=p.snapshot_time
), next_close_distinct AS (
  SELECT DISTINCT user_id,next_close_time FROM measured WHERE next_close_time IS NOT NULL
), next_close_grant AS (
  SELECT n.user_id,n.next_close_time,COUNT(g.vir_time) AS new_grants_within20s
  FROM next_close_distinct n LEFT JOIN grant_scenes g ON g.user_id=n.user_id
    AND g.vir_time>=n.next_close_time AND g.vir_time<=n.next_close_time+INTERVAL '20 seconds'
  GROUP BY n.user_id,n.next_close_time
), renewal_audit AS (
  SELECT m.month,COUNT(*) AS offers_with_next_close,
    SUM(CASE WHEN g.new_grants_within20s>0 THEN 1 ELSE 0 END) AS next_close_has_grant_within20s_orders,
    SUM(CASE WHEN g.new_grants_within20s=0 THEN 1 ELSE 0 END) AS next_close_missing_grant_within20s_orders,
    SUM(CASE WHEN m.next_close_time<m.expiry_time AND g.new_grants_within20s=0 THEN 1 ELSE 0 END) AS short_window_missing_renewal_grant_orders
  FROM measured m JOIN next_close_grant g ON g.user_id=m.user_id AND g.next_close_time=m.next_close_time GROUP BY m.month
), audit AS (
  SELECT COUNT(*) AS eligible_orders,
    SUM(apply_before_offer) AS apply_before_offer_orders,
    SUM(apply_at_or_after_end) AS apply_at_or_after_end_orders,
    SUM(CASE WHEN user_mismatch_rows>0 THEN 1 ELSE 0 END) AS apply_user_mismatch_orders,
    SUM(CASE WHEN vir_time::date<>vir_date THEN 1 ELSE 0 END) AS offer_date_timestamp_mismatch_orders,
    SUM(CASE WHEN available_end_time<=vir_time THEN 1 ELSE 0 END) AS nonpositive_available_window_orders,
    SUM(CASE WHEN next_close_time<=vir_time THEN 1 ELSE 0 END) AS invalid_next_close_orders,
    (SELECT COUNT(*) FROM tags WHERE type_n>1) AS conflicting_type_serials,
    (SELECT COUNT(*) FROM offers)-(SELECT COUNT(DISTINCT serial_id) FROM offers) AS duplicate_selected_serials
  FROM measured
)
SELECT 'duration_monthly'::text AS result_kind,ROW_TO_JSON(x)::text AS payload FROM monthly x
UNION ALL SELECT 'duration_raw_serial_monthly',ROW_TO_JSON(x)::text FROM raw_monthly x
UNION ALL SELECT 'available_calendar_day_distribution',ROW_TO_JSON(x)::text FROM available_days x
UNION ALL SELECT 'actual_calendar_day_distribution',ROW_TO_JSON(x)::text FROM actual_days x
UNION ALL SELECT 'available_full24h_day_distribution',ROW_TO_JSON(x)::text FROM elapsed_days x
UNION ALL SELECT 'still_valid_observed_day_distribution',ROW_TO_JSON(x)::text FROM censored_days x
UNION ALL SELECT 'renewal_at_next_close_audit',ROW_TO_JSON(x)::text FROM renewal_audit x
UNION ALL SELECT 'duration_source_audit',ROW_TO_JSON(x)::text FROM audit x;
-- END MODULE: duration


-- MODULE: renewal
/* 只读：循环贷可提单获额订单的有效窗口及实际使用/失效时长。
   入样条件is_pass1=1且recycle_type唯一为2。保持既往20秒相邻获额批次去重：
   同一serial先取最新记录，再每用户相邻间隔<=20秒视为一批，取批次最后时刻/最大serial。
   下一次分期或整笔结清，即使新获额失败或不可提单，也作为原未使用获额的覆盖终点。
   15天沿用原提单窗口D0~D14，过期时刻=获额日期+15日的00:00；并另给滚动360小时敏感性。
   可用窗口=min(下一次结清,15天过期)-获额时刻，独立于是否已提单。
   实际存续=min(本serial首次提单,下一次结清,15天过期)-获额时刻。
   提单只按同serial匹配，不限制成功放款；早于获额/过期后提单独立审计。
   日分组为终点日期-获额日期；满24小时分组另列。当前仍有效为右删失，不冒充完整时长。
*/
WITH params AS (
  SELECT DATE '2025-07-01' AS start_date,
         TIMESTAMP '2026-10-14 09:27:27.582028' AS snapshot_time
), tags AS (
  SELECT serial_id,COUNT(DISTINCT recycle_type) AS type_n,MIN(recycle_type) AS recycle_type
  FROM wangchuanliang.side_recycle_type_copy GROUP BY serial_id
), valid_offers AS (
  SELECT DISTINCT ON (v.user_id,v.serial_id)
    v.user_id,v.serial_id,v.vir_date,
    TO_TIMESTAMP(v.vir_unix) AT TIME ZONE 'America/Belize' AS vir_time
  FROM wangchuanliang.order_vir_f_copy v JOIN tags t ON t.serial_id=v.serial_id CROSS JOIN params p
  WHERE v.is_pass1=1 AND t.type_n=1 AND t.recycle_type=2
    AND v.user_id IS NOT NULL AND v.serial_id IS NOT NULL AND v.vir_unix>0
    AND TO_TIMESTAMP(v.vir_unix) AT TIME ZONE 'America/Belize'>=p.start_date::timestamp-INTERVAL '1 day'
    AND TO_TIMESTAMP(v.vir_unix) AT TIME ZONE 'America/Belize'<=p.snapshot_time
  ORDER BY v.user_id,v.serial_id,v.vir_unix DESC
), offer_lag AS (
  SELECT v.*,LAG(vir_time) OVER(PARTITION BY user_id ORDER BY vir_time,serial_id) AS previous_time FROM valid_offers v
), offer_batch AS (
  SELECT v.*,SUM(CASE WHEN previous_time IS NULL OR vir_time-previous_time>INTERVAL '20 seconds' THEN 1 ELSE 0 END)
    OVER(PARTITION BY user_id ORDER BY vir_time,serial_id ROWS UNBOUNDED PRECEDING) AS batch_id FROM offer_lag v
), offer_rank AS (
  SELECT v.*,ROW_NUMBER() OVER(PARTITION BY user_id,batch_id ORDER BY vir_time DESC,serial_id DESC) AS rn FROM offer_batch v
), offers AS (
  SELECT v.*,TO_CHAR(v.vir_time,'YYYY-MM') AS month,
    v.vir_time::date+15 AS expiry_date,
    (v.vir_time::date+15)::timestamp AS expiry_time,
    v.vir_time+INTERVAL '15 days' AS rolling_expiry_time
  FROM offer_rank v CROSS JOIN params p WHERE v.rn=1 AND v.vir_time>=p.start_date::timestamp
), funded AS (
  SELECT DISTINCT ON (o.user_id,o.serial_id) o.user_id,o.serial_id,o.remit_time,o.repaid_time,o.repaid_date,o.is_repaid,o.loan_status_code
  FROM wangchuanliang.order_loan_f_v2_copy o CROSS JOIN params p
  WHERE o.is_remit=1 AND o.remit_amt>0 AND o.remit_time>TIMESTAMP '2000-01-01'
    AND o.remit_time<=p.snapshot_time
  ORDER BY o.user_id,o.serial_id,o.apply_time ASC NULLS LAST
), close_events AS (
  SELECT user_id,close_time,MAX(is_whole) AS includes_whole,MAX(is_period) AS includes_period
  FROM (
    SELECT f.user_id,f.repaid_time AS close_time,1 AS is_whole,0 AS is_period
    FROM funded f CROSS JOIN params p
    WHERE (f.is_repaid=1 OR f.loan_status_code=7) AND f.repaid_time>=p.start_date::timestamp-INTERVAL '1 day'
      AND f.repaid_time<=p.snapshot_time AND f.repaid_time>=f.remit_time
    UNION ALL
    SELECT f.user_id,rp.repaid_time_period,0,1
    FROM wangchuanliang.repayment_plan_v2_copy rp JOIN funded f ON f.serial_id=rp.serial_id CROSS JOIN params p
    WHERE (rp.is_repaid_period=1 OR rp.loan_status_code_period=7)
      AND rp.repaid_time_period>=p.start_date::timestamp-INTERVAL '1 day'
      AND rp.repaid_time_period<=p.snapshot_time AND rp.repaid_time_period>=f.remit_time
  ) q GROUP BY user_id,close_time
), timeline AS (
  SELECT user_id,vir_time AS event_time,1 AS event_kind,serial_id FROM offers
  UNION ALL SELECT user_id,close_time,0,NULL::bigint FROM close_events
), timeline_windows AS (
  SELECT e.*,
    MIN(CASE WHEN event_kind=0 THEN event_time END)
      OVER(PARTITION BY user_id ORDER BY event_time,event_kind,serial_id
           ROWS BETWEEN 1 FOLLOWING AND UNBOUNDED FOLLOWING) AS next_close_time,
    MAX(CASE WHEN event_kind=0 THEN event_time END)
      OVER(PARTITION BY user_id ORDER BY event_time,event_kind,serial_id
           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS previous_close_time
  FROM timeline e
), offer_bound AS (
  SELECT o.*,t.next_close_time,t.previous_close_time,
    LEAST(COALESCE(t.next_close_time,o.expiry_time),o.expiry_time) AS available_end_time,
    LEAST(COALESCE(t.next_close_time,o.rolling_expiry_time),o.rolling_expiry_time) AS rolling_available_end_time,
    CASE WHEN t.next_close_time IS NOT NULL AND t.next_close_time<o.expiry_time THEN '下次结清覆盖失效' ELSE '15自然日到期' END AS available_end_reason,
    CASE WHEN t.previous_close_time::date=o.vir_time::date THEN 1 ELSE 0 END AS same_day_close_origin,
    CASE WHEN o.vir_time-t.previous_close_time BETWEEN INTERVAL '0 seconds' AND INTERVAL '20 seconds' THEN 1 ELSE 0 END AS close_origin_within20s
  FROM offers o JOIN timeline_windows t ON t.user_id=o.user_id AND t.serial_id=o.serial_id AND t.event_kind=1
), first_apply AS (
  SELECT o.serial_id,MIN(a.apply_time) AS apply_time,
    COUNT(DISTINCT a.user_id) AS apply_user_n,
    SUM(CASE WHEN a.user_id<>o.user_id THEN 1 ELSE 0 END) AS user_mismatch_rows
  FROM offers o JOIN wangchuanliang.order_loan_f_v2_copy a ON a.serial_id=o.serial_id CROSS JOIN params p
  WHERE a.apply_time>TIMESTAMP '2000-01-01' AND a.apply_time<=p.snapshot_time
  GROUP BY o.serial_id
), bound_apply AS (
  SELECT b.*,a.apply_time,COALESCE(a.user_mismatch_rows,0) AS user_mismatch_rows,
    CASE WHEN a.apply_time<b.vir_time THEN 1 ELSE 0 END AS apply_before_offer,
    CASE WHEN a.apply_time>=b.available_end_time THEN 1 ELSE 0 END AS apply_at_or_after_end,
    CASE WHEN a.apply_time>=b.vir_time AND a.apply_time<b.available_end_time AND COALESCE(a.user_mismatch_rows,0)=0 THEN 1 ELSE 0 END AS valid_apply,
    CASE WHEN a.apply_time>=b.vir_time AND a.apply_time<b.available_end_time AND COALESCE(a.user_mismatch_rows,0)=0
         THEN a.apply_time ELSE b.available_end_time END AS actual_end_time
  FROM offer_bound b LEFT JOIN first_apply a ON a.serial_id=b.serial_id
), measured AS (
  SELECT b.*,
    CASE WHEN b.apply_before_offer=1 OR b.user_mismatch_rows>0 THEN '提单关联或时间异常'
         WHEN b.valid_apply=1 THEN '有效窗内已提单'
         WHEN b.available_end_time>p.snapshot_time THEN '截至取数仍有效未提单'
         ELSE b.available_end_reason END AS actual_end_reason,
    CASE WHEN b.available_end_time<=p.snapshot_time THEN 1 ELSE 0 END AS completed_available_window,
    CASE WHEN (b.valid_apply=1 OR b.available_end_time<=p.snapshot_time) AND b.apply_before_offer=0 AND b.user_mismatch_rows=0 THEN 1 ELSE 0 END AS completed_actual_duration,
    LEAST(b.available_end_time,p.snapshot_time) AS available_observed_end_time,
    LEAST(b.actual_end_time,p.snapshot_time) AS actual_observed_end_time
  FROM bound_apply b CROSS JOIN params p
), monthly AS (
  SELECT month,COUNT(*) AS eligible_orders,
    SUM(same_day_close_origin) AS same_day_close_origin_orders,
    SUM(close_origin_within20s) AS close_origin_within20s_orders,
    SUM(completed_available_window) AS completed_available_orders,
    SUM(completed_actual_duration) AS completed_actual_orders,
    SUM(valid_apply) AS valid_applied_orders,
    SUM(CASE WHEN actual_end_reason='下次结清覆盖失效' THEN 1 ELSE 0 END) AS overwritten_unapplied_orders,
    SUM(CASE WHEN actual_end_reason='15自然日到期' THEN 1 ELSE 0 END) AS expired_unapplied_orders,
    SUM(CASE WHEN actual_end_reason='截至取数仍有效未提单' THEN 1 ELSE 0 END) AS still_valid_unapplied_orders,
    SUM(CASE WHEN actual_end_reason='提单关联或时间异常' THEN 1 ELSE 0 END) AS anomalous_orders,
    AVG(CASE WHEN completed_available_window=1 THEN EXTRACT(EPOCH FROM (available_end_time-vir_time))/86400.0 END) AS completed_available_mean_days,
    AVG(CASE WHEN completed_actual_duration=1 THEN EXTRACT(EPOCH FROM (actual_end_time-vir_time))/86400.0 END) AS completed_actual_mean_days,
    SUM(CASE WHEN available_end_reason='下次结清覆盖失效' AND completed_available_window=1 THEN 1 ELSE 0 END) AS completed_potential_overwritten_orders,
    SUM(CASE WHEN rolling_available_end_time<>available_end_time THEN 1 ELSE 0 END) AS affected_by_calendar_vs_rolling15_orders,
    SUM(CASE WHEN rolling_available_end_time>available_end_time AND apply_time>=available_end_time
                  AND apply_time<rolling_available_end_time THEN 1 ELSE 0 END) AS extra_apply_if_rolling15_orders
  FROM measured GROUP BY month
), raw_monthly AS (
  SELECT TO_CHAR(v.vir_time,'YYYY-MM') AS month,COUNT(*) AS serial_dedup_before20s_orders
  FROM valid_offers v CROSS JOIN params p WHERE v.vir_time>=p.start_date::timestamp GROUP BY TO_CHAR(v.vir_time,'YYYY-MM')
), available_days AS (
  SELECT month,(available_end_time::date-vir_time::date) AS day_group,available_end_reason,
    COUNT(*) AS orders,AVG(EXTRACT(EPOCH FROM (available_end_time-vir_time))/86400.0) AS mean_elapsed_days
  FROM measured WHERE completed_available_window=1
  GROUP BY month,(available_end_time::date-vir_time::date),available_end_reason
), actual_days AS (
  SELECT month,(actual_end_time::date-vir_time::date) AS day_group,actual_end_reason,COUNT(*) AS orders,
    AVG(EXTRACT(EPOCH FROM (actual_end_time-vir_time))/86400.0) AS mean_elapsed_days
  FROM measured WHERE completed_actual_duration=1
  GROUP BY month,(actual_end_time::date-vir_time::date),actual_end_reason
), elapsed_days AS (
  SELECT month,FLOOR(EXTRACT(EPOCH FROM (available_end_time-vir_time))/86400.0)::integer AS full24h_days,
    available_end_reason,COUNT(*) AS orders
  FROM measured WHERE completed_available_window=1
  GROUP BY month,FLOOR(EXTRACT(EPOCH FROM (available_end_time-vir_time))/86400.0)::integer,available_end_reason
), censored_days AS (
  SELECT month,(p.snapshot_time::date-vir_time::date) AS observed_day_group,COUNT(*) AS orders
  FROM measured CROSS JOIN params p WHERE actual_end_reason='截至取数仍有效未提单'
  GROUP BY month,(p.snapshot_time::date-vir_time::date)
), grant_scenes AS (
  SELECT DISTINCT v.user_id,TO_TIMESTAMP(v.vir_unix) AT TIME ZONE 'America/Belize' AS vir_time
  FROM wangchuanliang.order_vir_f_copy v CROSS JOIN params p
  WHERE v.vir_unix>0 AND TO_TIMESTAMP(v.vir_unix) AT TIME ZONE 'America/Belize'>=p.start_date::timestamp
    AND TO_TIMESTAMP(v.vir_unix) AT TIME ZONE 'America/Belize'<=p.snapshot_time
), next_close_distinct AS (
  SELECT DISTINCT user_id,next_close_time FROM measured WHERE next_close_time IS NOT NULL
), next_close_grant AS (
  SELECT n.user_id,n.next_close_time,COUNT(g.vir_time) AS new_grants_within20s
  FROM next_close_distinct n LEFT JOIN grant_scenes g ON g.user_id=n.user_id
    AND g.vir_time>=n.next_close_time AND g.vir_time<=n.next_close_time+INTERVAL '20 seconds'
  GROUP BY n.user_id,n.next_close_time
), renewal_audit AS (
  SELECT m.month,COUNT(*) AS offers_with_next_close,
    SUM(CASE WHEN g.new_grants_within20s>0 THEN 1 ELSE 0 END) AS next_close_has_grant_within20s_orders,
    SUM(CASE WHEN g.new_grants_within20s=0 THEN 1 ELSE 0 END) AS next_close_missing_grant_within20s_orders,
    SUM(CASE WHEN m.next_close_time<m.expiry_time AND g.new_grants_within20s=0 THEN 1 ELSE 0 END) AS short_window_missing_renewal_grant_orders
  FROM measured m JOIN next_close_grant g ON g.user_id=m.user_id AND g.next_close_time=m.next_close_time GROUP BY m.month
), audit AS (
  SELECT COUNT(*) AS eligible_orders,
    SUM(apply_before_offer) AS apply_before_offer_orders,
    SUM(apply_at_or_after_end) AS apply_at_or_after_end_orders,
    SUM(CASE WHEN user_mismatch_rows>0 THEN 1 ELSE 0 END) AS apply_user_mismatch_orders,
    SUM(CASE WHEN vir_time::date<>vir_date THEN 1 ELSE 0 END) AS offer_date_timestamp_mismatch_orders,
    SUM(CASE WHEN available_end_time<=vir_time THEN 1 ELSE 0 END) AS nonpositive_available_window_orders,
    SUM(CASE WHEN next_close_time<=vir_time THEN 1 ELSE 0 END) AS invalid_next_close_orders,
    (SELECT COUNT(*) FROM tags WHERE type_n>1) AS conflicting_type_serials,
    (SELECT COUNT(*) FROM offers)-(SELECT COUNT(DISTINCT serial_id) FROM offers) AS duplicate_selected_serials
  FROM measured
)
 , missing_fast_renewal AS (
   SELECT n.user_id,n.next_close_time,MIN(g.vir_time) AS first_delayed_grant
   FROM next_close_grant n LEFT JOIN grant_scenes g ON g.user_id=n.user_id
     AND g.vir_time>=n.next_close_time AND g.vir_time<n.next_close_time+INTERVAL '1 day'
   WHERE n.new_grants_within20s=0 GROUP BY n.user_id,n.next_close_time
 ), coverage AS (
   SELECT m.actual_end_reason,COUNT(*) AS orders,
     SUM(CASE WHEN n.new_grants_within20s>0 THEN 1 ELSE 0 END) AS renewed_within20s_orders,
     SUM(CASE WHEN n.new_grants_within20s=0 AND a.first_delayed_grant IS NOT NULL THEN 1 ELSE 0 END) AS renewed_later_within24h_orders,
     SUM(CASE WHEN n.new_grants_within20s=0 AND a.first_delayed_grant IS NULL THEN 1 ELSE 0 END) AS no_renewal_within24h_orders
   FROM measured m JOIN next_close_grant n ON n.user_id=m.user_id AND n.next_close_time=m.next_close_time
   LEFT JOIN missing_fast_renewal a ON a.user_id=m.user_id AND a.next_close_time=m.next_close_time
   WHERE m.next_close_time<m.expiry_time GROUP BY m.actual_end_reason
 ), late_apply AS (
   SELECT CASE WHEN m.apply_time>=m.expiry_time THEN '15自然日之后提单'
               WHEN n.new_grants_within20s>0 THEN '结清覆盖后提单且20秒内有新获额'
               WHEN a.first_delayed_grant IS NOT NULL AND a.first_delayed_grant<=m.apply_time THEN '结清覆盖后提单且提单前有延迟新获额'
               ELSE '结清覆盖后提单但提单前未证实新获额' END AS anomaly_kind,
          COUNT(*) AS orders,
          MIN(EXTRACT(EPOCH FROM(m.apply_time-m.available_end_time))) AS min_delay_seconds,
          MAX(EXTRACT(EPOCH FROM(m.apply_time-m.available_end_time))) AS max_delay_seconds
   FROM measured m LEFT JOIN next_close_grant n ON n.user_id=m.user_id AND n.next_close_time=m.next_close_time
   LEFT JOIN missing_fast_renewal a ON a.user_id=m.user_id AND a.next_close_time=m.next_close_time
   WHERE m.apply_at_or_after_end=1 GROUP BY 1
 )
 SELECT 'renewal_coverage'::text AS kind,ROW_TO_JSON(x)::text FROM coverage x
 UNION ALL SELECT 'late_apply_audit',ROW_TO_JSON(x)::text FROM late_apply x;
-- END MODULE: renewal


-- MODULE: offers
/* 循环贷获额订单提单率，纯订单维，与T0用户后续提单口径不同。
   分母：is_pass1=1且recycle_type唯一为2；每个serial_id仅保留最新通过获额记录。
   主表保留不同serial；同时给既往20秒批次去重对照，不能混用两套分母。
   分子：获额serial_id=提单serial_id，取本serial首次提单。不要求成功放款。
   不按用户找其他serial，也不以随后结清时间再截断实际同serial提单。
   D1/D2为第1/第2天单日，另给累计D0-D1/D0-D2。
   3日内=D0-D3，7日内=D0-D7；15自然日有效期=D0-D14（沿用原循环贷口径）。
   当前尚未观察满窗口的获额也进入分母，显示截至取数时的已观察提单率。
*/
WITH params AS (
  SELECT DATE '2025-07-01' AS start_date,
         TIMESTAMP '2026-10-14 09:43:44.681592' AS snapshot_time
), tags AS (
  SELECT serial_id,COUNT(DISTINCT recycle_type) AS type_n,MIN(recycle_type) AS recycle_type
  FROM wangchuanliang.side_recycle_type_copy GROUP BY serial_id
), eligible_rows AS (
  SELECT v.user_id,v.serial_id,v.vir_date::date AS vir_date,v.vir_unix,v.loan_type_code,
    TO_TIMESTAMP(v.vir_unix) AT TIME ZONE 'America/Belize' AS vir_time
  FROM wangchuanliang.order_vir_f_copy v JOIN tags t ON t.serial_id=v.serial_id CROSS JOIN params p
  WHERE v.is_pass1=1 AND t.type_n=1 AND t.recycle_type=2
    AND v.vir_unix>0 AND v.serial_id IS NOT NULL AND v.user_id IS NOT NULL
    AND TO_TIMESTAMP(v.vir_unix) AT TIME ZONE 'America/Belize'>=p.start_date::timestamp-INTERVAL '1 day'
    AND TO_TIMESTAMP(v.vir_unix) AT TIME ZONE 'America/Belize'<=p.snapshot_time
), serial_offers AS (
  SELECT DISTINCT ON (serial_id) user_id,serial_id,vir_date,vir_time,vir_unix,loan_type_code
  FROM eligible_rows ORDER BY serial_id,vir_unix DESC,user_id DESC
), with_lag AS (
  SELECT v.*,LAG(vir_time) OVER(PARTITION BY user_id ORDER BY vir_time,serial_id) AS prior_time FROM serial_offers v
), with_batch AS (
  SELECT v.*,SUM(CASE WHEN prior_time IS NULL OR vir_time-prior_time>INTERVAL '20 seconds' THEN 1 ELSE 0 END)
    OVER(PARTITION BY user_id ORDER BY vir_time,serial_id ROWS UNBOUNDED PRECEDING) AS batch_id FROM with_lag v
), ranked AS (
  SELECT v.*,ROW_NUMBER() OVER(PARTITION BY user_id,batch_id ORDER BY vir_time DESC,serial_id DESC) AS batch_rn
  FROM with_batch v
), offers AS (
  SELECT v.*,DATE_TRUNC('month',v.vir_time)::date AS month_start
  FROM ranked v CROSS JOIN params p WHERE v.vir_time>=p.start_date::timestamp
), matched_loan_rows AS (
  SELECT o.serial_id,o.user_id AS offer_user_id,a.user_id AS apply_user_id,a.apply_date,a.apply_time,
    CASE WHEN a.apply_time>TIMESTAMP '2000-01-01' AND a.apply_time<=p.snapshot_time THEN a.apply_time
         WHEN a.apply_date>DATE '2000-01-01' AND a.apply_date<=p.snapshot_time::date THEN a.apply_date::timestamp END AS apply_sort_time
  FROM offers o JOIN wangchuanliang.order_loan_f_v2_copy a ON a.serial_id=o.serial_id CROSS JOIN params p
  WHERE (a.apply_time<=p.snapshot_time OR a.apply_time IS NULL OR a.apply_time<=TIMESTAMP '2000-01-01')
), loan_presence AS (
  SELECT serial_id,COUNT(*) AS matched_rows,
    SUM(CASE WHEN offer_user_id<>apply_user_id OR apply_user_id IS NULL THEN 1 ELSE 0 END) AS user_mismatch_rows
  FROM matched_loan_rows GROUP BY serial_id
), first_apply AS (
  SELECT DISTINCT ON (serial_id) serial_id,apply_date,apply_time,apply_sort_time
  FROM matched_loan_rows WHERE apply_sort_time IS NOT NULL
  ORDER BY serial_id,apply_sort_time,apply_date,apply_user_id
), base AS (
  SELECT o.*,f.apply_date,f.apply_time,f.apply_sort_time,COALESCE(l.matched_rows,0) AS matched_rows,
    COALESCE(l.user_mismatch_rows,0) AS user_mismatch_rows,
    CASE WHEN f.apply_date>DATE '2000-01-01' THEN f.apply_date-o.vir_date
         WHEN f.apply_time>TIMESTAMP '2000-01-01' THEN f.apply_time::date-o.vir_date END AS apply_day,
    CASE WHEN p.snapshot_time::date>=o.vir_date+3 THEN 1 ELSE 0 END AS reached_d3_date,
    CASE WHEN p.snapshot_time::date>=o.vir_date+7 THEN 1 ELSE 0 END AS reached_d7_date,
    CASE WHEN p.snapshot_time>=(o.vir_date+15)::timestamp THEN 1 ELSE 0 END AS complete_15day_window
  FROM offers o LEFT JOIN first_apply f ON f.serial_id=o.serial_id
  LEFT JOIN loan_presence l ON l.serial_id=o.serial_id CROSS JOIN params p
), variants AS (
  SELECT 'serial_id订单去重'::text AS denominator_rule,b.* FROM base b
  UNION ALL SELECT '20秒批次去重对照',b.* FROM base b WHERE b.batch_rn=1
), counts AS (
  SELECT denominator_rule,month_start,COUNT(*) AS n_offer,
    SUM(CASE WHEN user_mismatch_rows=0 AND apply_day=0 THEN 1 ELSE 0 END) AS n_d0,
    SUM(CASE WHEN user_mismatch_rows=0 AND apply_day=1 THEN 1 ELSE 0 END) AS n_d1_only,
    SUM(CASE WHEN user_mismatch_rows=0 AND apply_day=2 THEN 1 ELSE 0 END) AS n_d2_only,
    SUM(CASE WHEN user_mismatch_rows=0 AND apply_day=3 THEN 1 ELSE 0 END) AS n_d3_only,
    SUM(CASE WHEN user_mismatch_rows=0 AND apply_day BETWEEN 0 AND 1 THEN 1 ELSE 0 END) AS n_d1_cumulative,
    SUM(CASE WHEN user_mismatch_rows=0 AND apply_day BETWEEN 0 AND 2 THEN 1 ELSE 0 END) AS n_d2_cumulative,
    SUM(CASE WHEN user_mismatch_rows=0 AND apply_day BETWEEN 0 AND 3 THEN 1 ELSE 0 END) AS n_d3_cumulative,
    SUM(CASE WHEN user_mismatch_rows=0 AND apply_day BETWEEN 0 AND 7 THEN 1 ELSE 0 END) AS n_d7_cumulative,
    SUM(CASE WHEN user_mismatch_rows=0 AND apply_day BETWEEN 0 AND 14 THEN 1 ELSE 0 END) AS n_d15_cumulative,
    SUM(CASE WHEN user_mismatch_rows=0 AND apply_day BETWEEN 4 AND 7 THEN 1 ELSE 0 END) AS n_d4_d7,
    SUM(CASE WHEN user_mismatch_rows=0 AND apply_day BETWEEN 8 AND 14 THEN 1 ELSE 0 END) AS n_d8_d14,
    SUM(CASE WHEN matched_rows>0 THEN 1 ELSE 0 END) AS n_any_serial_match,
    SUM(CASE WHEN apply_day>=15 THEN 1 ELSE 0 END) AS n_apply_after_15day_window,
    SUM(CASE WHEN apply_day<0 THEN 1 ELSE 0 END) AS n_apply_before_offer_date,
    SUM(CASE WHEN apply_time>TIMESTAMP '2000-01-01' AND apply_time<vir_time THEN 1 ELSE 0 END) AS n_apply_before_offer_time,
    SUM(CASE WHEN matched_rows>0 AND apply_day IS NULL THEN 1 ELSE 0 END) AS n_match_missing_apply_date,
    SUM(CASE WHEN matched_rows=0 THEN 1 ELSE 0 END) AS n_no_serial_match,
    SUM(CASE WHEN user_mismatch_rows>0 THEN 1 ELSE 0 END) AS n_user_mismatch,
    SUM(reached_d3_date) AS n_reached_d3_date,
    SUM(reached_d7_date) AS n_reached_d7_date,
    SUM(complete_15day_window) AS n_complete_15day_window,
    SUM(CASE WHEN apply_time>TIMESTAMP '2000-01-01' AND apply_date<>apply_time::date THEN 1 ELSE 0 END) AS n_apply_date_time_mismatch
  FROM variants GROUP BY denominator_rule,month_start
), monthly AS (
  SELECT c.*,TO_CHAR(month_start,'YYYY-MM') AS month,
    ROUND(100.0*n_d0/n_offer,4) AS d0_pct,
    ROUND(100.0*n_d1_only/n_offer,4) AS d1_only_pct,
    ROUND(100.0*n_d2_only/n_offer,4) AS d2_only_pct,
    ROUND(100.0*n_d1_cumulative/n_offer,4) AS d1_cumulative_pct,
    ROUND(100.0*n_d2_cumulative/n_offer,4) AS d2_cumulative_pct,
    ROUND(100.0*n_d3_cumulative/n_offer,4) AS d3_pct,
    ROUND(100.0*n_d7_cumulative/n_offer,4) AS d7_pct,
    ROUND(100.0*n_d15_cumulative/n_offer,4) AS d15_pct
  FROM counts c
), daily_distribution AS (
  SELECT denominator_rule,TO_CHAR(month_start,'YYYY-MM') AS month,apply_day,COUNT(*) AS matched_offer_orders
  FROM variants WHERE matched_rows>0 AND user_mismatch_rows=0
  GROUP BY denominator_rule,TO_CHAR(month_start,'YYYY-MM'),apply_day
), source_audit AS (
  SELECT (SELECT COUNT(*) FROM eligible_rows) AS eligible_source_rows_with_padding,
    (SELECT COUNT(*) FROM offers) AS serial_dedup_offer_count,
    (SELECT COUNT(*) FROM offers WHERE batch_rn=1) AS batch20_dedup_offer_count,
    (SELECT COUNT(*) FROM (SELECT serial_id FROM eligible_rows GROUP BY serial_id HAVING COUNT(DISTINCT user_id)>1) z) AS serial_multi_user_count,
    (SELECT COUNT(*) FROM tags WHERE type_n>1) AS conflicting_type_serials,
    (SELECT COUNT(*) FROM offers WHERE vir_date<>vir_time::date) AS offer_date_time_mismatch_count,
    (SELECT COUNT(*) FROM offers WHERE loan_type_code<>2 OR loan_type_code IS NULL) AS cycle_offer_not_reloan_code_count,
    (SELECT COUNT(*) FROM offers)-(SELECT COUNT(DISTINCT serial_id) FROM offers) AS duplicate_serial_count
)
SELECT 'monthly'::text AS result_kind,ROW_TO_JSON(x)::text AS payload FROM monthly x
UNION ALL SELECT 'daily_distribution',ROW_TO_JSON(x)::text FROM daily_distribution x
UNION ALL SELECT 'source_audit',ROW_TO_JSON(x)::text FROM source_audit x;
-- END MODULE: offers


-- MODULE: finance
/* 循环贷经营：成功放款月×整笔类型×成功放款次数。
   当前盈利和D7盈利均使用due_date<业务日期-7的同一成熟整笔订单子样本。
   当期规模/金额/件均/加权合同息费用全部成功放款订单，不被成熟筛选影响。
   当前账面盈利=(SUM(repaid_amt)-SUM(remit_amt))/SUM(remit_amt)。
   当前真实回款盈利=(实际流水SUM(amount)-SUM(remit_amt))/SUM(remit_amt)。
   固定D7盈利仅累计payin_date<=due_date+7的实际流水。
   盈利不是扣营销、资金、运营成本后的净利润，金额均为MXN，不做汇率转换。
   D7逾期以repaid_date无效或>due_date+7重建，当前逾期只看整笔状态8。
   分期和整笔不混用；同serial去重，流水不盲目DISTINCT。
*/
WITH params AS (
  SELECT DATE '2025-07-01' AS start_date,
    TIMESTAMP '2026-10-14 09:57:31.255477' AS snapshot_time,
    (TIMESTAMP '2026-10-14 09:57:31.255477')::date AS as_of_date
), tags AS (
  SELECT serial_id,COUNT(DISTINCT recycle_type) AS type_n,MIN(recycle_type) AS recycle_type
  FROM wangchuanliang.side_recycle_type_copy GROUP BY serial_id
), funding AS (
  SELECT DISTINCT ON(o.serial_id) o.serial_id,o.user_id,o.apply_time,o.remit_date,o.remit_time,
    o.remit_amt,o.repaid_amt,o.pre_amt,o.post_amt,o.loan_day,o.total_term,
    o.remit_succ_rnb,o.loan_type,o.due_date,o.repaid_date,o.loan_status_code
  FROM wangchuanliang.order_loan_f_v2_copy o CROSS JOIN params p
  WHERE o.is_remit=1 AND o.remit_amt>0 AND o.remit_date>=p.start_date
    AND o.remit_date<=p.as_of_date AND o.remit_time>TIMESTAMP '2000-01-01' AND o.remit_time<=p.snapshot_time
  ORDER BY o.serial_id,o.apply_time ASC NULLS LAST
), labeled AS (
  SELECT o.*,DATE_TRUNC('month',o.remit_date)::date AS month_start,
    CASE WHEN t.type_n=1 AND t.recycle_type=2 AND o.loan_type='reloan' THEN 'cycle'
         WHEN t.type_n=1 AND t.recycle_type=3 AND o.loan_type='reloan' THEN 'settled_reloan'
         WHEN o.loan_type='firstloan' AND COALESCE(t.recycle_type,0)<>2 AND COALESCE(t.type_n,0)<=1 THEN 'firstloan'
         ELSE 'unknown' END AS order_type,
    CASE WHEN o.remit_succ_rnb=1 THEN '1次' WHEN o.remit_succ_rnb=2 THEN '2次'
         WHEN o.remit_succ_rnb=3 THEN '3次' WHEN o.remit_succ_rnb=4 THEN '4次'
         WHEN o.remit_succ_rnb=5 THEN '5次' WHEN o.remit_succ_rnb>=6 THEN '6次及以上' ELSE '缺失' END AS loan_band
  FROM funding o LEFT JOIN tags t ON t.serial_id=o.serial_id
), matured AS (
  SELECT o.* FROM labeled o CROSS JOIN params p WHERE o.due_date>DATE '2000-01-01' AND o.due_date<p.as_of_date-7
), repayments AS (
  SELECT m.serial_id,
    COALESCE(SUM(r.amount),0) AS current_cash_repaid_amt,
    COALESCE(SUM(CASE WHEN r.payin_date<=m.due_date THEN r.amount ELSE 0 END),0) AS paid_by_due_amt,
    COALESCE(SUM(CASE WHEN r.payin_date<=m.due_date+7 THEN r.amount ELSE 0 END),0) AS paid_by_d7_amt,
    COUNT(r.serial_id) AS payin_rows,
    SUM(CASE WHEN r.serial_id IS NOT NULL AND r.amount IS NULL THEN 1 ELSE 0 END) AS missing_amount_rows
  FROM matured m CROSS JOIN params p LEFT JOIN wangchuanliang.repayment_record_copy r ON r.serial_id=m.serial_id
    AND r.payin_date>DATE '2000-01-01' AND r.payin_date<=p.as_of_date
  GROUP BY m.serial_id
), metrics AS (
  SELECT m.*,r.current_cash_repaid_amt,r.paid_by_due_amt,r.paid_by_d7_amt,r.payin_rows,r.missing_amount_rows,
    CASE WHEN m.loan_status_code=8 THEN 1 ELSE 0 END AS current_status8,
    CASE WHEN m.repaid_date>DATE '2000-01-01' AND m.repaid_date<=m.due_date THEN 0 ELSE 1 END AS due_overdue,
    CASE WHEN m.repaid_date>DATE '2000-01-01' AND m.repaid_date<=m.due_date+7 THEN 0 ELSE 1 END AS d7_overdue
  FROM matured m JOIN repayments r ON r.serial_id=m.serial_id
), cells AS (
  SELECT TO_CHAR(o.month_start,'YYYY-MM') AS month,o.order_type,o.loan_band,
    COUNT(*) AS funded_orders,SUM(o.remit_amt) AS funded_remit_amt,
    SUM(CASE WHEN o.pre_amt IS NOT NULL AND o.post_amt IS NOT NULL THEN o.pre_amt+o.post_amt ELSE 0 END) AS contractual_fee_amt,
    SUM(CASE WHEN o.pre_amt IS NOT NULL AND o.post_amt IS NOT NULL THEN o.remit_amt ELSE 0 END) AS fee_known_remit_amt,
    SUM(CASE WHEN o.loan_day>0 THEN o.loan_day ELSE 0 END) AS loan_day_sum,
    SUM(CASE WHEN o.loan_day>0 THEN 1 ELSE 0 END) AS loan_day_known_orders,
    COUNT(m.serial_id) AS matured_orders,SUM(m.remit_amt) AS matured_remit_amt,
    SUM(CASE WHEN m.repaid_amt IS NOT NULL THEN m.repaid_amt ELSE 0 END) AS current_book_repaid_amt,
    SUM(CASE WHEN m.serial_id IS NOT NULL AND m.repaid_amt IS NULL THEN 1 ELSE 0 END) AS missing_book_repaid_orders,
    SUM(m.current_cash_repaid_amt) AS current_cash_repaid_amt,SUM(m.paid_by_due_amt) AS paid_by_due_amt,
    SUM(m.paid_by_d7_amt) AS paid_by_d7_amt,SUM(m.current_status8) AS current_status8_orders,
    SUM(m.due_overdue) AS due_overdue_orders,SUM(m.d7_overdue) AS d7_overdue_orders,
    SUM(m.missing_amount_rows) AS missing_payin_amount_rows
  FROM labeled o LEFT JOIN metrics m ON m.serial_id=o.serial_id GROUP BY o.month_start,o.order_type,o.loan_band
), audit AS (
  SELECT p.snapshot_time,p.as_of_date,p.as_of_date-8 AS latest_mature_due_date,
    (SELECT COUNT(*) FROM funding) AS funded_orders,
    (SELECT COUNT(*) FROM matured) AS matured_orders,
    (SELECT COUNT(*) FROM metrics) AS metrics_orders,
    (SELECT COUNT(*) FROM tags WHERE type_n>1) AS type_conflicting_serials,
    (SELECT COUNT(*) FROM funding WHERE remit_date<>remit_time::date) AS remit_date_time_mismatch_orders,
    (SELECT COUNT(*) FROM matured WHERE repaid_amt IS NULL) AS missing_book_repaid_orders,
    (SELECT SUM(missing_amount_rows) FROM repayments) AS missing_payin_amount_rows,
    (SELECT COUNT(*) FROM labeled WHERE order_type='cycle' AND remit_succ_rnb<2) AS invalid_cycle_loan_sequence_orders,
    (SELECT COUNT(*) FROM (SELECT serial_id FROM funding GROUP BY serial_id HAVING COUNT(*)>1) q) AS duplicate_funding_serials,
    (SELECT COUNT(*) FROM wangchuanliang.order_loan_f_v2_copy o
       WHERE o.is_remit=1 AND o.remit_amt>0 AND o.remit_date>=p.start_date AND o.remit_date<=p.as_of_date
         AND (o.remit_time IS NULL OR o.remit_time<=TIMESTAMP '2000-01-01')) AS invalid_remit_time_in_period_orders
  FROM params p
)
SELECT 'finance_cells'::text AS result_kind,ROW_TO_JSON(x)::text AS payload FROM cells x
UNION ALL SELECT 'finance_audit',ROW_TO_JSON(x)::text FROM audit x;
-- END MODULE: finance


RESET query_dop;
