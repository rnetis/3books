"""renko-toobit-scanner — signal engine (Python mirror of the Swift engines).

Every rule here is traceable to docs/strategy.md, which maps each rule to the
three books:
  A  Wyckoff structure          (The Wyckoff Methodology in Depth)      30 pts
  B  Renko trend quality        (chart engine added by this repo)      20 pts
  C  Tape rules                 (The Day Traders' Bible)               25 pts
  D  Dual-time-frame momentum   (High Probability Trading Strategies)  25 pts

Pure stdlib — no third-party dependencies — so the same file can run in CI.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Sequence

# --------------------------------------------------------------------------- #
# Primitives
# --------------------------------------------------------------------------- #


@dataclass
class Candle:
    t: int      # open time ms
    o: float
    h: float
    l: float
    c: float
    v: float    # base volume
    qv: float = 0.0   # quote volume
    trades: int = 0
    taker_buy: float = 0.0  # taker-buy base volume (field 9), if present


@dataclass
class Brick:
    direction: int          # +1 up, -1 down
    open: float
    close: float
    t_open: int             # candle open time when the brick was emitted
    t_close: int            # last candle that touched/extended the brick
    volume: float = 0.0     # summed base volume of candles attributed to it
    candles: int = 0        # candle count attributed to this brick
    low: float = 0.0        # lowest candle low while this brick was head
    high: float = 0.0       # highest candle high while this brick was head


def sma(values: Sequence[float], period: int) -> list[float]:
    out = [float("nan")] * len(values)
    if period <= 0:
        return out
    running = 0.0
    for i, v in enumerate(values):
        running += v
        if i >= period:
            running -= values[i - period]
        if i >= period - 1:
            out[i] = running / period
    return out


def atr(candles: Sequence[Candle], period: int = 14) -> float | None:
    """ATR(period) on True Range; returns the last value or None if not ready."""
    if len(candles) < period + 1:
        return None
    trs = []
    prev_close = candles[0].c
    for cd in candles[1:]:
        trs.append(max(cd.h - cd.l, abs(cd.h - prev_close), abs(cd.l - prev_close)))
        prev_close = cd.c
    trs = trs[-period:]
    return sum(trs) / len(trs) if trs else None


def pivots(values: Sequence[float], lookback: int = 3) -> list[tuple[int, str]]:
    """Fractal pivots. Returns [(index, 'H'|'L')]."""
    out = []
    for i in range(lookback, len(values) - lookback):
        window = values[i - lookback: i + lookback + 1]
        if values[i] == max(window) and window.count(values[i]) == 1:
            out.append((i, "H"))
        elif values[i] == min(window) and window.count(values[i]) == 1:
            out.append((i, "L"))
    return out


# --------------------------------------------------------------------------- #
# Renko engine (wick-aware, classic threshold algorithm)
# --------------------------------------------------------------------------- #


def build_bricks(candles: Sequence[Candle], brick_size: float,
                 max_bricks_per_candle: int = 64) -> list[Brick]:
    """Renko construction per docs/strategy.md: closes drive continuation and
    flips (a reversal needs a full brick-size close beyond the last edge), and
    wicks may only EXTEND the current direction — never flip intra-candle.
    Each candle may emit 0..n bricks. Anchor is the first open rounded to a
    size multiple."""
    if brick_size <= 0 or not candles:
        return []
    bricks: list[Brick] = []
    edge = round(candles[0].o / brick_size) * brick_size
    direction = 0
    for cd in candles:
        emitted = 0
        while emitted < max_bricks_per_candle:
            if cd.c >= edge + brick_size:       # close-based continuation / flip up
                bricks.append(Brick(+1, edge, edge + brick_size, cd.t, cd.t,
                                    low=min(cd.l, edge),
                                    high=max(cd.h, edge + brick_size)))
                edge += brick_size
                direction = +1
            elif cd.c <= edge - brick_size:     # close-based continuation / flip down
                bricks.append(Brick(-1, edge, edge - brick_size, cd.t, cd.t,
                                    low=min(cd.l, edge - brick_size),
                                    high=max(cd.h, edge)))
                edge -= brick_size
                direction = -1
            else:
                break
            emitted += 1
        if direction > 0:                       # wicks extend the current run only
            while cd.h >= edge + brick_size and emitted < max_bricks_per_candle:
                bricks.append(Brick(+1, edge, edge + brick_size, cd.t, cd.t,
                                    low=min(cd.l, edge),
                                    high=max(cd.h, edge + brick_size)))
                edge += brick_size
                emitted += 1
        elif direction < 0:
            while cd.l <= edge - brick_size and emitted < max_bricks_per_candle:
                bricks.append(Brick(-1, edge, edge - brick_size, cd.t, cd.t,
                                    low=min(cd.l, edge - brick_size),
                                    high=max(cd.h, edge)))
                edge -= brick_size
                emitted += 1
        if bricks:                              # attribute the candle once
            tail = bricks[-1]
            tail.volume += cd.v
            tail.candles += 1
            tail.t_close = cd.t
            tail.low = min(tail.low, cd.l)
            tail.high = max(tail.high, cd.h)
    return bricks


def brick_size(candles: Sequence[Candle], multiplier: float = 0.5,
               fixed: float | None = None) -> float:
    if fixed:
        return fixed
    a = atr(candles, 14)
    return a * multiplier if a else 0.0


def run_head(bricks: Sequence[Brick]) -> int:
    """Consecutive same-direction bricks at the head of the series."""
    if not bricks:
        return 0
    d = bricks[-1].direction
    n = 0
    for b in reversed(bricks):
        if b.direction != d:
            break
        n += 1
    return n


def consistency(bricks: Sequence[Brick], window: int = 10) -> float:
    tail = bricks[-window:]
    if not tail:
        return 0.0
    d = tail[-1].direction
    return sum(1 for b in tail if b.direction == d) / len(tail)


def bricks_per_candle(bricks: Sequence[Brick], window: int = 10) -> float:
    """Brick 'speed': bricks printed per candle consumed, over the window."""
    tail = bricks[-window:]
    candles_used = sum(max(b.candles, 1) for b in tail)
    if candles_used == 0:
        return 0.0
    return len(tail) / candles_used


# --------------------------------------------------------------------------- #
# Factor A — Wyckoff (30)
# --------------------------------------------------------------------------- #


@dataclass
class WyckoffRange:
    support: float
    resistance: float
    low_touches: int
    high_touches: int
    start_idx: int          # absolute brick index where the range begins


@dataclass
class Shake:
    kind: str              # 'spring' | 'utad'
    penetration: float     # depth beyond the level, in bricks
    volume_vs_avg: float   # shake brick volume / volume SMA(20)
    reentry_bricks: int    # bricks taken to reclaim the range (0 = none yet)
    idx: int               # absolute brick index of the shake brick
    extreme: float         # spring low / UTAD high (brick low/high incl. wicks)
    test_valid: bool = False
    broken: bool = False   # failed: price closed beyond the shake extreme again


@dataclass
class Wyckoff:
    points: dict[str, int] = field(default_factory=dict)
    rng: WyckoffRange | None = None
    shake: Shake | None = None
    phase: str = "?"
    notes: list[str] = field(default_factory=list)

    def total(self) -> int:
        return sum(self.points.values())


def _cluster_level(vals: list[float], tol: float) -> tuple[float, int, int] | None:
    """Group pivot prices into levels; return (level, touches, last_index) for the
    level with the most touches (tie: most recent). None if no level has >= 2
    touches. This mirrors the book: a range edge is a level the market *tests*,
    so a one-off extreme (e.g. the spring's own low) must not become support."""
    best: tuple[float, int, int] | None = None
    for i, v in enumerate(vals):
        near = [j for j, w in enumerate(vals) if abs(w - v) <= tol]
        if len(near) < 2:
            continue
        cand = (v, len(near), max(near))
        if best is None or cand[1] > best[1] or (cand[1] == best[1] and cand[2] > best[2]):
            best = cand
    return best


def detect_range(bricks: Sequence[Brick], lookback: int = 60,
                 pivot_lb: int = 3) -> WyckoffRange | None:
    seg = bricks[-lookback:]
    if len(seg) < 12:
        return None
    offset = len(bricks) - len(seg)
    closes = [b.close for b in seg]
    piv = pivots(closes, pivot_lb)
    highs = [closes[i] for i, k in piv if k == "H"]
    lows = [closes[i] for i, k in piv if k == "L"]
    if len(highs) < 2 or len(lows) < 2:
        return None
    tol = (max(closes) - min(closes)) * 0.06 or 1e-12
    sup = _cluster_level(lows, tol)
    res = _cluster_level(highs, tol)
    if sup is None or res is None or res[0] <= sup[0] \
            or (res[0] - sup[0]) / sup[0] < 0.002:
        return None
    start = next((i for i, _ in piv), 0) + offset
    return WyckoffRange(sup[0], res[0], sup[1], res[1], start)


def detect_shake(bricks: Sequence[Brick], rng: WyckoffRange,
                 vol_sma: Sequence[float], window: int = 15) -> Shake | None:
    """Spring (long side) / UTAD (short side) per docs/strategy.md A1."""
    tail = bricks[-window:]
    offset = len(bricks) - len(tail)
    if len(tail) < 4 or rng is None:
        return None
    size = abs(bricks[-1].close - bricks[-1].open) or 1e-12

    def vol_ref(rel_idx: int, fallback: float) -> float:
        j = offset + rel_idx - 1
        if 0 <= j < len(vol_sma) and vol_sma[j] == vol_sma[j]:
            return vol_sma[j]
        return fallback

    for i, b in enumerate(tail):
        if b.close < rng.support:                      # ---- spring side
            extreme = min(x.low for x in tail[i:])
            depth = (rng.support - extreme) / size
            reentry = 0
            for j in range(i + 1, min(i + 6, len(tail))):
                if tail[j].close > rng.support:
                    reentry = j - i
                    break
            return Shake("spring", depth, b.volume / vol_ref(i, b.volume),
                         reentry, offset + i, extreme)
        if b.close > rng.resistance:                   # ---- UTAD side
            extreme = max(x.high for x in tail[i:])
            depth = (extreme - rng.resistance) / size
            reentry = 0
            for j in range(i + 1, min(i + 6, len(tail))):
                if tail[j].close < rng.resistance:
                    reentry = j - i
                    break
            return Shake("utad", depth, b.volume / vol_ref(i, b.volume),
                         reentry, offset + i, extreme)
    return None


def wyckoff_factor(bricks: Sequence[Brick]) -> Wyckoff:
    """docs/strategy.md Factor A. Points attach to the direction of the detected
    event; wyckoff_points_for() maps them to long/short."""
    out = Wyckoff()
    if len(bricks) < 20:
        out.notes.append("not enough bricks")
        return out
    size = abs(bricks[-1].close - bricks[-1].open) or 1e-12
    vols = [b.volume for b in bricks]
    vol_sma = sma(vols, 20)

    rng = detect_range(bricks)
    out.rng = rng
    pts = out.points
    if rng is None:
        out.notes.append("no trading range — no wyckoff edge")
        return out

    # A0 range quality (0-6)
    pts["range_touches"] = 3 if rng.low_touches >= 2 and rng.high_touches >= 2 else 0
    height_bricks = (rng.resistance - rng.support) / size
    pts["range_cause"] = 2 if height_bricks >= 4 else 0
    half = len(bricks) // 2
    first_v = sum(vols[:half]) / max(half, 1)
    second_v = sum(vols[half:]) / max(len(vols) - half, 1)
    pts["range_vol_contract"] = 1 if second_v < first_v else 0
    out.notes.append(f"range {rng.support:.6g}-{rng.resistance:.6g} "
                     f"({height_bricks:.1f} bricks, "
                     f"{rng.low_touches}L/{rng.high_touches}H touches)")

    shake = detect_shake(bricks, rng, vol_sma)
    out.shake = shake
    if shake is None:
        out.phase = "B"
        out.notes.append("no spring/UTAD in window")
        return out

    long_side = shake.kind == "spring"
    after = bricks[shake.idx + 1:]

    # A-failure override: a later brick closes beyond the shake extreme again
    if long_side and any(b.close < shake.extreme - 1e-12 for b in after):
        shake.broken = True
    if not long_side and any(b.close > shake.extreme + 1e-12 for b in after):
        shake.broken = True

    if shake.broken:
        out.phase = "B"
        out.notes.append(f"{shake.kind} failed — new extreme beyond the shake; "
                         "wyckoff reset")
        return out

    # A1 shake quality (0-12)
    pts["shake"] = 5
    if shake.reentry_bricks > 0 and shake.reentry_bricks <= 2 and shake.penetration <= 1.0:
        pts["shake_typology"] = 2          # fast shallow reclaim — spring #3 class
    elif shake.penetration >= 2.0:
        pts["shake_typology"] = 1          # terminal shakeout class
    if shake.penetration <= 2.0:
        pts["shake_depth"] = 2
    if shake.volume_vs_avg <= 1.0:
        pts["shake_volume"] = 2

    # A2 test validity (0-6): only meaningful once price has reclaimed the range
    # (re-entry). The test = first pullback brick after the reclaim, holding
    # above the spring low, on volume lower than the two previous (book Ch. 17/18).
    if shake.reentry_bricks > 0:
        re_idx = shake.idx + shake.reentry_bricks
        want = -1 if long_side else +1
        for k, b in enumerate(bricks[re_idx + 1:]):
            if b.direction == want:
                holds = b.close > shake.extreme if long_side else b.close < shake.extreme
                if holds:
                    shake.test_valid = True
                    pts["test_hold"] = 3
                    t_i = re_idx + 1 + k
                    v1 = vols[t_i - 2] if t_i >= 2 else float("inf")
                    v2 = vols[t_i - 1] if t_i >= 1 else float("inf")
                    if b.volume < v1 and b.volume < v2:
                        pts["test_volume"] = 2
                    if b.candles >= 3:
                        pts["test_range"] = 1   # slow pull = 'narrow range' analogue
                break

    # A3 phase / SOS / LPS (0-6)
    mid = (rng.support + rng.resistance) / 2
    above_mid = bricks[-1].close > mid if long_side else bricks[-1].close < mid
    run = run_head(bricks) if long_side else -run_head(bricks)
    last_v_ref = vol_sma[-1] if vol_sma[-1] == vol_sma[-1] else 0
    if above_mid and run >= 3 and vols[-1] > last_v_ref:
        pts["phase_d_sos"] = 2
        out.phase = "D"
    elif above_mid:
        out.phase = "C->D"
    else:
        out.phase = "C"
    if (len(bricks) - rng.start_idx) >= 12:
        pts["phase_b_cause"] = 2
    if after:
        held = (min(b.low for b in after) > shake.extreme) if long_side \
            else (max(b.high for b in after) < shake.extreme)
        pre_v = sum(vols[max(shake.idx - 3, 0):shake.idx])
        if held and sum(b.volume for b in after) < pre_v:
            pts["lps"] = 2
    out.notes.append(f"{shake.kind} depth {shake.penetration:.1f} brick, "
                     f"vol {shake.volume_vs_avg:.2f}x avg, "
                     f"re-entry {shake.reentry_bricks} bricks, "
                     f"test {'valid' if shake.test_valid else 'pending'}")
    return out


def wyckoff_points_for(w: Wyckoff, side: str) -> int:
    """Side 'long' scores spring-family points; 'short' mirrors UTAD."""
    if w.rng is None:
        return 0
    if w.shake is None or w.shake.broken:
        return min(sum(w.points.values()), 6)   # only A0 range points transfer
    is_long_event = w.shake.kind == "spring"
    return w.total() if (side == "long") == is_long_event else 0


# --------------------------------------------------------------------------- #
# Factor B — Renko trend quality (20)
# --------------------------------------------------------------------------- #


def renko_factor(bricks: Sequence[Brick]) -> dict:
    if len(bricks) < 5:
        return {"long": 0, "short": 0, "run": 0, "consistency": 0.0, "speed": 0.0}
    head = run_head(bricks)
    up_run = head if bricks[-1].direction == 1 else 0
    dn_run = head if bricks[-1].direction == -1 else 0
    cons = consistency(bricks, 10)

    def structure_ok(side: str) -> bool:
        seg = bricks[-6:]
        if side == "long":
            tops = [b.close for b in seg if b.direction == 1]
            return len(tops) >= 2 and tops[-1] > tops[0]
        tops = [b.close for b in seg if b.direction == -1]
        return len(tops) >= 2 and tops[-1] < tops[0]

    avg_speed = bricks_per_candle(bricks, 20)
    head_speed = bricks_per_candle(bricks, max(head, 2))

    def score(run: int, side: str) -> int:
        s = min(run, 8)                       # 0-8 run length
        s += round(cons * 6)                  # 0-6 consistency
        s += 4 if structure_ok(side) else 0   # 0-4 staircase structure
        if run >= 3 and head_speed > avg_speed:
            s += 2                            # 0-2 speed (effort/result harmony)
        return int(min(s, 20))

    return {"long": score(up_run, "long"), "short": score(dn_run, "short"),
            "run": head, "consistency": round(cons, 2), "speed": round(head_speed, 3)}


# --------------------------------------------------------------------------- #
# Factor C — Day Traders' Bible tape rules (25)
# --------------------------------------------------------------------------- #


def tape_factor(candles: Sequence[Candle], brick_size_: float) -> dict:
    window = candles[-30:]
    out: dict = {"long": 0, "short": 0, "stand_aside": False, "warn": None,
                 "notes": [], "adv_dec_share": None}
    if len(window) < 15:
        out["notes"].append("not enough candles")
        return out

    closes = [c.c for c in window]
    piv = pivots(closes, 2)
    highs = [closes[i] for i, k in piv if k == "H"]
    lows = [closes[i] for i, k in piv if k == "L"]

    # C1 trend of the market (0-6): consecutive higher tops & bottoms
    def trend_pts(seq: list[float], rising: bool) -> int:
        n = 0
        for a, b in zip(seq, seq[1:]):
            if (b > a) if rising else (b < a):
                n += 1
        return min(n * 2, 6)

    long_pts = trend_pts(highs[-3:], True) + trend_pts(lows[-3:], True)
    short_pts = trend_pts(highs[-3:], False) + trend_pts(lows[-3:], False)
    long_pts, short_pts = min(long_pts, 6), min(short_pts, 6)

    # C2 advances vs declines volume (0-8)
    up_v = sum(c.v for c in window if c.c > c.o)
    dn_v = sum(c.v for c in window if c.c < c.o)
    share = up_v / (up_v + dn_v) if (up_v + dn_v) else 0.5
    out["adv_dec_share"] = round(share, 3)
    long_pts += round(max(0.0, share - 0.5) * 16)     # +8 per 50pp above neutral
    short_pts += round(max(0.0, 0.5 - share) * 16)

    # C3 closing strength (0-5): winners close in their top/bottom third
    bull = [c for c in window if c.c > c.o]
    bear = [c for c in window if c.c < c.o]
    if bull:
        strong = sum(1 for c in bull if (c.c - c.l) > 2 * (c.h - c.c))
        long_pts += round(min(strong / len(bull) / 0.7, 1.0) * 5)
    if bear:
        strong = sum(1 for c in bear if (c.h - c.c) > 2 * (c.c - c.l))
        short_pts += round(min(strong / len(bear) / 0.7, 1.0) * 5)

    # C4 normal reaction 1/2-2/3 of the preceding swing (0-3)
    if highs and lows and highs[-1] > lows[-1]:
        last_high, last_low = highs[-1], lows[-1]
        retrace = (closes[-1] - last_low) / (last_high - last_low)
        out["retrace"] = round(retrace, 2)
        if retrace >= 0.5:
            long_pts += 3
        elif retrace >= 0.33:
            long_pts += 1
        retrace_s = (last_high - closes[-1]) / (last_high - last_low)
        if retrace_s >= 0.5:
            short_pts += 3
        elif retrace_s >= 0.33:
            short_pts += 1

    # C5 position of day vs session midrange (0-3)
    session = candles[-240:]
    if len(session) >= 30:
        hi = max(c.h for c in session)
        lo = min(c.l for c in session)
        mid = (hi + lo) / 2
        if closes[-1] > mid:
            long_pts += 2 if closes[-1] < mid + (hi - mid) / 2 else 3
        if closes[-1] < mid:
            short_pts += 2 if closes[-1] > mid - (mid - lo) / 2 else 3
        out["session_mid"] = mid

    # C6 stand-aside filters (the book's 'when NOT to trade')
    wrange = max(c.h for c in window) - min(c.l for c in window)
    vols = [c.v for c in window]
    vavg = sum(vols) / len(vols)
    session_vols = [c.v for c in candles[-60:]] if len(candles) >= 60 else vols
    svavg = sum(session_vols) / len(session_vols)
    if wrange <= 2 * brick_size_ and vavg <= 0.6 * svavg:
        out["stand_aside"] = True
        out["warn"] = "lifeless market (narrow radius + small volume) - stand aside"
    elif wrange <= brick_size_ and vavg >= 2.5 * svavg:
        out["stand_aside"] = True
        out["warn"] = "abnormal volume in tiny radius - manipulation watch, stand aside"
    out["long"], out["short"] = min(long_pts, 25), min(short_pts, 25)
    return out


# --------------------------------------------------------------------------- #
# Factor D — Miner dual-time-frame momentum + trigger (25)
# --------------------------------------------------------------------------- #


def stochastic(candles: Sequence[Candle], k_period: int = 14, smooth: int = 3) \
        -> tuple[list[float], list[float]]:
    """Slow stochastic: fast %K over k_period, slow %K = SMA(smooth) of fast %K,
    %D = SMA(smooth) of slow %K. Returns (slowK, D). NaN-neutralized at 50."""
    n = len(candles)
    fast_k = [50.0] * n
    for i in range(k_period - 1, n):
        seg = candles[i - k_period + 1: i + 1]
        hi, lo = max(c.h for c in seg), min(c.l for c in seg)
        fast_k[i] = 100.0 * (candles[i].c - lo) / (hi - lo) if hi > lo else 50.0
    sk = [50.0 if v != v else v for v in sma(fast_k, smooth)]
    d = [50.0 if v != v else v for v in sma(sk, smooth)]
    return sk, d


@dataclass
class Miner:
    points: dict[str, int] = field(default_factory=dict)
    htf_state: str = "?"
    ltf_reversal_age: int | None = None
    trigger: str | None = None
    entry: float | None = None
    stop: float | None = None
    notes: list[str] = field(default_factory=list)

    def total(self) -> int:
        return sum(self.points.values())


def miner_factor(ltf: Sequence[Candle], htf: Sequence[Candle],
                 tick: float = 1e-6, brick: float = 0.0) -> Miner:
    out = Miner()
    if len(htf) < 30 or len(ltf) < 25:
        out.notes.append("not enough candles")
        return out
    sk_h, d_h = stochastic(htf)
    sk_l, d_l = stochastic(ltf)
    k, dd = sk_h[-1], d_h[-1]
    ob_h = k >= 75 and dd >= 75
    os_h = k <= 25 and dd <= 25
    if k > dd and not ob_h:
        out.htf_state, out.points["htf"] = "bull", 8
    elif k > dd and ob_h:
        out.htf_state, out.points["htf"] = "bull-OB", 4
    elif os_h:
        out.htf_state, out.points["htf"] = "OS", 3
    elif k < dd and not os_h:
        out.htf_state, out.points["htf"] = "bear", 8
    elif k < dd and os_h:
        out.htf_state, out.points["htf"] = "bear-OS", 4
    else:
        out.htf_state = "flat"

    # LTF reversal: slowK crosses %D, within the last 5 candles, made below OB
    for j in range(max(len(ltf) - 5, 1), len(ltf)):
        if sk_l[j - 1] <= d_l[j - 1] and sk_l[j] > d_l[j] and sk_l[j] < 75:
            age = len(ltf) - 1 - j
            out.points["ltf_reversal_long"] = 7 if age <= 1 else 5
            if out.ltf_reversal_age is None:
                out.ltf_reversal_age = age
            break
    for j in range(max(len(ltf) - 5, 1), len(ltf)):
        if sk_l[j - 1] >= d_l[j - 1] and sk_l[j] < d_l[j] and sk_l[j] > 25:
            age_s = len(ltf) - 1 - j
            out.points["ltf_reversal_short"] = 7 if age_s <= 1 else 5
            if out.ltf_reversal_age is None:
                out.ltf_reversal_age = age_s
            break

    # Tr-1BH/L trigger + swing stop (book p.140)
    size_ref = brick if brick > 0 else abs(ltf[-1].c - ltf[-1].o) or tick
    i = len(ltf) - 1
    if out.points.get("ltf_reversal_long", 0) > 0:
        entry = ltf[i].h + tick
        stop = min(c.l for c in ltf[-6:-1]) - tick
        risk = entry - stop
        if 0 < risk <= 2 * size_ref:
            out.points["trigger_long"] = 4
            out.points["stop_long"] = 3
            out.points["rr_long"] = 2
            if out.entry is None:
                out.entry, out.stop = entry, stop
                out.trigger = (f"LONG Tr-1BH: buy-stop {entry:.6g}, stop {stop:.6g} "
                               f"(1R {entry + risk:.6g})")
    if out.points.get("ltf_reversal_short", 0) > 0:
        entry_s = ltf[i].l - tick
        stop_s = max(c.h for c in ltf[-6:-1]) + tick
        risk_s = stop_s - entry_s
        if 0 < risk_s <= 2 * size_ref:
            out.points["trigger_short"] = 4
            out.points["stop_short"] = 3
            out.points["rr_short"] = 2
            if out.entry is None:
                out.entry, out.stop = entry_s, stop_s
                out.trigger = (f"SHORT Tr-1BL: sell-stop {entry_s:.6g}, "
                               f"stop {stop_s:.6g} (1R {entry_s - risk_s:.6g})")
    if out.trigger:
        out.points["plan"] = 1
    out.notes.append(f"HTF {out.htf_state} (K {k:.0f}/D {dd:.0f}), "
                     f"LTF reversal age {out.ltf_reversal_age}")
    return out


def miner_points_for(m: Miner, side: str) -> int:
    if side == "long":
        return (m.points.get("htf", 0) + m.points.get("ltf_reversal_long", 0)
                + m.points.get("trigger_long", 0) + m.points.get("stop_long", 0)
                + m.points.get("rr_long", 0) + m.points.get("plan", 0))
    return (m.points.get("htf", 0) + m.points.get("ltf_reversal_short", 0)
            + m.points.get("trigger_short", 0) + m.points.get("stop_short", 0)
            + m.points.get("rr_short", 0) + m.points.get("plan", 0))


# --------------------------------------------------------------------------- #
# Composite
# --------------------------------------------------------------------------- #


def scan_symbol(symbol: str, k1m: Sequence[Candle], k15m: Sequence[Candle],
                tick: float = 1e-6, threshold: int = 75) -> dict | None:
    size = brick_size(k1m)
    if size <= 0:
        return None
    bricks = build_bricks(k1m, size)
    if len(bricks) < 15:
        return None

    w = wyckoff_factor(bricks)
    a_long = min(wyckoff_points_for(w, "long"), 30)
    a_short = min(wyckoff_points_for(w, "short"), 30)
    b = renko_factor(bricks)
    c = tape_factor(k1m, size)
    d = miner_factor(k1m, k15m, tick, size)

    s_long = a_long + b["long"] + c["long"] + miner_points_for(d, "long")
    s_short = a_short + b["short"] + c["short"] + miner_points_for(d, "short")
    if c["stand_aside"]:
        s_long, s_short = min(s_long, 40), min(s_short, 40)

    direction, score = ("LONG", s_long) if s_long >= s_short else ("SHORT", s_short)
    if abs(s_long - s_short) < 8 or c["stand_aside"]:
        direction = "NEUTRAL"
        score = max(s_long, s_short)

    price = k1m[-1].c
    entry, stop = d.entry, d.stop
    if entry is None or stop is None:
        if direction == "LONG":
            entry = bricks[-1].close
            stop = min(b.low for b in bricks[-3:]) - size
        elif direction == "SHORT":
            entry = bricks[-1].close
            stop = max(b.high for b in bricks[-3:]) + size
        else:
            entry, stop = None, None
    risk = abs(entry - stop) if entry is not None and stop is not None else 0.0
    if entry is not None and risk > 0:
        t1 = entry + risk if direction != "SHORT" else entry - risk
        t2 = entry + 2 * risk if direction != "SHORT" else entry - 2 * risk
    else:
        t1 = t2 = None
    stretch = None
    if w.rng and direction != "NEUTRAL":
        height = w.rng.resistance - w.rng.support
        dur = max(len(bricks) - w.rng.start_idx, 1) / 60.0
        proj = height * max(dur, 0.25)
        stretch = w.rng.resistance + proj if direction == "LONG" \
            else w.rng.support - proj

    return {
        "symbol": symbol, "price": price,
        "direction": direction, "score": score,
        "notify": direction in ("LONG", "SHORT") and score >= threshold,
        "score_long": s_long, "score_short": s_short,
        "brick_size": size, "bricks": len(bricks),
        "entry": entry, "stop": stop, "t1": t1, "t2": t2,
        "rr": 1.0 if risk > 0 and t1 is not None else None,
        "stretch_target": stretch,
        "breakdown": {
            "A_wyckoff": {"long": a_long, "short": a_short, "max": 30,
                          "phase": w.phase, "notes": w.notes},
            "B_renko": {"long": b["long"], "short": b["short"], "max": 20,
                        "run": b["run"], "consistency": b["consistency"],
                        "speed": b["speed"]},
            "C_tape": {"long": c["long"], "short": c["short"], "max": 25,
                       "stand_aside": c["stand_aside"], "warn": c["warn"],
                       "adv_dec_share": c.get("adv_dec_share"),
                       "notes": c["notes"]},
            "D_miner": {"long": miner_points_for(d, "long"),
                        "short": miner_points_for(d, "short"), "max": 25,
                        "htf": d.htf_state, "reversal_age": d.ltf_reversal_age,
                        "trigger": d.trigger, "notes": d.notes},
        },
        "ts": k1m[-1].t,
    }
