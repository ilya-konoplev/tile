<p align="center">
  <img src="docs/icon.png" width="112" alt="Tile">
</p>

<h1 align="center">Tile</h1>

<p align="center">
  Тепловая карта экранного времени на рабочем столе macOS.<br>
  A desktop heatmap of your Mac screen time.
</p>

<p align="center">
  <a href="https://github.com/ilya-konoplev/tile/releases/latest/download/Tile.zip"><b>Скачать для Mac</b></a>
  &nbsp;·&nbsp;
  <a href="#установка">Установка</a>
  &nbsp;·&nbsp;
  <a href="#english">English</a>
</p>

<p align="center">
  <img src="docs/preview.svg" width="560" alt="Виджет Tile">
</p>

## Описание

Tile — виджет для macOS, который показывает активность за компьютером в виде сетки: одна плитка — один день, около трёх месяцев истории. Данные берутся из системной базы Экранного времени, вести учёт вручную не нужно.

Приложения и сайты можно разметить как полезные или негативные. Для каждого дня считается баланс — полезное время минус негативное. Дни с положительным балансом окрашиваются в основной цвет, с отрицательным — в цвет негативного, дни без размеченной активности остаются нейтральными.

### Возможности

- Сетка за 13 недель с подсказкой по наведению и подробной разбивкой дня по клику.
- Разметка приложений и сайтов: полезное, нейтральное, негативное.
- Режим «Всё вредным по умолчанию» и настраиваемый вес негативного времени.
- Выбор цветов для положительных и отрицательных дней.
- Перемещение виджета по рабочему столу и изменение размера (60–140 %).
- Светлая, тёмная и автоматическая тема; обычный материал или «Жидкое стекло».
- Значок в строке меню, окно настроек, запуск при входе в систему.
- Интерфейс на русском и английском языках.

### Конфиденциальность

Все данные обрабатываются локально. Приложение не содержит сетевого кода и ничего не отправляет. Полный доступ к диску требуется только для чтения базы Экранного времени, которую macOS хранит в защищённой папке.

## Установка

