import SwiftUI
import RealityKit
import ARKit
import AVFAudio
import simd
import CoreMotion

class SpatialAudioManager: ObservableObject {
	private let audioEngine = AVAudioEngine()
	private let environmentNode = AVAudioEnvironmentNode()
	private let playerNode = AVAudioPlayerNode()
	private var standardPingBuffer: AVAudioPCMBuffer?
	private var closePingBuffer: AVAudioPCMBuffer?
	private var isSetup = false
	
	@Published var targetWorldPosition: simd_float3?
	@Published var targetScreenPosition: CGPoint?
	@Published var isPlayingPing = false
	
	private var currentCameraPosition: simd_float3 = simd_float3(0, 0, 0)
	private let maxPingInterval: TimeInterval = 1.2 // seconds when far away
	private let minPingInterval: TimeInterval = 0.15 // seconds when very close
	private let maxDistance: Float = 3.0 // meters - distance for slowest pings
	private let minDistance: Float = 0.1 // meters - distance for fastest pings
	private let closeDistance: Float = 0.5 // meters - distance for "close" sound
	
	// Head tracking
	private let headTracker = CMHeadphoneMotionManager()
	private var isHeadTrackingActive = false
	
	// Ping scheduling control
	private var currentPingTask: DispatchWorkItem?
	
	init() {
		setupAudioEngine()
		generatePingSounds()
		setupHeadTracking()
	}
	
	private func setupAudioEngine() {
		// Configure the environment node for spatial audio
		environmentNode.outputType = .headphones
		environmentNode.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
		environmentNode.listenerVectorOrientation = AVAudio3DVectorOrientation(
			forward: AVAudio3DVector(x: 0, y: 0, z: -1),
			up: AVAudio3DVector(x: 0, y: 1, z: 0)
		)
		
		// Attach nodes to audio engine
		audioEngine.attach(playerNode)
		audioEngine.attach(environmentNode)
		
		// Use explicit format to ensure consistency - mono format for spatial audio
		let audioFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
		
		// Connect nodes: playerNode -> environmentNode -> output
		audioEngine.connect(playerNode, to: environmentNode, format: audioFormat)
		audioEngine.connect(environmentNode, to: audioEngine.outputNode, format: nil)
		
		// Configure player node for spatial audio
		playerNode.position = AVAudio3DPoint(x: 0, y: 0, z: -1)
		playerNode.renderingAlgorithm = .HRTF
		
		// Enhanced spatial audio settings for more precise directionality
		environmentNode.distanceAttenuationParameters.maximumDistance = 50.0
		environmentNode.distanceAttenuationParameters.referenceDistance = 1.0
		environmentNode.distanceAttenuationParameters.rolloffFactor = 2.0
		
		// More aggressive reverb settings for better spatial perception
		environmentNode.reverbParameters.enable = true
		environmentNode.reverbParameters.level = 0.1
		environmentNode.reverbParameters.filterParameters.bypass = false
		
		isSetup = true
	}
	
	private func generatePingSounds() {
		let sampleRate: Double = 44100
		let audioFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
		
		// Generate standard ping sound (for when far/medium distance)
		let standardDuration: Float = 0.25
		let standardFrameCount = AVAudioFrameCount(sampleRate * Double(standardDuration))
		guard let standardBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: standardFrameCount) else { return }
		standardBuffer.frameLength = standardFrameCount
		
		if let channelData = standardBuffer.floatChannelData?[0] {
			for i in 0..<Int(standardFrameCount) {
				let time = Float(i) / Float(sampleRate)
				let amplitude = exp(-time * 5.0) * 0.25
				let sample = sin(2.0 * Float.pi * 800 * time) * amplitude
				channelData[i] = sample
			}
		}
		standardPingBuffer = standardBuffer
		
