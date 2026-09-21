#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
T7+ 召回前端看板 · 后端
名单：wangchuanliang.t7recalllist_0818_0819
触达日：recall_date = 2026-08-18

  export PGPASSWORD='...'
  python3 appendix_t7_0818_dashboard.py
"""
from __future__ import annotations

import json
import os
from pathlib import Path

HERE = Path(__file__).resolve().parent
HTML_PATH = HERE / "T7召回0818前端看板.html"
JSON_PATH = HERE / "t7_0818_dashboard_data.json"
RECALL_DATE = "2026-08-18"
LIST_TABLE = "wangchuanliang.t7recalllist_0818_0819"

U = f"""
SELECT DISTINCT churn_user_id::bigint AS user_id,
       COALESCE(strat, 'NA') AS strat,
       churn_days
FROM {LIST_TABLE}
WHERE churn_user_id IS NOT NULL
  AND recall_date = DATE '{RECALL_DATE}'
"""


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


def fetch():
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
    print("remit day expr", remit_day, flush=True)

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
    for r in due_daily:
        r["n_due"] = int(r["n_due"])
        r["n_od"] = int(r["n_od"])
        remit = float(r["remit"] or 0)
        repaid = float(r["repaid"] or 0)
        r["profit_pct"] = round(100.0 * (repaid - remit) / remit, 2) if remit else None
        r["overdue_pct"] = round(100.0 * r["n_od"] / r["n_due"], 2) if r["n_due"] else None

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


def write_html(data):
    k = data["kpi"]
    payload = json.dumps(data, ensure_ascii=False)

    def fmt(n):
        return f"{int(n):,}"

    def pct(v):
        return "—" if v is None else f"{v:.2f}%"

    html_head = f"""<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>T7 召回前端看板 · 2026-08-18</title>
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
.box{{height:300px;position:relative}}
.foot{{color:#7fa6c2;font-size:12px;margin-top:28px;border-top:1px solid var(--line);padding-top:14px;line-height:1.8}}
@media(max-width:900px){{.kpis,.grid{{grid-template-columns:1fr}}}}
</style>
</head>
<body>
<main class="wrap">
<div class="top">
  <div class="kicker">FRONTEND DASHBOARD · T7+ RECALL · 2026-08-18</div>
  <h1>流失 7 天以上召回 · 前端看板</h1>
  <p class="meta">名单 {fmt(k['n_user'])} 人 · 统计至 {k['as_of']} · 本周 {k['week_start']} 起（周一）<br>
  提单：apply_date≥8/18，用户去重。本周提单=本周任意提单用户；本周新增提单=召回后首次提单落在本周。<br>
  放款：is_remit=1 且 remit_amt&gt;0。到期盈利/逾期：is_due=1 且已放款；逾期=loan_status_code=8。</p>
</div>
<section class="kpis">
  <article class="card"><div class="label">提单率</div><div class="num a">{pct(k['apply_rate'])}</div><div class="sub">{fmt(k['n_apply'])} / {fmt(k['n_user'])} · 8/18至今去重用户</div></article>
  <article class="card"><div class="label">总提单人数</div><div class="num g">{fmt(k['n_apply'])}</div><div class="sub">8/18至今任意提单用户</div></article>
  <article class="card"><div class="label">本周提单人数</div><div class="num">{fmt(k['n_apply_week'])}</div><div class="sub">本周有过提单的去重用户</div></article>
  <article class="card"><div class="label">本周新增提单人数</div><div class="num p">{fmt(k['n_first_week'])}</div><div class="sub">召回后首次提单落在本周</div></article>
  <article class="card"><div class="label">放款单量</div><div class="num g">{fmt(k['n_remit'])}</div><div class="sub">8/18至今已放款订单数</div></article>
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
  <div class="card chart"><h3>按到期日的盈利率</h3><p>当日到期放款单 (repaid−remit)/remit</p><div class="box"><canvas id="c5"></canvas></div></div>
  <div class="card chart"><h3>按到期日的逾期率</h3><p>当日到期单中 loan_status_code=8 占比</p><div class="box"><canvas id="c6"></canvas></div></div>
</div>
<div class="grid" style="margin-top:14px">
  <div class="card chart"><h3>转化结构</h3><p>已提单 vs 尚未提单</p><div class="box"><canvas id="c7"></canvas></div></div>
  <div class="card chart"><h3>本周 vs 累计</h3><p>本周新增提单用户 / 本周提单用户 / 本周放款单量</p><div class="box"><canvas id="c8"></canvas></div></div>
</div>
<div class="grid" style="margin-top:14px">
  <div class="card chart"><h3>分层 strat 提单率</h3><p>人数柱 + 提单率折线</p><div class="box"><canvas id="c9"></canvas></div></div>
  <div class="card chart"><h3>流失天数提单率</h3><p>7–15 / 16–30 / 31–60 / 61–90 / 91–180 / 180d+</p><div class="box"><canvas id="c10"></canvas></div></div>
</div>
<p class="foot">数据：kaby_dw · {LIST_TABLE} · recall_date={RECALL_DATE} · 库内 CURRENT_DATE={k['as_of']}</p>
</main>
<script>
const D = __DATA__;
"""
    html_js = r"""
const col = {cy:'#43c7e7', gr:'#64dcae', am:'#ffc26b', pk:'#f68ab0'};
Chart.defaults.font.family='-apple-system,BlinkMacSystemFont,"PingFang SC","Microsoft YaHei",sans-serif';
Chart.defaults.color='#aac5da';
function base(y2) {
  const scales = {
    x: {ticks:{color:'#aac5da', maxRotation:45}, grid:{display:false}},
    y: {type:'linear', position:'left', ticks:{color:'#aac5da'}, grid:{color:'rgba(42,92,126,.25)'}}
  };
  if (y2) scales.y2 = {type:'linear', position:'right', ticks:{color:'#ffc26b'}, grid:{drawOnChartArea:false}};
  return {responsive:true, maintainAspectRatio:false, interaction:{mode:'index', intersect:false},
    plugins:{legend:{labels:{color:'#eff8ff'}}}, scales};
}
function line(id, labels, datasets, y2) {
  new Chart(document.getElementById(id), {type:'line', data:{labels, datasets}, options:base(y2)});
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
  {label:'到期盈利率%', data:dd.map(x=>x.profit_pct), borderColor:col.gr, tension:.25, pointRadius:2, spanGaps:true}
], false);
line('c6', dd.map(x=>x.d.slice(5)), [
  {label:'到期逾期率%', data:dd.map(x=>x.overdue_pct), borderColor:col.pk, tension:.25, pointRadius:2, spanGaps:true},
  {label:'到期单量', data:dd.map(x=>x.n_due), borderColor:col.cy, tension:.25, yAxisID:'y2', pointRadius:2}
], true);
new Chart(document.getElementById('c7'), {type:'doughnut', data:{labels:['已提单','尚未提单'], datasets:[{data:[k.n_apply, k.n_user-k.n_apply], backgroundColor:[col.gr, 'rgba(42,92,126,.55)'], borderWidth:0}]},
  options:{responsive:true, maintainAspectRatio:false, plugins:{legend:{labels:{color:'#eff8ff'}}}},
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
]}, options:Object.assign(base(true), {layout:{padding:{top:28,right:8}}}),
  plugins:[{id:'rateLabel9', afterDatasetsDraw(chart){ drawRateLabels(chart); }}]});
new Chart(document.getElementById('c10'), {type:'bar', data:{labels:D.churn.map(x=>x.bin), datasets:[
  {label:'名单人数', data:D.churn.map(x=>x.n_user), backgroundColor:'rgba(67,199,231,.35)', yAxisID:'y'},
  {label:'提单率%', data:D.churn.map(x=>x.pct), type:'line', borderColor:col.pk, yAxisID:'y2', tension:.2, pointRadius:3}
]}, options:Object.assign(base(true), {layout:{padding:{top:28,right:8}}}),
  plugins:[{id:'rateLabel10', afterDatasetsDraw(chart){ drawRateLabels(chart); }}]});
</script>
</body></html>
"""
    HTML_PATH.write_text(html_head.replace("__DATA__", payload) + html_js, encoding="utf-8")


if __name__ == "__main__":
    data = fetch()
    JSON_PATH.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    write_html(data)
    print("kpi", data["kpi"])
    print("HTML", HTML_PATH)
