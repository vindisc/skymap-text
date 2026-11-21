import Testing

@testable import MiaoYanCore

@Suite struct MarkdownEditingTests {
    // MARK: Source lines

    @Test func testLineRangesEndOnlyAtCmarkLineEndings() {
        let text = "a\u{2028}b\r\nsecond\rthird\nlast" as NSString
        #expect(SourceLines.range(ofLine: 0, in: text).map(text.substring(with:)) == "a\u{2028}b")
        #expect(SourceLines.range(ofLine: 1, in: text).map(text.substring(with:)) == "second")
        #expect(SourceLines.range(ofLine: 2, in: text).map(text.substring(with:)) == "third")
        #expect(SourceLines.range(ofLine: 3, in: text).map(text.substring(with:)) == "last")
        #expect(SourceLines.range(ofLine: 4, in: text) == nil)
    }

    @Test func testLineAtOffsetMatchesLineRanges() {
        let text = "one\r\ntwo\n\nfour" as NSString
        for index in 0..<4 {
            let range = SourceLines.range(ofLine: index, in: text)!
            #expect(SourceLines.line(atOffset: range.location, in: text) == index)
            #expect(SourceLines.line(atOffset: NSMaxRange(range), in: text) == index)
        }
        #expect(SourceLines.line(atOffset: 999, in: text) == 3)
    }

    // MARK: Task marker

    @Test func testToggleCountsBodyLinesAfterFrontmatter() {
        let text = "---\ntitle: a\n---\nintro\n- [ ] first\n- [x] second\n"
        #expect(TaskMarker.toggled(text, bodyLine: 2) == "---\ntitle: a\n---\nintro\n- [x] first\n- [x] second\n")
        #expect(TaskMarker.toggled(text, bodyLine: 3) == "---\ntitle: a\n---\nintro\n- [ ] first\n- [ ] second\n")
        #expect(TaskMarker.toggled(text, bodyLine: 1) == nil)
        #expect(TaskMarker.toggled(text, bodyLine: 9) == nil)
    }

    @Test func testToggleReachesNestedAndQuotedItems() {
        #expect(TaskMarker.toggled("- a\n  1. [ ] b", bodyLine: 2) == "- a\n  1. [x] b")
        #expect(TaskMarker.toggled("> - [X] q", bodyLine: 1) == "> - [ ] q")
    }

    // MARK: List continuation

    private func pressReturn(_ text: String, at caret: Int? = nil) -> (String, Int)? {
        let ns = text as NSString
        guard let edit = ListContinuation.edit(in: ns, caret: caret ?? ns.length) else { return nil }
        return (ns.replacingCharacters(in: edit.range, with: edit.replacement), edit.caret)
    }

    @Test func testReturnContinuesBulletsNumbersAndTasks() {
        #expect(pressReturn("- one")?.0 == "- one\n- ")
        #expect(pressReturn("* one")?.0 == "* one\n* ")
        #expect(pressReturn("9. nine")?.0 == "9. nine\n10. ")
        #expect(pressReturn("1) one")?.0 == "1) one\n2) ")
        #expect(pressReturn("- [x] done")?.0 == "- [x] done\n- [ ] ")
        #expect(pressReturn("  - nested")?.0 == "  - nested\n  - ")
        #expect(pressReturn("> - quoted")?.0 == "> - quoted\n> - ")
        #expect(pressReturn("- 中文条目")?.1 == ("- 中文条目\n- " as NSString).length)
    }

    @Test func testReturnOnAnEmptyItemEndsTheList() {
        #expect(pressReturn("- one\n- ")?.0 == "- one\n")
        #expect(pressReturn("- one\n- ")?.1 == 6)
        #expect(pressReturn("- [ ] ")?.0 == "")
        #expect(pressReturn("- [ ]")?.0 == "")
        #expect(pressReturn("2. ")?.0 == "")
    }

    @Test func testReturnElsewhereIsAPlainNewline() {
        #expect(pressReturn("plain text") == nil)
        #expect(pressReturn("- one", at: 3) == nil)
        #expect(pressReturn("-not a list") == nil)
        #expect(pressReturn("**bold** line") == nil)
        #expect(pressReturn("---") == nil)
        #expect(pressReturn("- one\nplain") == nil)
    }

    @Test func testReturnOnAMiddleLineContinuesThatLine() {
        let text = "- one\n- two\nend"
        let caret = ("- one" as NSString).length
        #expect(pressReturn(text, at: caret)?.0 == "- one\n- \n- two\nend")
    }

    @Test func testReturnWorksOnCRLFNotes() {
        #expect(pressReturn("- one\r\n- two", at: 5)?.0 == "- one\r\n- \r\n- two")
        #expect(pressReturn("intro\r\n- last")?.0 == "intro\r\n- last\r\n- ")
    }

