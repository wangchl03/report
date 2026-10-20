"""Document-style interpretation of the frozen, reconciled behavior comparison.

All displayed numbers are derived from analysis.json; this module does not
extract new data, fit a model, or change the underlying event definitions.
"""
import html
import json
from pathlib import Path


def pct(x):
    return f'{x:.2%}'


def num(x):
    return f'{x:,.0f}'


def pp(x):
    return f'{x * 100:+.2f}个百分点'


def table(headers, rows):
    escape = lambda v: html.escape(str(v))
    return ('<div class="scroll"><table><thead><tr>' +
            ''.join('<th>' + escape(x) + '</th>' for x in headers) +
            '</tr></thead><tbody>' + ''.join(
                '<tr>' + ''.join('<td>' + escape(x) + '</td>' for x in row) +
                '</tr>' for row in rows) + '</tbody></table></div>')


def build_narrative(data, chart, plt):
    """Return explanatory sections, using the report's dark plotting setup."""
    overall = {r['group']: r for r in data['overall']}
    target, control = overall['提额≥3000'], overall['其他T0合计']
    adjusted = {r['metric']: r for r in data['adjusted']
                if r['analysis'] == '产品条件可比' and
                r['control'] == '其他T0合计'}
    robustness = {r['metric']: r for r in data['adjusted']
                  if r['analysis'] == '每用户最后一次T0_产品条件可比' and
                  r['control'] == '其他T0合计'}
    support = next(r for r in data['common_support']
                   if r['analysis'] == '产品条件可比' and
                   r['control'] == '其他T0合计')
    segments = [r for r in data['nonapp_segments'] if r['group'] == '提额≥3000']
    nonapp = target['events'] - target['d0_n']
    later = target['d7_n'] - target['d0_n']
    control_later = control['d7_n'] - control['d0_n']
    month_target = sorted([r for r in data['monthly']
                           if r['group'] == '提额≥3000'], key=lambda r: r['period'])
    month_control = {r['period']: r for r in data['monthly']
                     if r['group'] == '其他T0合计'}
    first, last = month_target[0], month_target[-1]
    first_control, last_control = month_control[first['period']], month_control[last['period']]
    section = {}

    section['summary'] = f'''<section class="hero" id="analysis-summary">
<p class="muted">具体数据对比分析报告 · 基于已核对的获额事件与行为日志</p>
<h2>核心判断：页面互动更丰富，实际提单转化较弱</h2>
<p>2026年6—9月，T0提额≥3000的{num(target['events'])}次获额事件涉及
{num(target['users'])}名用户。这批事件对应的用户历史借款次数更多、获额额度更高，
获额前一周也更常进入借款页；获额后当天则更常选择金额、查看还款计划，
但当天实际提单率为<strong>{pct(target['has_d0_apply'])}</strong>，低于其他T0的
<strong>{pct(control['has_d0_apply'])}</strong>。</p>
<div class="grid kpi-grid">
<div class="card"><span>原始当天提单率差</span><strong>{pp(target['has_d0_apply']-control['has_d0_apply'])}</strong><small>全部目标事件与其他T0比较</small></div>
<div class="card"><span>产品条件分档对齐后的差值</span><strong>{pp(adjusted['has_d0_apply']['delta'])}</strong><small>覆盖目标事件{pct(support['target_coverage'])}；观察性比较</small></div>
<div class="card"><span>当天未提单中，已进页且有互动</span><strong>{num(segments[-1]['events'])}次 / {pct(segments[-1]['share'])}</strong><small>适合优先分析需求与页面决策环节</small></div>
<div class="card"><span>D0—D7累计首次提单率</span><strong>{pct(target['d7_rate'])} vs {pct(control['d7_rate'])}</strong><small>含获额当日及之后7个自然日；遇下一次T0截断</small></div>
</div>
<p><strong>业务含义：</strong>这批人群有较多已记录的页面参与行为，分析重点应落在“进入页面后如何形成借款决策”，
并把没有进页记录的事件单独识别。金额与还款计划互动提供了后续验证的方向，
尚不足以确定用户是价格敏感、暂时没有需求，还是遇到了操作障碍。</p>
<p class="muted">本文沿用原参考表的“提额≥3000”，包含恰好3000。统计单位为获额事件，
同用户相邻获额间隔≤20秒链式去重；同一用户可能贡献多次事件。</p></section>'''

    profile_rows = [
        ['历史成功借款次数（均值）', f"{target['loan_n_mean']:.2f}次", f"{control['loan_n_mean']:.2f}次", '目标事件对应用户的既往借款经验更多'],
        ['本次最高获额额度（均值）', num(target['credit_mean']), num(control['credit_mean']), '两组产品规模差异较大，应做分档可比分析'],
        ['本次最低日息（均值）', pct(target['daily_fee_mean']), pct(control['daily_fee_mean']), '平均日息更低，单凭均值不能解释个体选择'],
        ['获额前7天有行为记录的天数（均值）', f"{target['pre7_active_days']:.2f}天", f"{control['pre7_active_days']:.2f}天", '目标组在获额前已有较多已记录活动'],
        ['获额前7天进入借款页的天数（均值）', f"{target['pre7_entry_days']:.2f}天", f"{control['pre7_entry_days']:.2f}天", '页面参与差异在获额之前已经存在'],
        ['获额后当天可观察时长（均值）', f"{target['d0_exposure_hours']:.2f}小时", f"{control['d0_exposure_hours']:.2f}小时", '平均观察时长接近；仍需考虑时点与个体差异'],
    ]
    section['profile'] = '<section id="profile"><h2>这批用户在获额之前有哪些特征</h2>'
    section['profile'] += table(['比较维度', '提额≥3000', '其他T0', '分析含义'], profile_rows)
    section['profile'] += '''<p>首先，两组在历史借款经验和额度规模上有明显差别，直接拿全部事件的提单率比较，
混合了用户结构与产品条件差异。其次，目标组获额前一周进入借款页的天数已经更多，
因此，获额后的页面参与不能全部解释为本次提额新带来的意愿。</p>
<p>目标组平均最低日息较低，但提单率仍较低，这说明“平均利率更低”与“实际提单更多”在这份汇总中并不同步。
还需要看用户实际选择的金额、期次、应还金额以及具体需求；均值无法回答这些问题。</p></section>'''

    section['pages_interpretation'] = f'''<h3>行为差异主要体现在哪里</h3>
<p>目标组当天借款页进页率为{pct(target['d0_entry'])}，比其他T0低
{abs((target['d0_entry']-control['d0_entry'])*100):.2f}个百分点；
金额选择或修改发生率却高{(target['d0_amount']-control['d0_amount'])*100:.2f}个百分点，
还款计划详情发生率高{(target['d0_plan']-control['d0_plan'])*100:.2f}个百分点。
因此，原始差异更明显地表现为“金额与还款计划相关动作较多、实际提单比例较低”。</p>
<p>有借款页进页记录的事件中，目标组当天提单率为{pct(target['entry_actual_submit_rate'])}，
其他T0为{pct(control['entry_actual_submit_rate'])}。这进一步提示应关注进入页面后与提单有关的环节。
不过，完整D0日志可能包含提单后的查看或修改，以上属于同窗共现关系，不能视为严格的顺序漏斗。</p>
<div class="callout">金额和还款计划是值得进一步核验的决策维度。现有数据能够证明相关动作更多，
但不能直接证明用户在“反复犹豫”、认为价格过高，或认为额度不合适。</div>'''

    fig, ax = plt.subplots(figsize=(11, 4.2))
    x = list(range(len(month_target)))
    for records, label, color, dy in [
        (month_target, '提额≥3000', '#43c7e7', -19),
        ([month_control[r['period']] for r in month_target], '其他T0', '#ffc26b', 10),
    ]:
        values = [r['has_d0_apply'] * 100 for r in records]
        ax.plot(x, values, marker='o', lw=2.2, color=color, label=label)
        for i, value in enumerate(values):
            obj=ax.annotate(f'{value:.2f}%', (i, value), xytext=(0, dy),
                        textcoords='offset points', ha='center', fontsize=10, color=color)
            obj.set_gid('metric-data-label')
    ax.set_xticks(x, [r['period'] for r in month_target])
    ax.set(ylabel='当天实际提单率（%）', ylim=(15, 51),
           title='6—9月：目标组提单率持续下降，与其他T0的差距扩大')
    ax.legend(frameon=False, loc='upper right')
    monthly_chart = chart(fig, '月度当天提单率与差距')
    monthly_chart += '<p class="chart-caption">标签为各获额月份的当天实际提单率＝当月当天提单事件数÷当月全部获额事件数。按获额月份分组；各月分母见下表。</p>'
    section['monthly'] = '<h3 id="monthly-analysis">月度变化：差距从6月到9月扩大</h3>' + monthly_chart
    section['monthly'] += table(
        ['月份', '目标事件数', '目标当天提单数', '目标当天提单率', '其他T0当天提单率', '两组差值'],
        [[r['period'], num(r['events']), num(r['d0_n']), pct(r['has_d0_apply']),
          pct(month_control[r['period']]['has_d0_apply']),
          pp(r['has_d0_apply'] - month_control[r['period']]['has_d0_apply'])]
         for r in month_target])
    section['monthly'] += f'''<p>目标组当天提单率由6月的{pct(first['has_d0_apply'])}降至9月的
{pct(last['has_d0_apply'])}，下降{abs((last['has_d0_apply']-first['has_d0_apply'])*100):.2f}个百分点；
同期其他T0下降{abs((last_control['has_d0_apply']-first_control['has_d0_apply'])*100):.2f}个百分点。
两组提单率差距由{abs((first['has_d0_apply']-first_control['has_d0_apply'])*100):.2f}个百分点扩大到
{abs((last['has_d0_apply']-last_control['has_d0_apply'])*100):.2f}个百分点。</p>
<p>目标组进页率同期从{pct(first['d0_entry'])}降至{pct(last['d0_entry'])}，
金额操作率和还款计划查看率也有所下降。这提示后续应逐月检查用户构成、获额政策、产品与渠道的变化，
同时观察页面行为和最终提单。当前月度比较未逐月对齐全部产品条件，不能据此确认是某项政策或页面改动导致下降。</p>'''

    comparison_metrics = [
        ('d0_entry', '借款页进页率'), ('d0_amount', '金额选择或修改发生率'),
        ('d0_plan', '还款计划详情发生率'), ('has_d0_apply', '当天实际提单率'),
    ]
    section['adjusted_interpretation'] = table(
        ['指标', '全部事件原始差值', '分档对齐后差值', '分档对齐后差值95%区间'],
        [[label, pp(target[key]-control[key]), pp(adjusted[key]['delta']),
          f"[{pp(adjusted[key]['low95'])}，{pp(adjusted[key]['high95'])}]" ]
          for key, label in comparison_metrics])
    section['adjusted_interpretation'] += f'''<p>分档对齐后，“进页率更低”的差异缩小，95%区间包含0，
暂不能确认可比条件下存在稳定的进页率差异；但金额操作、还款计划查看更多以及实际提单更少的方向仍保留。
当天提单率分别为{pct(adjusted['has_d0_apply']['target'])}和
{pct(adjusted['has_d0_apply']['control_rate'])}，相差{pp(adjusted['has_d0_apply']['delta'])}。</p>
<p>该比较包括{num(support['target_n'])}次目标事件和{num(support['control_n'])}次对照事件，
覆盖目标的{pct(support['target_coverage'])}。原始差值与分档对齐后的差值来自不同覆盖范围，
不能将差值收窄的部分直接称为“额度、利率解释了多少比例”。</p>
<p>再限制每个用户只保留期间内最后一次T0事件，分档对齐后提单率差仍为
{pp(robustness['has_d0_apply']['delta'])}，95%区间为
[{pp(robustness['has_d0_apply']['low95'])}，{pp(robustness['has_d0_apply']['high95'])}]。
这说明多次获额事件的重复贡献不足以解释全部观察差异；其他未控制因素仍可能存在。</p>'''

    section['delayed'] = '<section id="delayed"><h2>后续是否只是延迟提单</h2>'
    section['delayed'] += table(
        ['观察指标', '提额≥3000', '其他T0'], [
            ['当天实际提单', f"{num(target['d0_n'])} / {pct(target['has_d0_apply'])}",
             f"{num(control['d0_n'])} / {pct(control['has_d0_apply'])}"],
            ['D1—D7新增首次提单（占全部获额事件）', f"{num(later)} / {pct(later/target['events'])}",
             f"{num(control_later)} / {pct(control_later/control['events'])}"],
            ['D0—D7累计首次提单', f"{num(target['d7_n'])} / {pct(target['d7_rate'])}",
             f"{num(control['d7_n'])} / {pct(control['d7_rate'])}"],
            ['当天未提单中，D1—D7后来提单的比例', pct(later/nonapp),
             pct(control_later/(control['events']-control['d0_n']))],
        ])
    section['delayed'] += f'''<p>目标组有{num(later)}次事件在获额次日至第7天才首次提单，
说明确实存在后续转化。但在当天未提单事件中，后来提单的比例为{pct(later/nonapp)}，
低于其他T0的{pct(control_later/(control['events']-control['d0_n']))}；
截至D7的累计提单率仍低{(control['d7_rate']-target['d7_rate'])*100:.2f}个百分点。
因此，现有观察范围内的差异不能充分归结为“只是晚几天提单”。</p>
<p class="muted">D0—D7共涉及8个自然日，D0从获额时刻开始。每次事件遇下一次有效T0获额即截断，
后续提单属于新的获额事件；这里不是每个用户完整固定7×24小时的累计转化率，截断后也不代表用户永久不提单。</p></section>'''

    section['nonapp_interpretation'] = f'''<h3>未提单事件的主要分析方向</h3>
<p>目标组当天未提单{num(nonapp)}次，其中{num(segments[-1]['events'])}次已经进页并有互动，
占{pct(segments[-1]['share'])}；没有进页记录的两类合计{num(segments[0]['events']+segments[1]['events'])}次，
占{pct(segments[0]['share']+segments[1]['share'])}。这两个状态有不同的后续验证重点。</p>
<p>已进页互动的事件，可以进一步看金额修改幅度、期次切换、应还金额和退出位置，核对是否存在产品方案与需求不匹配；
缺少进页记录的事件，则应先补齐通知送达、打开与页面进入链路。两类都不能仅凭日志缺口确定用户主观原因。</p>'''
    section['nonapp_interpretation'] += '''<p class="muted">此处互动包括金额、期次、合同、还款计划、用途、优惠券及产品比较相关映射；
确认相关埋点单独核验，不计入这四类状态中的互动定义。优惠券映射本次无匹配记录。
“无进页记录”只描述已观测日志，不能直接等同于用户从未打开页面。</p>'''

    audit_file = Path(__file__).resolve().parent / 'confirmation_and_coupon_audit.json'
    confirm_without_order = None
    if audit_file.is_file():
        audit = next(r for r in json.loads(audit_file.read_text()) if r['group'] == '提额≥3000')
        confirm_without_order = audit['confirm_without_actual_D0']
    section['actions'] = '<section id="actions"><h2>建议怎样继续分析和验证</h2>'
    section['actions'] += table(
        ['优先方向', '本次证据', '下一步需要补充的分析', '判断改善的指标'], [
            ['金额与还款方案的匹配',
             f"分档对齐后金额操作多{adjusted['d0_amount']['delta']*100:.2f}个百分点，计划详情多{adjusted['d0_plan']['delta']*100:.2f}个百分点；提单仍较少",
             '限制到首次提单前，追踪初始金额→最终金额、期次切换、每期应还与退出位置；区分主动调整与页面默认动作',
             '可比条件下的实际提单率、D0—D7累计提单率；结合金额和风险表现判断'],
            ['按未提单状态分组', f"{num(segments[-1]['events'])}次进页互动未提单；{num(segments[0]['events']+segments[1]['events'])}次无进页记录",
             '分别验证产品说明与方案展示、获额通知送达和页面触达；通过小范围随机实验估计增量',
             '各组增量实际提单率，同时监测投诉、借款质量与触达成本'],
            ['检查6—9月差距扩大的来源',
             f"目标提单率{pct(first['has_d0_apply'])}→{pct(last['has_d0_apply'])}，原始差距扩大",
             '逐月对齐用户借款阶段、实际额度/日息、渠道、风险模型分及版本；再核对政策与页面版本变化',
             '月度可比条件下的提单率差及覆盖率'],
            ['确认埋点与订单链路核验',
             f'{num(confirm_without_order)}次有确认相关记录但无当天实际订单' if confirm_without_order is not None else '确认相关埋点与实际订单并非等价',
             '逐次核验确认结果、接口返回、取消、重复点击与订单落库；先区分业务放弃和系统失败',
             '已验证的异常事件数、修复后实际提单增量'],
        ])
    section['actions'] += '''<p>以上是基于观察结果提出的验证方向，并不代表相应原因已经被确认。
若要评估产品展示、通知或方案调整能带来多少提升，需要在同一类合格用户中做随机对照，
以实际订单为结果，并同时观察后续借款金额与风险。当前数据不支持承诺具体提单率提升幅度。</p>
<p>若把行为加入意愿模型，获额时评分只能使用此前已发生且当时已可用的数据；
获额后的行为应在明确的后续评分时点重新生成特征，并仅预测该评分时点之后的提单。
完整D0的页面动作不能直接回填为获额时点特征。</p></section>'''
    return section
