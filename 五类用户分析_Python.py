#!/usr/bin/env python3
"""
五类用户盈利能力分析 -- Python 数据提取脚本
输出: 五类用户按放款序列拆分的订单数/放款额/利润
数据源: wangchuanliang.order_loan_f_v2_copy (订单主表)
        wangchuanliang.side_recycle_type_copy (循环贷标签)
"""
import psycopg2

DB = {
    "host": "47.89.225.85",
    "port": "8000",
    "dbname": "kaby_dw",
    "user": "wangchuanliang_readonly",
    "password": "gMOZQxb3spunr",
}

def main():
    conn = psycopg2.connect(**DB)
    cur = conn.cursor()

    # === 查询: 用户分类 + 放款序列 + 订单级利润 ===
    cur.execute("""
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
    loan_seq AS (
        SELECT
            o.user_id, ut.utype,
            o.remit_amt, o.repaid_amt, o.apply_amt,
            o.overdue_days, o.loan_status_code,
            ROW_NUMBER() OVER (PARTITION BY o.user_id ORDER BY o.apply_time) AS seq
        FROM wangchuanliang.order_loan_f_v2_copy o
        JOIN user_type ut ON o.user_id = ut.user_id
        WHERE o.is_remit = 1
          AND o.reg_date >= '2025-01-01' AND o.reg_date <= '2026-05-31'
    )
    SELECT
        CASE WHEN utype IN ('等放','迁移') THEN '原生等放' ELSE '原生非等放' END AS big_type,
        utype,
        CASE WHEN seq = 1 THEN '首贷' WHEN seq = 2 THEN '第2次' WHEN seq = 3 THEN '第3次' ELSE '第4次+' END AS stage,
        COUNT(*)                                                    AS n_orders,
        SUM(remit_amt)                                              AS total_remit,
        COALESCE(SUM(CASE WHEN loan_status_code IN (7,8) THEN remit_amt END), 0) AS end_remit,
        COALESCE(SUM(CASE WHEN loan_status_code IN (7,8) THEN repaid_amt END), 0) AS end_repaid,
        SUM(CASE WHEN overdue_days > 0 THEN 1 ELSE 0 END)           AS od_orders,
        SUM(CASE WHEN loan_status_code = 8 THEN 1 ELSE 0 END)       AS s8_orders
    FROM loan_seq
    GROUP BY big_type, utype, stage
    ORDER BY big_type, utype, stage
    """)

    # === 整理结果 ===
    results = {}
    for row in cur.fetchall():
        big_type, utype, stage, n_orders, total_remit, end_remit, end_repaid, od, s8 = row
        profit = float(end_repaid or 0) - float(end_remit or 0)
        key = (big_type, utype)
        if key not in results:
            results[key] = {}
        results[key][stage] = {
            'n_orders': n_orders,
            'total_remit': float(total_remit or 0),
            'profit': profit,
            'profit_pct': round(profit / float(end_remit or 1) * 100, 1),
            's8_pct': round(float(s8 or 0) / n_orders * 100, 1) if n_orders > 0 else 0,
        }

    # === 聚合五类指标 ===
    CATEGORIES = {
        '原生等放':   {'等放', '迁移'},
        '非等放':     {'迁移', '原生非等放'},
        '等放':       {'等放'},
        '迁移':       {'迁移'},
        '原生非等放': {'原生非等放'},
    }

    for cat_name, sub_types in CATEGORIES.items():
        total_orders, total_remit, total_profit = 0, 0, 0
        for (bt, ut), stages_data in results.items():
            if ut in sub_types:
                for stage, d in stages_data.items():
                    total_orders += d['n_orders']
                    total_remit += d['total_remit']
                    total_profit += d['profit']
        print(
            f"{cat_name}: 订单={total_orders:,}, "
            f"放款={total_remit:,.0f}, "
            f"利润={total_profit:,.0f}, "
            f"盈利率={total_profit/total_remit*100:.1f}%"
        )

    cur.close()
    conn.close()


if __name__ == '__main__':
    main()
