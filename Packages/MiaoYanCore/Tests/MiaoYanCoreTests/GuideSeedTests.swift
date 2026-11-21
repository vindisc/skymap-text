import Foundation
import Testing

@testable import MiaoYanCore

@Suite struct GuideSeedTests {
    /// The Mac and the iPhone share an iCloud library: whichever opens it
    /// first writes the guide, and the other one must then write nothing.
    @Test func testOnlyAnEmptyLibraryWithNoGuideGetsOneOnADeviceThatNeverSeeded() {
        #expect(GuideSeed.shouldSeed(libraryHasNotes: false, guideFolderExists: false, seededOnThisDevice: false))
        #expect(!(GuideSeed.shouldSeed(libraryHasNotes: true, guideFolderExists: false, seededOnThisDevice: false)))
        #expect(!(GuideSeed.shouldSeed(libraryHasNotes: false, guideFolderExists: true, seededOnThisDevice: false)))
        #expect(!(GuideSeed.shouldSeed(libraryHasNotes: false, guideFolderExists: false, seededOnThisDevice: true)))
    }

    @Test func testChineseTagsGetTheChineseGuideAndEveryOtherLanguageTheEnglishOne() {
        for tag in ["zh-Hans-CN", "zh-Hant-TW", "zh-HK"] {
            #expect(GuideSeed.plan(forLanguage: tag).folder == "妙言指南", tag)
        }
        for tag in ["en-US", "ja-JP", "es-ES", ""] {
            #expect(GuideSeed.plan(forLanguage: tag).folder == "MiaoYan Guide", tag)
        }
        for tag in ["zh-Hans", "en"] {
            let plan = GuideSeed.plan(forLanguage: tag)
            #expect(GuideSeed.folderNames.contains(plan.folder))
            #expect(plan.notes.count == 3)
        }
    }

    @Test func testAGuideFolderSitsDirectlyInTheLibrary() throws {
        let root = URL(fileURLWithPath: "/lib")
        #expect(GuideSeed.isGuideFolder(root.appendingPathComponent("妙言指南"), root: root))
        #expect(GuideSeed.isGuideFolder(root.appendingPathComponent("MiaoYan Guide"), root: root))
        #expect(!(GuideSeed.isGuideFolder(root.appendingPathComponent("Work/妙言指南"), root: root)))
        #expect(!(GuideSeed.isGuideFolder(root.appendingPathComponent("指南"), root: root)))

        // The same library reached through /var and /private/var.
        let real = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("GuideSeed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: real.appendingPathComponent("妙言指南"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: real) }
        let aliased = URL(fileURLWithPath: real.path.hasPrefix("/private") ? String(real.path.dropFirst(8)) : "/private" + real.path)
        #expect(GuideSeed.isGuideFolder(aliased.appendingPathComponent("妙言指南"), root: real))
        #expect(GuideSeed.isGuideFolder(real.appendingPathComponent("妙言指南"), root: aliased))
    }

    /// Two devices that seeded before either synced leave iCloud's numbered
    /// copy, which must count as a guide too.
    @Test func testANumberedCopyIsAGuideAndOtherNamesAreNot() {
        #expect(GuideSeed.isGuideFolderName("MiaoYan Guide 2"))
        #expect(GuideSeed.isGuideFolderName("妙言指南 3"))
        #expect(!(GuideSeed.isGuideFolderName("MiaoYan Guide 2b")))
        #expect(!(GuideSeed.isGuideFolderName("MiaoYan Guides")))
        #expect(!(GuideSeed.isGuideFolderName("MiaoYan Guide ")))
    }

    /// The launch-time note list reads two levels and skips hidden files, so
    /// a library of deep folders or of notes still in iCloud looked empty.
    @Test func testNotesDeepInFoldersOrStillInICloudMakeALibraryNotEmpty() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GuideNotes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let deep = root.appendingPathComponent("Work/2024/Q1")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Work/cover.png"))
        #expect(!(GuideSeed.libraryHasNotes(at: root, extensions: ["md", "txt"])))

        try Data().write(to: deep.appendingPathComponent(".Plan.md.icloud"))
        #expect(GuideSeed.libraryHasNotes(at: root, extensions: ["md", "txt"]))

        try FileManager.default.removeItem(at: deep.appendingPathComponent(".Plan.md.icloud"))
        try Data().write(to: deep.appendingPathComponent("Plan.MD"))
        #expect(GuideSeed.libraryHasNotes(at: root, extensions: ["md", "txt"]))
    }

    @Test func testTheHideLinkIsRecognisedAndNothingElseIs() {
        #expect(GuideSeed.isHideLink(URL(string: GuideSeed.hideLink)!))
        #expect(!(GuideSeed.isHideLink(URL(string: "miaoyan://goto/Guide")!)))
        #expect(!(GuideSeed.isHideLink(URL(string: "https://guide/hide")!)))
    }
}
