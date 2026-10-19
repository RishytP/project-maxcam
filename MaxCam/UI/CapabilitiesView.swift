import AVFoundation
import SwiftUI
import UIKit

/// "Custom Camera Capabilities" — enumerates exactly what the physical device
/// exposes. No fabricated values: every row comes from an AVFoundation query.
struct CapabilitiesView: View {
    let capabilities: DeviceCapabilities
    let encoder: EncoderCapabilities

    @Environment(\.dismiss) private var dismiss
    @State private var exportText: String?

    var body: some View {
        NavigationStack {
            List {
                deviceSection
                summarySection
                ForEach(capabilities.cameras) { camera in
                    cameraSection(camera)
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
                        exportText = DiagnosticsExport.current().report
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .sheet(item: Binding(
                get: { exportText.map { DiagnosticReport(text: $0) } },
                set: { exportText = $0?.text }
            )) { report in
                ShareSheet(items: [report.text])
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Sections

    private var deviceSection: some View {
        Section("Device") {
            LabeledContent("Model", value: capabilities.modelID)
            LabeledContent("iOS", value: capabilities.systemVersion)
            LabeledContent("Build", value: capabilities.osVersionString)
            LabeledContent("Screen scale", value: "\(capabilities.screenScale)x")
            LabeledContent("Camera access", value: capabilities.hasCameraAccess ? "Granted" : "Not granted")
        }
    }

    private var summarySection: some View {
        Section("Feature summary") {
            ForEach(gates, id: \.feature.rawValue) { verdict in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(verdict.feature.rawValue)
                        Spacer()
                        Text(verdict.isAvailable ? "YES" : "no")
                            .foregroundColor(verdict.isAvailable ? .green : .secondary)
                    }
                    Text(verdict.reason)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            LabeledContent("Movie codecs") {
                Text(encoder.reportLine)
                    .font(.caption2.monospaced())
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private var gates: [CapabilityGate.Verdict] {
        CapabilityGate(capabilities: capabilities, encoder: encoder).allVerdicts
    }

    private func cameraSection(_ camera: CameraDeviceInfo) -> some View {
        Section("\(camera.positionLabel) \(camera.displayName)") {
            LabeledContent("Device type", value: camera.deviceType.rawValue)
            LabeledContent("Unique ID", value: camera.uniqueID)
            LabeledContent("Constituents", value: camera.constituentLabel)
            LabeledContent("Flash", value: camera.hasFlash ? "Yes" : "No")
            if let aperture = camera.lensAperture {
                LabeledContent("Lens aperture", value: String(format: "f/%.1f", aperture))
            }
            LabeledContent("Formats", value: "\(camera.formats.count)")

            ForEach(camera.formats) { format in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(format.resolutionLabel)
                            .font(.footnote.weight(.semibold))
                        if format.isOpenGateCapable {
                            Text("OPEN GATE")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.green.opacity(0.25))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    ForEach(format.diagnosticLines.dropFirst(), id: \.self) { line in
                        Text(line)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func flagRow(_ title: String, _ value: Bool) -> some View {
        LabeledContent(title) {
            Text(value ? "YES" : "no")
                .foregroundColor(value ? .green : .secondary)
        }
    }
}

/// Identifiable wrapper so a plain string can drive a `sheet(item:)`.
private struct DiagnosticReport: Identifiable {
    let text: String
    var id: String { text }
}

/// Minimal share sheet for the diagnostics text.
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
