#!/usr/bin/env python3
"""
RomKana conversion service.

Hybrid kana-kanji conversion:
  - CANDIDATES: mozcpy (Mozc-derived dictionary + cost model). Reading-faithful,
    fast (~10-20ms). Generates the n-best candidate list (never hallucinates).
  - RERANK (use_llm=true): score each mozcpy candidate by the LLM's TOTAL
    (sum) conditional log-likelihood of the candidate tokens given the context,
    and reorder by it. The LLM only judges dictionary candidates — it never
    generates text — so this is hallucination-free and reorders the popup so the
    contextually-natural reading lands first (e.g. 雨/飴 by context).
    Measured (hard 30-case set): dictionary top1 15/30 -> Qwen2.5-7B 19/30,
    Qwen3-1.7B 17/30. NOTE: sum, not mean — mean cancels the signal.

Endpoint:
  POST /convert  {"reading": "...", "context": "", "n_best": 8, "use_llm": false}
       -> {"candidates": ["...", ...], "best": "..."}
  GET  /health   -> {"ok": true, "llm": <bool loaded>}
"""
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import mozcpy

HOST, PORT = "127.0.0.1", 8765
# Reranker model (sum-loglik scoring). Swap this one line to trade speed for
# quality. Quality on the hard 30-case set; latency is the per-convert rerank
# with batching + KV-cache (short .. long-context), as the IME waits on it:
#   Qwen2.5-7B-Instruct 19/30 (~220-685ms — exceeds the 400ms wait on long input)
#   Qwen3-1.7B          17/30 (~96-279ms — stays within the wait)  <- chosen
#   Qwen2.5-1.5B-base   16/30 (~57-152ms)
#   Qwen2.5-0.5B        14/30 (~26-56ms, < dictionary)
MODEL_REPO = "mlx-community/Qwen3-1.7B-4bit"

_converter = mozcpy.Converter()

# Lazily-initialized LLM scorer (only when use_llm is requested).
_llm = {"loaded": False, "model": None, "tok": None}
_llm_lock = threading.Lock()  # serialize MLX inference across request threads

# Adaptive learning: remember which surface the user actually chose for a given
# reading, and float repeatedly-chosen surfaces to the top of future
# conversions. This adapts to the user's own vocabulary/preferences — the single
# biggest real-world quality lever, independent of the static model.
_LEARN_PATH = os.path.expanduser("~/Library/Application Support/RomKana/learned.json")
_LEARN_MAX_READING = 12   # don't learn long readings (whole sentences never repeat)
_LEARN_PROMOTE_MIN = 2    # promote a surface only after it's been chosen this many times
_LEARN_CTX_CHARS = 2      # how many trailing context chars form the context bucket
# Learning is keyed by "<ctxbucket>\t<reading>". The bucket is the last few chars
# of the preceding text, so the SAME reading can resolve differently by context
# (e.g. ""\tあめ vs って\tあめ). An empty bucket is the broad, any-context entry —
# the fallback. This keeps the user's own context→choice habit, which is more
# reliable than the small LLM (measured: it ranks 飴/汽車 last even in the right
# context). Lookup tries the context-specific entry first, then the broad one.
_learned = {}             # "<bucket>\t<reading>" -> {surface: count}
_learn_lock = threading.Lock()


def _learn_key(reading, context):
    return f"{(context or '')[-_LEARN_CTX_CHARS:]}\t{reading}"


def _load_learned():
    global _learned
    try:
        with open(_LEARN_PATH, encoding="utf-8") as f:
            _learned = json.load(f)
    except Exception:  # noqa: BLE001 - missing/corrupt file -> start empty
        _learned = {}
        return
    # Migrate the old flat format ({reading: {...}}) to broad-bucket keys.
    if any("\t" not in k for k in _learned):
        _learned = {(k if "\t" in k else f"\t{k}"): v for k, v in _learned.items()}


def _save_learned():
    try:
        os.makedirs(os.path.dirname(_LEARN_PATH), exist_ok=True)
        tmp = _LEARN_PATH + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(_learned, f, ensure_ascii=False)
        os.replace(tmp, _LEARN_PATH)  # atomic
    except Exception as e:  # noqa: BLE001
        sys.stderr.write(f"[romkana] save learned failed: {e}\n")


