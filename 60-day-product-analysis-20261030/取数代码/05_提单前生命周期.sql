/*
60/28/21天产品提单前生命周期画像；只读SELECT，不执行建表或写入。
目标提单窗口：2026-02-01至本轮快照；60天只纳入loan_type=reloan，28天、21天保留全部提单。
历史包含这些用户全部库内期限产品，保留续贷用户此前的首贷借款和还款。
历史动作按精确时间严格早于apply_time；逾期标记还需对应到期日之后的边界已过去。
历史分期先确定自己的事件起点，再与提单锚点按时间累计，避免同单分期放大订单数。
输出为聚合单元，不输出用户订单明细。查询时间参数固定不代表源表状态被冻结。
*/
SET TIME ZONE 'America/Belize';

WITH cohort AS (
 SELECT o.user_id,o.serial_id,o.apply_time,o.apply_date,o.apply_unix,o.reg_date,
        o.loan_day,o.loan_type,o.product_no,o.apply_amt,o.remit_amt,
        CASE WHEN o.is_remit=1 AND o.remit_amt>0 THEN 1 ELSE 0 END AS funded,
        TO_CHAR(o.apply_date,'YYYY-MM') AS month
 FROM wangchuanliang.order_loan_f_v2_copy o
 WHERE o.loan_day IN (60,28,21)
   AND o.apply_date>=DATE '2026-02-01' AND o.apply_date<DATE '2026-11-01'
   AND o.apply_time<TIMESTAMP '2026-10-27 22:26:05.680353'::timestamp AND o.user_id<>5101518
   AND (o.loan_day<>60 OR o.loan_type='reloan')
), users AS (SELECT DISTINCT user_id FROM cohort), history AS (
 SELECT o.* FROM wangchuanliang.order_loan_f_v2_copy o JOIN users u ON u.user_id=o.user_id
 WHERE o.apply_time>=TIMESTAMP '2000-01-01' AND o.apply_time<TIMESTAMP '2026-10-27 22:26:05.680353'::timestamp
), funded_history AS (
 SELECT h.*,
   CASE WHEN (h.is_repaid=1 OR h.loan_status_code=7)
         AND h.repaid_time>=h.remit_time AND h.repaid_time<TIMESTAMP '2026-10-27 22:26:05.680353'::timestamp
        THEN h.repaid_time END AS valid_settle_time
 FROM history h WHERE h.is_remit=1 AND h.remit_amt>0
  AND h.remit_time>=h.apply_time AND h.remit_time<TIMESTAMP '2026-10-27 22:26:05.680353'::timestamp
), periods AS (
 SELECT p.user_id,p.serial_id,p.current_term,p.due_date_period,p.repaid_time_period,
        p.overdue_days_period,p.is_repaid_period,h.remit_time,h.valid_settle_time
 FROM wangchuanliang.repayment_plan_v2_copy p
 JOIN funded_history h ON h.user_id=p.user_id AND h.serial_id=p.serial_id
), period_order AS (
 SELECT p.user_id,p.serial_id,COUNT(*) AS plan_rows,COUNT(DISTINCT p.current_term) AS term_n,
   MIN(CASE WHEN p.overdue_days_period>0 AND p.due_date_period>=DATE '2000-01-01'
                 AND p.due_date_period::timestamp+INTERVAL '1 day'>p.remit_time
            THEN p.due_date_period::timestamp+INTERVAL '1 day' END) AS first_period_late_time,
   COUNT(CASE WHEN p.overdue_days_period>0 THEN 1 END) AS snapshot_late_period_n
 FROM periods p GROUP BY p.user_id,p.serial_id
), recycle AS (
 SELECT r.serial_id,COUNT(DISTINCT r.recycle_type) AS versions,MIN(r.recycle_type) AS candidate
 FROM wangchuanliang.side_recycle_type_copy r
 WHERE EXISTS(SELECT 1 FROM history h WHERE h.serial_id=r.serial_id)
 GROUP BY r.serial_id
),
event_long AS (
 SELECT user_id,apply_time AS t,'app'::text AS kind,0::numeric AS amount,
        0::numeric AS aux,0::integer AS days FROM history
 UNION ALL
 SELECT h.user_id,h.remit_time,'fund',h.remit_amt,
        CASE WHEN h.pre_amt IS NOT NULL AND h.post_amt IS NOT NULL THEN h.pre_amt+h.post_amt END,
        h.loan_day FROM funded_history h
 UNION ALL
 SELECT h.user_id,h.valid_settle_time,'settle',
        CASE WHEN h.repaid_date<h.due_date THEN 1 ELSE 0 END,
        EXTRACT(EPOCH FROM (h.valid_settle_time-h.remit_time))/86400.0,
        CASE WHEN h.overdue_days>0 THEN 1 ELSE 0 END
 FROM funded_history h WHERE h.valid_settle_time IS NOT NULL
 UNION ALL
 SELECT h.user_id,h.valid_settle_time,'settled_period_late',0,0,0
 FROM funded_history h JOIN period_order p ON p.user_id=h.user_id AND p.serial_id=h.serial_id
 WHERE h.valid_settle_time IS NOT NULL AND p.first_period_late_time<h.valid_settle_time
 UNION ALL
 SELECT h.user_id,h.due_date::timestamp+INTERVAL '1 day','order_due',
        CASE WHEN h.overdue_days>0 THEN 1 ELSE 0 END,0,0
 FROM funded_history h WHERE h.due_date>=DATE '2000-01-01'
  AND h.due_date::timestamp+INTERVAL '1 day'>h.remit_time
 UNION ALL
 SELECT p.user_id,p.due_date_period::timestamp+INTERVAL '1 day','period_due',
        CASE WHEN p.overdue_days_period>0 THEN 1 ELSE 0 END,0,0
 FROM periods p WHERE p.due_date_period>=DATE '2000-01-01'
  AND p.due_date_period::timestamp+INTERVAL '1 day'>p.remit_time
 UNION ALL
 SELECT p.user_id,p.first_period_late_time,'period_late_order',0,0,0
 FROM period_order p WHERE p.first_period_late_time IS NOT NULL
 UNION ALL
 SELECT p.user_id,p.repaid_time_period,'period_paid',0,0,0 FROM periods p
 WHERE p.is_repaid_period=1 AND p.repaid_time_period>=p.remit_time
  AND p.repaid_time_period<TIMESTAMP '2026-10-27 22:26:05.680353'::timestamp
 UNION ALL
 SELECT p.user_id,p.due_date_period::timestamp+INTERVAL '1 day','open_late',1,0,0
 FROM periods p WHERE p.due_date_period>=DATE '2000-01-01'
  AND p.due_date_period::timestamp+INTERVAL '1 day'>p.remit_time
  AND (p.repaid_time_period IS NULL OR p.repaid_time_period<p.remit_time
       OR p.repaid_time_period>p.due_date_period::timestamp+INTERVAL '1 day')
 UNION ALL
 SELECT p.user_id,p.repaid_time_period,'open_late',-1,0,0
 FROM periods p WHERE p.due_date_period>=DATE '2000-01-01'
  AND p.due_date_period::timestamp+INTERVAL '1 day'>p.remit_time
  AND p.repaid_time_period>p.due_date_period::timestamp+INTERVAL '1 day'
  AND p.repaid_time_period<TIMESTAMP '2026-10-27 22:26:05.680353'::timestamp
 UNION ALL
 SELECT h.user_id,h.remit_time,'cycle_fund',0,0,0 FROM funded_history h
 JOIN recycle r ON r.serial_id=h.serial_id WHERE r.versions=1 AND r.candidate=2
), event_pivot AS (
 SELECT user_id,t,
 SUM(CASE WHEN kind='app' THEN 1 ELSE 0 END) AS d_app_n,
 SUM(CASE WHEN kind='fund' THEN 1 ELSE 0 END) AS d_fund_n,
 SUM(CASE WHEN kind='fund' THEN amount ELSE 0 END) AS d_fund_amt,
 SUM(CASE WHEN kind='fund' AND aux IS NOT NULL THEN aux ELSE 0 END) AS d_fee_amt,
 SUM(CASE WHEN kind='fund' AND aux IS NOT NULL THEN amount ELSE 0 END) AS d_fee_known_amt,
 SUM(CASE WHEN kind='settle' THEN 1 ELSE 0 END) AS d_settled_n,
 SUM(CASE WHEN kind='settle' THEN amount ELSE 0 END) AS d_early_n,
 SUM(CASE WHEN kind='settle' THEN aux ELSE 0 END) AS d_hold_days,
 SUM(CASE WHEN kind='settle' THEN days ELSE 0 END) AS d_settled_order_late_n,
 SUM(CASE WHEN kind='settled_period_late' THEN 1 ELSE 0 END) AS d_settled_period_late_order_n,
 SUM(CASE WHEN kind='order_due' THEN 1 ELSE 0 END) AS d_order_due_n,
 SUM(CASE WHEN kind='order_due' THEN amount ELSE 0 END) AS d_order_late_n,
 SUM(CASE WHEN kind='period_due' THEN 1 ELSE 0 END) AS d_period_due_n,
 SUM(CASE WHEN kind='period_due' THEN amount ELSE 0 END) AS d_period_late_n,
 SUM(CASE WHEN kind='period_late_order' THEN 1 ELSE 0 END) AS d_period_late_order_n,
 SUM(CASE WHEN kind='period_paid' THEN 1 ELSE 0 END) AS d_period_paid_n,
 SUM(CASE WHEN kind='open_late' THEN amount ELSE 0 END) AS d_open_late_periods,
 SUM(CASE WHEN kind='fund' AND days=21 THEN 1 ELSE 0 END) AS d_loan21_n,
 SUM(CASE WHEN kind='fund' AND days=28 THEN 1 ELSE 0 END) AS d_loan28_n,
 SUM(CASE WHEN kind='fund' AND days=60 THEN 1 ELSE 0 END) AS d_loan60_n,
 SUM(CASE WHEN kind='cycle_fund' THEN 1 ELSE 0 END) AS d_cycle_n
 FROM event_long WHERE t<TIMESTAMP '2026-10-27 22:26:05.680353'::timestamp GROUP BY user_id,t
), times AS (
 SELECT user_id,t FROM event_pivot
 UNION SELECT user_id,apply_time FROM cohort
 UNION SELECT user_id,apply_time-INTERVAL '30 days' FROM cohort
), timeline AS (
 SELECT a.user_id,a.t,COALESCE(e.d_app_n,0) AS d_app_n,COALESCE(e.d_fund_n,0) AS d_fund_n,COALESCE(e.d_fund_amt,0) AS d_fund_amt,COALESCE(e.d_fee_amt,0) AS d_fee_amt,COALESCE(e.d_fee_known_amt,0) AS d_fee_known_amt,COALESCE(e.d_settled_n,0) AS d_settled_n,COALESCE(e.d_early_n,0) AS d_early_n,COALESCE(e.d_hold_days,0) AS d_hold_days,COALESCE(e.d_settled_order_late_n,0) AS d_settled_order_late_n,COALESCE(e.d_settled_period_late_order_n,0) AS d_settled_period_late_order_n,COALESCE(e.d_order_due_n,0) AS d_order_due_n,COALESCE(e.d_order_late_n,0) AS d_order_late_n,COALESCE(e.d_period_due_n,0) AS d_period_due_n,COALESCE(e.d_period_late_n,0) AS d_period_late_n,COALESCE(e.d_period_late_order_n,0) AS d_period_late_order_n,COALESCE(e.d_period_paid_n,0) AS d_period_paid_n,COALESCE(e.d_open_late_periods,0) AS d_open_late_periods,COALESCE(e.d_loan21_n,0) AS d_loan21_n,COALESCE(e.d_loan28_n,0) AS d_loan28_n,COALESCE(e.d_loan60_n,0) AS d_loan60_n,COALESCE(e.d_cycle_n,0) AS d_cycle_n
 FROM times a LEFT JOIN event_pivot e ON e.user_id=a.user_id AND e.t=a.t
), prefix AS (
 SELECT a.*,COALESCE(SUM(d_app_n) OVER w,0) AS p_app_n,
 COALESCE(SUM(d_fund_n) OVER w,0) AS p_fund_n,
 COALESCE(SUM(d_fund_amt) OVER w,0) AS p_fund_amt,
 COALESCE(SUM(d_fee_amt) OVER w,0) AS p_fee_amt,
 COALESCE(SUM(d_fee_known_amt) OVER w,0) AS p_fee_known_amt,
 COALESCE(SUM(d_settled_n) OVER w,0) AS p_settled_n,
 COALESCE(SUM(d_early_n) OVER w,0) AS p_early_n,
 COALESCE(SUM(d_hold_days) OVER w,0) AS p_hold_days,
 COALESCE(SUM(d_settled_order_late_n) OVER w,0) AS p_settled_order_late_n,
 COALESCE(SUM(d_settled_period_late_order_n) OVER w,0) AS p_settled_period_late_order_n,
 COALESCE(SUM(d_order_due_n) OVER w,0) AS p_order_due_n,
 COALESCE(SUM(d_order_late_n) OVER w,0) AS p_order_late_n,
 COALESCE(SUM(d_period_due_n) OVER w,0) AS p_period_due_n,
 COALESCE(SUM(d_period_late_n) OVER w,0) AS p_period_late_n,
 COALESCE(SUM(d_period_late_order_n) OVER w,0) AS p_period_late_order_n,
 COALESCE(SUM(d_period_paid_n) OVER w,0) AS p_period_paid_n,
 COALESCE(SUM(d_open_late_periods) OVER w,0) AS p_open_late_periods,
 COALESCE(SUM(d_loan21_n) OVER w,0) AS p_loan21_n,
 COALESCE(SUM(d_loan28_n) OVER w,0) AS p_loan28_n,
 COALESCE(SUM(d_loan60_n) OVER w,0) AS p_loan60_n,
 COALESCE(SUM(d_cycle_n) OVER w,0) AS p_cycle_n,
   SUM(d_fund_n-d_settled_n) OVER(PARTITION BY user_id ORDER BY t ROWS UNBOUNDED PRECEDING) AS open_after,
   MIN(CASE WHEN d_app_n>0 THEN t END) OVER w AS first_app_time,
   MAX(CASE WHEN d_app_n>0 THEN t END) OVER w AS last_app_time,
   MIN(CASE WHEN d_fund_n>0 THEN t END) OVER w AS first_fund_time,
   MAX(CASE WHEN d_fund_n>0 THEN t END) OVER w AS last_fund_time,
   MAX(CASE WHEN d_settled_n>0 THEN t END) OVER w AS last_settle_time
 FROM timeline a
 WINDOW w AS (PARTITION BY user_id ORDER BY t ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)
), temporal AS (
 SELECT a.*,
   MAX(CASE WHEN d_settled_n>0 AND open_after=0 THEN t END) OVER(
      PARTITION BY user_id ORDER BY t ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS last_clean_time
 FROM prefix a
),
model AS (
 SELECT m.serial_id,COUNT(DISTINCT m.user_id) AS user_versions,MIN(m.user_id) AS user_candidate,
 COUNT(DISTINCT CASE WHEN m.kabybxgboost363dpd7cre IS NOT NULL AND m.kabybxgboost363dpd7cre<>-9999999 THEN m.kabybxgboost363dpd7cre END) AS versions_363,
 MIN(CASE WHEN m.kabybxgboost363dpd7cre IS NOT NULL AND m.kabybxgboost363dpd7cre<>-9999999 THEN m.kabybxgboost363dpd7cre END) AS candidate_363,
 COUNT(DISTINCT CASE WHEN m.kabybxgboost404fpd7crecyc IS NOT NULL AND m.kabybxgboost404fpd7crecyc<>-9999999 THEN m.kabybxgboost404fpd7crecyc END) AS versions_404,
 MIN(CASE WHEN m.kabybxgboost404fpd7crecyc IS NOT NULL AND m.kabybxgboost404fpd7crecyc<>-9999999 THEN m.kabybxgboost404fpd7crecyc END) AS candidate_404,
 COUNT(DISTINCT CASE WHEN m.kabybmerge410fpd7cre IS NOT NULL AND m.kabybmerge410fpd7cre<>-9999999 THEN m.kabybmerge410fpd7cre END) AS versions_410,
 MIN(CASE WHEN m.kabybmerge410fpd7cre IS NOT NULL AND m.kabybmerge410fpd7cre<>-9999999 THEN m.kabybmerge410fpd7cre END) AS candidate_410
 FROM wangchuanliang.model_result_copy m
 WHERE EXISTS(SELECT 1 FROM cohort c WHERE c.serial_id=m.serial_id) GROUP BY m.serial_id
), latest_credit_clock AS (
 SELECT c.user_id,c.serial_id,MAX(v.vir_unix) AS latest_unix
 FROM cohort c JOIN wangchuanliang.order_vir_f_copy v
  ON v.user_id=c.user_id AND v.serial_id=c.serial_id AND v.vir_unix<=c.apply_unix AND v.vir_unix>0
 GROUP BY c.user_id,c.serial_id
), credit AS (
 SELECT x.user_id,x.serial_id,
 CASE WHEN COUNT(DISTINCT v.is_pass1)=1 AND MIN(v.is_pass1)=1
       AND COUNT(DISTINCT v.max_credit_apply_amt)=1 AND MIN(v.max_credit_apply_amt)>0
      THEN MIN(v.max_credit_apply_amt) END AS credit_amt
 FROM latest_credit_clock x JOIN wangchuanliang.order_vir_f_copy v
  ON v.user_id=x.user_id AND v.serial_id=x.serial_id AND v.vir_unix=x.latest_unix
 GROUP BY x.user_id,x.serial_id
), features AS (
 SELECT c.*,CASE WHEN m.user_versions=1 AND m.user_candidate=c.user_id AND m.versions_363=1 THEN m.candidate_363 END AS score_363,
 CASE WHEN m.user_versions=1 AND m.user_candidate=c.user_id AND m.versions_404=1 THEN m.candidate_404 END AS score_404,
 CASE WHEN m.user_versions=1 AND m.user_candidate=c.user_id AND m.versions_410=1 THEN m.candidate_410 END AS score_410,
 p.p_app_n AS prior_app_n,p.p_fund_n AS prior_fund_n,p.p_fund_amt AS prior_fund_amt,p.p_fee_amt AS prior_fee_amt,p.p_fee_known_amt AS prior_fee_known_amt,p.p_settled_n AS prior_settled_n,p.p_early_n AS prior_early_n,p.p_hold_days AS prior_hold_days,p.p_settled_order_late_n AS prior_settled_order_late_n,p.p_settled_period_late_order_n AS prior_settled_period_late_order_n,p.p_order_due_n AS prior_order_due_n,p.p_order_late_n AS prior_order_late_n,p.p_period_due_n AS prior_period_due_n,p.p_period_late_n AS prior_period_late_n,p.p_period_late_order_n AS prior_period_late_order_n,p.p_period_paid_n AS prior_period_paid_n,p.p_open_late_periods AS prior_open_late_periods,p.p_loan21_n AS prior_loan21_n,p.p_loan28_n AS prior_loan28_n,p.p_loan60_n AS prior_loan60_n,p.p_cycle_n AS prior_cycle_n,
 p.p_fund_n-p.p_settled_n AS prior_open_order_n,
 p.p_app_n-b.p_app_n AS applications30,
 p.p_fund_n-b.p_fund_n AS funded30,
 p.p_settled_n-b.p_settled_n AS settled30,
 p.p_period_late_n-b.p_period_late_n AS new_late_periods30,
 EXTRACT(EPOCH FROM(c.apply_time-p.first_app_time))/86400.0 AS history_age_days,
 CASE WHEN c.reg_date>=DATE '2000-01-01' AND c.reg_date<=c.apply_date THEN c.apply_date-c.reg_date END AS account_age_days,
 EXTRACT(EPOCH FROM(c.apply_time-p.last_app_time))/86400.0 AS days_since_last_application,
 EXTRACT(EPOCH FROM(c.apply_time-p.last_fund_time))/86400.0 AS days_since_last_borrow,
 EXTRACT(EPOCH FROM(c.apply_time-p.last_settle_time))/86400.0 AS days_since_last_settlement,
 CASE WHEN p.p_fund_n-p.p_settled_n=0 AND p.p_fund_n>0
      THEN EXTRACT(EPOCH FROM(c.apply_time-p.last_clean_time))/86400.0 END AS clean_wait_days,
 CASE WHEN p.p_fund_n>=2 THEN EXTRACT(EPOCH FROM(p.last_fund_time-p.first_fund_time))/86400.0/(p.p_fund_n-1) END AS mean_borrow_gap_days,
 p.p_fund_amt/NULLIF(p.p_fund_n,0) AS mean_past_borrow_amt,
 p.p_early_n/NULLIF(p.p_settled_n,0) AS early_settle_rate,
 p.p_hold_days/NULLIF(p.p_settled_n,0) AS mean_holding_days,
 p.p_fee_amt/NULLIF(p.p_fee_known_amt,0) AS past_fee_rate,
 p.p_order_late_n/NULLIF(p.p_order_due_n,0) AS past_order_overdue_rate,
 p.p_period_late_n/NULLIF(p.p_period_due_n,0) AS past_period_overdue_rate,
 p.p_cycle_n/NULLIF(p.p_fund_n,0) AS past_cycle_borrow_share,
 c.apply_amt::numeric/NULLIF(cr.credit_amt,0) AS credit_utilization,
 CASE WHEN p.p_fund_n=0 THEN '0' WHEN p.p_fund_n=1 THEN '1'
      WHEN p.p_fund_n BETWEEN 2 AND 3 THEN '2-3' WHEN p.p_fund_n BETWEEN 4 AND 5 THEN '4-5'
      WHEN p.p_fund_n BETWEEN 6 AND 10 THEN '6-10' ELSE '11+' END AS prior_borrow_band
 FROM cohort c JOIN temporal p ON p.user_id=c.user_id AND p.t=c.apply_time
 JOIN temporal b ON b.user_id=c.user_id AND b.t=c.apply_time-INTERVAL '30 days'
 LEFT JOIN model m ON m.serial_id=c.serial_id
 LEFT JOIN credit cr ON cr.user_id=c.user_id AND cr.serial_id=c.serial_id
), quality AS (
 SELECT (SELECT COUNT(*)-COUNT(DISTINCT serial_id) FROM cohort) AS target_duplicate_orders,
  (SELECT COUNT(*)-COUNT(DISTINCT serial_id) FROM history) AS history_duplicate_orders,
  (SELECT COUNT(*) FROM period_order WHERE plan_rows<>term_n) AS history_duplicate_period_orders,
  (SELECT COUNT(*) FROM funded_history WHERE overdue_days>0 AND due_date<DATE '2000-01-01') AS overdue_orders_missing_due_date,
  (SELECT COUNT(*) FROM periods WHERE overdue_days_period>0 AND due_date_period<DATE '2000-01-01') AS overdue_periods_missing_due_date,
  (SELECT MIN(apply_date) FROM history) AS earliest_history_date,
  (SELECT COUNT(*) FROM history) AS history_order_rows,
  (SELECT COUNT(*) FROM periods) AS history_period_rows
), cells AS (
 SELECT loan_day,
  CASE WHEN GROUPING(month)=1 THEN 'ALL' ELSE month END AS month,
  CASE WHEN GROUPING(loan_type)=1 THEN 'ALL' ELSE loan_type END AS loan_type,
  CASE WHEN GROUPING(funded)=1 THEN -1 ELSE funded END AS funded,
  CASE WHEN GROUPING(prior_borrow_band)=1 THEN 'ALL' ELSE prior_borrow_band END AS prior_borrow_band,
  COUNT(*)::bigint AS n,
  COUNT(DISTINCT user_id)::bigint AS users,
  SUM(funded)::bigint AS funded_n,
  COUNT(prior_app_n)::bigint AS prior_app_n_known,
  SUM(prior_app_n)::float8 AS prior_app_n_sum,
  COUNT(prior_fund_n)::bigint AS prior_fund_n_known,
  SUM(prior_fund_n)::float8 AS prior_fund_n_sum,
  COUNT(prior_fund_amt)::bigint AS prior_fund_amt_known,
  SUM(prior_fund_amt)::float8 AS prior_fund_amt_sum,
  COUNT(prior_settled_n)::bigint AS prior_settled_n_known,
  SUM(prior_settled_n)::float8 AS prior_settled_n_sum,
  COUNT(prior_early_n)::bigint AS prior_early_n_known,
  SUM(prior_early_n)::float8 AS prior_early_n_sum,
  COUNT(prior_settled_order_late_n)::bigint AS prior_settled_order_late_n_known,
  SUM(prior_settled_order_late_n)::float8 AS prior_settled_order_late_n_sum,
  COUNT(prior_settled_period_late_order_n)::bigint AS prior_settled_period_late_order_n_known,
  SUM(prior_settled_period_late_order_n)::float8 AS prior_settled_period_late_order_n_sum,
  COUNT(prior_order_due_n)::bigint AS prior_order_due_n_known,
  SUM(prior_order_due_n)::float8 AS prior_order_due_n_sum,
  COUNT(prior_order_late_n)::bigint AS prior_order_late_n_known,
  SUM(prior_order_late_n)::float8 AS prior_order_late_n_sum,
  COUNT(prior_period_due_n)::bigint AS prior_period_due_n_known,
  SUM(prior_period_due_n)::float8 AS prior_period_due_n_sum,
  COUNT(prior_period_late_n)::bigint AS prior_period_late_n_known,
  SUM(prior_period_late_n)::float8 AS prior_period_late_n_sum,
  COUNT(prior_period_late_order_n)::bigint AS prior_period_late_order_n_known,
  SUM(prior_period_late_order_n)::float8 AS prior_period_late_order_n_sum,
  COUNT(prior_period_paid_n)::bigint AS prior_period_paid_n_known,
  SUM(prior_period_paid_n)::float8 AS prior_period_paid_n_sum,
  COUNT(prior_open_late_periods)::bigint AS prior_open_late_periods_known,
  SUM(prior_open_late_periods)::float8 AS prior_open_late_periods_sum,
  COUNT(prior_loan21_n)::bigint AS prior_loan21_n_known,
  SUM(prior_loan21_n)::float8 AS prior_loan21_n_sum,
  COUNT(prior_loan28_n)::bigint AS prior_loan28_n_known,
  SUM(prior_loan28_n)::float8 AS prior_loan28_n_sum,
  COUNT(prior_loan60_n)::bigint AS prior_loan60_n_known,
  SUM(prior_loan60_n)::float8 AS prior_loan60_n_sum,
  COUNT(prior_cycle_n)::bigint AS prior_cycle_n_known,
  SUM(prior_cycle_n)::float8 AS prior_cycle_n_sum,
  COUNT(prior_open_order_n)::bigint AS prior_open_order_n_known,
  SUM(prior_open_order_n)::float8 AS prior_open_order_n_sum,
  COUNT(applications30)::bigint AS applications30_known,
  SUM(applications30)::float8 AS applications30_sum,
  COUNT(funded30)::bigint AS funded30_known,
  SUM(funded30)::float8 AS funded30_sum,
  COUNT(settled30)::bigint AS settled30_known,
  SUM(settled30)::float8 AS settled30_sum,
  COUNT(new_late_periods30)::bigint AS new_late_periods30_known,
  SUM(new_late_periods30)::float8 AS new_late_periods30_sum,
  COUNT(history_age_days)::bigint AS history_age_days_known,
  SUM(history_age_days)::float8 AS history_age_days_sum,
  COUNT(account_age_days)::bigint AS account_age_days_known,
  SUM(account_age_days)::float8 AS account_age_days_sum,
  COUNT(days_since_last_application)::bigint AS days_since_last_application_known,
  SUM(days_since_last_application)::float8 AS days_since_last_application_sum,
  COUNT(days_since_last_borrow)::bigint AS days_since_last_borrow_known,
  SUM(days_since_last_borrow)::float8 AS days_since_last_borrow_sum,
  COUNT(days_since_last_settlement)::bigint AS days_since_last_settlement_known,
  SUM(days_since_last_settlement)::float8 AS days_since_last_settlement_sum,
  COUNT(clean_wait_days)::bigint AS clean_wait_days_known,
  SUM(clean_wait_days)::float8 AS clean_wait_days_sum,
  COUNT(mean_borrow_gap_days)::bigint AS mean_borrow_gap_days_known,
  SUM(mean_borrow_gap_days)::float8 AS mean_borrow_gap_days_sum,
  COUNT(mean_past_borrow_amt)::bigint AS mean_past_borrow_amt_known,
  SUM(mean_past_borrow_amt)::float8 AS mean_past_borrow_amt_sum,
  COUNT(early_settle_rate)::bigint AS early_settle_rate_known,
  SUM(early_settle_rate)::float8 AS early_settle_rate_sum,
  COUNT(mean_holding_days)::bigint AS mean_holding_days_known,
  SUM(mean_holding_days)::float8 AS mean_holding_days_sum,
  COUNT(past_fee_rate)::bigint AS past_fee_rate_known,
  SUM(past_fee_rate)::float8 AS past_fee_rate_sum,
  COUNT(past_order_overdue_rate)::bigint AS past_order_overdue_rate_known,
  SUM(past_order_overdue_rate)::float8 AS past_order_overdue_rate_sum,
  COUNT(past_period_overdue_rate)::bigint AS past_period_overdue_rate_known,
  SUM(past_period_overdue_rate)::float8 AS past_period_overdue_rate_sum,
  COUNT(past_cycle_borrow_share)::bigint AS past_cycle_borrow_share_known,
  SUM(past_cycle_borrow_share)::float8 AS past_cycle_borrow_share_sum,
  COUNT(credit_utilization)::bigint AS credit_utilization_known,
  SUM(credit_utilization)::float8 AS credit_utilization_sum,
  COUNT(score_363)::bigint AS score_363_known,
  SUM(score_363)::float8 AS score_363_sum,
  COUNT(score_404)::bigint AS score_404_known,
  SUM(score_404)::float8 AS score_404_sum,
  COUNT(score_410)::bigint AS score_410_known,
  SUM(score_410)::float8 AS score_410_sum,
  COUNT(apply_amt)::bigint AS apply_amt_known,
  SUM(apply_amt)::float8 AS apply_amt_sum,
  PERCENTILE_CONT(0.5) WITHIN GROUP(ORDER BY prior_app_n)::float8 AS prior_app_n_median,
  PERCENTILE_CONT(0.5) WITHIN GROUP(ORDER BY prior_fund_n)::float8 AS prior_fund_n_median,
  PERCENTILE_CONT(0.5) WITHIN GROUP(ORDER BY prior_order_late_n)::float8 AS prior_order_late_n_median,
  PERCENTILE_CONT(0.5) WITHIN GROUP(ORDER BY prior_period_late_n)::float8 AS prior_period_late_n_median,
  PERCENTILE_CONT(0.5) WITHIN GROUP(ORDER BY mean_past_borrow_amt)::float8 AS mean_past_borrow_amt_median,
  PERCENTILE_CONT(0.5) WITHIN GROUP(ORDER BY credit_utilization)::float8 AS credit_utilization_median,
  PERCENTILE_CONT(0.5) WITHIN GROUP(ORDER BY days_since_last_borrow)::float8 AS days_since_last_borrow_median,
  PERCENTILE_CONT(0.5) WITHIN GROUP(ORDER BY mean_borrow_gap_days)::float8 AS mean_borrow_gap_days_median,
  PERCENTILE_CONT(0.5) WITHIN GROUP(ORDER BY clean_wait_days)::float8 AS clean_wait_days_median,
  SUM(CASE WHEN prior_fund_n>0 THEN 1 ELSE 0 END)::bigint AS has_history_n,
  SUM(CASE WHEN prior_order_due_n>0 THEN 1 ELSE 0 END)::bigint AS has_order_due_n,
  SUM(CASE WHEN prior_period_due_n>0 THEN 1 ELSE 0 END)::bigint AS has_period_due_n,
  SUM(CASE WHEN prior_order_late_n>0 THEN 1 ELSE 0 END)::bigint AS ever_order_late_n,
  SUM(CASE WHEN prior_period_late_n>0 THEN 1 ELSE 0 END)::bigint AS ever_period_late_n,
  SUM(CASE WHEN prior_settled_order_late_n>0 THEN 1 ELSE 0 END)::bigint AS ever_settled_order_late_n,
  SUM(CASE WHEN prior_settled_period_late_order_n>0 THEN 1 ELSE 0 END)::bigint AS ever_settled_period_late_n,
  SUM(CASE WHEN prior_open_order_n>0 THEN 1 ELSE 0 END)::bigint AS has_open_order_n,
  SUM(CASE WHEN prior_open_late_periods>0 THEN 1 ELSE 0 END)::bigint AS has_open_late_period_n,
  SUM(CASE WHEN prior_early_n>0 THEN 1 ELSE 0 END)::bigint AS ever_early_settle_n,
  SUM(CASE WHEN prior_settled_n>0 THEN 1 ELSE 0 END)::bigint AS has_settlement_n,
  SUM(CASE WHEN prior_cycle_n>0 THEN 1 ELSE 0 END)::bigint AS prior_cycle_borrow_n,
  SUM(CASE WHEN (loan_day=60 AND prior_loan60_n>0) OR (loan_day=28 AND prior_loan28_n>0) OR (loan_day=21 AND prior_loan21_n>0) THEN 1 ELSE 0 END)::bigint AS prior_same_product_n,
  SUM(CASE WHEN prior_loan21_n>0 THEN 1 ELSE 0 END)::bigint AS prior_21day_borrow_n,
  SUM(CASE WHEN prior_loan28_n>0 THEN 1 ELSE 0 END)::bigint AS prior_28day_borrow_n,
  SUM(CASE WHEN prior_loan60_n>0 THEN 1 ELSE 0 END)::bigint AS prior_60day_borrow_n,
  SUM(CASE WHEN credit_utilization>=0.9 THEN 1 ELSE 0 END)::bigint AS util_ge90_n,
  SUM(CASE WHEN credit_utilization>1 THEN 1 ELSE 0 END)::bigint AS util_gt100_n,
  SUM(CASE WHEN prior_open_order_n<0 OR prior_open_late_periods<0 OR applications30<0 OR funded30<0 THEN 1 ELSE 0 END)::bigint AS negative_history_counts_n,
  SUM(CASE WHEN prior_fund_n>0 AND days_since_last_borrow IS NULL THEN 1 ELSE 0 END)::bigint AS history_missing_dates_n
 FROM features GROUP BY GROUPING SETS ((loan_day),(loan_day,loan_type),(loan_day,loan_type,funded),
 (loan_day,month),(loan_day,month,loan_type),(loan_day,prior_borrow_band),
 (loan_day,month,loan_type,prior_borrow_band))
)
SELECT c.*,q.* FROM cells c CROSS JOIN quality q
ORDER BY loan_day,month,loan_type,funded,prior_borrow_band;


-- 各产品的产品码与放款构成
SELECT o.loan_day,CASE WHEN o.is_remit=1 AND o.remit_amt>0 THEN 1 ELSE 0 END AS funded,
 COALESCE(NULLIF(TRIM(o.product_no),''),'MISSING') AS product_no,COUNT(*) AS n,
 SUM(CASE WHEN o.apply_amt IS NULL OR o.apply_amt<=0 THEN 1 ELSE 0 END) AS amount_unknown_or_zero,
 SUM(CASE WHEN o.loan_type='firstloan' THEN 1 ELSE 0 END) AS firstloan_n FROM wangchuanliang.order_loan_f_v2_copy o
 WHERE o.loan_day IN (60,28,21) AND o.apply_date>=DATE '2026-02-01' AND o.apply_date<DATE '2026-11-01'
 AND o.apply_time<TIMESTAMP '2026-10-27 22:26:05.680353'::timestamp AND o.user_id<>5101518
 AND (o.loan_day<>60 OR o.loan_type='reloan') GROUP BY o.loan_day,CASE WHEN o.is_remit=1 AND o.remit_amt>0 THEN 1 ELSE 0 END,COALESCE(NULLIF(TRIM(o.product_no),''),'MISSING') ORDER BY o.loan_day,funded,product_no;


-- 按本报告样本统计跨产品用户交叉
WITH u AS (SELECT o.user_id,MAX(CASE WHEN loan_day=60 THEN 1 ELSE 0 END) AS has60,
 MAX(CASE WHEN loan_day=28 THEN 1 ELSE 0 END) AS has28,MAX(CASE WHEN loan_day=21 THEN 1 ELSE 0 END) AS has21 FROM wangchuanliang.order_loan_f_v2_copy o
 WHERE o.loan_day IN (60,28,21) AND o.apply_date>=DATE '2026-02-01' AND o.apply_date<DATE '2026-11-01'
 AND o.apply_time<TIMESTAMP '2026-10-27 22:26:05.680353'::timestamp AND o.user_id<>5101518
 AND (o.loan_day<>60 OR o.loan_type='reloan') GROUP BY o.user_id) SELECT has60,has28,has21,COUNT(*) AS users FROM u GROUP BY has60,has28,has21 ORDER BY has60 DESC,has28 DESC,has21 DESC;
