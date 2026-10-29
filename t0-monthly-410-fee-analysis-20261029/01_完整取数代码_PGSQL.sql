-- 本次完整结果校验时间：2026-10-29 20:59:39（北京时间）；模型分已覆盖统计期全部T0事件。
/*
用途：T0 整体、每日 410 高分前 20% 的月度当天提单率，以及两种息费口径。
统计：2026-09-01 至 2026-09-30；2026-10-01 至 2026-10-28，均包含结束日。
环境：PostgreSQL / GaussDB(DWS)；业务时区 America/Belize。
执行：整段执行，只读查询；不执行 DROP、CREATE、INSERT、UPDATE、DELETE。

口径：
  A. 月度提单率按事件计数。同一用户多次有效 T0 获额事件分别计入。
  B. 每天独立选 410 高分事件，再按月累计事件数；不对每天的提单率取平均。
  C. 高分组使用 score_410 > 当天第 80 百分位；同分不拆分，实际占比略低于 20%。
  D. 息费只使用高分组获额后当天首次提单的订单，且 remit_amt > 0；不限制 is_remit。
  E. 订单息费率 = SUM(pre_amt + post_amt) / SUM(remit_amt)。
  F. 产品息费率 = SUM(product_info_copy.total_fee * remit_amt) / SUM(remit_amt)。
     total_fee 已是比例值，例如 0.406 = 40.6%，不再除以 100。
  G. 产品匹配失败或 total_fee 无效时，产品口径的分子、分母同步排除，并输出数量。
     相同 product_no 多行仅在 total_fee 完全一致时合并，避免连接放大。
  H. 缺失模型分不当作低分或未提单；整体提单率仍纳入这些 T0 事件。

输出：每月一行，含全部分子、分母、费率、有效评分日期范围及质量校验字段。
重跑：读取执行时的订单、评分和产品配置；源表后续更新会影响重跑结果。
复核：event_audit 的四项异常计数应为 0；先核对这些字段，再使用业务指标。
*/

SET TIME ZONE 'America/Belize';
SET query_dop = 1;

-- 01. 统计范围：结束日期为排他上界，2026-10-29 表示包含 10 月 28 日。
WITH params AS (
    SELECT DATE '2026-09-01' AS base_start_date,
           DATE '2026-09-01' AS output_start_date,
           DATE '2026-10-29' AS output_end_date,
           CURRENT_TIMESTAMP AT TIME ZONE 'America/Belize' AS data_cutoff_ts
),

-- 02. 获额通过的续贷记录；业务用户黑名单统一排除。vir_unix 的单位为秒。
raw_pass_offer AS (
    SELECT v.user_id, v.serial_id, v.vir_date::date AS vir_date,
           v.vir_unix,
           TO_TIMESTAMP(v.vir_unix) AT TIME ZONE 'America/Belize' AS vir_time
    FROM wangchuanliang.order_vir_f_copy v CROSS JOIN params p
    WHERE v.is_pass1 = 1 AND v.loan_type_code = 2 AND v.vir_unix > 0
      AND v.user_id NOT IN (5101518)
      AND v.vir_date >= p.base_start_date - 1
      AND v.vir_date < p.data_cutoff_ts::date + 1
      AND TO_TIMESTAMP(v.vir_unix) AT TIME ZONE 'America/Belize' < p.data_cutoff_ts
),

-- 03. 仅保留 side_recycle_type_copy 中 recycle_type = 3 的 T0 获额。
qualified_offer AS (
    SELECT v.* FROM raw_pass_offer v
    WHERE EXISTS (
        SELECT 1 FROM wangchuanliang.side_recycle_type_copy r
        WHERE r.serial_id = v.serial_id AND r.recycle_type = 3
    )
),

-- 04. 同一用户、同一获额流水只保留时间最新的一条。
serial_latest AS (
    SELECT DISTINCT ON (user_id, serial_id) * FROM qualified_offer
    ORDER BY user_id, serial_id, vir_unix DESC
),

