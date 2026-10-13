#!/usr/bin/env python3
"""Offline, exhaustive five-dimension analysis of an already validated T0 cube.

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
from typing import Any


MONTHS = tuple(f"2026-{m:02d}" for m in range(1, 11))
COMPLETE_MONTHS = MONTHS[:9]
JAN, SEP, OCT = 0, 8, 9
DIMENSIONS = ("base_band", "loan_band", "score_band", "fee_band", "daily_band")
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
EPSILON = 1e-10


def empty_counts() -> dict[str, list[int]]:
    return {"n": [0] * len(MONTHS), "y": [0] * len(MONTHS)}


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


def read_source(path: Path) -> tuple[dict[str, Any], Any, list[dict[str, Any]], dict[str, list[str]], dict[str, Any]]:
    if path.suffix.lower()=='.csv':
        import csv
        with path.open(encoding='utf-8-sig',newline='') as source:
            records=list(csv.DictReader(source))
        payload={'metadata':{'labels':DEFAULT_LABELS,'zero_catalog_audit':[],'zero_catalog_product':[]},'audit':{},'rows':[]}
        for record in records:
            value=json.loads(record['payload'])
            if record['kind']=='cube':payload['rows'].append(value)
            elif record['kind']=='audit':
                if value['key'] in payload['audit']:raise ValueError('duplicate upstream audit key: '+value['key'])
                payload['audit'][value['key']]=value['n']
            elif record['kind'] in ['zero_catalog_audit','zero_catalog_product']:payload['metadata'][record['kind']].append(value)
            elif record['kind']=='metadata':payload['metadata'].update(value)
    else:
        with path.open(encoding='utf-8') as source:
            payload=json.load(source)
    if not isinstance(payload, dict) or not isinstance(payload.get("rows"), list):
        raise ValueError("input must contain metadata, audit, and a rows array")
    metadata = payload.get("metadata", {})
    if not isinstance(metadata, dict):
        raise ValueError("metadata must be an object")
    aggregate_rows: dict[tuple[Any, ...], list[int]] = {}
    observed: dict[str, set[str]] = {field: set() for field in CUBE_FIELDS}
    original_n = original_y = 0
    for row_number, raw in enumerate(payload["rows"], start=1):
        if not isinstance(raw, dict):
            raise ValueError(f"source row {row_number} is not an object")
        month = raw.get("month")
        if month not in MONTHS:
            raise ValueError(f"source row {row_number}: month must be in Jan--Oct 2026")
        absent = [field for field in CUBE_FIELDS if field not in raw]
        if absent:
            raise ValueError(f"source row {row_number}: missing fields {absent}")
        categories = tuple(normalize_category(raw[field], field) for field in CUBE_FIELDS)
        for field, value in zip(CUBE_FIELDS, categories):
            observed[field].add(value)
        n = integer_count(raw.get("n"), row_number, "n")
        y = integer_count(raw.get("y"), row_number, "y")
        if y > n:
            raise ValueError(f"source row {row_number}: y={y} exceeds n={n}")
        original_n += n
        original_y += y
        key = (month,) + categories
        accumulator = aggregate_rows.setdefault(key, [0, 0])
        accumulator[0] += n
        accumulator[1] += y
    supplied_labels = metadata.get("labels", {})
    if not isinstance(supplied_labels, dict):
        raise ValueError("metadata.labels must be an object when present")
    labels: dict[str, list[str]] = {}
    unexpected: dict[str, list[str]] = {}
    for field in CUBE_FIELDS:
        provided = supplied_labels.get(field, DEFAULT_LABELS[field])
        if not isinstance(provided, list) or not all(isinstance(value, str) for value in provided):
            raise ValueError(f"metadata.labels.{field} must be a string array")
        labels[field] = list(dict.fromkeys(provided))
        extra = sorted(observed[field] - set(labels[field]))
        labels[field].extend(extra)
        if extra:
            unexpected[field] = extra
    order = {field: {value: index for index, value in enumerate(labels[field])} for field in CUBE_FIELDS}
    rows = [dict(zip(("month",) + CUBE_FIELDS, key), n=counts[0], y=counts[1]) for key, counts in aggregate_rows.items()]
    rows.sort(key=lambda row: (row["month"],) + tuple(order[field][row[field]] for field in CUBE_FIELDS))
    if sum(row["n"] for row in rows) != original_n or sum(row["y"] for row in rows) != original_y:
        raise AssertionError("cube normalization changed counts")
    source_audit = {
        "input_rows": len(payload["rows"]),
        "normalized_cube_rows": len(rows),
        "duplicate_cube_rows_merged": len(payload["rows"]) - len(rows),
        "input_n": original_n,
        "input_y": original_y,
        "normalized_n": sum(row["n"] for row in rows),
        "normalized_y": sum(row["y"] for row in rows),
        "unexpected_categories_preserved": unexpected,
        "source_metric_and_maturity_validation": "upstream audit retained; aggregate cube cannot revalidate event-level T0 rules",
    }
    upstream=payload.get('audit',{})
    required=['额度可分析T0事件数','丰富字段后事件数','重复事件键','重复提单归属','D0窗口异常']
    if path.suffix.lower()=='.csv' and any(k not in upstream for k in required):
        raise ValueError('SQL export is missing required upstream audit rows')
    if upstream:
        for k in ['重复事件键','重复提单归属','D0窗口异常']:
            if upstream.get(k,0)!=0:raise ValueError('upstream event audit failed: '+k)
        for k in ['额度可分析T0事件数','丰富字段后事件数']:
            if k in upstream and upstream[k]!=original_n:raise ValueError('upstream denominator differs from cube: '+k)
    return metadata, upstream, rows, labels, source_audit


def aggregate(rows: list[dict[str, Any]], fields: tuple[str, ...]) -> dict[tuple[str, ...], dict[str, list[int]]]:
    result: dict[tuple[str, ...], dict[str, list[int]]] = {}
    for row in rows:
        key = tuple(row[field] for field in fields)
        counts = result.get(key)
        if counts is None:
            counts = empty_counts()
            result[key] = counts
        index = int(row["month"][-2:]) - 1
        counts["n"][index] += row["n"]
        counts["y"][index] += row["y"]
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


def compare_group(counts: dict[str, list[int]], parent: dict[str, list[int]], minimum_n: int, review_indices: list[int]) -> dict[str, Any]:
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


def rank_groups(groups: list[dict[str, Any]], negative_k: int, positive_k: int, minimum_n: int) -> dict[str, list[str]]:
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


def decomposition_audit(groups: list[dict[str, Any]], parent: dict[str, list[int]]) -> dict[str, Any]:
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


def make_projections(rows: list[dict[str, Any]], labels: dict[str, list[str]], scope_totals: dict[str, dict[tuple[str, ...], dict[str, list[int]]]], minimum_n: int, review_indices: list[int], negative_k: int, positive_k: int) -> list[dict[str, Any]]:
    projections = []
    label_order = {field: {value: index for index, value in enumerate(labels[field])} for field in CUBE_FIELDS}
    for order in range(1, len(DIMENSIONS) + 1):
        for dimensions in itertools.combinations(DIMENSIONS, order):
            subset_id = "__".join(dimensions)
            for scope, extension_fields in SCOPES.items():
                projection_id = subset_id + "@" + scope
                aggregated = aggregate(rows, extension_fields + dimensions)
                by_parent: dict[tuple[str, ...], dict[tuple[str, ...], dict[str, list[int]]]] = defaultdict(dict)
                for values, counts in aggregated.items():
                    by_parent[values[:len(extension_fields)]][values[len(extension_fields):]] = counts
                contexts = []
                for parent_values in context_keys(scope, labels):
                    parent = scope_totals[scope].get(parent_values, empty_counts())
                    parent_id = context_id(scope, parent_values)
                    members = by_parent.get(parent_values, {})
                    if order == 1:
                        # Single dimensions expose complete label sets, even if a category has no event.
                        members = {**{(level,): empty_counts() for level in labels[dimensions[0]]}, **members}
                    ordered_values = sorted(members, key=lambda values: tuple(label_order[field][value] for field, value in zip(dimensions, values)))
                    groups = []
                    for values in ordered_values:
                        counts = members[values]
                        groups.append({
                            "id": stable_group_id(projection_id, parent_id, values),
                            "levels": list(values), "key": dict(zip(dimensions, values)),
                            "n_by_month": counts["n"], "y_by_month": counts["y"],
                            "contains_missing": any("缺失" in value for value in values),
                            "contains_invalid_or_conflict": any("无效" in value or "冲突" in value for value in values),
                            "known_complete": not any("缺失" in value or "无效" in value or "冲突" in value for value in values),
                            **compare_group(counts, parent, minimum_n, review_indices),
                        })
                    contexts.append({
                        "id": parent_id, "filters": dict(zip(extension_fields, parent_values)),
                        "n_by_month": parent["n"], "y_by_month": parent["y"], "rate_by_month": rates(parent),
                        "groups": groups,
                        "rankings": rank_groups(groups, negative_k, positive_k, minimum_n),
                        "audit": decomposition_audit(groups, parent),
                        "group_count": len(groups),
                        "eligible_group_count": sum(group["eligible"] for group in groups),
                        "confirmed_negative_group_count": sum(group["confirmed_negative"] for group in groups),
                        "confirmed_positive_group_count": sum(group["confirmed_positive"] for group in groups),
                    })
                projections.append({"id": projection_id, "subset_id": subset_id, "dimensions": list(dimensions), "order": order, "scope": scope, "extension_fields": list(extension_fields), "contexts": contexts})
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
                **{field: group[field] for field in ("nJan", "nSep", "rJan", "rSep", "delta", "net", "within", "mix", "entry_exit", "state", "eligible")},
            })
        matrices.append({"id": projection["subset_id"], "projection_id": projection["id"], "context_id": context["id"], "row_dimension": row_dimension, "column_dimension": column_dimension, "row_levels": labels[row_dimension], "column_levels": labels[column_dimension], "cells": cells, "includes_zero_cells": True})
    if len(matrices) != 10:
        raise AssertionError("expected all ten two-dimensional matrices")
    return matrices


def make_combinations(projections: list[dict[str, Any]], negative_k: int, positive_k: int) -> dict[str, Any]:
    result = {}
    for order, name in ((3, "three_way"), (5, "five_way")):
        candidates = []
        for projection in projections:
            if projection["order"] != order:
                continue
            for context in projection["contexts"]:
                for group in context["groups"]:
                    if not group["eligible"]:
                        continue
                    candidates.append({
                        "projection_id": projection["id"], "context_id": context["id"], "group_id": group["id"],
                        "dimensions": projection["dimensions"], "scope": projection["scope"], "filters": context["filters"], "key": group["key"],
                        **{field: group[field] for field in ("nJan", "nSep", "rJan", "rSep", "delta", "net", "within", "mix", "entry_exit", "confirmed_negative", "confirmed_positive", "positive_net_declining_rate", "negative_net_improving_rate", "contains_missing", "known_complete", "review")},
                    })
        rules = {
            "negative_rate": (lambda g: g["delta"] < -EPSILON, "delta", False, negative_k),
            "positive_rate": (lambda g: g["delta"] > EPSILON, "delta", True, positive_k),
            "negative_net": (lambda g: g["net"] is not None and g["net"] < -EPSILON, "net", False, negative_k),
            "positive_net": (lambda g: g["net"] is not None and g["net"] > EPSILON, "net", True, positive_k),
            "confirmed_negative_rate": (lambda g: g["confirmed_negative"], "delta", False, negative_k),
            "confirmed_positive_rate": (lambda g: g["confirmed_positive"], "delta", True, positive_k),
            "positive_net_declining_rate": (lambda g: g["positive_net_declining_rate"], "net", True, positive_k),
            "top_neg": (lambda g: g["known_complete"] and g["confirmed_negative"], "delta", False, negative_k),
            "top_pos": (lambda g: g["known_complete"] and g["confirmed_positive"], "delta", True, positive_k),
        }
        result[name] = {"eligible_group_count": len(candidates), "rankings": {}}
        for rank_name, (predicate, field, reverse, limit) in rules.items():
            selected = sorted((candidate for candidate in candidates if predicate(candidate)), key=lambda candidate: (candidate[field], candidate["group_id"]), reverse=reverse)
            result[name]["rankings"][rank_name] = selected[:limit]
    result["warning"] = "Rankings across projections/scopes are exploratory, overlap, and must not be summed; net is relative to each displayed scope's own denominator."
    return result


def coverage_summary(projections: list[dict[str, Any]]) -> dict[str, Any]:
    by_order = []
    for order in range(1, 6):
        members = [projection for projection in projections if projection["order"] == order]
        by_order.append({"order": order, "expected_subsets": math.comb(5, order), "actual_subsets": len({member["subset_id"] for member in members}), "expected_scope_projections": 4 * math.comb(5, order), "actual_scope_projections": len(members), "groups": sum(context["group_count"] for member in members for context in member["contexts"]), "eligible_groups": sum(context["eligible_group_count"] for member in members for context in member["contexts"])})
    if len(projections) != 124 or len({projection["subset_id"] for projection in projections}) != 31:
        raise AssertionError("exhaustive five-dimension subset coverage failed")
    return {"expected_nonempty_subsets": 31, "actual_nonempty_subsets": 31, "expected_scope_projections": 124, "actual_scope_projections": len(projections), "scopes": list(SCOPES), "by_order": by_order, "complete": True, "projection_index": [{"id": projection["id"], "dimensions": projection["dimensions"], "order": projection["order"], "scope": projection["scope"], "contexts": len(projection["contexts"]), "groups": sum(context["group_count"] for context in projection["contexts"]), "eligible_groups": sum(context["eligible_group_count"] for context in projection["contexts"])} for projection in projections]}


def analyze(input_path: Path, minimum_n: int = 100, negative_k: int = 20, positive_k: int = 5, review_months: tuple[str, ...] = ("2026-07", "2026-08", "2026-09")) -> dict[str, Any]:
    if minimum_n < 1 or negative_k < 1 or positive_k < 1:
        raise ValueError("minimum_n and ranking limits must be positive")
    if not review_months or any(month not in COMPLETE_MONTHS for month in review_months):
        raise ValueError("review months must be complete months Jan--Sep 2026")
    review_indices = [MONTHS.index(month) for month in review_months]
    if any(right - left != 1 for left, right in zip(review_indices, review_indices[1:])) or review_indices[-1] != SEP:
        raise ValueError("review months must be consecutive and end in September")
    metadata, source_audit, rows, labels, analysis_audit = read_source(input_path)
    scope_totals = {scope: aggregate(rows, fields) for scope, fields in SCOPES.items()}
    overall = scope_totals["overall"].get((), empty_counts())
    projections = make_projections(rows, labels, scope_totals, minimum_n, review_indices, negative_k, positive_k)
    totals = [{"month": month, "n": overall["n"][index], "y": overall["y"][index], "rate": ratio(overall["y"][index], overall["n"][index]), "delta_jan": pp_difference(ratio(overall["y"][index], overall["n"][index]), ratio(overall["y"][JAN], overall["n"][JAN])), "is_partial": index == OCT} for index, month in enumerate(MONTHS)]
    analysis_audit["projection_month_count_checks"] = sum(len(projection["contexts"]) * len(MONTHS) for projection in projections)
    analysis_audit["projection_contribution_checks"] = sum(context["audit"]["contribution_available"] for projection in projections for context in projection["contexts"])
    analysis_audit["all_projection_counts_reconcile"] = True
    analysis_audit["all_available_contributions_reconcile"] = True
    metadata = {**metadata, "labels": labels}
    return {
        "schema_version": "t0-five-dim-analysis/v1",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "source_path": str(input_path.resolve()),
        "metadata": metadata, "audit": source_audit, "analysis_audit": analysis_audit,
        "contract": {
            "statistical_unit": "user × strict T0 credit-grant event; inherited upstream denominator",
            "dimensions": list(DIMENSIONS), "months": list(MONTHS), "complete_months": list(COMPLETE_MONTHS),
            "comparison": {"from": MONTHS[JAN], "to": MONTHS[SEP]},
            "partial_months": [{"month": MONTHS[OCT], "label": "2026年10月1–11日（部分月份）", "included_in_main_comparison": False}],
            "minimum_n_each_endpoint": minimum_n, "review_months": list(review_months),
            "ranking_limits": {"negative": negative_k, "positive": positive_k},
            "units": {"rate": "fraction", "share": "fraction", "rJan": "fraction", "rSep": "fraction", "wJan": "fraction", "wSep": "fraction", "delta_jan": "pp", "delta": "pp", "net": "pp", "within": "pp", "mix": "pp", "entry_exit": "pp"},
            "missing_policy": "Explicit missing, invalid, and conflict categories remain independent; no stratification drops events.",
            "candidate_policy": "top_neg/top_pos use eligible known_complete groups with consecutive-month confirmation and the sign of within-group rate delta; positive net alone is not called rate improvement.",
            "exact_zero_policy": "Upstream categories determine change direction; this program applies no tolerance or rebucketing.",
            "net_formula": "100 × (wSep × rSep − wJan × rJan); absent endpoints contribute y/N=0 without an invented rate",
            "within_formula": "100 × ((wSep+wJan)/2) × (rSep−rJan), shared groups only",
            "mix_formula": "100 × ((rSep+rJan)/2) × (wSep−wJan), shared groups only",
            "entry_exit_policy": "New/disappeared groups retain net in entry_exit; within/mix are null.",
            "addition_policy": "Only disjoint groups within one projection and one context add to that context's total change. Different projections/scopes must not be summed.",
            "interpretation": "Descriptive associations and accounting decomposition; no causal attribution, significance claim, or policy recommendation.",
            "maturity_policy": "Jan--Sep designated complete by task; October retained separately. Event-window maturity and metric identity remain subject to source metadata/audit.",
            "monthly_vector_order": list(MONTHS),
        },
        "coverage": coverage_summary(projections), "totals": totals,
        "views": make_views(rows, labels, scope_totals), "projections": projections,
        "per_dimension_rankings": {dimension: [{"projection_id": projection["id"], "scope": projection["scope"], "contexts": [{"context_id": context["id"], "filters": context["filters"], "rankings": context["rankings"]} for context in projection["contexts"]]} for projection in projections if projection["dimensions"] == [dimension]] for dimension in DIMENSIONS},
        "matrices": make_matrices(projections, labels, minimum_n, review_indices),
        "combinations": make_combinations(projections, negative_k, positive_k),
        "cube": {"fields": ["month", *CUBE_FIELDS, "n", "y"], "rows": rows},
    }


def standardize(rows,filters,min_n=20):
    groups=defaultdict(lambda:{'2026-01':[0,0],'2026-09':[0,0]})
    totals={'2026-01':[0,0],'2026-09':[0,0]}
    for r in rows:
        if r['month'] not in totals or not all(r[k]==v for k,v in filters.items()):continue
        a=groups[tuple(r[k] for k in DIMENSIONS)][r['month']];a[0]+=r['n'];a[1]+=r['y'];totals[r['month']][0]+=r['n'];totals[r['month']][1]+=r['y']
    valid=[g for g in groups.values() if g['2026-01'][0]>=min_n and g['2026-09'][0]>=min_n]
    nj=sum(g['2026-01'][0] for g in valid);ns=sum(g['2026-09'][0] for g in valid)
    if not nj or not ns:return {'filters':filters,'strata':0}
    rj=sum(g['2026-01'][1] for g in valid)/nj
    rs=sum(g['2026-01'][0]/nj*g['2026-09'][1]/g['2026-09'][0] for g in valid)
    return {'filters':filters,'strata':len(valid),'nJan_common':nj,'nSep_common':ns,
            'coverageJan':nj/totals['2026-01'][0],'coverageSep':ns/totals['2026-09'][0],
            'rJan_common':rj,'rSep_standardized':rs,'delta_pp':100*(rs-rj),'cell_min_n':min_n}


def main() -> None:
    directory = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, default=directory / "cube.json")
    parser.add_argument("--output", type=Path, default=directory / "analysis.json")
    parser.add_argument("--minimum-n", type=int, default=100)
    parser.add_argument("--top-k", type=int, default=20, help="negative ranking limit")
    parser.add_argument("--positive-top-k", type=int, default=5)
    parser.add_argument("--review-months", nargs="+", default=["2026-07", "2026-08", "2026-09"])
    parser.add_argument("--pretty", action="store_true", help="indent output (considerably larger)")
    args = parser.parse_args()
    if not args.input.is_file():
        parser.error(f"source cube does not exist: {args.input}; no analysis output was generated")
    if args.input.resolve() == args.output.resolve():
        parser.error("output must not overwrite the input cube")
    try:
        output = analyze(args.input, args.minimum_n, args.top_k, args.positive_top_k, tuple(args.review_months))
    except (ValueError, AssertionError, json.JSONDecodeError) as error:
        parser.error(str(error))
    output['report_standardized']=[standardize(output['cube']['rows'],{'credit_type':t,'amount_band':'≥3000'}) for t in ['增加','降低']]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8") as target:
        json.dump(output, target, ensure_ascii=False, allow_nan=False, indent=2 if args.pretty else None, separators=None if args.pretty else (",", ":"))
    print(json.dumps({"output": str(args.output.resolve()), "cube_rows": output["analysis_audit"]["normalized_cube_rows"], "subsets": output["coverage"]["actual_nonempty_subsets"], "scope_projections": output["coverage"]["actual_scope_projections"], "matrices": len(output["matrices"]), "all_counts_and_contributions_reconcile": True}, ensure_ascii=False))


if __name__ == "__main__":
    main()
