"""Portable aggregate analysis: source SELECT JSON + product_info_copy catalog.

No database credentials or user-level records. Product enrichment is built on
the event-enriched SQL aggregates, never by attaching choices to an old cube.
Every joint row is mutually exclusive; projection tables are separate views.
"""
from __future__ import annotations
import argparse,collections,csv,itertools,json,math,hashlib
from datetime import datetime
from decimal import Decimal
from pathlib import Path

CORE=('month','credit_type','amount_band','base_band','loan_band','score_band','fee_band','daily_band','score_new_band')
DAYS=('day_change_type','day_change_band')
MEASURES=('n','y','d0_funded_n','d0_due_n','d0_overdue_n','d0_remit_amt','d0_repaid_amt','d0_repaid_missing_n','d0_status_missing_n')
DISPLAY={'base_band':'基础额度','loan_band':'上笔借款次数','score_band':'410原分档','fee_band':'原总息费变化','daily_band':'原日息变化',
 'score_new_band':'410新增分档','day_change_type':'最大账期方向','day_change_band':'最大账期幅度','product_migration_type':'产品迁移类型',
 'previous_offer_combo':'上一笔获额组合','current_offer_combo':'本次获额组合','previous_actual_product_no':'上笔实际产品',
 'offer_count_path':'获额产品数量路径','previous_actual_still_offered':'上笔实际产品仍可选','credit_type':'额度方向','amount_band':'变额幅度'}
ANALYSIS_DIMS=('base_band','loan_band','score_band','fee_band','daily_band','score_new_band','day_change_type','day_change_band',
 'product_migration_type','previous_offer_combo','current_offer_combo','previous_actual_product_no','offer_count_path','previous_actual_still_offered')
NEW_ROUTE=('previous_offer_combo','current_offer_combo','previous_actual_product_no','d0_actual_product_no','d0_offer_origin','d0_product_quality')
ORIGINAL_FIELDS=('t0_month','credit_type','amount_band','base_band','loan_band','score_band','fee_band','daily_band','score_new_band',
 't0_event_count','d0_apply_event_count','d0_funded_order_count','d0_due_order_count','d0_overdue_order_count',
 'd0_due_remit_amt_mxn','d0_due_repaid_amt_mxn','d0_due_profit_amt_mxn','d0_repaid_missing_count','d0_status_missing_count',
 'has_invalid_dimension','stat_date','start_event_date','end_event_date','refresh_time','day_change_type','day_change_band')
BAD={'缺失','无效','冲突','缺失/无效'}

def scalar(raw,positive=False):
    if raw is None:return None
    try:
        value=float(raw)
        return value if math.isfinite(value) and (value>0 if positive else value>=0) else None
    except (TypeError,ValueError):return None
def tokens(raw):return sorted({part.strip() for part in (raw or '').split(',') if part.strip()})
def ratio(a,b):return a/b if b else None
def zero():return {key:0 for key in MEASURES}
def add(target,row):
    for key in MEASURES:target[key]+=row[key] or 0
def finish(row):
    profit=None if row['d0_repaid_missing_n'] else row['d0_repaid_amt']-row['d0_remit_amt']
    return {**row,'rate':ratio(row['y'],row['n']),'profit_amt':profit,
      'profit_rate':ratio(profit,row['d0_remit_amt']) if profit is not None else None,
      'overdue_rate':None if row['d0_status_missing_n'] else ratio(row['d0_overdue_n'],row['d0_due_n']),
      'due_coverage':ratio(row['d0_due_n'],row['d0_funded_n'])}
def aggregate(rows,keys):
    result={}
    for row in rows:
        key=tuple(row[k] for k in keys);target=result.setdefault(key,zero());add(target,row)
    return [{**dict(zip(keys,key)),**finish(value)} for key,value in sorted(result.items(),key=lambda item:tuple(str(v) for v in item[0]))]
def daytext(value):
    text=format(Decimal(str(value)),'f')
    return (text.rstrip('0').rstrip('.') if '.' in text else text)+'天'
def days_label(current,previous):
    if current is None or previous is None:return '缺失','缺失'
    difference=Decimal(str(current))-Decimal(str(previous))
    if difference==0:return '不变',daytext(previous)
    return ('增加' if difference>0 else '减少'),'7天' if abs(difference)==7 else '14天' if abs(difference)==14 else '其他'
