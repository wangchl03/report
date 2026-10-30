SET TIME ZONE 'America/Belize';

WITH cohort AS (
    -- 本笔60天成功放款订单，包含首贷和续贷；按本笔提单日期限定统计期。
    SELECT user_id,serial_id,apply_time,apply_date,remit_time,
           remit_amt,repaid_amt,due_date,loan_status_code,loan_type
    FROM wangchuanliang.order_loan_f_v2_copy
    WHERE apply_date>=DATE '2026-01-01'
      AND apply_date<='2026-10-29'::date
      AND (apply_time<'2026-10-29 03:34:25.518022'::timestamp OR apply_time IS NULL)
      AND loan_day=60
      AND is_remit=1 AND remit_amt>0
      AND user_id NOT IN (5101518)
), history AS (
    -- 不限制历史产品期限、申请年份或首续贷，保留所有可获得的成功放款历史。
    SELECT h.user_id,h.serial_id,h.apply_time,h.remit_time
    FROM wangchuanliang.order_loan_f_v2_copy h
    WHERE h.is_remit=1 AND h.remit_amt>0
      AND EXISTS (SELECT 1 FROM cohort c WHERE c.user_id=h.user_id)
), history_per_target AS (
    SELECT c.user_id,c.serial_id,
           COUNT(DISTINCT CASE
               WHEN h.remit_time<c.apply_time THEN h.serial_id END) AS prior_funded_n,
           MAX(CASE
               WHEN h.serial_id IS NOT NULL AND h.apply_time<c.apply_time
                AND (h.remit_time IS NULL OR h.remit_time<TIMESTAMP '2000-01-01'
                     OR h.remit_time<h.apply_time)
               THEN 1 ELSE 0 END) AS invalid_prior_funding_clock,
           COUNT(h.serial_id) AS joined_history_rows,
           COUNT(DISTINCT h.serial_id) AS distinct_history_orders,
           MIN(CASE WHEN h.remit_time<c.apply_time THEN h.remit_time END) AS earliest_prior_funding_time
    FROM cohort c
    LEFT JOIN history h ON h.user_id=c.user_id AND h.serial_id<>c.serial_id
    GROUP BY c.user_id,c.serial_id
), classified AS (
    SELECT c.*,h.prior_funded_n,h.invalid_prior_funding_clock,
           h.joined_history_rows,h.distinct_history_orders,h.earliest_prior_funding_time,
           CASE WHEN c.apply_time IS NULL OR h.invalid_prior_funding_clock=1 THEN -1
                WHEN h.prior_funded_n>=6 THEN 6
                ELSE h.prior_funded_n END AS borrow_band,
           CASE WHEN c.due_date>=DATE '2000-01-01'
                     AND c.due_date<'2026-10-29'::date THEN 1 ELSE 0 END AS mature
    FROM cohort c
    JOIN history_per_target h ON h.user_id=c.user_id AND h.serial_id=c.serial_id
)
SELECT GROUPING(borrow_band) AS is_total,
       CASE WHEN GROUPING(borrow_band)=1 THEN NULL ELSE borrow_band END AS borrow_band,
       COUNT(*) AS funded_orders,
       COUNT(DISTINCT serial_id) AS distinct_orders,
       SUM(mature) AS mature_orders,
       SUM(CASE WHEN mature=1 AND loan_status_code=8 THEN 1 ELSE 0 END) AS mature_overdue_orders,
       SUM(CASE WHEN mature=1 AND loan_status_code=7 THEN 1 ELSE 0 END) AS mature_settled_orders,
       SUM(CASE WHEN mature=1 AND (loan_status_code IS NULL OR loan_status_code NOT IN (7,8))
                THEN 1 ELSE 0 END) AS mature_other_status_orders,
       SUM(CASE WHEN mature=1 THEN remit_amt END) AS mature_remit_amt,
       SUM(CASE WHEN mature=1 THEN repaid_amt END) AS mature_repaid_amt,
       SUM(CASE WHEN mature=1 AND repaid_amt IS NULL THEN 1 ELSE 0 END) AS mature_missing_repaid,
       SUM(CASE WHEN loan_status_code=8 THEN 1 ELSE 0 END) AS all_funded_overdue_orders,
       SUM(remit_amt) AS all_remit_amt,
       SUM(repaid_amt) AS all_repaid_amt,
       SUM(CASE WHEN repaid_amt IS NULL THEN 1 ELSE 0 END) AS all_missing_repaid,
       SUM(CASE WHEN loan_type='firstloan' THEN 1 ELSE 0 END) AS firstloan_orders,
       SUM(CASE WHEN loan_type='reloan' THEN 1 ELSE 0 END) AS reloan_orders,
       SUM(CASE WHEN apply_time IS NULL THEN 1 ELSE 0 END) AS missing_apply_time_orders,
       SUM(invalid_prior_funding_clock) AS historical_clock_affected_orders,
       SUM(CASE WHEN joined_history_rows<>distinct_history_orders THEN 1 ELSE 0 END) AS duplicated_history_affected_orders,
       SUM(CASE WHEN due_date IS NULL OR due_date<DATE '2000-01-01' THEN 1 ELSE 0 END) AS invalid_due_date_orders,
       SUM(CASE WHEN remit_time IS NULL OR remit_time<apply_time OR remit_time>='2026-10-29 03:34:25.518022'::timestamp
                THEN 1 ELSE 0 END) AS invalid_current_funding_clock_orders,
       MIN(earliest_prior_funding_time) AS earliest_prior_funding_time,
       MIN(apply_time) AS first_application,
       MAX(apply_time) AS last_application
FROM classified
GROUP BY GROUPING SETS ((borrow_band),())
ORDER BY is_total,borrow_band;
