/* 报告完整复现SQL：T0 405评分四组对照：2026-09-16至2026-09-30（含首尾）。
   只读；严格T0母集、20秒获额去重和观测时刻最新405分沿用已核对查询。
   分母为T0事件，不按统计期去重用户。
   >490包含在>480内；全部T0 = >480事件 + 剔除>480的其余事件。
   缺失分保留在其余事件并单列审计，不将缺分解释为低分。
   D3含T0至D+3；D7含T0至D+7；数据完整日截至2026-10-08。
   输出主表、口径2、分组占比、相对大盘差值、互斥提单时点分布、母表及时间质量审计。
   差值按未四舍五入比率计算后保留两位小数，单位pp。
   本查询已在现有GaussDB(DWS)数据源执行；含DWS列存背景表，不是跨库通用DDL。
*/
WITH params AS (
    SELECT DATE '2026-09-16' AS start_date,
           DATE '2026-10-01' AS end_date,
           TIMESTAMP '2026-10-09 00:00:00' AS data_cutoff_ts,
           490::numeric AS score_threshold
), raw_pass_offer AS (
    SELECT v.user_id, v.serial_id, v.vir_date::date AS vir_date,
           v.vir_unix, v.loan_type_code,
           (TO_TIMESTAMP(v.vir_unix) AT TIME ZONE 'America/Belize') AS vir_time
    FROM wangchuanliang.order_vir_f_copy v CROSS JOIN params p
    WHERE v.is_pass1 = 1 AND v.vir_unix > 0
      AND v.vir_date >= p.start_date - 1
      AND v.vir_date < p.data_cutoff_ts::date + 1
), qualified_offer AS (
    SELECT v.* FROM raw_pass_offer v
    WHERE v.loan_type_code = 2
      AND EXISTS (
          SELECT 1 FROM wangchuanliang.side_recycle_type_copy r
          WHERE r.serial_id = v.serial_id AND r.recycle_type = 3
      )
), serial_latest AS (
    SELECT DISTINCT ON (user_id, serial_id) *
    FROM qualified_offer
    ORDER BY user_id, serial_id, vir_unix DESC
), lagged AS (
    SELECT v.*, LAG(vir_time) OVER (
        PARTITION BY user_id ORDER BY vir_time, serial_id
    ) AS previous_time
    FROM serial_latest v
), batched AS (
    SELECT l.*, SUM(CASE
        WHEN previous_time IS NULL
          OR vir_time - previous_time > INTERVAL '20 seconds'
        THEN 1 ELSE 0 END) OVER (
        PARTITION BY user_id ORDER BY vir_time, serial_id
        ROWS UNBOUNDED PRECEDING
    ) AS batch_id
    FROM lagged l
), batch_ranked AS (
    SELECT b.*, ROW_NUMBER() OVER (
        PARTITION BY user_id, batch_id ORDER BY vir_time DESC, serial_id DESC
    ) AS batch_rn
    FROM batched b
), dedup_offer AS (
    SELECT b.* FROM batch_ranked b CROSS JOIN params p
    WHERE batch_rn = 1 AND vir_date >= p.start_date
      AND vir_time < p.data_cutoff_ts
), candidate_users AS (
    SELECT DISTINCT user_id FROM dedup_offer
), all_orders AS (
    SELECT DISTINCT ON (o.user_id, o.serial_id)
           o.user_id, o.serial_id, o.apply_time, o.apply_date,
           o.is_remit, o.remit_amt, o.remit_time,
           o.is_repaid, o.repaid_date, o.repaid_time, o.loan_status_code
    FROM wangchuanliang.order_loan_f_v2_copy o
    INNER JOIN candidate_users u ON u.user_id = o.user_id
    ORDER BY o.user_id, o.serial_id, o.apply_time ASC NULLS LAST
), clean_settlement AS (
    SELECT o.* FROM all_orders o CROSS JOIN params p
    WHERE o.is_remit = 1 AND o.remit_amt > 0
      AND (o.is_repaid = 1 OR o.loan_status_code = 7)
      AND o.repaid_time > TIMESTAMP '2000-01-01'
      AND o.repaid_date >= p.start_date
      AND o.repaid_time < p.data_cutoff_ts
      /* 在结清时刻没有其他未结清的已放款订单，按历史时间重建。 */
      AND NOT EXISTS (
          SELECT 1 FROM all_orders x
          WHERE x.user_id = o.user_id AND x.serial_id <> o.serial_id
            AND x.is_remit = 1 AND x.remit_amt > 0
            AND x.remit_time <= o.repaid_time
            AND (x.repaid_time IS NULL
                 OR x.repaid_time <= TIMESTAMP '2000-01-01'
                 OR x.repaid_time > o.repaid_time)
      )
), settlement_matched AS (
    SELECT e.*, s.serial_id AS settled_serial_id, s.repaid_time,
           ROW_NUMBER() OVER (
               PARTITION BY e.user_id, e.serial_id
               ORDER BY s.repaid_time DESC, s.serial_id DESC
           ) AS settlement_rn
    FROM dedup_offer e INNER JOIN clean_settlement s
      ON s.user_id = e.user_id AND s.repaid_date = e.vir_date
     AND s.repaid_time <= e.vir_time
), strict_t0_all AS (
    SELECT e.*, LEAD(vir_time) OVER (
        PARTITION BY user_id ORDER BY vir_time, serial_id
    ) AS next_t0_time
    FROM settlement_matched e WHERE settlement_rn = 1
), cohort AS (
    SELECT e.* FROM strict_t0_all e CROSS JOIN params p
    WHERE e.vir_date >= p.start_date AND e.vir_date < p.end_date
), latest_pass_ranked AS (
    /* e本身已经获额通过。因此最近通过记录一定在e当天，不必回填更早日。 */
    SELECT e.user_id, e.serial_id AS event_serial_id,
           v.serial_id AS score_serial_id, v.vir_time AS score_offer_time,
           ROW_NUMBER() OVER (
               PARTITION BY e.user_id, e.serial_id
               ORDER BY v.vir_time DESC, v.serial_id DESC
           ) AS score_offer_rn
    FROM cohort e INNER JOIN raw_pass_offer v
      ON v.user_id = e.user_id AND v.vir_date = e.vir_date
     AND v.vir_time <= e.vir_time
), scored_cohort AS (
    SELECT e.*, a.score_serial_id, a.score_offer_time,
           NULLIF(m.kabybxgboost405apd7crecyc, -9999999) AS score_405
    FROM cohort e
    LEFT JOIN latest_pass_ranked a
      ON a.user_id = e.user_id AND a.event_serial_id = e.serial_id
     AND a.score_offer_rn = 1
    LEFT JOIN wangchuanliang.model_result_copy m
      ON m.user_id = e.user_id AND m.serial_id = a.score_serial_id
), first_user_apply AS (
    SELECT e.user_id, e.serial_id, MIN(o.apply_time) AS first_apply_time
    FROM cohort e CROSS JOIN params p
    LEFT JOIN all_orders o
      ON o.user_id = e.user_id AND o.apply_time >= e.vir_time
     AND o.apply_time < e.vir_date + INTERVAL '8 days'
     AND o.apply_time < p.data_cutoff_ts
     /* next_t0_time来自所有严格T0事件，不能先筛490分再分配提单。 */
     AND (e.next_t0_time IS NULL OR o.apply_time < e.next_t0_time)
    GROUP BY e.user_id, e.serial_id
), first_order_apply AS (
    SELECT e.user_id, e.serial_id, MIN(o.apply_time) AS first_apply_time
    FROM cohort e CROSS JOIN params p
    LEFT JOIN all_orders o
      ON o.user_id = e.user_id AND o.serial_id = e.serial_id
     AND o.apply_time >= e.vir_time
     AND o.apply_time < e.vir_date + INTERVAL '8 days'
     AND o.apply_time < e.vir_time + INTERVAL '15 days'
     AND o.apply_time < p.data_cutoff_ts
    GROUP BY e.user_id, e.serial_id
), event_labels AS (
    SELECT e.*, p.data_cutoff_ts, p.score_threshold,
           u.first_apply_time AS p1_first_apply_time,
           o.first_apply_time AS p2_first_apply_time,
           CASE WHEN e.vir_date + INTERVAL '1 day' <= p.data_cutoff_ts THEN 1 ELSE 0 END AS d0_mature,
           CASE WHEN e.vir_date + INTERVAL '4 days' <= p.data_cutoff_ts THEN 1 ELSE 0 END AS d3_mature,
           CASE WHEN e.vir_date + INTERVAL '8 days' <= p.data_cutoff_ts THEN 1 ELSE 0 END AS d7_mature,
           CASE WHEN u.first_apply_time < e.vir_date + INTERVAL '1 day' THEN 1 ELSE 0 END AS p1_d0,
           CASE WHEN u.first_apply_time < e.vir_date + INTERVAL '4 days' THEN 1 ELSE 0 END AS p1_d3,
           CASE WHEN u.first_apply_time < e.vir_date + INTERVAL '8 days' THEN 1 ELSE 0 END AS p1_d7,
           CASE WHEN o.first_apply_time < e.vir_date + INTERVAL '1 day' THEN 1 ELSE 0 END AS p2_d0,
           CASE WHEN o.first_apply_time < e.vir_date + INTERVAL '4 days' THEN 1 ELSE 0 END AS p2_d3,
           CASE WHEN o.first_apply_time < e.vir_date + INTERVAL '8 days' THEN 1 ELSE 0 END AS p2_d7
    FROM scored_cohort e CROSS JOIN params p
    LEFT JOIN first_user_apply u ON u.user_id = e.user_id AND u.serial_id = e.serial_id
    LEFT JOIN first_order_apply o ON o.user_id = e.user_id AND o.serial_id = e.serial_id
), grouped_events AS (
    SELECT e.*, '405分>490'::text AS sample_group, 1 AS group_order
    FROM event_labels e WHERE score_405 > 490
    UNION ALL
    SELECT e.*, '405分>480'::text AS sample_group, 2 AS group_order
    FROM event_labels e WHERE score_405 > 480
    UNION ALL
    SELECT e.*, '全部T0'::text AS sample_group, 3 AS group_order
    FROM event_labels e
    UNION ALL
    SELECT e.*, '剔除405分>480的T0事件'::text AS sample_group, 4 AS group_order
    FROM event_labels e WHERE score_405 <= 480 OR score_405 IS NULL
), aggregate_counts AS (
    SELECT sample_group, group_order,
           COUNT(*) AS t0_event_count,
           COUNT(DISTINCT user_id) AS unique_user_count,
           SUM(CASE WHEN score_405 IS NULL THEN 1 ELSE 0 END) AS missing_score_count,
           SUM(d0_mature) AS d0_mature_count,
           SUM(d3_mature) AS d3_mature_count,
           SUM(d7_mature) AS d7_mature_count,
           SUM(p1_d0*d0_mature) AS p1_d0_apply_count,
           SUM(p1_d3*d3_mature) AS p1_d3_apply_count,
           SUM(p1_d7*d7_mature) AS p1_d7_apply_count,
           SUM(p2_d0*d0_mature) AS p2_d0_apply_count,
           SUM(p2_d3*d3_mature) AS p2_d3_apply_count,
           SUM(p2_d7*d7_mature) AS p2_d7_apply_count
    FROM grouped_events GROUP BY sample_group, group_order
), audits AS (
    SELECT
        (SELECT COUNT(*) FROM qualified_offer q CROSS JOIN params p
         WHERE q.vir_date >= p.start_date AND q.vir_date < p.end_date) AS qualified_raw_rows,
        (SELECT COUNT(*) FROM serial_latest q CROSS JOIN params p
         WHERE q.vir_date >= p.start_date AND q.vir_date < p.end_date) AS unique_serial_events,
        (SELECT COUNT(*) FROM dedup_offer q CROSS JOIN params p
         WHERE q.vir_date >= p.start_date AND q.vir_date < p.end_date) AS after_20s_events,
        (SELECT COUNT(*) FROM event_labels WHERE score_offer_time > vir_time) AS future_score_offer_events,
        (SELECT COUNT(*) FROM event_labels WHERE score_serial_id <> serial_id) AS different_score_offer_events,
        (SELECT COUNT(*) - COUNT(DISTINCT serial_id) FROM event_labels) AS duplicate_event_serial_count,
        (SELECT COUNT(*) FROM event_labels
         WHERE p1_first_apply_time < vir_time OR p2_first_apply_time < vir_time) AS negative_apply_delay_count
)
SELECT c.*,
       ROUND(100.0 * c.p1_d0_apply_count / NULLIF(c.d0_mature_count, 0), 2) AS p1_d0_pct,
       ROUND(100.0 * c.p1_d3_apply_count / NULLIF(c.d3_mature_count, 0), 2) AS p1_d3_pct,
       ROUND(100.0 * c.p1_d7_apply_count / NULLIF(c.d7_mature_count, 0), 2) AS p1_d7_pct,
       ROUND(100.0 * c.p2_d0_apply_count / NULLIF(c.d0_mature_count, 0), 2) AS p2_d0_pct,
       ROUND(100.0 * c.p2_d3_apply_count / NULLIF(c.d3_mature_count, 0), 2) AS p2_d3_pct,
       ROUND(100.0 * c.p2_d7_apply_count / NULLIF(c.d7_mature_count, 0), 2) AS p2_d7_pct,
       ROUND(100.0 * c.t0_event_count / NULLIF(total.t0_event_count, 0), 2) AS event_share_pct,
       ROUND(100.0 * c.p1_d0_apply_count / NULLIF(c.d0_mature_count, 0)
             - 100.0 * total.p1_d0_apply_count / NULLIF(total.d0_mature_count, 0), 2) AS vs_all_d0_pp,
       ROUND(100.0 * c.p1_d3_apply_count / NULLIF(c.d3_mature_count, 0)
             - 100.0 * total.p1_d3_apply_count / NULLIF(total.d3_mature_count, 0), 2) AS vs_all_d3_pp,
       ROUND(100.0 * c.p1_d7_apply_count / NULLIF(c.d7_mature_count, 0)
             - 100.0 * total.p1_d7_apply_count / NULLIF(total.d7_mature_count, 0), 2) AS vs_all_d7_pp,
       c.p1_d3_apply_count - c.p1_d0_apply_count AS d1_d3_apply_count,
       c.p1_d7_apply_count - c.p1_d3_apply_count AS d4_d7_apply_count,
       c.d7_mature_count - c.p1_d7_apply_count AS d7_no_apply_count,
       ROUND(100.0 * (c.p1_d3_apply_count - c.p1_d0_apply_count)
             / NULLIF(c.d7_mature_count, 0), 2) AS d1_d3_event_pct,
       ROUND(100.0 * (c.p1_d7_apply_count - c.p1_d3_apply_count)
             / NULLIF(c.d7_mature_count, 0), 2) AS d4_d7_event_pct,
       ROUND(100.0 * (c.d7_mature_count - c.p1_d7_apply_count)
             / NULLIF(c.d7_mature_count, 0), 2) AS d7_no_apply_pct,
       ROUND(100.0 * c.p1_d0_apply_count / NULLIF(c.p1_d7_apply_count, 0), 2) AS d0_share_of_d7_pct,
       ROUND(100.0 * (c.p1_d7_apply_count - c.p1_d0_apply_count)
             / NULLIF(c.d7_mature_count, 0), 2) AS d1_d7_event_pct,
       a.*, p.start_date, p.end_date - 1 AS last_event_date, p.data_cutoff_ts,
       p.data_cutoff_ts::date - 1 AS data_date
FROM aggregate_counts c
CROSS JOIN (SELECT * FROM aggregate_counts WHERE sample_group = '全部T0') total
CROSS JOIN audits a CROSS JOIN params p
ORDER BY c.group_order;
