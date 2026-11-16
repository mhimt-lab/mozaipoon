import AVFoundation
import CoreImage
import Vision

// Finding personal information in the lines that were read: the kinds (`TextKind`), the
// words to hide, and the lines that continue one another.

func mostCommonReading(_ t: TextTrack) -> String {
    var count: [String: Int] = [:]
    for s in t.samples { count[s.string, default: 0] += 1 }
    return count.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }!.key
}

/// One sample per distinct reading of the line (readings differ when recognition errs), the
/// one with the recognized text (for the boxes of character ranges) when there is one.
func distinctReadings(_ t: TextTrack) -> [TextSample] {
    var out: [TextSample] = []
    var at: [String: Int] = [:]
    for s in t.samples {
        if let i = at[s.string] {
            if out[i].text == nil, s.text != nil { out[i] = s }
        } else {
            at[s.string] = out.count
            out.append(s)
        }
    }
    // A reading off its place has another line's box: its text only (a part found in it alone
    // has no box, and the whole line is hidden).
    for s in t.offPlace where at[s.string] == nil {
        at[s.string] = out.count
        out.append(TextSample(frame: s.frame, rect: s.rect, string: s.string, text: nil))
    }
    return out
}

/// Parts of the line to hide per kind. Every reading is checked, so a line is covered for its
/// whole track when any frame read the information correctly.
func kindParts(_ t: TextTrack, size: CGSize) -> [TextKind: [CGRect]] {
    var out: [TextKind: [CGRect]] = [:]
    for s in distinctReadings(t) {
        for (kind, range) in findKinds(in: s.string) {
            // No box for the range: hide the whole line rather than drop what was found.
            out[kind, default: []].append(relativeBox(s, range: range, size: size, along: t.isTilted) ?? whole)
        }
    }
    return out.mapValues(mergeOverlapping)
}

