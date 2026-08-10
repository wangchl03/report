// ===========================================================================
// 五类用户盈利能力对比报告 -- Chart.js 图表脚本
// 依赖: Chart.js 4.4.0 (从 CDN 加载)
// 数据变量 CATS, NAMES, CONTRIB, SEQM, DL 需在 HTML 中提前定义
// ===========================================================================


var CATS = {CATS_JS};
var NAMES = {NAMES_JS};
var CONTRIB = {CONTRIB_JS};
var SEQM = {SEQ_JS};
var DL = {DL_JS};
var DS = ['原生等放','非等放','等放','迁移','原生非等放'];

Chart.defaults.color = '#9ca3af';
Chart.defaults.borderColor = 'transparent';

function grouped(id, datasets) {{
  new Chart(document.getElementById(id), {{
    type: 'bar', data: {{ labels: CATS, datasets: datasets }},
    options: {{
      responsive: true, maintainAspectRatio: false,
      plugins: {{
        legend: {{ labels: {{ color: '#d1d5db' }} }},
        tooltip: {{ backgroundColor: '#374151', titleColor: '#f9fafb', bodyColor: '#e5e7eb',
          callbacks: {{ label: function(c) {{ return c.dataset.label + ': ' + c.raw.toLocaleString() + (c.dataset.unit||''); }} }} }}
      }},
      scales: {{
        x: {{ grid: {{ color: '#374151' }}, ticks: {{ color: '#9ca3af' }} }},
        y: {{ beginAtZero: true, grid: {{ color: '#374151' }}, ticks: {{ color: '#9ca3af', callback: function(v){{ return v + (datasets[0].unit||''); }} }} }}
      }}
    }}
  }});
}}

function makeDS(metric, unit) {{
  return DS.map(function(n) {{
    return {{ label: n, data: CATS.map(function(c){{ return SEQM[n][c][metric]; }}), backgroundColor: DL[n], borderRadius: 8, borderWidth: 0, unit: unit }};
  }});
}}

grouped('c_s8', makeDS('s8pct', '%'));
grouped('c_profit', makeDS('profit', '%'));
grouped('c_remit', makeDS('avg_remit', ' 元'));
grouped('c_n', makeDS('n', ''));

new Chart(document.getElementById('c_single_vs_multi'), {{
  type: 'bar', data: {{
    labels: DS,
    datasets: [
      {{ label: '仅1次盈利率', data: DS.map(function(n){{return CONTRIB[n][2];}}), backgroundColor: DS.map(function(n){{return DL[n]+'88';}}), borderRadius:8, borderWidth:0, unit:'%' }},
      {{ label: '多次盈利率', data: DS.map(function(n){{return CONTRIB[n][4];}}), backgroundColor: DS.map(function(n){{return DL[n];}}), borderRadius:8, borderWidth:0, unit:'%' }}
    ]
  }},
  options: {{
    responsive: true, maintainAspectRatio: false,
    plugins: {{ legend: {{ labels: {{ color: '#d1d5db' }} }}, tooltip: {{ backgroundColor: '#374151' }} }},
    scales: {{ x: {{ grid: {{ color: '#374151' }}, ticks: {{ color: '#9ca3af' }} }}, y: {{ grid: {{ color: '#374151' }}, ticks: {{ color: '#9ca3af', callback: function(v){{return v+'%';}} }} }} }}
  }}
}});