    /// U+2028 and U+2029 do not end a line for cmark, so `- ` after one is
    /// text inside the line, not an empty item to delete.
    @Test func testReturnTreatsUnicodeSeparatorsAsTextInTheLine() {
        for separator in ["\u{2028}", "\u{2029}"] {
            #expect(pressReturn("pasted\(separator)- ") == nil)
            #expect(pressReturn("pasted\(separator)- [ ] ") == nil)
            #expect(pressReturn("- a\(separator)b")?.0 == "- a\(separator)b\n- ", separator.debugDescription)
            #expect(pressReturn("- a\(separator)")?.0 == "- a\(separator)\n- ", separator.debugDescription)
        }
    }

    @Test func testAThematicBreakIsNotAListItem() {
        #expect(pressReturn("* * *") == nil)
        #expect(pressReturn("- - -") == nil)
        #expect(pressReturn("  * * * *") == nil)
        #expect(pressReturn("- - nested dash")?.0 == "- - nested dash\n- ")
    }

    /// The Mac editor continued `> ` quote lines and the iPhone did not;
    /// both run this rule now, so a quote continues at its depth and an
    /// empty quote line ends it, as an empty item ends its list.
    @Test func testReturnContinuesQuotesAtTheirDepth() {
        #expect(pressReturn("> quoted")?.0 == "> quoted\n> ")
        #expect(pressReturn("> quoted")?.1 == ("> quoted\n> " as NSString).length)
        #expect(pressReturn("> > deeper")?.0 == "> > deeper\n> > ")
        #expect(pressReturn("  > indented")?.0 == "  > indented\n  > ")
        #expect(pressReturn(">  two spaces")?.0 == ">  two spaces\n>  ")
        #expect(pressReturn("> > - quoted item")?.0 == "> > - quoted item\n> > - ")
        #expect(pressReturn("> 1) quoted")?.0 == "> 1) quoted\n> 2) ")
        #expect(pressReturn("> a\r\nend", at: 3)?.0 == "> a\r\n> \r\nend")
    }

    @Test func testReturnOnAnEmptyQuoteLineEndsTheQuote() {
        #expect(pressReturn("> a\n> ")?.0 == "> a\n")
        #expect(pressReturn("> a\n> ")?.1 == 4)
        #expect(pressReturn("> > ")?.0 == "")
        #expect(pressReturn("> a\n>  \nend", at: 7)?.0 == "> a\n\nend")
        #expect(pressReturn(">") == nil)
        #expect(pressReturn(">no space") == nil)
    }

    /// `- name:` in a YAML block is code: the Mac editor wrote a `- ` after
    /// it, the iPhone checked fences itself; the rule skips fences now.
    @Test func testReturnInsideAFencedCodeBlockIsAPlainNewline() {
        let yaml = "```yaml\n- name: a\n> not a quote\n1) step\n```\n- after"
        let ns = yaml as NSString
        for line in ["- name: a", "> not a quote", "1) step"] {
            let caret = NSMaxRange(ns.range(of: line))
            #expect(pressReturn(yaml, at: caret) == nil)
            #expect(ListContinuation.isInFencedCode(at: caret, in: ns))
        }
        #expect(pressReturn(yaml)?.0 == yaml + "\n- ")
        #expect(!(ListContinuation.isInFencedCode(at: ns.length, in: ns)))
        #expect(pressReturn("intro\r\n```\r\n- a\r\n```\r\n", at: 15) == nil)
        #expect(pressReturn("intro\r\n```\r\n- a\r\n", at: 15) != nil)
        #expect(pressReturn("```\n- a\n```  \n", at: 7) == nil)
        // A fence never closed is drawn as text and stays a list.
        #expect(pressReturn("```\n- a")?.0 == "```\n- a\n- ")
        #expect(pressReturn("```\nx\n```\n- a")?.0 == "```\nx\n```\n- a\n- ")
        // An indented fence is no fence for the editors' highlighting.
        #expect(pressReturn("  ```\n- a\n  ```", at: 9)?.0 == "  ```\n- a\n- \n  ```")
    }

    @Test func testLineBreakFollowsTheNote() {
        #expect(ListContinuation.lineBreak(in: "a\nb") == "\n")
        #expect(ListContinuation.lineBreak(in: "a\r\nb") == "\r\n")
        #expect(ListContinuation.lineBreak(in: "") == "\n")
    }

    // MARK: Line edits

    private func apply(_ edit: LineEdits.Edit?, to text: String) -> (String, NSRange)? {
        guard let edit else { return nil }
        return ((text as NSString).replacingCharacters(in: edit.range, with: edit.replacement), edit.selection)
    }