-- 05. 获取同一用户相邻获额时刻，准备进行 20 秒链式去重。
lagged AS (
    SELECT v.*, LAG(vir_time) OVER (
        PARTITION BY user_id ORDER BY vir_time, serial_id
    ) AS previous_time
    FROM serial_latest v
),

-- 06. 相邻获额间隔大于 20 秒才开新批次；连续相邻间隔不超过 20 秒归为一批。
batched AS (
    SELECT v.*, SUM(CASE WHEN previous_time IS NULL
                              OR vir_time - previous_time > INTERVAL '20 seconds'
                        THEN 1 ELSE 0 END) OVER (
        PARTITION BY user_id ORDER BY vir_time, serial_id ROWS UNBOUNDED PRECEDING
    ) AS batch_id
    FROM lagged v
),

-- 07. 每个获额批次取最后一条，时间相同时按流水号排序。
batch_ranked AS (
    SELECT v.*, ROW_NUMBER() OVER (
        PARTITION BY user_id, batch_id ORDER BY vir_time DESC, serial_id DESC
    ) AS batch_rn
    FROM batched v
),

-- 08. 得到去重后的获额事件。
dedup_offer AS (
    SELECT v.* FROM batch_ranked v CROSS JOIN params p
    WHERE batch_rn = 1 AND vir_date >= p.base_start_date
),

-- 09. 提取候选用户，仅用于缩小订单查询范围，不按月合并用户事件。
candidate_users AS (
    SELECT DISTINCT user_id FROM dedup_offer
),

-- 10. 查询候选用户全部历史成功放款订单，用实际放款与结清时间还原在贷状态。
funded_orders AS (
    SELECT DISTINCT ON (o.user_id, o.serial_id)
           o.user_id, o.serial_id, o.apply_time, o.remit_time,
           o.remit_amt, o.is_remit, o.repaid_time, o.repaid_date,
           o.is_repaid, o.loan_status_code
    FROM wangchuanliang.order_loan_f_v2_copy o
    JOIN candidate_users u ON u.user_id = o.user_id
    WHERE o.is_remit = 1 AND o.remit_amt > 0
    ORDER BY o.user_id, o.serial_id, o.apply_time ASC NULLS LAST
),

-- 11. 找到结清时其他成功放款订单全部已结清的干净结清事件。
clean_settlement AS (
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
),

-- 12. 获额必须发生在同一业务日的干净结清之后；匹配最近的合格结清事件。
settlement_matched AS (
    SELECT e.*, s.serial_id AS settled_serial_id, s.repaid_time,
           ROW_NUMBER() OVER (
               PARTITION BY e.user_id, e.serial_id
               ORDER BY s.repaid_time DESC, s.serial_id DESC
           ) AS settlement_rn
    FROM dedup_offer e JOIN clean_settlement s
      ON s.user_id = e.user_id AND s.repaid_date = e.vir_date
     AND s.repaid_time <= e.vir_time
),

-- 13. 获取下一次有效 T0 获额时刻，用于截断本次事件的提单归属。
strict_t0_all AS (
    SELECT e.*, LEAD(vir_time) OVER (
        PARTITION BY user_id ORDER BY vir_time, serial_id
    ) AS next_t0_time
    FROM settlement_matched e WHERE settlement_rn = 1
),

-- 14. 按获额日期限定本次统计事件：9 月 1 日至 10 月 28 日。
cohort AS (
    SELECT e.*, p.data_cutoff_ts FROM strict_t0_all e CROSS JOIN params p
    WHERE e.vir_date >= p.output_start_date AND e.vir_date < p.output_end_date
),

-- 15. 查询统计期内的提单；不要求提单后成功放款。
raw_applications AS (
    SELECT o.user_id,o.serial_id,o.apply_time,
           COUNT(*) OVER (PARTITION BY o.user_id,o.serial_id) AS source_order_rows
    FROM wangchuanliang.order_loan_f_v2_copy o
    JOIN candidate_users u ON u.user_id=o.user_id
    CROSS JOIN params p
    WHERE o.apply_date>=p.output_start_date
      AND o.apply_date<p.output_end_date
      AND o.apply_time>=p.output_start_date::timestamp
      AND o.apply_time<p.output_end_date::timestamp
),

