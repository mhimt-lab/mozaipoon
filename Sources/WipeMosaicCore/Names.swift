import Foundation

// Japanese person names in a line of on-screen text. macOS has no name recognition for
// Japanese (NLTagger's nameType is not available for it), so common family names are looked
// up and accepted only where a name is likely: followed by an honorific, a given name, or
// alone on the line (a chat's contact name). Names with rare family names and nicknames are
// not found; the user adds those as words.

/// Common Japanese family names (two or more characters).
private let familyNames: Set<String> = [
    "佐藤", "鈴木", "高橋", "田中", "伊藤", "渡辺", "渡邊", "渡邉", "山本", "中村", "小林", "加藤",
    "吉田", "山田", "佐々木", "山口", "松本", "井上", "木村", "斎藤", "斉藤", "齋藤", "齊藤", "清水",
    "山崎", "山﨑", "森田", "池田", "橋本", "阿部", "石川", "山下", "中島", "石井", "小川", "前田",
    "岡田", "長谷川", "藤田", "後藤", "近藤", "村上", "遠藤", "青木", "坂本", "福田", "太田", "西村",
    "藤井", "金子", "岡本", "藤原", "中野", "三浦", "原田", "中川", "松田", "竹内", "小野", "田村",
    "中山", "和田", "石田", "上田", "内田", "柴田", "酒井", "宮崎", "横山", "高木", "安藤", "宮本",
    "大野", "小島", "谷口", "工藤", "今井", "高田", "丸山", "増田", "杉山", "村田", "大塚", "小山",
    "平野", "藤本", "河野", "上野", "野口", "武田", "松井", "千葉", "岩崎", "菅原", "木下", "久保",
    "佐野", "野村", "松尾", "市川", "菊地", "菊池", "杉本", "古川", "大西", "島田", "水野", "桜井",
    "櫻井", "高野", "渡部", "吉川", "山内", "西田", "飯田", "菅野", "西川", "小松", "北村", "安田",
    "五十嵐", "川口", "平田", "中田", "久保田", "服部", "岩田", "土屋", "川崎", "福島", "本田", "樋口",
    "秋山", "田口", "永井", "山中", "中西", "吉村", "川上", "石原", "大橋", "松岡", "馬場", "浅野",
    "荒木", "大久保", "野田", "小沢", "小澤", "田辺", "川村", "星野", "黒田", "尾崎", "望月", "永田",
    "熊谷", "内藤", "松村", "西山", "大谷", "平井", "大島", "岩本", "片山", "本間", "早川", "横田",
    "岡崎", "荒井", "大石", "鎌田", "成田", "宮田", "小田", "石橋", "篠原", "須藤", "河合", "大川",
    "宮下", "宮内", "松下", "吉岡", "高山", "坂口", "新井", "小池", "浅井", "上原", "横井", "中井",
    "堀内", "森本", "森川", "今村", "吉野", "宮川", "水谷", "根本", "小森", "宇野", "冨田", "富田",
    "坂田", "内山", "竹田", "野崎", "長田", "片岡", "細川", "稲垣", "原口", "中尾", "落合", "塚本",
    "堀田", "福井", "関口", "奥村", "植田", "北川", "杉浦", "宮原", "青山", "野中", "西岡", "小西",
    "吉井", "岡村", "飯島", "須田", "中本", "牧野", "松浦", "中谷", "古田", "平山", "大森", "小倉",
    "細谷", "上村", "奥田", "竹中", "河村", "武藤", "白石", "桑原", "広瀬", "廣瀬", "小野寺", "安達",
    "足立", "江口", "志村", "栗原", "若林", "西尾", "西野", "高村", "大竹", "三宅", "長尾", "戸田",
    "西本", "藤川", "坂井", "松原", "大山", "竹下", "八木", "石黒", "森下", "浅田", "平川", "吉原",
    "岩井", "三上", "川田", "米田", "神田", "福本", "松山", "天野", "小原", "堀川", "内海", "角田",
    "中原", "片桐", "森山", "有馬", "北野", "大村", "黒木", "中澤", "中沢", "荻野", "小泉", "新田",
    "大木", "寺田", "宮沢", "宮澤", "篠田", "田島", "竹本", "石山", "西原", "梅田", "遠山", "瀬戸",
    "高瀬", "今田", "増井", "長野", "小笠原", "大野木", "野上", "川島", "矢野", "加納", "三好",
    "柳田", "柳沢", "徳永", "徳田", "大津", "藤野", "宮城", "金田", "金井", "島崎", "畠山", "畑中",
    "杉田", "関根", "茂木", "相馬", "相沢", "相澤", "小柳", "戸塚", "大澤", "大沢", "飯塚", "高島",
    "髙橋", "髙田", "髙木", "濱田", "浜田", "濵田", "𠮷田", "邉見",
]