def migration(previous,current):
    if not previous or not current:return '缺失'
    a,b=set(previous),set(current)
    if a==b:return '组合不变'
    if a<b:return '增加产品'
    if b<a:return '减少产品'
    return '部分替换' if a&b else '全部替换'
def profile(ids,catalog):
    products=[catalog.get(pid) for pid in ids];matched=bool(ids) and all(products)
    summary={}
    for field in ('loan_term','days','daily_fee','total_fee'):
        values=[product.get(field) if product else None for product in products]
        good=matched and all(value is not None for value in values)
        summary[field+'_min']=min(values) if good else None
        summary[field+'_max']=max(values) if good else None
    if not ids:quality='无产品信息'
    elif not matched:quality='产品未全匹配'
    elif any(summary[field+'_min'] is None for field in ('loan_term','days','daily_fee','total_fee')):quality='属性不完整'
    else:quality='完整'
    return summary,quality

def enrich(source):
    catalog={}
    for raw in source['catalog']:
        pid=str(raw['product_no']).strip();assert pid and pid not in catalog
        catalog[pid]={'product_no':pid,'loan_term':scalar(raw.get('loan_term'),True),'days':scalar(raw.get('days'),True),
                      'daily_fee':scalar(raw.get('daily_fee')),'total_fee':scalar(raw.get('total_fee'))}
    output=[]
    for raw in source['rows']:
        r={**raw};current=tokens(r['risk_product']);previous=tokens(r['previous_risk_product']) if r['previous_owner_matches'] else []
        current_stats,current_quality=profile(current,catalog);previous_stats,previous_quality=profile(previous,catalog)
        r.update({'previous_offer_combo':'+'.join(previous) or '缺失','current_offer_combo':'+'.join(current) or '缺失',
          'product_migration_type':migration(previous,current),'previous_offer_product_count':len(previous),'current_offer_product_count':len(current),
          'offer_product_count_change':len(current)-len(previous),'offer_count_path':f'{len(previous)}→{len(current)}',
          'offer_retained_product_count':len(set(previous)&set(current)),'offer_added_product_count':len(set(current)-set(previous)),
          'offer_removed_product_count':len(set(previous)-set(current)),'previous_offer_info_status':previous_quality,'current_offer_info_status':current_quality})
        for prefix,stats in (('previous_offer',previous_stats),('current_offer',current_stats)):
            r.update({prefix+'_'+key:value for key,value in stats.items()})
        r['day_change_type'],r['day_change_band']=days_label(current_stats['days_max'],previous_stats['days_max'])
        previous_actual=str(r.get('settled_product_no') or '').strip()
        current_actual=str(r.get('d0_actual_product_no') or '').strip()
        r['previous_actual_product_no']=previous_actual or '产品缺失'
        r['d0_actual_product_no']=current_actual or ('未提单' if r['y']==0 else r['d0_product_quality'])
        previous_actual_data=catalog.get(previous_actual);actual_data=catalog.get(current_actual)
        for prefix,attrs in (('previous_actual',previous_actual_data),('d0_actual',actual_data)):
            for field in ('loan_term','days','daily_fee','total_fee'):r[prefix+'_'+field]=attrs.get(field) if attrs else None
        r['previous_actual_info_status']='完整' if previous_actual_data and all(previous_actual_data[field] is not None for field in ('loan_term','days','daily_fee','total_fee')) else '产品或属性缺失'
        r['d0_actual_info_status']='未提单' if r['y']==0 else '完整' if actual_data and all(actual_data[field] is not None for field in ('loan_term','days','daily_fee','total_fee')) else '产品或属性缺失'
        r['previous_actual_in_previous_offer']=int(previous_actual in previous) if previous_actual else None
        r['previous_actual_still_offered']=int(previous_actual in current) if previous_actual else None
        same=r['d0_offer_origin']=='原获额订单';valid=r['d0_product_quality']=='有效'
        eligible=bool(r['y'] and same and valid and current_actual in current)
        r['d0_choice_eligible']=int(eligible)
        r['d0_actual_in_current_offer']=int(current_actual in current) if r['y'] and valid else None
        r['d0_choice_status']='未提单' if not r['y'] else '异获额订单提单' if not same else '提单产品不可识别' if not valid else '原组合内提单' if eligible else '产品不在原组合'
        r['d0_chosen_same_as_previous']=int(current_actual==previous_actual) if eligible and previous_actual else None
        for name,field in (('low_daily','daily_fee'),('low_fee','total_fee'),('long_days','days')):
            low,high=current_stats[field+'_min'],current_stats[field+'_max']
            comparable=eligible and len(current)>=2 and low is not None and high is not None and low<high and actual_data and actual_data[field] is not None
            r[name+'_comparable_count']=r['y'] if comparable else 0
            chosen=comparable and actual_data[field]==(high if name=='long_days' else low)
            r[name+'_chosen_count']=r['y'] if chosen else 0
        retained=eligible and previous_actual in current and len(current)>=2
        r['repeat_product_comparable_count']=r['y'] if retained else 0
        r['repeat_product_chosen_count']=r['y'] if retained and current_actual==previous_actual else 0
        r['d0_same_offer_apply_count']=r['y'] if same else 0
        r['d0_other_offer_apply_count']=r['y'] if r['d0_offer_origin']=='其他获额订单' else 0
        r['d0_identified_choice_count']=r['y'] if eligible else 0
        r['d0_unidentified_choice_count']=r['y'] if r['y'] and same and not eligible else 0
        r['_previous_ids']=previous;r['_current_ids']=current
        assert r['d0_same_offer_apply_count']+r['d0_other_offer_apply_count']==r['y']
        assert 0<=r['d0_overdue_n']<=r['d0_due_n']<=r['d0_funded_n']<=r['y']<=r['n']
        output.append(r)
    keys=CORE+DAYS+NEW_ROUTE
    collapsed={};extra_measures=('d0_same_offer_apply_count','d0_other_offer_apply_count','d0_identified_choice_count','d0_unidentified_choice_count',
      'low_daily_comparable_count','low_daily_chosen_count','low_fee_comparable_count','low_fee_chosen_count','long_days_comparable_count','long_days_chosen_count',
      'repeat_product_comparable_count','repeat_product_chosen_count')
    for r in output:
        key=tuple(r[field] for field in keys)
        if key not in collapsed:
            collapsed[key]={**r,**zero(),**{field:0 for field in extra_measures}}
        target=collapsed[key];add(target,r)
        for field in extra_measures:target[field]+=r[field]
    rows=sorted(collapsed.values(),key=lambda r:tuple(str(r[field]) for field in keys))
    return rows,catalog,extra_measures

