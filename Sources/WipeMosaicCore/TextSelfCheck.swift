import AVFoundation
import CoreImage
import Vision

// Checks of the rules of `ScreenText.mask` and of joining lines, run by `selfCheck`
// (SelfCheck.swift) on synthetic tracks.

/// Synthetic tracks for the rules of `mask` and `addContinuations` (no recognition needed).
func selfCheckMask() -> [String] {
    var failures: [String] = []
    func expect(_ ok: Bool, _ what: String) { if !ok { failures.append(what) } }
    let size = CGSize(width: 1000, height: 1000)
    let bounds = CGRect(origin: .zero, size: size)
    let times = (0..<120).map { Double($0) / 30 }
    func track(_ id: Int, _ frames: ClosedRange<Int>, y: CGFloat, _ text: String, x: CGFloat = 100) -> TextTrack {
        var t = TextTrack(id: id, samples: [frames.lowerBound, frames.upperBound].map {
            TextSample(frame: $0, rect: CGRect(x: x, y: y, width: 600, height: 40), string: text, text: nil)
        })
        t.text = text
        return t
    }
    func screen(_ tracks: [TextTrack]) -> ScreenText {
        let entries = tracks.map {
            TextEntry(id: $0.id + 1, text: $0.text, trackIDs: [$0.id], firstFrame: $0.first,
                      frameCount: $0.last - $0.first + 1, kinds: Set($0.parts.keys))
        }
        return ScreenText(times: times, fps: 30, size: size, tracks: tracks, entries: entries, extend: 0.1, cuts: [])
    }
    let all = Set(TextKind.allCases)
    // Vision gave three lines each another's text at frame 6 (read every 3 frames): the address
    // line's box the text of the line below, that one's the URL of a later message; the URL's
    // own line and the address line's text were left out.
    func read(_ id: Int, _ frames: [Int], y: CGFloat, _ text: String, at moved: [Int: CGFloat] = [:]) -> TextTrack {
        TextTrack(id: id, samples: frames.map {
            TextSample(frame: $0, rect: CGRect(x: 100, y: moved[$0] ?? y, width: 600, height: 40), string: text, text: nil)
        })
    }
    let addressLine = read(0, [0, 3, 9, 12], y: 600, "送り先の住所は〒100-0000東京")
    let lineBelow = read(1, [0, 3, 6, 9, 12], y: 550, "都みほん区サンプル町1-2-3", at: [6: 600])
    let urlLine = read(2, [0, 3, 9, 12], y: 200, "https://example.com/share/abc1")
    let urlThere = read(3, [6], y: 550, "https://example.com/share/abc1")
    // The other messages on screen, read where they are at every frame.
    let rest = ["おはようございます", "よろしくお願いします", "ありがとうございます", "電話番号も教えてください",
                "了解です", "はい、大丈夫です"].enumerated().map { k, text in read(4 + k, [0, 3, 6, 9, 12], y: 700 + CGFloat(k) * 50, text) }
    let unmixed = droppingMixedUpReadings([addressLine, lineBelow, urlLine, urlThere] + rest, times: times)
    expect(unmixed.count == 9 && unmixed.map(\.id) == Array(0..<9) && unmixed[1].samples.map(\.frame) == [0, 3, 9, 12]
           && unmixed[1].offPlace.map(\.frame) == [6] && unmixed[0].samples.count == 4 && unmixed[2].samples.count == 4,
           "mixed up: the text read at another line's place is dropped, and the line read off its place")
    // The same text really there: the screen jumped (the line at its place is not read there
    // after it), or the text is on screen twice (read at its other place too).
    let jumped = droppingMixedUpReadings([read(0, [0, 3], y: 600, "送り先の住所は〒100-0000東京"), urlLine,
                                          read(3, [6], y: 600, "https://example.com/share/abc1")] + rest, times: times)
    let twice = droppingMixedUpReadings([read(0, [0, 3, 9, 12], y: 600, "送り先の住所は〒100-0000東京"),
                                         read(2, [0, 3, 6, 9, 12], y: 200, "https://example.com/share/abc1"),
                                         read(3, [6], y: 600, "https://example.com/share/abc1")] + rest, times: times)
    // Another screen for a moment (most lines not read where expected), then back.
    let others = rest.map { read($0.id, [0, 3, 9, 12], y: $0.samples[0].rect.minY, $0.samples[0].string) }
    let moment = droppingMixedUpReadings([addressLine, urlLine, read(3, [6], y: 600, "https://example.com/share/abc1")] + others, times: times)
    expect(jumped.count == 9 && twice.count == 9 && moment.count == 9, "mixed up: text really at the place is kept")
    // Only part of the screen scrolled by a line and stopped (a list beside still menus): the
    // line pushed out at the top was not read at that frame nor when pinned, and comes back.
    // The lines moved together, so none is off its place.
    let still = (0..<12).map { k in read(20 + k, [0, 3, 6, 30, 33], y: 100 + CGFloat(k) * 50, "メニューの項目その\(["一", "二", "三", "四", "五", "六", "七", "八", "九", "十", "壱", "弐"][k])") }
    let list = ["送り先の住所は〒100-0000東京", "都みほん区サンプル町1-2-3", "ハイツ402です", "090-0000-1111です"].enumerated().map { k, text in
        TextTrack(id: 40 + k, samples: (k == 3 ? [0, 3, 33] : [0, 3, 6, 30, 33]).map { f in
            TextSample(frame: f, rect: CGRect(x: 800, y: 300 + CGFloat(k) * 50 + (f == 6 || f == 30 ? 50 : 0), width: 600, height: 40), string: text, text: nil)
        })
    }
    let region = droppingMixedUpReadings(still + list, times: times)
    expect(region.count == 16 && region.allSatisfy { $0.offPlace.isEmpty }, "mixed up: lines that moved together are not off their place")
    // The same, scrolled back at once (a notch down and up): no reading at the same place.
    let stillBack = still.map { read($0.id, [0, 3, 6, 9, 12], y: $0.samples[0].rect.minY, $0.samples[0].string) }
    let scrolledBack: [TextTrack] = list.map { (t: TextTrack) -> TextTrack in
        let frames: [Int] = t.id == 43 ? [0, 3, 9, 12] : [0, 3, 6, 9, 12]
        let first = t.samples[0]
        let samples: [TextSample] = frames.map { (f: Int) -> TextSample in
            let dy: CGFloat = f == 6 ? 50 : 0
            return TextSample(frame: f, rect: first.rect.offsetBy(dx: 0, dy: dy), string: first.string, text: nil)
        }
        return TextTrack(id: t.id, samples: samples)
    }
    let regionBack = droppingMixedUpReadings(stillBack + scrolledBack, times: times)
    expect(regionBack.count == 16 && regionBack.allSatisfy { $0.offPlace.isEmpty }, "mixed up: lines that moved and came back together are not off their place")
    // One line moved onto another's place and stayed there (pinned at the same place): the
    // reading is held there, not taken as a mix-up.
    let covered = read(10, [0, 3, 33], y: 600, "送り先の住所は〒100-0000東京")
    let stayed = read(11, [0, 3, 6, 30, 33], y: 550, "090-0000-1111です", at: [6: 600, 30: 600])
    let heldThere = droppingMixedUpReadings([covered, stayed] + rest, times: times)
    expect(heldThere.allSatisfy { $0.offPlace.isEmpty }, "mixed up: a line that moved and stayed is not off its place")
    // A new line's reading copied to the frame since when the picture was still (`newSince`):
    // no line is read at that frame, so it is not judged there, and the track is kept.
    let sinceStill = TextTrack(id: 3, samples: [4, 6].map {
        TextSample(frame: $0, rect: CGRect(x: 100, y: 550, width: 600, height: 40), string: "https://example.com/share/abc1", text: nil)
    })
    let keptSince = droppingMixedUpReadings([addressLine, lineBelow, urlLine, sinceStill] + rest, times: times)
    expect(keptSince.count == 10, "mixed up: a track with a reading copied back to a still frame is kept")
    // The line expected at the place read differently (路線情服 / 路線價報): the same line, kept.
    // The same words elsewhere (another line on screen, read 路線價報 once) are not read at that frame.
    let sameWords = TextTrack(id: 2, samples: zip([0, 3, 9, 12], ["路续情報", "路線價報", "路续情報", "路续情報"]).map { f, text in
        TextSample(frame: f, rect: CGRect(x: 100, y: 200, width: 600, height: 40), string: text, text: nil)
    })
    let misreadAt = droppingMixedUpReadings([read(0, [0, 3, 9, 12], y: 600, "路線情服"), lineBelow, sameWords,
                                             read(3, [6], y: 600, "路線價報")] + rest, times: times)
    expect(misreadAt.count == 10, "mixed up: a line read differently at its own place is kept")
    let shortText = droppingMixedUpReadings([addressLine, lineBelow, read(2, [0, 3, 9, 12], y: 200, "ね"), read(3, [6], y: 550, "ね")] + rest, times: times)
    expect(shortText.count == 10, "mixed up: a track of a few characters is kept")
    // The reading off its place may be the only one that reads the number: it still counts.
    let misread = read(1, [0, 3, 9, 12], y: 550, "O9O-OOOO-1111です")
    let numberLine = TextTrack(id: 1, samples: (misread.samples + [TextSample(frame: 6, rect: CGRect(x: 100, y: 600, width: 600, height: 40),
                                                                                string: "090-0000-1111です", text: nil)]).sorted { $0.frame < $1.frame })
    let offNumber = droppingMixedUpReadings([addressLine, numberLine, urlLine] + rest, times: times)
    expect(offNumber[1].offPlace.count == 1 && kindParts(offNumber[1], size: size)[.number] != nil,
           "mixed up: the text of a reading off its place still finds the number")
    // Scrolled by whole lines at once and then still (an arrow key, a notch of the wheel):
    // every line is read one, two or three lines further at frame 6, and again when the
    // picture is pinned at 30. No reading is a mix-up.
    for step in 1...3 {
        let lines = (0..<6).map { k in
            TextTrack(id: k, samples: [0, 3, 6, 30].map { f in
                TextSample(frame: f, rect: CGRect(x: 100, y: 300 + CGFloat(k) * 50 + (f >= 6 ? CGFloat(step) * 50 : 0), width: 600, height: 40),
                           string: ["送り先の住所は〒100-0000東京", "都みほん区サンプル町1-2-3", "ハイツ402です",
                                    "ありがとうございます", "090-0000-1111です", "hanako.yamada@example.com"][k], text: nil)
            })
        }
        let kept = droppingMixedUpReadings(lines, times: times)
        expect(kept.count == 6 && kept.allSatisfy { $0.samples.count == 4 && $0.offPlace.isEmpty }, "mixed up: a scroll by \(step) lines at once keeps every reading")
    }
    let phone = CGRect(x: 0.1, y: 0, width: 0.3, height: 1), link = CGRect(x: 0.6, y: 0, width: 0.3, height: 1)

    // A chain read differently: misread first (nothing found), then the phone number, then a
    // misread with only the URL. Every track gets both parts, and the gaps stay hidden.
    var a = track(0, 0...10, y: 500, "電話 O9O-1234-5678 https://x.jp")
    var b = track(1, 20...30, y: 500, "電話 090-1234-5678 https://x.jp")
    var c = track(2, 40...50, y: 500, "電話 O9O-1234-S678 https://x.jp")
    a.parts = [:]
    b.parts = [.number: [phone], .url: [link]]
    c.parts = [.url: [link]]
    let m = screen([a, b, c]).mask(TextMaskOptions(kinds: all, words: [], lines: []))
    expect(m.frames[5].count == 2, "chain: misread first track gets both parts (\(m.frames[5].count))")
    expect(m.frames[45].count == 2, "chain: later track keeps the earlier parts (\(m.frames[45].count))")
    expect(!m.frames[15].isEmpty && !m.frames[35].isEmpty, "chain: gaps hidden")
    expect(m.hidden == [1, 2, 3], "chain: all entries hidden (\(m.hidden.sorted()))")

    // Not a continuation: other text at the place.
    var e = track(0, 0...10, y: 500, "電話 090-1234-5678")
    e.parts = [.number: [phone]]
    var f = track(1, 20...30, y: 500, "まったく別の文章がここに出ています")
    f.parts = [:]
    let m3 = screen([e, f]).mask(TextMaskOptions(kinds: all, words: [], lines: []))
    expect(m3.frames[25].isEmpty, "chain: other text is not hidden")

    // An address continues on the line below, also while scrolling with the two lines read at
    // different frames. (Wrapped URLs need recognized text with boxes: checked on screen.mov.)
    var addr = TextTrack(id: 0, samples: [
        TextSample(frame: 0, rect: CGRect(x: 100, y: 600, width: 600, height: 40), string: "東京都みほん区", text: nil),
        TextSample(frame: 30, rect: CGRect(x: 100, y: 300, width: 600, height: 40), string: "東京都みほん区", text: nil),
    ])
    addr.parts = [.address: [CGRect(x: 0, y: 0, width: 1, height: 1)]]
    let below = TextTrack(id: 1, samples: [
        TextSample(frame: 3, rect: CGRect(x: 100, y: 540, width: 500, height: 40), string: "テストハイツ402", text: nil),
        TextSample(frame: 27, rect: CGRect(x: 100, y: 270, width: 500, height: 40), string: "テストハイツ402", text: nil),
    ])
    var tracks = [addr, below]
    addContinuations(&tracks, times: times, extend: 0.1, bounds: bounds, size: size)
    expect(tracks[1].parts[.address] != nil, "address: the line below is hidden")
    // Each line read once, at different frames (glare moving over a filmed screen).
    var once = TextTrack(id: 0, samples: [
        TextSample(frame: 10, rect: CGRect(x: 100, y: 600, width: 600, height: 40), string: "東京都みほん区", text: nil)])
    once.parts = [.address: [CGRect(x: 0, y: 0, width: 1, height: 1)]]
    let onceBelow = TextTrack(id: 1, samples: [
        TextSample(frame: 13, rect: CGRect(x: 100, y: 550, width: 500, height: 40), string: "テストハイツ402", text: nil)])
    var tracks2 = [once, onceBelow]
    addContinuations(&tracks2, times: times, extend: 0.35, bounds: bounds, size: size)
    expect(tracks2[1].parts[.address] != nil, "address: lines read once at different frames")
    // Two lines shown together but read at different frames (glare, a finger), each read
    // twice: still the line below.
    var upper = track(0, 10...11, y: 600, "東京都みほん区")
    upper.parts = [.address: [whole]]
    var tracks3 = [upper, track(1, 12...13, y: 555, "テストハイツ402")]
    addContinuations(&tracks3, times: times, extend: 0.35, bounds: bounds, size: size)
    expect(tracks3[1].parts[.address] != nil, "address: lines shown together, read at different frames")
    // A centered address (an order screen): the shorter line below is not left-aligned.
    var centered = [upper, track(1, 10...11, y: 555, "テストハイツ402", x: 300)]
    addContinuations(&centered, times: times, extend: 0.35, bounds: bounds, size: size)
    expect(centered[1].parts[.address] != nil, "address: centered line below")
    // A long line under a short address (a centered or right-aligned value column), and a
    // line starting a little right of a short one.
    var short = track(0, 10...11, y: 600, "東京都渋谷区", x: 300)
    short.parts = [.address: [whole]]
    var longBelow = [short, track(1, 10...11, y: 555, "神宮前1-2-3 テストハイツ402号室", x: 100)]
    addContinuations(&longBelow, times: times, extend: 0.35, bounds: bounds, size: size)
    expect(longBelow[1].parts[.address] != nil, "address: longer centered line below")
    var tiny = TextTrack(id: 0, samples: [10, 11].map {
        TextSample(frame: $0, rect: CGRect(x: 100, y: 600, width: 30, height: 40), string: "東京都", text: nil)
    })
    tiny.parts = [.address: [whole]]
    var indentedBelow = [tiny, track(1, 10...11, y: 555, "テストハイツ402", x: 140)]
    addContinuations(&indentedBelow, times: times, extend: 0.35, bounds: bounds, size: size)
    expect(indentedBelow[1].parts[.address] != nil, "address: line below starting right of a short one")
    // A short address with the line below starting a little right of its end.
    var shortRight = TextTrack(id: 0, samples: [10, 11].map {
        TextSample(frame: $0, rect: CGRect(x: 100, y: 600, width: 100, height: 40), string: "東京都", text: nil)
    })
    shortRight.parts = [.address: [whole]]
    var rightBelow = [shortRight, track(1, 10...11, y: 555, "テストハイツ402", x: 210)]
    addContinuations(&rightBelow, times: times, extend: 0.35, bounds: bounds, size: size)
    expect(rightBelow[1].parts[.address] != nil, "address: line below starting just right of a short one")
    // Wrapped email address, URL and number through addContinuations (no recognized text:
    // the words are hidden with whole-line boxes).
    for (u, l) in [("共有先は example", ".com/private/yamada"), ("電話は 080-0000-", "2222 です"),
                   ("メールは sato.ichi", "ro@example.jp です")] {
        var w = [track(0, 0...10, y: 600, u), track(1, 0...10, y: 555, l, x: 140)]
        addContinuations(&w, times: times, extend: 0.35, bounds: bounds, size: size)
        expect(!w[0].parts.isEmpty && !w[1].parts.isEmpty, "wrap through addContinuations: \(u) / \(l)")
    }
    var plain = [track(0, 0...10, y: 600, "よろしくお願いします"), track(1, 0...10, y: 555, "はい")]
    addContinuations(&plain, times: times, extend: 0.35, bounds: bounds, size: size)
    expect(plain[0].parts.isEmpty && plain[1].parts.isEmpty, "wrap: ordinary lines are not hidden")

    // Steady boxes: a line read every 3 frames while scrolling 2 px a frame, its box off by a
    // few pixels each time, then speeding up, then a jump the tracker joined. What is hidden
    // must still contain what the recognized boxes alone hid (interpolated, continued before
    // and after, with the old margins), at every frame; and the blocks must move with the line.
    let jit: [CGFloat] = [0, 2, -2, 1, -1, 2, 0, -2, 1, -1, 0, 2, -1]
    let jitH: [CGFloat] = [0, 3, -3, 2, -2, 0, 3, -1, -3, 1, 2, -2, 0]
    let sampleFrames = Array(stride(from: 6, through: 96, by: 3))
    var scroll = TextTrack(id: 0, samples: sampleFrames.enumerated().map { i, f in
        var y = 200 + 2 * CGFloat(f) + jit[i % jit.count]
        if f > 48 { y += 0.04 * CGFloat((f - 48) * (f - 48)) }
        if f >= 75 { y += 160 }
        return TextSample(frame: f, rect: CGRect(x: 100 + jit[(i + 4) % jit.count], y: y, width: 600, height: 40 + jitH[i % jitH.count]),
                          string: "090-1234-5678", text: nil)
    })
    scroll.text = "090-1234-5678"
    scroll.parts = [.number: [phone]]
    let extendS = 0.1
    func oldHidden(_ f: Int) -> CGRect? {  // the recognized boxes and margins alone
        let sm = scroll.samples, t = times[f]
        var line: CGRect, margin = CGSize.zero
        if f < sm[0].frame {
            guard times[sm[0].frame] - t <= extendS + 1e-6 else { return nil }
            let k = min(1.5, CGFloat((times[sm[0].frame] - t) / (times[sm[1].frame] - times[sm[0].frame])))
            line = lerp(sm[0].rect, sm[1].rect, -k).union(sm[0].rect).intersection(bounds)
        } else if f > sm[sm.count - 1].frame {
            let a = sm[sm.count - 2], b = sm[sm.count - 1]
            guard t - times[b.frame] <= extendS + 1e-6 else { return nil }
            let k = min(1.5, CGFloat((t - times[b.frame]) / (times[b.frame] - times[a.frame])))
            line = lerp(b.rect, a.rect, -k).union(b.rect).intersection(bounds)
        } else if let b = sm.firstIndex(where: { $0.frame >= f }), sm[b].frame != f, b > 0 {
            let ra = sm[b - 1].rect, rb = sm[b].rect
            let u = (t - times[sm[b - 1].frame]) / (times[sm[b].frame] - times[sm[b - 1].frame])
            line = lerp(ra, rb, CGFloat(u))
            let spread = CGFloat(1.6 * u * (1 - u))
            margin = CGSize(width: abs(rb.midX - ra.midX) * spread, height: abs(rb.midY - ra.midY) * spread)
        } else {
            line = sm.first { $0.frame == f }!.rect
        }
        let h = line.height
        let r = CGRect(x: line.minX + phone.minX * line.width, y: line.minY + phone.minY * line.height,
                       width: phone.width * line.width, height: phone.height * line.height)
        return r.insetBy(dx: -h * 0.35 - margin.width, dy: -h * 0.3 - margin.height).intersection(bounds)
    }
    scroll.makeSteady(times: times)
    expect(!scroll.steady.isEmpty && scroll.steady.contains { $0.slack != .zero }, "steady: boxes are fitted")
    let sm = screen([scroll]).mask(TextMaskOptions(kinds: all, words: [], lines: []))
    for f in times.indices {
        guard let old = oldHidden(f), !old.isEmpty else { continue }
        let new = sm.frames[f]
        expect(new.contains { $0.insetBy(dx: -0.01, dy: -0.01).contains(old) },
               "steady: frame \(f) hides what the recognized boxes hid (\(old) in \(new))")
        expect(sm.anchors[f].count == new.count, "steady: an anchor for every box at frame \(f)")
    }
    let ys = (8...44).compactMap { sm.anchors[$0].first?.y }
    let steps = zip(ys, ys.dropFirst()).map { $1 - $0 }
    expect(ys.count == 37 && steps.allSatisfy { abs($0 - 2) <= 1 }, "steady: blocks move with the line (steps \(steps))")

    // Matching lines to tracks while scrolling 26 px per recognition (3 frames).
    let scr = CGSize(width: 900, height: 1900)
    func box(_ y: CGFloat, x: CGFloat = 60, w: CGFloat = 580) -> CGRect { CGRect(x: x, y: y, width: w, height: 44) }
    let body = ["おはようございます", "送り先の住所は", "ありがとうございます", "了解です"]
    var prevTracks = body.enumerated().map { (box(400 + CGFloat($0) * 150), $1, 60) }
    prevTracks.append((box(1800), "山田 花子", 60))  // fixed header
    prevTracks.append((box(500, x: 240, w: 600), "https://example.com/share/abc123", 60))
    // The URL is not read this time; the same URL in another message 660 px away is.
    var now = body.enumerated().map { (box(426 + CGFloat($0) * 150), $1) }
    now.append((box(1800), "山田 花子"))
    now.append((box(1160), "https://example.com/share/abc123"))
    var got = matchLines(now, to: prevTracks, frame: 63, size: scr)
    expect(!got.contains { $0.line == 5 }, "match: the same text far away, moving unlike the rest, is not joined")
    expect(got.count == 5, "match: the other lines are joined (\(got.count))")
    // A line misread (similar text) is joined when it moves with the rest, not when it jumps.
    now[1] = (box(576), "送り先の住所わ")
    got = matchLines(now, to: prevTracks, frame: 63, size: scr)
    expect(got.contains { $0.line == 1 && $0.track == 1 }, "match: misread line moving with the rest is joined")
    now[1] = (box(1176), "送り先の住所わ")
    got = matchLines(now, to: prevTracks, frame: 63, size: scr)
    expect(!got.contains { $0.line == 1 }, "match: misread line far off is not joined")
    // Back after two missed recognitions: three times the motion.
    var late = prevTracks
    late[2] = (box(400 + 2 * 150 - 52), "ありがとうございます", 54)
    now[1] = (box(576), "送り先の住所は")
    now[2] = (box(726), "ありがとうごさいます")
    got = matchLines(now, to: late, frame: 63, size: scr)
    expect(got.contains { $0.line == 2 && $0.track == 2 }, "match: a line back after missed recognitions is joined")
    // A line cut at the picture edge (narrower) moving sideways with the rest.
    let side = [(box(400, x: 100), "おはようございます", 60), (box(600, x: 100), "ありがとうございます", 60),
                (box(800, x: 100, w: 700), "電話は 090-1234-5678 です", 60)]
    let sideNow = [(box(400, x: 40), "おはようございます"), (box(600, x: 40), "ありがとうございます"),
                   (box(800, x: 40, w: 500), "電話は 090-1234-56")]
    got = matchLines(sideNow, to: side, frame: 63, size: scr)
    expect(got.contains { $0.line == 2 && $0.track == 2 }, "match: a line cut at the edge is joined by its other edge")
    // No pair of the same text: similar text is joined as before.
    got = matchLines([(box(1000), "送り先の住所わ")], to: [(box(400), "送り先の住所は", 60)], frame: 63, size: scr)
    expect(got.count == 1, "match: without a reference, a similar line is joined as before")

    // QR codes are hidden along their corners (slanted), not by the upright box around them.
    func rotated(_ c: CGPoint, side: CGFloat, degrees: CGFloat) -> [CGPoint] {
        let r = side / 2 * sqrt(2), a0 = degrees * .pi / 180
        return [135, 45, -45, -135].map { k in
            let a = a0 + CGFloat(k) * .pi / 180
            return CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
        }
    }
    func contains(_ q: [CGPoint], _ p: CGPoint) -> Bool { quadContains(q, p) }
    let sq = rotated(CGPoint(x: 500, y: 500), side: 100, degrees: 30)
    expect(abs(abs(signedArea(outset(sq, by: 10))) - 120 * 120) < 1, "code: outset moves every edge by the distance")
    expect(abs(abs(signedArea(outset(Array(sq.reversed()), by: 10))) - 120 * 120) < 1, "code: outset works either way round")
    func codeTrack(_ id: Int, _ frames: [Int], at c: CGPoint, shift: Int = 0, places: [Int: CGPoint] = [:]) -> TextTrack {
        var t = TextTrack(id: id, samples: frames.map { f in
            let q = rotated(places[f] ?? c, side: 100, degrees: 30), box = boundingBox(q)
            let rel = (0..<4).map { k in q[(k + shift) % 4] }.map { CGPoint(x: ($0.x - box.minX) / box.width, y: ($0.y - box.minY) / box.height) }
            return TextSample(frame: f, rect: box, string: codeText, text: nil, corners: rel)
        })
        t.isCode = true
        t.text = codeText
        t.parts = [.qr: [whole]]
        t.makeSteady(times: times)
        return t
    }
    func codeScreen(_ tracks: [TextTrack], cuts: [Int]) -> ScreenText {
        let e = TextEntry(id: 1, text: codeText, trackIDs: tracks.map(\.id), firstFrame: 0, frameCount: 1, kinds: [.qr])
        return ScreenText(times: times, fps: 30, size: size, tracks: tracks, entries: [e], extend: 0.1, cuts: cuts)
    }
    let qa = codeTrack(0, [0, 5, 10], at: CGPoint(x: 300, y: 500)), qb = codeTrack(1, [30, 35, 40], at: CGPoint(x: 700, y: 500))
    let qo = TextMaskOptions(kinds: [.qr], words: [], lines: [])
    let qm = codeScreen([qa, qb], cuts: []).mask(qo)
    let truth = rotated(CGPoint(x: 300, y: 500), side: 100, degrees: 30)
    expect(qm.frames[5].isEmpty && qm.codes[5].count == 1, "code: a quad, not a box (\(qm.frames[5].count) boxes, \(qm.codes[5].count) quads)")
    expect(qm.codes[5].first.map { q in truth.allSatisfy { contains(q, $0) } } ?? false, "code: the quad holds the code")
    // The corner of the upright box around the code is left alone.
    expect(qm.codes[5].first.map { !contains($0, CGPoint(x: boundingBox(truth).minX + 2, y: boundingBox(truth).minY + 2)) } ?? false,
           "code: the corner of the box around a slanted code is not hidden")
    expect(qm.codes[20].contains { abs(boundingBox($0).midX - 500) < 30 }, "code: across a gap it moves between the places")
    // Without a cut, also held where it was and where it is next (as long as a code is held).
    expect(qm.codes[12].contains { q in truth.allSatisfy { contains(q, $0) } }, "code: across a gap, also held at its place")
    expect(qm.codes[12].contains { q in rotated(CGPoint(x: 500, y: 500), side: 100, degrees: 30).allSatisfy { contains(q, $0) } },
           "code: across a gap, the room is there from the first frame (it may have moved at once)")
    // Across a cut it jumps: at its old place before, at the new one after.
    let qc = codeScreen([qa, qb], cuts: [20]).mask(qo)
    expect(qc.codes[19].allSatisfy { boundingBox($0).midX < 400 } && !qc.codes[19].isEmpty, "code: before a cut, at its old place")
    expect(qc.codes[20].allSatisfy { boundingBox($0).midX > 600 } && !qc.codes[20].isEmpty, "code: after a cut, at its new place")
    expect(qc.codes[29].allSatisfy { q in rotated(CGPoint(x: 700, y: 500), side: 100, degrees: 30).allSatisfy { contains(q, $0) } },
           "code: after a cut, the new place holds the code")
    // Corners named differently (the code read turned): matched, not averaged into a smaller quad.
    let turned = codeScreen([qa, codeTrack(1, [30, 35, 40], at: CGPoint(x: 300, y: 500), shift: 1)], cuts: []).mask(qo)
    expect(turned.codes[20].contains { q in truth.allSatisfy { contains(q, $0) } }, "code: corners named after a turn are matched across a gap")
    let mixed = codeTrack(0, [0, 5, 10], at: CGPoint(x: 300, y: 500))
    var mixedSamples = mixed.samples
    mixedSamples[1].corners = mixedSamples[1].corners.map { c in (0..<4).map { c[($0 + 2) % 4] } }
    var mt = TextTrack(id: 0, samples: mixedSamples)
    mt.isCode = true
    mt.makeSteady(times: times)
    expect(mt.codeQuads(atFrame: 5, times: times, extend: 0).map { $0.allSatisfy { q in truth.allSatisfy { contains(q, $0) } } } ?? false,
           "code: corners named after a half turn are matched before averaging")
    // A cut between two readings of one track: the code jumps, it does not slide between.
    let jump = codeTrack(0, [10, 13], at: CGPoint(x: 300, y: 500), places: [13: CGPoint(x: 700, y: 500)])
    let jq = jump.codeQuads(atFrame: 11, times: times, extend: 0, cuts: [12]) ?? []
    expect(jq.count == 1 && truth.allSatisfy { contains(jq[0], $0) }, "code: before a cut within a track, at its old place")
    // The nearest code continues one, not the first to start (two codes side by side).
    let near0 = codeTrack(0, [0, 5, 10], at: CGPoint(x: 300, y: 500))
    let other = codeTrack(1, [15, 20], at: CGPoint(x: 420, y: 500)), same = codeTrack(2, [18, 25], at: CGPoint(x: 300, y: 500))
    let links = ScreenText.continuations(of: [near0, other, same], times: times, all: false) ?? [:]
    expect(links[0]?.id == 2, "code: continued by the nearest code (\(links[0]?.id ?? -1))")
    // Drawn: blocks inside the quad, the picture outside it (in the corner of its box).
    let checker = CIFilter(name: "CICheckerboardGenerator", parameters: [
        "inputCenter": CIVector(x: 0, y: 0), "inputColor0": CIColor.white, "inputColor1": CIColor.black, "inputWidth": 3,
    ])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 200, height: 200))
    let diamond = rotated(CGPoint(x: 100, y: 100), side: 100, degrees: 45)
    let drawn = codeBlocks(checker, over: checker, codes: [diamond], block: 12)
    var px = [UInt8](repeating: 0, count: 200 * 200 * 4)
    CIContext().render(drawn, toBitmap: &px, rowBytes: 800, bounds: CGRect(x: 0, y: 0, width: 200, height: 200), format: .RGBA8, colorSpace: nil)
    func gray(_ x: Int, _ y: Int) -> Int { Int(px[((199 - y) * 200 + x) * 4]) }
    let mid = (95...105).map { gray($0, 100) }
    expect(mid.allSatisfy { $0 > 40 && $0 < 215 }, "code: inside the quad the checker is averaged into blocks (\(mid))")
    let corner = (55...61).map { gray($0, 58) }
    expect(Set(corner).isSubset(of: [0, 255]) || corner.allSatisfy { $0 < 8 || $0 > 247 }, "code: outside the quad the picture is kept (\(corner))")
    // Fine blocks: still at most `maxCodeBlocks` across the code (finer ones left codes readable).
    let fine = codeBlocks(checker, over: checker, codes: [diamond], block: 2)
    CIContext().render(fine, toBitmap: &px, rowBytes: 800, bounds: CGRect(x: 0, y: 0, width: 200, height: 200), format: .RGBA8, colorSpace: nil)
    let row = (70...130).map { gray($0, 100) }
    let changes = zip(row, row.dropFirst()).filter { abs($0 - $1) > 6 }.count
    expect(changes <= 16, "code: few blocks across a code with a fine block size (\(changes) changes)")
    // A quad that cannot be straightened (corners crossed) is hidden by its box.
    let crossed = [diamond[0], diamond[2], diamond[1], diamond[3]]
    let boxed = codeBlocks(checker, over: checker, codes: [crossed], block: 12)
    CIContext().render(boxed, toBitmap: &px, rowBytes: 800, bounds: CGRect(x: 0, y: 0, width: 200, height: 200), format: .RGBA8, colorSpace: nil)
    let inBox = (95...105).map { gray($0, 100) } + (60...64).map { gray($0, 60) }
    expect(inBox.allSatisfy { $0 > 40 && $0 < 215 }, "code: a crossed quad is hidden by its box (\(inBox))")

    // Slanted lines (a screen filmed at an angle) are hidden along the line, not by the
    // upright box around it, which also covered the lines above and below.
    func slantedLine(_ c: CGPoint, length: CGFloat, height: CGFloat, degrees: CGFloat, from u0: CGFloat = 0, to u1: CGFloat = 1) -> [CGPoint] {
        let a = degrees * .pi / 180, d = CGPoint(x: cos(a), y: sin(a)), n = CGPoint(x: -sin(a), y: cos(a))
        func at(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
            CGPoint(x: c.x + (u - 0.5) * length * d.x + v * n.x, y: c.y + (u - 0.5) * length * d.y + v * n.y)
        }
        return [at(u0, height / 2), at(u1, height / 2), at(u1, -height / 2), at(u0, -height / 2)]
    }
    let line20 = slantedLine(CGPoint(x: 500, y: 500), length: 400, height: 24, degrees: 20)
    let back = slantedBox(boundingBox(line20), angle: 20 * .pi / 180)
    expect(back.map { abs($0.length - 400) < 0.01 && abs($0.height - 24) < 0.01 } ?? false, "slanted: length and height found again from the box")
    expect(slantedBox(boundingBox(line20), angle: 40 * .pi / 180) == nil, "slanted: none beyond 35°")
    func slantedTrack(_ id: Int, at c: CGPoint, length: CGFloat = 400, degrees: CGFloat = 20) -> TextTrack {
        var t = TextTrack(id: id, samples: [0, 15, 30].map { f in
            let q = slantedLine(c, length: length, height: 24, degrees: degrees), box = boundingBox(q)
            let rel = q.map { CGPoint(x: ($0.x - box.minX) / box.width, y: ($0.y - box.minY) / box.height) }
            return TextSample(frame: f, rect: box, string: "電話 090-0000-1111", text: nil, corners: rel)
        })
        t.text = "電話 090-0000-1111"
        t.measureTilt(times: times)
        t.parts = [.number: [CGRect(x: 0.5, y: 0, width: 0.25, height: 1)]]  // along the line
        t.makeSteady(times: times)
        return t
    }
    let numbers = TextMaskOptions(kinds: [.number], words: [], lines: [])
    let st = slantedTrack(0, at: CGPoint(x: 500, y: 500))
    expect(st.isTilted && abs(st.tilt(atFrame: 20, times: times) - 20 * .pi / 180) < 1e-6, "slanted: a long line is slanted")
    let slm = screen([st]).mask(numbers)
    let part = slantedLine(CGPoint(x: 500, y: 500), length: 400, height: 24, degrees: 20, from: 0.5, to: 0.75)
    expect(slm.frames[15].isEmpty && slm.slanted[15].count == 1, "slanted: hidden by a slanted box (\(slm.frames[15].count), \(slm.slanted[15].count))")
    if let q = slm.slanted[15].first {
        expect(part.allSatisfy { contains(q, $0) }, "slanted: the part is inside the slanted box")
        let rest = slantedLine(CGPoint(x: 500, y: 500), length: 400, height: 0, degrees: 20, from: 0.2, to: 0.3)
        let lb = boundingBox(line20)
        expect(!rest.contains { contains(q, $0) } && !contains(q, CGPoint(x: lb.minX + 2, y: lb.maxY - 2)),
               "slanted: the rest of the line and the empty corner of its box are kept")
    }
    expect(!slantedTrack(1, at: CGPoint(x: 500, y: 500), length: 40).isTilted, "slanted: a short line keeps its upright box")
    // At the edge of the picture the line may be cut: the whole upright box instead.
    let edgeBox = boundingBox(slantedLine(.zero, length: 400, height: 24, degrees: 20))
    let et = slantedTrack(2, at: CGPoint(x: -edgeBox.minX + 0.5, y: 500))
    let em = screen([et]).mask(numbers)
    expect(em.slanted[15].isEmpty && em.frames[15].count == 1 && (em.frames[15].first?.width ?? 0) >= edgeBox.width,
           "slanted: at the picture's edge the whole upright box is hidden")
    // The line under a slanted address is found along the slant: the short next line (its
    // upright box is lower than the address's) is hidden, a line far under it whose upright
    // box touches the address's is not.
    func slantedText(_ id: Int, at c: CGPoint, length: CGFloat, _ text: String) -> TextTrack {
        var t = TextTrack(id: id, samples: [0, 15, 30].map { f in
            let q = slantedLine(c, length: length, height: 24, degrees: 20), box = boundingBox(q)
            let rel = q.map { CGPoint(x: ($0.x - box.minX) / box.width, y: ($0.y - box.minY) / box.height) }
            return TextSample(frame: f, rect: box, string: text, text: nil, corners: rel)
        })
        t.text = text
        t.measureTilt(times: times)
        return t
    }
    let a20 = 20 * CGFloat.pi / 180
    var slantedAddress = [
        slantedText(0, at: CGPoint(x: 500, y: 500), length: 400, "東京都みほん区サンプル町1-2-3"),
        slantedText(1, at: CGPoint(x: 500 + 31.2 * sin(a20) - 100 * cos(a20), y: 500 - 31.2 * cos(a20) - 100 * sin(a20)),
                    length: 200, "ハイツ402です"),
        slantedText(2, at: CGPoint(x: 500, y: 350), length: 400, "はい、大丈夫です"),
    ]
    slantedAddress[0].parts = [.address: [whole]]
    addContinuations(&slantedAddress, times: times, extend: 0.35, bounds: bounds, size: size)
    expect(slantedAddress.allSatisfy(\.isTilted), "slanted: the address lines are slanted")
    expect(slantedAddress[1].parts[.address] != nil, "slanted: the short line under a slanted address is hidden")
    expect(slantedAddress[2].parts[.address] == nil, "slanted: a line far under a slanted address is kept")

    // A slanted line moving fast across itself, then lost: where it was, where its motion
    // takes it and everything between are hidden (two separate boxes left the middle bare).
    func slantedSamples(_ frames: [(Int, CGPoint)], length: CGFloat = 400, degrees: CGFloat = 20, readAt: CGFloat? = nil) -> TextTrack {
        var t = TextTrack(id: 0, samples: frames.map { f, c in
            let q = slantedLine(c, length: length, height: 24, degrees: degrees), box = boundingBox(q)
            let read = slantedLine(c, length: length, height: 24, degrees: readAt ?? degrees)
            let rel = read.map { CGPoint(x: ($0.x - box.minX) / box.width, y: ($0.y - box.minY) / box.height) }
            return TextSample(frame: f, rect: box, string: "電話 090-0000-1111", text: nil, corners: rel)
        })
        t.text = "電話 090-0000-1111"
        t.measureTilt(times: times)
        t.parts = [.number: [whole]]
        t.makeSteady(times: times)
        return t
    }
    let down = CGPoint(x: 60 * sin(a20), y: -60 * cos(a20))  // across the line, 60 px per 0.1 s
    func across(_ k: CGFloat) -> CGPoint { CGPoint(x: 500 + k * down.x, y: 500 + k * down.y) }
    let moving = slantedSamples([(0, across(0)), (3, across(1)), (6, across(2))])
    let movingMask = screen([moving]).mask(numbers)
    for (f, k) in [(7, 2.33), (9, 3.0)] as [(Int, CGFloat)] {
        let between = stride(from: 2, through: k, by: 0.25).map { across($0) }
        expect(movingMask.slanted[f].count == 1 && between.allSatisfy { p in movingMask.slanted[f].contains { contains($0, p) } },
               "slanted: after the last reading, from where it was to where it moves is hidden (frame \(f))")
    }
    // A slanted line read only once is continued before and after it (it crashed: the turn
    // between the last two readings was looked up).
    let readOnce = slantedSamples([(10, CGPoint(x: 500, y: 500))])
    let onceMask = screen([readOnce]).mask(numbers)
    expect(readOnce.isTilted && onceMask.slanted[11].count == 1 && onceMask.slanted[9].count == 1, "slanted: a line read once is hidden around it")
    // The slant read 0.6° too steep: the height found from the box shrinks by about a third,
    // and the ends of the long line turn 4 px off its axis; the measured height and the slack
    // of the slant keep them in.
    let steep = slantedSamples([(0, CGPoint(x: 500, y: 500)), (15, CGPoint(x: 500, y: 500)), (30, CGPoint(x: 500, y: 500))],
                               length: 800, readAt: 20.6)
    let steepMask = screen([steep]).mask(numbers)
    let trueLine = slantedLine(CGPoint(x: 500, y: 500), length: 800, height: 24, degrees: 20)
    expect(steep.isTilted && steepMask.slanted[15].count == 1 && trueLine.allSatisfy { p in steepMask.slanted[15].contains { contains($0, p) } },
           "slanted: a slant read a little off still holds the whole line")
    // Blocks line up with where the line starts, not with the room around it (which changes as
    // the line moves): with more room, the blocks inside are the same.
    let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 400, height: 400))
    let lineAt = SlantedLine(box: boundingBox(slantedLine(CGPoint(x: 200, y: 200), length: 240, height: 24, degrees: 20)), angle: a20, height: 24)!
    func drawnBlocks(room: CGFloat) -> [UInt8] {
        let q = SlantedLine.quad([lineAt], rel: whole, along: room, across: room, slack: 0)
        var px = [UInt8](repeating: 0, count: 400 * 400 * 4)
        CIContext().render(slantedBlocks(noise, over: noise, quads: [q], anchors: [lineAt.start], block: 10), toBitmap: &px, rowBytes: 1600,
                           bounds: CGRect(x: 0, y: 0, width: 400, height: 400), format: .RGBA8, colorSpace: nil)
        return px
    }
    let tight = drawnBlocks(room: 4), roomy = drawnBlocks(room: 13)
    let inside = stride(from: -100, through: 100, by: 7).map { lineAt.point(CGFloat($0), 0) }
    let differing = inside.filter { p in
        let i = ((399 - Int(p.y)) * 400 + Int(p.x)) * 4
        return abs(Int(tight[i]) - Int(roomy[i])) > 2
    }
    expect(differing.isEmpty, "slanted: the blocks do not change with the room around the line (\(differing.count) of \(inside.count) differ)")
    // Lines matched by their own heights: on a slanted line read in part the box is far lower.
    let fullLine = boundingBox(slantedLine(CGPoint(x: 500, y: 500), length: 600, height: 24, degrees: 20))
    let partLine = boundingBox(slantedLine(CGPoint(x: 400, y: 464), length: 300, height: 24, degrees: 20))
    expect(matchLines([(partLine, "電話 090-0000-1111")], to: [(fullLine, "電話 090-0000-1111 です", 0)], frame: 3, size: size,
                      heights: ([24], [24])).count == 1, "slanted: a line read in part is matched by its own height")
    // QR codes side by side, one read alone for a while: the other's track does not take it.
    var codeTracks = TrackBuilder(size: size)
    codeTracks.codes = true
    codeTracks.maxMissed = 12
    func codeLine(_ c: CGPoint) -> (CGRect, [CGPoint]) {
        let q = rotated(c, side: 100, degrees: 30), box = boundingBox(q)
        return (box, q.map { CGPoint(x: ($0.x - box.minX) / box.width, y: ($0.y - box.minY) / box.height) })
    }
    for (f, c) in [(0, CGPoint(x: 300, y: 500)), (15, CGPoint(x: 450, y: 500)), (30, CGPoint(x: 300, y: 500))] {
        let (box, rel) = codeLine(c)
        codeTracks.add(frame: f, lines: [(box, codeText, nil)], corners: [rel])
    }
    expect(codeTracks.tracks.allSatisfy { t in Set(t.samples.map { $0.rect.midX.rounded() }).count == 1 },
           "code: a track does not move to the code beside it (\(codeTracks.tracks.map { $0.samples.map { Int($0.rect.midX) } }))")
    return failures
}
