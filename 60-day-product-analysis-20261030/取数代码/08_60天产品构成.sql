SET TIME ZONE 'America/Belize';

WITH base AS (
    SELECT
        serial_id,
        product_no,
        apply_time
    FROM wangchuanliang.order_loan_f_v2_copy
    WHERE apply_date >= DATE '2026-01-01'
      AND apply_date <= CURRENT_DATE
      AND apply_time < CURRENT_TIMESTAMP AT TIME ZONE 'America/Belize'
      AND loan_day = 60
      AND loan_type = 'reloan'
      AND user_id NOT IN (5101518)
)
SELECT
    GROUPING(product_no) AS is_total,
    CASE WHEN GROUPING(product_no) = 1 THEN '合计'
         WHEN product_no IS NULL OR TRIM(product_no) = '' THEN '（产品编号为空）'
         ELSE product_no END AS product_no,
    COUNT(*) AS order_count,
    COUNT(DISTINCT serial_id) AS distinct_orders,
    MIN(apply_time) AS first_application,
    MAX(apply_time) AS last_application
FROM base
GROUP BY GROUPING SETS ((product_no), ())
ORDER BY is_total, order_count DESC, product_no;
