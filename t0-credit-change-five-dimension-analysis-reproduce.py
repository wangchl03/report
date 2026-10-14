#!/usr/bin/env python3
"""Offline, exhaustive six-label analysis with D0-first-order postloan metrics of an already validated T0 cube.

Usage: python3 analyze.py --input cube.json --output analysis.json

This program never connects to a database, publishes content, or creates Excel
files. The source cube's metric definition and upstream audit are preserved.
Rates and shares are fractions; every difference/decomposition is in pp.
Only Jan--Sep enter complete-month comparisons. October is retained separately.
"""

from __future__ import annotations

import argparse
import hashlib
import itertools
import json
import math
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from decimal import Decimal
from typing import Any


MONTHS = tuple(f"2026-{m:02d}" for m in range(1, 11))
COMPLETE_MONTHS = MONTHS[:9]
JAN, SEP, OCT = 0, 8, 9
DIMENSIONS = ("base_band", "loan_band", "score_band", "fee_band", "daily_band", "score_new_band")
LEGACY_DIMENSIONS = DIMENSIONS[:5]
ADDITIVE = ("n", "y", "funded_n", "due_n", "overdue_n", "remit_cents", "repaid_cents", "repaid_missing_n", "status_missing_n")
CUBE_FIELDS = ("credit_type", "amount_band") + DIMENSIONS
SCOPES = {
    "overall": (),
    "credit_type": ("credit_type",),
    "amount_band": ("amount_band",),
    "credit_type_amount": ("credit_type", "amount_band"),
}
DEFAULT_LABELS = {
    "credit_type": ["增加", "降低", "不变"],
    "amount_band": ["<500", "500–1000", "1000–2000", "2000–3000", "≥3000"],
    "base_band": ["0–1000", "1000–2000", "2000–5000", "5000–10000", "≥10000"],
    "loan_band": ["1次", "2次", "3次", "4次", "5次", ">5次", "缺失/无效"],
    "score_band": ["1–529", "529–569", "569–3000", "缺失", "无效", "冲突"],
    "fee_band": ["增加0–5pp", "增加5–10pp", "增加≥10pp", "不变", "减少0–5pp", "减少5–10pp", "减少≥10pp", "缺失"],
    "daily_band": ["增加0–0.25pp", "增加0.25–0.5pp", "增加≥0.5pp", "不变", "减少0–0.25pp", "减少0.25–0.5pp", "减少≥0.5pp", "缺失"],
}
DEFAULT_LABELS["score_new_band"] = ["<505", "505–535", "≥535", "缺失", "无效", "冲突"]
EPSILON = 1e-10


def empty_counts() -> dict[str, list[int]]:
    return {field: [0] * len(MONTHS) for field in ADDITIVE}





def ratio(y: int, n: int) -> float | None:
    return y / n if n else None


def pp_difference(new: float | None, old: float | None) -> float | None:
    return 100.0 * (new - old) if new is not None and old is not None else None


def integer_count(value: Any, row_number: int, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"source row {row_number}: {field} must be an integer count")
    if not math.isfinite(value) or value != int(value) or value < 0:
        raise ValueError(f"source row {row_number}: invalid {field}={value!r}")
    return int(value)


def normalize_category(value: Any, field: str) -> str:
    # Preserve explicit Chinese missing/invalid/conflict labels independently.
    if value is None or (isinstance(value, str) and not value.strip()):
        return "缺失/无效" if field == "loan_band" else "缺失"
    if not isinstance(value, str):
        raise ValueError(f"{field} must be a category string, got {value!r}")
    return value.strip()


def read_source(path: Path):
    if path.suffix.lower() == ".csv":
        import csv
        payload = {"metadata": {"labels": DEFAULT_LABELS}, "audit": {}, "rows": [], "controls": []}
        with path.open(encoding="utf-8-sig", newline="") as source:
            for record in csv.DictReader(source):
                value = json.loads(record["payload"])
                kind = record["kind"]
                if kind == "cube":
                    payload["rows"].append(value)
                elif kind == "audit":
                    payload["audit"][value["key"]] = value["n"]
                elif kind in ("control", "controls"):
                    payload["controls"].append(value)
                elif kind == "metadata":
                    payload["metadata"].update(value)
    else:
        with path.open(encoding="utf-8") as source:
            payload = json.load(source)
    if not isinstance(payload, dict) or not isinstance(payload.get("rows"), list):
        raise ValueError("input must contain rows and optional metadata/audit/controls")
    metadata = payload.get("metadata", {})
    accumulators = {}
    observed = {field: set() for field in CUBE_FIELDS}
    for row_number, raw in enumerate(payload["rows"], 1):
        if raw.get("month") not in MONTHS:
            raise ValueError(f"row {row_number}: month is outside Jan--Oct 2026")
        missing_fields = [field for field in CUBE_FIELDS if field not in raw]
        if missing_fields:
            raise ValueError(f"row {row_number}: missing cube fields {missing_fields}")
        categories = tuple(normalize_category(raw[field], field) for field in CUBE_FIELDS)
        stats = {"n": integer_count(raw.get("n"), row_number, "n"), "y": integer_count(raw.get("y"), row_number, "y")}
        for field in ("funded_n", "due_n", "overdue_n", "repaid_missing_n", "status_missing_n"):
            stats[field] = integer_count(raw.get("d0_" + field), row_number, "d0_" + field)
        for field in ("remit", "repaid"):
            value = raw.get("d0_" + field + "_amt")
            if value is None:
                if field == "repaid" and stats["repaid_missing_n"]:
                    stats[field + "_cents"] = 0
                    continue
                raise ValueError(f"row {row_number}: unflagged null {field} amount")
            cents = Decimal(str(value)) * 100
            if not cents.is_finite() or cents != cents.to_integral_value():
                raise ValueError(f"row {row_number}: money must be finite MXN cents")
            stats[field + "_cents"] = int(cents)
        if not 0 <= stats["overdue_n"] <= stats["due_n"] <= stats["funded_n"] <= stats["y"] <= stats["n"]:
            raise ValueError(f"row {row_number}: D0/postloan count hierarchy violated")
        for field, category in zip(CUBE_FIELDS, categories):
            observed[field].add(category)
        key = (raw["month"],) + categories
        target = accumulators.setdefault(key, {field: 0 for field in ADDITIVE})
        for field in ADDITIVE:
            target[field] += stats[field]
    supplied = metadata.get("labels", {})
    labels = {}
    extra = {}
    for field in CUBE_FIELDS:
        labels[field] = list(dict.fromkeys(supplied.get(field, DEFAULT_LABELS[field])))
        extras = sorted(observed[field] - set(labels[field]))
        labels[field].extend(extras)
        if extras:
            extra[field] = extras
    ordering = {field: {v: i for i, v in enumerate(labels[field])} for field in CUBE_FIELDS}
    rows = [dict(zip(("month",) + CUBE_FIELDS, key), **stats) for key, stats in accumulators.items()]
    rows.sort(key=lambda row: (row["month"],) + tuple(ordering[field][row[field]] for field in CUBE_FIELDS))
    overall = aggregate(rows, ())[()]
    control_checks = 0
    mapping = {"n": "n", "y": "y", "funded_n": "d0_funded_n", "due_n": "d0_due_n",
               "overdue_n": "d0_overdue_n", "remit_cents": "d0_remit_amt", "repaid_cents": "d0_repaid_amt"}
    for control in payload.get("controls", []):
        if control["month"] not in MONTHS:
            continue
        index = MONTHS.index(control["month"])
        for field, source_field in mapping.items():
            expected = control[source_field]
            if field.endswith("_cents"):
                expected = int(Decimal(str(expected or 0)) * 100)
            if overall[field][index] != expected:
                raise AssertionError(f"SQL control mismatch: {control['month']} {field}")
            control_checks += 1
    audit = payload.get("audit", {})
    for key in ("重复事件键", "重复提单归属", "D0窗口异常", "财务同键字段冲突", "D0提单财务未匹配"):
        if audit.get(key, 0):
            raise ValueError(f"upstream event/financial audit failed: {key}")
    result_audit = {"input_rows": len(payload["rows"]), "normalized_cube_rows": len(rows),
                    "duplicate_cube_rows_merged": len(payload["rows"]) - len(rows),
                    "input_n": sum(row["n"] for row in rows), "input_y": sum(row["y"] for row in rows),
                    "normalized_n": sum(row["n"] for row in rows), "normalized_y": sum(row["y"] for row in rows),
                    "unexpected_categories_preserved": extra, "sql_control_checks": control_checks,
                    "money_arithmetic": "integer MXN cents; no mean of cell profit ratios",
                    "source_metric_and_maturity_validation": "upstream event audit retained; current due-order subset is distinct from the T0 denominator"}
    return metadata, audit, rows, labels, result_audit





