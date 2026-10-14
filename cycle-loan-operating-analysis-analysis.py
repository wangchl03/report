"""Recompute the report from aggregate SQL outputs. No user identifiers needed."""
import argparse,json,calendar,math
from collections import defaultdict
from pathlib import Path
def ratio(n,d):return n/d if d else None
def grouped(rows,keys,fields):
  out={}
  for r in rows:
    key=tuple(r[k] for k in keys)
    a=out.setdefault(key,{k:r[k] for k in keys}|{f:0 for f in fields})
    for f in fields:a[f]+=r.get(f) or 0
  return list(out.values())
def finance_metrics(r):
  n=r['matured_orders'];amt=r['matured_remit_amt']
  return r|{'maturity_coverage':ratio(n,r['funded_orders']),
    'average_remit_amt':ratio(r['funded_remit_amt'],r['funded_orders']),
    'weighted_fee_rate':ratio(r['contractual_fee_amt'],r['fee_known_remit_amt']),
    'average_loan_days':ratio(r['loan_day_sum'],r['loan_day_known_orders']),
    'cash_profit_amt':r['current_cash_repaid_amt']-amt if n else None,
    'book_profit_amt':r['current_book_repaid_amt']-amt if n else None,
    'd7_profit_amt':r['paid_by_d7_amt']-amt if n else None,
    'cash_profit_rate':ratio(r['current_cash_repaid_amt']-amt,amt) if n else None,
    'book_profit_rate':ratio(r['current_book_repaid_amt']-amt,amt) if n else None,
    'd7_profit_rate':ratio(r['paid_by_d7_amt']-amt,amt) if n else None,
    'current_overdue_rate':ratio(r['current_status8_orders'],n),
    'd7_overdue_rate':ratio(r['d7_overdue_orders'],n)}
