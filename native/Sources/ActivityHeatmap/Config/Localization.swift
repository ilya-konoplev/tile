import Foundation

/// UI language. Deliberately not `Locale`-driven: the widget sits on the
/// desktop next to whatever else the user runs, and several people asked for
/// a language that differs from the system one. `system` follows macOS,
/// the explicit cases override it.
enum Language: String, Codable, CaseIterable {
    case system
    case ru
    case en

    /// The language actually used for rendering.
    var resolved: Language {
        guard self == .system else { return self }
        let code = Locale.preferredLanguages.first?.prefix(2).lowercased() ?? "en"
        return code == "ru" ? .ru : .en
    }

    /// Language names stay in their own language (as every OS does); only
    /// "System" is translated, so it needs the current strings passed in.
    func displayName(_ strings: L10n) -> String {
        switch self {
        case .system: return strings.languageSystem
        case .ru: return "Русский"
        case .en: return "English"
        }
    }
}

/// All user-facing copy in one place. A struct rather than a table of keys so
/// that a missing translation is a compile error, not a silent fallback to a
/// raw key at runtime.
struct L10n {
    let lang: Language

    init(_ language: Language) {
        self.lang = language.resolved
    }

    private func pick(_ ru: String, _ en: String) -> String {
        lang == .ru ? ru : en
    }

    // MARK: Widget

    /// Header line: today's date. Replaced the static "Активность" title and
    /// the day-count pill – the pill counted grid cells up to today (86 of 91),
    /// which read as "86 days tracked" while only a handful actually held data.
    func today(_ date: Date = Date(), calendar: Calendar = .current) -> String {
        let comps = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        guard let y = comps.year, let m = comps.month, let d = comps.day,
              let weekday = comps.weekday else { return "" }
        let day = self.date(iso: String(format: "%04d-%02d-%02d", y, m, d))
        return "\(day), \(weekdayName(weekday))"
    }

    /// `weekday` is Foundation's 1 = Sunday numbering. Russian keeps weekday
    /// names lowercase mid-phrase, English capitalises them – so this is not a
    /// shared list with a `capitalized` applied to it.
    private func weekdayName(_ weekday: Int) -> String {
        let ru = ["воскресенье", "понедельник", "вторник", "среда",
                  "четверг", "пятница", "суббота"]
        let en = ["Sunday", "Monday", "Tuesday", "Wednesday",
                  "Thursday", "Friday", "Saturday"]
        let index = max(0, min(6, weekday - 1))
        return lang == .ru ? ru[index] : en[index]
    }
    /// The two ends of the diverging legend scale. The design labels them by
    /// what the colour *means* ("Негатив" / "Польза"), not by intensity –
    /// the scale runs across a sign change, not from less to more.
    var legendNegative: String { pick("Негатив", "Harmful") }
    var legendPositive: String { pick("Польза", "Useful") }

    /// Signed balance, e.g. "+2 ч 15 мин" / "−1 ч 30 мин". Uses a real minus
    /// sign (U+2212), not a hyphen: it aligns with digits and reads as a sign
    /// rather than a dash.
    func balance(_ seconds: Int) -> String {
        if seconds == 0 { return pick("баланс 0", "balance 0") }
        let sign = seconds > 0 ? "+" : "\u{2212}"
        return "\(sign)\(duration(abs(seconds)))"
    }

    /// The legend's left-hand figure: "Баланс: +37 ч" / "Balance: +37 h".
    func balanceTotal(_ seconds: Int) -> String {
        let sign = seconds > 0 ? "+" : (seconds < 0 ? "\u{2212}" : "")
        return pick("Баланс: ", "Balance: ") + sign + duration(abs(seconds))
    }

    var categoryUseful: String { pick("Полезное", "Useful") }
    var categoryDestructive: String { pick("Вредное", "Harmful") }
    var categoryNeutral: String { pick("Нейтральное", "Neutral") }
    var categoryHint: String {
        pick("Полезное добавляет времени в баланс дня, вредное вычитает",
             "Useful adds to the day's balance, harmful subtracts from it")
    }
    var accentColorBad: String { pick("Цвет негативного", "Harmful colour") }
    var totalSuffix: String { pick("всего", "total") }
    var noActivity: String { pick("нет активности", "no activity") }
    var dayDetailPartial: String {
        pick("Старый день — сохранён только топ. Полный список ведётся с недавних пор.",
             "Older day — only the top was kept. Full lists start from recently.")
    }
    var dragHint: String {
        pick("Потяни, чтобы передвинуть · двойной клик – вернуть на место",
             "Drag to move · double-click to reset")
    }
    var scaleHint: String {
        pick("Потяни, чтобы изменить масштаб", "Drag to resize")
    }

    // MARK: Widget states

