import Testing

import MiaoYanCore

@Suite struct NoteSearchReaderTests {
    @Test func testReadsMatchBeyondFormerSearchLimitAndAcrossUTF8ChunkBoundary() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let text = String(repeating: "a", count: 65_535) + "中文 café" + String(repeating: "b", count: 65_536)
        try text.write(to: url, atomically: true, encoding: .utf8)
        let result = try NoteSearchReader.read(url)
        #expect(result == text)
        #expect(result.range(of: "中文 CAFE", options: [.caseInsensitive, .diacriticInsensitive]) != nil)
    }

    @Test func testEmptyFileRemainsReadableForTitleSearch() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data().write(to: url)
        #expect(try NoteSearchReader.read(url) == "")
    }

    @Test func testReadsGBKNoteForSearch() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let text = "这是一篇旧的周报"
        try XCTUnwrap(text.data(using: NoteTextTests.encoding(.GB_18030_2000))).write(to: url)
        #expect(try NoteSearchReader.read(url) == text)
    }

    func testCancellationStopsBeforeOpeningFile() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try NoteSearchReader.read(URL(fileURLWithPath: "/nonexistent-miaoyan-search-test"))
                XCTFail("Cancelled reads must stop before opening a file")
            } catch is CancellationError {
                // Expected, rather than a file-not-found error.
            } catch {
                XCTFail("Expected cancellation, got \(error)")
            }
        }
        await task.value
    }
}

