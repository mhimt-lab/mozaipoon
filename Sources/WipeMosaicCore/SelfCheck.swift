import Foundation

// Regression checks for the rules that find personal information, run by
// `wipe-mosaic selfcheck` (Command Line Tools have no XCTest or swift-testing macros).
// Each case is a bug that was found and fixed; keep them passing.

/// Failed checks (empty when all pass).
public func selfCheck() -> [String] {
    var failures: [String] = []
    func expect(_ ok: Bool, _ what: @autoclosure () -> String) { if !ok { failures.append(what()) } }

    let names: [(String, [String])] = [
        ("田中さん", ["田中"]), ("山田花子です", ["山田花子"]), ("鈴木次郎も来た", ["鈴木次郎"]),
        ("担当田中様", ["担当田中"]), ("高橋健太郎様", ["高橋健太郎"]), ("佐藤一郎君", ["佐藤一郎"]),
        ("山田 さくら", ["山田 さくら"]), ("山田さくらさん", ["山田さくら"]), ("山田さくら", ["山田さくら"]),
        ("山田サクラ", ["山田サクラ"]), ("山田サクラです", ["山田サクラ"]), ("山田サクラが来た", ["山田サクラ"]),
        ("桑原さん", ["桑原"]), ("葛西様", ["葛西"]), ("髙橋", ["髙橋"]), ("濱田さん", ["濱田"]), ("森さん", ["森"]),
        ("山田 は来た", []), ("森の中", []), ("東京都みほん区", []),
    ]
    for (s, want) in names {
        let got = nameRanges(in: s).map { String(s[$0]) }
        expect(got == want, "name \(s): \(got) (want \(want))")
    }

    func kinds(_ s: String) -> [TextKind: [String]] {
        findKinds(in: s).reduce(into: [:]) { $0[$1.0, default: []].append(String(s[$1.1])) }
    }
    expect(kinds("連絡は090-0000-1111まで")[.number] == ["090-0000-1111"], "number with hyphens")
    expect(kinds("090.0000.1111")[.number] == ["090.0000.1111"], "number with dots")
    expect(kinds("会員番号は A-00001234です")[.number] == ["A-00001234"], "number with letters")
    expect(kinds("HTTPS://EXAMPLE.COM/a")[.url] != nil, "URL in capitals")
    for u in ["lin.ee/abc", "bit.ly/x1", "shop.tokyo", "example.co.uk"] {
        expect(kinds(u)[.url] != nil, "URL \(u)")
    }
    expect(kinds("hanako.yamada@example.com")[.email] != nil, "email")
    expect(kinds("〒100-0000東京都みほん区")[.address]?.first == "〒100-0000東京都みほん区", "address to the line end")

    let full = "ＹＡＭＡＤＡ＿Ｔさん"
    expect(wordRanges(in: full, words: [normalizedForMatch("yamada_t")]).count == 1, "full-width word")
    expect(wordRanges(in: "鈴木 次郎です", words: ["鈴木"]).map { String("鈴木 次郎です"[$0]) } == ["鈴木 次郎"],
           "word with the given name after it")

    failures += selfCheckMask()
    return failures
}