def record_choice(reading, surface, context=""):
    """Record that the user chose `surface` for `reading` after `context`. Bumps
    both the broad (any-context) entry and the context-specific one. Skips no-ops
    (plain kana) and overly long readings that won't recur."""
    reading = (reading or "").strip()
    surface = (surface or "").strip()
    if not reading or not surface or reading == surface:
        return
    if len(reading) > _LEARN_MAX_READING:
        return
    with _learn_lock:
        _bump(_learn_key(reading, ""), surface)            # broad / any-context
        bucket = (context or "")[-_LEARN_CTX_CHARS:]
        if bucket:
            _bump(_learn_key(reading, context), surface)   # context-specific
        _save_learned()


def _bump(key, surface):
    counts = _learned.setdefault(key, {})
    counts[surface] = counts.get(surface, 0) + 1


# User dictionary: hand-curated reading -> [surfaces], merged into the candidate
# list so the user can register conversions the dictionary lacks (e.g. あい->AI).
# Distinct from learning: these are always offered as candidates (not gated on a
# pick count). Edit the JSON file to add entries.
_USERDICT_PATH = os.path.expanduser("~/Library/Application Support/RomKana/userdict.json")
_userdict = {}  # reading -> [surface, ...]
_userdict_mtime = 0.0


def _load_userdict():
    """Load the user dictionary, seeding it with あい->AI on first run."""
    global _userdict, _userdict_mtime
    if not os.path.exists(_USERDICT_PATH):
        _userdict = {"あい": ["AI"]}
        try:
            os.makedirs(os.path.dirname(_USERDICT_PATH), exist_ok=True)
            with open(_USERDICT_PATH, "w", encoding="utf-8") as f:
                json.dump(_userdict, f, ensure_ascii=False, indent=2)
        except Exception as e:  # noqa: BLE001
            sys.stderr.write(f"[romkana] seed userdict failed: {e}\n")
    else:
        try:
            with open(_USERDICT_PATH, encoding="utf-8") as f:
                _userdict = json.load(f)
        except Exception:  # noqa: BLE001
            _userdict = {}
    try:
        _userdict_mtime = os.path.getmtime(_USERDICT_PATH)
    except OSError:
        _userdict_mtime = 0.0


def _maybe_reload_userdict():
    """Hot-reload the dictionary when the file changes, so edits take effect
    without restarting the service."""
    try:
        m = os.path.getmtime(_USERDICT_PATH)
    except OSError:
        return
    if m != _userdict_mtime:
        _load_userdict()


def _apply_userdict(reading, ordered):
    """Insert the user's registered surfaces for this reading just below the top
    candidate (one key away), so they're selectable without displacing the
    contextual #1. Promotion to #1 still happens via learning if picked often."""
    _maybe_reload_userdict()
    extras = _userdict.get(reading)
    if not extras:
        return ordered
    for s in reversed(extras):
        if s and s not in ordered:
            ordered.insert(1 if ordered else 0, s)
    return ordered


def reset_learned(reading=None):
    """Clear adaptive learning: every entry for a single reading (all context
    buckets) if given, otherwise everything (memory + file)."""
    global _learned
    with _learn_lock:
        if reading:
            rd = reading.strip()
            for k in [k for k in _learned if k.split("\t", 1)[-1] == rd]:
                _learned.pop(k, None)
        else:
            _learned = {}
        if _learned:
            _save_learned()
        else:
            try:
                if os.path.exists(_LEARN_PATH):
                    os.remove(_LEARN_PATH)
            except OSError as e:  # noqa: BLE001
                sys.stderr.write(f"[romkana] reset learned failed: {e}\n")
    return len(_learned)


def _apply_learned(reading, ordered, context=""):
    """Float the user's most-chosen surface for this reading to the front. Tries
    the context-specific entry first (so the same reading can resolve differently
    by context), then the broad any-context entry. Leaves order untouched if
    neither has cleared the threshold — the dictionary/LLM ranking then governs."""
    bucket = (context or "")[-_LEARN_CTX_CHARS:]
    keys = ([_learn_key(reading, context)] if bucket else []) + [_learn_key(reading, "")]
    for key in keys:
        counts = _learned.get(key)
        if not counts:
            continue
        best = max(counts, key=counts.get)
        if counts[best] >= _LEARN_PROMOTE_MIN and best in ordered:
            return ordered if ordered[0] == best else [best] + [c for c in ordered if c != best]
    return ordered


