import AppKit
import ApplicationServices
import ServiceManagement

// MARK: - Window enumeration

/// One real window. Backed by its AXUIElement, which stays valid while the
/// window lives, so clicks act on the window directly with no matching step.
/// Accessibility is also the only API that distinguishes a minimized window
/// from one sitting on another Space -- CGWindowList reports both as offscreen.
struct WinInfo {
    /// AXUIElement identity is stable for the lifetime of a window.  A title
    /// is not: documents can be renamed, and several windows can share one.
    let id: WindowID
    let element: AXUIElement
    let pid: pid_t
    let title: String
    let frame: CGRect  // CoreGraphics global coords: origin top-left of primary screen, y down
    /// The last display on which the window was actually visible. A minimized
    /// window's AX frame is not consistently reported by every application.
    let displayID: CGDirectDisplayID?
    /// Minimized, or its app is hidden. Not visible on any screen right now.
    let stowed: Bool
}

struct WindowID: Hashable {
    let pid: pid_t
    let axHash: CFHashCode
}

extension WinInfo: Equatable {
    static func == (a: WinInfo, b: WinInfo) -> Bool {
        a.id == b.id && a.frame == b.frame && a.displayID == b.displayID
            && a.stowed == b.stowed && a.title == b.title
    }
}

struct WindowLocation {
    let element: AXUIElement
    var frame: CGRect
    var displayID: CGDirectDisplayID?
    var order: Int
    var lastSeen: Date
}

func axValue(_ el: AXUIElement, _ key: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, key as CFString, &v) == .success ? v : nil
}

func axFrame(_ el: AXUIElement) -> CGRect? {
    guard let pv = axValue(el, kAXPositionAttribute), let sv = axValue(el, kAXSizeAttribute)
    else { return nil }
    var p = CGPoint.zero, s = CGSize.zero
    AXValueGetValue(pv as! AXValue, .cgPoint, &p)
    AXValueGetValue(sv as! AXValue, .cgSize, &s)
    return CGRect(origin: p, size: s)
}

// MARK: - Moving windows

@discardableResult
func setAXPosition(_ el: AXUIElement, _ p: CGPoint) -> Bool {
    var p = p
    guard let v = AXValueCreate(.cgPoint, &p) else { return false }
    return AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, v) == .success
}

@discardableResult
func setAXSize(_ el: AXUIElement, _ size: CGSize) -> Bool {
    var size = size
    guard let v = AXValueCreate(.cgSize, &size) else { return false }
    return AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, v) == .success
}

func primaryScreen() -> NSScreen? {
    let mainDisplay = CGMainDisplayID()
    return NSScreen.screens.first(where: { $0.displayID == mainDisplay })
        ?? NSScreen.screens.first
}

/// Convert an NSScreen frame from Cocoa coordinates to the Quartz coordinates
/// used by Accessibility, so it can be compared with AX window frames.
func cgFrame(of screen: NSScreen) -> CGRect {
    let primaryTop = primaryScreen()?.frame.maxY ?? 0
    let f = screen.frame
    return CGRect(x: f.minX, y: primaryTop - f.maxY, width: f.width, height: f.height)
}

/// Puts a window on `screen`, keeping its offset within whatever screen it was
/// on and nudging it back inside if it would hang off the edge. No-op when the
/// window is already there.
@MainActor func move(_ element: AXUIElement, frame knownFrame: CGRect? = nil,
                     from sourceScreen: NSScreen? = nil, onto screen: NSScreen) {
    guard let frame = axFrame(element) ?? knownFrame else { return }
    let fromScreen = sourceScreen ?? screenContaining(frame)
    guard fromScreen?.displayID != screen.displayID else { return }
    let to = cgFrame(of: screen)
    let from = fromScreen.map(cgFrame(of:)) ?? to
    let x = to.minX + (frame.minX - from.minX)
    let y = to.minY + (frame.minY - from.minY)
    setAXPosition(element, CGPoint(
        x: min(max(x, to.minX), max(to.minX, to.maxX - frame.width)),
        y: min(max(y, to.minY), max(to.minY, to.maxY - frame.height))))
}

