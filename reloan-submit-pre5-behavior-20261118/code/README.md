# 续贷确认提单前5行为：完整复现代码

统计期为2026年1月1日至11月15日（America/Belize）。行为和订单表均只读，不建中间表，不执行业务数据修改。

## 文件

- `01_完整只读统计.sql`：完整PGSQL，可直接复制到客户端执行。默认统计1月；改顶部params的起止时间可统计其他月。包含全部中文行为映射、原始/剔除触摸两种mode、全部路径、5个位置分布、耗时分布、质量统计，无Top截断。
- `02_全期用户订单去重核对.sql`：完整期间点击、用户、订单及关联质量核对；月度去重用户数和订单数不能相加代替全期去重数。
- `run_readonly.py`：按月执行01并缓存结果，随后执行02。使用标准PG环境变量连接，无本机目录和凭据依赖。
- `summarize.py`：汇总11个月结果，核对总量，输出`statistics_result.json`。该文件的高频路径展示前30项，全部路径仍完整保存在各月`compact_YYYYMM.json`内。
- `report_facts.py`：从月度完整路径重新汇总报告事实，生成`content_facts.json`；金额行为使用最新五项并集（editing、滑动、固定选项、打开修改、确认修改），不修改历史宽口径结果；耗时仅在完整5条非触摸样本中计算。`summarize.py`会自动调用。
- `tracking_points_snapshot.json`：本次解析所用埋点字典快照（517行）。SQL已内置最终映射，运行时不需扫描tracking_points，也不受字典后续改名影响。
- `label_codes.json`：原计算程序使用的597个行为编号及中文映射；01已将编号替换为中文，不需要额外解码。

## 运行

使用Python 3.10+。安装依赖后，在本机配置`PGHOST`、`PGPORT`、`PGDATABASE`、`PGUSER`、`PGPASSWORD`、`PGSSLMODE`等标准PG连接环境变量，或使用受保护的`.pgpass`。不要把密码写入本代码包。

```sh
python3 -m pip install -r requirements.txt
python3 run_readonly.py --dws
python3 summarize.py
```

普通PostgreSQL去掉`--dws`；该选项仅在DWS中设置`query_dop=1`。默认结果写入同目录`results/`，每月成功结果原子保存，中断后重跑会复用已完成月份。需要重算现有月份时加`--force`。可通过`--out`指定取数目录，再用`summarize.py --data-dir 目录`对应汇总。

两种SQL均为只读SELECT；Python额外设置只读REPEATABLE READ事务、Belize时区、64MB work_mem及10分钟语句超时。各月份独立事务，不声明全期共用数据库快照。复现时源表若已变化，结果也会变化。

## 固定统计口径

1. 确认点击为`event_type='element_click'`，控件基础码`hfmgyiwihoavrqzv`/`udopwuxjursbmvcm`。每次点击均统计；同一用户同毫秒日志用click_weight保留次数。
2. 通过user_id匹配点击后`[T,T+24小时]`内首笔全类型实际提单，再判断`loan_type='reloan'`；不预筛续贷再找首笔，不要求放款、审批或当前订单状态。埋点无serial_id，属于时间关联。
3. 前序为同一用户`[T−1小时,T)`的最近5条；不足5条不补齐。允许跨页面，凌晨1点前可自然跨日，其他时点滚动1小时不会跨日。
4. mode=0保留原始日志；mode=1先排除touch_change，再取最近5条，其他重复不合并。p1最近、p5最早，展示按p5→p4→p3→p2→p1→确认提单。
5. 同刻不同中文行为记为“同刻并列（顺序未知）”，不强行排序；第5条的同刻边界保留整组判定。完整有序5步路径排除不足5条或并列无法排序的记录，份额仍以全部点击数为分母。
6. 通用触摸无具体控件信息；“启动App”连续日志不直接等同多次独立启动；“勾选协议”按已确认element_value=1解释，0为取消。
7. 黑名单用户5101518排除。event_time已是Belize业务时间，不再转换。页面、控件按本次冻结映射解析。

## 结果行

`grouping_code`：3完整路径；63/95/111/119/123分别为倒数第1/2/3/4/5条；125前序跨度；126最近行为距离；127总体。每种分组内`clicks`合计均等于对应mode总体。

`clicks`为加权点击数，`users`为本次SQL范围的去重用户数，`distinct_orders`为去重关联订单数；三者不可混用。`complete5`为可找到5条的点击数，`ordered_complete5`为其中无同刻不同类别并列的点击数；`ambiguous_clicks`和`boundary_clicks`用于质量核验。`span_seconds`汇总为最早选中行为至点击的秒差，`nearest_seconds`用于最近行为距离分档。

`02`按全期直接去重；不要将月度、路径或位置分组中的去重用户/订单数相加。高频路径和行为出现率属于已关联续贷提单队列的描述，不直接代表召回增量或因果效果。