// 利润饼图
new Chart(document.getElementById('c_profit_pie'), {{
  type: 'doughnut', data: {{ labels: DS, datasets: [{{ data: [{PD}], backgroundColor: DS.map(function(n){{return DL[n];}}), borderWidth:2, borderColor:'#111827' }}] }},
  options: {{ responsive:true, maintainAspectRatio:false,
    plugins: {{
      legend: {{ position:'bottom', labels:{{color:'#d1d5db',padding:16,font:{{size:12}}}} }},
      tooltip: {{ backgroundColor:'#374151', callbacks:{{label:function(c){{return c.label+': '+c.raw.toFixed(1)+'%';}}}} }}
    }},
    layout: {{ padding: 8 }}
  }},
  plugins: [{{
    id: 'doughnutLabels',
    afterDraw: function(chart) {{
      var ctx = chart.ctx;
      var meta = chart.getDatasetMeta(0);
      var centerX = (chart.chartArea.left + chart.chartArea.right) / 2;
      var centerY = (chart.chartArea.top + chart.chartArea.bottom) / 2;
      meta.data.forEach(function(el, i) {{
        var angle = (el.startAngle + el.endAngle) / 2;
        var r = (el.outerRadius + el.innerRadius) / 2;
        var x = centerX + Math.cos(angle) * r;
        var y = centerY + Math.sin(angle) * r;
        var val = chart.data.datasets[0].data[i];
        ctx.save();
        ctx.fillStyle = '#f9fafb';
        ctx.font = 'bold 13px -apple-system,BlinkMacSystemFont,sans-serif';
        ctx.textAlign = 'center';
        ctx.textBaseline = 'middle';
        ctx.fillText(val.toFixed(1) + '%', x, y);
        ctx.restore();
      }});
    }}
  }}]
}});

// 放款饼图
new Chart(document.getElementById('c_remit_pie'), {{
  type: 'doughnut', data: {{ labels: DS, datasets: [{{ data: [{RD}], backgroundColor: DS.map(function(n){{return DL[n];}}), borderWidth:2, borderColor:'#111827' }}] }},
  options: {{ responsive:true, maintainAspectRatio:false,
    plugins: {{
      legend: {{ position:'bottom', labels:{{color:'#d1d5db',padding:16,font:{{size:12}}}} }},
      tooltip: {{ backgroundColor:'#374151', callbacks:{{label:function(c){{return c.label+': '+c.raw.toFixed(1)+'%';}}}} }}
    }},
    layout: {{ padding: 8 }}
  }},
  plugins: [{{
    id: 'doughnutLabels',
    afterDraw: function(chart) {{
      var ctx = chart.ctx;
      var meta = chart.getDatasetMeta(0);
      var centerX = (chart.chartArea.left + chart.chartArea.right) / 2;
      var centerY = (chart.chartArea.top + chart.chartArea.bottom) / 2;
      meta.data.forEach(function(el, i) {{
        var angle = (el.startAngle + el.endAngle) / 2;
        var r = (el.outerRadius + el.innerRadius) / 2;
        var x = centerX + Math.cos(angle) * r;
        var y = centerY + Math.sin(angle) * r;
        var val = chart.data.datasets[0].data[i];
        ctx.save();
        ctx.fillStyle = '#f9fafb';
        ctx.font = 'bold 13px -apple-system,BlinkMacSystemFont,sans-serif';
        ctx.textAlign = 'center';
        ctx.textBaseline = 'middle';
        ctx.fillText(val.toFixed(1) + '%', x, y);
        ctx.restore();
      }});
    }}
  }}]
}});

// 阶段利润堆叠
new Chart(document.getElementById('c_stage_profit'), {{
  type: 'bar', data: {{ labels: CATS, datasets: DS.map(function(n){{ return {{ label:n, data: CATS.map(function(c){{ return SEQM[n][c].profit_wan; }}), backgroundColor:DL[n], borderRadius:4, borderWidth:0 }}; }}) }},
  options: {{ responsive:true, maintainAspectRatio:false, plugins: {{ legend:{{labels:{{color:'#d1d5db'}}}}, tooltip: {{ backgroundColor:'#374151', callbacks:{{label:function(c){{return c.dataset.label+': '+(c.raw).toLocaleString()+' 万';}}}} }} }}, scales: {{ x: {{ stacked:true, grid:{{color:'#374151'}}, ticks:{{color:'#9ca3af'}} }}, y: {{ stacked:true, grid:{{color:'#374151'}}, ticks:{{color:'#9ca3af',callback:function(v){{return v+' 万';}}}} }} }} }}
}});