@Suite struct NoteTextTests {
    static func encoding(_ cf: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cf.rawValue)))
    }

    /// Legacy notes decode to their own text, never to a lossy guess that
    /// the next save would write back as UTF-8 mojibake.
    @Test func testLegacyEncodingsDecodeToTheirOwnText() throws {
        let samples: [(String, String.Encoding)] = [
            ("这是一篇旧的周报，记录了本周的工作。", Self.encoding(.GB_18030_2000)),
            ("這是一篇舊的週報，記錄了本週的工作。", Self.encoding(.big5)),
            ("plain café 中文", .utf8),
            ("UTF-16 note 中文", .utf16),
            ("Windows note: café, naïve, résumé", .windowsCP1252),
        ]
        for (text, encoding) in samples {
            let data = try XCTUnwrap(text.data(using: encoding))
            #expect(NoteText.decode(data) == text, "\(encoding)")
        }
    }

    /// A mostly English note with a few CJK characters was detected as a
    /// Western or Cyrillic code page and saved back as mojibake. The user's
    /// language settles it, without pulling other CJK encodings its way.
    @Test func testMostlyEnglishLegacyNotesFollowTheUsersLanguage() throws {
        struct Sample {
            let text: String
            let encoding: String.Encoding
            let languages: [String]
        }
        let samples = [
            Sample(text: "# Weekly\n\n- Fix the sidebar\n- Ship 4.6\n- 周报", encoding: Self.encoding(.GB_18030_2000), languages: ["zh-Hans-CN", "en"]),
            Sample(text: "# Weekly\n\n- Fix the sidebar\n- Ship 4.6\n- 週報", encoding: Self.encoding(.big5), languages: ["zh-Hant-TW"]),
            Sample(text: "# Memo\n\n- Fix sidebar\n- 메모", encoding: Self.encoding(.EUC_KR), languages: ["ko-KR"]),
            Sample(text: "今日はいい天気ですね。散歩に行きましょう。", encoding: .shiftJIS, languages: ["zh-Hans-CN"]),
            Sample(text: "Café au lait, résumé, naïve façade.", encoding: .windowsCP1252, languages: ["zh-Hans-CN"]),
            Sample(text: "Café au lait, résumé, naïve façade.", encoding: .windowsCP1252, languages: ["en-US"]),
        ]
        for sample in samples {
            let data = try XCTUnwrap(sample.text.data(using: sample.encoding))
            #expect(NoteText.decode(data, preferredLanguages: sample.languages) == sample.text, "\(sample.encoding) \(sample.languages)")
        }
    }

    /// A UTF-8 note with one bad byte was read as Windows-1252 or GB18030,
    /// shown as mojibake and saved back that way. It is reported as damaged
    /// UTF-8 and decoded as UTF-8, the bad byte as U+FFFD.
    @Test func testUTF8WithABadByteIsDamagedNotALegacyEncoding() throws {
        var damaged = Data("# 你好世界".utf8)
        damaged.append(0xFF)
        damaged.append(Data("\n".utf8))
        #expect(NoteText.isDamagedUTF8(damaged))
        #expect(NoteText.decode(damaged, preferredLanguages: ["zh-Hans-CN"]) == "# 你好世界\u{FFFD}\n")
        #expect(NoteText.decode(damaged, preferredLanguages: ["en-US"]) == "# 你好世界\u{FFFD}\n")

        var truncated = Data("Café notes, 第一段落".utf8)
        truncated.removeLast()
        #expect(NoteText.isDamagedUTF8(truncated))

        let legacy: [(String, String.Encoding)] = [
            ("这是一篇旧的周报，记录了本周的工作。", Self.encoding(.GB_18030_2000)),
            ("中文", Self.encoding(.GB_18030_2000)),
            // Short titles whose GB18030 or EUC-KR bytes happen to pair up
            // into a few UTF-8 sequences: an equal-count rule read them as
            // damaged UTF-8 and opened them read-only as mojibake.
            ("# 学习笔记\n", Self.encoding(.GB_18030_2000)),
            ("테스트", Self.encoding(.EUC_KR)),
            ("회의록", Self.encoding(.EUC_KR)),
            ("這是一篇舊的週報，記錄了本週的工作。", Self.encoding(.big5)),
            ("# Memo\n\n- Fix sidebar\n- 메모", Self.encoding(.EUC_KR)),
            ("今日はいい天気ですね。散歩に行きましょう。", .shiftJIS),
            ("UTF-16 note 中文", .utf16),
            ("Windows note: café, naïve, résumé", .windowsCP1252),
        ]
        for (text, encoding) in legacy {
            #expect(!(NoteText.isDamagedUTF8(try XCTUnwrap(text.data(using: encoding)))))
        }
        #expect(!(NoteText.isDamagedUTF8(Data("plain café 中文".utf8))))
        for (text, encoding) in legacy where text.count > 8 {
            #expect(!(NoteText.mayBeDamagedUTF8(try XCTUnwrap(text.data(using: encoding)))))
        }
        let title = try XCTUnwrap("# 学习笔记\n".data(using: Self.encoding(.GB_18030_2000)))
        #expect(NoteText.mayBeDamagedUTF8(title))
        #expect(NoteText.decode(title, preferredLanguages: ["zh-Hans-CN"]) == "# 学习笔记\n", "and shown in its own encoding")

        // Too few sequences to call damaged outright, but never editable:
        // the legacy reading saved back would be mojibake.
        var short = Data("# 你好".utf8)
        short.append(0xFF)
        var cut = Data("Café notes, 第一段".utf8)
        cut.removeLast()
        for sample in [short, cut] {
            #expect(!(NoteText.isDamagedUTF8(sample)))
            #expect(NoteText.mayBeDamagedUTF8(sample))
        }
        #expect(!(NoteText.isDamagedUTF8(Data([0x23, 0x20, 0x61, 0xFF, 0x0A]))))
    }
}

@Suite struct NoteContentMatcherTests {
    private func candidate(_ index: Int, title: String, url: URL = URL(fileURLWithPath: "/nonexistent"), loaded: String? = nil) -> NoteSearchCandidate {
        NoteSearchCandidate(index: index, title: title, url: url, loadedText: loaded)
    }