**Требования:** Mac с процессором Apple Silicon (M1 и новее), macOS 13 Ventura или новее. Для Mac с процессором Intel используйте [сборку из исходников](#сборка-из-исходников).

### 1. Загрузка

1. Скачайте [Tile.zip](https://github.com/ilya-konoplev/tile/releases/latest/download/Tile.zip) и распакуйте архив. Safari обычно распаковывает его автоматически.
2. Переместите `ActivityHeatmap.app` в папку «Программы».

### 2. Первый запуск

Приложение не нотариально заверено Apple, поэтому при первом запуске macOS его заблокирует. Разрешение выдаётся один раз.

1. Откройте `ActivityHeatmap` из папки «Программы».
2. В окне с предупреждением нажмите «Готово».
3. Откройте «Системные настройки» → «Конфиденциальность и безопасность» и прокрутите страницу вниз.
4. Напротив сообщения об `ActivityHeatmap` нажмите «Всё равно открыть», подтвердите паролем и нажмите «Открыть».

На macOS 13–14 достаточно открыть приложение через контекстное меню: правый клик → «Открыть» → «Открыть».

Приложение не отображается в Dock: оно работает из строки меню.

### 3. Доступ к данным

1. Откройте «Системные настройки» → «Конфиденциальность и безопасность» → «Полный доступ к диску». Этот экран также открывается кнопкой «Открыть настройки системы» в настройках Tile.
2. Нажмите «+» и выберите `ActivityHeatmap` в папке «Программы».
3. Включите переключатель напротив приложения.
4. Перезапустите Tile: значок в строке меню → «Выход», затем откройте приложение снова.

После перезапуска на рабочем столе появится сетка. Tile загрузит данные, которые macOS хранит за последние дни; дальше история накапливается автоматически.

### 4. Настройка

Значок в строке меню → «Настройки…»:

- «Приложения и сайты» — разметка полезного и негативного. Пока ничего не размечено, плитки показывают общее время за день.
- «Запускать при входе» — автозапуск.
- Виджет перемещается за верхнюю часть карточки, размер меняется ручкой внизу.

## Решение проблем

| Проблема | Решение |
|---|---|
| Виджет запрашивает доступ, хотя он выдан | Выйдите из Tile через строку меню и откройте снова. Убедитесь, что переключатель включён для копии приложения из папки «Программы». |
| Нет кнопки «Всё равно открыть» | Кнопка появляется только после попытки открыть приложение и доступна около часа. |
| Сетка пустая | В первые дни это ожидаемо. Если сетка пуста и через сутки, проверьте, что включено «Системные настройки» → «Экранное время». |
| Виджет не реагирует на мышь | Закройте Übersicht и другие программы для виджетов рабочего стола: они перехватывают события мыши. |

## Удаление

1. В настройках Tile выключите «Запускать при входе», если автозапуск был включён.
2. Выйдите из приложения через строку меню и переместите `ActivityHeatmap` в Корзину.
3. При необходимости удалите историю: `~/Library/Application Support/ActivityHeatmap`.
4. Удалите приложение из списка «Полный доступ к диску» кнопкой «−».

## Сборка из исходников

Требуются Command Line Tools; полный Xcode не нужен.

```bash
xcode-select --install
cd native
bash build.sh release
```

Переместите собранный `ActivityHeatmap.app` в «Программы» и выполните [шаг 3](#3-доступ-к-данным). Если приложение планируется пересобирать, сначала создайте сертификат подписи по инструкции `./make_cert.sh` — иначе доступ к диску будет сбрасываться после каждой сборки. Подробности — в [native/README.md](native/README.md).

## Статус

Личный проект, не прошедший широкого тестирования. Работа зависит от внутренней базы Экранного времени macOS, поэтому обновления системы могут потребовать доработок.

---

<a name="english"></a>
## English

Tile is a macOS desktop widget that shows your computer activity as a grid: one tile per day, about three months of history. It reads the system Screen Time database, so there is nothing to track manually.

Apps and websites can be marked as useful or harmful. Each day gets a balance — useful time minus harmful time. Days with a positive balance use the main colour, negative days use the harmful colour, and days without classified activity stay neutral.

### Features

- 13-week grid with a hover summary and a full per-day breakdown on click.
- Classification of apps and websites: useful, neutral, harmful.
- "Harmful by default" mode and an adjustable weight for harmful time.
- Separate colours for positive and negative days.
- Movable and resizable widget (60–140 %).
- Light, dark and automatic theme; regular or Liquid Glass material.
- Menu bar icon, settings window, launch at login.
- Russian and English interface.

### Privacy

All data is processed locally. The app contains no network code. Full Disk Access is required only to read the Screen Time database, which macOS stores in a protected folder.

### Installation

**Requirements:** Apple Silicon Mac (M1 or later), macOS 13 Ventura or later. On Intel Macs, build from source.

1. Download [Tile.zip](https://github.com/ilya-konoplev/tile/releases/latest/download/Tile.zip), unzip it and move `ActivityHeatmap.app` to Applications.
2. Open the app. The app is not notarized, so macOS blocks the first launch: click "Done", then go to System Settings → Privacy & Security, click "Open Anyway" and confirm. On macOS 13–14, right-click the app and choose "Open".
3. Go to System Settings → Privacy & Security → Full Disk Access, click "+", add `ActivityHeatmap` and enable it.
4. Quit Tile from the menu bar and open it again.

The app has no Dock icon; it runs from the menu bar.

### Build from source

```bash
xcode-select --install
cd native
bash build.sh release
```

If you plan to rebuild the app, create a signing certificate first (`./make_cert.sh` prints the steps); otherwise Full Disk Access resets after every build. See [native/README.md](native/README.md).

---

## Структура репозитория

- [native/](native/) — приложение на Swift/SwiftUI: [README](native/README.md), [ARCHITECTURE](native/ARCHITECTURE.md), [STATUS](native/STATUS.md).
- [ubersicht-prototype/](ubersicht-prototype/) — первая версия в виде виджета для [Übersicht](https://tracesof.net/uebersicht/). Приложение от неё не зависит.