def _ensure_llm():
    if _llm["loaded"]:
        return _llm["model"] is not None
    _llm["loaded"] = True
    try:
        from mlx_lm import load
        _llm["model"], _llm["tok"] = load(MODEL_REPO)
        sys.stderr.write("[romkana] LLM loaded for rescoring\n")
    except Exception as e:  # noqa: BLE001 - degrade gracefully to mozcpy-only
        sys.stderr.write(f"[romkana] LLM load failed, dictionary-only: {e}\n")
        _llm["model"] = None
    return _llm["model"] is not None


def _rerank(context, candidates):
    """Reorder candidates by the total (sum) conditional log-likelihood of each
    candidate's tokens given the context. SUM (not mean): natural/common kanji
    compress to fewer tokens, so summing rewards them — averaging cancels it.

    The context is identical across all candidates, so we forward it ONCE into a
    KV cache, tile that cache across the N candidates, then score every
    candidate's remaining tokens in a single batched forward. This removes the
    redundant per-candidate context recompute (the dominant cost for long
    context) while producing the same scores as the naive per-candidate scorer
    (verified against a single-sequence ground truth).

    Right-padding the remainder is safe under causal attention: a candidate's
    real tokens precede its pads, so pad positions never affect real-token
    logits, and we mask pads out of the score anyway."""
    import mlx.core as mx
    from mlx_lm.models.cache import make_prompt_cache
    tok, model = _llm["tok"], _llm["model"]

    full = [tok.encode((context or "") + c) for c in candidates]
    ctx_len = max(1, len(tok.encode(context or "")))
    n = len(full)

    # Longest common prefix across all candidate token sequences (≈ the context;
    # one shorter if the tokenizer merges across the context/candidate boundary).
    P = min(len(f) for f in full)
    for j in range(P):
        c0 = full[0][j]
        if any(full[i][j] != c0 for i in range(1, n)):
            P = j
            break
    # Cache the shared prefix, but never past where scoring begins (ctx_len-1),
    # so every scored token's predicting logit comes from the batched remainder.
    cache_len = max(0, min(P, ctx_len - 1))

    pad_id = tok.eos_token_id if tok.eos_token_id is not None else 0
    cache = make_prompt_cache(model)
    if cache_len > 0:
        model(mx.array([full[0][:cache_len]]), cache=cache)  # populate cache (logits unused)
        for layer in cache:                                  # replicate context across candidates
            k, v = layer.state
            layer.state = (mx.concatenate([k] * n, axis=0),
                           mx.concatenate([v] * n, axis=0))

    rem = [f[cache_len:] for f in full]
    R = max(len(r) for r in rem)
    xb = mx.array([r + [pad_id] * (R - len(r)) for r in rem])   # [N, R]
    logits = model(xb, cache=cache)                            # [N, R, V]
    lse = mx.logsumexp(logits, axis=-1)                        # [N, R]

    # Remainder slot k predicts token rem_i[k+1] (= full_i[cache_len+k+1]). A slot
    # is scored when the predicted token lies in [ctx_len, len(full_i)).
    T = [[0] * R for _ in range(n)]
    M = [[0.0] * R for _ in range(n)]
    for i, r in enumerate(rem):
        for k in range(ctx_len - 1 - cache_len, len(r) - 1):
            T[i][k] = r[k + 1]
            M[i][k] = 1.0
    tok_lp = mx.take_along_axis(logits, mx.array(T)[..., None], axis=-1).squeeze(-1) - lse
    scores = (tok_lp * mx.array(M)).sum(axis=1).tolist()
    scores = [s if len(full[i]) > ctx_len else -1e9 for i, s in enumerate(scores)]
    order = sorted(range(n), key=lambda i: scores[i], reverse=True)
    return [candidates[i] for i in order]


# Common colloquial kana spellings normalized to their standard form before
# dictionary lookup. The ORIGINAL reading's candidates are still merged in
# afterwards, so e.g. 交友 (こうゆう) stays reachable even when こうゆう→こういう
# is applied. Without this, mozcpy reads こうゆう as 交友/公有 and the natural
# "こういうふうに…" never appears.
_COLLOQUIAL_RULES = [
    ("こうゆう", "こういう"),
    ("そうゆう", "そういう"),
    ("どうゆう", "どういう"),
    ("とゆう", "という"),
]


