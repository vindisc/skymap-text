import Foundation

/// A note as the background matcher sees it: plain values only, so reading and
/// lowercasing bodies can leave the main thread without touching an app's
/// note model.
public struct NoteSearchCandidate: Sendable {
    public let index: Int
    /// Lowercased file name without the extension, so `.` or `md` no longer
    /// matches every note through `.md`.
    public let title: String
    public let url: URL
    /// The in-memory text of a loaded note, which can be newer than the file.
    /// Nil means read the file.
    public let loadedText: String?

    public init(index: Int, title: String, url: URL, loadedText: String?) {
        self.index = index
        self.title = title
        self.url = url
        self.loadedText = loadedText
    }
}

/// One match: where the note ranks, plus — for a body hit — the line to jump
/// to and the line's text trimmed to a context window, so a results row can
/// explain itself.
public struct NoteSearchMatch: Sendable {
    public let index: Int
    public let priority: Int
    /// The body hit's line, zero-based against the note's text lines; nil for
    /// a title-only match.
    public let hitLine: Int?
    /// The hit line's text with the hit centred; nil for a title-only match.
    public let snippet: String?

    public init(index: Int, priority: Int, hitLine: Int? = nil, snippet: String? = nil) {
        self.index = index
        self.priority = priority
        self.hitLine = hitLine
        self.snippet = snippet
    }
}

public enum NoteContentMatcher {
    /// Matching candidates in their original order. Every note whose title
    /// holds all the terms is kept, since those rank first and cost no file
    /// read; body matches then fill up to `limit`. Stopping at `limit` in
    /// list order used to drop an exact title match that sat after a hundred
    /// body matches. Runs off the main thread.
    public static func match(
        _ candidates: [NoteSearchCandidate],
        terms: [String],
        limit: Int,
        isCancelled: () -> Bool
    ) -> [NoteSearchMatch] {
        guard !terms.isEmpty else { return candidates.map { NoteSearchMatch(index: $0.index, priority: 0) } }
        var matches: [NoteSearchMatch] = []
        var titleMatched = Set<Int>()
        for candidate in candidates where terms.allSatisfy({ candidate.title.contains($0) }) {
            if isCancelled() { return [] }
            matches.append(NoteSearchMatch(index: candidate.index, priority: 4))
            titleMatched.insert(candidate.index)
        }
        for candidate in candidates where !titleMatched.contains(candidate.index) {
            if matches.count >= limit { break }
            if isCancelled() { return [] }
            let body = {
                candidate.loadedText ?? (try? Data(contentsOf: candidate.url)).flatMap(NoteText.decode) ?? ""
            }
            guard let hit = bodyHit(title: candidate.title, body: body, terms: terms) else { continue }
            matches.append(NoteSearchMatch(index: candidate.index, priority: hit.priority, hitLine: hit.line, snippet: hit.snippet))
        }
        return matches.sorted { $0.index < $1.index }
    }

    /// 4 when every term is in the title, then 3, 2, 1 as more of the match
    /// comes from the body; nil when some term is in neither.
    public static func priority(title: String, body: () -> String, terms: [String]) -> Int? {
        bodyHit(title: title, body: body, terms: terms)?.priority
    }

    /// The rank plus, for a body match, the first missing term's location
    /// turned into a zero-based line and a centred context snippet.
    static func bodyHit(
        title: String,
        body: () -> String,
        terms: [String]
    ) -> (priority: Int, line: Int?, snippet: String?)? {
        guard !terms.isEmpty else { return nil }

        let titleMatches = terms.filter { title.contains($0) }.count
        if titleMatches == terms.count { return (4, nil, nil) }

        let content = searchable(body())
        var contentMatches = 0
        var firstHit: (location: Int, term: String)?
        for term in terms where !title.contains(term) {
            let range = content.range(of: term.precomposedStringWithCanonicalMapping, options: [.caseInsensitive, .literal])
            guard range.location != NSNotFound else { return nil }
            contentMatches += 1
            if firstHit == nil { firstHit = (range.location, term) }
        }

        let rank = titleMatches > contentMatches ? 3 : (titleMatches > 0 ? 2 : 1)
        guard let firstHit else { return (rank, nil, nil) }

        // The hit's line: the newlines before it, then the line's own bounds.
        let before = content.substring(to: firstHit.location) as String
        let line = before.components(separatedBy: "\n").count - 1
        let lines = (content as String).components(separatedBy: "\n")
        guard line < lines.count else { return (rank, nil, nil) }
        return (rank, line, Self.centre(lines[line], term: firstHit.term))
    }

    /// The line trimmed to about 72 characters with the hit kept in the
    /// middle, so long lines explain themselves without filling the row.
    static func centre(_ line: String, term: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > 72 else { return trimmed }
        let hit = trimmed.range(of: term, options: [.caseInsensitive]) ?? trimmed.startIndex..<trimmed.startIndex
        let head = trimmed.index(hit.lowerBound, offsetBy: -24, limitedBy: trimmed.startIndex) ?? trimmed.startIndex
        let tail = trimmed.index(hit.lowerBound, offsetBy: 48, limitedBy: trimmed.endIndex) ?? trimmed.endIndex
        return (head > trimmed.startIndex ? "…" : "") + String(trimmed[head..<tail]) + (tail < trimmed.endIndex ? "…" : "")
    }

    /// The body in composed form, so a literal search still finds `café`
    /// whether it was stored precomposed or as `e` plus a combining accent.
    /// Text without combining marks, nearly every note, is used as it is.
    static func searchable(_ body: String) -> NSString {
        let text = body as NSString
        guard text.rangeOfCharacter(from: .nonBaseCharacters).location != NSNotFound else { return text }
        return body.precomposedStringWithCanonicalMapping as NSString
    }
}
