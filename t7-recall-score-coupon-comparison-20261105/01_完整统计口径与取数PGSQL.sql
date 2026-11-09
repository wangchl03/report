/* T7+召回：五批coupon原分组与score排序的独立对比。
   表：t7recalllist_0930、1010、1016、1023、1030；均位于wangchuanliang。
   日期口径：America/Belize；W日包含召回日，自召回日00:00至+W日00:00之前。
   提单数据截至2026-11-07（含），统一业务时间上界2026-11-08 00:00，不包含上界。
   9/30支持3/7/15/30日；10/10、16、23支持3/7/15日；10/30支持3/7日。固定W日窗口截止早于统一上界时，按固定窗口计算。
   每批原分组人数决定score的切分人数；score在全批有效[0,3000]中排序，不按coupon标签限制。
   黑名单在本地blacklist数组填入；五批实际命中均为0人，公开附件不包含个人ID。
   每批已核对用户键无重复、score和标签无冲突；勿在有冲突时擅自取MIN/MAX覆盖。
   applied_users_Wd/selected_users为W日提单率；窗口内一人多次提单仅计一次。
   返回人数与排名等完整汇总；同目录复核程序从冻结汇总计算并核对全部比例和汇总差值。
*/
SET TIME ZONE 'America/Belize';


-- 9月30日：t7recalllist_0930
WITH blacklist AS (
    SELECT UNNEST(ARRAY[]::bigint[]) AS user_id
), label_order(group_id, coupon_label) AS (
    VALUES (1, '637-1000'),
        (2, '561-636'),
        (3, '518-560'),
        (4, '460-517'),
        (5, '459-')
), source_users AS (
    SELECT DISTINCT churn_user_id::bigint AS user_id,
           TRIM(coupon_level_2::text) AS coupon_label, score
    FROM wangchuanliang.t7recalllist_0930
    WHERE churn_user_id IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM blacklist b WHERE b.user_id=churn_user_id::bigint)
), coupon_users AS (
    SELECT u.user_id, u.score, u.coupon_label, g.group_id
    FROM source_users u
    JOIN label_order g ON g.coupon_label=u.coupon_label
), group_sizes AS (
    SELECT g.group_id, g.coupon_label, COUNT(c.user_id) AS users
    FROM label_order g
    LEFT JOIN coupon_users c ON c.group_id=g.group_id
    GROUP BY g.group_id, g.coupon_label
), rank_bounds AS (
    SELECT group_id, coupon_label, users,
           SUM(users) OVER (ORDER BY group_id)-users+1 AS min_rank,
           SUM(users) OVER (ORDER BY group_id) AS max_rank
    FROM group_sizes
), ranked_score AS (
    SELECT user_id, score, coupon_label,
           ROW_NUMBER() OVER (ORDER BY score DESC, user_id ASC) AS score_rank
    FROM source_users
    WHERE score BETWEEN 0 AND 3000
), sample_members AS (
    SELECT 'coupon'::text AS scheme, c.group_id, c.user_id, c.score,
           c.coupon_label, NULL::bigint AS score_rank
    FROM coupon_users c
    UNION ALL
    SELECT 'score'::text AS scheme, g.group_id, s.user_id, s.score,
           s.coupon_label, s.score_rank
    FROM ranked_score s
    JOIN rank_bounds g ON s.score_rank BETWEEN g.min_rank AND g.max_rank
), candidate_users AS (
    SELECT DISTINCT user_id FROM sample_members
), first_application AS (
    SELECT o.user_id, MIN(o.apply_time) AS first_apply_time
    FROM wangchuanliang.order_loan_f_v2_copy o
    JOIN candidate_users u ON u.user_id=o.user_id
    WHERE o.apply_time >= TIMESTAMP '2026-09-30 00:00:00'
      AND o.apply_time < TIMESTAMP '2026-10-30 00:00:00'
      AND o.apply_date >= DATE '2026-09-30'
      AND o.apply_date < DATE '2026-10-30'
    GROUP BY o.user_id
)
SELECT m.scheme, COALESCE(m.group_id,0) AS group_id,
       COUNT(*) AS selected_users,
       COUNT(DISTINCT m.user_id) AS distinct_users,
       MIN(m.score_rank) AS min_rank, MAX(m.score_rank) AS max_rank,
       MIN(m.score)::text AS min_score, MAX(m.score)::text AS max_score,
       SUM(CASE WHEN m.coupon_label='-90' THEN 1 ELSE 0 END) AS coupon_minus90_users,
       SUM(CASE WHEN a.first_apply_time < TIMESTAMP '2026-10-03 00:00:00' THEN 1 ELSE 0 END) AS applied_users_3d,
       SUM(CASE WHEN a.first_apply_time < TIMESTAMP '2026-10-07 00:00:00' THEN 1 ELSE 0 END) AS applied_users_7d,
       SUM(CASE WHEN a.first_apply_time < TIMESTAMP '2026-10-15 00:00:00' THEN 1 ELSE 0 END) AS applied_users_15d,
       SUM(CASE WHEN a.first_apply_time < TIMESTAMP '2026-10-30 00:00:00' THEN 1 ELSE 0 END) AS applied_users_30d
