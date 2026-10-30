SET TIME ZONE 'America/Belize';

-- quality
WITH cohort AS (
    SELECT user_id, serial_id, product_no, total_term, loan_status_code, due_date
    FROM wangchuanliang.order_loan_f_v2_copy
    WHERE apply_date >= DATE '2026-01-01'
      AND apply_date <= '2026-10-28'::date
      AND apply_time < '2026-10-28 23:06:09.336055'::timestamp
      AND loan_day = 60
      AND loan_type = 'reloan'
      AND user_id NOT IN (5101518)
      AND is_remit = 1 AND remit_amt > 0
      AND due_date >= DATE '2000-01-01'
      AND due_date < '2026-10-28'::date
), periods AS (
    SELECT c.user_id, c.serial_id, c.product_no, c.total_term,
           c.loan_status_code, c.due_date,
           p.current_term, p.loan_status_code_period,
           p.overdue_days_period, p.due_date_period, p.is_repaid_period
    FROM cohort c
    JOIN wangchuanliang.repayment_plan_v2_copy p
      ON c.user_id = p.user_id AND c.serial_id = p.serial_id
), per_order AS (
    SELECT c.user_id, c.serial_id, c.product_no, c.total_term,
           c.loan_status_code, c.due_date,
           COUNT(p.current_term) AS plan_rows,
           COUNT(DISTINCT p.current_term) AS distinct_terms,
           MIN(p.current_term) AS min_term, MAX(p.current_term) AS max_term,
           MAX(p.due_date_period) AS last_period_due_date,
           MIN(CASE WHEN p.overdue_days_period > 0 THEN p.current_term END) AS first_historical_term,
           MIN(CASE WHEN p.loan_status_code_period = 8 THEN p.current_term END) AS first_current_term,
           SUM(CASE WHEN p.overdue_days_period IS NULL THEN 1 ELSE 0 END) AS overdue_days_missing,
           SUM(CASE WHEN p.loan_status_code_period IS NULL THEN 1 ELSE 0 END) AS status_missing
    FROM cohort c
    LEFT JOIN periods p ON c.user_id=p.user_id AND c.serial_id=p.serial_id
    GROUP BY c.user_id, c.serial_id, c.product_no, c.total_term, c.loan_status_code, c.due_date
)
SELECT COUNT(*) AS orders,
        COUNT(DISTINCT serial_id) AS distinct_orders,
        SUM(plan_rows) AS period_rows,
        MIN(min_term) AS min_term, MAX(max_term) AS max_term,
        SUM(CASE WHEN plan_rows<>distinct_terms THEN 1 ELSE 0 END) AS duplicate_period_orders,
        SUM(CASE WHEN plan_rows<>total_term OR min_term<>1 OR max_term<>total_term OR plan_rows=0 THEN 1 ELSE 0 END) AS incomplete_plan_orders,
        SUM(CASE WHEN last_period_due_date<>due_date THEN 1 ELSE 0 END) AS final_due_mismatch_orders,
        SUM(CASE WHEN first_historical_term IS NOT NULL THEN 1 ELSE 0 END) AS historical_overdue_orders,
        SUM(CASE WHEN first_current_term IS NOT NULL THEN 1 ELSE 0 END) AS current_overdue_orders,
        SUM(CASE WHEN loan_status_code=8 THEN 1 ELSE 0 END) AS current_status8_orders,
        SUM(CASE WHEN (loan_status_code=8 AND first_current_term IS NULL)
                       OR (loan_status_code<>8 AND first_current_term IS NOT NULL) THEN 1 ELSE 0 END) AS order_period_status_mismatch,
        SUM(CASE WHEN first_current_term IS NOT NULL AND first_historical_term IS NULL THEN 1 ELSE 0 END) AS current_without_historical_overdue_orders,
        SUM(overdue_days_missing) AS missing_overdue_days,
        SUM(status_missing) AS missing_period_status
        FROM per_order;

