#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
结清0在贷 T0 动态资质模型：训练、落盘复原、全量评分。

用法（在本文件所在目录）：
  export PGPASSWORD='...'
  python3 appendix_t0_dynamic_quality_model.py train    # 抽样本、训练、保存模型
  python3 appendix_t0_dynamic_quality_model.py restore  # 用已公布参数重建模型（不连库也能复原）
  python3 appendix_t0_dynamic_quality_model.py score    # 用已保存模型对 2026-01～08 全量 T0 评分

依赖：pip install pandas numpy scikit-learn psycopg2-binary joblib
数据库：kaby_dw，特征 SQL 见同目录 appendix_t0_dynamic_quality_feature_extract.sql
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path

import joblib
import numpy as np
import pandas as pd
from sklearn.impute import SimpleImputer
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import brier_score_loss, roc_auc_score
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler

HERE = Path(__file__).resolve().parent
SQL_PATH = HERE / "appendix_t0_dynamic_quality_feature_extract.sql"
FEATURE_CSV = HERE / "t0_dynamic_quality_features.csv"
PARAM_CSV = HERE / "appendix_t0_dynamic_quality_model_parameters.csv"
METRICS_CSV = HERE / "t0_dynamic_quality_model_metrics.csv"
MODEL_PATH = HERE / "t0_dynamic_quality_model.joblib"
MONTHLY_CSV = HERE / "t0_dynamic_quality_monthly_2026_01_08.csv"

FEATURES = [
    "max_credit_apply_amt",
    "hist_remit_cnt",
    "hist_settled_cnt",
    "hist_overdue_order_cnt",
    "hist_max_overdue_days",
    "hist_avg_remit_amt",
    "hist_total_remit_amt",
    "hist_weighted_interest_rate",
    "user_loan_tenure_days",
    "days_since_last_repaid",
    "hist_overdue_order_rate",
    "previous_order_overdue_flag",
    "previous_remit_amt",
    "previous_interest_rate",
]

# 报告所用已训练参数（与 appendix_t0_dynamic_quality_model_parameters.csv 一致），用于 restore
PUBLISHED = [
    # feature, impute_median, mean, scale, coefficient
    ("max_credit_apply_amt", 2000.0, 3708.813462885154, 4435.428746809324, 0.020476655589362652),
    ("hist_remit_cnt", 2.0, 3.2574404761904763, 4.465357116416243, -0.04301406276296724),
    ("hist_settled_cnt", 2.0, 3.2574404761904763, 4.465357116416243, -0.04301406276296724),
    ("hist_overdue_order_cnt", 0.0, 0.13567927170868346, 0.4137535203049464, 0.005843026775700361),
    ("hist_max_overdue_days", 0.0, -1.5749299719887955, 3.439501390176089, 0.01269953310922488),
    ("hist_avg_remit_amt", 1050.0, 1745.351945584334, 1832.1757765222574, -0.1502806446478411),
    ("hist_total_remit_amt", 2000.0, 8736.776785714286, 23844.599114780125, -0.05187487848467586),
    ("hist_weighted_interest_rate", 0.4282095890410959, 0.41175598374393535, 0.09052298943422384, -0.00178598395300831),
    ("user_loan_tenure_days", 18.0, 52.38795518207283, 95.86039986608331, -0.09142594304172652),
    ("days_since_last_repaid", 0.0, 0.0, 1.0, 0.0),
    ("hist_overdue_order_rate", 0.0, 0.03768101311920247, 0.13932748260302738, 0.031014087408055557),
    ("previous_order_overdue_flag", 0.0, 0.03405112044817927, 0.181360529455565, 0.06489875849260429),
    ("previous_remit_amt", 1100.0, 2249.5487570028013, 2893.8625669892053, 0.20135304074751187),
    ("previous_interest_rate", 0.45428571428571424, 0.4200950330686726, 0.11529553991176812, 0.05802433716053298),
]
PUBLISHED_INTERCEPT = -0.5655415339997043
PUBLISHED_P30 = 0.3590
PUBLISHED_P60 = 0.3710


def db_kwargs():
    if not os.environ.get("PGPASSWORD"):
        raise SystemExit("请先设置环境变量 PGPASSWORD")
    import psycopg2

    return dict(
        host=os.environ.get("PGHOST", "47.89.225.85"),
        port=int(os.environ.get("PGPORT", "8000")),
        dbname=os.environ.get("PGDATABASE", "kaby_dw"),
        user=os.environ.get("PGUSER", "wangchuanliang_readonly"),
        password=os.environ["PGPASSWORD"],
        connect_timeout=30,
        options="-c statement_timeout=900000",
    )


def connect():
    import psycopg2

    return psycopg2.connect(**db_kwargs())


