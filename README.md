# Peninsula

*[한국어](README.ko.md)*

A macOS app that turns the MacBook notch into a Dynamic Island. SwiftUI + AppKit, no third-party dependencies.

**0.05% CPU · 14MB · 3 threads while resident** — all measured, and [further down](#performance) is how it got there.

<img src="docs/compact.png" width="248" alt="The resting pill while playing">

While something is playing the notch grows a little sideways and carries just the artwork and the meter. Hovering opens it.

<img src="docs/media.png" width="640" alt="Media panel">

<img src="docs/shelf.png" width="640" alt="Shelf">

<img src="docs/devices.png" width="640" alt="Device batteries">

> ### Before you download this
>
> macOS gives no public API for what another app is playing. This app reads the **private MediaRemote framework** through the system perl binary, which is still entitled ([details](#things-worth-knowing)).
>
> **Apple can close that path in any macOS update.** When it happens the app says so in the notch rather than dying quietly — but the playback features end there. For the same reason this app **cannot go on the App Store**, and never will.
>
> Everything else — the shelf, AirDrop, device batteries, the HUD replacement, live activities — is public API and is not at risk.

---

## Install

macOS 14 (Sonoma) or later, on a MacBook with a notch.

Download the zip from [Releases](https://github.com/RHbox/peninsula/releases), unpack it, and move the app to **Applications**. It is signed with a Developer ID and notarised by Apple, so it opens without a warning.

**Turn on "Open at login" *after* moving the app to Applications** — it registers a path.

**Languages** — English · 한국어 · 日本語 · 简体中文 · Español · Français · Deutsch, following the system language. The source strings are English, so a language with no translation falls back to readable English, and adding one is a single `Resources/<code>.lproj/` folder.

### Build from source

```bash
./scripts/bundle.sh release && open build/Dynamic.app
```

The first build fetches [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) (BSD-3) and builds it into a framework. No cmake needed.

---

## Why "peninsula"

The iPhone has a Dynamic **Island**. It is pixels floating in the middle of the screen — a real island, free to grow in any direction.

The MacBook notch is **a physical hole in the panel**. It cannot be detached from the bezel. So this app does not imitate an island; it stays attached and reaches outward instead — drawn in **exactly the cutout's black**, starting at the cutout's edge and growing from there, which is visually indistinguishable.

For that to hold, two things must never break, and the whole codebase stands on them.

**1. The resting state must be identical to the cutout.**
There are four states — `idle` (the cutout itself, invisible), `compact` (grown a little sideways), `peek` (a banner), `expanded` (the full panel). Keeping the pill permanently wider than the cutout turns "a notch" into "a black bar". Once playback stops and some time passes, the pill withdraws and only the notch is left.

**2. Nothing may be drawn over the cutout.**
There is no screen behind the camera housing. So every row that crosses the cutout's latitude is split into **leading / gap / trailing** — the banner, the HUD bar, the tab strip. When a third tab appears and the labels no longer fit, they drop to icons rather than being truncated.

The notch is also **pinned to a private window server Space**. The `.stationary` flag alone does not survive a desktop switch, and a panel that slides away exposes the physical cutout. A real notch is hardware; hardware does not move.

---

## Motion — measured, not guessed

It uses Apple's own notation from WWDC23 (`duration` + `bounce`). A transition is defined in exactly one place, [`Motion.Timeline`](Sources/Dynamic/Motion/Motion.swift), and **the real animation and the Motion Lab read the same values.**

The default preset's numbers were not chosen. They come from **recording a real Dynamic Island at 50fps, extracting the silhouette frame by frame, and least-squares fitting Apple's own `Spring(duration:bounce:)`** to it.

| | duration | bounce | fit (rms) |
|---|---|---|---|
| Expand · horizontal | 0.445s | +0.10 | 0.009 |
| Expand · vertical | 0.420s | +0.06 | 0.011 |
| Collapse · vertical | 0.455s | +0.12 | 0.007 |
| Collapse · horizontal | ~0.19s | overdamped | — |

Two assumptions turned out to be wrong.

**Expanding, both axes move together.** That width leads and height follows was a plausible guess, and false. Measured, the horizontal and vertical progress track each other within 2% across the whole transition.

**Collapsing, width arrives more than twice as early.** The panel snaps closed horizontally into a tall black block, and that block is drawn upward. On a MacBook this reads as "returning into the slot".

**Content is scaled whole, not re-laid-out.** Also measured. The artwork's left margin during expansion, frame by frame: 55px at 85.5% of container width, 61px at 94.5%, 64px at 98.6% (final 65px). A fixed margin would stay at 65 throughout; proportional to the container it would be 55.6 / 61.4 / 64.1 — **it is proportional.** So each state's content is laid out once at its own final size and scaled by the container's two springs. Re-laying it out for the current size every frame crushes a 624pt layout into a 384×101 box, rows overlap and spill past the corners.

The scale has to live **inside the transition**. The container's size changes in the *same transaction* that inserts the content, and a view that did not exist a frame earlier gives `.animation(_:value:)` no previous value to compare — it silently does nothing, and the content appears at full size inside the pill.

**Blur runs on a different clock from opacity.** Tied to the same curve, the blur lifts uniformly and the whole thing becomes "a crossfade with soft edges". The reference starts focusing about 30% through the container's travel and is already sharp at 75%, while on the way out it becomes unreadable **within two frames**. So blur alone rides separate `contentFocus` / `contentDefocus` curves.

The recoil is still a **horizontal-only impulse** — the container spring covers both axes and would shake the vertical too. The impulse is applied when the width arrives, not at t=0.

### Motion Lab

Settings › Motion Lab steps through every frame at **1/60s**, forwards and backwards. It is not abstract boxes: **the real island content** (artwork, title, meter, scrubber, transport) takes the actual transition effects, so you can judge by eye when and how each element arrives. Turning on the cutout overlay makes safe-zone violations obvious.

It can also be dumped as a contact sheet:

```bash
"$(swift build --show-bin-path)/Dynamic" --dump-frames ./frames
```

---

## Features

**Now playing** — artwork (3D flip on track change), title and artist, synced lyrics, scrubber with remaining time, favourite / previous / play / next / AirPlay, system volume, meter. Lyrics also show on the resting pill.

**Shelf** — a wide strip along the top of the screen catches the drag and the panel opens fully. It splits into two zones at **AirDrop : shelf = 1:3**, so where you drop is the destination. Files are copied into a folder of the app's own, so moving the original keeps them; dropping the same file again brings it to the front. Double-click for Quick Look; only the × removes it.

**Devices** — battery levels for connected Bluetooth devices. AirPods report left, right and case separately.

**Live activities** — charger connected / full / low, downloads and screenshots finished, devices connecting, AirDrop arriving.

**HUD replacement** — intercepts the volume and brightness keys and draws them in the notch instead of the system overlay. Needs Accessibility permission, and turns itself on the moment the permission is granted, with no relaunch.

---

## Performance

It is a menu-bar resident, so the idle cost is the whole story. Measured, then fixed.

| | before | now |
|---|---|---|
| Idle CPU | 4.2% | **0.05%** |
| Memory, idle with nothing playing | 57MB | **14MB** |
| Memory, idle while playing | — | **23–30MB** |
| Threads (idle) | — | **3** |
| CPU per frame during expand/collapse | — | **−25%** |
| Growth per 200 expand/collapse cycles | +21MB | **0MB** |

With the conditions attached, because they matter more than the numbers. The idle CPU figure is 54.2 seconds of accumulated CPU divided by **31.8 hours of continuous real use** — playback, panels, shelf and all — not a quiet minute picked by hand.

Memory depends mostly on whether artwork is loaded, so both states are listed. While playing, repeated 100-second runs land anywhere between 23 and 30MB on the same build, so treat any single reading as ±4MB; after 31.8 hours of real use it was 49MB across 6 threads. It does grow, but it **grows once and stops** — ⑤ below is that story.

**① The meter ate CPU for two reasons.**

On macOS, a `TimelineView` inside an `NSHostingView` makes `sizeThatFits()` oscillate between the real size and zero dozens of times a second, recomputing the entire layout each time (Apple FB13810482, open). The notch is exactly that structure. And with `.shadow()` on the whole container, moving a single bar inside it recomputes a 646×244 blur every frame — a shadow is cast by the rendered *result*.

The meter became a `CAShapeLayer` with `CABasicAnimation` (the render server interpolates; the app only sets a target four times a second), and the shadow moved to a static layer behind the content. **The rule that came out of it: never put an animating element inside a layer that carries a shadow or a clip.**

**② The memory was the artwork.** `NSImage(data:)` rasterises at full resolution — a 3000×3000 cover is 36MB of pixels alone, drawn on screen at 96pt. Switching to `CGImageSourceCreateThumbnailAtIndex` means the full bitmap is never created.

**③ The cost during transitions was in three places.** A bench that repeats expand/collapse 200 times (`DYNAMIC_BENCH=transitions`) made it measurable by removing one part at a time.

- **Apply the jelly deformation to the shape, not the view.** A `scaleEffect` on the container propagates down into the AppKit views inside it (the meter, the AirPlay button), and every frame runs `-[NSView setFrameTransform:]` → layout invalidation → tracking-area updates, recursively. That was 4.4 points. Stretching `NotchShape`'s path gives the same shape at essentially no cost.
- **Invisible black was being painted twice.** The shadow layer already fills the same silhouette with black, and the content layer filled it again. 5 points.
- **The outline sets its line width to zero when invisible.** `stroke` recomputes the bezier outline every frame regardless.

The second rule from this: **never put an AppKit-hosted view inside an animating transform.**

**④ The settings window lets go when closed.** With `isReleasedWhenClosed = false` and a static reference held on top, opening it once kept the entire SwiftUI tree alive for the rest of the session. Most of this app's resident memory was a window nobody was looking at.

**⑤ Expanding and collapsing leaked memory — except it was a cache, not a leak.** Two hundred open/close cycles ended 21MB heavier and stayed there. `leaks` reports zero. Reachable and still growing means a cache.

The culprit was **CoreGraphics' glyph bitmap cache** (`CGGlyphBuilderLockBitmaps`). That cache holds **one entry per distinct text matrix** and **evicts nothing**. Because this app scales content whole rather than re-laying it out (see the motion section), a single transition rasterises the title, artist and timings at **a slightly different scale every frame**. Each frame mints a new entry, and it stays forever.

Here the intuition inverts. **The cheaper the rendering, the more it leaks** — cheaper means more frames, and more frames mean more distinct scales.

The fix is to draw the text **once** into a texture and let the springs move that texture (`drawingGroup`). But **not on the panel as a whole**, which is the obvious place and is wrong: nothing hosted from AppKit — the meter, the AirPlay button — draws inside a rasterised group; they become 🚫 placeholders. That took a screenshot to notice. So [`rasterisedText()`](Sources/Dynamic/Motion/Transitions.swift) is applied only to text subtrees. On the marquee title it goes *inside* the offset, so scrolling moves a texture instead of redrawing the glyphs every frame.

The result: 0MB of growth over 200 cycles, a five-minute soak flat at 86·86·85·85MB, and transition CPU down from 16.3% to 11.1% as a bonus.

**⑥ Focus mode was removed.** `INFocusStatusCenter` is not trustworthy on macOS — `authorizationStatus` returns `.notDetermined` inside the same process at the very moment tccd has `kTCCServiceFocusStatus` recorded as `authValue=2` (allowed), and `focusStatus.isFocused` never moved off `false` even with a Focus turned on. Requesting authorisation shows no prompt, and **SIGABRTs the process** if the app was not launched through LaunchServices. That is not a surface worth carrying for one moon icon.

---

## Layout

```
Sources/Dynamic/
  App/          entry point, app delegate, status item
  Core/         preferences, login item, observation loop, logging
  Motion/       spring timelines, transitions, frame dump
  Notch/        panel, shape, geometry, controller (the whole window layer)
  Media/        MediaRemote bridge, playback engine, lyrics, artwork, system volume
  Shelf/        shelf store, drag detection, Quick Look
  System/       power / folder / Bluetooth observers, file origin, HUD tap, brightness
  UI/           every SwiftUI view
```

The core three: [`NotchController`](Sources/Dynamic/Notch/NotchController.swift) (window and pointer), [`NotchViewModel`](Sources/Dynamic/Notch/NotchViewModel.swift) (state machine), [`Motion`](Sources/Dynamic/Motion/Motion.swift) (all of the motion).

---

## Security

**There are only two entitlements** — sandbox disabled (to run perl and to copy the user's files) and Apple Events (to favourite a track in Music). `allow-jit` and `disable-library-validation` were in there until it turned out everything works without them.

**Four fields ever leave the machine**: title, artist, album and duration. To lrclib.net, over HTTPS, switchable off in settings, and through an ephemeral session so no process-wide cookies or credentials go along.

**The event tap cannot see typing.** It subscribes to `NX_SYSDEFINED` only, so even with Accessibility permission granted, keyboard, mouse and text events are never delivered to it in the first place.

**No user data reaches the logs.** Filenames and paths are all logged as `.private` — `.public` would leave them in plain text in the system log and in any sysdiagnose.

**Every private API is called through `dlsym`.** With `@_silgen_name`, a symbol that disappears fails dyld binding and the app will not even launch; looked up by name it simply returns `nil` and only that one feature goes quiet. Both the above-full-screen behaviour (SkyLight) and brightness (DisplayServices) work this way.

**Patterns handed to subprocesses are escaped.** The argument to `pkill -f` is a regex matched against every process on the system, so `+ * ( [` in the app's own path could kill something unrelated.

---

## Things worth knowing

**Playback information** — since macOS 15.4, MediaRemote is reachable only by Apple's own processes. This app reads it through [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter), using the system perl binary, which is still entitled. If that path closes, the notch says so rather than going quiet.

**Receiving AirDrop is macOS's job.** Both the approval dialog and the progress belong to `sharingd`, and there is no way in. So the arrival is detected instead — a received file carries `sharingd` as the agent in `com.apple.quarantine`, which distinguishes it from a download into the same folder. It reads "receiving" while the transfer runs, and switches to "received" and lands on the shelf when the file size settles.

**The meter is decoration.** macOS offers no public API to read another app's output. It responds to playback state; it does not measure a signal.

**Signing** — an ad-hoc signature changes on every build, and macOS keys privacy permissions to the signature. That means **rebuilding silently revokes them.** The bundler finds a usable certificate automatically, and one can be pinned:

```bash
SIGN_IDENTITY="Apple Development: you@example.com" ./scripts/bundle.sh release
```

**Open at login** registers a path, so turn it on after moving the app to Applications.

---

## Releasing

```bash
./scripts/release.sh
```

Builds, signs, notarises and staples, and leaves `build/dist/Dynamic-<version>.zip`.

**A Developer ID Application certificate is required.** Apple Distribution (for the App Store) and Apple Development (for your own Macs) cannot be notarised, and fail minutes after submission with an error that does not name the cause. So the script matches the certificate by name and refuses to start without it.

Credentials are stored once:

```bash
xcrun notarytool store-credentials Dynamic-notary --apple-id you@example.com --team-id TEAMID --password xxxx-xxxx-xxxx-xxxx
```

Two things that catch people out are already handled. The signature needs a **secure timestamp** (`--timestamp=none` is rejected), and the hardened runtime has to be on **every Mach-O in the bundle** — not just the main executable, but `MediaRemoteAdapter.framework` too.

---

## Licence

[MIT](LICENSE).

Bundles [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) (BSD 3-Clause, © 2025 Jonas van den Berg). Its full licence text ships inside the app at `Dynamic.app/Contents/Resources/LICENSE-mediaremote-adapter`.