@MainActor func listWindows(using locations: inout [WindowID: WindowLocation]) -> [WinInfo] {
    var out: [WinInfo] = []
    let now = Date()
    var nextOrder = locations.values.map(\.order).max().map { $0 + 1 } ?? 0
    for app in NSWorkspace.shared.runningApplications
    where app.activationPolicy == .regular {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // A wedged app must not stall the tick.
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        guard let windows = axValue(axApp, kAXWindowsAttribute) as? [AXUIElement] else { continue }

        for w in windows {
            // Outlook and Calendar report their main window as AXDialog, so
            // filtering on AXStandardWindow alone drops real windows. Having a
            // minimize button is the honest test of "a window this dock should
            // manage", and it also excludes Finder's desktop window, which has
            // no subrole at all.
            guard axValue(w, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole
                    || axValue(w, kAXMinimizeButtonAttribute) != nil
            else { continue }
            let minimized = axValue(w, kAXMinimizedAttribute) as? Bool ?? false
            let hidden = app.isHidden
            let id = WindowID(pid: app.processIdentifier, axHash: CFHash(w))
            let old = locations[id]
            let reportedFrame = axFrame(w)
            guard let visibleFrame = reportedFrame ?? old?.frame else { continue }
            locations[id]?.lastSeen = now
            let currentDisplay = reportedFrame.flatMap { screenContaining($0)?.displayID }
            // Some apps expose the minimized frame at the Dock's location and
            // others expose the old frame. Never let that transient value move
            // a stowed tile to the wrong display.
            let displayID = (minimized || hidden) ? (old?.displayID ?? currentDisplay) : currentDisplay
            if !minimized && !hidden {
                if old == nil {
                    locations[id] = WindowLocation(element: w, frame: visibleFrame,
                                                   displayID: currentDisplay, order: nextOrder,
                                                   lastSeen: now)
                    nextOrder += 1
                } else {
                    locations[id]?.frame = visibleFrame
                    locations[id]?.displayID = currentDisplay
                }
            } else if old == nil {
                locations[id] = WindowLocation(element: w, frame: visibleFrame,
                                               displayID: displayID, order: nextOrder,
                                               lastSeen: now)
                nextOrder += 1
            }
            out.append(WinInfo(
                id: id,
                element: w,
                pid: app.processIdentifier,
                title: axValue(w, kAXTitleAttribute) as? String ?? app.localizedName ?? "",
                frame: (minimized || hidden) ? (old?.frame ?? visibleFrame) : visibleFrame,
                displayID: displayID,
                stowed: minimized || hidden))
        }
    }
    // A few applications report the same AX window more than once.
    var seen = Set<WindowID>()
    return out.filter { seen.insert($0.id).inserted }
        .sorted { (locations[$0.id]?.order ?? .max) < (locations[$1.id]?.order ?? .max) }
}

@MainActor func listWindows() -> [WinInfo] {
    var locations: [WindowID: WindowLocation] = [:]
    return listWindows(using: &locations)
}

/// CG global point (y down, from primary top) -> Cocoa global point (y up, from primary bottom).
func cocoaPoint(_ p: CGPoint) -> CGPoint {
    let primaryTop = primaryScreen()?.frame.maxY ?? 0
    return CGPoint(x: p.x, y: primaryTop - p.y)
}

func screenContaining(_ cgRect: CGRect) -> NSScreen? {
    let c = cocoaPoint(CGPoint(x: cgRect.midX, y: cgRect.midY))
    return NSScreen.screens.first { $0.frame.contains(c) }
}

func screenOf(_ w: WinInfo) -> NSScreen? {
    if let id = w.displayID, let screen = NSScreen.screens.first(where: { $0.displayID == id }) {
        return screen
    }
    return screenContaining(w.frame)
}

/// Display currently hosting the real macOS Dock, which draws one window at
/// the dock level spanning exactly that display. Follows the Dock as it moves.
/// Returns nil while the Dock is auto-hidden -- that window goes off-screen.
func realDockScreen() -> CGDirectDisplayID? {
    let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
    guard let raw = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly], kCGNullWindowID
    ) as? [[String: Any]] else { return nil }

    for d in raw where d[kCGWindowLayer as String] as? Int == dockLevel {
        guard d[kCGWindowOwnerName as String] as? String == "Dock",
              let bd = d[kCGWindowBounds as String],
              let bounds = bd as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds),
              let id = NSScreen.screens.first(where: { screen in
                  guard let displayID = screen.displayID else { return false }
                  // Window bounds and CGDisplayBounds share Quartz's global
                  // top-left coordinate system. Avoid the Cocoa/Quartz flip
                  // used for AX window mapping, which can misidentify the
                  // Dock during a display handoff.
                  return CGDisplayBounds(displayID).contains(
                      CGPoint(x: rect.midX, y: rect.midY))
              })?.displayID
        else { continue }
        return id
    }
    return nil
}

// MARK: - Raising