		// Generate close ping sound (pleasant bell-like sound for very close)
		let closeDuration: Float = 0.4
		let closeFrameCount = AVAudioFrameCount(sampleRate * Double(closeDuration))
		guard let closeBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: closeFrameCount) else { return }
		closeBuffer.frameLength = closeFrameCount
		
		if let channelData = closeBuffer.floatChannelData?[0] {
			for i in 0..<Int(closeFrameCount) {
				let time = Float(i) / Float(sampleRate)
				let amplitude = exp(-time * 2.5) * 0.35
				
				// Create a pleasant bell-like sound with harmonics
				let fundamental = sin(2.0 * Float.pi * 1200 * time)
				let harmonic2 = sin(2.0 * Float.pi * 1800 * time) * 0.3
				let harmonic3 = sin(2.0 * Float.pi * 2400 * time) * 0.15
				
				let sample = (fundamental + harmonic2 + harmonic3) * amplitude
				channelData[i] = sample
			}
		}
		closePingBuffer = closeBuffer
	}
	
	private func setupHeadTracking() {
		// Check if head tracking is available (AirPods connected)
		guard headTracker.isDeviceMotionAvailable else {
			print("Head tracking not available - AirPods may not be connected")
			return
		}
		
		// Start head tracking (CMHeadphoneMotionManager handles its own update rate)
		headTracker.startDeviceMotionUpdates(to: .main) { [weak self] (motion, error) in
			guard let self = self, let motion = motion else { return }
			self.updateListenerOrientation(from: motion)
		}
		
		isHeadTrackingActive = true
		print("Head tracking started successfully")
	}
	
	func setTarget(worldPosition: simd_float3) {
		// Stop any existing pinging immediately
		stopPinging()
		
		// Set new target and start pinging
		targetWorldPosition = worldPosition
		startPinging()
	}
	
	func updateListenerPosition(cameraTransform: simd_float4x4) {
		guard isSetup else { return }
		
		// Extract position from camera transform (phone's position in world)
		let position = cameraTransform.columns.3
		
		// Store current camera position for distance calculations
		currentCameraPosition = simd_float3(position.x, position.y, position.z)
		
		// Update listener position from phone's AR tracking
		environmentNode.listenerPosition = AVAudio3DPoint(
			x: position.x, y: position.y, z: position.z
		)
		
		// Listener orientation will be updated separately by head tracking
		// If head tracking is not active, fall back to camera orientation
		if !isHeadTrackingActive {
			let forward = -cameraTransform.columns.2 // Camera looks down negative Z
			let up = cameraTransform.columns.1
			
			environmentNode.listenerVectorOrientation = AVAudio3DVectorOrientation(
				forward: AVAudio3DVector(x: forward.x, y: forward.y, z: forward.z),
				up: AVAudio3DVector(x: up.x, y: up.y, z: up.z)
			)
		}
		
		// Update target audio position if we have a target
		if let target = targetWorldPosition {
			playerNode.position = AVAudio3DPoint(x: target.x, y: target.y, z: target.z)
			updateSpatialAudioEnhancement(targetPosition: target, listenerPosition: currentCameraPosition)
		}
	}
	
	private func updateListenerOrientation(from motion: CMDeviceMotion) {
		guard isSetup else { return }
		
		// Get the rotation matrix from AirPods motion data
		let rotationMatrix = motion.attitude.rotationMatrix
		
		// Extract forward and up vectors from the rotation matrix
		// AirPods coordinate system: X=right, Y=up, Z=forward (toward face)
		// We need to convert to audio coordinate system
		
		// Forward vector (where the user is looking)
		let forward = AVAudio3DVector(
			x: Float(-rotationMatrix.m13), // Negate Z to match audio coordinate system
			y: Float(-rotationMatrix.m23), // Negate Y to match audio coordinate system  
			z: Float(rotationMatrix.m33)   // Z becomes forward in audio coordinates
		)
		
		// Up vector (top of user's head)
		let up = AVAudio3DVector(
			x: Float(rotationMatrix.m12),
			y: Float(rotationMatrix.m22),
			z: Float(-rotationMatrix.m32)
		)
		
		// Update the listener orientation with head tracking data
		environmentNode.listenerVectorOrientation = AVAudio3DVectorOrientation(
			forward: forward,
			up: up
		)
	}
	
	private func updateSpatialAudioEnhancement(targetPosition: simd_float3, listenerPosition: simd_float3) {
		let distance = simd_distance(listenerPosition, targetPosition)
		
		// Calculate direction vector from listener to target
		let direction = targetPosition - listenerPosition
		let normalizedDirection = simd_normalize(direction)
		
		// Enhance distance attenuation for more dramatic spatial effect
		let enhancedDistance = max(0.1, distance)
		environmentNode.distanceAttenuationParameters.referenceDistance = min(1.0, enhancedDistance * 0.5)
		
		// Adjust reverb based on distance for better depth perception
		let reverbLevel = min(0.3, 0.05 + (distance * 0.02))
		environmentNode.reverbParameters.level = Float(reverbLevel)
		
		// Calculate angle-based volume adjustment for more directional effect
		// This makes sounds more directional when they're to the side
		let volumeMultiplier = calculateDirectionalVolume(direction: normalizedDirection)
		playerNode.volume = Float(volumeMultiplier)
	}
	
	private func calculateDirectionalVolume(direction: simd_float3) -> Double {
		// Get the angle from the forward direction (assuming forward is -Z)
		let forward = simd_float3(0, 0, -1)
		let dotProduct = simd_dot(direction, forward)
		let angle = acos(max(-1.0, min(1.0, dotProduct)))
		
		// Create more dramatic volume differences based on angle
		// Sounds directly in front: full volume
		// Sounds to the side: reduced volume
		// Sounds behind: very quiet
		let normalizedAngle = angle / Float.pi // 0 to 1
		
		// Exponential curve for more dramatic directional effect
		let volumeMultiplier = pow(cos(angle * 0.5), 2.0) // More aggressive than linear
		
		return max(0.1, min(1.0, Double(volumeMultiplier))) // Keep some minimum volume
	}
	
	func updateTargetScreenPosition(frame: ARFrame, viewBounds: CGRect) {
		guard let worldPos = targetWorldPosition else {
			targetScreenPosition = nil
			return
		}
		
		// Use ARKit's built-in projection method
		let camera = frame.camera
		let screenPoint = camera.projectPoint(worldPos, 
											  orientation: .portrait, 
											  viewportSize: CGSize(width: viewBounds.width, height: viewBounds.height))
		
		// Check if the point is within the screen bounds
		if screenPoint.x >= 0 && screenPoint.x <= viewBounds.width && 
		   screenPoint.y >= 0 && screenPoint.y <= viewBounds.height {
			targetScreenPosition = CGPoint(x: CGFloat(screenPoint.x), y: CGFloat(screenPoint.y))
		} else {
			targetScreenPosition = nil
		}
	}
	
	private func calculatePingInterval() -> TimeInterval {
		guard let target = targetWorldPosition else { return maxPingInterval }
		
		// Calculate distance between current position and target
		let distance = simd_distance(currentCameraPosition, target)
		
		// Clamp distance to our min/max range
		let clampedDistance = max(minDistance, min(maxDistance, distance))
		
		// Calculate interval: closer = faster pings with exponential curve
		// Normalize distance to 0-1 range (0 = close, 1 = far)
		let normalizedDistance = (clampedDistance - minDistance) / (maxDistance - minDistance)
		
		// Use exponential curve to make pings much more aggressive when close
		let exponentialDistance = pow(normalizedDistance, 2.5)
		let interval = minPingInterval + (maxPingInterval - minPingInterval) * TimeInterval(exponentialDistance)
		
		return interval
	}
	
	private func getCurrentPingBuffer() -> AVAudioPCMBuffer? {
		guard let target = targetWorldPosition else { return standardPingBuffer }
		
		let distance = simd_distance(currentCameraPosition, target)
		
		// Use nice bell sound when very close, standard ping otherwise
		return distance <= closeDistance ? closePingBuffer : standardPingBuffer
	}
	
	private func startPinging() {
		guard isSetup, let _ = standardPingBuffer else { return }
		
		// Start the audio engine if not running
		if !audioEngine.isRunning {
			do {
				try audioEngine.start()
			} catch {
				print("Failed to start audio engine: \(error)")
				return
			}
		}
		
		isPlayingPing = true
		schedulePing()
	}
	
	private func schedulePing() {
		guard isPlayingPing, let buffer = getCurrentPingBuffer() else { return }
		
		// Calculate dynamic interval based on distance
		let interval = calculatePingInterval()
		
		playerNode.scheduleBuffer(buffer, at: nil, options: [], completionHandler: { [weak self] in
			// Create a new task for the next ping
			let nextPingTask = DispatchWorkItem { [weak self] in
				self?.schedulePing()
			}
			
			// Cancel any existing task and store the new one
			self?.currentPingTask?.cancel()
			self?.currentPingTask = nextPingTask
			
			// Schedule the next ping
			DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: nextPingTask)
		})
		
		if !playerNode.isPlaying {
			playerNode.play()
		}
	}
	
	func stopPinging() {
		isPlayingPing = false
		
		// Cancel any scheduled ping tasks
		currentPingTask?.cancel()
		currentPingTask = nil
		
		// Stop the player node and clear any scheduled buffers
		playerNode.stop()
		playerNode.reset()
		
		// Stop the audio engine if it's running
		if audioEngine.isRunning {
			audioEngine.stop()
		}
	}
	
	func stopHeadTracking() {
		if isHeadTrackingActive {
			headTracker.stopDeviceMotionUpdates()
			isHeadTrackingActive = false
			print("Head tracking stopped")
		}
	}
	
	deinit {
		stopPinging()
		stopHeadTracking()
	}
}

