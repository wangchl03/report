"""Read-only timestamp-level page aggregation, aligned to exclusive T0 windows."""
from pathlib import Path
from datetime import datetime,date,timedelta,time as day_time
from zoneinfo import ZoneInfo
from concurrent.futures import ThreadPoolExecutor,as_completed
import json,sys,time,hashlib,base64,secrets
import numpy as np,pandas as pd,psycopg2
W=Path(__file__).resolve().parent
from common import parse_dws_json,PGPMessage,connection_kwargs
TZ=ZoneInfo('America/Belize')

PROPS={
 'newpage':"e.event_type='page_view_in' AND e.props_id IN ('Loan_newpage','Loan_newpage_select')",
 'amount':"e.props_id IN ('amount_modification','loan_form_loan_amount_selectionn_new','loan_form_loan_amount_selectionn_new_select')",
 'term':"e.props_id IN ('loan_form_term_selection_new','loan_form_term_selection_new_select')",
 'contract':"e.props_id IN ('Loan_contract_newdetails','Loan_contract_newdetails_select')",
 'plan':"e.props_id IN ('Loan_plan_newdetails','Loan_plan_newdetails_select')",
 'purpose':"e.props_id IN ('Loan_purpose_newdetails','Loan_purpose_newdetails_select')",
 'confirm':"e.props_id IN ('Loan_newconfirm','Loan_newconfirm_select')",
 'coupon':"e.props_id IN ('Order_coupons_back','Order_coupons_back_select','Order_coupons_confirm','Order_coupons_confirm_select','Order_coupons_page','Order_coupons_page_select')",
 'comparison':"e.props_id IN ('ProductComparison_page','ProductComparison_page_close','ProductComparison_page_confirm')",
}