    @Test func testPriorityFollowsWhereTheTermsWereFound() {
        #expect(NoteContentMatcher.priority(title: "潮流周刊", body: { "" }, terms: ["潮流"]) == 4)
        #expect(NoteContentMatcher.priority(title: "潮流周刊", body: { "Rust 工具" }, terms: ["潮流", "rust"]) == 2)
        #expect(NoteContentMatcher.priority(title: "周刊", body: { "Rust 工具" }, terms: ["rust"]) == 1)
        #expect(NoteContentMatcher.priority(title: "周刊", body: { "Rust" }, terms: ["go"]) == nil)
    }

    /// The body search ignores case but not accents, and finds an accented
    /// word whether the body or the query holds it composed or decomposed,
    /// as `lowercased()` plus `contains` did.
    @Test func testBodyMatchIgnoresCaseButKeepsAccentsAndCanonicalForms() {
        func found(_ body: String, _ term: String) -> Bool {
            NoteContentMatcher.priority(title: "", body: { body }, terms: [term]) != nil
        }
        #expect(found("The Quick FOX", "fox"))
        #expect(found("妙言 MiaoYan 预览", "miaoyan 预"))
        #expect(found("ＡＢＣ 全角", "ａｂｃ"))
        #expect(found("Hello CAFÉ", "café"))
        #expect(found("cafe\u{301} decomposed", "café"))
        #expect(found("café composed", "cafe\u{301}"))
        #expect(!(found("Hello Café", "cafe")))
        #expect(!(found("cafe\u{301}", "cafe")))
        #expect(!(found("妙言预览", "预览不存在")))
    }

    @Test func testBodyIsNotReadWhenTheTitleSettlesTheMatch() {
        var reads = 0
        _ = NoteContentMatcher.priority(
            title: "潮流周刊",
            body: {
                reads += 1; return ""
            }, terms: ["周刊"])
        #expect(reads == 0)
    }

    @Test func testADotMatchesTextNotTheFileExtension() {
        // Titles carry no extension, so "." only matches a note that has one.
        let matches = NoteContentMatcher.match(
            [candidate(0, title: "潮流周刊", loaded: "没有句点"), candidate(1, title: "周刊", loaded: "v1.2")],
            terms: ["."], limit: .max, isCancelled: { false })
        #expect(matches.map(\.index) == [1])
    }

    @Test func testLoadedTextWinsOverTheFileAndUnloadedNotesAreRead() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try "saved on disk".write(to: url, atomically: true, encoding: .utf8)

        let fromDisk = NoteContentMatcher.match([candidate(0, title: "a", url: url)], terms: ["disk"], limit: .max, isCancelled: { false })
        #expect(fromDisk.map(\.index) == [0])

        // An open note's unsaved text is what the user sees, so it decides.
        let edited = NoteContentMatcher.match([candidate(0, title: "a", url: url, loaded: "typed just now")], terms: ["disk"], limit: .max, isCancelled: { false })
        #expect(edited.isEmpty)
    }

    @Test func testLimitCapsBodyMatchesAndCancellationReturnsNothing() {
        let all = (0..<5).map { candidate($0, title: "entry \($0)", loaded: "a note") }
        #expect(NoteContentMatcher.match(all, terms: ["note"], limit: 2, isCancelled: { false }).map(\.index) == [0, 1])
        #expect(NoteContentMatcher.match(all, terms: ["note"], limit: .max, isCancelled: { true }).isEmpty)
    }

    @Test func testATitleMatchIsNeverCutByEarlierBodyMatches() {
        let bodies = (0..<150).map { candidate($0, title: "entry \($0)", loaded: "mentions plan") }
        let exact = candidate(150, title: "plan")
        let found = NoteContentMatcher.match(bodies + [exact], terms: ["plan"], limit: 100, isCancelled: { false })
        #expect(found.contains { $0.index == 150 && $0.priority == 4 })
        #expect(found.count == 100)
    }

    @Test func testUnopenedGBKNotesMatchOnTheirBody() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        try XCTUnwrap("旧笔记里的周报".data(using: gb18030)).write(to: url)
        let found = NoteContentMatcher.match([candidate(0, title: "legacy", url: url)], terms: ["周报"], limit: 100, isCancelled: { false })
        #expect(found.map(\.index) == [0])
    }
}