/// Brings a window back on the screen whose strip was clicked, which is the
/// point of a per-screen dock: the tile you click decides where the window
/// lands. The move happens before un-minimizing, because AX position on a
/// minimized window sets the frame it will restore to -- setting it afterwards
/// would race the restore animation.
@MainActor func raise(_ w: WinInfo, onto screen: NSScreen) {
    let app = NSRunningApplication(processIdentifier: w.pid)
    app?.unhide()
    move(w.element, frame: w.frame, from: screenOf(w), onto: screen)
    AXUIElementSetAttributeValue(w.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    AXUIElementSetAttributeValue(w.element, kAXMainAttribute as CFString, kCFBooleanTrue)
    AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
    app?.activate()
}

// MARK: - System Dock appearance

enum DockEdge: String { case bottom, left, right }

/// Mirrors whatever the user has set in System Settings -> Desktop & Dock.
/// Read fresh each tick, so changes land within a second without any
/// notification plumbing.
struct DockStyle: Equatable {
    var tile: CGFloat = 48
    var large: CGFloat = 128
    var magnify = false
    var edge: DockEdge = .bottom
    var autoHide = false
    var autoHideDelay: TimeInterval = 0.15
    var animationDuration: TimeInterval = 0.18
    var showIndicators = true
    var minimizeEffect = "genie"

    // Ratios calibrated against the stock Dock. The indicator has its own
    // visual lane; it must not make the configured icon smaller.
    var pad: CGFloat { round(tile * 0.19) }
    var gap: CGFloat { round(tile * 0.12) }
    var margin: CGFloat { round(tile * 0.10) }
    func indicatorLane(for iconSize: CGFloat) -> CGFloat {
        showIndicators ? max(4, min(8, iconSize * 0.14)) : 0
    }
    var thickness: CGFloat { tile + indicatorLane(for: tile) + 2 * pad }
    var radius: CGFloat { thickness / 2 }
    var maxScale: CGFloat { magnify ? max(1, large / tile) : 1 }
    var isVertical: Bool { edge != .bottom }

    /// The expanded panel depth, including room for magnified icons to spill
    /// beyond the resting glass.
    var expandedDepth: CGFloat {
        let largestIcon = tile * maxScale
        return max(thickness,
                   pad + largestIcon + indicatorLane(for: largestIcon) + pad)
    }

    static func current() -> DockStyle {
        let d = UserDefaults(suiteName: "com.apple.dock")
        func num(_ key: String, _ fallback: CGFloat) -> CGFloat {
            if let value = d?.object(forKey: key) as? NSNumber {
                return CGFloat(truncating: value)
            }
            return fallback
        }
        func flag(_ key: String, _ fallback: Bool) -> Bool {
            (d?.object(forKey: key) as? NSNumber)?.boolValue ?? fallback
        }
        let tile = min(max(num("tilesize", 48), 16), 256)
        let large = min(max(num("largesize", 128), tile), 512)
        let delay = min(max(num("autohide-delay", 0.15), 0), 2)
        return DockStyle(
            tile: tile,
            large: large,
            magnify: flag("magnification", false),
            edge: DockEdge(rawValue: d?.string(forKey: "orientation") ?? "") ?? .bottom,
            autoHide: flag("autohide", false),
            autoHideDelay: TimeInterval(delay),
            animationDuration: 0.18,
            showIndicators: flag("show-process-indicators", true),
            minimizeEffect: d?.string(forKey: "mineffect") ?? "genie",
            // Dock's exact animation curve is private. This duration tracks
            // its short settle animation and is used consistently for hover,
            // reveal, and preference changes.
        )
    }
}

// MARK: - Dock UI

final class WinButton: NSButton {
    var win: WinInfo!
    var icon: NSImage?
    var indicatorEdge: DockEdge = .bottom
    var showsIndicator = true

    /// Use a known coordinate system: y grows down, so the indicator lane for
    /// a bottom dock is always the physical bottom of the tile.
    override var isFlipped: Bool { true }

    private var indicatorLane: CGFloat {
        guard showsIndicator else { return 0 }
        return max(4, min(8, min(bounds.width, bounds.height) * 0.14))
    }

    private func iconRect(in bounds: NSRect) -> NSRect {
        var rect = bounds
        let lane = indicatorLane
        guard lane > 0 else { return rect }
        switch indicatorEdge {
        case .bottom:
            rect.size.height = max(1, rect.height - lane)
        case .left:
            rect.size.width = max(1, rect.width - lane)
        case .right:
            rect.origin.x += lane
            rect.size.width = max(1, rect.width - lane)
        }
        return rect
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if let icon {
            icon.draw(in: iconRect(in: bounds), from: .zero, operation: .sourceOver,
                      fraction: 1, respectFlipped: true, hints: nil)
        }
        guard showsIndicator, win != nil else { return }
        let diameter = max(2, min(4, bounds.width * 0.07))
        let rect: NSRect
        switch indicatorEdge {
        case .bottom:
            rect = NSRect(x: bounds.midX - diameter / 2, y: bounds.maxY - diameter - 1,
                          width: diameter, height: diameter)
        case .left:
            rect = NSRect(x: bounds.maxX - diameter - 1, y: bounds.midY - diameter / 2,
                          width: diameter, height: diameter)
        case .right:
            rect = NSRect(x: 1, y: bounds.midY - diameter / 2,
                          width: diameter, height: diameter)
        }
        NSColor.labelColor.withAlphaComponent(0.85).setFill()
        NSBezierPath(ovalIn: rect).fill()
    }

}

/// Glass strip plus the icon row. Icons are siblings of the glass view, not its
/// contentView: NSGlassEffectView only guarantees z-order for its contentView.
final class DockContentView: NSView {
    let glass = NSGlassEffectView()
    var style = DockStyle()
    /// Cursor position along the layout axis, in view coords. nil when away.
    var cursor: CGFloat?
    var layoutAnimationDuration: TimeInterval = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        glass.style = .regular
        addSubview(glass)
    }
    required init?(coder: NSCoder) { fatalError() }

    var tiles: [WinButton] { subviews.compactMap { $0 as? WinButton } }

    /// Rect a tile occupies given its offset along the edge and its magnified size.
    private func tileRect(offset: CGFloat, size: CGFloat) -> NSRect {
        let lane = style.indicatorLane(for: size)
        return switch style.edge {
        case .bottom: NSRect(x: offset, y: style.pad, width: size, height: size + lane)
        case .left:   NSRect(x: style.pad, y: bounds.height - offset - size,
                             width: size + lane, height: size)
        case .right:  NSRect(x: bounds.width - style.pad - size - lane,
                             y: bounds.height - offset - size, width: size + lane, height: size)
        }
    }

    override func layout() {
        super.layout()
        glass.cornerRadius = style.radius
        let t = style.thickness
        glass.frame = switch style.edge {
        case .bottom: NSRect(x: 0, y: 0, width: bounds.width, height: t)
        case .left:   NSRect(x: 0, y: 0, width: t, height: bounds.height)
        case .right:  NSRect(x: bounds.width - t, y: 0, width: t, height: bounds.height)
        }
        layoutTiles(animated: false)
    }

    func layoutTiles(animated: Bool = false) {
        let s = style, tiles = self.tiles
        guard !tiles.isEmpty else { return }
        let axis = s.isVertical ? bounds.height : bounds.width
        let reach = 2.5 * s.tile  // falloff spans ~2.5 tiles either side, like the Dock

        // Scale each tile from its *unmagnified* centre, then lay the magnified
        // widths out cumulatively. Cheap approximation of the Dock's curve;
        // exact would need solving position and width together.
        let base = CGFloat(tiles.count) * s.tile + CGFloat(tiles.count - 1) * s.gap
        var centre = (axis - base) / 2 + s.tile / 2
        var scales: [CGFloat] = []
        for _ in tiles {
            var k: CGFloat = 1
            if let c = cursor, s.maxScale > 1 {
                let d = abs(c - centre) / reach
                if d < 1 { k = 1 + (s.maxScale - 1) * cos(d * .pi / 2) }
            }
            scales.append(k)
            centre += s.tile + s.gap
        }

        var total = scales.reduce(0) { $0 + $1 * s.tile } + CGFloat(tiles.count - 1) * s.gap
        // A dock cannot grow past the display. Preserve every window, but
        // proportionally reduce the tile size when there is not enough room.
        // This is preferable to clipping the last windows or making the
        // panel extend onto a neighbouring display.
        let usable = max(1, axis - 2 * s.pad)
        let compression = min(1, (usable - CGFloat(max(0, tiles.count - 1)) * s.gap)
            / max(1, scales.reduce(0) { $0 + $1 * s.tile }))
        if compression < 1 {
            scales = scales.map { $0 * compression }
            total = scales.reduce(0) { $0 + $1 * s.tile } + CGFloat(tiles.count - 1) * s.gap
        }
        var offset = (axis - total) / 2
        for (tile, k) in zip(tiles, scales) {
            let size = s.tile * k
            let frame = tileRect(offset: offset, size: size)
            if animated && layoutAnimationDuration > 0 {
                tile.animator().frame = frame
            } else {
                tile.frame = frame
            }
            offset += size + s.gap
        }
    }

}

