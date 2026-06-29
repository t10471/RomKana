# Third-Party Notices

RomKana（`~/Library/Input Methods/RomKana.app`）は、以下の第三者の成果物を**同梱・リンク**して配布しています。各成果物はそれぞれの著作権者に帰属し、下記ライセンスの下で利用しています。RomKana 本体のコードは MIT License（[`LICENSE`](LICENSE)）です。

## 同梱・リンクしている成果物

| 成果物 | 配布形態 | ライセンス | 著作権 | 入手元 |
|---|---|---|---|---|
| AzooKeyKanaKanjiConverter | 静的リンク | MIT | © 2023 Miwa / Ensan | https://github.com/azooKey/AzooKeyKanaKanjiConverter |
| AzooKey 既定辞書（azooKey_dictionary_storage） | `Dictionary/` フォルダを同梱 | Apache-2.0 | © 2024 Miwa / ensan | （上記リポジトリに同梱） |
| llama.cpp（`llama.framework`） | フレームワーク同梱 | MIT | © 2023 Georgi Gerganov and ggml authors | https://github.com/ggml-org/llama.cpp ／ ビルド: https://github.com/azooKey/llama.cpp release `b4846` |
| zenz-v3.2-small（`ggml-model-Q5_K_M.gguf`） | モデルファイル同梱 | Apache-2.0 | © Miwa Keita (ensan) | https://huggingface.co/Miwa-Keita/zenz-v3.2-small-gguf |
| base_n5_lm（個人最適化の base N-gram・任意） | `.marisa` 同梱（personalization 有効時のみ／リポジトリ非収録） | **未明示**（要確認） | © Miwa Keita | https://huggingface.co/Miwa-Keita/base_n5_lm （azooKey-Desktop submodule 由来） |
| SwiftyMarisa | 静的リンク | BSD-2-Clause（デュアルのうち選択。他に LGPL） | © 2016 Vladimir Solomenchuk | https://github.com/ensan-hcl/SwiftyMarisa （marisa-trie © 2010 Susumu Yata） |
| Jinja | 静的リンク | MIT | © 2024 John Mai | https://github.com/maiqingqiang/Jinja |
| swift-tokenizers | 静的リンク | Apache-2.0 | © Hugging Face | https://github.com/ensan-hcl/swift-tokenizers |
| swift-collections | 静的リンク | Apache-2.0 | © Apple Inc. and the Swift project authors | https://github.com/apple/swift-collections |
| swift-numerics | 静的リンク | Apache-2.0 | © Apple Inc. and the Swift project authors | https://github.com/apple/swift-numerics |
| swift-algorithms | 静的リンク | Apache-2.0 | © Apple Inc. and the Swift project authors | https://github.com/apple/swift-algorithms |

### 注記

- **zenz モデルは Apache-2.0**（HF リポジトリ [`Miwa-Keita/zenz-v3.2-small-gguf`](https://huggingface.co/Miwa-Keita/zenz-v3.2-small-gguf) の表示）。同梱の `ggml-model-Q5_K_M.gguf` は、配布モデルを **GGUF 形式へ量子化（Q5_K_M）したもの**＝改変にあたるため、その旨をここに明示します（Apache-2.0 §4(b)）。基盤モデルは京都大学 NLP の `gpt2-small-japanese-char` 系です。
- Apache-2.0 の成果物（zenz モデル・AzooKey 既定辞書・swift-* 各種）のうち、zenz 以外は**未改変**で同梱しています。
- **base_n5_lm（個人最適化）はライセンス未明示**。HF [`Miwa-Keita/base_n5_lm`](https://huggingface.co/Miwa-Keita/base_n5_lm) に license の記載が無く、azooKey-Desktop のサブモジュールとして提供されている。本リポジトリには含めず（取得手順のみ）、個人最適化を使う場合に各自で取得・同梱する。再配布時は作者にライセンスを確認すること。

---

## ライセンス全文ファイル

各ライセンスの全文は [`licenses/`](licenses/) に同梱しています（`.app` にも `Contents/Resources/licenses/` として同梱）。

| ライセンス | 全文 |
|---|---|
| MIT | [`licenses/MIT.txt`](licenses/MIT.txt) |
| BSD-2-Clause | [`licenses/BSD-2-Clause.txt`](licenses/BSD-2-Clause.txt) |
| Apache-2.0 | [`licenses/Apache-2.0.txt`](licenses/Apache-2.0.txt) |

以下は各ライセンスの要約・著作権表示です（全文は上記ファイル）。

## ライセンス全文（要約）

### MIT License（AzooKeyKanaKanjiConverter, llama.cpp, Jinja に適用）

```
MIT License

Copyright (c) 2023 Miwa / Ensan            (AzooKeyKanaKanjiConverter)
Copyright (c) 2023 Georgi Gerganov and ggml authors   (llama.cpp)
Copyright (c) 2024 John Mai                 (Jinja)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### BSD 2-Clause License（SwiftyMarisa / marisa-trie に適用）

> SwiftyMarisa は BSD-2-Clause と LGPL のデュアルライセンス。本製品は **BSD-2-Clause** を選択して利用しています。

```
Copyright (c) 2016, Vladimir Solomenchuk
Copyright (c) 2010, Susumu Yata (marisa-trie)
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
   this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
```

### Apache License 2.0（zenz モデル, AzooKey 既定辞書, swift-tokenizers, swift-collections, swift-numerics, swift-algorithms に適用）

これらの成果物は Apache License, Version 2.0 の下で配布されています。全文は次を参照してください: https://www.apache.org/licenses/LICENSE-2.0

```
Copyright Miwa Keita (ensan)           (zenz-v3.2-small-gguf)
Copyright 2024 Miwa / ensan            (azooKey_dictionary_storage)
Copyright Hugging Face                 (swift-tokenizers)
Copyright Apple Inc. and the Swift project authors  (swift-collections / swift-numerics / swift-algorithms)

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```
