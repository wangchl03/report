"""Rebuild the concise T0 behavior report from frozen aggregate statistics.

Run: python build_brief_report.py --output-dir /path/to/report_folder
No database access, training, or label/metric recalculation is performed.
"""
from pathlib import Path
from collections import Counter
import argparse,hashlib,html,io,json,re,shutil,zipfile
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib import font_manager
from report_support import configure_dark_plots,finish_report

W=Path(__file__).resolve().parent
DEFAULT_OUT=Path('/Users/wangchuanliang/Documents/Codex/2026-10-18/wen/outputs/T0提额3000及以上_获额后行为特征对比_20260601-20260930_20261020')
FILE='T0提额3000及以上_获额后行为特征分析报告_简略版.html'
COLORS=['#43c7e7','#ffc26b']
SOURCE_NAMES=['build_brief_report.py','report_support.py','common.py','extract_cohorts.py',
              'extract_behavior.py','analyze.py','cohort_query.sql','boundary_query.sql',
              'behavior_query.sql','reference_joint_query.sql']
esc=lambda x:html.escape(str(x))
pct=lambda x:f'{x:.2%}'
num=lambda x:f'{int(x):,}'
pp=lambda x:f'{x*100:+.2f}个百分点'


def table(headers,rows):
    return '<div class="scroll"><table><thead><tr>'+''.join('<th>'+esc(x)+'</th>' for x in headers)+'</tr></thead><tbody>'+''.join('<tr>'+''.join('<td>'+esc(x)+'</td>' for x in r)+'</tr>' for r in rows)+'</tbody></table></div>'


def fold(title,body):
    return '<details class="data-details"><summary>'+esc(title)+'</summary>'+body+'</details>'


def mark(text):
    text.set_gid('metric-data-label')
    return text


def point_labels(ax,xs,ys,color,dy):
    for x,y in zip(xs,ys):
        mark(ax.annotate(f'{y:.2f}%',(x,y),xytext=(0,dy),textcoords='offset points',
                        ha='center',va='bottom' if dy>=0 else 'top',color=color,fontsize=9,
                        bbox={'boxstyle':'round,pad=.12','fc':'#082235','ec':'none','alpha':.92}))


def figure(fig,name,out,audit):
    assets=out/'简略版图表';assets.mkdir(exist_ok=True)
    labels=[x for x in fig.findobj() if hasattr(x,'get_gid') and x.get_gid()=='metric-data-label']
    audit[name]={'count':len(labels),'labels':[x.get_text() for x in labels]}
    for i,x in enumerate(labels,1):x.set_gid(f'data-label-{i:03d}')
    fig.tight_layout()
    fig.savefig(assets/(name+'.png'),dpi=150,bbox_inches='tight')
    buf=io.StringIO();fig.savefig(buf,format='svg',bbox_inches='tight');plt.close(fig)
    svg=buf.getvalue();svg=svg[svg.index('<svg'):]
    (assets/(name+'.svg')).write_text(svg,encoding='utf-8')
    prefix='brief'+hashlib.sha256(name.encode()).hexdigest()[:8]+'_'
    for old in sorted(set(re.findall(r'id="([^"]+)"',svg)),key=len,reverse=True):
        svg=svg.replace('id="'+old+'"','id="'+prefix+old+'"').replace('href="#'+old+'"','href="#'+prefix+old+'"').replace('url(#'+old+')','url(#'+prefix+old+')')
    return '<div class="figure">'+svg+'</div>'


