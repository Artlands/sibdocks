import AppKit
import ApplicationServices

// MARK: - Window enumeration

/// One real window. Backed by its AXUIElement, which stays valid while the
/// window lives, so clicks act on the window directly with no matching step.
/// Accessibility is also the only API that distinguishes a minimized window
/// from one sitting on another Space -- CGWindowList reports both as offscreen.
struct WinInfo {
    let element: AXUIElement
    let pid: pid_t
    let title: String
    let frame: CGRect  // CoreGraphics global coords: origin top-left of primary screen, y down
    /// Minimized, or its app is hidden. Not visible on any screen right now.
    let stowed: Bool
}

extension WinInfo: Equatable {
    static func == (a: WinInfo, b: WinInfo) -> Bool {
        CFEqual(a.element, b.element) && a.frame == b.frame
            && a.stowed == b.stowed && a.title == b.title
    }
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

func setAXPosition(_ el: AXUIElement, _ p: CGPoint) {
    var p = p
    guard let v = AXValueCreate(.cgPoint, &p) else { return }
    AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, v)
}

/// NSScreen.frame in CoreGraphics coords, so it can be compared with window
/// frames without flipping every value at the call site.
func cgFrame(of screen: NSScreen) -> CGRect {
    let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
    let f = screen.frame
    return CGRect(x: f.minX, y: primaryTop - f.maxY, width: f.width, height: f.height)
}

/// Puts a window on `screen`, keeping its offset within whatever screen it was
/// on and nudging it back inside if it would hang off the edge. No-op when the
/// window is already there.
@MainActor func move(_ element: AXUIElement, onto screen: NSScreen) {
    guard let frame = axFrame(element),
          screenContaining(frame)?.displayID != screen.displayID
    else { return }
    let to = cgFrame(of: screen)
    let from = screenContaining(frame).map(cgFrame(of:)) ?? to
    let x = to.minX + (frame.minX - from.minX)
    let y = to.minY + (frame.minY - from.minY)
    setAXPosition(element, CGPoint(
        x: min(max(x, to.minX), max(to.minX, to.maxX - frame.width)),
        y: min(max(y, to.minY), max(to.minY, to.maxY - frame.height))))
}

@MainActor func listWindows() -> [WinInfo] {
    var out: [WinInfo] = []
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
                    || axValue(w, kAXMinimizeButtonAttribute) != nil,
                  let frame = axFrame(w)
            else { continue }
            let minimized = axValue(w, kAXMinimizedAttribute) as? Bool ?? false
            out.append(WinInfo(
                element: w,
                pid: app.processIdentifier,
                title: axValue(w, kAXTitleAttribute) as? String ?? app.localizedName ?? "",
                frame: frame,
                stowed: minimized || app.isHidden))
        }
    }
    // Calendar reports its window twice. Identical windows would draw as
    // duplicate tiles, so collapse them.
    var seen = Set<String>()
    return out.filter { seen.insert("\($0.pid)|\($0.title)|\($0.frame)").inserted }
}

/// CG global point (y down, from primary top) -> Cocoa global point (y up, from primary bottom).
func cocoaPoint(_ p: CGPoint) -> CGPoint {
    let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
    return CGPoint(x: p.x, y: primaryTop - p.y)
}

func screenContaining(_ cgRect: CGRect) -> NSScreen? {
    let c = cocoaPoint(CGPoint(x: cgRect.midX, y: cgRect.midY))
    return NSScreen.screens.first { $0.frame.contains(c) }
}

func screenOf(_ w: WinInfo) -> NSScreen? { screenContaining(w.frame) }

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
              let rect = CGRect(dictionaryRepresentation: bd as! CFDictionary),
              let id = screenContaining(rect)?.displayID
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
    move(w.element, onto: screen)
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

    // ponytail: ratios calibrated against the stock Dock -- tilesize 42 yields
    // a 62pt screen inset (8 pad + 42 tile + 8 pad + 4 margin). Tune here if a
    // future macOS restyles the Dock.
    var pad: CGFloat { round(tile * 0.19) }
    var gap: CGFloat { round(tile * 0.12) }
    var margin: CGFloat { round(tile * 0.10) }
    var thickness: CGFloat { tile + 2 * pad }
    var radius: CGFloat { thickness / 2 }
    var maxScale: CGFloat { magnify ? max(1, large / tile) : 1 }
    var isVertical: Bool { edge != .bottom }

    static func current() -> DockStyle {
        let d = UserDefaults(suiteName: "com.apple.dock")
        func num(_ key: String, _ fallback: CGFloat) -> CGFloat {
            (d?.object(forKey: key) as? Double).map { CGFloat($0) } ?? fallback
        }
        return DockStyle(
            tile: num("tilesize", 48),
            large: num("largesize", 128),
            magnify: d?.bool(forKey: "magnification") ?? false,
            edge: DockEdge(rawValue: d?.string(forKey: "orientation") ?? "") ?? .bottom
        )
    }
}

