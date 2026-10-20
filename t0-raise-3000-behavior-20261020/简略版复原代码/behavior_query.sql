-- Read-only parameterized aggregation. Parameters are the saved event arrays.
WITH arrays AS (
 SELECT %(ids)s::bigint[] ids,%(users)s::bigint[] users,
        %(offers)s::double precision[] offers,%(stops)s::double precision[] stops
), indices AS (SELECT generate_subscripts(ids,1) AS i FROM arrays), anchors AS (
 SELECT a.ids[n.i] event_id,a.users[n.i] user_id,a.offers[n.i] offer_epoch,a.stops[n.i] stop_epoch,
        TO_TIMESTAMP(a.offers[n.i]) AT TIME ZONE 'America/Belize' AS offer_time,
        TO_TIMESTAMP(a.stops[n.i]) AT TIME ZONE 'America/Belize' AS stop_time,
        (TO_TIMESTAMP(a.offers[n.i]) AT TIME ZONE 'America/Belize')::date AS offer_date
 FROM arrays a CROSS JOIN indices n
), first_app AS (
 SELECT a.event_id,MIN(o.apply_time) AS first_app_time
 FROM anchors a LEFT JOIN wangchuanliang.order_loan_f_v2_copy o
  ON o.user_id=a.user_id AND o.apply_time>=a.offer_time AND o.apply_time<a.stop_time
  AND o.user_id=ANY(%(users)s::bigint[])
  AND o.apply_date>=%(month_start)s AND o.apply_date<%(month_end_plus8)s
 GROUP BY a.event_id
), attributed AS (
 SELECT a.event_id,a.user_id,a.offer_epoch,a.stop_epoch,a.offer_date,a.offer_time,a.stop_time,
        p.first_app_time,e.event_type,e.props_id,e.create_time,e.create_date,
        e.event_start_time,e.event_end_time,e.user_id AS log_user,
        COALESCE(e.create_time::date-a.offer_date,-99) AS relative_day,
        CASE WHEN p.first_app_time IS NULL OR e.create_time<p.first_app_time THEN 1 ELSE 0 END AS before_app,
        CASE WHEN e.event_type='page_view_out' AND e.event_start_time>=1000000000000
                       AND e.event_end_time>=e.event_start_time
                       AND e.event_end_time-e.event_start_time<=86400000
             THEN GREATEST(0.0,
                    LEAST(e.event_end_time/1000.0,
                      EXTRACT(EPOCH FROM ((e.create_time::date+1)::timestamp AT TIME ZONE 'America/Belize')),
                      CASE WHEN e.create_time>=a.offer_time THEN a.stop_epoch ELSE a.offer_epoch END)
                    -GREATEST(e.event_start_time/1000.0,
                      EXTRACT(EPOCH FROM (e.create_time::date::timestamp AT TIME ZONE 'America/Belize')),
                      CASE WHEN e.create_time>=a.offer_time THEN a.offer_epoch ELSE a.offer_epoch-86400*8 END))
             ELSE 0.0 END AS page_seconds,
        CASE WHEN e.event_type='page_view_out' AND (e.event_start_time IS NULL OR e.event_end_time IS NULL
                  OR e.event_start_time<1000000000000 OR e.event_end_time<e.event_start_time
                  OR e.event_end_time-e.event_start_time>86400000) THEN 1 ELSE 0 END AS bad_duration
 FROM anchors a LEFT JOIN first_app p ON p.event_id=a.event_id
 LEFT JOIN wangchuanliang.event_track_record e
   ON e.user_id=a.user_id
  AND e.user_id=ANY(%(users)s::bigint[])
  AND e.create_date>=%(log_start)s AND e.create_date<%(log_end)s
  AND e.create_time>=a.offer_date-7 AND e.create_time<a.stop_time
  AND (e.create_time<a.offer_date OR e.create_time>=a.offer_time)
)
SELECT e.event_id,e.relative_day,
       EXTRACT(EPOCH FROM e.first_app_time AT TIME ZONE 'America/Belize')::double precision AS first_app_epoch,
       COUNT(e.log_user)::bigint AS records,
       SUM(CASE WHEN e.log_user IS NOT NULL AND e.before_app=1 THEN 1 ELSE 0 END)::bigint AS pre_records,
       SUM(e.page_seconds)::double precision AS page_seconds,
       SUM(CASE WHEN e.before_app=1 THEN e.page_seconds ELSE 0 END)::double precision AS pre_page_seconds,
       SUM(CASE WHEN e.props_id IN ('Loan_newpage','Loan_newpage_select') THEN e.page_seconds ELSE 0 END)::double precision AS loan_page_seconds,
       SUM(CASE WHEN e.before_app=1 AND e.props_id IN ('Loan_newpage','Loan_newpage_select') THEN e.page_seconds ELSE 0 END)::double precision AS pre_loan_page_seconds,
       SUM(e.bad_duration)::bigint AS bad_duration_records,
       SUM(CASE WHEN e.log_user IS NOT NULL AND e.create_time::date<>e.create_date THEN 1 ELSE 0 END)::bigint AS date_mismatch_records,
       MIN(CASE WHEN e.event_type='page_view_in' AND e.props_id IN ('Loan_newpage','Loan_newpage_select')
                THEN EXTRACT(EPOCH FROM e.create_time AT TIME ZONE 'America/Belize') END)::double precision AS first_page_epoch,
       SUM(CASE WHEN e.event_type='page_view_in' AND e.props_id IN ('Loan_newpage','Loan_newpage_select') THEN 1 ELSE 0 END)::bigint AS newpage,
       SUM(CASE WHEN (e.event_type='page_view_in' AND e.props_id IN ('Loan_newpage','Loan_newpage_select')) AND e.before_app=1 THEN 1 ELSE 0 END)::bigint AS pre_newpage,
       SUM(CASE WHEN e.props_id IN ('amount_modification','loan_form_loan_amount_selectionn_new','loan_form_loan_amount_selectionn_new_select') THEN 1 ELSE 0 END)::bigint AS amount,
       SUM(CASE WHEN (e.props_id IN ('amount_modification','loan_form_loan_amount_selectionn_new','loan_form_loan_amount_selectionn_new_select')) AND e.before_app=1 THEN 1 ELSE 0 END)::bigint AS pre_amount,
       SUM(CASE WHEN e.props_id IN ('loan_form_term_selection_new','loan_form_term_selection_new_select') THEN 1 ELSE 0 END)::bigint AS term,
       SUM(CASE WHEN (e.props_id IN ('loan_form_term_selection_new','loan_form_term_selection_new_select')) AND e.before_app=1 THEN 1 ELSE 0 END)::bigint AS pre_term,
       SUM(CASE WHEN e.props_id IN ('Loan_contract_newdetails','Loan_contract_newdetails_select') THEN 1 ELSE 0 END)::bigint AS contract,
       SUM(CASE WHEN (e.props_id IN ('Loan_contract_newdetails','Loan_contract_newdetails_select')) AND e.before_app=1 THEN 1 ELSE 0 END)::bigint AS pre_contract,
       SUM(CASE WHEN e.props_id IN ('Loan_plan_newdetails','Loan_plan_newdetails_select') THEN 1 ELSE 0 END)::bigint AS plan,
       SUM(CASE WHEN (e.props_id IN ('Loan_plan_newdetails','Loan_plan_newdetails_select')) AND e.before_app=1 THEN 1 ELSE 0 END)::bigint AS pre_plan,
       SUM(CASE WHEN e.props_id IN ('Loan_purpose_newdetails','Loan_purpose_newdetails_select') THEN 1 ELSE 0 END)::bigint AS purpose,
       SUM(CASE WHEN (e.props_id IN ('Loan_purpose_newdetails','Loan_purpose_newdetails_select')) AND e.before_app=1 THEN 1 ELSE 0 END)::bigint AS pre_purpose,
       SUM(CASE WHEN e.props_id IN ('Loan_newconfirm','Loan_newconfirm_select') THEN 1 ELSE 0 END)::bigint AS confirm,
       SUM(CASE WHEN (e.props_id IN ('Loan_newconfirm','Loan_newconfirm_select')) AND e.before_app=1 THEN 1 ELSE 0 END)::bigint AS pre_confirm,
       SUM(CASE WHEN e.props_id IN ('Order_coupons_back','Order_coupons_back_select','Order_coupons_confirm','Order_coupons_confirm_select','Order_coupons_page','Order_coupons_page_select') THEN 1 ELSE 0 END)::bigint AS coupon,
       SUM(CASE WHEN (e.props_id IN ('Order_coupons_back','Order_coupons_back_select','Order_coupons_confirm','Order_coupons_confirm_select','Order_coupons_page','Order_coupons_page_select')) AND e.before_app=1 THEN 1 ELSE 0 END)::bigint AS pre_coupon,
       SUM(CASE WHEN e.props_id IN ('ProductComparison_page','ProductComparison_page_close','ProductComparison_page_confirm') THEN 1 ELSE 0 END)::bigint AS comparison,
       SUM(CASE WHEN (e.props_id IN ('ProductComparison_page','ProductComparison_page_close','ProductComparison_page_confirm')) AND e.before_app=1 THEN 1 ELSE 0 END)::bigint AS pre_comparison
FROM attributed e GROUP BY e.event_id,e.relative_day,e.first_app_time ORDER BY e.event_id,e.relative_day;