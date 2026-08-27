-- Джерело для дашборду закупівлі: одна плоска таблиця замість зв'язків у Tableau.
-- Гранулярність: кампанія x день установки. Кожен юзер належить рівно одному дню
-- і одній кампанії, тому всі стовпці адитивні і Tableau просто сумує їх по будь-якому зрізу.
-- Навмисно жодного відсотка: тільки чисельники й знаменники, відношення рахуються
-- в Tableau як SUM(x)/SUM(y), інакше фільтри дадуть середнє від середнього.
WITH cost AS ( -- витрати по кампанії за день
    SELECT campaign_id, campaign AS campaign_name, media_source, CAST(date AS DATE) AS d, -- date тут рядковий, без касту не зіститься з install_date
           SUM(cost_usd) AS cost_usd, SUM(impressions) AS impressions, SUM(clicks) AS clicks
    FROM test_app_dataset.cost_table
    GROUP BY campaign_id, campaign_name, media_source, d
  ),
  inst AS ( -- один рядок = один юзер
    SELECT campaign_id, campaign_name, media_source, DATE(install_date) AS d,
           COALESCE(NULLIF(advertising_id, ''), firebase_analytic_app_id) AS user_key
    FROM test_app_dataset.non_org_installs_report
    WHERE campaign_id IS NOT NULL -- рядки без атрибуції не належать жодній кампанії
    GROUP BY campaign_id, campaign_name, media_source, d, user_key
  ),
  ev AS ( -- прапорці етапів і виручка з підписок, по юзеру
    SELECT COALESCE(NULLIF(advertising_id, ''), firebase_analytic_app_id) AS user_key,
           MAX(IF(event_name = 'trial_started', 1, 0)) AS f_trial, -- прапорець: юзер хоч раз дійшов до кроку
           MAX(IF(event_name = 'trial_converted', 1, 0)) AS f_paid,
           MAX(IF(event_name = 'subscription_renewed', 1, 0)) AS f_renew,
           SUM(IFNULL(event_revenue_usd, 0)) AS sub_rev
    FROM test_app_dataset.in_app_events_report
    GROUP BY user_key
  ),
  adr AS ( -- рекламна виручка, по юзеру; окремо, бо ad_revenue_raw це мільйони показів
    SELECT COALESCE(NULLIF(advertising_id, ''), firebase_analytic_app_id) AS user_key,
           SUM(event_revenue_usd) AS ad_rev
    FROM test_app_dataset.ad_revenue_raw
    WHERE event_name = 'ad_revenue'
    GROUP BY user_key
  ),
  users AS (
    SELECT i.campaign_id, i.campaign_name, i.media_source, i.d,
           COUNT(*) AS installs, -- inst уже згорнутий до одного рядка на юзера, DISTINCT не потрібен
           SUM(IFNULL(f_trial, 0)) AS trial_started,
           SUM(IFNULL(f_paid, 0)) AS trial_converted,
           SUM(IFNULL(f_renew, 0)) AS sub_renewed,
           SUM(IFNULL(sub_rev, 0)) AS sub_rev,
           SUM(IFNULL(ad_rev, 0)) AS ad_rev
    FROM inst i
    LEFT JOIN ev e ON i.user_key = e.user_key
    LEFT JOIN adr a ON i.user_key = a.user_key -- обидві CTE по рядку на юзера, тому розмноження немає
    GROUP BY i.campaign_id, i.campaign_name, i.media_source, i.d
  )
  SELECT COALESCE(c.campaign_id, u.campaign_id) AS campaign_id,
         COALESCE(c.campaign_name, u.campaign_name) AS campaign_name,
         COALESCE(c.media_source, u.media_source) AS media_source,
         COALESCE(c.d, u.d) AS day,
         IFNULL(cost_usd, 0) AS cost_usd, -- нулі замість NULL, інакше Tableau малюватиме дірки в графіках
         IFNULL(impressions, 0) AS impressions,
         IFNULL(clicks, 0) AS clicks,
         IFNULL(installs, 0) AS installs,
         IFNULL(trial_started, 0) AS trial_started,
         IFNULL(trial_converted, 0) AS trial_converted,
         IFNULL(sub_renewed, 0) AS sub_renewed,
         IFNULL(sub_rev, 0) AS sub_rev,
         IFNULL(ad_rev, 0) AS ad_rev
  FROM cost c
  FULL JOIN users u ON c.campaign_id = u.campaign_id AND c.d = u.d; -- FULL: лишаємо і дні з витратами без інсталів, і навпаки