// 阶段放款堆叠
new Chart(document.getElementById('c_stage_remit'), {{
  type: 'bar', data: {{ labels: CATS, datasets: DS.map(function(n){{ return {{ label:n, data: CATS.map(function(c){{ return SEQM[n][c].remit_wan; }}), backgroundColor:DL[n], borderRadius:4, borderWidth:0 }}; }}) }},
  options: {{ responsive:true, maintainAspectRatio:false, plugins: {{ legend:{{labels:{{color:'#d1d5db'}}}}, tooltip: {{ backgroundColor:'#374151', callbacks:{{label:function(c){{return c.dataset.label+': '+(c.raw).toLocaleString()+' 万';}}}} }} }}, scales: {{ x: {{ stacked:true, grid:{{color:'#374151'}}, ticks:{{color:'#9ca3af'}} }}, y: {{ stacked:true, grid:{{color:'#374151'}}, ticks:{{color:'#9ca3af',callback:function(v){{return v+' 万';}}}} }} }} }}
}});

// ===== 循环贷图表 =====
// 循环贷 vs 非循环贷 盈利率对比
new Chart(document.getElementById('c_cycle_profit'), {{
  type: 'bar', data: {{
    labels: ['原生等放','非等放','等放','迁移','原生非等放'],
    datasets: [
      {{ label: '循环贷盈利率', data: [10.64, 23.32, 7.55, 32.79, 4.04], backgroundColor: '#3b82f6', borderRadius: 8, borderWidth: 0, unit: '%' }},
      {{ label: '非循环贷盈利率', data: [9.95, 26.16, 4.65, 34.75, 3.27], backgroundColor: '#6b7280', borderRadius: 8, borderWidth: 0, unit: '%' }}
    ]
  }},
  options: {{
    responsive: true, maintainAspectRatio: false,
    plugins: {{ legend: {{ labels: {{ color: '#d1d5db' }} }}, tooltip: {{ backgroundColor: '#374151', callbacks: {{ label: function(c) {{ return c.dataset.label + ': ' + c.raw.toFixed(2) + '%'; }} }} }} }},
    scales: {{ x: {{ grid: {{ color: '#374151' }}, ticks: {{ color: '#9ca3af' }} }}, y: {{ grid: {{ color: '#374151' }}, ticks: {{ color: '#9ca3af', callback: function(v) {{ return v + '%'; }} }} }} }}
  }}
}});

// 各阶段循环贷订单占比
new Chart(document.getElementById('c_cycle_ratio'), {{
  type: 'bar', data: {{
    labels: ['第2次放款','第3次放款','第4次+放款'],
    datasets: [
      {{ label: '等放', data: [29.4, 47.3, 53.5], backgroundColor: '#60a5fa', borderRadius: 8, borderWidth: 0 }},
      {{ label: '迁移', data: [18.0, 28.5, 33.0], backgroundColor: '#f59e0b', borderRadius: 8, borderWidth: 0 }},
      {{ label: '原生非等放', data: [23.3, 36.5, 42.4], backgroundColor: '#ef4444', borderRadius: 8, borderWidth: 0 }}
    ]
  }},
  options: {{
    responsive: true, maintainAspectRatio: false,
    plugins: {{ legend: {{ labels: {{ color: '#d1d5db' }} }}, tooltip: {{ backgroundColor: '#374151', callbacks: {{ label: function(c) {{ return c.dataset.label + ': ' + c.raw.toFixed(1) + '%'; }} }} }} }},
    scales: {{ x: {{ grid: {{ color: '#374151' }}, ticks: {{ color: '#9ca3af' }} }}, y: {{ beginAtZero: true, grid: {{ color: '#374151' }}, ticks: {{ color: '#9ca3af', callback: function(v) {{ return v + '%'; }} }}, max: 60 }} }}
  }}
}});