/// Vision sometimes gives the lines of a frame each another line's text: in a chat starting to
/// scroll, the address line's box read as the line below it, that one's as the URL of a later
/// message, while the URL's own line and the address line's text were left out (2026-11-16).
/// The line below then seemed to jump onto the address line for a frame, and the URL to appear
/// on it; as a URL its whole line was hidden there, the address line's start too, for the time
/// a track is continued before and after it.
///
/// Judged only at a frame that agrees with the frames around it: of the upright lines read
/// before and after it, two thirds or more are read where they are expected (moving evenly
/// between those readings). A scroll by whole lines at once (an arrow key, a notch of the
/// wheel) or a moment of another screen puts most lines elsewhere, and nothing is changed
/// there. At such a frame, where a line read clearly otherwise (similarity below 0.3 to all its
/// readings; readings of one line misread differently, as 路線情服 and 路線價報, are about
/// 0.5) is expected and nothing of it was read:
/// - a reading of a track off its own expected place no longer places the track (it goes on
///   between its readings before and after), but its text is kept (`TextTrack.offPlace`): it
///   may be the only correct reading of the line. Not when another line read then moved the
///   same way (a part of the screen scrolled), nor when the reading before or after it is at
///   the same place;
/// - a track of up to two readings of 4 characters or more is dropped when its text is also
///   expected elsewhere then, and nothing of it was read there (one or two characters, as
///   "ね", are often on screen twice).
/// The same text really appearing for a moment over another line, with its other place not
/// read either, cannot be told apart (LIMITATIONS).
func droppingMixedUpReadings(_ tracks: [TextTrack], times: [Double]) -> [TextTrack] {
    func upright(_ s: TextSample) -> Bool {
        guard let c = s.corners, c.count == 4 else { return true }
        let q = place(c, in: s.rect)
        return abs(atan2(q[1].y - q[0].y, q[1].x - q[0].x)) < minTilt
    }
    func sameArea(_ a: CGRect, _ b: CGRect) -> Bool {
        let i = a.intersection(b)
        return !i.isNull && i.width * i.height >= 0.5 * max(a.width * a.height, b.width * b.height)
    }
    // The readings of each track, to compare text with (any of them may be the misread one).
    let keys = tracks.map { Set($0.samples.map { normalizedForMatch($0.string) }) }
    func similar(_ k: Int, _ key: String) -> Double { keys[k].map { similarity($0, key) }.max() ?? 0 }
    // Samples by frame, and the tracks read before and after each frame read.
    var at: [Int: [(track: Int, sample: Int)]] = [:]
    for (k, t) in tracks.enumerated() { for (i, s) in t.samples.enumerated() { at[s.frame, default: []].append((k, i)) } }
    let frames = at.keys.sorted()
    let byFirst = tracks.indices.sorted { tracks[$0].first < tracks[$1].first }
    var open: [Int] = [], next = 0
    var offPlace: [Int: Set<Int>] = [:]  // track → indices of samples off their place
    var mixedUp = Set<Int>(), cleared = Set<Int>()  // short tracks found mixed up / not
    for f in frames {
        while next < byFirst.count, tracks[byFirst[next]].first < f { open.append(byFirst[next]); next += 1 }
        open.removeAll { tracks[$0].last <= f }
        // Where each line read before and after is expected, and whether it was read at f.
        var expected: [Int: CGRect] = [:]
        var readAt: [Int: [Int]] = [:]
        for (k, i) in at[f] ?? [] { readAt[k, default: []].append(i) }
        for k in open {
            let ss = tracks[k].samples
            var lo = 0, hi = ss.count  // first sample after f
            while lo < hi { let mid = (lo + hi) / 2; if ss[mid].frame > f { hi = mid } else { lo = mid + 1 } }
            var j = lo - 1
            while j >= 0, ss[j].frame == f { j -= 1 }
            guard j >= 0, lo < ss.count, upright(ss[j]), upright(ss[lo]) else { continue }
            let a = ss[j], b = ss[lo]
            let u = CGFloat((times[f] - times[a.frame]) / max(times[b.frame] - times[a.frame], 1e-9))
            expected[k] = lerp(a.rect, b.rect, u)
        }
        let inPlace = expected.filter { k, e in (readAt[k] ?? []).contains { sameArea(tracks[k].samples[$0].rect, e) } }.count
        let agrees = expected.count >= 3 && inPlace * 3 >= expected.count * 2
        guard agrees else {
            for (m, _) in at[f] ?? [] where tracks[m].samples.count <= 2 { cleared.insert(m) }
            continue
        }
        // A line read otherwise expected at the place of `s`, nothing of it read at f (`read`).
        func other(_ m: Int, _ s: TextSample, read: [Int: [Int]]) -> Bool {
            let key = normalizedForMatch(s.string)
            return expected.contains { k, e in k != m && read[k] == nil && sameArea(e, s.rect) && similar(k, key) < 0.3 }
        }
        // First the readings off their own place, then the short tracks, with those readings
        // left out: the line read off its place is then not read at f.
        // How far each line read at f is from where it was expected.
        var shifts: [(track: Int, dx: CGFloat, dy: CGFloat)] = []
        for (k, e) in expected { for i in readAt[k] ?? [] { let r = tracks[k].samples[i].rect; shifts.append((k, r.midX - e.midX, r.midY - e.midY)) } }
        var read = readAt
        for (m, i) in at[f] ?? [] {
            let s = tracks[m].samples[i], ss = tracks[m].samples
            guard upright(s), let own = expected[m], !sameArea(own, s.rect), other(m, s, read: readAt) else { continue }
            // Not when another line read at f moved the same way (a part of the screen scrolled),
            // nor when the reading before or after is at the same place (held there).
            let dx = s.rect.midX - own.midX, dy = s.rect.midY - own.midY, tolerance = s.rect.height / 2
            if shifts.contains(where: { $0.track != m && abs($0.dx - dx) <= tolerance && abs($0.dy - dy) <= tolerance }) { continue }
            if (i > 0 && sameArea(ss[i - 1].rect, s.rect)) || (i + 1 < ss.count && sameArea(ss[i + 1].rect, s.rect)) { continue }
            offPlace[m, default: []].insert(i)
            read[m] = read[m]?.filter { $0 != i }
            if read[m]?.isEmpty == true { read[m] = nil }
        }
        for (m, i) in at[f] ?? [] where tracks[m].samples.count <= 2 {
            let s = tracks[m].samples[i]
            let key = normalizedForMatch(s.string)
            let mixed = key.count >= 4 && upright(s) && other(m, s, read: read)
                && expected.contains { k, e in k != m && read[k] == nil && !sameArea(e, s.rect) && similar(k, key) >= 0.95 }
            if mixed { mixedUp.insert(m) } else { cleared.insert(m) }
        }
    }
    // Built from samples alone (as `TrackBuilder` makes them), numbered again in order.
    return tracks.indices.filter { !(mixedUp.contains($0) && !cleared.contains($0)) }.enumerated().map { id, k in
        let off = offPlace[k] ?? []
        var t = TextTrack(id: id, samples: tracks[k].samples.enumerated().filter { !off.contains($0.offset) }.map(\.element))
        t.offPlace = tracks[k].samples.enumerated().filter { off.contains($0.offset) }.map(\.element)
        return t
    }
}

