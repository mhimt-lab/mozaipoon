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
        ("山田アレクサンダー", ["山田アレクサンダー"]), ("山田コーポレーション", ["山田コーポレーション"]),
        ("山田プロジェクトマネージャー", ["山田プロジェクトマネージャー"]),
        ("山田アレクサンダー・ジュニア", ["山田アレクサンダー・ジュニア"]),
        ("長谷部さん", ["長谷部"]), ("担当山田太郎", ["担当山田太郎"]), ("山田さくらが来た", ["山田さくら"]),
        ("山田 さくらこです", ["山田 さくらこ"]), ("山田 まさひろです", ["山田 まさひろ"]),
        ("犬飼さん", ["犬飼"]), ("担当犬飼くん", ["担当犬飼"]),
        // A title in kanji after the full name (山田太郎部長); a family name with a spaced katakana
        // or hiragana name before a particle or a mark; given names with particle letters inside.
        ("山田太郎部長", ["山田太郎部"]), ("佐藤健太郎課長", ["佐藤健太郎"]), ("担当山田太郎部長", ["担当山田太郎部"]),
        ("山田 サクラが来た", ["山田 サクラ"]), ("山田 タロウ（営業）", ["山田 タロウ"]), ("山田サクラ宛", ["山田サクラ"]),
        ("山田 さくら、佐藤", ["山田 さくら"]), ("山田さくら、佐藤", ["山田さくら"]),
        ("山田ひなのが来た", ["山田ひなの"]), ("山田はるとが来た", ["山田はると"]), ("山田ことのは帰った", ["山田ことの"]),
        ("山田さくらから聞いた", ["山田さくら"]), ("山田さくらって人", ["山田さくら"]), ("山田ひなのです。", ["山田ひなの"]),
        // Family names not in the list, with a kana or spaced given name, a space, or 様.
        ("犬飼 太郎さん", ["犬飼 太郎"]), ("犬飼 さん", ["犬飼"]), ("犬飼さくらさん", ["犬飼さくら"]),
        ("犬飼サクラさん", ["犬飼サクラ"]), ("勅使河原さん", ["勅使河原"]), ("犬飼様", ["犬飼"]), ("犬飼健一様", ["犬飼健一"]),
        ("製品仕様", []), ("前回同様", []), ("お客様", []), ("時間がたくさん", []), ("田舎のおばあちゃん", []),
        ("山田 からきたよね", ["山田 からきたよね"]),  // spaced hiragana to the line end: taken as a name
        ("山田 は来た", []), ("森の中", []), ("東京都みほん区", []), ("皆さん", []), ("たくさん", []),
        ("仕様です", []),
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

    // Wrapped email addresses, URLs and numbers: the last word of a line and the first of
    // the next, joined.
    let wraps: [(String, String, TextKind?)] = [
        ("メールは hanako.yamada@", "example.com です", .email), ("hanako.yamada@exam", "ple.com", .email),
        ("hanako.yamada @", "example.com", .email), ("sato.ichi", "ro@example.jp です", .email),
        ("sato.ichi", "ro＠example.jp", .email), ("sato.ichi", "ro @example.jp", .email),
        ("資料は https://", "example.com/share", .url), ("共有先は example", ".com/private/yamada", .url),
        ("example.c", "om/users/yamada-hana", .url), ("https://example.com/share/", "abc123", .url),
        ("電話は 080-0000-", "2222 です", .number), ("090-12", "34-5678", .number),
        ("カード 4111 1111 1111", "1111 で", .number), ("電話 090 12", "34 567", .number),
        ("080 00", "00 2222", .number), ("（090）", "123-45", .number),
        ("https://example.com/users（", "yamada）", .url),
        ("よろしくお願いします", "はい", nil), ("9:41", "5G", nil), ("Wi-Fi", "OK", nil),
    ]
    for (u, l, want) in wraps {
        let got: TextKind? = {
            guard let ru = trailingWord(u), let rl = leadingWord(l) else { return nil }
            return wrappedKind(String(u[ru]), String(l[rl]))
        }()
        expect(got == want, "wrap \(u) / \(l): \(String(describing: got))")
    }
    // A line from Vision is a bridged NSString (UTF-16 indices): the words must still be found.
    let line = "連絡先 https://example.com/users/yamada-hana"
    let bridged = NSString(characters: Array(line.utf16), length: line.utf16.count) as String
    expect(trailingWord(bridged).map { String(bridged[$0]) } == "https://example.com/users/yamada-hana",
           "trailing word of a bridged Japanese line")
    expect(leadingWord("  ple.com です").map { String("  ple.com です"[$0]) } == "ple.com", "leading word")

    failures += selfCheckMask()
    return failures
}