FROM sample_members m
LEFT JOIN first_application a ON a.user_id=m.user_id
GROUP BY GROUPING SETS ((m.scheme,m.group_id),(m.scheme))
ORDER BY m.scheme, group_id;

-- 10月10日：t7recalllist_1010
WITH blacklist AS (
    SELECT UNNEST(ARRAY[]::bigint[]) AS user_id
), label_order(group_id, coupon_label) AS (
    VALUES (1, '637-1000'),
        (2, '561-636'),
        (3, '518-560'),
        (4, '460-517'),
        (5, '459-')
), source_users AS (
    SELECT DISTINCT churn_user_id::bigint AS user_id,
           TRIM(coupon_level_2::text) AS coupon_label, score
    FROM wangchuanliang.t7recalllist_1010
    WHERE churn_user_id IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM blacklist b WHERE b.user_id=churn_user_id::bigint)
), coupon_users AS (
    SELECT u.user_id, u.score, u.coupon_label, g.group_id
    FROM source_users u
    JOIN label_order g ON g.coupon_label=u.coupon_label
), group_sizes AS (
    SELECT g.group_id, g.coupon_label, COUNT(c.user_id) AS users
    FROM label_order g
    LEFT JOIN coupon_users c ON c.group_id=g.group_id
    GROUP BY g.group_id, g.coupon_label
), rank_bounds AS (
    SELECT group_id, coupon_label, users,
           SUM(users) OVER (ORDER BY group_id)-users+1 AS min_rank,
           SUM(users) OVER (ORDER BY group_id) AS max_rank
    FROM group_sizes
), ranked_score AS (
    SELECT user_id, score, coupon_label,
           ROW_NUMBER() OVER (ORDER BY score DESC, user_id ASC) AS score_rank
    FROM source_users
    WHERE score BETWEEN 0 AND 3000
), sample_members AS (
    SELECT 'coupon'::text AS scheme, c.group_id, c.user_id, c.score,
           c.coupon_label, NULL::bigint AS score_rank
    FROM coupon_users c
    UNION ALL
    SELECT 'score'::text AS scheme, g.group_id, s.user_id, s.score,
           s.coupon_label, s.score_rank
    FROM ranked_score s
    JOIN rank_bounds g ON s.score_rank BETWEEN g.min_rank AND g.max_rank
), candidate_users AS (
    SELECT DISTINCT user_id FROM sample_members
), first_application AS (
    SELECT o.user_id, MIN(o.apply_time) AS first_apply_time
    FROM wangchuanliang.order_loan_f_v2_copy o
    JOIN candidate_users u ON u.user_id=o.user_id
    WHERE o.apply_time >= TIMESTAMP '2026-10-10 00:00:00'
      AND o.apply_time < TIMESTAMP '2026-10-25 00:00:00'
      AND o.apply_date >= DATE '2026-10-10'
      AND o.apply_date < DATE '2026-10-25'
    GROUP BY o.user_id
)
SELECT m.scheme, COALESCE(m.group_id,0) AS group_id,
       COUNT(*) AS selected_users,
       COUNT(DISTINCT m.user_id) AS distinct_users,
       MIN(m.score_rank) AS min_rank, MAX(m.score_rank) AS max_rank,
       MIN(m.score)::text AS min_score, MAX(m.score)::text AS max_score,
       SUM(CASE WHEN m.coupon_label='-90' THEN 1 ELSE 0 END) AS coupon_minus90_users,
       SUM(CASE WHEN a.first_apply_time < TIMESTAMP '2026-10-13 00:00:00' THEN 1 ELSE 0 END) AS applied_users_3d,
       SUM(CASE WHEN a.first_apply_time < TIMESTAMP '2026-10-17 00:00:00' THEN 1 ELSE 0 END) AS applied_users_7d,
       SUM(CASE WHEN a.first_apply_time < TIMESTAMP '2026-10-25 00:00:00' THEN 1 ELSE 0 END) AS applied_users_15d
