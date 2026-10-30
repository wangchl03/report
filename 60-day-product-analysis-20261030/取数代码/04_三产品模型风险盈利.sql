/*
21天、28天、60天续贷产品：实际执行的只读取数SQL。
本文件不包含建表、删表或写入操作。

第一部分：整体样本质量、各模型逐分值频数及完整三模型样本频数。
  实际快照：北京时间2026-10-29 14:02:48.595449。
  kind='quality'：整体样本与有效模型分数量；
  kind='score'：按期限、模型、当前订单状态、月份、分值聚合的频数；
  kind='common'：三模型同时有效的频数，原统计辅助结果，不是本Excel额外样本。
  均值、中位数、最小值、最大值与分位阈值据kind='score'计算；详见复核程序。

第二部分：沿用第一部分固定阈值，提取各档订单数、逾期数、放款与还款金额。
  实际快照：北京时间2026-10-29 15:49:13.292071。
  两次取数的27档订单数、逾期数完全一致。
  订单占比 = n / 同期限同模型各档n合计。
  订单逾期率 = overdue_n / n。
  实际盈利率 = (repaid_amt - remit_amt) / remit_amt；两个金额均为该档汇总金额。

样本边界固定：2026-01-01起，apply_time早于2026-10-28 23:06:09.336055，
业务时区America/Belize；due_date早于2026-10-28；仅reloan成功放款且remit_amt>0。
后续执行源表可能更新，金额和当前状态不保证与冻结快照相同。
*/

-- ==================== 第一部分：原始聚合取数 ====================
SET TIME ZONE 'America/Belize';

