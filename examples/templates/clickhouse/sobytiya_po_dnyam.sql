-- name: События по дням
-- folder: ClickHouse
-- connection: ch
-- var: from | type=date | label=С | default=today-7
-- var: to | type=date | label=По | default=today
-- var: event | type=text | label=Событие (пусто = все)
SELECT toDate(ts) AS day, event, count() AS cnt
FROM events
WHERE ts >= {{from}} AND ts < toDate({{to}}) + 1
  [[ AND event = {{event}} ]]
GROUP BY day, event
ORDER BY day DESC, cnt DESC
