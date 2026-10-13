-- 网页附录：复现全部组合、产品、月度、偏好和属性图表。
-- 6月无双产品时无分组，展示时补0事件；比例为NULL。
-- 固定事件和到期日期；repaid_amt和逾期状态始终取执行时快照，不能恢复过去状态。
-- 双产品T0原获额订单当天选择及到期贷后；仅查询，不创建或修改业务表。
-- 事件2026-01-01—2026-10-12；整笔due_date<=2026-10-12；贷后为执行时当前快照。
-- 按T0月份、组合、实际选择A/B分组；合计重新汇总金额，不平均比率。
-- 盈利率=(SUM(order.repaid_amt)-SUM(order.remit_amt))/SUM(order.remit_amt)。
-- 金额逾期率=SUM(status_period=8的remit_amt_period)/SUM(到期整笔remit_amt)。
SET TIME ZONE 'America/Belize';
SET query_dop=1;
WITH params AS (
    SELECT DATE '2026-01-01' AS base_start_date,
           DATE '2026-01-01' AS output_start_date,
           DATE '2026-10-13' AS output_end_date,
           TIMESTAMP '2026-10-13 00:00:00' AS data_cutoff_ts
), raw_pass_offer AS (
    SELECT v.user_id, v.serial_id, v.vir_date::date AS vir_date,
           v.vir_unix, v.risk_product::text AS risk_product,
           TO_TIMESTAMP(v.vir_unix) AT TIME ZONE 'America/Belize' AS vir_time
    FROM wangchuanliang.order_vir_f_copy v CROSS JOIN params p
    WHERE v.is_pass1 = 1 AND v.loan_type_code = 2 AND v.vir_unix > 0
      AND v.vir_date >= p.base_start_date - 1
      AND v.vir_date < p.data_cutoff_ts::date + 1
      AND TO_TIMESTAMP(v.vir_unix) AT TIME ZONE 'America/Belize' < p.data_cutoff_ts
), qualified_offer AS (
    SELECT v.* FROM raw_pass_offer v
    WHERE EXISTS (
        SELECT 1 FROM wangchuanliang.side_recycle_type_copy r
        WHERE r.serial_id = v.serial_id AND r.recycle_type = 3
    )
), serial_latest AS (
    SELECT DISTINCT ON (user_id, serial_id) * FROM qualified_offer
    ORDER BY user_id, serial_id, vir_unix DESC
), lagged AS (
    SELECT v.*, LAG(vir_time) OVER (
        PARTITION BY user_id ORDER BY vir_time, serial_id
    ) AS previous_time
    FROM serial_latest v
), batched AS (
    SELECT v.*, SUM(CASE WHEN previous_time IS NULL
                              OR vir_time - previous_time > INTERVAL '20 seconds'
                        THEN 1 ELSE 0 END) OVER (
        PARTITION BY user_id ORDER BY vir_time, serial_id ROWS UNBOUNDED PRECEDING
    ) AS batch_id
    FROM lagged v
), batch_ranked AS (
    SELECT v.*, ROW_NUMBER() OVER (
        PARTITION BY user_id, batch_id ORDER BY vir_time DESC, serial_id DESC
    ) AS batch_rn
    FROM batched v
), dedup_offer AS (
    SELECT v.* FROM batch_ranked v CROSS JOIN params p
    WHERE batch_rn = 1 AND vir_date >= p.base_start_date
), candidate_users AS (
    SELECT DISTINCT user_id FROM dedup_offer
), funded_orders AS (
    SELECT DISTINCT ON (o.user_id, o.serial_id)
           o.user_id, o.serial_id, o.apply_time, o.remit_time,
           o.remit_amt, o.is_remit, o.repaid_time, o.repaid_date,
           o.is_repaid, o.loan_status_code
    FROM wangchuanliang.order_loan_f_v2_copy o
    JOIN candidate_users u ON u.user_id = o.user_id
    WHERE o.is_remit = 1 AND o.remit_amt > 0
    ORDER BY o.user_id, o.serial_id, o.apply_time ASC NULLS LAST
), clean_settlement AS (
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
), settlement_matched AS (
    SELECT e.*, s.serial_id AS settled_serial_id, s.repaid_time,
           ROW_NUMBER() OVER (
               PARTITION BY e.user_id, e.serial_id
               ORDER BY s.repaid_time DESC, s.serial_id DESC
           ) AS settlement_rn
    FROM dedup_offer e JOIN clean_settlement s
      ON s.user_id = e.user_id AND s.repaid_date = e.vir_date
     AND s.repaid_time <= e.vir_time
), strict_t0_all AS (
    SELECT e.*, LEAD(vir_time) OVER (
        PARTITION BY user_id ORDER BY vir_time, serial_id
    ) AS next_t0_time
    FROM settlement_matched e WHERE settlement_rn = 1
), cohort AS (
    SELECT e.*, p.data_cutoff_ts FROM strict_t0_all e CROSS JOIN params p
    WHERE e.vir_date >= p.output_start_date AND e.vir_date < p.output_end_date

), product_tokens AS (
    /* 英文逗号拆分；空格和空项不作为产品编号。 */
    SELECT user_id, serial_id,
           BTRIM(regexp_split_to_table(COALESCE(risk_product, ''), ',')) AS product_no
    FROM cohort
), product_counts AS (
    SELECT user_id, serial_id,
           COUNT(CASE WHEN product_no <> '' THEN 1 END)::integer AS product_count,
           COUNT(DISTINCT CASE WHEN product_no <> '' THEN product_no END)::integer AS unique_product_count,
           COUNT(CASE WHEN product_no = '' THEN 1 END)::integer AS empty_token_count
    FROM product_tokens GROUP BY user_id, serial_id
), event_products AS (
    SELECT e.*, DATE_TRUNC('month', e.vir_date)::date AS t0_month,
           COALESCE(c.product_count, 0) AS product_count,
           COALESCE(c.unique_product_count, 0) AS unique_product_count,
           COALESCE(c.empty_token_count, 0) AS empty_token_count
    FROM cohort e LEFT JOIN product_counts c
      ON c.user_id = e.user_id AND c.serial_id = e.serial_id

), catalog AS (
    /* 当前可用产品信息表。字段逐一映射，不把不同产品的极值拼成一个产品。 */
    SELECT BTRIM(product_no) AS product_no, loan_term::numeric AS total_term,
           CASE WHEN BTRIM(days) ~ '^[0-9]+([.][0-9]+)?$'
                THEN BTRIM(days)::numeric END AS loan_day,
           daily_fee::numeric AS daily_rate, total_fee::numeric AS fee_rate
    FROM wangchuanliang.product_info_copy
), ranked_tokens AS (
    SELECT t.*, ROW_NUMBER() OVER (
        PARTITION BY user_id, serial_id ORDER BY product_no
    ) AS option_rank
    FROM product_tokens t WHERE product_no <> ''
), option_info AS (
    SELECT t.user_id,t.serial_id,
           SUM(CASE WHEN c.product_no IS NOT NULL THEN 1 ELSE 0 END)::integer AS matched_option_n,
           MAX(CASE WHEN t.option_rank=1 THEN t.product_no END) AS a_product,
           MAX(CASE WHEN t.option_rank=2 THEN t.product_no END) AS b_product,
           MAX(CASE WHEN t.option_rank=1 THEN c.total_term END) AS a_term,
           MAX(CASE WHEN t.option_rank=2 THEN c.total_term END) AS b_term,
           MAX(CASE WHEN t.option_rank=1 THEN c.loan_day END) AS a_days,
           MAX(CASE WHEN t.option_rank=2 THEN c.loan_day END) AS b_days,
           MAX(CASE WHEN t.option_rank=1 THEN c.daily_rate END) AS a_daily,
           MAX(CASE WHEN t.option_rank=2 THEN c.daily_rate END) AS b_daily,
           MAX(CASE WHEN t.option_rank=1 THEN c.fee_rate END) AS a_fee,
           MAX(CASE WHEN t.option_rank=2 THEN c.fee_rate END) AS b_fee
    FROM ranked_tokens t LEFT JOIN catalog c ON c.product_no=t.product_no
    GROUP BY t.user_id,t.serial_id
), raw_applications AS (
    SELECT o.user_id,o.serial_id,o.apply_time,
           NULLIF(BTRIM(o.product_no),'') AS selected_product,
           o.is_remit,o.remit_amt,o.repaid_amt,o.due_date,o.loan_status_code
    FROM wangchuanliang.order_loan_f_v2_copy o
    JOIN candidate_users u ON u.user_id=o.user_id CROSS JOIN params p
    WHERE o.apply_time>=p.output_start_date::timestamp
      AND o.apply_time<p.data_cutoff_ts
), applications AS (
    SELECT DISTINCT ON (user_id,serial_id) * FROM raw_applications
    ORDER BY user_id,serial_id,apply_time ASC,selected_product ASC NULLS LAST
), product_conflicts AS (
    /* 同一订单最早提单时点出现多个不同产品，不能任取一个作为选择。 */
    SELECT a.user_id,a.serial_id,COUNT(DISTINCT r.selected_product)::integer AS first_product_n
    FROM applications a JOIN raw_applications r
      ON r.user_id=a.user_id AND r.serial_id=a.serial_id AND r.apply_time=a.apply_time
    GROUP BY a.user_id,a.serial_id
), exact_matches AS (
    SELECT e.user_id,e.serial_id,a.apply_time,a.selected_product,c.first_product_n,
           a.is_remit,a.remit_amt,a.repaid_amt,a.due_date,a.loan_status_code
    FROM event_products e JOIN applications a
      ON a.user_id=e.user_id AND a.serial_id=e.serial_id
     AND a.apply_time>=e.vir_time AND a.apply_time<e.vir_date+INTERVAL '1 day'
    LEFT JOIN product_conflicts c ON c.user_id=a.user_id AND c.serial_id=a.serial_id
), first_user_candidates AS (
    SELECT e.user_id,e.serial_id,a.serial_id AS user_first_serial,
           ROW_NUMBER() OVER (PARTITION BY e.user_id,e.serial_id
               ORDER BY a.apply_time ASC NULLS LAST,a.serial_id ASC NULLS LAST) AS rn
    FROM event_products e LEFT JOIN applications a
      ON a.user_id=e.user_id AND a.apply_time>=e.vir_time
     AND a.apply_time<e.vir_date+INTERVAL '1 day'
     AND (e.next_t0_time IS NULL OR a.apply_time<e.next_t0_time)
), labeled AS (
    SELECT e.*,i.matched_option_n,i.a_product,i.b_product,
           i.a_term,i.b_term,i.a_days,i.b_days,i.a_daily,i.b_daily,i.a_fee,i.b_fee,
           x.apply_time,x.selected_product,x.first_product_n,
           x.is_remit,x.remit_amt,x.repaid_amt,x.due_date,x.loan_status_code,
           u.user_first_serial,
           CASE WHEN x.apply_time IS NULL THEN '当天未按原订单提单'
                WHEN e.product_count NOT IN (1,2) THEN '非单产品或双产品'
                WHEN e.product_count<>e.unique_product_count THEN '获额产品编号重复'
                WHEN COALESCE(x.first_product_n,0)>1 THEN '最早提单产品冲突'
                WHEN x.selected_product IS NULL THEN '提单产品编号缺失'
                WHEN x.selected_product<>i.a_product
                 AND (i.b_product IS NULL OR x.selected_product<>i.b_product)
                  THEN '提单产品不在获额选项'
                WHEN COALESCE(i.matched_option_n,0)<>e.product_count THEN '获额产品信息未完整匹配'
                WHEN i.a_term IS NULL OR i.a_term<=0 OR i.a_days IS NULL OR i.a_days<=0
                  OR i.a_daily IS NULL OR i.a_daily<0 OR i.a_fee IS NULL OR i.a_fee<0
                  OR (e.product_count=2 AND (i.b_term IS NULL OR i.b_term<=0 OR i.b_days IS NULL
                      OR i.b_days<=0 OR i.b_daily IS NULL OR i.b_daily<0 OR i.b_fee IS NULL OR i.b_fee<0))
                  THEN '产品条件缺失或无效'
                ELSE '可分析当天选择' END AS match_status
    FROM event_products e LEFT JOIN option_info i
      ON i.user_id=e.user_id AND i.serial_id=e.serial_id
    LEFT JOIN exact_matches x ON x.user_id=e.user_id AND x.serial_id=e.serial_id
    LEFT JOIN first_user_candidates u ON u.user_id=e.user_id AND u.serial_id=e.serial_id AND u.rn=1

), loan_dates AS (
    SELECT DATE '2026-10-12' AS end_due_date
), dual AS (
    /* Do not restrict to funded, mature, selected or matched products here. */
    SELECT l.*,
           CASE WHEN apply_time IS NOT NULL AND is_remit=1 AND remit_amt>0
                THEN 1 ELSE 0 END AS funded_flag,
           CASE WHEN apply_time IS NOT NULL AND is_remit=1 AND remit_amt>0
                     AND due_date>DATE '2000-01-01' AND due_date<=d.end_due_date
                THEN 1 ELSE 0 END AS due_flag,
           CASE WHEN match_status='可分析当天选择' AND selected_product=a_product THEN 'A'
                WHEN match_status='可分析当天选择' AND selected_product=b_product THEN 'B'
                WHEN apply_time IS NOT NULL THEN '无法识别选择'
                ELSE '当天未提单' END AS chosen_side
    FROM labeled l CROSS JOIN loan_dates d WHERE product_count=2
), financial_source_quality AS (
    /* A repeated source order cannot silently select a different financial row. */
    SELECT r.user_id,r.serial_id,COUNT(*)-1 AS financial_repeat_rows
    FROM raw_applications r JOIN dual e
      ON r.user_id=e.user_id AND r.serial_id=e.serial_id
    WHERE e.apply_time IS NOT NULL
    GROUP BY r.user_id,r.serial_id
), period_raw AS (
    /* Only periods under the very same mature funded D0 orders participate. */
    SELECT p.user_id,p.serial_id,p.current_term,
           p.remit_amt_period,p.loan_status_code_period
    FROM wangchuanliang.repayment_plan_v2_copy p
    JOIN dual e ON p.serial_id=e.serial_id AND p.user_id=e.user_id
    WHERE e.due_flag=1
), period_terms AS (
    /* One row per order+term. Identical duplicates are exposed; conflicts fail QA. */
    SELECT user_id,serial_id,current_term,COUNT(*) AS source_rows,
           MAX(remit_amt_period) AS remit_amt_period,
           MAX(loan_status_code_period) AS loan_status_code_period,
           CASE WHEN COUNT(DISTINCT remit_amt_period)>1
                     OR COUNT(DISTINCT loan_status_code_period)>1
                THEN 1 ELSE 0 END AS conflict_flag,
           CASE WHEN COUNT(remit_amt_period)<>COUNT(*) THEN 1 ELSE 0 END AS amount_null_flag,
           CASE WHEN COUNT(loan_status_code_period)<>COUNT(*) THEN 1 ELSE 0 END AS status_null_flag
    FROM period_raw GROUP BY user_id,serial_id,current_term
), period_orders AS (
    SELECT user_id,serial_id,COUNT(*) AS period_n,
           SUM(remit_amt_period) AS plan_remit_amt,
           SUM(CASE WHEN loan_status_code_period=8 THEN remit_amt_period ELSE 0 END)
             AS overdue_period_remit_amt,
           SUM(source_rows-1) AS repeated_period_rows,
           SUM(conflict_flag) AS conflicting_terms,
           SUM(amount_null_flag) AS null_amount_terms,
           SUM(status_null_flag) AS null_status_terms,
           SUM(CASE WHEN current_term IS NULL THEN 1 ELSE 0 END) AS null_term_n,
           SUM(CASE WHEN remit_amt_period<0 THEN 1 ELSE 0 END) AS negative_amount_terms
    FROM period_terms GROUP BY user_id,serial_id
), observed AS (
    SELECT e.*,p.period_n,p.plan_remit_amt,p.overdue_period_remit_amt,
           p.repeated_period_rows,p.conflicting_terms,p.null_amount_terms,p.null_status_terms,
           p.null_term_n,p.negative_amount_terms,COALESCE(q.financial_repeat_rows,0) AS financial_repeat_rows
    FROM dual e LEFT JOIN period_orders p
      ON p.user_id=e.user_id AND p.serial_id=e.serial_id
    LEFT JOIN financial_source_quality q ON q.user_id=e.user_id AND q.serial_id=e.serial_id

), aggregates AS (
    SELECT CASE WHEN GROUPING(t0_month)=1 THEN '合计'
                ELSE TO_CHAR(t0_month,'YYYY-MM') END AS month,
           a_product,b_product,a_term,b_term,a_days,b_days,a_daily,b_daily,a_fee,b_fee,
           CASE WHEN GROUPING(chosen_side)=1 THEN '组合合计' ELSE chosen_side END AS choice_side,
           COUNT(*)::bigint AS slice_event_n,
           SUM(CASE WHEN apply_time IS NOT NULL THEN 1 ELSE 0 END)::bigint AS d0_n,
           SUM(CASE WHEN match_status='可分析当天选择' THEN 1 ELSE 0 END)::bigint AS choice_n,
           SUM(funded_flag)::bigint AS funded_n,
           SUM(due_flag)::bigint AS due_funded_n,
           SUM(CASE WHEN due_flag=1 AND loan_status_code=8 THEN 1 ELSE 0 END)::bigint AS overdue_order_n,
           SUM(CASE WHEN due_flag=1 THEN remit_amt ELSE 0 END) AS remit_amt,
           SUM(CASE WHEN due_flag=1 THEN repaid_amt ELSE 0 END) AS book_repaid_amt,
           SUM(CASE WHEN due_flag=1 THEN repaid_amt-remit_amt ELSE 0 END) AS book_profit_amt,
           SUM(CASE WHEN due_flag=1 THEN overdue_period_remit_amt ELSE 0 END) AS overdue_period_remit_amt,
           SUM(CASE WHEN due_flag=1 THEN plan_remit_amt ELSE 0 END) AS plan_remit_amt,
           SUM(CASE WHEN due_flag=1 AND repaid_amt IS NULL THEN 1 ELSE 0 END)::bigint AS missing_book_repaid_n,
           SUM(CASE WHEN due_flag=1 AND loan_status_code IS NULL THEN 1 ELSE 0 END)::bigint AS missing_order_status_n,
           SUM(CASE WHEN due_flag=1 AND period_n IS NULL THEN 1 ELSE 0 END)::bigint AS missing_plan_order_n,
           SUM(CASE WHEN due_flag=1 AND conflicting_terms>0 THEN 1 ELSE 0 END)::bigint AS conflicting_plan_order_n,
           SUM(CASE WHEN due_flag=1 AND (null_amount_terms>0 OR negative_amount_terms>0)
                    THEN 1 ELSE 0 END)::bigint AS bad_period_amount_order_n,
           SUM(CASE WHEN due_flag=1 AND (null_status_terms>0 OR null_term_n>0)
                    THEN 1 ELSE 0 END)::bigint AS bad_period_status_order_n,
           SUM(CASE WHEN due_flag=1 AND ABS(plan_remit_amt-remit_amt)>0.01 THEN 1 ELSE 0 END)::bigint
             AS period_principal_mismatch_n,
           SUM(CASE WHEN due_flag=1 THEN COALESCE(repeated_period_rows,0) ELSE 0 END)::bigint
             AS repeated_period_rows,
           SUM(financial_repeat_rows)::bigint AS financial_repeat_rows,
           SUM(CASE WHEN funded_flag=1 AND (due_date IS NULL OR due_date<=DATE '2000-01-01')
                    THEN 1 ELSE 0 END)::bigint AS invalid_funded_due_date_n,
           SUM(CASE WHEN product_count<>unique_product_count THEN 1 ELSE 0 END)::bigint AS duplicate_option_n,
           SUM(CASE WHEN apply_time IS NOT NULL AND match_status<>'可分析当天选择' THEN 1 ELSE 0 END)::bigint
             AS unidentifiable_d0_n,
           SUM(CASE WHEN user_first_serial IS NOT NULL AND user_first_serial<>serial_id THEN 1 ELSE 0 END)::bigint
             AS changed_serial_n
    FROM observed
    GROUP BY GROUPING SETS (
      (t0_month,a_product,b_product,a_term,b_term,a_days,b_days,a_daily,b_daily,a_fee,b_fee),
      (a_product,b_product,a_term,b_term,a_days,b_days,a_daily,b_daily,a_fee,b_fee),
      (t0_month,a_product,b_product,a_term,b_term,a_days,b_days,a_daily,b_daily,a_fee,b_fee,chosen_side),
      (a_product,b_product,a_term,b_term,a_days,b_days,a_daily,b_daily,a_fee,b_fee,chosen_side)
    )
), reports AS (
    SELECT a.*,c.slice_event_n AS combo_t0_n,c.d0_n AS combo_d0_n,c.choice_n AS combo_choice_n,
           1.0*c.d0_n/NULLIF(c.slice_event_n,0) AS combo_d0_rate,
           1.0*a.choice_n/NULLIF(c.choice_n,0) AS choice_share,
           CASE WHEN a.missing_book_repaid_n=0
                THEN a.book_profit_amt/NULLIF(a.remit_amt,0) END AS profit_rate,
           CASE WHEN a.missing_order_status_n=0
                THEN 1.0*a.overdue_order_n/NULLIF(a.due_funded_n,0) END AS overdue_order_rate,
           CASE WHEN a.missing_plan_order_n+a.conflicting_plan_order_n+a.bad_period_amount_order_n
                       +a.bad_period_status_order_n=0
                THEN a.overdue_period_remit_amt/NULLIF(a.remit_amt,0) END AS overdue_amount_rate
    FROM aggregates a JOIN aggregates c ON c.month=a.month
      AND c.a_product IS NOT DISTINCT FROM a.a_product
      AND c.b_product IS NOT DISTINCT FROM a.b_product
      AND c.choice_side='组合合计'
    WHERE a.choice_side IN ('组合合计','A','B','无法识别选择')
)
, monthly_rollup AS (
    SELECT month,SUM(slice_event_n) AS t0_n,SUM(d0_n) AS d0_n,SUM(funded_n) AS funded_n,
           SUM(due_funded_n) AS due_n,SUM(remit_amt) AS remit_amt,SUM(book_repaid_amt) AS repaid_amt,
           SUM(book_profit_amt) AS profit_amt,SUM(overdue_order_n) AS overdue_n,
           SUM(overdue_period_remit_amt) AS overdue_period_amt,
           1.0*SUM(d0_n)/NULLIF(SUM(slice_event_n),0) AS d0_rate,
           1.0*SUM(due_funded_n)/NULLIF(SUM(funded_n),0) AS due_coverage,
           SUM(book_profit_amt)/NULLIF(SUM(remit_amt),0) AS profit_rate,
           1.0*SUM(overdue_order_n)/NULLIF(SUM(due_funded_n),0) AS order_overdue_rate,
           SUM(overdue_period_remit_amt)/NULLIF(SUM(remit_amt),0) AS amount_overdue_rate
    FROM reports WHERE choice_side='组合合计' GROUP BY month
), selected_properties AS (
    SELECT month,SUM(choice_n) AS choice_n,
           SUM(choice_n*CASE WHEN choice_side='A' THEN a_days ELSE b_days END)/NULLIF(SUM(choice_n),0) AS avg_days,
           SUM(choice_n*CASE WHEN choice_side='A' THEN a_term ELSE b_term END)/NULLIF(SUM(choice_n),0) AS avg_terms,
           SUM(choice_n*CASE WHEN choice_side='A' THEN a_daily ELSE b_daily END)/NULLIF(SUM(choice_n),0) AS avg_daily,
           SUM(choice_n*CASE WHEN choice_side='A' THEN a_fee ELSE b_fee END)/NULLIF(SUM(choice_n),0) AS avg_fee
    FROM reports WHERE choice_side IN ('A','B') GROUP BY month
), compared_choices AS (
    SELECT month,choice_n,
           CASE WHEN choice_side='A' THEN a_days-b_days ELSE b_days-a_days END AS days_delta,
           CASE WHEN choice_side='A' THEN a_term-b_term ELSE b_term-a_term END AS term_delta,
           CASE WHEN choice_side='A' THEN a_daily-b_daily ELSE b_daily-a_daily END AS daily_delta,
           CASE WHEN choice_side='A' THEN a_fee-b_fee ELSE b_fee-a_fee END AS fee_delta,
           CASE WHEN (a_daily<b_daily AND a_days>b_days) OR (b_daily<a_daily AND b_days>a_days)
                THEN 1 ELSE 0 END AS low_daily_longer,
           CASE WHEN choice_side='A' THEN a_product ELSE b_product END AS selected_product
    FROM reports WHERE choice_side IN ('A','B')
), preference_rollup AS (
    SELECT month,SUM(choice_n) AS choice_n,
           SUM(CASE WHEN days_delta>0 THEN choice_n ELSE 0 END) AS longer_n,
           SUM(CASE WHEN fee_delta>0 THEN choice_n ELSE 0 END) AS higher_fee_n,
           SUM(CASE WHEN days_delta>0 AND fee_delta>0 THEN choice_n ELSE 0 END) AS longer_higher_fee_n,
           SUM(CASE WHEN daily_delta=0 THEN choice_n ELSE 0 END) AS same_daily_n,
           SUM(CASE WHEN daily_delta=0 AND days_delta>0 THEN choice_n ELSE 0 END) AS same_daily_longer_n,
           SUM(CASE WHEN daily_delta<>0 THEN choice_n ELSE 0 END) AS different_daily_n,
           SUM(CASE WHEN daily_delta<0 THEN choice_n ELSE 0 END) AS lower_daily_n,
           SUM(CASE WHEN daily_delta<>0 AND low_daily_longer=1 THEN choice_n ELSE 0 END) AS lower_daily_also_longer_n,
           SUM(CASE WHEN term_delta=0 THEN choice_n ELSE 0 END) AS same_term_n
    FROM compared_choices GROUP BY month
), actual_product_mix AS (
    SELECT month,selected_product,SUM(choice_n) AS choice_n
    FROM compared_choices GROUP BY month,selected_product
), phase_rows AS (
    SELECT CASE WHEN month BETWEEN '2026-01' AND '2026-05' THEN '1-5月'
                WHEN month BETWEEN '2026-08' AND '2026-09' THEN '8-9月' END AS phase,r.*
    FROM reports r WHERE month<>'合计'
), phase_summary AS (
    SELECT phase,SUM(slice_event_n) AS t0_n,SUM(d0_n) AS d0_n,
           1.0*SUM(d0_n)/NULLIF(SUM(slice_event_n),0) AS d0_rate
    FROM phase_rows WHERE phase IS NOT NULL AND choice_side='组合合计' GROUP BY phase
), phase_selected_properties AS (
    SELECT phase,SUM(choice_n) AS choice_n,
           SUM(choice_n*CASE WHEN choice_side='A' THEN a_days ELSE b_days END)/NULLIF(SUM(choice_n),0) AS avg_days,
           SUM(choice_n*CASE WHEN choice_side='A' THEN a_daily ELSE b_daily END)/NULLIF(SUM(choice_n),0) AS avg_daily,
           SUM(choice_n*CASE WHEN choice_side='A' THEN a_fee ELSE b_fee END)/NULLIF(SUM(choice_n),0) AS avg_fee
    FROM phase_rows WHERE phase IS NOT NULL AND choice_side IN ('A','B') GROUP BY phase
)
SELECT '组合及产品月度与合计'::text AS result_kind,ROW_TO_JSON(t)::text AS result_payload FROM reports t
UNION ALL SELECT '月度及全期汇总',ROW_TO_JSON(t)::text FROM monthly_rollup t
UNION ALL SELECT '所选产品事件加权属性',ROW_TO_JSON(t)::text FROM selected_properties t
UNION ALL SELECT '选择偏好计数',ROW_TO_JSON(t)::text FROM preference_rollup t
UNION ALL SELECT '实际提单产品份额计数',ROW_TO_JSON(t)::text FROM actual_product_mix t
UNION ALL SELECT '完整月份阶段提单',ROW_TO_JSON(t)::text FROM phase_summary t
UNION ALL SELECT '完整月份阶段产品属性',ROW_TO_JSON(t)::text FROM phase_selected_properties t;