def compare(rows,fields,first='2026-01',second='2026-09',minimum=100):
    data=aggregate(rows,('month',*fields));lookup={}
    months={r['month']:r for r in aggregate(rows,('month',))}
    for row in data:lookup.setdefault(tuple(row[k] for k in fields),{})[row['month']]=row
    output=[]
    for key,history in lookup.items():
        a,b=history.get(first),history.get(second)
        if not a or not b:continue
        delta=100*(b['rate']-a['rate']);net=100*(b['y']/months[second]['n']-a['y']/months[first]['n'])
        if a['n']>=minimum and b['n']>=minimum:
            output.append({'dimensions':list(fields),'key':dict(zip(fields,key)),'first_month':first,'second_month':second,'first':a,'second':b,
              'delta_pp':delta,'net_pp':net,'eligible_finance':b['d0_due_n']>=100 and (b['due_coverage'] or 0)>=0.5,
              'last3':[{'month':month,'n':history.get(month,{}).get('n',0),'rate':history.get(month,{}).get('rate')} for month in ('2026-07','2026-08','2026-09')]})
    return sorted(output,key=lambda r:(r['delta_pp'],r['net_pp']))

def standardize(rows,fields,first='2026-01',second='2026-09',minimum=10):
    data=aggregate(rows,('month',*fields));lookup={}
    for row in data:lookup.setdefault(tuple(row[k] for k in fields),{})[row['month']]=row
    common=[(v[first],v[second]) for v in lookup.values() if first in v and second in v and v[first]['n']>=minimum and v[second]['n']>=minimum]
    totals={r['month']:r for r in aggregate(rows,('month',))};an=sum(a['n'] for a,b in common);bn=sum(b['n'] for a,b in common)
    if not common:return {'dimensions':list(fields),'common_cells':0,'standardized_delta_pp':None,'first_coverage':0,'second_coverage':0}
    difference=sum(((a['n']/an+b['n']/bn)/2)*(b['rate']-a['rate']) for a,b in common)*100
    return {'dimensions':list(fields),'common_cells':len(common),'minimum_cell_n_each_period':minimum,'standardized_delta_pp':difference,
      'first_coverage':an/totals[first]['n'],'second_coverage':bn/totals[second]['n'],'first_events':an,'second_events':bn}

