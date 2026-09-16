#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
三层动态资质 × 图1四指标：当日提单率 / 息费 / 逾期率 / 盈利率。

用法（本文件所在目录）：
  export PGPASSWORD='...'
  python3 appendix_t0_tier_fig1.py

依赖：pandas、psycopg2。模型特征 SQL 见 appendix_t0_dynamic_quality_feature_extract.sql。
评分公式与 P30/P60 阈值与《T0动态资质三层与提单率结构验证报告》一致（2025 训练、锁阈值后套 2026）。
图1口径与《T0结清获额后交叉分析报告》一致：自然日首次提单，息费=已放款，逾期/盈利=已放款且已到期。
"""
from __future__ import annotations

import json
import os
from pathlib import Path

import pandas as pd

HERE = Path(__file__).resolve().parent
FEATURE_SQL = HERE / "appendix_t0_dynamic_quality_feature_extract.sql"
OUT_CSV = HERE / "t0_tier_fig1_monthly.csv"
OUT_JSON = HERE / "t0_tier_fig1_monthly.json"

# 三层报告已发布参数（训练样本预测风险 P30 / P60）
P30 = 0.3563149222988503
P60 = 0.3711136188813171

RISK_SQL = """
1.0 / (1.0 + EXP(-(
  -0.5652802238981256
  + (0.0182714389842564 * ((COALESCE(max_credit_apply_amt, 2000.0) - 3708.813462885154) / 4435.428746809324))
  + (-0.0356718241001912 * ((COALESCE(hist_remit_cnt, 2.0) - 3.0983018207282913) / 4.477071675286755))
  + (-0.0356718241001912 * ((COALESCE(hist_settled_cnt, 2.0) - 3.0983018207282913) / 4.477071675286755))
  + (0.010166844650504 * ((COALESCE(hist_overdue_order_cnt, 0.0) - 0.1287640056022408) / 0.4008468962367186))
  + (-0.0010884378745081 * ((COALESCE(hist_max_overdue_days, 0.0) - -1.3855042016806722) / 3.2734854877909365))
  + (-0.0897233469271387 * ((COALESCE(hist_avg_remit_amt, 1000.0) - 1642.5042745050282) / 1835.077924028703))
  + (-0.0648771907524624 * ((COALESCE(hist_total_remit_amt, 1800.0) - 8366.807598039215) / 23495.151922501816))
  + (0.0235588554139508 * ((COALESCE(hist_weighted_interest_rate, 0.4151226038513839) - 0.3830001672326967) / 0.1357819678071449))
  + (-0.0836188087025032 * ((COALESCE(user_loan_tenure_days, 22.0) - 53.39189425770308) / 95.45111751130464))
  + (-0.0240646425788879 * ((COALESCE(days_since_last_repaid, 0.0) - 2.0390406162464987) / 14.127627627627538))
  + (0.0162338489661254 * ((COALESCE(hist_overdue_order_rate, 0.0) - 0.0358033506570425) / 0.1354266535459552))
  + (0.0780277043361126 * ((COALESCE(previous_order_overdue_flag, 0.0) - 0.0340511204481792) / 0.181360529455565))
  + (0.1458843338381181 * ((COALESCE(previous_remit_amt, 1100.0) - 2249.5487570028013) / 2893.8625669892053))
  + (0.043155211445057 * ((COALESCE(previous_interest_rate, 0.4542857142857142) - 0.4200950330686726) / 0.1152955399117681))
)))
"""

T0_SETUP = [
"""
SET statement_timeout = 0
""",
"""
DROP TABLE IF EXISTS tmp_m_origin
""",
"""
CREATE TEMP TABLE tmp_m_origin AS
WITH params AS (
    SELECT DATE '2026-01-01' AS start_date, DATE '2026-09-01' AS end_date
), raw_offer AS (
    SELECT DISTINCT ON (v.user_id, v.serial_id)
        v.user_id, v.serial_id, v.vir_date::date AS vir_date, TO_TIMESTAMP(v.vir_unix) AS vir_time
    FROM wangchuanliang.order_vir_f_copy v
    INNER JOIN wangchuanliang.side_recycle_type_copy r ON r.serial_id = v.serial_id
    CROSS JOIN params p
    WHERE v.is_pass1 = 1 AND v.loan_type_code = 2 AND r.recycle_type = 3
      AND v.vir_date >= p.start_date - 1 AND v.vir_date < p.end_date
    ORDER BY v.user_id, v.serial_id, v.vir_unix DESC
), lagged AS (
    SELECT r.*, LAG(r.vir_time) OVER (PARTITION BY r.user_id ORDER BY r.vir_time, r.serial_id) AS prev_vir_time
    FROM raw_offer r
), batched AS (
    SELECT l.*, SUM(CASE WHEN l.prev_vir_time IS NULL OR l.vir_time - l.prev_vir_time > INTERVAL '20 seconds' THEN 1 ELSE 0 END)
      OVER (PARTITION BY l.user_id ORDER BY l.vir_time, l.serial_id ROWS UNBOUNDED PRECEDING) AS batch_id
    FROM lagged l
), dedup_offer AS (
    SELECT user_id, serial_id, vir_date, vir_time
    FROM (
        SELECT b.*, ROW_NUMBER() OVER (PARTITION BY b.user_id, b.batch_id ORDER BY b.vir_time DESC, b.serial_id DESC) AS batch_rn
        FROM batched b
    ) x
    CROSS JOIN params p
    WHERE batch_rn = 1 AND vir_date >= p.start_date AND vir_date < p.end_date
), candidate_users AS (SELECT DISTINCT user_id FROM dedup_offer),
all_orders AS (
    SELECT o.user_id, o.serial_id, o.apply_time, o.repaid_time, o.repaid_date::date AS repaid_date,
           o.loan_status_code, o.is_remit, o.is_repaid
    FROM wangchuanliang.order_loan_f_v2_copy o
    INNER JOIN candidate_users u ON u.user_id = o.user_id
), clean_settlement AS (
    SELECT o.user_id, o.serial_id, o.repaid_time, o.repaid_date
    FROM all_orders o
    WHERE o.is_remit = 1 AND (o.is_repaid = 1 OR o.loan_status_code = 7)
      AND o.repaid_time > TIMESTAMP '2000-01-01 00:00:00'
      AND NOT EXISTS (
          SELECT 1 FROM all_orders x
          WHERE x.user_id = o.user_id AND x.serial_id <> o.serial_id AND x.apply_time < o.repaid_time
            AND (x.loan_status_code IN (5, 8) OR (x.loan_status_code = 7 AND x.repaid_time > o.repaid_time))
      )
), paired AS (
    SELECT e.user_id, e.serial_id AS credit_serial_id, e.vir_date, e.vir_time,
           ROW_NUMBER() OVER (PARTITION BY e.user_id, e.vir_date ORDER BY e.vir_time ASC, e.serial_id DESC) AS day_rn
    FROM dedup_offer e
    INNER JOIN clean_settlement s
        ON s.user_id = e.user_id AND s.repaid_date = e.vir_date AND e.vir_time >= s.repaid_time
)
SELECT user_id, credit_serial_id, vir_date, vir_time FROM paired WHERE day_rn = 1
""",
"""
DROP TABLE IF EXISTS tmp_first
""",
"""
CREATE TEMP TABLE tmp_first AS
SELECT t.user_id, t.vir_date, t.vir_time,
       o.serial_id, o.apply_date, o.apply_time, o.due_date, o.is_remit, o.remit_amt,
       o.pre_amt, o.post_amt, o.repaid_date,
       CASE
         WHEN o.serial_id IS NULL THEN 'never'
         WHEN o.apply_date = t.vir_date THEN '当日'
         WHEN o.apply_date >= t.vir_date + 1 AND o.apply_date <= t.vir_date + 3 THEN '1-3日'
         WHEN o.apply_date >= t.vir_date + 4 AND o.apply_date <= t.vir_date + 7 THEN '4-7日'
         ELSE '7日以后'
       END AS bucket
