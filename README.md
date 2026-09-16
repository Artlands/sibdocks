# SibDocks

A dock for every display that is not currently hosting the system Dock. Each
screen gets its own strip showing only the windows currently assigned to that
screen; clicking an icon raises that window on the display whose strip was
clicked.

macOS gives you one Dock that follows the active display and lists *apps*.
SibDocks gives you one strip per other display that lists *windows*, and only
the ones living on that display.

The display currently hosting the system Dock continues to use it. If the
system Dock visits another display, SibDocks takes over the display it left,
preventing two docks from being stacked on the same edge.

## Requirements

- macOS 26 or later, for the Liquid Glass material (developed on macOS 27)
- Swift 6 toolchain (Xcode Command Line Tools is enough)
- Accessibility permission

The published app uses bundle identifier `com.artlands.sibdocks`.

## Build and run

```sh
./build.sh          # produces SibDocks.app
open SibDocks.app   # appears in the menu bar and requests Accessibility
```

For a local Homebrew-compatible archive:

```sh
./Scripts/package-release.sh 0.1.0
./Scripts/update-cask.sh 0.1.0
```

This produces `dist/SibDocks-0.1.0.zip`, its SHA-256 sidecar, and the cask in
`Casks/sibdocks.rb`. The archive is ad-hoc signed by default for development;
that is not sufficient for a public Homebrew release because Gatekeeper will
reject it. Set `SIGNING_IDENTITY` to a Developer ID Application identity and
`NOTARY_PROFILE` to an `xcrun notarytool` profile when producing the release
archive. The release workflow enforces both.

The cask is ready to submit to `homebrew/cask` after the matching GitHub
release exists. For a personal tap, copy `Casks/sibdocks.rb` into an
`Artlands/homebrew-sibdocks` repository and install with:

```sh
brew tap Artlands/sibdocks
brew install --cask sibdocks
```

GitHub tag pushes matching `vMAJOR.MINOR.PATCH` run the signed/notarized
release workflow. Configure these repository secrets first:
`DEVELOPER_ID_CERTIFICATE_P12_BASE64`, `DEVELOPER_ID_CERTIFICATE_PASSWORD`,
`BUILD_KEYCHAIN_PASSWORD`, `APPLE_NOTARY_KEY_BASE64`, `APPLE_NOTARY_KEY_ID`,
and `APPLE_NOTARY_ISSUER`.

The first launch asks for Accessibility in System Settings → Privacy &
Security → Accessibility. SibDocks remains available in the menu bar while it
waits for approval and starts its display docks automatically after access is
granted. The display strips may be empty until approval is granted, because
macOS does not expose application windows to SibDocks without Accessibility.
The menu-bar item also includes a shortcut to the Accessibility pane if the
permission prompt was dismissed.

**Every rebuild costs you that grant.** Ad-hoc signing ties the Accessibility
permission to the binary's cdhash, so a rebuilt binary is a different binary as
far as TCC is concerned, and it gets denied with no prompt. `build.sh` runs
`tccutil reset Accessibility com.artlands.sibdocks` to clear the stale entry, so the
next launch asks again rather than quitting silently. Sign with a stable
self-signed certificate instead if the re-approval gets tiresome.
It runs as an `LSUIElement` agent: no Dock icon, no app menu. Quitting is
through the menu bar icon → **Quit SibDocks**, and the same menu includes a
checkable **Start SibDocks at Login** option. This uses macOS's native Login
Items registration, so the setting can also be reviewed in System Settings →
General → Login Items. From a terminal, it can also be stopped with:

```sh
pkill -x SibDocks
```

The login-item setting is independent of Accessibility permission. SibDocks
still needs Accessibility enabled under System Settings → Privacy & Security
→ Accessibility before it can enumerate and control application windows.

SibDocks uses the native `dock.rectangle` symbol for its application and menu
bar icon. The bundle icon is rendered directly from that same SF Symbol during
each build, so it stays visually identical rather than relying on a separate
piece of artwork.

## Minimized windows

SibDocks keeps a dimmed tile for a minimized or hidden window on the strip
belonging to the last display where that window was visible. Clicking that tile
brings the window back **onto the strip's display**, including when the window
was minimized from another screen. The last display and frame are cached so
applications that report the system Dock's frame while minimized do not cause
the tile to jump to the wrong screen.

