# renko-toobit-scanner

An iOS app + Python signal lab that scans the **Toobit USDT-M futures** market for the best
day-trading / scalping setups, built on a **Renko** chart engine and three books:

| Book | What it contributes | Weight |
| --- | --- | --- |
| *The Wyckoff Methodology in Depth* (R. Villahermosa) | Trading ranges, **springs / UTADs**, phase A–E logic, volume tests | **30 %** |
| *The Day Traders' Bible* (R. Wyckoff, "Rollo Tape") | Intraday **tape rules**: trend of the market, volume of advances vs. declines, closing strength, when NOT to trade | **25 %** |
| *High Probability Trading Strategies* (R. Miner) | Dual-time-frame **momentum** (stochastic 75/25), setup → trigger → entry → initial stop discipline | **25 %** |
| Renko chart engine | Noise-filtered brick structure that everything above is computed on | **20 %** |

Every `SCAN` refresh ranks all top-liquidity Toobit perps, scores each symbol 0–100 for
**LONG** and **SHORT**, and fires an **on-device local notification** when a setup crosses
your threshold (default ≥ 75), e.g.:

> `▲ LONG ETHUSDT — score 84 — entry 1950.2 · stop 1938.1 (1R 1962.3)`

The repo **ends in an IPA**: the included GitHub Actions workflow builds the app on a macOS
runner and uploads an **unsigned IPA** artifact on every push.

```
                       ┌─────────────────────────────────────────────┐
                       │            Toobit public REST API           │
                       │  /quote/v1/klines · contract/ticker/24hr ·  │
                       │  openInterest · futures/fundingRate         │
                       └───────────────┬─────────────────────────────┘
                                       │  1m / 15m klines + 24h universe
              ┌────────────────────────┴────────────────────────┐
              │                Renko brick engine                │
              │  brick = ATR(14) × mult · wick-aware · multi-    │
              │  brick candles · bricks-per-candle speed         │
              └───────┬─────────────────┬───────────────┬───────┘
                      │                 │               │
        ┌─────────────▼───┐   ┌─────────▼───────┐   ┌───▼──────────────┐
        │ Wyckoff (30)    │   │ Tape rules (25) │   │ Miner MTF (25)   │
        │ range + spring/ │   │ trend of market,│   │ stoch 75/25,     │
        │ UTAD + tests,   │   │ adv/dec volume, │   │ LTF reversal,    │
        │ phase inference │   │ closing strength│   │ Tr-1BH/L trigger │
        └─────────┬───────┘   └────────┬────────┘   └───────┬──────────┘
                  └────────────────────┼────────────────────┘
                     ┌─────────────────▼──────────────────┐
                     │  SignalScorer  →  0–100 LONG/SHORT  │
                     │  entry · stop · 1R/2R targets · R:R │
                     └─────────────────┬──────────────────┘
             Python lab (verify/live)  │  iOS app (SwiftUI, dark terminal)
             lab/toobit_lab.py         │  scan → rank → UNUserNotification
```

## Repository map

```
renko-toobit-scanner/
├── README.md                  ← you are here
├── docs/
│   ├── strategy.md            ← the three books distilled into codeable rules + score rubric
│   ├── api-notes.md           ← verified Toobit endpoints, field maps, gotchas
│   └── install.md             ← CI IPA → sideload guide (Sideloadly / AltStore / Xcode)
├── lab/                       ← Python signal lab (no API keys needed)
│   ├── toobit_lab.py          ← check | universe | scan | watch  subcommands
│   ├── engine.py              ← same Renko + scoring logic, mirrored from Swift
│   ├── tests/test_engine.py   ← pytest unit tests for the brick engine & scorer
│   └── sample_scan.json       ← captured live output from a real scan
├── app/
│   ├── project.yml            ← XcodeGen spec (generates RenkoTrader.xcodeproj)
│   ├── Sources/               ← SwiftUI app (iOS 16+, dark-terminal UI)
│   └── Tests/                 ← XCTest unit tests (RenkoEngine, SignalScorer)
└── .github/workflows/build-ipa.yml  ← macOS runner → tests → archive → unsigned IPA artifact
```

## Quick start

### 1 · Try the strategy from your laptop (Python signal lab)

