"""循环贷产品结构与盈利差异分析复核代码。
用法：python 完整分析代码.py --input 原始事件分层统计.xlsx --output-dir 复核结果
依赖：pandas、openpyxl。仅仅读取Excel，不连接数据库或写回源文件。
"""
from pathlib import Path
import hashlib, json, math
import pandas as pd

import argparse
parser = argparse.ArgumentParser(description='从事件分层Excel复核月度趋势与盈利差拆解')
parser.add_argument('--input', required=True, help='原始事件分层统计.xlsx的路径')
parser.add_argument('--output-dir', default='.', help='分析JSON和核验记录保存目录')
args = parser.parse_args()
W = Path(args.output_dir).resolve()
W.mkdir(parents=True, exist_ok=True)
SOURCE = Path(args.input).resolve()
MAP = dict(zip(
    ['模型','评分分组','产品分组','放款事件数','到期事件数','事件占比','盈利率','逾期率','逾期订单回款率','全部放款金额','到期放款金额','到期已还金额','逾期事件数','逾期放款金额','逾期已还金额'],
    ['model','cohort','product','orders','mature_orders','order_share','profit','overdue','recovery','funded_amt','principal','repaid','overdue_orders','overdue_principal','overdue_repaid']))
KEYS = {'循环贷整体':'all','单获额产品':'single','双获额产品合计':'dual','双获额产品长账期':'long','双获额产品短账期':'short','双获额产品未分长短':'unclassified'}
ADDITIVE = ['orders','mature_orders','funded_amt','principal','repaid','overdue_orders','overdue_principal','overdue_repaid']
TIERS = ['前20%','前20%—50%','后50%']

def ratio(a,b): return float(a/b) if b else None
def close(a,b): return math.isclose(float(a),float(b),rel_tol=1e-10,abs_tol=1e-6)
def enriched(r):
    r = dict(r)
    r.update(profit=ratio(r['repaid']-r['principal'],r['principal']),
             overdue=ratio(r['overdue_orders'],r['mature_orders']),
             recovery=ratio(r['overdue_repaid'],r['overdue_principal']),
             maturity=ratio(r['mature_orders'],r['orders']),
             q=ratio(r['overdue_principal'],r['principal']),
             s=ratio(r['repaid']-r['overdue_repaid'],r['principal']-r['overdue_principal']))
    if r['principal'] and r['overdue_principal']:
        assert close(r['profit'],(1-r['q'])*r['s']+r['q']*r['recovery']-1)
    return r

def read(sheet):
    df = pd.read_excel(SOURCE,sheet_name=sheet,header=4).rename(columns=MAP)
    records=[]
    for i,r in df.iterrows():
        v={k:(None if pd.isna(x) else x.item() if hasattr(x,'item') else x) for k,x in r.items() if k in MAP.values()}
        v.update(month=r['放款月份'].strftime('%Y-%m') if '放款月份' in r else '合计',key=KEYS[v['product']],source_row=i+6)
        for f in ['orders','mature_orders','overdue_orders']:v[f]=int(v[f])
        z=enriched(v)
        for f in ['profit','overdue','recovery']:
            assert (v[f] is None and z[f] is None) or close(v[f],z[f])
        records.append(z)
    return records

def pooled(rows):
    v={f:sum(r[f] for r in rows) for f in ADDITIVE}
    return enriched(v)

def cash_gap(a,b):
    q=(a['q']+b['q'])/2
    effects={'overdue_exposure':(b['q']-a['q'])*((b['recovery']+a['recovery'])-(b['s']+a['s']))/2,
             'overdue_recovery':q*(b['recovery']-a['recovery']),
             'non_overdue_return':(1-q)*(b['s']-a['s'])}
    delta=b['profit']-a['profit'];assert close(sum(effects.values()),delta)
    return {'a':a,'b':b,'delta':delta,'effects':effects}

def nested(monthly,model,ak,bk,months):
    d={(r['month'],r['cohort'],r['key']):r for r in monthly if r['model']==model and r['month'] in months and r['cohort'] in TIERS}
    aa={m:pooled([d[m,t,ak] for t in TIERS]) for m in months};bb={m:pooled([d[m,t,bk] for t in TIERS]) for m in months}
    A=pooled(list(aa.values()));B=pooled(list(bb.values()));eff={'month_mix':0.,'score_mix':0.,'within_month_score':0.}
    cells=[]
    for m in months:
        ma,mb=aa[m],bb[m];wa=ma['principal']/A['principal'];wb=mb['principal']/B['principal'];wm=(wa+wb)/2
        eff['month_mix']+=(wb-wa)*(mb['profit']+ma['profit'])/2
        for t in TIERS:
            a,b=d[m,t,ak],d[m,t,bk];sa=a['principal']/ma['principal'];sb=b['principal']/mb['principal']
            assert a['principal']>0 and b['principal']>0
            eff['score_mix']+=wm*(sb-sa)*(b['profit']+a['profit'])/2
            eff['within_month_score']+=wm*(sa+sb)/2*(b['profit']-a['profit'])
            cells.append({'month':m,'tier':t,'a_profit':a['profit'],'b_profit':b['profit'],'a_principal':a['principal'],'b_principal':b['principal']})
    delta=B['profit']-A['profit'];assert close(sum(eff.values()),delta)
    return {'model':model,'a_key':ak,'b_key':bk,'delta':delta,'effects':eff,'cells':cells}