FROM sample_members m
LEFT JOIN first_application a ON a.user_id=m.user_id
GROUP BY GROUPING SETS ((m.scheme,m.group_id),(m.scheme))
ORDER BY m.scheme, group_id;

-- 10月16日：t7recalllist_1016
WITH blacklist AS (
    SELECT UNNEST(ARRAY[]::bigint[]) AS user_id
), label_order(group_id, coupon_label) AS (
    VALUES (1, '637-1000'),
        (2, '561-636'),
        (3, '518-560'),
        (4, '460-517'),
        (5, '459-')
), source_users AS (
    SELECT DISTINCT churn_user_id::bigint AS user_id,
           TRIM(coupon_level_2::text) AS coupon_label, score
    FROM wangchuanliang.t7recalllist_1016
    WHERE churn_user_id IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM blacklist b WHERE b.user_id=churn_user_id::bigint)
), coupon_users AS (
    SELECT u.user_id, u.score, u.coupon_label, g.group_id
    FROM source_users u
    JOIN label_order g ON g.coupon_label=u.coupon_label
), group_sizes AS (
    SELECT g.group_id, g.coupon_label, COUNT(c.user_id) AS users
    FROM label_order g
    LEFT JOIN coupon_users c ON c.group_id=g.group_id
    GROUP BY g.group_id, g.coupon_label
), rank_bounds AS (
    SELECT group_id, coupon_label, users,
           SUM(users) OVER (ORDER BY group_id)-users+1 AS min_rank,
           SUM(users) OVER (ORDER BY group_id) AS max_rank
    FROM group_sizes
), ranked_score AS (
    SELECT user_id, score, coupon_label,
           ROW_NUMBER() OVER (ORDER BY score DESC, user_id ASC) AS score_rank
    FROM source_users
    WHERE score BETWEEN 0 AND 3000
), sample_members AS (
    SELECT 'coupon'::text AS scheme, c.group_id, c.user_id, c.score,
           c.coupon_label, NULL::bigint AS score_rank
    FROM coupon_users c
    UNION ALL
    SELECT 'score'::text AS scheme, g.group_id, s.user_id, s.score,
           s.coupon_label, s.score_rank
    FROM ranked_score s
    JOIN rank_bounds g ON s.score_rank BETWEEN g.min_rank AND g.max_rank
), candidate_users AS (
    SELECT DISTINCT user_id FROM sample_members
), first_application AS (
    SELECT o.user_id, MIN(o.apply_time) AS first_apply_time
    FROM wangchuanliang.order_loan_f_v2_copy o
    JOIN candidate_users u ON u.user_id=o.user_id
    WHERE o.apply_time >= TIMESTAMP '2026-10-16 00:00:00'
      AND o.apply_time < TIMESTAMP '2026-10-31 00:00:00'
      AND o.apply_date >= DATE '2026-10-16'
      AND o.apply_date < DATE '2026-10-31'
    GROUP BY o.user_id
)
SELECT m.scheme, COALESCE(m.group_id,0) AS group_id,
       COUNT(*) AS selected_users,
       COUNT(DISTINCT m.user_id) AS distinct_users,
       MIN(m.score_rank) AS min_rank, MAX(m.score_rank) AS max_rank,
       MIN(m.score)::text AS min_score, MAX(m.score)::text AS max_score,
       SUM(CASE WHEN m.coupon_label='-90' THEN 1 ELSE 0 END) AS coupon_minus90_users,
       SUM(CASE WHEN a.first_apply_time < TIMESTAMP '2026-10-19 00:00:00' THEN 1 ELSE 0 END) AS applied_users_3d,
       SUM(CASE WHEN a.first_apply_time < TIMESTAMP '2026-10-23 00:00:00' THEN 1 ELSE 0 END) AS applied_users_7d,
       SUM(CASE WHEN a.first_apply_time < TIMESTAMP '2026-10-31 00:00:00' THEN 1 ELSE 0 END) AS applied_users_15d
