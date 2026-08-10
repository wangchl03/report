-- ============================================================================
-- 五类用户盈利能力分析 -- 完整 PGSQL 查询
-- 数据源: wangchuanliang.order_loan_f_v2_copy
-- 关联表: wangchuanliang.side_recycle_type_copy (循环贷标签)
-- 范围: 2025.01 ~ 2026.05 注册用户, 全量
-- ============================================================================

-- 第1步: 用户分类 (等放 / 迁移 / 原生非等放)
-- 原生等放 = 等放 + 迁移, 非等放 = 迁移 + 原生非等放
WITH user_type AS (
    SELECT user_id,
        CASE 
            WHEN MIN(CASE WHEN is_remit = 0 THEN apply_time END) IS NULL 
                THEN '等放'
            WHEN MIN(CASE WHEN is_remit = 1 THEN apply_time END)
               < MIN(CASE WHEN is_remit = 0 THEN apply_time END) 
                THEN '迁移'
            ELSE '原生非等放'
        END AS utype
    FROM wangchuanliang.order_loan_f_v2_copy
    WHERE reg_date >= '2025-01-01' AND reg_date <= '2026-05-31'
    GROUP BY user_id
    HAVING SUM(CASE WHEN is_remit = 1 THEN 1 ELSE 0 END) > 0
),

-- 第2步: 放款序列编号 (按 apply_time 升序)
loan_seq AS (
    SELECT 
        o.user_id,
        ut.utype,
        CASE WHEN ut.utype IN ('等放','迁移') THEN '原生等放' ELSE '原生非等放' END AS big_type,
        o.serial_id, o.remit_amt, o.repaid_amt, o.apply_amt,
        o.overdue_days, o.loan_status_code, o.loan_day,
        ROW_NUMBER() OVER (PARTITION BY o.user_id ORDER BY o.apply_time) AS seq
    FROM wangchuanliang.order_loan_f_v2_copy o
    JOIN user_type ut ON o.user_id = ut.user_id
    WHERE o.is_remit = 1
      AND o.reg_date >= '2025-01-01' AND o.reg_date <= '2026-05-31'
),

-- 第3步: 订单级聚合 (按大类型 + 子类型 + 阶段)
seq_agg AS (
    SELECT 
        big_type, utype,
        CASE WHEN seq = 1 THEN '首贷'
             WHEN seq = 2 THEN '第2次放款'
             WHEN seq = 3 THEN '第3次放款'
             ELSE '第4次+放款' END AS stage,
        COUNT(*)                                                    AS n_orders,
        COUNT(DISTINCT user_id)                                     AS n_users,
        SUM(CASE WHEN overdue_days > 0 THEN 1 ELSE 0 END)           AS od_orders,
        SUM(CASE WHEN loan_status_code = 8 THEN 1 ELSE 0 END)       AS s8_orders,
        SUM(CASE WHEN loan_status_code = 7 THEN 1 ELSE 0 END)       AS s7_orders,
        SUM(CASE WHEN loan_status_code = 5 THEN 1 ELSE 0 END)       AS s5_orders,
        COALESCE(SUM(CASE WHEN loan_status_code IN (7,8) THEN remit_amt END), 0) AS end_remit,
        COALESCE(SUM(CASE WHEN loan_status_code IN (7,8) THEN repaid_amt END), 0) AS end_repaid,
        COALESCE(SUM(CASE WHEN loan_status_code = 8 THEN remit_amt END), 0)       AS s8_remit,
        COALESCE(SUM(CASE WHEN loan_status_code = 8 THEN repaid_amt END), 0)      AS s8_repaid,
        SUM(remit_amt)                                              AS total_remit,
        SUM(apply_amt)                                              AS total_apply,
        ROUND(AVG(remit_amt))                                       AS avg_remit,
        ROUND(AVG(loan_day))                                        AS avg_loan_day
    FROM loan_seq
    GROUP BY big_type, utype, stage
)

-- 第4步: 输出
SELECT 
    big_type   AS "大类",
    utype      AS "子类",
    stage      AS "阶段",
    n_orders   AS "订单数",
    n_users    AS "用户数",
    ROUND(od_orders::numeric / NULLIF(n_orders,0) * 100, 1)     AS "订单级od>0%",
    ROUND(s8_orders::numeric / NULLIF(n_orders,0) * 100, 1)     AS "订单级s8%",
    ROUND((end_repaid - end_remit) / NULLIF(end_remit,0) * 100, 2) AS "盈利率%",
    ROUND(s8_repaid / NULLIF(s8_remit,0) * 100, 2)               AS "逾期回款率%",
    avg_remit                                                      AS "件均放款额",
    ROUND(total_apply / NULLIF(n_orders,0))                      AS "件均申请额",
    avg_loan_day                                                   AS "平均期限(天)"