// MARK: - Dock UI

final class WinButton: NSButton {
    var win: WinInfo!
}

/// Glass strip plus the icon row. Icons are siblings of the glass view, not its
/// contentView: NSGlassEffectView only guarantees z-order for its contentView.
final class DockContentView: NSView {
    let glass = NSGlassEffectView()
    var style = DockStyle()
    /// Cursor position along the layout axis, in view coords. nil when away.
    var cursor: CGFloat?

    override init(frame: NSRect) {
        super.init(frame: frame)
        glass.style = .regular
        addSubview(glass)
    }
    required init?(coder: NSCoder) { fatalError() }

    var tiles: [WinButton] { subviews.compactMap { $0 as? WinButton } }

    /// Rect a tile occupies given its offset along the edge and its magnified size.
    private func tileRect(offset: CGFloat, size: CGFloat) -> NSRect {
        switch style.edge {
        case .bottom: NSRect(x: offset, y: style.pad, width: size, height: size)
        case .left:   NSRect(x: style.pad, y: bounds.height - offset - size,
                             width: size, height: size)
        case .right:  NSRect(x: bounds.width - style.pad - size,
                             y: bounds.height - offset - size, width: size, height: size)
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
        layoutTiles()
    }

    func layoutTiles() {
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

        let total = scales.reduce(0) { $0 + $1 * s.tile } + CGFloat(tiles.count - 1) * s.gap
        var offset = (axis - total) / 2
        for (tile, k) in zip(tiles, scales) {
            let size = s.tile * k
            tile.frame = tileRect(offset: offset, size: size)
            offset += size + s.gap
        }
    }

    /// True where the panel should swallow clicks. Everywhere else it is a
    /// transparent hole and must not block the windows underneath.
    func isInteractive(_ p: NSPoint) -> Bool {
        glass.frame.contains(p) || tiles.contains { $0.frame.contains(p) }
    }
}

final class DockPanel: NSPanel {
    private var shown: [WinInfo] = []
    private var shownStyle: DockStyle?
    /// The display this strip belongs to; clicking a tile sends the window here.
    private var homeScreen: NSScreen?
    private var body: DockContentView { contentView as! DockContentView }

    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false  // the glass carries its own
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        contentView = DockContentView()
    }

    func update(_ wins: [WinInfo], style: DockStyle, on screen: NSScreen) {
        guard wins != shown || style != shownStyle else { return }
        shown = wins
        shownStyle = style
        homeScreen = screen
        body.style = style

        guard !wins.isEmpty else { orderOut(nil); return }

        body.tiles.forEach { $0.removeFromSuperview() }
        for w in wins {
            let b = WinButton()
            b.win = w
            b.isBordered = false
            b.bezelStyle = .regularSquare
            b.imagePosition = .imageOnly
            b.imageScaling = .scaleProportionallyUpOrDown
            b.image = NSRunningApplication(processIdentifier: w.pid)?.icon
            b.toolTip = w.title
            b.alphaValue = w.stowed ? 0.45 : 1
            b.target = self
            b.action = #selector(click(_:))
            body.addSubview(b)
        }

        // Room for the strip, plus headroom for magnified icons to spill out of it.
        let depth = max(style.thickness, style.pad + style.tile * style.maxScale + style.pad)
        let n = CGFloat(wins.count)
        let length = n * style.tile * style.maxScale + (n - 1) * style.gap + 2 * style.pad
        let f = screen.frame

        let frame: NSRect = switch style.edge {
        case .bottom: NSRect(x: f.midX - length / 2, y: f.minY + style.margin,
                             width: min(length, f.width), height: depth)
        case .left:   NSRect(x: f.minX + style.margin, y: f.midY - length / 2,
                             width: depth, height: min(length, f.height))
        case .right:  NSRect(x: f.maxX - style.margin - depth, y: f.midY - length / 2,
                             width: depth, height: min(length, f.height))
        }
        setFrame(frame, display: true)
        body.needsLayout = true
        orderFront(nil)
    }

