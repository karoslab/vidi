//
//  CompanionPanelView.swift
//  vidi
//
//  The SwiftUI content hosted inside the menu bar panel — the "Vidi Current"
//  redesign. A dark graphite shell (window chrome) wraps warm Paper Current
//  content. Three surfaces route off `companionManager.panelDisplayState`:
//    • control   — editorial headline, shortcut hint, settings, Open Vidi-Chat
//    • listening — live transcript, audio bars, Cancel / Send
//    • activity  — recent voice sessions + real permission states
//  (The `chat` state expands the NSPanel into a webview handled entirely by
//  MenuBarPanelManager; this view renders the control surface as a fallback.)
//
//  All bindings are the SAME companionManager state as before — the redesign is
//  presentation only. The voice pipeline, shortcut, permissions, and
//  model/mode/effort persistence are untouched.
//

import AVFoundation
import SwiftUI

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var emailInput: String = ""
    /// When the current listening capture started, for the live timer.
    @State private var listeningStartedAt: Date = Date()
    #if DEBUG
    // Phase A0 go/no-go harness for echo-cancelled barge-in. Debug builds only;
    // deleted once VoiceConversationAudioEngine ships.
    @StateObject private var aecSpikeHarness = AECSpikeHarness()
    #endif

    /// Panel width for the control / listening / activity surfaces. The
    /// desktop reference is 620×720; this scales it down for menu-bar use.
    static let panelWidth: CGFloat = 440

    private var isReady: Bool {
        companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader

            Rectangle()
                .fill(VC.Colors.voiceRule)
                .frame(height: 1)

            content
        }
        .frame(width: Self.panelWidth)
        .background(panelBackground)
    }

    // MARK: - Content routing

    @ViewBuilder
    private var content: some View {
        if !isReady {
            // Setup / permissions / onboarding — the existing flow, shown on the
            // new shell background. This replaces the ready surfaces exactly as
            // it does today.
            setupSurface
        } else {
            switch companionManager.panelDisplayState {
            case .listening:
                listeningSurface
            case .activity:
                activitySurface
            case .control, .chat:
                controlSurface
            }
        }
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack(spacing: 10) {
            VidiCurrentAppMark(side: 24)

            HStack(spacing: 6) {
                Text("Vidi Voice")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(VC.Colors.voiceText)
                Text(headerSubtitle)
                    .font(.system(size: 12))
                    .foregroundColor(VC.Colors.voiceText.opacity(0.42))
            }

            Spacer()

            // Voice state reads by dot + icon + label + color (never color
            // alone) — the accessibility status-semantics rule (Phase 11C).
            HStack(spacing: 6) {
                VidiCurrentStatusDot(color: statusStyle.color, pulsing: statusStyle.pulses)
                Image(systemName: statusStyle.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(statusStyle.color)
                    .accessibilityHidden(true)
                Text(statusStyle.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(VC.Colors.textSecondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Vidi status: \(statusStyle.label)")

            if isReady {
                headerSurfaceToggle
            }

            Button(action: {
                NotificationCenter.default.post(name: .vidiDismissPanel, object: nil)
            }) {
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
        .padding(.vertical, 13)
    }

    /// The clock/voice header control that switches between Control and Activity.
    private var headerSurfaceToggle: some View {
        let showingActivity = companionManager.panelDisplayState == .activity
        return Button(action: {
            if showingActivity {
                companionManager.showControlPanel()
            } else {
                companionManager.showActivityPanel()
            }
        }) {
            Image(systemName: showingActivity ? "chevron.backward" : "clock")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(VC.Colors.textSecondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(VC.Colors.glassFill))
                .overlay(Circle().stroke(VC.Colors.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityLabel(showingActivity ? "Back to voice control" : "Show voice activity")
    }

    private var headerSubtitle: String {
        if !isReady { return "setup" }
        switch companionManager.panelDisplayState {
        case .listening: return "listening"
        case .activity: return "activity"
        case .control, .chat: return "menu bar"
        }
    }

    // MARK: - Control surface

    private var controlSurface: some View {
        VStack(alignment: .leading, spacing: 14) {
            editorialCard
            settingsCard
            openChatRow
            controlFooter
        }
        .padding(16)
    }

    private var editorialCard: some View {
        VidiCurrentPaperCard {
            VStack(alignment: .leading, spacing: 12) {
                VidiCurrentEyebrow(text: "Voice control")

                Text("Speak naturally.\nVidi keeps the thread.")
                    .font(VC.display(24, weight: .semibold))
                    .foregroundColor(VC.Colors.carbon)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    Text("Hold")
                        .font(.system(size: 12))
                        .foregroundColor(VC.Colors.graphite)
                    VidiCurrentKeycap(glyph: "⌃")
                    VidiCurrentKeycap(glyph: "⌥")
                    Text("to talk. Start with \u{201C}vidi\u{2026}\u{201D} to hand work to the right room.")
                        .font(.system(size: 12))
                        .foregroundColor(VC.Colors.graphite)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Hold Control Option to talk. Start with vidi to hand work to the right room.")
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var settingsCard: some View {
        VidiCurrentPaperCard(fill: VC.Colors.paperSoft) {
            VStack(spacing: 0) {
                settingRow(iconName: "waveform", title: "Hands-free") {
                    HStack(spacing: 8) {
                        Text(companionManager.isHandsFreeEnabled ? "On" : "Off")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(VC.Colors.muted)
                        Toggle("", isOn: Binding(
                            get: { companionManager.isHandsFreeEnabled },
                            set: { companionManager.setHandsFreeEnabled($0) }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .tint(VC.Colors.cobalt)
                        .scaleEffect(0.8)
                        .accessibilityLabel("Hands-free listening")
                    }
                }

                settingDivider

                settingRow(iconName: "cpu", title: "Model") {
                    VidiCurrentSegmentTrack {
                        VidiCurrentSegment(label: "GPT-5.2", isSelected: companionManager.selectedModel == "gpt-5.2") {
                            companionManager.setSelectedModel("gpt-5.2")
                        }
                        VidiCurrentSegment(label: "Mini", isSelected: companionManager.selectedModel == "gpt-4.1-mini") {
                            companionManager.setSelectedModel("gpt-4.1-mini")
                        }
                    }
                }

                settingDivider

                settingRow(iconName: "arrow.triangle.branch", title: "Agent mode") {
                    VidiCurrentSegmentTrack {
                        VidiCurrentSegment(label: "Plan", isSelected: companionManager.voiceAgentMode == "plan") {
                            companionManager.setVoiceAgentMode("plan")
                        }
                        VidiCurrentSegment(label: "Auto", isSelected: companionManager.voiceAgentMode == "auto", activeIsCobalt: true) {
                            companionManager.setVoiceAgentMode("auto")
                        }
                    }
                }

                settingDivider

                settingRow(iconName: "gauge.with.dots.needle.50percent", title: "Agent effort") {
                    VidiCurrentSegmentTrack {
                        VidiCurrentSegment(label: "Low", isSelected: companionManager.voiceAgentEffort == "low") {
                            companionManager.setVoiceAgentEffort("low")
                        }
                        VidiCurrentSegment(label: "Med", isSelected: companionManager.voiceAgentEffort == "medium") {
                            companionManager.setVoiceAgentEffort("medium")
                        }
                        VidiCurrentSegment(label: "High", isSelected: companionManager.voiceAgentEffort == "high") {
                            companionManager.setVoiceAgentEffort("high")
                        }
                        VidiCurrentSegment(label: "Ultra", isSelected: companionManager.voiceAgentEffort == "ultra") {
                            companionManager.setVoiceAgentEffort("ultra")
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }

    private func settingRow<Trailing: View>(
        iconName: String,
        title: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(VC.Colors.graphite)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(VC.Colors.surfaceReading)
                )
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(VC.Colors.carbon)
            Spacer()
            trailing()
        }
        .padding(.vertical, 12)
    }

    private var settingDivider: some View {
        Rectangle().fill(VC.Colors.paperRule).frame(height: 1)
    }

    private var openChatRow: some View {
        Button(action: {
            companionManager.showChatExtension()
        }) {
            HStack(spacing: 14) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(VC.Colors.actionSecondary)
                    .frame(width: 42, height: 42)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(VC.Colors.actionSecondary.opacity(0.14))
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text("Open workspace")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(VC.Colors.textPrimary)
                    Text("Type instead of talk \u{2014} same rooms, same context")
                        .font(.system(size: 11))
                        .foregroundColor(VC.Colors.textSecondary)
                }
                Spacer()
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(VC.Colors.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(VC.Colors.glassFillStrong)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(VC.Colors.glassBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityLabel("Open workspace. Type instead of talk, same rooms, same context.")
    }

    private var controlFooter: some View {
        HStack(spacing: 12) {
            if let microphoneName = defaultMicrophoneName {
                Text("Microphone: \(microphoneName)")
                    .font(.system(size: 11))
                    .foregroundColor(VC.Colors.voiceText.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer()
            Button(action: { companionManager.showActivityPanel() }) {
                Text("Permissions")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(VC.Colors.voiceText.opacity(0.7))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .accessibilityLabel("Permissions")

            Button(action: { NSApp.terminate(nil) }) {
                Text("Quit Vidi")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(VC.Colors.voiceText.opacity(0.7))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .accessibilityLabel("Quit Vidi")
        }
        .padding(.top, 2)
    }

    private var defaultMicrophoneName: String? {
        AVCaptureDevice.default(for: .audio)?.localizedName
    }

    // MARK: - Listening surface

    private var listeningSurface: some View {
        VStack(alignment: .leading, spacing: 14) {
            VidiCurrentPaperCard {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        HStack(spacing: 8) {
                            Circle().fill(VC.Colors.actionPrimary).frame(width: 8, height: 8)
                            Text("LIVE TRANSCRIPT")
                                .font(.system(size: 11, weight: .heavy))
                                .tracking(0.8)
                                // Reads on the textPrimary fill in BOTH appearances
                                // (surfaceReadingElevated inverts with textPrimary).
                                .foregroundColor(VC.Colors.surfaceReadingElevated)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(VC.Colors.textPrimary))

                        Spacer()

                        TimelineView(.periodic(from: listeningStartedAt, by: 0.1)) { context in
                            Text(elapsedString(now: context.date))
                                .font(VC.mono(13, weight: .medium))
                                .foregroundColor(VC.Colors.muted)
                        }
                        .accessibilityHidden(true)
                    }

                    Text(displayedPartialTranscript)
                        .font(VC.display(26, weight: .semibold))
                        .foregroundColor(
                            companionManager.livePartialTranscript.isEmpty
                                ? VC.Colors.muted : VC.Colors.carbon
                        )
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Live transcript: \(displayedPartialTranscript)")

                    audioBars

                    if let parkedAction = companionManager.pendingConfirmDescription {
                        signalNotice(
                            title: "Waiting for your confirm",
                            detail: "\(parkedAction) \u{2014} nothing has run. Say \u{201C}vidi, confirm\u{201D} to approve."
                        )
                    }

                    understandsBlock
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            listeningControls
        }
        .padding(16)
        .onAppear { listeningStartedAt = Date() }
    }

    private var displayedPartialTranscript: String {
        let partial = companionManager.livePartialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        return partial.isEmpty ? "Listening\u{2026}" : partial
    }

    private func elapsedString(now: Date) -> String {
        let elapsed = max(0, now.timeIntervalSince(listeningStartedAt))
        let minutes = Int(elapsed) / 60
        let seconds = Int(elapsed) % 60
        let tenths = Int((elapsed - Double(Int(elapsed))) * 10)
        return String(format: "%02d:%02d.%d", minutes, seconds, tenths)
    }

    /// Staggered audio bars. Animate ONLY while capture is live and reduce-motion
    /// is off; otherwise render a calm static bank derived from the real
    /// audio-power level.
    private var audioBars: some View {
        let isCapturing = companionManager.voiceState == .listening
        let animate = isCapturing && !reduceMotion
        let barCount = 40
        let palette: [Color] = [VC.Colors.roomViolet, VC.Colors.roomCyan, VC.Colors.cobalt]

        return TimelineView(.animation(minimumInterval: 0.05, paused: !animate)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 4) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(palette[index % palette.count])
                        .frame(width: 4, height: barHeight(index: index, phase: phase, animate: animate))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 88)
            .padding(.vertical, 4)
            .overlay(alignment: .top) { Rectangle().fill(VC.Colors.paperRule).frame(height: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(VC.Colors.paperRule).frame(height: 1) }
        }
        .accessibilityHidden(true)
    }

    private func barHeight(index: Int, phase: Double, animate: Bool) -> CGFloat {
        let level = max(0.08, min(1.0, companionManager.currentAudioPowerLevel))
        guard animate else {
            // Static: a gentle standing wave scaled by the last measured level.
            let base = 0.35 + 0.3 * sin(Double(index) * 0.5)
            return CGFloat(14 + 60 * base * level)
        }
        let wave = sin(phase * 6 + Double(index) * 0.55)
        let amplitude = 0.4 + 0.6 * level
        let normalized = (wave * 0.5 + 0.5) * amplitude
        return CGFloat(10 + 68 * normalized)
    }

    private var understandsBlock: some View {
        let isPlanMode = companionManager.voiceAgentMode == "plan"
        return VStack(alignment: .leading, spacing: 10) {
            VidiCurrentEyebrow(text: "Vidi understands")

            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(VC.Colors.paper)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(VC.Colors.paperRule, lineWidth: 1)
                    )
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(VC.Colors.roomCyan)
                            .frame(width: 4)
                            .padding(.vertical, 6)
                    }
                    .frame(width: 30, height: 30)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Destination \u{00B7} Voice \u{00B7} vidi-chat")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(VC.Colors.carbon)
                    Text(isPlanMode
                         ? "Plan mode \u{2014} read-only first. Nothing runs without your confirm."
                         : "Auto mode \u{2014} action-capable. Risky actions still ask first.")
                        .font(.system(size: 11))
                        .foregroundColor(VC.Colors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(alignment: .top, spacing: 6) {
                Text(transcriptionPrivacyNote.lead)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(VC.Colors.graphite)
                    .fixedSize(horizontal: false, vertical: true)
                Text(transcriptionPrivacyNote.detail)
                    .font(.system(size: 11))
                    .foregroundColor(VC.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [4]))
                    .foregroundColor(VC.Colors.paperRule)
            )
        }
        .padding(.top, 4)
    }

    /// Truthful, provider-aware transcription-privacy note. Apple Speech runs
    /// on-device (audio stays local); every cloud provider (Grok is the default
    /// pin) sends audio off-device to transcribe, so the note names the provider
    /// and says the audio leaves rather than claiming local-only.
    private var transcriptionPrivacyNote: (lead: String, detail: String) {
        if companionManager.transcriptionRunsOnDevice {
            return ("Private by design.",
                    "Audio is transcribed locally; only the text is sent.")
        }
        let provider = companionManager.activeTranscriptionProviderDisplayName
        let named = provider.isEmpty ? "the cloud" : provider
        return ("Transcribed via \(named).",
                "Audio leaves this Mac for transcription; only the final text goes to Vidi.")
    }

    private func signalNotice(title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Circle().fill(VC.Colors.alert).frame(width: 8, height: 8).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(VC.Colors.alertInk)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(VC.Colors.alertInk.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(VC.Colors.alertWell))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail)")
    }

    private var listeningControls: some View {
        // Cancel / Send-now drive ONLY the push-to-talk dictation pipeline
        // (cancelCurrentDictation / stopPushToTalkFromKeyboardShortcut). During
        // ambient (wake-word) capture they'd no-op or mislead, so they show only
        // while PTT dictation is the live mic. The ⌃⌥ hint stays in both modes.
        let isPushToTalk = companionManager.isPushToTalkCaptureLive
        return HStack(spacing: 11) {
            if isPushToTalk {
                Button(action: { companionManager.cancelActiveVoiceCapture() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark")
                        Text("Cancel")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(VC.Colors.stateDanger)
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(VC.Colors.dangerWell)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(VC.Colors.stateDanger.opacity(0.4), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .accessibilityLabel("Cancel capture")
            }

            HStack(spacing: 6) {
                Text(isPushToTalk ? "Release" : "Hold")
                    .font(.system(size: 11))
                    .foregroundColor(VC.Colors.voiceText.opacity(0.6))
                VidiCurrentKeycap(glyph: "⌃")
                VidiCurrentKeycap(glyph: "⌥")
                Text(isPushToTalk ? "to send" : "to talk")
                    .font(.system(size: 11))
                    .foregroundColor(VC.Colors.voiceText.opacity(0.6))
            }
            .accessibilityHidden(true)

            Spacer()

            if isPushToTalk {
                Button(action: { companionManager.endActiveVoiceCaptureAndSend() }) {
                    HStack(spacing: 6) {
                        Text("Send now")
                        Image(systemName: "arrow.up")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(VC.Colors.textOnAccent)
                    .padding(.horizontal, 18)
                    .frame(height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(VC.Colors.actionPrimary)
                    )
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .accessibilityLabel("Send now")
            }
        }
    }

    // MARK: - Activity surface

    private var activitySurface: some View {
        VStack(alignment: .leading, spacing: 14) {
            VidiCurrentPaperCard {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        VidiCurrentEyebrow(text: "Voice history")
                        Text("Recent sessions")
                            .font(VC.display(22))
                            .foregroundColor(VC.Colors.carbon)
                    }

                    if companionManager.recentVoiceSessions.isEmpty {
                        Text("No voice sessions yet. Give Vidi a task with \u{201C}vidi, \u{2026}\u{201D} and it shows up here.")
                            .font(.system(size: 12))
                            .foregroundColor(VC.Colors.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 8)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(companionManager.recentVoiceSessions.prefix(8))) { session in
                                activityRow(session: session)
                                if session.id != companionManager.recentVoiceSessions.prefix(8).last?.id {
                                    settingDivider
                                }
                            }
                        }
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            permissionsCard
        }
        .padding(16)
    }

    private func activityRow(session: VoiceActivityStore.Session) -> some View {
        let visuals = activityVisuals(for: session.outcome)
        return Button(action: {
            if session.hadAgentWork {
                companionManager.showChatExtension()
            }
        }) {
            HStack(spacing: 12) {
                Text(relativeTimeString(session.timestamp))
                    .font(VC.mono(10))
                    .foregroundColor(VC.Colors.muted)
                    .frame(width: 62, alignment: .leading)

                Image(systemName: visuals.iconName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(visuals.iconColor)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(visuals.iconWell)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(session.transcript.isEmpty ? "Voice command" : session.transcript)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(VC.Colors.carbon)
                        .lineLimit(1)
                    Text("\(Int(session.durationSeconds.rounded())) sec voice \u{00B7} \(visuals.meta)")
                        .font(.system(size: 10))
                        .foregroundColor(VC.Colors.muted)
                        .lineLimit(1)
                }
                Spacer()
                if session.hadAgentWork {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(VC.Colors.muted)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor(isEnabled: session.hadAgentWork)
        .accessibilityLabel("\(session.transcript). \(visuals.meta).\(session.hadAgentWork ? " Opens Vidi-Chat." : "")")
    }

    private func activityVisuals(for outcome: VoiceActivityStore.Outcome) -> (iconName: String, iconColor: Color, iconWell: Color, meta: String) {
        switch outcome {
        case .answered:
            return ("checkmark", VC.Colors.stateSuccess, VC.Colors.stateSuccess.opacity(0.15), "Answered")
        case .permissionRequired:
            return ("exclamationmark", VC.Colors.stateDanger, VC.Colors.dangerWell, "Permission required")
        case .cancelled:
            return ("arrow.uturn.backward", VC.Colors.textTertiary, VC.Colors.surfaceReading, "Cancelled")
        case .error:
            return ("exclamationmark", VC.Colors.stateDanger, VC.Colors.dangerWell, "Didn\u{2019}t reach vidi-chat")
        }
    }

    private var permissionsCard: some View {
        VidiCurrentPaperCard(fill: VC.Colors.paperSoft) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    VidiCurrentEyebrow(text: "Permissions")
                    Text("System access")
                        .font(VC.display(20))
                        .foregroundColor(VC.Colors.carbon)
                }

                paperPermissionRow(
                    label: "Microphone",
                    isGranted: companionManager.hasMicrophonePermission,
                    grant: {
                        let status = AVCaptureDevice.authorizationStatus(for: .audio)
                        if status == .notDetermined {
                            AVCaptureDevice.requestAccess(for: .audio) { _ in }
                        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                )
                paperPermissionRow(
                    label: "Accessibility",
                    isGranted: companionManager.hasAccessibilityPermission,
                    grant: { WindowPositionManager.requestAccessibilityPermission() }
                )
                paperPermissionRow(
                    label: "Screen Recording",
                    isGranted: companionManager.hasScreenRecordingPermission,
                    grant: { WindowPositionManager.requestScreenRecordingPermission() }
                )

                // Static, always-true statement: the confirm gate always asks
                // before a production action runs. Not a togglable permission.
                HStack(spacing: 9) {
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 11, weight: .bold))
                        // Dark ink, not white: white-on-stateDanger drops to
                        // 2.34:1 in dark mode, below the 3:1 icon-boundary
                        // floor. Ink clears 3:1 in both appearances.
                        .foregroundColor(VC.Colors.textOnAccent)
                        .frame(width: 19, height: 19)
                        .background(Circle().fill(VC.Colors.alert))
                        .accessibilityHidden(true)
                    Text("Production actions")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(VC.Colors.graphite)
                    Spacer()
                    Text("Ask every time")
                        .font(.system(size: 11))
                        .foregroundColor(VC.Colors.muted)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Production actions: ask every time")
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func paperPermissionRow(label: String, isGranted: Bool, grant: @escaping () -> Void) -> some View {
        HStack(spacing: 9) {
            Image(systemName: isGranted ? "checkmark" : "exclamationmark")
                .font(.system(size: 11, weight: .bold))
                // Dark ink, not white: white on either fill drops below the
                // 3:1 icon-boundary floor in dark mode (stateSuccess 2.04:1,
                // stateDanger 2.34:1). Ink clears 3:1 on both, both modes.
                .foregroundColor(VC.Colors.textOnAccent)
                .frame(width: 19, height: 19)
                .background(Circle().fill(isGranted ? VC.Colors.success : VC.Colors.alert))
                .accessibilityHidden(true)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(VC.Colors.graphite)
            Spacer()
            if isGranted {
                Text("Allowed")
                    .font(.system(size: 11))
                    .foregroundColor(VC.Colors.muted)
            } else {
                Button(action: grant) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        // Dark ink, not white: white-on-cobalt (actionSecondary)
                        // measures 3.1:1 light / 2.06:1 dark — both fail
                        // WCAG AA's 4.5:1. Ink measures 5.72:1 / 8.62:1.
                        .foregroundColor(VC.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(VC.Colors.cobalt))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .accessibilityLabel("Grant \(label) permission")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(isGranted ? "allowed" : "not allowed")")
    }

    private func relativeTimeString(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            return formatter.string(from: date)
        }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    // MARK: - Setup surface (permissions / onboarding — restyled minimally)

    private var setupSurface: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let errorMessage = companionManager.lastErrorMessage,
               companionManager.voiceState == .idle {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(VC.Colors.alert)
                    Text(errorMessage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(VC.Colors.alert)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }

            permissionsCopySection
                .padding(.top, 16)
                .padding(.horizontal, 16)

            if !companionManager.allPermissionsGranted {
                Spacer().frame(height: 16)
                settingsSection.padding(.horizontal, 16)
            }

            if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer().frame(height: 16)
                startButton.padding(.horizontal, 16)
            }

            Spacer().frame(height: 12)

            Rectangle().fill(VC.Colors.voiceRule).frame(height: 1).padding(.horizontal, 16)

            footerSection
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private var permissionsCopySection: some View {
        if companionManager.allPermissionsGranted && !companionManager.hasSubmittedEmail {
            VStack(alignment: .leading, spacing: 4) {
                Text("Drop your email to get started.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(VC.Colors.voiceText.opacity(0.85))
                Text("If I keep building this, I'll keep you in the loop.")
                    .font(.system(size: 11))
                    .foregroundColor(VC.Colors.voiceText.opacity(0.5))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.allPermissionsGranted {
            Text("You're all set. Hit Start to meet Vidi.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(VC.Colors.voiceText.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.hasCompletedOnboarding && companionManager.hasEverHadAllPermissions {
            VStack(alignment: .leading, spacing: 6) {
                Text("Permissions needed")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(VC.Colors.voiceText.opacity(0.85))
                Text("Some permissions were revoked. Grant all four below to keep using Vidi.")
                    .font(.system(size: 11))
                    .foregroundColor(VC.Colors.voiceText.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("This is Vidi.")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(VC.Colors.voiceText.opacity(0.85))
                Text("An always-on companion that helps you learn stuff as you use your computer.")
                    .font(.system(size: 11))
                    .foregroundColor(VC.Colors.voiceText.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Nothing runs in the background. Vidi will only take a screenshot when you press the hot key, so you can give that permission in peace.")
                    .font(.system(size: 11))
                    .foregroundColor(VC.Colors.info)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var startButton: some View {
        if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            if !companionManager.hasSubmittedEmail {
                VStack(spacing: 8) {
                    TextField("Enter your email", text: $emailInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(VC.Colors.voiceText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(VC.Colors.surfaceReading)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(VC.Colors.hairline, lineWidth: 1)
                        )
                    Button(action: { companionManager.submitEmail(emailInput) }) {
                        Text("Submit")
                            .font(.system(size: 14, weight: .semibold))
                            // Dark ink, not white: white-on-cobalt (actionSecondary)
                            // measures 3.1:1 light / 2.06:1 dark — both fail
                            // WCAG AA's 4.5:1. Ink measures 5.72:1 / 8.62:1.
                            .foregroundColor(VC.Colors.textOnAccent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(emailInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                          ? VC.Colors.cobalt.opacity(0.4) : VC.Colors.cobalt)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .disabled(emailInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                Button(action: { companionManager.triggerOnboarding() }) {
                    Text("Start")
                        .font(.system(size: 14, weight: .semibold))
                        // Dark ink, not white: white-on-cobalt (actionSecondary)
                        // measures 3.1:1 light / 2.06:1 dark — both fail
                        // WCAG AA's 4.5:1. Ink measures 5.72:1 / 8.62:1.
                        .foregroundColor(VC.Colors.textOnAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(VC.Colors.cobalt))
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
    }

    private var settingsSection: some View {
        VStack(spacing: 2) {
            Text("PERMISSIONS")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(VC.Colors.voiceText.opacity(0.5))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)

            microphonePermissionRow
            accessibilityPermissionRow
            screenRecordingPermissionRow
            if companionManager.hasScreenRecordingPermission {
                screenContentPermissionRow
            }
        }
    }

    private var accessibilityPermissionRow: some View {
        shellPermissionRow(
            label: "Accessibility",
            iconName: "hand.raised",
            isGranted: companionManager.hasAccessibilityPermission,
            subtitle: nil,
            grantButtons: {
                HStack(spacing: 6) {
                    shellGrantButton("Grant") { WindowPositionManager.requestAccessibilityPermission() }
                    Button(action: {
                        WindowPositionManager.revealAppInFinder()
                        WindowPositionManager.openAccessibilitySettings()
                    }) {
                        Text("Find App")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(VC.Colors.voiceText.opacity(0.85))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().stroke(VC.Colors.voiceRule, lineWidth: 0.8))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .accessibilityLabel("Find app in Finder")
                }
            }
        )
    }

    private var screenRecordingPermissionRow: some View {
        shellPermissionRow(
            label: "Screen Recording",
            iconName: "rectangle.dashed.badge.record",
            isGranted: companionManager.hasScreenRecordingPermission,
            subtitle: companionManager.hasScreenRecordingPermission
                ? "Only takes a screenshot when you use the hotkey"
                : "Quit and reopen after granting",
            grantButtons: {
                shellGrantButton("Grant") { WindowPositionManager.requestScreenRecordingPermission() }
            }
        )
    }

    private var screenContentPermissionRow: some View {
        shellPermissionRow(
            label: "Screen Content",
            iconName: "eye",
            isGranted: companionManager.hasScreenContentPermission,
            subtitle: nil,
            grantButtons: {
                shellGrantButton("Grant") { companionManager.requestScreenContentPermission() }
            }
        )
    }

    private var microphonePermissionRow: some View {
        shellPermissionRow(
            label: "Microphone",
            iconName: "mic",
            isGranted: companionManager.hasMicrophonePermission,
            subtitle: nil,
            grantButtons: {
                shellGrantButton("Grant") {
                    let status = AVCaptureDevice.authorizationStatus(for: .audio)
                    if status == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        )
    }

    private func shellPermissionRow<Buttons: View>(
        label: String,
        iconName: String,
        isGranted: Bool,
        subtitle: String?,
        @ViewBuilder grantButtons: () -> Buttons
    ) -> some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? VC.Colors.voiceText.opacity(0.5) : VC.Colors.alert)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(VC.Colors.voiceText.opacity(0.85))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundColor(VC.Colors.voiceText.opacity(0.5))
                    }
                }
            }
            Spacer()
            if isGranted {
                HStack(spacing: 4) {
                    Circle().fill(VC.Colors.success).frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(VC.Colors.success)
                }
            } else {
                grantButtons()
            }
        }
        .padding(.vertical, 6)
    }

    private func shellGrantButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                // Dark ink, not white: white-on-cobalt (actionSecondary)
                // measures 3.1:1 light / 2.06:1 dark — both fail WCAG AA's
                // 4.5:1. Ink measures 5.72:1 / 8.62:1.
                .foregroundColor(VC.Colors.textOnAccent)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(VC.Colors.cobalt))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityLabel("\(title) permission")
    }

    private var footerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            footerButtons
            // CC BY 4.0 requires visible attribution when the Azelma voice is in
            // use. Shown only while the local voice is enabled (the toggle ships
            // off). Plain house style, no dashes.
            if VidiConfig.localVoiceEnabled {
                Text(TTSProviderSelection.localVoiceAttribution)
                    .font(.system(size: 10))
                    .foregroundColor(VC.Colors.voiceText.opacity(0.35))
                    .accessibilityLabel(TTSProviderSelection.localVoiceAttribution)
            }
        }
    }

    private var footerButtons: some View {
        HStack {
            Button(action: { NSApp.terminate(nil) }) {
                HStack(spacing: 6) {
                    Image(systemName: "power").font(.system(size: 11, weight: .medium))
                    Text("Quit Vidi").font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(VC.Colors.voiceText.opacity(0.6))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .accessibilityLabel("Quit Vidi")

            #if DEBUG
            Spacer()
            Button(action: {
                let handsFreeWasEnabled = companionManager.isHandsFreeEnabled
                if handsFreeWasEnabled { companionManager.setHandsFreeEnabled(false) }
                Task {
                    await aecSpikeHarness.run()
                    if handsFreeWasEnabled { companionManager.setHandsFreeEnabled(true) }
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "waveform.badge.mic").font(.system(size: 11, weight: .medium))
                    Text(aecSpikeHarness.isRunning ? "Spike Running\u{2026}" : "AEC Spike").font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(VC.Colors.voiceText.opacity(0.6))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .disabled(aecSpikeHarness.isRunning)
            .help("Phase A0: verify echo-cancelled barge-in works on this Mac (stay quiet for clip 1, say \"testing one two three\" over clip 2)")
            #endif

            if companionManager.hasCompletedOnboarding {
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "play.circle").font(.system(size: 11, weight: .medium))
                    Text("Watch Onboarding Again").font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(VC.Colors.voiceText.opacity(0.25))
                .help("Onboarding video coming soon")
            }
        }
    }

    // MARK: - Visual Helpers

    /// The panel shell: a native glass material (samples the desktop behind the
    /// non-opaque panel), legible over busy/light/dark wallpaper, with a solid
    /// canvas fallback under Reduce Transparency (Phase 11B).
    private var panelBackground: some View {
        LiquidGlassPanelBackground(cornerRadius: 20)
    }

    /// The single source of truth for the current voice state's presentation —
    /// label + SF Symbol + color + pulse. Every consumer (header dot, icon,
    /// label) derives from this so text/icon/color never diverge (Phase 11C).
    private var statusStyle: VidiVoiceStatePresentation.Style {
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            return VidiVoiceStatePresentation.setup
        }
        if companionManager.lastErrorMessage != nil && companionManager.voiceState == .idle {
            return VidiVoiceStatePresentation.error
        }
        if companionManager.pendingConfirmDescription != nil {
            return VidiVoiceStatePresentation.confirm
        }
        if companionManager.isSentryWatching && companionManager.voiceState == .idle {
            return VidiVoiceStatePresentation.watching
        }
        switch companionManager.voiceState {
        case .idle:
            return companionManager.isOverlayVisible
                ? VidiVoiceStatePresentation.active
                : VidiVoiceStatePresentation.ready
        case .listening:
            return VidiVoiceStatePresentation.listening
        case .processing:
            return VidiVoiceStatePresentation.working
        case .responding:
            return VidiVoiceStatePresentation.responding
        }
    }
}
