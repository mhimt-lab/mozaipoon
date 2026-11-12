# コマンドライン版（wipe-mosaic）

`swift build -c release` で `.build/release/wipe-mosaic` ができる。アプリと同じ処理を、ターミナルから実行できる。

```sh
wipe-mosaic people <動画> [-o <サムネイル保存先>] [--photo <写真>]... [--match <別の動画>]   # 映っている人の一覧
wipe-mosaic run <動画> <出力> --people 1,3 [--report faces.csv]       # 人物1と3にモザイク
wipe-mosaic run <動画> <出力> --wipe x,y,w,h                          # ワイプ方式（下）
wipe-mosaic info <動画>                                               # サイズ・長さ・fps（JSON）
```

- 画面に出すのは件数・秒数・距離だけ（顔の座標や画像の中身は出さない）
- `people --photo` は各人物と写真との距離を出し、アプリで候補になる組み合わせに `(suggested)` を付ける
- `people <動画> --match <別の動画>` は、各人物と別の動画の人物との距離を出し、アプリで「『動画名』で選んだ人に似ています」になる組み合わせに `(suggested)` を付ける（基準 0.5、合成素材では同じ人 0.05〜0.38・別人 0.61 以上）
- オプション：`--tiles n`（人物方式 4・ワイプ方式 3）、`--tile-interval 秒`（人物方式のみ。0.1、0 で毎フレーム）、`--hold 秒`（0.3）、`--pad 比率`（0.45）、`--block px`（長辺÷60）。run のみ `--overwrite`・`--progress`・`--report`

## ワイプ方式（`--wipe`）

画面録画＋ワイプの動画向け。**ワイプ内でいちばん大きい顔（本人）だけ残し、ほかの顔はすべてモザイク**にする。
位置は動画のピクセル単位で左上原点の `x,y,幅,高さ`。`wipe-mosaic preview <動画> --wipe ... --at 秒 -o check.png` で確認できる。
`--min-inside`（0.8）でワイプ内とみなす割合、`--keep-all-in-wipe` でワイプ内の顔を全員残す。