WITH cohort AS (
    SELECT user_id,serial_id,apply_time,apply_date,product_no,loan_status_code,loan_day,
           remit_amt,repaid_amt,TO_CHAR(apply_date,'YYYY-MM') AS apply_month
    FROM wangchuanliang.order_loan_f_v2_copy
    WHERE apply_date>=DATE '2026-01-01' AND apply_date<='2026-10-28'::date
      AND apply_time<'2026-10-28 23:06:09.336055'::timestamp
      AND loan_day IN (21,28,60) AND loan_type='reloan'
      AND user_id NOT IN (5101518)
      AND is_remit=1 AND remit_amt>0
      AND due_date>=DATE '2000-01-01' AND due_date<'2026-10-28'::date
), model_per_serial AS (
    SELECT m.serial_id,COUNT(*) AS model_rows,COUNT(DISTINCT m.user_id) AS user_versions,
           MIN(m.user_id) AS model_user_id,COUNT(DISTINCT CASE WHEN m.kabybmerge410fpd7cre IS NOT NULL AND m.kabybmerge410fpd7cre<>-9999999 THEN m.kabybmerge410fpd7cre END) AS nd_410,MIN(CASE WHEN m.kabybmerge410fpd7cre IS NOT NULL AND m.kabybmerge410fpd7cre<>-9999999 THEN m.kabybmerge410fpd7cre END) AS value_410,COUNT(DISTINCT CASE WHEN m.kabybxgboost363dpd7cre IS NOT NULL AND m.kabybxgboost363dpd7cre<>-9999999 THEN m.kabybxgboost363dpd7cre END) AS nd_363,MIN(CASE WHEN m.kabybxgboost363dpd7cre IS NOT NULL AND m.kabybxgboost363dpd7cre<>-9999999 THEN m.kabybxgboost363dpd7cre END) AS value_363,COUNT(DISTINCT CASE WHEN m.kabybxgboost405apd7crecyc IS NOT NULL AND m.kabybxgboost405apd7crecyc<>-9999999 THEN m.kabybxgboost405apd7crecyc END) AS nd_405,MIN(CASE WHEN m.kabybxgboost405apd7crecyc IS NOT NULL AND m.kabybxgboost405apd7crecyc<>-9999999 THEN m.kabybxgboost405apd7crecyc END) AS value_405
    FROM wangchuanliang.model_result_copy m
    WHERE EXISTS(SELECT 1 FROM cohort c WHERE c.serial_id=m.serial_id)
    GROUP BY m.serial_id
), credit_per_order AS (
    SELECT c.user_id,c.serial_id,COUNT(v.serial_id) AS passed_credit_records,
           MAX(TO_TIMESTAMP(v.vir_unix) AT TIME ZONE 'America/Belize') AS latest_credit_time
    FROM cohort c LEFT JOIN wangchuanliang.order_vir_f_copy v
      ON v.user_id=c.user_id AND v.serial_id=c.serial_id
     AND v.is_pass1=1 AND v.vir_unix>0
     AND (TO_TIMESTAMP(v.vir_unix) AT TIME ZONE 'America/Belize')<=c.apply_time
    GROUP BY c.user_id,c.serial_id
), scored AS (
    SELECT c.*,COALESCE(k.passed_credit_records,0) AS passed_credit_records,k.latest_credit_time,
           m.model_rows,m.user_versions,m.model_user_id,m.nd_410,m.nd_363,m.nd_405,
           CASE WHEN k.passed_credit_records>0 AND m.user_versions=1 AND m.model_user_id=c.user_id AND m.nd_410=1 THEN m.value_410 END AS score_410,
           CASE WHEN k.passed_credit_records>0 AND m.user_versions=1 AND m.model_user_id=c.user_id AND m.nd_363=1 THEN m.value_363 END AS score_363,
           CASE WHEN k.passed_credit_records>0 AND m.user_versions=1 AND m.model_user_id=c.user_id AND m.nd_405=1 THEN m.value_405 END AS score_405
    FROM cohort c LEFT JOIN model_per_serial m ON m.serial_id=c.serial_id
    LEFT JOIN credit_per_order k ON k.user_id=c.user_id AND k.serial_id=c.serial_id
)
SELECT 'quality'::text AS kind,
       loan_day,
       NULL::text AS model,
       loan_status_code,
       NULL::text AS apply_month,
       NULL::float8 AS score,
       COUNT(*) AS n,
       COUNT(DISTINCT serial_id) AS distinct_orders,
       COUNT(DISTINCT user_id) AS users,
       SUM(CASE WHEN model_rows IS NULL THEN 1 ELSE 0 END) AS missing_model_record,
       SUM(CASE WHEN user_versions<>1 OR model_user_id<>user_id THEN 1 ELSE 0 END) AS model_user_conflicts,
       SUM(CASE WHEN passed_credit_records=0 THEN 1 ELSE 0 END) AS missing_passed_credit,
       SUM(CASE WHEN latest_credit_time>apply_time THEN 1 ELSE 0 END) AS credit_after_apply,
       SUM(CASE WHEN nd_410>1 THEN 1 ELSE 0 END) AS conflicts_410,
       SUM(CASE WHEN nd_363>1 THEN 1 ELSE 0 END) AS conflicts_363,
       SUM(CASE WHEN nd_405>1 THEN 1 ELSE 0 END) AS conflicts_405,
       COUNT(score_410) AS valid_410,
       COUNT(score_363) AS valid_363,
       COUNT(score_405) AS valid_405,
       SUM(CASE WHEN repaid_amt IS NULL THEN 1 ELSE 0 END) AS repaid_missing,
       SUM(remit_amt) AS remit_sum,
       SUM(repaid_amt) AS repaid_sum FROM scored GROUP BY loan_day,
       loan_status_code