FROM sample_members m
LEFT JOIN first_application a ON a.user_id=m.user_id
GROUP BY GROUPING SETS ((m.scheme,m.group_id),(m.scheme))
ORDER BY m.scheme, group_id;

-- 10月23日：t7recalllist_1023
WITH blacklist AS (
    SELECT UNNEST(ARRAY[]::bigint[]) AS user_id
), label_order(group_id, coupon_label) AS (
    VALUES (1, '637-1000'),
        (2, '561-636'),
        (3, '518-560'),
        (4, '460-517'),
        (5, '459-')
), source_users AS (
    SELECT DISTINCT churn_user_id::bigint AS user_id,
           TRIM(coupon_level_2::text) AS coupon_label, score
    FROM wangchuanliang.t7recalllist_1023
    WHERE churn_user_id IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM blacklist b WHERE b.user_id=churn_user_id::bigint)
), coupon_users AS (
    SELECT u.user_id, u.score, u.coupon_label, g.group_id
    FROM source_users u
    JOIN label_order g ON g.coupon_label=u.coupon_label
), group_sizes AS (
    SELECT g.group_id, g.coupon_label, COUNT(c.user_id) AS users
    FROM label_order g
    LEFT JOIN coupon_users c ON c.group_id=g.group_id
    GROUP BY g.group_id, g.coupon_label
), rank_bounds AS (
    SELECT group_id, coupon_label, users,
           SUM(users) OVER (ORDER BY group_id)-users+1 AS min_rank,
           SUM(users) OVER (ORDER BY group_id) AS max_rank
    FROM group_sizes
), ranked_score AS (
    SELECT user_id, score, coupon_label,
           ROW_NUMBER() OVER (ORDER BY score DESC, user_id ASC) AS score_rank
    FROM source_users
    WHERE score BETWEEN 0 AND 3000
), sample_members AS (
    SELECT 'coupon'::text AS scheme, c.group_id, c.user_id, c.score,
           c.coupon_label, NULL::bigint AS score_rank
    FROM coupon_users c
    UNION ALL
    SELECT 'score'::text AS scheme, g.group_id, s.user_id, s.score,
           s.coupon_label, s.score_rank
    FROM ranked_score s
    JOIN rank_bounds g ON s.score_rank BETWEEN g.min_rank AND g.max_rank
), candidate_users AS (
    SELECT DISTINCT user_id FROM sample_members
), first_application AS (
    SELECT o.user_id, MIN(o.apply_time) AS first_apply_time
    FROM wangchuanliang.order_loan_f_v2_copy o
    JOIN candidate_users u ON u.user_id=o.user_id
    WHERE o.apply_time >= TIMESTAMP '2026-10-23 00:00:00'
      AND o.apply_time < TIMESTAMP '2026-11-07 00:00:00'
      AND o.apply_date >= DATE '2026-10-23'
      AND o.apply_date < DATE '2026-11-07'
    GROUP BY o.user_id
)
SELECT m.scheme, COALESCE(m.group_id,0) AS group_id,
       COUNT(*) AS selected_users,
       COUNT(DISTINCT m.user_id) AS distinct_users,
       MIN(m.score_rank) AS min_rank, MAX(m.score_rank) AS max_rank,
       MIN(m.score)::text AS min_score, MAX(m.score)::text AS max_score,
       SUM(CASE WHEN m.coupon_label='-90' THEN 1 ELSE 0 END) AS coupon_minus90_users,
       SUM(CASE WHEN a.first_apply_time < TIMESTAMP '2026-10-26 00:00:00' THEN 1 ELSE 0 END) AS applied_users_3d,
       SUM(CASE WHEN a.first_apply_time < TIMESTAMP '2026-10-30 00:00:00' THEN 1 ELSE 0 END) AS applied_users_7d,
       SUM(CASE WHEN a.first_apply_time < TIMESTAMP '2026-11-07 00:00:00' THEN 1 ELSE 0 END) AS applied_users_15d
