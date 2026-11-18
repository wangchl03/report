"""只读分月复现：PG连接参数来自标准PG环境变量，无业务表写入。"""
from __future__ import annotations

import argparse
from datetime import date, datetime
from decimal import Decimal
import json
from pathlib import Path
import time

import psycopg2

BASE = Path(__file__).resolve().parent
START_MARKER = "TIMESTAMP '2026-01-01 00:00:00' AS start_time"
END_MARKER = "TIMESTAMP '2026-02-01 00:00:00' AS end_time"
GROUPS = (3, 63, 95, 111, 119, 123, 125, 126, 127)


def json_value(value):
    if isinstance(value, Decimal):
        return float(value)
    if isinstance(value, (date, datetime)):
        return value.isoformat()
    raise TypeError(type(value).__name__)


def save_json(path, data):
    temporary = path.with_suffix(path.suffix + '.partial')
    temporary.write_text(json.dumps(data, ensure_ascii=False, indent=2,
                                    default=json_value), encoding='utf-8')
    temporary.replace(path)


def connect(dws=False):
    # libpq自动读取PGHOST、PGPORT、PGDATABASE、PGUSER、PGPASSWORD、PGSSLMODE等。
    conn = psycopg2.connect(connect_timeout=15,
                            application_name='reloan_pre5_readonly_reproduction')
    conn.set_session(readonly=True, isolation_level='REPEATABLE READ')
    with conn.cursor() as cur:
        cur.execute("SET LOCAL TIME ZONE 'America/Belize'")
        cur.execute("SET LOCAL statement_timeout = '10min'")
        cur.execute("SET LOCAL work_mem = '64MB'")
        if dws:
            cur.execute('SET LOCAL query_dop = 1')
        cur.execute("SELECT current_setting('transaction_read_only')")
        assert cur.fetchone()[0] == 'on', '必须使用只读事务'
    return conn


def query(sql, dws=False):
    conn = connect(dws)
    began = time.monotonic()
    try:
        with conn.cursor() as cur:
            cur.execute(sql)
            columns = [column[0] for column in cur.description]
            rows = [dict(zip(columns, row)) for row in cur.fetchall()]
    finally:
        conn.rollback()
        conn.close()
    return rows, round(time.monotonic() - began, 3)


def monthly_bounds(start, end):
    current = start
    while current < end:
        following = (datetime(current.year + 1, 1, 1) if current.month == 12
                     else datetime(current.year, current.month + 1, 1))
        following = min(following, end)
        yield current, following
        current = following


def check_month(rows):
    # 9种分组分别守恒：任一路径/位置/时间桶的点击数都等于总体。
    for mode in (0, 1):
        subset = [row for row in rows if row['mode'] == mode]
        total = next(row['clicks'] for row in subset if row['grouping_code'] == 127)
        for group in GROUPS:
            count = sum(row['clicks'] for row in subset if row['grouping_code'] == group)
            assert count == total, (mode, group, count, total)
        all_paths = [row for row in subset if row['grouping_code'] == 3]
        ordered_complete = sum(row['clicks'] for row in all_paths
                               if all(row['p' + str(i)] is not None and
                                      row['p' + str(i)] != '同刻并列（顺序未知）'
                                      for i in range(1, 6)))
        expected = next(row['ordered_complete5'] for row in subset
                        if row['grouping_code'] == 127)
        assert ordered_complete == expected, (mode, ordered_complete, expected)


def period_sql(template, start, end):
    # start/end已经解析为datetime；只替换唯一的日期常量，不拼入任意SQL。
    assert template.count(START_MARKER) == template.count(END_MARKER) == 1
    return template.replace(START_MARKER,
                            "TIMESTAMP '" + str(start) + "' AS start_time").replace(
                                END_MARKER,
                                "TIMESTAMP '" + str(end) + "' AS end_time")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', type=Path, default=BASE / 'results')
    parser.add_argument('--dws', action='store_true',
                        help='DWS环境设置query_dop=1；普通PostgreSQL不使用此参数')
    parser.add_argument('--force', action='store_true', help='重算并替换已有成功缓存')
    parser.add_argument('--audit-only', action='store_true')
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    template = (BASE / '01_完整只读统计.sql').read_text(encoding='utf-8')
    start, end = datetime(2026, 1, 1), datetime(2026, 11, 16)
    if not args.audit_only:
        for left, right in monthly_bounds(start, end):
            name = 'compact_' + left.strftime('%Y%m')
            target = args.out / (name + '.json')
            if target.exists() and not args.force:
                print('复用已完成月份：' + name, flush=True)
                continue
            sql = period_sql(template, left, right)
            print('执行月份：' + name, flush=True)
            rows, seconds = query(sql, args.dws)
            check_month(rows)
            (args.out / (name + '.sql')).write_text(sql, encoding='utf-8')
            save_json(target, dict(start=str(left), end=str(right), read_only=True,
                                   seconds=seconds, rows=rows))
            print('完成：' + name + '，行数=' + str(len(rows)), flush=True)
    # 全期去重用户数/订单数不可把月度去重数相加，须单独全期核对。
    audit = args.out / 'global_association_audit.json'
    if args.force or not audit.exists():
        sql = (BASE / '02_全期用户订单去重核对.sql').read_text(encoding='utf-8')
        print('执行全期去重核对', flush=True)
        rows, seconds = query(sql, args.dws)
        save_json(audit, dict(start=str(start), end=str(end), read_only=True,
                              seconds=seconds, rows=rows))
    print('取数完成。运行 summarize.py 汇总结果。', flush=True)


if __name__ == '__main__':
    main()
