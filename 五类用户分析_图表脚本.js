// ===========================================================================
// 五类用户盈利能力对比报告 -- Chart.js 图表脚本
// 依赖: Chart.js 4.4.0 (从 CDN 加载)
// 数据变量 CATS, NAMES, CONTRIB, SEQM, DL 需在 HTML 中提前定义
// ===========================================================================

var CATS = ["首贷", "第2次放款", "第3次放款", "第4次+放款"];
var NAMES = ["原生等放", "非等放", "等放", "迁移", "原生非等放"];
var CONTRIB = {"原生等放": [229609, 45.2, -51.1, 54.8, 16.2, 10.4], "非等放": [64094, 40.3, -10.0, 59.7, 25.0, 20.72], "等放": [194478, 47.4, -61.3, 52.6, 12.9, 6.02], "迁移": [35131, 32.7, 53.9, 67.3, 33.7, 34.71], "原生非等放": [28963, 49.6, -61.5, 50.4, 11.2, 3.74]};
var SEQM = {"原生等放": {"首贷": {"n": 229609, "s8pct": 36.9, "profit": 4.5, "avg_remit": 1448, "profit_wan": 1508, "remit_wan": 33257}, "第2次放款": {"n": 125882, "s8pct": 33.4, "profit": 10.0, "avg_remit": 2152, "profit_wan": 2718, "remit_wan": 27091}, "第3次放款": {"n": 80985, "s8pct": 33.2, "profit": 9.0, "avg_remit": 2745, "profit_wan": 2000, "remit_wan": 22232}, "第4次+放款": {"n": 178182, "s8pct": 29.7, "profit": 13.0, "avg_remit": 4596, "profit_wan": 10608, "remit_wan": 81891}}, "非等放": {"首贷": {"n": 64094, "s8pct": 21.2, "profit": 31.2, "avg_remit": 1023, "profit_wan": 2044, "remit_wan": 6555}, "第2次放款": {"n": 38267, "s8pct": 18.7, "profit": 30.9, "avg_remit": 1462, "profit_wan": 1731, "remit_wan": 5597}, "第3次放款": {"n": 24825, "s8pct": 20.2, "profit": 26.9, "avg_remit": 1841, "profit_wan": 1229, "remit_wan": 4571}, "第4次+放款": {"n": 56833, "s8pct": 22.0, "profit": 21.0, "avg_remit": 3344, "profit_wan": 3998, "remit_wan": 19007}}, "等放": {"首贷": {"n": 194478, "s8pct": 43.5, "profit": -2.1, "avg_remit": 1489, "profit_wan": -618, "remit_wan": 28954}, "第2次放款": {"n": 102224, "s8pct": 39.0, "profit": 4.7, "avg_remit": 2269, "profit_wan": 1095, "remit_wan": 23196}, "第3次放款": {"n": 65113, "s8pct": 38.0, "profit": 4.5, "avg_remit": 2932, "profit_wan": 854, "remit_wan": 19092}, "第4次+放款": {"n": 139639, "s8pct": 32.9, "profit": 10.1, "avg_remit": 4866, "profit_wan": 6879, "remit_wan": 67947}}, "迁移": {"首贷": {"n": 35131, "s8pct": 0.4, "profit": 49.4, "avg_remit": 1225, "profit_wan": 2126, "remit_wan": 4303}, "第2次放款": {"n": 23658, "s8pct": 9.6, "profit": 41.7, "avg_remit": 1646, "profit_wan": 1624, "remit_wan": 3895}, "第3次放款": {"n": 15872, "s8pct": 13.5, "profit": 36.5, "avg_remit": 1979, "profit_wan": 1146, "remit_wan": 3140}, "第4次+放款": {"n": 38543, "s8pct": 18.2, "profit": 26.7, "avg_remit": 3618, "profit_wan": 3729, "remit_wan": 13944}}, "原生非等放": {"首贷": {"n": 28963, "s8pct": 40.9, "profit": -3.7, "avg_remit": 778, "profit_wan": -83, "remit_wan": 2252}, "第2次放款": {"n": 14609, "s8pct": 33.4, "profit": 6.3, "avg_remit": 1165, "profit_wan": 107, "remit_wan": 1702}, "第3次放款": {"n": 8953, "s8pct": 32.0, "profit": 5.8, "avg_remit": 1598, "profit_wan": 84, "remit_wan": 1431}, "第4次+放款": {"n": 18290, "s8pct": 30.0, "profit": 5.3, "avg_remit": 2768, "profit_wan": 269, "remit_wan": 5063}}};
var DL = {"原生等放": "#3b82f6", "非等放": "#10b981", "等放": "#60a5fa", "迁移": "#f59e0b", "原生非等放": "#ef4444"};
var DS = ['原生等放','非等放','等放','迁移','原生非等放'];

