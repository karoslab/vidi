//
//  AudioOutputRouteMonitor.swift
//  vidi
//
//  Watches the system's default AUDIO OUTPUT route and classifies it as either
//  "private listening" (headphones — only the owner can hear Vidi) or "speaker"
//  (the room can hear her). This is the switch that unlocks headphones-mode
//  full-duplex barge-in (Workstream S2):
//
//    - Private listening (AirPods / any Bluetooth, or the built-in headphone
//      jack): Vidi's TTS goes into the owner's ears only, so the microphone can
//      stay LIVE while she speaks without transcribing her own voice out of the
//      room. CompanionManager skips the half-duplex mic gate on these routes,
//      and the existing wake-word path gives "vidi, stop" barge-in for free —
//      no new speech-recognition code required.
//
//    - Speaker (built-in speaker, HDMI/DisplayPort monitor, AirPlay, USB DAC):
//      the room hears her, so a live mic WOULD hear her own TTS. On these routes
//      the half-duplex gate stays raised (mic muted while she speaks), exactly
//      as before this feature existed.
//
//  This is CoreAudio (`AudioObjectGetPropertyData`), NOT AVAudioSession —
//  AVAudioSession is an iOS API and does not drive output routing on macOS.
//
//  Deliberate classification choices (see `classifyOutputRoute`):
//    - USB is a SPEAKER. The owner may run a USB DAC into desk monitors; treating
//      a USB device as private listening would wrongly open the mic into a loud
//      room. The `vidiHeadphonesMode` override exists precisely so a USB
//      HEADPHONE amp can be forced to "on" when they actually wear headphones.
//    - The built-in output device is only private listening when its OUTPUT
//      data source is the headphone jack ('hdpn'); the built-in SPEAKER data
//      source ('ispk') is a speaker.
//

import Combine
import CoreAudio
import Foundation

/// How the user has asked us to treat the current output route, read from
/// `defaults write <bundle> vidiHeadphonesMode <value>` — same pattern
/// `AmbientWakeListener` uses for `vidiVoiceProcessingBargeIn`.
///
///   - `auto` (default): classify the live route from CoreAudio transport type.
///   - `on`: always treat output as private listening (force full-duplex).
///   - `off`: always treat output as speaker (force half-duplex).
enum HeadphonesModeOverride: String {
    case auto
    case forcedOn = "on"
    case forcedOff = "off"

    /// Parse the raw `defaults` string. Anything unrecognized (or absent) means
    /// `auto`, so a typo can never silently disable the mic gate.
    static func fromDefaultsValue(_ rawValue: String?) -> HeadphonesModeOverride {
        guard let rawValue else { return .auto }
        return HeadphonesModeOverride(rawValue: rawValue.lowercased()) ?? .auto
    }
}

/// The classification of a single output route, independent of the user
/// override. Split out so the decision is a pure, unit-testable function.
enum OutputRouteClassification {
    /// Only the wearer hears the audio — barge-in is safe with a live mic.
    case privateListening
    /// The room hears the audio — the mic must be gated while Vidi speaks.
    case speaker
}

@MainActor
final class AudioOutputRouteMonitor: ObservableObject {

    /// Process-wide singleton so CompanionManager's gate decisions and any UI
    /// read the same live route. Created lazily on first access.
    static let shared = AudioOutputRouteMonitor()

    /// True when the current effective route is private listening (headphones).
    /// Effective = the live CoreAudio classification unless `vidiHeadphonesMode`
    /// forces it. This is the single value CompanionManager consults to decide
    /// whether to skip the half-duplex mic gate. Published so any SwiftUI could
    /// observe it, and so a mid-speech route flip propagates immediately.
    @Published private(set) var isPrivateListening: Bool = false

    /// True when the current default output device is a Bluetooth / BluetoothLE
    /// route (AirPods on A2DP report Bluetooth transport). DISTINCT from
    /// `isPrivateListening`: a wired headphone jack is private-listening but is
    /// NOT Bluetooth and does NOT suffer the AirPods HFP→A2DP profile flap. The
    /// TTS Bluetooth start-protection guard (BluetoothStartProtectionDecision)
    /// consults THIS, not `isPrivateListening`, so a wired-headphone turn is never
    /// needlessly padded. Unaffected by the `vidiHeadphonesMode` override — that
    /// override forces the private-listening MIC-gate decision, but the physical
    /// transport (and thus whether a profile flap is physically possible) is a
    /// hardware fact, not a preference.
    @Published private(set) var isBluetoothOutput: Bool = false