def derive(s):
  a=s['activity'];fin=s['finance']['finance_cells'];of=s['offers']['monthly'];lc=s['lifecycle'];du=s['duration']
  add=['funded_orders','funded_remit_amt','contractual_fee_amt','fee_known_remit_amt','loan_day_sum','loan_day_known_orders',
       'matured_orders','matured_remit_amt','current_book_repaid_amt','current_cash_repaid_amt','paid_by_due_amt',
       'paid_by_d7_amt','current_status8_orders','due_overdue_orders','d7_overdue_orders']
  fm=[finance_metrics(r) for r in grouped(fin,['month','order_type'],add) if r['order_type'] in ('cycle','settled_reloan')]
  fc=[finance_metrics(r|{f:r.get(f) or 0 for f in add}) for r in fin if r['order_type'] in ('cycle','settled_reloan')]
  scale=[]
  background=s['finance'].get('funding_background') or grouped(fin,['month','order_type'],['funded_orders','funded_remit_amt'])
  for month in sorted({r['month'] for r in background}):
    rows=[r for r in background if r['month']==month];cy=next((r for r in rows if r['order_type']=='cycle'),None)
    st=next((r for r in rows if r['order_type']=='settled_reloan'),None)
    alln=sum(r['funded_orders'] for r in rows);alla=sum(r['funded_remit_amt'] for r in rows)
    scale.append({'month':month,'all_funded_orders':alln,'all_funded_remit_amt':alla,
      'cycle_funded_orders':cy['funded_orders'] if cy else 0,'settled_funded_orders':st['funded_orders'] if st else 0,
      'firstloan_funded_orders':sum(r['funded_orders'] for r in rows if r['order_type']=='firstloan'),
      'unknown_funded_orders':sum(r['funded_orders'] for r in rows if r['order_type']=='unknown'),
      'cycle_share_all':ratio(cy['funded_orders'],alln) if cy else 0,
      'cycle_share_reloan':ratio(cy['funded_orders'],cy['funded_orders']+(st['funded_orders'] if st else 0)) if cy else 0,
      'cycle_amount_share_all':ratio(cy['funded_remit_amt'],alla) if cy else 0})
  # Four-question qualification and cadence retain their own January-Oct13 boundaries.
  funded={r['month']:r for r in a['funded_monthly']};q1=[]
  for r in a['offer_monthly']:
    f=funded[r['month']]
    q1.append(r|{k:f[k] for k in ('new_cycle_borrowers','old_cycle_borrowers','new_cycle_funded_orders','old_cycle_funded_orders')}
      |{'old_group_frequency':ratio(f['old_cycle_funded_orders'],f['old_cycle_borrowers'])})
  jan=next(r for r in q1 if r['month']=='2026-01');sep=next(r for r in q1 if r['month']=='2026-09')
  number=frequency=0
  for prefix in ('new','old'):
    n0=jan[prefix+'_cycle_borrowers'];n1=sep[prefix+'_cycle_borrowers']
    f0=jan[prefix+'_cycle_funded_orders']/n0;f1=sep[prefix+'_cycle_funded_orders']/n1
    number+=(n1-n0)*(f0+f1)/2;frequency+=(f1-f0)*(n0+n1)/2
  delta=sep['new_cycle_funded_orders']+sep['old_cycle_funded_orders']-jan['new_cycle_funded_orders']-jan['old_cycle_funded_orders']
  assert math.isclose(number+frequency,delta,abs_tol=1e-7)
  growth={'order_increase':delta,'new_group_increase':sep['new_cycle_funded_orders']-jan['new_cycle_funded_orders'],
    'old_group_increase':sep['old_cycle_funded_orders']-jan['old_cycle_funded_orders'],
    'borrower_number_component':number,'frequency_component':frequency,
    'borrower_number_share':number/delta,'frequency_share':frequency/delta}
  cadence=[r|{'early_share':ratio(r['early_settled_orders'],r['due_date_known_orders']),
    'held_days':ratio(r['held_day_sum'],r['held_day_known_orders']),
    'scheduled_days':ratio(r['scheduled_day_sum'],r['scheduled_day_known_orders'])}
    for r in a['settlement_monthly'] if r['order_type']=='cycle']
  funnel=[]
  fields=['all_settled_orders','zero_outstanding_settled_orders','canonical_clean_scenes','same_day_type3_pass_scenes',
          'strict_t0_settled_orders','strict_t0_events']
  for month in sorted(funded):
    for kind in ('cycle','non_cycle'):
      rows=[r for r in s['funnel']['monthly_funnel'] if r['month']==month and
            (r['order_type']=='cycle' if kind=='cycle' else r['order_type'] in ('firstloan','settled_reloan'))]
      r={'month':month,'kind':kind}|{f:sum(z[f] for z in rows) for f in fields}
      r['zero_outstanding_share']=ratio(r['zero_outstanding_settled_orders'],r['all_settled_orders'])
      r['type3_pass_given_zero_scene']=ratio(r['same_day_type3_pass_scenes'],r['canonical_clean_scenes'])
      r['t0_order_share']=ratio(r['strict_t0_settled_orders'],r['all_settled_orders']);funnel.append(r)
  # Rates are recalculated from counts; D1/D2 are single-day, not cumulative.
  offers=[]
  for r in of:
    z=r.copy()
    for key,num in [('d0','n_d0'),('d1_single','n_d1_only'),('d2_single','n_d2_only'),
      ('d1_cumulative','n_d1_cumulative'),('d2_cumulative','n_d2_cumulative'),('d3','n_d3_cumulative'),
      ('d7','n_d7_cumulative'),('d15','n_d15_cumulative')]:z[key]=ratio(r[num],r['n_offer'])
    offers.append(z)
  eligible_total=sum(r['n_offer'] for r in offers if r['denominator_rule']=='serial_id订单去重')
  totals=lc['lifecycle_totals'];paths=[]
  for total in totals:
    cohort=total['cohort_name'];ps=[r for r in lc['lifecycle_paths'] if r['cohort_name']==cohort];known=0
    for p in ps:
      if p['path']=='其他或缺失标签路径':continue
      n=p['users'] if p['path']=='首笔循环贷后全部循环贷' else p['verified_transition_users'];known+=n
      paths.append({'cohort_name':cohort,'path':p['path'],'users':n,'share':n/total['users'],
        'single_order_users':p['single_order_users'],'cohort_users':total['users']})
    paths.append({'cohort_name':cohort,'path':'其他标签或时序未核验','users':total['users']-known,
                  'share':(total['users']-known)/total['users'],'single_order_users':0,'cohort_users':total['users']})
  silence=lc['lifecycle_silence_risk'];risk=[]
  for r in silence:
    dn=sum(p['users'] for p in silence if (p['cohort_name'],p['path'],p['silent_days'])==(r['cohort_name'],r['path'],r['silent_days']))
    risk.append(r|{'silent_users_in_path':dn,'share':ratio(r['users'],dn)})
  dm=[];heat=[]
  for m in du['duration_monthly']:
    rows=[r for r in du['available_calendar_day_distribution'] if r['month']==m['month']];n=m['completed_available_orders']
    dm.append(m|{'completed_coverage':ratio(n,m['eligible_orders']),
      'within7_share':ratio(sum(r['orders'] for r in rows if r['day_group']<=7),n),
      'day15_share':ratio(sum(r['orders'] for r in rows if r['day_group']==15),n)})
    for day in range(16):
      count=sum(r['orders'] for r in rows if r['day_group']==day)
      heat.append({'month':m['month'],'day':day,'orders':count,'share':ratio(count,n),'completed_orders':n})
  winN=sum(r['completed_available_orders'] for r in dm)
  window_summary={'eligible_orders':sum(r['eligible_orders'] for r in dm),'completed_orders':winN,
    'mean_days':sum(r['completed_available_orders']*r['completed_available_mean_days'] for r in dm)/winN,
    'within7_share':sum(r['within7_share']*r['completed_available_orders'] for r in dm)/winN,
    'overwritten_potential_share':sum(r['completed_potential_overwritten_orders'] for r in dm)/winN,
    'still_valid_unapplied_orders':sum(r['still_valid_unapplied_orders'] for r in dm),
    'unapplied_overwritten':sum(r['overwritten_unapplied_orders'] for r in dm),
    'unapplied_expired':sum(r['expired_unapplied_orders'] for r in dm)}
  # Compare same fully matured month and loan-count band, never infer causality.
  compare=[]
  for month in sorted({r['month'] for r in fc}):
    for band in ('2次','3次','4次','5次','6次及以上'):
      cy=next((r for r in fc if (r['month'],r['loan_band'],r['order_type'])==(month,band,'cycle')),None)
      st=next((r for r in fc if (r['month'],r['loan_band'],r['order_type'])==(month,band,'settled_reloan')),None)
      if cy and st and min(cy['matured_orders'],st['matured_orders'])>=30:
        compare.append({'month':month,'loan_band':band,'cycle_matured_orders':cy['matured_orders'],
          'settled_matured_orders':st['matured_orders'],'cash_profit_gap_pp':100*(cy['cash_profit_rate']-st['cash_profit_rate']),
          'd7_profit_gap_pp':100*(cy['d7_profit_rate']-st['d7_profit_rate']),
          'current_overdue_gap_pp':100*(cy['current_overdue_rate']-st['current_overdue_rate']),
          'd7_overdue_gap_pp':100*(cy['d7_overdue_rate']-st['d7_overdue_rate'])})
  order={'首笔循环贷后全部循环贷':0,'转结清续贷后未再循环贷':1,'转结清续贷后又回循环贷':2,'其他标签或时序未核验':3}
  paths.sort(key=lambda r:(r['cohort_name'],order[r['path']]))
  result={'meta':s['metadata'],'funding_monthly':scale,'finance_monthly':sorted(fm,key=lambda r:(r['month'],r['order_type'])),
    'finance_cells':fc,'quality_comparison':compare,'offer_monthly':sorted(offers,key=lambda r:(r['denominator_rule'],r['month'])),
    'offer_orders':eligible_total,'qualification':q1,'funding_growth':growth,'funded_sequence':a['funded_sequence'],
    'settlement_cadence':cadence,'fixed_old_cohort':a['fixed_old_monthly'],'t0_bridge':funnel,
    'lifecycle_totals':totals,'lifecycle_paths':paths,'silence_risk':risk,'cancellation_audit':lc['cancellation_audit'],
    'window_monthly':sorted(dm,key=lambda r:r['month']),'window_heatmap':heat,'window_summary':window_summary,
    'renewal_audit':s['renewal'],'audits':{'finance':s['finance']['finance_audit'],'offers':s['offers']['source_audit'],
      'lifecycle':lc['lifecycle_source_audit'],'duration':du['duration_source_audit'],'funnel':s['funnel']['funnel_audit']}}
  return result
def main():
  p=argparse.ArgumentParser();p.add_argument('--sources',required=True);p.add_argument('--output',required=True);args=p.parse_args()
  result=derive(json.loads(Path(args.sources).read_text()));Path(args.output).write_text(json.dumps(result,ensure_ascii=False,indent=2))
  print(json.dumps({'offer_orders':result['offer_orders'],'window':result['window_summary'],
    'finance_jan_aug_sep':[r for r in result['finance_monthly'] if r['month'] in ('2026-01','2026-08','2026-09') and r['order_type'] in ('cycle','settled_reloan')],
    'funding_growth':result['funding_growth']},ensure_ascii=False,indent=2))
if __name__=='__main__':main()
