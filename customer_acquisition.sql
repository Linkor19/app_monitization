-- c = скільки разів подія сталася, u = скільки унікальних юзерів її зробили;
-- якщо c значно більше за u, подія повторювана (рендьюали, скасування)
SELECT event_name, COUNT(*) c, COUNT(DISTINCT COALESCE(NULLIF(advertising_id,''), firebase_analytic_app_id)) u -- список подій
FROM `mornhouse-test-environment.test_app_dataset.in_app_events_report`
GROUP BY 1 ORDER BY c DESC;

-- перевірка підозри, що 50 кампаній для одного застосунку забагато:
-- частина з них може бути вимкнена або відкручена один день
SELECT campaign, campaign_id, -- скільки з 50 кампаній реально живі
         ROUND(SUM(cost_usd), 2) AS cost_usd,
         SUM(impressions) AS impressions,
         SUM(clicks) AS clicks,
         COUNT(DISTINCT adset_id) AS adsets, -- ширина кампанії: скільки груп оголошень всередині
         COUNT(DISTINCT date) AS active_days, -- скільки днів реально крутилась, а не скільки існує
         MIN(date) AS first_day, MAX(date) AS last_day -- вікно життя: свіжа кампанія чи давно мертва
  FROM test_app_dataset.cost_table
  GROUP BY campaign, campaign_id
  ORDER BY cost_usd DESC;


SELECT campaign, campaign_id, -- Загальні витрати
         ROUND(SUM(cost_usd), 2) AS cost_usd,
         SUM(impressions) AS impressions,
         SUM(clicks) AS clicks,
         COUNT(*) AS rows_in_table -- скільки рядків стоїть за сумою: date x adset x country x city
  FROM test_app_dataset.cost_table
  GROUP BY campaign, campaign_id
  ORDER BY cost_usd DESC;

-- CAC: ділимо гроші на людей. Гроші лежать у cost_table без жодних ID юзерів,
-- тому єдиний місток до інсталів — campaign_id
WITH cost AS ( -- вартість залучення CAC
    SELECT campaign, campaign_id, SUM(cost_usd) AS cost_usd
    FROM test_app_dataset.cost_table
    GROUP BY campaign, campaign_id
  ),
  inst AS ( -- рахуємо унікальні пристрої, а не рядки таблиці
    SELECT campaign_id, COUNT(DISTINCT COALESCE(NULLIF(advertising_id, ''), firebase_analytic_app_id)) AS
  installs
    FROM test_app_dataset.non_org_installs_report
    GROUP BY campaign_id
  )
  SELECT campaign, cost_usd, installs, cost_usd/ installs AS cpi -- ціна одного інсталу
  FROM cost c
  LEFT JOIN inst i ON c.campaign_id = i.campaign_id -- LEFT: видно кампанії, що витратили гроші й не дали інсталів
  ORDER BY cost_usd DESC;

-- дивимось знак виручки: у рефаунда MIN буде від'ємним, тобто SUM сама
-- віднімає повернення і окремо їх віднімати не треба
SELECT event_name, COUNT(*), MIN(event_revenue_usd), MAX(event_revenue_usd) -- як працюють рефаунди
  FROM test_app_dataset.in_app_events_report
  WHERE event_name IN ('subscription_refunded', 'trial_converted', 'subscription_renewed')
  GROUP BY event_name;

WITH inst AS ( -- LTV по кампаніям
      SELECT campaign_id, campaign_name, COALESCE(NULLIF(advertising_id, ''), firebase_analytic_app_id) AS
  user_key
      FROM test_app_dataset.non_org_installs_report
      GROUP BY campaign_id, campaign_name, user_key
    ),
    rev AS ( -- дві виручки в одну колонку: підписки і реклама всередині застосунку
      SELECT COALESCE(NULLIF(advertising_id, ''), firebase_analytic_app_id) AS user_key, event_revenue_usd
  AS amount, 'sub' AS src
      FROM test_app_dataset.in_app_events_report
      UNION ALL
      SELECT COALESCE(NULLIF(advertising_id, ''), firebase_analytic_app_id), event_revenue_usd, 'ad'
      FROM test_app_dataset.ad_revenue_raw
      WHERE event_name = 'ad_revenue'
    )
    SELECT campaign_id, campaign_name,
           COUNT(DISTINCT i.user_key) AS installs,
           SUM(IF(src = 'sub', amount, 0)) AS sub_rev,
           SUM(IF(src = 'ad', amount, 0)) AS ad_rev,
           SUM(amount) AS total_rev,
           SUM(amount) / COUNT(DISTINCT i.user_key) AS ltv -- вся виручка кампанії на одного залученого юзера
    FROM inst i
    LEFT JOIN rev r ON i.user_key = r.user_key -- LEFT: юзери без виручки мусять лишитись у знаменнику
    GROUP BY campaign_id, campaign_name
    ORDER BY ltv DESC;


