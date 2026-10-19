import SwiftUI

/// Format picker. Every row is a configuration the capability matrix proved the
/// device supports; nothing is shown speculatively.
struct FormatPickerView: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                lensSection

                if viewModel.configurations.isEmpty {
                    Section {
                        Text("No recording configuration is available on this device.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                } else {
                    ForEach(viewModel.configurationsByPipeline) { group in
                        Section(header: Text(group.title)) {
                            ForEach(group.configurations) { config in
                                row(for: config)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Format")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var lensSection: some View {
        Section("Lens") {
            ForEach(viewModel.capabilities.rearCameras) { camera in
                Button {
                    viewModel.setLens(camera.uniqueID)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(camera.displayName)
                            Text(camera.constituentLabel)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if camera.uniqueID == viewModel.preferredLensID {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }
    }

    private func row(for config: RecordingConfiguration) -> some View {
        Button {
            viewModel.selectConfiguration(config)
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("\(config.width) x \(config.height)")
                            .font(.subheadline.weight(.semibold))
                        if config.isOpenGate {
                            Text("OPEN GATE")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.green.opacity(0.25))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    Text("\(Int(config.frameRate.rounded())) fps  "
                        + "\(config.bitDepth)-bit \(config.chroma.displayName)")
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                    Text(config.colorLabel)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if config.id == viewModel.selectedConfiguration?.id {
                    Image(systemName: "checkmark")
                }
            }
        }
    }
}