-- first_overdue_term
WITH cohort AS (
    SELECT user_id, serial_id, product_no, total_term, loan_status_code, due_date
    FROM wangchuanliang.order_loan_f_v2_copy
    WHERE apply_date >= DATE '2026-01-01'
      AND apply_date <= '2026-10-28'::date
      AND apply_time < '2026-10-28 23:06:09.336055'::timestamp
      AND loan_day = 60
      AND loan_type = 'reloan'
      AND user_id NOT IN (5101518)
      AND is_remit = 1 AND remit_amt > 0
      AND due_date >= DATE '2000-01-01'
      AND due_date < '2026-10-28'::date
), periods AS (
    SELECT c.user_id, c.serial_id, c.product_no, c.total_term,
           c.loan_status_code, c.due_date,
           p.current_term, p.loan_status_code_period,
           p.overdue_days_period, p.due_date_period, p.is_repaid_period
    FROM cohort c
    JOIN wangchuanliang.repayment_plan_v2_copy p
      ON c.user_id = p.user_id AND c.serial_id = p.serial_id
), per_order AS (
    SELECT c.user_id, c.serial_id, c.product_no, c.total_term,
           c.loan_status_code, c.due_date,
           COUNT(p.current_term) AS plan_rows,
           COUNT(DISTINCT p.current_term) AS distinct_terms,
           MIN(p.current_term) AS min_term, MAX(p.current_term) AS max_term,
           MAX(p.due_date_period) AS last_period_due_date,
           MIN(CASE WHEN p.overdue_days_period > 0 THEN p.current_term END) AS first_historical_term,
           MIN(CASE WHEN p.loan_status_code_period = 8 THEN p.current_term END) AS first_current_term,
           SUM(CASE WHEN p.overdue_days_period IS NULL THEN 1 ELSE 0 END) AS overdue_days_missing,
           SUM(CASE WHEN p.loan_status_code_period IS NULL THEN 1 ELSE 0 END) AS status_missing
    FROM cohort c
    LEFT JOIN periods p ON c.user_id=p.user_id AND c.serial_id=p.serial_id
    GROUP BY c.user_id, c.serial_id, c.product_no, c.total_term, c.loan_status_code, c.due_date
)
SELECT 'historical'::text AS definition, first_historical_term AS term,
             COUNT(*) AS orders
        FROM per_order WHERE first_historical_term IS NOT NULL
        GROUP BY first_historical_term
        UNION ALL
        SELECT 'current'::text AS definition, first_current_term AS term, COUNT(*) AS orders
        FROM per_order WHERE first_current_term IS NOT NULL GROUP BY first_current_term
        ORDER BY definition,term;

-- per_period
WITH cohort AS (
    SELECT user_id, serial_id, product_no, total_term, loan_status_code, due_date
    FROM wangchuanliang.order_loan_f_v2_copy
    WHERE apply_date >= DATE '2026-01-01'
      AND apply_date <= '2026-10-28'::date
      AND apply_time < '2026-10-28 23:06:09.336055'::timestamp
      AND loan_day = 60
      AND loan_type = 'reloan'
      AND user_id NOT IN (5101518)
      AND is_remit = 1 AND remit_amt > 0
      AND due_date >= DATE '2000-01-01'
      AND due_date < '2026-10-28'::date
), periods AS (
    SELECT c.user_id, c.serial_id, c.product_no, c.total_term,
           c.loan_status_code, c.due_date,
           p.current_term, p.loan_status_code_period,
           p.overdue_days_period, p.due_date_period, p.is_repaid_period
    FROM cohort c
    JOIN wangchuanliang.repayment_plan_v2_copy p
      ON c.user_id = p.user_id AND c.serial_id = p.serial_id
), per_order AS (
    SELECT c.user_id, c.serial_id, c.product_no, c.total_term,
           c.loan_status_code, c.due_date,
           COUNT(p.current_term) AS plan_rows,
           COUNT(DISTINCT p.current_term) AS distinct_terms,
           MIN(p.current_term) AS min_term, MAX(p.current_term) AS max_term,
           MAX(p.due_date_period) AS last_period_due_date,
           MIN(CASE WHEN p.overdue_days_period > 0 THEN p.current_term END) AS first_historical_term,
           MIN(CASE WHEN p.loan_status_code_period = 8 THEN p.current_term END) AS first_current_term,
           SUM(CASE WHEN p.overdue_days_period IS NULL THEN 1 ELSE 0 END) AS overdue_days_missing,
           SUM(CASE WHEN p.loan_status_code_period IS NULL THEN 1 ELSE 0 END) AS status_missing
    FROM cohort c
    LEFT JOIN periods p ON c.user_id=p.user_id AND c.serial_id=p.serial_id
    GROUP BY c.user_id, c.serial_id, c.product_no, c.total_term, c.loan_status_code, c.due_date
)
SELECT current_term AS term, COUNT(*) AS period_count,
        COUNT(DISTINCT serial_id) AS distinct_orders,
        SUM(CASE WHEN overdue_days_period>0 THEN 1 ELSE 0 END) AS historical_overdue,
        SUM(CASE WHEN loan_status_code_period=8 THEN 1 ELSE 0 END) AS current_overdue,
        SUM(CASE WHEN overdue_days_period>0 AND loan_status_code_period=7 THEN 1 ELSE 0 END) AS historically_overdue_now_settled,
        SUM(CASE WHEN loan_status_code_period=8 AND COALESCE(overdue_days_period,0)<=0 THEN 1 ELSE 0 END) AS current_without_positive_overdue_days
        FROM periods GROUP BY current_term ORDER BY current_term;

