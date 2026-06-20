#!/usr/bin/env python3
"""Phase 0 prompt harness: compare romaji-direct vs kana-first conversion."""
import json, sys, time, urllib.request

URL = "http://127.0.0.1:8080/v1/chat/completions"
MODEL = "LiquidAI/LFM2.5-1.2B-JP-202606-MLX-4bit"

SYSTEM_KANA = (
    "あなたは日本語IMEのかな漢字変換エンジンです。"
    "入力された平仮名の読みを、文脈に合った自然な漢字かな交じり文に変換してください。"
    "読み（音）は変えず、漢字にできる部分だけ漢字にします。"
    "変換結果の文だけを出力し、説明・引用符・前置きは付けないこと。"
)
FEWSHOT_KANA = [
    ("わたしはにほんごをべんきょうしています", "私は日本語を勉強しています"),
    ("きょうはいいてんきですね", "今日はいい天気ですね"),
    ("こうゆうふうににゅうりょくすると", "こうゆう風に入力すると"),
    ("あしたともだちとえいがをみます", "明日友達と映画を見ます"),
]

def chat(system, fewshot, text):
    msgs = [{"role": "system", "content": system}]
    for r, a in fewshot:
        msgs += [{"role": "user", "content": r}, {"role": "assistant", "content": a}]
    msgs.append({"role": "user", "content": text})
    body = {"model": MODEL, "messages": msgs, "temperature": 0.0, "max_tokens": 96}
    req = urllib.request.Request(
        URL, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=120) as resp:
        out = json.load(resp)
    return out["choices"][0]["message"]["content"].strip(), time.time() - t0

if __name__ == "__main__":
    # input kana readings (what the local romaji->kana table would produce)
    tests = sys.argv[1:] or [
        "こうゆうふうににゅうりょくすると",   # the user's example
        "りんごをたべました",
        "あすはかいぎがあります",
        "きょうのひるごはんはぱすたでした",
        "ありがとうございます",
        "でんしゃがおくれてちこくした",
    ]
    for t in tests:
        text, dt = chat(SYSTEM_KANA, FEWSHOT_KANA, t)
        print(f"[{dt:5.2f}s] {t}\n        -> {text}\n")