UNION ALL
SELECT 'score'::text AS kind,
       loan_day,
       '410'::text AS model,
       loan_status_code,
       apply_month,
       score_410 AS score,
       COUNT(*) AS n,
       NULL::numeric AS distinct_orders,
       NULL::numeric AS users,
       NULL::numeric AS missing_model_record,
       NULL::numeric AS model_user_conflicts,
       NULL::numeric AS missing_passed_credit,
       NULL::numeric AS credit_after_apply,
       NULL::numeric AS conflicts_410,
       NULL::numeric AS conflicts_363,
       NULL::numeric AS conflicts_405,
       NULL::numeric AS valid_410,
       NULL::numeric AS valid_363,
       NULL::numeric AS valid_405,
       NULL::numeric AS repaid_missing,
       NULL::numeric AS remit_sum,
       NULL::numeric AS repaid_sum FROM scored WHERE loan_status_code IN (7,8) AND score_410 IS NOT NULL GROUP BY loan_day,
       loan_status_code,
       apply_month,
       score_410
UNION ALL
SELECT 'score'::text AS kind,
       loan_day,
       '363'::text AS model,
       loan_status_code,
       apply_month,
       score_363 AS score,
       COUNT(*) AS n,
       NULL::numeric AS distinct_orders,
       NULL::numeric AS users,
       NULL::numeric AS missing_model_record,
       NULL::numeric AS model_user_conflicts,
       NULL::numeric AS missing_passed_credit,
       NULL::numeric AS credit_after_apply,
       NULL::numeric AS conflicts_410,
       NULL::numeric AS conflicts_363,
       NULL::numeric AS conflicts_405,
       NULL::numeric AS valid_410,
       NULL::numeric AS valid_363,
       NULL::numeric AS valid_405,
       NULL::numeric AS repaid_missing,
       NULL::numeric AS remit_sum,
       NULL::numeric AS repaid_sum FROM scored WHERE loan_status_code IN (7,8) AND score_363 IS NOT NULL GROUP BY loan_day,
       loan_status_code,
       apply_month,
       score_363
UNION ALL
SELECT 'score'::text AS kind,
       loan_day,
       '405'::text AS model,
       loan_status_code,
       apply_month,
       score_405 AS score,
       COUNT(*) AS n,
       NULL::numeric AS distinct_orders,
       NULL::numeric AS users,
       NULL::numeric AS missing_model_record,
       NULL::numeric AS model_user_conflicts,
       NULL::numeric AS missing_passed_credit,
       NULL::numeric AS credit_after_apply,
       NULL::numeric AS conflicts_410,
       NULL::numeric AS conflicts_363,
       NULL::numeric AS conflicts_405,
       NULL::numeric AS valid_410,
       NULL::numeric AS valid_363,
       NULL::numeric AS valid_405,
       NULL::numeric AS repaid_missing,
       NULL::numeric AS remit_sum,
       NULL::numeric AS repaid_sum FROM scored WHERE loan_status_code IN (7,8) AND score_405 IS NOT NULL GROUP BY loan_day,
       loan_status_code,
       apply_month,
       score_405
UNION ALL
SELECT 'common'::text AS kind,
       loan_day,
       '410'::text AS model,
       loan_status_code,
       apply_month,
       score_410 AS score,
       COUNT(*) AS n,
       NULL::numeric AS distinct_orders,
       NULL::numeric AS users,
       NULL::numeric AS missing_model_record,
       NULL::numeric AS model_user_conflicts,
       NULL::numeric AS missing_passed_credit,
       NULL::numeric AS credit_after_apply,
       NULL::numeric AS conflicts_410,
       NULL::numeric AS conflicts_363,
       NULL::numeric AS conflicts_405,
       NULL::numeric AS valid_410,
       NULL::numeric AS valid_363,
       NULL::numeric AS valid_405,
       NULL::numeric AS repaid_missing,
       NULL::numeric AS remit_sum,
       NULL::numeric AS repaid_sum FROM scored WHERE loan_status_code IN (7,8) AND score_410 IS NOT NULL AND score_410 IS NOT NULL AND score_363 IS NOT NULL AND score_405 IS NOT NULL GROUP BY loan_day,
       loan_status_code,
       apply_month,
       score_410
