import Foundation

/// The span a report covers. Weeks run Monday to Sunday in local time.
enum Period: Hashable {
    case year(Int)
    case all
    case thisWeek
    case lastWeek
    case thisMonth

    var isShort: Bool {
        switch self {
        case .thisWeek, .lastWeek, .thisMonth: return true
        case .year, .all: return false
        }
    }

    var isWeek: Bool { self == .thisWeek || self == .lastWeek }

    var year: Int? {
        if case .year(let y) = self { return y }
        return nil
    }

    /// Inclusive range of local days; nil means all time.
    func range(today: DayKey = LocalTime.today) -> ClosedRange<DayKey>? {
        switch self {
        case .year(let y):
            return LocalTime.dayKey(year: y, month: 1, day: 1)...LocalTime.dayKey(year: y, month: 12, day: 31)
        case .all:
            return nil
        case .thisWeek:
            let monday = LocalTime.monday(of: today)
            return monday...(monday + 6)
        case .lastWeek:
            let monday = LocalTime.monday(of: today) - 7
            return monday...(monday + 6)
        case .thisMonth:
            let first = LocalTime.firstOfMonth(today)
            return first...(first + LocalTime.daysInMonth(first) - 1)
        }
    }

    /// What to compare against. An unfinished week or month is compared with the same number
    /// of days at the start of the previous one, so a two-day-old week isn't "down 70%".
    func comparison(today: DayKey = LocalTime.today) -> (range: ClosedRange<DayKey>, label: String)? {
        switch self {
        case .thisWeek:
            let monday = LocalTime.monday(of: today)
            let elapsed = today - monday
            return ((monday - 7)...(monday - 7 + elapsed), elapsed >= 6 ? "上周" : "上周同期")
        case .lastWeek:
            let monday = LocalTime.monday(of: today) - 7
            return ((monday - 7)...(monday - 1), "前一周")
        case .thisMonth:
            let first = LocalTime.firstOfMonth(today)
            let previous = LocalTime.firstOfMonth(first - 1)
            let elapsed = min(today - first, LocalTime.daysInMonth(previous) - 1)
            let complete = today - first + 1 >= LocalTime.daysInMonth(first)
            return (previous...(previous + elapsed), complete ? "上月" : "上月同期")
        case .year, .all:
            return nil
        }
    }

    /// Days of the period that have happened, for "本周才过了 2 天".
    func elapsedDays(today: DayKey = LocalTime.today) -> Int? {
        guard isShort, let r = range(today: today) else { return nil }
        return max(0, min(r.upperBound, today) - r.lowerBound + 1)
    }

    /// Menu and footer label.
    var label: String {
        switch self {
        case .year(let y): return "\(String(y)) 年"
        case .all: return "全部时间"
        case .thisWeek: return "本周"
        case .lastWeek: return "上周"
        case .thisMonth: return "本月"
        }
    }

    var reportName: String {
        switch self {
        case .year, .all: return "AI 年度报告"
        case .thisWeek, .lastWeek: return "AI 周报"
        case .thisMonth: return "AI 月报"
        }
    }

    /// Lead-in for sentences: "这一年，你和 AI…".
    var phrase: String {
        switch self {
        case .year: return "这一年"
        case .all: return "到目前为止"
        case .thisWeek: return "这一周"
        case .lastWeek: return "上周"
        case .thisMonth: return "这个月"
        }
    }

    /// "第 44 周" / "10 月" / "2026" for eyebrows and the share card.
    func badge(today: DayKey = LocalTime.today) -> String {
        switch self {
        case .year(let y): return String(y)
        case .all: return "ALL TIME"
        case .thisWeek, .lastWeek: return "第 \(LocalTime.isoWeek(range(today: today)!.lowerBound)) 周"
        case .thisMonth: return "\(LocalTime.components(today).month ?? 0) 月"
        }
    }

    /// "10.26 – 11.01" for weeks, "2026.10" for a month.
    func rangeText(today: DayKey = LocalTime.today) -> String {
        guard let r = range(today: today) else { return "ALL TIME" }
        let a = LocalTime.components(r.lowerBound), b = LocalTime.components(r.upperBound)
        switch self {
        case .thisMonth: return String(format: "%d.%02d", a.year ?? 0, a.month ?? 0)
        case .year(let y): return String(y)
        default: return String(format: "%d.%02d – %d.%02d", a.month ?? 0, a.day ?? 0, b.month ?? 0, b.day ?? 0)
        }
    }

    var fileTag: String {
        switch self {
        case .year(let y): return String(y)
        case .all: return "全部"
        case .thisWeek, .lastWeek: return "W\(LocalTime.isoWeek(range()!.lowerBound))"
        case .thisMonth: return rangeText()
        }
    }
}

extension LocalTime {
    /// 0 = Monday … 6 = Sunday.
    static func weekdayIndex(_ day: DayKey) -> Int { ((components(day).weekday ?? 1) + 5) % 7 }
    static func monday(of day: DayKey) -> DayKey { day - weekdayIndex(day) }
    static func firstOfMonth(_ day: DayKey) -> DayKey {
        let c = components(day)
        return dayKey(year: c.year ?? 1970, month: c.month ?? 1, day: 1)
    }
    static func daysInMonth(_ day: DayKey) -> Int {
        let date = Date(timeIntervalSince1970: Double(day) * 86400)
        return utc.range(of: .day, in: .month, for: date)?.count ?? 30
    }
    static func isoWeek(_ day: DayKey) -> Int {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c.component(.weekOfYear, from: Date(timeIntervalSince1970: Double(day) * 86400))
    }
}

/// Headline numbers of a span, used for "比上周 ↑ 32%".
struct PeriodTotals {
    var tokens: Int64 = 0
    var sessions = 0
    var prompts = 0
    var activeDays = 0
}

extension PeriodTotals {
    static func of(_ scan: ScanResult, in range: ClosedRange<DayKey>) -> PeriodTotals {
        var t = PeriodTotals()
        var sessions = Set<String>()
        var days = Set<DayKey>()
        for u in scan.usage {
            let d = LocalTime.day(u.time)
            guard range.contains(d) else { continue }
            t.tokens += u.tokens.total
            days.insert(d)
        }
        for p in scan.prompts {
            let d = LocalTime.day(p.time)
            guard range.contains(d) else { continue }
            t.prompts += 1
            sessions.insert(p.session)
            days.insert(d)
        }
        for (key, info) in scan.sessions {
            guard let start = info.start else { continue }
            let d = LocalTime.day(start)
            if range.contains(d) {
                sessions.insert(key)
                days.insert(d)
            }
        }
        t.sessions = sessions.count
        t.activeDays = days.count
        return t
    }
}
