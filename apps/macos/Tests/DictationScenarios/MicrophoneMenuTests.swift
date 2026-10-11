import CoreAudio
import Foundation
import Testing
@testable import Dictation

@MainActor
struct MicrophoneMenuTests {
    private typealias Inputs = MadeUpInputs

    @Test func rowsKeepTheWordsAndStableIdentityWhenADeviceIsRenamed() {
        let rig = MeterRig()
        let rows = rig.menu.rows
        #expect(rows.map(\.title) == ["Built-in microphone (recommended)", "System default", "AirPods Pro", "USB Microphone"])
        #expect(rows.map(\.isRecommended) == [true, false, false, false])
        #expect(rows.map(\.isChosen) == [true, false, false, false])
        #expect(rows[1].detail == "Follows macOS: AirPods Pro")
        #expect(rows.allSatisfy { $0.level == nil && $0.canHear })
        rig.menu.choose(.device(uid: Inputs.usb.uid, name: "Old name"))
        #expect(rig.preferences.microphone == .device(uid: Inputs.usb.uid, name: "Old name"))
        #expect(rig.menu.rows[3].isChosen)
        #expect(rig.menu.rows[3].id == rows[3].id)
        #expect(rig.menu.label == "USB Microphone")
        #expect(rig.menu.note == nil)
    }

    @Test func additionalBuiltInDevicesAreListedAndASavedBuiltInIsConnected() {
        let rig = MeterRig()
        let second = AudioInput(id: 42, uid: "second-internal", name: "Second internal input", isBuiltIn: true)
        rig.menu.updateInputs(Inputs.inputs([Inputs.builtIn, second], default: Inputs.builtIn))
        #expect(rig.menu.rows.map(\.title) == ["Built-in microphone (recommended)", "System default", "Second internal input"])
        rig.menu.choose(.device(uid: Inputs.builtIn.uid, name: "Old internal name"))
        let chosen = rig.menu.rows.first { $0.isChosen }
        #expect(chosen?.title == Inputs.builtIn.name)
        #expect(chosen?.canHear == true)
    }

    @Test func missingAndClosedLidRowsCannotHear() {
        let rig = MeterRig()
        rig.menu.choose(.device(uid: "missing", name: "Desk Mic"))
        rig.menu.updateInputs(Inputs.inputs([Inputs.builtIn], default: Inputs.builtIn, lidClosed: true))
        let rows = rig.menu.rows
        #expect(rows.map(\.canHear) == [false, false, false])
        #expect(rows[0].detail == "Off while the lid is closed")
        #expect(rows[2].title == "Desk Mic (not connected)")
        #expect(rows[2].detail == "Not connected")
        #expect(rows[2].isChosen)
        #expect(rows.allSatisfy { $0.level == nil })
        rig.menu.startMetering()
        #expect(rig.engine.opened.isEmpty)
        rig.menu.stopMetering()
    }

    @Test func missingDeviceTakesPrecedenceOverPermissionAndMeteringState() {
        let rig = MeterRig()
        rig.authorized = false
        rig.menu.choose(.device(uid: "missing", name: "Desk Mic"))
        rig.menu.updateInputs(.none)
        for metering in [false, true] {
            if metering { rig.menu.startMetering() }
            #expect(rig.menu.rows.map(\.quiet) == [.notConnected, .notConnected, .notConnected])
        }
        #expect(rig.engine.opened.isEmpty)
        rig.menu.stopMetering()
    }

    @Test func closedLidTakesPrecedenceOverTransportPermissionAndEngineRefusal() {
        let rig = MeterRig()
        rig.authorized = false
        rig.engine.transports[Inputs.builtIn.id] = "bluetooth"
        rig.engine.blocked.insert(Inputs.builtIn.id)
        rig.menu.updateInputs(Inputs.inputs([Inputs.builtIn], default: Inputs.builtIn, lidClosed: true))
        for metering in [false, true] {
            if metering { rig.menu.startMetering() }
            #expect(rig.menu.rows.map(\.quiet) == [.lidClosed, .lidClosed])
        }
        #expect(rig.engine.opened.isEmpty)
        rig.menu.stopMetering()
    }