def reconcile(rows,baseline,keys):
    before={tuple(r[k] for k in keys):r for r in aggregate(baseline['rows'],keys)}
    after={tuple(r[k] for k in keys):r for r in aggregate(rows,keys)}
    changes=[]
    for key in set(before)|set(after):
        a,b=before.get(key,zero()),after.get(key,zero());diff={}
        for field in MEASURES:
            delta=Decimal(str(b[field]))-Decimal(str(a[field]))
            if abs(delta)>Decimal('0.000001'):diff[field]={'old':a[field],'new':b[field],'delta':float(delta)}
        if diff:changes.append({'key':dict(zip(keys,key)),'fields':diff})
    return {'old_keys':len(before),'new_keys':len(after),'all_exact':not changes,'event_n_y_exact':not any('n' in x['fields'] or 'y' in x['fields'] for x in changes),
      'changed_keys':len(changes),'changes':changes,'old_snapshot':baseline['metadata']['snapshot']}

def fields_spec(max_slots):
    # Preserve the complete 26-column incoming Tableau schema and order.
    definitions={
      't0_month':'T0事件所在自然月，日期为月初；不是订单到期月。',
      'credit_type':'本次获额额度减上一笔触发结清订单的获额额度：增加、降低、不变。',
      'amount_band':'增加/降低按差值绝对值；不变按本次实际额度。边界：<500、[500,1000)、[1000,2000)、[2000,3000)、≥3000。',
      'base_band':'上一笔触发结清成功放款订单的获额额度：[0,1000)、[1000,2000)、[2000,5000)、[5000,10000)、≥10000。',
      'loan_band':'上一笔触发结清订单的remit_succ_rnb：1、2、3、4、5、>5次；缺失/无效单列。',
      'score_band':'本次T0获额user_id+serial_id匹配kabybmerge410fpd7cre：[1,529)、[529,569)、[569,3000]；缺失、无效、冲突单列保留。',
      'fee_band':'当前risk_product产品MAX(total_fee)减上一笔实际product_no的total_fee，均关联product_info_copy。完全相等才不变；绝对幅度<5pp、[5,10)pp、≥10pp。',
      'daily_band':'当前risk_product产品MIN(daily_fee)减上一笔实际product_no的daily_fee，均关联product_info_copy。完全相等才不变；绝对幅度<0.25pp、[0.25,0.5)pp、≥0.5pp。',
      'score_new_band':'与原分档使用同一个410评分：[1,505)、[505,535)、[535,3000]。不是第二个模型分。',
      't0_event_count':'严格T0事件执行原额度分析排除规则后的样本数；不是月度去重用户数。',
      'd0_apply_event_count':'口径1：获额后当天用户首次提单，不要求与原获额serial_id相同；一笔提单只归属最近前序T0。',
      'd0_funded_order_count':'只看该事件当天首次提单的实际订单，is_remit=1且remit_amt>0；包含尚未到期订单。',
      'd0_due_order_count':'上述已放款订单，due_date>2000-01-01且due_date<stat_date；归属T0事件月。',
      'd0_overdue_order_count':'上述到期订单当前loan_status_code=8；不是历史入催、D7逾期或窗口末状态。',
      'd0_due_remit_amt_mxn':'到期已放款整笔订单SUM(remit_amt)；盈利率分母，不用apply_amt，不做汇率换算。',
      'd0_due_repaid_amt_mxn':'当前订单表SUM(repaid_amt)，不扣折扣、不用流水；有缺失时为已知金额部分和，须结合缺失计数。',
      'd0_due_profit_amt_mxn':'还款缺失计数=0时：账面还款金额减放款金额；有缺失时为空。Tableau汇总须先确认SUM(缺失计数)=0。',
      'd0_repaid_missing_count':'到期订单中repaid_amt为空的数量；>0时不可计算该筛选客群盈利率。',
      'd0_status_missing_count':'到期订单中loan_status_code为空的数量；>0时不可计算该筛选客群订单逾期率。',
      'has_invalid_dimension':'仅原六维出现缺失、无效、冲突、缺失/无效时为1。新增账期和产品质量不改本字段；质量分档底层保留，筛选改变分母。',
      'stat_date':'到期筛选右开边界。本文件为2026-10-13，因此到期订单包含截至10月12日；不是财务历史状态快照字段。',
      'start_event_date':'含当天：2026-01-01。',
      'end_event_date':'含当天：2026-10-11。1—9月完整，10月仅1—11日。',
      'refresh_time':'America/Belize业务本地源数据快照，本次2026-10-14 04:17:11；不是到期截止日期或Excel导出时间。',
      'day_change_type':'MAX(当前获额组合days)减MAX(上一笔结清单的获额组合days)，正为增加、负为减少、0为不变。任一端产品未全匹配或days非正数时缺失。',
      'day_change_band':'增加/减少：差值绝对值恰为7天或14天分别为7天/14天，其余为其他；不变显示之前最大账期如28天。需联合方向使用。'
    }
    original=[(name,'date' if name in ('t0_month','stat_date','start_event_date','end_event_date') else 'datetime' if name=='refresh_time'
                    else 'money' if name in ('d0_due_remit_amt_mxn','d0_due_repaid_amt_mxn','d0_due_profit_amt_mxn')
                    else 'count' if name in ORIGINAL_FIELDS[9:20] else 'text',definitions[name]) for name in ORIGINAL_FIELDS]
    added=[('previous_offer_combo','text','上一笔结清订单对应获额通过记录的risk_product规范集合，去重并按编号文本排序。'),
      ('current_offer_combo','text','本次T0获额risk_product规范集合；不是实际选择产品。'),
      ('previous_actual_product_no','text','触发T0整笔结清的上一笔成功放款订单product_no。'),
      ('d0_actual_product_no','text','用户获额后当天首次提单的实际product_no；未提单和产品质量异常独立标记。'),
      ('product_migration_type','text','前后获额产品集合比较：组合不变、严格增集、严格减集、部分替换、全部替换；无完整编号时缺失。'),
      ('d0_offer_origin','text','原获额订单、其他获额订单或未提单；不改变口径1当天提单。'),
      ('d0_product_quality','text','首次实际提单订单的产品编号质量：有效、产品缺失、冲突、部分缺失或未提单。'),
      ('d0_choice_status','text','用于区分原组合内选择、异获额订单提单、组合外产品、不可识别和未提单。'),
      ('offer_count_path','text','上一笔获额产品个数到本次个数的路径。'),
      *[(key,'count','按前后完整产品集合计算，不依据实际选择结果。') for key in ('previous_offer_product_count','current_offer_product_count','offer_product_count_change','offer_retained_product_count','offer_added_product_count','offer_removed_product_count')],
      *[(key,'text','产品目录匹配及属性完整状态；不反向删除T0事件。') for key in ('previous_offer_info_status','current_offer_info_status','previous_actual_info_status','d0_actual_info_status')],
      ('previous_actual_in_previous_offer','count','上一笔实际产品是否在其对应获额组合内；产品未知时空。'),
      ('previous_actual_still_offered','count','上一笔实际产品是否仍在当前可选组合中，属于提单前信息。'),
      ('d0_actual_in_current_offer','count','当前首次提单产品是否属于原T0获额集合；不能据此剔除总体提单事件。'),
      ('d0_chosen_same_as_previous','count','可识别原组合内选择是否与上笔实际产品相同；未提单/不可归属时空。')]
    for prefix,label in (('previous_offer','上笔获额组合'),('current_offer','本次获额组合')):
        for prop,unit in (('loan_term','number'),('days','number'),('daily_fee','rate'),('total_fee','rate')):
            for bound in ('min','max'):added.append((prefix+'_'+prop+'_'+bound,unit,label+'各产品的'+prop+' '+bound+'；目录所有产品匹配且该属性有效才有值。'))
    for prefix,label in (('previous_actual','上笔实际产品'),('d0_actual','本次首次实际提单产品')):
        for prop,kind in (('loan_term','number'),('days','number'),('daily_fee','rate'),('total_fee','rate')):added.append((prefix+'_'+prop,kind,label+'的product_info_copy属性，不是客户实际报价或优惠后的合同费率。'))
    for prefix,label in (('previous_offer','上笔获额'),('current_offer','本次获额')):
        for slot in range(1,max_slots+1):
            for prop,kind in (('no','text'),('loan_term','number'),('days','number'),('daily_fee','rate'),('total_fee','rate')):
                added.append((f'{prefix}_product_{slot}_{prop}',kind,f'{label}第{slot}个规范排序产品的{prop}；不是展示顺序/推荐位置；不足该个数时空。'))
    for key,meaning in (
      ('d0_same_offer_apply_count','原获额订单当天提单事件数'),('d0_other_offer_apply_count','其他获额订单当天提单事件数'),
      ('d0_identified_choice_count','原获额订单且产品在原组合内的可识别选择数'),('d0_unidentified_choice_count','原获额订单但产品未知/不在组合内的提单数'),
      ('low_daily_comparable_count','多产品日息存在差异且原组合选择可识别的样本数'),('low_daily_chosen_count','上述可比样本选择最低日息产品的数量'),
      ('low_fee_comparable_count','多产品总息费存在差异且原组合选择可识别的样本数'),('low_fee_chosen_count','上述可比样本选择最低总息费产品的数量'),
      ('long_days_comparable_count','多产品账期存在差异且原组合选择可识别的样本数'),('long_days_chosen_count','上述可比样本选择最长账期产品的数量'),
      ('repeat_product_comparable_count','多产品且上笔实际产品仍可选的可识别选择数'),('repeat_product_chosen_count','上述样本继续选择上笔实际产品的数量')):
        added.append((key,'count',meaning+'；属于结果/条件偏好计数，不能替代总体T0分母。'))
    return [{'name':name,'kind':kind,'meaning':meaning} for name,kind,meaning in original+added]

