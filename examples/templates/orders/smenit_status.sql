-- name: Сменить статус заказов
-- folder: Orders
-- connection: prod-pg
-- var: order_ids | type=list | label=ID заказов | item=number | required
-- var: status | type=select | label=Новый статус | options=new,paid,shipped,cancelled | required
UPDATE orders
SET status = {{status}}, updated_at = now()
WHERE id IN ({{order_ids}})