    @Test func bothBluetoothTransportsTakePrecedenceOverPermissionAndEngineRefusal() {
        for transport in ["bluetooth", "bluetoothLE"] {
            let rig = MeterRig()
            rig.authorized = false
            rig.engine.transports[Inputs.airPods.id] = transport
            for metering in [false, true] {
                if metering { rig.menu.startMetering() }
                // System default resolves to these same AirPods.
                #expect(rig.menu.rows[1].quiet == .bluetooth)
                #expect(rig.menu.rows[2].quiet == .bluetooth)
            }
            #expect(rig.engine.opened.isEmpty)
            rig.authorized = true
            rig.menu.poll()
            #expect(rig.menu.rows[1].quiet == .bluetooth)
            #expect(rig.menu.rows[2].quiet == .bluetooth)
            #expect(!rig.engine.opened.contains(Inputs.airPods.id))
            rig.menu.stopMetering()
        }
    }

    @Test func permissionTakesPrecedenceOverAnUnmeterableEngine() {
        let rig = MeterRig()
        rig.authorized = false
        rig.engine.blocked.insert(Inputs.usb.id)
        for metering in [false, true] {
            if metering { rig.menu.startMetering() }
            #expect(rig.menu.rows[0].quiet == .notAllowed)
            #expect(rig.menu.rows[3].quiet == .notAllowed)
        }
        #expect(rig.engine.opened.isEmpty)
        rig.menu.stopMetering()
    }

    @Test func engineRefusalIsUnavailableBeforeAndDuringMetering() {
        let rig = MeterRig()
        rig.engine.transports[Inputs.usb.id] = "aggregate"
        rig.engine.blocked.insert(Inputs.usb.id)
        rig.menu.updateInputs(Inputs.inputs([Inputs.builtIn, Inputs.usb], default: Inputs.usb))
        for metering in [false, true] {
            if metering { rig.menu.startMetering() }
            #expect(rig.menu.rows[1].quiet == .unavailable)
            #expect(rig.menu.rows[2].quiet == .unavailable)
        }
        #expect(rig.engine.opened == [Inputs.builtIn.id])
        rig.menu.stopMetering()
    }

    @Test func authorizedBuiltInHasNoQuietReasonWithoutRequiringALevel() {
        let rig = MeterRig()
        rig.menu.updateInputs(Inputs.inputs([Inputs.builtIn], default: Inputs.builtIn))
        #expect(rig.menu.rows.map(\.quiet) == [nil, nil])
        #expect(rig.menu.rows.allSatisfy { $0.level == nil })
        rig.menu.startMetering()
        #expect(rig.menu.rows.map(\.quiet) == [nil, nil])
        rig.menu.poll()
        #expect(rig.menu.rows.allSatisfy { $0.quiet == nil && $0.level != nil })
        rig.menu.setRecording(true)
        #expect(rig.menu.rows.allSatisfy { $0.quiet == nil && $0.level == nil })
        rig.menu.stopMetering()
        #expect(rig.menu.rows.map(\.quiet) == [nil, nil])
    }

    @Test func unauthorizedStartOpensNothingAndRevocationClosesEverything() {
        let rig = MeterRig()
        rig.authorized = false
        rig.menu.startMetering()
        rig.menu.poll()
        #expect(rig.engine.opened.isEmpty)
        #expect(rig.menu.rows.allSatisfy { $0.level == nil })
        rig.authorized = true
        rig.menu.poll()
        #expect(rig.engine.opened == [Inputs.builtIn.id, Inputs.usb.id])
        rig.authorized = false
        rig.menu.poll()
        #expect(rig.engine.handles.allSatisfy { $0.stops == 1 })
        #expect(rig.menu.rows.allSatisfy { $0.level == nil })
        rig.menu.stopMetering()
    }

    @Test func nativeBoundaryChecksAuthorizationAndBothBluetoothTransportsBeforeOpening() {
        for allowed in [false, true] {
            for transport in ["bluetooth", "bluetoothLE", "aggregate", "usb", "builtIn"] {
                var opens = 0
                let engine = NativeMicrophoneMeter(authorized: { allowed }, transport: { _ in transport },
                    makeInput: { _ in opens += 1; return FakeMeterInput() })
                #expect(engine.isBluetooth(Inputs.usb) == (transport == "bluetooth" || transport == "bluetoothLE"))
                let opened = engine.open(Inputs.usb)
                let permitted = allowed && transport != "bluetooth" && transport != "bluetoothLE" && transport != "aggregate"
                #expect(opens == (permitted ? 1 : 0))
                #expect((opened != nil) == permitted)
                opened?.stop()
            }
        }
    }