---------------- LTV / CAC

 -- зводимо два попередні запити: скільки заплатили за кампанію і скільки вона повернула
WITH cost AS ( -- окупність залучення: LTV / CAC по кампаніям
    SELECT campaign_id, campaign, SUM(cost_usd) AS cost_usd
    FROM test_app_dataset.cost_table
    GROUP BY campaign_id, campaign
  ),
  inst AS (
    SELECT campaign_id, COALESCE(NULLIF(advertising_id, ''), firebase_analytic_app_id) AS user_key
    FROM test_app_dataset.non_org_installs_report
    GROUP BY campaign_id, user_key
  ),
  rev AS (
    SELECT COALESCE(NULLIF(advertising_id, ''), firebase_analytic_app_id) AS user_key, event_revenue_usd AS amount, 'sub' AS src
    FROM test_app_dataset.in_app_events_report
    UNION ALL
    SELECT COALESCE(NULLIF(advertising_id, ''), firebase_analytic_app_id), event_revenue_usd, 'ad'
    FROM test_app_dataset.ad_revenue_raw
    WHERE event_name = 'ad_revenue'
  ),
  ltv AS (
    SELECT campaign_id,
           COUNT(DISTINCT i.user_key) AS installs,
           SUM(IF(src = 'sub', amount, 0)) AS sub_rev,
           SUM(IF(src = 'ad', amount, 0)) AS ad_rev,
           SUM(amount) AS total_rev
    FROM inst i
    LEFT JOIN rev r ON i.user_key = r.user_key
    GROUP BY campaign_id
  )
  SELECT campaign, installs, cost_usd,-- sub_rev, ad_rev, total_rev,
--          cost_usd / installs AS cpi,
--          total_rev / installs AS ltv,
         total_rev / NULLIF(cost_usd, 0) AS ltv_cac -- < 1 = кампанія в мінусі; NULLIF страхує нульовий спенд
  FROM cost c
  JOIN ltv l ON c.campaign_id = l.campaign_id
  WHERE installs > 500 -- відсікаємо хвости на 78-82 інстали, де середнє нічого не означає
  ORDER BY ltv_cac DESC;

--

-- таблиця спряження для хі-квадрат: скільки юзерів кожної кампанії дійшло до кроку.
-- Рахуємо тільки позитивні кроки, негативні не потрібні: друга колонка
-- таблиці 3x2 рахується як різниця з попереднім кроком
WITH inst AS ( -- унікальні юзери по кампаніям
    SELECT campaign_name, COALESCE(NULLIF(advertising_id, ''), firebase_analytic_app_id) AS user_key
    FROM test_app_dataset.non_org_installs_report
    WHERE campaign_name IN ('mock_campaign_674dbd59', 'mock_campaign_f81bdda1', 'mock_campaign_1e8723bd')
    GROUP BY campaign_name, user_key
  ),
  ev AS ( -- пара юзер+подія без дублів: один юзер тригерить подію багато разів
    SELECT COALESCE(NULLIF(advertising_id, ''), firebase_analytic_app_id) AS user_key, event_name
    FROM test_app_dataset.in_app_events_report
    GROUP BY user_key, event_name
  )
  SELECT campaign_name,
         COUNT(DISTINCT i.user_key) AS installs,
         COUNT(DISTINCT IF(event_name = 'trial_started', i.user_key, NULL)) AS trial_started, -- клітинки таблиці
         COUNT(DISTINCT IF(event_name = 'trial_converted', i.user_key, NULL)) AS trial_converted,
  FROM inst i
  LEFT JOIN ev e ON i.user_key = e.user_key -- LEFT: хто не дійшов до жодної події, лишається в installs
  GROUP BY campaign_name;