-- historical_first_by_current_status
WITH cohort AS (
    SELECT user_id, serial_id, product_no, total_term, loan_status_code, due_date
    FROM wangchuanliang.order_loan_f_v2_copy
    WHERE apply_date >= DATE '2026-01-01'
      AND apply_date <= '2026-10-28'::date
      AND apply_time < '2026-10-28 23:06:09.336055'::timestamp
      AND loan_day = 60
      AND loan_type = 'reloan'
      AND user_id NOT IN (5101518)
      AND is_remit = 1 AND remit_amt > 0
      AND due_date >= DATE '2000-01-01'
      AND due_date < '2026-10-28'::date
), periods AS (
    SELECT c.user_id, c.serial_id, c.product_no, c.total_term,
           c.loan_status_code, c.due_date,
           p.current_term, p.loan_status_code_period,
           p.overdue_days_period, p.due_date_period, p.is_repaid_period
    FROM cohort c
    JOIN wangchuanliang.repayment_plan_v2_copy p
      ON c.user_id = p.user_id AND c.serial_id = p.serial_id
), per_order AS (
    SELECT c.user_id, c.serial_id, c.product_no, c.total_term,
           c.loan_status_code, c.due_date,
           COUNT(p.current_term) AS plan_rows,
           COUNT(DISTINCT p.current_term) AS distinct_terms,
           MIN(p.current_term) AS min_term, MAX(p.current_term) AS max_term,
           MAX(p.due_date_period) AS last_period_due_date,
           MIN(CASE WHEN p.overdue_days_period > 0 THEN p.current_term END) AS first_historical_term,
           MIN(CASE WHEN p.loan_status_code_period = 8 THEN p.current_term END) AS first_current_term,
           SUM(CASE WHEN p.overdue_days_period IS NULL THEN 1 ELSE 0 END) AS overdue_days_missing,
           SUM(CASE WHEN p.loan_status_code_period IS NULL THEN 1 ELSE 0 END) AS status_missing
    FROM cohort c
    LEFT JOIN periods p ON c.user_id=p.user_id AND c.serial_id=p.serial_id
    GROUP BY c.user_id, c.serial_id, c.product_no, c.total_term, c.loan_status_code, c.due_date
)
SELECT first_historical_term AS first_term,
        COUNT(*) AS ever_overdue_orders,
        SUM(CASE WHEN loan_status_code=8 THEN 1 ELSE 0 END) AS currently_overdue_orders,
        SUM(CASE WHEN loan_status_code=7 THEN 1 ELSE 0 END) AS currently_settled_orders
        FROM per_order WHERE first_historical_term IS NOT NULL
        GROUP BY first_historical_term ORDER BY first_historical_term;