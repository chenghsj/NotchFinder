import Foundation

struct FileDateGroup: Identifiable {
    let title: String
    let entries: [FileEntry]
    var id: String { title }

    static func byDateAdded(_ entries: [FileEntry], now: Date = .now, calendar: Calendar = .current) -> [Self] {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let lastWeek = calendar.date(byAdding: .day, value: -7, to: today) ?? yesterday
        let lastMonth = calendar.date(byAdding: .day, value: -30, to: today) ?? lastWeek
        let groups = Dictionary(grouping: entries) { entry -> Bucket in
            let date = entry.added
            if date == .distantPast { return .undated }
            if date >= today && calendar.isDate(date, inSameDayAs: today) { return .today }
            if date >= yesterday && date < today { return .yesterday }
            if date >= lastWeek && date < yesterday { return .lastWeek }
            if date >= lastMonth && date < lastWeek { return .lastMonth }
            return .month(calendar.dateInterval(of: .month, for: date)?.start ?? date)
        }
        return groups.keys.sorted { first, second in
            func date(_ bucket: Bucket) -> Date {
                switch bucket {
                case .today: today
                case .yesterday: yesterday
                case .lastWeek: lastWeek
                case .lastMonth: lastMonth
                case .month(let month): month
                case .undated: .distantPast
                }
            }
            return date(first) > date(second)
        }.map { bucket in
            FileDateGroup(title: bucket.title(relativeTo: now, calendar: calendar), entries: groups[bucket] ?? [])
        }
    }

    private enum Bucket: Hashable {
        case today, yesterday, lastWeek, lastMonth, month(Date), undated

        func title(relativeTo now: Date, calendar: Calendar) -> String {
            switch self {
            case .today: return L10n.text("今天")
            case .yesterday: return L10n.text("昨天")
            case .lastWeek: return L10n.text("前 7 天")
            case .lastMonth: return L10n.text("前 30 天")
            case .month(let month):
                let locale = L10n.locale
                let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
                return month.formatted(calendar.isDate(month, equalTo: now, toGranularity: .year)
                                       ? style.month(.wide) : style.year().month(.wide))
            case .undated: return L10n.text("未記錄加入日期")
            }
        }
    }
}
