import SwiftUI

/// Root camera screen. Every control is driven by the live capability matrix so
/// only options the device genuinely advertises are ever presented.
struct CameraView: View {
    @ObservedObject var viewModel: AppViewModel

    @State private var showCapabilities = false
    @State private var showFormatPicker = false
    @State private var showAdvancedControls = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if viewModel.isReady {
                CameraPreview(
                    session: viewModel.engine.session,
                    onTapToFocus: { point in viewModel.focus(at: point) }
                )
                .ignoresSafeArea()
                .overlay(alignment: .top) { statusBar }
                .overlay(alignment: .bottom) { bottomControls }
            } else if let error = viewModel.lastError {
                unavailableView(error)
            } else {
                ProgressView("Starting camera...")
                    .tint(.white)
                    .foregroundColor(.white)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
        .sheet(isPresented: $showCapabilities) {
            CapabilitiesView(
                capabilities: viewModel.capabilities,
                encoder: viewModel.encoder,
                raw: viewModel.raw
            )
        }
        .sheet(isPresented: $showFormatPicker) {
            FormatPickerView(viewModel: viewModel)
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Text(viewModel.stats.isRecording ? "REC" : "STBY")
                    .font(.caption.weight(.heavy))
                    .foregroundColor(viewModel.stats.isRecording ? .red : .white)

                if viewModel.stats.isRecording {
                    Text(timecode(viewModel.stats.recordedDuration))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.white)
                }

                Spacer()

                Button {
                    showCapabilities = true
                } label: {
                    Image(systemName: "info.circle")
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 10) {
                Text(viewModel.selectedConfiguration?.summary ?? "No format available")
                    .font(.caption2.monospaced())
                    .foregroundColor(.white)
                    .lineLimit(1)
                Spacer()
                Text(String(format: "%.1f fps", viewModel.stats.currentFPS))
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.white)
            }

            HStack(spacing: 10) {
                if viewModel.stats.isThermallyConstrained {
                    Label(thermalLabel, systemImage: "thermometer.high")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
                if viewModel.stats.isLowPowerModeEnabled {
                    Text("LOW POWER")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(.yellow)
                }
                if viewModel.stats.droppedFrames > 0 {
                    Text("\(viewModel.stats.droppedFrames) dropped")
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.orange)
                }
                Spacer()
            }