/// Convert between the Quartz coordinates used by Accessibility and the
/// Cocoa coordinates used by NSScreen.visibleFrame.
func cocoaRect(fromCG rect: CGRect) -> NSRect {
    let top = primaryScreen()?.frame.maxY ?? 0
    return NSRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
}

func cgRect(fromCocoa rect: NSRect) -> CGRect {
    let top = primaryScreen()?.frame.maxY ?? 0
    return CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
}

/// The portion of a display available to ordinary windows when SibDocks is
/// acting as a fixed Dock. visibleFrame already excludes the menu bar and the
/// real Dock; this adds SibDocks' own edge reservation on displays where it
/// is present.
func sibDocksUsableFrame(on screen: NSScreen, style: DockStyle) -> NSRect {
    var usable = screen.visibleFrame
    let screenFrame = screen.frame
    // Magnified icons are an interactive spill area. The permanent
    // reservation follows the dock's resting glass footprint; the expanded
    // hover state may temporarily overlay that extra headroom just like the
    // system Dock does.
    let reserved = style.margin + style.thickness

    switch style.edge {
    case .bottom:
        let minY = min(max(usable.minY, screenFrame.minY + reserved), usable.maxY)
        usable = NSRect(x: usable.minX, y: minY, width: usable.width,
                        height: max(0, usable.maxY - minY))
    case .left:
        let minX = min(max(usable.minX, screenFrame.minX + reserved), usable.maxX)
        usable = NSRect(x: minX, y: usable.minY,
                        width: max(0, usable.maxX - minX), height: usable.height)
    case .right:
        let maxX = min(max(usable.minX, screenFrame.maxX - reserved), usable.maxX)
        usable = NSRect(x: usable.minX, y: usable.minY,
                        width: max(0, maxX - usable.minX), height: usable.height)
    }
    return usable
}

/// Keeps a visible application window out of the SibDocks footprint. The
/// window is moved when it fits and resized first when it is larger than the
/// remaining usable area, matching the practical effect of a fixed system
/// Dock on zoomed windows.
@MainActor
@discardableResult
func keepWindowOutOfSibDocks(_ window: WinInfo, on screen: NSScreen,
                             style: DockStyle) -> CGRect? {
    guard !window.stowed else { return nil }
    let usable = sibDocksUsableFrame(on: screen, style: style)
    let current = cocoaRect(fromCG: window.frame)
    // A window has to cross the display boundary before its centre is
    // reported on the destination display. During that transition its frame
    // is outside the source display (and may be in the gap between displays).
    // Do not clamp or resize it back to the source display, or dragging
    // between displays becomes impossible. This also leaves intentionally
    // spanning windows alone.
    guard screen.frame.contains(current) else { return nil }
    guard !usable.contains(current) else { return nil }

    let width = min(current.width, usable.width)
    let height = min(current.height, usable.height)
    let target = NSRect(
        x: min(max(current.minX, usable.minX), max(usable.minX, usable.maxX - width)),
        y: min(max(current.minY, usable.minY), max(usable.minY, usable.maxY - height)),
        width: width,
        height: height)
    let targetCG = cgRect(fromCocoa: target)

    let needsSizeChange = abs(target.width - current.width) > 0.5
        || abs(target.height - current.height) > 0.5
    let needsPositionChange = abs(target.minX - current.minX) > 0.5
        || abs(target.minY - current.minY) > 0.5
    let sizeChanged = !needsSizeChange || setAXSize(window.element, target.size)
    let positionChanged = !needsPositionChange || setAXPosition(window.element, targetCG.origin)
    // Do not replace the cached restore frame when the app rejects either AX
    // write; the existing frame is safer than a target that was never applied.
    guard sizeChanged && positionChanged else { return nil }
    return targetCG
}