/// Information often continues on the next line: an address (building name, room number)
/// that matches no pattern by itself, and an email address, URL or number wrapped at any
/// point ("hanako.yamada@" / "example.com", "example" / ".com/yamada", "sato.ichi" /
/// "ro@example.jp", "080-0000-" / "2222"). Only one line further, from lines whose own text
/// matched, so a long paragraph is not swallowed.
/// - the line below an address: the whole line
/// - two lines whose last and first words, joined, make an email address, URL or number
///   across the join: both words
func addContinuations(_ tracks: inout [TextTrack], times: [Double], extend: Double, bounds: CGRect, size: CGSize) {
    let readings = tracks.map(distinctReadings)
    let lasts: [[(TextSample, Range<String.Index>)]] = readings.map { $0.compactMap { s in trailingWord(s.string).map { (s, $0) } } }
    let firsts: [[(TextSample, Range<String.Index>)]] = readings.map { $0.compactMap { s in leadingWord(s.string).map { (s, $0) } } }
    var changes: [(Int, TextKind, [CGRect])] = []
    for a in tracks.indices {
        let address = tracks[a].parts[.address] != nil
        guard address || !lasts[a].isEmpty else { continue }
        let (ta0, ta1) = (times[tracks[a].first] - extend, times[tracks[a].last] + extend)
        for b in tracks.indices where b != a && (address || !firsts[b].isEmpty) {
            // On screen at the same time (cheap, before comparing words or places).
            guard ta0 <= times[tracks[b].last], times[tracks[b].first] <= ta1 else { continue }
            if address, isLine(tracks[b], below: tracks[a], times: times, extend: extend, bounds: bounds) {
                changes.append((b, .address, [whole]))
            }
            guard !lasts[a].isEmpty, !firsts[b].isEmpty else { continue }
            var found: [(TextKind, TextSample, Range<String.Index>, TextSample, Range<String.Index>)] = []
            for (sa, ra) in lasts[a] {
                for (sb, rb) in firsts[b] {
                    if let kind = wrappedKind(String(sa.string[ra]), String(sb.string[rb])) { found.append((kind, sa, ra, sb, rb)) }
                }
            }
            guard !found.isEmpty, isLine(tracks[b], below: tracks[a], times: times, extend: extend, bounds: bounds)
            else { continue }
            for (kind, sa, ra, sb, rb) in found {
                changes.append((a, kind, [relativeBox(sa, range: ra, size: size, along: tracks[a].isTilted) ?? whole]))
                changes.append((b, kind, [relativeBox(sb, range: rb, size: size, along: tracks[b].isTilted) ?? whole]))
            }
        }
    }
    for (k, kind, parts) in changes where !parts.isEmpty {
        tracks[k].parts[kind] = mergeOverlapping((tracks[k].parts[kind] ?? []) + parts)
    }
}

/// Letters, digits, brackets and the symbols of addresses, URLs and numbers; "@" may have
/// spaces around it as read ("hanako.yamada @"), and so may groups of digits ("090 12").
private let wordChars = "(?:[A-Za-z0-9０-９._%+\\-‐－ー−/?=&#~:()（）\\[\\]]|\\s{0,2}[@＠]\\s{0,2}|(?<=[0-9０-９)）])\\s+(?=[0-9０-９(（]))+"

/// The first word of letters, digits and symbols of a line.
func leadingWord(_ s: String) -> Range<String.Index>? {
    guard let r = s.range(of: "^\\s*" + wordChars, options: .regularExpression) else { return nil }
    let start = s[r].firstIndex { !$0.isWhitespace } ?? r.lowerBound
    return start..<r.upperBound
}