    /// Follow the cursor for magnification, and stay click-through everywhere
    /// the dock is not actually drawn.
    func hover(_ screenPoint: NSPoint) {
        let p = body.convert(convertPoint(fromScreen: screenPoint), from: nil)
        let inside = NSPointInRect(p, body.bounds)
        body.cursor = inside ? (body.style.isVertical ? p.y : p.x) : nil
        body.layoutTiles()
        ignoresMouseEvents = !(inside && body.isInteractive(p))
    }

    @objc private func click(_ sender: WinButton) {
        guard let homeScreen else { return }
        raise(sender.win, onto: homeScreen)
    }
}

// MARK: - App

@MainActor final class Controller: NSObject, NSApplicationDelegate {
    private var docks: [CGDirectDisplayID: DockPanel] = [:]
    private var timer: Timer?
    private var statusItem: NSStatusItem?  // also the only way to quit an LSUIElement app
    private var hoverMonitor: Any?
    private var observers: [pid_t: AXObserver] = [:]
    private var trustTimer: Timer?

    func applicationDidFinishLaunching(_: Notification) {
        guard AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        ) else {
            // Rebuilding changes the binary's cdhash, which invalidates the
            // Accessibility grant, so this wait is a normal part of the dev
            // loop. Poll rather than quit, so approving is the only step.
            NSLog("SibDocks: waiting for Accessibility approval...")
            trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, AXIsProcessTrusted() else { return }
                    self.trustTimer?.invalidate()
                    self.start()
                }
            }
            return
        }
        start()
    }

    private func start() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "dock.rectangle",
                                     accessibilityDescription: "SibDocks")
        let menu = NSMenu()
        menu.addItem(withTitle: "Quit SibDocks",
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item

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

        // ponytail: 1s poll. Swap for AX notification observers only if CPU shows up.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    private func tick() {
        let wins = listWindows()

        var byScreen: [CGDirectDisplayID: [WinInfo]] = [:]
        for w in wins {
            guard let s = screenOf(w), let id = s.displayID else { continue }
            byScreen[id, default: []].append(w)
        }
        let style = DockStyle.current()
        // That display already has a dock: the real one.
        let taken = realDockScreen()
        let live = Set(NSScreen.screens.compactMap(\.displayID)).subtracting([taken].compactMap { $0 })
        for (id, dock) in docks where !live.contains(id) {
            dock.orderOut(nil); docks[id] = nil
        }
        for screen in NSScreen.screens {
            guard let id = screen.displayID, id != taken else { continue }
            let dock = docks[id] ?? {
                let d = DockPanel(); docks[id] = d; return d
            }()
            dock.update(byScreen[id] ?? [], style: style, on: screen)
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

if CommandLine.arguments.contains("--selftest") {
    let primaryTop = NSScreen.screens[0].frame.maxY
    for y in [0.0, 100.0, primaryTop] {  // CG<->Cocoa flip is its own inverse
        let p = CGPoint(x: 5, y: y)
        assert(cocoaPoint(cocoaPoint(p)) == p)
    }
    // Magnification layout: tiles must never overlap, the tile under the
    // cursor must be the biggest, and no cursor must mean no magnification.
    let cv = DockContentView(frame: NSRect(x: 0, y: 0, width: 600, height: 100))
    for edge in [DockEdge.bottom, .left, .right] {
        cv.style = DockStyle(tile: 42, large: 72, magnify: true, edge: edge)
        cv.subviews.compactMap { $0 as? WinButton }.forEach { $0.removeFromSuperview() }
        for _ in 0..<6 { cv.addSubview(WinButton()) }

        let axisMid: CGFloat = cv.style.isVertical ? 50 : 300
        cv.cursor = axisMid
        cv.layoutTiles()
        let rects = cv.tiles.map(\.frame)
        let along: (NSRect) -> CGFloat = { cv.style.isVertical ? $0.midY : $0.midX }
        for (a, b) in zip(rects, rects.dropFirst()) {
            let gap = abs(along(b) - along(a)) - (a.width + b.width) / 2
            assert(gap > -0.01, "magnified tiles overlap on \(edge)")
        }
        let widest = rects.map(\.width).max()!
        let nearest = rects.min { abs(along($0) - axisMid) < abs(along($1) - axisMid) }!
        assert(nearest.width == widest, "cursor tile is not the largest on \(edge)")
        assert(widest <= 72.01, "magnified past largesize on \(edge)")

        cv.cursor = nil
        cv.layoutTiles()
        assert(cv.tiles.allSatisfy { abs($0.frame.width - 42) < 0.01 },
               "tiles magnified with no cursor on \(edge)")
    }
    print("layout ok (bottom/left/right, magnified + resting)")

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

let app = NSApplication.shared
let controller = Controller()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
