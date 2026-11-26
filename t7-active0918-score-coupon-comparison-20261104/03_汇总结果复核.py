"""Verify seven-batch counts, window rates and unchanged historical batch objects."""
from pathlib import Path
from decimal import Decimal
import hashlib, json
x=json.loads((Path(__file__).resolve().parent/'02_对比统计数据.json').read_text())
checked=0
assert len(x['batches'])==7
assert [b['batch'] for b in x['batches']]==['t7recalllist_active'+k for k in ['0918','1010','1016','1023','1030','1106','1116']]
for b in x['batches']:
    groups=b['groups'];days=list(b['windows'])
    assert [g['users'] for g in groups]==b['group_sizes']
    assert sum(b['group_sizes'])==b['coupon_selected_users']==b['score_selected_users']
    for i,g in enumerate(groups):
        assert g['score_rank_min']==sum(b['group_sizes'][:i])+1
        assert g['score_rank_max']==sum(b['group_sizes'][:i+1])
        for f in ['coupon','score']:
            counts=[g['windows'][d][f+'_applicants'] for d in days]
            assert all(0<=a<=g['users'] for a in counts)
            assert counts==sorted(counts)
            for d,a in zip(days,counts):
                assert Decimal(g['windows'][d][f+'_rate'])==Decimal(a)/g['users']
                checked+=1
        for d,w in g['windows'].items():
            assert Decimal(w['difference_pp'])==Decimal(w['score_applicants']-w['coupon_applicants'])*100/g['users']
    for r in b['cumulative']:
        part=groups[:r['top_groups']]
        assert r['users']==sum(g['users'] for g in part)
        for d,w in r['windows'].items():
            for f in ['coupon','score']:
                a=sum(g['windows'][d][f+'_applicants'] for g in part)
                assert w[f+'_applicants']==a
                assert Decimal(w[f+'_rate'])==Decimal(a)/r['users']
                checked+=1
            assert w['additional_observed_applicants']==w['score_applicants']-w['coupon_applicants']
            assert Decimal(w['difference_pp'])==Decimal(w['score_applicants']-w['coupon_applicants'])*100/r['users']
    print(b['batch'], 'groups=',len(groups),'windows=',','.join(days),'verified')
for b in x['batches'][:5]:
    actual=hashlib.sha256(json.dumps(b,ensure_ascii=False,sort_keys=True,separators=(',',':')).encode()).hexdigest()
    assert actual==x['historical_baseline']['frozen_batch_sha256'][b['batch']]
assert [list(b['windows']) for b in x['batches']]==[['3','7','15','30'],['3','7','15'],['3','7','15'],['3','7','15'],['3','7'],['3','7','15'],['3','7']]
print(json.dumps({'all_passed':True,'batches':len(x['batches']),'frozen_batches_verified':5,'rates_verified':checked,'database_required':False},ensure_ascii=False))
