import AVFoundation
import CoreAudio
import Darwin
import Foundation

/// Opens independent native-format input callbacks. No aggregate device,
/// resampling, audio storage, or output is involved.
@MainActor
struct NativeMicrophoneMeter: MicrophoneMeterEngine {
    private let authorized: @MainActor () -> Bool
    private let transport: @MainActor (AudioDeviceID) -> String
    private let makeInput: @MainActor (AudioDeviceID) -> (any MicrophoneMeterInput)?

    init(authorized: @escaping @MainActor () -> Bool = { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized },
         transport: @escaping @MainActor (AudioDeviceID) -> String = AudioHardware.transport,
         makeInput: @escaping @MainActor (AudioDeviceID) -> (any MicrophoneMeterInput)? = { NativeMeterInput(device: $0) }) {
        self.authorized = authorized
        self.transport = transport
        self.makeInput = makeInput
    }

    func isBluetooth(_ device: AudioInput) -> Bool {
        let transport = transport(device.id)
        return transport == "bluetooth" || transport == "bluetoothLE"
    }

    func isMeterable(_ device: AudioInput) -> Bool {
        Self.isMeterable(transport: transport(device.id))
    }

    static func isMeterable(transport: String) -> Bool {
        // An aggregate can gain a Bluetooth subdevice while open. Its direct
        // transport cannot promise that metering leaves headsets out of calls.
        transport != "bluetooth" && transport != "bluetoothLE" && transport != "aggregate"
    }

    func open(_ device: AudioInput) -> (any MicrophoneMeterInput)? {
        // Repeat both gates at the hardware boundary, even if the caller was
        // authorized when it assembled its list. This API never asks for access.
        guard authorized(), isMeterable(device) else { return nil }
        return makeInput(device.id)
    }
}

/// Core Audio owns callback scheduling. Only the atomic RMS word is mutable on
/// that thread; the format and storage live until the IOProc has been destroyed.
final class MeterSamples: @unchecked Sendable {
    private let formats: [MeterSampleFormat]
    private let latest: UnsafeMutablePointer<Int64>

    convenience init?(format: AudioStreamBasicDescription) { self.init(formats: [format]) }

    init?(formats: [AudioStreamBasicDescription]) {
        var buffers: [MeterSampleFormat] = []
        for format in formats {
            guard let encoding = MeterSampleFormat(format: format) else { return nil }
            let count = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? Int(format.mChannelsPerFrame) : 1
            buffers.append(contentsOf: repeatElement(encoding, count: count))
        }
        guard !buffers.isEmpty else { return nil }
        self.formats = buffers
        latest = .allocate(capacity: 1)
        latest.initialize(to: 0)
    }

    deinit { latest.deinitialize(count: 1); latest.deallocate() }

    // OSAtomic remains available on the app's macOS 14 minimum. Swift's Atomic
    // requires macOS 15. These aligned 64-bit operations are lock-free on Macs.
    func rms() -> Double {
        Double(bitPattern: UInt64(bitPattern: OSAtomicAdd64Barrier(0, latest)))
    }

    func receive(_ buffers: UnsafePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffers))
        var squares = 0.0
        var count = 0
        guard list.count == formats.count else { store(0); return }
        for (index, buffer) in list.enumerated() {
            let format = formats[index]
            let bytesPerSample = format.bytesPerSample
            let floatingPoint = format.floatingPoint
            let bigEndian = format.bigEndian
            guard let data = buffer.mData else { continue }
            let samples = Int(buffer.mDataByteSize) / bytesPerSample
            for index in 0..<samples {
                let offset = index * bytesPerSample
                let sample: Double
                if floatingPoint && bytesPerSample == 4 {
                    let bits = data.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                    sample = Double(Float(bitPattern: bigEndian ? UInt32(bigEndian: bits) : UInt32(littleEndian: bits)))
                } else if floatingPoint {
                    let bits = data.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
                    sample = Double(bitPattern: bigEndian ? UInt64(bigEndian: bits) : UInt64(littleEndian: bits))
                } else if bytesPerSample == 2 {
                    let bits = data.loadUnaligned(fromByteOffset: offset, as: Int16.self)
                    sample = Double(bigEndian ? Int16(bigEndian: bits) : Int16(littleEndian: bits)) / 32_768
                } else if bytesPerSample == 4 {
                    let bits = data.loadUnaligned(fromByteOffset: offset, as: Int32.self)
                    sample = Double(bigEndian ? Int32(bigEndian: bits) : Int32(littleEndian: bits)) / 2_147_483_648
                } else {
                    let a = UInt32(data.load(fromByteOffset: offset, as: UInt8.self))
                    let b = UInt32(data.load(fromByteOffset: offset + 1, as: UInt8.self))
                    let c = UInt32(data.load(fromByteOffset: offset + 2, as: UInt8.self))
                    let bits = bigEndian ? (a << 16 | b << 8 | c) : (c << 16 | b << 8 | a)
                    sample = Double(Int32(bitPattern: bits << 8)) / 2_147_483_648
                }
                if sample.isFinite { squares += sample * sample }
            }
            count += samples
        }
        let value = count > 0 ? sqrt(squares / Double(count)) : 0
        store(value)
    }

    private func store(_ value: Double) {
        let bits = Int64(bitPattern: value.bitPattern)
        var previous = OSAtomicAdd64Barrier(0, latest)
        while !OSAtomicCompareAndSwap64Barrier(previous, bits, latest) {
            previous = OSAtomicAdd64Barrier(0, latest)
        }
    }
}

