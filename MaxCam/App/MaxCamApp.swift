import SwiftUI

@main
struct MaxCamApp: App {
    @StateObject private var viewModel = AppViewModel(engine: CameraEngine())

    var body: some Scene {
        WindowGroup {
            CameraView(viewModel: viewModel)
                .preferredColorScheme(.dark)
        }
    }
}