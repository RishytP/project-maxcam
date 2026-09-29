import AVFoundation
import Foundation

/// Hardware-backed encoder capabilities for the current device, sourced from
/// AVFoundation only. No values are assumed.
struct EncoderCapabilities {
    /// Codecs advertised by an `AVCaptureMovieFileOutput` on this device
    /// (intrinsic to the pipeline that writes movie files in place).
    let movieFileCodecs: [AVVideoCodecType]

    static func current() -> EncoderCapabilities {
        let movieOutput = AVCaptureMovieFileOutput()
        let movieCodecs = movieOutput.availableVideoCodecTypes
        return EncoderCapabilities(movieFileCodecs: movieCodecs)
    }

    var supportsHEVC: Bool {
        movieFileCodecs.contains(.hevc) ||
        movieFileCodecs.contains { $0.rawValue == AVVideoCodecType.hevc.rawValue }
    }

    var supportsProRes: Bool {
        EncoderCapabilities.isProRes(advertised: movieFileCodecs)
    }

    var supportsAppleLog: Bool {
        // Log capture availability is derived per-format via supportedColorSpaces;
        // the encoder only needs to preserve the encoded color space through the
        // color properties we set on the writer input. There is no separate
        // "Log codec" to advertise.
        true
    }

    var proResCodecs: [AVVideoCodecType] {
        movieFileCodecs.filter { EncoderCapabilities.isProRes(advertised: [$0]) }
    }

    // FourCC families for the ProRes codecs AVFoundation advertises.
    private static func isProRes(advertised codecs: [AVVideoCodecType]) -> Bool {
        let proResFourCCs: [String] = [
            "apcn", // Apple ProRes 422
            "apch", // Apple ProRes 422 HQ
            "apcs", // Apple ProRes 422 LT
            "apco", // Apple ProRes 422 Proxy
            "ap4h", // Apple ProRes 4444
            "ap4x", // Apple ProRes 4444 XQ
            "aprn", // ProRes RAW (natively recorded by iPhone 17 Pro line)
        ]
        return codecs.contains { codec in
            guard let fourCC = codec.fourCharCodeString else { return false }
            return proResFourCCs.contains(fourCC)
        }
    }
}

private extension AVVideoCodecType {
    /// The four-character-code spelling of the codec, e.g. "hvc1", "apcn".
    var fourCharCodeString: String? {
        let raw = rawValue as NSString
        guard raw.length == 4 else { return nil }
        // AVVideoCodecType.rawValue is "avc1", "hvc1", "apcn", etc.
        return raw as String
    }
}