struct ContentView: View {
	@State private var serverURLString: String = UserDefaults.standard.string(forKey: "serverURL") ?? "ws://192.168.1.100:8765"
	@State private var isStreaming: Bool = false
	@StateObject private var spatialAudioManager = SpatialAudioManager()

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

			ZStack {
				ARViewContainer(spatialAudioManager: spatialAudioManager)
					.ignoresSafeArea()
				
				// Crosshair in center to show where target will be placed
				VStack {
					Spacer()
					HStack {
						Spacer()
						Image(systemName: "plus")
							.font(.system(size: 24, weight: .medium))
							.foregroundColor(.white)
							.background(
								Circle()
									.fill(Color.black.opacity(0.4))
									.frame(width: 40, height: 40)
							)
						Spacer()
					}
					Spacer()
				}
				
				// Target active indicator
				if spatialAudioManager.isPlayingPing {
					VStack {
						HStack {
							Spacer()
							HStack(spacing: 8) {
								Image(systemName: "speaker.wave.2.fill")
									.font(.system(size: 14))
								Text("Target Active")
									.font(.system(size: 14, weight: .medium))
							}
							.foregroundColor(.white)
							.padding(.horizontal, 12)
							.padding(.vertical, 6)
							.background(Color.green.opacity(0.8))
							.cornerRadius(15)
							Spacer()
						}
						.padding(.top, 20)
						Spacer()
					}
				}
				
				// Target position indicator
				if let targetPos = spatialAudioManager.targetScreenPosition {
					ZStack {
						Circle()
							.stroke(Color.green, lineWidth: 3)
							.frame(width: 30, height: 30)
						
						Circle()
							.fill(Color.green)
							.frame(width: 8, height: 8)
						
						Text("♪")
							.font(.system(size: 16, weight: .bold))
							.foregroundColor(.green)
							.offset(x: 0, y: -20)
					}
					.position(targetPos)
					.animation(.easeInOut(duration: 0.3), value: targetPos)
				}
				
				VStack {
					Spacer()
					HStack {
						Spacer()
						Button(action: {
							// Target selection will be handled by the AR view
							NotificationCenter.default.post(name: .setTargetCenter, object: nil)
						}) {
							Text("Set Target (Center)")
								.font(.system(size: 16, weight: .medium))
								.foregroundColor(.white)
								.padding(.horizontal, 20)
								.padding(.vertical, 12)
								.background(Color.black.opacity(0.6))
								.cornerRadius(25)
						}
						Spacer()
					}
					.padding(.bottom, 50)
				}
			}
		}
	}
}

