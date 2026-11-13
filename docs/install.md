# From repo to iPhone in ~15 minutes

The GitHub Actions workflow produces an **unsigned IPA** (you chose this: no Apple
Developer account, no secrets in CI). You install it by sideloading.

## 1 · Get the IPA

1. Create a GitHub repo and push this project (Actions works on free accounts for both
   public and private repos).
2. Actions tab → **Build Unsigned IPA** → runs on push, or **Run workflow** manually.
3. When the run finishes (≈ 8–12 min on `macos-15`), open its summary page and download
   **RenkoTrader-unsigned-ipa** — unzip it to get `RenkoTrader.ipa`.

## 2 · Install it (pick one)

### Sideloadly (Windows or macOS — easiest)

1. Install [Sideloadly](https://sideloadly.io) and iTunes (Windows only, for USB drivers).
2. Plug in your iPhone → drag `RenkoTrader.ipa` onto Sideloadly.
3. Enter your normal Apple ID (a free one works) → **Start**.
4. On the phone: Settings → General → VPN & Device Management → trust the profile.
5. Open the app, allow notifications when prompted.

### AltStore / SideStore

Install AltServer on your computer, install AltStore on the phone, open the IPA through it.
AltStore refreshes the 7-day signature automatically while your computer is reachable.

### Xcode (macOS)

Open `app/project.yml`-generated project locally (`cd app && xcodegen generate && open
RenkoTrader.xcodeproj`), select the **RenkoTrader** target → Signing & Capabilities →
Team = your Personal Team → Run on device. Same 7-day limit, but debugging is free.

## 3 · The 7-day reality (free Apple ID)

Free provisioning signatures last **7 days**, then the app must be re-signed. Options:

- Re-run Sideloadly weekly (2 minutes), or
- Use AltStore/SideStore auto-refresh, or
- Enroll in the Apple Developer Program ($99/yr) and re-sign once a year.

## 4 · Switching CI to a signed IPA later

If you get a Developer account, extend `.github/workflows/build-ipa.yml`:

1. Add repo secrets: `P12_BASE64` (certificate, base64), `P12_PASSWORD`,
   `PROFILE_BASE64` (ad-hoc distribution provisioning profile, base64).
2. Replace the unsigned packaging block with `xcodebuild -exportArchive` using
   `ExportOptions.plist` with `method: ad-hoc` and your profile.
3. Everything else (tests, artifact upload) stays the same.

## 5 · App configuration

- First launch: allow **notifications** (that is the whole point of the app).
- Settings tab: notify threshold (default 75), universe size (30), brick multiplier
  (ATR × 0.5), MTF pair (15m → 1m), scan interval (60 s), cooldown (15 min), test
  notification button.
- Bundle ID in `app/project.yml` is a placeholder (`com.renkotrader.ios`) — change it to
  something unique before sideloading if you also use the same Apple ID for other sideloaded
  apps.

## 6 · Trust, privacy, and what the app does NOT do

- The app talks only to `https://api.toobit.com` public market-data endpoints. It has **no
  API keys, no trading capability, and no analytics** — it cannot place or modify orders.
- All computation runs on-device; nothing about you leaves the phone except those public
  requests.
- Educational tool; not financial advice. Futures leverage can wipe an account quickly —
  size with Miner's 3 % rule and verify signals on your own chart before acting.