UNION ALL
SELECT 'common'::text AS kind,
       loan_day,
       '363'::text AS model,
       loan_status_code,
       apply_month,
       score_363 AS score,
       COUNT(*) AS n,
       NULL::numeric AS distinct_orders,
       NULL::numeric AS users,
       NULL::numeric AS missing_model_record,
       NULL::numeric AS model_user_conflicts,
       NULL::numeric AS missing_passed_credit,
       NULL::numeric AS credit_after_apply,
       NULL::numeric AS conflicts_410,
       NULL::numeric AS conflicts_363,
       NULL::numeric AS conflicts_405,
       NULL::numeric AS valid_410,
       NULL::numeric AS valid_363,
       NULL::numeric AS valid_405,
       NULL::numeric AS repaid_missing,
       NULL::numeric AS remit_sum,
       NULL::numeric AS repaid_sum FROM scored WHERE loan_status_code IN (7,8) AND score_363 IS NOT NULL AND score_410 IS NOT NULL AND score_363 IS NOT NULL AND score_405 IS NOT NULL GROUP BY loan_day,
       loan_status_code,
       apply_month,
       score_363
UNION ALL
SELECT 'common'::text AS kind,
       loan_day,
       '405'::text AS model,
       loan_status_code,
       apply_month,
       score_405 AS score,
       COUNT(*) AS n,
       NULL::numeric AS distinct_orders,
       NULL::numeric AS users,
       NULL::numeric AS missing_model_record,
       NULL::numeric AS model_user_conflicts,
       NULL::numeric AS missing_passed_credit,
       NULL::numeric AS credit_after_apply,
       NULL::numeric AS conflicts_410,
       NULL::numeric AS conflicts_363,
       NULL::numeric AS conflicts_405,
       NULL::numeric AS valid_410,
       NULL::numeric AS valid_363,
       NULL::numeric AS valid_405,
       NULL::numeric AS repaid_missing,
       NULL::numeric AS remit_sum,
       NULL::numeric AS repaid_sum FROM scored WHERE loan_status_code IN (7,8) AND score_405 IS NOT NULL AND score_410 IS NOT NULL AND score_363 IS NOT NULL AND score_405 IS NOT NULL GROUP BY loan_day,
       loan_status_code,
       apply_month,
       score_405;

-- ==================== 第二部分：分档风险与盈利取数 ====================
SET TIME ZONE 'America/Belize';

