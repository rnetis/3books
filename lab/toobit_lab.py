#!/usr/bin/env python3
"""renko-toobit-scanner — Python signal lab CLI.

Subcommands
  check      smoke-test every Toobit endpoint the app uses (no API keys needed)
  universe   print the top-liquidity USDT-M universe by 24 h quote volume
  scan       full scan: Renko + Wyckoff + tape + Miner scores for every symbol
  watch      repeat scan every --interval seconds (like the app's scan loop)

Examples
  python toobit_lab.py check
  python toobit_lab.py universe --top 30
  python toobit_lab.py scan --top 30 --threshold 75
  python toobit_lab.py watch --interval 60
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from datetime import datetime, timezone

import requests

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from engine import Candle, scan_symbol  # noqa: E402

BASE = "https://api.toobit.com"
UA = {"User-Agent": "renko-toobit-scanner-lab/1.0"}
MIN = 60_000


def get(path: str, **params) -> object:
    r = requests.get(BASE + path, params=params, headers=UA, timeout=20)
    r.raise_for_status()
    return r.json()


def parse_klines(raw) -> list[Candle]:
    """Toobit kline row: [t,o,h,l,c,baseVol,?,quoteVol,trades,takerBuyBase,takerBuyQuote]"""
    out = []
    for row in raw:
        t = int(row[0])
        out.append(Candle(t=t, o=float(row[1]), h=float(row[2]), l=float(row[3]),
                          c=float(row[4]), v=float(row[5]),
                          qv=float(row[7]) if len(row) > 7 else 0.0,
                          trades=int(row[8]) if len(row) > 8 else 0,
                          taker_buy=float(row[9]) if len(row) > 9 else 0.0))
    return out


def drop_partial(candles: list[Candle], interval_ms: int, now_ms: int | None = None) \
        -> list[Candle]:
    """The last kline is the in-progress candle; the engines score completed bars."""
    now_ms = now_ms or int(time.time() * 1000)
    if candles and candles[-1].t + interval_ms > now_ms:
        candles = candles[:-1]
    return candles


def load_universe(top: int) -> list[dict]:
    tickers = get("/quote/v1/contract/ticker/24hr")
    swaps = [t for t in tickers if str(t.get("s", "")).endswith("-SWAP-USDT")]
    swaps.sort(key=lambda t: float(t.get("qv", 0)), reverse=True)
    return swaps[:top]


def load_tick_sizes() -> dict[str, float]:
    info = get("/api/v1/exchangeInfo")
    ticks: dict[str, float] = {}
    for s in info.get("symbols", []):
        for f in s.get("filters", []):
            if f.get("filterType") == "PRICE_FILTER":
                try:
                    ticks[s["symbol"]] = float(f["tickSize"])
                except (KeyError, ValueError):
                    pass
    return ticks


# --------------------------------------------------------------------------- #
# Subcommands
# --------------------------------------------------------------------------- #


def cmd_check(args) -> int:
    print("== Toobit endpoint smoke tests ==")
    fails = 0

    def expect(name: str, cond: bool, detail: str = ""):
        nonlocal fails
        print(f"  [{'PASS' if cond else 'FAIL'}] {name} {detail}")
        fails += 0 if cond else 1

    now = int(time.time() * 1000)
    k = parse_klines(get("/quote/v1/klines", symbol="BTC-SWAP-USDT",
                         interval="1m", limit=200))
    expect("klines 1m BTC-SWAP-USDT", len(k) >= 100,
           f"({len(k)} candles, last close {k[-1].c})")
    expect("klines ascending & fresh", k[0].t < k[-1].t and now - k[-1].t < 10 * MIN)
    k15 = parse_klines(get("/quote/v1/klines", symbol="ETH-SWAP-USDT",
                           interval="15m", limit=100))
    expect("klines 15m ETH-SWAP-USDT", len(k15) >= 50, f"({len(k15)} candles)")
    t = get("/quote/v1/contract/ticker/24hr")
    swaps = [x for x in t if str(x.get("s", "")).endswith("-SWAP-USDT")]
    expect("ticker 24h universe", len(swaps) > 100, f"({len(swaps)} swaps)")
    expect("ticker fields", {"s", "c", "qv", "op", "pcp"} <= set(swaps[0].keys()))
    info = get("/api/v1/exchangeInfo")
    syms = [s for s in info.get("symbols", []) if s.get("status") == "TRADING"]
    expect("exchangeInfo", len(syms) > 100, f"({len(syms)} trading symbols)")
    oi = get("/quote/v1/openInterest", symbol="BTC-SWAP-USDT")
    expect("openInterest", "openInterestList" in oi, f"({oi})")
    fr = get("/api/v1/futures/fundingRate", symbol="BTC-SWAP-USDT")
    expect("fundingRate", isinstance(fr, list) and fr and "rate" in fr[0])
    ls = get("/quote/v1/globalLongShortAccountRatio", symbol="BTC-SWAP-USDT",
             period="15m", limit=5)
    expect("globalLongShortAccountRatio", isinstance(ls, list) and len(ls) >= 1)
    print(f"== {8 - fails}/8 passed ==")
    return 1 if fails else 0


def cmd_universe(args) -> int:
    swaps = load_universe(args.top)
    print(f"Top {len(swaps)} by 24h quote volume:")
    for i, t in enumerate(swaps, 1):
        print(f"{i:>3}  {t['s']:<20} last {t['c']:>12}  "
              f"qv {float(t['qv']) / 1e6:>10.1f}M  oi {float(t['op']) / 1e6:>8.2f}M  "
              f"24h {float(t['pcp']) * 100:>+6.2f}%")
    return 0


def cmd_scan(args) -> int:
    ticks = load_tick_sizes()
    swaps = load_universe(args.top)
    signals = []
    print(f"Scanning top {len(swaps)} Toobit USDT-M perps "
          f"(threshold {args.threshold}) ...")
    for t in swaps:
        sym = t["s"]
        base = sym.replace("-SWAP-USDT", "USDT")
        try:
            k1 = drop_partial(parse_klines(get("/quote/v1/klines", symbol=sym,
                                               interval="1m", limit=1000)), MIN)
            k15 = drop_partial(parse_klines(get("/quote/v1/klines", symbol=sym,
                                                interval="15m", limit=200)), 15 * MIN)
        except (requests.RequestException, ValueError, IndexError) as e:
            print(f"  {sym}: fetch failed ({e.__class__.__name__})")
            continue
        sig = scan_symbol(sym, k1, k15, tick=ticks.get(base, 1e-6),
                          threshold=args.threshold)
        if sig:
            signals.append(sig)
        time.sleep(args.pause)  # be polite to the API

    longs = [s for s in signals if s["direction"] == "LONG"]
    shorts = [s for s in signals if s["direction"] == "SHORT"]
    rest = [s for s in signals if s["direction"] == "NEUTRAL"]
    for group, title in ((longs, "LONG setups"), (shorts, "SHORT setups")):
        group.sort(key=lambda s: s["score"], reverse=True)
        print(f"\n-- {title} ({len(group)}) --")
        for s in group:
            print(f"  {s['score']:>3}  {s['symbol']:<18} @ {s['price']:.6g}  "
                  f"entry {s['entry']:.6g}  stop {s['stop']:.6g}  "
                  f"1R {s['t1']:.6g}")
    print(f"\n-- neutral / stand-aside: {len(rest)} --")
    for s in sorted(rest, key=lambda s: max(s['score_long'], s['score_short']),
                    reverse=True)[:10]:
        warn = s["breakdown"]["C_tape"].get("warn") or ""
        print(f"  {max(s['score_long'], s['score_short']):>3}  {s['symbol']:<18} "
              f"{warn}")

    out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
    os.makedirs(out_dir, exist_ok=True)
    payload = {"generated": datetime.now(timezone.utc).isoformat(),
               "threshold": args.threshold, "universe_top": args.top,
               "signals": signals}
    path = os.path.join(out_dir, "latest_scan.json")
    with open(path, "w") as f:
        json.dump(payload, f, indent=1)
    print(f"\nsaved {len(signals)} signals -> {path}")

    hot = [s for s in signals if s["notify"]]
    if hot:
        print("\n*** NOTIFICATIONS (score >= threshold) ***")
        for s in sorted(hot, key=lambda s: s["score"], reverse=True):
            print(f"  {s['direction']} {s['symbol']}  score {s['score']}  "
                  f"entry {s['entry']:.6g}  stop {s['stop']:.6g}  1R {s['t1']:.6g}")
    return 0


def cmd_watch(args) -> int:
    while True:
        os.system("clear" if os.name != "nt" else "cls")
        cmd_scan(args)
        print(f"\nsleeping {args.interval}s (ctrl-C to stop)")
        try:
            time.sleep(args.interval)
        except KeyboardInterrupt:
            return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("check", help="smoke-test Toobit endpoints")
    p.set_defaults(fn=cmd_check)

    p = sub.add_parser("universe", help="top-liquidity universe")
    p.add_argument("--top", type=int, default=30)
    p.set_defaults(fn=cmd_universe)

    p = sub.add_parser("scan", help="one full scan of the universe")
    p.add_argument("--top", type=int, default=30)
    p.add_argument("--threshold", type=int, default=75)
    p.add_argument("--pause", type=float, default=0.15,
                   help="pause between symbols, seconds")
    p.set_defaults(fn=cmd_scan)

    p = sub.add_parser("watch", help="scan in a loop")
    p.add_argument("--top", type=int, default=30)
    p.add_argument("--threshold", type=int, default=75)
    p.add_argument("--pause", type=float, default=0.15)
    p.add_argument("--interval", type=int, default=60)
    p.set_defaults(fn=cmd_watch)

    args = ap.parse_args()
    return args.fn(args)


if __name__ == "__main__":
    raise SystemExit(main())