def build_charts(data,out):
    rows={r['group']:r for r in data['overall']};t,c=rows['提额≥3000'],rows['其他T0合计']
    audit={};charts={}
    font_path=Path('/System/Library/Fonts/Supplemental/Arial Unicode.ttf')
    if font_path.exists():font_manager.fontManager.addfont(str(font_path));plt.rcParams['font.family']='Arial Unicode MS'
    configure_dark_plots(plt)
    plt.rcParams.update({'axes.spines.top':False,'axes.spines.right':False,'svg.fonttype':'none',
                         'font.size':10,'axes.grid':True,'grid.alpha':.18})
    keys=['d0_active','d0_entry','d0_amount','d0_plan','has_d0_apply']
    labels=['获额后重新活跃','进入提单页','金额选择/修改','还款计划详情','当天实际提单']
    fig,ax=plt.subplots(figsize=(12.2,4.6));x=np.arange(len(keys))
    for row,offset,color,label in [(t,-.18,COLORS[0],'提额≥3000'),(c,.18,COLORS[1],'其他T0')]:
        bars=ax.bar(x+offset,[row[k]*100 for k in keys],.36,color=color,label=label)
        for text in ax.bar_label(bars,labels=[pct(row[k]) for k in keys],padding=5,color=color,fontsize=10):mark(text)
    ax.set_xticks(x,labels);ax.set(ylim=(0,108),ylabel='发生事件数 ÷ 该组全部获额事件数（%）',title='获额后当天行为及实际提单')
    ax.legend(frameon=False,loc='upper right');charts['overall']=figure(fig,'当天行为与提单对比',out,audit)

    months=sorted({r['period'] for r in data['monthly']});fig,ax=plt.subplots(figsize=(12.2,4.1));x=np.arange(len(months))
    for group,color,dy in [('提额≥3000',COLORS[0],-16),('其他T0合计',COLORS[1],10)]:
        z={r['period']:r for r in data['monthly'] if r['group']==group};ys=[z[m]['has_d0_apply']*100 for m in months]
        ax.plot(x,ys,marker='o',lw=2.2,color=color,label=group);point_labels(ax,x,ys,color,dy)
    ax.set_xticks(x,months);ax.set(ylim=(15,51),ylabel='当天实际提单率（%）',title='获额月份与当天实际提单率')
    ax.legend(frameon=False,loc='upper right');charts['monthly']=figure(fig,'月度当天提单率对比',out,audit)

    segs=[r['segment'] for r in data['nonapp_segments'] if r['group']=='提额≥3000']
    labels=['无行为记录','有记录但无进页记录','进页无所列互动','进页且互动未提单']
    palette=['#6f8b9f','#43c7e7','#64dcae','#ffc26b'];fig,ax=plt.subplots(figsize=(12.2,4.4));left=np.zeros(2)
    for category,label,color in zip(segs,labels,palette):
        z=[next(r for r in data['nonapp_segments'] if r['group']==g and r['segment']==category) for g in ['提额≥3000','其他T0合计']]
        vals=[r['share']*100 for r in z];ax.barh([0,1],vals,left=left,color=color,label=label)
        for i,(r,value) in enumerate(zip(z,vals)):
            mark(ax.text(left[i]+value/2,i,f'{num(r["events"])}次\n{value:.2f}%',ha='center',va='center',color='#062333',fontsize=10))
        left+=vals
    ax.set_yticks([0,1],[f'提额≥3000\n未提单N={num(t["events"]-t["d0_n"])}',f'其他T0\n未提单N={num(c["events"]-c["d0_n"])}'])
    ax.invert_yaxis();ax.set(xlim=(0,100),xlabel='本组当天未提单事件中的占比（%）',title='当天未提单事件的行为分布')
    ax.legend(frameon=False,loc='upper center',bbox_to_anchor=(.5,-.20),ncol=2);charts['nonapp']=figure(fig,'未提单事件行为分布',out,audit)

    fig,ax=plt.subplots(figsize=(13,4.9))
    for group,color,dy in [('提额≥3000',COLORS[0],10),('其他T0合计',COLORS[1],-14)]:
        z=sorted([r for r in data['daily'] if r['group']==group],key=lambda r:r['day'])
        xs=[r['day'] for r in z];ys=[r['newpage_rate']*100 for r in z]
        ax.plot(xs,ys,marker='o',ms=4,color=color,label=group);point_labels(ax,xs,ys,color,dy)
    ax.axvline(0,color='#9bb5c7',ls='--',lw=1)
    ax.set_xticks(range(-7,8),['D'+str(i) for i in range(-7,8)])
    ax.set(ylim=(-4,108),xlabel='相对获额自然日（后续遇下一次T0截断）',ylabel='当日进页事件数 ÷ 当日可观察事件数（%）',title='有效观察事件日中的借款页进页率')
    ax.margins(x=.04);ax.legend(frameon=False,loc='upper left');charts['daily']=figure(fig,'获额前后借款页进页率',out,audit)
    return charts,audit