```bash
cd lab
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

# smoke-test every Toobit endpoint the app uses
python toobit_lab.py check

# top-liquidity universe (default 30 symbols by 24h quote volume)
python toobit_lab.py universe

# one full scan: Renko + Wyckoff + tape + Miner scores for every symbol
python toobit_lab.py scan

# keep scanning every 60 s like the app does
python toobit_lab.py watch
```

`scan` prints the ranked signal table (the same numbers the app shows) and writes
`out/latest_scan.json`. The exact logic is mirrored in Swift, so if the lab says a setup is
an 84, the app will score it 84 too.

### 2 · Build the IPA with GitHub Actions (no Apple Developer account needed)

1. Push this repo to GitHub (public or private — Actions works on both).
2. Open **Actions → Build Unsigned IPA → Run workflow** (or just push).
3. Download the `RenkoTrader-unsigned-ipa` artifact — it contains `RenkoTrader.ipa`.

### 3 · Put it on your iPhone

The CI IPA is **unsigned**, so install it by sideloading with any free Apple ID:

- **Sideloadly** (Windows/macOS, easiest): open the IPA → plug in iPhone → enter your
  Apple ID → Start. Or
- **AltStore / SideStore**, or drag-and-drop in **Xcode → Devices** (re-sign).

Full walkthrough, free-account 7-day re-sign caveats, and how to switch the workflow to a
signed build with your P12 + provisioning profile: **[docs/install.md](docs/install.md)**.

## What the app does

- **Universe** — pulls all Toobit USDT-M perp tickers, keeps the top N (default 30) by 24 h
  quote volume, so you always scan the deepest liquidity ("top liquidity" selection).
- **Scan loop** — refreshes in the foreground every 60 s and via background `BGAppRefresh`
  when the app is suspended.
- **Per symbol** — builds 1 m Renko bricks, then evaluates the three books' rule sets plus
  Renko trend quality; combines them into a 0–100 score for LONG and SHORT.
- **Notify** — when a new setup ≥ your threshold appears, a local notification fires with
  direction, score, entry, stop and first target (15-minute cooldown per symbol+direction).
- **Detail view** — dark-terminal Renko canvas with spring/UTAD markers, tape-volume bars,
  stochastic panel, and the full score breakdown so you can see *why* a signal fired.
- **Risk** — every signal carries its initial stop (Wyckoff spring low / Miner swing low),
  1R and 2R targets, and R:R. Max 3 % capital exposure per trade and the position-size
  formula follow Miner (p.159–162); nothing here places orders — you execute manually.

## Verified Toobit endpoints (public, no keys)

| Purpose | Endpoint |
| --- | --- |
| Top-liquidity universe, 24 h stats incl. OI | `GET /quote/v1/contract/ticker/24hr` |
| 1 m / 15 m / 1 h candles | `GET /quote/v1/klines?symbol=BTC-SWAP-USDT&interval=1m&limit=1000` |
| Contract specs | `GET /api/v1/exchangeInfo` |
| Open interest | `GET /quote/v1/openInterest?symbol=...` |
| Funding rate | `GET /api/v1/futures/fundingRate?symbol=...` |
| Long/short account ratio | `GET /quote/v1/globalLongShortAccountRatio?symbol=...&period=15m` |

Base `https://api.toobit.com`. Symbol format on quote endpoints is `<BASE>-SWAP-USDT`
(e.g. `BTC-SWAP-USDT`) — see [docs/api-notes.md](docs/api-notes.md) for the full field map
and the `interval` enum.

## Configuration

| Setting (app Settings tab / lab CLI flag) | Default | Meaning |
| --- | --- | --- |
| Universe size | 30 | Top symbols by 24 h quote volume |
| Notify threshold | 75 | Score ≥ this fires a notification |
| Brick size | ATR(14) × 0.5 | Or fixed price distance |
| MTF pair | 15 m → 1 m | Miner higher-TF filter → trading TF |
| Scan interval | 60 s | Foreground refresh |
| Cooldown | 15 min | Per symbol+direction re-notification |

## Disclaimers

- Educational tooling, **not financial advice**; crypto futures are high-risk instruments.
- Scores encode the three books' heuristics — they are opinions quantified, not predictions.
- The books were written for stocks a century ago (and 2019 modern Wyckoff); the rules here
  are their heuristics adapted to perpetual futures, backtest before risking money.