WITH cohort AS (
    SELECT user_id,serial_id,apply_time,apply_date,product_no,loan_status_code,loan_day,
           remit_amt,repaid_amt,TO_CHAR(apply_date,'YYYY-MM') AS apply_month
    FROM wangchuanliang.order_loan_f_v2_copy
    WHERE apply_date>=DATE '2026-01-01' AND apply_date<='2026-10-28'::date
      AND apply_time<'2026-10-28 23:06:09.336055'::timestamp
      AND loan_day IN (21,28,60) AND loan_type='reloan'
      AND user_id NOT IN (5101518)
      AND is_remit=1 AND remit_amt>0
      AND due_date>=DATE '2000-01-01' AND due_date<'2026-10-28'::date
), model_per_serial AS (
    SELECT m.serial_id,COUNT(*) AS model_rows,COUNT(DISTINCT m.user_id) AS user_versions,
           MIN(m.user_id) AS model_user_id,COUNT(DISTINCT CASE WHEN m.kabybmerge410fpd7cre IS NOT NULL AND m.kabybmerge410fpd7cre<>-9999999 THEN m.kabybmerge410fpd7cre END) AS nd_410,MIN(CASE WHEN m.kabybmerge410fpd7cre IS NOT NULL AND m.kabybmerge410fpd7cre<>-9999999 THEN m.kabybmerge410fpd7cre END) AS value_410,COUNT(DISTINCT CASE WHEN m.kabybxgboost363dpd7cre IS NOT NULL AND m.kabybxgboost363dpd7cre<>-9999999 THEN m.kabybxgboost363dpd7cre END) AS nd_363,MIN(CASE WHEN m.kabybxgboost363dpd7cre IS NOT NULL AND m.kabybxgboost363dpd7cre<>-9999999 THEN m.kabybxgboost363dpd7cre END) AS value_363,COUNT(DISTINCT CASE WHEN m.kabybxgboost405apd7crecyc IS NOT NULL AND m.kabybxgboost405apd7crecyc<>-9999999 THEN m.kabybxgboost405apd7crecyc END) AS nd_405,MIN(CASE WHEN m.kabybxgboost405apd7crecyc IS NOT NULL AND m.kabybxgboost405apd7crecyc<>-9999999 THEN m.kabybxgboost405apd7crecyc END) AS value_405
    FROM wangchuanliang.model_result_copy m
    WHERE EXISTS(SELECT 1 FROM cohort c WHERE c.serial_id=m.serial_id)
    GROUP BY m.serial_id
), credit_per_order AS (
    SELECT c.user_id,c.serial_id,COUNT(v.serial_id) AS passed_credit_records,
           MAX(TO_TIMESTAMP(v.vir_unix) AT TIME ZONE 'America/Belize') AS latest_credit_time
    FROM cohort c LEFT JOIN wangchuanliang.order_vir_f_copy v
      ON v.user_id=c.user_id AND v.serial_id=c.serial_id
     AND v.is_pass1=1 AND v.vir_unix>0
     AND (TO_TIMESTAMP(v.vir_unix) AT TIME ZONE 'America/Belize')<=c.apply_time
    GROUP BY c.user_id,c.serial_id
), scored AS (
    SELECT c.*,COALESCE(k.passed_credit_records,0) AS passed_credit_records,k.latest_credit_time,
           m.model_rows,m.user_versions,m.model_user_id,m.nd_410,m.nd_363,m.nd_405,
           CASE WHEN k.passed_credit_records>0 AND m.user_versions=1 AND m.model_user_id=c.user_id AND m.nd_410=1 THEN m.value_410 END AS score_410,
           CASE WHEN k.passed_credit_records>0 AND m.user_versions=1 AND m.model_user_id=c.user_id AND m.nd_363=1 THEN m.value_363 END AS score_363,
           CASE WHEN k.passed_credit_records>0 AND m.user_versions=1 AND m.model_user_id=c.user_id AND m.nd_405=1 THEN m.value_405 END AS score_405
    FROM cohort c LEFT JOIN model_per_serial m ON m.serial_id=c.serial_id
    LEFT JOIN credit_per_order k ON k.user_id=c.user_id AND k.serial_id=c.serial_id
), thresholds(loan_day,model,q50,q80) AS (
    VALUES (21,'410'::text,491.0::numeric,518.0::numeric),
           (21,'363'::text,457.0::numeric,478.0::numeric),
           (21,'405'::text,445.0::numeric,466.0::numeric),
           (28,'410'::text,518.0::numeric,551.0::numeric),
           (28,'363'::text,466.0::numeric,489.0::numeric),
           (28,'405'::text,449.0::numeric,472.0::numeric),
           (60,'410'::text,544.0::numeric,583.0::numeric),
           (60,'363'::text,480.0::numeric,507.0::numeric),
           (60,'405'::text,469.0::numeric,493.0::numeric)
), model_long AS (
SELECT loan_day,
       serial_id,
       loan_status_code,
       remit_amt,
       repaid_amt,
       '410'::text AS model,
       score_410 AS score FROM scored WHERE loan_status_code IN (7,8) AND score_410 IS NOT NULL
UNION ALL
SELECT loan_day,
       serial_id,
       loan_status_code,
       remit_amt,
       repaid_amt,
       '363'::text AS model,
       score_363 AS score FROM scored WHERE loan_status_code IN (7,8) AND score_363 IS NOT NULL
UNION ALL
SELECT loan_day,
       serial_id,
       loan_status_code,
       remit_amt,
       repaid_amt,
       '405'::text AS model,
       score_405 AS score FROM scored WHERE loan_status_code IN (7,8) AND score_405 IS NOT NULL
), banded AS (
    SELECT m.*,
           CASE WHEN m.score>t.q80 THEN 'HIGH20'
                WHEN m.score>t.q50 THEN 'MID30'
                ELSE 'LOW50' END AS band
    FROM model_long m
    JOIN thresholds t ON t.loan_day=m.loan_day AND t.model=m.model
)
SELECT loan_day,model,band,
       COUNT(*) AS n,
       COUNT(DISTINCT serial_id) AS distinct_orders,
       SUM(CASE WHEN loan_status_code=8 THEN 1 ELSE 0 END) AS overdue_n,
       SUM(CASE WHEN loan_status_code=7 THEN 1 ELSE 0 END) AS settled_n,
       SUM(CASE WHEN repaid_amt IS NULL THEN 1 ELSE 0 END) AS missing_repaid,
       SUM(remit_amt) AS remit_amt,
       SUM(repaid_amt) AS repaid_amt,
       MIN(score) AS min_score,
       MAX(score) AS max_score
