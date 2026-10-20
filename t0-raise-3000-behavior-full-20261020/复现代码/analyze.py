"""Event-level behavior description, common-support comparisons and sensitivity."""
from pathlib import Path
import json,math,warnings,os
warnings.filterwarnings('ignore')
import numpy as np,pandas as pd,pyarrow.parquet as pq
W=Path(__file__).resolve().parent
OUT=Path(os.environ.get('T0_BEHAVIOR_OUTPUT_DIR',str(W.parent.parent/'outputs/T0提额3000及以上_获额后行为特征对比_20260601-20260930_20261020')))
OUT.mkdir(exist_ok=True)
GROUPS=['提额≥3000','提额0至3000','额度不变','额度降低','其他T0合计']
PAGES=['newpage','amount','term','contract','plan','purpose','confirm','coupon','comparison']
LABEL={'newpage':'借款页进页','amount':'金额选择或修改','term':'期次选择','contract':'合同详情',
       'plan':'还款计划详情','purpose':'借款用途','confirm':'提单确认相关','coupon':'优惠券相关','comparison':'产品比较相关'}
PRIMARY=['d0_active','d0_entry','d0_amount','d0_term','d0_plan','d0_contract','d0_coupon','d0_comparison','has_d0_apply']
MLABEL={'d0_active':'获额后当天有行为记录','d0_entry':'获额后当天进入借款页',
        **{'d0_'+k:LABEL[k]+'发生率' for k in PAGES if k!='newpage'},'has_d0_apply':'当天实际提单率',
        'pre7_active_days':'获额前7天活跃天数','pre7_entry_days':'获额前7天借款页活跃天数'}


def enc(v):
 if isinstance(v,(np.integer,)):return int(v)
 if isinstance(v,(np.floating,)):return float(v) if np.isfinite(v) else None
 if isinstance(v,(pd.Timestamp,)):return v.isoformat()
 if isinstance(v,np.bool_):return bool(v)
 raise TypeError(type(v).__name__)


def group_frames(f):
 for g in GROUPS:yield g,f.loc[f.group.ne('提额≥3000') if g=='其他T0合计' else f.group.eq(g)]


