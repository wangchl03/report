# user_behavior_track 字段与统计口径说明

表名：`wangchuanliang.user_behavior_track` · 58字段 · 字段核验日期：2026-11-18。

## 数据来源

| 层级 | 来源表 | 说明 |
| --- | --- | --- |
| 目标表 | wangchuanliang.user_behavior_track | 用户日聚合表，58字段；一位用户一个业务日期一行。 |
| 直接来源 | wangchuanliang.user_behavior_track_record | 23字段事件明细；本表按 user_id、event_date 汇总。 |
| 上游原始埋点 | ods.user_behavior_data_record | 按现有解析SQL读取；event_time 为实际事件发生的毫秒时间戳。 |
| 上游用户映射 | ods."user" | 按 sequence_id 关联，取业务 user_id；空白关联键及未匹配用户不进入明细。 |
| 行为名称字典 | wangchuanliang.tracking_points | 页面与控件的中文名称参考；用于字段下方的行为注释，不参与日志计数。 |

## 统一统计口径

- **业务时间：** 原始 event_time 转为 America/Belize 时间；active_date 取明细 event_date，不使用入库时间 create_time。
- **统计范围：** 读取 user_id > 0 的明细，排除永久黑名单用户5101518；不区分贷款产品或召回批次。
- **日志计数：** 计数保留源明细每条日志，不做20秒去重；active_status 是条数，不是0/1。当天无明细则不生成用户日记录。
- **编码匹配：** 页面和控件按基础码识别，通常取首个下划线前的部分；访问/输入配对使用完整编码，具体条件见附录。
- **零值与空值：** 已有用户日记录中，无对应行为的计数记0；无合格完整访问的时长为NULL，不补0。
- **业务结果：** 点击提单、还款、结清申请或优惠券确认，仅表示操作日志；实际结果从订单、还款和红包业务表确认。

## 字段解释

下表来源字段均指 `wangchuanliang.user_behavior_track_record`；R1—R4见后文。

### 用户与日期（5项）

| 字段（类型） | 业务含义 | 来源字段 | 统计口径 |
| --- | --- | --- | --- |
| `user_id`<br><sub>行为所属用户</sub><br>bigint | 行为所属的业务用户。 | user_id | 直接取明细user_id，与active_date组成逻辑唯一键。 |
| `active_date`<br><sub>行为发生日期</sub><br>date | 实际行为发生的Belize自然日。 | event_date | 直接取明细event_date；日期按America/Belize划分。 |
| `active_status`<br><sub>当天全部行为日志数</sub><br>bigint | 当天全部明细日志条数，不是0/1活跃标志。 | user_id、event_date | 按用户、日期COUNT(*)；保留原日志行数。 |
| `first_event_time`<br><sub>当天首次行为时间</sub><br>timestamp | 当天最早一条实际事件的时间。 | event_time | 按用户、日期MIN(event_time)。 |
| `last_event_time`<br><sub>当天最后行为时间</sub><br>timestamp | 当天最晚一条实际事件的时间。 | event_time | 按用户、日期MAX(event_time)。 |

### 通用事件（7项）

| 字段（类型） | 业务含义 | 来源字段 | 统计口径 |
| --- | --- | --- | --- |
| `app_start_logs`<br><sub>启动App</sub><br>bigint | 当天启动App的日志条数。 | event_type | 统计 event_type='app_start' 的日志条数。 |
| `page_view_logs`<br><sub>页面进入或离开</sub><br>bigint | 当天页面日志条数，包含进入和离开。 | event_type | 统计 event_type='page_view' 的日志条数。 |
| `element_click_logs`<br><sub>点击页面控件</sub><br>bigint | 当天控件点击日志条数。 | event_type | 统计 event_type='element_click' 的日志条数。 |
| `text_change_logs`<br><sub>编辑输入内容</sub><br>bigint | 当天文本输入变化日志条数，不等于编辑轮次。 | event_type | 统计 event_type='text_change' 的日志条数。 |
| `slider_change_logs`<br><sub>调整滑动条</sub><br>bigint | 当天滑条变化日志条数，不等于完整拖动次数。 | event_type | 统计 event_type='slider_change' 的日志条数。 |
| `switch_change_logs`<br><sub>切换控件开关</sub><br>bigint | 当天开关变化日志条数，不区分打开或关闭。 | event_type | 统计 event_type='switch_change' 的日志条数。 |
| `touch_change_logs`<br><sub>触摸页面控件</sub><br>bigint | 当天触摸日志条数，不等于手势次数。 | event_type | 统计 event_type='touch_change' 的日志条数。 |

