SET TIME ZONE 'America/Belize';

WITH cohort AS (
    SELECT serial_id, product_no, apply_time, remit_amt, repaid_amt,
           loan_status_code, due_date,
           (is_remit = 1 AND remit_amt > 0) AS funded,
           (is_remit = 1 AND remit_amt > 0
            AND due_date >= DATE '2000-01-01'
            AND due_date < CURRENT_DATE) AS mature
    FROM wangchuanliang.order_loan_f_v2_copy
    WHERE apply_date >= DATE '2026-01-01'
      AND apply_date <= '2026-10-28'::date
      AND apply_time < '2026-10-28 23:06:09.336055'::timestamp
      AND loan_day = 60
      AND loan_type = 'reloan'
      AND user_id NOT IN (5101518)
)
SELECT
    GROUPING(product_no) AS is_total,
    CASE WHEN GROUPING(product_no) = 1 THEN '合计'
         ELSE product_no END AS product_no,
    COUNT(*) AS application_orders,
    COUNT(DISTINCT serial_id) AS distinct_application_orders,
    SUM(CASE WHEN funded THEN 1 ELSE 0 END) AS funded_orders,
    SUM(CASE WHEN mature THEN 1 ELSE 0 END) AS mature_orders,
    SUM(CASE WHEN mature AND loan_status_code = 8 THEN 1 ELSE 0 END) AS overdue_orders,
    SUM(CASE WHEN mature THEN remit_amt END) AS mature_remit_amt,
    SUM(CASE WHEN mature THEN repaid_amt END) AS mature_repaid_amt,
    SUM(CASE WHEN mature AND repaid_amt IS NULL THEN 1 ELSE 0 END) AS missing_repaid_orders,
    SUM(CASE WHEN mature AND (loan_status_code IS NULL OR loan_status_code NOT IN (7,8)) THEN 1 ELSE 0 END) AS mature_other_status_orders,
    SUM(CASE WHEN funded AND (due_date IS NULL OR due_date < DATE '2000-01-01') THEN 1 ELSE 0 END) AS funded_invalid_due_date_orders,
    MIN(CASE WHEN mature THEN due_date END) AS first_mature_due_date,
    MAX(CASE WHEN mature THEN due_date END) AS last_mature_due_date
FROM cohort
GROUP BY GROUPING SETS ((product_no), ())
ORDER BY is_total, application_orders DESC, product_no;
