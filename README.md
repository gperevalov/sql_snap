# SQL Snap

Android-приложение для работы с **MySQL, PostgreSQL и ClickHouse** прямо с телефона — без своего сервера.
Главная фишка — **шаблоны запросов с переменными**: на телефоне остаётся только заполнить пару полей и нажать «Выполнить».

## Возможности

- Подключения к MySQL (в т.ч. MySQL 8), PostgreSQL, ClickHouse (через HTTP/HTTPS). Пароли хранятся в зашифрованном хранилище Android.
- Шаблоны с переменными `{{имя}}` и удобным вводом по типу:
  текст, число, дата (календарь + «Сегодня / Вчера / −7 дн»), дата-время, да/нет, выбор из списка, список для `IN (...)` (вставили столбец ID — получили `1, 2, 3`), «как есть».
- Необязательные блоки: `[[ AND status = {{status}} ]]` выкидывается, если поле пустое.
- Экранирование строк под диалект каждой СУБД — значения не ломают SQL и не дают инъекций.
- История введённых значений (чипсы под полями).
- SQL-консоль, результаты таблицей или карточками, фильтр, копирование в TSV (вставляется в Excel/Sheets) и CSV.
- Подтверждение перед INSERT/UPDATE/DELETE/DDL, режим «только чтение» на подключение.

## Как править шаблоны с компьютера

1. **Веб-редактор по Wi‑Fi** (самое удобное). В приложении: «Синхр.» → включить «Редактор по Wi‑Fi» → открыть показанную ссылку `http://192.168.x.x:8787/?t=…` в браузере на ПК (ПК и телефон в одной сети). Там: редактор SQL с подсветкой, настройка переменных, подключения, запуск запросов (выполняет телефон), консоль, импорт/экспорт. `Ctrl+S` — сохранить, `Ctrl+Enter` — выполнить. Ключ в ссылке меняется при каждом включении.
2. **GitHub-репозиторий с .sql файлами.** Шаблон — обычный `.sql` с шапкой-комментарием (см. `examples/templates`). Правите в IDE, пушите, на телефоне жмёте **Pull**. Кнопка **Push** отправляет изменения с телефона обратно. Нужен fine-grained token с правом *Contents: Read and write* только на этот репозиторий.
3. **JSON** — экспорт/импорт через буфер обмена, по ссылке или файлом в веб-редакторе.

### Формат .sql шаблона

```sql
-- name: Заказы клиента
-- folder: Orders
-- connection: prod-pg            <- название подключения в приложении
-- description: Последние заказы клиента
-- var: client_id | type=number | label=ID клиента | required
-- var: status | type=select | options=new,paid,shipped
-- var: ids | type=list | item=number
-- var: from | type=date | default=today-30
SELECT * FROM orders
WHERE client_id = {{client_id}}
  [[ AND status = {{status}} ]]
  [[ AND id IN ({{ids}}) ]]
  AND created_at >= {{from}}
```

Типы: `text, number, date, datetime, bool, select, list, raw`.
Динамические значения по умолчанию: `today, yesterday, tomorrow, today-7, today+1, month_start, prev_month_start, year_start, now, now-2h, now-30m`.

## Сборка APK (бесплатно, через GitHub Actions)

1. Создайте **приватный** репозиторий на GitHub и запушьте туда эту папку (папка `signing/` в `.gitignore` и в репо не попадёт).
2. В репозитории: *Settings → Secrets and variables → Actions → New repository secret*
   - Name: `ANDROID_KEYSTORE_BASE64`
   - Value: содержимое файла `signing/keystore.base64.txt`

   Это постоянный ключ подписи — благодаря ему новые версии ставятся поверх старой без потери шаблонов и подключений. Сохраните `signing/` в надёжном месте.
3. Каждый push в `main` запускает сборку (*Actions → Build APK*). Готовый APK появится в *Releases → latest* (и в артефактах сборки).
4. Откройте ссылку на APK с телефона и установите (разрешите установку из этого источника).

Если сборка упала — пришлите лог шага, который покраснел, поправлю.

### Локальная сборка (если стоит Flutter)

```bash
flutter create --platforms=android --org tech.mpspace --project-name sqlsnap .
# в android/app/src/main/AndroidManifest.xml добавить перед <application>:
#   <uses-permission android:name="android.permission.INTERNET"/>
# и в тег <application> атрибут android:usesCleartextTraffic="true"
flutter build apk --release
```

## Важно про сеть

Телефон подключается к базам напрямую, поэтому порты должны быть доступны с телефона (у вас базы открыты в интернет — ок). Рекомендую завести отдельного пользователя БД для телефона с минимальными правами, для PostgreSQL/MySQL включить SSL, а для ClickHouse использовать HTTPS (порт 8443).

## Структура

```
lib/
  main.dart               навигация
  models.dart             подключения, шаблоны, переменные, результаты
  template_engine.dart    переменные, [[ ]] блоки, экранирование, defaults
  db.dart                 драйверы MySQL / PostgreSQL / ClickHouse
  store.dart              хранение данных + пароли в secure storage
  lan_server.dart         HTTP-сервер для веб-редактора по Wi‑Fi
  github_sync.dart        pull/push .sql файлов через GitHub API
  sqlfile.dart            формат .sql с шапкой
  screens/                экраны приложения
assets/web/index.html     веб-редактор (отдаётся телефоном)
.github/workflows/        сборка APK
branding/                 иконка
examples/templates/       примеры шаблонов
```
