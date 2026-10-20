"""Package exact event/day inputs and verify HTML, XLSX and offline replay."""
from pathlib import Path
from zipfile import ZipFile,ZIP_DEFLATED
from html.parser import HTMLParser
from urllib.parse import urlparse,unquote
from datetime import datetime
import json,hashlib,shutil,subprocess,os,re,math,xml.etree.ElementTree as ET
import importlib.metadata as md
from analyze import OUT
W=Path(__file__).resolve().parent
NS={'s':'http://schemas.openxmlformats.org/spreadsheetml/2006/main','c':'http://schemas.openxmlformats.org/drawingml/2006/chart','a':'http://schemas.openxmlformats.org/drawingml/2006/main'}


def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()


class Parser(HTMLParser):
 def __init__(self):super().__init__(convert_charrefs=True);self.ids=[];self.links=[];self.scripts=[];self.script=None;self.source=None;self.code=False;self.sources={}
 def handle_starttag(self,t,attrs):
  a=dict(attrs)
  if 'id'in a:self.ids.append(a['id'])
  if t=='a' and a.get('href'):self.links.append(a['href'])
  if t=='script':self.script={'attrs':a,'text':''}
  if t=='details'and'data-source'in a:self.source=a['data-source'];self.sources[self.source]=''
  if t=='code'and self.source:self.code=True
 def handle_data(self,x):
  if self.script is not None:self.script['text']+=x
  if self.source and self.code:self.sources[self.source]+=x
 def handle_endtag(self,t):
  if t=='script'and self.script is not None:self.scripts.append(self.script);self.script=None
  if t=='code':self.code=False
  if t=='details':self.source=None


def verify_xlsx():
 build=json.loads((W/'workbook_qa.json').read_text());assert build['passed'];file=Path(build['file']);expect=json.loads((W/'expected_cells.json').read_text())
 with ZipFile(file)as z:
  strings=[]
  if 'xl/sharedStrings.xml'in z.namelist():
   for si in ET.fromstring(z.read('xl/sharedStrings.xml')).findall('s:si',NS):strings.append(''.join(x.text or'' for x in si.findall('.//s:t',NS)))
  sheets=ET.fromstring(z.read('xl/workbook.xml')).findall('s:sheets/s:sheet',NS);cells={};formulas=0
  assert len(sheets)==5
  for i,s in enumerate(sheets,1):
   for c in ET.fromstring(z.read(f'xl/worksheets/sheet{i}.xml')).findall('.//s:sheetData/s:row/s:c',NS):
    assert c.attrib.get('t')!='e',c.attrib
    if c.find('s:f',NS)is not None:formulas+=1
    t=c.attrib.get('t');v=c.find('s:v',NS)
    if t=='s':got=strings[int(v.text)]
    elif t=='inlineStr':got=''.join(n.text or'' for n in c.findall('.//s:t',NS))
    elif t=='str':got=v.text if v is not None else''
    elif t=='d':got=(datetime.fromisoformat(v.text.replace('Z','+00:00')).replace(tzinfo=None)-datetime(1899,12,30)).total_seconds()/86400
    else:got=float(v.text)if v is not None and v.text else None
    cells[s.attrib['name']+'!'+c.attrib['r']]=got
  for key,want in expect.items():
   got=cells.get(key)
   if want is None:assert got in[None,''],(key,got)
   elif isinstance(want,(int,float)):assert got is not None and math.isclose(got,want,rel_tol=1e-11,abs_tol=1e-9),(key,got,want)
   else:assert got==want,(key,got,want)
  chart_names=[n for n in z.namelist()if'/charts/chart'in n and n.endswith('.xml')];assert len(chart_names)==1
  series=ET.fromstring(z.read(chart_names[0])).findall('.//c:ser',NS);assert len(series)==2
  colors=[]
  for s in series:
   assert s.find('c:val/c:numRef/c:f',NS)is not None
   rgb=s.find('c:spPr/a:ln/a:solidFill/a:srgbClr',NS);assert rgb is not None;colors.append(rgb.attrib['val'].upper())
  assert colors==['356F9D','B36D35']
 return {'verified_cells':len(expect),'formula_cells':formulas,'native_charts':1,'series_colors':colors}


