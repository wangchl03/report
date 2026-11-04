/* T7活跃召回：coupon_level_2 与 score 原规则对比。
   统计单位：批内去重用户。日期统一 America/Belize。
   3/7/15日窗口均包含召回当天，分别截至9月21日/25日、10月3日00:00之前。
   coupon：保留五个原始有效标签，排除-90；不按score筛选。
   score：全表score位于[0,3000]的用户，按score降序、user_id升序取前8034人；
          不按coupon_level_2筛选。两套名单只保持组人数一致。
   查询前须确认同一用户无冲突分数/分组；本批原始8669行、8669人，无冲突。
   提单率=对应窗口提单人数/该组人数；不平均各组提单率。
   下方查询返回人数；附件复核程序按同一公式计算全部百分比。
*/
SET TIME ZONE 'America/Belize';

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
