'use strict';
const SLUG='cycle-loan-operating-analysis',VERSION='354269528608';
const C={blue:'#77b8ff',green:'#49d5ae',gold:'#ffca7d',red:'#ff939d',purple:'#c5afff',muted:'#a9bed0',ink:'#e8f2fa',line:'#31506a',dark:'#091b2c'};
const typeName={cycle:'循环贷',settled_reloan:'结清续贷',firstloan:'首贷',unknown:'标签未知'};
const typeColor={cycle:C.blue,settled_reloan:C.green,firstloan:C.gold,unknown:'#a7a8b1'};
const bands=['2次','3次','4次','5次','6次及以上'];
let D,offerRows=[],detailRows=[];
const $=id=>document.getElementById(id),esc=x=>String(x??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const num=(x,k=0)=>x===null||x===undefined?'未成熟':Number(x).toLocaleString('zh-CN',{minimumFractionDigits:k,maximumFractionDigits:k});
const pct=(x,k=2)=>x===null||x===undefined?'未成熟':(100*x).toFixed(k)+'%';
const pp=x=>x===null||x===undefined?'—':(x>0?'+':'')+x.toFixed(2)+'pp';
const sum=(rows,key)=>rows.reduce((a,r)=>a+(r[key]??0),0),meanRatio=(rows,n,d)=>sum(rows,d)?sum(rows,n)/sum(rows,d):null;
const mLabel=m=>m.slice(2).replace('-','/'),partial=m=>m==='2026-10';
function table(id,heads,rows){$(id).innerHTML='<table><thead><tr>'+heads.map(x=>'<th>'+esc(x)+'</th>').join('')+'</tr></thead><tbody>'+rows.map(row=>'<tr>'+row.map((x,i)=>'<td class="'+(i?'num':'')+'">'+esc(x)+'</td>').join('')+'</tr>').join('')+'</tbody></table>';}
function kpis(id,items){$(id).innerHTML=items.map(([v,t])=>'<div class="kpi"><strong>'+esc(v)+'</strong><span>'+esc(t)+'</span></div>').join('');}
function svg(id,W,H,body,label){$(id).innerHTML=`<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" role="img" aria-label="${esc(label)}">${body}</svg>`;}
function txt(x,y,t,color=C.ink,size=12,anchor='start',extra=''){return `<text x="${x}" y="${y}" fill="${color}" font-size="${size}" text-anchor="${anchor}" ${extra}>${esc(t)}</text>`;}
function title(t){return '<title>'+esc(t)+'</title>';}
function width(id,minimum=580){return Math.max(minimum,Math.floor($(id).clientWidth-26));}
function legend(items){return '<div class="legend">'+items.map(([name,color])=>'<span><i class="swatch" style="background:'+color+'"></i>'+esc(name)+'</span>').join('')+'</div>';}
function lineChart(id,rows,series,options={}){
  const W=width(id,options.minWidth??1050),H=options.height??365,L=58,R=168,T=32,B=48;
  const vals=series.flatMap(s=>rows.map(r=>r[s.key]).filter(v=>v!==null&&v!==undefined));
  if(!vals.length){$(id).textContent='无可展示的有效数据。';return;}
  let lo=options.min??Math.floor(Math.min(...vals)*100/5)*.05-.025,hi=options.max??Math.ceil(Math.max(...vals)*100/5)*.05+.025;
  if(hi<=lo)hi=lo+1;
  const x=i=>L+i*(W-L-R)/Math.max(1,rows.length-1),y=v=>T+(hi-v)/(hi-lo)*(H-T-B);
  let body='';
  for(let k=0;k<=5;k++){const v=lo+(hi-lo)*k/5,yy=y(v);body+=`<line x1="${L}" x2="${W-R}" y1="${yy}" y2="${yy}" class="grid"/>`+txt(L-9,yy+4,options.valueFormat?options.valueFormat(v):pct(v,0),C.muted,11,'end');}
  rows.forEach((r,i)=>{if(partial(r.month))body+=`<rect x="${x(i)-17}" y="${T}" width="34" height="${H-T-B}" fill="#ffca7d" opacity="0.06"/>`;body+=txt(x(i),H-B+24,mLabel(r.month)+(partial(r.month)?'*':''),C.muted,11,'middle');});
  const lastLabels=[];
  series.forEach(s=>{
    const pts=rows.map((r,i)=>({r,i,v:r[s.key]})).filter(p=>p.v!==null&&p.v!==undefined);
    if(!pts.length)return;
    body+=`<polyline points="${pts.map(p=>x(p.i)+','+y(p.v)).join(' ')}" fill="none" stroke="${s.color}" stroke-width="2.3" ${s.dash?'stroke-dasharray="6 4"':''}/>`;
    pts.forEach(p=>body+=`<circle cx="${x(p.i)}" cy="${y(p.v)}" r="3.3" fill="${s.color}" tabindex="0">${title(p.r.month+' '+s.name+' '+(options.valueFormat?options.valueFormat(p.v):pct(p.v))+(p.r.n_offer?'；分母 '+num(p.r.n_offer):''))}</circle>`);
    const p=pts.at(-1);lastLabels.push({y:y(p.v),text:s.name+' '+(options.valueFormat?options.valueFormat(p.v):pct(p.v)),color:s.color});
  });
  lastLabels.sort((a,b)=>a.y-b.y);let previous=T-20;
  lastLabels.forEach(l=>{l.yy=Math.max(l.y,previous+22,T+5);previous=l.yy;});
  const overflow=Math.max(0,previous-(H-B-3));lastLabels.forEach(l=>body+=txt(W-R+15,l.yy-overflow+4,l.text,l.color,12,'start','class="data-label"'));
  body+=txt(L,18,options.caption??'数据标签放在曲线右侧；悬停数据点可查看精确数值',C.muted,11);
  svg(id,W,H,body,options.title??'月度趋势');$(id).insertAdjacentHTML('beforeend',legend(series.map(s=>[s.name,s.color])));
}
function stackedChart(id,rows,series,options={}){
  const W=width(id,options.minWidth??580),H=options.height??350,L=58,R=18,T=options.percent?55:35,B=48;
  const totals=rows.map(r=>series.reduce((s,a)=>s+(r[a.key]??0),0)),max=options.percent?1:Math.max(...totals)*1.16;
  const y=v=>T+(1-v/max)*(H-T-B),step=(W-L-R)/rows.length,bw=Math.min(35,step*.68);let body='';
  for(let k=0;k<=4;k++){const v=max*k/4,yy=y(v);body+=`<line x1="${L}" x2="${W-R}" y1="${yy}" y2="${yy}" class="grid"/>`+txt(L-7,yy+4,options.percent?pct(v,0):num(v),C.muted,11,'end');}
  rows.forEach((r,i)=>{const xx=L+step*i+step/2;let acc=0;
    series.forEach(s=>{const v=r[s.key]??0;body+=`<rect x="${xx-bw/2}" y="${y(acc+v)}" width="${bw}" height="${Math.max(0,y(acc)-y(acc+v))}" fill="${s.color}">${title(r.month+' '+s.name+' '+(options.percent?pct(v):num(v)))}</rect>`;acc+=v;});
    const lab=options.percent?series.find(s=>s.key===(options.labelKey??series[0].key)):null;
    if(rows.length<=10||(i%2===0&&i<rows.length-2)||i===rows.length-1)body+=txt(xx,y(acc)-8,options.percent?pct(r[lab.key]??0,1):num(acc),options.percent?lab.color:C.ink,11,'middle','class="data-label"');
    body+=txt(xx,H-B+23,mLabel(r.month)+(partial(r.month)?'*':''),C.muted,10,'middle');
  });
  if(options.percent)body+=txt(L,17,'顶部标签：'+series.find(s=>s.key===(options.labelKey??series[0].key)).name+'占比',C.muted,11);
  svg(id,W,H,body,options.title??'月度构成');$(id).insertAdjacentHTML('beforeend',legend(series.map(s=>[s.name,s.color])));
}
function horizontalBars(id,items,{suffix='',percent=false,Wmin=580}={}){
  const W=width(id,Wmin),L=178,R=120,row=47,H=items.length*row+45,T=24,max=Math.max(...items.map(x=>x.value),1),range=W-L-R;let body='';
  items.forEach((a,i)=>{const yy=T+i*row,w=a.value/max*range;body+=txt(L-12,yy+15,a.name,C.muted,12,'end')+`<rect x="${L}" y="${yy}" width="${w}" height="24" fill="${a.color}" rx="2">${title(a.name+' '+num(a.value))}</rect>`+txt(L+w+10,yy+16,(percent?pct(a.value):num(a.value))+suffix,a.color,12);});svg(id,W,H,body,'数量与构成条形图');
}
function supply(){
  stackedChart('funding-volume',D.funding_monthly,[{key:'cycle_funded_orders',name:'循环贷',color:C.blue},{key:'settled_funded_orders',name:'结清续贷',color:C.green},{key:'firstloan_funded_orders',name:'首贷',color:C.gold},{key:'unknown_funded_orders',name:'标签未知',color:'#a7a8b1'}]);
  lineChart('funding-shares',D.funding_monthly,[{key:'cycle_share_all',name:'占全部订单',color:C.blue},{key:'cycle_share_reloan',name:'占类型2＋3续贷',color:C.green},{key:'cycle_amount_share_all',name:'占全部本金',color:C.gold}],{minWidth:580,caption:'10月*为部分月份；比例不能直接替代经营质量',min:.10,max:.75});
  table('funding-table',['放款月份','全部放款数','循环贷数','结清续贷数','首贷数','循环贷占全部','循环贷占续贷','循环贷本金占全部'],D.funding_monthly.map(r=>[r.month+(partial(r.month)?'*':''),num(r.all_funded_orders),num(r.cycle_funded_orders),num(r.settled_funded_orders),num(r.firstloan_funded_orders),pct(r.cycle_share_all),pct(r.cycle_share_reloan),pct(r.cycle_amount_share_all)]));
  const seq=D.funded_sequence.filter(r=>r.order_type==='cycle'),months=[...new Set(seq.map(r=>r.month))].sort();
  const rows=months.map(month=>{const rs=seq.filter(r=>r.month===month),n=sum(rs,'funded_orders');return {month,...Object.fromEntries(bands.map(b=>[b,rs.find(r=>r.loan_band===b)?.funded_orders/n||0]))};});
  stackedChart('sequence-chart',rows,bands.map((b,i)=>({key:b,name:b,color:[C.blue,C.green,C.gold,C.purple,C.red][i]})),{percent:true,minWidth:1050,labelKey:'6次及以上'});
}
function conversion(){
  const rule=$('offer-rule').value,cumulative=$('short-window-mode').value==='cumulative';
  offerRows=D.offer_monthly.filter(r=>r.denominator_rule===rule);
  lineChart('offer-chart',offerRows,[{key:'d0',name:'当日D0',color:C.blue},{key:'d3',name:'D0至D3',color:C.green},{key:'d7',name:'D0至D7',color:C.gold},{key:'d15',name:'15日D0至D14',color:C.purple}],{min:.20,max:.75});
  $('offer-denominator-note').textContent='当前分母：'+rule+'，合计'+num(sum(offerRows,'n_offer'))+'笔。所有比例的分母均为获额订单，不是提单用户数。10月*截至取数时；D1/D2当前显示'+(cumulative?'累计窗口。':'各自单日。');
  table('offer-table',['获额月份','获额订单数','当日提单数','当日率',cumulative?'D0至D1累计率':'第1日单日率',cumulative?'D0至D2累计率':'第2日单日率','D3累计数','D3累计率','D7累计数','D7累计率','15日内数','15日内率'],offerRows.map(r=>[r.month+(partial(r.month)?'*':''),num(r.n_offer),num(r.n_d0),pct(r.d0),pct(cumulative?r.d1_cumulative:r.d1_single),pct(cumulative?r.d2_cumulative:r.d2_single),num(r.n_d3_cumulative),pct(r.d3),num(r.n_d7_cumulative),pct(r.d7),num(r.n_d15_cumulative),pct(r.d15)]));
  const delay=offerRows.map(r=>({month:r.month,d0:r.n_d0/r.n_d15_cumulative,d13:(r.n_d3_cumulative-r.n_d0)/r.n_d15_cumulative,d47:r.n_d4_d7/r.n_d15_cumulative,d814:r.n_d8_d14/r.n_d15_cumulative}));
  stackedChart('apply-delay-chart',delay,[{key:'d0',name:'当日',color:C.blue},{key:'d13',name:'D1至D3',color:C.green},{key:'d47',name:'D4至D7',color:C.gold},{key:'d814',name:'D8至D14',color:C.purple}],{percent:true});
  const inc=offerRows.map(r=>({month:r.month,d03:r.d3-r.d0,d37:r.d7-r.d3,d715:r.d15-r.d7}));
  lineChart('window-increment-chart',inc,[{key:'d03',name:'D1至D3增量',color:C.green},{key:'d37',name:'D4至D7增量',color:C.gold},{key:'d715',name:'D8至D14增量',color:C.purple}],{minWidth:580,min:0,max:.25,caption:'分母仍为获额订单；这里是增量，不是占已提单的比例'});
}
function duration(){
  const w=D.window_summary;kpis('window-kpis',[[num(w.mean_days,2)+'天','完整可用窗口平均时长；20秒去重样本'],[pct(w.within7_share),'完整窗口在D0至D7结束'],[pct(w.overwritten_potential_share),'按下次结清规则提前终止窗口'],[num(w.still_valid_unapplied_orders),'截至快照仍有效未提单']]);
  const rows=D.window_monthly,W=1160,H=85+rows.length*34,L=125,T=49,cw=60,rh=34;let body=txt(L,20,'格内为完整窗口占比；悬停查看数量。10月条件样本明显未成熟。',C.muted,12);
  for(let day=0;day<16;day++)body+=txt(L+day*cw+cw/2,T-12,String(day)+'日',C.muted,11,'middle');
  rows.forEach((r,i)=>{const y=T+i*rh;body+=txt(L-12,y+22,r.month+(r.completed_coverage<.9999?'*':''),C.muted,12,'end');
    for(let day=0;day<16;day++){const cell=D.window_heatmap.find(a=>a.month===r.month&&a.day===day),alpha=.08+Math.min(1,cell.share/.25)*.8;body+=`<g tabindex="0">${title(r.month+' 日组'+day+'：'+num(cell.orders)+'/'+num(cell.completed_orders)+'='+pct(cell.share)+'；完整覆盖'+pct(r.completed_coverage))}<rect x="${L+day*cw}" y="${y}" width="${cw-3}" height="${rh-3}" fill="${C.blue}" opacity="${alpha}"/><text x="${L+day*cw+cw/2-1}" y="${y+21}" text-anchor="middle" fill="${cell.share>.12?'#081523':C.ink}" font-size="11">${pct(cell.share,1)}</text></g>`;}});
  svg('duration-heatmap',W,H,body,'月份与有效自然日二维分布热力图');
  table('duration-table',['获额月份','20秒去重获额数','完整窗口数','完整覆盖率','已完成均值（天）','D0至D7结束占比','15日到期占比','仍有效未提单'],rows.map(r=>[r.month,num(r.eligible_orders),num(r.completed_available_orders),pct(r.completed_coverage),num(r.completed_available_mean_days,2),pct(r.within7_share),pct(r.day15_share),num(r.still_valid_unapplied_orders)]));
  horizontalBars('expiry-results',[{name:'未提单被结清覆盖',value:w.unapplied_overwritten,color:C.blue},{name:'未提单15日到期',value:w.unapplied_expired,color:C.gold},{name:'仍有效未提单',value:w.still_valid_unapplied_orders,color:C.green}]);
  table('renewal-table',['原订单状态','下次结清20秒内新获额','延迟但24小时内获额','24小时内无证据'],D.renewal_audit.renewal_coverage.map(r=>[r.actual_end_reason,num(r.renewed_within20s_orders),num(r.renewed_later_within24h_orders),num(r.no_renewal_within24h_orders)]));
}
function drivers(){
  stackedChart('new-old-chart',D.qualification,[{key:'new_cycle_funded_orders',name:'首次循环贷借款组',color:C.blue},{key:'old_cycle_funded_orders',name:'动态老借款组',color:C.green}],{height:345});
  const g=D.funding_growth;horizontalBars('growth-decomposition',[{name:'活跃借款用户数因素',value:g.borrower_number_component,color:C.blue},{name:'组内平均频次因素',value:g.frequency_component,color:C.green}]);
  table('qualification-table',['月份','获额活跃用户','新资格活跃用户','老资格活跃用户','新循环贷借款用户','动态老借款用户','动态老组人均放款笔数'],D.qualification.map(r=>[r.month,num(r.eligible_users),num(r.new_qualified_active_users),num(r.old_qualified_active_users),num(r.new_cycle_borrowers),num(r.old_cycle_borrowers),num(r.old_group_frequency,2)]));
  const c=D.settlement_cadence;
  lineChart('cadence-chart',c,[{key:'held_days',name:'已结清实际持有',color:C.blue},{key:'scheduled_days',name:'已结清合同账期',color:C.green}],{min:10,max:28,valueFormat:v=>num(v,2)+'天',caption:'本图只看当月已整笔结清订单，不是到期订单盈利样本'});
}
function collide(a,b){return a.x<b.x+b.w&&a.x+a.w>b.x&&a.y<b.y+b.h&&a.y+a.h>b.y;}
function scatter(rows,profit,risk){
  const id='profit-risk-scatter',W=width(id,580),H=415,L=60,R=33,T=38,B=48;
  const pts=rows.filter(r=>r.matured_orders>=30&&r[profit]!==null&&r[risk]!==null);
  if(!pts.length){$(id).textContent='当前筛选没有≥30笔成熟订单的单元；不绘制收益风险点。';return;}
  const xs=pts.map(r=>r[risk]),ys=pts.map(r=>r[profit]),xmin=Math.floor((Math.min(...xs)-.035)*100)/100,xmax=Math.ceil((Math.max(...xs)+.035)*100)/100;
  const ymin=Math.min(0,Math.floor((Math.min(...ys)-.03)*100)/100),ymax=Math.ceil((Math.max(...ys)+.04)*100)/100;
  const x=v=>L+(v-xmin)/(xmax-xmin)*(W-L-R),y=v=>T+(ymax-v)/(ymax-ymin)*(H-T-B);let body='';
  for(let k=0;k<=4;k++){let xx=L+(W-L-R)*k/4,yy=T+(H-T-B)*k/4;body+=`<line x1="${xx}" x2="${xx}" y1="${T}" y2="${H-B}" class="grid"/>`+txt(xx,H-B+22,pct(xmin+(xmax-xmin)*k/4,0),C.muted,11,'middle');body+=`<line x1="${L}" x2="${W-R}" y1="${yy}" y2="${yy}" class="grid"/>`+txt(L-8,yy+4,pct(ymax-(ymax-ymin)*k/4,0),C.muted,11,'end');}
  body+=txt(L,18,'纵轴：盈利率；横轴：逾期率；面积：成熟放款本金',C.muted,11);
  const mx=Math.max(...pts.map(r=>r.matured_remit_amt)),circles=pts.map(r=>({r,x:x(r[risk]),y:y(r[profit]),rad:6+Math.sqrt(r.matured_remit_amt/mx)*19})),labels=[];
  circles.forEach(p=>{body+=`<circle cx="${p.x}" cy="${p.y}" r="${p.rad}" fill="${typeColor[p.r.order_type]}" opacity=".62" stroke="${typeColor[p.r.order_type]}" stroke-width="1.3" tabindex="0">${title(typeName[p.r.order_type]+' '+p.r.loan_band+'；盈利 '+pct(p.r[profit])+'；风险 '+pct(p.r[risk])+'；成熟订单 '+num(p.r.matured_orders)+'；成熟本金 '+num(p.r.matured_remit_amt)+' MXN；覆盖 '+pct(p.r.maturity_coverage))}</circle>`;});
  circles.forEach(p=>{const label=(p.r.order_type==='cycle'?'循环':'续贷')+p.r.loan_band.replace('及以上','+'),lw=label.length*12+8;
    const candidates=[[p.x+p.rad+6,p.y-7],[p.x+p.rad+6,p.y+12],[p.x-lw-p.rad-6,p.y-7],[p.x-lw-p.rad-6,p.y+12],[p.x-lw/2,p.y-p.rad-14],[p.x-lw/2,p.y+p.rad+10]];
    const chosen=candidates.map(([xx,yy])=>({x:xx,y:yy-12,w:lw,h:17})).find(b=>b.x>=L&&b.x+b.w<=W-R&&b.y>=T&&b.y+b.h<=H-B&&!labels.some(o=>collide(b,o))&&!circles.some(c=>collide(b,{x:c.x-c.rad,y:c.y-c.rad,w:c.rad*2,h:c.rad*2})));
    if(chosen){labels.push(chosen);body+=txt(chosen.x,chosen.y+13,label,typeColor[p.r.order_type],12,'start','class="data-label"');}});
  svg(id,W,H,body,'成熟放款次数客群盈利风险气泡对照');$(id).insertAdjacentHTML('beforeend',legend([['循环贷',C.blue],['结清续贷',C.green]]));
}
function quality(){
  const month=$('quality-month').value,profit=$('profit-metric').value,risk=$('risk-metric').value;
  const cells=D.finance_cells.filter(r=>r.month===month&&['cycle','settled_reloan'].includes(r.order_type));
  const totals=D.finance_monthly.filter(r=>r.month===month&&['cycle','settled_reloan'].includes(r.order_type));scatter(cells,profit,risk);
  $('quality-maturity-note').textContent=month+'放款样本成熟覆盖：'+totals.map(r=>typeName[r.order_type]+' '+pct(r.maturity_coverage)+'（'+num(r.matured_orders)+'/'+num(r.funded_orders)+'）').join('；')+'。统一成熟边界：到期日≤'+D.meta.mature_due_max+'，当前回款取各模块快照；若覆盖偏低，不代表整月质量。';
  const profitAmt={cash_profit_rate:'cash_profit_amt',d7_profit_rate:'d7_profit_amt',book_profit_rate:'book_profit_amt'}[profit];
  table('quality-summary-table',['类型','全量放款数','放款本金（万MXN）','成熟订单数','成熟覆盖','所选盈利率','所选逾期率','所选盈利额（万MXN）'],totals.map(r=>[typeName[r.order_type],num(r.funded_orders),num(r.funded_remit_amt/10000,2),num(r.matured_orders),pct(r.maturity_coverage),pct(r[profit]),pct(r[risk]),r[profitAmt]===null?'未成熟':num(r[profitAmt]/10000,2)]));
  table('quality-band-table',['类型','成功放款次数','全量放款数','成熟订单数','成熟覆盖','件均（MXN）','加权合同息费','实际盈利率','账面盈利率','D7实际盈利率','当前逾期率','D7逾期率'],cells.map(r=>[typeName[r.order_type],r.loan_band,num(r.funded_orders),num(r.matured_orders),pct(r.maturity_coverage),num(r.average_remit_amt,0),pct(r.weighted_fee_rate),pct(r.cash_profit_rate),pct(r.book_profit_rate),pct(r.d7_profit_rate),pct(r.current_overdue_rate),pct(r.d7_overdue_rate)]));
  const cmp=bands.map(b=>{const cy=cells.find(r=>r.order_type==='cycle'&&r.loan_band===b),st=cells.find(r=>r.order_type==='settled_reloan'&&r.loan_band===b);return cy&&st&&Math.min(cy.matured_orders,st.matured_orders)>=30?{band:b,profit:100*(cy[profit]-st[profit]),risk:100*(cy[risk]-st[risk])}:null;}).filter(Boolean).sort((a,b)=>a.profit-b.profit);
  $('quality-focus').textContent=cmp.length?'当前同月对照最大所选盈利率差：'+cmp[0].band+'，循环贷−结清续贷 '+pp(cmp[0].profit)+'；所选逾期率差 '+pp(cmp[0].risk)+'。这是同次数观察性对照，不能解释为循环贷标签的因果效应。':'没有双方均≥30笔成熟订单的次数档，不做差距排名。';
}
function blend(a,b,t){const aa=a.match(/\w\w/g).map(v=>parseInt(v,16)),bb=b.match(/\w\w/g).map(v=>parseInt(v,16));return '#'+aa.map((x,i)=>Math.round(x+(bb[i]-x)*t).toString(16).padStart(2,'0')).join('');}
function matrix(){
  const kind=$('matrix-type').value,key=$('matrix-metric').value,rows=D.funding_monthly.map(r=>r.month),W=1120,L=125,T=45,cw=177,rh=37,H=T+rows.length*rh+30;
  const risk=key.includes('overdue'),cs=D.finance_cells.filter(r=>r.order_type===kind&&bands.includes(r.loan_band)),mx=Math.max(...cs.map(r=>r.matured_orders),1);let body=txt(L,20,'面积=成熟订单数；颜色与数值='+$('matrix-metric').selectedOptions[0].text,C.muted,12);
  bands.forEach((b,i)=>body+=txt(L+i*cw+cw/2,T-10,b,C.muted,12,'middle'));
  rows.forEach((m,i)=>{const yy=T+i*rh;body+=txt(L-10,yy+25,m+(partial(m)?'*':''),C.muted,12,'end');bands.forEach((b,j)=>{
    const r=cs.find(z=>z.month===m&&z.loan_band===b),xx=L+j*cw+cw/2;body+=`<rect x="${L+j*cw}" y="${yy}" width="${cw-4}" height="${rh-3}" fill="#102a3e"/>`;
    if(!r||!r.matured_orders){body+=txt(xx,yy+24,'未成熟',C.muted,11,'middle');return;}
    const v=r[key],t=Math.max(0,Math.min(1,risk?(v-.20)/.40:(v+.10)/.35)),color=risk?blend('49d5ae','ff939d',t):blend('ff939d','49d5ae',t),rad=6+Math.sqrt(r.matured_orders/mx)*10;
    body+=`<g tabindex="0">${title(m+' '+typeName[kind]+' '+b+'；'+pct(v)+'；成熟 '+num(r.matured_orders)+'；覆盖 '+pct(r.maturity_coverage))}<circle cx="${xx-43}" cy="${yy+18}" r="${rad}" fill="${color}" opacity="${.4+.5*r.maturity_coverage}"/><text x="${xx+18}" y="${yy+24}" fill="${color}" font-size="12" text-anchor="middle">${pct(v)}</text></g>`;
  });});svg('quality-matrix',W,H,body,'月份借款次数盈利风险多维气泡矩阵');
}
function lifecycle(){
  const cohort=$('lifecycle-cohort').value,days=Number($('silence-days').value),paths=D.lifecycle_paths.filter(r=>r.cohort_name===cohort),n=paths[0].cohort_users;
  const W=width('lifecycle-mosaic',1050),H=205,L=12,usable=W-24,colors=[C.blue,C.green,C.gold,C.red];let body=txt(L,20,cohort+'：'+num(n)+'人；面积为用户占比，路径互斥且经过结清时序核验',C.muted,12),xx=L;
  paths.forEach((r,i)=>{const ww=r.share*usable;body+=`<rect x="${xx}" y="40" width="${Math.max(1,ww-3)}" height="90" fill="${colors[i]}" opacity=".65">${title(r.path+' '+num(r.users)+'人 '+pct(r.share))}</rect>`;
    if(ww>125)body+=txt(xx+ww/2,75,num(r.users)+'人','#081523',18,'middle')+txt(xx+ww/2,103,pct(r.share),'#081523',13,'middle');
    xx+=ww;});
  paths.forEach((r,i)=>body+=txt(L+(i%2)*usable/2,157+Math.floor(i/2)*23,r.path+'：'+num(r.users)+'人（'+pct(r.share)+'）',colors[i],12));svg('lifecycle-mosaic',W,H,body,'用户生命周期路径面积构成');
  table('lifecycle-path-table',['后续路径','用户数','占样本比例','其中仅一笔循环贷用户数'],paths.map(r=>[r.path,num(r.users),pct(r.share),num(r.single_order_users)]));
  const rs=D.silence_risk.filter(r=>r.cohort_name===cohort&&r.path==='首笔循环贷后全部循环贷'&&r.silent_days===days);
  horizontalBars('silence-risk-chart',rs.map(r=>({name:r.risk_status,value:r.users,color:r.risk_status.includes('状态8')?C.red:r.risk_status.includes('无逾期')?C.green:C.gold})),{Wmin:690});
  table('silence-risk-table',['风险状态','用户数','占连续循环静默用户'],rs.map(r=>[r.risk_status,num(r.users),pct(r.share)]));
  const all=paths.find(r=>r.path==='首笔循环贷后全部循环贷');
  $('lifecycle-focus').textContent='全部循环贷路径 '+num(all.users)+'人；其中只有一笔 '+num(all.single_order_users)+'人，至少两笔循环贷 '+num(all.users-all.single_order_users)+'人。当前静默'+days+'天的连续循环贷用户 '+num(rs[0]?.silent_users_in_path||0)+'人。未再放款只描述取数时状态，不推断永久流失。';
  table('cancellation-table',['用户样本','首笔循环贷后有分期逾期','逾期日之后又循环贷放款','逾期日之后新循环获额并放款','同逾期日获额待判序'],D.cancellation_audit.map(r=>[r.cohort_name,num(r.users_with_positive_period_overdue),num(r.users_cycle_funded_after_overdue_date),num(r.users_cycle_newly_approved_after_overdue_date),num(r.users_approval_on_same_overdue_date)]));
}
function bridge(){
  const month=$('bridge-month').value,rows=D.t0_bridge.filter(r=>r.month===month);
  rows.forEach(r=>horizontalBars(r.kind==='cycle'?'cycle-funnel':'noncycle-funnel',[
    {name:'全部整笔结清订单',value:r.all_settled_orders,color:C.blue},
    {name:'结清后零其他在途订单',value:r.zero_outstanding_settled_orders,color:C.green},
    {name:'去重后的清零场景',value:r.canonical_clean_scenes,color:C.gold},
    {name:'进入严格T0的结清订单',value:r.strict_t0_settled_orders,color:C.purple}]));
  table('bridge-table',['结清月份','来源类型','全部结清订单','零在途订单','零在途比例','清零场景','场景中type3获额通过比例','进入T0结清订单','T0事件数'],rows.map(r=>[r.month,r.kind==='cycle'?'循环贷':'首贷＋结清续贷',num(r.all_settled_orders),num(r.zero_outstanding_settled_orders),pct(r.zero_outstanding_share),num(r.canonical_clean_scenes),pct(r.type3_pass_given_zero_scene),num(r.strict_t0_settled_orders),num(r.strict_t0_events)]));
}
function details(){
  const month=$('detail-month').value,kind=$('detail-type').value,band=$('detail-band').value;
  detailRows=D.finance_cells.filter(r=>(month==='all'||r.month===month)&&(kind==='all'||r.order_type===kind)&&(band==='all'||r.loan_band===band));
  $('detail-count').textContent='筛选结果 '+num(detailRows.length)+'个聚合单元，当前预览 '+Math.min(30,detailRows.length)+'行。';
  table('detail-table',['放款月份','类型','成功放款次数','放款数','放款本金MXN','成熟数','成熟覆盖','实际回款MXN','实际盈利额MXN','实际盈利率','账面盈利率','D7盈利率','当前逾期率','D7逾期率'],detailRows.slice(0,30).map(r=>[r.month,typeName[r.order_type],r.loan_band,num(r.funded_orders),num(r.funded_remit_amt),num(r.matured_orders),pct(r.maturity_coverage),r.matured_orders?num(r.current_cash_repaid_amt):'未成熟',num(r.cash_profit_amt),pct(r.cash_profit_rate),pct(r.book_profit_rate),pct(r.d7_profit_rate),pct(r.current_overdue_rate),pct(r.d7_overdue_rate)]));
}
function downloadCSV(rows,name){
  if(!rows.length)return;const keys=Object.keys(rows[0]),quote=x=>'"'+String(x??'').replace(/"/g,'""')+'"';
  const csv='\ufeff'+[keys.map(quote).join(','),...rows.map(r=>keys.map(k=>quote(r[k])).join(','))].join('\r\n');
  const u=URL.createObjectURL(new Blob([csv],{type:'text/csv;charset=utf-8'})),a=document.createElement('a');a.href=u;a.download=name;a.click();setTimeout(()=>URL.revokeObjectURL(u),1000);
}
function options(id,values,selected){$(id).insertAdjacentHTML('beforeend',values.map(v=>'<option value="'+esc(v)+'">'+esc(v)+'</option>').join(''));if(selected)$(id).value=selected;}
function audits(){
  const o=D.audits.offers[0],l=D.audits.lifecycle[0],w=D.audits.duration[0],f=D.audits.finance[0];
  table('audit-table',['核验项','结果'],[
    ['独立serial获额订单数',num(o.serial_dedup_offer_count)],['20秒批次获额订单数',num(o.batch20_dedup_offer_count)],
    ['同获额serial跨用户',num(o.serial_multi_user_count)],['重复获额serial',num(o.duplicate_serial_count)],
    ['获额日期／时间不一致',num(o.offer_date_time_mismatch_count)],['循环贷类型标签冲突',num(o.conflicting_type_serials)],
    ['重复分期记录',num(l.duplicate_period_rows)],['分期逾期字段冲突',num(l.conflicting_overdue_periods)],
    ['有效时长样本提单早于获额',num(w.apply_before_offer_orders)],['理论有效终点后同serial提单',num(w.apply_at_or_after_end_orders)],
    ['经营成功放款总订单数',num(f.funded_orders)],['经营成熟整笔订单数',num(f.matured_orders)],
    ['账面回款缺失的成熟订单',num(f.missing_book_repaid_orders)],['流水金额缺失记录',num(f.missing_payin_amount_rows)],
    ['循环贷放款次数＜2',num(f.invalid_cycle_loan_sequence_orders)],['当前源表是否可以还原旧状态8','不能，仅聚合存档能精确重算旧报告']]);
}
async function init(){
  D=await(await fetch(SLUG+'.data.json?v='+VERSION)).json();
  $('report-meta').textContent='更新时间：'+D.meta.updated_at+'｜主体：2025-07-01至'+D.meta.main_end_business_date+'取数时｜金额：MXN｜增长及T0衔接：2026-01-01至2026-10-13';
  $('max-due').textContent=D.meta.mature_due_max;
  kpis('headline-kpis',[[num(D.offer_orders),'独立循环贷获额订单；截至快照'],['22.37% → 38.97%','2026年1→9月循环贷占全部放款'],['37.26% → 26.53%','2026年1→9月独立订单当日提单率'],['13.20% / 37.20%','8月循环贷实际盈利率／当前订单逾期率']]);
  const months=D.funding_monthly.map(r=>r.month);options('quality-month',months,'2026-08');options('bridge-month',[...new Set(D.t0_bridge.map(r=>r.month))].sort(),'2026-09');options('detail-month',months);options('detail-band',bands.filter(b=>D.finance_cells.some(r=>r.loan_band===b)));
  supply();conversion();duration();drivers();quality();matrix();lifecycle();bridge();details();audits();
  ['offer-rule','short-window-mode'].forEach(id=>$(id).addEventListener('change',conversion));
  ['quality-month','profit-metric','risk-metric'].forEach(id=>$(id).addEventListener('change',quality));
  ['matrix-type','matrix-metric'].forEach(id=>$(id).addEventListener('change',matrix));
  ['lifecycle-cohort','silence-days'].forEach(id=>$(id).addEventListener('change',lifecycle));
  $('bridge-month').addEventListener('change',bridge);['detail-month','detail-type','detail-band'].forEach(id=>$(id).addEventListener('change',details));
  $('offer-download').addEventListener('click',()=>downloadCSV(offerRows,'循环贷获额订单月度提单率.csv'));
  $('detail-download').addEventListener('click',()=>downloadCSV(detailRows,'循环贷经营质量筛选汇总.csv'));
  let sqlLoaded=false;$('sql-details').addEventListener('toggle',async()=>{if(!$('sql-details').open||sqlLoaded)return;try{const r=await fetch(SLUG+'.sql?v='+VERSION);if(!r.ok)throw new Error('SQL加载失败');$('sql-pre').textContent=await r.text();sqlLoaded=true;}catch(e){$('sql-pre').textContent='加载失败，请点击完整PGSQL下载链接。';}});
  $('load-state').textContent='汇总数据已加载。可切换订单分母、月份、借款次数及收益风险口径；详细数据最多预览30行。';
  window.reportReady=true;window.reportCounts={charts:document.querySelectorAll('.chart svg').length,detailPreview:Math.min(30,detailRows.length),details:document.querySelectorAll('details').length};
}
init().catch(e=>{$('load-state').textContent='报告数据加载异常：'+e.message;$('load-state').classList.add('error');window.reportError=e.message;});