private struct MeterSampleFormat {
    let bytesPerSample: Int
    let floatingPoint: Bool
    let bigEndian: Bool

    init?(format: AudioStreamBasicDescription) {
        let flags = format.mFormatFlags
        let floatingPoint = flags & kAudioFormatFlagIsFloat != 0
        let bits = Int(format.mBitsPerChannel)
        guard format.mFormatID == kAudioFormatLinearPCM,
              flags & kAudioFormatFlagIsPacked != 0,
              (floatingPoint && [32, 64].contains(bits))
                || (!floatingPoint && flags & kAudioFormatFlagIsSignedInteger != 0 && [16, 24, 32].contains(bits)),
              format.mChannelsPerFrame > 0 else { return nil }
        let channels = flags & kAudioFormatFlagIsNonInterleaved != 0 ? 1 : format.mChannelsPerFrame
        guard format.mBytesPerFrame == UInt32(bits / 8) * channels else { return nil }
        bytesPerSample = bits / 8
        self.floatingPoint = floatingPoint
        bigEndian = flags & kAudioFormatFlagIsBigEndian != 0
    }
}

/// A C callback has no actor isolation, performs no allocation or locking, and
/// calls no UI or dispatch API. Core Audio supplies the device's native buffers.
let microphoneMeterCallback: AudioDeviceIOProc = { _, _, input, _, _, _, context in
    guard let context else { return noErr }
    Unmanaged<MeterSamples>.fromOpaque(context).takeUnretainedValue().receive(input)
    return noErr
}

@MainActor
private final class NativeMeterInput: MicrophoneMeterInput {
    private let device: AudioDeviceID
    private var samples: MeterSamples?
    private var proc: AudioDeviceIOProcID?
    private var number: Int?
    private var listeners: PropertyListeners?

    init?(device: AudioDeviceID) {
        self.device = device
        guard startInput() else { return nil }
        let number = DeviceNotices.add { [weak self] in self?.restart() }
        self.number = number
        listen(number: number)
    }

    private func startInput() -> Bool {
        // Property-change restarts obey the same gates as the first open.
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              NativeMicrophoneMeter.isMeterable(transport: AudioHardware.transport(of: device)) else { return false }
        let streams = Self.list(device, selector: kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        var formats: [AudioStreamBasicDescription] = []
        for stream in streams {
            var format = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var property = AudioHardware.address(kAudioStreamPropertyVirtualFormat)
            guard AudioObjectGetPropertyData(stream, &property, 0, nil, &size, &format) == noErr else { return false }
            formats.append(format)
        }
        guard let samples = MeterSamples(formats: formats) else { return false }
        var proc: AudioDeviceIOProcID?
        guard AudioDeviceCreateIOProcID(device, microphoneMeterCallback,
                                       Unmanaged.passUnretained(samples).toOpaque(), &proc) == noErr,
              let proc else { return false }
        guard AudioDeviceStart(device, proc) == noErr else {
            AudioDeviceDestroyIOProcID(device, proc)
            return false
        }
        self.samples = samples
        self.proc = proc
        return true
    }

    private func listen(number: Int) {
        var listeners = PropertyListeners(number: number)
        listeners.listen(to: device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        listeners.listen(to: device, kAudioDevicePropertyDeviceIsAlive)
        for stream in Self.list(device, selector: kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput) {
            listeners.listen(to: stream, kAudioStreamPropertyVirtualFormat)
        }
        self.listeners = listeners
    }

    private func restart() {
        closeInput()
        listeners?.removeAll()
        _ = startInput()
        if let number { listen(number: number) }
    }

    func rms() -> Double? { samples?.rms() }

    /// A restart that failed leaves no input running.
    var isRunning: Bool { proc != nil }

    private func closeInput() {
        guard let proc else { return }
        AudioDeviceStop(device, proc)
        AudioDeviceDestroyIOProcID(device, proc)
        self.proc = nil
        samples = nil
    }

    func stop() {
        if let number { DeviceNotices.remove(number) }
        number = nil
        listeners?.removeAll()
        listeners = nil
        closeInput()
    }

    private static func list(_ device: AudioObjectID, selector: AudioObjectPropertySelector,
                             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var property = AudioHardware.address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size) == noErr,
              size > 0, size % UInt32(MemoryLayout<AudioObjectID>.size) == 0 else { return [] }
        var values = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = values.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(device, &property, 0, nil, &size, $0.baseAddress!)
        }
        return status == noErr ? Array(values.prefix(Int(size) / MemoryLayout<AudioObjectID>.size)) : []
    }

    isolated deinit { stop() }
}