FROM banded
GROUP BY loan_day,model,band;

-- ==================== 第三部分：同期全部续贷评分百分位 ====================
/*
整体参照池：所有期限的续贷提单订单；不限定放款、到期或当前状态。
目标样本：原21/28/60天成熟续贷放款订单；产品内部的原分档界限保留不变。
月份：每笔订单提单前最近一条同订单获额通过记录的业务月份。
SQL返回整体评分频数、目标评分频数及质量汇总，不导出个人明细。
统计计算详见复核资料中的同期百分位复核.py：
  F(score) = 同月同模型评分<=score的整体订单数 / 同月同模型有效订单总数。
  每笔目标订单先映射至月度F(score)，再按订单数量汇总中位数与P25/P75。
  原来的三个产品内部高/中/低档不重新按月分档。
同月比较为回溯统计，不是获额时刻实时排名。
*/
SET TIME ZONE 'America/Belize';

WITH orders AS (
    -- Overall comparison population: all historical renewal APPLICATION orders observed by the fixed cutoff.
    -- No loan_day / successful-funding / maturity / current-state restriction here.
    -- Relevant credit months are restricted downstream to months represented by the target cohort.
    SELECT user_id,serial_id,apply_time,apply_date,loan_day,loan_status_code,
           is_remit,remit_amt,due_date
    FROM wangchuanliang.order_loan_f_v2_copy
    WHERE loan_type='reloan'
      AND apply_time<'2026-10-28 23:06:09.336055'::timestamp
      AND user_id NOT IN (5101518)
), credit_per_order AS (
    SELECT o.user_id,o.serial_id,
           COUNT(v.serial_id) AS passed_credit_records,
           MAX(TO_TIMESTAMP(v.vir_unix) AT TIME ZONE 'America/Belize') AS latest_credit_time
    FROM orders o
    LEFT JOIN wangchuanliang.order_vir_f_copy v
      ON v.user_id=o.user_id AND v.serial_id=o.serial_id
     AND v.is_pass1=1 AND v.vir_unix>0
     AND (TO_TIMESTAMP(v.vir_unix) AT TIME ZONE 'America/Belize')<=o.apply_time
    GROUP BY o.user_id,o.serial_id
), model_per_serial AS (
    SELECT m.serial_id,
           COUNT(DISTINCT m.user_id) AS user_versions,
           MIN(m.user_id) AS model_user_id,
           COUNT(DISTINCT CASE WHEN m.kabybmerge410fpd7cre IS NOT NULL AND m.kabybmerge410fpd7cre<>-9999999 THEN m.kabybmerge410fpd7cre END) AS nd_410,
           MIN(CASE WHEN m.kabybmerge410fpd7cre IS NOT NULL AND m.kabybmerge410fpd7cre<>-9999999 THEN m.kabybmerge410fpd7cre END) AS value_410,
           COUNT(DISTINCT CASE WHEN m.kabybxgboost363dpd7cre IS NOT NULL AND m.kabybxgboost363dpd7cre<>-9999999 THEN m.kabybxgboost363dpd7cre END) AS nd_363,
           MIN(CASE WHEN m.kabybxgboost363dpd7cre IS NOT NULL AND m.kabybxgboost363dpd7cre<>-9999999 THEN m.kabybxgboost363dpd7cre END) AS value_363,
           COUNT(DISTINCT CASE WHEN m.kabybxgboost405apd7crecyc IS NOT NULL AND m.kabybxgboost405apd7crecyc<>-9999999 THEN m.kabybxgboost405apd7crecyc END) AS nd_405,
           MIN(CASE WHEN m.kabybxgboost405apd7crecyc IS NOT NULL AND m.kabybxgboost405apd7crecyc<>-9999999 THEN m.kabybxgboost405apd7crecyc END) AS value_405
    FROM wangchuanliang.model_result_copy m
    WHERE EXISTS (SELECT 1 FROM orders o WHERE o.serial_id=m.serial_id)
    GROUP BY m.serial_id
), scored AS (
    SELECT o.*,k.passed_credit_records,k.latest_credit_time,
           TO_CHAR(k.latest_credit_time,'YYYY-MM') AS credit_month,
           m.user_versions,m.model_user_id,m.nd_410,m.nd_363,m.nd_405,
           CASE WHEN o.apply_date>=DATE '2026-01-01'
                     AND o.apply_date<='2026-10-28'::date
                     AND o.loan_day IN (21,28,60)
                     AND o.is_remit=1 AND o.remit_amt>0
                     AND o.due_date>=DATE '2000-01-01'
                     AND o.due_date<'2026-10-28'::date
                     AND o.loan_status_code IN (7,8)
                THEN 1 ELSE 0 END AS is_target,
           CASE WHEN k.passed_credit_records>0 AND m.user_versions=1 AND m.model_user_id=o.user_id AND m.nd_410=1 THEN m.value_410 END AS score_410,
           CASE WHEN k.passed_credit_records>0 AND m.user_versions=1 AND m.model_user_id=o.user_id AND m.nd_363=1 THEN m.value_363 END AS score_363,
           CASE WHEN k.passed_credit_records>0 AND m.user_versions=1 AND m.model_user_id=o.user_id AND m.nd_405=1 THEN m.value_405 END AS score_405
    FROM orders o
    LEFT JOIN credit_per_order k ON k.user_id=o.user_id AND k.serial_id=o.serial_id
    LEFT JOIN model_per_serial m ON m.serial_id=o.serial_id
), target_months AS (
    SELECT DISTINCT credit_month
    FROM scored
    WHERE is_target=1 AND credit_month IS NOT NULL
), relevant AS (
    SELECT s.* FROM scored s
    WHERE s.credit_month IN (SELECT credit_month FROM target_months)
), model_long AS (
    SELECT loan_day,serial_id,credit_month,is_target,'410'::text AS model,score_410 AS score FROM relevant WHERE score_410 IS NOT NULL
    UNION ALL
    SELECT loan_day,serial_id,credit_month,is_target,'363'::text AS model,score_363 AS score FROM relevant WHERE score_363 IS NOT NULL
    UNION ALL
    SELECT loan_day,serial_id,credit_month,is_target,'405'::text AS model,score_405 AS score FROM relevant WHERE score_405 IS NOT NULL
)
SELECT 'reference_quality'::text AS kind,
       NULL::int AS loan_day,
       NULL::text AS model,
       credit_month,
       NULL::float8 AS score,
       COUNT(*) AS n,
       COUNT(DISTINCT serial_id) AS distinct_orders,
       SUM(CASE WHEN passed_credit_records IS NULL OR passed_credit_records=0 THEN 1 ELSE 0 END) AS missing_credit,
       SUM(CASE WHEN user_versions<>1 OR model_user_id<>user_id THEN 1 ELSE 0 END) AS user_conflicts,
       SUM(CASE WHEN nd_410>1 THEN 1 ELSE 0 END) AS score_conflicts_410,
       SUM(CASE WHEN nd_363>1 THEN 1 ELSE 0 END) AS score_conflicts_363,
       SUM(CASE WHEN nd_405>1 THEN 1 ELSE 0 END) AS score_conflicts_405,
       COUNT(score_410) AS valid_410,
       COUNT(score_363) AS valid_363,
       COUNT(score_405) AS valid_405,
       SUM(CASE WHEN is_remit=1 AND remit_amt>0 THEN 1 ELSE 0 END) AS funded_n,
       MIN(latest_credit_time) AS min_credit_time,
       MAX(latest_credit_time) AS max_credit_time FROM relevant GROUP BY credit_month
