# Strategy specification — three books → one score

This document is the contract between the books and the code. Everything `lab/engine.py`
and the Swift engines compute is traceable to a rule below, and every rule is traceable to
the books. Quotes are verbatim from the uploaded PDFs.

Score composition (user-selected *balanced blend*):

| Factor | Source | Weight | Points |
| --- | --- | --- | --- |
| A | Wyckoff structure (range, spring/UTAD, tests, phase) | 30 % | 30 |
| B | Renko trend quality (run length, consistency, speed) | 20 % | 20 |
| C | Day Traders' Bible tape rules | 25 % | 25 |
| D | Miner dual-time-frame momentum + trigger | 25 % | 25 |

Total 0–100, computed **separately for LONG and SHORT** on each symbol. The reported
direction is the higher of the two; a signal is only actionable if its score ≥ threshold
(default 75) and the stand-aside filter (rule C6) does not trip.

All computations run on **1-minute klines** (trading timeframe) with **15-minute** as the
Miner higher timeframe. Renko is built from the 1 m stream; Factors A and B read the brick
series; Factors C and D read raw candles + klines.

---

## Factor A — Wyckoff structure (30 pts)

Source: Villahermosa, *The Wyckoff Methodology in Depth* (2019).

### A0. Trading-range construction (precondition, 0–6 pts)

The scanner maintains the last ~60 bricks and finds swing pivots (fractal, ±3 bricks).
Support ("**Ice**") = pivot-low cluster; resistance ("**Creek**") = pivot-high cluster.
The book: *"A range needs two points to build the channel; the key is in the ends"* —
anchor 1 is the climax extreme, anchor 2 the AR end; Phase B tests may redraw the extremes.

Points:

- +3 — ≥ 2 touches each side within the window (a range, not a trend).
- +2 — range height ≥ 4 bricks (cause worth building; cause = time × range height,
  *"effect proportional to cause"*).
- +1 — volume contraction across the range: volume SMA of the second half < first half
  (accumulation signature: *"overall volume and volatility decrease"* in Phase B).

### A1. Spring / UTAD detection (0–12 pts)

The book's operational criteria, codified:

1. **Precondition** — the range exists (A0) and has been building (Phase B before Phase C).
2. **Penetration** — a brick closes below Ice (spring) / above Creek (UTAD).
3. **Re-entry** — *"If after the breakout of the lower part of the structure the price fails
   to stay below and re-enters the range again, it denotes strong purchase entry and adds
   greater probability that the breakout is false"* — within ≤ 5 bricks, price closes back
   inside the range.
