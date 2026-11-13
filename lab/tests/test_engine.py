"""Unit tests for the signal engine (synthetic data, no network)."""
from __future__ import annotations

import math
import sys
import os

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from engine import (Brick, Candle, Miner, build_bricks, brick_size,  # noqa: E402
                    consistency, miner_factor, miner_points_for, pivots,
                    renko_factor, run_head, scan_symbol, stochastic,
                    tape_factor, wyckoff_factor)


def mk(candles: list[tuple[int, float, float, float, float, float]]) -> list[Candle]:
    return [Candle(t=t, o=o, h=h, l=l, c=c, v=v) for t, o, h, l, c, v in candles]


# --------------------------------------------------------------------------- #
# Renko engine
# --------------------------------------------------------------------------- #


def test_bricks_basic_up_run():
    # 1.0-wide candles stepping up by 0.5 -> a brick every 2 candles (size 0.5)
    t0 = 1_700_000_000_000
    cands = []
    price = 100.0
    for i in range(20):
        price += 0.5 if i % 2 else 0.0
        cands.append((t0 + i * 60_000, price, price + 0.2, price - 0.2, price, 10.0))
    bricks = build_bricks(mk(cands), 0.5)
    assert len(bricks) >= 5
    assert all(b.direction == 1 for b in bricks[-5:])
    # bricks step by exactly one size
    for a, b in zip(bricks, bricks[1:]):
        assert math.isclose(b.open - a.open, 0.5, abs_tol=1e-9)


def test_bricks_reversal_requires_full_size():
    # go up 2 bricks, then CLOSE one brick below the edge -> flip down
    t0 = 1_700_000_000_000
    cands = [(t0, 100.0, 101.5, 99.9, 101.4, 10.0),
             (t0 + 60_000, 101.4, 102.9, 101.3, 102.9, 10.0),   # 1 up brick
             (t0 + 120_000, 102.9, 103.0, 100.8, 100.9, 10.0)]  # 1 more up + flip
    bricks = build_bricks(mk(cands), 1.0)
    # candle 3 closes below the edge (101.0), so the close flips direction
    # first and its upper wick (103.0) is ignored — no intra-candle zigzag
    assert [b.direction for b in bricks] == [1, 1, -1]
    assert math.isclose(bricks[-1].open, bricks[-2].close, abs_tol=1e-9)
    assert math.isclose(bricks[-1].close, bricks[-1].open - 1.0, abs_tol=1e-9)


def test_wick_aware_multi_bricks_per_candle():
    t0 = 1_700_000_000_000
    # candle 2 spans 4 brick sizes with its high: closes drive 3 bricks,
    # the wick extends the up-run by one more
    big = [(t0, 100.0, 100.4, 99.6, 100.0, 10.0),
           (t0 + 60_000, 100.0, 104.0, 99.9, 103.5, 50.0)]
    bricks = build_bricks(mk(big), 1.0)
    assert len(bricks) == 4
    assert all(b.direction == 1 for b in bricks)
    assert math.isclose(bricks[-1].close, 104.0, abs_tol=1e-9)


def test_wick_never_flips_intra_candle():
    t0 = 1_700_000_000_000
    # up-run then a candle whose low dips a full brick below the edge but
    # whose close stays inside: no flip, wick must not reverse direction
    cands = [(t0, 100.0, 101.4, 99.9, 101.4, 10.0),
             (t0 + 60_000, 101.4, 102.0, 101.9, 102.0, 10.0),
             (t0 + 120_000, 102.0, 102.3, 101.7, 102.2, 10.0)]
    bricks = build_bricks(mk(cands), 1.0)
    assert all(b.direction == 1 for b in bricks)


def test_run_head_and_consistency():
    def b(d):
        return Brick(d, 0, d * 0.5, 0, 0, 1.0, 1)
    bricks = [b(1), b(1), b(-1), b(1), b(1), b(1)]
    assert run_head(bricks) == 3
    assert 0.0 <= consistency(bricks, 6) <= 1.0


