#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
T7+ 召回看板 · 后端
默认跑 0818 / 0902 / 0910 / 0917 四个批次。

  export PGPASSWORD='...'
  python3 appendix_t7_0818_dashboard.py
  python3 appendix_t7_0818_dashboard.py 0902 0910 0917
"""
from __future__ import annotations

import html as html_lib
import json
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent

BATCHES = [
    {
        "slug": "0818",
        "table": "wangchuanliang.t7recalllist_0818_0819",
        "recall_date": "2026-08-18",
        "filter_recall_date": True,
    },
    {
        "slug": "0902",
        "table": "wangchuanliang.t7recalllist_0902",
        "recall_date": "2026-09-02",
        "filter_recall_date": False,
    },
    {
        "slug": "0910",
        "table": "wangchuanliang.t7recalllist_0910",
        "recall_date": "2026-09-10",
        "filter_recall_date": False,
    },
    {
        "slug": "0917",
        "table": "wangchuanliang.t7recalllist_0917",
        "recall_date": "2026-09-17",
        "filter_recall_date": False,
    },
]


def list_cte(batch) -> str:
    extra = ""
    if batch.get("filter_recall_date"):
        extra = (
            f"\n  AND recall_date = DATE '{batch['recall_date']}'"
            "\n  AND recall_date <> DATE '2026-08-19'"
        )
    return f"""
SELECT DISTINCT churn_user_id::bigint AS user_id,
       COALESCE(strat, 'NA') AS strat,
       churn_days
