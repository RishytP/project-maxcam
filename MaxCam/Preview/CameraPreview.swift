import AVFoundation
import SwiftUI
import UIKit

/// Thin UIView that hosts the capture session's preview layer.
///
/// The `AVCaptureVideoPreviewLayer` performs AVFoundation's own display
/// transform: Apple Log, P3-D65, and HLG buffers are tone-mapped for the
/// screen natively, and the preview NEVER mutates the recorded pixel buffers.
final class CameraPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    func configure(session: AVCaptureSession) {
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspect
        setNeedsLayout()
    }

    func updateOrientation(for interfaceOrientation: UIInterfaceOrientation) {
        guard let connection = previewLayer.connection, connection.isVideoOrientationSupported else { return }
        let orientation: AVCaptureVideoOrientation
        switch interfaceOrientation {
        case .portrait: orientation = .portrait
        case .portraitUpsideDown: orientation = .portraitUpsideDown
        case .landscapeLeft: orientation = .landscapeRight
        case .landscapeRight: orientation = .landscapeLeft
        default: orientation = .portrait
        }
        connection.videoOrientation = orientation
    }
}

/// SwiftUI wrapper. `onChange` of the session identity re-wires the preview.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        view.configure(session: session)
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: CameraPreviewView, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.configure(session: session)
        }
        uiView.setNeedsLayout()
    }
}