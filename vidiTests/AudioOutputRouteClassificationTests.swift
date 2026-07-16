//
//  AudioOutputRouteClassificationTests.swift
//  vidiTests
//
//  Verifies the pure output-route classification that drives headphones mode
//  (Workstream S2). `classifyOutputRoute` is the decision that decides whether
//  Vidi keeps the mic live during her speech (private listening → full-duplex
//  barge-in) or gates it (speaker → half-duplex). Extracting it as a pure
//  function of (transport type, built-in data source) is what makes it testable
//  without real audio hardware. Also covers the `vidiHeadphonesMode` override
//  parser and the four-char-code helper the 'hdpn' data source relies on.
//

import CoreAudio
import Testing
@testable import Vidi

struct AudioOutputRouteClassificationTests {

    // MARK: - Bluetooth → private listening (the AirPods case)

    @Test func bluetoothClassifiesAsPrivateListening() {
        // AirPods Pro / AirPods report a Bluetooth transport — the whole reason
        // headphones mode exists.
        let classification = AudioOutputRouteMonitor.classifyOutputRoute(
            transportType: kAudioDeviceTransportTypeBluetooth,
            builtInOutputDataSource: nil
        )
        #expect(classification == .privateListening)
    }

    @Test func bluetoothLEClassifiesAsPrivateListening() {
        let classification = AudioOutputRouteMonitor.classifyOutputRoute(
            transportType: kAudioDeviceTransportTypeBluetoothLE,
            builtInOutputDataSource: nil
        )
        #expect(classification == .privateListening)
    }

    // MARK: - Built-in: headphone jack vs. speaker

    @Test func builtInHeadphoneJackClassifiesAsPrivateListening() {
        // Wired headphones in the built-in jack report data source 'hdpn'.
        let classification = AudioOutputRouteMonitor.classifyOutputRoute(
            transportType: kAudioDeviceTransportTypeBuiltIn,
            builtInOutputDataSource: AudioOutputRouteMonitor.headphoneJackDataSource
        )
        #expect(classification == .privateListening)
    }

    @Test func builtInSpeakerClassifiesAsSpeaker() {
        // The built-in speaker data source ('ispk') — the room hears her.
        let internalSpeakerDataSource = fourCharCode("ispk")
        let classification = AudioOutputRouteMonitor.classifyOutputRoute(
            transportType: kAudioDeviceTransportTypeBuiltIn,
            builtInOutputDataSource: internalSpeakerDataSource
        )
        #expect(classification == .speaker)
    }

    @Test func builtInWithNoDataSourceClassifiesAsSpeaker() {
        // If we can't read a data source, keep the mic gate — never open the mic
        // into a route we can't confirm is private.
        let classification = AudioOutputRouteMonitor.classifyOutputRoute(
            transportType: kAudioDeviceTransportTypeBuiltIn,
            builtInOutputDataSource: nil
        )
        #expect(classification == .speaker)
    }

    // MARK: - Deliberate speakers (USB DAC, HDMI, DisplayPort, AirPlay)

    @Test func usbClassifiesAsSpeaker() {
        // USB is deliberately a speaker: a USB DAC into desk monitors is the
        // common case; a USB headphone amp is forced on via vidiHeadphonesMode.
        let classification = AudioOutputRouteMonitor.classifyOutputRoute(
            transportType: kAudioDeviceTransportTypeUSB,
            builtInOutputDataSource: nil
        )
        #expect(classification == .speaker)
    }

    @Test func hdmiClassifiesAsSpeaker() {
        let classification = AudioOutputRouteMonitor.classifyOutputRoute(
            transportType: kAudioDeviceTransportTypeHDMI,
            builtInOutputDataSource: nil
        )
        #expect(classification == .speaker)
    }

    @Test func displayPortClassifiesAsSpeaker() {
        let classification = AudioOutputRouteMonitor.classifyOutputRoute(
            transportType: kAudioDeviceTransportTypeDisplayPort,
            builtInOutputDataSource: nil
        )
        #expect(classification == .speaker)
    }

