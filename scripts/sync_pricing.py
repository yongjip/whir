#!/usr/bin/env python3
"""Sync pricing.json from LiteLLM's community-maintained price table.

Run by .github/workflows/sync-pricing.yml (and by hand). Stdlib only.

Strategy
  Claude  auto-discover every top-level `claude-*` chat model from LiteLLM, so
          new models get priced without a code change. Rows whose cache prices
          don't match Whir's hardcoded multipliers (read 0.1x, write-5m 1.25x)
          are dropped with a warning — WhirCore prices cache tokens by
          multiplier, so a mismatched row would misprice silently. Family
          fallback prefixes (claude-opus-4, ...) cover log snapshots that are
          newer than LiteLLM.
  OpenAI  auto-discover direct text GPT models with complete input/cache/output
          prices. Explicit exceptions cover Codex ids LiteLLM does not expose.

Safety
  - No write when nothing changed (no daily commit noise; asOf only moves on
    a real change).
  - Fails (exit 1, no write) when a non-estimate price moves by more than 2x
    either way, or when Claude coverage collapses — a human should look.
"""

import json
import math
import sys
import urllib.request
from datetime import date, timezone, datetime
from pathlib import Path

SOURCE = "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
PRICING = Path(__file__).resolve().parent.parent / "pricing.json"

# Family fallbacks: price unknown-but-related model ids (e.g. a dated snapshot
# LiteLLM hasn't added yet) off a representative model. Longest-prefix matching
# in WhirCore means exact rows always win over these.
CLAUDE_FAMILIES = [
    ("claude-fable-5",  "claude-fable-5"),
    ("claude-opus-4",   "claude-opus-4-8"),
    ("claude-sonnet-5", "claude-sonnet-5"),
    ("claude-sonnet-4", "claude-sonnet-4-6"),
    ("claude-haiku-4",  "claude-haiku-4-5"),
]

# (whir id, litellm key) for Codex model ids absent or inconsistently named in
# LiteLLM. Ordinary OpenAI models are discovered automatically below.
OPENAI_EXCEPTIONS = [
    ("gpt-5.3-codex-spark", "gpt-5.3-codex-spark"),
]

# LiteLLM labels some specialized APIs as chat models. Codex logs contain text
# model ids, so exclude those modalities rather than silently applying their
# token tables to an unrelated future Codex id.
OPENAI_EXCLUDED_MARKERS = ("audio", "realtime", "search")

MAX_RATIO = 2.0   # a legit repricing beyond 2x either way deserves human eyes


def clean(x):
    x = round(x, 6)
    return int(x) if x == int(x) else x


def per_million(model, field):
    v = model.get(field)
    return clean(v * 1e6) if isinstance(v, (int, float)) else None


def multipliers_ok(key, m):
    """Whir hardcodes cache read = 0.1x input, write-5m = 1.25x input."""
    i = m.get("input_cost_per_token")
    for field, mult in [("cache_read_input_token_cost", 0.1),
                        ("cache_creation_input_token_cost", 1.25)]:
        v = m.get(field)
        if v is not None and not math.isclose(v, mult * i, rel_tol=1e-6):
            print(f"  warn: {key} {field} != {mult}x input — dropped (would misprice cache tokens)")
            return False
    return True