FROM tmp_m_origin t
LEFT JOIN (
    SELECT user_id, vir_date, serial_id, apply_date, apply_time, due_date, is_remit, remit_amt, pre_amt, post_amt, repaid_date
    FROM (
        SELECT t.user_id, t.vir_date, a.serial_id, a.apply_date, a.apply_time, a.due_date, a.is_remit,
               a.remit_amt, a.pre_amt, a.post_amt, a.repaid_date,
               ROW_NUMBER() OVER (PARTITION BY t.user_id, t.vir_date ORDER BY a.apply_time, a.serial_id) AS rn
        FROM tmp_m_origin t
        INNER JOIN wangchuanliang.order_loan_f_v2_copy a
          ON a.user_id = t.user_id AND a.apply_time >= t.vir_time
    ) z WHERE rn = 1
) o ON o.user_id = t.user_id AND o.vir_date = t.vir_date
""",
"""
DROP TABLE IF EXISTS tmp_repay
""",
"""
CREATE TEMP TABLE tmp_repay AS
SELECT f.serial_id, SUM(r.amount) AS repay_amt
FROM tmp_first f
INNER JOIN wangchuanliang.repayment_record_copy r ON r.serial_id = f.serial_id
WHERE f.is_remit = 1 AND f.due_date < CURRENT_DATE AND COALESCE(f.remit_amt, 0) > 0
  AND r.payin_date >= f.apply_date AND r.payin_date <= f.due_date