    @Test func bluetoothAndBluetoothLENeverOpen() {
        let rig = MeterRig()
        rig.engine.blocked.insert(Inputs.usb.id) // A second Bluetooth transport.
        rig.menu.startMetering()
        #expect(rig.engine.opened == [Inputs.builtIn.id])
        rig.menu.poll()
        #expect(rig.menu.rows[1].level == nil)
        #expect(rig.menu.rows[2].level == nil)
        #expect(rig.menu.rows[3].level == nil)
        rig.menu.stopMetering()
    }

    @Test func pauseClosesSynchronouslyAndResumesOnlyWhileRequested() {
        let rig = MeterRig()
        rig.menu.startMetering()
        rig.menu.setRecording(true)
        #expect(rig.engine.handles.allSatisfy { $0.stops == 1 })
        #expect(rig.menu.rows.allSatisfy { $0.level == nil })
        rig.menu.poll()
        #expect(rig.engine.opened.count == 2)
        rig.menu.setRecording(false)
        #expect(rig.engine.opened.count == 4)
        rig.menu.stopMetering()
        rig.menu.setRecording(true)
        rig.menu.setRecording(false)
        #expect(rig.engine.opened.count == 4)
        rig.menu.startMetering()
        rig.menu.setRecording(true)
        rig.menu.stopMetering()
        rig.menu.setRecording(false)
        #expect(rig.engine.opened.count == 6)
    }

    @Test func deviceRemovalAndLidClosingStopTheirInputs() {
        let rig = MeterRig()
        rig.menu.startMetering()
        rig.menu.updateInputs(Inputs.inputs([Inputs.builtIn], default: Inputs.builtIn))
        #expect(rig.engine.handles[1].stops == 1)
        #expect(rig.engine.handles[0].stops == 0)
        rig.menu.updateInputs(Inputs.inputs([Inputs.builtIn], default: Inputs.builtIn, lidClosed: true))
        #expect(rig.engine.handles[0].stops == 1)
        rig.menu.stopMetering()
        rig.menu.stopMetering()
        #expect(rig.engine.handles.allSatisfy { $0.stops == 1 })
    }