def aggregate(rows, fields):
    result = {}
    for row in rows:
        key = tuple(row[field] for field in fields)
        target = result.get(key)
        if target is None:
            target = empty_counts()
            result[key] = target
        index = MONTHS.index(row["month"])
        for field in ADDITIVE:
            target[field][index] += row[field]
    return result





def context_keys(scope: str, labels: dict[str, list[str]]) -> list[tuple[str, ...]]:
    fields = SCOPES[scope]
    return list(itertools.product(*(labels[field] for field in fields))) if fields else [()]


def context_id(scope: str, values: tuple[str, ...]) -> str:
    return scope + ":" + json.dumps(values, ensure_ascii=False, separators=(",", ":"))


def stable_group_id(projection_id: str, parent_id: str, values: tuple[str, ...]) -> str:
    identity = json.dumps([projection_id, parent_id, values], ensure_ascii=False, separators=(",", ":"))
    return hashlib.sha256(identity.encode("utf-8")).hexdigest()[:20]


def rates(counts: dict[str, list[int]]) -> list[float | None]:
    return [ratio(y, n) for n, y in zip(counts["n"], counts["y"])]


def conversion_comparison(counts: dict[str, list[int]], parent: dict[str, list[int]], minimum_n: int, review_indices: list[int]) -> dict[str, Any]:
    n, y = counts["n"], counts["y"]
    r = rates(counts)
    w_jan, w_sep = ratio(n[JAN], parent["n"][JAN]), ratio(n[SEP], parent["n"][SEP])
    state = "shared" if n[JAN] and n[SEP] else "new" if n[SEP] else "disappeared" if n[JAN] else "absent_at_both_endpoints"
    net = within = mix = entry_exit = None
    if w_jan is not None and w_sep is not None:
        # y/N handles absent groups without inventing an absent group's rate.
        net = 100.0 * (y[SEP] / parent["n"][SEP] - y[JAN] / parent["n"][JAN])
        if state == "shared":
            within = 100.0 * ((w_sep + w_jan) / 2.0) * (r[SEP] - r[JAN])
            mix = 100.0 * ((r[SEP] + r[JAN]) / 2.0) * (w_sep - w_jan)
            entry_exit = 0.0
        else:
            entry_exit = net
    eligible = n[JAN] >= minimum_n and n[SEP] >= minimum_n
    review_valid = [n[JAN] >= minimum_n and n[index] >= minimum_n for index in review_indices]
    review_deltas = [pp_difference(r[index], r[JAN]) for index in review_indices]
    if not all(review_valid):
        review_status = "insufficient_sample"
    elif all(value is not None and value < -EPSILON for value in review_deltas):
        review_status = "all_below_jan"
    elif all(value is not None and value > EPSILON for value in review_deltas):
        review_status = "all_above_jan"
    else:
        review_status = "mixed_or_flat"
    decline_streak = increase_streak = 0
    for index in range(SEP, JAN, -1):
        if n[index] < minimum_n or n[index - 1] < minimum_n:
            break
        change = pp_difference(r[index], r[index - 1])
        if change is not None and change < -EPSILON:
            decline_streak += 1
        else:
            break
    for index in range(SEP, JAN, -1):
        if n[index] < minimum_n or n[index - 1] < minimum_n:
            break
        change = pp_difference(r[index], r[index - 1])
        if change is not None and change > EPSILON:
            increase_streak += 1
        else:
            break
    delta = pp_difference(r[SEP], r[JAN])
    return {
        "nJan": n[JAN], "nSep": n[SEP], "yJan": y[JAN], "ySep": y[SEP],
        "rJan": r[JAN], "rSep": r[SEP], "wJan": w_jan, "wSep": w_sep,
        "delta": delta, "net": net, "within": within, "mix": mix,
        "entry_exit": entry_exit, "state": state, "eligible": eligible,
        "confirmed_negative": eligible and review_status == "all_below_jan",
        "confirmed_positive": eligible and review_status == "all_above_jan",
        "positive_net_declining_rate": eligible and net is not None and net > EPSILON and delta is not None and delta < -EPSILON,
        "negative_net_improving_rate": eligible and net is not None and net < -EPSILON and delta is not None and delta > EPSILON,
        "review": {
            "months": [MONTHS[index] for index in review_indices],
            "n": [n[index] for index in review_indices],
            "rate": [r[index] for index in review_indices],
            "delta_jan": review_deltas,
            "delta_previous": [pp_difference(r[index], r[index - 1]) if index else None for index in review_indices],
            "qualified_against_jan": review_valid,
            "qualified_against_previous": [bool(index and n[index] >= minimum_n and n[index - 1] >= minimum_n) for index in review_indices],
            "status": review_status,
            "latest_monthly_decline_streak": decline_streak,
            "latest_monthly_increase_streak": increase_streak,
        },
        "partial_october": {"n": n[OCT], "y": y[OCT], "rate": r[OCT], "delta_jan": pp_difference(r[OCT], r[JAN]), "is_partial": True},
    }


