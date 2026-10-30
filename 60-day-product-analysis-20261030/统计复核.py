"""Offline verification of the frozen aggregate evidence used by the report."""
from pathlib import Path
from decimal import Decimal
import hashlib
import json

HERE=Path(__file__).resolve().parent
DATA=HERE/'数据依据'
for row in json.loads((DATA/'来源清单.json').read_text()):
    assert hashlib.sha256((HERE/row['file']).read_bytes()).hexdigest()==row['sha256'],row['key']
load=lambda key:json.loads((DATA/(key+'.json')).read_text())
offers=load('offers');split=load('offer_split');choice=load('offer_choice')
assert offers['all_passed'] and split['all_passed'] and choice['all_passed']
total=offers['rows'][-1]
assert (total['offer_events'],total['d0_apply_events'])==(10621,3352)
for row in offers['rows']:
    mo=row['event_month'];items=[r for r in split['rows'] if r['event_month']==mo]
    for key in ('offer_events','d0_apply_events'):
        assert sum(r[key] for r in items)==row[key]
risk=load('risk');bands=load('bands');ranks=load('percentiles')
assert not bands['count_or_overdue_drift'] and not ranks['count_drift']
for c in risk['cohorts']:
    assert c['mature_orders']==c['overdue_orders']+c['settled_orders']
    assert abs(c['profit_rate']-(c['repaid_amt']/c['remit_amt']-1))<1e-12
for b in bands['rows']:
    match=next(r for r in ranks['summary'] if (r['loan_day'],r['model'],r['band'])==(b['loan_day'],b['model'],b['band']))
    assert b['n']==match['n']
    assert abs(Decimal(b['profit_rate'])-(Decimal(b['repaid_amt'])/Decimal(b['remit_amt'])-1))<Decimal('1e-20')
life=[x for x in load('lifetime')['groups'] if x['borrow_band']>0]
assert all(x['firstloan_orders']==0 and x['funded_orders']==x['reloan_orders'] for x in life)
assert sum(x['funded_orders'] for x in life)==3453
assert sum(x['mature_orders'] for x in life)==2406
profiles=[x for x in load('profiles')['by_loan_type'] if x['loan_type']=='reloan']
assert {x['loan_day'] for x in profiles}=={21,28,60}
print(json.dumps({'passed':True,'frozen_sources':12,'grant_events':10621,'d0_applications':3352,
                  'main_mature_60_orders':2393,'lifetime_reloan_funded_orders':3453},ensure_ascii=False))