def test_brick_size_atr_floor():
    t0 = 1_700_000_000_000
    cands = []
    price = 100.0
    for i in range(30):
        price += 0.5
        cands.append((t0 + i * 60_000, price - 0.5, price + 0.5, price - 1.0, price, 10.0))
    bs = brick_size(mk(cands), multiplier=0.5)
    assert bs > 0


# --------------------------------------------------------------------------- #
# Factor A — Wyckoff: synthetic spring
# --------------------------------------------------------------------------- #


def _spring_series() -> list[Brick]:
    """Build bricks: wide sideways range, one-brick undercut, reclaim, rally."""
    t0 = 1_700_000_000_000
    cands: list[tuple[int, float, float, float, float, float]] = []
    t = t0
    price = 100.0
    # build a range 100-104 by oscillating
    for cycle in range(6):
        for _ in range(3):
            price += 1.0
            cands.append((t, price - 1.0, price, price - 1.2, price, 40.0))
            t += 60_000
        for _ in range(3):
            price -= 1.0
            cands.append((t, price + 1.0, price + 1.2, price, price, 40.0))
            t += 60_000
    # spring: dive 2 bricks below the last pivot low then reclaim
    low = price
    price -= 2.0
    cands.append((t, price + 2.0, price + 2.0, price, price, 15.0))  # low-volume shake
    t += 60_000
    price += 1.0
    cands.append((t, price - 1.0, price + 1.0, price - 1.0, price, 30.0))
    t += 60_000
    price += 1.0
    cands.append((t, price - 1.0, price + 1.0, price - 1.0, price, 30.0))
    t += 60_000
    price += 1.0
    cands.append((t, price - 1.0, price + 1.0, price - 1.0, price, 35.0))
    t += 60_000
    price += 1.0
    cands.append((t, price - 1.0, price + 1.0, price - 1.0, price, 45.0))
    return build_bricks(mk(cands), 1.0)


def test_spring_detected_and_scores_long():
    bricks = _spring_series()
    w = wyckoff_factor(bricks)
    assert w.shake is not None and w.shake.kind == "spring"
    assert not w.shake.broken
    from engine import wyckoff_points_for
    assert wyckoff_points_for(w, "long") >= 12
    assert wyckoff_points_for(w, "short") <= 6   # range points at most


def test_utad_detected_scores_short():
    # mirror of the spring series: range then a spike above resistance, fall back
    t0 = 1_700_000_000_000
    cands = []
    t = t0
    price = 100.0
    for cycle in range(6):
        for _ in range(3):
            price -= 1.0
            cands.append((t, price + 1.0, price + 1.2, price, price, 40.0))
            t += 60_000
        for _ in range(3):
            price += 1.0
            cands.append((t, price - 1.0, price, price - 1.2, price, 40.0))
            t += 60_000
    price += 2.0
    cands.append((t, price - 2.0, price, price - 2.0, price, 15.0))
    t += 60_000
    price -= 1.0
    cands.append((t, price + 1.0, price + 1.0, price - 1.0, price, 30.0))
    t += 60_000
    price -= 1.0
    cands.append((t, price + 1.0, price + 1.0, price - 1.0, price, 30.0))
    t += 60_000
    price -= 1.0
    cands.append((t, price + 1.0, price + 1.0, price - 1.0, price, 35.0))
    t += 60_000
    price -= 1.0
    cands.append((t, price + 1.0, price + 1.0, price - 1.0, price, 45.0))
    t += 60_000
    from engine import wyckoff_points_for
    bricks = build_bricks(mk(cands), 1.0)
    w = wyckoff_factor(bricks)
    assert w.shake is not None and w.shake.kind == "utad"
    assert not w.shake.broken
    assert wyckoff_points_for(w, "short") >= 12