def conversion_rank_groups(groups: list[dict[str, Any]], negative_k: int, positive_k: int, minimum_n: int) -> dict[str, list[str]]:
    eligible = [group for group in groups if group["eligible"]]
    rules = {
        "negative_rate": (lambda g: g["delta"] < -EPSILON, "delta", False, negative_k),
        "positive_rate": (lambda g: g["delta"] > EPSILON, "delta", True, positive_k),
        "negative_net": (lambda g: g["net"] is not None and g["net"] < -EPSILON, "net", False, negative_k),
        "positive_net": (lambda g: g["net"] is not None and g["net"] > EPSILON, "net", True, positive_k),
        "confirmed_negative_rate": (lambda g: g["confirmed_negative"], "delta", False, negative_k),
        "confirmed_positive_rate": (lambda g: g["confirmed_positive"], "delta", True, positive_k),
        "positive_net_declining_rate": (lambda g: g["positive_net_declining_rate"], "net", True, positive_k),
        "negative_net_improving_rate": (lambda g: g["negative_net_improving_rate"], "net", False, negative_k),
    }
    result = {}
    for name, (predicate, field, reverse, limit) in rules.items():
        selected = sorted((group for group in eligible if predicate(group)), key=lambda group: (group[field], group["id"]), reverse=reverse)
        result[name] = [group["id"] for group in selected[:limit]]
    # These rate-change candidates require complete known categories and all
    # consecutive review months to confirm the endpoint direction. Statistical
    # rankings above retain missing groups for transparent accounting.
    result["top_neg"] = [g["id"] for g in sorted((g for g in eligible if g["known_complete"] and g["confirmed_negative"]), key=lambda g: (g["delta"], g["id"]))[:negative_k]]
    result["top_pos"] = [g["id"] for g in sorted((g for g in eligible if g["known_complete"] and g["confirmed_positive"]), key=lambda g: (g["delta"], g["id"]), reverse=True)[:positive_k]]
    result["new_groups"] = [g["id"] for g in sorted((g for g in groups if g["state"] == "new" and g["nSep"] >= minimum_n and g["net"] is not None), key=lambda g: g["net"], reverse=True)[:positive_k]]
    result["disappeared_groups"] = [g["id"] for g in sorted((g for g in groups if g["state"] == "disappeared" and g["nJan"] >= minimum_n and g["net"] is not None), key=lambda g: g["net"])[:negative_k]]
    return result


def conversion_decomposition_audit(groups: list[dict[str, Any]], parent: dict[str, list[int]]) -> dict[str, Any]:
    expected = pp_difference(ratio(parent["y"][SEP], parent["n"][SEP]), ratio(parent["y"][JAN], parent["n"][JAN]))
    valid = expected is not None
    totals = {field: math.fsum(group[field] for group in groups if group[field] is not None) if valid else None for field in ("net", "within", "mix", "entry_exit")}
    residual = totals["net"] - expected if valid else None
    decomposition_residual = totals["within"] + totals["mix"] + totals["entry_exit"] - expected if valid else None
    for index in range(len(MONTHS)):
        if sum(group["n_by_month"][index] for group in groups) != parent["n"][index]:
            raise AssertionError(f"projection denominator changed for {MONTHS[index]}")
        if sum(group["y_by_month"][index] for group in groups) != parent["y"][index]:
            raise AssertionError(f"projection numerator changed for {MONTHS[index]}")
    if valid and (abs(residual) > EPSILON or abs(decomposition_residual) > EPSILON):
        raise AssertionError("non-overlapping group contribution does not reconcile to parent delta")
    return {
        "total_delta_pp": expected,
        "sum_net_pp": totals["net"], "sum_within_pp": totals["within"],
        "sum_mix_pp": totals["mix"], "sum_entry_exit_pp": totals["entry_exit"],
        "net_residual_pp": residual, "decomposition_residual_pp": decomposition_residual,
        "all_month_counts_reconcile": True, "contribution_available": valid,
        "cross_projection_addition_allowed": False,
    }