FROM sample_members m
LEFT JOIN first_application a ON a.user_id=m.user_id
GROUP BY GROUPING SETS ((m.scheme,m.group_id),(m.scheme))
ORDER BY m.scheme, group_id;

-- 10月30日：t7recalllist_1030
WITH blacklist AS (
    SELECT UNNEST(ARRAY[]::bigint[]) AS user_id
), label_order(group_id, coupon_label) AS (
    VALUES (1, '600-1000'),
        (2, '528-600'),
        (3, '528-')
), source_users AS (
    SELECT DISTINCT churn_user_id::bigint AS user_id,
           TRIM(coupon_level_2::text) AS coupon_label, score
    FROM wangchuanliang.t7recalllist_1030
    WHERE churn_user_id IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM blacklist b WHERE b.user_id=churn_user_id::bigint)
), coupon_users AS (
    SELECT u.user_id, u.score, u.coupon_label, g.group_id
    FROM source_users u
    JOIN label_order g ON g.coupon_label=u.coupon_label
), group_sizes AS (
    SELECT g.group_id, g.coupon_label, COUNT(c.user_id) AS users
    FROM label_order g
    LEFT JOIN coupon_users c ON c.group_id=g.group_id
    GROUP BY g.group_id, g.coupon_label
), rank_bounds AS (
    SELECT group_id, coupon_label, users,
           SUM(users) OVER (ORDER BY group_id)-users+1 AS min_rank,
           SUM(users) OVER (ORDER BY group_id) AS max_rank
    FROM group_sizes
), ranked_score AS (
    SELECT user_id, score, coupon_label,
           ROW_NUMBER() OVER (ORDER BY score DESC, user_id ASC) AS score_rank
    FROM source_users
    WHERE score BETWEEN 0 AND 3000
), sample_members AS (
    SELECT 'coupon'::text AS scheme, c.group_id, c.user_id, c.score,
           c.coupon_label, NULL::bigint AS score_rank
    FROM coupon_users c
    UNION ALL
    SELECT 'score'::text AS scheme, g.group_id, s.user_id, s.score,
           s.coupon_label, s.score_rank
    FROM ranked_score s
    JOIN rank_bounds g ON s.score_rank BETWEEN g.min_rank AND g.max_rank
), candidate_users AS (
    SELECT DISTINCT user_id FROM sample_members
), first_application AS (
    SELECT o.user_id, MIN(o.apply_time) AS first_apply_time
    FROM wangchuanliang.order_loan_f_v2_copy o
    JOIN candidate_users u ON u.user_id=o.user_id
    WHERE o.apply_time >= TIMESTAMP '2026-10-30 00:00:00'
      AND o.apply_time < TIMESTAMP '2026-11-06 00:00:00'
      AND o.apply_date >= DATE '2026-10-30'
      AND o.apply_date < DATE '2026-11-06'
    GROUP BY o.user_id
)
SELECT m.scheme, COALESCE(m.group_id,0) AS group_id,
       COUNT(*) AS selected_users,
       COUNT(DISTINCT m.user_id) AS distinct_users,
       MIN(m.score_rank) AS min_rank, MAX(m.score_rank) AS max_rank,
       MIN(m.score)::text AS min_score, MAX(m.score)::text AS max_score,
       SUM(CASE WHEN m.coupon_label='-90' THEN 1 ELSE 0 END) AS coupon_minus90_users,
       SUM(CASE WHEN a.first_apply_time < TIMESTAMP '2026-11-02 00:00:00' THEN 1 ELSE 0 END) AS applied_users_3d,
       SUM(CASE WHEN a.first_apply_time < TIMESTAMP '2026-11-06 00:00:00' THEN 1 ELSE 0 END) AS applied_users_7d
FROM sample_members m
LEFT JOIN first_application a ON a.user_id=m.user_id
GROUP BY GROUPING SETS ((m.scheme,m.group_id),(m.scheme))
ORDER BY m.scheme, group_id;