def sql():
 text="""WITH arrays AS (
 SELECT %(ids)s::bigint[] ids,%(users)s::bigint[] users,
        %(offers)s::double precision[] offers,%(stops)s::double precision[] stops
), indices AS (SELECT generate_subscripts(ids,1) AS i FROM arrays), anchors AS (
 SELECT a.ids[n.i] event_id,a.users[n.i] user_id,a.offers[n.i] offer_epoch,a.stops[n.i] stop_epoch,
        TO_TIMESTAMP(a.offers[n.i]) AT TIME ZONE 'America/Belize' AS offer_time,
        TO_TIMESTAMP(a.stops[n.i]) AT TIME ZONE 'America/Belize' AS stop_time,
        (TO_TIMESTAMP(a.offers[n.i]) AT TIME ZONE 'America/Belize')::date AS offer_date
 FROM arrays a CROSS JOIN indices n
), first_app AS (
 SELECT a.event_id,MIN(o.apply_time) AS first_app_time
 FROM anchors a LEFT JOIN wangchuanliang.order_loan_f_v2_copy o
  ON o.user_id=a.user_id AND o.apply_time>=a.offer_time AND o.apply_time<a.stop_time
  AND o.user_id=ANY(%(users)s::bigint[])
  AND o.apply_date>=%(month_start)s AND o.apply_date<%(month_end_plus8)s
 GROUP BY a.event_id
), attributed AS (
 SELECT a.event_id,a.user_id,a.offer_epoch,a.stop_epoch,a.offer_date,a.offer_time,a.stop_time,
        p.first_app_time,e.event_type,e.props_id,e.create_time,e.create_date,
        e.event_start_time,e.event_end_time,e.user_id AS log_user,
        COALESCE(e.create_time::date-a.offer_date,-99) AS relative_day,
        CASE WHEN p.first_app_time IS NULL OR e.create_time<p.first_app_time THEN 1 ELSE 0 END AS before_app,
        CASE WHEN e.event_type='page_view_out' AND e.event_start_time>=1000000000000
                       AND e.event_end_time>=e.event_start_time
                       AND e.event_end_time-e.event_start_time<=86400000
             THEN GREATEST(0.0,
                    LEAST(e.event_end_time/1000.0,
                      EXTRACT(EPOCH FROM ((e.create_time::date+1)::timestamp AT TIME ZONE 'America/Belize')),
                      CASE WHEN e.create_time>=a.offer_time THEN a.stop_epoch ELSE a.offer_epoch END)
                    -GREATEST(e.event_start_time/1000.0,
                      EXTRACT(EPOCH FROM (e.create_time::date::timestamp AT TIME ZONE 'America/Belize')),
                      CASE WHEN e.create_time>=a.offer_time THEN a.offer_epoch ELSE a.offer_epoch-86400*8 END))
             ELSE 0.0 END AS page_seconds,
        CASE WHEN e.event_type='page_view_out' AND (e.event_start_time IS NULL OR e.event_end_time IS NULL
                  OR e.event_start_time<1000000000000 OR e.event_end_time<e.event_start_time
                  OR e.event_end_time-e.event_start_time>86400000) THEN 1 ELSE 0 END AS bad_duration
 FROM anchors a LEFT JOIN first_app p ON p.event_id=a.event_id
 LEFT JOIN wangchuanliang.event_track_record e
   ON e.user_id=a.user_id
  AND e.user_id=ANY(%(users)s::bigint[])
  AND e.create_date>=%(log_start)s AND e.create_date<%(log_end)s
  AND e.create_time>=a.offer_date-7 AND e.create_time<a.stop_time
  AND (e.create_time<a.offer_date OR e.create_time>=a.offer_time)
)
SELECT e.event_id,e.relative_day,
       EXTRACT(EPOCH FROM e.first_app_time AT TIME ZONE 'America/Belize')::double precision AS first_app_epoch,
       COUNT(e.log_user)::bigint AS records,
       SUM(CASE WHEN e.log_user IS NOT NULL AND e.before_app=1 THEN 1 ELSE 0 END)::bigint AS pre_records,
       SUM(e.page_seconds)::double precision AS page_seconds,
       SUM(CASE WHEN e.before_app=1 THEN e.page_seconds ELSE 0 END)::double precision AS pre_page_seconds,
       SUM(CASE WHEN e.props_id IN ('Loan_newpage','Loan_newpage_select') THEN e.page_seconds ELSE 0 END)::double precision AS loan_page_seconds,
       SUM(CASE WHEN e.before_app=1 AND e.props_id IN ('Loan_newpage','Loan_newpage_select') THEN e.page_seconds ELSE 0 END)::double precision AS pre_loan_page_seconds,
       SUM(e.bad_duration)::bigint AS bad_duration_records,
       SUM(CASE WHEN e.log_user IS NOT NULL AND e.create_time::date<>e.create_date THEN 1 ELSE 0 END)::bigint AS date_mismatch_records,
       MIN(CASE WHEN e.event_type='page_view_in' AND e.props_id IN ('Loan_newpage','Loan_newpage_select')
                THEN EXTRACT(EPOCH FROM e.create_time AT TIME ZONE 'America/Belize') END)::double precision AS first_page_epoch,
"""
 counts=[]
 for name,predicate in PROPS.items():
  counts.append(f"       SUM(CASE WHEN {predicate} THEN 1 ELSE 0 END)::bigint AS {name}")
  counts.append(f"       SUM(CASE WHEN ({predicate}) AND e.before_app=1 THEN 1 ELSE 0 END)::bigint AS pre_{name}")
 return text+',\n'.join(counts)+"\nFROM attributed e GROUP BY e.event_id,e.relative_day,e.first_app_time ORDER BY e.event_id,e.relative_day"