def wrap_train_sql(base_sql: str) -> str:
    inner = base_sql.strip().rstrip(";")
    return (
        "WITH feature_data AS (" + inner + ") "
        "SELECT user_id, max_credit_apply_amt, hist_remit_cnt, hist_settled_cnt, "
        "hist_overdue_order_cnt, hist_max_overdue_days, hist_avg_remit_amt, "
        "hist_total_remit_amt, hist_weighted_interest_rate, user_loan_tenure_days, "
        "days_since_last_repaid, hist_overdue_order_rate, previous_order_overdue_flag, "
        "previous_remit_amt, previous_interest_rate, next_order_overdue_label, vir_date "
        "FROM feature_data "
        "WHERE is_train_period = 1 AND is_mature_label_sample = 1 "
        "AND MOD(user_id, 10) = 0"
    )


def export_train_features():
    sql = wrap_train_sql(SQL_PATH.read_text(encoding="utf-8"))
    with connect() as conn:
        with conn.cursor() as cur, FEATURE_CSV.open("w", encoding="utf-8", newline="") as f:
            cur.copy_expert(f"COPY ({sql}) TO STDOUT WITH CSV HEADER", f)
    print("特征样本已写出", FEATURE_CSV)


def make_pipeline():
    return Pipeline(
        [
            ("impute", SimpleImputer(strategy="median")),
            ("scale", StandardScaler()),
            ("logit", LogisticRegression(max_iter=1000, C=0.5, solver="lbfgs")),
        ]
    )


def train():
    export_train_features()
    df = pd.read_csv(FEATURE_CSV)
    for col in FEATURES + ["next_order_overdue_label"]:
        df[col] = pd.to_numeric(df[col], errors="coerce")
    df["vir_date"] = pd.to_datetime(df["vir_date"])
    train_all = df[df.next_order_overdue_label.notna()].copy()
    fit = train_all[train_all.vir_date < pd.Timestamp("2025-10-01")]
    valid = train_all[train_all.vir_date >= pd.Timestamp("2025-10-01")]

    probe = make_pipeline()
    probe.fit(fit[FEATURES], fit.next_order_overdue_label.astype(int))

    def evaluate(name, part, model):
        p = model.predict_proba(part[FEATURES])[:, 1]
        return {
            "样本": name,
            "样本量": len(part),
            "逾期率": float(part.next_order_overdue_label.mean()),
            "AUC": float(roc_auc_score(part.next_order_overdue_label, p)),
            "Brier": float(brier_score_loss(part.next_order_overdue_label, p)),
        }

    metrics = pd.DataFrame(
        [
            evaluate("训练期_2025_01_09", fit, probe),
            evaluate("时间外验证_2025_10_12", valid, probe),
        ]
    )

    final_model = make_pipeline()
    final_model.fit(train_all[FEATURES], train_all.next_order_overdue_label.astype(int))
    train_risk = final_model.predict_proba(train_all[FEATURES])[:, 1]
    p30 = float(np.quantile(train_risk, 0.30))
    p60 = float(np.quantile(train_risk, 0.60))
    metrics["资质最好阈值_预测逾期风险P30"] = p30
    metrics["资质一般上限_预测逾期风险P60"] = p60

    logit = final_model.named_steps["logit"]
    scaler = final_model.named_steps["scale"]
    imputer = final_model.named_steps["impute"]
    params = pd.DataFrame(
        {
            "feature": FEATURES,
            "impute_median": imputer.statistics_,
            "mean": scaler.mean_,
            "scale": scaler.scale_,
            "coefficient": logit.coef_[0],
        }
    )
    params.loc[len(params)] = ["intercept", 0, 0, 1, logit.intercept_[0]]
    params.to_csv(PARAM_CSV, index=False, encoding="utf-8-sig")
    metrics.to_csv(METRICS_CSV, index=False, encoding="utf-8-sig")
    joblib.dump({"model": final_model, "features": FEATURES, "p30": p30, "p60": p60}, MODEL_PATH)
    print(metrics.to_string(index=False))
    print("P30", p30, "P60", p60)
    print("模型已保存", MODEL_PATH)


