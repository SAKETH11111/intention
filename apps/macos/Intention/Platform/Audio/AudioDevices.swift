import AudioToolbox
import CoreAudio
import Foundation
import IOKit

/// Core Audio's and IOKit's answers about input devices and the lid. Each
/// is a property read: no device is opened, so none needs a permission.
enum AudioHardware {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    /// The inputs as they are now.
    static func inputs() -> AudioInputs {
        let devices: [AudioDeviceID] = list(of: system, kAudioHardwarePropertyDevices)
        return AudioInputs(devices: devices.compactMap(input), systemDefault: defaultInput, lidClosed: lidClosed)
    }

    /// What a recording on `device` listens to, so `Microphone` asks the
    /// rule whether to move whenever one changes: the default input, the
    /// list of devices, and the device's state, sample rate, input channels
    /// and input sources. `inputs()` drops a device whose sources are gone
    /// while Core Audio goes on listing it with its rate and channels as
    /// they were, so only its own listener tells a recording.
    static func watchedWhileRecording(_ device: AudioDeviceID) -> [(object: AudioObjectID, property: AudioObjectPropertyAddress)] {
        [(system, address(kAudioHardwarePropertyDefaultInputDevice)),
         (system, address(kAudioHardwarePropertyDevices)),
         (device, address(kAudioDevicePropertyDeviceIsAlive)),
         (device, address(kAudioDevicePropertyNominalSampleRate)),
         (device, address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)),
         (device, address(kAudioDevicePropertyDataSources, scope: kAudioObjectPropertyScopeInput))]
    }

    /// `device` when it is an input that can record now, as System
    /// Settings lists inputs: alive, with input channels, not hidden, and
    /// with something to record from.
    private static func input(_ device: AudioDeviceID) -> AudioInput? {
        guard inputChannels(of: device) > 0, isAlive(device), (value(of: device, kAudioDevicePropertyIsHidden) as UInt32?) != 1,
              (value(of: device, kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: kAudioObjectPropertyScopeInput) as UInt32?) != 0,
              hasSource(device), let uid = string(of: device, kAudioDevicePropertyDeviceUID) else { return nil }
        return AudioInput(id: device, uid: uid, name: string(of: device, kAudioObjectPropertyName) ?? uid,
                          isBuiltIn: (value(of: device, kAudioDevicePropertyTransportType) as UInt32?) == kAudioDeviceTransportTypeBuiltIn)
    }

    /// A device that lists where its input comes from, as a built-in
    /// microphone does ("imic" on a MacBook Pro, October 2026), needs at
    /// least one source; one that lists none has nothing to record.
    private static func hasSource(_ device: AudioDeviceID) -> Bool {
        var property = address(kAudioDevicePropertyDataSources, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectHasProperty(device, &property),
              AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size) == noErr else { return true }
        return size >= UInt32(MemoryLayout<UInt32>.size)
    }

    /// Whether a MacBook's lid is closed. Apple notebooks cut their
    /// microphone off in hardware then, while Core Audio may go on listing
    /// it, so this comes from power management, as Wispr Flow reads it. A
    /// Mac without a lid reports none, which counts as open.
    static var lidClosed: Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let state = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return state as? Bool ?? false
    }

    static var defaultInput: AudioDeviceID? {
        let device: AudioDeviceID? = value(of: system, kAudioHardwarePropertyDefaultInputDevice)
        return device == kAudioObjectUnknown ? nil : device
    }

    static func isAlive(_ device: AudioDeviceID) -> Bool {
        (value(of: device, kAudioDevicePropertyDeviceIsAlive) as UInt32?) == 1
    }

    static func sampleRate(of device: AudioDeviceID) -> Double? {
        value(of: device, kAudioDevicePropertyNominalSampleRate)
    }

    static func inputChannels(of device: AudioDeviceID) -> UInt32 {
        var property = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, list) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + $1.mNumberChannels }
    }

    /// A fixed name for how the device is attached, safe to log.
    static func transport(of device: AudioDeviceID) -> String {
        switch value(of: device, kAudioDevicePropertyTransportType) as UInt32? {
        case kAudioDeviceTransportTypeBuiltIn: "builtIn"
        case kAudioDeviceTransportTypeBluetooth: "bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: "bluetoothLE"
        case kAudioDeviceTransportTypeUSB: "usb"
        case kAudioDeviceTransportTypeAggregate: "aggregate"
        case kAudioDeviceTransportTypeVirtual: "virtual"
        default: "other"
        }
    }

    /// An input-only HAL unit bound to `device`, not yet initialized.
    static func inputUnit(for device: AudioDeviceID) -> AudioUnit? {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { return nil }
        var instance: AudioUnit?
        guard AudioComponentInstanceNew(component, &instance) == noErr, let unit = instance else { return nil }
        var on: UInt32 = 1, off: UInt32 = 0, device = device
        let size = UInt32(MemoryLayout<UInt32>.size)
        // Input must be enabled before the device is chosen.
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, size) == noErr,
              AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, size) == noErr,
              AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device,
                                   UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
            AudioComponentInstanceDispose(unit)
            return nil
        }
        return unit
    }

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func value<T>(of object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var property = address(selector, scope: scope)
        guard AudioObjectHasProperty(object, &property) else { return nil }
        var size = UInt32(MemoryLayout<T>.size)
        let result = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { result.deallocate() }
        guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, result) == noErr else { return nil }
        return result.pointee
    }

    private static func string(of object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var property = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let result = UnsafeMutablePointer<Unmanaged<CFString>?>.allocate(capacity: 1)
        result.initialize(to: nil)
        defer { result.deallocate() }
        guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, result) == noErr, let text = result.pointee else { return nil }
        return text.takeRetainedValue() as String
    }

    private static func list<T>(of object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [T] {
        var property = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size) == noErr, size >= MemoryLayout<T>.stride else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let result = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { result.deallocate() }
        guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, result) == noErr else { return [] }
        return Array(UnsafeBufferPointer(start: result, count: min(count, Int(size) / MemoryLayout<T>.stride)))
    }
}

