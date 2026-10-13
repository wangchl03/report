-- T0 410评分四档对照；统计期保持2026-09-16—2026-09-30（含首尾）。
-- 评分边界固定自9月完整月份T0：546、515、496；同分不拆分。
-- 四档实际评分范围：546—726、515—545、496—514、386—495。
-- 完整数据截至2026-10-08；D0/D3/D7、口径1/2、严格母表均不变。
-- 全部T0行只作比较基准与四档对账；网页主表仍展示四类。
SET TIME ZONE 'America/Belize';
SET query_dop = 1;
WITH params AS (
    SELECT DATE '2026-09-16' AS start_date,
           DATE '2026-10-01' AS end_date,
           TIMESTAMP '2026-10-09 00:00:00' AS data_cutoff_ts,
           546::numeric AS top10_min_score,
           515::numeric AS top30_min_score,
           496::numeric AS top50_min_score,
           1::numeric AS valid_score_min,
           3000::numeric AS valid_score_max
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
), selected_model_scores AS (
    /* 同一获额订单出现重复同分时只取一次；不求用户历史平均或最高分。 */
    SELECT m.user_id, m.serial_id,
           MIN(m.kabybmerge410fpd7cre) AS score_410,
           COUNT(DISTINCT m.kabybmerge410fpd7cre) AS distinct_score_count
    FROM wangchuanliang.model_result_copy m
    INNER JOIN latest_pass_ranked a
      ON a.user_id = m.user_id AND a.score_serial_id = m.serial_id
     AND a.score_offer_rn = 1
    GROUP BY m.user_id, m.serial_id
), scored_cohort AS (
    SELECT e.*, a.score_serial_id, a.score_offer_time, m.score_410
    FROM cohort e
    INNER JOIN latest_pass_ranked a
      ON a.user_id = e.user_id AND a.event_serial_id = e.serial_id
     AND a.score_offer_rn = 1
    INNER JOIN selected_model_scores m
      ON m.user_id = e.user_id AND m.serial_id = a.score_serial_id
    CROSS JOIN params p
    WHERE m.score_410 BETWEEN p.valid_score_min AND p.valid_score_max
      AND m.distinct_score_count = 1
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
    SELECT e.*, p.data_cutoff_ts,
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
    /* 四组互斥；边界固定来自2026年9月完整月份T0评分分布，报告统计期不变。 */
    SELECT e.*, '前10%｜546—726分'::text AS sample_group, 1 AS group_order
    FROM event_labels e CROSS JOIN params p WHERE e.score_410 >= p.top10_min_score
    UNION ALL
    SELECT e.*, '10%—30%｜515—545分'::text AS sample_group, 2 AS group_order
    FROM event_labels e CROSS JOIN params p
    WHERE e.score_410 >= p.top30_min_score AND e.score_410 < p.top10_min_score
    UNION ALL
    SELECT e.*, '30%—50%｜496—514分'::text AS sample_group, 3 AS group_order
    FROM event_labels e CROSS JOIN params p
    WHERE e.score_410 >= p.top50_min_score AND e.score_410 < p.top30_min_score
    UNION ALL
    SELECT e.*, '后50%｜386—495分'::text AS sample_group, 4 AS group_order
    FROM event_labels e CROSS JOIN params p WHERE e.score_410 < p.top50_min_score
    UNION ALL
    /* 仅作为大盘基准与对账，网页四类主表不新增第五类。 */
    SELECT e.*, '全部T0'::text AS sample_group, 0 AS group_order
    FROM event_labels e
), aggregate_counts AS (
    SELECT sample_group, group_order,
           COUNT(*) AS t0_event_count,
           COUNT(DISTINCT user_id) AS unique_user_count,
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
        (SELECT COUNT(*) FROM cohort) AS strict_t0_before_score_count,
        (SELECT COUNT(*) FROM selected_model_scores WHERE distinct_score_count > 1) AS score_conflict_order_count,
        (SELECT COUNT(*) FROM event_labels WHERE score_410 < 386 OR score_410 > 726) AS outside_september_score_range_count,
        (SELECT COUNT(*) FROM event_labels WHERE score_410 <> FLOOR(score_410)) AS noninteger_score_count,
        (SELECT MIN(score_410) FROM event_labels) AS observed_score_min,
        (SELECT MAX(score_410) FROM event_labels) AS observed_score_max,
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
       p.data_cutoff_ts::date - 1 AS data_date,
       p.valid_score_min, p.valid_score_max,
       p.top10_min_score, p.top30_min_score, p.top50_min_score
FROM aggregate_counts c
CROSS JOIN (SELECT * FROM aggregate_counts WHERE sample_group = '全部T0') total
CROSS JOIN audits a CROSS JOIN params p
ORDER BY c.group_order;
