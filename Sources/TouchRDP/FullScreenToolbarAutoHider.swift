import AppKit
import ObjectiveC

/// Full-screen presentation options shared by every TouchRDP window: the title/tool
/// bar (Connect button + tab strip) auto-hides with the menu bar, so the session owns
/// every pixel; mousing to the top edge reveals both together.
let fullScreenAutoHideOptions: NSApplication.PresentationOptions =
    [.fullScreen, .autoHideMenuBar, .autoHideToolbar]

/// Applies `fullScreenAutoHideOptions` to a window whose delegate we do NOT own
/// (SwiftUI's main window). The only hook AppKit honors for this is the window
/// delegate's `willUseFullScreenPresentationOptions` — mutating
/// `NSApp.presentationOptions` inside an active full-screen space is silently
/// ignored (verified empirically on macOS 26). So this installs a forwarding proxy:
/// it answers that single selector (merging our options over whatever the original
/// delegate wanted) and hands every other message to the original untouched.
final class FullScreenToolbarAutoHider: NSObject, NSWindowDelegate {
    private static var associationKey: UInt8 = 0
    private weak var original: NSWindowDelegate?

    static func install(on window: NSWindow) {
        guard !(window.delegate is FullScreenToolbarAutoHider) else { return }
        let proxy = FullScreenToolbarAutoHider()
        proxy.original = window.delegate
        window.delegate = proxy
        // NSWindow.delegate is weak; tie the proxy's lifetime to the window's.
        objc_setAssociatedObject(window, &associationKey, proxy, .OBJC_ASSOCIATION_RETAIN)
    }

    func window(_ window: NSWindow,
                willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = []
    ) -> NSApplication.PresentationOptions {
        let base = original?.window?(window, willUseFullScreenPresentationOptions: proposedOptions)
            ?? proposedOptions
        return base.union(fullScreenAutoHideOptions)
    }

    // Full transparency for everything we don't implement ourselves.
    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let original, original.responds(to: aSelector) { return original }
        return super.forwardingTarget(for: aSelector)
    }
}