### 页面进入与离开（8项）

| 字段（类型） | 业务含义 | 来源字段 | 统计口径 |
| --- | --- | --- | --- |
| `page_entry_logs`<br><sub>进入页面</sub><br>bigint | 当天全部页面进入日志条数。 | event_type、page_type | 统计 event_type='page_view' 且 page_type='page_view_in' 的日志条数。 |
| `page_exit_logs`<br><sub>离开页面</sub><br>bigint | 当天全部页面离开日志条数。 | event_type、page_type | 统计 event_type='page_view' 且 page_type='page_view_out' 的日志条数。 |
| `home_page_entry_logs`<br><sub>进入首页</sub><br>bigint | 当天首页进入日志条数。 | event_type、page_type、page_id | 统计 page_view + page_view_in，且页面基础码匹配附录的日志条数。 |
| `loan_page_entry_logs`<br><sub>进入借款提单页</sub><br>bigint | 当天提单页进入日志条数；还款操作也可能进入该页。 | event_type、page_type、page_id | 统计 page_view + page_view_in，且页面基础码匹配附录的日志条数。 |
| `repayment_page_entry_logs`<br><sub>进入还款或还款详情页</sub><br>bigint | 当天普通还款页及H5还款详情页进入日志条数。 | event_type、page_type、page_id | 统计 page_view + page_view_in，且页面基础码匹配附录的日志条数。 |
| `order_page_entry_logs`<br><sub>进入订单列表或订单详情</sub><br>bigint | 当天已识别订单页进入日志条数。 | event_type、page_type、page_id | 统计 page_view + page_view_in，且页面基础码匹配附录的日志条数。 |
| `coupon_page_entry_logs`<br><sub>进入优惠券列表</sub><br>bigint | 当天优惠券列表页进入日志条数。 | event_type、page_type、page_id | 统计 page_view + page_view_in，且页面基础码匹配附录的日志条数。 |
| `agreement_page_entry_logs`<br><sub>进入协议列表</sub><br>bigint | 当天协议列表页进入日志条数。 | event_type、page_type、page_id | 统计 page_view + page_view_in，且页面基础码匹配附录的日志条数。 |

### 提单与借款操作（18项）