def prepare():
 focus=json.loads((W/'cohort.json').read_text());future=json.loads((W/'boundary.json').read_text())
 f=pd.DataFrame(focus['rows']);f['focus']=True
 b=pd.DataFrame(future['rows']);b['focus']=False
 all_=pd.concat([f,b],ignore_index=True).drop_duplicates(['user_id','credit_serial_id','vir_time'])
 all_['offer_time']=pd.to_datetime(all_.vir_time,utc=True).dt.tz_convert(TZ)
 all_=all_.sort_values(['user_id','offer_time','credit_serial_id']).reset_index(drop=True)
 all_['next_offer_time']=all_.groupby('user_id').offer_time.shift(-1)
 all_['offer_day']=all_.offer_time.dt.normalize()
 all_['natural_stop']=all_.offer_day+pd.Timedelta(days=8)
 all_['stop_time']=all_[['next_offer_time','natural_stop']].min(axis=1)
 f=all_.loc[all_.focus].copy().reset_index(drop=True)
 f['event_id']=np.arange(len(f),dtype='int64')
 # Parsed timestamps can have microsecond resolution. Timestamp.timestamp()
 # returns epoch seconds independently of their internal pandas unit.
 f['offer_epoch']=f.offer_time.map(lambda t:t.timestamp())
 f['stop_epoch']=f.stop_time.map(lambda t:t.timestamp())
 f['group']=np.select([f.credit_change_amt>=3000,f.credit_change_amt>0,f.credit_change_amt.eq(0)],['提额≥3000','提额0至3000','额度不变'],default='额度降低')
 f['month']=f.offer_time.dt.strftime('%Y-%m')
 f['loan_stage']=np.select([f.successful_loan_n<=1,f.successful_loan_n<=3,f.successful_loan_n<=5],['1次','2至3次','4至5次'],default='6次及以上')
 f['credit_band']=pd.cut(f.current_credit_amt,[0,5000,7000,10000,15000,float('inf')],labels=['≤5000','5000至7000','7000至10000','10000至15000','>15000']).astype(str)
 f['rate_band']=pd.cut(f.current_daily,[-.001,.015,.02,.025,float('inf')],labels=['≤1.5%','1.5%至2%','2%至2.5%','>2.5%']).astype(str)
 assert f.event_id.is_unique and (f.stop_time>f.offer_time).all()
 assert (f.offer_time.dt.date.astype(str)==f.vir_date.str[:10]).all()
 assert f.offer_epoch.between(1700000000,1900000000).all()
 assert (f.stop_epoch>f.offer_epoch).all() and ((f.stop_epoch-f.offer_epoch)<=86400*8).all()
 assert (pd.to_datetime(f.offer_epoch,unit='s',utc=True).dt.tz_convert(TZ).dt.strftime('%Y-%m-%d')==f.vir_date.str[:10]).all()
 stored=f.copy()
 for col in stored.select_dtypes(include='datetimetz').columns:
  stored[col]=stored[col].dt.tz_convert('UTC').dt.tz_localize(None)
 stored.to_parquet(W/'events.parquet',index=False)
 return f


