/* T7+活跃召回：五批coupon原分组与score排名对比。
   单位：批内去重用户；各批独立。业务时区America/Belize。
   同批每对组人数一致；score在该批所有有效[0,3000]分数中排序，不按coupon标签过滤。
   分子：窗口内至少提单一次的去重人数；分母：组内全部入选人数。
   日期窗口左闭右开，含召回当天；未成熟窗口不输出。
   9月18日对应已有冻结3/7/15日结果；新增四批截止2026-11-04 00:00判断观察期。
   黑名单在本地填入下方blacklist数组；五批本次命中均为0人，公开附件不含个人ID。
   各查询返回计数、排名和原始分数范围；提单率=applied_users_Wd/selected_users。
   精确率与汇总差值由同目录复核程序按冻结JSON中的计数复核。
*/
SET TIME ZONE 'America/Belize';


-- 一、9月18日：保留原已发布两套查询。
-- 一、coupon_level_2：五个原分组。
WITH blacklist AS (
    -- 复用时在本地填入既有黑名单，例如 ARRAY[用户ID]::bigint[]。
    -- 本批实际命中黑名单0人；公开附件不包含个人黑名单ID。
    SELECT UNNEST(ARRAY[]::bigint[]) AS user_id
), cohort AS (
    SELECT DISTINCT churn_user_id::bigint AS user_id,
           TRIM(coupon_level_2) AS coupon_level_2
    FROM wangchuanliang.t7recalllist_active0918
    WHERE churn_user_id IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM blacklist b WHERE b.user_id = churn_user_id::bigint)
      AND TRIM(coupon_level_2) IN ('637-1000','561-636','518-560','460-517','459-')
), first_application AS (
    SELECT o.user_id, MIN(o.apply_time) AS first_apply_time
    FROM wangchuanliang.order_loan_f_v2_copy o
    JOIN (SELECT DISTINCT user_id FROM cohort) c ON c.user_id=o.user_id
    WHERE o.apply_time >= TIMESTAMP '2026-09-18 00:00:00'
      AND o.apply_time < TIMESTAMP '2026-10-03 00:00:00'
      AND o.apply_date >= DATE '2026-09-18'
      AND o.apply_date < DATE '2026-10-03'
    GROUP BY o.user_id
)
SELECT c.coupon_level_2, COUNT(*) AS recalled_users,
       COUNT(DISTINCT c.user_id) AS distinct_users,
       SUM(CASE WHEN a.first_apply_time < TIMESTAMP '2026-09-21 00:00:00' THEN 1 ELSE 0 END) AS applied_users_3d,
       SUM(CASE WHEN a.first_apply_time < TIMESTAMP '2026-09-25 00:00:00' THEN 1 ELSE 0 END) AS applied_users_7d,
       COUNT(a.first_apply_time) AS applied_users_15d
FROM cohort c
LEFT JOIN first_application a ON a.user_id=c.user_id
GROUP BY c.coupon_level_2
ORDER BY CASE c.coupon_level_2
    WHEN '637-1000' THEN 1
    WHEN '561-636' THEN 2
    WHEN '518-560' THEN 3
    WHEN '460-517' THEN 4
    WHEN '459-' THEN 5 END
;

-- 二、score：从全表有效分数中取前8034人，按指定人数切分。
WITH blacklist AS (
    -- 复用时在本地填入既有黑名单，例如 ARRAY[用户ID]::bigint[]。
    -- 本批实际命中黑名单0人；公开附件不包含个人黑名单ID。
    SELECT UNNEST(ARRAY[]::bigint[]) AS user_id
), valid_users AS (
    SELECT DISTINCT churn_user_id::bigint AS user_id, score
    FROM wangchuanliang.t7recalllist_active0918
    WHERE churn_user_id IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM blacklist b WHERE b.user_id = churn_user_id::bigint)
      AND score BETWEEN 0 AND 3000
), ranked AS (
    SELECT user_id, score,
           ROW_NUMBER() OVER (ORDER BY score DESC, user_id ASC) AS score_rank
    FROM valid_users
), selected AS (
    SELECT user_id, score, score_rank,
           CASE WHEN score_rank <= 91 THEN 1
                WHEN score_rank <= 722 THEN 2
                WHEN score_rank <= 2024 THEN 3
                WHEN score_rank <= 5393 THEN 4
                WHEN score_rank <= 8034 THEN 5 END AS score_group
    FROM ranked
    WHERE score_rank <= 8034
), first_application AS (
    SELECT o.user_id, MIN(o.apply_time) AS first_apply_time
    FROM wangchuanliang.order_loan_f_v2_copy o
    JOIN selected s ON s.user_id=o.user_id
    WHERE o.apply_time >= TIMESTAMP '2026-09-18 00:00:00'
      AND o.apply_time < TIMESTAMP '2026-10-03 00:00:00'
      AND o.apply_date >= DATE '2026-09-18'
      AND o.apply_date < DATE '2026-10-03'
    GROUP BY o.user_id
), invalid_coupon_users AS (
    SELECT DISTINCT churn_user_id::bigint AS user_id
    FROM wangchuanliang.t7recalllist_active0918
    WHERE TRIM(coupon_level_2)='-90'
      AND churn_user_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM blacklist b WHERE b.user_id = churn_user_id::bigint)
)
SELECT COALESCE(s.score_group,0) AS score_group,
       COUNT(*) AS selected_users,COUNT(DISTINCT s.user_id) AS distinct_users,
       MIN(s.score_rank) AS min_rank,MAX(s.score_rank) AS max_rank,
       MIN(s.score)::text AS min_score,MAX(s.score)::text AS max_score,
       COUNT(b.user_id) AS selected_coupon_minus90_users,
       SUM(CASE WHEN a.first_apply_time < TIMESTAMP '2026-09-21 00:00:00' THEN 1 ELSE 0 END) AS applied_users_3d,
       SUM(CASE WHEN a.first_apply_time < TIMESTAMP '2026-09-25 00:00:00' THEN 1 ELSE 0 END) AS applied_users_7d,
       COUNT(a.first_apply_time) AS applied_users_15d
