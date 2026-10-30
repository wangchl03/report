-- 按获额产品数量分组：单产品仅40602；多产品为40602及其他产品。
/*
获额产品包含40602：2026年1月1日至10月28日当天提单率。
业务日：America/Belize；按有效获额事件统计，不按月去重用户。
获额：is_pass1=1，排除side_recycle_type_copy中recycle_type=1。
不额外限定loan_type_code，不要求T0干净结清，不要求循环贷在途。
获额去重：同用户同流水取最后记录；相邻间隔<=20秒链式分组，每组取最后记录。
先构建所有产品的有效获额序列，再筛选40602，避免重复归属提单。
提单：获额时刻起至业务当天结束，且早于下一有效获额时刻，取第一笔。
提单产品不限，不要求放款成功。排除业务黑名单5101518。
只读查询，不创建或修改数据库表。
*/
SET TIME ZONE 'America/Belize';
SET query_dop = 1;

WITH scope_users AS (
    -- 先缩小到统计期内曾获40602的用户，再还原这些用户的全部产品获额序列。
    SELECT DISTINCT v.user_id
    FROM wangchuanliang.order_vir_f_copy v
    WHERE v.is_pass1 = 1
      AND v.vir_unix > 0
      AND v.user_id NOT IN (5101518)
      AND v.vir_date >= DATE '2025-12-31'
      AND v.vir_date < DATE '2026-10-30'
      AND v.risk_product ~ '(^|[^0-9])40602([^0-9]|$)'
      AND NOT EXISTS (
          SELECT 1 FROM wangchuanliang.side_recycle_type_copy r
          WHERE r.serial_id = v.serial_id AND r.recycle_type = 1
      )
),
raw_pass AS (
    SELECT
        v.user_id,
        v.serial_id,
        v.vir_unix,
        v.vir_date::date AS source_vir_date,
        TO_TIMESTAMP(v.vir_unix) AT TIME ZONE 'America/Belize' AS credit_time,
        (TO_TIMESTAMP(v.vir_unix) AT TIME ZONE 'America/Belize')::date AS credit_date,
        v.risk_product,
        v.loan_type_code
    FROM wangchuanliang.order_vir_f_copy v
    JOIN scope_users u ON u.user_id = v.user_id
    WHERE v.is_pass1 = 1
      AND v.vir_unix > 0
      AND v.user_id NOT IN (5101518)
      -- 两侧各读取一天，处理20秒去重在统计边界附近的事件。
      AND v.vir_date >= DATE '2025-12-31'
      AND v.vir_date < DATE '2026-10-30'
),
eligible_pass AS (
    SELECT v.*
    FROM raw_pass v
    WHERE NOT EXISTS (
        SELECT 1
        FROM wangchuanliang.side_recycle_type_copy r
        WHERE r.serial_id = v.serial_id
          AND r.recycle_type = 1
    )
),
serial_latest AS (
    SELECT DISTINCT ON (user_id, serial_id) *
    FROM eligible_pass
    ORDER BY user_id, serial_id, vir_unix DESC
),
lagged AS (
    SELECT
        v.*,
        LAG(credit_time) OVER (
            PARTITION BY user_id ORDER BY credit_time, serial_id
        ) AS previous_time
    FROM serial_latest v
),
batched AS (
    SELECT
        v.*,
        SUM(CASE
                WHEN previous_time IS NULL
                  OR credit_time - previous_time > INTERVAL '20 seconds'
                    THEN 1
                ELSE 0
            END) OVER (
                PARTITION BY user_id
                ORDER BY credit_time, serial_id
                ROWS UNBOUNDED PRECEDING
            ) AS batch_id
    FROM lagged v
),
batch_ranked AS (
    SELECT
        v.*,
        ROW_NUMBER() OVER (
            PARTITION BY user_id, batch_id
            ORDER BY credit_time DESC, serial_id DESC
        ) AS batch_rn
    FROM batched v
),
valid_offers AS (
    SELECT * FROM batch_ranked WHERE batch_rn = 1
),
offer_sequence AS (
    SELECT
        v.*,
        LEAD(credit_time) OVER (
            PARTITION BY user_id ORDER BY credit_time, serial_id
        ) AS next_credit_time
    FROM valid_offers v
),
cohort AS (
    SELECT
        v.*,
        TO_CHAR(credit_date, 'YYYY-MM') AS event_month,
        CASE WHEN risk_product ~ '^[[:space:]]*40602[[:space:]]*$'
             THEN 1 ELSE 0 END AS single_product_flag
    FROM offer_sequence v
    WHERE credit_date >= DATE '2026-01-01'
      AND credit_date < DATE '2026-10-29'
      -- 按完整产品编号匹配，支持单产品和双产品。
      AND risk_product ~ '(^|[^0-9])40602([^0-9]|$)'
),
candidate_users AS (
    SELECT DISTINCT user_id FROM cohort
),
raw_applications AS (
    SELECT
        o.user_id,
        o.serial_id,
        o.apply_time,
        o.product_no,
        COUNT(*) OVER (PARTITION BY o.user_id, o.serial_id) AS source_order_rows
    FROM wangchuanliang.order_loan_f_v2_copy o
    JOIN candidate_users u ON u.user_id = o.user_id
    WHERE o.apply_date >= DATE '2026-01-01'
      AND o.apply_date < DATE '2026-10-29'
      AND o.apply_time >= TIMESTAMP '2026-01-01 00:00:00'
      AND o.apply_time < TIMESTAMP '2026-10-29 00:00:00'
),
applications AS (
    SELECT DISTINCT ON (user_id, serial_id) *
    FROM raw_applications
    ORDER BY user_id, serial_id, apply_time
),
ranked_labels AS (
    SELECT
        e.*,
        a.serial_id AS apply_serial_id,
        a.apply_time,
        a.product_no AS apply_product_no,
        a.source_order_rows,
        ROW_NUMBER() OVER (
            PARTITION BY e.user_id, e.serial_id
            ORDER BY a.apply_time ASC NULLS LAST, a.serial_id ASC NULLS LAST
        ) AS application_rn
    FROM cohort e
    LEFT JOIN applications a
      ON a.user_id = e.user_id
     AND a.apply_time >= e.credit_time
     AND a.apply_time < (e.credit_date + 1)::timestamp
     AND (e.next_credit_time IS NULL OR a.apply_time < e.next_credit_time)
),
labels AS (
    SELECT * FROM ranked_labels WHERE application_rn = 1
),
monthly AS (
    SELECT event_month, single_product_flag,
           COUNT(*) AS offer_events,
           COUNT(apply_serial_id) AS d0_apply_events
    FROM labels
    GROUP BY event_month, single_product_flag
),
months AS (
    SELECT '2026-01'::text AS event_month UNION ALL
    SELECT '2026-02' UNION ALL SELECT '2026-03' UNION ALL
    SELECT '2026-04' UNION ALL SELECT '2026-05' UNION ALL
    SELECT '2026-06' UNION ALL SELECT '2026-07' UNION ALL
    SELECT '2026-08' UNION ALL SELECT '2026-09' UNION ALL SELECT '2026-10'
),
product_groups AS (
    SELECT 1 AS single_product_flag UNION ALL SELECT 0
),
summary_rows AS (
    SELECT m.event_month, g.single_product_flag,
           COALESCE(s.offer_events, 0) AS offer_events,
           COALESCE(s.d0_apply_events, 0) AS d0_apply_events
    FROM months m CROSS JOIN product_groups g
    LEFT JOIN monthly s
      ON s.event_month = m.event_month
     AND s.single_product_flag = g.single_product_flag
    UNION ALL
    SELECT '合计', single_product_flag, COUNT(*), COUNT(apply_serial_id)
    FROM labels
    GROUP BY single_product_flag
),
recycle_profile AS (
    SELECT
        r.serial_id,
        COUNT(*) AS mapping_rows,
        MAX(CASE WHEN r.recycle_type = 1 THEN 1 ELSE 0 END) AS has_type1
    FROM wangchuanliang.side_recycle_type_copy r
    WHERE EXISTS (SELECT 1 FROM cohort e WHERE e.serial_id = r.serial_id)
    GROUP BY r.serial_id
),
audit AS (
    SELECT
        COUNT(*) - COUNT(DISTINCT user_id::text || ':' || l.serial_id::text) AS repeated_credit_events,
        COUNT(apply_serial_id) - COUNT(DISTINCT CASE WHEN apply_serial_id IS NOT NULL
            THEN user_id::text || ':' || apply_serial_id::text END) AS repeated_application_assignments,
        SUM(CASE WHEN apply_serial_id IS NOT NULL AND (
            apply_time < credit_time OR apply_time >= (credit_date + 1)::timestamp
            OR (next_credit_time IS NOT NULL AND apply_time >= next_credit_time)
        ) THEN 1 ELSE 0 END) AS invalid_label_times,
        SUM(CASE WHEN source_order_rows > 1 THEN 1 ELSE 0 END) AS repeated_source_application_events,
        SUM(CASE WHEN source_vir_date <> credit_date THEN 1 ELSE 0 END) AS date_mismatch_events,
        SUM(CASE WHEN user_id = 5101518 THEN 1 ELSE 0 END) AS blacklist_events,
        SUM(CASE WHEN r.mapping_rows IS NULL THEN 1 ELSE 0 END) AS missing_recycle_type_events,
        SUM(CASE WHEN r.has_type1 = 1 THEN 1 ELSE 0 END) AS excluded_type1_events
    FROM labels l
    LEFT JOIN recycle_profile r ON r.serial_id = l.serial_id
)
SELECT s.event_month,
       CASE WHEN s.single_product_flag = 1 THEN '单产品' ELSE '多产品' END AS product_group,
       s.offer_events,
       s.d0_apply_events,
       ROUND(100.0 * s.d0_apply_events / NULLIF(s.offer_events, 0), 2) AS d0_apply_rate_pct,
       a.*
FROM summary_rows s
CROSS JOIN audit a
ORDER BY s.event_month, s.single_product_flag DESC;
