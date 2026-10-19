import AVFoundation
import SwiftUI
import UIKit

/// Hosts the capture session's preview layer.
///
/// `AVCaptureVideoPreviewLayer` performs AVFoundation's own display transform:
/// Apple Log, P3-D65 and HLG buffers are tone-mapped for the screen natively.
/// The preview never mutates the buffers that reach the recorder, so the
/// monitoring transform can never leak into the recorded master.
final class CameraPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    /// Called with a point in the capture device's normalized focus coordinate
    /// space, already converted from the tap location.
    var onTapToFocus: ((CGPoint) -> Void)?

    func configure(session: AVCaptureSession) {
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspect
        if gestureRecognizers?.isEmpty ?? true {
            addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
        }
        setNeedsLayout()
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard let onTapToFocus else { return }
        let layerPoint = recognizer.location(in: self)
        // Let AVFoundation do the orientation-correct conversion rather than
        // hand-rolling the transform.
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint)
        onTapToFocus(devicePoint)
    }
}

/// SwiftUI wrapper around the preview layer.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var onTapToFocus: ((CGPoint) -> Void)?

    func makeUIView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        view.backgroundColor = .black
        view.onTapToFocus = onTapToFocus
        view.configure(session: session)
        return view
    }

    func updateUIView(_ uiView: CameraPreviewView, context: Context) {
        uiView.onTapToFocus = onTapToFocus
        if uiView.previewLayer.session !== session {
            uiView.configure(session: session)
        }
    }
}
