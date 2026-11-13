# Toobit API notes (verified live on 2026-11-13)

Base URL: `https://api.toobit.com` — public market-data endpoints need **no API key**.
Official docs: <https://api-docs.toobit.com/api/usdt-m-market-data>.

## Symbol naming (the #1 gotcha)

- `GET /api/v1/exchangeInfo` lists contract ids like `BTCUSDT` (501 TRADING USDT pairs).
- The quote/market-data endpoints use the **`<BASE>-SWAP-USDT`** id, e.g. `BTC-SWAP-USDT`.
- Both klines and all auxiliary endpoints below were verified to work **only** with the
  suffixed form; plain `BTCUSDT` on `openInterest`/`fundingRate` returns
  `{"code":-100011,"msg":"Not supported symbols"}`.
- The ticker list also contains non-crypto swaps (e.g. `UNH-SWAP-USDT` — tokenized stock
  futures); the universe filter is `s.endsWith("-SWAP-USDT")` + ranking by quote volume,
  which naturally keeps crypto majors at the top.

## Endpoints used by this repo

| Purpose | Request | Verified response shape |
| --- | --- | --- |
| Universe + 24 h stats | `GET /quote/v1/contract/ticker/24hr` | `[{"t":ms,"si":"BTC-SWAP-USDT","s":"BTC-SWAP-USDT","c":"68875.4","h":"71613.4","l":"67513.6","o":"71440.1","v":"100032101.5","qv":"6939261716.15","op":"1134916.5","pc":"-2564.7","pcp":"-0.0359"}]` — `qv` = 24 h quote volume (ranking key), `op` = open interest, `pcp` = 24 h % change. ~1048 entries; omit `symbol` for all. |
| Klines | `GET /quote/v1/klines?symbol=BTC-SWAP-USDT&interval=1m&limit=1000` | `[[openTimeMs,"open","high","low","close","baseVol",0,"quoteVol",trades,"takerBuyBaseVol","takerBuyQuoteVol"], ...]` — Binance-style arrays, oldest→newest. Fields 9/10 verified consistent (`takerBuyBase ≤ baseVol`, ratio ≈ `takerBuyQuote/quoteVol`). Without `startTime`/`endTime` the docs say only the latest kline is returned — always pass `limit`. |
| Contract specs | `GET /api/v1/exchangeInfo` | `{"symbols":[{"symbol":"BTCUSDT","status":"TRADING","filters":[PRICE_FILTER/LOT_SIZE/MIN_NOTIONAL...]}]}` — use for tick size (`PRICE_FILTER.tickSize`). |
| Open interest | `GET /quote/v1/openInterest?symbol=BTC-SWAP-USDT` | `{"openInterestList":[{"size":"36137.81398","symbol":"BTC-SWAP-USDT"}]}` |
| Funding rate | `GET /api/v1/futures/fundingRate?symbol=BTC-SWAP-USDT` | `[{"symbol":"...","rate":"0.00008081","period":"8H","nextFundingTime":ms,"interest":"0.0001","fundingRateCap":"0.0024","fundingRateFloor":"-0.0024"}]` |
| Long/short ratio | `GET /quote/v1/globalLongShortAccountRatio?symbol=BTC-SWAP-USDT&period=15m&limit=30` | `[{"symbol":"...","timeStamp":ms,"longShortRatio":"1.7309","longAccount":"0.6338","shortAccount":"0.3662"}]` — `period` ∈ {5m,15m,30m,1h,2h,4h,6h,12h,1d}. |

## Valid kline `interval` values

Verified working: `1m`, `15m`. The full documented enum mirrors Binance:
`1m 3m 5m 15m 30m 1h 2h 4h 6h 12h 1d 3d 1w 1M` — the lab and app only use `1m`, `15m`
(and optionally `1h`) so they stay inside the verified set.

`limit` for `/quote/v1/klines`: default and max 1000. The app pulls `limit=1000` for 1 m
(~16.7 h) and `limit=200` for 15 m.

## Rate limits

Market-data weight is 1 per request on the endpoints used. The scan loop hits ~2 kline
requests per symbol; with a 30-symbol universe that is ~60 requests per scan cycle —
comfortably inside the documented limits at a 60 s refresh. The lab's `watch` mode sleeps
`--interval` seconds between cycles; keep ≥ 30 s.

## Error convention

Errors come back as JSON `{"code":-100011,"msg":"Not supported symbols"}` with HTTP 200, or
as HTML `404 Not found` for a wrong path. Treat any response that is not a JSON array of the
expected shape as a failure (both lab and app do).