            if let error = viewModel.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .shadow(color: .black.opacity(0.8), radius: 3)
    }

    // MARK: - Bottom controls

    private var bottomControls: some View {
        VStack(spacing: 14) {
            if showAdvancedControls {
                advancedControls
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            readoutRow

            HStack(alignment: .center, spacing: 28) {
                Button {
                    showFormatPicker = true
                } label: {
                    Text("FORMAT")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)

                recordButton

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showAdvancedControls.toggle()
                    }
                } label: {
                    Image(systemName: showAdvancedControls ? "chevron.down" : "slider.horizontal.3")
                        .font(.title3)
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 28)
        }
    }

    private var readoutRow: some View {
        HStack(spacing: 18) {
            Text(isoLabel)
            Text(shutterLabel)
            Text(wbLabel)
            Text(String(format: "%.0f fps", viewModel.stats.currentFPS))
            Spacer()
        }
        .font(.caption2.monospaced())
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .shadow(color: .black.opacity(0.8), radius: 3)
    }

    private var isoLabel: String {
        guard let iso = viewModel.manualISO else { return "ISO AUTO" }
        return "ISO \(Int(iso))"
    }

    private var shutterLabel: String {
        guard let denominator = viewModel.manualShutterDenominator else { return "SHUTTER AUTO" }
        return "1/\(denominator)"
    }

    private var wbLabel: String {
        guard let temperature = viewModel.manualTemperature else { return "WB AUTO" }
        return "\(Int(temperature))K"
    }

    private var advancedControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("EXPOSURE")
                    .font(.caption2.weight(.bold))
                    .foregroundColor(.secondary)
                Spacer()
                Button(viewModel.isAutoExposure ? "AUTO" : "RESET") {
                    viewModel.setAutoExposure()
                }
                .font(.caption2.weight(.bold))
                .foregroundColor(viewModel.isAutoExposure ? .green : .white)
            }

            if let range = viewModel.isoRange {
                stepperRow(
                    title: "ISO",
                    value: viewModel.manualISO.map { "\(Int($0))" } ?? "auto",
                    onDown: {
                        let current = viewModel.manualISO ?? range.lowerBound
                        viewModel.manualISO = max(range.lowerBound, current - isoStep(range))
                        viewModel.applyManualControls()
                    },
                    onUp: {
                        let current = viewModel.manualISO ?? range.lowerBound
                        viewModel.manualISO = min(range.upperBound, current + isoStep(range))
                        viewModel.applyManualControls()
                    }
                )
                Text("Range \(Int(range.lowerBound))–\(Int(range.upperBound))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if !viewModel.shutterDenominators.isEmpty {
                stepperRow(
                    title: "SHUTTER",
                    value: viewModel.manualShutterDenominator.map { "1/\($0)" } ?? "auto",
                    onDown: { stepShutter(by: -1) },
                    onUp: { stepShutter(by: 1) }
                )
            }

            stepperRow(
                title: "WB",
                value: viewModel.manualTemperature.map { "\(Int($0))K" } ?? "auto",
                onDown: { stepTemperature(by: -100) },
                onUp: { stepTemperature(by: 100) }
            )

            Button("Lock white balance") {
                if viewModel.manualTemperature == nil { viewModel.manualTemperature = 5600 }
                viewModel.applyManualControls()
            }
            .font(.caption2.weight(.bold))
            .foregroundColor(.white)
        }
        .padding(12)
        .background(.black.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
    }

    private func stepperRow(
        title: String,
        value: String,
        onDown: @escaping () -> Void,
        onUp: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundColor(.secondary)
                .frame(width: 66, alignment: .leading)
            Button(action: onDown) {
                Image(systemName: "minus.circle.fill").foregroundColor(.white)
            }
            .buttonStyle(.plain)
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundColor(.white)
                .frame(minWidth: 72)
            Button(action: onUp) {
                Image(systemName: "plus.circle.fill").foregroundColor(.white)
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }

    private func isoStep(_ range: ClosedRange<Float>) -> Float {
        max(1, (range.upperBound - range.lowerBound) / 100)
    }

    private func stepShutter(by offset: Int) {
        let denominators = viewModel.shutterDenominators
        guard !denominators.isEmpty else { return }
        let current = viewModel.manualShutterDenominator ?? denominators.first!
        let index = denominators.firstIndex(of: current)
            ?? denominators.firstIndex(where: { $0 >= current })
            ?? 0
        let next = min(max(index + offset, 0), denominators.count - 1)
        viewModel.manualShutterDenominator = denominators[next]
        viewModel.applyManualControls()
    }

    private func stepTemperature(by delta: Float) {
        let current = viewModel.manualTemperature ?? 5600
        viewModel.manualTemperature = min(max(current + delta, 2000), 10000)
        viewModel.applyManualControls()
    }

    private var recordButton: some View {
        Button(action: { viewModel.toggleRecording() }) {
            ZStack {
                Circle()
                    .strokeBorder(Color.white, lineWidth: 4)
                    .frame(width: 72, height: 72)
                Circle()
                    .fill(viewModel.stats.isRecording ? Color.red : Color.white)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: viewModel.stats.isRecording ? 8 : 28))
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func unavailableView(_ error: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "video.slash")
                .font(.largeTitle)
                .foregroundColor(.white)
            Text("Camera unavailable")
                .font(.headline)
                .foregroundColor(.white)
            Text(error)
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("Capabilities") { showCapabilities = true }
                .foregroundColor(.white)
        }
        .padding()
    }

    private var thermalLabel: String {
        switch viewModel.stats.thermalState {
        case .serious: return "THERMAL: SERIOUS"
        case .critical: return "THERMAL: CRITICAL"
        default: return "THERMAL: \(viewModel.stats.thermalState.displayName.uppercased())"
        }
    }

    private func timecode(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
