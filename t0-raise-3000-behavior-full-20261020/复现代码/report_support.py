"""Dark report presentation and verbatim, locally readable source appendix.

This module changes presentation only. It does not train, score or query data.
The palette follows the earlier T0 model reports.
"""
from pathlib import Path
from urllib.parse import quote
import hashlib
import html


DARK_CSS = """
:root{color-scheme:dark;--bg:#061b2a;--panel:#0b2a40;--paper:#082235;--line:#21465a;--ink:#d9e7ef;--muted:#9bb5c7;--cyan:#43c7e7;--green:#64dcae;--amber:#ffc26b;--accent:#43c7e7}
html{scroll-behavior:smooth}body{background:var(--bg);color:var(--ink)}
header{background:#082235;color:var(--ink);border-bottom:1px solid var(--line)}
header p,header .eyebrow,.note,.muted,small,footer{color:var(--muted)}
h1{color:#f3faff}h2{color:var(--cyan)}h3{color:var(--amber)}
section,.hero{background:var(--paper);border:1px solid var(--line);box-shadow:none}
.hero{border-left:5px solid var(--cyan)}
nav{background:var(--bg);border-color:var(--line)}
a,summary{color:var(--cyan)}a:hover{text-decoration:underline;color:#86e4f5}
.badge{background:var(--panel);color:var(--green);border:1px solid var(--line)}
.card,.journey span,.timeline div,.downloads a{background:var(--panel);border-color:var(--line)}
.card{border-top-color:var(--cyan)}.card strong{color:var(--green)}
.callout{background:#163348;border-left-color:var(--amber)}
table th{background:#123b51;color:var(--cyan)}
table th,table td{border-bottom-color:var(--line)}
tbody tr:nth-child(even){background:#0b2a40}tbody tr:hover{background:#10364b}
input,select,button{background:var(--panel);color:var(--ink);border:1px solid #3e6a82}
input::placeholder{color:var(--muted);opacity:1}button:hover{border-color:var(--cyan)}
input:focus-visible,select:focus-visible,button:focus-visible,summary:focus-visible,a:focus-visible{outline:2px solid var(--cyan);outline-offset:3px}
code{background:#0b2a40;color:#b3e4f5;border-radius:3px}
pre{background:#041725;color:#d1e7f1;border:1px solid var(--line);border-radius:9px}
pre code{background:transparent;padding:0;white-space:pre;color:inherit}
details{border-color:var(--line)}.figure{background:var(--paper)}
#code-appendix{scroll-margin-top:80px}
.source-controls{display:flex;gap:10px;flex-wrap:wrap;align-items:center;margin:20px 0}
.source-controls input{flex:1;min-width:220px;width:auto;max-width:none}
.source-controls select,.source-controls button{font:inherit;padding:8px 12px;border-radius:6px;cursor:pointer}
.source-controls label{font-size:14px;color:var(--muted)}
.source-count{font-size:14px;color:var(--muted)}
.source-file{border:1px solid var(--line);border-radius:9px;padding:13px 16px;margin:14px 0;background:#0b2a40}
.source-file summary{overflow-wrap:anywhere;cursor:pointer;font-weight:600}
.source-file .source-lang{font:12px ui-monospace,Menlo,monospace;color:var(--green);border:1px solid var(--line);border-radius:4px;padding:3px 7px;margin-right:8px}
.source-meta{display:flex;gap:12px;flex-wrap:wrap;font-size:12px;color:var(--muted);margin:10px 0}
.source-meta .source-hash{overflow-wrap:anywhere}
.source-file pre{margin:10px 0 0;max-height:720px;overflow:auto;padding:18px;font:12.5px/1.65 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;tab-size:4}
.source-file[hidden]{display:none!important}
.source-file code{white-space:pre;overflow-wrap:normal;word-break:normal}
@media(max-width:700px){.source-file{padding:12px}.source-controls input{min-width:100%}.source-file pre{font-size:12px}}
@media print{html{color-scheme:light}body{color:#172f40;background:white}section,.hero,.card,.journey span,.timeline div,.downloads a,.source-file{color:#172f40;background:white}h1,h2,h3,a,summary,header p,header .eyebrow{color:#172f40}header{background:white;color:#172f40}table th{background:#edf3f6;color:#172f40}tbody tr:nth-child(even){background:#f4f7f9}pre,code{color:#172f40;background:#f4f7f9}.source-controls{display:none}.source-file pre{max-height:none}}
"""