| 字段（类型） | 业务含义 | 来源字段 | 统计口径 |
| --- | --- | --- | --- |
| `loan_submit_clicks`<br><sub>点击借款提交按钮</sub><br>bigint | 当天提单按钮点击日志条数，不代表实际提单成功。 | event_type、element_id | 统计 element_click，且控件基础码匹配附录的日志条数。 |
| `amount_input_editing_logs`<br><sub>编辑弹窗内借款金额</sub><br>bigint | 当天金额输入控件editing日志条数，不读取输入金额。 | event_type、element_id、element_type | 统计 text_change + editing，且控件基础码匹配附录的日志条数。 |
| `amount_slider_changes`<br><sub>滑动调整借款金额</sub><br>bigint | 当天金额滑条变化日志条数。 | event_type、element_id | 统计 slider_change，且控件基础码匹配附录的日志条数。 |
| `amount_tab_clicks`<br><sub>点击固定借款金额选项</sub><br>bigint | 当天固定金额选项点击日志条数。 | event_type、element_id | 统计 element_click，且控件基础码匹配附录的日志条数。 |
| `amount_modify_open_clicks`<br><sub>点击修改借款金额</sub><br>bigint | 当天修改金额入口点击日志条数，不代表已修改金额。 | event_type、element_id | 统计 element_click，且控件基础码匹配附录的日志条数。 |
| `amount_modify_confirm_clicks`<br><sub>点击确认修改金额</sub><br>bigint | 当天修改金额确认按钮点击日志条数。 | event_type、element_id | 统计 element_click，且控件基础码匹配附录的日志条数。 |
| `agreement_view_clicks`<br><sub>点击查看借款协议</sub><br>bigint | 当天借款协议查看按钮点击日志条数。 | event_type、element_id | 统计 element_click，且控件基础码匹配附录的日志条数。 |
| `agreement_switch_changes`<br><sub>勾选或取消借款协议</sub><br>bigint | 当天借款协议开关变化日志条数，不等于同意次数。 | event_type、element_id | 统计 switch_change，且控件基础码匹配附录的日志条数。 |
| `term_entry_clicks`<br><sub>打开借款期限选择</sub><br>bigint | 当天期限选择入口点击日志条数。 | event_type、element_id | 统计 element_click，且控件基础码匹配附录的日志条数。 |
| `term_option_clicks`<br><sub>点击分期期次或产品选项</sub><br>bigint | 当天期次或分期产品选项点击日志条数。 | event_type、element_id | 统计 element_click，且控件基础码匹配附录的日志条数。 |
| `loan_plan_open_clicks`<br><sub>打开提单页还款计划</sub><br>bigint | 当天提单页还款计划打开按钮点击日志条数。 | event_type、element_id | 统计 element_click，且控件基础码匹配附录的日志条数。 |
| `loan_plan_close_clicks`<br><sub>关闭提单页还款计划</sub><br>bigint | 当天提单页还款计划关闭按钮点击日志条数。 | event_type、element_id | 统计 element_click，且控件基础码匹配附录的日志条数。 |
| `purpose_entry_clicks`<br><sub>打开借款用途选择</sub><br>bigint | 当天借款用途入口点击日志条数。 | event_type、element_id | 统计 element_click，且控件基础码匹配附录的日志条数。 |
| `purpose_option_clicks`<br><sub>点击借款用途选项</sub><br>bigint | 当天借款用途选项点击日志条数。 | event_type、element_id | 统计 element_click，且控件基础码匹配附录的日志条数。 |
| `purpose_confirm_clicks`<br><sub>点击确认借款用途</sub><br>bigint | 当天借款用途确认按钮点击日志条数。 | event_type、element_id | 统计 element_click，且控件基础码匹配附录的日志条数。 |
| `purpose_input_editing_logs`<br><sub>编辑其他或自填借款用途</sub><br>bigint | 当天其他或旧版借款用途输入editing日志条数，不读取输入原文。 | event_type、element_id、element_type | 统计 text_change + editing，且控件基础码匹配附录的日志条数。 |
| `loan_coupon_open_clicks`<br><sub>打开提额券或息费券选择</sub><br>bigint | 当天借款优惠券打开按钮点击日志条数。 | event_type、element_id | 统计 element_click，且控件基础码匹配附录的日志条数。 |
| `loan_coupon_confirm_clicks`<br><sub>点击确认提额券或息费券</sub><br>bigint | 当天借款优惠券确认按钮点击日志条数，不代表实际用券。 | event_type、element_id | 统计 element_click，且控件基础码匹配附录的日志条数。 |

### 还款、结清与对比（6项）

| 字段（类型） | 业务含义 | 来源字段 | 统计口径 |
| --- | --- | --- | --- |
| `repayment_entry_clicks`<br><sub>点击还款入口</sub><br>bigint | 当天还款入口点击日志条数，不代表实际还款。 | event_type、element_id | 统计 element_click，且控件基础码匹配附录的日志条数。 |
| `repayment_plan_clicks`<br><sub>点击已有订单还款计划</sub><br>bigint | 当天还款侧还款计划点击日志条数。 | event_type、element_id | 统计 element_click，且控件基础码匹配附录的日志条数。 |
| `early_settlement_entry_clicks`<br><sub>点击提前结清入口</sub><br>bigint | 当天提前结清入口点击日志条数。 | event_type、element_id | 统计 element_click，且控件基础码匹配附录的日志条数。 |
| `early_settlement_apply_clicks`<br><sub>点击申请提前结清</sub><br>bigint | 当天提前结清申请按钮点击日志条数，不代表实际结清。 | event_type、element_id | 统计 element_click，且控件基础码匹配附录的日志条数。 |
| `comparison_confirm_clicks`<br><sub>确认借款优势对比弹窗</sub><br>bigint | 当天优势对比弹窗确认点击日志条数。 | event_type、element_id | 统计 element_click，且控件基础码匹配附录的日志条数。 |
| `comparison_close_clicks`<br><sub>关闭借款优势对比弹窗</sub><br>bigint | 当天优势对比弹窗关闭点击日志条数。 | event_type、element_id | 统计 element_click，且控件基础码匹配附录的日志条数。 |

### 其他事件（1项）

| 字段（类型） | 业务含义 | 来源字段 | 统计口径 |
| --- | --- | --- | --- |
| `other_event_type_logs`<br><sub>其他事件类型日志数</sub><br>bigint | 当天七种已知事件类型以外的日志条数。 | event_type | 统计七种通用 event_type 之外的日志条数。 |

### 金额输入轮次与质量（2项）

