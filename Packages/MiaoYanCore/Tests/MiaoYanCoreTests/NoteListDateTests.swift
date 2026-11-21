import Foundation
import Testing

@testable import MiaoYanCore

@Suite struct NoteListDateTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func short(_ value: Date, _ locale: String) -> String {
        NoteListDate.short(value, now: date(2026, 11, 18, 22, 30), calendar: calendar, locale: Locale(identifier: locale))
    }

    @Test func testTodayShowsOnlyTheTime() {
        #expect(short(date(2026, 11, 18, 22, 8), "en_US") == "10:08\u{202F}PM")
        #expect(!(short(date(2026, 11, 18, 22, 8), "zh_CN").contains("2026")))
        #expect(short(date(2026, 11, 18, 22, 8), "zh_CN").contains("22:08"))
    }

    @Test func testYesterdayIsNamed() {
        #expect(short(date(2026, 11, 17, 9), "en_US") == "Yesterday")
        #expect(short(date(2026, 11, 17, 9), "zh_CN") == "昨天")
    }

    @Test func testThisYearShowsMonthAndDay() {
        #expect(short(date(2026, 10, 11), "zh_CN") == "10月11日")
        #expect(short(date(2026, 10, 11), "en_US") == "Oct 11")
    }

    private func shown(_ value: Date, language: String, system: String) -> String {
        let locale = NoteListDate.displayLocale(language: language, system: Locale(identifier: system))
        return NoteListDate.short(value, now: date(2026, 11, 18, 22, 30), calendar: calendar, locale: locale)
    }

    @Test func testTheAppsLanguageKeepsTheSystemsRegionAndClock() {
        let evening = date(2026, 11, 18, 22, 8)
        #expect(shown(evening, language: "en", system: "en_GB") == "22:08", "an English interface in a 24-hour region")
        #expect(shown(evening, language: "en", system: "en_CN") == "22:08")
        #expect(shown(evening, language: "en", system: "en_US") == "10:08\u{202F}PM")
        #expect(shown(evening, language: "en", system: "en_US@hours=h23") == "22:08", "24-hour time chosen in a 12-hour region")
        #expect(shown(date(2026, 10, 11), language: "en", system: "en_GB") == "11 Oct", "the region's day and month order")
    }

    @Test func testTheWordsStayInTheAppsLanguage() {
        #expect(shown(date(2026, 11, 17, 9), language: "zh-Hans", system: "en_US") == "昨天")
        #expect(shown(date(2026, 10, 11), language: "zh-Hans", system: "en_US") == "10月11日")
        #expect(shown(date(2026, 11, 18, 22, 8), language: "zh-Hans", system: "zh_CN") == "22:08")
        #expect(shown(date(2026, 11, 17, 9), language: "ja", system: "en_GB") == "昨日")
        #expect(shown(date(2026, 10, 11), language: "zh-Hant", system: "zh-Hans_CN@calendar=gregorian") == "10月11日")
    }

    @Test func testTheLocaleIsTheLanguagePlusTheSystemsRegion() {
        func identifier(_ language: String, _ system: String) -> String {
            NoteListDate.displayLocale(language: language, system: Locale(identifier: system)).identifier
        }
        #expect(identifier("zh-Hans", "en_US") == "zh-Hans_US@hours=h12")
        #expect(identifier("en", "zh-Hans_CN") == "en_CN@hours=h23")
        #expect(identifier("pt-BR", "pt_PT") == "pt_PT@hours=h23", "the system's region, not the language's own")
        #expect(identifier("es", "es_419") == "es_419@hours=h12")
        #expect(identifier("en", "en") == "en@hours=h12", "a system with no region adds none")
        #expect(identifier("en", "en_GB@rg=uszzzz") == "en_US@hours=h12", "the Region setting over the language's own")
        #expect(identifier("en", "en_US@calendar=buddhist;rg=dezzzz") == "en_DE@hours=h23")
    }

    @Test func testAnEarlierYearKeepsTheYear() {
        #expect(short(date(2025, 3, 2), "zh_CN") == "2025年3月2日")
        #expect(short(date(2025, 3, 2), "en_US").contains("2025"))
    }
}
