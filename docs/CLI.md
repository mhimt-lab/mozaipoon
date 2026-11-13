# コマンドライン版（wipe-mosaic）

`swift build -c release` で `.build/release/wipe-mosaic` ができる。アプリと同じ処理を、ターミナルから実行できる。

```sh
wipe-mosaic people <動画> [-o <サムネイル保存先>] [--photo <写真>]... [--match <別の動画>]   # 映っている人の一覧
wipe-mosaic run <動画> <出力> --people 1,3 [--report faces.csv]       # 人物1と3にモザイク
wipe-mosaic run <動画> <出力> --people 1,3 --style blur --sticker 3=face.png   # 1 はぼかし、3 はスタンプ
wipe-mosaic run <動画> <出力> --wipe x,y,w,h                          # ワイプ方式（下）
wipe-mosaic run <動画> <出力> --screen-text [--words 山田,花子]      # 画面の文字の個人情報（下）
wipe-mosaic text <動画> [--words 山田,花子] [--list]                  # 画面の文字の件数（--list で文字も出す）
wipe-mosaic info <動画>                                               # サイズ・長さ・fps（JSON）
wipe-mosaic selfcheck                                                 # 個人情報を見つける規則の回帰チェック（動画不要）
```

- 画面に出すのは件数・秒数・距離だけ（顔の座標や画像の中身は出さない）
- `people --photo` は各人物と写真との距離を出し、アプリで候補になる組み合わせに `(suggested)` を付ける
- `people <動画> --match <別の動画>` は、各人物と別の動画の人物との距離を出し、アプリで「『動画名』で選んだ人に似ています」になる組み合わせに `(suggested)` を付ける（基準 0.5、合成素材では同じ人 0.05〜0.38・別人 0.61 以上）
- オプション：`--tiles n`（人物方式 4・ワイプ方式 3）、`--tile-interval 秒`（人物方式のみ。0.1、0 で毎フレーム）、`--hold 秒`（0.3）、`--pad 比率`（0.45）、`--block px`（長辺÷60。ぼかしの強さも兼ねる）、`--style mosaic|blur`（顔と画面の文字の隠し方）。run のみ `--overwrite`・`--progress`・`--report`
- スタンプ（`--people` と run のみ）：`--sticker 人物番号=画像` で、その人の顔に画像を重ねる（繰り返し指定可。人物は `--people` に含めること）。画像に顔があれば顔同士を合わせる。`--sticker-scale 倍率`（1.2、0.5〜4）で大きさを変える。画像ごとに顔を覆える割合を出し、透明・半透明の部分から顔が見えるときは警告する。レポート CSV の `sticker_boxes` に人物と位置が入る

## ワイプ方式（`--wipe`）

画面録画＋ワイプの動画向け。**ワイプ内でいちばん大きい顔（本人）だけ残し、ほかの顔はすべてモザイク**にする。
位置は動画のピクセル単位で左上原点の `x,y,幅,高さ`。`wipe-mosaic preview <動画> --wipe ... --at 秒 -o check.png` で確認できる。
`--min-inside`（0.8）でワイプ内とみなす割合、`--keep-all-in-wipe` でワイプ内の顔を全員残す。


## 画面の文字（`--screen-text`）

画面録画と、画面をカメラで撮った動画向け。画面の文字を読み取り、電話番号・カード番号などの数字（6桁以上）・メールアドレス・URL・住所と郵便番号・人の名前の部分にモザイクをかける。`--people` と一緒に使える。下のオプションは `--screen-text` がないとエラーになる（`text` では不要）。

- `--text-kinds number,email,url,address,name`：自動で隠す種類（既定はすべて、`none` で自動で隠さない）
- `--words 山田,花子`：この言葉の部分も隠す（空白の有無、大文字・小文字、全角・半角は区別しない）
- `--lines 3,5`：この行を行全体で隠す（番号は `wipe-mosaic text <動画> --list` で出る。その動画にない番号はエラー）
- `--all-text`：読み取れた行をすべて隠す（画面をカメラで撮った動画向け。字幕なども隠れる）
- `text` は件数だけを出す。`--list` を付けたときだけ、読み取った文字を出す
