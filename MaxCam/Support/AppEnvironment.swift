import Foundation

extension ProcessInfo.ThermalState {
    var displayName: String {
        switch self {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

extension ProcessInfo {
    /// True when the device is hot enough that the app should shed load.
    var isThermallyConstrained: Bool {
        thermalState == .serious || thermalState == .critical
    }
}