/// The last word of letters, digits and symbols of a line.
func trailingWord(_ s: String) -> Range<String.Index>? {
    guard let r = s.range(of: wordChars + "\\s*$", options: .regularExpression) else { return nil }
    var end = r.upperBound
    while end > r.lowerBound, s[s.index(before: end)].isWhitespace { end = s.index(before: end) }
    return r.lowerBound..<end
}

/// The kind of information that `upper` (the end of a line) and `lower` (the start of the
/// next) make when joined, if a match crosses the join.
func wrappedKind(_ upper: String, _ lower: String) -> TextKind? {
    let u = upper.filter { !$0.isWhitespace }, l = lower.filter { !$0.isWhitespace }
    guard !u.isEmpty, !l.isEmpty else { return nil }
    let joined = u + l
    let join = joined.index(joined.startIndex, offsetBy: u.count)
    let crossing = findKinds(in: joined).filter { $0.1.lowerBound < join && $0.1.upperBound > join }.map(\.0)
    return [TextKind.email, .url, .number].first(where: crossing.contains)
}

/// `b` is the next line under `a`, at a frame where both are on screen (each continued
/// `extend` seconds, as when hidden): one where both were read if there is one, else one
/// where either was read (the other's place interpolated, or held where it was read: while
/// scrolling, two lines read once each at different frames are not matched). Overlapping `a`
/// sideways, with 1.5 lines to spare on either side (a wrapped value in a column, a centered
/// or right-aligned address). Two
/// lines that were never read together still match within `extend` (glare or a finger may
/// cover them in turn); a line of the next screen at the same place is hidden too then.
private func isLine(_ b: TextTrack, below a: TextTrack, times: [Double], extend: Double, bounds: CGRect) -> Bool {
    guard times[a.first] - extend <= times[b.last], times[b.first] - extend <= times[a.last] else { return false }
    let fa = Set(a.sampleFrames), fb = Set(b.sampleFrames)
    let both = fa.intersection(fb)
    for f in both.sorted() + fa.symmetricDifference(fb).sorted() {
        guard let ra = a.rect(atFrame: f, times: times, extend: extend, bounds: bounds),
              let rb = b.rect(atFrame: f, times: times, extend: extend, bounds: bounds)
        else { continue }
        if a.isTilted || b.isTilted {
            // On a slanted screen the upright boxes of neighbouring lines overlap, so the line
            // under an upright box was often another line beside it: compare along the slant.
            let angle = a.isTilted ? a.tilt(atFrame: f, times: times) : b.tilt(atFrame: f, times: times)
            if let sa = slantedBox(ra, angle: angle), let sb = slantedBox(rb, angle: angle) {
                if isNextLine(length: sa.length, height: sa.height, below: sb.center.minus(sa.center), angle: angle,
                              length: sb.length, height: sb.height) { return true }
                // Both slanted: the upright boxes say nothing. One upright line (too short to
                // measure, e.g. "402号"): either way, rather than leave it.
                if a.isTilted && b.isTilted { continue }
            }
            // No slanted line from the box (cut at the picture's edge): upright, as before.
        }
        let h = ra.height
        let gap = ra.minY - rb.maxY  // Core Image coordinates: y grows upward
        let column = rb.maxX > ra.minX - 1.5 * h && rb.minX < ra.maxX + 1.5 * h
        if gap > -0.3 * h, gap < 0.8 * h, column, rb.height > 0.7 * h, rb.height < 1.4 * h {
            return true
        }
    }
    return false
}

/// `isLine(below:)` in the frame of a line slanted by `angle`: `offset` from its centre to the
/// centre of the other line, which is the next line if just under it (across) and in the same
/// column (along), with about the same height.
func isNextLine(length la: CGFloat, height h: CGFloat, below offset: CGPoint, angle: CGFloat,
                length lb: CGFloat, height hb: CGFloat) -> Bool {
    let u = offset.x * cos(angle) + offset.y * sin(angle)   // along the line
    let v = -offset.x * sin(angle) + offset.y * cos(angle)  // across it, up
    let gap = -v - (h + hb) / 2
    let column = u + lb / 2 > -la / 2 - 1.5 * h && u - lb / 2 < la / 2 + 1.5 * h
    return gap > -0.3 * h && gap < 0.8 * h && column && hb > 0.7 * h && hb < 1.4 * h
}

