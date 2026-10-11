import Foundation
import IOKit

/// Whether a keyboard with fn is connected, so setup can lead with
/// recording a shortcut on a Mac whose keyboard has none, as most keyboards
/// not made by Apple have none macOS can see. Read from the I/O registry's
/// properties alone: no device is opened, so it asks for no permission.
enum KeyboardInventory {
    struct Keyboard: Equatable {
        /// A MacBook's own keyboard.
        let builtIn: Bool
        let vendorID: Int?
    }

    /// Apple's vendor numbers over USB and over Bluetooth. Apple's own
    /// keyboards have fn or the globe key; another maker's fn, where it has
    /// one, stays inside the keyboard and never reaches the Mac.
    static let appleVendors: Set<Int> = [0x05AC, 0x004C]

    /// Whether any of `keyboards` has fn, or nil when there are none to go
    /// by.
    static func hasFnKey(_ keyboards: [Keyboard]) -> Bool? {
        guard !keyboards.isEmpty else { return nil }
        return keyboards.contains { $0.builtIn || $0.vendorID.map(appleVendors.contains) == true }
    }

    /// The keyboards connected now.
    static func connected() -> [Keyboard] {
        guard let matching = IOServiceMatching("IOHIDDevice") as NSMutableDictionary? else { return [] }
        // Generic desktop, keyboard.
        matching["DeviceUsagePage"] = 1
        matching["DeviceUsage"] = 6
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching as CFDictionary, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var keyboards: [Keyboard] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            func property(_ name: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, name as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            keyboards.append(Keyboard(builtIn: (property("Built-In") as? Bool) ?? false,
                                      vendorID: (property("VendorID") as? NSNumber)?.intValue))
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return keyboards
    }
}
