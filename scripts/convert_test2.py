#!/usr/bin/env python3
"""Phase 0: pattern-completion framing via /v1/completions (not chat)."""
import json, sys, time, urllib.request

URL = "http://127.0.0.1:8080/v1/completions"
MODEL = "LiquidAI/LFM2.5-1.2B-JP-202606-MLX-4bit"

EXAMPLES = [
    ("わたしはにほんごをべんきょうしています", "私は日本語を勉強しています"),
    ("きょうはいいてんきですね", "今日はいい天気ですね"),
    ("こうゆうふうににゅうりょくすると", "こうゆう風に入力すると"),
    ("あしたともだちとえいがをみます", "明日友達と映画を見ます"),
    ("でんしゃがおくれてちこくした", "電車が遅れて遅刻した"),
    ("ありがとうございます", "ありがとうございます"),
]
HEADER = "平仮名の読みを自然な漢字かな交じり文に変換する。\n\n"

def build_prompt(reading):
    p = HEADER
    for r, a in EXAMPLES:
        p += f"読み:{r}\n変換:{a}\n"
    p += f"読み:{reading}\n変換:"
    return p

def convert(reading):
    body = {
        "model": MODEL,
        "prompt": build_prompt(reading),
        "temperature": 0.0,
        "max_tokens": 96,
        "stop": ["\n", "読み:"],
    }
    req = urllib.request.Request(
        URL, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=120) as resp:
        out = json.load(resp)
    return out["choices"][0]["text"].strip(), time.time() - t0

if __name__ == "__main__":
    tests = sys.argv[1:] or [
        "こうゆうふうににゅうりょくすると",
        "りんごをたべました",
        "あすはかいぎがあります",
        "きょうのひるごはんはぱすたでした",
        "でんしゃがおくれてちこくした",
        "かいぎのしりょうをじゅんびする",
        "あたらしいいめをつくりたい",
    ]
    for t in tests:
        text, dt = convert(t)
        print(f"[{dt:5.2f}s] {t}\n        -> {text}\n")
