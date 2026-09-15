# SibDocks

A dock per display. Each screen gets its own strip showing only the windows
currently on that screen; clicking an icon raises that window.

macOS gives you one Dock that follows the active display and lists *apps*.
SibDocks gives you one strip per display that lists *windows*, and only the
ones living on that display.

Whichever display the real Dock is currently on does not get a SibDocks
strip. That screen already has a dock. When you move the real Dock to another
display, the strips rearrange themselves to match.

## Requirements

- macOS 26 or later, for the Liquid Glass material (developed on macOS 27)
- Swift 6 toolchain (Xcode Command Line Tools is enough)
- Accessibility permission

## Build and run

```sh
./build.sh          # produces SibDocks.app
open SibDocks.app   # prompts for Accessibility, then quits
open SibDocks.app   # again, after granting
```

The first launch asks for Accessibility in System Settings → Privacy &
Security → Accessibility, then exits. Grant it and open the app again.

**Every rebuild costs you that grant.** Ad-hoc signing ties the Accessibility
permission to the binary's cdhash, so a rebuilt binary is a different binary as
far as TCC is concerned, and it gets denied with no prompt. `build.sh` runs
`tccutil reset Accessibility local.sibdocks` to clear the stale entry, so the
next launch asks again rather than quitting silently. Sign with a stable
self-signed certificate instead if the re-approval gets tiresome.
It runs as an `LSUIElement` agent: no Dock icon, no app menu. Quitting is
through the menu bar icon → **Quit SibDocks**, or from a terminal:

```sh
pkill -x SibDocks
```

## Minimized windows

Minimizing works exactly as macOS intends: the window goes to the system Dock.
SibDocks keeps a dimmed tile for it on the strip belonging to the screen it came
from, and clicking that tile brings the window back **onto that screen**.

That last part is the point of a per-screen dock. The tile you click decides
where the window lands, so a window minimized from one display and restored from
another display's strip moves there, keeping its offset within the screen. A
window already on the right screen is simply un-minimized where it sits.

The move is issued before clearing `AXMinimized`, because AX position on a
minimized window sets the frame it will restore to. Setting it afterwards would
race the restore animation.

Windows belonging to hidden apps (⌘H) get the same dimmed treatment, and
clicking unhides the app.

Note that the display hosting the real Dock has no strip, so windows minimized
there are reachable only from the system Dock.

## Appearance

The strips track System Settings → Desktop & Dock. `com.apple.dock` is read on
every tick, so a change shows up within a second:

| Setting | Key | Effect |
| --- | --- | --- |
| Size | `tilesize` | Icon size, and every derived measurement below |
| Magnification | `magnification`, `largesize` | Hover magnification with the same falloff curve |
| Position on screen | `orientation` | Strip sits along the bottom, left, or right edge |

The background is `NSGlassEffectView`, the same Liquid Glass material the
system Dock uses on macOS 26 and later, so light and dark mode come for free.

Padding, gaps, and corner radius are ratios of `tilesize`, calibrated against
the stock Dock: at `tilesize 42` the real Dock claims a 62pt screen inset, and
so does SibDocks (8 pad + 42 tile + 8 pad + 4 margin). They are grouped in
`DockStyle` if a future macOS restyles the Dock and they need re-tuning.

## How it works

1. Every second, each regular running app is asked via Accessibility for its
   `AXWindows`, keeping those with the `AXStandardWindow` subrole or a minimize
   button. Each window is held as its `AXUIElement`, along with its title,
   frame, and whether it is minimized or its app is hidden.
2. Each window's center is converted from CoreGraphics global coordinates
   (origin top-left of the primary display, y down) to Cocoa coordinates
   (origin bottom-left, y up) and matched against `NSScreen.frame`.
3. The display hosting the real macOS Dock is skipped. The Dock draws one
   window at the dock window level spanning exactly the display it lives on,
   so that window's bounds identify the display to leave alone.
4. One borderless non-activating `NSPanel` per remaining display renders that
   screen's windows as app icons on a glass strip along the configured edge.
   A panel with no windows hides itself.
5. A global mouse monitor drives magnification and toggles
   `ignoresMouseEvents`, so each panel swallows clicks on the strip and its
   icons but stays click-through over the transparent headroom that magnified
   icons need. Tracking areas would not work here, since a click-through panel
   does not receive its own events.
6. Clicking an icon moves the window onto that strip's screen, unhides the app,
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

Asserts that the coordinate flip is its own inverse and that live windows
resolve to real screens, then prints the screen → window mapping:

```
layout ok (bottom/left/right, magnified + resting)
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

- **One second of lag.** State comes from a poll, not from AX notifications.
  Marked `ponytail:` in the source. Swap in observers if the poll ever shows
  up in Activity Monitor.
- **One button per window, no grouping.** With enough windows open the strip
  runs off the edge of the screen. Group by app when that starts to bite.
- **Raise only.** No minimize, close, or quit from the strip.
- **Three Dock settings, not all of them.** Size, magnification, and position
  are tracked. Auto-hide, minimise effects, running-app indicators, and the
  recents section are not.
- **Magnification is an approximation.** Each tile is scaled from its resting
  centre and the magnified widths are then laid out cumulatively. The real Dock
  solves position and width together. Close, not identical.
- **Auto-hide defeats the Dock check.** A hidden Dock has no on-screen window
  to find, so that display gets a SibDocks strip too and the two overlap when
  the real Dock slides up. Fine if you do not use auto-hide.
- **No fullscreen handling.** The panel is `fullScreenAuxiliary`, so it floats
  over fullscreen windows rather than hiding.
- **Minimized windows live in the system Dock, not on the strip.** They appear
  in both places: a real Dock tile and a dimmed SibDocks tile. Removing them
  from the system Dock is not possible with public APIs.
- **Other Spaces are not filtered.** A window on another Space is neither
  minimized nor hidden, so it appears on its screen's strip as a normal tile.

## Files

```
Package.swift            SwiftPM manifest
Sources/SibDocks/main.swift   everything
build.sh                 assembles and signs SibDocks.app
```
