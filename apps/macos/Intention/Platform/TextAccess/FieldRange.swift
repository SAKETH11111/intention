import Foundation

/// A UTF-16 range as Accessibility reports it.
struct FieldRange: Equatable, Sendable {
    var location: Int
    var length: Int

    var upperBound: Int { location + length }

    init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }

    init(_ range: CFRange) {
        self.init(location: range.location, length: range.length)
    }

    var cfRange: CFRange { CFRange(location: location, length: length) }
}