FROM {batch['table']}
WHERE churn_user_id IS NOT NULL{extra}
"""


def md_label(recall_date: str) -> str:
    _y, m, d = recall_date.split("-")
    return f"{int(m)}/{int(d)}"


def attach_due_cum(due_daily):
    cum_repaid = 0.0
    cum_remit = 0.0
    cum_due = 0
    cum_od = 0
    for r in due_daily:
        n_due = int(r.get("n_due") or 0)
        n_od = int(r.get("n_od") or 0)
        remit = float(r.get("remit") or 0)
        repaid = float(r.get("repaid") or 0)
        r["n_due"] = n_due
        r["n_od"] = n_od
        r["profit_pct"] = round(100.0 * (repaid - remit) / remit, 2) if remit else None
        r["overdue_pct"] = round(100.0 * n_od / n_due, 2) if n_due else None
        cum_repaid += repaid
        cum_remit += remit
        cum_due += n_due
        cum_od += n_od
        r["cum_profit_pct"] = (
            round(100.0 * (cum_repaid - cum_remit) / cum_remit, 2) if cum_remit else None
        )
        r["cum_overdue_pct"] = round(100.0 * cum_od / cum_due, 2) if cum_due else None
    return due_daily


def connect():
    pwd = os.environ.get("PGPASSWORD")
    if not pwd:
        raise SystemExit("请先设置环境变量 PGPASSWORD")
    import psycopg2

    conn = psycopg2.connect(
        host=os.environ.get("PGHOST", "47.89.225.85"),
        port=int(os.environ.get("PGPORT", "8000")),
        dbname=os.environ.get("PGDATABASE", "kaby_dw"),
        user=os.environ.get("PGUSER", "wangchuanliang_readonly"),
        password=pwd,
        connect_timeout=30,
        options="-c statement_timeout=0",
    )
    conn.autocommit = True
    return conn


def rows(cur, sql):
    cur.execute(sql)
    cols = [d[0] for d in cur.description]
    out = []
    for r in cur.fetchall():
        item = {}
        for c, v in zip(cols, r):
            if hasattr(v, "as_tuple"):
                v = float(v)
            elif hasattr(v, "isoformat"):
                v = str(v)
            item[c] = v
        out.append(item)
    return out


def one(cur, sql):
    return rows(cur, sql)[0]


def fetch(batch):
    U = list_cte(batch)
    RECALL_DATE = batch["recall_date"]
    conn = connect()
    cur = conn.cursor()
    cur.execute("SET search_path TO wangchuanliang, public")
    cur.execute(
        """
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'wangchuanliang' AND table_name = 'order_loan_f_v2_copy'
          AND column_name = 'remit_date'
        """
    )
    remit_day = "o.remit_date::date" if cur.fetchone() else "o.apply_date::date"
    print("batch", batch["slug"], "remit day expr", remit_day, flush=True)

    kpi = one(
        cur,
        f"""
        WITH u AS ({U}),
        params AS (
            SELECT DATE '{RECALL_DATE}' AS recall_dt,
                   DATE_TRUNC('week', CURRENT_DATE)::date AS week_start,
                   CURRENT_DATE AS as_of
        ),
        apply_u AS (
            SELECT DISTINCT o.user_id
            FROM u
            INNER JOIN order_loan_f_v2_copy o ON o.user_id = u.user_id
            CROSS JOIN params p
            WHERE o.apply_date >= p.recall_dt
        ),
        first_apply AS (
            SELECT o.user_id, MIN(o.apply_date) AS first_dt
            FROM u
            INNER JOIN order_loan_f_v2_copy o ON o.user_id = u.user_id
            CROSS JOIN params p
            WHERE o.apply_date >= p.recall_dt
            GROUP BY 1
        )
        SELECT
            (SELECT COUNT(*) FROM u) AS n_user,
            (SELECT COUNT(*) FROM apply_u) AS n_apply,
            (SELECT COUNT(DISTINCT o.user_id)
             FROM u
             INNER JOIN order_loan_f_v2_copy o ON o.user_id = u.user_id
             CROSS JOIN params p
             WHERE o.apply_date >= p.week_start AND o.apply_date <= p.as_of) AS n_apply_week,
            (SELECT COUNT(*) FROM first_apply f CROSS JOIN params p
             WHERE f.first_dt >= p.week_start AND f.first_dt <= p.as_of) AS n_first_week,
            (SELECT COUNT(*)
             FROM u
             INNER JOIN order_loan_f_v2_copy o ON o.user_id = u.user_id
             CROSS JOIN params p
             WHERE o.apply_date >= p.recall_dt AND o.is_remit = 1
               AND COALESCE(o.remit_amt, 0) > 0) AS n_remit,
            (SELECT COUNT(*)
             FROM u
             INNER JOIN order_loan_f_v2_copy o ON o.user_id = u.user_id
             CROSS JOIN params p
             WHERE o.apply_date >= p.recall_dt AND o.is_remit = 1
               AND COALESCE(o.remit_amt, 0) > 0
               AND {remit_day} >= p.week_start AND {remit_day} <= p.as_of) AS n_remit_week,
            (SELECT COUNT(*)
             FROM u
             INNER JOIN order_loan_f_v2_copy o ON o.user_id = u.user_id
             CROSS JOIN params p
             WHERE o.apply_date >= p.recall_dt AND o.is_due = 1 AND o.is_remit = 1
               AND COALESCE(o.remit_amt, 0) > 0) AS n_due,
            (SELECT COUNT(*)
             FROM u
             INNER JOIN order_loan_f_v2_copy o ON o.user_id = u.user_id
             CROSS JOIN params p
             WHERE o.apply_date >= p.recall_dt AND o.is_due = 1 AND o.is_remit = 1
               AND COALESCE(o.remit_amt, 0) > 0 AND o.loan_status_code = 8) AS n_due_od,
            (SELECT SUM(COALESCE(o.repaid_amt, 0))
             FROM u
             INNER JOIN order_loan_f_v2_copy o ON o.user_id = u.user_id
             CROSS JOIN params p
             WHERE o.apply_date >= p.recall_dt AND o.is_due = 1 AND o.is_remit = 1
               AND COALESCE(o.remit_amt, 0) > 0) AS due_repaid,
            (SELECT SUM(o.remit_amt)
             FROM u
             INNER JOIN order_loan_f_v2_copy o ON o.user_id = u.user_id
             CROSS JOIN params p
             WHERE o.apply_date >= p.recall_dt AND o.is_due = 1 AND o.is_remit = 1
               AND COALESCE(o.remit_amt, 0) > 0) AS due_remit,
            (SELECT week_start FROM params) AS week_start,
            (SELECT as_of FROM params) AS as_of
        """,
    )

    n_user = int(kpi["n_user"] or 0)
    n_apply = int(kpi["n_apply"] or 0)
    n_due = int(kpi["n_due"] or 0)
    n_due_od = int(kpi["n_due_od"] or 0)
    due_repaid = float(kpi["due_repaid"] or 0)
    due_remit = float(kpi["due_remit"] or 0)
    profit = (due_repaid - due_remit) / due_remit if due_remit else None
    overdue = n_due_od / n_due if n_due else None

    kpi_out = {
        "n_user": n_user,
        "n_apply": n_apply,
        "apply_rate": round(100.0 * n_apply / n_user, 2) if n_user else 0,
        "n_apply_week": int(kpi["n_apply_week"] or 0),
        "n_first_week": int(kpi["n_first_week"] or 0),
        "n_remit": int(kpi["n_remit"] or 0),
        "n_remit_week": int(kpi["n_remit_week"] or 0),
        "n_due": n_due,
        "n_due_od": n_due_od,
        "profit_pct": None if profit is None else round(100.0 * profit, 2),
        "overdue_pct": None if overdue is None else round(100.0 * overdue, 2),
        "week_start": str(kpi["week_start"]),
        "as_of": str(kpi["as_of"]),
        "recall_date": RECALL_DATE,
        "remit_day": remit_day,
    }

    print("daily series", flush=True)
    first_daily = rows(
        cur,
        f"""
        WITH u AS ({U}),
        fa AS (
          SELECT o.user_id, MIN(o.apply_date) AS first_apply
          FROM u
          INNER JOIN order_loan_f_v2_copy o
            ON o.user_id = u.user_id AND o.apply_date >= DATE '{RECALL_DATE}'
          GROUP BY 1
        )
        SELECT first_apply::text AS d, COUNT(*) AS n
        FROM fa GROUP BY 1 ORDER BY 1
        """,
    )
    cum = 0
    for r in first_daily:
        r["n"] = int(r["n"])
        cum += r["n"]
        r["cum"] = cum
        r["rate"] = round(100.0 * cum / n_user, 2) if n_user else 0

    apply_daily = rows(
        cur,
        f"""
        WITH u AS ({U})
        SELECT o.apply_date::text AS d,
               COUNT(*) AS n_order,
               COUNT(DISTINCT o.user_id) AS n_user
        FROM u
        INNER JOIN order_loan_f_v2_copy o
          ON o.user_id = u.user_id AND o.apply_date >= DATE '{RECALL_DATE}'
        GROUP BY 1 ORDER BY 1
        """,
    )
    for r in apply_daily:
        r["n_order"] = int(r["n_order"])
        r["n_user"] = int(r["n_user"])

    remit_daily = rows(
        cur,
        f"""
        WITH u AS ({U})
        SELECT {remit_day}::text AS d, COUNT(*) AS n
        FROM u
        INNER JOIN order_loan_f_v2_copy o ON o.user_id = u.user_id
        WHERE o.apply_date >= DATE '{RECALL_DATE}'
          AND o.is_remit = 1 AND COALESCE(o.remit_amt, 0) > 0
          AND {remit_day} IS NOT NULL
        GROUP BY 1 ORDER BY 1
        """,
    )
    rcum = 0
    for r in remit_daily:
        r["n"] = int(r["n"])
        rcum += r["n"]
        r["cum"] = rcum

    due_daily = rows(
        cur,
        f"""
        WITH u AS ({U})
        SELECT o.due_date::text AS d,
               COUNT(*) AS n_due,
               SUM(CASE WHEN o.loan_status_code = 8 THEN 1 ELSE 0 END) AS n_od,
               SUM(COALESCE(o.repaid_amt, 0)) AS repaid,
               SUM(o.remit_amt) AS remit
        FROM u
        INNER JOIN order_loan_f_v2_copy o ON o.user_id = u.user_id
        WHERE o.apply_date >= DATE '{RECALL_DATE}'
          AND o.is_due = 1 AND o.is_remit = 1 AND COALESCE(o.remit_amt, 0) > 0
          AND o.due_date IS NOT NULL
        GROUP BY 1 ORDER BY 1
        """,
    )
    attach_due_cum(due_daily)

    strat = rows(
        cur,
        f"""
        WITH u AS ({U})
        SELECT u.strat, COUNT(*) AS n_user, COUNT(a.user_id) AS n_apply
        FROM u
        LEFT JOIN (
          SELECT DISTINCT o.user_id
          FROM u
          INNER JOIN order_loan_f_v2_copy o
            ON o.user_id = u.user_id AND o.apply_date >= DATE '{RECALL_DATE}'
        ) a ON a.user_id = u.user_id
        GROUP BY 1 ORDER BY n_user DESC
        """,
    )
    for r in strat:
        r["n_user"] = int(r["n_user"])
        r["n_apply"] = int(r["n_apply"])
        r["pct"] = round(100.0 * r["n_apply"] / r["n_user"], 2) if r["n_user"] else 0

    churn_raw = rows(
        cur,
        f"""
        WITH u AS ({U})
        SELECT
          CASE
            WHEN churn_days <= 15 THEN '7-15d'
            WHEN churn_days <= 30 THEN '16-30d'
            WHEN churn_days <= 60 THEN '31-60d'
            WHEN churn_days <= 90 THEN '61-90d'
            WHEN churn_days <= 180 THEN '91-180d'
            ELSE '180d+'
          END AS bin,
          COUNT(*) AS n_user,
          COUNT(a.user_id) AS n_apply
        FROM u
        LEFT JOIN (
          SELECT DISTINCT o.user_id
          FROM u
          INNER JOIN order_loan_f_v2_copy o
            ON o.user_id = u.user_id AND o.apply_date >= DATE '{RECALL_DATE}'
        ) a ON a.user_id = u.user_id
        GROUP BY 1
        """,
    )
    order = ["7-15d", "16-30d", "31-60d", "61-90d", "91-180d", "180d+"]
    by = {r["bin"]: r for r in churn_raw}
    churn = []
    for k in order:
        if k not in by:
            continue
        r = by[k]
        r["n_user"] = int(r["n_user"])
        r["n_apply"] = int(r["n_apply"])
        r["pct"] = round(100.0 * r["n_apply"] / r["n_user"], 2) if r["n_user"] else 0
        churn.append(r)

    conn.close()
    return {
        "kpi": kpi_out,
        "first_daily": first_daily,
        "apply_daily": apply_daily,
        "remit_daily": remit_daily,
        "due_daily": due_daily,
        "strat": strat,
        "churn": churn,
    }


def build_sql(batch, remit_day: str) -> str:
    LIST_TABLE = batch["table"]
    RECALL_DATE = batch["recall_date"]
    u_body = list_cte(batch).strip()
    return f"""-- T7 召回看板 · 可复现 PGSQL
-- 库：kaby_dw · schema：wangchuanliang
-- 名单：{LIST_TABLE}
-- 触达日：{RECALL_DATE}
-- 放款日：优先 o.remit_date::date（无该列时用 o.apply_date::date）
-- 本文件当前放款日表达式：{remit_day}
-- 本周：DATE_TRUNC('week', CURRENT_DATE)::date（周一）
-- 执行前：SET search_path TO wangchuanliang, public;

SET search_path TO wangchuanliang, public;

-- ---------------------------------------------------------------------------
-- 0) 放款日字段是否存在（结果有行则用 remit_date，否则用 apply_date）
-- ---------------------------------------------------------------------------
SELECT 1 AS has_remit_date
FROM information_schema.columns
WHERE table_schema = 'wangchuanliang'
  AND table_name = 'order_loan_f_v2_copy'
  AND column_name = 'remit_date';

-- ---------------------------------------------------------------------------
-- 1) 召回名单（去重用户）
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS tmp_t7_u;
CREATE TEMP TABLE tmp_t7_u AS
{u_body};