    @Test func testIndentAndOutdentCoverEveryLineOfTheSelection() {
        let text = "- a\n- b\n\n- c"
        let all = NSRange(location: 0, length: (text as NSString).length)
        let indented = apply(LineEdits.indent(in: text as NSString, selection: all), to: text)
        #expect(indented?.0 == "  - a\n  - b\n\n  - c")
        #expect(indented?.1 == NSRange(location: 0, length: 18))
        let back = apply(LineEdits.outdent(in: indented!.0 as NSString, selection: indented!.1), to: indented!.0)
        #expect(back?.0 == text)
        #expect(LineEdits.outdent(in: text as NSString, selection: all) == nil)
        #expect(apply(LineEdits.outdent(in: "\tx" as NSString, selection: NSRange(location: 1, length: 0)), to: "\tx")?.0 == "x")
        #expect(apply(LineEdits.outdent(in: " x" as NSString, selection: NSRange(location: 1, length: 0)), to: " x")?.0 == "x")
    }

    /// Indent then outdent on the last line, or on `selection` when given.
    private func indentRoundTrip(_ text: String, selection: NSRange? = nil) -> (String?, String?) {
        let ns = text as NSString
        let range = selection ?? NSRange(location: ns.length, length: 0)
        guard let indented = apply(LineEdits.indent(in: ns, selection: range), to: text) else { return (nil, nil) }
        let back = apply(LineEdits.outdent(in: indented.0 as NSString, selection: indented.1), to: indented.0)
        return (indented.0, back?.0)
    }

    @Test func testIndentUnderAnOrderedItemNestsAtItsContentColumn() {
        #expect(indentRoundTrip("1. a\n- b").0 == "1. a\n   - b")
        #expect(indentRoundTrip("1. a\n- b").1 == "1. a\n- b")
        #expect(indentRoundTrip("10. a\n- b").0 == "10. a\n    - b")
        #expect(indentRoundTrip("10. a\n- b").1 == "10. a\n- b")
        #expect(indentRoundTrip("1) a\n- b").0 == "1) a\n   - b")
        #expect(indentRoundTrip("1.  a\n- b").0 == "1.  a\n    - b")
        // An ordered item that is itself nested.
        #expect(indentRoundTrip("- x\n  1. a\n  - b").0 == "- x\n  1. a\n     - b")
        #expect(indentRoundTrip("- x\n  1. a\n  - b").1 == "- x\n  1. a\n  - b")
        // Every selected line moves by the same amount.
        let text = "1. a\n- b\n- c"
        let lines = NSRange(location: 5, length: 7)
        #expect(indentRoundTrip(text, selection: lines).0 == "1. a\n   - b\n   - c")
        #expect(indentRoundTrip(text, selection: lines).1 == text)
    }

    @Test func testIndentOutsideOrderedItemsStaysTwoSpaces() {
        #expect(indentRoundTrip("- a\n- b").0 == "- a\n  - b")
        #expect(indentRoundTrip("- a\n- b").1 == "- a\n- b")
        #expect(indentRoundTrip("plain\n- b").0 == "plain\n  - b")
        #expect(indentRoundTrip("1.5 kg\n- b").0 == "1.5 kg\n  - b")
        // Already at or past the item's content: plain two spaces.
        #expect(indentRoundTrip("1. a\n   - b").0 == "1. a\n     - b")
        #expect(indentRoundTrip("1. a\n   - b").1 == "1. a\n   - b")
    }

    @Test func testACaretKeepsItsPlaceInTheLine() {
        let text = "one\n- two\nthree"
        let caret = NSRange(location: 7, length: 0)  // "- t|wo"
        let edit = apply(LineEdits.indent(in: text as NSString, selection: caret), to: text)
        #expect(edit?.0 == "one\n  - two\nthree")
        #expect(edit?.1 == NSRange(location: 9, length: 0))
    }

    @Test func testToggleTaskTicksClearsAndCreates() {
        func toggle(_ text: String) -> String? {
            apply(LineEdits.toggleTask(in: text as NSString, selection: NSRange(location: 0, length: 0)), to: text)?.0
        }
        #expect(toggle("- [ ] a") == "- [x] a")
        #expect(toggle("  - [x] a") == "  - [ ] a")
        #expect(toggle("- a") == "- [ ] a")
        #expect(toggle("2. a") == "2. [ ] a")
        #expect(toggle("plain") == "- [ ] plain")
        #expect(toggle("  plain") == "  - [ ] plain")
        #expect(toggle("") == nil)
        #expect(toggle("- [ ] a\r\nnext") == "- [x] a\r\nnext")
    }

    @Test func testToggleTaskKeepsTheQuote() {
        func toggle(_ text: String) -> String? {
            apply(LineEdits.toggleTask(in: text as NSString, selection: NSRange(location: 0, length: 0)), to: text)?.0
        }
        #expect(toggle("> quote") == "> - [ ] quote")
        #expect(toggle("> - [ ] quote") == "> - [x] quote")
        #expect(toggle("> - [x] a") == "> - [ ] a")
        #expect(toggle("> > quote") == "> > - [ ] quote")
        #expect(toggle(">quote") == ">- [ ] quote")
        #expect(toggle("  > quote") == "  > - [ ] quote")
        #expect(toggle("> - a") == "> - [ ] a")
        #expect(toggle("> 1. a") == "> 1. [ ] a")
    }
}
