"""完整只读复现入口（不内置连接信息，不写数据库）。

1. 执行同目录完整.sql，导出第一个SELECT的kind,payload为cube.csv。
2. 导出第二个SELECT产品目录为catalog.csv（product_no,loan_term,days,daily_fee,total_fee）。
3. 本入口旁放置下载的分析代码，文件名改为analyze.py。
4. python reproduce.py --cube-csv cube.csv --catalog-csv catalog.csv --out reproduced
5. 生成cube.json/analysis.json/field-spec.json/fact-values.json等；报告所有指标均来自这些汇总。
   source.metadata.start_date/end_date/stat_date须与SQL params一致，当前默认已按交付口径设置。
   若需对账历史文件，可向analyze.run传入旧匿名cube和旧账期cube；不需要它们即可复现新指标。
所有交叉视图不可union回母体；率从可加分子分母重新计算。
"""
import argparse,csv,json,importlib.util
from pathlib import Path
def main():
    p=argparse.ArgumentParser();p.add_argument('--cube-csv',type=Path,required=True);p.add_argument('--catalog-csv',type=Path,required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args()
    rows=[];audit={}
    with a.cube_csv.open(encoding='utf-8-sig',newline='') as f:
      for row in csv.DictReader(f):
        payload=json.loads(row['payload'])
        if row['kind']=='cube':rows.append(payload)
        else:audit[payload['key']]=payload['n']
    with a.catalog_csv.open(encoding='utf-8-sig',newline='') as f:catalog=list(csv.DictReader(f))
    assert sum(r['n'] for r in rows)==audit['可分析T0']==audit['产品补齐后T0']
    for key in ('重复事件键','重复提单归属','D0财务字段冲突','D0财务未匹配','上一笔获额归属异常'):assert audit[key]==0,key
    metadata={'start_date':'2026-01-01','end_date':'2026-10-11','business_observation_date':'2026-10-13','snapshot':'2026-10-14T04:17:11.946492-06:00','currency':'MXN',
      'snapshot_note':'上述时间为本报告源快照；再次运行应替换为实际数据库快照，账面还款与状态会随时间刷新。','product_catalog_is_historical_quote':False}
    source={'rows':rows,'catalog':catalog,'audit':audit,'metadata':metadata}
    a.out.mkdir(parents=True,exist_ok=True);(a.out/'source.json').write_text(json.dumps(source,ensure_ascii=False))
    candidates=list(Path(__file__).parent.glob('*-analysis.py'))+[Path(__file__).with_name('analyze.py')]
    file=next(x for x in candidates if x.exists());spec=importlib.util.spec_from_file_location('product_analysis',file);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    result=module.run(source,a.out,None,None)
    print(json.dumps({'status':'PASS','overall':result['overall'],'coverage':result['coverage']},ensure_ascii=False))
if __name__=='__main__':main()
