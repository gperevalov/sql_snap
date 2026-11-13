-- name: Заказы клиента
-- folder: Orders
-- connection: prod-pg
-- description: Последние заказы клиента с фильтром по статусу
-- var: client_id | type=number | label=ID клиента | required
-- var: status | type=select | label=Статус | options=new,paid,shipped,cancelled
-- var: from | type=date | label=С даты | default=today-30
-- var: lim | type=number | label=Лимит | default=100
SELECT id, status, total, created_at
FROM orders
WHERE client_id = {{client_id}}
  [[ AND status = {{status}} ]]
  AND created_at >= {{from}}
ORDER BY created_at DESC
LIMIT {{lim}}
