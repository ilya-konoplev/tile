# Stage 5 – каталог идентификаторов, финальная сборка

## Задача 1 – каталог идентификаторов

### Дефект, который закрыт

Стадия 4 честно задокументировала известное ограничение (`STAGE4.md`, «Известное
ограничение – список "встречалось в данных"»): `activity.json` хранит только
отображаемые имена (`"Claude"`, `"VLC"`), исходный bundle id / домен теряется на
`Aggregator.displayName`. Поэтому список кандидатов в окне настроек
(`SettingsStore.candidates(kind:)`) восстанавливал недостающее эвристикой
`SettingsStore.classify` – реверс-DNS-подобные строки → `.app`, домен-подобные → `.site`.
Эвристика гарантированно ошибается на любой строке, форма которой не совпадает с её
реальным источником (пример из добавленного теста: `widget.example.app` – три сегмента,
последний `app` – TLD-подобное слово из таблицы эвристики → классифицировалось бы как
`.site`, хотя реально это bundle id, пришедший из `/app/usage`).

### Новые файлы

- `Sources/ActivityHeatmap/Data/Catalog.swift` – `CatalogKind` (`.app`/`.site`),
  `CatalogEntry` (`id`, `kind`, `name`, `seconds`, `lastSeen`) и класс `Catalog`,
  владеющий `catalog.json`. Паттерн 1-в-1 повторяет `Store`/`activity.json`:
  `loadPrevious()` (пусто при отсутствии/битом файле), `mergeCatalog(fresh:)` (id,
  встреченный в свежем скане, полностью заменяет старую запись; id, не встреченный
  в этом скане, доживает, пока его `lastSeen` не выйдет за 91-дневный горизонт –
  тот же принцип, что «дни доживают в `activity.json`»), атомарная запись
  (temp-файл + `FileManager.replaceItem`, идентично `Store.write`).
- `Sources/ActivityHeatmap/SelfTest/CatalogTests.swift` – новый набор тестов:
  `Aggregator.collectCatalog` (kind из потока, а не угадывание по форме строки –
  включая специально сконструированный случай «домен-образная строка из
  `/app/usage`» и «bundle-id-образная строка из `/app/webUsage`»; deny-листнутое
  приложение всё равно попадает в каталог, в отличие от `collect()`; union времени
  через день и переживание блокировки экрана), `Catalog` persistence (roundtrip,
  fresh побеждает старую запись, запись за горизонтом 91 день отбрасывается, пустой
  предыдущий каталог, атомарная перезапись, отсутствующий/битый файл → пусто).

### Изменённые файлы

- `Sources/ActivityHeatmap/Data/Aggregator.swift` – добавлена `Aggregator.collectCatalog`:
  проходит по тем же сырым `Knowledge.UsageRow`, что и `collect()`, но **без**
  фильтрации `settings.keeps` (каталог обязан показывать всё, что реально
  встречалось, включая уже запрещённое – иначе denied-элемент навсегда исчезает
  из списка кандидатов) и **без** сложной логики браузер/foreground/пересечение –
  каталогу нужен только факт «идентификатор X такого-то `kind` существовал и
  использовался примерно столько-то», не точный до секунды учёт. `kind` берётся
  прямо из `row.stream` (`/app/usage` → `.app`, `/app/webUsage` → `.site`).
- `Sources/ActivityHeatmap/Data/Store.swift` – `Store` теперь также владеет
  `Catalog` (тот же db-рид, что и для `activity.json`, повторно не читается).
  `refresh()` после успешной записи `activity.json` считает `collectCatalog`,
  мержит через `catalog.mergeCatalog` и пишет `catalog.json` – если чтение БД
  упало раньше (`Knowledge.loadRows` бросил), до этого кода выполнение не
  доходит, значит ни один из двух файлов не трогается. Это то самое правило
  «при ошибке чтения файл не перезаписывается», теперь верное и для каталога.
- `Sources/ActivityHeatmap/Config/SettingsStore.swift` – `candidates(kind:)`
  переписан: явные записи из `apps.allow/deny` (соотв. `sites.*`) плюс всё, что
  каталог когда-либо записал для этого `kind` – без обращения к `SettingsStore.classify`.
  `classify` не удалён (оставлен как явно задокументированный запасной вариант –
  контракт стадии 5 это разрешает – и продолжает использоваться только в своих
  собственных тестах), но на пути `candidates(kind:)` он больше не участвует.
