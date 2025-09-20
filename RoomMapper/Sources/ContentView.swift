import SwiftUI
import RealityKit
import ARKit

struct ContentView: View {
    var body: some View {
        ARViewContainer()
            .ignoresSafeArea()
    }
}

struct ARViewContainer: UIViewRepresentable {
    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)

        guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) else {
            return arView
        }

        let config = ARWorldTrackingConfiguration()
        config.environmentTexturing = .automatic
        config.sceneReconstruction = .mesh
        config.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }

        arView.debugOptions.insert(.showSceneUnderstanding)
        arView.debugOptions.insert(.showWorldOrigin)

        arView.session.run(config)
        arView.session.delegate = context.coordinator

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, ARSessionDelegate {
        func session(_ session: ARSession, didUpdate frame: ARFrame) {
        }

        func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {}
        func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {}
        func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {}

        func session(_ session: ARSession, didFailWithError error: Error) {
            print("ARSession failed: \(error.localizedDescription)")
        }

        func sessionWasInterrupted(_ session: ARSession) {}
        func sessionInterruptionEnded(_ session: ARSession) {}
    }
}