APPENDIX_JS = """
(()=>{
  const root=document.getElementById('code-appendix');
  const search=document.getElementById('sourceSearch');
  const language=document.getElementById('sourceLanguage');
  const files=Array.from(root.querySelectorAll('.source-file'));
  const count=document.getElementById('sourceCount');
  function filter(){
    const q=search.value.trim().toLowerCase(),lang=language.value;
    let visible=0;
    files.forEach(file=>{
      file.hidden=!(file.dataset.source.toLowerCase().includes(q)&&(!lang||file.dataset.language===lang));
      if(!file.hidden)visible++;
    });
    count.textContent='显示 '+visible+' / '+files.length+' 个完整代码文件';
  }
  search.addEventListener('input',filter);
  language.addEventListener('change',filter);
  document.getElementById('sourceExpand').addEventListener('click',()=>files.forEach(file=>{if(!file.hidden)file.open=true;}));
  document.getElementById('sourceCollapse').addEventListener('click',()=>files.forEach(file=>file.open=false));
  filter();
})();
"""


def configure_dark_plots(plt):
    """Set readable dark figure/axis/text colors before creating figures."""
    plt.rcParams.update({
        'figure.facecolor': '#082235', 'axes.facecolor': '#082235',
        'savefig.facecolor': '#082235', 'text.color': '#d9e7ef',
        'axes.labelcolor': '#d9e7ef', 'axes.titlecolor': '#d9e7ef',
        'xtick.color': '#9bb5c7', 'ytick.color': '#9bb5c7',
        'axes.edgecolor': '#45677b', 'grid.color': '#6c93a8',
        'legend.facecolor': '#0b2a40', 'legend.edgecolor': '#21465a',
        'legend.labelcolor': '#d9e7ef',
    })


def finish_report(document, source_files, source_directory):
    """Embed complete, HTML-escaped SQL/Python files with source SHA256.

    source_directory is the report-relative download folder. The caller copies
    these exact source files into that folder when packaging its experiment.
    No generated HTML or raw input data is embedded as source code.
    """
    files = sorted((Path(p) for p in source_files),
                   key=lambda p: (0 if p.suffix == '.sql' else 1, p.name))
    assert files and len({p.name for p in files}) == len(files)
    assert all(p.is_file() and p.suffix in {'.py', '.sql'} for p in files)
    sql_n = sum(p.suffix == '.sql' for p in files)
    py_n = len(files) - sql_n
    parts = ['<section id="code-appendix"><h2>附录：完整SQL与Python代码</h2>',
             f'<p>共 {sql_n} 个SQL文件、{py_n} 个Python文件，包含数据提取、事件与提单标记、行为构造、对比分析、核验及报告生成的实际源文件。以下逐文件完整收录，没有省略代码；可展开阅读或下载原文件。</p>',
             '<p class="muted">SQL保留脚本实际使用的参数占位符，参数由Python绑定。数据库连接沿用原提取脚本的本机配置或环境变量；附录不含连接密码。冻结输入、环境依赖和运行顺序见复现数据包。代码中的工作区路径按原分析保留。</p>',
             '<div class="source-controls"><label for="sourceSearch">代码文件</label><input id="sourceSearch" type="search" placeholder="搜索文件名，例如 train.py 或 daily_query.sql"><label for="sourceLanguage">语言</label><select id="sourceLanguage"><option value="">全部语言</option><option value="sql">SQL</option><option value="python">Python</option></select><button id="sourceExpand" type="button">展开筛选结果</button><button id="sourceCollapse" type="button">全部收起</button></div>',
             f'<p id="sourceCount" class="source-count" aria-live="polite">显示 {len(files)} / {len(files)} 个完整代码文件</p>']
    for i, path in enumerate(files, 1):
        raw = path.read_bytes()
        source = raw.decode('utf-8')
        digest = hashlib.sha256(raw).hexdigest()
        lang = 'sql' if path.suffix == '.sql' else 'python'
        label = 'SQL' if lang == 'sql' else 'Python'
        name = html.escape(path.name, quote=True)
        href = html.escape(quote(source_directory + '/' + path.name), quote=True)
        parts.append(
            f'<details class="source-file" id="source-file-{i:02d}" data-source="{name}" data-language="{lang}" data-sha256="{digest}">'
            f'<summary><span class="source-lang">{label}</span>{name}</summary>'
            f'<div class="source-meta"><span>{len(source.splitlines()):,} 行 · {len(raw):,} 字节</span><a href="{href}" download>下载完整源文件</a><span class="source-hash">SHA256：{digest}</span></div>'
            f'<pre><code class="language-{lang}">{html.escape(source, quote=False)}</code></pre></details>')
    parts.append('</section>')
    assert 'id="code-appendix"' not in document
    head_style_end = document.index('</style>')
    document = document[:head_style_end] + DARK_CSS + document[head_style_end:]
    nav_end = document.index('</nav>')
    document = document[:nav_end] + '<a href="#code-appendix">完整代码附录</a>' + document[nav_end:]
    main_end = document.rindex('</main>')
    return (document[:main_end] + ''.join(parts) + '<script>' + APPENDIX_JS +
            '</script>' + document[main_end:])