/// Single-character family names: also ordinary words, so stricter conditions apply.
private let shortFamilyNames: Set<String> = ["森", "原", "林", "東", "関", "辻", "堀", "西", "堤", "南", "岡", "泉", "浜", "谷"]

private let honorifics = ["さん", "さま", "様", "くん", "君", "ちゃん", "氏", "先生", "殿", "です", "と申します"]
private let politeEndings: Set<String> = ["です", "と申します"]

private func isKanji(_ c: Character) -> Bool {
    guard let u = c.unicodeScalars.first, c.unicodeScalars.count == 1 else { return false }
    switch u.value {
    case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0x20000...0x3FFFF, 0x3005: return true  // kanji, 々
    default: return false
    }
}

private func isHiragana(_ c: Character) -> Bool {
    guard let u = c.unicodeScalars.first, c.unicodeScalars.count == 1 else { return false }
    return (0x3041...0x3096).contains(u.value) || u.value == 0x30FC
}

private func isKatakana(_ c: Character) -> Bool {
    guard let u = c.unicodeScalars.first, c.unicodeScalars.count == 1 else { return false }
    return (0x30A1...0x30FA).contains(u.value) || u.value == 0x30FC
}

/// Ranges of likely person names (family name, with the given name when it follows).
func nameRanges(in s: String) -> [Range<String.Index>] {
    let chars = Array(s)
    var idx = Array(s.indices)
    idx.append(s.endIndex)
    let trimmed = s.trimmingCharacters(in: .whitespaces)
    /// An honorific at `k`. `polite`: also です and と申します, which follow company names too.
    func honorific(at k: Int, polite: Bool = true) -> Bool {
        guard k < chars.count else { return false }
        let rest = String(chars[k...])
        return honorifics.contains { (polite || !politeEndings.contains($0)) && rest.hasPrefix($0) }
    }
    var out: [Range<String.Index>] = []
    var i = 0
    while i < chars.count {
        var matched: (len: Int, short: Bool)?
        for len in stride(from: 3, through: 1, by: -1) where i + len <= chars.count {
            let w = String(chars[i..<(i + len)])
            if len > 1, familyNames.contains(w) { matched = (len, false); break }
            if len == 1, shortFamilyNames.contains(w) { matched = (1, true); break }
        }
        guard let m = matched else { i += 1; continue }
        // Right after another kanji (担当田中様): only with an honorific, which a name inside
        // an ordinary word (中山道) does not have.
        let inWord = i > 0 && isKanji(chars[i - 1])
        let end = i + m.len
        var j = end
        var spaced = false
        while j < chars.count, chars[j].isWhitespace { j += 1; spaced = true }
        // Given name: up to 3 kanji; or 2–5 kana before an honorific (山田さくらさん), at the end
        // of a spaced word (山田 さくら), or katakana (山田サクラ).
        var given = 0
        while j + given < chars.count, given < 3, isKanji(chars[j + given]) { given += 1 }
        if given == 0, spaced || !m.short, j < chars.count, isHiragana(chars[j]) || isKatakana(chars[j]) {
            // One script: katakana (サクラ) stops at the hiragana after it (サクラです).
            let kana: (Character) -> Bool = isKatakana(chars[j]) ? isKatakana : isHiragana
            while j + given < chars.count, given < 5, kana(chars[j + given]), !honorific(at: j + given, polite: false) {
                given += 1
            }
            let stop = j + given
            let ok: Bool
            if honorific(at: stop, polite: false) {
                ok = true  // 山田さくらさん
            } else if stop == chars.count || chars[stop].isWhitespace {
                // 山田 さくら, 山田サクラ, and a line that is just 山田さくら (a contact name)
                ok = spaced || isKatakana(chars[j]) || String(chars[i..<stop]) == trimmed
            } else {
                ok = !spaced && isKatakana(chars[j]) && !isKanji(chars[stop])  // 山田サクラです
            }
            if given < 2 || !ok { given = 0 }
        }
        var upper: Int?
        if honorific(at: j, polite: !inWord) {
            upper = end  // 田中さん, 佐藤です
        } else if given > 0, let g = (1...given).reversed().first(where: { honorific(at: j + $0, polite: false) }) {
            upper = j + g  // 高橋健太郎様, 担当田中太郎さん
        } else if inWord {
            upper = nil
        } else if given > 0, j + given == chars.count || !isKanji(chars[j + given]), spaced || !m.short {
            upper = j + given  // 山田 花子, 鈴木次郎も
        } else if String(chars[i..<end]) == trimmed {
            upper = end  // the line is just the name
        }
        if let u = upper {
            // Inside a word, the family name may be longer than the one found (桑原さん found
            // as 原さん, 大森さん as 森さん): hide up to 2 kanji before it too.
            var start = i
            while inWord, start > 0, i - start < 2, isKanji(chars[start - 1]) { start -= 1 }
            out.append(idx[start]..<idx[u])
            i = u
        } else {
            i += 1
        }
    }
    return out
}