    @Test func airPlayClassifiesAsSpeaker() {
        let classification = AudioOutputRouteMonitor.classifyOutputRoute(
            transportType: kAudioDeviceTransportTypeAirPlay,
            builtInOutputDataSource: nil
        )
        #expect(classification == .speaker)
    }

    // MARK: - Unknown transport → safe default (speaker)

    @Test func unknownTransportClassifiesAsSpeaker() {
        let classification = AudioOutputRouteMonitor.classifyOutputRoute(
            transportType: kAudioDeviceTransportTypeUnknown,
            builtInOutputDataSource: nil
        )
        #expect(classification == .speaker)
    }

    // MARK: - Bluetooth transport classification (BUG 2 flap guard)

    @Test func bluetoothClassifiesAsBluetoothOutput() {
        // AirPods on A2DP report Bluetooth transport — the only transport that
        // suffers the HFP→A2DP flap the lead-in silence guards.
        #expect(AudioOutputRouteMonitor.classifyBluetoothOutput(
            transportType: kAudioDeviceTransportTypeBluetooth
        ) == true)
    }

    @Test func bluetoothLEClassifiesAsBluetoothOutput() {
        #expect(AudioOutputRouteMonitor.classifyBluetoothOutput(
            transportType: kAudioDeviceTransportTypeBluetoothLE
        ) == true)
    }

    @Test func wiredHeadphoneJackIsNotBluetoothOutput() {
        // A wired jack is private-listening but NOT Bluetooth — it does not flap
        // profiles, so it must never be padded. Built-in transport → false.
        #expect(AudioOutputRouteMonitor.classifyBluetoothOutput(
            transportType: kAudioDeviceTransportTypeBuiltIn
        ) == false)
    }

    @Test func speakersAndOtherTransportsAreNotBluetoothOutput() {
        #expect(AudioOutputRouteMonitor.classifyBluetoothOutput(
            transportType: kAudioDeviceTransportTypeUSB
        ) == false)
        #expect(AudioOutputRouteMonitor.classifyBluetoothOutput(
            transportType: kAudioDeviceTransportTypeHDMI
        ) == false)
        #expect(AudioOutputRouteMonitor.classifyBluetoothOutput(
            transportType: kAudioDeviceTransportTypeAirPlay
        ) == false)
        #expect(AudioOutputRouteMonitor.classifyBluetoothOutput(
            transportType: kAudioDeviceTransportTypeUnknown
        ) == false)
    }

    // MARK: - Override parsing

    @Test func overrideDefaultsToAutoWhenAbsent() {
        #expect(HeadphonesModeOverride.fromDefaultsValue(nil) == .auto)
    }

    @Test func overrideParsesOnOffAuto() {
        #expect(HeadphonesModeOverride.fromDefaultsValue("on") == .forcedOn)
        #expect(HeadphonesModeOverride.fromDefaultsValue("off") == .forcedOff)
        #expect(HeadphonesModeOverride.fromDefaultsValue("auto") == .auto)
    }

    @Test func overrideIsCaseInsensitive() {
        #expect(HeadphonesModeOverride.fromDefaultsValue("ON") == .forcedOn)
        #expect(HeadphonesModeOverride.fromDefaultsValue("Off") == .forcedOff)
    }

    @Test func overrideFallsBackToAutoOnGarbage() {
        // A typo must never silently disable the mic gate — unknown = auto.
        #expect(HeadphonesModeOverride.fromDefaultsValue("headphones") == .auto)
        #expect(HeadphonesModeOverride.fromDefaultsValue("") == .auto)
    }

    // MARK: - Four-char-code helper

    @Test func fourCharCodeMatchesCoreAudioEncoding() {
        // 'hdpn' big-endian = 0x6864706E. Byte order matters: CoreAudio puts the
        // first character in the most-significant byte.
        #expect(fourCharCode("hdpn") == 0x6864_706E)
    }

    @Test func fourCharCodeRejectsWrongLength() {
        // Not exactly four ASCII chars → 0, which never matches a real source.
        #expect(fourCharCode("hdp") == 0)
        #expect(fourCharCode("hdpns") == 0)
        #expect(fourCharCode("") == 0)
    }
}
