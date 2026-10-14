"""Execute the seven report SELECT modules in one read-only transaction.

Required connection settings use local PG environment variables. No credentials
are written to disk or echoed. The SQL's per-module dates preserve report scope.
Current source snapshots may change; use saved aggregate sources for exact replay.
"""
import argparse,getpass,json,os,re
from pathlib import Path
import psycopg2

def main():
  p=argparse.ArgumentParser();p.add_argument('--sql',required=True);p.add_argument('--output-dir',required=True);args=p.parse_args()
  out=Path(args.output_dir);out.mkdir(parents=True,exist_ok=True)
  sql=Path(args.sql).read_text()
  modules=re.findall(r'-- MODULE: (\w+)\n(.*?)\n-- END MODULE: \1',sql,re.S)
  assert [name for name,_ in modules]==['activity','funnel','lifecycle','duration','renewal','offers','finance']
  config={k:v for k,v in {'host':os.environ.get('PGHOST'),'port':os.environ.get('PGPORT','8000'),
    'dbname':os.environ.get('PGDATABASE'),'user':os.environ.get('PGUSER'),'password':os.environ.get('PGPASSWORD'),
    'connect_timeout':20,'application_name':'cycle_operating_report_reproduction_readonly'}.items() if v is not None}
  for key in ('host','dbname','user'):
    if not config.get(key):config[key]=input('Please enter database '+key+' (not saved): ').strip()
  if not config.get('password'):config['password']=getpass.getpass('Database password (hidden, not saved): ')
  sources={}
  with psycopg2.connect(**config) as c:
    c.set_session(readonly=True,autocommit=False,isolation_level='REPEATABLE READ')
    with c.cursor() as q:
      q.execute("SET TIME ZONE 'America/Belize'");q.execute('SET query_dop=1');q.execute("SET statement_timeout='20min'")
      q.execute("SELECT CURRENT_TIMESTAMP,current_setting('transaction_read_only')")
      snapshot,mode=q.fetchone();assert mode=='on'
      for name,query in modules:
        assert not re.search(r'\b(CREATE|DROP|INSERT|DELETE|UPDATE)\s+(TABLE|INTO|FROM|wangchuanliang)',query,re.I)
        q.execute(query);data={}
        for kind,raw in q.fetchall():
          data.setdefault(kind,[]).append(json.loads(re.sub(r'(:\s*)(-?)\.(?=\d)',r'\g<1>\g<2>0.',raw)))
        sources[name]=data
        (out/(name+'.json')).write_text(json.dumps(data,ensure_ascii=False,indent=2))
        print('Completed aggregate module: '+name)
    c.rollback()
  sources['metadata']={'updated_at':snapshot.isoformat(),'source_business_timezone':'America/Belize',
    'main_start_date':'2025-07-01','main_end_business_date':'2026-10-14',
    'bridge_start_date':'2026-01-01','bridge_end_date':'2026-10-13','currency':'MXN',
    'mature_due_max':sources['finance']['finance_audit'][0]['latest_mature_due_date'],
    'execution_snapshot':snapshot.isoformat(),
    'warning':'Source tables are current snapshots; this requery cannot recover old current loan-status values.'}
  (out/'requery-sources.json').write_text(json.dumps(sources,ensure_ascii=False,indent=2))
  print('Read-only query finished. Connection settings were not saved.')
if __name__=='__main__':
  try:main()
  except psycopg2.Error as e:
    print('Database error: '+(e.pgcode or type(e).__name__)+'. Connection details were not printed.')
    raise SystemExit(1)
