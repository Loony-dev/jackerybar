// Popup window under the menu bar item (replaces NSPopover, which mis-sizes self-resizing SwiftUI content).
// Height follows the content; if the screen is too short, the content scrolls.

import SwiftUI

final class PopupWindow<Content: View> {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private let window: Panel
    private let hosting: NSHostingView<Content>
    /// Builds the content; `true` = measuring pass (no scroll view).
    private let make: (Bool) -> Content
    private weak var anchor: NSStatusBarButton?
    private var monitors: [Any] = []
    private let gap: CGFloat = 6
    private let margin: CGFloat = 8

    var isVisible: Bool { window.isVisible }
    /// Called on Escape; return true if handled (popup stays open).
    var onEscape: () -> Bool = { false }
    private let blur = NSVisualEffectView()
    private let tint = NSView()

    /// "dark" (default), "light" or "system".
    var theme: String = "dark" { didSet { applyTheme() } }

    private func applyTheme() {
        switch theme {
        case "light": window.appearance = NSAppearance(named: .aqua)
        case "system": window.appearance = nil
        default: window.appearance = NSAppearance(named: .darkAqua)
        }
        // Dark theme: deeper, almost black glass instead of the grey popover material.
        let dark = theme != "light" && (theme != "system" || NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        blur.material = dark ? .hudWindow : .popover
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(dark ? 0.45 : 0).cgColor
    }

    init(make: @escaping (Bool) -> Content) {
        self.make = make
        hosting = NSHostingView(rootView: make(false))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        // The window size is managed by fitToContent(); don't let SwiftUI resize it on its own.
        hosting.sizingOptions = []

        window = Panel(contentRect: NSRect(x: 0, y: 0, width: 344, height: 400),
                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .popUpMenu
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false

        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 14
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 0.5
        blur.layer?.borderColor = NSColor.separatorColor.cgColor
        tint.wantsLayer = true
        tint.frame = blur.bounds
        tint.autoresizingMask = [.width, .height]
        blur.addSubview(tint)
        blur.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: blur.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
        window.contentView = blur
        applyTheme()
    }

    /// Horizontal position is fixed while the popup is open: the status item's width changes
    /// with its text, and re-centring on every update makes the window jitter.
    private var pinnedX: CGFloat?

    func show(below button: NSStatusBarButton) {
        anchor = button
        pinnedX = nil
        fitToContent()
        window.alphaValue = 0
        window.orderFrontRegardless()
        window.makeKey()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; window.animator().alphaValue = 1 }

        // Close on any click outside the window, on Escape, or when another app takes focus.
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 {
                if self?.onEscape() != true { self?.close() }
                return nil
            }
            return e
        } as Any)
    }

    func close() {
        guard window.isVisible else { return }
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        window.orderOut(nil)
    }

    /// Sizes the window to the SwiftUI content and pins it right under the status item,
    /// clamped to the visible area of that screen.
    func fitToContent() {
        guard let button = anchor, let bw = button.window else { return }
        // Measure the SwiftUI content itself; the hosting view's fittingSize just echoes the window size.
        let measured = NSHostingController(rootView: make(true))
            .sizeThatFits(in: NSSize(width: 344, height: 6000))
        let size = NSSize(width: 344, height: ceil(measured.height))
        let anchorRect = bw.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = bw.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero

        var x = pinnedX ?? (anchorRect.midX - size.width / 2)
        x = min(max(x, visible.minX + margin), visible.maxX - size.width - margin)
        pinnedX = x
        let top = min(anchorRect.minY - gap, visible.maxY - gap)
        let height = min(size.height, top - visible.minY - margin)
        let frame = NSRect(x: x, y: top - height, width: size.width, height: height)
        if window.frame != frame { window.setFrame(frame, display: true) }
        if CommandLine.arguments.contains("--debug") {
            FileHandle.standardError.write("[popup] anchor=\(anchorRect) visible=\(visible) content=\(size) frame=\(frame)\n".data(using: .utf8)!)
        }
    }
}