That last part is the point of a per-screen dock. The tile you click decides
where the window lands, so a window minimized from one display and restored from
another display's strip moves there, keeping its offset within the screen. A
window already on the right screen is simply un-minimized where it sits.

The move is issued before clearing `AXMinimized`, because AX position on a
minimized window sets the frame it will restore to. Setting it afterwards would
race the restore animation.

Windows belonging to hidden apps (⌘H) get the same dimmed treatment, and
clicking unhides the app.

## Context menu

Right-clicking a tile follows the system Dock's familiar menu shape: **Open**
or **Show**, **Show All Windows**, an **Options** submenu with **Show in
Finder**, then **Hide** and **Quit**. The window actions use the stored
Accessibility element rather than trying to identify the window again.

macOS does not expose a public API for removing another application's
minimized window from the system Dock or re-parenting it into a third-party
panel. Consequently the system Dock may also show the minimized window; the
SibDocks tile is the authoritative per-display restore affordance available to
an Accessibility client.

## Appearance

The strips track System Settings → Desktop & Dock. `com.apple.dock` is read on
every tick, so a change shows up within a second:

| Setting | Key | Effect |
| --- | --- | --- |
| Size | `tilesize` | Icon size, and every derived measurement below |
| Magnification | `magnification`, `largesize` | Hover magnification with the same falloff curve |
| Position on screen | `orientation` | Strip sits along the bottom, left, or right edge |
| Automatically hide | `autohide`, `autohide-delay` | Reveals when the pointer reaches the configured edge |
| Open-app indicators | `show-process-indicators` | Small status dot on each window tile |
| Minimize animation | `mineffect` | Genie-style or scale-style tile departure |

The background is `NSGlassEffectView`, the same Liquid Glass material the
system Dock uses on macOS 26 and later, so light and dark mode come for free.

When a fixed SibDocks strip is visible, its edge footprint is reserved from
application windows. SibDocks uses the screen's `visibleFrame` as the base
usable area and keeps visible windows inside the remaining area through its
Accessibility connection, including resizing windows that are larger than
the available space. Auto-hidden strips keep the system Dock's overlay
behavior and do not reserve a permanent strip.

Padding, gaps, and corner radius are ratios of `tilesize`, calibrated against
the stock Dock. At `tilesize 42`, SibDocks uses an 8pt pad, a 6pt indicator
lane, a 64pt glass depth, and a 4pt edge margin. They are grouped in
`DockStyle` if a future macOS restyles the Dock and they need re-tuning.

## How it works

1. Each regular running app is asked via Accessibility for its `AXWindows`,
   keeping those with the `AXStandardWindow` subrole or a minimize button.
   Each window is held as its `AXUIElement`, along with its title, frame, last
   visible display, and whether it is minimized or its app is hidden.
2. Each window's center is converted from CoreGraphics global coordinates
   (origin top-left of the primary display, y down) to Cocoa coordinates
   (origin bottom-left, y up) and matched against `NSScreen.frame`.
3. The display hosting the real macOS Dock is suppressed so the two strips
   never overlap. SibDocks recreates its panel when the system Dock moves
   away; this can include the primary display when the Dock is visiting an
   external display.
4. One borderless non-activating `NSPanel` per remaining display renders that
   screen's windows as app icons on a glass strip along the configured edge.
   Displays with no windows keep no panel, so the strip appears when the first
   window arrives.
5. A global mouse monitor drives magnification. Fixed docks reserve their
   resting edge footprint from application windows through Accessibility, and
   each visible panel keeps its narrow clickable strip; auto-hidden panels
   overlay content only while revealed.
6. AX observers wake the controller immediately for window creation, movement,
   title, minimize, and app-hidden changes; a one-second poll remains as a
   recovery path for applications that do not emit useful AX notifications.
   System Dock ownership is checked separately at a shorter interval because
   moving the Dock between displays does not reliably emit a screen-change
   notification.
   Clicking an icon moves the window onto that strip's screen, unhides the app,
   clears `AXMinimized`, sets `AXMain`, performs `AXRaise`, and activates the
   app. It acts on the stored element directly, so there is no window-matching
   step to get wrong.

Displays coming and going are handled through
`NSApplication.didChangeScreenParametersNotification`.