- `Sources/ActivityHeatmap/SelfTest/SettingsStoreTests.swift` – тест `candidates`
  переделан: вместо посева через `settings.names` + ожидания, что классификатор
  угадает kind, сеется реальный `catalog.json` с явным `kind` по каждой записи.
  Добавлен отдельный тест «kind из потока, а не из формы строки» – конкретный,
  ранее гипотетический сценарий ошибки эвристики, зафиксированный как регрессия.
- `Sources/ActivityHeatmap/SelfTest/StoreTests.swift` – два новых теста:
  `testRefreshWritesCatalogAlongsideHistory` (сквозной прогон `Store.refresh` на
  синтетической БД подтверждает, что `catalog.json` реально пишется, а не только
  что `collectCatalog` в изоляции верна) и
  `testFailedRefreshDoesNotTouchCatalogEither` (провал чтения БД не трогает
  существующий `catalog.json`, симметрично уже существовавшему тесту для
  `activity.json`).
- `Sources/ActivityHeatmap/SelfTest/SelfTestHarness.swift` – зарегистрирован
  `CatalogTests.run()`.

### Итог по тестам

152 → **184** проверок, все проходят (`./.build/debug/ActivityHeatmap --self-test` →
`--- SelfTest: 184 passed, 0 failed ---`). Прирост даёт новый `CatalogTests.swift`,
два новых теста в `StoreTests.swift`, и переработанный `SettingsStore.candidates`-тест
в `SettingsStoreTests.swift` (старый вариант, посеянный через `names`+`classify`,
заменён на посев через каталог – часть старых проверок стала не нужна, часть новых
добавилась, вместе с отдельным regression-тестом на «kind из потока, а не из формы
строки»).

## Задача 2 – финальная сборка

- `swift build` – чисто, без ошибок и предупреждений (`Build complete!`).
- `./build.sh` (debug) – вывод содержит `using stable identity: ActivityHeatmap Dev`.
  Проверено `codesign -dvvv ActivityHeatmap.app`: `Authority=ActivityHeatmap Dev`,
  `flags=0x10000(runtime)` – стабильная подпись, не ad-hoc. Сертификат из прошлых
  стадий (`ActivityHeatmap Dev`, self-signed) уже существовал в login keychain,
  ломать/пересоздавать не потребовалось.
- Автозапуск (`SettingsStore.setLaunchAtLogin` → `SMAppService.mainApp.register()/
  unregister()`) прочитан и признан корректным: единственная точка вызова, вызывается
  строго из обработчика тумблера «Запускать при входе» в `SettingsWindow.swift`,
  нигде не вызывается автоматически при старте приложения
  (`AppDelegate.applicationDidFinishLaunching` его не трогает). `register()` в этой
  сессии **не вызывался** – по прямому запрету задачи это делает только пользователь
  нажатием переключателя.
- `native/README.md` написан: сборка (`build.sh`, `make_cert.sh` для стабильной
  подписи), выдача Full Disk Access, включение автозапуска, расположение файлов
  данных (`~/Library/Application Support/ActivityHeatmap/{activity,catalog,settings,
  position}.json`), порядок удаления приложения.

## Задача 3 – честный список оставшегося

`native/REMAINING.md` – см. файл целиком. Кратко: визуальный рендер виджета/окна
настроек по-прежнему нельзя сфотографировать в этом окружении (ограничение
`computer-use`/compositor для `LSUIElement`-приложения вне `/Applications`, не баг);
реальные данные из `knowledgeC.db` не проверялись (нет FDA на этой машине); клики по
«Запускать при входе» и «Открыть настройки системы» не выполнялись (реальная системная
прописка/переход, только пользователь); drag подтверждён только синтетическим вводом.
Из нового на стадии 5: `catalog.json` не проверен на реальных данных пользователя
(только на синтетике), семантика `seconds` при многодневных повторных `refresh()` на
живой, постепенно пополняющейся БД не показана вживую (только выведена логически из
дизайна, симметричного `DayStats.t`), `release`-сборка не прогонялась (только `debug`,
как и требовала стадия).

## Границы

- Übersicht на момент начала стадии 5 был уже выключен (`pgrep -f
  "Übersicht.app/Contents/MacOS"` – пусто до каких-либо действий). Ничего не
  запускалось и не гасилось, только зафиксировано это состояние.
- `../activity-heatmap.widget/` не тронут.
- Full Disk Access, TCC, Keychain trust – не трогались.
- `SMAppService.register()` не вызывался.
- Ничего не устанавливалось глобально.
- Процессы `ActivityHeatmap`, запущенные тестами и `./build.sh`/ручной проверкой
  подписи, остановлены за собой; `~/Library/Application Support/ActivityHeatmap/`
  проверен `ls` – пуст, тестового мусора не осталось.