Chart.defaults.color = '#9ca3af';
Chart.defaults.borderColor = 'transparent';

function grouped(id, datasets) {
  new Chart(document.getElementById(id), {
    type: 'bar', data: { labels: CATS, datasets: datasets },
    options: {
      responsive: true, maintainAspectRatio: false,
      plugins: {
        legend: { labels: { color: '#d1d5db' } },
        tooltip: { backgroundColor: '#374151', titleColor: '#f9fafb', bodyColor: '#e5e7eb',
          callbacks: { label: function(c) { return c.dataset.label + ': ' + c.raw.toLocaleString() + (c.dataset.unit||''); } } }
      },
      scales: {
        x: { grid: { color: '#374151' }, ticks: { color: '#9ca3af' } },
        y: { beginAtZero: true, grid: { color: '#374151' }, ticks: { color: '#9ca3af', callback: function(v){ return v + (datasets[0].unit||''); } } }
      }
    }
  });
}

function makeDS(metric, unit) {
  return DS.map(function(n) {
    return { label: n, data: CATS.map(function(c){ return SEQM[n][c][metric]; }), backgroundColor: DL[n], borderRadius: 8, borderWidth: 0, unit: unit };
  });
}

grouped('c_s8', makeDS('s8pct', '%'));
grouped('c_profit', makeDS('profit', '%'));
grouped('c_remit', makeDS('avg_remit', ' 元'));
grouped('c_n', makeDS('n', ''));

new Chart(document.getElementById('c_single_vs_multi'), {
  type: 'bar', data: {
    labels: DS,
    datasets: [
      { label: '仅1次盈利率', data: DS.map(function(n){return CONTRIB[n][2];}), backgroundColor: DS.map(function(n){return DL[n]+'88';}), borderRadius:8, borderWidth:0, unit:'%' },
      { label: '多次盈利率', data: DS.map(function(n){return CONTRIB[n][4];}), backgroundColor: DS.map(function(n){return DL[n];}), borderRadius:8, borderWidth:0, unit:'%' }
    ]
  },
  options: {
    responsive: true, maintainAspectRatio: false,
    plugins: { legend: { labels: { color: '#d1d5db' } }, tooltip: { backgroundColor: '#374151' } },
    scales: { x: { grid: { color: '#374151' }, ticks: { color: '#9ca3af' } }, y: { grid: { color: '#374151' }, ticks: { color: '#9ca3af', callback: function(v){return v+'%';} } } }
  }
});

// 利润饼图
new Chart(document.getElementById('c_profit_pie'), {
  type: 'doughnut', data: { labels: DS, datasets: [{ data: [97.8,52.3,47.7,50.1,2.2], backgroundColor: DS.map(function(n){return DL[n];}), borderWidth:2, borderColor:'#111827' }] },
  options: { responsive:true, maintainAspectRatio:false,
    plugins: {
      legend: { position:'bottom', labels:{color:'#d1d5db',padding:16,font:{size:12}} },
      tooltip: { backgroundColor:'#374151', callbacks:{label:function(c){return c.label+': '+c.raw.toFixed(1)+'%';}} }
    },
    layout: { padding: 8 }
  },
  plugins: [{
    id: 'doughnutLabels',
    afterDraw: function(chart) {
      var ctx = chart.ctx;
      var meta = chart.getDatasetMeta(0);
      var centerX = (chart.chartArea.left + chart.chartArea.right) / 2;
      var centerY = (chart.chartArea.top + chart.chartArea.bottom) / 2;
      meta.data.forEach(function(el, i) {
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
      });
    }
  }]
});

// 放款饼图
new Chart(document.getElementById('c_remit_pie'), {
  type: 'doughnut', data: { labels: DS, datasets: [{ data: [94.0,20.4,79.6,14.5,6.0], backgroundColor: DS.map(function(n){return DL[n];}), borderWidth:2, borderColor:'#111827' }] },
  options: { responsive:true, maintainAspectRatio:false,
    plugins: {
      legend: { position:'bottom', labels:{color:'#d1d5db',padding:16,font:{size:12}} },
      tooltip: { backgroundColor:'#374151', callbacks:{label:function(c){return c.label+': '+c.raw.toFixed(1)+'%';}} }
    },
    layout: { padding: 8 }
  },
  plugins: [{
    id: 'doughnutLabels',
    afterDraw: function(chart) {
      var ctx = chart.ctx;
      var meta = chart.getDatasetMeta(0);
      var centerX = (chart.chartArea.left + chart.chartArea.right) / 2;
      var centerY = (chart.chartArea.top + chart.chartArea.bottom) / 2;
      meta.data.forEach(function(el, i) {
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
      });
    }
  }]
});