### Why Accessibility and not CGWindowList

`CGWindowListCopyWindowInfo` reports a minimized window and a window sitting on
another Space identically: both are simply absent from the on-screen list and
present in the full one. Nothing in the CoreGraphics window dictionary tells
them apart. `AXMinimized` does, so Accessibility is the window source and
CoreGraphics is used only to locate the real Dock.

Two things fall out of that. Window titles come from `AXTitle`, which needs no
Screen Recording permission, so tiles are labelled with real titles rather than
just the app name. And because a window is held as its `AXUIElement`, which
stays valid for the window's lifetime, clicks act on it directly.

## Self-check

```sh
swift build && ./.build/debug/SibDocks --selftest
```

Asserts that the coordinate flip is its own inverse, the resting Dock
footprint is reserved on every edge, and live windows resolve to real screens;
it then prints the screen → window mapping:

```
layout ok (bottom/left/right, magnified + resting)
reservation geometry ok (bottom/left/right)
accessibility trusted: true
[DELL U2720Q] sibdocks
[DELL P2725QE] NSF_Proposal_AI_Datasets_2026 - Overleaf - Google Chrome
[DELL U2720Q] (stowed) a calm playlist ... - YouTube - Google Chrome
[DELL U2720Q] [1/2] Create macOS multi-screen dock tool
[DELL P2725QE] README.md — sibdocks
style: DockStyle(tile: 42.0, large: 72.0, magnify: true, edge: SibDocks.DockEdge.bottom)
real Dock on: DELL P2725QE
5 windows, 0 unmatched, 2 screen(s)
```

Run it from `SibDocks.app`, not from `.build`: enumeration is
Accessibility-only, so an untrusted binary reports zero windows.

`--dump` prints every app's raw AX window list with subrole, minimized state,
frame, and minimize-button presence. That is how the window filter was settled:
Outlook and Calendar report their main window as `AXDialog`, so filtering on
`AXStandardWindow` alone silently dropped real windows.

`--restore <app>` exercises what clicking a tile does, restoring that app's
window onto a strip-bearing screen and printing the before and after frames. A
synthetic click would need Accessibility for the test process too, so this is
the way in.

Run either with `--selftest`, for example `--selftest --dump`.

The layout check asserts that magnified tiles never overlap, that the tile
under the cursor is the largest one, that nothing grows past `largesize`, and
that tiles sit at exactly `tilesize` when the cursor is away, for all three
orientations.

If a window shows as `[unmatched]`, the coordinate conversion is wrong for
that display arrangement. Run this before filing anything.

## Known limits

- **The system Dock still owns minimized-window tiles.** Public macOS APIs do
  not allow SibDocks to remove or re-parent another app's minimized window.
  SibDocks mirrors the state and provides correct per-display restoration; it
  cannot suppress the system Dock's copy without private, fragile APIs.
- **One button per window, no grouping.** With enough windows open the strip
  proportionally compresses its tiles to keep every window on the display.
  Group by app would be needed for larger collections.
- **Tile click versus context actions.** A normal tile click raises/restores a
  window. The native context menu also provides Hide, Quit, and Show in Finder.
- **Some Dock details remain private.** Size, magnification, position,
  auto-hide, minimize effect, and the indicator preference are mirrored. The
  recents section and the Dock's exact animation, spacing, and indicator
  geometry are not exposed to third-party apps.
- **Magnification is an approximation.** Each tile is scaled from its resting
  centre and the magnified widths are then laid out cumulatively. The real Dock
  solves position and width together. Close, not identical.
- **Auto-hide detection.** When the system Dock is hidden, its on-screen window
  is unavailable, so SibDocks retains the last known Dock host (or falls back
  to the main display) until the Dock reappears.
- **Fullscreen handling.** SibDocks does not join another app's true
  full-screen Space, matching the system Dock's behavior.
- **Other Spaces are not filtered.** A window on another Space is neither
  minimized nor hidden, so it appears on its screen's strip as a normal tile.

## Files

```
Package.swift            SwiftPM manifest
Sources/SibDocks/main.swift      everything
Assets/AppIcon.icns              native dock.rectangle bundle icon
Scripts/render_menu_icon.swift   regenerates the icon during builds
build.sh                         assembles and signs SibDocks.app
```