FROM selected s
LEFT JOIN first_application a ON a.user_id=s.user_id
LEFT JOIN invalid_coupon_users b ON b.user_id=s.user_id
GROUP BY GROUPING SETS ((s.score_group),())
ORDER BY score_group
;


-- 10月10日：t7recalllist_active1010。
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
    FROM wangchuanliang.t7recalllist_active1010
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

-- 10月16日：t7recalllist_active1016。
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
    FROM wangchuanliang.t7recalllist_active1016
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

-- 10月23日：t7recalllist_active1023。
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
    FROM wangchuanliang.t7recalllist_active1023
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
      AND o.apply_time < TIMESTAMP '2026-10-30 00:00:00'
      AND o.apply_date >= DATE '2026-10-23'
      AND o.apply_date < DATE '2026-10-30'
    GROUP BY o.user_id
)
SELECT m.scheme, COALESCE(m.group_id,0) AS group_id,
       COUNT(*) AS selected_users,
       COUNT(DISTINCT m.user_id) AS distinct_users,
       MIN(m.score_rank) AS min_rank, MAX(m.score_rank) AS max_rank,
       MIN(m.score)::text AS min_score, MAX(m.score)::text AS max_score,
       SUM(CASE WHEN m.coupon_label='-90' THEN 1 ELSE 0 END) AS coupon_minus90_users,
       SUM(CASE WHEN a.first_apply_time < TIMESTAMP '2026-10-26 00:00:00' THEN 1 ELSE 0 END) AS applied_users_3d,
       SUM(CASE WHEN a.first_apply_time < TIMESTAMP '2026-10-30 00:00:00' THEN 1 ELSE 0 END) AS applied_users_7d
FROM sample_members m
LEFT JOIN first_application a ON a.user_id=m.user_id
GROUP BY GROUPING SETS ((m.scheme,m.group_id),(m.scheme))
ORDER BY m.scheme, group_id;

-- 10月30日：t7recalllist_active1030。
WITH blacklist AS (
    SELECT UNNEST(ARRAY[]::bigint[]) AS user_id
), label_order(group_id, coupon_label) AS (
    VALUES (1, '600-1000'),
        (2, '528-600'),
        (3, '528-')
), source_users AS (
    SELECT DISTINCT churn_user_id::bigint AS user_id,
           TRIM(coupon_level_2::text) AS coupon_label, score
    FROM wangchuanliang.t7recalllist_active1030
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
      AND o.apply_time < TIMESTAMP '2026-11-02 00:00:00'
      AND o.apply_date >= DATE '2026-10-30'
      AND o.apply_date < DATE '2026-11-02'
    GROUP BY o.user_id
)
SELECT m.scheme, COALESCE(m.group_id,0) AS group_id,
       COUNT(*) AS selected_users,
       COUNT(DISTINCT m.user_id) AS distinct_users,
       MIN(m.score_rank) AS min_rank, MAX(m.score_rank) AS max_rank,
       MIN(m.score)::text AS min_score, MAX(m.score)::text AS max_score,
       SUM(CASE WHEN m.coupon_label='-90' THEN 1 ELSE 0 END) AS coupon_minus90_users,
       SUM(CASE WHEN a.first_apply_time < TIMESTAMP '2026-11-02 00:00:00' THEN 1 ELSE 0 END) AS applied_users_3d
FROM sample_members m
LEFT JOIN first_application a ON a.user_id=m.user_id
GROUP BY GROUPING SETS ((m.scheme,m.group_id),(m.scheme))
ORDER BY m.scheme, group_id;