CSS='''
*{box-sizing:border-box}body{margin:0;font:16px/1.8 -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif}
main{max-width:1270px;margin:auto;padding:34px 24px 60px}h1{font-size:32px;line-height:1.4;margin:10px 0 14px;text-align:center}
h2{font-size:23px;line-height:1.5;margin:0 0 14px}h3{font-size:18px;margin:20px 0 12px}p{margin:10px 0}
section{padding:26px;margin:22px 0;border-radius:12px;scroll-margin-top:20px}nav{display:flex;justify-content:center;text-align:center;gap:18px;flex-wrap:wrap;margin:20px 0;font-size:14px}
a{text-decoration:none}.eyebrow,.note,.chart-note{font-size:14px;color:var(--muted)}.conclusion{padding:12px 16px;border-left:3px solid var(--cyan);background:#123146;margin:14px 0}
.cards{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:14px;margin:22px 0}.card{padding:17px;border:1px solid var(--line);border-top:3px solid var(--cyan);border-radius:8px}
.card h3{font-size:15px;min-height:0;line-height:1.45;margin:0 0 3px;color:var(--ink)}.card-line{display:flex;justify-content:space-between;align-items:baseline;gap:8px}.card-line span{font-size:12px;color:var(--muted)}
.card-line b{font-size:27px;font-weight:650;line-height:1.65;font-variant-numeric:tabular-nums}.target b{color:var(--cyan)}.control b{color:var(--amber)}.card small{display:block;font-size:12px;margin-top:9px}.card small .delta-negative{color:#ff7a83}.card small .delta-positive{color:#64dcae}.card small .delta-zero{color:var(--muted)}
.figure{margin:12px 0}.figure svg{display:block;width:100%;height:auto}.scroll{overflow:auto}table{width:100%;border-collapse:collapse;font-size:13px;margin:14px 0;font-variant-numeric:tabular-nums}
th,td{padding:10px 12px;border-bottom:1px solid var(--line);text-align:right;vertical-align:top}th{white-space:nowrap}th:first-child,td:first-child{text-align:left}
.data-details{border-top:1px solid var(--line);padding:14px 0;margin-top:12px}.data-details summary{cursor:pointer;font-weight:500}.downloads{display:flex;flex-wrap:wrap;gap:14px;margin:15px 0}.downloads a{padding:8px 12px;border:1px solid var(--line);border-radius:6px;font-size:14px}
#code-appendix{padding:18px 24px}#code-appendix h2{font-size:20px;margin-bottom:8px}.appendix-details{padding:0;border:0;margin:0}.appendix-details>summary{font-size:14px;cursor:pointer;font-weight:500}
pre{overflow:auto;padding:18px}code{font:12px ui-monospace,Menlo,monospace}.source-count,.source-meta{font-size:12px}
@media(max-width:1050px){.cards{grid-template-columns:repeat(2,minmax(0,1fr))}.card h3{min-height:0}}
@media(max-width:650px){main{padding:20px 12px}section{padding:20px 15px}h1{font-size:26px}.cards{grid-template-columns:1fr}.card h3{min-height:0}.card-line b{font-size:29px}}
@media print{nav,.source-controls{display:none}main{padding:0}section{break-inside:auto}.cards{grid-template-columns:repeat(2,1fr)}h2,h3{break-after:avoid}.conclusion{color:#172f40;background:#edf3f6}.figure{break-inside:avoid}table{font-size:10px}}
'''


def delta_label(value):
    css='delta-negative' if value<0 else 'delta-positive' if value>0 else 'delta-zero'
    return '<small>目标减对照：<span class="'+css+'">'+pp(value)+'</span></small>'