def restore_from_params(rows=None, intercept=None, p30=None, p60=None):
    """不重新训练：用标准化逻辑回归参数重建可 predict_proba 的 Pipeline。"""
    if rows is None:
        if PARAM_CSV.exists():
            pdf = pd.read_csv(PARAM_CSV, encoding="utf-8-sig")
            coef_row = pdf[pdf.feature == "intercept"].iloc[0]
            intercept = float(coef_row.coefficient)
            pdf = pdf[pdf.feature != "intercept"]
            med = pdf.impute_median.to_numpy(dtype=float)
            mean = pdf["mean"].to_numpy(dtype=float)
            scale = pdf["scale"].to_numpy(dtype=float)
            coef = pdf.coefficient.to_numpy(dtype=float)
            feats = pdf.feature.tolist()
        else:
            intercept = PUBLISHED_INTERCEPT
            feats = [r[0] for r in PUBLISHED]
            med = np.array([r[1] for r in PUBLISHED], dtype=float)
            mean = np.array([r[2] for r in PUBLISHED], dtype=float)
            scale = np.array([r[3] for r in PUBLISHED], dtype=float)
            coef = np.array([r[4] for r in PUBLISHED], dtype=float)
        p30 = PUBLISHED_P30 if p30 is None else p30
        p60 = PUBLISHED_P60 if p60 is None else p60
    else:
        feats = FEATURES
        med = np.array([r[1] for r in rows], dtype=float)
        mean = np.array([r[2] for r in rows], dtype=float)
        scale = np.array([r[3] for r in rows], dtype=float)
        coef = np.array([r[4] for r in rows], dtype=float)
        intercept = PUBLISHED_INTERCEPT if intercept is None else intercept
        p30 = PUBLISHED_P30 if p30 is None else p30
        p60 = PUBLISHED_P60 if p60 is None else p60

    n = len(feats)
    imputer = SimpleImputer(strategy="median")
    imputer.statistics_ = med
    imputer.n_features_in_ = n
    imputer.feature_names_in_ = np.array(feats, dtype=object)

    scaler = StandardScaler()
    scaler.mean_ = mean
    scaler.scale_ = np.where(scale == 0, 1.0, scale)
    scaler.var_ = scaler.scale_ ** 2
    scaler.n_features_in_ = n
    scaler.n_samples_seen_ = 1
    scaler.feature_names_in_ = np.array(feats, dtype=object)

    logit = LogisticRegression(max_iter=1000, C=0.5, solver="lbfgs")
    logit.classes_ = np.array([0, 1])
    logit.coef_ = coef.reshape(1, -1)
    logit.intercept_ = np.array([intercept], dtype=float)
    logit.n_features_in_ = n
    logit.feature_names_in_ = np.array(feats, dtype=object)

    model = Pipeline([("impute", imputer), ("scale", scaler), ("logit", logit)])
    bundle = {"model": model, "features": feats, "p30": p30, "p60": p60}
    joblib.dump(bundle, MODEL_PATH)
    print("已从参数复原模型", MODEL_PATH, "P30", p30, "P60", p60)
    return bundle


def load_model():
    if MODEL_PATH.exists():
        return joblib.load(MODEL_PATH)
    return restore_from_params()


def score_2026():
    bundle = load_model()
    model = bundle["model"]
    p30, p60 = bundle["p30"], bundle["p60"]
    base_sql = SQL_PATH.read_text(encoding="utf-8").strip().rstrip(";")
    sql = f"""
    WITH feature_data AS (
    {base_sql}
    )
    SELECT
        TO_CHAR(vir_date, 'YYYY-MM') AS ym,
        is_t0_apply,
        max_credit_apply_amt, hist_remit_cnt, hist_settled_cnt,
        hist_overdue_order_cnt, hist_max_overdue_days, hist_avg_remit_amt,
        hist_total_remit_amt, hist_weighted_interest_rate, user_loan_tenure_days,
        days_since_last_repaid, hist_overdue_order_rate, previous_order_overdue_flag,
        previous_remit_amt, previous_interest_rate
    FROM feature_data
    WHERE is_score_period = 1
    """
    with connect() as conn:
        df = pd.read_sql_query(sql, conn)
    for col in FEATURES:
        df[col] = pd.to_numeric(df[col], errors="coerce")
    df["predicted_overdue_risk"] = model.predict_proba(df[FEATURES])[:, 1]
    df["tier"] = np.where(
        df.predicted_overdue_risk <= p30,
        "资质最好（P0-P30）",
        np.where(df.predicted_overdue_risk <= p60, "资质一般（P30-P60）", "资质较差（P60-P100）"),
    )
    monthly = (
        df.groupby(["ym", "tier"], dropna=False)
        .agg(t0=("is_t0_apply", "size"), apply=("is_t0_apply", "sum"), risk=("predicted_overdue_risk", "mean"))
        .reset_index()
    )
    monthly["apply_rate"] = monthly["apply"] / monthly["t0"]
    monthly.to_csv(MONTHLY_CSV, index=False, encoding="utf-8-sig")
    print(monthly.to_string(index=False))
    print("月度结果", MONTHLY_CSV)


def main():
    parser = argparse.ArgumentParser(description="T0 动态资质模型：训练 / 复原 / 评分")
    parser.add_argument("cmd", choices=["train", "restore", "score"])
    args = parser.parse_args()
    if args.cmd == "train":
        train()
    elif args.cmd == "restore":
        restore_from_params()
    else:
        score_2026()


if __name__ == "__main__":
    main()
