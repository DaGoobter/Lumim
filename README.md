# Lumen: a Jellyfin client (v0.1 test build)

A native SwiftUI Jellyfin client for iPhone and iPad, built around untouched playback:
Direct Play, Dolby Vision, HDR10 and Dolby Atmos, plus full-quality offline downloads.

## What v0.1 does

- **Sign in** with a local address (`192.168.1.10:8096`) or a remote domain (`https://jellyfin.example.com`).
- **Home:** a hero banner, Continue Watching, Next Up, and the latest items in each library.
- **Library:** grids for each library, with sorting (name, date added, release date, rating).
- **Details:** Dolby Vision, HDR10+, HDR10, 4K and Atmos badges; seasons and episodes; the full list of media streams.
- **Playback** uses Apple's native player, which gives you PiP, AirPlay and Atmos/spatial audio:
  - MP4/MOV files the phone can play → **Direct Play** (original file, untouched).
  - MKV, or TrueHD/DTS audio → **Direct Stream**: the server repackages the video without re-encoding it, so DV/HDR is kept, and converts only the audio.
  - Re-encoding happens only when the video itself can't play on the device.
  - The **ⓘ button** in the player shows what's playing and why: play method, dynamic range, DV profile, audio, and the server's reasons.
  - Watch progress syncs to the server.
- **Downloads:** full quality, and they keep going in the background.
  - MP4/MOV → the original file, byte for byte.
  - MKV → a full-quality remux. The video is untouched and the audio is converted only if needed.
- **Settings:** streaming quality cap and a check of what this device supports (DV, HDR10, HEVC, AV1).

## Known limits (iOS itself, not this app)

- **TrueHD Atmos** can't be decoded on iPhone/iPad. The server converts it to Dolby Digital Plus, which usually drops the Atmos layer. **E-AC3 Atmos** (most WEB-DLs) plays as real Atmos.
- **Dolby Vision Profile 7** (UHD Blu-ray remuxes) isn't supported by Apple. Those files play in HDR10. Profiles 5 and 8 (WEB-DLs and most re-encodes) play in true Dolby Vision.
- Subtitles are off in v0.1. Subtitle selection comes next.

---

## Get the app on your iPhone (free)

### 1. Put the code on GitHub (one time)
1. Create a free account at github.com.
2. Create a **new public repository** named `lumen`. Leave every box unchecked.
3. On the empty repo page, click **"uploading an existing file"**. Drag **everything inside** the `Lumen` folder into the browser, including the `.github` folder. Then click **Commit changes**.
   - If the `.github` folder doesn't upload, create it by hand: click **Add file → Create new file**, type `.github/workflows/ios.yml` as the name, and paste in the contents of that file.

### 2. Let GitHub build it
1. Open the **Actions** tab in your repo. If GitHub asks, click to enable workflows.
2. Click **Build iOS app**, then **Run workflow**. A build takes about 5–10 minutes.
3. When it shows a green check, open the run and download **Lumen-ipa** from the bottom of the page. Unzip it to get `Lumen.ipa`.

A new build also starts automatically every time code is pushed to the repo.

### 3. Install with Sideloadly (Windows)
1. Install **iTunes** from apple.com (not the Microsoft Store version) and **Sideloadly** from sideloadly.io.
2. Plug in your iPhone and tap **Trust** on the phone.
3. Drag `Lumen.ipa` into Sideloadly, enter your Apple ID, and click **Start**.
4. On the iPhone, turn on **Settings → Privacy & Security → Developer Mode**. The phone restarts.
5. Then go to **Settings → General → VPN & Device Management**, tap your Apple ID, and tap **Trust**.

With a free Apple ID the app expires after **7 days**. Turn on Sideloadly's auto-refresh, or re-run step 3. Your downloads and sign-in are kept.
