"""仅从完整月度缓存生成报告事实；不查数据库，不改原始statistics_result.json。"""
from collections import Counter
import json
from pathlib import Path

AMOUNT_LABELS = {
    '编辑借款金额',       # element_type=editing，单独start_edit/end_edit不算
    '滑动调整借款金额',
    '选择固定借款金额',
    '打开修改金额',
    '确认修改金额',
}
HISTORICAL_AMOUNT_LABELS = AMOUNT_LABELS | {
    '清空借款金额', '开始编辑借款金额', '结束编辑借款金额',
}


def generate(data_dir):
    data_dir = Path(data_dir)
    src = json.loads((data_dir / 'statistics_result.json').read_text(encoding='utf-8'))
    files = sorted(data_dir.glob('compact_2026[0-9][0-9].json'))
    assert len(files) == 11
    total = src['modes']['0']['summary']['clicks']
    paths = {m: Counter() for m in (0, 1)}
    span_complete = {m: Counter() for m in (0, 1)}
    monthly = []
    for file in files:
        rows = json.loads(file.read_text(encoding='utf-8'))['rows']
        summaries = {}
        for mode in (0, 1):
            subset = [row for row in rows if row['mode'] == mode]
            summary = next(row for row in subset if row['grouping_code'] == 127)
            summaries[mode] = summary
            for group in (3, 63, 95, 111, 119, 123, 125, 126):
                assert sum(row['clicks'] for row in subset
                           if row['grouping_code'] == group) == summary['clicks']
            for row in subset:
                if row['grouping_code'] == 3:
                    path = tuple(row['p' + str(i)] for i in range(5, 0, -1))
                    paths[mode][path] += row['clicks']
                elif row['grouping_code'] == 125:
                    # 取完整5条的分子，不能用全部点击桶数替代完整5条桶数。
                    span_complete[mode][row['span_bucket']] += row['complete5']
        monthly.append({
            'month': file.stem[-6:], 'clicks': summaries[0]['clicks'],
            'users': summaries[0]['users'],
            'distinct_orders': summaries[0]['distinct_orders'],
            'complete5_non_touch': summaries[1]['complete5'],
            'complete5_non_touch_share': summaries[1]['complete5'] / summaries[1]['clicks'],
        })
    assert sum(paths[0].values()) == sum(paths[1].values()) == total
    complete_denominator = sum(span_complete[1].values())
    assert complete_denominator == src['modes']['1']['summary']['complete5']
    latest_count = historical_count = difference = 0
    single_counts, extra_labels = Counter(), Counter()
    for path, count in paths[1].items():
        labels = set(path)
        latest_count += count * bool(labels & AMOUNT_LABELS)
        historical_count += count * bool(labels & HISTORICAL_AMOUNT_LABELS)
        for label in labels & AMOUNT_LABELS:
            single_counts[label] += count
        if labels & HISTORICAL_AMOUNT_LABELS and not labels & AMOUNT_LABELS:
            difference += count
            for label in labels & HISTORICAL_AMOUNT_LABELS:
                extra_labels[label] += count
    spans = [dict(band=band, clicks=count,
                  share_complete5=count / complete_denominator,
                  share_all_clicks=count / total)
             for band, count in sorted(span_complete[1].items()) if band != '0_无记录']
    within60 = sum(count for band, count in span_complete[1].items()
                   if band in ('1_10秒内', '2_10至30秒', '3_30至60秒'))
    within300 = within60 + span_complete[1]['4_1至5分钟']
    audit = {key: int(src['global_association'][key]) for key in (
        'distinct_users', 'distinct_orders', 'anchor_groups', 'order_5m', 'order_1h')}
    facts = {
        'purpose': '从完整月度结果生成报告事实；不访问数据库，不修改历史统计结果。',
        'global': {
            'clicks': total, 'users_distinct': audit['distinct_users'],
            'orders_distinct': audit['distinct_orders'],
            'click_anchor_groups': audit['anchor_groups'],
            'order_5m': audit['order_5m'],
            'order_5m_share_conditional': audit['order_5m'] / total,
            'order_1h': audit['order_1h'],
            'order_1h_share_conditional': audit['order_1h'] / total,
        },
        'raw_nearest_touch': src['modes']['0']['positions_pages_merged'][0]['rows'][0],
        'raw_top_complete_paths': src['modes']['0']['top_full_paths_pages_merged'][:8],
        'non_touch_top_complete_paths': src['modes']['1']['top_full_paths_pages_merged'][:12],
        'non_touch_last_position': src['modes']['1']['positions_pages_merged'][0]['rows'],
        'non_touch_complete5_span': {
            'denominator': complete_denominator, 'bands': spans,
            'within60_seconds_clicks': within60,
            'within60_seconds_share': within60 / complete_denominator,
            'within300_seconds_clicks': within300,
            'within300_seconds_share': within300 / complete_denominator,
            'definition': '从最近5条非touch日志中最早一条的event_time到确认提单点击的时差；完整5条样本计算，含同刻并列。',
        },
        'amount_union_20261118': {
            'definition': '前5条非touch行为中，金额输入editing、滑动金额条、固定金额选项、打开金额修改、确认金额修改的可识别并集。',
            'labels': sorted(AMOUNT_LABELS), 'clicks': latest_count,
            'share': latest_count / total, 'single_counts': dict(single_counts),
            'historical_wide_definition_clicks': historical_count,
            'historical_wide_share': historical_count / total,
            'difference_clicks': difference, 'historical_extra_labels': dict(extra_labels),
            'note': '最新五项并集排除单独出现的start_edit/end_edit及清空金额；仅从现存路径缓存重汇总，同刻并列标签可能遮蔽具体行为，计数仅称明确识别。历史statistics_result.json保持原分类。',
        },
        'quality': {mode: {key: value for key, value in src['modes'][mode]['summary'].items()
                           if key != 'sum_span_seconds'} for mode in ('0', '1')},
        'monthly': monthly,
    }
    target = data_dir / 'content_facts.json'
    target.write_text(json.dumps(facts, ensure_ascii=False, indent=2), encoding='utf-8')
    return facts


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('--data-dir', type=Path,
                        default=Path(__file__).resolve().parent / 'results')
    generate(parser.parse_args().data_dir)