def make_views(rows: list[dict[str, Any]], labels: dict[str, list[str]], scope_totals: dict[str, dict[tuple[str, ...], dict[str, list[int]]]]) -> dict[str, Any]:
    views: dict[str, Any] = {"months": list(MONTHS), "dimensions": {}, "totals": []}
    population = scope_totals["overall"].get((), empty_counts())
    view_scopes = ("overall", "credit_type", "credit_type_amount")

    def view_row(scope: str, parent_values: tuple[str, ...], dimension: str | None, level: str, is_total: bool, counts: dict[str, list[int]], parent: dict[str, list[int]], index: int) -> dict[str, Any]:
        filters = dict(zip(SCOPES[scope], parent_values))
        r_jan = ratio(counts["y"][JAN], counts["n"][JAN])
        current_rate = ratio(counts["y"][index], counts["n"][index])
        return {
            "month": MONTHS[index], "scope": scope,
            "credit_type": filters.get("credit_type", "整体"),
            "amount_band": filters.get("amount_band", "总计"),
            "dimension": dimension, "level": level, "is_total": is_total,
            "n": counts["n"][index], "y": counts["y"][index],
            "parent_n": parent["n"][index],
            "share": ratio(counts["n"][index], parent["n"][index]),
            "rate": current_rate, "delta_jan": pp_difference(current_rate, r_jan),
            "population_n": population["n"][index],
            "population_share": ratio(counts["n"][index], population["n"][index]),
            "is_partial": index == OCT,
            **view_finance(counts, index),
        }

    for scope in view_scopes:
        for parent_values in context_keys(scope, labels):
            parent = scope_totals[scope].get(parent_values, empty_counts())
            for index in range(len(MONTHS)):
                views["totals"].append(view_row(scope, parent_values, None, "全部", True, parent, parent, index))
    for dimension in DIMENSIONS:
        view_rows = []
        for scope in view_scopes:
            classified = aggregate(rows, SCOPES[scope] + (dimension,))
            for parent_values in context_keys(scope, labels):
                parent = scope_totals[scope].get(parent_values, empty_counts())
                for index in range(len(MONTHS)):
                    view_rows.append(view_row(scope, parent_values, dimension, "全部", True, parent, parent, index))
                for level in labels[dimension]:
                    counts = classified.get(parent_values + (level,), empty_counts())
                    for index in range(len(MONTHS)):
                        view_rows.append(view_row(scope, parent_values, dimension, level, False, counts, parent, index))
        views["dimensions"][dimension] = view_rows
    return views


def make_projections(rows, labels, scope_totals, minimum_n, review_indices, negative_k, positive_k):
    projections = []
    label_order = {field: {value: i for i, value in enumerate(labels[field])} for field in CUBE_FIELDS}
    for order in range(1, 7):
        for dimensions in itertools.combinations(DIMENSIONS, order):
            redundant = "score_band" in dimensions and "score_new_band" in dimensions
            subset_id = "__".join(dimensions)
            for scope, extension_fields in SCOPES.items():
                projection_id = subset_id + "@" + scope
                aggregated = aggregate(rows, extension_fields + dimensions)
                by_parent = defaultdict(dict)
                for values, counts in aggregated.items():
                    by_parent[values[:len(extension_fields)]][values[len(extension_fields):]] = counts
                contexts = []
                for parent_values in context_keys(scope, labels):
                    parent = scope_totals[scope].get(parent_values, empty_counts())
                    parent_id = context_id(scope, parent_values)
                    members = by_parent.get(parent_values, {})
                    if order == 1:
                        members = {**{(level,): empty_counts() for level in labels[dimensions[0]]}, **members}
                    ordered = sorted(members, key=lambda values: tuple(label_order[field][value] for field, value in zip(dimensions, values)))
                    groups = []
                    for values in ordered:
                        counts = members[values]
                        known = not any(any(token in value for token in ("缺失", "无效", "冲突")) for value in values)
                        groups.append({"id": stable_group_id(projection_id, parent_id, values),
                                       "levels": list(values), "key": dict(zip(dimensions, values)),
                                       "n_by_month": counts["n"], "y_by_month": counts["y"],
                                       "contains_missing": any("缺失" in value for value in values),
                                       "contains_invalid_or_conflict": any("无效" in value or "冲突" in value for value in values),
                                       "known_complete": known, "redundant_score_labels": redundant,
                                       "effective_factor_count": order - int(redundant),
                                       **compare_group(counts, parent, minimum_n, review_indices)})
                    contexts.append({"id": parent_id, "filters": dict(zip(extension_fields, parent_values)),
                                     "n_by_month": parent["n"], "y_by_month": parent["y"],
                                     "rate_by_month": rates(parent), "postloan": postloan_payload(parent),
                                     "groups": groups, "rankings": rank_groups(groups, negative_k, positive_k, minimum_n),
                                     "audit": decomposition_audit(groups, parent),
                                     "group_count": len(groups), "eligible_group_count": sum(g["eligible"] for g in groups),
                                     "financial_eligible_group_count": sum(g["financial_eligible"] for g in groups),
                                     "confirmed_negative_group_count": sum(g["confirmed_negative"] for g in groups),
                                     "confirmed_positive_group_count": sum(g["confirmed_positive"] for g in groups)})
                projections.append({"id": projection_id, "subset_id": subset_id, "dimensions": list(dimensions),
                                    "order": order, "scope": scope, "extension_fields": list(extension_fields),
                                    "redundant_score_labels": redundant, "effective_factor_count": order-int(redundant),
                                    "contexts": contexts})
    return projections





def make_matrices(projections: list[dict[str, Any]], labels: dict[str, list[str]], minimum_n: int, review_indices: list[int]) -> list[dict[str, Any]]:
    matrices = []
    for projection in projections:
        if projection["order"] != 2 or projection["scope"] != "overall":
            continue
        row_dimension, column_dimension = projection["dimensions"]
        context = projection["contexts"][0]
        by_levels = {tuple(group["levels"]): group for group in context["groups"]}
        parent = {"n": context["n_by_month"], "y": context["y_by_month"]}
        cells = []
        for row_level, column_level in itertools.product(labels[row_dimension], labels[column_dimension]):
            group = by_levels.get((row_level, column_level))
            if group is None:
                zero = empty_counts()
                group = {"id": None, "levels": [row_level, column_level], "n_by_month": zero["n"], "y_by_month": zero["y"], **compare_group(zero, parent, minimum_n, review_indices)}
            cells.append({
                "row": row_level, "column": column_level, "group_id": group["id"],
                "n_by_month": group["n_by_month"], "y_by_month": group["y_by_month"],
                "postloan": group["postloan"], "financial_eligible": group["financial_eligible"],
                "profit_delta": group["profit_delta"], "overdue_delta": group["overdue_delta"],
                **{field: group[field] for field in ("nJan", "nSep", "rJan", "rSep", "delta", "net", "within", "mix", "entry_exit", "state", "eligible")},
            })
        matrices.append({"id": projection["subset_id"], "projection_id": projection["id"], "context_id": context["id"], "row_dimension": row_dimension, "column_dimension": column_dimension, "row_levels": labels[row_dimension], "column_levels": labels[column_dimension], "cells": cells, "includes_zero_cells": True})
    if len(matrices) != 15:
        raise AssertionError("expected all fifteen two-dimensional matrices")
    return matrices


