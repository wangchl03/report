-- Read only. Same-order model scores; no latest-user-score substitution.
WITH cohort AS (
 SELECT o.* FROM wangchuanliang.order_loan_f_v2_copy o
 WHERE o.loan_day=60 AND o.apply_date>=DATE '2026-02-01' AND o.apply_date<DATE '2026-11-01'
   AND o.apply_time<TIMESTAMP '2026-10-27 22:03:36.845563'::timestamp AND o.user_id<>5101518
), model_per_order AS (
 SELECT m.serial_id,COUNT(*)::bigint AS model_rows,
 COUNT(DISTINCT m.user_id) AS model_user_versions,MIN(m.user_id) AS model_user_candidate,
 COUNT(DISTINCT CASE WHEN m.kabybxgboost363dpd7cre IS NOT NULL AND m.kabybxgboost363dpd7cre<>-9999999 THEN m.kabybxgboost363dpd7cre END) AS nd_363,
 MIN(CASE WHEN m.kabybxgboost363dpd7cre IS NOT NULL AND m.kabybxgboost363dpd7cre<>-9999999 THEN m.kabybxgboost363dpd7cre END) AS candidate_363,
 MIN(m.kabybxgboost363dpd7cre) AS raw_min_363,
 MAX(m.kabybxgboost363dpd7cre) AS raw_max_363,
 COUNT(DISTINCT CASE WHEN m.kabybxgboost404fpd7crecyc IS NOT NULL AND m.kabybxgboost404fpd7crecyc<>-9999999 THEN m.kabybxgboost404fpd7crecyc END) AS nd_404,
 MIN(CASE WHEN m.kabybxgboost404fpd7crecyc IS NOT NULL AND m.kabybxgboost404fpd7crecyc<>-9999999 THEN m.kabybxgboost404fpd7crecyc END) AS candidate_404,
 MIN(m.kabybxgboost404fpd7crecyc) AS raw_min_404,
 MAX(m.kabybxgboost404fpd7crecyc) AS raw_max_404,
 COUNT(DISTINCT CASE WHEN m.kabybmerge410fpd7cre IS NOT NULL AND m.kabybmerge410fpd7cre<>-9999999 THEN m.kabybmerge410fpd7cre END) AS nd_410,
 MIN(CASE WHEN m.kabybmerge410fpd7cre IS NOT NULL AND m.kabybmerge410fpd7cre<>-9999999 THEN m.kabybmerge410fpd7cre END) AS candidate_410,
 MIN(m.kabybmerge410fpd7cre) AS raw_min_410,
 MAX(m.kabybmerge410fpd7cre) AS raw_max_410
 FROM wangchuanliang.model_result_copy m
 WHERE EXISTS(SELECT 1 FROM cohort o WHERE o.serial_id=m.serial_id)
 GROUP BY m.serial_id
), plan AS (
 SELECT p.user_id,p.serial_id,COUNT(*) AS plan_rows,COUNT(DISTINCT p.current_term) AS plan_terms,
 MIN(p.current_term) AS min_term,MAX(p.current_term) AS max_term,
 SUM(p.apply_amt_period)::float8 AS plan_contract_amt,
 SUM(p.remit_amt_period)::float8 AS plan_principal_amt,
 SUM(CASE WHEN p.loan_status_code_period=8 THEN p.apply_amt_period ELSE 0 END)::float8 AS overdue_contract_amt,
 SUM(CASE WHEN p.loan_status_code_period=8 THEN p.remit_amt_period ELSE 0 END)::float8 AS overdue_principal_amt,
 MAX(CASE WHEN p.loan_status_code_period=8 THEN 1 ELSE 0 END) AS any_current_period_overdue,
 MAX(CASE WHEN p.overdue_days_period>0 THEN 1 ELSE 0 END) AS any_historical_period_overdue,
 MIN(p.due_date_period) AS first_due_date,MAX(p.due_date_period) AS last_due_date,
 MAX(CASE WHEN p.current_term=1 THEN p.due_date_period END) AS first_term_due_date,
 MAX(CASE WHEN p.current_term=1 THEN p.overdue_days_period END) AS first_term_overdue_days,
 SUM(CASE WHEN p.current_term=1 THEN p.apply_amt_period ELSE 0 END)::float8 AS first_contract_amt,
 SUM(CASE WHEN p.current_term=1 AND p.overdue_days_period>7 THEN p.apply_amt_period ELSE 0 END)::float8 AS first_overdue7_amt,
 SUM(CASE WHEN p.apply_amt_period IS NULL OR p.remit_amt_period IS NULL THEN 1 ELSE 0 END) AS plan_amount_missing_rows,
 MAX(p.overdue_days_period) AS max_historical_period_overdue_days
 FROM wangchuanliang.repayment_plan_v2_copy p
 WHERE EXISTS(SELECT 1 FROM cohort o WHERE o.user_id=p.user_id AND o.serial_id=p.serial_id)
 GROUP BY p.user_id,p.serial_id
), recycle AS (
 SELECT r.serial_id,COUNT(DISTINCT r.recycle_type) AS recycle_versions,MIN(r.recycle_type) AS recycle_value
 FROM wangchuanliang.side_recycle_type_copy r
 WHERE EXISTS(SELECT 1 FROM cohort o WHERE o.serial_id=r.serial_id)
 GROUP BY r.serial_id
)
SELECT o.user_id,o.serial_id,o.apply_time,o.apply_date,o.remit_time,o.remit_date,
 o.loan_day,o.product_no,o.loan_type,o.remit_succ_rnb,o.apply_rnb,
 o.apply_amt::float8 AS apply_amt,o.remit_amt::float8 AS remit_amt,
 o.pre_amt::float8 AS pre_amt,o.post_amt::float8 AS post_amt,
 o.repaid_amt::float8 AS repaid_amt,o.due_date,o.due_time,o.is_due,
 o.repaid_time,o.repaid_date,o.is_repaid,o.is_remit,o.loan_status_code,o.overdue_days,o.total_term,
 m.model_rows,m.model_user_versions,m.model_user_candidate,
 m.nd_363,
 m.raw_min_363,
 m.raw_max_363,
 CASE WHEN m.model_user_versions=1 AND m.model_user_candidate=o.user_id AND m.nd_363=1 THEN m.candidate_363 END AS score_363,
 m.nd_404,
 m.raw_min_404,
 m.raw_max_404,
 CASE WHEN m.model_user_versions=1 AND m.model_user_candidate=o.user_id AND m.nd_404=1 THEN m.candidate_404 END AS score_404,
 m.nd_410,
 m.raw_min_410,
 m.raw_max_410,
 CASE WHEN m.model_user_versions=1 AND m.model_user_candidate=o.user_id AND m.nd_410=1 THEN m.candidate_410 END AS score_410,
 p.plan_rows,p.plan_terms,p.min_term,p.max_term,p.plan_contract_amt,p.plan_principal_amt,
 p.overdue_contract_amt,p.overdue_principal_amt,p.any_current_period_overdue,p.any_historical_period_overdue,
 p.first_due_date,p.last_due_date,p.first_term_due_date,p.first_term_overdue_days,
 p.first_contract_amt,p.first_overdue7_amt,p.plan_amount_missing_rows,p.max_historical_period_overdue_days,
 r.recycle_versions,CASE WHEN r.recycle_versions=1 THEN r.recycle_value END AS recycle_type
FROM cohort o LEFT JOIN model_per_order m ON m.serial_id=o.serial_id
 LEFT JOIN plan p ON p.user_id=o.user_id AND p.serial_id=o.serial_id
 LEFT JOIN recycle r ON r.serial_id=o.serial_id
ORDER BY o.apply_time,o.serial_id
;