    /// The user's `vidiHeadphonesMode` override. Read once at init (the same
    /// read cadence as `AmbientWakeListener.useVoiceProcessingBargeIn`); the
    /// live CoreAudio classification handles device changes, and the override is
    /// a rarely-touched escape hatch, so a relaunch to re-read it is acceptable.
    private let headphonesModeOverride: HeadphonesModeOverride

    // MARK: - CoreAudio property listeners

    /// The audio device we currently have a data-source listener attached to, so
    /// we can detach it when the default output device changes. `kAudioObjectUnknown`
    /// means "no listener attached yet".
    private var observedOutputDeviceID: AudioDeviceID = AudioDeviceID(kAudioObjectUnknown)

    /// Block installed on the SYSTEM object for "default output device changed".
    /// Retained so we can remove it in `deinit`.
    private var defaultDeviceChangeListenerBlock: AudioObjectPropertyListenerBlock?

    /// Block installed on the current output DEVICE for "data source changed"
    /// (e.g. built-in output flipping between speaker and headphone jack).
    /// Retained so we can remove it when the device changes or on deinit.
    private var dataSourceChangeListenerBlock: AudioObjectPropertyListenerBlock?

    init() {
        self.headphonesModeOverride = HeadphonesModeOverride.fromDefaultsValue(
            UserDefaults.standard.string(forKey: "vidiHeadphonesMode")
        )

        // Publish the initial route, then start listening for changes so the
        // value tracks AirPods connecting/disconnecting and the built-in output
        // flipping between speaker and headphone jack.
        reclassifyAndPublish()
        installDefaultOutputDeviceChangeListener()
        installDataSourceChangeListenerForCurrentDevice()
    }

