import SwiftUI
import UIKit

/// Diagnostic screen enumerating every camera hardware/format capability the
/// physical device actually exposes. No fabricated values.
struct CapabilitiesView: View {
    let capabilities: DeviceCapabilities

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Device") {
                    LabeledContent("Model", value: capabilities.modelID)
                    LabeledContent("iOS", value: capabilities.systemVersion)
                    LabeledContent("Build", value: capabilities.osBuild)
                    LabeledContent("Screen scale", value: "\(capabilities.screenScale)x")
                    LabeledContent("Camera access", value: capabilities.hasCameraAccess ? "Granted" : "Not granted")
                }

                ForEach(capabilities.cameras) { camera in
                    Section("\(camera.positionLabel) \(camera.displayName)") {
                        LabeledContent("Device type", value: camera.deviceType.rawValue)
                        LabeledContent("Unique ID", value: camera.uniqueID)
                        LabeledContent("Flash", value: camera.hasFlash ? "Yes" : "No")
                        if let f = camera.lensAperture {
                            LabeledContent("Lens aperture", value: String(format: "f/%.1f", f))
                        }
                        LabeledContent("Formats", value: "\(camera.formats.count)")

                        ForEach(camera.formats) { format in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(format.resolutionLabel)
                                    .font(.footnote.weight(.semibold))
                                ForEach(format.diagnosticLines.dropFirst(), id: \.self) {
                                    line in
                                    Text(line)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Custom Camera Capabilities")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        shareDiagnostics()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
    }

    private func shareDiagnostics() {
        let report = DiagnosticsExport.current().report
        let av = UIActivityViewController(activityItems: [report], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.windows.first?.rootViewController {
            root.present(av, animated: true)
        }
    }
}