| 字段（类型） | 业务含义 | 来源字段 | 统计口径 |
| --- | --- | --- | --- |
| `amount_input_rounds`<br><sub>借款金额输入轮次</sub><br>bigint | 当天有实际编辑日志的金额输入轮次。 | event_type、element_type、element_id、device_key、element_start_time、event_unix | 按R1对有效金额编辑分组后计数；同轮跨日，在各编辑日分别计1。 |
| `amount_input_unpairable_logs`<br><sub>无法归入输入轮次的金额编辑</sub><br>bigint | 当天金额编辑中缺设备、缺完整控件或输入起点不合法的日志条数。 | event_type、element_type、element_id、device_key、element_start_time、event_unix | 金额editing日志中input_pairable=0的行数；不计入R1轮次。 |

### 页面访问、时长与质量（11项）

| 字段（类型） | 业务含义 | 来源字段 | 统计口径 |
| --- | --- | --- | --- |
| `completed_page_visits`<br><sub>同日完整进入并离开页面</sub><br>bigint | 当天同时有唯一进入和唯一离开、且时间有效的页面访问组数。 | event_type、page_type、device_key、page_id、page_view_in_time、event_unix | 按R2配对、R3分类，统计完整访问组数。 |
| `completed_loan_page_visits`<br><sub>同日完整进入并离开提单页</sub><br>bigint | 当天完整页面访问中属于提单页的访问组数。 | event_type、page_type、device_key、page_id、page_view_in_time、event_unix | 按R2配对、R3分类，仅统计提单页的完整访问组数。 |
| `completed_page_duration_seconds`<br><sub>完整页面访问总时长（秒）</sub><br>double precision | 当天全部完整页面访问的起止跨度之和，单位秒。 | event_type、page_type、device_key、page_id、page_view_in_time、event_unix | 对该类完整访问按R4求和；无该类完整访问为NULL。 |
| `completed_loan_page_duration_seconds`<br><sub>完整提单页访问总时长（秒）</sub><br>double precision | 当天完整提单页访问的起止跨度之和，单位秒。 | event_type、page_type、device_key、page_id、page_view_in_time、event_unix | 对该类完整访问按R4求和；无该类完整访问为NULL。 |
| `completed_other_page_duration_seconds`<br><sub>完整非提单页访问总时长（秒）</sub><br>double precision | 当天完整非提单页访问的起止跨度之和，单位秒。 | event_type、page_type、device_key、page_id、page_view_in_time、event_unix | 对该类完整访问按R4求和；无该类完整访问为NULL。 |
| `page_visits_without_entry`<br><sub>页面访问缺少进入日志</sub><br>bigint | 按R3优先级归为当天缺进入记录的访问组数。 | event_type、page_type、device_key、page_id、page_view_in_time、event_unix | 按R3互斥优先级，统计visit_status=missing_entry的访问组数；无此类访问为0。 |
| `page_visits_without_exit`<br><sub>页面访问缺少离开日志</sub><br>bigint | 按R3优先级归为当天缺离开记录的访问组数。 | event_type、page_type、device_key、page_id、page_view_in_time、event_unix | 按R3互斥优先级，统计visit_status=missing_exit的访问组数；无此类访问为0。 |
| `page_visits_ambiguous`<br><sub>同次页面访问起止记录不唯一</sub><br>bigint | 按R3优先级归为同一访问有多个不同进入或离开时间的组数。 | event_type、page_type、device_key、page_id、page_view_in_time、event_unix | 按R3互斥优先级，统计visit_status=ambiguous的访问组数；无此类访问为0。 |
| `page_visits_cross_day`<br><sub>页面进入起点与日志日期跨日</sub><br>bigint | 按R3优先级归为页面起点日期与日志日期不同的访问组数。 | event_type、page_type、device_key、page_id、page_view_in_time、event_unix | 按R3互斥优先级，统计visit_status=cross_day的访问组数；无此类访问为0。 |
| `page_visits_invalid_timing`<br><sub>页面进入或离开时间异常</sub><br>bigint | 按R3优先级归为起点晚于首条日志或离开早于进入的访问组数。 | event_type、page_type、device_key、page_id、page_view_in_time、event_unix | 按R3互斥优先级，统计visit_status=invalid_timing的访问组数；无此类访问为0。 |
| `page_logs_unpairable`<br><sub>缺少配对信息的页面日志</sub><br>bigint | 当天页面进出日志中缺设备、缺完整页面编码或起点无效的日志条数。 | event_type、page_type、device_key、page_id、page_view_in_time、event_unix | 页面进出日志中page_pairable=0的行数；不参与R2配对。 |