def main():
    current = json.loads(PRICING.read_text())
    cur_claude = {r["prefix"]: r for r in current.get("claude", [])}
    cur_openai = {r["prefix"]: r for r in current.get("openai", [])}

    with urllib.request.urlopen(SOURCE, timeout=60) as resp:
        lite = json.load(resp)

    # ---- Claude: auto-discovery + family fallbacks ----
    claude = {}
    for key, m in sorted(lite.items()):
        if not (isinstance(m, dict) and key.startswith("claude-") and "/" not in key):
            continue
        if m.get("litellm_provider") != "anthropic" or m.get("mode") != "chat":
            continue
        i, o = per_million(m, "input_cost_per_token"), per_million(m, "output_cost_per_token")
        if not i or not o or not multipliers_ok(key, m):
            continue
        claude[key] = {"prefix": key, "input": i, "output": o}
    for prefix, rep in CLAUDE_FAMILIES:
        if prefix in claude:
            continue
        if rep in claude:
            claude[prefix] = {"prefix": prefix, "input": claude[rep]["input"], "output": claude[rep]["output"]}
        elif prefix in cur_claude:
            print(f"  warn: family {prefix}: representative {rep} missing upstream — kept current values")
            claude[prefix] = cur_claude[prefix]
    if len(claude) < 5:
        sys.exit(f"error: only {len(claude)} Claude rows survived — upstream shape changed? aborting")

    # ---- OpenAI: auto-discover direct text models + explicit exceptions ----
    openai = {}
    for key, m in sorted(lite.items()):
        if not (isinstance(m, dict) and key.startswith("gpt-") and "/" not in key):
            continue
        if m.get("litellm_provider") != "openai" or m.get("mode") != "chat":
            continue
        if any(marker in key for marker in OPENAI_EXCLUDED_MARKERS):
            continue
        i = per_million(m, "input_cost_per_token")
        c = per_million(m, "cache_read_input_token_cost")
        o = per_million(m, "output_cost_per_token")
        if not i or not c or not o or c > i:
            continue
        openai[key] = {"prefix": key, "input": i, "cachedInput": c,
                       "output": o, "estimate": False}

    for prefix, key in OPENAI_EXCEPTIONS:
        if prefix in openai:
            continue
        m = lite.get(key)
        i = per_million(m, "input_cost_per_token") if m else None
        o = per_million(m, "output_cost_per_token") if m else None
        c = per_million(m, "cache_read_input_token_cost") if m else None
        if i and c and o and c <= i:
            openai[prefix] = {"prefix": prefix, "input": i, "cachedInput": c,
                              "output": o, "estimate": False}
        elif prefix in cur_openai:
            print(f"  warn: {prefix}: no usable prices upstream ({key}) — kept current values")
            openai[prefix] = cur_openai[prefix]
        else:
            print(f"  warn: {prefix}: no upstream prices and no current row — skipped")

    # ---- sanity band vs the committed file (estimates are exempt) ----
    # Existing rows retain the 2x change guard. New Claude snapshots also check
    # their committed family fallback; new OpenAI ids are distinct tiers, so a
    # family ratio would reject legitimate mini/nano/etc. prices.
    def family(prefix, committed):
        best = None
        for p, r in committed.items():
            if prefix.startswith(p) and not r.get("estimate") and (best is None or len(p) > len(best[0])):
                best = (p, r)
        return best[1] if best else None

    def check_changes(rows, committed, family_fallback):
        for prefix, row in rows.items():
            old = committed.get(prefix)
            via = "prior"
            if family_fallback and (old is None or old.get("estimate")):
                old, via = family(prefix, committed), "family"
            if not old:
                reason = "no committed family" if family_fallback else "new model id"
                print(f"  warn: {prefix}: {reason} — admitting after structural checks")
                continue
            for f in ("input", "output"):
                if not (1 / MAX_RATIO <= row[f] / old[f] <= MAX_RATIO):
                    sys.exit(f"error: {prefix} {f} = {row[f]} vs {via} {old[f]} (>{MAX_RATIO}x) — review manually")

    check_changes(claude, cur_claude, family_fallback=True)
    check_changes(openai, cur_openai, family_fallback=False)

    new_claude = sorted(claude.values(), key=lambda r: r["prefix"])
    new_openai = sorted(openai.values(), key=lambda r: r["prefix"])
    if new_claude == current.get("claude") and new_openai == current.get("openai"):
        print("pricing.json unchanged")
        return

    out = {
        "version": 1,
        "asOf": datetime.now(timezone.utc).date().isoformat(),
        "comment": "Whir model price table ($/1M tokens); Claude family-prefix matched, "
                   "OpenAI exact-id matched with dated-snapshot fallback; "
                   "fetched daily by the app. Auto-synced from LiteLLM's "
                   "model_prices_and_context_window.json by scripts/sync_pricing.py — "
                   "edit that script, not this file. Claude cache multipliers are fixed "
                   "in code: read 0.1x input, write-5m 1.25x, write-1h 2x.",
        "claude": new_claude,
        "openai": new_openai,
    }
    PRICING.write_text(json.dumps(out, indent=2) + "\n")
    print(f"pricing.json updated: {len(new_claude)} Claude rows, {len(new_openai)} OpenAI rows, asOf {out['asOf']}")


if __name__ == "__main__":
    main()
