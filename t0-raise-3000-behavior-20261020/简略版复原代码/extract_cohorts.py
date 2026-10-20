"""Read-only exact T0 cohort and October boundary events for behavior attribution."""
from pathlib import Path
from datetime import datetime,date
from decimal import Decimal
import json,sys,time,re
import psycopg2
W=Path(__file__).resolve().parent
OLD=Path('/Users/wangchuanliang/Documents/Codex/2026-09-21/ji-x')
from common import connection_kwargs


def enc(v):
 if isinstance(v,(datetime,date)):return v.isoformat()
 if isinstance(v,Decimal):return float(v)
 raise TypeError(type(v).__name__)


def query(start,end):
 src=(W/'reference_joint_query.sql').read_text()
 prefix=src.split('), cross_banded AS (',1)[0]+')\n'
 prefix=prefix.replace("DATE '2026-06-01' AS start_date",f"DATE '{start}' AS start_date").replace("DATE '2026-10-01' AS end_date",f"DATE '{end}' AS end_date")
 prefix=prefix.replace('FROM t0_base t WHERE credit_change_amt >= 3000','FROM t0_base t')
 # Exact existence semantics; no dependence on the number of side-table rows.
 prefix=prefix.replace('    JOIN wangchuanliang.side_recycle_type_copy r\n      ON r.serial_id = v.serial_id\n','')
 prefix=prefix.replace('      AND r.recycle_type = 3','      AND EXISTS (SELECT 1 FROM wangchuanliang.side_recycle_type_copy r WHERE r.serial_id=v.serial_id AND r.recycle_type=3)')
 return prefix+'SELECT * FROM classified ORDER BY user_id,vir_time,credit_serial_id;'


def run(name,start,end):
 sql=query(start,end);(W/(name+'_query.sql')).write_text("SET TIME ZONE 'America/Belize';\n"+sql)
 p=W/(name+'.json')
 if p.exists():return json.loads(p.read_text())
 t=time.monotonic()
 with psycopg2.connect(**dict(connection_kwargs(),connect_timeout=30,application_name='t0_behavior_'+name+'_readonly')) as c:
  c.set_session(readonly=True,isolation_level='REPEATABLE READ')
  with c.cursor() as q:
   for setting in ["SET TIME ZONE 'America/Belize'",'SET query_dop=1',"SET work_mem='64MB'",'SET enable_nestloop=off','SET statement_timeout=360000']:q.execute(setting)
   q.execute("SELECT CURRENT_TIMESTAMP,current_setting('transaction_read_only')");snapshot,ro=q.fetchone();assert ro=='on'
   q.execute(sql);keys=[x.name for x in q.description];rows=[dict(zip(keys,r)) for r in q.fetchall()]
  c.rollback()
 result={'complete':True,'read_only':True,'snapshot':snapshot,'rows':rows,'seconds':round(time.monotonic()-t,2)}
 p.write_text(json.dumps(result,ensure_ascii=False,default=enc))
 print(json.dumps({'phase':name,'rows':len(rows),'seconds':result['seconds']},ensure_ascii=False),flush=True)
 return json.loads(p.read_text())


def main():
 from concurrent.futures import ThreadPoolExecutor
 with ThreadPoolExecutor(max_workers=2) as pool:
  a=pool.submit(run,'cohort','2026-06-01','2026-10-01')
  b=pool.submit(run,'boundary','2026-10-01','2026-10-09')
  focus=a.result();future=b.result()
 rows=focus['rows'];target=[r for r in rows if r['credit_change_amt']>=3000]
 # Older file formats store these records in data or at the top level.
 summary={'complete':True,'focus_rows':len(rows),'focus_users':len({r['user_id'] for r in rows}),
          'target_rows':len(target),'target_users':len({r['user_id'] for r in target}),
          'target_d0':sum(r['has_d0_apply'] for r in target),'expected_target_rows':12309,'expected_target_d0':3061,
          'reference_counts_match':len(target)==12309 and sum(r['has_d0_apply'] for r in target)==3061,
          'boundary_rows':len(future['rows']),
          'current_offer_conflict':sum(r['current_offer_conflict'] for r in rows),
          'previous_order_conflict':sum(r['previous_order_conflict'] for r in rows),
          'duplicate_event_keys':len(rows)-len({(r['user_id'],r['credit_serial_id'],r['vir_time']) for r in rows})}
 assert summary['duplicate_event_keys']==summary['current_offer_conflict']==summary['previous_order_conflict']==0
 (W/'cohort_manifest.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2))
 print(json.dumps(summary,ensure_ascii=False),flush=True)


if __name__=='__main__':main()