## 输入轮次、访问配对与时长

- **R1 金额输入轮次：** 只取金额控件的 text_change + editing；设备和完整控件编码须非空，且 0 < element_start_time ≤ event_unix。按用户、日期、设备、完整 element_id、element_start_time 分组，每组计1轮；跨日轮次在各实际编辑日分别计1轮。
- **R2 页面访问配对：** 只取 page_view 的进入/离开日志，设备与完整 page_id 非空、page_view_in_time > 0。按用户、日期、设备、完整 page_id、page_view_in_time 分组；进入、离开分别按不同 event_unix 数量判断，同时间重复边界只算一个边界。
- **R3 互斥分类顺序：** 依次判定：时间非法 → 跨日 → 多边界歧义 → 缺进入 → 缺离开 → 完整。每组只进入一个类别；缺配对键的日志单独计入 page_logs_unpairable。
- **R4 页面时长：** 只累计同日完整访问：SUM((last_out-page_view_in_time)/1000.0)，单位秒；last_out 为最后离开的 event_unix。可能含后台停留和多设备重叠，表示页面访问跨度。

## 附录：页面与控件筛选条件

`page_base`、`element_base` 通常为完整编码的首个下划线前缀；`page_id` 以 `buxtxlneoozyngzm` 开头时统一为该基础码。下面是现有SQL的条件，不使用旧版 props_id。

中间标志：`input_pairable` 为满足R1的输入；`page_pairable` 为满足R2配对键的页面日志；`visit_status` 为R3的分类结果；`is_loan_page=1` 表示页面基础码为 `xyrsaqxpwmedzlsm` 或 `vdecaucgiowzpoeh`。这些是SQL派生标志，不是明细表实体字段。