-- ---------------------------------------------------------------------------
-- 2) KPI（提单率、本周提单/新增提单、放款、到期盈利与逾期）
-- ---------------------------------------------------------------------------
WITH params AS (
    SELECT DATE '{RECALL_DATE}' AS recall_dt,
           DATE_TRUNC('week', CURRENT_DATE)::date AS week_start,
           CURRENT_DATE AS as_of
),
apply_u AS (
    SELECT DISTINCT o.user_id
    FROM tmp_t7_u u
    INNER JOIN order_loan_f_v2_copy o ON o.user_id = u.user_id
    CROSS JOIN params p
    WHERE o.apply_date >= p.recall_dt
),
first_apply AS (
    SELECT o.user_id, MIN(o.apply_date) AS first_dt
    FROM tmp_t7_u u
    INNER JOIN order_loan_f_v2_copy o ON o.user_id = u.user_id
    CROSS JOIN params p
    WHERE o.apply_date >= p.recall_dt
    GROUP BY 1
)
SELECT
    (SELECT COUNT(*) FROM tmp_t7_u) AS n_user,
    (SELECT COUNT(*) FROM apply_u) AS n_apply,
    ROUND(100.0 * (SELECT COUNT(*) FROM apply_u)
        / NULLIF((SELECT COUNT(*) FROM tmp_t7_u), 0), 2) AS apply_rate,
    (SELECT COUNT(DISTINCT o.user_id)
     FROM tmp_t7_u u
     INNER JOIN order_loan_f_v2_copy o ON o.user_id = u.user_id
     CROSS JOIN params p
     WHERE o.apply_date >= p.week_start AND o.apply_date <= p.as_of) AS n_apply_week,
    (SELECT COUNT(*) FROM first_apply f CROSS JOIN params p
     WHERE f.first_dt >= p.week_start AND f.first_dt <= p.as_of) AS n_first_week,
    (SELECT COUNT(*)
     FROM tmp_t7_u u
     INNER JOIN order_loan_f_v2_copy o ON o.user_id = u.user_id
     CROSS JOIN params p
     WHERE o.apply_date >= p.recall_dt AND o.is_remit = 1
       AND COALESCE(o.remit_amt, 0) > 0) AS n_remit,
    (SELECT COUNT(*)
     FROM tmp_t7_u u
     INNER JOIN order_loan_f_v2_copy o ON o.user_id = u.user_id
     CROSS JOIN params p
     WHERE o.apply_date >= p.recall_dt AND o.is_remit = 1
       AND COALESCE(o.remit_amt, 0) > 0
       AND {remit_day} >= p.week_start AND {remit_day} <= p.as_of) AS n_remit_week,
    (SELECT COUNT(*)
     FROM tmp_t7_u u
     INNER JOIN order_loan_f_v2_copy o ON o.user_id = u.user_id
     CROSS JOIN params p
     WHERE o.apply_date >= p.recall_dt AND o.is_due = 1 AND o.is_remit = 1
       AND COALESCE(o.remit_amt, 0) > 0) AS n_due,
    (SELECT COUNT(*)
     FROM tmp_t7_u u
     INNER JOIN order_loan_f_v2_copy o ON o.user_id = u.user_id
     CROSS JOIN params p
     WHERE o.apply_date >= p.recall_dt AND o.is_due = 1 AND o.is_remit = 1
       AND COALESCE(o.remit_amt, 0) > 0 AND o.loan_status_code = 8) AS n_due_od,
    (SELECT SUM(COALESCE(o.repaid_amt, 0))
     FROM tmp_t7_u u
     INNER JOIN order_loan_f_v2_copy o ON o.user_id = u.user_id
     CROSS JOIN params p
     WHERE o.apply_date >= p.recall_dt AND o.is_due = 1 AND o.is_remit = 1
       AND COALESCE(o.remit_amt, 0) > 0) AS due_repaid,
    (SELECT SUM(o.remit_amt)
     FROM tmp_t7_u u
     INNER JOIN order_loan_f_v2_copy o ON o.user_id = u.user_id
     CROSS JOIN params p
     WHERE o.apply_date >= p.recall_dt AND o.is_due = 1 AND o.is_remit = 1
       AND COALESCE(o.remit_amt, 0) > 0) AS due_remit,
    (SELECT week_start FROM params) AS week_start,
    (SELECT as_of FROM params) AS as_of;

-- 盈利率 = (due_repaid - due_remit) / due_remit
-- 逾期率 = n_due_od / n_due

-- ---------------------------------------------------------------------------
-- 3) 召回后首次提单日分布（累计人数、累计提单率）
-- ---------------------------------------------------------------------------
WITH fa AS (
  SELECT o.user_id, MIN(o.apply_date) AS first_apply
  FROM tmp_t7_u u
  INNER JOIN order_loan_f_v2_copy o
    ON o.user_id = u.user_id AND o.apply_date >= DATE '{RECALL_DATE}'
  GROUP BY 1
)
SELECT first_apply::text AS d, COUNT(*) AS n
FROM fa
GROUP BY 1
ORDER BY 1;

-- ---------------------------------------------------------------------------
-- 4) 每日提单用户（当日有过提单的去重用户）与当日提单订单数
-- ---------------------------------------------------------------------------
SELECT o.apply_date::text AS d,
       COUNT(*) AS n_order,
       COUNT(DISTINCT o.user_id) AS n_user
FROM tmp_t7_u u
INNER JOIN order_loan_f_v2_copy o
  ON o.user_id = u.user_id AND o.apply_date >= DATE '{RECALL_DATE}'
GROUP BY 1
ORDER BY 1;

-- ---------------------------------------------------------------------------
-- 5) 每日放款单量
-- ---------------------------------------------------------------------------
SELECT {remit_day}::text AS d, COUNT(*) AS n
FROM tmp_t7_u u
INNER JOIN order_loan_f_v2_copy o ON o.user_id = u.user_id
WHERE o.apply_date >= DATE '{RECALL_DATE}'
  AND o.is_remit = 1 AND COALESCE(o.remit_amt, 0) > 0
  AND {remit_day} IS NOT NULL
GROUP BY 1
ORDER BY 1;

-- ---------------------------------------------------------------------------
-- 6) 按到期日的当天盈利率、逾期率（累计值由按 due_date 顺序滚动 repaid/remit、逾期单量计算）
-- ---------------------------------------------------------------------------
SELECT o.due_date::text AS d,
       COUNT(*) AS n_due,
       SUM(CASE WHEN o.loan_status_code = 8 THEN 1 ELSE 0 END) AS n_od,
       SUM(COALESCE(o.repaid_amt, 0)) AS repaid,
       SUM(o.remit_amt) AS remit
FROM tmp_t7_u u
INNER JOIN order_loan_f_v2_copy o ON o.user_id = u.user_id
WHERE o.apply_date >= DATE '{RECALL_DATE}'
  AND o.is_due = 1 AND o.is_remit = 1 AND COALESCE(o.remit_amt, 0) > 0
  AND o.due_date IS NOT NULL
GROUP BY 1
ORDER BY 1;

-- ---------------------------------------------------------------------------
-- 7) 分层 strat 名单人数与提单率
-- ---------------------------------------------------------------------------
SELECT u.strat,
       COUNT(*) AS n_user,
       COUNT(a.user_id) AS n_apply
FROM tmp_t7_u u
LEFT JOIN (
  SELECT DISTINCT o.user_id
  FROM tmp_t7_u u
  INNER JOIN order_loan_f_v2_copy o
    ON o.user_id = u.user_id AND o.apply_date >= DATE '{RECALL_DATE}'
) a ON a.user_id = u.user_id
GROUP BY 1
ORDER BY n_user DESC;

-- ---------------------------------------------------------------------------
-- 8) 流失天数分箱名单人数与提单率
-- ---------------------------------------------------------------------------
SELECT
  CASE
    WHEN churn_days <= 15 THEN '7-15d'
    WHEN churn_days <= 30 THEN '16-30d'
    WHEN churn_days <= 60 THEN '31-60d'
    WHEN churn_days <= 90 THEN '61-90d'
    WHEN churn_days <= 180 THEN '91-180d'
    ELSE '180d+'
  END AS bin,
  COUNT(*) AS n_user,
  COUNT(a.user_id) AS n_apply