def _normalize(reading):
    out = reading
    for a, b in _COLLOQUIAL_RULES:
        out = out.replace(a, b)
    return out


def _mozc(reading, n_best):
    try:
        cs = _converter.convert(reading, n_best=max(1, n_best))
    except Exception:  # noqa: BLE001
        return []
    return [cs] if isinstance(cs, str) else list(cs)


def convert(reading, context="", n_best=6, use_llm=False):
    reading = (reading or "").strip()
    if not reading:
        return {"candidates": [], "best": ""}
    norm = _normalize(reading)
    # Normalized reading first (usually what the user meant), then the original
    # so its candidates remain available.
    readings = [norm, reading] if norm != reading else [reading]
    cands = []
    for r in readings:
        cands.extend(_mozc(r, n_best))
    # Always offer the raw kana reading as a fallback candidate.
    cands.append(reading)
    # Dedupe, preserve order.
    seen, ordered = set(), []
    for c in cands:
        if c and c not in seen:
            seen.add(c)
            ordered.append(c)

    if use_llm and len(ordered) > 1 and _ensure_llm():
        with _llm_lock:
            try:
                ordered = _rerank(context, ordered)
            except Exception as e:  # noqa: BLE001
                sys.stderr.write(f"[romkana] rescore failed: {e}\n")

    # Offer registered user-dictionary surfaces, then let learning promote a
    # consistently-chosen one to #1 (runs last so it can override the model).
    ordered = _apply_userdict(reading, ordered)
    ordered = _apply_learned(reading, ordered, context)

    return {"candidates": ordered, "best": ordered[0] if ordered else reading}


def convert_segments(segments, context="", n_best=6, use_llm=False):
    """Convert space-separated segments INDEPENDENTLY, left to right, feeding each
    chosen surface as context for the next (so '生成'→'AI' reads naturally). Each
    segment is {"r": <kana reading to convert>} or {"t": <literal text>} (e.g. an
    acronym like "llm" the client already knows shouldn't be kana-converted).
    Returns the concatenated best surface, plus a raw-reading fallback."""
    acc = context or ""
    bests, raw = [], []
    for seg in segments:
        if "t" in seg:
            s = (seg.get("t") or "")
            bests.append(s)
            raw.append(s)
        else:
            r = (seg.get("r") or "").strip()
            if not r:
                continue
            best = convert(r, context=acc, n_best=n_best, use_llm=use_llm)["best"]
            bests.append(best)
            raw.append(r)
        acc = (acc + bests[-1])[-24:]
    concat = "".join(bests)
    cands = [concat]
    if "".join(raw) != concat:
        cands.append("".join(raw))
    return {"candidates": cands, "best": concat, "segments_best": bests}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # quiet

    def _send(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self._send(200, {"ok": True, "llm": _llm["model"] is not None})
        elif self.path == "/learned":
            self._send(200, {"learned": _learned})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path not in ("/convert", "/learn", "/reset_learn"):
            self._send(404, {"error": "not found"})
            return
        try:
            n = int(self.headers.get("Content-Length", 0))
            req = json.loads(self.rfile.read(n) or b"{}")
        except Exception:  # noqa: BLE001
            self._send(400, {"error": "bad json"})
            return
        if self.path == "/learn":
            record_choice(req.get("reading", ""), req.get("surface", ""),
                          req.get("context", ""))
            self._send(200, {"ok": True})
            return
        if self.path == "/reset_learn":
            remaining = reset_learned(req.get("reading"))
            self._send(200, {"ok": True, "remaining": remaining})
            return
        if req.get("segments"):
            result = convert_segments(
                segments=req["segments"],
                context=req.get("context", ""),
                n_best=req.get("n_best", 6),
                use_llm=bool(req.get("use_llm", False)),
            )
        else:
            result = convert(
                reading=req.get("reading", ""),
                context=req.get("context", ""),
                n_best=req.get("n_best", 6),
                use_llm=bool(req.get("use_llm", False)),
            )
        self._send(200, result)


def main():
    _load_learned()
    _load_userdict()
    # Warm-load the reranker in the background so the first conversion that asks
    # for use_llm doesn't block on a cold model load (~10-30s).
    threading.Thread(target=_ensure_llm, daemon=True).start()
    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    sys.stderr.write(f"[romkana] conversion service on http://{HOST}:{PORT}\n")
    srv.serve_forever()


if __name__ == "__main__":
    main()