extension Notification.Name {
	static let streamToggle = Notification.Name("streamToggle")
	static let setTargetCenter = Notification.Name("setTargetCenter")
}

struct ARViewContainer: UIViewRepresentable {
	let spatialAudioManager: SpatialAudioManager
	
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
		context.coordinator.setSpatialAudioManager(spatialAudioManager)
		context.coordinator.setARView(arView)

		NotificationCenter.default.addObserver(forName: .streamToggle, object: nil, queue: .main) { note in
			guard let on = note.userInfo?["on"] as? Bool, let url = note.userInfo?["url"] as? String else { return }
			context.coordinator.setStreaming(on: on, urlString: url)
		}
		
		NotificationCenter.default.addObserver(forName: .setTargetCenter, object: nil, queue: .main) { _ in
			context.coordinator.setTargetAtCenter(arView: arView)
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
		private var spatialAudioManager: SpatialAudioManager?
		private var arView: ARView?

		func setSpatialAudioManager(_ manager: SpatialAudioManager) {
			spatialAudioManager = manager
		}
		
		func setARView(_ view: ARView) {
			arView = view
		}
		
		func setTargetAtCenter(arView: ARView) {
			guard let frame = arView.session.currentFrame else { return }
			
			// Get the center point of the screen
			let screenCenter = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
			
			// Perform hit test from the center of the screen
			let hitTestResults = arView.hitTest(screenCenter, types: [.existingPlaneUsingExtent, .estimatedHorizontalPlane, .featurePoint])
			
			if let result = hitTestResults.first {
				// Convert hit test result to world position
				let worldTransform = result.worldTransform
				let worldPosition = simd_float3(worldTransform.columns.3.x, worldTransform.columns.3.y, worldTransform.columns.3.z)
				
				// Set the target in the spatial audio manager
				spatialAudioManager?.setTarget(worldPosition: worldPosition)
				
				print("Target set at world position: \(worldPosition)")
			} else {
				// Fallback: set target 1 meter in front of the camera
				let cameraTransform = frame.camera.transform
				let cameraPosition = simd_float3(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
				let cameraForward = -simd_float3(cameraTransform.columns.2.x, cameraTransform.columns.2.y, cameraTransform.columns.2.z)
				let targetPosition = cameraPosition + cameraForward * 1.0
				
				spatialAudioManager?.setTarget(worldPosition: targetPosition)
				
				print("Target set at fallback position: \(targetPosition)")
			}
		}

		func setStreaming(on: Bool, urlString: String) {
			isStreaming = on
			webSocketTask?.cancel(with: .goingAway, reason: nil)
			webSocketTask = nil
			lastSentByAnchor.removeAll()
			guard on, let url = URL(string: urlString) else { return }
			webSocketTask = session.webSocketTask(with: url)
			webSocketTask?.resume()
		}

		func session(_ session: ARSession, didUpdate frame: ARFrame) {
			// Update spatial audio listener position and orientation
			spatialAudioManager?.updateListenerPosition(cameraTransform: frame.camera.transform)
			
			// Update target screen position if we have an AR view
			if let arView = arView {
				spatialAudioManager?.updateTargetScreenPosition(
					frame: frame,
					viewBounds: arView.bounds
				)
			}
		}

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