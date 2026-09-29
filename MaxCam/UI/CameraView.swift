import SwiftUI

/// Root camera screen. All controls are filtered by the live capability
/// matrix so only supported options are ever presented.
struct CameraView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var showCapabilities = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if viewModel.isReady {
                    CameraPreview(session: viewModel.engine.session)
                        .ignoresSafeArea()
                        .overlay(alignment: .top) { topBar }
                        .overlay(alignment: .bottom) { bottomControls }
                } else if let error = viewModel.lastError {
                    VStack(spacing: 12) {
                        Text("Camera unavailable").font(.headline).foregroundColor(.white)
                        Text(error).font(.footnote).foregroundColor(.secondary).multilineTextAlignment(.center)
                    }
                    .padding()
                } else {
                    ProgressView("Starting camera...")
                        .tint(.white)
                        .foregroundColor(.white)
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Capabilities") { showCapabilities = true }
                        .foregroundColor(.white)
                }
            }
            .sheet(isPresented: $showCapabilities) {
                CapabilitiesView(capabilities: viewModel.capabilities)
            }
        }
        .onAppear { viewModel.start() }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Text(viewModel.stats.isRecording ? "REC" : "STBY")
                .font(.subheadline.weight(.bold))
                .foregroundColor(viewModel.stats.isRecording ? .red : .white)
            Text(viewModel.selectedConfiguration?.summary ?? "No config")
                .font(.caption2.monospaced())
                .foregroundColor(.white)
            Spacer()
            Text(String(format: "%.0f fps", viewModel.stats.currentFPS))
                .font(.caption2.monospaced())
                .foregroundColor(.white)
            if viewModel.stats.droppedFrames > 0 {
                Text("\(viewModel.stats.droppedFrames) dropped")
                    .font(.caption2.monospaced())
                    .foregroundColor(.orange)
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .shadow(color: .black.opacity(0.6), radius: 3)
    }

    private var bottomControls: some View {
        VStack(spacing: 12) {
            if let config = viewModel.selectedConfiguration {
                Text(formatDetails(config))
                    .font(.caption2.monospaced())
                    .foregroundColor(.white)
            }

            HStack(spacing: 24) {
                Text("ISO \(viewModel.stats.isRecording ? "custom" : "auto")")
                Text("1/48")
                Text("WB AWB")
                Spacer()
            }
            .font(.caption.monospaced())
            .foregroundColor(.white)
            .padding(.horizontal)
            .shadow(color: .black.opacity(0.6), radius: 3)

            recordButton
                .padding(.bottom, 24)
        }
    }

    private var recordButton: some View {
        Button(action: { viewModel.toggleRecording() }) {
            ZStack {
                Circle().strokeBorder(Color.white, lineWidth: 4)
                    .frame(width: 72, height: 72)
                Circle()
                    .fill(viewModel.stats.isRecording ? Color.red : Color.white)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: viewModel.stats.isRecording ? 8 : 28))
            }
        }
        .buttonStyle(.plain)
    }

    private func formatDetails(_ config: RecordingConfiguration) -> String {
        "\(config.resolutionLabel) | \(Int(config.frameRate)) fps | \(config.codec.rawValue) | \(config.colorSpace.displayName)"
    }
}