def fact_record(r,catalog,spec,metadata):
    aliases={'t0_event_count':'n','d0_apply_event_count':'y','d0_funded_order_count':'d0_funded_n','d0_due_order_count':'d0_due_n',
      'd0_overdue_order_count':'d0_overdue_n','d0_due_remit_amt_mxn':'d0_remit_amt','d0_due_repaid_amt_mxn':'d0_repaid_amt',
      'd0_repaid_missing_count':'d0_repaid_missing_n','d0_status_missing_count':'d0_status_missing_n'}
    result={**r,'t0_month':r['month']+'-01','stat_date':metadata['business_observation_date'],'start_event_date':metadata['start_date'],
      'end_event_date':metadata['end_date'],'refresh_time':metadata['snapshot'][:19].replace('T',' '),
      'd0_due_profit_amt_mxn':None if r['d0_repaid_missing_n'] else round(r['d0_repaid_amt']-r['d0_remit_amt'],2),
      'has_invalid_dimension':int(any(r[field] in BAD for field in ('base_band','loan_band','score_band','fee_band','daily_band','score_new_band')))}
    result.update({field:r[key] for field,key in aliases.items()})
    for prefix,ids in (('previous_offer',r['_previous_ids']),('current_offer',r['_current_ids'])):
        for slot,pid in enumerate(ids,1):
            result[f'{prefix}_product_{slot}_no']=pid
            info=catalog.get(pid,{})
            for prop in ('loan_term','days','daily_fee','total_fee'):result[f'{prefix}_product_{slot}_{prop}']=info.get(prop)
    return {f['name']:result.get(f['name']) for f in spec}

