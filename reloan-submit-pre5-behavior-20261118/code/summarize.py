from pathlib import Path
from collections import Counter,defaultdict
import json
import argparse

W=Path(__file__).resolve().parent/'results'
POSITION={63:1,95:2,111:3,119:4,123:5}
ADDITIVE=('clicks','complete5','ordered_complete5','ambiguous_clicks','boundary_clicks',
          'cross_day_clicks','order_5m','order_1h','sum_span_seconds','valid_span_clicks','nonunique_order_clicks')


def summarize(partial=False):
    files=sorted(W.glob('compact_2026[0-9][0-9].json'))
    if not partial:assert len(files)==11,len(files)
    totals={m:Counter() for m in (0,1)};paths={m:Counter() for m in (0,1)}
    positions={m:{k:Counter() for k in range(1,6)} for m in (0,1)}
    spans={m:Counter() for m in (0,1)};nearest={m:Counter() for m in (0,1)};monthly=[]
    for file in files:
        d=json.loads(file.read_text());month=d['start'][:7]
        for mode in (0,1):
            rs=[r for r in d['rows'] if r['mode']==mode]
            summary=next(r for r in rs if r['grouping_code']==127)
            monthly.append(dict(month=month,mode=mode,**{k:v for k,v in summary.items() if k not in ('mode','p1','p2','p3','p4','p5','span_bucket','nearest_bucket','grouping_code')}))
            for k in ADDITIVE:totals[mode][k]+=summary[k]
            for g in (3,63,95,111,119,123,125,126):
                n=sum(r['clicks'] for r in rs if r['grouping_code']==g)
                assert n==summary['clicks'],(file.name,mode,g,n,summary['clicks'])
            for r in rs:
                g=r['grouping_code'];n=r['clicks']
                if g==3:paths[mode][tuple(r['p'+str(k)] for k in range(5,0,-1))]+=n
                elif g in POSITION:
                    k=POSITION[g];positions[mode][k][r['p'+str(k)] or '无前序记录']+=n
                elif g==125:spans[mode][r['span_bucket']]+=n
                elif g==126:nearest[mode][r['nearest_bucket']]+=n
    assert totals[0]['clicks']==totals[1]['clicks']
    out=dict(period='2026-01-01至2026-11-15',months=len(files),partial=partial,monthly=monthly,modes={})
    for mode in (0,1):
        total=totals[mode]['clicks'];assert sum(paths[mode].values())==total
        for k in range(1,6):assert sum(positions[mode][k].values())==total
        ordered=Counter({p:n for p,n in paths[mode].items() if '同刻并列（顺序未知）' not in p})
        full=Counter({p:n for p,n in ordered.items() if None not in p})
        assert sum(full.values())==totals[mode]['ordered_complete5']
        feature=Counter()
        for p,n in paths[mode].items():
            flags=set()
            for s in p:
                if not s:continue
                if s in ('打开修改金额','清空借款金额','确认修改金额','选择固定借款金额','滑动调整借款金额','开始编辑借款金额','编辑借款金额','结束编辑借款金额'):flags.add('金额操作')
                if s in ('打开借款期限选择','关闭借款期限选择','选择分期或产品'):flags.add('账期/产品选择')
                if '息费券' in s:flags.add('息费券操作')
                if '提额券' in s:flags.add('提额券操作')
                if '协议' in s:flags.add('借款协议操作')
                if s in ('查看还款计划','关闭还款计划'):flags.add('查看/关闭还款计划')
                if s=='点击确认提单':flags.add('前序再次点击确认提单')
            for f in flags:feature[f]+=n
        def render(c,limit):return [dict(path=[s for s in p if s is not None],steps=sum(s is not None for s in p),clicks=n,share=n/total) for p,n in c.most_common(limit)]
        def normalize(s):
            if s is None:return None
            return s.replace('提单页（固定金额）','提单页').replace('提单页（滑动金额）','提单页').replace('首页大按钮','点击首页主按钮')
        normalized=Counter()
        for p,n in full.items():normalized[tuple(normalize(s) for s in p)]+=n
        normalized_positions=[]
        for k in range(1,6):
            counts=Counter()
            for s,n in positions[mode][k].items():counts[normalize(s)]+=n
            normalized_positions.append(dict(position=k,rows=[dict(behavior=s,clicks=n,share=n/total) for s,n in counts.most_common(20)]))
        out['modes'][str(mode)]=dict(summary=dict(totals[mode]),top_full_paths=render(full,30),
           top_ordered_paths_any_length=render(ordered,30),
           top_full_paths_pages_merged=render(normalized,30),positions_pages_merged=normalized_positions,
           positions=[dict(position=k,rows=[dict(behavior=s,clicks=n,share=n/total) for s,n in positions[mode][k].most_common(20)]) for k in range(1,6)],
           span_bands=[dict(band=b,clicks=n,share=n/total) for b,n in sorted(spans[mode].items())],
           nearest_bands=[dict(band=b,clicks=n,share=n/total) for b,n in sorted(nearest[mode].items())],
           feature_presence_definite=[dict(feature=f,clicks=n,share=n/total) for f,n in feature.most_common()],
           distinct_path_patterns=len(paths[mode]),checks_passed=True)
    audit_path=W/'global_association_audit.json'
    if audit_path.exists():
        audit=json.loads(audit_path.read_text())
        g=next(r for r in audit['rows'] if r['is_total']==1 and r['match_class']=='reloan')
        if not partial:assert out['modes']['0']['summary']['clicks']==int(g['click_logs'])
        out['global_association']=g
        for m in monthly:
            r=next(a for a in audit['rows'] if a['is_total']==0 and a['match_class']=='reloan' and a['click_month'].startswith(m['month']))
            assert m['clicks']==int(r['click_logs'])
    (W/('partial_summary.json' if partial else 'statistics_result.json')).write_text(json.dumps(out,ensure_ascii=False,indent=2))
    for m,v in out['modes'].items():
        print('MODE',m,'SUMMARY',v['summary'])
        print('TOP FULL',json.dumps(v['top_full_paths'][:10],ensure_ascii=False))
        print('POSITIONS',json.dumps([dict(position=x['position'],rows=x['rows'][:5]) for x in v['positions']],ensure_ascii=False))
    print('COMPLETED MONTHS',len(files),flush=True)


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--partial',action='store_true');p.add_argument('--data-dir',type=Path,default=W);a=p.parse_args();W=a.data_dir.resolve();summarize(a.partial)
    if not a.partial:
        from report_facts import generate
        generate(W)