UNION ALL
SELECT 'target_quality'::text AS kind,
       loan_day,
       NULL::text AS model,
       credit_month,
       NULL::float8 AS score,
       COUNT(*) AS n,
       COUNT(DISTINCT serial_id) AS distinct_orders,
       SUM(CASE WHEN passed_credit_records IS NULL OR passed_credit_records=0 THEN 1 ELSE 0 END) AS missing_credit,
       SUM(CASE WHEN user_versions<>1 OR model_user_id<>user_id THEN 1 ELSE 0 END) AS user_conflicts,
       SUM(CASE WHEN nd_410>1 THEN 1 ELSE 0 END) AS score_conflicts_410,
       SUM(CASE WHEN nd_363>1 THEN 1 ELSE 0 END) AS score_conflicts_363,
       SUM(CASE WHEN nd_405>1 THEN 1 ELSE 0 END) AS score_conflicts_405,
       COUNT(score_410) AS valid_410,
       COUNT(score_363) AS valid_363,
       COUNT(score_405) AS valid_405,
       SUM(CASE WHEN is_remit=1 AND remit_amt>0 THEN 1 ELSE 0 END) AS funded_n,
       MIN(latest_credit_time) AS min_credit_time,
       MAX(latest_credit_time) AS max_credit_time FROM scored WHERE is_target=1 GROUP BY loan_day,
       credit_month