def run(source,output,baseline,day_baseline):
    rows,catalog,extra=enrich(source)
    max_slots=max(max(r['previous_offer_product_count'],r['current_offer_product_count']) for r in rows)
    spec=fields_spec(max_slots);facts=[fact_record(r,catalog,spec,source['metadata']) for r in rows]
    assert tuple(f['name'] for f in spec[:26])==ORIGINAL_FIELDS
    monthly=aggregate(rows,('month',));overall=finish({key:sum(row[key] or 0 for row in rows) for key in MEASURES})
    reconciliation={}
    if baseline:reconciliation['original_six']=reconcile(rows,baseline,CORE)
    if day_baseline:reconciliation['original_days']=reconcile(rows,day_baseline,CORE+DAYS)
    assert all(r['event_n_y_exact'] for r in reconciliation.values()),'Mother/event count drift requires review'
    for r in rows:
        assert r['n']>0 and r['d0_identified_choice_count']+r['d0_unidentified_choice_count']==r['d0_same_offer_apply_count']
    views={'monthly':monthly,'directions':aggregate(rows,('month','credit_type','amount_band')),
      'migration':aggregate(rows,('month','credit_type','product_migration_type')),
      'paths':aggregate(rows,('month','previous_offer_combo','current_offer_combo','product_migration_type','day_change_type','day_change_band')),
      'actual_paths':aggregate(rows,('month','previous_actual_product_no','d0_actual_product_no','d0_choice_status')),
      'choice_origins':aggregate(rows,('month','d0_offer_origin','d0_choice_status')),
      'dimensions':{field:aggregate(rows,('month','credit_type',field)) for field in ANALYSIS_DIMS},
      'offer_count':aggregate(rows,('month','offer_count_path'))}
    views['flows']=[{k:r[k] for k in ('month','previous_offer_combo','current_offer_combo','d0_choice_status','n','y')}
      for r in aggregate(rows,('month','previous_offer_combo','current_offer_combo','d0_choice_status'))]
    # Conditional preference denominators include only attributable choices;
    # raw T0 and D0 counts stay in the main fact and path views.
    preference={}
    for r in rows:
        if not r['d0_choice_eligible']:continue
        key=(r['month'],r['current_offer_combo'],r['d0_actual_product_no'])
        target=preference.setdefault(key,{**zero(),**{k:0 for k in extra}});add(target,r)
        for k in extra:target[k]+=r[k]
    choice_totals=collections.Counter()
    for (month,combo,pid),stats in preference.items():choice_totals[(month,combo)]+=stats['d0_identified_choice_count']
    preferences=[]
    for (month,combo,pid),stats in preference.items():
        denominator=choice_totals[(month,combo)];info=catalog.get(pid,{})
        preferences.append({'month':month,'current_offer_combo':combo,'selected_product_no':pid,**finish(stats),**info,
          'attributable_choice_n':denominator,'choice_share':stats['d0_identified_choice_count']/denominator})
    views['preferences']=sorted(preferences,key=lambda r:(r['month'],r['current_offer_combo'],r['selected_product_no']))
    plans=[('credit_type','amount_band','loan_band','score_new_band'),('credit_type','amount_band','product_migration_type'),
      ('credit_type','loan_band','product_migration_type'),('credit_type','score_new_band','product_migration_type'),
      ('credit_type','amount_band','day_change_type','day_change_band'),('credit_type','loan_band','day_change_type'),
      ('credit_type','amount_band','loan_band','product_migration_type'),('credit_type','amount_band','score_new_band','product_migration_type'),
      ('credit_type','amount_band','product_migration_type','day_change_type'),('credit_type','amount_band','loan_band','score_new_band','product_migration_type'),
      ('credit_type','previous_offer_combo','current_offer_combo'),('credit_type','amount_band','previous_offer_combo','current_offer_combo'),
      ('credit_type','loan_band','previous_offer_combo','current_offer_combo'),('credit_type','score_new_band','previous_offer_combo','current_offer_combo'),
      ('credit_type','amount_band','loan_band','score_new_band','previous_offer_combo','current_offer_combo'),
      ('credit_type','amount_band','loan_band','score_new_band','previous_offer_combo','current_offer_combo','day_change_type','day_change_band')]
    for field in ('base_band','fee_band','daily_band','previous_actual_product_no','offer_count_path'):
        plans.extend([('credit_type',field,'product_migration_type'),('credit_type',field,'previous_offer_combo','current_offer_combo')])
    comparisons=[]
    for plan in dict.fromkeys(plans):comparisons.extend(compare(rows,plan))
    # New August/September routes receive a separate same-route comparison,
    # never a fictitious January rate of zero.
    recent=compare(rows,('credit_type','previous_offer_combo','current_offer_combo','day_change_type'),'2026-08','2026-09',50)
    comparisons.sort(key=lambda r:(r['delta_pp'],r['net_pp']))
    standard=[standardize(rows,('base_band','loan_band','score_new_band')),standardize(rows,('base_band','loan_band','score_new_band','product_migration_type')),
      standardize(rows,('base_band','loan_band','score_new_band','day_change_type')),standardize(rows,('base_band','loan_band','score_new_band','previous_offer_combo','current_offer_combo'))]
    all_paths=aggregate(rows,('previous_offer_combo','current_offer_combo','product_migration_type','day_change_type','day_change_band'))
    first_appearance={}
    for r in views['paths']:
        key=(r['previous_offer_combo'],r['current_offer_combo']);first_appearance[key]=min(r['month'],first_appearance.get(key,r['month']))
    for r in all_paths:r['first_seen_month']=first_appearance[(r['previous_offer_combo'],r['current_offer_combo'])]
    all_paths.sort(key=lambda r:-r['n'])
    quality={key:sum(row['n'] for row in rows if row['d0_choice_status']==key) for key in sorted({r['d0_choice_status'] for r in rows})}
    pairs=[]
    for x,y in itertools.combinations(ANALYSIS_DIMS,2):
        candidates=compare(rows,(x,y))
        pairs.append({'x':x,'y':y,'eligible':len(candidates),'min_delta':candidates[0]['delta_pp'] if candidates else None,
                      'max_delta':candidates[-1]['delta_pp'] if candidates else None,'worst':candidates[0] if candidates else None})
    preference_totals={k:sum(row[k] for row in rows) for k in extra}
    analysis={'metadata':source['metadata'],'overall':overall,'views':views,'paths_all':all_paths,'comparisons':comparisons,'recent_comparisons':recent,
      'negative':comparisons[:30],'positive':list(reversed([r for r in comparisons if r['delta_pp']>0]))[:30],
      'standardization':standard,'quality':quality,'preference_totals':preference_totals,'dimensions':DISPLAY,'pairs':pairs,
      'coverage':{'full_joint_rows':len(rows),'joint_fields':len(spec),'two_way_family_pairs':len(list(itertools.combinations(ANALYSIS_DIMS,2))),
        'planned_multiway_projections':len(set(plans)),'eligible_comparison_count':len(comparisons),'paths':len(all_paths),'max_product_slots':max_slots},
      'reconciliation':{key:{k:v for k,v in value.items() if k!='changes'} for key,value in reconciliation.items()}}
    output.mkdir(parents=True,exist_ok=True)
    def save(name,value):(output/name).write_text(json.dumps(value,ensure_ascii=False,separators=(',',':'),allow_nan=False))
    save('cube.json',{'metadata':source['metadata'],'rows':[{k:v for k,v in r.items() if k not in ('risk_product','previous_risk_product','settled_product_no','previous_owner_matches','_previous_ids','_current_ids')} for r in rows]})
    save('field-spec.json',spec);save('fact-values.json',{'fields':[f['name'] for f in spec],'rows':[[r[f['name']] for f in spec] for r in facts]})
    save('analysis.json',analysis);save('reconciliation.json',reconciliation);save('product-catalog.json',list(catalog.values()))
    return analysis

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--source',required=True,type=Path);parser.add_argument('--output',required=True,type=Path)
    parser.add_argument('--baseline',type=Path);parser.add_argument('--day-baseline',type=Path);args=parser.parse_args()
    data=json.loads(args.source.read_text());result=run(data,args.output,json.loads(args.baseline.read_text()) if args.baseline else None,json.loads(args.day_baseline.read_text()) if args.day_baseline else None)
    print(json.dumps({'status':'PASS','overall':result['overall'],'coverage':result['coverage'],'reconciliation':result['reconciliation'],'quality':result['quality'],'preference_totals':result['preference_totals']},ensure_ascii=False))