def run(f,month,shard):
 name=f'{month}_{shard}';part=W/'behavior_parts';part.mkdir(exist_ok=True)
 p=part/(name+'.parquet');m=part/(name+'.json')
 sample=f.loc[f.month.eq(month)&(f.user_id%2).eq(shard)]
 params={k:sample[c].tolist() for k,c in [('ids','event_id'),('users','user_id'),('offers','offer_epoch'),('stops','stop_epoch')]}
 start=date.fromisoformat(month+'-01');end=(start.replace(day=28)+timedelta(days=4)).replace(day=1)
 params.update(month_start=start,month_end_plus8=end+timedelta(days=8),log_start=start-timedelta(days=8),log_end=end+timedelta(days=9))
 request=hashlib.sha256((sql()+json.dumps(params,sort_keys=True,default=str)).encode()).hexdigest()
 if p.exists() and m.exists():
  info=json.loads(m.read_text())
  if info.get('complete') and info['request_sha256']==request and info['sha256']==hashlib.sha256(p.read_bytes()).hexdigest():
   return p,info
 t=time.monotonic();key=secrets.token_urlsafe(32);params['key']=key
 packed="SELECT COUNT(*),encode(pgp_sym_encrypt(string_agg(row_to_json(q)::text,E'\\n'),%(key)s,'compress-algo=1,compress-level=6,cipher-algo=aes256'),'base64') FROM ("+sql()+") q"
 with psycopg2.connect(**dict(connection_kwargs(),connect_timeout=35,application_name='t0_behavior_'+name+'_readonly')) as c:
  c.set_session(readonly=True,isolation_level='REPEATABLE READ')
  with c.cursor() as q:
   for setting in ["SET TIME ZONE 'America/Belize'",'SET query_dop=1',"SET work_mem='64MB'",'SET enable_nestloop=off','SET statement_timeout=480000']:q.execute(setting)
   q.execute("SELECT CURRENT_TIMESTAMP,current_setting('transaction_read_only')");snapshot,ro=q.fetchone();assert ro=='on'
   q.execute(packed,params);n,blob=q.fetchone()
  c.rollback()
 raw=PGPMessage.from_blob(base64.b64decode(blob)).decrypt(key).message
 if isinstance(raw,(bytes,bytearray)):raw=bytes(raw).decode()
 records=[parse_dws_json(x) for x in str(raw).splitlines()]
 result=pd.DataFrame(records);assert len(result)==n and set(result.event_id)==set(sample.event_id)
 assert not result.duplicated(['event_id','relative_day']).any()
 found=result.groupby('event_id').first_app_epoch.first()
 actual=sample.event_id.map(found)
 ends=sample.offer_day.map(lambda t:t.timestamp())+86400
 assert np.array_equal((actual.notna()&(actual.to_numpy()<ends.to_numpy())).astype(int).to_numpy(),sample.has_d0_apply.to_numpy()), 'Part D0 attribution disagrees with known orders'
 assert result.records.sum()>0, 'Unexpected entirely empty historical log window'
 result.to_parquet(p,index=False)
 info={'complete':True,'month':month,'shard':shard,'rows':len(result),'events':len(sample),'read_only':True,
       'snapshot':snapshot.isoformat(),'request_sha256':request,'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'seconds':round(time.monotonic()-t,2),'known_D0_labels_verified':True}
 m.write_text(json.dumps(info,ensure_ascii=False,indent=2));print(json.dumps(info,ensure_ascii=False),flush=True)
 return p,info


def main():
 f=prepare();(W/'behavior_query.sql').write_text("-- Read-only parameterized aggregation. Parameters are the saved event arrays.\n"+sql()+';')
 results=[]
 with ThreadPoolExecutor(max_workers=2) as pool:
  tasks=[pool.submit(run,f,month,shard) for month in ['2026-06','2026-07','2026-08','2026-09'] for shard in [0,1]]
  try:
   for task in as_completed(tasks):results.append(task.result())
  except BaseException:
   for task in tasks:task.cancel()
   raise
 frames=[pd.read_parquet(p) for p,_ in results];daily=pd.concat(frames,ignore_index=True)
 assert set(daily.event_id)==set(f.event_id) and not daily.duplicated(['event_id','relative_day']).any()
 daily.to_parquet(W/'behavior_daily.parquet',index=False)
 manifest={'complete':True,'events':len(f),'daily_rows':len(daily),'shards':sorted([m for _,m in results],key=lambda x:(x['month'],x['shard'])),
           'snapshot_limits':'per-shard read-only snapshots; mutable source copies; no immutable ingested_at',
           'sha256':hashlib.sha256((W/'behavior_daily.parquet').read_bytes()).hexdigest(),
           'props':PROPS}
 (W/'behavior_manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2))
 print(json.dumps({'complete':True,'events':len(f),'daily_rows':len(daily)},ensure_ascii=False),flush=True)


if __name__=='__main__':main()