    var loadingBody: String { pick("Считаю активность…", "Measuring activity…") }
    var noAccessTitle: String { pick("Нет доступа к knowledgeC.db", "No access to knowledgeC.db") }
    var noAccessBody: String {
        pick("Дай Full Disk Access приложению ActivityHeatmap: System Settings → Privacy & Security → Full Disk Access → добавь ActivityHeatmap и полностью перезапусти его.",
             "Grant Full Disk Access to ActivityHeatmap: System Settings → Privacy & Security → Full Disk Access → add ActivityHeatmap and restart it completely.")
    }
    var failedTitle: String { pick("Сбой агрегации", "Aggregation failed") }

    // MARK: Menu bar

    var menuWidgetEnabled: String { pick("Виджет включён", "Widget enabled") }
    var menuSettings: String { pick("Настройки…", "Settings…") }
    var menuQuit: String { pick("Выход", "Quit") }
    /// Tray panel: the toggle row's own label, plus the status line under it.
    var trayWidget: String { pick("Виджет", "Widget") }
    var trayTrackingActive: String { pick("Отслеживание активно", "Tracking active") }
    var trayTrackingOff: String { pick("Выключен", "Off") }

    // MARK: Settings window

    var settingsTitle: String { pick("Активность — настройки", "Activity — Settings") }
    var appsSitesTitle: String { pick("Приложения и сайты", "Apps & Sites") }
    /// Back link on the pushed screen. The chevron is part of the string so
    /// the two sides can put it where their typography wants it.
    var backToSettings: String { pick("‹ Настройки", "‹ Settings") }

    /// Summary under the "Приложения и сайты ›" row: how many of the known
    /// identifiers are actually being counted.
    func trackedSummary(_ tracked: Int, of total: Int) -> String {
        pick("\(tracked) из \(total) учитываются", "\(tracked) of \(total) counted")
    }

    var widgetEnabled: String { pick("Виджет включён", "Widget enabled") }
    var widgetEnabledHint: String {
        pick("Плитки активности на рабочем столе", "Activity tiles on the desktop")
    }
    var launchAtLogin: String { pick("Запускать при входе", "Launch at login") }
    var launchAtLoginHint: String {
        pick("Автозапуск после перезагрузки Mac", "Starts automatically after a reboot")
    }
    func launchAtLoginFailed(_ detail: String) -> String {
        pick("Не удалось изменить автозапуск: \(detail)",
             "Could not change the login item: \(detail)")
    }

    var accessGranted: String { pick("Доступ к данным есть", "Data access granted") }
    var accessDenied: String { pick("Нет доступа к данным", "No data access") }
    var accessGrantedBody: String {
        pick("Full Disk Access предоставлен – виджет получает данные об активности.",
             "Full Disk Access is granted – the widget is reading activity data.")
    }
    var accessDeniedBody: String {
        pick("Для отслеживания активности нужен Full Disk Access. Разрешите доступ в Системных настройках.",
             "Tracking activity requires Full Disk Access. Grant it in System Settings.")
    }
    var openSystemSettings: String { pick("Открыть настройки системы", "Open System Settings") }

    var searchPlaceholder: String {
        pick("Поиск по приложениям и сайтам…", "Search apps and sites…")
    }

    // Filter chips. The glyph is baked into the label exactly as the design
    // draws it – it is the same `+ · −` vocabulary as the per-row segmented
    // control, and the two must read as one system.
    var filterAll: String { pick("Все", "All") }
    var filterUseful: String { pick("+ Полезные", "+ Useful") }
    var filterNeutral: String { pick("· Нейтральные", "· Neutral") }
    var filterHarmful: String { pick("− Негативные", "− Harmful") }

    /// Two halves of the legend line under the chips, each preceded by its
    /// colour swatch, so the sentence can't be assembled in the wrong order.
    var categoryLegendUseful: String {
        pick("полезное красит плитки фиолетовым,", "useful tints tiles purple,")
    }
    var categoryLegendHarmful: String {
        pick("негативное — оранжевым", "harmful — orange")
    }

    func showMore(_ n: Int) -> String {
        pick("Показать ещё \(n)", "Show \(n) more")
    }

    // Tooltips on the three-way segmented control.
    var categoryUsefulTip: String {
        pick("Полезное — красит плитки в акцентный цвет",
             "Useful — tints tiles with the accent colour")
    }
    var categoryNeutralTip: String {
        pick("Нейтральное — не влияет на цвет", "Neutral — does not affect colour")
    }
    var categoryHarmfulTip: String {
        pick("Негативное — уводит плитки в минус", "Harmful — pushes tiles negative")
    }
    var sectionApps: String { pick("ПРИЛОЖЕНИЯ", "APPS") }
    var sectionSites: String { pick("САЙТЫ", "SITES") }
    var addManually: String { pick("Добавить вручную", "Add manually") }
    var addManuallyButton: String { pick("+ Добавить вручную", "+ Add manually") }
    var nothingFound: String { pick("Ничего не найдено.", "Nothing found.") }
    var sectionEmpty: String { pick("Пока пусто.", "Empty for now.") }
    var groupByKind: String { pick("По типу", "By kind") }
    var groupByCategory: String { pick("По категориям", "By category") }
    var kindApp: String { pick("Приложение", "App") }
    var kindSite: String { pick("Сайт", "Site") }
    var domainPlaceholder: String { pick("домен, напр. example.com", "domain, e.g. example.com") }
    var bundleIdPlaceholder: String { pick("bundle id, напр. com.apple.Safari", "bundle id, e.g. com.apple.Safari") }
    var addButton: String { pick("Добавить", "Add") }
    var cancelButton: String { pick("Отмена", "Cancel") }

