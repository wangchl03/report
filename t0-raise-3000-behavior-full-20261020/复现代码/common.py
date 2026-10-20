"""Portable read-only connection configuration and DWS JSON normalization."""
from pathlib import Path
import os,sys,json,re
vendor=Path(__file__).resolve().parent.parent/'intent_v2_behavior_windows_20261019/vendor'
if vendor.exists():sys.path.insert(0,str(vendor))
from pgpy import PGPMessage


def connection_kwargs():
 names=['DB_HOST','DB_NAME','DB_USER','DB_PASSWORD']
 if all(os.environ.get(k) for k in names):
  return dict(host=os.environ['DB_HOST'],port=int(os.environ.get('DB_PORT','8000')),
              dbname=os.environ['DB_NAME'],user=os.environ['DB_USER'],password=os.environ['DB_PASSWORD'])
 local=Path('/Users/wangchuanliang/Documents/Codex/2026-09-21/ji-x/work')
 if not local.exists():raise RuntimeError('Set DB_HOST, DB_PORT, DB_NAME, DB_USER and DB_PASSWORD for extraction. Offline analysis needs no database.')
 sys.path.insert(0,str(local))
 from analyze_t0_down_d1_d5_maturity_profit import connection_kwargs as existing
 return existing()


def parse_dws_json(text):
 pattern=r'("(?:[^"\\]|\\.)*")|(?P<lead>[:\[,]\s*)(?P<sign>-?)\.(?P<digit>\d)'
 def repair(m):
  if m.group(1) is not None:return m.group(0)
  return m.group('lead')+m.group('sign')+'0.'+m.group('digit')
 return json.loads(re.sub(pattern,repair,text))