    @Test func timerIsSafeFromBackgroundAndQueuedTicksCannotReopenAfterStop() async throws {
        let rig = MeterRig()
        rig.menu.startMetering()
        let callback = rig.menu.timerCallback()
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { callback(); continuation.resume() }
        }
        #expect(await eventually { rig.menu.rows[0].level != nil })
        let level = try #require(rig.menu.rows[0].level)
        #expect(level >= 0 && level <= 1)
        rig.menu.stopMetering()
        rig.menu.stopMetering()
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { callback(); continuation.resume() }
        }
        await Task.yield()
        #expect(rig.menu.rows.allSatisfy { $0.level == nil })
        #expect(rig.engine.opened.count == 2)
        #expect(rig.engine.handles.allSatisfy { $0.stops == 1 })
    }

    @Test func cancelingTheScopedMeterStopsEveryInput() async {
        let rig = MeterRig()
        let task = Task { await rig.menu.metering() }
        #expect(await eventually { rig.engine.opened.count == 2 })
        task.cancel()
        await task.value
        #expect(!rig.menu.isMetering)
        #expect(rig.menu.rows.allSatisfy { $0.level == nil })
        #expect(rig.engine.handles.allSatisfy { $0.stops == 1 })
    }

    @Test func anOldCanceledScopeCannotStopANewSession() async {
        let rig = MeterRig()
        let first = Task { await rig.menu.metering() }
        #expect(await eventually { rig.engine.opened.count == 2 })
        rig.menu.stopMetering()
        let second = Task { await rig.menu.metering() }
        #expect(await eventually { rig.engine.opened.count == 4 })
        first.cancel()
        await first.value
        #expect(rig.menu.isMetering)
        #expect(rig.engine.handles.suffix(2).allSatisfy { $0.stops == 0 })
        second.cancel()
        await second.value
        #expect(!rig.menu.isMetering)
        #expect(rig.engine.handles.allSatisfy { $0.stops == 1 })
    }

    @Test func overlappingScopesAndExplicitStartKeepTheirOwnLifetime() async {
        let rig = MeterRig()
        let first = Task { await rig.menu.metering() }
        #expect(await eventually { rig.engine.opened.count == 2 })
        var secondStarted = false
        let second = Task {
            secondStarted = true
            await rig.menu.metering()
        }
        #expect(await eventually { secondStarted })
        first.cancel()
        await first.value
        #expect(rig.menu.isMetering)
        rig.menu.startMetering()
        second.cancel()
        await second.value
        #expect(rig.menu.isMetering)
        rig.menu.stopMetering()
        #expect(rig.engine.opened.count == 2)
        #expect(rig.engine.handles.allSatisfy { $0.stops == 1 })
    }

    @Test func failedOpenHasNoLevelAndDuplicateStartDoesNotReopen() {
        let rig = MeterRig()
        rig.engine.failures.insert(Inputs.usb.id)
        rig.menu.updateInputs(Inputs.inputs([Inputs.builtIn, Inputs.usb], default: Inputs.usb))
        rig.menu.startMetering()
        rig.menu.startMetering()
        rig.menu.poll()
        #expect(rig.engine.opened.filter { $0 == Inputs.builtIn.id }.count == 1)
        #expect(rig.menu.rows[2].level == nil)
        #expect(rig.menu.rows[1].quiet == .unavailable)
        #expect(rig.menu.rows[2].quiet == .unavailable)
        rig.authorized = false
        #expect(rig.menu.rows[1].quiet == .notAllowed)
        #expect(rig.menu.rows[2].quiet == .notAllowed)
        #expect(rig.engine.opened.filter { $0 == Inputs.usb.id }.count == 1)
        rig.authorized = true
        rig.menu.setRecording(true)
        #expect(rig.menu.rows[2].quiet == .unavailable)
        rig.menu.stopMetering()
        #expect(rig.menu.rows[2].quiet == .unavailable)
        rig.engine.failures.remove(Inputs.usb.id)
        rig.menu.setRecording(false)
        rig.menu.startMetering()
        #expect(rig.menu.rows[2].quiet == nil)
        #expect(rig.engine.opened.filter { $0 == Inputs.usb.id }.count == 2)
        rig.menu.stopMetering()
    }

    @Test func mixedStreamsAndPlanarChannelsUseTheirOwnNativeFormats() async throws {
        try await Task.detached {
            let floating = Self.format(bits: 32, flags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked)
            let integer = Self.format(bits: 16, flags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked)
            // Float32 +0.5 and Int16 -0.5, each little endian.
            let mixed = try Self.measure(formats: [floating, integer], bytes: [[0, 0, 0, 0x3f], [0, 0xc0]])
            #expect(abs(mixed - 0.5) < 0.000001)
            let planar = Self.format(bits: 64, flags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved, channels: 2)
            let separate = try Self.measure(formats: [planar],
                bytes: [[0, 0, 0, 0, 0, 0, 0xe0, 0x3f], [0, 0, 0, 0, 0, 0, 0xe0, 0xbf]])
            #expect(abs(separate - 0.5) < 0.000001)
        }.value
    }

    @Test func packedIntegerFormatsRespectSignAndEndianness() async throws {
        try await Task.detached {
            for (bits, bigEndian, bytes) in [
                (16, true, [UInt8(0xc0), 0]),
                (24, false, [0, 0, 0xc0]),
                (24, true, [0xc0, 0, 0]),
                (32, false, [0, 0, 0, 0xc0]),
                (32, true, [0xc0, 0, 0, 0])
            ] {
                let flags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | (bigEndian ? kAudioFormatFlagIsBigEndian : 0)
                let measured = try Self.measure(formats: [Self.format(bits: UInt32(bits), flags: flags)], bytes: [bytes])
                #expect(abs(measured - 0.5) < 0.000001)
            }
        }.value
    }

    nonisolated private static func format(bits: UInt32, flags: AudioFormatFlags, channels: UInt32 = 1) -> AudioStreamBasicDescription {
        let count: UInt32 = flags & kAudioFormatFlagIsNonInterleaved != 0 ? 1 : channels
        return AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: flags, mBytesPerPacket: bits / 8 * count, mFramesPerPacket: 1,
            mBytesPerFrame: bits / 8 * count, mChannelsPerFrame: channels, mBitsPerChannel: bits, mReserved: 0)
    }

    nonisolated private static func measure(formats: [AudioStreamBasicDescription], bytes: [[UInt8]]) throws -> Double {
        let samples = try #require(MeterSamples(formats: formats))
        let buffers = AudioBufferList.allocate(maximumBuffers: bytes.count)
        defer {
            for buffer in buffers { buffer.mData?.deallocate() }
            buffers.unsafeMutablePointer.deallocate()
        }
        for (index, data) in bytes.enumerated() {
            let storage = UnsafeMutableRawPointer.allocate(byteCount: data.count, alignment: 8)
            data.withUnsafeBytes { storage.copyMemory(from: $0.baseAddress!, byteCount: data.count) }
            buffers[index] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(data.count), mData: storage)
        }
        let time = AudioTimeStamp()
        var output = AudioBufferList(mNumberBuffers: 0, mBuffers: AudioBuffer())
        let result = withUnsafePointer(to: time) { stamp in
            microphoneMeterCallback(0, stamp, buffers.unsafePointer, stamp, &output, stamp,
                Unmanaged.passUnretained(samples).toOpaque())
        }
        #expect(result == noErr)
        return samples.rms()
    }

    /// Calls the exact Core Audio C callback with synthetic native-format
    /// buffers on its own queue. No device, authorization API or mic opens.
    @Test func nativeCallbackMeasuresRMSOffActor() async throws {
        try await Task.detached {
            let format = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
            let samples = try #require(MeterSamples(format: format))
            #expect(samples.rms() == 0)
            var data: [Float] = [0.5, -0.5, 0.5, -0.5]
            data.withUnsafeMutableBytes { bytes in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2,
                    mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
                let time = AudioTimeStamp()
                var output = AudioBufferList(mNumberBuffers: 0, mBuffers: AudioBuffer())
                let result = withUnsafePointer(to: time) { stamp in
                    microphoneMeterCallback(0, stamp, &list, stamp, &output, stamp,
                        Unmanaged.passUnretained(samples).toOpaque())
                }
                #expect(result == noErr)
            }
            #expect(abs(samples.rms() - 0.5) < 0.000001)
        }.value
    }
}

