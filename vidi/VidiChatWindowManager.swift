//
//  VidiChatWindowManager.swift
//  vidi
//
//  Owns the native Vidi-Chat window — a regular titled NSWindow hosting a
//  WKWebView pointed at the local vidi-chat agent (VidiConfig.vidiChatBaseURL).
//  This is the "I'd rather type" path: same capability as the wake-word voice
//  agent, full vidi-chat UI, but without leaving the native app for a browser.
//
//  The window health-checks vidi-chat before loading. launchd
//  (the vidi-chat launch agent) keeps the server alive, but if it's mid-restart
//  the window shows a "Starting Vidi-Chat…" state and retries until the
//  server answers, instead of rendering a dead white page.
//

import AppKit
import SwiftUI
import WebKit

@MainActor
final class VidiChatWindowManager: NSObject {

    static let shared = VidiChatWindowManager()

    private var vidiChatWindow: NSWindow?
    private var vidiChatWebView: WKWebView?
    private var connectionStatusHostingView: NSHostingView<VidiChatConnectingView>?
    private var healthCheckRetryTimer: Timer?

    /// Seconds between health-check attempts while vidi-chat is unreachable.
    private let healthCheckRetryInterval: TimeInterval = 2.0

    /// Opens (or brings forward) the Vidi-Chat window. The app is LSUIElement
    /// (menu bar only), so we must explicitly activate to make the window key —
    /// otherwise typing into the chat box would not work.
    func showVidiChatWindow() {
        if let existingWindow = vidiChatWindow {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = makeVidiChatWindow()
        vidiChatWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        beginHealthCheckAndLoad()
    }

    // MARK: - Window construction

    private func makeVidiChatWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Vidi-Chat"
        window.minSize = NSSize(width: 640, height: 480)
        window.center()
        // Remember size/position across launches
        window.setFrameAutosaveName("VidiChatWindow")
        // The window is owned by this manager, not released on close —
        // we tear it down ourselves in windowWillClose.
        window.isReleasedWhenClosed = false
        window.delegate = self

        let webViewConfiguration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: webViewConfiguration)
        webView.autoresizingMask = [.width, .height]
        vidiChatWebView = webView

        let containerView = NSView(frame: window.contentLayoutRect)
        containerView.autoresizingMask = [.width, .height]
        webView.frame = containerView.bounds
        containerView.addSubview(webView)

        // "Starting Vidi-Chat…" overlay, shown until the health check passes
        let connectingView = NSHostingView(rootView: VidiChatConnectingView())
        connectingView.autoresizingMask = [.width, .height]
        connectingView.frame = containerView.bounds
        containerView.addSubview(connectingView)
        connectionStatusHostingView = connectingView

        window.contentView = containerView
        return window
    }

    // MARK: - Health check → load

    /// Probes the vidi-chat server; loads the web UI once it answers,
    /// retrying every few seconds while it is unreachable.
    private func beginHealthCheckAndLoad() {
        healthCheckRetryTimer?.invalidate()
        attemptHealthCheck()
    }

    private func attemptHealthCheck() {
        guard let healthCheckURL = URL(string: VidiConfig.vidiChatBaseURL) else { return }

        var healthCheckRequest = URLRequest(url: healthCheckURL)
        healthCheckRequest.httpMethod = "HEAD"
        healthCheckRequest.timeoutInterval = 3

        Task { @MainActor in
            do {
                let (_, response) = try await URLSession.shared.data(for: healthCheckRequest)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200..<500).contains(httpResponse.statusCode) else {
                    scheduleHealthCheckRetry()
                    return
                }
                loadVidiChatUI()
            } catch {
                scheduleHealthCheckRetry()
            }
        }
    }

    private func scheduleHealthCheckRetry() {
        // Stop retrying if the user closed the window while we were waiting
        guard vidiChatWindow != nil else { return }
        healthCheckRetryTimer = Timer.scheduledTimer(
            withTimeInterval: healthCheckRetryInterval,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.attemptHealthCheck()
            }
        }
    }

    private func loadVidiChatUI() {
        guard let vidiChatURL = URL(string: VidiConfig.vidiChatBaseURL) else { return }
        connectionStatusHostingView?.removeFromSuperview()
        connectionStatusHostingView = nil
        vidiChatWebView?.load(URLRequest(url: vidiChatURL))
    }
}

// MARK: - NSWindowDelegate

extension VidiChatWindowManager: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        healthCheckRetryTimer?.invalidate()
        healthCheckRetryTimer = nil
        vidiChatWebView = nil
        connectionStatusHostingView = nil
        vidiChatWindow = nil
    }
}

// MARK: - Connecting state view

/// Full-window placeholder shown while the local vidi-chat server is
/// unreachable (e.g. launchd is restarting it). Uses the Frost semantic canvas
/// and a compact glass status card, following System/Light/Dark (Phase 11D).
struct VidiChatConnectingView: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            VC.Colors.canvasBase
            statusCard
        }
        .ignoresSafeArea()
    }

    private var statusCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                VidiCurrentAppMark(side: 22)
                Text("Vidi-Chat")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(VC.Colors.textPrimary)
            }
            ProgressView()
                .controlSize(.small)
            Text("Starting Vidi-Chat…")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(VC.Colors.textSecondary)
            Text("Waiting for the local agent on port 4183")
                .font(.system(size: 11))
                .foregroundColor(VC.Colors.textTertiary)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(reduceTransparency ? AnyShapeStyle(VC.Colors.surfaceReading) : AnyShapeStyle(.regularMaterial))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(VC.Colors.glassBorder, lineWidth: 1)
        )
        .shadow(color: VC.Colors.glassShadow, radius: 20, x: 0, y: 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Starting Vidi-Chat. Waiting for the local agent on port 4183.")
    }
}
