"""Dark, self-contained Chinese report of observed T0 behavior differences."""
from pathlib import Path
import html,json,io,re,hashlib,shutil,warnings
warnings.filterwarnings('ignore')
import pandas as pd,numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib import font_manager
from report_support import configure_dark_plots,finish_report
from narrative_report import build_narrative
from metric_guide import render_metric_guide
from analyze import OUT,LABEL,GROUPS,PRIMARY
W=Path(__file__).resolve().parent
CHART_LABELS={}


def esc(x):return html.escape(str(x))
def pct(v):return '—' if v is None else f'{v:.2%}'
def num(v):return '—' if v is None else f'{v:,.0f}'
def dec(v):return '—' if v is None else f'{v:.2f}'
def pp(v):return f'{v*100:+.2f}个百分点'
def table(headers,rows):
 return '<div class="scroll"><table><thead><tr>'+''.join('<th>'+esc(v)+'</th>' for v in headers)+'</tr></thead><tbody>'+''.join('<tr>'+''.join('<td>'+esc(v)+'</td>' for v in row)+'</tr>' for row in rows)+'</tbody></table></div>'


def chart(fig,name):
 assets=OUT/'图表';assets.mkdir(exist_ok=True)
 labels=[obj for obj in fig.findobj() if hasattr(obj,'get_gid') and obj.get_gid()=='metric-data-label']
 CHART_LABELS[name]={'count':len(labels),'labels':[obj.get_text() for obj in labels]}
 for i,obj in enumerate(labels,1):obj.set_gid(f'data-label-{i:03d}')
 fig.tight_layout()
 fig.savefig(assets/(name+'.png'),dpi=150,bbox_inches='tight');buf=io.StringIO();fig.savefig(buf,format='svg',bbox_inches='tight');plt.close(fig)
 svg=buf.getvalue()[buf.getvalue().find('<svg'):];(assets/(name+'.svg')).write_text(svg)
 prefix='fig'+hashlib.sha256(name.encode()).hexdigest()[:8]+'_'
 for old in sorted(set(re.findall(r'id="([^"]+)"',svg)),key=len,reverse=True):
  svg=svg.replace('id="'+old+'"','id="'+prefix+old+'"').replace('href="#'+old+'"','href="#'+prefix+old+'"').replace('url(#'+old+')','url(#'+prefix+old+')')
 return '<div class="figure'+(' figure-tall' if '逐日' in name else '')+'">'+svg+'</div>'


def label_points(ax,xs,ys,color,offset):
 for x,y in zip(xs,ys):
  text=ax.annotate(f'{y:.2f}%',(x,y),xytext=offset,textcoords='offset points',
                   ha='center',va='bottom' if offset[1]>=0 else 'top',fontsize=9,color=color,
                   bbox={'boxstyle':'round,pad=.10','fc':'#082235','ec':'none','alpha':.92})
  text.set_gid('metric-data-label')


