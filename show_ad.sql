-- SELECT campaign_name, SUM(event_revenue_usd)/ COALESCE(COUNT(*),1) AS profit_per_one_show, COUNT(*) AS qnt -- Компанії, що приносять найбільше прибутку на один перегляд
-- FROM test_app_dataset.ad_revenue_raw
-- GROUP BY campaign_name
-- HAVING qnt > 10
-- ORDER BY SUM(event_revenue_usd)/ COALESCE(COUNT(*),1) DESC
-- LIMIT 20;
--
SELECT campaign_name, AVG(aoa_shown_before_paywall) AS needed_shows, AVG(time_to_paywall) AS time_needed,
       AVG(click_to_pay_time) AS needed_time_transaction,
       AVG(actions_before_paywall) AS actions_before_paywall,
       COUNT(*) AS qnt -- -- Ефективність середнього показу по компаніям
FROM test_app_dataset.ad_revenue_raw
WHERE aoa_shown_before_paywall <> 0
GROUP BY campaign_name
HAVING qnt > 10
ORDER BY AVG(aoa_shown_before_paywall) ASC
LIMIT 20;


-- SELECT ad_group_id, COUNT(DISTINCT campaign_id) AS campaign_id_cnt -- є ієрархія, проте переглядати потрібно по айді, адже назви групп в різних кампаніях повторюются
--   FROM test_app_dataset.ad_revenue_raw
--   GROUP BY ad_group_id
--   HAVING campaign_id_cnt <> 1;

SELECT DISTINCT(event_name) -- які впринципі є події
FROM test_app_dataset.in_app_events_report
LIMIT 20;

SELECT DISTINCT (carrier)
FROM test_app_dataset.ad_revenue_raw;


-- Дослідимо вплив продемонстрованих кампаній на користувача, чи є роздратування
WITH churn_events AS ( -- фільтруємо негативні події
  SELECT
    COALESCE(NULLIF(advertising_id, ''), firebase_analytic_app_id) AS user_key,
    timestamp AS churn_time,
    ROW_NUMBER() OVER () AS churn_event_id
  FROM test_app_dataset.in_app_events_report
  WHERE event_name IN ('trial_canceled', 'trial_churned', 'subscription_churned')
),
exposures AS (
  SELECT -- об'єднуємо таблиці, кожній негативній дії шукаємо рекламу, що їй упереджувало
    c.churn_event_id,
    a.creative_id,
    a.ad_format,
    COUNT(*) OVER (PARTITION BY c.churn_event_id) AS exposures_before_churn
  FROM churn_events c
  JOIN test_app_dataset.ad_revenue_raw a
    ON COALESCE(NULLIF(a.advertising_id, ''), a.firebase_analytic_app_id) = c.user_key
   AND a.timestamp BETWEEN TIMESTAMP_SUB(c.churn_time, INTERVAL 7 DAY) AND c.churn_time -- шукаємо по останнім дням для актуальності
),
penalty AS ( -- між усіма кампаніями ділимо штраф у -1 (-0.2, -0.2, ...)
  SELECT creative_id, ad_format, SUM(-1.0 / exposures_before_churn) AS penalty_sum
  FROM exposures
  GROUP BY creative_id, ad_format
),
totals AS ( -- збираємо таблицю для агрегації по креативам
  SELECT creative_id, ad_format, COUNT(*) AS total_shows
  FROM test_app_dataset.ad_revenue_raw
  GROUP BY creative_id, ad_format
)
SELECT p.creative_id, p.ad_format, t.total_shows, p.penalty_sum, -- ділимо сумарний штраф на кількість показів
       p.penalty_sum / t.total_shows AS avg_penalty_per_show
FROM penalty p
JOIN totals t USING (creative_id, ad_format)
WHERE t.total_shows > 500 -- враховуємо лише статистично значимі кампанії
ORDER BY avg_penalty_per_show DESC -- менше = ближче до нуля = краще (менше дратує)
LIMIT 20;

-- аналогічно визначимо компанії, що несуть ризики для користувацького досвіду
-- їх варто переглянути та прийняти рішення по продовженню
WITH churn_events AS (
  SELECT
    COALESCE(NULLIF(advertising_id, ''), firebase_analytic_app_id) AS user_key,
    timestamp AS churn_time,
    ROW_NUMBER() OVER () AS churn_event_id
  FROM test_app_dataset.in_app_events_report
  WHERE event_name IN ('trial_canceled', 'trial_churned', 'subscription_churned')
),
exposures AS (
  SELECT
    c.churn_event_id,
    a.creative_id,
    a.ad_format,
    COUNT(*) OVER (PARTITION BY c.churn_event_id) AS exposures_before_churn
  FROM churn_events c
  JOIN `mornhouse-test-environment.test_app_dataset.ad_revenue_raw` a
    ON COALESCE(NULLIF(a.advertising_id, ''), a.firebase_analytic_app_id) = c.user_key
   AND a.timestamp BETWEEN TIMESTAMP_SUB(c.churn_time, INTERVAL 7 DAY) AND c.churn_time
),
penalty AS (
  SELECT creative_id, ad_format, SUM(-1.0 / exposures_before_churn) AS penalty_sum
  FROM exposures
  GROUP BY creative_id, ad_format
),
totals AS (
  SELECT creative_id, ad_format, COUNT(*) AS total_shows
  FROM test_app_dataset.ad_revenue_raw
  GROUP BY creative_id, ad_format
)
SELECT p.creative_id, p.ad_format, t.total_shows, p.penalty_sum,
       p.penalty_sum / t.total_shows AS avg_penalty_per_show
FROM penalty p
JOIN totals t USING (creative_id, ad_format)
WHERE t.total_shows > 20
ORDER BY avg_penalty_per_show ASC
LIMIT 20;


SELECT campaign, COUNT(campaign)
FROM test_app_dataset.cost_table
GROUP BY campaign