def make_combinations(projections, negative_k, positive_k):
    result = {}
    for order, name in ((0, "all_known"), (3, "three_way"), (5, "five_way"), (6, "six_way")):
        candidates = []
        for projection in projections:
            if order and projection["order"] != order:
                continue
            if order == 0 and (projection["order"] < 2 or projection["redundant_score_labels"]):
                continue
            for context in projection["contexts"]:
                for group in context["groups"]:
                    if group["eligible"] and group["known_complete"]:
                        candidates.append(compact_group(projection, context, group))
        rules = {"negative_rate": (lambda g: g["delta"] < -EPSILON, "delta", False, negative_k),
                 "positive_rate": (lambda g: g["delta"] > EPSILON, "delta", True, positive_k),
                 "negative_net": (lambda g: g["net"] is not None and g["net"] < -EPSILON, "net", False, negative_k),
                 "positive_net": (lambda g: g["net"] is not None and g["net"] > EPSILON, "net", True, positive_k),
                 "top_neg": (lambda g: g["confirmed_negative"], "delta", False, negative_k),
                 "top_pos": (lambda g: g["confirmed_positive"], "delta", True, positive_k),
                 "positive_net_declining_rate": (lambda g: g["positive_net_declining_rate"], "net", True, positive_k)}
        ranks = {}
        for rank_name, (predicate, field, reverse, limit) in rules.items():
            ranks[rank_name] = sorted((g for g in candidates if predicate(g)), key=lambda g: (g[field], g["group_id"]), reverse=reverse)[:limit]
        result[name] = {"eligible_group_count": len(candidates), "rankings": ranks}
    result["warning"] = "Overlapping projections cannot be summed. Old/new score labels describe one score, not independent factors."
    return result





def coverage_summary(projections: list[dict[str, Any]]) -> dict[str, Any]:
    by_order = []
    for order in range(1, 7):
        members = [projection for projection in projections if projection["order"] == order]
        by_order.append({"order": order, "expected_subsets": math.comb(6, order), "actual_subsets": len({member["subset_id"] for member in members}), "expected_scope_projections": 4 * math.comb(6, order), "actual_scope_projections": len(members), "groups": sum(context["group_count"] for member in members for context in member["contexts"]), "eligible_groups": sum(context["eligible_group_count"] for member in members for context in member["contexts"])})
    if len(projections) != 252 or len({projection["subset_id"] for projection in projections}) != 63:
        raise AssertionError("exhaustive six-label subset coverage failed")
    return {"expected_nonempty_subsets": 63, "actual_nonempty_subsets": 63, "expected_scope_projections": 252, "actual_scope_projections": len(projections), "scopes": list(SCOPES), "by_order": by_order, "complete": True, "projection_index": [{"id": projection["id"], "dimensions": projection["dimensions"], "order": projection["order"], "scope": projection["scope"], "contexts": len(projection["contexts"]), "groups": sum(context["group_count"] for context in projection["contexts"]), "eligible_groups": sum(context["eligible_group_count"] for context in projection["contexts"])} for projection in projections]}


