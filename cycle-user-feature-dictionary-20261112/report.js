(() => {
  'use strict';
  const data = JSON.parse(document.getElementById('unified-report-data').textContent);
  const reports = [...document.querySelectorAll('.u-report')];
  const tabs = [...document.querySelectorAll('[data-select-loan]')];
  const toc = document.getElementById('scheme-toc');
  const input = document.getElementById('unified-search');
  const scope = document.getElementById('search-scope');
  const results = document.getElementById('unified-results');
  const grid = document.getElementById('unified-result-links');
  const clear = document.getElementById('clear-unified-search');
  const menu = document.querySelector('.u-toc');
  const narrow = window.matchMedia('(max-width: 980px)');
  let selected = 1;
  let observer;
  const escape = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const searchable = data.fields.map(field => ({...field, text: Object.values(field).filter(v => typeof v === 'string').join(' ').toLowerCase()}));

  function search() {
    const query = input.value.trim().toLowerCase();
    clear.hidden = !query;
    results.hidden = !query;
    document.getElementById('search-scope-note').textContent = scope.value === 'all' ? '全部方案共 335 项' : `当前方案共 ${data.counts[selected]} 项`;
    if (!query) { grid.replaceChildren(); document.getElementById('unified-result-count').textContent = ''; return; }
    const pool = searchable.filter(f => scope.value === 'all' || f.scheme === selected);
    const tokens = query.split(/\s+/);
    const hits = pool.filter(f => tokens.every(t => f.text.includes(t)));
    document.getElementById('unified-result-count').textContent = hits.length ? `找到 ${hits.length} 项字段（搜索范围 ${pool.length} 项）` : '没有匹配字段，请尝试其他关键词或切换搜索范围。';
    grid.innerHTML = hits.map(f => `<a class="u-result" href="#${escape(f.anchor)}"><b>${f.scheme}次贷款 · ${escape(f.id)}</b>${escape(f.field)}${f.sql_field || f.db_field ? `<code>${escape(f.sql_field || f.db_field)}</code>` : ''}<small>${escape(f.major)}${f.minor ? ' · ' + escape(f.minor) : ''}</small></a>`).join('');
  }

  function observe() {
    if (observer) observer.disconnect();
    if (!('IntersectionObserver' in window)) return;
    observer = new IntersectionObserver(entries => {
      const visible = entries.filter(e => e.isIntersecting).sort((a, b) => a.boundingClientRect.top - b.boundingClientRect.top);
      if (!visible.length) return;
      const id = visible[0].target.id;
      toc.querySelectorAll('a').forEach(a => a.setAttribute('aria-current', a.hash === '#' + id ? 'location' : 'false'));
    }, {rootMargin: '-125px 0px -60% 0px', threshold: 0});
    data.navigation[selected].forEach(item => { const el = document.getElementById(item.id); if (el) observer.observe(el); });
  }

  function select(n) {
    selected = n;
    reports.forEach(report => { report.hidden = Number(report.dataset.loan) !== n; });
    tabs.forEach(tab => tab.setAttribute('aria-current', Number(tab.dataset.selectLoan) === n ? 'page' : 'false'));
    document.getElementById('toc-scheme-label').textContent = `${n}次贷款 · ${data.counts[n]}项特征`;
    document.getElementById('breadcrumb-scheme').textContent = `${n}次贷款`;
    toc.innerHTML = data.navigation[n].map(item => `<a class="u-toc-link${item.level ? ' u-toc-sub' : ''}" href="#${escape(item.id)}">${escape(item.label)}</a>`).join('');
    document.title = `${n}次贷款 · ${data.counts[n]}项特征 | 循环贷用户特征口径总报告`;
    search();
    observe();
  }

  function route(scroll) {
    let hash;
    try { hash = decodeURIComponent(location.hash.slice(1)); } catch { hash = ''; }
    const match = /^loan-([1-5])(?:-|$)/.exec(hash);
    if (match && Number(match[1]) !== selected) select(Number(match[1]));
    if (!scroll || !hash) return;
    requestAnimationFrame(() => {
      const target = /^loan-[1-5]$/.test(hash) ? document.querySelector('.u-workspace') : document.getElementById(hash);
      if (target && !target.closest('[hidden]')) target.scrollIntoView({block: 'start', behavior: 'auto'});
    });
  }

  input.addEventListener('input', search);
  scope.addEventListener('change', search);
  clear.addEventListener('click', () => { input.value = ''; search(); input.focus(); });
  input.addEventListener('keydown', event => { if (event.key === 'Escape') { input.value = ''; search(); } });
  window.addEventListener('hashchange', () => route(true));
  toc.addEventListener('click', event => { if (event.target.closest('a') && narrow.matches) menu.open = false; });
  tabs.forEach(tab => tab.addEventListener('click', event => {
    event.preventDefault();
    if (location.hash === tab.hash) route(true);
    else location.hash = tab.hash;
  }));
  tabs.forEach((tab, index) => tab.addEventListener('keydown', event => {
    let next;
    if (event.key === 'ArrowRight') next = (index + 1) % tabs.length;
    if (event.key === 'ArrowLeft') next = (index + tabs.length - 1) % tabs.length;
    if (event.key === 'Home') next = 0;
    if (event.key === 'End') next = tabs.length - 1;
    if (next !== undefined) { event.preventDefault(); tabs[next].focus(); tabs[next].click(); }
  }));
  narrow.addEventListener('change', () => { menu.open = !narrow.matches; });
  menu.open = !narrow.matches;
  select(1);
  route(Boolean(location.hash));
})();
