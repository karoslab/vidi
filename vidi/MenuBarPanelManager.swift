//
//  MenuBarPanelManager.swift
//  vidi
//
//  Manages the NSStatusItem (menu bar icon) and a custom borderless NSPanel
//  that drops down below it when clicked. The panel hosts a SwiftUI view
//  (CompanionPanelView) via NSHostingView.
//
//  The panel is non-activating so it does not steal focus from the user's
//  current app, and auto-dismisses when the user clicks outside.
//
//  Vidi Current redesign: the panel is wider (control / listening / activity
//  surfaces) and can EXPAND IN PLACE into a Vidi-Chat webview extension. When
//  `companionManager.panelDisplayState` becomes `.chat`, the panel resizes to a
//  chat window and swaps its content to a retained WKWebView (kept alive across
//  collapse/expand so draft text and scroll survive). "Back to Voice" collapses
//  it to the control surface.
//

import AppKit
import Combine
import SwiftUI
import WebKit

extension Notification.Name {
    static let vidiDismissPanel = Notification.Name("vidiDismissPanel")
}

/// Custom NSPanel subclass that can become the key window even with
/// .nonactivatingPanel style, allowing text fields (and the chat webview) to
/// receive focus.
private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class MenuBarPanelManager: NSObject {
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var clickOutsideMonitor: Any?
    private var dismissPanelObserver: NSObjectProtocol?
    private var panelStateCancellable: AnyCancellable?

    private let companionManager: CompanionManager

    /// Width of the control / listening / activity surfaces. The desktop
    /// reference is 620×720; this scales it down for menu-bar use.
    private let panelWidth: CGFloat = 440
    private let panelHeight: CGFloat = 420

    /// The expanded Vidi-Chat extension size.
    private let chatExtensionWidth: CGFloat = 1000
    private let chatExtensionHeight: CGFloat = 700
    private let chatTopBarHeight: CGFloat = 46

    // The SwiftUI content (control/listening/activity), retained so it can be
    // swapped back in after the chat extension collapses.
    private var contentHostingView: NSView?

    // Chat extension — the WKWebView is retained (hidden, not destroyed) across
    // collapse/expand so draft text and scroll survive.
    private var chatContainerView: NSView?
    private var chatWebView: WKWebView?
    private var chatConnectingHostingView: NSHostingView<VidiChatConnectingView>?
    private var chatHealthCheckRetryTimer: Timer?
    private var hasLoadedChatURL = false
    private var isShowingChatExtension = false

    /// Seconds between health-check attempts while vidi-chat is unreachable.
    private let chatHealthCheckRetryInterval: TimeInterval = 2.0

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
        createStatusItem()

        dismissPanelObserver = NotificationCenter.default.addObserver(
            forName: .vidiDismissPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.hidePanel()
        }

        // React to Vidi-Chat extension expand/collapse.
        panelStateCancellable = companionManager.$panelDisplayState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newState in
                self?.handlePanelDisplayStateChange(newState)
            }
    }

    deinit {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = dismissPanelObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Status Item

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem?.button else { return }

        button.image = makeVidiMenuBarIcon()
        button.image?.isTemplate = false
        button.action = #selector(statusItemClicked)
        button.target = self
    }

    /// Renders the 🐷 pig emoji into a menu-bar-sized NSImage. Drawn full-color
    /// (not a template image) so the pig keeps its color in the status bar.
    private func makeVidiMenuBarIcon() -> NSImage {
        let iconSize: CGFloat = 18
        let image = NSImage(size: NSSize(width: iconSize, height: iconSize))
        image.lockFocus()

        let emoji = "🐷" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: iconSize * 0.86)
        ]
        let textSize = emoji.size(withAttributes: attributes)
        let drawRect = NSRect(
            x: (iconSize - textSize.width) / 2,
            y: (iconSize - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        )
        emoji.draw(in: drawRect, withAttributes: attributes)

        image.unlockFocus()
        return image
    }

    /// Opens the panel automatically on app launch so the user sees
    /// permissions and the start button right away.
    func showPanelOnLaunch() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.showPanel()
        }
    }

    @objc private func statusItemClicked() {
        if let panel, panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    // MARK: - Panel Lifecycle

    private func showPanel() {
        if panel == nil {
            createPanel()
        }

        if isShowingChatExtension {
            positionChatExtension()
        } else {
            positionPanelBelowStatusItem()
        }

        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
        installClickOutsideMonitor()
        companionManager.setMenuBarPanelVisible(true)
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        removeClickOutsideMonitor()
        companionManager.setMenuBarPanelVisible(false)
    }

    private func createPanel() {
        let companionPanelView = CompanionPanelView(companionManager: companionManager)

        let hostingView = NSHostingView(rootView: companionPanelView)
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        contentHostingView = hostingView

        let menuBarPanel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        menuBarPanel.isFloatingPanel = true
        menuBarPanel.level = .floating
        menuBarPanel.isOpaque = false
        menuBarPanel.backgroundColor = .clear
        menuBarPanel.hasShadow = false
        menuBarPanel.hidesOnDeactivate = false
        menuBarPanel.isExcludedFromWindowsMenu = true
        menuBarPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        menuBarPanel.isMovableByWindowBackground = false
        menuBarPanel.titleVisibility = .hidden
        menuBarPanel.titlebarAppearsTransparent = true

        menuBarPanel.contentView = hostingView
        panel = menuBarPanel
    }

    private func positionPanelBelowStatusItem() {
        guard let panel else { return }
        guard let buttonWindow = statusItem?.button?.window else { return }

        let statusItemFrame = buttonWindow.frame
        let gapBelowMenuBar: CGFloat = 4

        // Snugly wrap the SwiftUI content via its fitting size.
        let fittingSize = panel.contentView?.fittingSize ?? CGSize(width: panelWidth, height: panelHeight)
        let actualPanelHeight = fittingSize.height

        var panelOriginX = statusItemFrame.midX - (panelWidth / 2)
        let panelOriginY = statusItemFrame.minY - actualPanelHeight - gapBelowMenuBar

        // Keep the wider panel fully on-screen.
        if let visibleFrame = (statusItem?.button?.window?.screen ?? NSScreen.main)?.visibleFrame {
            panelOriginX = min(max(panelOriginX, visibleFrame.minX + 8), visibleFrame.maxX - panelWidth - 8)
        }

        panel.setFrame(
            NSRect(x: panelOriginX, y: panelOriginY, width: panelWidth, height: actualPanelHeight),
            display: true
        )
    }

    // MARK: - Vidi-Chat extension (in-place expand)

    private func handlePanelDisplayStateChange(_ newState: VidiPanelDisplayState) {
        guard let panel, panel.isVisible else { return }

        if newState == .chat {
            if !isShowingChatExtension { enterChatExtension() }
        } else if isShowingChatExtension {
            exitChatExtension()
        } else {
            // A control ↔ activity ↔ listening switch changes the content
            // height; re-fit the panel after SwiftUI recomputes its layout.
            DispatchQueue.main.async { [weak self] in
                self?.positionPanelBelowStatusItem()
            }
        }
    }

    private func enterChatExtension() {
        guard let panel else { return }
        isShowingChatExtension = true

        let container = makeChatContainerView()
        chatContainerView = container
        panel.contentView = container

        positionChatExtension()

        // The webview needs the panel key + app active to accept typed input.
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if !hasLoadedChatURL {
            beginChatHealthCheckAndLoad()
        }
    }

    private func exitChatExtension() {
        guard let panel else { return }
        isShowingChatExtension = false

        // Swap the SwiftUI content back in — the chat container + its retained
        // WKWebView stay alive (via `chatContainerView` / `chatWebView`) so a
        // later re-expand preserves draft text and scroll.
        if let hostingView = contentHostingView {
            panel.contentView = hostingView
        }

        positionPanelBelowStatusItem()
    }

    private func positionChatExtension() {
        guard let panel else { return }
        guard let buttonWindow = statusItem?.button?.window else { return }

        let statusItemFrame = buttonWindow.frame
        let gapBelowMenuBar: CGFloat = 4

        var originX = statusItemFrame.midX - (chatExtensionWidth / 2)
        var originY = statusItemFrame.minY - chatExtensionHeight - gapBelowMenuBar

        if let visibleFrame = (statusItem?.button?.window?.screen ?? NSScreen.main)?.visibleFrame {
            originX = min(max(originX, visibleFrame.minX + 8), visibleFrame.maxX - chatExtensionWidth - 8)
            originY = max(originY, visibleFrame.minY + 8)
        }

        panel.setFrame(
            NSRect(x: originX, y: originY, width: chatExtensionWidth, height: chatExtensionHeight),
            display: true,
            animate: true
        )
    }

    /// Builds the chat extension container: a dark top bar ("Back to Voice" +
    /// title) above the retained WKWebView (with a connecting placeholder).
    private func makeChatContainerView() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: chatExtensionWidth, height: chatExtensionHeight))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(VC.Colors.voicePanel).cgColor

        // Top bar (SwiftUI hosted).
        let topBar = NSHostingView(rootView: ChatExtensionTopBar(
            onBack: { [weak self] in self?.companionManager.collapseChatExtension() },
            onClose: { NotificationCenter.default.post(name: .vidiDismissPanel, object: nil) }
        ))
        topBar.frame = NSRect(
            x: 0,
            y: chatExtensionHeight - chatTopBarHeight,
            width: chatExtensionWidth,
            height: chatTopBarHeight
        )
        topBar.autoresizingMask = [.width, .minYMargin]
        container.addSubview(topBar)

        // WKWebView — reuse the retained instance if we already have one.
        let webView: WKWebView
        if let existing = chatWebView {
            existing.removeFromSuperview()
            webView = existing
        } else {
            let configuration = WKWebViewConfiguration()
            webView = WKWebView(frame: .zero, configuration: configuration)
            chatWebView = webView
        }
        webView.frame = NSRect(x: 0, y: 0, width: chatExtensionWidth, height: chatExtensionHeight - chatTopBarHeight)
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)

        // Connecting placeholder over the webview, shown until health passes.
        if !hasLoadedChatURL {
            let connectingView = NSHostingView(rootView: VidiChatConnectingView())
            connectingView.frame = webView.frame
            connectingView.autoresizingMask = [.width, .height]
            container.addSubview(connectingView)
            chatConnectingHostingView = connectingView
        }

        return container
    }

    private func beginChatHealthCheckAndLoad() {
        chatHealthCheckRetryTimer?.invalidate()
        attemptChatHealthCheck()
    }

    private func attemptChatHealthCheck() {
        guard let healthCheckURL = URL(string: VidiConfig.vidiChatBaseURL) else { return }

        var healthCheckRequest = URLRequest(url: healthCheckURL)
        healthCheckRequest.httpMethod = "HEAD"
        healthCheckRequest.timeoutInterval = 3

        Task { @MainActor in
            do {
                let (_, response) = try await URLSession.shared.data(for: healthCheckRequest)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200..<500).contains(httpResponse.statusCode) else {
                    scheduleChatHealthCheckRetry()
                    return
                }
                loadChatUI()
            } catch {
                scheduleChatHealthCheckRetry()
            }
        }
    }

    private func scheduleChatHealthCheckRetry() {
        // Stop retrying if the extension was collapsed while we were waiting.
        guard isShowingChatExtension else { return }
        chatHealthCheckRetryTimer = Timer.scheduledTimer(
            withTimeInterval: chatHealthCheckRetryInterval,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.attemptChatHealthCheck()
            }
        }
    }

    private func loadChatUI() {
        // The web app resolves ?room=voice to the persistent voice thread. If the
        // param does nothing yet the app just shows home — still correct. Vidi is
        // a passive client; it never auto-sends or creates threads.
        guard let chatURL = URL(string: VidiConfig.vidiChatBaseURL + "/?room=voice") else { return }
        chatConnectingHostingView?.removeFromSuperview()
        chatConnectingHostingView = nil
        chatWebView?.load(URLRequest(url: chatURL))
        hasLoadedChatURL = true
    }

    // MARK: - Click Outside Dismissal

    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, let panel = self.panel else { return }

            let clickLocation = NSEvent.mouseLocation
            if panel.frame.contains(clickLocation) {
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard panel.isVisible else { return }

                // Don't dismiss the expanded chat extension on an outside
                // click — it behaves like a full window, not a popover.
                if self.companionManager.panelDisplayState == .chat {
                    return
                }

                if !self.companionManager.allPermissionsGranted && !NSApp.isActive {
                    return
                }

                self.hidePanel()
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }
}

// MARK: - Chat extension top bar

/// The compact dark top bar above the Vidi-Chat webview: a "Back to Voice"
/// button and the "Vidi-Chat · from Voice" title.
private struct ChatExtensionTopBar: View {
    let onBack: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Back to Voice")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(VC.Colors.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(VC.Colors.glassFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(VC.Colors.hairline, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .accessibilityLabel("Back to Voice")

            HStack(spacing: 8) {
                VidiCurrentAppMark(side: 20)
                Text("Vidi-Chat")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(VC.Colors.textPrimary)
                Text("from Voice")
                    .font(.system(size: 12))
                    .foregroundColor(VC.Colors.textTertiary)
            }

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(VC.Colors.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(VC.Colors.glassFill))
                    .overlay(Circle().stroke(VC.Colors.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .accessibilityLabel("Close panel")
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VC.Colors.voicePanel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(VC.Colors.voiceRule).frame(height: 1)
        }
    }
}