    // MARK: Appearance

    var sectionAppearance: String { pick("Внешний вид", "Appearance") }
    /// Section headers from handoff 4's regrouped settings window. Sentence
    /// case, as the mockup writes them and as System Settings does.
    var sectionWidget: String { pick("Виджет", "Widget") }
    var sectionTiles: String { pick("Плитки активности", "Activity tiles") }
    var sectionData: String { pick("Данные", "Data") }

    var appearanceRow: String { pick("Оформление", "Appearance") }
    var appearanceHint: String { pick("Светлая или тёмная тема", "Light or dark theme") }
    var appearanceSystem: String { pick("Авто", "Auto") }
    var appearanceLight: String { pick("Светлая", "Light") }
    var appearanceDark: String { pick("Тёмная", "Dark") }

    var materialRow: String { pick("Материал", "Material") }
    var materialHint: String {
        pick("Непрозрачный или стеклянный", "Opaque or glass")
    }
    var materialRegular: String { pick("Обычный", "Regular") }
    var materialGlass: String { pick("Liquid Glass", "Liquid Glass") }

    var unclassifiedHarmful: String { pick("Всё вредным по умолчанию", "Harmful by default") }
    var unclassifiedHarmfulHint: String {
        pick("Неразмеченное время тянет баланс в минус, пока не отметишь полезным",
             "Unclassified time counts against you until you mark it useful")
    }
    var harmfulWeightRow: String { pick("Вес вредного", "Harmful weight") }
    var harmfulWeightHint: String {
        pick("Во сколько раз вредное время весит против полезного",
             "How much harmful time weighs against useful")
    }
    var accentColor: String { pick("Цвет полезного", "Useful colour") }
    var accentHint: String {
        pick("Плитки с положительным балансом", "Tiles with a positive balance")
    }
    var accentBadHint: String {
        pick("Плитки с отрицательным балансом", "Tiles with a negative balance")
    }
    var widgetScale: String { pick("Масштаб виджета", "Widget scale") }
    var widgetScaleHint: String {
        pick("Размер плиток на рабочем столе", "Tile size on the desktop")
    }
    var showLegend: String { pick("Показывать легенду", "Show legend") }
    var liquidGlass: String { pick("Жидкое стекло", "Liquid glass") }
    var liquidGlassHint: String {
        pick("Больше прозрачности, блики и глубокая тень — во всём приложении",
             "More transparency, highlights and a deeper shadow, app-wide")
    }
    var language: String { pick("Язык", "Language") }
    var languageSystem: String { pick("Системный", "System") }

    // MARK: Formatting

    /// Russian needs three plural forms, English two – so this cannot be a
    /// shared format string.
    func days(_ n: Int) -> String {
        guard lang == .ru else { return "\(n) day\(n == 1 ? "" : "s")" }
        let mod10 = n % 10, mod100 = n % 100
        if mod10 == 1 && mod100 != 11 { return "\(n) день" }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "\(n) дня" }
        return "\(n) дней"
    }

    func duration(_ seconds: Int) -> String {
        var h = seconds / 3600
        var m = Int((Double(seconds % 3600) / 60).rounded())
        // Rounding the leftover minutes can land on 60 (e.g. 39599s → 59.98 →
        // 60), which showed as "10 h 60 min". Carry it into the hour.
        if m == 60 { h += 1; m = 0 }
        let hourUnit = pick("ч", "h")
        let minUnit = pick("мин", "min")
        if h == 0 { return "\(m) \(minUnit)" }
        return m == 0 ? "\(h) \(hourUnit)" : "\(h) \(hourUnit) \(m) \(minUnit)"
    }

    private static let monthsRu = [
        "января", "февраля", "марта", "апреля", "мая", "июня",
        "июля", "августа", "сентября", "октября", "ноября", "декабря",
    ]
    private static let monthsEn = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]

    /// "19 июля" / "19 July" from an ISO `yyyy-MM-dd` key.
    func date(iso: String) -> String {
        let parts = iso.split(separator: "-")
        guard parts.count == 3, let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month) else { return iso }
        let name = lang == .ru ? Self.monthsRu[month - 1] : Self.monthsEn[month - 1]
        return "\(day) \(name)"
    }
}