-- 16. 同一用户、同一提单流水只保留最早的提单时间。
applications AS (
    SELECT DISTINCT ON (user_id,serial_id) *
    FROM raw_applications
    ORDER BY user_id,serial_id,apply_time
),

-- 17. 从获额时刻到当天结束匹配提单，并在下一次有效 T0 获额时刻截断。
ranked AS (
    SELECT e.user_id,e.serial_id AS credit_serial_id,
           e.vir_date,e.vir_time,e.repaid_time,e.next_t0_time,
           a.serial_id AS apply_serial_id,a.apply_time,a.source_order_rows,
           ROW_NUMBER() OVER (
               PARTITION BY e.user_id,e.serial_id
               ORDER BY a.apply_time ASC NULLS LAST,a.serial_id ASC NULLS LAST
           ) AS rn
    FROM cohort e
    LEFT JOIN applications a
      ON a.user_id=e.user_id
     AND a.apply_time>=e.vir_time
     AND a.apply_time<(e.vir_date+1)::timestamp
     AND (e.next_t0_time IS NULL OR a.apply_time<e.next_t0_time)
),

-- 18. 每次 T0 事件只取获额后当天的首次提单；没有提单的事件仍保留在分母。
labels AS (
    SELECT * FROM ranked WHERE rn=1
),

-- 19. 模型分取本次获额流水对应的 410 分。同一流水存在不同用户或多个有效分时，不任意选分。
model_per_serial AS (
    SELECT m.serial_id,
           COUNT(*) AS model_rows,
           COUNT(DISTINCT m.user_id) AS user_versions,
           MIN(m.user_id) AS model_user_id,
           COUNT(DISTINCT CASE WHEN m.kabybmerge410fpd7cre IS NOT NULL
                                    AND m.kabybmerge410fpd7cre<>-9999999
                               THEN m.kabybmerge410fpd7cre END) AS score_versions,
           MIN(CASE WHEN m.kabybmerge410fpd7cre IS NOT NULL
                         AND m.kabybmerge410fpd7cre<>-9999999
                    THEN m.kabybmerge410fpd7cre END) AS score_value
    FROM wangchuanliang.model_result_copy m
    WHERE EXISTS (SELECT 1 FROM labels l WHERE l.credit_serial_id=m.serial_id)
    GROUP BY m.serial_id
),

-- 20. 获额事件与评分匹配；空值、缺省值 -9999999、评分冲突不参与高分组排名。
scored AS (
    SELECT l.*, TO_CHAR(l.vir_date,'YYYY-MM') AS event_month,
           m.model_rows, m.user_versions, m.score_versions,
           CASE WHEN m.user_versions=1 AND m.model_user_id=l.user_id
                     AND m.score_versions=1 THEN m.score_value END AS score_410
    FROM labels l
    LEFT JOIN model_per_serial m ON m.serial_id=l.credit_serial_id
),

-- 21. 每个业务日独立计算有效 410 分的第 80 百分位。
daily_thresholds AS (
    SELECT vir_date,
           PERCENTILE_CONT(0.8) WITHIN GROUP (ORDER BY score_410) AS q80
    FROM scored
    WHERE score_410 IS NOT NULL
    GROUP BY vir_date
),

-- 22. 取分数严格高于当天第 80 百分位的事件；边界同分不拆分。
classified AS (
    SELECT s.*, d.q80,
           CASE WHEN s.score_410>d.q80 THEN 1 ELSE 0 END AS top20_flag
    FROM scored s
    LEFT JOIN daily_thresholds d ON d.vir_date=s.vir_date
),

