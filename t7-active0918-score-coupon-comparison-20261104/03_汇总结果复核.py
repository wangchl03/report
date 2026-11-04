"""Verify every published aggregate and display percentage; no database required."""
from pathlib import Path
from decimal import Decimal
import json
W=Path(__file__).resolve().parent
x=json.loads((W/'02_对比统计数据.json').read_text())
sizes=[91,631,1302,3369,2641]
assert [g['users']for g in x['groups']]==sizes
assert sum(sizes)==8034
checked=0
for g in x['groups']:
    for family in ['coupon','score']:
        a=[g['windows'][str(d)][family+'_applicants']for d in [3,7,15]]
        assert 0<=a[0]<=a[1]<=a[2]<=g['users']
        for day,count in zip([3,7,15],a):
            assert Decimal(g['windows'][str(day)][family+'_rate'])==Decimal(count)/g['users']
            checked+=1
for r in x['cumulative']:
    part=x['groups'][:r['top_groups']]
    assert r['users']==sum(g['users']for g in part)
    for day in [3,7,15]:
        w=r['windows'][str(day)]
        for family in ['coupon','score']:
            a=sum(g['windows'][str(day)][family+'_applicants']for g in part)
            assert w[family+'_applicants']==a
            assert Decimal(w[family+'_rate'])==Decimal(a)/r['users']
            checked+=1
        assert w['additional_observed_applicants']==w['score_applicants']-w['coupon_applicants']
        assert Decimal(w['difference_pp'])==Decimal(w['score_applicants']-w['coupon_applicants'])*100/r['users']
for day in [3,7,15]:
    rates=[Decimal(g['windows'][str(day)]['score_rate'])for g in x['groups']]
    assert all(a>b for a,b in zip(rates,rates[1:]))
assert x['cumulative'][2]['windows']['7']['score_applicants']==275
assert x['cumulative'][2]['windows']['7']['coupon_applicants']==100
print(json.dumps({'all_passed':True,'rates_verified':checked,'database_required':False},ensure_ascii=False))