def main():
 d=json.loads((W/'analysis.json').read_text());assert json.loads((W/'analysis_qa.json').read_text())['passed']
 rows={r['group']:r for r in d['overall']};t=rows['提额≥3000'];c=rows['其他T0合计']
 segments=[r for r in d['nonapp_segments'] if r['group']=='提额≥3000'];not_sub=sum(r['events'] for r in segments)
 absent=sum(r['events'] for r in segments[:2]);interact=segments[-1]['events']
 adjusted=[r for r in d['adjusted'] if r['analysis']=='产品条件可比' and r['control']=='其他T0合计'];adj={r['metric']:r for r in adjusted}
 support=next(r for r in d['common_support'] if r['analysis']=='产品条件可比' and r['control']=='其他T0合计')
 findings=[
  f"当天实际提单比例较低：提额≥3000事件的当天提单率为{pct(t['has_d0_apply'])}，其他T0为{pct(c['has_d0_apply'])}，相差{pp(t['has_d0_apply']-c['has_d0_apply'])}。",
  f"这批事件对应的用户借款经验更多、额度更高：历史成功借款次数平均{dec(t['loan_n_mean'])}次，其他T0为{dec(c['loan_n_mean'])}次；本次获额平均{num(t['credit_mean'])}，其他T0为{num(c['credit_mean'])}。",
  f"获额后当天借款页进页率为{pct(t['d0_entry'])}，其他T0为{pct(c['d0_entry'])}；已有进页记录的事件中，当天实际提单比例分别为{pct(t['entry_actual_submit_rate'])}和{pct(c['entry_actual_submit_rate'])}。",
  f"金额选择/修改发生率分别为{pct(t['d0_amount'])}和{pct(c['d0_amount'])}，还款计划详情发生率分别为{pct(t['d0_plan'])}和{pct(c['d0_plan'])}。页面操作与实际提交需要分开衡量，不能把操作次数直接当作更强借款意愿。",
  f"目标人群当天未提单共{num(not_sub)}次，其中{pct(absent/not_sub)}没有借款页进页记录（含无任何行为记录）；{pct(interact/not_sub)}已经进页且出现所列互动，但仍未提单。两类人群需要分别分析。",
  f"D0—D7首次提单率为{pct(t['d7_rate'])}，其他T0为{pct(c['d7_rate'])}；当天未提单的目标事件中，{pct((t['d7_n']-t['d0_n'])/not_sub)}后来在D1—D7提单。观察在下一次有效T0获额时截断。",
 ]
 if 'd0_entry' in adj:
  r=adj['d0_entry'];findings.append(f"限制到同月份、相同借款次数档、获额额度档和最低日息档的共同样本后，借款页进页率差为{pp(r['delta'])}，用户聚类95%区间[{pp(r['low95'])}，{pp(r['high95'])}]。该可比范围覆盖目标事件的{pct(r['target_coverage'])}。")
 if 'has_d0_apply' in adj:
  r=adj['has_d0_apply'];findings.append(f"同一产品条件可比范围内，当天实际提单率差为{pp(r['delta'])}，用户聚类95%区间[{pp(r['low95'])}，{pp(r['high95'])}]；这仍是可比事件的关联差异，不能直接解释为提额的因果影响。")
 (W/'findings.json').write_text(json.dumps(findings,ensure_ascii=False,indent=2))
 fp='/System/Library/Fonts/PingFang.ttc'
 try:font_manager.fontManager.addfont(fp);plt.rcParams['font.family']=font_manager.FontProperties(fname=fp).get_name()
 except Exception:plt.rcParams['font.family']='Arial Unicode MS'
 configure_dark_plots(plt);plt.rcParams.update({'axes.spines.top':False,'axes.spines.right':False,'svg.fonttype':'none','font.size':10,'axes.grid':True,'grid.alpha':.18})
 figures={}
 labels=['有行为记录','进入借款页','金额选择/修改','还款计划详情','当天实际提单'];keys=['d0_active','d0_entry','d0_amount','d0_plan','has_d0_apply']
 fig,ax=plt.subplots(figsize=(12.4,4.9));x=np.arange(len(keys))
 for row,shift,color,label in [(t,-.18,'#43c7e7','提额≥3000'),(c,.18,'#ffc26b','其他T0')]:
  bars=ax.bar(x+shift,[row[k]*100 for k in keys],.36,label=label,color=color)
  texts=ax.bar_label(bars,labels=[pct(row[k]) for k in keys],padding=5,color=color,fontsize=10)
  for obj in texts:obj.set_gid('metric-data-label')
 ax.set_xticks(x,labels);ax.set(ylabel='发生事件数 ÷ 该组全部获额事件数（%）',ylim=(0,108),title='获额后当天行为及实际提单');ax.legend(frameon=False,loc='upper right');figures['behavior']=chart(fig,'获额后当天行为对比')
 fig,axs=plt.subplots(2,1,figsize=(13.4,9.2))
 for group,color in [('提额≥3000','#43c7e7'),('其他T0合计','#ffc26b')]:
  z=pd.DataFrame([r for r in d['daily'] if r['group']==group]).sort_values('day');axs[0].plot(z.day,z.active_rate*100,marker='o',ms=4,color=color,label=group);axs[1].plot(z.day,z.newpage_rate*100,marker='o',ms=4,color=color,label=group)
  offset=(0,10) if group=='提额≥3000' else (0,-14)
  label_points(axs[0],z.day,z.active_rate*100,color,offset);label_points(axs[1],z.day,z.newpage_rate*100,color,offset)
 for ax,title in zip(axs,['有效观察事件日中的行为记录率','有效观察事件日中的借款页进页率']):
  ax.axvline(0,color='#9bb5c7',ls='--',lw=1);ax.set(xlabel='相对获额自然日（D0起按下一次T0截断）',ylabel='当日发生事件数 ÷ 当日可观察事件数（%）',title=title,ylim=(-4,108));ax.set_xticks(range(-7,8),['D'+str(x) for x in range(-7,8)]);ax.margins(x=.04);ax.legend(frameon=False,loc='upper left')
 figures['daily']=chart(fig,'获额前7天与后7天逐日行为')
 fig,ax=plt.subplots(figsize=(12.3,4.8));seglabels=['无行为记录','有记录但无进页记录','进页无所列互动','进页且互动未提单'];colors=['#6f8b9f','#43c7e7','#64dcae','#ffc26b'];positions=np.arange(2);left=np.zeros(2)
 for i,(label,color) in enumerate(zip(seglabels,colors)):
  vals=[next(r['share'] for r in d['nonapp_segments'] if r['group']==g and r['segment']==segments[i]['segment'])*100 for g in ['提额≥3000','其他T0合计']]
  counts=[next(r['events'] for r in d['nonapp_segments'] if r['group']==g and r['segment']==segments[i]['segment']) for g in ['提额≥3000','其他T0合计']]
  ax.barh(positions,vals,left=left,color=color,label=label)
  for j,(v,n) in enumerate(zip(vals,counts)):
   obj=ax.text(left[j]+v/2,j,f'{n:,}次\n{v:.2f}%',ha='center',va='center',color='#062333',fontsize=10,fontweight='medium');obj.set_gid('metric-data-label')
  left+=vals
 ax.set_yticks(positions,[f'提额≥3000\n未提单N={not_sub:,}',f'其他T0\n未提单N={c["events"]-c["d0_n"]:,}']);ax.invert_yaxis();ax.set(xlabel='该类未提单事件数 ÷ 本组全部当天未提单事件数（%）',title='当天未提单事件的互斥行为分类',xlim=(0,100));ax.legend(frameon=False,loc='upper center',bbox_to_anchor=(.5,-.19),ncol=2);figures['nonapp']=chart(fig,'当天未提单事件行为分布')
 figures['behavior']+=f'<p class="chart-caption">每根柱的标签＝发生该行为或实际提单的事件数÷该组全部获额事件数。目标N={t["events"]:,}，其他T0 N={c["events"]:,}。D0从获额时刻开始，含首次提单后的日志；各行为可共现，不能相加作为顺序漏斗。</p>'
 figures['daily']+='<p class="chart-caption">每个折线点均标出发生率；上图为至少1条行为记录，下图为至少1条借款页进页记录。分母是该组该日仍有正观察时长的事件数，逐日人数见下表；获额前7天为完整自然日，D0从获额时刻起，后续遇下一次T0截断。</p>'
 figures['nonapp']+=f'<p class="chart-caption">每段标签同时给出事件数与占比。目标分母是{not_sub:,}次D0未提单事件，其他T0分母是{c["events"]-c["d0_n"]:,}次D0未提单事件；四类互斥且原值合计100%，标签四舍五入后合计可能略有差异。这里“未提单”仅指该事件D0未提单，之后仍可能提单。</p>'
 css='''*{box-sizing:border-box}body{margin:0;font:16px/1.8 -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif}main{max-width:1320px;margin:auto;padding:34px 26px 70px}h1{font-size:34px;line-height:1.4;text-align:center}h2{font-size:24px;margin:0 0 16px}h3{font-size:18px}section,.hero{margin:24px 0;padding:26px;border-radius:12px}nav{display:flex;gap:18px;flex-wrap:wrap;margin:22px 0}a{text-decoration:none}.muted{font-size:14px}.scroll{overflow:auto}table{width:100%;border-collapse:collapse;font-size:13px;font-variant-numeric:tabular-nums}th,td{padding:11px 12px;border-bottom:1px solid;text-align:right;vertical-align:top}th{white-space:nowrap}th:first-child,td:first-child{text-align:left}.figure svg{width:100%;height:auto;max-height:540px}.callout{padding:16px 20px;border-left:4px solid;margin:18px 0}.grid{display:grid;grid-template-columns:1fr 1fr;gap:20px}.downloads{display:flex;gap:16px;flex-wrap:wrap}.downloads a{padding:10px 16px;border:1px solid;border-radius:7px}details{padding:14px 0}summary{cursor:pointer}li{margin:9px 0}code{font:13px ui-monospace,Menlo,monospace}pre{overflow:auto;padding:18px}@media(max-width:800px){main{padding:20px 12px}section{padding:20px 16px}h1{font-size:27px}.grid{grid-template-columns:1fr}}'''
 css+='''.kpi-grid{margin:24px 0}.kpi-grid .card{padding:18px 20px;border:1px solid var(--line);border-radius:9px}.kpi-grid span,.kpi-grid strong,.kpi-grid small{display:block}.kpi-grid strong{font-size:25px;margin:8px 0;line-height:1.5}.kpi-grid small{font-size:13px}p{max-width:1120px}h3[id]{scroll-margin-top:25px}.figure-tall svg{max-height:none}.chart-caption{font-size:14px;color:var(--muted);margin:8px 0 22px}@media print{nav,.downloads{display:none}section{break-inside:auto}h2,h3{break-after:avoid}tr,.card{break-inside:avoid}.scroll{overflow:visible}table{font-size:10px}.callout{background:#edf3f6;color:#172f40}.figure{background:white}}'''
 narrative=build_narrative(d,chart,plt)
 out=['<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>T0提额≥3000：用户行为与实际提单对比分析报告</title><meta name="description" content="2026年6至9月T0提额3000及以上事件的具体数据对比、月度变化、产品条件可比分析和未提单特征。"><style>'+css+'</style></head><body><main>']
 out+=['<h1>T0提额≥3000用户<br>获额后行为与页面特征对比</h1><nav>'+''.join(f'<a href="#{key}">{label}</a>' for key,label in [('findings','主要发现'),('design','思路与样本'),('overall','总体差异'),('pages','页面行为'),('nonapp','未提单特征'),('adjusted','可比对照'),('daily','逐日变化'),('limits','定义与限制'),('files','结果下载')])+'</nav>']
 out[1]=out[1].replace('获额后行为与页面特征对比</h1>','用户行为与实际提单对比分析报告</h1>').replace('<nav>','<p class="muted">生成时间 · 2026年10月19日</p><nav><a href="#analysis-summary">分析结论</a><a href="#profile">获额前特征</a><a href="#monthly-analysis">月度趋势</a><a href="#delayed">后续转化</a><a href="#actions">后续验证方向</a>')
 out+=[narrative['summary'],'<section id="findings"><h2>关键数值摘要</h2><details><summary>展开8项统计摘要</summary><ol>'+''.join('<li>'+esc(x)+'</li>' for x in findings)+'</ol></details><p class="muted">以上为事件与行为的关联描述。不能据此断定提额造成了提单率下降，也不能把页面浏览直接解释为价格敏感、额度不足或借款失败。</p></section>']
 q=d['quality']
 out+=['<section id="design"><h2>分析思路与样本</h2><p>沿用指定五档版Excel的T0口径：结清当天、结清之后重新通过获额；前后获额额度及上一笔放款金额均为正。提额增量按本次额度减去上笔额度，≥3000包含恰好3000。比较对象为同期间满足相同有效T0条件的其他事件，分为0＜提额＜3000、额度不变和额度降低。</p><p>先看获额前7天的行为基线，再看获额后当天和之后第1—7天的日志。每次获额的后续行为在下一次有效T0获额时停止归属，避免同一条后续日志被重复计入不同获额事件。获额前7天基线可能被同用户多个事件复用。</p><p>整体对比保留完整D0行为，因此包括实际提单之后的页面动作，只能用于描述。另输出严格按日志记录时间限制在首次提单之前的观察视图；主未提单诊断只比较当天未提单事件，不使用提交后的行为解释未提交。</p>']
 out+=[table(['范围','获额事件数','去重用户数','当天提单事件数'],[[r['group'],num(r['events']),num(r['users']),num(r['d0_n'])] for r in d['overall']])]
 out+=[f'<p class="muted">目标为{num(q["target_events"])}次事件、{num(q["target_users"])}名用户，与原表12,309次事件和3,061次当天提单对账一致。其他T0合计为三类对照之和，不能再次与三类相加。同一用户可在不同时间属于不同事件分组，跨目标和其他分组的用户有{num(q["users_in_both_event_groups"])}人；不等于互斥用户画像。</p></section>']
 out+=[narrative['profile']]
 out+=['<section id="overall"><h2>总体与月度差异</h2>',table(['事件分组','当天提单率','D0—D7提单率','平均历史借款次数','平均本次额度','平均最低日息','前7天活跃天数','当天平均可观察小时'],[[r['group'],pct(r['has_d0_apply']),pct(r['d7_rate']),dec(r['loan_n_mean']),num(r['credit_mean']),pct(r['daily_fee_mean']),dec(r['pre7_active_days']),dec(r['d0_exposure_hours'])] for r in d['overall']]),figures['behavior'],narrative['monthly']]
 out+=['<details><summary>展开逐月分组结果</summary>',table(['获额月份','事件分组','事件数','当天提单率','有行为记录率','借款页进页率','金额选择发生率','还款计划发生率'],[[r['period'],r['group'],num(r['events']),pct(r['has_d0_apply']),pct(r['d0_active']),pct(r['d0_entry']),pct(r['d0_amount']),pct(r['d0_plan'])] for r in d['monthly']]),'</details></section>']
 page_rows=[]
 for key,label in LABEL.items():
  field='d0_entry' if key=='newpage' else 'd0_'+key
  page_rows.append([label,pct(t[field]),pct(c[field]),pp(t[field]-c[field]),pct(t.get(key+'_among_entry')),pct(c.get(key+'_among_entry'))])
 out+=['<section id="pages"><h2>页面行为发生率</h2><p>发生率的分母为该组全部获额事件；“进页后人群”列指同一观察窗中既有进页记录又出现该动作的事件比例，属于行为共现，不是已验证的严格先后漏斗。</p>',table(['行为','提额≥3000','其他T0','差值','目标进页人群中占比','其他进页人群中占比'],page_rows),table(['事件分组','借款页日志停留秒数均值','进页事件停留秒数中位数','获额至首次进页日志中位分钟'],[[r['group'],dec(r['d0_loan_page_seconds_mean']),dec(r['d0_loan_page_seconds_median_entrants']),dec(r['entry_delay_minutes_median'])] for r in d['overall']]),'<p class="muted">时长仅汇总有效page_view_out日志并裁剪到事件和自然日边界，不等于互斥在线时长。确认提单相关埋点不等于订单落库，不能用作独立解释变量证明借款意愿。</p><details><summary>提单前视图（至少有60秒可观察时间）</summary>',table(['事件分组','全部事件','至少60秒事件','平均提单前可观察分钟','提单前进页率','提单前金额操作率','提单前还款计划率'],[[r['group'],num(r['events']),num(r['eligible_60sec_events']),dec(r['mean_available_minutes']),pct(r['newpage_rate_60sec']),pct(r['amount_rate_60sec']),pct(r['plan_rate_60sec'])] for r in d['preapp']]),'<p class="muted">提单越快，可观察的提单前时间越短。60秒限制只是敏感性视图，会选择性排除即时提单事件，不能与完整D0发生率直接等同。</p></details></section>']
 out+=['<section id="nonapp"><h2>未提单用户的行为特征</h2>',figures['nonapp'],table(['事件分组','当天未提单数','有行为记录率','借款页进页率','金额选择率','还款计划率','期次选择率'],[[r['group'],num(r['events']),pct(r['d0_active']),pct(r['d0_entry']),pct(r['d0_amount']),pct(r['d0_plan']),pct(r['d0_term'])] for r in d['nonapp']]),'<h3>目标未提单事件的四种状态</h3>',table(['状态','事件数','在目标未提单中的占比'],[[r['segment'],num(r['events']),pct(r['share'])] for r in segments]),'<p>建议将“缺少进页记录”和“已经进页互动但未提单”分开处理。前者可验证获额提醒、页面触达与真实需求；后者可进一步核对金额、期次、还款计划和确认后的订单链路。现有日志不能直接区分未看到通知、暂时不需要借款、主动放弃或技术失败，需后续埋点或实验验证。</p></section>']
 out+=['<section id="adjusted"><h2>控制可比条件后，差异是否保留</h2><p>先按月份、历史借款次数档和获额时段分层；再加入本次额度五档与最低日息四档。只保留目标至少10次、对照至少20次的共同分层，按目标在共同分层的事件分布加权。此为观察性标准化，不是随机实验或因果效应。</p>',table(['对照方式','对照人群','共同分层数','目标事件数','对照事件数','目标覆盖率'],[[r['analysis'],r['control'],num(r['common_cells']),num(r['target_n']),num(r['control_n']),pct(r['target_coverage'])] for r in d['common_support']])]
 for name,control in [('产品条件可比','其他T0合计'),('仅当天未提单_产品条件可比','其他T0合计'),('每用户最后一次T0_产品条件可比','其他T0合计')]:
  sub=[r for r in d['adjusted'] if r['analysis']==name and r['control']==control and r['metric'] in PRIMARY]
  out+=['<h3>'+esc(name)+'</h3>',table(['指标','目标标准化值','对照标准化值','差值','差值95%区间'],[[r['metric_label'],pct(r['target']),pct(r['control_rate']),pp(r['delta']),f"[{pp(r['low95'])}，{pp(r['high95'])}] "] for r in sub])]
 out+=['<p class="muted">区间按用户聚类计算，同一用户在目标和对照中的多次事件共同进入方差估计，分层权重固定。区间只描述当前样本不确定性，不修正探索性多指标比较、埋点缺失、渠道差异或历史后补；共同支持覆盖之外不能外推。</p></section>']
 out+=['<section id="daily"><h2>获额前后逐日变化</h2>',figures['daily'],'<p>逐日分母为当天仍有正观察时长的事件数。D0从获额时刻开始，是部分自然日；D1—D7遇下一次T0时退出本次观察。后续分母减少不是用户流失，缺少观察时间也没有填成不活跃。</p>',table(['相对日','目标观察事件数','目标有记录率','目标进页率','其他观察事件数','其他有记录率','其他进页率'],[[str(day),num(next(r for r in d['daily'] if r['group']=='提额≥3000' and r['day']==day)['exposed_events']),pct(next(r for r in d['daily'] if r['group']=='提额≥3000' and r['day']==day)['active_rate']),pct(next(r for r in d['daily'] if r['group']=='提额≥3000' and r['day']==day)['newpage_rate']),num(next(r for r in d['daily'] if r['group']=='其他T0合计' and r['day']==day)['exposed_events']),pct(next(r for r in d['daily'] if r['group']=='其他T0合计' and r['day']==day)['active_rate']),pct(next(r for r in d['daily'] if r['group']=='其他T0合计' and r['day']==day)['newpage_rate'])] for day in range(-7,8)]),'</section>']
 out+=['<section id="limits"><h2>定义、质量与解释边界</h2><ul><li>数据来自order_vir_f_copy、side_recycle_type_copy、order_loan_f_v2_copy、product_info_copy及event_track_record；均为只读查询。</li><li>原参考表为额度五档、利率和尾号分布版，获额事件及当天提单底数已核对；行为数据为本次逐月分片新提取。</li><li>后续提单不要求同获额订单号，不要求成功放款。原表的本笔额度使用率仍限同获额订单当天首次提单金额÷本次额度，前笔使用率限上笔结清订单的提单金额÷上笔获额额度，均按有效事件等权平均。</li><li>行为按create_time与获额时点对齐；日志时间不是不可变客户端动作或入库时点。没有独立event_id，无法证明原始行为记录完全无重复；因此发生率优先于次数和时长。</li><li>本次未假定页面访问顺序，仅按既有埋点SQL映射页面类别。产品比较页面和还款计划动作只能提出成本比较假设，不能直接证明价格敏感。</li><li>获额前行为是可追溯日志基线，可能受上笔借款和还款行为影响；不能把前后变化全部归因于本次提额。</li><li>完整D0及后续每日行为包含提单后的活动，不可直接当成获额时点预测特征。若用于意愿模型，必须只取评分时已发生且已可用的行为。</li><li>当前源副本缺少不可变ingested_at及历史状态版本，后补数据、埋点变更和当前状态修订仍可能影响历史回溯。各分片有不同只读事务快照。</li></ul>']
 out+=[table(['核对项目','结果'],[['全部有效T0获额事件数',num(q['cohort_events'])],['目标事件/当天提单与原表一致','是'],['原始日志逐日聚合行数',num(q['raw_log_daily_rows'])],['按日期存在性检查的缺失源日',str(q['missing_source_day_flags'])],['归属后无效时长记录数',num(q['invalid_duration_records_attributed'])],['日志日期与时间日期不一致记录数',num(q['date_mismatch_records_attributed'])],['负停留时长聚合行数',num(q['negative_page_duration_rows'])]]),'<p class="muted">日期存在性检查只证明这些日期有日志，不证明ETL全量完整。无日志按没有已记录行为处理，不能完全区分未活跃与漏报。</p></section>']
 xlsx='T0提额3000及以上_获额后行为特征对比_20260601-20260930.xlsx'
 out+=['<section id="files"><h2>统计结果与复现</h2><div class="downloads"><a href="'+xlsx+'" download>下载统计Excel</a><a href="行为特征统计与分析_复现代码.zip" download>下载复现代码</a></div><p class="muted">Excel含总体与月度、页面行为、逐日行为、未提单与可比对照、统计口径。复现代码沿用本地完整缓存时可离线分析；在其他环境重新提取源副本，结果可能随后补数据发生变化。</p></section></main></body></html>']
 document=''.join(out)
 document=document.replace('<a href="#analysis-summary">分析结论</a>','<a href="#analysis-summary">分析结论</a><a href="#metric-guide">指标口径</a>')
 document=document.replace('<section id="design">',render_metric_guide(d)+'<section id="design">')
 document=document.replace('目标进页人群中占比','目标有进页记录事件中占比').replace('其他进页人群中占比','其他有进页记录事件中占比')
 document=document.replace('先按月份、历史借款次数档和获额时段分层；再加入本次额度五档与最低日息四档。只保留目标至少10次、对照至少20次的共同分层，按目标在共同分层的事件分布加权。','“月份与借款经验可比”按月份×历史借款次数档×6小时获额时段分层；“产品条件可比”按月份×历史借款次数档×本次额度五档×最低日息四档分层。两者分别计算。全事件及仅未提单对照的共同层要求目标≥10次、对照≥20次；每用户最后一次T0的敏感性对照要求目标≥5次、对照≥10次。均按共同层内目标事件分布加权。')
 document=document.replace('<h2>页面行为发生率</h2>','<h2>页面行为发生率</h2>'+narrative['pages_interpretation'])
 document=document.replace('<h2>未提单用户的行为特征</h2>','<h2>未提单事件的行为特征</h2>'+narrative['nonapp_interpretation'])
 document=document.replace('<section id="adjusted">',narrative['delayed']+'<section id="adjusted">')
 document=document.replace('<h2>控制可比条件后，差异是否保留</h2>','<h2>控制可比条件后，差异是否保留</h2>'+narrative['adjusted_interpretation'])
 document=document.replace('<section id="limits">',narrative['actions']+'<section id="limits">')
 if all(r['d0_coupon_n']==0 for r in d['overall']):
  document=document.replace('<h2>页面行为发生率</h2>','<h2>页面行为发生率</h2><p class="muted">优惠券相关字段按既有Order_coupons_*埋点映射，本次所有分组均未观测到匹配记录。该项不用于画像结论，不能据此判断用户没有使用优惠券，需另外核对新版埋点。</p>')
 code=OUT/'复现代码';code.mkdir(exist_ok=True)
 sources=[p for p in W.iterdir() if p.suffix in {'.py','.sql'}]
 for p in sources:shutil.copy2(p,code/p.name)
 document=finish_report(document,sources,'复现代码')
 (W/'chart_label_manifest.json').write_text(json.dumps(CHART_LABELS,ensure_ascii=False,indent=2))
 (OUT/'T0提额3000及以上_获额后行为特征分析报告.html').write_text(document)
 (OUT/'主要发现.txt').write_text('\n\n'.join(findings))
 (OUT/'分析摘要.json').write_text(json.dumps({'findings':findings,'quality':q,'common_support':d['common_support']},ensure_ascii=False,indent=2))
 print(json.dumps({'report':str(OUT/'T0提额3000及以上_获额后行为特征分析报告.html'),'findings':findings},ensure_ascii=False),flush=True)


if __name__=='__main__':main()
