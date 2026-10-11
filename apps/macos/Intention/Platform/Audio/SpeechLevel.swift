import Foundation

/// How loud a chunk of recorded speech is, from 0 for silence to 1 for
/// loud speech close to the microphone, for the indicators to show that
/// Intention hears the person. Only loudness is computed; nothing is kept.
enum SpeechLevel {
    /// Below this the chunk counts as silence: room noise on a laptop's
    /// microphone sits around -60 dBFS.
    static let floor = -52.0
    /// At or above this the chunk is as loud as shown: close speech peaks
    /// near -10 dBFS.
    static let ceiling = -14.0

    /// The level of 16-bit little-endian mono PCM, as `SpeechAudioConverter`
    /// produces it, from its root mean square in decibels.
    static func of(_ pcm: Data) -> Double {
        let count = pcm.count / 2
        guard count > 0 else { return 0 }
        let sum = pcm.withUnsafeBytes { raw -> Double in
            var total = 0.0
            for index in 0..<count {
                let sample = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))) / 32_768
                total += sample * sample
            }
            return total
        }
        return of(rms: (sum / Double(count)).squareRoot())
    }

    /// The same mapping for mono samples before resampling or chunking.
    static func of(rms: Double) -> Double {
        guard rms.isFinite, rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(1, max(0, (decibels - floor) / (ceiling - floor)))
    }
}