final class DockPanel: NSPanel {
    private var shown: [WinInfo] = []
    private var shownStyle: DockStyle?
    private var shownScreenID: CGDirectDisplayID?
    private var shownScreenFrame: NSRect = .zero
    private var shownSystemDockSuppressed = false
    /// The display this strip belongs to; clicking a tile sends the window here.
    private var homeScreen: NSScreen?
    private var hideWorkItem: DispatchWorkItem?
    private var body: DockContentView { contentView as! DockContentView }
    var stateDidChange: (() -> Void)?

    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        // Match the system Dock's window-server level. The typed `.dock`
        // constant is deprecated even though the underlying level remains
        // the correct one, so use the current CoreGraphics value directly.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false  // the glass carries its own
        // The system Dock does not cover another app's true full-screen Space.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        contentView = DockContentView()
    }

    func update(_ wins: [WinInfo], style: DockStyle, on screen: NSScreen,
                systemDockIsPresent: Bool = false) {
        guard wins != shown || style != shownStyle
                || screen.displayID != shownScreenID
                || screen.frame != shownScreenFrame
                || systemDockIsPresent != shownSystemDockSuppressed else { return }
        shown = wins
        shownStyle = style
        shownScreenID = screen.displayID
        shownScreenFrame = screen.frame
        shownSystemDockSuppressed = systemDockIsPresent
        homeScreen = screen
        body.style = style
        body.layoutAnimationDuration = style.animationDuration
        // update() always lays out a fresh resting frame. A hover state from
        // the previous frame would otherwise magnify into the compact bounds
        // after a display reconfiguration or Dock handoff.
        body.cursor = nil

        hideWorkItem?.cancel()
        // Nothing to point at: no tiles on this display, or the real Dock is here.
        guard !systemDockIsPresent, !wins.isEmpty else {
            body.tiles.forEach { $0.removeFromSuperview() }
            alphaValue = 1
            orderOut(nil)
            return
        }

        body.tiles.forEach { $0.removeFromSuperview() }
        for w in wins {
            let b = WinButton()
            b.win = w
            b.isBordered = false
            b.bezelStyle = .regularSquare
            b.imagePosition = .imageOnly
            b.imageScaling = .scaleProportionallyUpOrDown
            b.icon = NSRunningApplication(processIdentifier: w.pid)?.icon
            b.image = nil
            b.toolTip = w.title
            b.alphaValue = w.stowed ? 0.45 : 1
            b.indicatorEdge = style.edge
            b.showsIndicator = style.showIndicators
            b.target = self
            b.action = #selector(click(_:))
            b.menu = nativeContextMenu(for: b)
            body.addSubview(b)
        }

        // At rest the panel is only as deep and long as the visible glass.
        // Magnification expands it temporarily from hover().
        let depth = style.thickness
        let n = CGFloat(wins.count)
        let length = n * style.tile + (n - 1) * style.gap + 2 * style.pad
        let frame = frame(on: screen, style: style, length: length, depth: depth)
        setFrame(frame, display: true)
        body.needsLayout = true
        if style.autoHide && !nearEdge(NSEvent.mouseLocation) {
            orderOut(nil)
        } else {
            reveal(animated: false)
        }
    }

    /// Follow the cursor for magnification while the visible dock panel keeps
    /// mouse events enabled for reliable primary and secondary clicks.
    func hover(_ screenPoint: NSPoint) {
        guard !shown.isEmpty else { return }
        if body.style.autoHide {
            if nearEdge(screenPoint) {
                hideWorkItem?.cancel()
                reveal(animated: true)
            } else {
                scheduleHide()
                return
            }
        } else if !isVisible {
            reveal(animated: true)
        }
        let p = body.convert(convertPoint(fromScreen: screenPoint), from: nil)
        let inside = NSPointInRect(p, body.bounds)
        let cursor: CGFloat? = inside ? (body.style.isVertical ? p.y : p.x) : nil
        let wasExpanded = body.cursor != nil && body.style.magnify
        let changed: Bool
        if let old = body.cursor, let cursor {
            changed = abs(old - cursor) > 0.5
        } else {
            changed = body.cursor != cursor
        }
        body.cursor = cursor
        let isExpanded = cursor != nil && body.style.magnify
        if isExpanded != wasExpanded {
            resizeForHover(expanded: isExpanded)
        }
        if changed {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = body.style.animationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                body.layoutAnimationDuration = context.duration
                body.layoutTiles(animated: true)
            }
        }
    }

    private func nearEdge(_ point: NSPoint) -> Bool {
        guard let screen = homeScreen, screen.frame.contains(point) else { return false }
        let f = screen.frame
        let slop: CGFloat = 5
        switch body.style.edge {
        case .bottom: return point.y <= f.minY + slop
        case .left: return point.x <= f.minX + slop
        case .right: return point.x >= f.maxX - slop
        }
    }

    private func frame(on screen: NSScreen, style: DockStyle,
                       length: CGFloat, depth: CGFloat) -> NSRect {
        let f = screen.frame
        switch style.edge {
        case .bottom:
            return NSRect(x: f.midX - length / 2, y: f.minY + style.margin,
                          width: min(length, f.width), height: depth)
        case .left:
            return NSRect(x: f.minX + style.margin, y: f.midY - length / 2,
                          width: depth, height: min(length, f.height))
        case .right:
            return NSRect(x: f.maxX - style.margin - depth, y: f.midY - length / 2,
                          width: depth, height: min(length, f.height))
        }
    }

    private func resizeForHover(expanded: Bool) {
        guard let screen = homeScreen, !shown.isEmpty else { return }
        let scale = expanded ? body.style.maxScale : 1
        let count = CGFloat(shown.count)
        let length = count * body.style.tile * scale
            + (count - 1) * body.style.gap + 2 * body.style.pad
        let depth = expanded ? body.style.expandedDepth : body.style.thickness
        let target = frame(on: screen, style: body.style, length: length, depth: depth)
        setFrame(target, display: true, animate: true)
        body.needsLayout = true
    }

    private func reveal(animated: Bool) {
        hideWorkItem?.cancel()
        guard !isVisible else { return }
        alphaValue = 0
        orderFront(nil)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = body.style.animationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().alphaValue = 1
            }
        } else {
            alphaValue = 1
        }
    }

    private func scheduleHide() {
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isVisible else { return }
            self.orderOut(nil)
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + body.style.autoHideDelay, execute: work)
    }

    /// Use AppKit's native contextual-menu presentation for both tracking and
    /// rendering. The menu inherits the user's current system appearance, so
    /// it stays consistent with macOS instead of maintaining a second custom
    /// menu surface in SibDocks.
    private func nativeContextMenu(for button: WinButton) -> NSMenu {
        let app = NSRunningApplication(processIdentifier: button.win.pid)
        let menu = NSMenu()
        menu.autoenablesItems = false

        let showTitle = button.win.stowed ? "Open" : "Show"
        menu.addItem(nativeMenuItem(showTitle, #selector(menuShow(_:)), button))
        menu.addItem(nativeMenuItem("Show All Windows", #selector(menuShowAll(_:)), button,
                                   enabled: app != nil))
        menu.addItem(.separator())

        let options = NSMenu(title: "Options")
        options.addItem(nativeMenuItem("Show in Finder", #selector(menuShowInFinder(_:)), button,
                                       enabled: app?.bundleURL != nil))
        let optionsItem = NSMenuItem(title: "Options", action: nil, keyEquivalent: "")
        optionsItem.submenu = options
        menu.addItem(optionsItem)
        menu.addItem(.separator())

        menu.addItem(nativeMenuItem("Hide", #selector(menuHide(_:)), button,
                                   enabled: app != nil && !(app?.isHidden ?? true)))
        menu.addItem(nativeMenuItem("Quit", #selector(menuQuit(_:)), button, enabled: app != nil))
        return menu
    }

    private func nativeMenuItem(_ title: String, _ action: Selector, _ button: WinButton,
                                enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = button
        item.isEnabled = enabled
        return item
    }

    private func menuButton(_ item: NSMenuItem) -> WinButton? {
        item.representedObject as? WinButton
    }

    @objc private func menuShow(_ item: NSMenuItem) {
        guard let button = menuButton(item) else { return }
        contextShow(button)
    }

    @objc private func menuShowAll(_ item: NSMenuItem) {
        guard let button = menuButton(item) else { return }
        contextShowAll(button)
    }

    @objc private func menuShowInFinder(_ item: NSMenuItem) {
        guard let button = menuButton(item) else { return }
        contextShowInFinder(button)
    }

    @objc private func menuHide(_ item: NSMenuItem) {
        guard let button = menuButton(item) else { return }
        contextHide(button)
    }

    @objc private func menuQuit(_ item: NSMenuItem) {
        guard let button = menuButton(item) else { return }
        contextQuit(button)
    }

    private func contextShow(_ button: WinButton) {
        guard let homeScreen else { return }
        raise(button.win, onto: homeScreen)
    }

    private func contextShowAll(_ button: WinButton) {
        let app = NSRunningApplication(processIdentifier: button.win.pid)
        app?.unhide()
        for window in shown where window.pid == button.win.pid {
            AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString,
                                         kCFBooleanFalse)
            AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        }
        app?.activate()
    }

    private func contextShowInFinder(_ button: WinButton) {
        guard let url = NSRunningApplication(processIdentifier: button.win.pid)?.bundleURL
        else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func contextHide(_ button: WinButton) {
        NSRunningApplication(processIdentifier: button.win.pid)?.hide()
        stateDidChange?()
    }

    private func contextQuit(_ button: WinButton) {
        NSRunningApplication(processIdentifier: button.win.pid)?.terminate()
        stateDidChange?()
    }

    @objc private func click(_ sender: WinButton) {
        guard let homeScreen else { return }
        let wasStowed = sender.win.stowed
        raise(sender.win, onto: homeScreen)
        guard wasStowed else { return }

        // Let the restored window use the same short Dock-style departure
        // animation as the system Dock. The exact Genie shader is private, so
        // this is a geometry equivalent that collapses toward the configured
        // edge; Scale collapses toward the icon's center.
        let original = sender.frame
        let collapsed: NSRect
        if body.style.minimizeEffect == "scale" {
            collapsed = NSRect(x: original.midX, y: original.midY,
                               width: 1, height: 1)
        } else {
            switch body.style.edge {
            case .bottom:
                collapsed = NSRect(x: original.minX, y: 0, width: original.width, height: 1)
            case .left:
                collapsed = NSRect(x: body.bounds.minX, y: original.minY, width: 1, height: original.height)
            case .right:
                collapsed = NSRect(x: body.bounds.maxX, y: original.minY, width: 1, height: original.height)
            }
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = body.style.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            sender.animator().frame = collapsed
            sender.animator().alphaValue = 0
        }
    }
}

// MARK: - App

private func accessibilityCallback(observer: AXObserver, element: AXUIElement,
                                   notification: CFString,
                                   refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let controller = Unmanaged<Controller>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated {
        controller.scheduleTick()
    }
}

@MainActor final class Controller: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var docks: [CGDirectDisplayID: DockPanel] = [:]
    private var timer: Timer?
    private var dockOwnershipTimer: Timer?
    /// The last display known to host the real Dock. The Dock window can be
    /// absent while auto-hidden, so retain the last known host for that gap.
    private var lastDockHostScreen: CGDirectDisplayID?
    private var statusItem: NSStatusItem?  // also the only way to quit an LSUIElement app
    private var accessibilityItem: NSMenuItem?
    private var launchAtLoginItem: NSMenuItem?
    private var hoverMonitor: Any?
    private var observers: [pid_t: AXObserver] = [:]
    private var trustTimer: Timer?
    private var locations: [WindowID: WindowLocation] = [:]
    private var tickPending = false

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.applicationIconImage = runtimeIcon()
        installStatusItem()
        guard AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        ) else {
            // Rebuilding changes the binary's cdhash, which invalidates the
            // Accessibility grant, so this wait is a normal part of the dev
            // loop. Poll rather than quit, so approving is the only step.
            NSLog("SibDocks: waiting for Accessibility approval...")
            // Start the display surfaces even before permission is granted.
            // They remain empty until Accessibility becomes trusted, but this
            // makes the per-display dock visible and lets the app recover
            // without requiring another launch.
            updateAccessibilityMenuItem()
            start()
            trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, AXIsProcessTrusted() else { return }
                    self.trustTimer?.invalidate()
                    self.trustTimer = nil
                    self.updateAccessibilityMenuItem()
                    self.start()
                    self.tick()
                }
            }
            return
        }
        updateAccessibilityMenuItem()
        start()
    }

    private func installStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = menuIcon()
        item.button?.toolTip = "SibDocks"
        let menu = NSMenu()
        menu.delegate = self
        let accessibility = NSMenuItem(
            title: "Accessibility Access Required…",
            action: #selector(openAccessibilitySettings(_:)),
            keyEquivalent: ""
        )
        accessibility.target = self
        menu.addItem(accessibility)
        accessibilityItem = accessibility

        let launchAtLogin = NSMenuItem(
            title: "Start SibDocks at Login",
            action: #selector(toggleLaunchAtLogin(_:)),
            keyEquivalent: ""
        )
        launchAtLogin.target = self
        menu.addItem(launchAtLogin)
        launchAtLoginItem = launchAtLogin
        updateLaunchAtLoginMenuItem()
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit SibDocks",
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    private func start() {
        guard timer == nil else { return }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }

        // Global monitor rather than tracking areas: the panels are click-through
        // wherever the dock is not drawn, so they cannot rely on their own events.
        hoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let p = NSEvent.mouseLocation
                for dock in self.docks.values { dock.hover(p) }
            }
        }

        // Keep a low-frequency reconciliation pass for apps that do not emit
        // the AX notifications needed to describe minimization reliably.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Moving the real Dock between displays does not reliably emit a
        // screen-parameter notification. Check only its ownership frequently;
        // run the expensive Accessibility reconciliation when that ownership
        // actually changes.
        dockOwnershipTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let current = realDockScreen() ?? self.lastDockHostScreen
                guard current != self.lastDockHostScreen else { return }
                self.tick()
            }
        }
        tick()
    }

    private func updateAccessibilityMenuItem() {
        let trusted = AXIsProcessTrusted()
        accessibilityItem?.title = trusted
            ? "Accessibility Access Granted"
            : "Accessibility Access Required…"
        accessibilityItem?.isEnabled = !trusted
    }

    @objc private func openAccessibilitySettings(_ sender: NSMenuItem) {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ]
        for rawURL in urls {
            guard let url = URL(string: rawURL), NSWorkspace.shared.open(url) else { continue }
            return
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        updateLaunchAtLoginMenuItem()
    }

    private func updateLaunchAtLoginMenuItem() {
        launchAtLoginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            updateLaunchAtLoginMenuItem()
        } catch {
            updateLaunchAtLoginMenuItem()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn’t update Start at Login"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private func menuIcon() -> NSImage {
        let image = NSImage(systemSymbolName: "dock.rectangle",
                            accessibilityDescription: "SibDocks")!
        image.isTemplate = true
        return image
    }

    private func runtimeIcon() -> NSImage {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let image = NSImage(contentsOf: url)
        else { return menuIcon() }
        return image
    }

    func scheduleTick() {
        guard !tickPending else { return }
        tickPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.tickPending = false
            self.tick()
        }
    }

    func applicationWillTerminate(_: Notification) {
        if let hoverMonitor {
            NSEvent.removeMonitor(hoverMonitor)
        }
        timer?.invalidate()
        dockOwnershipTimer?.invalidate()
        trustTimer?.invalidate()
        for observer in observers.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observers.removeAll()
        docks.values.forEach { $0.orderOut(nil) }
    }

    private func updateAccessibilityObservers(for windows: [WinInfo]) {
        let pids = Set(windows.map(\.pid))
        for pid in Array(observers.keys) where !pids.contains(pid) {
            if let observer = observers.removeValue(forKey: pid) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            }
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for pid in pids where observers[pid] == nil {
            var observer: AXObserver?
            guard AXObserverCreate(pid, accessibilityCallback, &observer) == .success,
                  let observer else { continue }
            let appElement = AXUIElementCreateApplication(pid)
            for notification in [
                kAXWindowCreatedNotification,
                kAXUIElementDestroyedNotification,
                kAXApplicationHiddenNotification,
                kAXApplicationShownNotification
            ] {
                AXObserverAddNotification(observer, appElement, notification as CFString, refcon)
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            observers[pid] = observer
        }

        // Value changes are where most applications report AXMinimized. Add
        // the window-level observers after the app observer has been created.
        for window in windows {
            guard let observer = observers[window.pid] else { continue }
            let notifications: [String] = [
                kAXUIElementDestroyedNotification,
                kAXMovedNotification,
                kAXResizedNotification,
                kAXTitleChangedNotification,
                kAXValueChangedNotification
            ]
            for notification in notifications {
                AXObserverAddNotification(observer, window.element, notification as CFString, refcon)
            }
        }
    }

    private func tick() {
        // AX queries can wait for the per-application messaging timeout when
        // macOS has not granted Accessibility to this binary. Do not block
        // the main thread on every running app while waiting for approval:
        // render the display surfaces immediately and resume enumeration as
        // soon as the trust timer observes access.
        let wins = AXIsProcessTrusted()
            ? listWindows(using: &locations)
            : []
        updateAccessibilityObservers(for: wins)
        let liveIDs = Set(wins.map(\.id))
        let now = Date()
        // Keep a briefly missing app's last display so an AX timeout during a
        // minimize transition cannot strand its tile. Closed windows are
        // discarded after the grace period.
        locations = locations.filter {
            liveIDs.contains($0.key) || now.timeIntervalSince($0.value.lastSeen) < 30
        }

        var byScreen: [CGDirectDisplayID: [WinInfo]] = [:]
        for w in wins {
            guard let s = screenOf(w), let id = s.displayID else { continue }
            byScreen[id, default: []].append(w)
        }
        let style = DockStyle.current()
        // The display currently hosting the system Dock is left to it. Every
        // other display gets a SibDocks strip, including the primary display
        // after the system Dock moves to an extended display.
        let primaryID = primaryScreen()?.displayID
        let screenIDs = Set(NSScreen.screens.compactMap(\.displayID))
        let detectedDockHost = realDockScreen()
        let dockHost = detectedDockHost
            ?? (lastDockHostScreen.flatMap { screenIDs.contains($0) ? $0 : nil })
            ?? primaryID
        lastDockHostScreen = dockHost
        // Keep a panel alive while the real Dock visits its display. This
        // preserves the panel's state and lets the same panel be revealed as
        // soon as the real Dock leaves, instead of relying on reconstruction.
        let live = screenIDs.subtracting([dockHost].compactMap { $0 })
        for (id, dock) in Array(docks) where !live.contains(id) {
            dock.orderOut(nil); docks[id] = nil
        }

        // A third-party window cannot change NSScreen.visibleFrame the way
        // the private system Dock does. Enforce the same usable-area rule for
        // visible windows through the Accessibility permission SibDocks
        // already requires. Auto-hidden docks intentionally overlay content
        // only while revealed, like the system Dock, so they do not reserve a
        // permanent strip.
        // AX moved notifications arrive while the user is dragging a window.
        // Defer reservation writes until the drag ends; otherwise a transient
        // position at the edge can fight the user's drag gesture.
        if !style.autoHide && NSEvent.pressedMouseButtons == 0 {
            for screen in NSScreen.screens {
                guard let id = screen.displayID, live.contains(id),
                      let screenWindows = byScreen[id], !screenWindows.isEmpty
                else { continue }
                for window in screenWindows {
                    if let adjusted = keepWindowOutOfSibDocks(window, on: screen, style: style) {
                        locations[window.id]?.frame = adjusted
                    }
                }
            }
        }

        for screen in NSScreen.screens {
            guard let id = screen.displayID, live.contains(id) else { continue }
            let dock = docks[id] ?? {
                let d = DockPanel(); docks[id] = d; return d
            }()
            if dock.stateDidChange == nil {
                dock.stateDidChange = { [weak self] in self?.scheduleTick() }
            }
            dock.update(byScreen[id] ?? [], style: style, on: screen,
                        systemDockIsPresent: id == dockHost)
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

let app = NSApplication.shared

if CommandLine.arguments.contains("--selftest") {
    guard let mainScreen = primaryScreen() else {
        print("selftest requires an active WindowServer session")
        exit(2)
    }
    let primaryTop = mainScreen.frame.maxY
    for y in [0.0, 100.0, primaryTop] {  // CG<->Cocoa flip is its own inverse
        let p = CGPoint(x: 5, y: y)
        assert(cocoaPoint(cocoaPoint(p)) == p)
    }
    // Magnification layout: tiles must never overlap, the tile under the
    // cursor must be the biggest, and no cursor must mean no magnification.
    // Give vertical docks the same usable axis as the horizontal case. The
    // real panel compresses only when a display genuinely has too many tiles.
    let cv = DockContentView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
    for edge in [DockEdge.bottom, .left, .right] {
        cv.style = DockStyle(tile: 42, large: 72, magnify: true, edge: edge)
        cv.subviews.compactMap { $0 as? WinButton }.forEach { $0.removeFromSuperview() }
        for _ in 0..<6 { cv.addSubview(WinButton()) }

        let axisMid: CGFloat = 300
        cv.cursor = axisMid
        cv.layoutTiles()
        let rects = cv.tiles.map(\.frame)
        let along: (NSRect) -> CGFloat = { cv.style.isVertical ? $0.midY : $0.midX }
        let extent: (NSRect) -> CGFloat = { cv.style.isVertical ? $0.height : $0.width }
        for (a, b) in zip(rects, rects.dropFirst()) {
            let gap = abs(along(b) - along(a)) - (extent(a) + extent(b)) / 2
            assert(gap > -0.01, "magnified tiles overlap on \(edge)")
        }
        let widest = rects.map(extent).max()!
        let nearest = rects.min { abs(along($0) - axisMid) < abs(along($1) - axisMid) }!
        assert(extent(nearest) == widest, "cursor tile is not the largest on \(edge)")
        assert(widest <= 72.01, "magnified past largesize on \(edge)")

        cv.cursor = nil
        cv.layoutTiles()
        assert(cv.tiles.allSatisfy { abs(extent($0.frame) - 42) < 0.01 },
               "tiles magnified with no cursor on \(edge)")
    }
    print("layout ok (bottom/left/right, magnified + resting)")

    // Reservation geometry: every fixed edge must leave the resting panel
    // footprint outside the area available to application windows.
    for edge in [DockEdge.bottom, .left, .right] {
        let style = DockStyle(tile: 42, large: 72, magnify: true, edge: edge)
        let usable = sibDocksUsableFrame(on: mainScreen, style: style)
        let f = mainScreen.frame
        let reserved = style.margin + style.thickness
        switch edge {
        case .bottom:
            assert(usable.minY >= f.minY + reserved - 0.01,
                   "bottom Dock footprint is not reserved")
        case .left:
            assert(usable.minX >= f.minX + reserved - 0.01,
                   "left Dock footprint is not reserved")
        case .right:
            assert(usable.maxX <= f.maxX - reserved + 0.01,
                   "right Dock footprint is not reserved")
        }
    }
    print("reservation geometry ok (bottom/left/right)")

    if CommandLine.arguments.contains("--dump") {
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(axApp, 0.25)
            var v: CFTypeRef?
            let t0 = Date()
            let err = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &v)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            let ws = v as? [AXUIElement]
            print("\(app.localizedName ?? "?") hidden=\(app.isHidden) err=\(err.rawValue) "
                + "windows=\(ws?.count ?? -1) in \(ms)ms")
            for w in ws ?? [] {
                print("    sub=\(axValue(w, kAXSubroleAttribute) as? String ?? "nil")"
                    + " min=\(axValue(w, kAXMinimizedAttribute) as? Bool ?? false)"
                    + " frame=\(axFrame(w).map(String.init(describing:)) ?? "nil")"
                    + " minBtn=\(axValue(w, kAXMinimizeButtonAttribute) != nil)"
                    + " title=\((axValue(w, kAXTitleAttribute) as? String ?? "-").prefix(36))")
            }
        }
        exit(0)
    }

    // Exercises exactly what clicking a tile does, since a synthetic click
    // would need Accessibility for this process too.
    if let i = CommandLine.arguments.firstIndex(of: "--restore"),
       let name = CommandLine.arguments.dropFirst(i + 1).first {
        let onDockScreen = realDockScreen()
        guard let target = NSScreen.screens.first(where: { $0.displayID != onDockScreen })
        else { print("every screen has the real Dock"); exit(1) }
        guard let w = listWindows().first(where: {
            NSRunningApplication(processIdentifier: $0.pid)?.localizedName == name
        }) else { print("no window for \(name)"); exit(1) }
        print("before: frame=\(w.frame) stowed=\(w.stowed) screen=\(screenOf(w)?.localizedName ?? "none")")
        raise(w, onto: target)
        usleep(800_000)
        let now = listWindows().first { CFEqual($0.element, w.element) }
        print("after:  frame=\(now?.frame.debugDescription ?? "gone") "
            + "stowed=\(now?.stowed ?? false) screen=\(now.flatMap(screenOf)?.localizedName ?? "none")")
        print("target was \(target.localizedName)")
        exit(0)
    }

    // Window enumeration is Accessibility-only now, so an untrusted binary sees
    // nothing. Run this from SibDocks.app, not from .build.
    print("accessibility trusted: \(AXIsProcessTrusted())")

    let wins = listWindows()
    var unmatched = 0
    for w in wins {
        if let s = screenOf(w) {
            print("[\(s.localizedName)]\(w.stowed ? " (stowed)" : "") \(w.title)")
        }
        else { unmatched += 1; print("[unmatched] \(w.title) \(w.frame)") }
    }
    assert(wins.isEmpty || unmatched < wins.count, "no window mapped to a screen -- coord flip is wrong")
    let taken = realDockScreen()
    let style = DockStyle.current()
    print("style: \(style)")
    print("real Dock on: " + (NSScreen.screens.first { $0.displayID == taken }?.localizedName ?? "none (auto-hidden?)"))
    print("\(wins.count) windows, \(unmatched) unmatched, \(NSScreen.screens.count) screen(s)")
    exit(0)
}

let controller = Controller()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