def analyze(input_path, minimum_n=100, negative_k=20, positive_k=5,
            review_months=("2026-07", "2026-08", "2026-09"), legacy_cube=None):
    if min(minimum_n,negative_k,positive_k) < 1:
        raise ValueError("sample and ranking limits must be positive")
    review_indices = [MONTHS.index(month) for month in review_months]
    if not review_indices or review_indices[-1] != SEP or any(b-a != 1 for a,b in zip(review_indices,review_indices[1:])):
        raise ValueError("review months must be consecutive complete months ending in September")
    metadata, source_audit, rows, labels, analysis_audit = read_source(input_path)
    legacy = validate_legacy(rows, legacy_cube)
    scope_totals = {scope: aggregate(rows,fields) for scope,fields in SCOPES.items()}
    overall = scope_totals["overall"].get((),empty_counts())
    projections = make_projections(rows,labels,scope_totals,minimum_n,review_indices,negative_k,positive_k)
    totals = [{"month":month,"n":overall["n"][index],"y":overall["y"][index],
               "rate":ratio(overall["y"][index],overall["n"][index]),
               "delta_jan":pp_difference(ratio(overall["y"][index],overall["n"][index]),ratio(overall["y"][JAN],overall["n"][JAN])),
               "is_partial":index==OCT,**view_finance(overall,index)} for index,month in enumerate(MONTHS)]
    analysis_audit.update({"legacy_validation":legacy,
                           "projection_month_count_checks":sum(len(p["contexts"])*10 for p in projections),
                           "projection_contribution_checks":sum(c["audit"]["contribution_available"] for p in projections for c in p["contexts"]),
                           "all_projection_counts_reconcile":True,"all_projection_postloan_counts_amounts_reconcile":True,
                           "all_available_contributions_reconcile":True})
    audit = dict(source_audit)
    for name,dimensions in (("完整五维事件",LEGACY_DIMENSIONS),("完整六标签事件",DIMENSIONS)):
        audit.setdefault(name,sum(row["n"] for row in rows if not any(any(t in row[d] for t in ("缺失","无效","冲突")) for d in dimensions)))
    metadata = {**metadata,"labels":labels,"postloan_attribution_key":"d0",
                "postloan_attribution":"口径1D0首次实际提单订单(user_id+apply_serial_id)，成功放款且已到期",
                "month_assignment":"T0事件月份，不改为到期月份",
                "same_score_warning":"score_band与score_new_band是同一410分数的两种分档，不是独立因素"}
    public_rows = [public_cube_row(row) for row in rows]
    data = {"schema_version":"t0-six-label-postloan-analysis/v1","generated_at":datetime.now(timezone.utc).isoformat(),
            "source_path":str(input_path.resolve()),"metadata":metadata,"audit":audit,"analysis_audit":analysis_audit,
            "contract":{"statistical_unit":"user × original analyzable T0 event; postloan unit is its D0-first actual order",
                        "dimensions":list(DIMENSIONS),"underlying_factor_count":5,"months":list(MONTHS),
                        "complete_months":list(COMPLETE_MONTHS),"comparison":{"from":MONTHS[JAN],"to":MONTHS[SEP]},
                        "partial_months":[{"month":MONTHS[OCT],"label":"2026年10月1–11日（部分月份）","included_in_main_comparison":False}],
                        "minimum_n_each_endpoint":minimum_n,"minimum_due_each_endpoint":minimum_n,"review_months":list(review_months),
                        "ranking_limits":{"negative":negative_k,"positive":positive_k},"monthly_vector_order":list(MONTHS),
                        "units":{"rate":"fraction","share":"fraction","rJan":"fraction","rSep":"fraction","wJan":"fraction","wSep":"fraction",
                                 "delta":"pp","delta_jan":"pp","net":"pp","within":"pp","mix":"pp","entry_exit":"pp",
                                 "profit_rate":"fraction","overdue_rate":"fraction","mature_coverage":"fraction",
                                 "profit_delta":"pp","overdue_delta":"pp","remit_amt":"MXN","repaid_amt":"MXN"},
                        "maturity_policy":"Jan--Sep are complete T0 calendar months for D0 conversion. Postloan metrics use only funded orders due before the source Belize observation date; every month retains mature coverage.",
                        "missing_policy":"Missing/invalid/conflict categories are independent. A repayment/status missing flag invalidates its affected financial ratio, never the T0 denominator.",
                        "candidate_policy":"Conversion top_neg/top_pos require known categories and consecutive Jul--Sep confirmation against Jan. Financial rankings require two endpoints with at least 100 due orders and separate NULL guards; no financial consecutive-confirmation claim.",
                        "exact_zero_policy":"Upstream fee/daily categories use exact zero; no tolerance or rebucketing here.",
                        "same_score_policy":"Old/new score bins are one underlying score. Redundant-score projections are marked; their refinement is not a second independent factor.",
                        "net_formula":"100 × (wSep*rSep−wJan*rJan); newly observed/disappeared groups use y/N and retain entry_exit.",
                        "within_formula":"100 × (wSep+wJan)/2 × (rSep−rJan), shared groups only",
                        "mix_formula":"100 × (rSep+rJan)/2 × (wSep−wJan), shared groups only",
                        "addition_policy":"Only disjoint groups within one projection and one context add to its total change. Different projections/scopes are overlapping and cannot be added.",
                        "standardization_policy":"Conversion: common known cells with each n≥20, weighted by Jan event count. Finance: common known cells with each due≥20, positive principal and no repayment/status missing; profit weights Jan principal, risk weights Jan due orders.",
                        "interpretation":"Descriptive associations/accounting only; no causal or statistical-significance claim."},
            "coverage":coverage_summary(projections),"totals":totals,"views":make_views(rows,labels,scope_totals),
            "projections":projections,"matrices":make_matrices(projections,labels,minimum_n,review_indices),
            "combinations":make_combinations(projections,negative_k,positive_k),"standardized":make_standardized(rows),
            "cube":{"fields":list(public_rows[0]) if public_rows else [],"rows":public_rows}}
    data["per_dimension_rankings"] = {dimension:[{"projection_id":p["id"],"scope":p["scope"],
                "contexts":[{"context_id":c["id"],"filters":c["filters"],"rankings":c["rankings"]} for c in p["contexts"]]}
                for p in projections if p["dimensions"]==[dimension]] for dimension in DIMENSIONS}
    score_oct = next(v for v in data["views"]["dimensions"]["score_new_band"]
                     if v["scope"]=="overall" and v["month"]==MONTHS[OCT] and v["level"]=="≥535")
    data["analysis_audit"]["october_due_order_n"] = totals[OCT]["matured_loan_n"]
    data["analysis_audit"]["october_high_score_due_order_n"] = score_oct["matured_loan_n"]
    return data







def view_finance(counts, index):
    loan = finance_at(counts,index)
    return {"funded_loan_n":loan["funded_n"],"matured_loan_n":loan["due_n"],"overdue_loan_n":loan["overdue_n"],
            "matured_remit_amt":loan["remit_amt"],"matured_repaid_amt":loan["repaid_amt"],
            "matured_repaid_missing_n":loan["repaid_missing_n"],"matured_status_missing_n":loan["status_missing_n"],
            "profit_amt":loan["profit_amt"],"profit_rate":loan["profit_rate"],"overdue_rate":loan["overdue_rate"],
            "mature_coverage":loan["mature_coverage"],"due_share_of_d0":loan["due_share_of_d0"],
            "financial_sample_ge100":loan["financial_sample_ge100"]}


def cents_to_amount(cents):
    return cents / 100.0


def finance_at(counts, index):
    funded, due, overdue = (counts[field][index] for field in ("funded_n", "due_n", "overdue_n"))
    remit = cents_to_amount(counts["remit_cents"][index])
    missing_repaid = counts["repaid_missing_n"][index]
    missing_status = counts["status_missing_n"][index]
    repaid = None if missing_repaid else cents_to_amount(counts["repaid_cents"][index])
    profit = None if repaid is None else cents_to_amount(counts["repaid_cents"][index] - counts["remit_cents"][index])
    return {"funded_n": funded, "due_n": due, "overdue_n": overdue,
            "remit_amt": remit, "repaid_amt": repaid, "profit_amt": profit,
            "profit_rate": None if profit is None else ratio(profit, remit),
            "overdue_rate": None if missing_status else ratio(overdue, due),
            "mature_coverage": ratio(due, funded), "due_share_of_d0": ratio(due, counts["y"][index]),
            "repaid_missing_n": missing_repaid, "status_missing_n": missing_status,
            "financial_sample_ge100": due >= 100, "is_partial": index == OCT}


def postloan_payload(counts):
    monthly = [finance_at(counts, index) for index in range(10)]
    result = {field + "_by_month": counts[field] for field in ("funded_n", "due_n", "overdue_n", "repaid_missing_n", "status_missing_n")}
    result.update({"remit_amt_by_month": [m["remit_amt"] for m in monthly],
                   "repaid_amt_by_month": [m["repaid_amt"] for m in monthly],
                   "profit_rate_by_month": [m["profit_rate"] for m in monthly],
                   "overdue_rate_by_month": [m["overdue_rate"] for m in monthly],
                   "mature_coverage_by_month": [m["mature_coverage"] for m in monthly],
                   "jan": monthly[JAN], "sep": monthly[SEP], "oct": monthly[OCT]})
    return result