-- 23. 按月累计整体和每日高分组的分子、分母，保留缺分日期与事件数。
monthly_population AS (
    SELECT
        event_month,
        COUNT(*) AS all_t0_events,
        SUM(CASE WHEN apply_serial_id IS NOT NULL THEN 1 ELSE 0 END)
            AS all_d0_events,
        COUNT(score_410) AS valid_score_events,
        SUM(CASE WHEN score_410 IS NULL THEN 1 ELSE 0 END)
            AS missing_or_invalid_score_events,
        SUM(CASE WHEN model_rows IS NULL THEN 1 ELSE 0 END)
            AS missing_model_rows,
        SUM(CASE WHEN score_versions > 1 THEN 1 ELSE 0 END)
            AS score_conflict_events,
        MIN(vir_date) AS first_event_date,
        MAX(vir_date) AS last_event_date,
        MIN(CASE WHEN score_410 IS NOT NULL THEN vir_date END)
            AS first_valid_score_date,
        MAX(CASE WHEN score_410 IS NOT NULL THEN vir_date END)
            AS last_valid_score_date,
        COUNT(DISTINCT CASE WHEN score_410 IS NOT NULL THEN vir_date END)
            AS days_with_valid_scores,
        SUM(top20_flag) AS top20_events,
        SUM(CASE WHEN top20_flag = 1 AND apply_serial_id IS NOT NULL
                 THEN 1 ELSE 0 END) AS top20_d0_events
    FROM classified
    GROUP BY event_month
),

-- 24. 提取高分组当天首次提单的订单属性。
high_d0_orders AS (
    SELECT
        c.event_month,
        c.user_id,
        c.credit_serial_id,
        c.apply_serial_id,
        o.serial_id AS matched_order_id,
        o.product_no,
        o.loan_day,
        o.total_term,
        o.pre_amt,
        o.post_amt,
        o.remit_amt,
        o.is_remit
    FROM classified c
    LEFT JOIN wangchuanliang.order_loan_f_v2_copy o
        ON o.user_id = c.user_id
       AND o.serial_id = c.apply_serial_id
    WHERE c.top20_flag = 1
      AND c.apply_serial_id IS NOT NULL
),

-- 25. 产品表先归为每个产品编号一行，检查空值和不同费率冲突。
product_catalog AS (
    SELECT
        BTRIM(product_no) AS product_no,
        COUNT(*) AS catalog_rows,
        COUNT(DISTINCT total_fee) AS fee_versions,
        CASE
            WHEN COUNT(total_fee) = COUNT(*)
             AND COUNT(DISTINCT total_fee) = 1
            THEN MIN(total_fee)::numeric
        END AS total_fee
    FROM wangchuanliang.product_info_copy
    WHERE NULLIF(BTRIM(product_no), '') IS NOT NULL
    GROUP BY BTRIM(product_no)
),

-- 26. 用本笔提单选择的产品编号匹配产品表；不使用获额可选产品列表。
priced_orders AS (
    SELECT
        h.*,
        p.product_no AS matched_product_no,
        p.catalog_rows,
        p.fee_versions,
        p.total_fee,
        CASE
            WHEN h.remit_amt > 0
             AND p.total_fee IS NOT NULL
             AND p.total_fee >= 0
            THEN 1
            ELSE 0
        END AS product_fee_valid
    FROM high_d0_orders h
    LEFT JOIN product_catalog p
        ON p.product_no = NULLIF(BTRIM(h.product_no), '')
),

