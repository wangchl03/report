from pathlib import Path
from collections import defaultdict
import json,re,math,hashlib
W=Path(__file__).resolve().parent
SOURCE=json.loads((W/'source_workbooks.json').read_text())
def ratio(a,b):return a/b if b else None
def records(book,sheet):
 rows=book['sheets'][sheet]['rows'];head=rows[4]
 return [dict(zip(head,row))|{'excel_row':i} for i,row in enumerate(rows[5:],6) if row and row[0] is not None]
def aggregate(rows):
 n=sum(r['提单单量'] for r in rows);fund=sum(r['放款单量'] for r in rows);long=sum(r['长账期单量'] for r in rows);mat=sum(r['到期放款单量'] for r in rows);over=sum(r['到期逾期单量'] for r in rows);amt=sum(r['到期放款金额'] for r in rows);paid=round(sum(r['到期已还金额'] for r in rows),2)
 return dict(first=n,funded=fund,long_n=long,mature=mat,overdue_n=over,remit=amt,repaid=paid,profit_amount=round(paid-amt,2),profit=ratio(paid-amt,amt),overdue=ratio(over,mat),long_share=ratio(long,n),maturity=ratio(mat,fund),funding=ratio(fund,n),ticket=ratio(amt,mat))
def split(rows):return {side:aggregate([r for r in rows if bool(r['长账期单量'])==(side=='long')]) for side in ['long','short']}
result={};checks=[]
for name,b in SOURCE.items():
 summary=records(b,'批次汇总');total=summary.pop();rows=records(b,'获额组合与提单产品');product=records(b,'多产品首单产品统计');allp=records(b,'全部首单产品对照')
 assert len(summary)==(9 if name=='新增流失' else 7)
 assert total['全部首单数']==total['单产品首单数']+total['合格多产品提单单量']+total['异常首单数']
 assert total['同账期多产品首单数']==0
 for r in rows:
  assert r['长账期单量'] in [0,r['提单单量']]
  assert len(str(r['获额产品编号组合']).split(' + '))==2
  assert r['到期逾期单量']<=r['到期放款单量']<=r['放款单量']<=r['提单单量']
  if r['到期放款金额']:
   assert math.isclose(r['到期盈利率'],(r['到期已还金额']-r['到期放款金额'])/r['到期放款金额'],abs_tol=1e-10)
   assert math.isclose(r['到期订单逾期率'],r['到期逾期单量']/r['到期放款单量'],abs_tol=1e-10)
 a=aggregate(rows);sp=split(rows)
 for key,col in [('first','合格多产品提单单量'),('funded','放款单量'),('long_n','长账期单量'),('mature','双产品到期订单数'),('overdue_n','到期逾期单量'),('remit','到期放款金额'),('repaid','到期已还金额')]:
  assert math.isclose(a[key],total[col],abs_tol=.001),(name,key,a[key],total[col])
 for key,col in [('profit','双产品到期盈利率'),('overdue','双产品到期逾期率')]:assert math.isclose(a[key],total[col],abs_tol=1e-10)
 for side,label in [('long','长'),('short','短')]:
  assert sp[side]['mature']==total[f'双产品{label}账期到期订单数']
  for key,metric in [('profit','盈利率'),('overdue','逾期率')]:assert math.isclose(sp[side][key],total[f'双产品{label}账期到期{metric}'],abs_tol=1e-10)
 batches=[]
 for s in summary:
  rr=[r for r in rows if r['召回批次']==s['召回批次']];d=split(rr);aa=aggregate(rr)
  for key,col in [('first','合格多产品提单单量'),('funded','放款单量'),('long_n','长账期单量'),('mature','双产品到期订单数'),('overdue_n','到期逾期单量')]:assert aa[key]==s[col]
  assert s['双产品到期订单数']==s['双产品长账期到期订单数']+s['双产品短账期到期订单数']
  days=(__import__('datetime').date(2026,11,5)-__import__('datetime').datetime.fromisoformat(s['召回日期']).date()).days
  batches.append(dict(batch=s['召回批次'],days=days,recall=s['召回用户数'],first=s['全部首单数'],single=s['单产品首单数'],dual=s['合格多产品提单单量'],anomalies=s['异常首单数'],single_mature=s['单产品到期订单数'],single_profit=s['单产品到期盈利率'],single_overdue=s['单产品到期逾期率'],dual_all=aa,**d))
 pairs=[]
 for pair in sorted(set(r['获额产品编号组合'] for r in rows)):
  rr=[r for r in rows if r['获额产品编号组合']==pair]
  pairs.append(dict(pair=pair,label=rr[0]['获额产品及账期'],**aggregate(rr),**split(rr)))
 pairs.sort(key=lambda a:a['first'],reverse=True)
 terms=[]
 for day in sorted(set(r['提单产品账期（天）'] for r in rows)):
  rr=[r for r in rows if r['提单产品账期（天）']==day]
  terms.append(dict(days=day,**aggregate(rr),**split(rr)))
 matrix=[]
 for period in sorted(set(tuple(sorted(int(x) for x in re.findall(r'（(\d+)天）',r['获额产品及账期']))) for r in rows)):
  rr=[r for r in rows if tuple(sorted(int(x) for x in re.findall(r'（(\d+)天）',r['获额产品及账期'])))==period]
  matrix.append(dict(period=list(period),**aggregate(rr),**split(rr)))
 old=[r for r in rows if r['召回日期']<'2026-10-01']
 mature_early={'all':aggregate(old),**split(old)}
 # Standardize long and short outcomes to a common distribution within batch + product pair.
 cells=[]
 for key in sorted(set((r['召回批次'],r['获额产品编号组合']) for r in rows)):
  rr=[r for r in rows if (r['召回批次'],r['获额产品编号组合'])==key];d=split(rr)
  if d['long']['mature'] and d['short']['mature']:
   cells.append(dict(batch=key[0],pair=key[1],**d))
 def standardize(threshold):
  eligible=[c for c in cells if min(c['long']['mature'],c['short']['mature'])>=threshold]
  if not eligible:return {'cells':0}
  nw=sum(c['long']['mature']+c['short']['mature'] for c in eligible);aw=sum(c['long']['remit']+c['short']['remit'] for c in eligible)
  return dict(cells=len(eligible),mature=nw,remit=aw,long_mature=sum(c['long']['mature'] for c in eligible),short_mature=sum(c['short']['mature'] for c in eligible),
    long_profit=sum(c['long']['profit']*(c['long']['remit']+c['short']['remit']) for c in eligible)/aw,short_profit=sum(c['short']['profit']*(c['long']['remit']+c['short']['remit']) for c in eligible)/aw,
    long_overdue=sum(c['long']['overdue']*(c['long']['mature']+c['short']['mature']) for c in eligible)/nw,short_overdue=sum(c['short']['overdue']*(c['long']['mature']+c['short']['mature']) for c in eligible)/nw)
 allfund=sum(r['全部首单放款单量'] for r in allp);allmat=sum(r['到期放款单量'] for r in allp)
 group=dict(first=total['单产品首单数'],mature=total['单产品到期订单数'],profit=total['单产品到期盈利率'],overdue=total['单产品到期逾期率'],overdue_n=round(total['单产品到期订单数']*total['单产品到期逾期率']))
 assert math.isclose(group['overdue_n']/group['mature'],group['overdue'],abs_tol=1e-10)
 sensitivity={label:{'all':aggregate(rs),**split(rs)} for label,rs in [('all',rows),('early',old),('without_first',[r for r in rows if r['召回批次']!=summary[0]['召回批次']])]}
 result[name]=dict(sensitivity=sensitivity,source=b['path'],sha256=b['sha256'],snapshot=b['sheets']['批次汇总']['rows'][1][0],recall=total['召回用户数'],first=total['全部首单数'],anomalies=total['异常首单数'],single=group,dual=a,**sp,batches=batches,pairs=pairs,terms=terms,term_combos=matrix,early=mature_early,standardized={str(t):standardize(t) for t in [1,5,10,20]},all_first_funded=allfund,all_first_mature=allmat,unclassified_mature=allmat-total['单产品到期订单数']-a['mature'],source_totals=total)
 # Reconcile product-detail and combination-detail sheets without counting the duplicate Sheet1.
 for col1,col2 in [('提单单量','提单单量'),('放款单量','放款单量'),('长账期单量','长账期单量'),('到期放款单量','到期放款单量'),('到期逾期单量','到期逾期单量'),('到期放款金额','到期放款金额'),('到期已还金额','到期已还金额')]:assert math.isclose(sum(r[col1] for r in rows),sum(r[col2] for r in product),abs_tol=.001)
 checks.append({'population':name,'batch_count':len(summary),'combination_rows':len(rows),'workbook_total_reconciled':True,'all_product_detail_reconciled':True,'long_short_financials_reconciled':True,'unclassified_mature':result[name]['unclassified_mature'],'source_hash':b['sha256']})
(W/'analysis.json').write_text(json.dumps(result,ensure_ascii=False,indent=2,allow_nan=False));(W/'checks.json').write_text(json.dumps(checks,ensure_ascii=False,indent=2))
for name,r in result.items():
 print('\n',name)
 print('total', {k:r[k] for k in ['recall','first','anomalies','single','dual','long','short','all_first_funded','all_first_mature','unclassified_mature']})
 print('terms',r['terms'])
 print('term combos',r['term_combos'])
 print('top 7 pairs',r['pairs'][:7])
 print('early',r['early'],'standardized',r['standardized'])
