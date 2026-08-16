# Peninsula

*[한국어](README.ko.md)*

A macOS app that turns the MacBook notch into a Dynamic Island. SwiftUI + AppKit, no third-party dependencies.

**0.05% CPU · 14MB · 3 threads while resident.**

<img src="docs/compact.png" width="248" alt="The resting pill while playing">

<img src="docs/media.png" width="640" alt="Media panel">

<img src="docs/shelf.png" width="640" alt="Shelf">

<img src="docs/devices.png" width="640" alt="Device batteries">

> **Playback comes from a private API.** macOS has no public way to read what another app is playing, so this reads MediaRemote through the system perl binary ([details](#notes)). Apple can close that path in any update; the notch says so if it happens. The App Store is out for the same reason.
>
> The shelf, AirDrop, batteries, HUD and activities are all public API.

---

## Install

macOS 14 or later, MacBook with a notch.

Download from [Releases](https://github.com/Team-Lunibee/Peninsula/releases), unzip, move to **Applications**.

Turn on "Open at login" *after* moving it there — it registers a path.

**Languages** — English · 한국어 · 日本語 · 简体中文 · Español · Français · Deutsch, following the system.

### Build

```bash
./scripts/bundle.sh release && open build/Peninsula.app
```

The first build fetches [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) (BSD-3) and builds it into a framework. No cmake needed.

---

## Features

**Now playing** — artwork with a 3D flip on track change, title, artist, synced lyrics from lrclib.net, scrubber, favourite / previous / play / next / AirPlay, system volume, meter. Lyrics also show on the resting pill.

**Shelf** — a wide strip along the top catches a drag and opens the panel. It splits **AirDrop : shelf = 1:3**, so where you drop is the destination. Files are copied into the app's own folder, so moving the original keeps them. Double-click for Quick Look. Expiry is configurable, 1 day to forever.

**Devices** — Bluetooth battery levels. AirPods report left, right and case separately.

**Live activities** — charging and battery, downloads, screenshots, device connections, AirDrop arrivals.

**HUD replacement** — volume and brightness keys drawn in the notch instead of the system overlay. Needs Accessibility permission, and turns itself on the moment it is granted.

---

## Performance

| | |
|---|---|
| Idle CPU | **0.05%** |
| Memory, nothing playing | **14MB** |
| Memory, while playing | **23–30MB** |
| Threads, idle | **3** |
| Growth per 200 expand/collapse cycles | **0MB** |

Idle CPU is 54.2 seconds of accumulated CPU across 31.8 hours of continuous use — playback, panels and shelf included — rather than a quiet minute picked by hand. Memory tracks whether artwork is loaded; repeated 100-second runs vary between 23 and 30MB on the same build, so read any single figure as ±4MB.

The meter is drawn by Core Animation, so the render server interpolates every frame and the app only sets a target four times a second. It stops entirely when the display sleeps, as does pointer tracking. Artwork is decoded through `CGImageSourceCreateThumbnailAtIndex`, so a 3000×3000 cover never becomes 36MB of pixels. Text is rasterised once per transition instead of once per frame, which is what holds the 0MB across 200 cycles.

---

## Why "peninsula"

The iPhone has an island — pixels in the middle of the screen, free to grow in any direction. The MacBook notch is a hole in the panel, and cannot be detached from the bezel. So this doesn't imitate an island. It stays attached and reaches outward, drawn in the cutout's exact black, starting at the cutout's edge.

Two rules follow, and the codebase stands on them.

**The resting state equals the cutout.** Four states: `idle` (invisible), `compact`, `peek` (banner), `expanded`. A pill permanently wider than the cutout is a black bar, not a notch.

**Nothing is drawn over the cutout.** There is no screen behind the camera housing, so every row crossing that latitude splits into leading / gap / trailing. When a third tab appears and labels no longer fit, they drop to icons.

The notch is pinned to a private window server Space, so it stays put across desktop switches and above full-screen apps.

---

## Motion

Apple's own notation from WWDC23 (`duration` + `bounce`), defined once in [`Motion.Timeline`](Sources/Peninsula/Motion/Motion.swift) and read by both the animation and the Motion Lab.

The defaults are fitted, not chosen: a real Dynamic Island recorded at 50fps, silhouette extracted per frame, least-squares fitted to `Spring(duration:bounce:)`.

| | duration | bounce | fit (rms) |
|---|---|---|---|
| Expand · horizontal | 0.445s | +0.10 | 0.009 |
| Expand · vertical | 0.420s | +0.06 | 0.011 |
| Collapse · vertical | 0.455s | +0.12 | 0.007 |
| Collapse · horizontal | ~0.19s | overdamped | — |

Expanding, both axes travel together within 2%. Collapsing, width arrives twice as early: the panel snaps shut sideways into a tall block, which is then drawn upward.

Content is scaled whole rather than re-laid-out — each state is laid out once at its final size and scaled by the container's springs, matching how the reference behaves. Blur runs on its own clock, sharp by 75% on the way in and unreadable within two frames on the way out. The recoil is a horizontal-only impulse, applied when the width arrives.

### Motion Lab

Settings › Motion Lab steps frame by frame at 1/60s using the real island content. Development builds only.

```bash
"$(swift build --show-bin-path)/Peninsula" --dump-frames ./frames
```

---

## Security

**Two entitlements** — sandbox disabled, to run perl and copy dropped files, and Apple Events, to favourite a track.

**Four fields leave the machine**: title, artist, album and duration, to lrclib.net over HTTPS, through an ephemeral session, and switchable off.

**The event tap cannot see typing.** It subscribes to `NX_SYSDEFINED` only, so keyboard and mouse events are never delivered to it.

**Filenames and paths are logged as `.private`**, keeping them out of the system log and any sysdiagnose.

**Private APIs go through `dlsym`.** A missing symbol returns `nil` and disables one feature, where a direct binding would stop the app launching at all.

---

## Notes

**Playback** — since macOS 15.4, MediaRemote is reachable only by Apple's own processes. Peninsula reads it via [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) through the system perl binary, which is still entitled.

**AirDrop reception belongs to `sharingd`** — its dialog, its progress. Arrivals are detected instead: a received file carries `sharingd` as the agent in `com.apple.quarantine`, which separates it from an ordinary download into the same folder.

**The meter is decoration.** There is no public API to read another app's audio output.

**Signing** — macOS keys privacy permissions to the code signature, so an ad-hoc signature loses them on every rebuild. The bundler prefers a Developer ID certificate; pin one with `SIGN_IDENTITY=...`.

---

## Layout

```
Sources/Peninsula/
  App/      entry point, app delegate, status item
  Core/     preferences, login item, observation, logging, updates
  Motion/   spring timelines, transitions, frame dump
  Notch/    panel, shape, geometry, controller
  Media/    MediaRemote bridge, playback, lyrics, artwork, volume
  Shelf/    store, drag detection, Quick Look
  System/   power / folder / Bluetooth observers, HUD tap, brightness
  UI/       SwiftUI views
```

Core three: [`NotchController`](Sources/Peninsula/Notch/NotchController.swift), [`NotchViewModel`](Sources/Peninsula/Notch/NotchViewModel.swift), [`Motion`](Sources/Peninsula/Motion/Motion.swift).

---

## Releasing

```bash
./scripts/release.sh
```

Builds, signs, notarises, staples, writes `build/dist/Peninsula-<version>.zip`.

Needs a **Developer ID Application** certificate — Apple Distribution and Apple Development cannot be notarised. Credentials are stored once:

```bash
xcrun notarytool store-credentials Peninsula-notary --apple-id you@example.com --team-id TEAMID --password xxxx-xxxx-xxxx-xxxx
```

The icon is drawn by `scripts/make-icon.swift` rather than exported from a design tool.

---

## Licence

[MIT](LICENSE). Bundles [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) (BSD 3-Clause, © 2025 Jonas van den Berg).