-- 27. 两种息费分别累计金额，先累加、后相除；中间不对单笔金额四舍五入。
monthly_fees AS (
    SELECT
        event_month,
        COUNT(*) AS first_d0_order_rows,
        COUNT(DISTINCT apply_serial_id) AS first_d0_distinct_orders,
        SUM(CASE WHEN matched_order_id IS NULL THEN 1 ELSE 0 END)
            AS unmatched_order_rows,
        SUM(CASE WHEN remit_amt > 0 THEN 1 ELSE 0 END)
            AS order_fee_orders,
        SUM(CASE WHEN remit_amt IS NULL OR remit_amt <= 0 THEN 1 ELSE 0 END)
            AS invalid_principal_orders,
        SUM(CASE WHEN remit_amt > 0 AND (pre_amt IS NULL OR post_amt IS NULL)
                 THEN 1 ELSE 0 END) AS missing_order_fee_fields,
        SUM(CASE WHEN remit_amt > 0
                 THEN COALESCE(pre_amt, 0) + COALESCE(post_amt, 0) END)
            AS order_fee_amt,
        SUM(CASE WHEN remit_amt > 0 THEN remit_amt END)
            AS order_principal_amt,
        SUM(product_fee_valid) AS product_fee_orders,
        SUM(CASE WHEN product_fee_valid = 1 THEN total_fee * remit_amt END)
            AS product_fee_amt,
        SUM(CASE WHEN product_fee_valid = 1 THEN remit_amt END)
            AS product_principal_amt,
        SUM(CASE WHEN matched_product_no IS NULL THEN 1 ELSE 0 END)
            AS unmatched_product_orders,
        SUM(CASE WHEN fee_versions > 1 THEN 1 ELSE 0 END)
            AS conflicting_product_fee_orders,
        SUM(CASE WHEN matched_product_no IS NOT NULL
                      AND (total_fee IS NULL OR total_fee < 0)
                 THEN 1 ELSE 0 END) AS invalid_product_fee_orders,
        SUM(CASE WHEN product_fee_valid = 1 AND total_fee = 0
                 THEN 1 ELSE 0 END) AS zero_product_fee_orders
    FROM priced_orders
    GROUP BY event_month
),

-- 28. 事件唯一性、订单归属与时间先后检查。
event_audit AS (
    SELECT
        COUNT(*) - COUNT(DISTINCT credit_serial_id) AS repeated_t0_ids,
        COUNT(apply_serial_id) - COUNT(DISTINCT apply_serial_id)
            AS repeated_application_assignments,
        SUM(CASE
                WHEN repaid_time > vir_time
                  OR vir_time::date <> vir_date
                  OR apply_time < vir_time
                  OR apply_time::date <> vir_date
                  OR apply_time >= next_t0_time
                THEN 1 ELSE 0
            END) AS invalid_label_times,
        SUM(CASE WHEN source_order_rows > 1 THEN 1 ELSE 0 END)
            AS repeated_source_applications
    FROM labels
)

-- 29. 最终输出：百分比字段为百分数值，例如 39.25 表示 39.25%。
SELECT
    p.event_month,
    p.first_event_date,
    p.last_event_date,
    p.all_t0_events,
    p.all_d0_events,
    ROUND(p.all_d0_events::numeric / NULLIF(p.all_t0_events, 0) * 100, 2)
        AS all_d0_rate_pct,
    p.valid_score_events,
    p.missing_or_invalid_score_events,
    p.missing_model_rows,
    p.score_conflict_events,
    p.first_valid_score_date,
    p.last_valid_score_date,
    p.days_with_valid_scores,
    p.top20_events,
    p.top20_d0_events,
    ROUND(p.top20_d0_events::numeric / NULLIF(p.top20_events, 0) * 100, 2)
        AS top20_d0_rate_pct,
    ROUND(p.top20_events::numeric / NULLIF(p.valid_score_events, 0) * 100, 2)
        AS top20_selected_share_pct,
    f.first_d0_order_rows,
    f.first_d0_distinct_orders,
    f.unmatched_order_rows,
    f.order_fee_orders,
    f.invalid_principal_orders,
    f.missing_order_fee_fields,
    f.order_principal_amt,
    f.order_fee_amt,
    ROUND(f.order_fee_amt / NULLIF(f.order_principal_amt, 0) * 100, 2)
        AS order_fee_rate_pct,
    f.product_fee_orders,
    f.product_principal_amt,
    f.product_fee_amt,
    ROUND(f.product_fee_amt / NULLIF(f.product_principal_amt, 0) * 100, 2)
        AS product_fee_rate_pct,
    f.unmatched_product_orders,
    f.conflicting_product_fee_orders,
    f.invalid_product_fee_orders,
    f.zero_product_fee_orders,
    a.repeated_t0_ids,
    a.repeated_application_assignments,
    a.invalid_label_times,
    a.repeated_source_applications
FROM monthly_population p
LEFT JOIN monthly_fees f
    ON f.event_month = p.event_month
CROSS JOIN event_audit a
ORDER BY p.event_month;