FROM tmp_t7_u u
LEFT JOIN (
  SELECT DISTINCT o.user_id
  FROM tmp_t7_u u
  INNER JOIN order_loan_f_v2_copy o
    ON o.user_id = u.user_id AND o.apply_date >= DATE '{RECALL_DATE}'
) a ON a.user_id = u.user_id
GROUP BY 1;
"""


def write_html(data, batch):
    attach_due_cum(data.get("due_daily") or [])
    k = data["kpi"]
    payload = json.dumps(data, ensure_ascii=False)
    LIST_TABLE = batch["table"]
    RECALL_DATE = batch["recall_date"]
    md = md_label(RECALL_DATE)
    list_note = (
        "（仅 recall_date=2026-08-18，不含同表 8/19 批次）"
        if batch.get("filter_recall_date")
        else ""
    )
    HTML_PATH = HERE / f"t7-{batch['slug']}.html"
    json_name = f"t7_{batch['slug']}_dashboard_data.json"

    def fmt(n):
        return f"{int(n):,}"

    def pct(v):
        return "—" if v is None else f"{v:.2f}%"

    html_head = f"""<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>T7 召回看板 · {RECALL_DATE}</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js"></script>
<style>
:root{{--bg:#071b2f;--card:#0c2944;--line:#2a5c7e;--text:#eff8ff;--muted:#aac5da;--cy:#43c7e7;--gr:#64dcae;--am:#ffc26b;--pk:#f68ab0}}
*{{box-sizing:border-box}}body{{margin:0;background:#06192b;color:var(--text);font-family:-apple-system,BlinkMacSystemFont,"PingFang SC","Microsoft YaHei",sans-serif}}
.wrap{{max-width:1480px;margin:auto;padding:24px 28px 64px}}
.top{{text-align:center;border-bottom:1px solid var(--line);padding-bottom:16px}}
.kicker{{color:var(--cy);font-size:12px;letter-spacing:2px;font-weight:700}}
h1{{font-size:24px;margin:8px 0 6px}}
.meta{{color:var(--muted);font-size:13px;line-height:1.7}}
.kpis{{display:grid;grid-template-columns:repeat(4,1fr);gap:12px;margin:18px 0}}
.card{{background:rgba(10,41,68,.95);border:1px solid var(--line);border-radius:14px;padding:16px}}
.label{{color:var(--muted);font-size:12px}}
.num{{font-size:26px;font-weight:800;margin:6px 0 2px;color:var(--cy);line-height:1.15}}
.num.g{{color:var(--gr)}}.num.a{{color:var(--am)}}.num.p{{color:var(--pk)}}
.sub{{color:var(--muted);font-size:12px}}
.grid{{display:grid;grid-template-columns:1fr 1fr;gap:14px}}
.chart h3{{margin:0 0 4px;font-size:15px}}
.chart p{{margin:0 0 10px;font-size:12px;color:var(--muted)}}
.box{{height:300px;position:relative;overflow:visible}}
.foot{{color:#7fa6c2;font-size:12px;margin-top:28px;border-top:1px solid var(--line);padding-top:14px;line-height:1.8}}
.appendix{{margin-top:36px;border-top:1px solid var(--line);padding-top:8px}}
.appendix h2{{font-size:18px;margin:22px 0 10px}}
.appendix p,.appendix li{{color:var(--muted);font-size:13px;line-height:1.8}}
.appendix ul{{padding-left:1.2em}}
details.code{{margin:10px 0;background:rgba(10,41,68,.95);border:1px solid var(--line);border-radius:12px;padding:10px 14px}}
details.code summary{{cursor:pointer;color:var(--cy);font-weight:700;font-size:13px}}
details.code pre{{overflow:auto;max-height:520px;font-size:11px;line-height:1.45;color:#d7ecf8;white-space:pre-wrap;word-break:break-word}}
@media(max-width:900px){{.kpis,.grid{{grid-template-columns:1fr}}}}
</style>
</head>
<body>
<main class="wrap">
<div class="top">
  <div class="kicker">DASHBOARD · T7+ RECALL · {RECALL_DATE}</div>
  <h1>流失 7 天以上召回 · 看板</h1>
  <p class="meta">名单 {fmt(k['n_user'])} 人{list_note} · 统计至 {k['as_of']} · 本周 {k['week_start']} 起（周一）</p>
</div>
<section class="kpis">
  <article class="card"><div class="label">提单率</div><div class="num a">{pct(k['apply_rate'])}</div><div class="sub">{fmt(k['n_apply'])} / {fmt(k['n_user'])} · {md}至今去重用户</div></article>
  <article class="card"><div class="label">总提单人数</div><div class="num g">{fmt(k['n_apply'])}</div><div class="sub">{md}至今任意提单用户</div></article>
  <article class="card"><div class="label">本周提单人数</div><div class="num">{fmt(k['n_apply_week'])}</div><div class="sub">本周有过提单的去重用户</div></article>
  <article class="card"><div class="label">本周新增提单人数</div><div class="num p">{fmt(k['n_first_week'])}</div><div class="sub">召回后首次提单落在本周</div></article>
  <article class="card"><div class="label">放款单量</div><div class="num g">{fmt(k['n_remit'])}</div><div class="sub">{md}至今已放款订单数</div></article>
  <article class="card"><div class="label">本周新增放款单量</div><div class="num">{fmt(k['n_remit_week'])}</div><div class="sub">本周新放款订单数</div></article>
  <article class="card"><div class="label">订单盈利率</div><div class="num a">{pct(k['profit_pct'])}</div><div class="sub">到期订单</div></article>
  <article class="card"><div class="label">订单逾期率</div><div class="num p">{pct(k['overdue_pct'])}</div><div class="sub">到期订单</div></article>
</section>
<div class="grid">
  <div class="card chart"><h3>累计提单人数与提单率</h3><p>按召回后首次提单日累计，分母={fmt(k['n_user'])}</p><div class="box"><canvas id="c1"></canvas></div></div>
  <div class="card chart"><h3>每日新增首次提单</h3><p>每人只记召回后第一笔提单所在日</p><div class="box"><canvas id="c2"></canvas></div></div>
</div>
<div class="grid" style="margin-top:14px">
  <div class="card chart"><h3>每日提单用户</h3><p>当日有过提单的去重用户</p><div class="box"><canvas id="c3"></canvas></div></div>
  <div class="card chart"><h3>每日放款单量与累计</h3><p>已放款订单；本周新增见 KPI</p><div class="box"><canvas id="c4"></canvas></div></div>
</div>
<div class="grid" style="margin-top:14px">
  <div class="card chart"><h3>按到期日的盈利率</h3><p>当天到期单 vs 截至当日累计到期单，(repaid−remit)/remit</p><div class="box"><canvas id="c5"></canvas></div></div>
  <div class="card chart"><h3>按到期日的逾期率</h3><p>当天到期单 vs 截至当日累计到期单，loan_status_code=8 占比</p><div class="box"><canvas id="c6"></canvas></div></div>
</div>
<div class="grid" style="margin-top:14px">
  <div class="card chart"><h3>转化结构</h3><p>已提单 vs 尚未提单</p><div class="box pie"><canvas id="c7"></canvas></div></div>
  <div class="card chart"><h3>本周 vs 累计</h3><p>本周新增提单用户 / 本周提单用户 / 本周放款单量</p><div class="box"><canvas id="c8"></canvas></div></div>
</div>
<div class="grid" style="margin-top:14px">
  <div class="card chart"><h3>分层 strat 提单率</h3><p>人数柱 + 提单率折线</p><div class="box"><canvas id="c9"></canvas></div></div>
  <div class="card chart"><h3>流失天数提单率</h3><p>7–15 / 16–30 / 31–60 / 61–90 / 91–180 / 180d+</p><div class="box"><canvas id="c10"></canvas></div></div>
</div>
"""
    html_js = r"""
const col = {cy:'#43c7e7', gr:'#64dcae', am:'#ffc26b', pk:'#f68ab0'};
Chart.defaults.font.family='-apple-system,BlinkMacSystemFont,"PingFang SC","Microsoft YaHei",sans-serif';
Chart.defaults.color='#aac5da';
function base(y2) {
  const scales = {
    x: {ticks:{color:'#aac5da', maxRotation:45, autoSkip:true, autoSkipPadding:6}, grid:{display:false}},
    y: {type:'linear', position:'left', ticks:{color:'#aac5da'}, grid:{color:'rgba(42,92,126,.25)'}}
  };
  if (y2) scales.y2 = {type:'linear', position:'right', ticks:{color:'#ffc26b'}, grid:{drawOnChartArea:false}};
  return {responsive:true, maintainAspectRatio:false, interaction:{mode:'index', intersect:false},
    layout:{padding:{top:10,right:18,bottom:4,left:4}},
    plugins:{
      legend:{labels:{color:'#eff8ff', padding:16}},
      tooltip:{
        enabled:true,
        position:'keepIn',
        xAlign:'left',
        yAlign:'center',
        padding:10,
        caretPadding:8,
        displayColors:true
      }
    },
    scales};
}
if (typeof Chart !== 'undefined' && Chart.Tooltip && !Chart.Tooltip.positioners.keepIn) {
  Chart.Tooltip.positioners.keepIn = function(items, eventPosition) {
    const nearest = Chart.Tooltip.positioners.nearest.call(this, items, eventPosition);
    if (!nearest) return false;
    const area = this.chart.chartArea;
    let x = nearest.x, y = nearest.y;
    const cut = area.left + (area.right - area.left) * 0.62;
    if (x > cut) x = Math.max(area.left + 8, x - 120);
    y = Math.min(Math.max(y, area.top + 8), area.bottom - 8);
    return {x, y};
  };
}
function line(id, labels, datasets, y2, extraOpt) {
  const opt = Object.assign(base(y2), extraOpt || {});
  new Chart(document.getElementById(id), {type:'line', data:{labels, datasets}, options:opt});
}
function drawRateLabels(chart) {
  const {ctx} = chart;
  chart.data.datasets.forEach((ds,i)=>{
    if(!String(ds.label).includes('提单率')) return;
    const pts = chart.getDatasetMeta(i).data;
    ctx.save();
    ctx.font='11px sans-serif';
    ctx.fillStyle='#f68ab0';
    ctx.textBaseline='bottom';
    pts.forEach((pt,j)=>{
      const v=ds.data[j];
      if(v==null) return;
      let dx=0, dy=-16, align='center';
      if(j===0){ align='left'; dx=10; }
      else if(j===pts.length-1){ align='right'; dx=-10; }
      const prev=pts[j-1], next=pts[j+1];
      if(prev && next && pt.y>=prev.y && pt.y>=next.y) dy=-20;
      ctx.textAlign=align;
      ctx.fillText(Number(v).toFixed(2)+'%', pt.x+dx, pt.y+dy);
    });
    ctx.restore();
  });
}
const fd = D.first_daily, ad = D.apply_daily, rd = D.remit_daily, dd = D.due_daily, k=D.kpi;
line('c1', fd.map(x=>x.d.slice(5)), [
  {label:'累计提单人数', data:fd.map(x=>x.cum), borderColor:col.cy, backgroundColor:'rgba(67,199,231,.12)', fill:true, tension:.25, yAxisID:'y', pointRadius:2},
  {label:'提单率%', data:fd.map(x=>x.rate), borderColor:col.am, tension:.25, yAxisID:'y2', pointRadius:2}
], true);
new Chart(document.getElementById('c2'), {type:'bar', data:{labels:fd.map(x=>x.d.slice(5)), datasets:[
  {label:'当日首次提单', data:fd.map(x=>x.n), backgroundColor:col.gr}
]}, options:base(false)});
new Chart(document.getElementById('c3'), {type:'bar', data:{labels:ad.map(x=>x.d.slice(5)), datasets:[
  {label:'当日提单用户', data:ad.map(x=>x.n_user), backgroundColor:'rgba(67,199,231,.7)'}
]}, options:base(false)});
line('c4', rd.map(x=>x.d.slice(5)), [
  {label:'当日放款单', data:rd.map(x=>x.n), borderColor:col.gr, tension:.25, yAxisID:'y', pointRadius:2},
  {label:'累计放款单', data:rd.map(x=>x.cum), borderColor:col.am, tension:.25, yAxisID:'y2', pointRadius:2}
], true);
line('c5', dd.map(x=>x.d.slice(5)), [
  {label:'当天盈利率%', data:dd.map(x=>x.profit_pct), borderColor:col.gr, tension:.25, pointRadius:2, spanGaps:true},
  {label:'累计盈利率%', data:dd.map(x=>x.cum_profit_pct), borderColor:col.am, tension:.25, pointRadius:2, spanGaps:true}
], false);
line('c6', dd.map(x=>x.d.slice(5)), [
  {label:'当天逾期率%', data:dd.map(x=>x.overdue_pct), borderColor:col.pk, tension:.25, pointRadius:2, spanGaps:true},
  {label:'累计逾期率%', data:dd.map(x=>x.cum_overdue_pct), borderColor:col.cy, tension:.25, pointRadius:2, spanGaps:true}
], false);
new Chart(document.getElementById('c7'), {type:'doughnut', data:{labels:['已提单','尚未提单'], datasets:[{data:[k.n_apply, k.n_user-k.n_apply], backgroundColor:[col.gr, 'rgba(42,92,126,.55)'], borderWidth:0}]},
  options:{responsive:true, maintainAspectRatio:false, cutout:'55%', layout:{padding:{top:4,bottom:8,left:4,right:8}}, plugins:{legend:{position:'right', labels:{color:'#eff8ff', padding:12, boxWidth:12}}}},
  plugins:[{id:'pieLabel', afterDatasetsDraw(chart){
    const {ctx} = chart; const ds = chart.data.datasets[0];
    const total = ds.data.reduce((a,b)=>a+b,0);
    const meta = chart.getDatasetMeta(0);
    meta.data.forEach((arc,i)=>{
      const v = ds.data[i]; const pos = arc.tooltipPosition();
      ctx.save(); ctx.fillStyle='#eff8ff'; ctx.textAlign='center'; ctx.textBaseline='middle';
      ctx.font='13px sans-serif'; ctx.fillText((100*v/total).toFixed(2)+'%', pos.x, pos.y);
      ctx.restore();
    });
  }}]});
new Chart(document.getElementById('c8'), {type:'bar', data:{labels:['本周新增提单用户','本周提单用户','本周放款单量','累计提单人数','累计放款单量'],
  datasets:[{label:'人数/单量', data:[k.n_first_week, k.n_apply_week, k.n_remit_week, k.n_apply, k.n_remit],
    backgroundColor:[col.pk, col.cy, col.am, col.gr, 'rgba(67,199,231,.45)']}]},
  options:Object.assign(base(false), {layout:{padding:{top:22}}}),
  plugins:[{id:'barLabel', afterDatasetsDraw(chart){
    const {ctx}=chart; const meta=chart.getDatasetMeta(0);
    ctx.save(); ctx.fillStyle='#eff8ff'; ctx.font='11px sans-serif'; ctx.textAlign='center'; ctx.textBaseline='bottom';
    meta.data.forEach((pt,j)=>{ const v=chart.data.datasets[0].data[j]; if(v==null) return; ctx.fillText(Number(v).toLocaleString(), pt.x, pt.y-4); });
    ctx.restore();
  }}]});
new Chart(document.getElementById('c9'), {type:'bar', data:{labels:D.strat.map(x=>x.strat), datasets:[
  {label:'名单人数', data:D.strat.map(x=>x.n_user), backgroundColor:'rgba(67,199,231,.35)', yAxisID:'y'},
  {label:'提单率%', data:D.strat.map(x=>x.pct), type:'line', borderColor:col.pk, yAxisID:'y2', tension:.2, pointRadius:3}
]}, options:Object.assign(base(true), {layout:{padding:{top:0,right:8}}}),
  plugins:[{id:'rateLabel9', afterDatasetsDraw(chart){ drawRateLabels(chart); }}]});
new Chart(document.getElementById('c10'), {type:'bar', data:{labels:D.churn.map(x=>x.bin), datasets:[
  {label:'名单人数', data:D.churn.map(x=>x.n_user), backgroundColor:'rgba(67,199,231,.35)', yAxisID:'y'},
  {label:'提单率%', data:D.churn.map(x=>x.pct), type:'line', borderColor:col.pk, yAxisID:'y2', tension:.2, pointRadius:3}
]}, options:Object.assign(base(true), {layout:{padding:{top:0,right:8}}}),
  plugins:[{id:'rateLabel10', afterDatasetsDraw(chart){ drawRateLabels(chart); }}]});
</script>
</body></html>
"""
    sql_txt = build_sql(batch, k["remit_day"])
    py_txt = Path(__file__).read_text(encoding="utf-8")
    front_src = (
        html_head
        + "\n<!-- 口径与附录见页面底部 -->\n</main>\n"
        + f"<script>\nconst D = /* 由后端写入，对象结构同 {json_name} */;\n"
        + html_js
    )
    appendix = (
        '<section class="appendix" id="method">\n'
        "<h2>口径说明</h2>\n"
        "<ul>\n"
        f"<li>名单：<code>{LIST_TABLE}</code>，批次日 <code>{RECALL_DATE}</code>，按 <code>churn_user_id</code> 去重。"
        + (
            "仅 <code>recall_date = 2026-08-18</code>，不含同表 2026-08-19 批次。"
            if batch.get("filter_recall_date")
            else "该表无可用召回日日期字段，以整表为该批次名单。"
        )
        + "</li>\n"
        f"<li>提单：<code>apply_date ≥ {RECALL_DATE}</code>。总提单人数=召回后任意提单用户去重；本周提单=本周任意提单用户去重；本周新增提单=召回后首次提单日期落在本周（周一 <code>DATE_TRUNC('week', CURRENT_DATE)</code> 至库内 <code>CURRENT_DATE</code>）。</li>\n"
        "<li>放款：<code>is_remit = 1</code> 且 <code>remit_amt &gt; 0</code>；本周新增放款按放款日（本页为 <code>"
        + html_lib.escape(str(k["remit_day"]))
        + "</code>）落在本周的订单数。</li>\n"
        "<li>到期盈利 / 逾期：召回后提单且 <code>is_due = 1</code>、<code>is_remit = 1</code>、<code>remit_amt &gt; 0</code>。盈利率 = <code>(repaid_amt − remit_amt) / remit_amt</code>；逾期率 = <code>loan_status_code = 8</code> 占到期放款单。</li>\n"
        "<li>转化结构：已提单 vs 名单中尚未提单。分层 / 流失天数：名单人数与对应提单率。</li>\n"
        "</ul>\n"
        "<h2>附录：</h2>\n"
        '<details class="code"><summary>1. PGSQL（名单 + KPI + 全部图数据）</summary><pre>'
        + html_lib.escape(sql_txt)
        + "</pre></details>\n"
        '<details class="code"><summary>2. 后端 Python（查库、汇总、写出 HTML）</summary><pre>'
        + html_lib.escape(py_txt)
        + "</pre></details>\n"
        '<details class="code"><summary>3. 前端 HTML / CSS / Chart.js（数据对象 D 由后端注入）</summary><pre>'
        + html_lib.escape(front_src)
        + "</pre></details>\n"
        "</section>\n"
        f'<p class="foot">数据：kaby_dw · {LIST_TABLE} · recall_date={RECALL_DATE} · 库内 CURRENT_DATE={k["as_of"]}</p>\n'
        "</main>\n"
        "<script>\nconst D = "
        + payload
        + ";\n"
    )
    HTML_PATH.write_text(html_head + appendix + html_js, encoding="utf-8")
    sql_path = HERE / f"appendix_t7_{batch['slug']}_dashboard.sql"
    sql_path.write_text(sql_txt, encoding="utf-8")
    print("HTML", HTML_PATH)


TAB_LABEL = {
    "0818": "8月18日批次",
    "0902": "9月2日批次",
    "0910": "9月10日批次",
    "0917": "9月17日批次",
}


def _fmt(n):
    return f"{int(n):,}"


def _pct(v):
    return "—" if v is None else f"{v:.2f}%"


def panel_body(data, batch, pfx):
    k = data["kpi"]
    md = md_label(batch["recall_date"])
    rd = batch["recall_date"]
    list_note = (
        "（仅 recall_date=2026-08-18，不含同表 8/19 批次）"
        if batch.get("filter_recall_date")
        else ""
    )
    return f"""
<div class="top">
  <div class="kicker">DASHBOARD · T7+ RECALL · {rd}</div>
  <p class="meta">名单 {_fmt(k['n_user'])} 人{list_note} · 统计至 {k['as_of']} · 本周 {k['week_start']} 起（周一）</p>
</div>
<section class="kpis">
  <article class="card"><div class="label">提单率</div><div class="num a">{_pct(k['apply_rate'])}</div><div class="sub">{_fmt(k['n_apply'])} / {_fmt(k['n_user'])} · {md}至今去重用户</div></article>
  <article class="card"><div class="label">总提单人数</div><div class="num g">{_fmt(k['n_apply'])}</div><div class="sub">{md}至今任意提单用户</div></article>
  <article class="card"><div class="label">本周提单人数</div><div class="num">{_fmt(k['n_apply_week'])}</div><div class="sub">本周有过提单的去重用户</div></article>
  <article class="card"><div class="label">本周新增提单人数</div><div class="num p">{_fmt(k['n_first_week'])}</div><div class="sub">召回后首次提单落在本周</div></article>
  <article class="card"><div class="label">放款单量</div><div class="num g">{_fmt(k['n_remit'])}</div><div class="sub">{md}至今已放款订单数</div></article>
  <article class="card"><div class="label">本周新增放款单量</div><div class="num">{_fmt(k['n_remit_week'])}</div><div class="sub">本周新放款订单数</div></article>
  <article class="card"><div class="label">订单盈利率</div><div class="num a">{_pct(k['profit_pct'])}</div><div class="sub">到期订单</div></article>
  <article class="card"><div class="label">订单逾期率</div><div class="num p">{_pct(k['overdue_pct'])}</div><div class="sub">到期订单</div></article>
</section>
<div class="grid">
  <div class="card chart"><h3>累计提单人数与提单率</h3><p>按召回后首次提单日累计，分母={_fmt(k['n_user'])}</p><div class="box"><canvas id="{pfx}c1"></canvas></div></div>
  <div class="card chart"><h3>每日新增首次提单</h3><p>每人只记召回后第一笔提单所在日</p><div class="box"><canvas id="{pfx}c2"></canvas></div></div>
</div>
<div class="grid" style="margin-top:14px">
  <div class="card chart"><h3>每日提单用户</h3><p>当日有过提单的去重用户</p><div class="box"><canvas id="{pfx}c3"></canvas></div></div>
  <div class="card chart"><h3>每日放款单量与累计</h3><p>已放款订单；本周新增见 KPI</p><div class="box"><canvas id="{pfx}c4"></canvas></div></div>
</div>
<div class="grid" style="margin-top:14px">
  <div class="card chart"><h3>按到期日的盈利率</h3><p>当天到期单 vs 截至当日累计到期单，(repaid−remit)/remit</p><div class="box"><canvas id="{pfx}c5"></canvas></div></div>
  <div class="card chart"><h3>按到期日的逾期率</h3><p>当天到期单 vs 截至当日累计到期单，loan_status_code=8 占比</p><div class="box"><canvas id="{pfx}c6"></canvas></div></div>
</div>
<div class="grid" style="margin-top:14px">
  <div class="card chart"><h3>转化结构</h3><p>已提单 vs 尚未提单</p><div class="box pie"><canvas id="{pfx}c7"></canvas></div></div>
  <div class="card chart"><h3>本周 vs 累计</h3><p>本周新增提单用户 / 本周提单用户 / 本周放款单量</p><div class="box"><canvas id="{pfx}c8"></canvas></div></div>
</div>
<div class="grid" style="margin-top:14px">
  <div class="card chart"><h3>分层 strat 提单率</h3><p>人数柱 + 提单率折线</p><div class="box"><canvas id="{pfx}c9"></canvas></div></div>
  <div class="card chart"><h3>流失天数提单率</h3><p>7–15 / 16–30 / 31–60 / 61–90 / 91–180 / 180d+</p><div class="box"><canvas id="{pfx}c10"></canvas></div></div>
</div>
"""


def charts_js_for(pfx: str) -> str:
    js = r"""
const fd = D.first_daily, ad = D.apply_daily, rd = D.remit_daily, dd = D.due_daily, k=D.kpi;
line('__P__c1', fd.map(x=>x.d.slice(5)), [
  {label:'累计提单人数', data:fd.map(x=>x.cum), borderColor:col.cy, backgroundColor:'rgba(67,199,231,.12)', fill:true, tension:.25, yAxisID:'y', pointRadius:2},
  {label:'提单率%', data:fd.map(x=>x.rate), borderColor:col.am, tension:.25, yAxisID:'y2', pointRadius:2}
], true);
new Chart(document.getElementById('__P__c2'), {type:'bar', data:{labels:fd.map(x=>x.d.slice(5)), datasets:[
  {label:'当日首次提单', data:fd.map(x=>x.n), backgroundColor:col.gr}
]}, options:base(false)});
new Chart(document.getElementById('__P__c3'), {type:'bar', data:{labels:ad.map(x=>x.d.slice(5)), datasets:[
  {label:'当日提单用户', data:ad.map(x=>x.n_user), backgroundColor:'rgba(67,199,231,.7)'}
]}, options:base(false)});
line('__P__c4', rd.map(x=>x.d.slice(5)), [
  {label:'当日放款单', data:rd.map(x=>x.n), borderColor:col.gr, tension:.25, yAxisID:'y', pointRadius:2},
  {label:'累计放款单', data:rd.map(x=>x.cum), borderColor:col.am, tension:.25, yAxisID:'y2', pointRadius:2}
], true);
line('__P__c5', dd.map(x=>x.d.slice(5)), [
  {label:'当天盈利率%', data:dd.map(x=>x.profit_pct), borderColor:col.gr, tension:.25, pointRadius:2, spanGaps:true},
  {label:'累计盈利率%', data:dd.map(x=>x.cum_profit_pct), borderColor:col.am, tension:.25, pointRadius:2, spanGaps:true}
], false);
line('__P__c6', dd.map(x=>x.d.slice(5)), [
  {label:'当天逾期率%', data:dd.map(x=>x.overdue_pct), borderColor:col.pk, tension:.25, pointRadius:2, spanGaps:true},
  {label:'累计逾期率%', data:dd.map(x=>x.cum_overdue_pct), borderColor:col.cy, tension:.25, pointRadius:2, spanGaps:true}
], false);
new Chart(document.getElementById('__P__c7'), {type:'doughnut', data:{labels:['已提单','尚未提单'], datasets:[{data:[k.n_apply, k.n_user-k.n_apply], backgroundColor:[col.gr, 'rgba(42,92,126,.55)'], borderWidth:0}]},
  options:{responsive:true, maintainAspectRatio:false, cutout:'55%', layout:{padding:{top:4,bottom:8,left:4,right:8}}, plugins:{legend:{position:'right', labels:{color:'#eff8ff', padding:12, boxWidth:12}}}},
  plugins:[{id:'pieLabel', afterDatasetsDraw(chart){
    const {ctx} = chart; const ds = chart.data.datasets[0];
    const total = ds.data.reduce((a,b)=>a+b,0);
    const meta = chart.getDatasetMeta(0);
    meta.data.forEach((arc,i)=>{
      const v = ds.data[i]; const pos = arc.tooltipPosition();
      ctx.save(); ctx.fillStyle='#eff8ff'; ctx.textAlign='center'; ctx.textBaseline='middle';
      ctx.font='13px sans-serif'; ctx.fillText((100*v/total).toFixed(2)+'%', pos.x, pos.y);
      ctx.restore();
    });
  }}]});
new Chart(document.getElementById('__P__c8'), {type:'bar', data:{labels:['本周新增提单用户','本周提单用户','本周放款单量','累计提单人数','累计放款单量'],
  datasets:[{label:'人数/单量', data:[k.n_first_week, k.n_apply_week, k.n_remit_week, k.n_apply, k.n_remit],
    backgroundColor:[col.pk, col.cy, col.am, col.gr, 'rgba(67,199,231,.45)']}]},
  options:Object.assign(base(false), {layout:{padding:{top:22}}}),
  plugins:[{id:'barLabel', afterDatasetsDraw(chart){
    const {ctx}=chart; const meta=chart.getDatasetMeta(0);
    ctx.save(); ctx.fillStyle='#eff8ff'; ctx.font='11px sans-serif'; ctx.textAlign='center'; ctx.textBaseline='bottom';
    meta.data.forEach((pt,j)=>{ const v=chart.data.datasets[0].data[j]; if(v==null) return; ctx.fillText(Number(v).toLocaleString(), pt.x, pt.y-4); });
    ctx.restore();
  }}]});
new Chart(document.getElementById('__P__c9'), {type:'bar', data:{labels:D.strat.map(x=>x.strat), datasets:[
  {label:'名单人数', data:D.strat.map(x=>x.n_user), backgroundColor:'rgba(67,199,231,.35)', yAxisID:'y'},
  {label:'提单率%', data:D.strat.map(x=>x.pct), type:'line', borderColor:col.pk, yAxisID:'y2', tension:.2, pointRadius:3}
]}, options:Object.assign(base(true), {layout:{padding:{top:0,right:8}}}),
  plugins:[{id:'rateLabel9', afterDatasetsDraw(chart){ drawRateLabels(chart); }}]});
new Chart(document.getElementById('__P__c10'), {type:'bar', data:{labels:D.churn.map(x=>x.bin), datasets:[
  {label:'名单人数', data:D.churn.map(x=>x.n_user), backgroundColor:'rgba(67,199,231,.35)', yAxisID:'y'},
  {label:'提单率%', data:D.churn.map(x=>x.pct), type:'line', borderColor:col.pk, yAxisID:'y2', tension:.2, pointRadius:3}
]}, options:Object.assign(base(true), {layout:{padding:{top:0,right:8}}}),
  plugins:[{id:'rateLabel10', afterDatasetsDraw(chart){ drawRateLabels(chart); }}]});
"""
    return js.replace("__P__", pfx)


def write_hub(items):
    payload = {batch["slug"]: data for batch, data in items}
    btns = []
    panels = []
    draws = []
    for i, (batch, data) in enumerate(items):
        slug = batch["slug"]
        on = " on" if i == 0 else ""
        cls = "on" if i == 0 else ""
        btns.append(
            f'<button type="button" data-tab="{slug}" class="{cls}">{TAB_LABEL[slug]}</button>'
        )
        pfx = f"b{slug}_"
        panels.append(
            f'<section class="panel{on}" id="p-{slug}">{panel_body(data, batch, pfx)}</section>'
        )
        draws.append(
            f"if(slug==={json.dumps(slug)}){{\nconst D = DATA[{json.dumps(slug)}];\n"
            + charts_js_for(pfx)
            + "\n}"
        )
    html = f"""<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>流失 7 天以上召回 · 看板</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js"></script>
<style>
:root{{--bg:#071b2f;--card:#0c2944;--line:#2a5c7e;--text:#eff8ff;--muted:#aac5da;--cy:#43c7e7;--gr:#64dcae;--am:#ffc26b;--pk:#f68ab0}}
*{{box-sizing:border-box}}body{{margin:0;background:#06192b;color:var(--text);font-family:-apple-system,BlinkMacSystemFont,"PingFang SC","Microsoft YaHei",sans-serif}}
.wrap{{max-width:1480px;margin:auto;padding:24px 28px 64px}}
.page-top{{text-align:center}}
.kicker{{color:var(--cy);font-size:12px;letter-spacing:2px;font-weight:700}}
h1{{font-size:24px;margin:8px 0 6px}}
.tabs{{display:flex;flex-wrap:wrap;gap:10px;justify-content:center;margin:18px 0 8px}}
.tabs button{{appearance:none;border:1px solid var(--line);background:#0c2944;color:var(--text);border-radius:999px;padding:10px 18px;font-size:14px;font-weight:700;cursor:pointer}}
.tabs button:hover{{border-color:var(--cy)}}
.tabs button.on{{background:var(--cy);color:#062033;border-color:var(--cy)}}
.panel{{display:none}}
.panel.on{{display:block}}
.top{{text-align:center;border-bottom:1px solid var(--line);padding:8px 0 16px}}
.meta{{color:var(--muted);font-size:13px;line-height:1.7}}
.kpis{{display:grid;grid-template-columns:repeat(4,1fr);gap:12px;margin:18px 0}}
.card{{background:rgba(10,41,68,.95);border:1px solid var(--line);border-radius:14px;padding:16px}}
.label{{color:var(--muted);font-size:12px}}
.num{{font-size:26px;font-weight:800;margin:6px 0 2px;color:var(--cy);line-height:1.15}}
.num.g{{color:var(--gr)}}.num.a{{color:var(--am)}}.num.p{{color:var(--pk)}}
.sub{{color:var(--muted);font-size:12px}}
.grid{{display:grid;grid-template-columns:1fr 1fr;gap:14px}}
.chart h3{{margin:0 0 4px;font-size:15px}}
.chart p{{margin:0 0 10px;font-size:12px;color:var(--muted)}}
.box{{height:300px;position:relative;overflow:visible}}
@media(max-width:900px){{.kpis,.grid{{grid-template-columns:1fr}}}}
</style>
</head>
<body>
<main class="wrap">
<div class="page-top">
  <div class="kicker">T7+ RECALL · MULTI-BATCH</div>
  <h1>流失 7 天以上召回 · 看板</h1>
  <div class="tabs">{"".join(btns)}</div>
</div>
{"".join(panels)}
</main>
<script>
const DATA = {json.dumps(payload, ensure_ascii=False)};
const col = {{cy:'#43c7e7', gr:'#64dcae', am:'#ffc26b', pk:'#f68ab0'}};
Chart.defaults.font.family='-apple-system,BlinkMacSystemFont,"PingFang SC","Microsoft YaHei",sans-serif';
Chart.defaults.color='#aac5da';
Chart.register({{
  id: 'legendPlotGap',
  afterLayout(chart) {{
    const legend = chart.legend;
    const area = chart.chartArea;
    if (!legend || !legend.options.display || !area) return;
    if (chart.config.type === 'pie' || chart.config.type === 'doughnut') return;
    const hasRateLbl = (chart.data.datasets || []).some(d => String(d.label || '').includes('提单率'));
    area.top += hasRateLbl ? 34 : 8;
  }}
}});
function base(y2) {{
  const scales = {{
    x: {{ticks:{{color:'#aac5da', maxRotation:45, autoSkip:true, autoSkipPadding:6}}, grid:{{display:false}}}},
    y: {{type:'linear', position:'left', ticks:{{color:'#aac5da'}}, grid:{{color:'rgba(42,92,126,.25)'}}}}
  }};
  if (y2) scales.y2 = {{type:'linear', position:'right', ticks:{{color:'#ffc26b'}}, grid:{{drawOnChartArea:false}}}};
  return {{responsive:true, maintainAspectRatio:false, interaction:{{mode:'index', intersect:false}},
    layout:{{padding:{{top:10,right:18,bottom:4,left:4}}}},
    plugins:{{
      legend:{{labels:{{color:'#eff8ff', padding:16}}}},
      tooltip:{{
        enabled:true,
        position:'keepIn',
        xAlign:'left',
        yAlign:'center',
        padding:10,
        caretPadding:8,
        displayColors:true
      }}
    }}, scales}};
}}
if (typeof Chart !== 'undefined' && Chart.Tooltip && !Chart.Tooltip.positioners.keepIn) {{
  Chart.Tooltip.positioners.keepIn = function(items, eventPosition) {{
    const nearest = Chart.Tooltip.positioners.nearest.call(this, items, eventPosition);
    if (!nearest) return false;
    const area = this.chart.chartArea;
    let x = nearest.x, y = nearest.y;
    const cut = area.left + (area.right - area.left) * 0.62;
    if (x > cut) x = Math.max(area.left + 8, x - 120);
    y = Math.min(Math.max(y, area.top + 8), area.bottom - 8);
    return {{x, y}};
  }};
}}
function line(id, labels, datasets, y2, extraOpt) {{
  const opt = Object.assign(base(y2), extraOpt || {{}});
  new Chart(document.getElementById(id), {{type:'line', data:{{labels, datasets}}, options:opt}});
}}
function drawRateLabels(chart) {{
  const {{ctx}} = chart;
  chart.data.datasets.forEach((ds,i)=>{{
    if(!String(ds.label).includes('提单率')) return;
    const pts = chart.getDatasetMeta(i).data;
    ctx.save();
    ctx.font='11px sans-serif';
    ctx.fillStyle='#f68ab0';
    ctx.textBaseline='bottom';
    pts.forEach((pt,j)=>{{
      const v=ds.data[j];
      if(v==null) return;
      let dx=0, dy=-16, align='center';
      if(j===0){{ align='left'; dx=10; }}
      else if(j===pts.length-1){{ align='right'; dx=-10; }}
      const prev=pts[j-1], next=pts[j+1];
      if(prev && next && pt.y>=prev.y && pt.y>=next.y) dy=-20;
      ctx.textAlign=align;
      ctx.fillText(Number(v).toFixed(2)+'%', pt.x+dx, pt.y+dy);
    }});
    ctx.restore();
  }});
}}
const drawn = {{}};
function draw(slug) {{
{chr(10).join(draws)}
}}
function show(slug) {{
  document.querySelectorAll('.tabs button').forEach(b=>b.classList.toggle('on', b.dataset.tab===slug));
  document.querySelectorAll('.panel').forEach(p=>p.classList.toggle('on', p.id==='p-'+slug));
  const run = () => {{
    if (!drawn[slug]) {{ draw(slug); drawn[slug]=true; }}
    document.querySelectorAll('#p-'+slug+' canvas').forEach(cv => {{
      const ch = Chart.getChart(cv);
      if (ch) ch.resize();
    }});
  }};
  requestAnimationFrame(() => requestAnimationFrame(run));
}}
document.querySelectorAll('.tabs button').forEach(btn => {{
  btn.addEventListener('click', () => show(btn.dataset.tab));
}});
show({json.dumps(items[0][0]["slug"])});
</script>
</body></html>
"""
    path = HERE / "t7.html"
    path.write_text(html, encoding="utf-8")
    print("HTML", path)


def write_hub_from_disk():
    items = []
    for batch in BATCHES:
        p = HERE / f"t7_{batch['slug']}_dashboard_data.json"
        if not p.exists():
            print("skip hub, missing", p.name, flush=True)
            return
        items.append((batch, json.loads(p.read_text(encoding="utf-8"))))
    for batch, data in items:
        attach_due_cum(data.get("due_daily") or [])
    write_hub(items)


if __name__ == "__main__":
    by = {b["slug"]: b for b in BATCHES}
    slugs = sys.argv[1:] or [b["slug"] for b in BATCHES]
    for slug in slugs:
        if slug not in by:
            raise SystemExit(f"未知批次 {slug}，可选：{', '.join(by)}")
        batch = by[slug]
        print("batch", slug, batch["table"], batch["recall_date"], flush=True)
        data = fetch(batch)
        json_path = HERE / f"t7_{slug}_dashboard_data.json"
        json_path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
        write_html(data, batch)
        print("kpi", data["kpi"], flush=True)
    write_hub_from_disk()