def build_document(data,charts):
    rows={r['group']:r for r in data['overall']};t,c=rows['提额≥3000'],rows['其他T0合计']
    n0,n1=t['events']-t['d0_n'],c['events']-c['d0_n'];later=t['d7_n']-t['d0_n'];other_later=c['d7_n']-c['d0_n']
    selected=[('has_d0_apply','当天提单率'),('d7_rate','D0—D7累计首次提单率'),('d0_amount','金额选择/修改发生率'),('d0_plan','还款计划详情发生率')]
    cards=''.join('<div class="card" data-metric="'+key+'"><h3>'+label+'</h3><div class="card-line target"><span>提额≥3000</span><b>'+pct(t[key])+'</b></div><div class="card-line control"><span>其他T0</span><b>'+pct(c[key])+'</b></div>'+delta_label(t[key]-c[key])+'</div>' for key,label in selected)
    out=['<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>T0提额≥3000用户行为分析</title><style>'+CSS+'</style></head><body><main>']
    out+=['<h1>T0提额≥3000用户行为分析</h1><nav>'+''.join('<a href="#'+key+'">'+title+'</a>' for key,title in [('core','核心判断'),('overall','总体与月度'),('nonapp','未提单特征'),('delayed','后续提单'),('daily','逐日进页率')])+'</nav>']
    out+=[f'<section id="core"><h2>核心判断：页面互动更多，实际提单率较低</h2><p>提额≥3000事件更常出现选择金额、查看还款计划的记录，但当天及D0—D7累计首次提单率均低于其他T0。</p><div class="cards">{cards}</div><p class="note">分母为各组全部获额事件：目标{num(t["events"])}次，其他T0 {num(c["events"])}次；同一用户可贡献多次事件。页面发生率按“至少1条对应日志”计数，完整D0包含提单后行为，以上为关联描述。</p></section>']

    general=table(['事件分组','事件数','去重用户数','当天提单数','当天提单率','D0—D7累计首次提单率','金额选择/修改发生率','还款计划详情发生率'],[[r['group'],num(r['events']),num(r['users']),num(r['d0_n']),pct(r['has_d0_apply']),pct(r['d7_rate']),pct(r['d0_amount']),pct(r['d0_plan'])] for r in data['overall']])
    monthly=table(['获额月份','事件分组','事件数','当天提单数','当天提单率','获额后重新活跃率','进页率','金额选择/修改发生率','还款计划详情发生率'],[[r['period'],r['group'],num(r['events']),num(r['d0_n']),pct(r['has_d0_apply']),pct(r['d0_active']),pct(r['d0_entry']),pct(r['d0_amount']),pct(r['d0_plan'])] for r in data['monthly']])
    mt=sorted([r for r in data['monthly'] if r['group']=='提额≥3000'],key=lambda r:r['period']);mc={r['period']:r for r in data['monthly'] if r['group']=='其他T0合计'}
    a,z=mt[0],mt[-1];gap0=mc[a['period']]['has_d0_apply']-a['has_d0_apply'];gap1=mc[z['period']]['has_d0_apply']-z['has_d0_apply']
    out+=['<section id="overall"><h2>总体与月度差异</h2>'+charts['overall']+'<p class="chart-note" id="settlement-day-note">本图以用户结清当日、结清后这笔重新获额通过订单为锚点，统计用户从该次获额通过时刻起至当天结束的行为及实际提单。</p>'+fold('展开总体对比数据与口径',general+'<p class="note">获额后重新活跃：窗口内event_track_record至少1条日志，不限类型；进页：至少1条Loan_newpage/Loan_newpage_select的page_view_in日志。金额和还款计划按对应props_id映射，不要求发生在首次提单之前。每事件同类多条记录仍只计1次。</p>')+charts['monthly']+f'<p class="conclusion">目标组当天提单率由6月的{pct(a["has_d0_apply"])}降至9月的{pct(z["has_d0_apply"])}；与其他T0的差距由{gap0*100:.2f}扩大至{gap1*100:.2f}个百分点。</p><p class="chart-note">月度按获额月份分组；分子为当月获额后当天实际提单的事件数，分母为当月全部获额事件数。</p>'+fold('展开月度明细数据',monthly)+'</section>']

    segs=[r for r in data['nonapp_segments'] if r['group']=='提额≥3000'];other={r['segment']:r for r in data['nonapp_segments'] if r['group']=='其他T0合计'}
    seg_table=table(['互斥分类','目标事件数','目标占比','其他T0事件数','其他T0占比'],[[r['segment'],num(r['events']),pct(r['share']),num(other[r['segment']]['events']),pct(other[r['segment']]['share'])] for r in segs])
    nonapp_table=table(['事件分组','当天未提单数','获额后重新活跃率','借款页进页率','金额选择/修改发生率','还款计划详情发生率','期次选择发生率'],[[r['group'],num(r['events']),pct(r['d0_active']),pct(r['d0_entry']),pct(r['d0_amount']),pct(r['d0_plan']),pct(r['d0_term'])] for r in data['nonapp']])
    noentry=segs[0]['share']+segs[1]['share']
    out+=['<section id="nonapp"><h2>未提单事件的行为特征</h2>'+charts['nonapp']+f'<p class="conclusion">提额3000以上组当天未提单{num(n0)}次，页面互动更多；其中{pct(segs[-1]["share"])}已进页且有互动，{pct(noentry)}无进页记录。</p><p class="chart-note">每段同时标注事件数与占比；分母仅为本组D0未提单事件，目标{num(n0)}次、其他T0 {num(n1)}次。四类互斥，原值合计100%；标签因四舍五入可能略有差异。</p>'+fold('展开未提单分类、分组数据及口径',seg_table+nonapp_table+'<p class="note">“进页无所列互动”：D0未提单、有借款页进页记录，但金额、期次、合同、还款计划、用途、优惠券、产品比较7类均无对应日志。“确认相关”未计入这7类，确认埋点也不等同实际订单。无记录不能完全排除漏报；优惠券旧映射本次无匹配记录。</p>')+'</section>']

    delay_rows=[['当天实际提单',f'{num(t["d0_n"])} / {pct(t["has_d0_apply"])}',f'{num(c["d0_n"])} / {pct(c["has_d0_apply"])}'],['D1—D7新增首次提单（占全部获额事件）',f'{num(later)} / {pct(later/t["events"])}',f'{num(other_later)} / {pct(other_later/c["events"])}'],['D0—D7累计首次提单',f'{num(t["d7_n"])} / {pct(t["d7_rate"])}',f'{num(c["d7_n"])} / {pct(c["d7_rate"])}'],['D0未提单中，D1—D7后来提单的比例',pct(later/n0),pct(other_later/n1)]]
    out+=['<section id="delayed"><h2>后续是否延迟提单</h2>'+table(['指标','提额≥3000','其他T0'],delay_rows)+f'<p class="conclusion">有延迟提单，但累计到D7仍低{(c["d7_rate"]-t["d7_rate"])*100:.2f}个百分点，差异不能仅由提单较晚解释。</p><p class="chart-note">D0从获额时刻开始，D1—D7是之后7个自然日；遇下一次有效T0获额即截断。提单按用户实际提交订单识别，可为其他订单号，不要求放款成功。</p></section>']

    daily={g:{r['day']:r for r in data['daily'] if r['group']==g} for g in ['提额≥3000','其他T0合计']}
    daily_rows=[]
    for day in range(-7,8):
        v,u=daily['提额≥3000'][day],daily['其他T0合计'][day]
        daily_rows.append(['D'+str(day),num(v['exposed_events']),num(v['newpage_n']),pct(v['newpage_rate']),num(u['exposed_events']),num(u['newpage_n']),pct(u['newpage_rate'])])
    assert all(daily['提额≥3000'][day]['newpage_rate']>daily['其他T0合计'][day]['newpage_rate'] for day in range(1,8))
    assert all(daily['提额≥3000'][day]['newpage_rate']>daily['其他T0合计'][day]['newpage_rate'] for day in range(-7,0))
    assert daily['提额≥3000'][0]['newpage_rate']<daily['其他T0合计'][0]['newpage_rate']
    daily_table=table(['相对日','目标可观察事件数','目标进页事件数','目标进页率','其他可观察事件数','其他进页事件数','其他进页率'],daily_rows)
    out+=['<section id="daily"><h2>获额前后逐日变化</h2>'+charts['daily']+f'<p class="conclusion">结清获额日前7天、当天（获额之后的当天数据）、获额后7天，提额3000以上组借款页进页率除当天略低于其他T0（{pct(daily["提额≥3000"][0]["newpage_rate"])}对{pct(daily["其他T0合计"][0]["newpage_rate"])}）外，其余各日均高于其他T0，但总体实际提单率更低。</p><p class="chart-note">每点＝当日有进页记录的事件数÷当日仍有正观察时长的事件数。D−7至D−1为完整自然日；D0从获额时刻起，之后遇下一次T0截断。已提单事件也统计后续访问，本图不是未提单用户回访率。</p>'+fold('展开逐日分子、分母及进页率',daily_table+'<p class="note">没有观察时长的事件退出该日分母；仍可观察但没有进页记录的事件保留分母、分子计0。同一天多次进入提单页，也只计1次进页事件。</p>')+'</section></main></body></html>']
    return ''.join(out)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input',type=Path,default=W/'analysis.json')
    parser.add_argument('--output-dir',type=Path,default=DEFAULT_OUT)
    args=parser.parse_args();out=args.output_dir.resolve();out.mkdir(parents=True,exist_ok=True)
    data=json.loads(args.input.read_text());assert data['quality']['reference_target_events_match'] and data['quality']['reference_D0_match']
    charts,audit=build_charts(data,out)
    dest=out/'简略版复原代码';dest.mkdir(exist_ok=True)
    sources=[W/name for name in SOURCE_NAMES]
    for src in sources:
        target=dest/src.name
        if src.resolve()!=target.resolve():shutil.copy2(src,target)
    if args.input.resolve()!=(dest/'analysis.json').resolve():shutil.copy2(args.input,dest/'analysis.json')
    readme='''T0提额≥3000行为分析简略版\n\n输入analysis.json为原统计冻结汇总，不重新取数或重新计算标签。\n复原简略版：python build_brief_report.py --input analysis.json --output-dir ./report_output\n需要Python3、numpy及matplotlib；原统计提取脚本另依赖pandas、pyarrow等，完整环境及事件输入见原统计复现包。\n当前简略版不包含原始用户级输入；原SQL/统计的完整复算使用原报告所附完整代码数据ZIP。\nsource SQL保留参数占位符，由Python绑定；不含数据库凭证。\n'''
    (dest/'README.txt').write_text(readme,encoding='utf-8')
    (dest/'requirements.txt').write_text('numpy\nmatplotlib\n',encoding='utf-8')
    (dest/'chart_label_manifest.json').write_text(json.dumps(audit,ensure_ascii=False,indent=2),encoding='utf-8')
    document=finish_report(build_document(data,charts),sources,'简略版复原代码')
    document=document.replace('<h2>附录：完整SQL与Python代码</h2>','<h2>附录：复原报告代码</h2>').replace('>完整代码附录</a>','>复原报告代码</a>')
    start=document.index('<section id="code-appendix">');controls=document.index('<div class="source-controls">',start)
    intro='<section id="code-appendix"><h2>附录：复原报告代码</h2><details id="appendix-code-details" class="appendix-details"><summary>展开复原报告代码</summary><p class="note">完整SQL、Python及复原代码下载。</p><div class="downloads"><a href="简略版报告复原代码.zip" download>下载简略版复原代码</a>'
    full_zip=out/'行为特征统计与分析_复现代码.zip'
    if full_zip.exists():intro+='<a href="行为特征统计与分析_复现代码.zip" download>下载原统计完整复现包</a>'
    original=out/'T0提额3000及以上_获额后行为特征分析报告.html'
    if original.exists():intro+='<a href="T0提额3000及以上_获额后行为特征分析报告.html">查看完整报告</a>'
    intro+='</div>'
    appendix_end=document.index('</section>',controls)
    document=document[:start]+intro+document[controls:appendix_end]+'</details>'+document[appendix_end:]
    (out/FILE).write_text(document,encoding='utf-8')
    hashes={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in dest.iterdir() if p.is_file() and p.name!='FILE_SHA256.json'}
    (dest/'FILE_SHA256.json').write_text(json.dumps(hashes,ensure_ascii=False,indent=2),encoding='utf-8')
    with zipfile.ZipFile(out/'简略版报告复原代码.zip','w',zipfile.ZIP_DEFLATED,compresslevel=5) as z:
        for p in sorted(dest.iterdir()):
            if p.is_file():z.write(p,'简略版复原代码/'+p.name)
    assert {name:v['count'] for name,v in audit.items()}=={'当天行为与提单对比':10,'月度当天提单率对比':8,'未提单事件行为分布':8,'获额前后借款页进页率':30}
    print(json.dumps({'report':str(out/FILE),'figures':len(charts),'data_labels':sum(v['count'] for v in audit.values()),'cards':4,'source_files':len(sources)},ensure_ascii=False))


if __name__=='__main__':main()
