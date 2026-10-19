import AVFoundation
import Foundation

/// Hardware-backed encoder capabilities for the current device, sourced from
/// AVFoundation only. No values are assumed.
///
/// `AVCaptureMovieFileOutput` is what advertises the in-place movie codecs, and
/// that list is also what gates the ProRes family: if the system does not
/// advertise `apcn`/`apch`/…, the device cannot record ProRes and we say so.
struct EncoderCapabilities: @unchecked Sendable {
    let movieFileCodecs: [AVVideoCodecType]

    static func current() -> EncoderCapabilities {
        EncoderCapabilities(movieFileCodecs: AVCaptureMovieFileOutput().availableVideoCodecTypes)
    }

    var supportsHEVC: Bool {
        movieFileCodecs.contains { $0.rawValue == AVVideoCodecType.hevc.rawValue }
    }

    var supportsH264: Bool {
        movieFileCodecs.contains { $0.rawValue == AVVideoCodecType.h264.rawValue }
    }

    /// Standard ProRes 422 family (and 4444). Deliberately excludes ProRes RAW.
    var proResCodecs: [AVVideoCodecType] {
        EncoderCapabilities.standardProRes.filter { movieFileCodecs.contains($0) }
    }

    var supportsProRes: Bool {
        !proResCodecs.isEmpty
    }

    /// ProRes RAW is a different codec from ProRes 422 and is reported
    /// separately. It is only ever true when the system advertises `aprn`.
    var supportsProResRAW: Bool {
        movieFileCodecs.contains { $0.rawValue == "aprn" }
    }

    static let standardProRes: [AVVideoCodecType] = [
        .proRes4444, .proRes422HQ, .proRes422, .proRes422LT, .proRes422Proxy,
    ]

    var reportLine: String {
        movieFileCodecs.isEmpty
            ? "none"
            : movieFileCodecs.map(\.rawValue).joined(separator: ", ")
    }
}
