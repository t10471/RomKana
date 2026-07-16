# 自作 macOS IME「RomKana」開発記（3）— 「ときどき丸ごと落ちる」を追う

[前回まで](https://zenn.dev/toshinao/articles/1cffb713b1c670)で、ローマ字をローカルでかな漢字に変換する macOS の IME を作り、文節変換と個人最適化まで足しました。毎日使う道具になると、こんどはバグがはっきり見えてきます。いちばん厄介だったのが「**打っていた文字が、ときどきフッと丸ごと消える**」現象でした。

じつは原因の違うクラッシュが2つありました。ひとつは変換の最中に落ちるもので、前回（第2部）で直しています。もうひとつが今回の主役、**フォーカスを別のアプリへ移した瞬間に落ちる**ものです。症状は同じ「消える」でも、犯人はまったく別でした。

現行構成のリファレンスは [`architecture.md`](https://github.com/t10471/RomKana/blob/master/docs/architecture.md) を参照してください。

---

## まず、本当に落ちているのか

「消える」には2通りあります。表示が崩れているだけか、プロセスごと死んでいるか。切り分けは簡単で、**macOS のクラッシュレポートを見ればいい**。

```
~/Library/Logs/DiagnosticReports/RomKana-*.ips
```

開くと、同じ形のレポートが数十件たまっていました。1日に何度も落ちている。スタックはこうです。

```
EXC_BAD_ACCESS (SIGSEGV)
KERN_INVALID_ADDRESS at 0x004f6e7e87dd4ed8 (possible pointer authentication failure)
  objc_msgSend
  -[_IMKServerLegacy deactivateServer_CommonWithClientWrapper:controller:]
  …
```

読みどころは2つ。**`deactivateServer`** ＝ 入力メソッドが非アクティブになる（フォーカスが外れる）瞬間に落ちている。そして **でたらめなアドレスへの `objc_msgSend`**（しかも "pointer authentication failure"）＝ **解放済みのオブジェクトにメッセージを送っている**、いわゆる use-after-free です。自分のコードのフレームは一切出てこない。OS 側が、こちらの渡した「もう死んでいるオブジェクト」を触って落ちている、という形でした。

## 犯人は「セッションごとに作る候補ウィンドウ」

use-after-free なら、「いつの間にか解放されるのに、まだ誰かが握っているオブジェクト」を探します。心当たりは候補ウィンドウ（`IMKCandidates`）でした。

RomKana は、入力コントローラ（`IMKInputController`）の初期化で、**コントローラごとに候補ウィンドウを1つ作って持って**いました。

```swift
override init!(server: ..., ...) {
    super.init(...)
    candidatesWindow = IMKCandidates(server: server, panelType: ...)
}
```

ここに罠があります。macOS は**テキスト入力のセッションごとに新しいコントローラを作る**。アプリを切り替えるたび、入力欄が変わるたびに、コントローラが生まれては捨てられます。そのたびに候補ウィンドウも作られ、サーバ（`IMKServer`）に紐づく。コントローラが捨てられれば候補ウィンドウも解放されますが、**サーバ側には解放済みウィンドウへの参照が残る**。次に非アクティブ化が走ると、その死んだ参照を触って落ちる——という筋でした。

IME 開発の定石を調べると、はっきり書いてありました。**「`IMKInputController` はオブジェクトを保持するな」**、そして**「非アクティブ化の最中に `client()` を触るな（後始末は OS がやる）」**。まさに踏んでいた地雷です。

## 直し方：候補ウィンドウはプロセスに1つ

答えは単純で、**候補ウィンドウをコントローラごとに作らず、プロセスに1つだけ**にする。しかもその共有ウィンドウは、最初から `main.swift` に用意されていました。作ってあるのに使っていなかった、という気の抜けるオチ付きです。

コントローラは候補ウィンドウを**持たない**。共有ウィンドウを参照するだけにしました。

```swift
private var candidatesWindow: IMKCandidates! { sharedCandidates }
```

候補の選択（`candidateSelected(_:)` など）は、共有ウィンドウでも**サーバ経由でいまアクティブなコントローラに届く**ので、機能はそのまま。捨てるのは「セッションごとにウィンドウを分ける」細かな配慮だけです。プロセスごと落ちるよりは、ずっとまし。

間欠的なクラッシュなので、直した直後だけでは「効いた」と言い切れません。しばらく使ってクラッシュレポートが増えないのを見て、はじめて安心できます。前回直した「変換中に落ちるバグ」は修正後ゼロ件。今回の非アクティブ化クラッシュも、これで止まるのを期待して様子を見ています。

## 今回の教訓

- **「落ちた？」はクラッシュレポートを見れば一発。** `~/Library/Logs/DiagnosticReports/` にスタック付きで残る。表示バグかプロセス死かを推測で悩まず、まず開く。
- **でたらめなアドレスへの `objc_msgSend`（PAC 失敗）は use-after-free のサイン。** 「いつ解放され、誰がまだ握っているか」を探すのが近道。
- **入力コントローラはオブジェクトを持たせない。** OS がセッションごとにコントローラを作っては捨てる前提を忘れて候補ウィンドウを持たせると、フレームワーク側に死んだ参照が残る。共有して、コントローラは何も抱えないのが安全。
- **同じ「消える」でも原因は別。** 変換中の範囲外アクセス（第2部）と、非アクティブ化の use-after-free（今回）は、症状が同じでも犯人はまったく違った。症状で決めつけない。
- **間欠バグは「様子見」まで含めて修正。** 直した瞬間ではなく、数日クラッシュレポートが増えないことで確かめる。

---

## 参考リンク

- [前回までの開発記（第1部・第2部）](https://zenn.dev/toshinao/articles/1cffb713b1c670)
- [macOS Input Method Development Guidelines for 2026（Shiki Suen）](https://shikisuen.medium.com/macos-input-method-development-guidelines-for-2026-5123461fa53b) — `IMKInputController` はオブジェクトを持たない・非アクティブ化中に `client()` を触らない、の出典。
- [IMKCandidates — Apple Developer Documentation](https://developer.apple.com/documentation/inputmethodkit/imkcandidates?language=objc)
- 現行構成のリファレンス: [`architecture.md`](https://github.com/t10471/RomKana/blob/master/docs/architecture.md)
