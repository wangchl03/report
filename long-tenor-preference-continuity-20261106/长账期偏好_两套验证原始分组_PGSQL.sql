/* 历史选择偏好延续性：两套方案的原始分组人数与点估计。
 * 统计2025-01-01起记录，提单截止2026-10-31。
 * 归一权重调整、置信区间与辅助分层见报告方法；本SQL输出原始结果。
 * 不执行DDL或写入。产品账期使用查询时product_info_copy.days。
 */
SET TIME ZONE 'America/Belize';
SET query_dop=1;
/* 只读。所有合格获额先20秒链式去重，再判断是否提供不同总账期。
 * 不限定召回名单；按本轮明确条件，不追加首续贷过滤，保留类型用于复核。
 * 分段读取时向结束边界多读取20秒，只输出本段获额，保证跨段末笔判定。
 * user_id、serial_id匹配实际提单，不要求放款。
 */
WITH raw_pass AS (
    SELECT v.user_id,v.serial_id,v.vir_unix,v.risk_product,v.loan_type_code
    FROM wangchuanliang.order_vir_f_copy v
    WHERE v.user_id IS NOT NULL AND v.user_id<>5101518
      AND v.is_pass1=1
      AND v.vir_date >= DATE '2025-01-01'::date
      AND v.vir_unix >= EXTRACT(EPOCH FROM TIMESTAMP '2025-01-01'::timestamp AT TIME ZONE 'America/Belize')
      AND v.vir_unix < EXTRACT(EPOCH FROM TIMESTAMP '2026-11-01 00:00:20'::timestamp AT TIME ZONE 'America/Belize')
), credit_source AS (
    SELECT user_id,serial_id,vir_unix,
           MIN(risk_product) AS risk_product,
           MIN(loan_type_code) AS credit_loan_type,
           COUNT(*) AS credit_source_rows,
           COUNT(DISTINCT risk_product) AS credit_product_versions
    FROM raw_pass GROUP BY user_id,serial_id,vir_unix
), recycle_profile AS (
    SELECT r.serial_id,
           MAX(CASE WHEN r.recycle_type=1 THEN 1 ELSE 0 END) AS has_type1,
           MAX(CASE WHEN r.recycle_type<>1 THEN 1 ELSE 0 END) AS has_non1
    FROM wangchuanliang.side_recycle_type_copy r
    JOIN (SELECT DISTINCT serial_id FROM credit_source) k ON k.serial_id=r.serial_id
    GROUP BY r.serial_id
), eligible AS (
    SELECT c.* FROM credit_source c JOIN recycle_profile r ON r.serial_id=c.serial_id
    WHERE r.has_non1=1 AND r.has_type1=0
), sequenced AS (
    SELECT e.*,LEAD(vir_unix) OVER(PARTITION BY user_id ORDER BY vir_unix,serial_id) AS next_credit_unix
    FROM eligible e
), kept AS (
    SELECT *,TO_TIMESTAMP(vir_unix) AT TIME ZONE 'America/Belize' AS credit_time
    FROM sequenced
    WHERE vir_unix < EXTRACT(EPOCH FROM TIMESTAMP '2026-11-01'::timestamp AT TIME ZONE 'America/Belize')
      AND (next_credit_unix IS NULL OR next_credit_unix-vir_unix>20)
), tokens AS (
    SELECT user_id,serial_id,TRIM(REGEXP_SPLIT_TO_TABLE(COALESCE(risk_product,''),',')) AS product_no
    FROM kept
), offer_products AS (
    SELECT DISTINCT user_id,serial_id,product_no FROM tokens WHERE product_no<>''
), catalog AS (
    SELECT TRIM(product_no) AS product_no,
           CASE WHEN COUNT(DISTINCT TRIM(days))=1 THEN
               MIN(CASE WHEN TRIM(days)~'^[0-9]+([.][0-9]+)?$' THEN TRIM(days)::numeric END)
           END AS product_days
    FROM wangchuanliang.product_info_copy GROUP BY TRIM(product_no)
), offer_profile AS (
    SELECT f.user_id,f.serial_id,COUNT(*) AS product_count,
           STRING_AGG(f.product_no,',' ORDER BY f.product_no) AS offer_combo,
           COUNT(p.product_days) AS known_days,
           MIN(p.product_days) AS shortest_days,MAX(p.product_days) AS longest_days
    FROM offer_products f LEFT JOIN catalog p ON p.product_no=f.product_no
    GROUP BY f.user_id,f.serial_id
), valid_offers AS (
    SELECT k.*,p.product_count,p.offer_combo,p.shortest_days,p.longest_days
    FROM kept k JOIN offer_profile p ON p.user_id=k.user_id AND p.serial_id=k.serial_id
    WHERE p.product_count>=2 AND p.known_days=p.product_count
      AND p.shortest_days>0 AND p.longest_days>p.shortest_days
      AND k.credit_product_versions=1
), application_source AS (
    SELECT o.user_id,o.serial_id,o.apply_time,NULLIF(TRIM(o.product_no),'') AS selected_product,
           o.loan_type,o.apply_amt
    FROM wangchuanliang.order_loan_f_v2_copy o
    JOIN valid_offers v ON v.user_id=o.user_id AND v.serial_id=o.serial_id
    WHERE o.apply_time>=TIMESTAMP '2025-01-01'
      AND o.apply_time<TIMESTAMP '2026-11-01'
), applications AS (
    SELECT user_id,serial_id,MIN(apply_time) AS apply_time,
           MIN(selected_product) AS selected_product,MIN(loan_type) AS loan_type,
           MIN(apply_amt) AS apply_amt,COUNT(*) AS application_source_rows,
           COUNT(DISTINCT selected_product) AS selected_product_versions,
           COUNT(DISTINCT loan_type) AS loan_type_versions
    FROM application_source GROUP BY user_id,serial_id
), labelled AS (
    SELECT v.user_id,v.serial_id,v.credit_time,v.offer_combo,v.product_count,
           v.shortest_days,v.longest_days,v.credit_loan_type,
           a.apply_time,a.selected_product,a.loan_type,a.apply_amt,
           cp.product_days AS selected_days,
           CASE WHEN a.serial_id IS NULL THEN 'not_applied'
                WHEN a.selected_product_versions>1 OR a.loan_type_versions>1 THEN 'source_conflict'
                WHEN a.apply_time<v.credit_time THEN 'applied_before_credit'
                WHEN a.selected_product IS NULL THEN 'missing_selected_product'
                WHEN f.product_no IS NULL THEN 'outside_offer'
                WHEN cp.product_days=v.longest_days THEN 'long'
                WHEN cp.product_days=v.shortest_days THEN 'short'
                ELSE 'middle' END AS choice
    FROM valid_offers v
    LEFT JOIN applications a ON a.user_id=v.user_id AND a.serial_id=v.serial_id
    LEFT JOIN offer_products f ON f.user_id=v.user_id AND f.serial_id=v.serial_id AND f.product_no=a.selected_product
    LEFT JOIN catalog cp ON cp.product_no=a.selected_product
)
, valid_choices AS (
    SELECT l.*,CASE WHEN choice='long' THEN 1 ELSE 0 END AS chose_longest,
           CASE WHEN choice='short' THEN 1 ELSE 0 END AS chose_shortest
    FROM labelled l WHERE choice IN ('long','short','middle')
), frozen_history AS (
    SELECT user_id,COUNT(*) AS history_n,SUM(chose_longest) AS history_long
    FROM valid_choices WHERE apply_time<TIMESTAMP '2026-08-01'
    GROUP BY user_id HAVING COUNT(*)>=3
), fixed_future AS (
    SELECT v.*,ROW_NUMBER() OVER(PARTITION BY user_id ORDER BY apply_time,serial_id) AS rn
    FROM valid_choices v WHERE apply_time>=TIMESTAMP '2026-08-01'
), fixed_test AS (
    SELECT '固定时点'::text AS scheme,v.user_id,v.serial_id,v.apply_time,v.offer_combo,
           h.history_n,h.history_long,v.chose_longest,v.chose_shortest
    FROM fixed_future v JOIN frozen_history h ON h.user_id=v.user_id WHERE v.rn=1
), choice_times AS (
    SELECT user_id,apply_time,COUNT(*) AS n,SUM(chose_longest) AS k
    FROM valid_choices GROUP BY user_id,apply_time
), time_histories AS (
    SELECT user_id,apply_time,
           COALESCE(SUM(n) OVER(PARTITION BY user_id ORDER BY apply_time
               ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0) AS history_n,
           COALESCE(SUM(k) OVER(PARTITION BY user_id ORDER BY apply_time
               ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0) AS history_long
    FROM choice_times
), dynamic_candidates AS (
    SELECT v.*,h.history_n,h.history_long,
           ROW_NUMBER() OVER(PARTITION BY v.user_id ORDER BY v.apply_time,v.serial_id) AS rn
    FROM valid_choices v JOIN time_histories h ON h.user_id=v.user_id AND h.apply_time=v.apply_time
    WHERE v.apply_time>=TIMESTAMP '2026-08-01' AND h.history_n>=3
), dynamic_test AS (
    SELECT '按选择次数推进'::text AS scheme,user_id,serial_id,apply_time,offer_combo,
           history_n,history_long,chose_longest,chose_shortest
    FROM dynamic_candidates WHERE rn=1
), tests AS (
    SELECT * FROM fixed_test UNION ALL SELECT * FROM dynamic_test
), grouped AS (
    SELECT *,CASE WHEN history_long*10>=history_n*7 THEN '高偏好：历史>=70%'
                  WHEN history_long*10<=history_n*3 THEN '低偏好：历史<=30%'
                  ELSE '中间：历史>30%且<70%' END AS preference_group,
             CASE WHEN history_long*10>=history_n*7 THEN 1
                  WHEN history_long*10<=history_n*3 THEN 3 ELSE 2 END AS group_order
    FROM tests
)
SELECT scheme,preference_group,COUNT(*) AS validation_users,
       SUM(chose_longest) AS longest_choice_users,SUM(chose_shortest) AS shortest_choice_users,
       SUM(chose_longest)::numeric/COUNT(*) AS longest_choice_rate,
       SUM(chose_shortest)::numeric/COUNT(*) AS shortest_choice_rate,
       AVG(history_n)::numeric AS mean_history_choices
FROM grouped GROUP BY scheme,preference_group,group_order ORDER BY scheme,group_order;