| 字段 | 筛选条件 |
| --- | --- |
| `home_page_entry_logs` | `event_type = 'page_view' AND page_base IN ('bzqlgnxzgeepufzi') AND page_type = 'page_view_in'` |
| `loan_page_entry_logs` | `event_type = 'page_view' AND page_base IN ('xyrsaqxpwmedzlsm', 'vdecaucgiowzpoeh') AND page_type = 'page_view_in'` |
| `repayment_page_entry_logs` | `event_type = 'page_view' AND page_base IN ('tnxeadfhnoowyjot', 'dzjhiykdjkfvtqqt') AND page_type = 'page_view_in'` |
| `order_page_entry_logs` | `event_type = 'page_view' AND page_base IN ('benzjkekbsvpivii', 'zadxcgfjwhkfvcdx') AND page_type = 'page_view_in'` |
| `coupon_page_entry_logs` | `event_type = 'page_view' AND page_base IN ('iqsvfjcxwpqtsrbj') AND page_type = 'page_view_in'` |
| `agreement_page_entry_logs` | `event_type = 'page_view' AND page_base IN ('ncdewxroajlsexrt') AND page_type = 'page_view_in'` |
| `loan_submit_clicks` | `event_type = 'element_click' AND element_base IN ('hfmgyiwihoavrqzv', 'udopwuxjursbmvcm')` |
| `amount_input_editing_logs` | `event_type = 'text_change' AND element_base IN ('gbyukfclsrdmxaon') AND element_type = 'editing'` |
| `amount_slider_changes` | `event_type = 'slider_change' AND element_base IN ('jrocyutivyeqdxrx')` |
| `amount_tab_clicks` | `event_type = 'element_click' AND element_base IN ('xhwhgrqsxqkfwpoj')` |
| `amount_modify_open_clicks` | `event_type = 'element_click' AND element_base IN ('gwexsotywwgsvrgv')` |
| `amount_modify_confirm_clicks` | `event_type = 'element_click' AND element_base IN ('saynozmunkdceoya')` |
| `agreement_view_clicks` | `event_type = 'element_click' AND element_base IN ('oflwqlzkgvyvhltd', 'gwhhjdfmvnpjaouh')` |
| `agreement_switch_changes` | `event_type = 'switch_change' AND element_base IN ('rxwqrtzvjyfydxla', 'cmnorubwcltxjbrf')` |
| `term_entry_clicks` | `event_type = 'element_click' AND element_base IN ('gfelmnelmexljaiv')` |
| `term_option_clicks` | `event_type = 'element_click' AND element_base IN ('zfmdsmjpuslrcchx', 'denkhhpvgqgwethb', 'rdapttngylaiuvth')` |
| `loan_plan_open_clicks` | `event_type = 'element_click' AND element_base IN ('omuwccqjaovwdwyx', 'gemkzaypdtcrwdkg')` |
| `loan_plan_close_clicks` | `event_type = 'element_click' AND element_base IN ('zzzinqtexbgyjniw')` |
| `purpose_entry_clicks` | `event_type = 'element_click' AND element_base IN ('jhljcsppjdgaqzfi', 'zurfrtfnjkzajxzd')` |
| `purpose_option_clicks` | `event_type = 'element_click' AND element_base IN ('wftjhrycnfabaffq', 'jgzhflrnlbsnlxbn')` |
| `purpose_confirm_clicks` | `event_type = 'element_click' AND element_base IN ('dfzucgwykunozmqi', 'okemgtjjfltrigiw')` |
| `purpose_input_editing_logs` | `event_type = 'text_change' AND element_base IN ('ifacdrnrccxemper', 'apsgcizksqamapoh') AND element_type = 'editing'` |
| `loan_coupon_open_clicks` | `event_type = 'element_click' AND element_base IN ('tjmcxmtdjhvszkrg', 'shaiubwligggtrlc', 'ejknnzgmqlepvxuy', 'gbjnaljcxrmlvpwo')` |
| `loan_coupon_confirm_clicks` | `event_type = 'element_click' AND element_base IN ('tpiujbhwafjhokvs', 'dmadzxixvpamlgpg', 'clxghdbhffmbbhyh', 'mpjlvbjrygzfqxvo')` |
| `repayment_entry_clicks` | `event_type = 'element_click' AND element_base IN ('naolqihbzjxkiuna', 'rypqjlovpcdapboi', 'tgzdtqemiiandtbg', 'iswwtuuhkdvzlqrb')` |
| `repayment_plan_clicks` | `event_type = 'element_click' AND element_base IN ('ntbnfjkdgejtgorq', 'ngbqkgoxefwovflp', 'fhmssjksrsgmlrab', 'jinymtemwmbtexio')` |
| `early_settlement_entry_clicks` | `event_type = 'element_click' AND element_base IN ('hjhyfnwygrrmmbfc', 'hhckxcemjmhnrrvb', 'wygwowvhpxyurins')` |
| `early_settlement_apply_clicks` | `event_type = 'element_click' AND element_base IN ('lmeglertzqhylnmv')` |
| `comparison_confirm_clicks` | `event_type = 'element_click' AND element_base IN ('hdyhzkeafxctlbrb', 'brvaadhytccdqbgt')` |
| `comparison_close_clicks` | `event_type = 'element_click' AND element_base IN ('jyyfzhlcsedgpohi', 'zyudysagbeyheldy')` |
| `amount_input_rounds` | `event_type = 'text_change' AND element_type = 'editing' AND element_base = 'gbyukfclsrdmxaon' AND input_pairable = 1` |
| `amount_input_unpairable_logs` | `event_type = 'text_change' AND element_type = 'editing' AND element_base = 'gbyukfclsrdmxaon' AND input_pairable = 0` |
| `completed_loan_page_visits` | `event_type = 'page_view' AND page_type IN ('page_view_in', 'page_view_out') AND page_pairable = 1；按R2配对后 visit_status = 'complete' AND page_base IN ('xyrsaqxpwmedzlsm', 'vdecaucgiowzpoeh')` |
| `completed_loan_page_duration_seconds` | `event_type = 'page_view' AND page_type IN ('page_view_in', 'page_view_out') AND page_pairable = 1；按R2配对后 visit_status = 'complete' AND page_base IN ('xyrsaqxpwmedzlsm', 'vdecaucgiowzpoeh')` |
| `completed_other_page_duration_seconds` | `event_type = 'page_view' AND page_type IN ('page_view_in', 'page_view_out') AND page_pairable = 1；按R2配对后 visit_status = 'complete' AND page_base NOT IN ('xyrsaqxpwmedzlsm', 'vdecaucgiowzpoeh')` |

## 核验依据

- 已对照数据库当前58个字段、类型及字段注释。
- 中文行为注释结合建表注释与本地留存的 tracking_points 页面、控件释义逐项核对。
- 日聚合口径：`01_user_behavior_track_完整建表与按月导入_20251101-20261028.sql`（与月度计算模板一致）。
- 上游解析口径：`user_behavior_track_record_增量更新_今天及前3天.sql`。