/// Carries listener calls from Core Audio's and IOKit's threads to a
/// handler on the main actor. A listener is registered under a number
/// rather than a pointer, so a call that arrives while it is removed finds
/// nothing instead of freed memory.
enum DeviceNotices {
    @MainActor private static var handlers: [Int: @MainActor () -> Void] = [:]
    @MainActor private static var last = 0

    /// A number for a new listener, whose calls run `handler`.
    @MainActor static func add(_ handler: @escaping @MainActor () -> Void) -> Int {
        last += 1
        handlers[last] = handler
        return last
    }

    @MainActor static func remove(_ number: Int) {
        handlers[number] = nil
    }

    /// From any thread: runs the handler registered as `number` on the
    /// main actor, if it is still there.
    nonisolated static func noticed(_ number: Int) {
        DispatchQueue.main.async { MainActor.assumeIsolated { handlers[number]?() } }
    }
}

/// Core Audio's property listener, given its listener's number. Core Audio
/// calls it on a thread of its own. It is a C function rather than a
/// block: a listener block comes into Swift as a closure, and the closure
/// removed is never the one added, so a block listener could not be
/// removed and would outlive what it reports to.
let audioPropertyChanged: AudioObjectPropertyListenerProc = { _, _, _, number in
    DeviceNotices.noticed(Int(bitPattern: number))
    return noErr
}

/// `kIOPMMessageClamshellStateChange` from IOKit/pwr_mgt/IOPM.h, which
/// Swift does not import: the power-management root's general-interest
/// message when a MacBook's lid opens or closes.
let clamshellStateChange: UInt32 = 0xE003_4100

