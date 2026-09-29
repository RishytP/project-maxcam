import AVFoundation
import Foundation

/// Named, runtime-provable capture configuration constraints that the matcher
/// uses to describe *why* a given option is (or is not) available.
enum CapabilityGate: Equatable, Sendable {
    case formatLacks(option: String, requirement: String)
    case fpsOutOfRange
    case noColorSpaceNamed(String)
    case codecNotAdvertised(String)
    case hdrNotAdvertised
    case thermalCritical
    case missingDevice

    var reason: String {
        switch self {
        case .formatLacks(let option, let requirement):
            return "\(option) is not supported by the active format (\(requirement))."
        case .fpsOutOfRange:
            return "The selected frame rate is not inside the format's supported range."
        case .noColorSpaceNamed(let name):
            return "The active color space \"\(name)\" is not enumerated by this format."
        case .codecNotAdvertised(let codec):
            return "The codec \"\(codec)\" is not advertised as supported."
        case .hdrNotAdvertised:
            return "The format does not advertise video HDR support."
        case .thermalCritical:
            return "Device thermal state is critical; recording is halted."
        case .missingDevice:
            return "No matching camera device exists."
        }
    }
}