GROUP BY f.serial_id
""",
]


def db_kwargs():
    if not os.environ.get("PGPASSWORD"):
        raise SystemExit("请先设置环境变量 PGPASSWORD")
    import psycopg2  # noqa: F401

    return dict(
        host=os.environ.get("PGHOST", "47.89.225.85"),
        port=int(os.environ.get("PGPORT", "8000")),
        dbname=os.environ.get("PGDATABASE", "kaby_dw"),
        user=os.environ.get("PGUSER", "wangchuanliang_readonly"),
        password=os.environ["PGPASSWORD"],
        connect_timeout=30,
        options="-c statement_timeout=0",
    )


def score_sql() -> str:
    feat = FEATURE_SQL.read_text(encoding="utf-8").strip().rstrip(";")
    if feat.endswith("ORDER BY b.vir_time, b.user_id, b.offer_serial_id"):
        feat = feat[: -len("ORDER BY b.vir_time, b.user_id, b.offer_serial_id")].rstrip()
    feat = feat.replace(
        "DATE '2025-01-01' AS feature_start_date",
        "DATE '2026-01-01' AS feature_start_date",
    )
    return f"""
    WITH feature_data AS (
    {feat}
    )
    SELECT
        user_id,
        vir_date,
        {RISK_SQL} AS predicted_overdue_risk
    FROM feature_data
    WHERE is_score_period = 1
    """


def tier_of(risk: float) -> str:
    if risk <= P30:
        return "资质最好（P0-P30）"
    if risk <= P60:
        return "资质一般（P30-P60）"
    return "资质较差（P60-P100）"


def summarize(df: pd.DataFrame) -> pd.DataFrame:
    due = (
        (df.is_remit == 1)
        & (df.bucket == "当日")
        & df.due_date.notna()
        & (df.due_date < df.as_of_date)
        & (df.remit_amt.fillna(0) > 0)
    )
    remit = (df.is_remit == 1) & (df.bucket == "当日") & (df.remit_amt.fillna(0) > 0)
    od = due & (
        df.repaid_date.isna()
        | (df.repaid_date <= pd.Timestamp("2000-01-01"))
        | (df.repaid_date > df.due_date)
    )
    g = df.groupby(["ym", "tier"], dropna=False)
    rows = []
    for (ym, tier), part in g:
        t0 = len(part)
        d0 = int((part.bucket == "当日").sum())
        rmask = remit.loc[part.index]
        dmask = due.loc[part.index]
        omask = od.loc[part.index]
        remit_sum = float(part.loc[rmask, "remit_amt"].sum())
        fee_num = float((part.loc[rmask, "pre_amt"].fillna(0) + part.loc[rmask, "post_amt"].fillna(0)).sum())
        due_remit = float(part.loc[dmask, "remit_amt"].sum())
        repay_sum = float(part.loc[dmask, "repay_amt"].fillna(0).sum())
        n_due = int(dmask.sum())
        n_od = int(omask.sum())
        rows.append(
            {
                "ym": ym,
                "tier": tier,
                "t0": t0,
                "n_d0": d0,
                "d0_apply_pct": round(100.0 * d0 / t0, 2) if t0 else None,
                "n_remit_d0": int(rmask.sum()),
                "d0_fee_pct": round(100.0 * fee_num / remit_sum, 2) if remit_sum else None,
                "n_due_d0": n_due,
                "d0_od_pct": round(100.0 * n_od / n_due, 2) if n_due else None,
                "d0_profit_pct": round(100.0 * (repay_sum / due_remit - 1), 2) if due_remit else None,
            }
        )
    out = pd.DataFrame(rows).sort_values(["tier", "ym"])
    tot = df.groupby("ym", dropna=False).size().rename("t0_all")
    out = out.merge(tot, on="ym", how="left")
    out["share_pct"] = (100.0 * out.t0 / out.t0_all).round(2)
    return out


def main():
    import psycopg2

    conn = psycopg2.connect(**db_kwargs())
    conn.autocommit = True
    cur = conn.cursor()
    print("1/3 T0 用户日 + 首次提单 + 还款", flush=True)
    for i, stmt in enumerate(T0_SETUP, 1):
        print(f"  setup {i}/{len(T0_SETUP)}", flush=True)
        cur.execute(stmt)
    grain_path = HERE / "t0_tier_fig1_grain.csv"
    print("  copy grain", flush=True)
    with grain_path.open("w", encoding="utf-8", newline="") as f:
        cur.copy_expert(
            """COPY (
        SELECT
          f.user_id, f.vir_date,
          TO_CHAR(f.vir_date, 'YYYY-MM') AS ym,
          f.bucket, f.is_remit, f.remit_amt, f.pre_amt, f.post_amt,
          f.due_date, f.repaid_date, COALESCE(rp.repay_amt, 0) AS repay_amt,
          CURRENT_DATE AS as_of_date
        FROM tmp_first f
        LEFT JOIN tmp_repay rp ON rp.serial_id = f.serial_id
            ) TO STDOUT WITH CSV HEADER""",
            f,
        )
    grain = pd.read_csv(grain_path)
    print("T0 grain", len(grain), flush=True)
    print("2/3 动态资质评分", flush=True)
    score_path = HERE / "t0_tier_fig1_score.csv"
    with score_path.open("w", encoding="utf-8", newline="") as f:
        cur.copy_expert("COPY (" + score_sql() + ") TO STDOUT WITH CSV HEADER", f)
    score = pd.read_csv(score_path)
    print("scored", len(score), flush=True)
    conn.close()

    for col in ["vir_date", "due_date", "repaid_date", "as_of_date"]:
        if col in grain.columns:
            grain[col] = pd.to_datetime(grain[col], errors="coerce")
    score["vir_date"] = pd.to_datetime(score["vir_date"], errors="coerce")
    score["predicted_overdue_risk"] = pd.to_numeric(score["predicted_overdue_risk"], errors="coerce")
    score["tier"] = score["predicted_overdue_risk"].map(tier_of)

    df = grain.merge(score[["user_id", "vir_date", "predicted_overdue_risk", "tier"]], on=["user_id", "vir_date"], how="inner")
    print("inner join", len(df), "unmatched T0", len(grain) - len(df))
    monthly = summarize(df)
    monthly.to_csv(OUT_CSV, index=False, encoding="utf-8-sig")
    payload = {
        "as_of": str(grain.as_of_date.dropna().iloc[0].date()) if len(grain) else None,
        "t0": int(len(df)),
        "unmatched": int(len(grain) - len(df)),
        "p30": P30,
        "p60": P60,
        "rows": monthly.to_dict(orient="records"),
    }
    OUT_JSON.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    print(monthly.to_string(index=False))
    print("写出", OUT_CSV, OUT_JSON)


if __name__ == "__main__":
    main()
