T0提额≥3000用户行为分析：完整版网页复原包

包含完整SQL/Python源代码、冻结汇总结果、图表标签清单及环境依赖。
不包含用户/事件明细缓存。

离线复原报告：
1. 安装 requirements.txt 中的依赖。
2. 在本目录执行：
   mkdir -p replay_output
   T0_BEHAVIOR_OUTPUT_DIR="$PWD/replay_output" python3 build_report.py

重新提取并计算事件级统计需访问原始数据库，依次参考 extract_cohorts.py、extract_behavior.py、analyze.py；连接参数通过 DB_HOST、DB_PORT、DB_NAME、DB_USER、DB_PASSWORD 配置。
package_and_verify.py 为原本地完整缓存核验脚本，需原始缓存与工作簿核验输入，不能仅用本网页包直接运行。