// 阶段利润堆叠
new Chart(document.getElementById('c_stage_profit'), {
  type: 'bar', data: { labels: CATS, datasets: DS.map(function(n){ return { label:n, data: CATS.map(function(c){ return SEQM[n][c].profit_wan; }), backgroundColor:DL[n], borderRadius:4, borderWidth:0 }; }) },
  options: { responsive:true, maintainAspectRatio:false, plugins: { legend:{labels:{color:'#d1d5db'}}, tooltip: { backgroundColor:'#374151', callbacks:{label:function(c){return c.dataset.label+': '+(c.raw).toLocaleString()+' 万';}} } }, scales: { x: { stacked:true, grid:{color:'#374151'}, ticks:{color:'#9ca3af'} }, y: { stacked:true, grid:{color:'#374151'}, ticks:{color:'#9ca3af',callback:function(v){return v+' 万';}} } } }
});

// 阶段放款堆叠
new Chart(document.getElementById('c_stage_remit'), {
  type: 'bar', data: { labels: CATS, datasets: DS.map(function(n){ return { label:n, data: CATS.map(function(c){ return SEQM[n][c].remit_wan; }), backgroundColor:DL[n], borderRadius:4, borderWidth:0 }; }) },
  options: { responsive:true, maintainAspectRatio:false, plugins: { legend:{labels:{color:'#d1d5db'}}, tooltip: { backgroundColor:'#374151', callbacks:{label:function(c){return c.dataset.label+': '+(c.raw).toLocaleString()+' 万';}} } }, scales: { x: { stacked:true, grid:{color:'#374151'}, ticks:{color:'#9ca3af'} }, y: { stacked:true, grid:{color:'#374151'}, ticks:{color:'#9ca3af',callback:function(v){return v+' 万';}} } } }
});

// ===== 循环贷图表 =====
// 循环贷 vs 非循环贷 盈利率对比
new Chart(document.getElementById('c_cycle_profit'), {
  type: 'bar', data: {
    labels: ['原生等放','非等放','等放','迁移','原生非等放'],
    datasets: [
      { label: '循环贷盈利率', data: [10.64, 23.32, 7.55, 32.79, 4.04], backgroundColor: '#3b82f6', borderRadius: 8, borderWidth: 0, unit: '%' },
      { label: '非循环贷盈利率', data: [9.95, 26.16, 4.65, 34.75, 3.27], backgroundColor: '#6b7280', borderRadius: 8, borderWidth: 0, unit: '%' }
    ]
  },
  options: {
    responsive: true, maintainAspectRatio: false,
    plugins: { legend: { labels: { color: '#d1d5db' } }, tooltip: { backgroundColor: '#374151', callbacks: { label: function(c) { return c.dataset.label + ': ' + c.raw.toFixed(2) + '%'; } } } },
    scales: { x: { grid: { color: '#374151' }, ticks: { color: '#9ca3af' } }, y: { grid: { color: '#374151' }, ticks: { color: '#9ca3af', callback: function(v) { return v + '%'; } } } }
  }
});

// 各阶段循环贷订单占比
new Chart(document.getElementById('c_cycle_ratio'), {
  type: 'bar', data: {
    labels: ['第2次放款','第3次放款','第4次+放款'],
    datasets: [
      { label: '等放', data: [29.4, 47.3, 53.5], backgroundColor: '#60a5fa', borderRadius: 8, borderWidth: 0 },
      { label: '迁移', data: [18.0, 28.5, 33.0], backgroundColor: '#f59e0b', borderRadius: 8, borderWidth: 0 },
      { label: '原生非等放', data: [23.3, 36.5, 42.4], backgroundColor: '#ef4444', borderRadius: 8, borderWidth: 0 }
    ]
  },
  options: {
    responsive: true, maintainAspectRatio: false,
    plugins: { legend: { labels: { color: '#d1d5db' } }, tooltip: { backgroundColor: '#374151', callbacks: { label: function(c) { return c.dataset.label + ': ' + c.raw.toFixed(1) + '%'; } } } },
    scales: { x: { grid: { color: '#374151' }, ticks: { color: '#9ca3af' } }, y: { beginAtZero: true, grid: { color: '#374151' }, ticks: { color: '#9ca3af', callback: function(v) { return v + '%'; } }, max: 60 } }
  }
});