4. **Volume typology** (the book's three spring types):
   - Spring #1 "Terminal Shakeout": deep penetration + sudden volume/range expansion —
     valid but requires strong demand to reclaim; moderate points.
   - Spring #2: moderate penetration, rising volume; moderate points.
   - Spring #3: shallow penetration + *decreasing volume, narrowing ranges* —
     *"strongest, directly tradable"*; full points.
5. **Reclaim speed** — the faster price is back inside, the higher the score (a one-brick
   undercut is the classic hammer-shaped spring).

Points: +5 spring or UTAD detected with re-entry, +3 typology bonus (Spring #3 or deep
Terminal Shakeout with wide-range reclaim), +2 spring depth ≤ 2 bricks (shallow, not a
real breakdown), +2 volume at the spring below the 20-period volume SMA (no panic
liquidation; the book warns high-volume shakes should be waited out for the test).

Direction: spring → LONG; UTAD → SHORT.

### A2. Test validity (0–6 pts)

The book, twice, verbatim:

> *"For the test to be successful, it should be developed with a narrowing of the ranges,
> a decrease in volume and should be kept above the level of the Spring/Shakeout."* (Ch. 18)

> *"The test is considered valid when the candle has a volume lower than that of the two
> previous [candles], denoting … lack of interest in that direction."* (Ch. 17)

Points: +3 first pullback after the spring holds **above the spring low**, +2 its volume <
volume of both of the two previous bricks (No Supply on longs / No Demand on shorts),
+1 narrow range on that test brick.

### A3. Phase & SOS/LPS confirmation (0–6 pts)

- +2 — Phase inference: spring present ⇒ Phase C; price now above range midpoint with a
  wide-range brick closing in its upper half and expanding volume ⇒ Phase D
  (*"SOS … should move with 'ease' to at least the midpoint of the range"*).
- +2 — Phase B ≥ Phases A + C in duration, or B shorter (the book: *"we want this Phase to
  be greater than Phases A and C"* — a short B denotes urgency and *adds* strength).
- +2 — LPS structure: pullback after the SOS holds above the spring low on low volume
  (the book's preferred entry).

### A-failure overrides (from the book's failure conditions)

- A test that makes a **new low** below the spring low ⇒ the spring is voided; reset A.
- Deep shakeout with no demand afterwards (price keeps falling) ⇒ reset A.
- *"Spring must necessarily cause the range to break up. Anything other than this should not
  be labeled as Spring."* If, 10 bricks after a "spring", no upward range-break has begun,
  the label is withdrawn.

---

## Factor B — Renko trend quality (20 pts)

Renko is not in the books; it is the chart engine this repo adds. Its job here: remove
1-minute noise so Factors A and C see structure, and be scored itself for trend quality.

### Brick engine (identical in Python and Swift)

- Brick size = `max(ATR(14) of 1 m closes × multiplier, one price tick)`, multiplier
  default 0.5, configurable; fixed-size mode available.
- Wick-aware: each 1 m candle can emit 0..n bricks; continuation uses closes, wicks may
  extend the current direction; a reversal needs a full brick-size move against the
  current direction measured from the extreme of the last brick.
- `bricksPerCandle` = bricks emitted / candles consumed over the recent window → trend
  *speed* (Wyckoff tape readers judged moves by how fast they came out of the tape; a
  renko run that prints fast is the same observation).

### B-points (scored per direction)

- +0–8 — **Run length**: consecutive same-direction bricks at the head of the series
  (1 pt per brick, capped at 8). One brick = no edge; three+ = trend.
- +0–6 — **Consistency**: share of the last 10 bricks in the same direction × 6. The
  50 % line is neutral; ≥ 80 % = full.
- +0–4 — **Structure**: brick-highs/lows sequence in the direction (higher-highs
  staircase) — the renko equivalent of Wyckoff's *"consecutive higher tops and bottoms"*.
- +0–2 — **Speed**: bricks printing faster than the session average (`bricksPerCandle`
  in the run > overall average) — effort/result harmony: *"impulses should come with
  rising volume… a new extreme on falling volume = divergence"*, which instead deducts.

Contrarian guard: a fresh run **against** a just-detected spring is not penalized — the
spring *is* the reversal trigger; the run confirms the Phase C→D turn.

---

## Factor C — Day Traders' Bible tape rules (25 pts)

Source: Wyckoff ("Rollo Tape"), *The Day Traders' Bible*. All checks run on the last ~30
1 m candles. The book's core statement, verbatim:

> *"If it is a bull move, the volume must increase and the rest of the market offer some
> support or at least not oppose it. The reactions must show a smaller volume than the
> advances, indicating light pressure, and each upward swing must be of longer duration and
> reach a new high level, or it will mean that the rise has spent its force either
> temporarily or finally."* (Ch. X)

### C1. Trend of the market (0–6 pts)

Series of higher tops & bottoms on pivot detection (mirror for shorts) — the book's first
condition. +2 per completed pivot sequence level confirmed (recent top above prior top,
recent bottom above prior bottom; 3 levels max).

### C2. Volume of advances vs. declines (0–8 pts)

Sum volume of up-candles vs down-candles over the window. Bullish when advances carry
clearly more volume than declines (*"on reactions the quantities … decrease until, like the
ocean at ebb tide, the market is almost lifeless"*). Scored as
`upVol / (upVol + downVol)` mapped to 0–8, neutral at 0.5.

### C3. Closing strength (0–5 pts)

Share of recent up-candles closing in their top third (long) / down-candles in their bottom
third (short) — the tape reader's *"will not ordinarily let all of three points get away"*:
winners should close strong. Neutral at 40 %, full at 70 %+.

### C4. Normal-reaction check (0–3 pts)

The book's ½–⅔ expectation: *"rally = ½ to ⅔ of the preceding decline; failure to reach it =
pressure still on"*. For a long: the latest reaction retraced ≥ 50 % of the prior downswing
(continuation healthy, +3); 33–50 % (+1); < 33 % (pressure still on, 0 and direction doubt).
Mirror for shorts.

### C5. Position-of-day (0–3 pts)

Price relative to the session structure (day open, session high/low, midrange): longs score
when price holds above the day midpoint after a spring-type undercut of the session low
(the intraday "point of resistance" logic: *"bought at 128¾ after double support at 128,
stop 127⅞"*).

### C6. Stand-aside filter (override)

The book, verbatim:

> *"A market which swings within a radius of a couple of points cannot be said to have a
> trend, and is a good one for the Tape Reader to avoid."* (Ch. IV)

> *"Don't trade when the market isn't acting right! … When prices drift up and down without
> trend, like a ship without a rudder, and few positive indications develop, the percentage
> of losing trades is apt to be high."* (Ch. XI, Commandment 3)

Codified as two trip-wires on the 1 m series; either ⇒ both directions capped at 40 and no
notification:

- **Lifelessness** — range of the window ≤ 2 × brick size **and** window volume ≤ 60 % of
  its own SMA (the book's *"protracted zigzag within a short radius accompanied by very
  small volume means lifelessness"*).
- **Manipulation watch** — abnormal volume (≥ 2.5 × SMA) inside a ≤ 1-brick radius
  (*"abnormally large volume inside a small radius = accumulation/distribution
  (manipulation)"*) — shown as a warning, not a trade.

---

## Factor D — Miner dual-time-frame momentum + trigger (25 pts)

Source: Miner, *High Probability Trading Strategies*. The framework, verbatim:

> *"Trade in the direction of the larger time frame momentum. Execute the trade following
> the smaller time frame momentum reversals."* (p.13)

> *"Bull, not OB — Long following a bullish reversal as long as bullish reversal is made
> below the OB zone."* (Table 2.1, p.44)

### D0. Indicator (0 setup points; drives D1–D3)

Miner prescribes **no fixed periods** — *"test a few settings on recent data and see which
best meets the criteria"*; his worked example settled on a 13-period stochastic with **75 %
/ 25 % OB/OS lines** and both fast & slow lines in the zone to count. This repo uses
stochastic %K 14 / %D 3 / slow 3 on both timeframes with the book's 75/25 lines
(configurable), evaluated as the book's two-line variant:

- **Bullish reversal**: %K crosses above %D *outside* the OS zone context (i.e. made below
  the OB zone — never a reversal fired from inside OB, which the book ignores).
- **Bearish reversal**: %K crosses below %D above the OS zone.

### D1. Higher-TF direction filter (0–8 pts)

15 m momentum trend = direction between opposite reversals. Long scores 8 when the 15 m
is bull **and not OB**; 4 when bull but OB (possible-trade-but-extended); 0 when bear.
Mirror for shorts. (Rule 1: *"Only trade in the direction of the larger time frame momentum
trend unless the momentum position is overbought or oversold."*)

### D2. Lower-TF momentum reversal (0–7 pts)

1 m bullish reversal within the **last 5 candles** and made below the OB zone: +7 fresh
(≤ 2 candles), +5 (3–5 candles), 0 stale. Mirror for shorts. (Rule 2: *"execute only after a
smaller-TF momentum reversal in the direction of the larger-TF trend"*.)

### D3. Trigger + initial stop validity (0–10 pts)

The book, verbatim:

> *"trail the buy-stop or sell-stop to enter the trade one tick above the high or below the
> low of the last completed bar. Place the initial protective stop one tick beyond the swing
> high or low made prior to entry."* (p.140)

> *"Stops are always placed at the exact price that will void the setup."* (p.140)

Codified:

- +3 — **Tr-1BH/L trigger** is live: entry = last completed 1 m candle high + 1 tick
  (long) / low − 1 tick (short), not yet voided by an opposite reversal.
- +3 — **Initial stop** = one tick beyond the swing low made prior to the reversal (long);
  the app reports it and requires stop distance ≤ 2 × brick size for scalpability.
- +2 — **R:R sanity**: first objective (1R) reachable inside the recent brick range
  (reward:risk ≥ 1; Miner calls formal R:R ranking *"basically a bogus idea"* but the app
  still shows R and the two-unit plan).
- +2 — **Two-unit management** reported: ST unit exits on trailing 1BL/H at the 50–61.8 %
  minor target or the second adverse reversal; LT unit trails swings — the signal card
  includes this plan text.

---

## Composite score & notification

```
scoreLong  = A(30) + B(20) + C(25) + D(25)      # each factor computed for the long side
scoreShort = mirror
direction  = argmax; NEUTRAL if |scoreLong − scoreShort| < 8 or C6 trips
notify     = direction score ≥ threshold (default 75), cooldown 15 min per symbol+direction
```

Entry / stop / targets attached to every signal:

- Entry: Tr-1BH/L level when a trigger is live; else last brick edge.
- Stop: Wyckoff spring low − 1 tick (A-path) or Miner prior-swing low ± 1 tick (D-path) —
  whichever is closer, so stops are the tightest *setup-voiding* level.
- Targets: 1R (scalp unit) and 2R (runner), plus the Wyckoff cause projection =
  range height × (range duration / 60 bricks) beyond the Creek/Ice as a stretch target.

## What was deliberately NOT automated (and why)

- Point-and-figure horizontal counts (the Wyckoff book's "cause" counts): the author himself
  doubts their modern operability and the repo substitutes range-duration cause proxy.
- Elliott wave counting (Miner Ch. 3–5): the book's pattern/time context is subjective;
  the repo keeps his *objective* DTF momentum + trigger core and the price-zone idea only
  as the C4 normal-reaction check.
- Miner's fib projections (APP/Ex-Ret zones): kept out to stay mechanical; they are
  documented here for manual confluence.