def compare_group(counts, parent, minimum_n, review_indices):
    result = conversion_comparison(counts, parent, minimum_n, review_indices)
    postloan = postloan_payload(counts)
    jan, sep = postloan["jan"], postloan["sep"]
    finance_eligible = jan["due_n"] >= minimum_n and sep["due_n"] >= minimum_n
    result.update({"postloan": postloan, "financial_eligible": finance_eligible,
                   "profit_delta": pp_difference(sep["profit_rate"], jan["profit_rate"]),
                   "overdue_delta": pp_difference(sep["overdue_rate"], jan["overdue_rate"])})
    result["partial_october"]["postloan"] = postloan["oct"]
    return result


def rank_groups(groups, negative_k, positive_k, minimum_n):
    result = conversion_rank_groups(groups, negative_k, positive_k, minimum_n)
    eligible = [g for g in groups if g["known_complete"] and g["financial_eligible"]]
    for rank_name, field, negative in (("profit_decline", "profit_delta", True), ("profit_improvement", "profit_delta", False),
                                       ("overdue_increase", "overdue_delta", False), ("overdue_reduction", "overdue_delta", True)):
        selected = [g for g in eligible if g[field] is not None and (g[field] < -EPSILON if negative else g[field] > EPSILON)]
        selected.sort(key=lambda g: (g[field], g["id"]), reverse=not negative)
        limit = negative_k if rank_name in ("profit_decline", "overdue_increase") else positive_k
        result[rank_name] = [g["id"] for g in selected[:limit]]
    return result


def decomposition_audit(groups, parent):
    audit = conversion_decomposition_audit(groups, parent)
    maps = {"funded_n": "funded_n_by_month", "due_n": "due_n_by_month", "overdue_n": "overdue_n_by_month",
            "repaid_missing_n": "repaid_missing_n_by_month", "status_missing_n": "status_missing_n_by_month"}
    for index in range(10):
        for field, vector in maps.items():
            if sum(g["postloan"][vector][index] for g in groups) != parent[field][index]:
                raise AssertionError("postloan count changed in projection")
        for field, vector in (("remit_cents", "remit_amt_by_month"), ("repaid_cents", "repaid_amt_by_month")):
            if field == "repaid_cents" and parent["repaid_missing_n"][index]:
                continue
            summed = math.fsum(g["postloan"][vector][index] or 0 for g in groups)
            if abs(summed - parent[field][index] / 100) > 0.000001:
                raise AssertionError("postloan amount changed in projection")
    audit["all_postloan_month_counts_and_amounts_reconcile"] = True
    return audit


def compact_group(projection, context, group):
    fields = ("key", "nJan", "nSep", "yJan", "ySep", "rJan", "rSep", "delta", "net", "within", "mix",
              "entry_exit", "known_complete", "confirmed_negative", "confirmed_positive", "positive_net_declining_rate",
              "negative_net_improving_rate", "financial_eligible", "profit_delta", "overdue_delta",
              "review", "postloan")
    return {"projection_id": projection["id"], "context_id": context["id"], "group_id": group["id"],
            "dimensions": projection["dimensions"], "scope": projection["scope"], "filters": context["filters"],
            "redundant_score_labels": projection["redundant_score_labels"],
            "effective_factor_count": projection["effective_factor_count"], **{field: group[field] for field in fields}}


def standardized_specs():
    families = {"legacy_five": LEGACY_DIMENSIONS,
                "new_score_five": ("base_band", "loan_band", "score_new_band", "fee_band", "daily_band"),
                "six_labels": DIMENSIONS}
    contexts = [("overall", {}), *(("credit_type", {"credit_type": t}) for t in DEFAULT_LABELS["credit_type"]),
                *(("credit_type_amount", {"credit_type": t, "amount_band": "≥3000"}) for t in ("增加", "降低"))]
    return [(family, dimensions, scope, filters) for family, dimensions in families.items() for scope, filters in contexts]


def make_standardized(rows, min_n=20):
    summaries = []
    for family, dimensions, scope, filters in standardized_specs():
        subset = [r for r in rows if all(r[k] == v for k, v in filters.items())]
        grouped = aggregate(subset, dimensions)
        parent = aggregate(subset, ()).get((), empty_counts())
        cells = [(values, c) for values, c in grouped.items() if not any(any(t in v for t in ("缺失", "无效", "冲突")) for v in values)]
        common = [c for _, c in cells if c["n"][JAN] >= min_n and c["n"][SEP] >= min_n]
        nj, ns = (sum(c["n"][i] for c in common) for i in (JAN, SEP))
        rj = ratio(sum(c["y"][JAN] for c in common), nj)
        rs = math.fsum(c["n"][JAN]/nj*c["y"][SEP]/c["n"][SEP] for c in common) if nj else None
        finance_cells = [c for _, c in cells if c["due_n"][JAN] >= min_n and c["due_n"][SEP] >= min_n
                         and c["remit_cents"][JAN] > 0 and c["remit_cents"][SEP] > 0
                         and not any(c[field][i] for field in ("repaid_missing_n", "status_missing_n") for i in (JAN, SEP))]
        dj, ds = (sum(c["due_n"][i] for c in finance_cells) for i in (JAN, SEP))
        mj, ms = (sum(c["remit_cents"][i] for c in finance_cells) for i in (JAN, SEP))
        pj = ratio(sum(c["repaid_cents"][JAN]-c["remit_cents"][JAN] for c in finance_cells), mj)
        ps = math.fsum(c["remit_cents"][JAN]/mj*(c["repaid_cents"][SEP]-c["remit_cents"][SEP])/c["remit_cents"][SEP] for c in finance_cells) if mj else None
        oj = ratio(sum(c["overdue_n"][JAN] for c in finance_cells), dj)
        os = math.fsum(c["due_n"][JAN]/dj*c["overdue_n"][SEP]/c["due_n"][SEP] for c in finance_cells) if dj else None
        summaries.append({"family": family, "dimensions": list(dimensions), "effective_factor_count": len(dimensions)-int(family=="six_labels"),
                          "scope": scope, "filters": filters, "strata": len(common), "nJan_common": nj, "nSep_common": ns,
                          "coverageJan": ratio(nj, parent["n"][JAN]), "coverageSep": ratio(ns, parent["n"][SEP]),
                          "rJan_common": rj, "rSep_standardized": rs, "delta_pp": pp_difference(rs, rj), "cell_min_n": min_n,
                          "finance": {"strata": len(finance_cells), "dueJan_common": dj, "dueSep_common": ds,
                                      "remitJan_common": mj/100, "remitSep_common": ms/100,
                                      "coverage_dueJan": ratio(dj, parent["due_n"][JAN]), "coverage_dueSep": ratio(ds, parent["due_n"][SEP]),
                                      "coverage_remitJan": ratio(mj, parent["remit_cents"][JAN]), "coverage_remitSep": ratio(ms, parent["remit_cents"][SEP]),
                                      "profitJan_common": pj, "profitSep_standardized": ps, "profit_delta_pp": pp_difference(ps,pj),
                                      "overdueJan_common": oj, "overdueSep_standardized": os, "overdue_delta_pp": pp_difference(os,oj)}})
    return summaries