/// IOKit's interest callback on the power-management root, given its
/// listener's number, on the lid listener's queue. Only the lid counts.
let lidChanged: IOServiceInterestCallback = { number, _, message, _ in
    guard message == clamshellStateChange else { return }
    DeviceNotices.noticed(Int(bitPattern: number))
}

/// Core Audio property listeners that report to one number, removed
/// together.
struct PropertyListeners {
    let number: Int
    private var added: [(AudioObjectID, AudioObjectPropertyAddress)] = []

    init(number: Int) {
        self.number = number
    }

    mutating func listen(to object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) {
        listen(to: object, AudioHardware.address(selector, scope: scope))
    }

    mutating func listen(to object: AudioObjectID, _ property: AudioObjectPropertyAddress) {
        var property = property
        guard AudioObjectAddPropertyListener(object, &property, audioPropertyChanged, UnsafeMutableRawPointer(bitPattern: number)) == noErr else { return }
        added.append((object, property))
    }

    mutating func removeAll() {
        for (object, property) in added {
            var property = property
            AudioObjectRemovePropertyListener(object, &property, audioPropertyChanged, UnsafeMutableRawPointer(bitPattern: number))
        }
        added = []
    }
}

/// Hears a MacBook's lid open and close through IOKit's power-management
/// notice, for the listener `number`. Whoever handles the notice reads the
/// lid again. A Mac without a lid never sends one.
final class LidListener {
    private static let queue = DispatchQueue(label: "co.intention.mac.lid")
    private var port: IONotificationPortRef?
    private var notification: io_object_t = 0

    init(number: Int) {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return }
        defer { IOObjectRelease(root) }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        IONotificationPortSetDispatchQueue(port, Self.queue)
        guard IOServiceAddInterestNotification(port, root, kIOGeneralInterest, lidChanged, UnsafeMutableRawPointer(bitPattern: number),
                                               &notification) == KERN_SUCCESS else {
            IONotificationPortDestroy(port)
            return
        }
        self.port = port
    }

    /// Whether IOKit took the listener.
    var isListening: Bool { notification != 0 }

    /// Stops listening. A notice already on its way finds its number gone.
    func remove() {
        if notification != 0 {
            IOObjectRelease(notification)
            notification = 0
        }
        if let port {
            IONotificationPortDestroy(port)
            self.port = nil
        }
    }

    deinit {
        remove()
    }
}

/// The inputs as they are now, followed while Settings shows the
/// Microphone choice, so its row says what a dictation would use. A
/// dictation reads the inputs itself when it starts.
@MainActor
@Observable
final class AudioInputWatch {
    private(set) var inputs = AudioInputs.none
    @ObservationIgnored var changed: (@MainActor (AudioInputs) -> Void)?
    /// Its number in `DeviceNotices` while it follows, nil otherwise.
    @ObservationIgnored private(set) var listening: Int?
    @ObservationIgnored private let read: @MainActor () -> AudioInputs

    /// Reads the inputs as it is made, so Settings never opens on an empty
    /// list before following starts.
    init(read: @escaping @MainActor () -> AudioInputs = AudioHardware.inputs) {
        self.read = read
        inputs = read()
    }

    /// Follows the inputs until the task is cancelled: the list of devices,
    /// the default input and the lid, and every few seconds anything a
    /// listener does not report, such as a device losing its source.
    func follow() async {
        let number = DeviceNotices.add { [weak self] in self?.refresh() }
        var listeners = PropertyListeners(number: number)
        listeners.listen(to: AudioHardware.system, kAudioHardwarePropertyDevices)
        listeners.listen(to: AudioHardware.system, kAudioHardwarePropertyDefaultInputDevice)
        let lid = LidListener(number: number)
        listening = number
        refresh()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { refresh() }
        }
        listeners.removeAll()
        lid.remove()
        DeviceNotices.remove(number)
        listening = nil
    }

    private func refresh() {
        let now = read()
        // Only a change redraws the row.
        if now != inputs {
            inputs = now
            changed?(now)
        }
    }
}