    deinit {
        // deinit is nonisolated; CoreAudio removal is thread-safe, and the
        // captured property addresses are value types, so tearing the listeners
        // down here (rather than hopping to the main actor) is safe.
        if let defaultDeviceChangeListenerBlock {
            var address = Self.defaultOutputDevicePropertyAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, nil, defaultDeviceChangeListenerBlock
            )
        }
        if let dataSourceChangeListenerBlock, observedOutputDeviceID != AudioDeviceID(kAudioObjectUnknown) {
            var address = Self.outputDataSourcePropertyAddress
            AudioObjectRemovePropertyListenerBlock(
                observedOutputDeviceID, &address, nil, dataSourceChangeListenerBlock
            )
        }
    }

    // MARK: - Property addresses (constants)

    // These are pure value-type descriptors with no shared mutable state, so
    // they're `nonisolated` — `deinit` (which is nonisolated on a @MainActor
    // class) must build local mutable copies of them to pass CoreAudio as
    // `inout`, and computed properties returning a fresh value each access make
    // that safe without any actor hop.

    /// System-object property: which device is the default OUTPUT.
    nonisolated private static var defaultOutputDevicePropertyAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// Device property: the transport type (Bluetooth, built-in, HDMI, USB, …).
    nonisolated private static var transportTypePropertyAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// Device property: the OUTPUT data source (headphone jack vs. speaker for
    /// the built-in device). Scope is OUTPUT — the built-in device has both an
    /// input and an output data source and we only care about the output side.
    nonisolated private static var outputDataSourcePropertyAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    // MARK: - Reclassification

    /// Re-read the live route from CoreAudio, apply the override, and publish the
    /// result. Called at init and from every property-listener callback. Only
    /// assigns `isPrivateListening` when the value actually changes so SwiftUI
    /// observers aren't churned needlessly.
    private func reclassifyAndPublish() {
        let liveClassification = Self.classifyCurrentOutputRoute()
        let effectiveIsPrivateListening: Bool
        switch headphonesModeOverride {
        case .auto:
            effectiveIsPrivateListening = (liveClassification == .privateListening)
        case .forcedOn:
            effectiveIsPrivateListening = true
        case .forcedOff:
            effectiveIsPrivateListening = false
        }

        if effectiveIsPrivateListening != isPrivateListening {
            isPrivateListening = effectiveIsPrivateListening
            print("🎧 AudioOutputRoute: \(effectiveIsPrivateListening ? "private-listening (headphones)" : "speaker")"
                  + " [live=\(liveClassification), override=\(headphonesModeOverride.rawValue)]")
        }

        // The Bluetooth flag tracks the PHYSICAL transport and ignores the
        // `vidiHeadphonesMode` override — whether a HFP→A2DP profile flap is
        // possible is a hardware fact, not a mic-gate preference.
        let liveIsBluetooth = Self.currentOutputIsBluetooth()
        if liveIsBluetooth != isBluetoothOutput {
            isBluetoothOutput = liveIsBluetooth
        }
    }

    /// Reads the current default output device's transport type + data source
    /// from CoreAudio and maps them to a classification. Returns `.speaker` if
    /// anything can't be read — the safe default is always to keep the mic gate.
    private static func classifyCurrentOutputRoute() -> OutputRouteClassification {
        guard let outputDeviceID = currentDefaultOutputDeviceID() else {
            return .speaker
        }
        let transportType = transportType(of: outputDeviceID)
        let outputDataSource = outputDataSource(of: outputDeviceID)
        return classifyOutputRoute(transportType: transportType, builtInOutputDataSource: outputDataSource)
    }

    /// PURE classification (no CoreAudio calls) so it can be unit-tested with
    /// synthetic transport/data-source values from any context. `nonisolated`
    /// because it touches no instance state and the tests call it synchronously
    /// off the main actor. Given a device's transport type and — for built-in
    /// devices — its output data source, decide whether the route is private
    /// listening or speaker.
    nonisolated static func classifyOutputRoute(
        transportType: UInt32,
        builtInOutputDataSource: UInt32?
    ) -> OutputRouteClassification {
        switch transportType {
        case kAudioDeviceTransportTypeBluetooth,
             kAudioDeviceTransportTypeBluetoothLE:
            // AirPods and every other Bluetooth output is private listening.
            return .privateListening

        case kAudioDeviceTransportTypeBuiltIn:
            // The built-in device is only private listening when its output is
            // routed to the HEADPHONE JACK ('hdpn'); the built-in SPEAKER
            // ('ispk') and everything else is a speaker.
            if builtInOutputDataSource == headphoneJackDataSource {
                return .privateListening
            }
            return .speaker

        case kAudioDeviceTransportTypeUSB,
             kAudioDeviceTransportTypeHDMI,
             kAudioDeviceTransportTypeDisplayPort,
             kAudioDeviceTransportTypeAirPlay,
             kAudioDeviceTransportTypeThunderbolt:
            // Deliberately speakers: a USB DAC/monitor, an HDMI/DisplayPort
            // display's speakers, and AirPlay all put sound into the room. A USB
            // headphone amp is the one ambiguous case, resolved by the
            // `vidiHeadphonesMode` = on override.
            return .speaker

        default:
            // Unknown transport — keep the mic gate (never open the mic into an
            // output route we can't reason about).
            return .speaker
        }
    }

    /// PURE Bluetooth classification (no CoreAudio calls) so it can be unit-tested
    /// with synthetic transport values. `nonisolated` because it touches no
    /// instance state. Given a device's transport type, decide whether the route
    /// is a Bluetooth / BluetoothLE link — the ONLY transports that renegotiate
    /// the HFP↔A2DP profile after a mic session and thus can swallow the opening
    /// of a clip (see BluetoothStartProtectionDecision). A wired headphone jack is
    /// private-listening but NOT Bluetooth, so it returns false here.
    nonisolated static func classifyBluetoothOutput(transportType: UInt32) -> Bool {
        switch transportType {
        case kAudioDeviceTransportTypeBluetooth,
             kAudioDeviceTransportTypeBluetoothLE:
            return true
        default:
            return false
        }
    }

    /// Reads the current default output device's transport type from CoreAudio and
    /// maps it to whether the route is Bluetooth. Returns false if anything can't
    /// be read (the safe default — never pad against an unknown route).
    private static func currentOutputIsBluetooth() -> Bool {
        guard let outputDeviceID = currentDefaultOutputDeviceID() else {
            return false
        }
        return classifyBluetoothOutput(transportType: transportType(of: outputDeviceID))
    }

    /// The CoreAudio four-char-code for the built-in output "headphone jack"
    /// data source ('hdpn'). CoreAudio reports data sources as big-endian
    /// four-char codes, matching how the constants are written in headers.
    /// `nonisolated` so both the pure classifier and the tests read it without
    /// an actor hop.
    nonisolated static let headphoneJackDataSource: UInt32 = fourCharCode("hdpn")

    // MARK: - CoreAudio reads

    /// The AudioDeviceID of the system default output device, or nil if it can't
    /// be read.
    private static func currentDefaultOutputDeviceID() -> AudioDeviceID? {
        var address = defaultOutputDevicePropertyAddress
        var outputDeviceID = AudioDeviceID(kAudioObjectUnknown)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize,
            &outputDeviceID
        )
        guard status == noErr, outputDeviceID != AudioDeviceID(kAudioObjectUnknown) else {
            return nil
        }
        return outputDeviceID
    }

    /// The transport type of a device, or `kAudioDeviceTransportTypeUnknown` if
    /// it can't be read (which classifies as speaker — the safe default).
    private static func transportType(of deviceID: AudioDeviceID) -> UInt32 {
        var address = transportTypePropertyAddress
        var transportType: UInt32 = kAudioDeviceTransportTypeUnknown
        var propertySize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, &transportType)
        guard status == noErr else { return kAudioDeviceTransportTypeUnknown }
        return transportType
    }

    /// The OUTPUT data-source four-char code of a device, or nil if the device
    /// has no selectable output data source (most non-built-in devices don't —
    /// then only the transport type matters).
    private static func outputDataSource(of deviceID: AudioDeviceID) -> UInt32? {
        var address = outputDataSourcePropertyAddress
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var dataSource: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, &dataSource)
        guard status == noErr else { return nil }
        return dataSource
    }

    // MARK: - Listeners

    /// Listen for the system default output device changing (e.g. AirPods
    /// connect → macOS switches output to them). On change we reclassify AND
    /// re-point the data-source listener at the new device.
    private func installDefaultOutputDeviceChangeListener() {
        var address = Self.defaultOutputDevicePropertyAddress
        let listenerBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // CoreAudio may call this on an arbitrary internal queue; hop to the
            // main actor where all our state (and @Published) lives.
            Task { @MainActor in
                guard let self else { return }
                self.reclassifyAndPublish()
                self.installDataSourceChangeListenerForCurrentDevice()
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, nil, listenerBlock
        )
        if status == noErr {
            self.defaultDeviceChangeListenerBlock = listenerBlock
        } else {
            print("🎧 AudioOutputRoute: failed to add default-output-device listener (status \(status))")
        }
    }

    /// Attach a data-source-change listener to the CURRENT default output
    /// device, first detaching any listener on the previously-observed device.
    /// This catches the built-in output flipping between the speaker and the
    /// headphone jack WITHOUT the default device itself changing.
    private func installDataSourceChangeListenerForCurrentDevice() {
        guard let currentDeviceID = Self.currentDefaultOutputDeviceID() else { return }

        // Nothing to do if we're already listening to this exact device.
        guard currentDeviceID != observedOutputDeviceID else { return }

        // Detach from the old device first.
        if observedOutputDeviceID != AudioDeviceID(kAudioObjectUnknown),
           let dataSourceChangeListenerBlock {
            var oldAddress = Self.outputDataSourcePropertyAddress
            AudioObjectRemovePropertyListenerBlock(
                observedOutputDeviceID, &oldAddress, nil, dataSourceChangeListenerBlock
            )
        }

        var address = Self.outputDataSourcePropertyAddress
        // Some output devices have no selectable data source; only listen when
        // the property exists (otherwise the add would fail harmlessly anyway).
        guard AudioObjectHasProperty(currentDeviceID, &address) else {
            observedOutputDeviceID = currentDeviceID
            dataSourceChangeListenerBlock = nil
            return
        }

        let listenerBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                self?.reclassifyAndPublish()
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(currentDeviceID, &address, nil, listenerBlock)
        if status == noErr {
            observedOutputDeviceID = currentDeviceID
            dataSourceChangeListenerBlock = listenerBlock
        } else {
            print("🎧 AudioOutputRoute: failed to add data-source listener (status \(status))")
        }
    }
}

// MARK: - Four-char-code helper

/// Build the CoreAudio four-char-code `UInt32` for a 4-character ASCII string
/// (e.g. "hdpn"), matching how CoreAudio encodes selectors and data sources
/// (first character in the most-significant byte). Non-ASCII or wrong-length
/// input yields 0, which never matches a real data source.
nonisolated func fourCharCode(_ string: String) -> UInt32 {
    let asciiValues = string.unicodeScalars.filter { $0.isASCII }.map { UInt32($0.value) }
    guard asciiValues.count == 4 else { return 0 }
    return (asciiValues[0] << 24) | (asciiValues[1] << 16) | (asciiValues[2] << 8) | asciiValues[3]
}