private extension CGPoint {
    func minus(_ p: CGPoint) -> CGPoint { CGPoint(x: x - p.x, y: y - p.y) }
}

let whole = CGRect(x: 0, y: 0, width: 1, height: 1)

/// Box of a character range relative to the line box. On a slanted line (`along`), relative to
/// the line along its slant: from its start (0) to its end (1), as `slantedQuad` draws it.
func relativeBox(_ s: TextSample, range: Range<String.Index>, size: CGSize, along: Bool = false) -> CGRect? {
    guard let box = try? s.text?.boundingBox(for: range) else { return nil }
    if along {
        // Without the line's own corners, the whole line rather than a part measured upright.
        guard let c = s.corners, c.count == 4 else { return nil }
        let q = place(c, in: s.rect)
        let start = CGPoint(x: (q[0].x + q[3].x) / 2, y: (q[0].y + q[3].y) / 2)
        let end = CGPoint(x: (q[1].x + q[2].x) / 2, y: (q[1].y + q[2].y) / 2)
        let dx = end.x - start.x, dy = end.y - start.y, l2 = dx * dx + dy * dy
        guard l2 > 0 else { return nil }
        let us = [box.topLeft, box.topRight, box.bottomRight, box.bottomLeft].map { p -> CGFloat in
            let x = p.x * size.width - start.x, y = p.y * size.height - start.y
            return (x * dx + y * dy) / l2
        }
        let u0 = max(0, us.min()!), u1 = min(1, us.max()!)
        guard u1 > u0 else { return nil }
        return CGRect(x: u0, y: 0, width: u1 - u0, height: 1)
    }
    let b = VNImageRectForNormalizedRect(box.boundingBox, Int(size.width), Int(size.height))
    let r = s.rect
    guard r.width > 0, r.height > 0, !b.isEmpty else { return nil }
    // Vertically the whole line; horizontally the range (Vision's range boxes are often short).
    let x0 = max(0, (b.minX - r.minX) / r.width), x1 = min(1, (b.maxX - r.minX) / r.width)
    guard x1 > x0 else { return nil }
    return CGRect(x: x0, y: 0, width: x1 - x0, height: 1)
}

func mergeOverlapping(_ rects: [CGRect]) -> [CGRect] {
    var out: [CGRect] = []
    for r in rects.sorted(by: { $0.minX < $1.minX }) {
        if let i = out.firstIndex(where: { $0.intersects(r) || $0.maxX >= r.minX - 0.01 && $0.minX <= r.maxX }) {
            out[i] = out[i].union(r)
        } else {
            out.append(r)
        }
    }
    return out
}

private let patterns: [(TextKind, NSRegularExpression)] = {
    let digit = "[0-9０-９]"
    let sep = "[\\-‐－ーｰ−\\s()（）.．]"
    let defs: [(TextKind, String)] = [
        (.email, "[A-Za-z0-9._%+\\-]+\\s{0,2}[@＠]\\s{0,2}[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}"),
        (.url, "(?i)(?:https?://|www\\.)[^\\s　]+"),
        (.url, "(?i)[A-Za-z0-9\\-]+(?:\\.[A-Za-z0-9\\-]+)*\\.(?:com|net|org|jp|io|me|info|biz|co|app|dev|ee|ly|gl|tokyo|uk|us|tv|ai|gg|cc|to|fm|so|xyz|site|online|shop|link|page)(?![A-Za-z0-9\\-])(?:/[^\\s　]*)?"),
        (.number, "(?:(?<![A-Za-zＡ-Ｚａ-ｚ])[A-Za-zＡ-Ｚａ-ｚ]{1,4}[\\-‐－]?)?\(digit)(?:\(digit)|\(sep)){4,}\(digit)"),
        (.address, "〒\\s?\(digit){3}[\\-‐－ーｰ−]\(digit){4}|(?<![0-9０-９\\-‐－ーｰ−])\(digit){3}[\\-‐－ーｰ−]\(digit){4}(?![0-9０-９\\-‐－ーｰ−])"),
        (.address, "(?:東京都|北海道|(?:京都|大阪)府|[^\\s　、。]{2,3}県)[^\\s　、。]*"),
        (.address, "[^\\s　、。]{1,6}[市区町村郡][^\\s　、。]*[0-9０-９一二三四五六七八九十丁目番地号][^\\s　、。]*"),
    ]
    return defs.map { ($0.0, try! NSRegularExpression(pattern: $0.1)) }
}()