def validate_legacy(rows, path):
    if path is None or not path.exists():
        return {"performed": False, "reason": "optional legacy cube not supplied"}
    old = json.loads(path.read_text())
    fields = ("month", "credit_type", "amount_band") + LEGACY_DIMENSIONS
    grouped = defaultdict(lambda: [0,0])
    for row in rows:
        target = grouped[tuple(row[field] for field in fields)]
        target[0] += row["n"]; target[1] += row["y"]
    expected = {tuple(row[field] for field in fields): [row["n"],row["y"]] for row in old["rows"]}
    if grouped != expected:
        raise AssertionError("legacy five-dimensional cube n/y changed")
    return {"performed": True, "exact_match": True, "legacy_cells": len(expected),
            "legacy_scope_projections_preserved": 124, "legacy_audit": old.get("audit", {})}


def public_cube_row(row):
    result = {field: row[field] for field in ("month",) + CUBE_FIELDS + ("n", "y")}
    for field in ("funded_n", "due_n", "overdue_n", "repaid_missing_n", "status_missing_n"):
        result["d0_" + field] = row[field]
    result["d0_remit_amt"] = row["remit_cents"]/100
    result["d0_repaid_amt"] = row["repaid_cents"]/100
    return result


def make_summary(data):
    full = []
    new_score = []
    for projection in data["projections"]:
        for context in projection["contexts"]:
            for group in context["groups"]:
                if not group["eligible"] or not group["known_complete"]:
                    continue
                if projection["order"] == 6 and projection["scope"] == "credit_type":
                    full.append(compact_group(projection,context,group))
                if "score_new_band" in projection["dimensions"] and not projection["redundant_score_labels"] and group["confirmed_negative"]:
                    new_score.append(compact_group(projection,context,group))
    negatives = sorted((g for g in full if g["delta"] < 0), key=lambda g:g["delta"])[:8]
    positives = sorted((g for g in full if g["delta"] > 0), key=lambda g:-g["delta"])[:4]
    score_rows = [v for v in data["views"]["dimensions"]["score_new_band"] if v["scope"] == "overall" and not v["is_total"]]
    return {"coverage": data["coverage"], "totals": data["totals"], "full_selected": negatives+positives,
            "fullSelected": negatives+positives, "standardized": data["standardized"],
            "new_score_negative_candidates": sorted(new_score,key=lambda g:g["delta"])[:12],
            "score_new_monthly": score_rows, "quality": data["audit"], "legacy_validation": data["analysis_audit"]["legacy_validation"],
            "same_score_warning": "Old/new score bins are two partitions of the same 410 score. Full six-label combinations represent five underlying factors.",
            "postloan_warning": f"D0 first actual application only; mature funded orders at current snapshot. October total due={data['totals'][OCT]['matured_loan_n']}; score≥535 October due={data['analysis_audit']['october_high_score_due_order_n']}. Recent cash/risk is not a full-cohort estimate."}


def main():
    directory = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input",type=Path,default=directory/"cube.json")
    parser.add_argument("--output",type=Path,default=directory/"analysis.json")
    parser.add_argument("--summary",type=Path,default=directory/"summary.json")
    parser.add_argument("--legacy-cube",type=Path,default=None)
    parser.add_argument("--minimum-n",type=int,default=100)
    parser.add_argument("--top-k",type=int,default=20)
    parser.add_argument("--positive-top-k",type=int,default=5)
    parser.add_argument("--pretty",action="store_true")
    args=parser.parse_args()
    if not args.input.is_file():
        parser.error("missing source cube/SQL-export CSV")
    if args.output.resolve()==args.input.resolve() or args.summary.resolve()==args.input.resolve():
        parser.error("outputs cannot overwrite source data")
    try:
        data=analyze(args.input,args.minimum_n,args.top_k,args.positive_top_k,legacy_cube=args.legacy_cube)
        summary=make_summary(data)
    except (ValueError,AssertionError,json.JSONDecodeError) as error:
        parser.error(str(error))
    args.output.parent.mkdir(parents=True,exist_ok=True)
    with args.output.open("w",encoding="utf-8") as target:
        json.dump(data,target,ensure_ascii=False,allow_nan=False,indent=2 if args.pretty else None,
                  separators=None if args.pretty else (",",":"))
    with args.summary.open("w",encoding="utf-8") as target:
        json.dump(summary,target,ensure_ascii=False,allow_nan=False,indent=2)
    print(json.dumps({"analysis":str(args.output.resolve()),"summary":str(args.summary.resolve()),
                      "cube_rows":data["analysis_audit"]["normalized_cube_rows"],
                      "projections":len(data["projections"]),"matrices":len(data["matrices"]),
                      "standardized_specs":len(data["standardized"]),
                      "october_due_n":data["analysis_audit"]["october_due_order_n"],
                      "october_high_score_due_n":data["analysis_audit"]["october_high_score_due_order_n"],
                      "legacy_exact":data["analysis_audit"]["legacy_validation"].get("exact_match"),
                      "all_counts_amounts_and_contributions_reconcile":True},ensure_ascii=False))





if __name__ == "__main__":
    main()