def main():
 code=OUT/'复现代码';code.mkdir(exist_ok=True)
 for p in W.iterdir():
  if p.is_file()and p.suffix in{'.py','.sql','.mjs'}:shutil.copy2(p,code/p.name)
 inputs=['events.parquet','behavior_daily.parquet','boundary.json','behavior_manifest.json','cohort_manifest.json',
         'source_profile.json','log_semantics_profile.json','analysis.json','analysis_qa.json',
         'reference_monthly_qa.json','epoch_conversion_check.json','timestamp_smoke_check.json',
         'confirmation_and_coupon_audit.json','chart_label_manifest.json']
 for name in inputs:shutil.copy2(W/name,code/name)
 for p in W.glob('*.csv'):shutil.copy2(p,code/p.name)
 versions={}
 for name in ['numpy','pandas','pyarrow','matplotlib','scipy','psycopg2-binary','cryptography']:
  try:versions[name]=md.version(name)
  except md.PackageNotFoundError:pass
 (code/'requirements.txt').write_text('\n'.join(k+'=='+v for k,v in versions.items())+'\nPGPy==0.6.0\n')
 readme='''T0提额≥3000获额后行为特征对比

主要统计单位为获额事件，日期2026-06-01至2026-09-30。
20秒去重、同日结清续贷及提单归属沿用参考表。
本次新增事件记录时间级行为，获额前7天基线及D0—D7逐日观察。

冻结输入
events.parquet：获额事件及产品/历史借款特征；时间以offer_epoch、stop_epoch为准。
behavior_daily.parquet：原始日志按获额事件和相对自然日聚合的冻结输入，包含提单前标记。
boundary.json：十月边界T0事件，用于截断九月事件的后续归属。
提供的是可复算统计所需聚合快照，不是原始每条行为日志。

Python3.12，依赖版本见requirements.txt。
无需数据库的离线复算：在本目录运行 python analyze.py。
报告：python build_report.py。
可设置T0_BEHAVIOR_OUTPUT_DIR指定输出目录，默认沿用原工作区布局。
Excel：用已加载的@oai/artifact-tool运行build_workbook.mjs；其余复现不依赖Node。

重新提取（非离线复算必需）：
1. 安装requirements.txt，配置DB_HOST、DB_PORT、DB_NAME、DB_USER、DB_PASSWORD，只读账户。
2. python extract_cohorts.py
3. python extract_behavior.py
4. python analyze.py
源副本后补或覆盖后，重新提取结果可能变化。原缓存完整性和快照时间见清单。
没有在代码或数据包中保存数据库密码或令牌。

解释边界
D0是获额后的部分自然日。下一次有效T0之后不再归属当前事件，不能将退出分母解释为流失。
完整D0包含提单后动作，不能当作获额时点的预测输入。确认埋点不等于实际订单。
同一用户可贡献多个事件，标准化区间按用户聚类；共同支持外不能外推。
页面动作与提额关联不代表因果，计划/金额操作不能直接证明价格敏感。
'''
 (code/'README.txt').write_text(readme)
 # Validate delivered code against an independent copied bundle, so source
 # caches cannot leak into the offline replay and published files are untouched.
 replay=W/'offline_replay';replay.mkdir(exist_ok=True)
 for name in ['analyze.py','events.parquet','behavior_daily.parquet','boundary.json','behavior_manifest.json','reference_monthly_qa.json']:
  shutil.copy2(code/name,replay/name)
 env=dict(os.environ,T0_BEHAVIOR_OUTPUT_DIR=str(W/'offline_replay_output'))
 subprocess.run(['/opt/anaconda3/bin/python3',str(replay/'analyze.py')],env=env,check=True,stdout=subprocess.DEVNULL)
 assert json.loads((replay/'analysis.json').read_text())==json.loads((W/'analysis.json').read_text())
 hashes={str(p.relative_to(code)):sha(p)for p in code.rglob('*')if p.is_file()and p.name!='FILE_SHA256.json'}
 (code/'FILE_SHA256.json').write_text(json.dumps(hashes,ensure_ascii=False,indent=2))
 zipfile=OUT/'行为特征统计与分析_复现代码.zip'
 with ZipFile(zipfile,'w',ZIP_DEFLATED,compresslevel=3)as z:
  for p in code.rglob('*'):
   if p.is_file():z.write(p,'复现代码/'+str(p.relative_to(code)))
 with ZipFile(zipfile)as z:assert z.testzip()is None
 report=OUT/'T0提额3000及以上_获额后行为特征分析报告.html';text=report.read_text();parser=Parser();parser.feed(text)
 assert len(parser.ids)==len(set(parser.ids))
 for href in parser.links:
  if href.startswith('#'):assert href[1:]in parser.ids,href
  elif urlparse(href).scheme:raise AssertionError(('Unexpected external link',href))
  else:assert (OUT/unquote(href)).is_file(),href
 assert parser.sources.keys()=={p.name for p in code.iterdir()if p.suffix in{'.py','.sql'}}
 for name,source in parser.sources.items():assert source.encode()==(code/name).read_bytes(),name
 runtime=W/'report_runtime.js';runtime.write_text('\n'.join(s['text']for s in parser.scripts))
 subprocess.run(['/Users/wangchuanliang/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node','--check',str(runtime)],check=True)
 for identifier in re.findall(r"getElementById\('([^']+)'\)",runtime.read_text()):assert identifier in parser.ids,identifier
 xlsx=verify_xlsx()
 result={'passed':True,'offline_aggregation_replay':'PASS','delivered_code_hashes':len(hashes),
         'SQL_Python_appendix_files':len(parser.sources),'all_HTML_links':'PASS','HTML_SVG_unique_ids':len(parser.ids),
         'javascript_syntax':'PASS','xlsx':xlsx,'zip_bytes':zipfile.stat().st_size,
         'browser_preview':'Not performed: prior browser security policy blocks local-file protocol; no workaround used'}
 (W/'delivery_checks.json').write_text(json.dumps(result,ensure_ascii=False,indent=2));print(json.dumps(result,ensure_ascii=False),flush=True)


if __name__=='__main__':main()
