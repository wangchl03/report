T0提额≥3000行为分析简略版

输入analysis.json为原统计冻结汇总，不重新取数或重新计算标签。
复原简略版：python build_brief_report.py --input analysis.json --output-dir ./report_output
需要Python3、numpy及matplotlib；原统计提取脚本另依赖pandas、pyarrow等，完整环境及事件输入见原统计复现包。
当前简略版不包含原始用户级输入；原SQL/统计的完整复算使用原报告所附完整代码数据ZIP。
source SQL保留参数占位符，由Python绑定；不含数据库凭证。