UNION ALL
SELECT 'reference'::text AS kind,
       NULL::int AS loan_day,
       model,
       credit_month,
       score,
       COUNT(*) AS n,
       NULL::bigint AS distinct_orders,
       NULL::bigint AS missing_credit,
       NULL::bigint AS user_conflicts,
       NULL::bigint AS score_conflicts_410,
       NULL::bigint AS score_conflicts_363,
       NULL::bigint AS score_conflicts_405,
       NULL::bigint AS valid_410,
       NULL::bigint AS valid_363,
       NULL::bigint AS valid_405,
       NULL::bigint AS funded_n,
       NULL::timestamp AS min_credit_time,
       NULL::timestamp AS max_credit_time FROM model_long GROUP BY model,
       credit_month,
       score
UNION ALL
SELECT 'target'::text AS kind,
       loan_day,
       model,
       credit_month,
       score,
       COUNT(*) AS n,
       NULL::bigint AS distinct_orders,
       NULL::bigint AS missing_credit,
       NULL::bigint AS user_conflicts,
       NULL::bigint AS score_conflicts_410,
       NULL::bigint AS score_conflicts_363,
       NULL::bigint AS score_conflicts_405,
       NULL::bigint AS valid_410,
       NULL::bigint AS valid_363,
       NULL::bigint AS valid_405,
       NULL::bigint AS funded_n,
       NULL::timestamp AS min_credit_time,
       NULL::timestamp AS max_credit_time FROM model_long WHERE is_target=1 GROUP BY loan_day,
       model,
       credit_month,
       score;