FROM seq_agg
ORDER BY big_type, utype, stage;


-- ====================================================================
-- 补充查询: 五类用户 x 循环贷/非循环贷 分阶段指标
-- ====================================================================
WITH user_type AS (
    SELECT user_id,
        CASE 
            WHEN MIN(CASE WHEN is_remit = 0 THEN apply_time END) IS NULL THEN '等放'
            WHEN MIN(CASE WHEN is_remit = 1 THEN apply_time END)
               < MIN(CASE WHEN is_remit = 0 THEN apply_time END) THEN '迁移'
            ELSE '原生非等放'
        END AS utype
    FROM wangchuanliang.order_loan_f_v2_copy
    WHERE reg_date >= '2025-01-01' AND reg_date <= '2026-05-31'
    GROUP BY user_id
    HAVING SUM(CASE WHEN is_remit = 1 THEN 1 ELSE 0 END) > 0
),
loan_seq AS (
    SELECT 
        o.user_id, ut.utype,
        CASE WHEN ut.utype IN ('等放','迁移') THEN '原生等放' ELSE '原生非等放' END AS big_type,
        o.serial_id, o.remit_amt, o.repaid_amt, o.loan_status_code, o.overdue_days,
        ROW_NUMBER() OVER (PARTITION BY o.user_id ORDER BY o.apply_time) AS seq
    FROM wangchuanliang.order_loan_f_v2_copy o
    JOIN user_type ut ON o.user_id = ut.user_id
    WHERE o.is_remit = 1
      AND o.reg_date >= '2025-01-01' AND o.reg_date <= '2026-05-31'
),
recycle_tag AS (
    SELECT serial_id, recycle_type
    FROM wangchuanliang.side_recycle_type_copy
    WHERE recycle_type IN (2, 3)
)
SELECT 
    CASE WHEN utype IN ('等放','迁移') THEN '原生等放' ELSE '原生非等放' END AS big_type,
    utype,
    CASE WHEN seq = 1 THEN '首贷'
         WHEN seq = 2 THEN '第2次'
         WHEN seq = 3 THEN '第3次'
         ELSE '第4次+' END AS stage,
    COALESCE(rt.recycle_type, 0) AS cycle_type,
    COUNT(*)                                                    AS n_orders,
    COUNT(DISTINCT ls.user_id)                                  AS n_users,
    SUM(ls.remit_amt)                                           AS total_remit,
    COALESCE(SUM(CASE WHEN ls.loan_status_code IN (7,8) THEN ls.remit_amt END), 0) AS end_remit,
    COALESCE(SUM(CASE WHEN ls.loan_status_code IN (7,8) THEN ls.repaid_amt END), 0) AS end_repaid,
    SUM(CASE WHEN ls.overdue_days > 0 THEN 1 ELSE 0 END)         AS n_od,
    SUM(CASE WHEN ls.loan_status_code = 8 THEN 1 ELSE 0 END)     AS n_s8
FROM loan_seq ls
LEFT JOIN recycle_tag rt ON ls.serial_id = rt.serial_id
GROUP BY big_type, utype, stage, rt.recycle_type
ORDER BY big_type, utype, stage, rt.recycle_type;


-- ====================================================================
-- 补充查询: 用户维度 -- 单次/多次借款盈利拆解
-- ====================================================================
WITH user_type AS (
    SELECT user_id,
        CASE 
            WHEN MIN(CASE WHEN is_remit = 0 THEN apply_time END) IS NULL THEN '等放'
            WHEN MIN(CASE WHEN is_remit = 1 THEN apply_time END)
               < MIN(CASE WHEN is_remit = 0 THEN apply_time END) THEN '迁移'
            ELSE '原生非等放'
        END AS utype,
        SUM(CASE WHEN is_remit = 1 THEN 1 ELSE 0 END) AS total_loans
    FROM wangchuanliang.order_loan_f_v2_copy
    WHERE reg_date >= '2025-01-01' AND reg_date <= '2026-05-31'
    GROUP BY user_id
    HAVING SUM(CASE WHEN is_remit = 1 THEN 1 ELSE 0 END) > 0
)
SELECT 
    utype,
    COUNT(*)                                                              AS n_users,
    SUM(CASE WHEN total_loans = 1 THEN 1 ELSE 0 END)                      AS single_users,
    SUM(CASE WHEN total_loans >= 2 THEN 1 ELSE 0 END)                     AS multi_users,
    ROUND(SUM(CASE WHEN total_loans = 1 THEN 1 ELSE 0 END) 
          * 100.0 / COUNT(*), 1)                                           AS single_pct,
    ROUND(SUM(CASE WHEN total_loans >= 2 THEN 1 ELSE 0 END) 
          * 100.0 / COUNT(*), 1)                                           AS multi_pct
FROM user_type
GROUP BY utype
ORDER BY utype;
