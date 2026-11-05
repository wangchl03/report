SET TIME ZONE 'America/Belize';
SET query_dop=1;

/*
2026年3—10月：含60天产品的续贷获额，按单/双产品及完整产品组合统计。
获额端：loan_type_code=2、is_pass1=1、已知recycle_type<>1。
先按相邻获额<=20秒链式分批，每批保留时间最晚、同时间serial_id最大的记录。
不按用户人日再次去重。保留记录中至少一个产品由product_info_copy.days确认是60天。
提单端：serial_id和user_id同时匹配，loan_type='reloan'，不要求放款。
仅统计获额当天提单；获额范围2026-03-01至2026-10-31，1—2月不展示。
2025-12-31及2026-11-01仅用于边界去重，不进入统计月份。
只读查询，不创建或修改数据库表。
*/
WITH product_catalog AS (
    SELECT TRIM(product_no) AS product_no,
           MIN(TRIM(days)) AS product_days,
           COUNT(*) AS catalog_rows,
           COUNT(DISTINCT TRIM(days)) AS day_versions
    FROM wangchuanliang.product_info_copy
    GROUP BY TRIM(product_no)
), product60_pattern AS (
    SELECT '(^|[^0-9])(' || STRING_AGG(product_no, '|') || ')([^0-9]|$)' AS pattern
    FROM product_catalog
    WHERE product_days='60' AND day_versions=1
), scope_users AS (
    SELECT DISTINCT v.user_id
    FROM wangchuanliang.order_vir_f_copy v
    CROSS JOIN product60_pattern p
    WHERE v.loan_type_code=2 AND v.is_pass1=1 AND v.vir_unix>0
      AND v.vir_date>=DATE '2025-12-31' AND v.vir_date<DATE '2026-11-02'
      AND v.user_id NOT IN (5101518)
      AND v.risk_product ~ p.pattern
), raw_pass AS (
    SELECT v.user_id, v.serial_id, v.vir_unix,
           v.vir_date::date AS source_credit_date,
           TO_TIMESTAMP(v.vir_unix) AT TIME ZONE 'America/Belize' AS credit_time,
           (TO_TIMESTAMP(v.vir_unix) AT TIME ZONE 'America/Belize')::date AS credit_date,
           v.risk_product
    FROM wangchuanliang.order_vir_f_copy v
    JOIN scope_users s ON s.user_id=v.user_id
    WHERE v.loan_type_code=2 AND v.is_pass1=1 AND v.vir_unix>0
      AND v.vir_date>=DATE '2025-12-31' AND v.vir_date<DATE '2026-11-02'
      AND v.vir_unix<=EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)
), recycle_profile AS (
    SELECT r.serial_id, COUNT(*) AS recycle_rows,
           MAX(CASE WHEN r.recycle_type=1 THEN 1 ELSE 0 END) AS has_type1,
           MAX(CASE WHEN r.recycle_type<>1 THEN 1 ELSE 0 END) AS has_non1,
           COUNT(DISTINCT r.recycle_type) AS recycle_versions
    FROM wangchuanliang.side_recycle_type_copy r
    GROUP BY r.serial_id
), eligible AS (
    SELECT v.*
    FROM raw_pass v
    JOIN recycle_profile r ON r.serial_id=v.serial_id
    WHERE r.has_type1=0 AND r.has_non1=1
), lagged AS (
    SELECT v.*, LAG(credit_time) OVER (
        PARTITION BY user_id ORDER BY credit_time, serial_id
    ) AS previous_time
    FROM eligible v
), batched AS (
    SELECT v.*, SUM(CASE WHEN previous_time IS NULL
               OR credit_time-previous_time>INTERVAL '20 seconds' THEN 1 ELSE 0 END)
           OVER (PARTITION BY user_id ORDER BY credit_time, serial_id
                 ROWS UNBOUNDED PRECEDING) AS batch_id
    FROM lagged v
), ranked AS (
    SELECT v.*, ROW_NUMBER() OVER (
        PARTITION BY user_id,batch_id ORDER BY credit_time DESC,serial_id DESC
    ) AS batch_rn
    FROM batched v
), winners AS (
    SELECT * FROM ranked WHERE batch_rn=1
      AND credit_date>=DATE '2026-03-01' AND credit_date<DATE '2026-11-01'
), risk_strings AS (
    SELECT DISTINCT risk_product FROM winners
), product_parts_raw AS (
    SELECT risk_product,
           TRIM(UNNEST(STRING_TO_ARRAY(risk_product,','))) AS product_no
    FROM risk_strings
), product_parts AS (
    SELECT DISTINCT risk_product,product_no
    FROM product_parts_raw
    WHERE NULLIF(product_no,'') IS NOT NULL
), combinations AS (
    SELECT p.risk_product,
           COUNT(*) AS product_count,
           STRING_AGG(p.product_no,' + ' ORDER BY p.product_no) AS product_combination,
           STRING_AGG(COALESCE(c.product_days,'未匹配'),' + ' ORDER BY p.product_no) AS product_days_combination,
           MAX(CASE WHEN c.product_days='60' AND c.day_versions=1 THEN 1 ELSE 0 END) AS contains60,
           SUM(CASE WHEN c.product_no IS NULL THEN 1 ELSE 0 END) AS unmatched_products,
           MAX(COALESCE(c.catalog_rows,0)) AS max_catalog_rows,
           MAX(COALESCE(c.day_versions,0)) AS max_day_versions
    FROM product_parts p
    LEFT JOIN product_catalog c ON c.product_no=p.product_no
    GROUP BY p.risk_product
), cohort AS (
    SELECT v.user_id,v.serial_id,v.vir_unix,v.credit_time,v.credit_date,
           v.source_credit_date,v.risk_product,v.batch_id,
           TO_CHAR(v.credit_date,'YYYY-MM') AS event_month,
           p.product_count,p.product_combination,p.product_days_combination,
           p.unmatched_products,p.max_catalog_rows,p.max_day_versions
    FROM winners v JOIN combinations p ON p.risk_product=v.risk_product
    WHERE p.contains60=1
), candidate_ids AS (
    SELECT DISTINCT serial_id FROM cohort
), order_profile AS (
    SELECT o.serial_id,COUNT(*) AS source_order_rows,
           COUNT(DISTINCT o.user_id) AS order_user_versions,
           MIN(o.user_id) AS order_user_id,
           COUNT(DISTINCT o.loan_type) AS loan_type_versions,
           MIN(o.loan_type) AS order_loan_type,
           MIN(CASE WHEN o.loan_type='reloan'
                     AND o.apply_time>=TIMESTAMP '2026-01-01'
                     AND o.apply_time<TIMESTAMP '2026-11-01'
                    THEN o.apply_time END) AS apply_time,
           MIN(o.product_no) AS applied_product_no
    FROM wangchuanliang.order_loan_f_v2_copy o
    JOIN candidate_ids s ON s.serial_id=o.serial_id
    GROUP BY o.serial_id
), labels AS (
    SELECT e.*,a.order_user_id,a.order_loan_type,a.apply_time,a.applied_product_no,
           COALESCE(a.source_order_rows,0) AS source_order_rows,
           COALESCE(a.order_user_versions,0) AS order_user_versions,
           COALESCE(a.loan_type_versions,0) AS loan_type_versions,
           CASE WHEN a.apply_time IS NOT NULL AND a.order_user_id=e.user_id
                     AND a.order_user_versions=1 AND a.order_loan_type='reloan'
                     AND a.loan_type_versions=1 AND a.apply_time>=e.credit_time
                     AND a.apply_time::date=e.credit_date
                THEN 1 ELSE 0 END AS applied
    FROM cohort e LEFT JOIN order_profile a ON a.serial_id=e.serial_id
), audit AS (
    SELECT
        (SELECT COUNT(*) FROM raw_pass) AS scope_raw_pass_rows,
        (SELECT COUNT(*) FROM eligible) AS scope_eligible_rows,
        (SELECT COUNT(*)-COUNT(DISTINCT user_id::text||':'||serial_id::text) FROM eligible) AS repeated_eligible_serial_rows,
        (SELECT COUNT(*) FROM winners) AS scope_batch_winners,
        (SELECT COUNT(*) FROM cohort) AS cohort_offers,
        (SELECT COUNT(DISTINCT user_id) FROM cohort) AS cohort_users,
        (SELECT COUNT(*)-COUNT(DISTINCT serial_id) FROM cohort) AS repeated_cohort_serial_rows,
        (SELECT COUNT(*) FROM labels WHERE source_order_rows>1) AS repeated_application_source_rows,
        (SELECT COUNT(*) FROM labels WHERE order_user_versions>1 OR loan_type_versions>1) AS ambiguous_application_rows,
        (SELECT COUNT(*) FROM labels WHERE order_user_id<>user_id) AS user_mismatch_rows,
        (SELECT COUNT(*) FROM labels WHERE source_order_rows>0 AND order_loan_type<>'reloan') AS matched_first_loan_rows,
        (SELECT COUNT(*) FROM labels WHERE apply_time<credit_time) AS before_credit_application_rows,
        (SELECT COUNT(*) FROM cohort WHERE unmatched_products>0) AS unmatched_product_offer_rows,
        (SELECT COUNT(*) FROM cohort WHERE max_catalog_rows>1 OR max_day_versions>1) AS duplicated_product_catalog_offer_rows,
        (SELECT COUNT(*) FROM cohort WHERE source_credit_date<>credit_date) AS credit_date_mismatch_rows,
        (SELECT COUNT(*) FROM cohort WHERE product_count>2) AS more_than_two_product_offers,
        (SELECT COUNT(*) FROM raw_pass v LEFT JOIN recycle_profile r ON r.serial_id=v.serial_id
         WHERE r.serial_id IS NULL OR (r.has_type1=0 AND r.has_non1=0)) AS scope_unknown_recycle_rows,
        (SELECT COUNT(*) FROM raw_pass v JOIN recycle_profile r ON r.serial_id=v.serial_id
         WHERE r.recycle_versions>1) AS scope_conflicting_recycle_rows,
        (SELECT COUNT(*) FROM cohort WHERE user_id IN (5101518)) AS blacklist_rows
), marked AS (
    SELECT l.*,CASE WHEN applied=1 AND applied_product_no IN (
        SELECT product_no FROM product_catalog WHERE product_days='60' AND day_versions=1
    ) THEN 1 ELSE 0 END AS chose60
    FROM labels l
)
SELECT COALESCE(event_month,'合计') AS event_month,
       product_count,product_combination,product_days_combination,
       COUNT(*) AS offer_events,SUM(applied) AS d0_apply_events,
       ROUND(100.0*SUM(applied)/NULLIF(COUNT(*),0),2) AS d0_apply_rate_pct
FROM marked
GROUP BY GROUPING SETS ((event_month,product_count,product_combination,product_days_combination),
                       (product_count,product_combination,product_days_combination))
ORDER BY event_month,product_count,product_combination;