def main():
    sha=hashlib.sha256(SOURCE.read_bytes()).hexdigest()
    assert sha=='363e909d4e5fa333c6ff87fb641f7580ff6803206283eb07e0abe3247ff27857'
    summary,monthly=read('全期汇总'),read('月度明细')
    assert len(summary)==54 and len(monthly)==540
    for r in summary:
        sub=[x for x in monthly if (x['model'],x['cohort'],x['key'])==(r['model'],r['cohort'],r['key'])]
        assert len(sub)==10
        for f in ADDITIVE:assert close(sum(x[f] for x in sub),r[f])
    lookup=lambda data,key,model='全部',cohort='全部客群':next(x for x in data if (x['key'],x['model'],x['cohort'])==(key,model,cohort))
    full={k:lookup(summary,k) for k in KEYS.values()}
    months=sorted({r['month'] for r in monthly})
    periods={}
    for label,ms in [('1—10月',months),('1—9月',months[:9])]:
        p={k:pooled([r for r in monthly if r['model']=='全部' and r['month'] in ms and r['key']==k]) for k in KEYS.values()}
        periods[label]={'products':p,'cash':{'dual_single':cash_gap(p['single'],p['dual']),'short_long':cash_gap(p['long'],p['short'])},
            'score':{model:{'dual_single':nested(monthly,model,'single','dual',ms),'short_long':nested(monthly,model,'long','short',ms)} for model in ['410 CYC','410 CRE']}}
    monthly_cash=[]
    for m in months:
        rows=[r for r in monthly if r['model']=='全部' and r['month']==m]
        z={k:lookup(rows,k) for k in KEYS.values()}
        for f in ADDITIVE:
            assert close(z['single'][f]+z['dual'][f],z['all'][f])
            assert close(z['long'][f]+z['short'][f]+z['unclassified'][f],z['dual'][f])
        monthly_cash.append({'month':m,'dual_single':cash_gap(z['single'],z['dual']),'short_long':cash_gap(z['long'],z['short'])})
    comparisons=[]
    for model,cohort in sorted({(r['model'],r['cohort']) for r in summary}):
        z={k:lookup(summary,k,model,cohort) for k in ['single','dual','long','short']}
        sub=[r for r in monthly if r['model']==model and r['cohort']==cohort]
        comparisons.append({'model':model,'cohort':cohort,'single_dual_gap':z['single']['profit']-z['dual']['profit'],'long_short_gap':z['long']['profit']-z['short']['profit'],
            'single_better_months':sum(lookup([r for r in sub if r['month']==m],'single',model,cohort)['profit']>lookup([r for r in sub if r['month']==m],'dual',model,cohort)['profit'] for m in months),
            'long_better_months':sum(lookup([r for r in sub if r['month']==m],'long',model,cohort)['profit']>lookup([r for r in sub if r['month']==m],'short',model,cohort)['profit'] for m in months)})
    tier_mix=[]
    for model in ['410 CYC','410 CRE']:
        for k in ['single','dual','long','short']:
            z=[lookup(summary,k,model,t) for t in TIERS];total=pooled(z)
            for r in z:tier_mix.append({'model':model,'key':k,'tier':r['cohort'],'orders':r['orders'],'order_share':r['orders']/total['orders'],'principal_share':r['principal']/total['principal'],'profit':r['profit']})
    result={'source':{'name':SOURCE.name,'sha256':sha,'sheets':{'summary':'全期汇总!A5:O59','monthly':'月度明细!A5:P545','definition':'事件评分门槛与口径!A30:B46'},'snapshot':'2026-11-10 13:43:57（北京时间）','maturity_date':'2026-11-09'},
        'summary':summary,'monthly':monthly,'periods':periods,'monthly_cash':monthly_cash,'tier_mix':tier_mix,'comparisons':comparisons,
        'scenario':{'short_current_profit':full['short']['profit'],'short_q':full['short']['q'],'short_recovery':full['short']['recovery'],'long_recovery':full['long']['recovery'],'short_s':full['short']['s'],'short_at_long_recovery':(1-full['short']['q'])*full['short']['s']+full['short']['q']*full['long']['recovery']-1}}
    (W/'report_data.json').write_text(json.dumps(result,ensure_ascii=False,indent=2,allow_nan=False))
    validation={'source_unchanged':hashlib.sha256(SOURCE.read_bytes()).hexdigest()==sha,'summary_rows':len(summary),'monthly_rows':len(monthly),'rates_recomputed':True,'monthly_totals_reconciled':True,'product_partitions_reconciled':True,'cash_decomposition_exact':True,'nested_score_decomposition_exact':True}
    (W/'analysis_validation.json').write_text(json.dumps(validation,ensure_ascii=False,indent=2))
    print(json.dumps(validation,ensure_ascii=False))
    for model,z in periods['1—10月']['score'].items():print(model,json.dumps(z['dual_single']['effects'],ensure_ascii=False))

if __name__=='__main__':main()