def setup():
 manifest=json.loads((W/'behavior_manifest.json').read_text());assert manifest['complete'] and len(manifest['shards'])==8
 # Epochs are authoritative; do not depend on external timezone-object
 # reconstruction in older pandas/pyarrow combinations.
 schema=pq.read_schema(W/'events.parquet')
 cols=[field.name for field in schema if not (hasattr(field.type,'tz') and field.type.tz)]
 f=pd.read_parquet(W/'events.parquet',columns=cols).sort_values('event_id').reset_index(drop=True)
 f['offer_date']=pd.to_datetime(f.vir_date.str[:10])
 f['offer_hour']=pd.to_datetime(f.offer_epoch,unit='s',utc=True).dt.tz_convert('America/Belize').dt.hour
 f['hour_band']=(f.offer_hour//6).astype(str)
 day_epoch=pd.to_datetime(f.offer_epoch,unit='s',utc=True).dt.tz_convert('America/Belize').dt.normalize().map(lambda t:t.timestamp()).to_numpy()
 f['day_epoch']=day_epoch
 d=pd.read_parquet(W/'behavior_daily.parquet')
 assert d.groupby('event_id').first_app_epoch.nunique().max()<=1
 first=d.groupby('event_id').first_app_epoch.first()
 f['first_app_epoch']=f.event_id.map(first)
 d0_label=(f.first_app_epoch.notna()&(f.first_app_epoch<day_epoch+86400)).astype(int)
 assert np.array_equal(d0_label,f.has_d0_apply),'D0 attribution differs from the reference cohort'
 f['has_d7_apply']=f.first_app_epoch.notna().astype(int)
 f['d0_exposure_hours']=(np.minimum(f.stop_epoch,day_epoch+86400)-f.offer_epoch)/3600
 f['preapp_exposure_hours']=(np.minimum(np.minimum(f.stop_epoch,day_epoch+86400),f.first_app_epoch.fillna(np.inf))-f.offer_epoch).clip(lower=0)/3600
 assert (f.d0_exposure_hours>0).all()
 d0=d.loc[d.relative_day.eq(0)].set_index('event_id')
 for name in ['records','page_seconds','loan_page_seconds','first_page_epoch']+PAGES+['pre_records']+['pre_'+k for k in PAGES]:
  f['d0_'+name]=f.event_id.map(d0[name]).fillna(0 if name!='first_page_epoch' else np.nan)
 f['d0_active']=f.d0_records.gt(0).astype(int);f['d0_entry']=f.d0_newpage.gt(0).astype(int)
 for k in PAGES:
  if k!='newpage':f['d0_'+k]=(f['d0_'+k]>0).astype(int)
  f['before_app_'+k]=f['d0_pre_'+k].gt(0).astype(int)
 f['entry_delay_minutes']=(f.d0_first_page_epoch-f.offer_epoch)/60
 pre=d.loc[d.relative_day.between(-7,-1)].copy()
 for field,flag in [('active','records'),('entry','newpage')]:
  s=pre.loc[pre[flag]>0].groupby('event_id').size();f['pre7_'+field+'_days']=f.event_id.map(s).fillna(0).astype(int)
 for k in ['amount','plan','coupon','comparison']:
  s=pre.groupby('event_id')[k].sum();f['pre7_'+k+'_count']=f.event_id.map(s).fillna(0)
 for n,g in group_frames(f):assert len(g)>0,n
 assert len(f.loc[f.group.eq('提额≥3000')])==12309
 assert f.loc[f.group.eq('提额≥3000'),'has_d0_apply'].sum()==3061
 f.to_parquet(W/'analysis_features.parquet',index=False)
 return f,d,manifest


def summary(g,label,period):
 out={'group':label,'period':period,'events':len(g),'users':g.user_id.nunique(),
      'd0_n':int(g.has_d0_apply.sum()),'d7_n':int(g.has_d7_apply.sum()),
      'loan_n_mean':g.successful_loan_n.mean(),'credit_mean':g.current_credit_amt.mean(),
      'previous_credit_mean':g.previous_credit_amt.mean(),'daily_fee_mean':g.current_daily.mean(),
      'previous_usage_mean':g.previous_usage.mean(),'current_usage_mean':g.current_usage.mean(),
      'd0_exposure_hours':g.d0_exposure_hours.mean(),'preapp_exposure_hours':g.preapp_exposure_hours.mean(),
      'pre7_active_days':g.pre7_active_days.mean(),'pre7_entry_days':g.pre7_entry_days.mean(),
      'd0_records_mean':g.d0_records.mean(),'d0_page_seconds_mean':g.d0_page_seconds.mean(),
      'd0_loan_page_seconds_mean':g.d0_loan_page_seconds.mean(),
      'entry_delay_minutes_median':g.entry_delay_minutes.median(),
      'd0_loan_page_seconds_median_entrants':g.loc[g.d0_entry.eq(1),'d0_loan_page_seconds'].median()}
 for field in PRIMARY+['d0_confirm','d0_purpose']:
  out[field]=g[field].mean();out[field+'_n']=int(g[field].sum())
 out['d7_rate']=g.has_d7_apply.mean()
 entrants=g.loc[g.d0_entry.eq(1)]
 out['entry_n']=len(entrants)
 out['entry_actual_submit_rate']=entrants.has_d0_apply.mean()
 out['preapp_entry_n']=int(g.before_app_newpage.sum())
 for k in ['amount','term','plan','coupon','comparison']:
  out[k+'_among_entry']=entrants['d0_'+k].mean()
 return out


def standardized(f,control='其他T0合计',strata=None,minimum=(10,20),name='产品条件可比'):
 strata=strata or ['month','loan_stage','credit_band','rate_band']
 keep=f.group.eq('提额≥3000') | (f.group.ne('提额≥3000') if control=='其他T0合计' else f.group.eq(control))
 x=f.loc[keep].copy();x['is_target']=x.group.eq('提额≥3000')
 x['cell']=x[strata].astype(str).agg('|'.join,axis=1)
 counts=x.groupby(['cell','is_target']).size().unstack(fill_value=0)
 common=counts.index[(counts.get(True,0)>=minimum[0])&(counts.get(False,0)>=minimum[1])]
 original_target=int(x.is_target.sum());x=x.loc[x.cell.isin(common)].copy()
 t=x.loc[x.is_target];c=x.loc[~x.is_target]
 meta={'analysis':name,'control':control,'strata':strata,'common_cells':len(common),
       'target_n':len(t),'control_n':len(c),'target_coverage':len(t)/original_target if original_target else 0,
       'control_coverage':len(c)/(keep.sum()-original_target) if keep.sum()>original_target else 0,
       'minimum_target_cell':minimum[0],'minimum_control_cell':minimum[1]}
 out=[]
 if not len(x):return out,meta
 target_counts=t.groupby('cell').size();weights=target_counts/len(t)
 for field in PRIMARY+['pre7_active_days','pre7_entry_days']:
  tm=t.groupby('cell')[field].mean();cm=c.groupby('cell')[field].mean()
  mt=float((weights*tm).sum());mc=float((weights*cm).sum());delta=mt-mc
  assert np.isclose(weights.sum(),1.) and np.isclose(mt,t[field].mean())
  if not field.startswith('pre7'):assert 0<=mt<=1 and 0<=mc<=1
  # Fixed common-support target weights; users may contribute both target and
  # control events. Aggregate both signs within user before calculating SE.
  influence=pd.Series(0.,index=x.index)
  for target,means,part,sign in [(True,tm,t,1),(False,cm,c,-1)]:
   ns=part.groupby('cell').size()
   influence.loc[part.index]=sign*part.cell.map(weights/ns)*(part[field]-part.cell.map(means))
  user_influence=influence.groupby(x.user_id).sum();n_users=len(user_influence)
  se=float(np.sqrt(np.square(user_influence).sum()*n_users/max(n_users-1,1)))
  out.append({'analysis':name,'control':control,'metric':field,'metric_label':MLABEL[field],
              'target':mt,'control_rate':mc,'delta':delta,'low95':delta-1.96*se,'high95':delta+1.96*se,
              'target_n':len(t),'control_n':len(c),'target_coverage':meta['target_coverage'],'common_cells':len(common)})
 return out,meta


def analyze():
 f,d,manifest=setup()
 overall=[summary(g,n,'合计') for n,g in group_frames(f)]
 monthly=[]
 for month in sorted(f.month.unique()):
  for n,g in group_frames(f.loc[f.month.eq(month)]):monthly.append(summary(g,n,month))
 daily=[];quality_dates=set()
 for day in range(-7,8):
  z=d.loc[d.relative_day.eq(day)].set_index('event_id')
  frame=f[['event_id','user_id','group','month','has_d0_apply','offer_epoch','stop_epoch','day_epoch','first_app_epoch']].copy()
  begin=frame.day_epoch+day*86400;end=begin+86400
  if day<0:frame['exposure_hours']=24.
  else:frame['exposure_hours']=((np.minimum(end,frame.stop_epoch)-np.maximum(begin,frame.offer_epoch))/3600).clip(lower=0)
  for col in ['records','page_seconds','loan_page_seconds']+PAGES:
   frame[col]=frame.event_id.map(z[col]).fillna(0)
  present=frame.records>0
  quality_dates.update(pd.to_datetime(frame.loc[present,'day_epoch']+day*86400,unit='s',utc=True).dt.tz_convert('America/Belize').dt.strftime('%Y-%m-%d'))
  for group,g in group_frames(frame):
   exposed=g.loc[g.exposure_hours>0]
   r={'group':group,'day':day,'cohort_events':len(g),'exposed_events':len(exposed),'exposure_hours':exposed.exposure_hours.mean(),
      'active_n':int(exposed.records.gt(0).sum()),'active_rate':exposed.records.gt(0).mean(),
      'records_mean':exposed.records.mean(),'page_seconds_mean':exposed.page_seconds.mean(),'loan_page_seconds_mean':exposed.loan_page_seconds.mean()}
   for page in PAGES:r[page+'_n']=int(exposed[page].gt(0).sum());r[page+'_rate']=exposed[page].gt(0).mean()
   daily.append(r)
 nonapp=[];segments=[]
 for label,g in group_frames(f.loc[f.has_d0_apply.eq(0)]):
  nonapp.append(summary(g,label,'当天未提单'))
  actions=g[['d0_'+x for x in ['amount','term','contract','plan','purpose','coupon','comparison']]].max(axis=1).gt(0)
  category=np.select([g.d0_records.eq(0),g.d0_entry.eq(0),~actions],
                     ['无获额后行为记录','有记录但缺少借款页进页记录','进页但无所列互动'],default='进页且有互动但未提单')
  for name in ['无获额后行为记录','有记录但缺少借款页进页记录','进页但无所列互动','进页且有互动但未提单']:
   n=int((category==name).sum());segments.append({'group':label,'segment':name,'events':n,'nonapp_events':len(g),'share':n/len(g)})
  assert sum(r['events'] for r in segments if r['group']==label)==len(g)
 adjusted=[];support=[]
 for control in ['其他T0合计','提额0至3000']:
  for name,strata in [('月份与借款经验可比',['month','loan_stage','hour_band']),
                      ('产品条件可比',['month','loan_stage','credit_band','rate_band'])]:
   rows,meta=standardized(f,control,strata,name=name);adjusted+=rows;support.append(meta)
 rows,meta=standardized(f.loc[f.has_d0_apply.eq(0)],'其他T0合计',name='仅当天未提单_产品条件可比');adjusted+=rows;support.append(meta)
 # One retained last T0 event per user, to check sensitivity to repeat events.
 last=f.sort_values(['offer_epoch','credit_serial_id']).groupby('user_id',sort=False).tail(1)
 user_sensitivity=[summary(g,n,'每用户最后一次T0') for n,g in group_frames(last)]
 rows,meta=standardized(last,'其他T0合计',minimum=(5,10),name='每用户最后一次T0_产品条件可比');adjusted+=rows;support.append(meta)
 # Timestamp-level pre-application view is shown separately from full D0.
 preapp=[]
 for label,g in group_frames(f):
  eligible=g.loc[g.preapp_exposure_hours>=1/60]
  r={'group':label,'events':len(g),'eligible_60sec_events':len(eligible),'mean_available_minutes':g.preapp_exposure_hours.mean()*60,
     'preapp_entry_rate_all':g.before_app_newpage.mean(),'d0_rate':g.has_d0_apply.mean()}
  for k in PAGES:
   r[k+'_rate_60sec']=eligible['before_app_'+k].mean()
  preapp.append(r)
 # Structural distributions that explain why raw group rates need adjustment.
 distributions=[]
 for field in ['loan_stage','credit_band','rate_band','hour_band']:
  for label,g in group_frames(f):
   for category,n in g[field].value_counts(dropna=False).items():
    distributions.append({'dimension':field,'group':label,'category':str(category),'events':int(n),'share':n/len(g)})
 # Daily before/after comparison with exposure denominators, not all records.
 phase=[]
 for label in GROUPS:
  for period,lo,hi in [('获额前7天',-7,-1),('获额当天',0,0),('获额后1至7天',1,7)]:
   z=pd.DataFrame([r for r in daily if r['group']==label and lo<=r['day']<=hi])
   n=z.exposed_events.sum()
   phase.append({'group':label,'phase':period,'exposed_event_days':int(n),
                 'active_rate':z.active_n.sum()/n if n else None,'entry_rate':z.newpage_n.sum()/n if n else None,
                 'amount_rate':z.amount_n.sum()/n if n else None,'plan_rate':z.plan_n.sum()/n if n else None})
 target=f.loc[f.group.eq('提额≥3000')];other=f.loc[f.group.ne('提额≥3000')]
 target_users=set(target.user_id);other_users=set(other.user_id)
 required_dates=pd.date_range('2026-05-25','2026-10-07').strftime('%Y-%m-%d')
 missing_dates=sorted(set(required_dates)-quality_dates)
 quality={'cohort_events':len(f),'cohort_users':f.user_id.nunique(),'target_events':len(target),'target_users':len(target_users),
          'other_events':len(other),'other_users':len(other_users),'users_in_both_event_groups':len(target_users&other_users),
          'reference_target_events_match':len(target)==12309,'reference_D0_match':target.has_d0_apply.sum()==3061,
          'D0_first_application_attribution_match':True,'all_event_keys_unique':f.event_id.is_unique,
          'raw_log_daily_rows':len(d),'invalid_duration_records_attributed':int(d.bad_duration_records.sum()),
          'date_mismatch_records_attributed':int(d.date_mismatch_records.sum()),
          'source_days_with_attributed_records':len(quality_dates),'missing_source_day_flags':missing_dates,
          'max_post_day':int(d.loc[d.relative_day>=0,'relative_day'].max()),
          'negative_page_duration_rows':int((d.page_seconds<0).sum()),
          'post_after_exclusive_stop_records':'excluded by SQL',
          'future_boundary_events':len(json.loads((W/'boundary.json').read_text())['rows'])}
 assert not missing_dates and quality['negative_page_duration_rows']==0
 result={'overall':overall,'monthly':monthly,'daily':daily,'nonapp':nonapp,'nonapp_segments':segments,
         'adjusted':adjusted,'common_support':support,'user_sensitivity':user_sensitivity,'preapp':preapp,
         'distributions':distributions,'phase':phase,'quality':quality,'labels':LABEL,'metric_labels':MLABEL,
         'source_snapshots':[s['snapshot'] for s in manifest['shards']]}
 # Replace NaN with explicit null for portable report/Excel inputs.
 serial=json.loads(pd.io.json.dumps(result,default_handler=enc)) if hasattr(pd.io.json,'dumps') else json.loads(json.dumps(result,default=enc))
 def clean(x):
  if isinstance(x,dict):return {k:clean(v) for k,v in x.items()}
  if isinstance(x,list):return [clean(v) for v in x]
  if isinstance(x,float) and not math.isfinite(x):return None
  return x
 serial=clean(serial);(W/'analysis.json').write_text(json.dumps(serial,ensure_ascii=False,indent=2))
 for name in ['overall','monthly','daily','nonapp','nonapp_segments','adjusted','common_support','user_sensitivity','phase']:
  pd.DataFrame(serial[name]).to_csv(W/(name+'.csv'),index=False,encoding='utf-8-sig')
 (W/'analysis_qa.json').write_text(json.dumps({'passed':True,**quality},ensure_ascii=False,indent=2,default=enc))
 print(json.dumps({'quality':quality,'overall':overall,'common_support':support},ensure_ascii=False,default=enc),flush=True)


if __name__=='__main__':analyze()
