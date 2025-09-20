import SwiftUI
import RealityKit
import ARKit

struct ContentView: View {
	@State private var serverURLString: String = UserDefaults.standard.string(forKey: "serverURL") ?? "ws://192.168.1.100:8765"
	@State private var isStreaming: Bool = false

	var body: some View {
		VStack(spacing: 0) {
			HStack {
				TextField("ws://host:8765", text: $serverURLString)
					.textFieldStyle(.roundedBorder)
					.keyboardType(.URL)
					.textInputAutocapitalization(.never)
					.disableAutocorrection(true)
				Button(isStreaming ? "Stop" : "Start") {
					isStreaming.toggle()
					UserDefaults.standard.set(serverURLString, forKey: "serverURL")
					NotificationCenter.default.post(name: .streamToggle, object: nil, userInfo: ["on": isStreaming, "url": serverURLString])
				}
			}
			.padding(8)
			.background(Color(.secondarySystemBackground))

			ARViewContainer()
				.ignoresSafeArea()
		}
	}
}

extension Notification.Name {
	static let streamToggle = Notification.Name("streamToggle")
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

		NotificationCenter.default.addObserver(forName: .streamToggle, object: nil, queue: .main) { note in
			guard let on = note.userInfo?["on"] as? Bool, let url = note.userInfo?["url"] as? String else { return }
			context.coordinator.setStreaming(on: on, urlString: url)
		}

		return arView
	}

	func updateUIView(_ uiView: ARView, context: Context) {}

	func makeCoordinator() -> Coordinator { Coordinator() }

	final class Coordinator: NSObject, ARSessionDelegate {
		private var webSocketTask: URLSessionWebSocketTask?
		private let session = URLSession(configuration: .default)
		private var isStreaming: Bool = false
		private let sendQueue = DispatchQueue(label: "roommapper.stream.queue", qos: .userInitiated)
		private var lastSentByAnchor: [UUID: TimeInterval] = [:]
		private let minSendInterval: TimeInterval = 0.4 // seconds per anchor
		private let pointDownsample: Int = 3 // take every Nth vertex

		func setStreaming(on: Bool, urlString: String) {
			isStreaming = on
			webSocketTask?.cancel(with: .goingAway, reason: nil)
			webSocketTask = nil
			lastSentByAnchor.removeAll()
			guard on, let url = URL(string: urlString) else { return }
			webSocketTask = session.webSocketTask(with: url)
			webSocketTask?.resume()
		}

		func session(_ session: ARSession, didUpdate frame: ARFrame) { }

		func session(_ session: ARSession, didAdd anchors: [ARAnchor]) { handle(anchors: anchors) }
		func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) { handle(anchors: anchors) }

		private func handle(anchors: [ARAnchor]) {
			guard isStreaming, let ws = webSocketTask else { return }
			let now = CACurrentMediaTime()
			for anchor in anchors {
				guard let meshAnchor = anchor as? ARMeshAnchor else { continue }
				let last = lastSentByAnchor[meshAnchor.identifier] ?? 0
				if now - last < minSendInterval { continue }
				lastSentByAnchor[meshAnchor.identifier] = now
				let geometry = meshAnchor.geometry
				sendQueue.async { [weak self] in
					guard let self = self else { return }
					var verts: [Float] = geometry.vertices.asArray()
					// Downsample points by taking every Nth triplet
					if self.pointDownsample > 1 && !verts.isEmpty {
						var reduced: [Float] = []
						reduced.reserveCapacity(verts.count / self.pointDownsample)
						for i in stride(from: 0, to: verts.count, by: self.pointDownsample * 3) {
							guard i + 2 < verts.count else { break }
							reduced.append(verts[i]); reduced.append(verts[i+1]); reduced.append(verts[i+2])
						}
						verts = reduced
					}
					let t = meshAnchor.transform
					let transform: [Float] = [
						t.columns.0.x, t.columns.0.y, t.columns.0.z, t.columns.0.w,
						t.columns.1.x, t.columns.1.y, t.columns.1.z, t.columns.1.w,
						t.columns.2.x, t.columns.2.y, t.columns.2.z, t.columns.2.w,
						t.columns.3.x, t.columns.3.y, t.columns.3.z, t.columns.3.w
					]
					let msg: [String: Any] = [
						"type": "point-cloud",
						"anchorId": meshAnchor.identifier.uuidString,
						"transform": transform,
						"points": verts
					]
					do {
						let data = try JSONSerialization.data(withJSONObject: msg, options: [])
						ws.send(.data(data)) { error in
							if let error = error { print("WebSocket send error: \(error)") }
						}
					} catch {
						print("JSON encode error: \(error)")
					}
				}
			}
		}
	}
}

private extension ARGeometrySource {
	func asArray() -> [Float] {
		let stride = self.stride
		let offset = self.offset
		let count = self.count
		var result = [Float]()
		result.reserveCapacity(count * 3)
		let buffer = self.buffer.contents()
		for i in 0..<count {
			let base = buffer.advanced(by: offset + i * stride)
			let f = base.bindMemory(to: Float.self, capacity: 3)
			result.append(f[0]); result.append(f[1]); result.append(f[2])
		}
		return result
	}
}

private extension ARGeometryElement {
	// No longer used; kept for reference if mesh streaming is restored
	func asArrayUInt32() -> [UInt32] {
		let primitives = self.count
		let indicesPerPrim = self.indexCountPerPrimitive
		var out = [UInt32]()
		out.reserveCapacity(primitives * indicesPerPrim)
		let buffer = self.buffer.contents()
		let startOffset = 0
		if self.bytesPerIndex == 2 {
			for i in 0..<(primitives * indicesPerPrim) {
				let base = buffer.advanced(by: startOffset + i * 2)
				let v = UInt32(base.bindMemory(to: UInt16.self, capacity: 1).pointee)
				out.append(v)
			}
		} else {
			for i in 0..<(primitives * indicesPerPrim) {
				let base = buffer.advanced(by: startOffset + i * 4)
				let v = base.bindMemory(to: UInt32.self, capacity: 1).pointee
				out.append(v)
			}
		}
		return out
	}
}
