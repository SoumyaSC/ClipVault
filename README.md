<div align="center">

<img src="Resources/brand/icon_256x256.png" width="128" alt="ClipVault">

# ClipVault

**A native macOS menu-bar clipboard manager.** Every piece of text and every image
you copy — captured silently, searchable instantly, pasteable anywhere.

[![Release](https://img.shields.io/github/v/release/SoumyaSC/ClipVault?color=6B5CF2&label=release)](https://github.com/SoumyaSC/ClipVault/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/SoumyaSC/ClipVault/total?color=6B5CF2)](https://github.com/SoumyaSC/ClipVault/releases)
![macOS 13+](https://img.shields.io/badge/macOS-13%20Ventura%2B-6B5CF2)
![Universal](https://img.shields.io/badge/binary-universal-6B5CF2)
![Dependencies](https://img.shields.io/badge/dependencies-none-6B5CF2)

</div>

## Screenshots

<div align="center">

<img src="docs/screenshots/panel-dark.png" width="360" alt="The ClipVault panel listing recent clipboard items, newest first, with a thumbnail for a copied image">

<em>⌘⇧V from anywhere. Click an item to copy it back.</em>

<br><br>

<img src="docs/screenshots/panel-search-dark.png" width="330" alt="The panel filtered live as a search query is typed">
&nbsp;&nbsp;
<img src="docs/screenshots/panel-light.png" width="330" alt="The same panel in light appearance">

<em>Search is focused the moment the panel opens · light and dark, automatically</em>

</div>

## Install

### Homebrew (recommended)

```sh
brew install --cask soumyasc/tap/clipvault
```

Brew-installed apps aren't quarantine-flagged, so Gatekeeper never prompts.
Upgrade later with `brew upgrade --cask clipvault`.

### Direct download

1. Grab the newest `ClipVault-<version>.zip` from [Releases](https://github.com/SoumyaSC/ClipVault/releases/latest)
2. Unzip and drag **ClipVault** into **Applications**
3. **First launch:** right-click the app → **Open** → **Open**. ClipVault is
   ad-hoc signed rather than notarised, so Gatekeeper blocks a plain
   double-click on a downloaded copy. Once is enough. (From the terminal:
   `xattr -dr com.apple.quarantine /Applications/ClipVault.app`)

Then copy anything — it's already in your history. Press **⌘⇧V** anywhere to see it.

> Keep exactly one copy installed, in `/Applications`. Running from elsewhere
> works day to day, but macOS only reports a trustworthy launch-at-login state
> for an app it can register from a standard location.

## Updates

ClipVault asks GitHub once a day whether a newer release exists and, if so, says
so in **Settings → Advanced** and in the menu-bar right-click menu. It never
installs anything behind your back:

```sh
brew upgrade --cask clipvault     # or download the new release
```

Turn the check off with **Settings → Advanced → Check for updates
automatically**; nothing else in the app touches the network.

> Why not Sparkle-style silent self-update: ClipVault is ad-hoc signed, which
> breaks the code-signature continuity a self-updater relies on to know it is
> installing the same app. Homebrew already does upgrades properly.

## The 15-second tour

| Action | How |
|---|---|
| Open panel | **⌘⇧V** anywhere, or click the menu-bar icon |
| Search | Just start typing (search is focused automatically) |
| Copy an item back | **Click it** (instant), or select with **↑↓** + **↩** |
| Quick Paste into previous app | Hover the card → 📋 button, or press **⌘↩** |
| Jump-copy top item | **⌘1** … **⌘9** |
| Pin / Unpin | Hover → 📌, or right-click |
| Delete item | Hover → 🗑, or right-click, or **⌘⌫** on selection |
| Filters | `All · Text · Images · Pinned` chips at the top |
| Settings | Gear icon, or right-click the menu-bar icon → Settings |

Right-clicking the menu-bar icon also offers **Quick Paste Last Item** and a **Launch at Login** toggle.

## What it captures

- **Plain text** — with rich-text (HTML/RTF) fidelity preserved when the source provides it, so formatting survives the round-trip
- **Images** — stored losslessly as PNG, with instant thumbnails generated for the list
- **Image files** — copy a `.png` / `.jpg` / `.heic`… from Finder and ClipVault captures the *picture itself*: clicking it pastes the image, not a filename

## What it deliberately ignores

- **Password-manager copies** — 1Password, Bitwarden, KeePassXC and friends mark copies as *concealed* (`org.nspasteboard.ConcealedType`); ClipVault never records them by default. If you disable this guard, captured sensitive items — text *and* images — are shown masked (`••••••••`) in the list; contents stay hidden until copied.
- **Transient copies** — internal app chatter flagged via `org.nspasteboard.TransientType`
- **Apps on your ignore list** — editable in Settings → Security (pre-filled with common password managers)
- **All other files** — documents, folders, multi-file selections are never stored
- Optional: **short numeric codes** (likely OTPs) — off by default so no legitimate copy is ever dropped

## Retention (defaults)

- **Last 200 items** kept (50–1000, configurable)
- **Images auto-purge after 30 days** (7/30/90/365/never, configurable) — pinned images are immune; *Never expire automatically* persists across relaunches
- Pinned items are never evicted by the cap

## Troubleshooting

| Symptom | Fix |
|---|---|
| Launch-at-login toggle looks wrong | macOS only reports a trustworthy state for an app it can register — run ClipVault from `/Applications`. From anywhere else the stored preference is kept as-is rather than being reset. |
| Behaviour seems stale | The footer shows the running version — make sure only `/Applications/ClipVault.app` is installed and relaunch. A second launch while one is running simply opens the panel (single-instance guard). |
| Icon hidden behind the notch | Press ⌘⇧V, double-click the app in Applications, or enable *Show ClipVault in the Dock*. |
| DMG won't build from source | A root-owned `diskimages-helper` can wedge DiskImages; `sudo pkill -9 diskimages-helper` or reboot. The build falls back to a ZIP automatically. |

## Performance notes

- Pasteboard polling is 4×/second with App Nap disabled for the process, so captures are near-instant even when idle.
- Image normalisation (PNG re-encode + thumbnails for large screenshots) runs off the main thread; the panel never blocks on big captures.
- The visible list is memoized per store-revision + query + filter; thumbnails decode once into an LRU cache.

## Privacy

Everything stays on your machine:

```
~/Library/Application Support/ClipVault/
├── manifest.json      # ordered metadata
└── data/              # payloads: <uuid>.txt / .png / .thumb.png / .html / .rtf / .files
```

No analytics. No accounts. No telemetry. Deleting that folder deletes your history.

The **one** network request ClipVault makes is the daily update check: an
unauthenticated `GET https://api.github.com/repos/SoumyaSC/ClipVault/releases/latest`,
which sends nothing but the request itself and can be switched off in Settings →
Advanced. Clipboard contents never leave your Mac.

## Permissions (only if you want Quick Paste)

| Permission | Needed for | Grant |
|---|---|---|
| **Accessibility** | Quick Paste (double-click / ⌘↩ pastes into your previous app) | Settings → Advanced → *Grant*, or automatically prompted on first use |

ClipVault uses Accessibility **only** to synthesise a ⌘V keystroke. It never reads other apps' content or your keystrokes. Plain click-to-copy needs **zero** permissions.

## Settings reference

- **General** — Launch at login · Dock icon · ⌘⇧V hotkey on/off · close-panel-after-copy · haptic feedback (ClipVault is silent by design)
- **History** — item cap · image retention · storage usage · purge now · open data folder
- **Security** — concealed-copy guard · sensitive masking · OTP filter · ignored-apps editor
- **Advanced** — Accessibility status · update check + toggle · re-show welcome banner · version, build and source commit

## Versioning & releases

ClipVault follows [Semantic Versioning](https://semver.org). The version lives in
exactly one place — the `VERSION` file at the repo root — and everything else
derives from it:

| Identity | Source | Where it shows up |
|---|---|---|
| Marketing version (`1.0.7`) | `VERSION` | `CFBundleShortVersionString`, panel footer, Settings → Advanced |
| Build number | `git rev-list --count HEAD` | `CFBundleVersion` — monotonic, so macOS never mistakes a newer build for an older one |
| Source commit | `git rev-parse --short HEAD` | `CVSourceCommit` in `Info.plist`, shown in About for bug reports |

Inspect what the current checkout would stamp:

```bash
./Scripts/version.sh
```

**What a bump means**

- **PATCH** — bug fixes and hardening; no behaviour a user relies on changes.
- **MINOR** — new capability or a visible behaviour change that stays compatible
  with existing history and preferences.
- **MAJOR** — a breaking change to the on-disk format (`manifest.json` schema,
  payload layout) or to preference keys, i.e. anything a downgrade can't undo.

Changelog compare/tag links are generated from the `origin` remote. A checkout
with no GitHub remote (a fork, a tarball) falls back to a visible
`OWNER/ClipVault` placeholder rather than silently writing someone else's URL.

**Cutting a release**

1. Describe the change under `## [Unreleased]` in `CHANGELOG.md` as you go.
2. Run the release script — it refuses to start on a dirty tree, with an empty
   `[Unreleased]`, or if the tag already exists:

```bash
./Scripts/release.sh patch --dry-run
```

3. Drop `--dry-run` to write `VERSION`, promote the changelog section, run the
   full build, commit `Release vX.Y.Z`, and create an annotated tag.
4. Push. The tag triggers `.github/workflows/release.yml`, which rebuilds from a
   clean checkout, verifies the tag matches `VERSION`, and publishes the archives
   with the changelog section as release notes:

```bash
git push origin HEAD --follow-tags
```

`.github/workflows/ci.yml` runs the SPM build, the test suite, and the full
release pipeline on every push and pull request.

> Not yet in place: a Developer ID signature and notarisation. Until then,
> downloaded builds need the one-time right-click → Open described in
> [Install](#install).

## Building from source

Requirements: macOS 13+, Command Line Tools (`xcode-select --install`). Full Xcode is **not** required.

```bash
./Scripts/build_app.sh
```

Pipeline: unit tests → universal `swiftc` build (arm64 + x86_64) → `.icns` assembly → `.app` bundle → ad-hoc codesign → DMG. Artifacts land in `dist/`.

Regenerate the icon after design tweaks:

```bash
swift Scripts/make_icon.swift Resources/brand
```

Run the test suite alone:

```bash
swift run ClipVaultTests
```

> Note: the test harness is a dependency-free executable because Command Line Tools don't ship XCTest. Same assertion API, zero Xcode requirement.

## Architecture (for maintainers)

```
Sources/
├── ClipVault/main.swift          # process entry (NSApplication, accessory policy)
└── ClipVaultCore/
    ├── Models/                   # ClipItem, ClipStore (JSON manifest + payload files, atomic writes)
    ├── Clipboard/                # ClipboardClassifier (pure, unit-tested) + 0.25s poll monitor
    ├── Helpers/                  # Carbon hotkey, CGEvent Quick Paste, SMAppService, feedback
    └── UI/                       # AppDelegate (status item/popover), SwiftUI panel & settings
```

Key invariants enforced by tests: pinned items sort above chronological; caps evict oldest *unpinned* only; re-copying old content moves it to the top (never duplicates); sensitivity flags never downgrade; payload-missing entries are dropped on load, never crash.

## Uninstall

```sh
brew uninstall --cask clipvault          # also removes the app
brew uninstall --zap --cask clipvault    # …and the history + preferences
```

By hand: quit ClipVault (menu-bar icon → Quit), delete it from `/Applications`,
then remove `~/Library/Application Support/ClipVault` (history) and
`~/Library/Preferences/app.clipvault.ClipVault.plist` (settings). If launch-at-login
was on, drop it from System Settings → General → Login Items.
