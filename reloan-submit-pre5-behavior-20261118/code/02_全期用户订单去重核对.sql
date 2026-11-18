/* Read only. Every submit-click log is retained through click_weight.
Actual event_time is already Belize timestamp; no additional time conversion.
The behavior table has no serial_id. Temporal association follows the existing
24-hour click-to-first-application convention: first ALL-type application, then
classify reloan. No approval, funding, current-status or credit-pass filters.
Prior window [T-1h,T); cross-day possible only before 01:00 by construction.
RANK retains every event at the fifth-position timestamp boundary; equal-time
events are explicitly resolved as unordered groups in analysis, never arbitrarily
ordered. Repeated events are not removed. Source tables are not modified. */
WITH clicks AS (
 SELECT user_id,event_time AS click_time,COUNT(*)::bigint AS click_weight
 FROM wangchuanliang.user_behavior_track_record
 WHERE event_time>=TIMESTAMP '2026-01-01 00:00:00' AND event_time<TIMESTAMP '2026-11-16 00:00:00'
   AND event_date>=DATE '2026-01-01' AND event_date<DATE '2026-11-16'
   AND user_id>0 AND user_id<>5101518 AND event_type='element_click'
   AND (element_id LIKE 'hfmgyiwihoavrqzv%' OR element_id LIKE 'udopwuxjursbmvcm%')
   AND SPLIT_PART(element_id,'_',1) IN ('hfmgyiwihoavrqzv','udopwuxjursbmvcm')
 GROUP BY user_id,event_time
), orders AS (
 SELECT user_id,serial_id,apply_time,loan_type
 FROM wangchuanliang.order_loan_f_v2_copy
 WHERE apply_time>=TIMESTAMP '2026-01-01 00:00:00' AND apply_time<TIMESTAMP '2026-11-17 00:00:00'
   AND user_id>0 AND user_id<>5101518
), next_apply AS (
 SELECT c.user_id,c.click_time,c.click_weight,MIN(o.apply_time) AS next_apply_time
 FROM clicks c LEFT JOIN orders o ON o.user_id=c.user_id
  AND o.apply_time>=c.click_time AND o.apply_time<=c.click_time+INTERVAL '24 hours'
 GROUP BY c.user_id,c.click_time,c.click_weight
), associations AS (
 SELECT n.user_id,n.click_time,n.click_weight,n.next_apply_time,
        COUNT(o.apply_time) AS next_orders,COUNT(DISTINCT o.loan_type) AS type_count,
        SUM(CASE WHEN o.apply_time IS NOT NULL AND o.loan_type IS NULL THEN 1 ELSE 0 END) AS unknown_types,
        COUNT(DISTINCT o.serial_id) AS next_distinct_serials,
        SUM(CASE WHEN o.apply_time IS NOT NULL AND o.serial_id IS NULL THEN 1 ELSE 0 END) AS missing_serials,
        MIN(o.loan_type) AS next_loan_type,
        CASE WHEN COUNT(DISTINCT o.serial_id)=1
                   AND SUM(CASE WHEN o.apply_time IS NOT NULL AND o.serial_id IS NULL THEN 1 ELSE 0 END)=0
             THEN MIN(o.serial_id::text) END AS next_serial_id
 FROM next_apply n LEFT JOIN orders o ON o.user_id=n.user_id AND o.apply_time=n.next_apply_time
 GROUP BY n.user_id,n.click_time,n.click_weight,n.next_apply_time
), classified AS (
 SELECT a.*,CASE WHEN next_apply_time IS NULL THEN 'no_application_24h'
                 WHEN type_count<>1 OR unknown_types>0 THEN 'next_order_type_ambiguous'
                 WHEN next_loan_type='reloan' THEN 'reloan'
                 WHEN next_loan_type='firstloan' THEN 'firstloan'
                 ELSE 'other_order_type' END AS match_class
 FROM associations a
)
SELECT DATE_TRUNC('month',click_time)::date AS click_month,
GROUPING(DATE_TRUNC('month',click_time)::date) AS is_total,match_class,
COUNT(*) AS anchor_groups,SUM(click_weight) AS click_logs,COUNT(DISTINCT user_id) AS distinct_users,
COUNT(DISTINCT next_serial_id) AS distinct_orders,
SUM(CASE WHEN next_orders>1 THEN click_weight ELSE 0 END) AS tied_order_clicks,
SUM(CASE WHEN next_serial_id IS NULL AND next_apply_time IS NOT NULL THEN click_weight ELSE 0 END) AS nonunique_order_clicks,
MIN(click_time) AS first_click,MAX(click_time) AS last_click,
SUM(CASE WHEN next_apply_time-click_time<=INTERVAL '5 minutes' THEN click_weight ELSE 0 END) AS order_5m,
SUM(CASE WHEN next_apply_time-click_time<=INTERVAL '1 hour' THEN click_weight ELSE 0 END) AS order_1h
FROM classified GROUP BY GROUPING SETS ((DATE_TRUNC('month',click_time)::date,match_class),(match_class));