@MainActor
private final class MeterRig {
    let engine = FakeMeterEngine()
    let preferences: Preferences
    var authorized = true
    lazy var menu = MicrophoneMenu(inputs: MadeUpInputs.inputs([MadeUpInputs.builtIn, MadeUpInputs.airPods, MadeUpInputs.usb], default: MadeUpInputs.airPods),
        engine: engine, authorized: { [unowned self] in authorized },
        preference: { [preferences] in preferences.microphone },
        choose: { [preferences] in preferences.microphone = $0 })
    init() {
        let defaults = UserDefaults(suiteName: "MicrophoneMenuTests." + UUID().uuidString)!
        preferences = Preferences(defaults: defaults)
    }
}

@MainActor
private final class FakeMeterEngine: MicrophoneMeterEngine {
    var transports: [UInt32: String] = [MadeUpInputs.builtIn.id: "builtIn",
        MadeUpInputs.airPods.id: "bluetooth", MadeUpInputs.usb.id: "usb"]
    var blocked: Set<UInt32> = [MadeUpInputs.airPods.id]
    var failures: Set<UInt32> = []
    var opened: [UInt32] = []
    var handles: [FakeMeterInput] = []
    func isBluetooth(_ device: AudioInput) -> Bool {
        transports[device.id] == "bluetooth" || transports[device.id] == "bluetoothLE"
    }
    func isMeterable(_ device: AudioInput) -> Bool { !blocked.contains(device.id) }
    func open(_ device: AudioInput) -> (any MicrophoneMeterInput)? {
        opened.append(device.id)
        guard !failures.contains(device.id) else { return nil }
        let input = FakeMeterInput()
        handles.append(input)
        return input
    }
}

@MainActor
private final class FakeMeterInput: MicrophoneMeterInput {
    var stops = 0
    func rms() -> Double? { 0.1 }
    func stop() { stops += 1 }
}
