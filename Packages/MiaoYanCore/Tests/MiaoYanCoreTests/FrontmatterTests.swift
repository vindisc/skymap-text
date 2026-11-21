import Testing

import MiaoYanCore

@Suite struct FrontmatterTests {
    private func body(_ text: String) -> String { String(Frontmatter.body(of: text)) }

    @Test func testStripsFrontmatterWithOrWithoutTitleKey() {
        #expect(body("---\ntitle: Hello\ndate: 2026-07-13\n---\nBody text") == "Body text")
        #expect(body("---\ntags: [ai, notes]\ndraft: true\n---\nBody text") == "Body text")
    }

    @Test func testKeepsTextThatDoesNotOpenWithAFence() {
        let text = "# Heading\n\n---\n\nafter a rule"
        #expect(body(text) == text)
    }

    @Test func testKeepsTextWhenTheFenceNeverClosesOnItsOwnLine() {
        #expect(body("---\nkey: value\nno closing fence") == "---\nkey: value\nno closing fence")
        #expect(body("---\nkey: value\n----\nstill inside") == "---\nkey: value\n----\nstill inside")
    }

    @Test func testFrontmatterOnlyDocumentBecomesEmpty() {
        #expect(body("---\nkey: value\n---") == "")
    }

    @Test func testCRLFDocuments() {
        #expect(body("---\r\nkey: value\r\n---\r\nBody") == "Body")
    }

    @Test func testKeepsASlideDeckThatOpensWithARule() {
        let deck = "---\n\n## niaho\n\n---\n\n## niha\n\n---\n"
        #expect(body(deck) == deck)
        #expect(!(Frontmatter.opensUnclosedBlock(deck)))
    }

    @Test func testStripsYAMLWithListsAndComments() {
        #expect(body("---\n# draft\ntags:\n  - ai\n- notes\ndate: 2026/10/12\n---\nBody") == "Body")
    }

    @Test func testKeepsABlockWithoutKeys() {
        #expect(body("---\nJust a sentence\n---\nBody") == "---\nJust a sentence\n---\nBody")
        #expect(body("---\nsee https://example.com\n---\nBody") == "---\nsee https://example.com\n---\nBody")
    }

    @Test func testOpensUnclosedBlock() {
        #expect(Frontmatter.opensUnclosedBlock("---\ntitle: Long"))
        #expect(!(Frontmatter.opensUnclosedBlock("---\ntitle: Long\n---\nBody")))
        #expect(!(Frontmatter.opensUnclosedBlock("# Heading")))
    }

    @Test func testLineCountCoversTheBlockInBothLineEndings() {
        #expect(Frontmatter.lineCount(of: "---\ntitle: A\ntags: b\n---\nBody") == 4)
        #expect(Frontmatter.lineCount(of: "---\r\ntitle: A\r\n---\r\nBody") == 3)
        #expect(Frontmatter.lineCount(of: "# No frontmatter\nBody") == 0)
    }
}