def test_broken_spring_resets():
    from engine import Brick as B
    # hand-built brick stream: range then a deep break that never re-enters
    bricks = []
    t = 0
    price = 100.0
    for i in range(6):
        for d in (1, 1, 1, -1, -1, -1):
            prev = price
            price += d
            bricks.append(B(d, prev, price, t, t, 20.0, 1,
                            low=min(prev, price), high=max(prev, price)))
            t += 1
    # trend away: 10 down bricks, never re-entering the range
    for i in range(10):
        prev = price
        price -= 1
        bricks.append(B(-1, prev, price, t, t, 20.0, 1,
                        low=min(prev, price), high=max(prev, price)))
        t += 1
    w = wyckoff_factor(bricks)
    # no spring re-entry => either no shake or shake marked broken/not scored
    from engine import wyckoff_points_for
    assert wyckoff_points_for(w, "long") < 15


# --------------------------------------------------------------------------- #
# Factor C / D
# --------------------------------------------------------------------------- #


def test_tape_factor_bounds_and_stand_aside():
    t0 = 1_700_000_000_000
    # lifeless: tiny range; recent volume far below the session baseline
    cands = [(t0 + i * 60_000, 100.0, 100.05, 99.95, 100.0, 20.0 if i < 40 else 1.0)
             for i in range(70)]
    res = tape_factor(mk(cands), 1.0)
    assert res["stand_aside"] is True
    assert res["long"] <= 25 and res["short"] <= 25


def test_stochastic_reaches_zones():
    t0 = 1_700_000_000_000
    cands = []
    price = 100.0
    t = t0
    for i in range(60):        # strong uptrend -> OB
        price += 0.5
        cands.append((t + i * 60_000, price - 0.5, price, price - 0.6, price, 10.0))
    sk, d = stochastic(mk(cands))
    assert sk[-1] > 75


def test_miner_factor_runs_on_synthetic():
    t0 = 1_700_000_000_000
    up, down = [], []
    price = 100.0
    t = t0
    for i in range(60):
        price += 0.4
        up.append((t + i * 60_000, price - 0.4, price + 0.1, price - 0.5, price, 10.0))
    price2 = 200.0
    t2 = t0
    for i in range(60):
        price2 -= 0.4
        down.append((t2 + i * 60_000, price2 + 0.4, price2 + 0.5, price2 - 0.1,
                     price2, 10.0))
    c_up, c_dn = mk(up), mk(down)
    m1 = miner_factor(c_up[-60:], c_dn, tick=0.01, brick=0.5)
    m2 = miner_factor(c_up[-60:], c_up, tick=0.01, brick=0.5)
    assert 0 <= miner_points(m1) <= 25 and 0 <= miner_points(m2) <= 25


def miner_points(m) -> int:
    return m.total()


def test_miner_htf_points_only_for_matching_direction():
    bull = Miner(points={"htf_long": 8})
    assert miner_points_for(bull, "long") == 8
    assert miner_points_for(bull, "short") == 0

    bear = Miner(points={"htf_short": 4})
    assert miner_points_for(bear, "long") == 0
    assert miner_points_for(bear, "short") == 4


# --------------------------------------------------------------------------- #
# Composite end-to-end on live-shaped data
# --------------------------------------------------------------------------- #


def test_scan_symbol_full_pipeline():
    t0 = 1_700_000_000_000
    one, quarter = [], []
    price = 100.0
    t = t0
    for cycle in range(24):
        for _ in range(4):
            price += 0.5
            one.append((t, price - 0.5, price + 0.1, price - 0.6, price, 30.0))
            t += 60_000
        for _ in range(4):
            price -= 0.5
            one.append((t, price + 0.5, price + 0.6, price - 0.1, price, 30.0))
            t += 60_000
    sig = scan_symbol("TEST-SWAP-USDT", mk(one[-500:]), mk(one), tick=0.01)
    assert sig is not None
    assert 0 <= sig["score_long"] <= 100 and 0 <= sig["score_short"] <= 100
    assert sig["direction"] in ("LONG", "SHORT", "NEUTRAL")
    assert set(sig["breakdown"].keys()) == {"A_wyckoff", "B_renko", "C_tape", "D_miner"}


def test_pivots_fractal():
    vals = [1.0, 2.0, 3.0, 2.0, 1.0, 2.0, 4.0, 2.0, 1.0]
    p = pivots(vals, 2)
    kinds = [k for _, k in p]
    assert kinds[0] == "H"
    assert "L" in kinds