/// Personal information in one line: (kind, range).
func findKinds(in s: String) -> [(TextKind, Range<String.Index>)] {
    let ns = NSRange(s.startIndex..., in: s)
    var out: [(TextKind, Range<String.Index>)] = []
    for (kind, re) in patterns {
        for m in re.matches(in: s, range: ns) {
            guard let r = Range(m.range, in: s) else { continue }
            if kind == .number && s[r].filter(\.isNumber).count < 6 { continue }
            // The rest of the line after the start of an address is still the address
            // (ward, town, building); the patterns stop at the first unusual character.
            out.append((kind, kind == .address ? r.lowerBound..<s.endIndex : r))
        }
    }
    out += nameRanges(in: s).map { (.name, $0) }
    return out
}

/// Ranges of `words` (normalized with `normalizedForMatch`) in `s`, ignoring spaces, letter
/// case and full/half width (recognition drops or adds spaces).
func wordRanges(in s: String, words: [String]) -> [Range<String.Index>] {
    var chars: [Character] = []
    var index: [String.Index] = []
    for i in s.indices where !s[i].isWhitespace {
        // One character may unify into several ("㈱" → "(株)"); each points back to it.
        for c in String(s[i]).precomposedStringWithCompatibilityMapping.lowercased() where !c.isWhitespace {
            chars.append(c)
            index.append(i)
        }
    }
    var out: [Range<String.Index>] = []
    for w in words {
        let wc = Array(w)
        guard !wc.isEmpty, wc.count <= chars.count else { continue }
        var k = 0
        while k + wc.count <= chars.count {
            if Array(chars[k..<(k + wc.count)]) == wc {
                out.append(index[k]..<withFollowingName(s, after: s.index(after: index[k + wc.count - 1])))
                k += wc.count
            } else {
                k += 1
            }
        }
    }
    return out
}

/// A family name is usually followed by the given name ("鈴木 次郎", "佐藤一郎"): extend a word
/// over an optional space and up to 4 kanji or katakana. Hiragana (particles, さん) stops it.
private func withFollowingName(_ s: String, after end: String.Index) -> String.Index {
    var i = end
    while i < s.endIndex, s[i].isWhitespace { i = s.index(after: i) }
    var out = end, n = 0
    while i < s.endIndex, n < 4, isNameCharacter(s[i]) {
        i = s.index(after: i)
        out = i
        n += 1
    }
    return out
}

private func isNameCharacter(_ c: Character) -> Bool {
    guard let u = c.unicodeScalars.first, c.unicodeScalars.count == 1 else { return false }
    switch u.value {
    case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0x3005: return true  // kanji, 々
    case 0x30A1...0x30FA, 0x30FC: return true  // katakana, ー
    default: return false
    }
}

extension Array {
    /// First index whose element satisfies `pred` (the array is sorted so that `pred` is
    /// false, then true).
    func partitionIndex(_ pred: (Element) -> Bool) -> Int {
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if pred(self[mid]) { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }
}

/// For comparing text: compatibility forms unified (full-width letters and digits), spaces
/// removed, lower case.
func normalizedForMatch(_ s: String) -> String {
    String(s.precomposedStringWithCompatibilityMapping.filter { !$0.isWhitespace }).lowercased()
}

/// 1 − edit distance / longer length.
func similarity(_ a: String, _ b: String) -> Double {
    if a == b { return 1 }
    let x = Array(a), y = Array(b)
    guard !x.isEmpty, !y.isEmpty else { return 0 }
    var prev = Array(0...y.count), cur = [Int](repeating: 0, count: y.count + 1)
    for i in 1...x.count {
        cur[0] = i
        for j in 1...y.count {
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
        }
        swap(&prev, &cur)
    }
    return 1 - Double(prev[y.count]) / Double(max(x.count, y.count))
}
