import SwiftUI
import RealityKit
import ARKit
import AVFAudio
import simd
import CoreMotion
import Speech
import Foundation
import UIKit

// MARK: - Proximity Detection with Haptic Feedback
class ProximityDetectionManager: ObservableObject {
	private let lightHaptic = UIImpactFeedbackGenerator(style: .light)
	private let mediumHaptic = UIImpactFeedbackGenerator(style: .medium)
	private let heavyHaptic = UIImpactFeedbackGenerator(style: .heavy)
	private let rigidHaptic = UIImpactFeedbackGenerator(style: .rigid)
	
	@Published var isEnabled = false
	@Published var currentDistance: Float = 10.0
	@Published var isProximityActive = false
	@Published var lastResetTime: TimeInterval = 0
	
	// Detection parameters - expanded range with more granular levels
	private let maxDetectionDistance: Float = 5.0 // meters - extended range
	private let minDetectionDistance: Float = 0.15 // meters
	
	// Distance thresholds for color-coded feedback levels
	private let veryCloseDistance: Float = 0.4 // meters - DARK RED (shake a lot)
	private let closeDistance: Float = 0.8 // meters - RED (shake)
	private let kindOfCloseDistance: Float = 1.5 // meters - ORANGE (decent bit)
	private let mediumDistance: Float = 2.5 // meters - GREEN (a little)
	private let farDistance: Float = 4.0 // meters - BLUE (very little)
	
	// Timing control - more aggressive when close
	private var lastHapticTime: TimeInterval = 0
	private var currentHapticInterval: TimeInterval = 1.0
	private let maxHapticInterval: TimeInterval = 2.0 // very slow when far
	private let minHapticInterval: TimeInterval = 0.05 // extremely fast when very close
	
	// System health monitoring  
	private let resetInterval: TimeInterval = 30.0 // Reset haptic generators every 30 seconds
	private var hapticFailureCount = 0
	
	// Ray sampling for detection
	private let rayCount = 5 // Number of rays to cast in front
	private let raySpread: Float = 0.3 // Radians spread of detection cone
	
	init() {
		// Prepare haptic generators for better responsiveness
		lightHaptic.prepare()
		mediumHaptic.prepare()
		heavyHaptic.prepare()
		rigidHaptic.prepare()
	}
	
	func toggle() {
		isEnabled.toggle()
		if !isEnabled {
			isProximityActive = false
			currentDistance = maxDetectionDistance
			resetHapticSystem() // Clean reset when disabling
		} else {
			// Fresh start when enabling
			resetHapticSystem()
			lastHapticTime = 0
			hapticFailureCount = 0
			print("📳 Proximity detection enabled with fresh haptic system")
		}
		print("📳 Proximity detection \(isEnabled ? "enabled" : "disabled")")
	}
	
	private func resetHapticSystem() {
		// Recreate haptic generators to prevent stuck states
		lightHaptic.prepare()
		mediumHaptic.prepare()
		heavyHaptic.prepare()
		rigidHaptic.prepare()
		
		DispatchQueue.main.async { [weak self] in
			self?.lastResetTime = CACurrentMediaTime()
		}
		print("🔄 Haptic system reset at \(CACurrentMediaTime())")
	}
	
	func forceReset() {
		print("🔧 Force reset proximity detection system")
		resetHapticSystem()
		lastHapticTime = 0
		hapticFailureCount = 0
		isProximityActive = false
		currentDistance = maxDetectionDistance
		
		// Trigger a brief confirmation haptic
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
			self?.lightHaptic.impactOccurred(intensity: 0.5)
			print("✅ Proximity system reset complete")
		}
	}
	
	func updateProximity(frame: ARFrame, arView: ARView) {
		guard isEnabled else { return }
		
		let nearestDistance = detectNearestObstacle(frame: frame, arView: arView)
		
		DispatchQueue.main.async { [weak self] in
			self?.currentDistance = nearestDistance
			self?.updateHapticFeedback(distance: nearestDistance)
		}
	}
	
	private func detectNearestObstacle(frame: ARFrame, arView: ARView) -> Float {
		var minDistance: Float = maxDetectionDistance
		
		let cameraTransform = frame.camera.transform
		let cameraPosition = simd_float3(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
		let forward = -simd_float3(cameraTransform.columns.2.x, cameraTransform.columns.2.y, cameraTransform.columns.2.z)
		
		// Method 1: Try scene reconstruction first (most accurate)
		let meshAnchors = frame.anchors.compactMap({ $0 as? ARMeshAnchor })
		if !meshAnchors.isEmpty {
			for meshAnchor in meshAnchors {
				let distance = checkMeshDistance(cameraPosition: cameraPosition, forward: forward, meshAnchor: meshAnchor)
				minDistance = min(minDistance, distance)
			}
		}
		
		// Method 2: Use depth data if available
		if minDistance >= maxDetectionDistance, let depthData = frame.sceneDepth {
			let depthDistance = checkDepthDistance(frame: frame, arView: arView, depthData: depthData)
			minDistance = min(minDistance, depthDistance)
		}
		
		// Method 3: Raycast fallback
		if minDistance >= maxDetectionDistance {
			let raycastDistance = checkRaycastDistance(arView: arView, cameraPosition: cameraPosition, forward: forward)
			minDistance = min(minDistance, raycastDistance)
		}
		
		return max(minDetectionDistance, minDistance)
	}
	
	private func checkMeshDistance(cameraPosition: simd_float3, forward: simd_float3, meshAnchor: ARMeshAnchor) -> Float {
		let meshTransform = meshAnchor.transform
		let geometry = meshAnchor.geometry
		
		// Sample points from the mesh and find closest in forward direction
		var minDistance: Float = maxDetectionDistance
		
		// Cast multiple rays in a cone pattern
		for i in 0..<rayCount {
			let angle = (Float(i) - Float(rayCount) / 2.0) * raySpread / Float(rayCount)
			let rayDirection = rotateVectorAroundY(forward, angle: angle)
			
			// Simple ray-mesh intersection approximation
			// Check distance to mesh anchor position as a quick approximation
			let meshPosition = simd_float3(meshTransform.columns.3.x, meshTransform.columns.3.y, meshTransform.columns.3.z)
			let toMesh = meshPosition - cameraPosition
			let distance = simd_length(toMesh)
			
			// Only consider if mesh is roughly in forward direction
			let dot = simd_dot(simd_normalize(toMesh), rayDirection)
			if dot > 0.5 && distance < maxDetectionDistance {
				minDistance = min(minDistance, distance)
			}
		}
		
		return minDistance
	}
	
	private func checkDepthDistance(frame: ARFrame, arView: ARView, depthData: ARDepthData) -> Float {
		let depthMap = depthData.depthMap
		CVPixelBufferLockBaseAddress(depthMap, .readOnly)
		defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
		
		let width = CVPixelBufferGetWidth(depthMap)
		let height = CVPixelBufferGetHeight(depthMap)
		let baseAddress = CVPixelBufferGetBaseAddress(depthMap)?.assumingMemoryBound(to: Float32.self)
		let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
		
		var minDepth: Float = maxDetectionDistance
		
		// Sample multiple points in the center region of the depth map
		let centerRegionSize: Float = 0.3 // 30% of screen around center
		let widthFloat = Float(width)
		let heightFloat = Float(height)
		let startX = Int(widthFloat * (0.5 - centerRegionSize / 2.0))
		let endX = Int(widthFloat * (0.5 + centerRegionSize / 2.0))
		let startY = Int(heightFloat * (0.5 - centerRegionSize / 2.0))
		let endY = Int(heightFloat * (0.5 + centerRegionSize / 2.0))
		
		for y in stride(from: startY, to: endY, by: 5) {
			for x in stride(from: startX, to: endX, by: 5) {
				if let depth = baseAddress?[y * (bytesPerRow / 4) + x] {
					if depth > 0 && depth < maxDetectionDistance {
						minDepth = min(minDepth, depth)
					}
				}
			}
		}
		
		return minDepth
	}
	
	private func checkRaycastDistance(arView: ARView, cameraPosition: simd_float3, forward: simd_float3) -> Float {
		var minDistance: Float = maxDetectionDistance
		
		// Cast rays from screen center and nearby points
		let screenCenter = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
		let raycastPoints = [
			screenCenter,
			CGPoint(x: screenCenter.x - 50, y: screenCenter.y),
			CGPoint(x: screenCenter.x + 50, y: screenCenter.y),
			CGPoint(x: screenCenter.x, y: screenCenter.y - 50),
			CGPoint(x: screenCenter.x, y: screenCenter.y + 50)
		]
		
		for point in raycastPoints {
			let raycastResults = arView.raycast(from: point, allowing: .estimatedPlane, alignment: .any)
			if let result = raycastResults.first {
				let hitPosition = simd_float3(result.worldTransform.columns.3.x, result.worldTransform.columns.3.y, result.worldTransform.columns.3.z)
				let distance = simd_distance(cameraPosition, hitPosition)
				minDistance = min(minDistance, distance)
			}
		}
		
		return minDistance
	}
	
	private func rotateVectorAroundY(_ vector: simd_float3, angle: Float) -> simd_float3 {
		let cosAngle = cos(angle)
		let sinAngle = sin(angle)
		return simd_float3(
			vector.x * cosAngle + vector.z * sinAngle,
			vector.y,
			-vector.x * sinAngle + vector.z * cosAngle
		)
	}
	
	private func updateHapticFeedback(distance: Float) {
		let now = CACurrentMediaTime()
		
		// Periodic reset to prevent stuck states
		if now - lastResetTime > resetInterval {
			print("⏰ Periodic haptic system reset triggered")
			resetHapticSystem()
			hapticFailureCount = 0
		}
		
		// Validate distance is reasonable
		guard distance > 0 && distance < 100 else {
			print("⚠️ Invalid distance detected: \(distance)m, skipping haptic")
			return
		}
		
		// Calculate haptic interval based on distance with exponential curve for more aggressive close feedback
		let normalizedDistance = min(1.0, max(0.0, distance / maxDetectionDistance))
		let exponentialCurve = pow(normalizedDistance, 3.0) // Cubic curve for very aggressive close feedback
		let interval = minHapticInterval + (maxHapticInterval - minHapticInterval) * TimeInterval(exponentialCurve)
		
		currentHapticInterval = interval
		
		// Only trigger haptic if enough time has passed
		guard now - lastHapticTime >= interval else { return }
		
		// Prevent haptic timing from getting stuck
		if now - lastHapticTime > 5.0 {
			print("🔄 Resetting stuck haptic timing")
			lastHapticTime = now - interval
		}
		
		lastHapticTime = now
		
		// Try to trigger haptic feedback with error handling
		let hapticTriggered = triggerHapticForDistance(distance)
		
		if hapticTriggered {
			hapticFailureCount = 0
			print("📳 Haptic triggered for distance: \(String(format: "%.2f", distance))m")
		} else {
			hapticFailureCount += 1
			print("❌ Haptic failed for distance: \(String(format: "%.2f", distance))m, failure count: \(hapticFailureCount)")
			
			// Reset system if too many failures
			if hapticFailureCount >= 3 {
				print("🔄 Too many haptic failures, resetting system")
				resetHapticSystem()
				hapticFailureCount = 0
			}
		}
	}
	
	private func triggerHapticForDistance(_ distance: Float) -> Bool {
		do {
			// 5-level color-coded feedback system
			if distance <= veryCloseDistance {
				// DARK RED - shake a lot (very close)
				isProximityActive = true
				if distance <= minDetectionDistance * 1.5 {
					// Extremely close - maximum intensity rigid feedback
					rigidHaptic.impactOccurred(intensity: 1.0)
				} else {
					// Very close - heavy feedback with high intensity
					heavyHaptic.impactOccurred(intensity: 1.0)
				}
			} else if distance <= closeDistance {
				// RED - shake (close)
				isProximityActive = true
				let distanceRatio = (distance - veryCloseDistance) / (closeDistance - veryCloseDistance)
				let intensity = 0.7 + 0.3 * (1.0 - distanceRatio) // 0.7 to 1.0 intensity
				heavyHaptic.impactOccurred(intensity: CGFloat(intensity))
			} else if distance <= kindOfCloseDistance {
				// ORANGE - decent bit of shaking (kind of close)
				isProximityActive = true
				let distanceRatio = (distance - closeDistance) / (kindOfCloseDistance - closeDistance)
				let intensity = 0.4 + 0.3 * (1.0 - distanceRatio) // 0.4 to 0.7 intensity
				mediumHaptic.impactOccurred(intensity: CGFloat(intensity))
			} else if distance <= mediumDistance {
				// GREEN - a little shaking (medium distance)
				isProximityActive = true
				let distanceRatio = (distance - kindOfCloseDistance) / (mediumDistance - kindOfCloseDistance)
				let intensity = 0.2 + 0.2 * (1.0 - distanceRatio) // 0.2 to 0.4 intensity
				lightHaptic.impactOccurred(intensity: CGFloat(intensity))
			} else if distance <= farDistance {
				// BLUE - very little shaking (far but detectable)
				isProximityActive = true
				let distanceRatio = (distance - mediumDistance) / (farDistance - mediumDistance)
				let intensity = 0.1 + 0.1 * (1.0 - distanceRatio) // 0.1 to 0.2 intensity
				lightHaptic.impactOccurred(intensity: CGFloat(intensity))
			} else {
				// Beyond detection range - no feedback
				isProximityActive = false
			}
			
			// Always prepare generators for next use when active
			if isProximityActive {
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
					self?.lightHaptic.prepare()
					self?.mediumHaptic.prepare() 
					self?.heavyHaptic.prepare()
					self?.rigidHaptic.prepare()
				}
			}
			
			return true
		} catch {
			print("❌ Haptic error: \(error)")
			return false
		}
	}
}

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
	@Published var detectedObjectScreenPosition: CGPoint?
	@Published var detectedBoundingBox: CGRect?
	
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
		// Configure audio session for spatial audio playback
		do {
			let audioSession = AVAudioSession.sharedInstance()
			try audioSession.setCategory(.playback, mode: .default, options: [.allowBluetooth, .allowBluetoothA2DP, .allowAirPlay])
			try audioSession.setActive(true)
		} catch {
			print("Failed to configure audio session for spatial audio: \(error)")
		}
		
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
		print("🎯 Setting target at world position: \(worldPosition)")
		
		// Stop any existing pinging immediately
		stopPinging()
		
		// Ensure audio session is configured for spatial audio
		ensureAudioSessionForSpatialAudio()
		
		// Set new target and start pinging
		targetWorldPosition = worldPosition
		startPinging()
		
		print("🎵 Target set, isPlayingPing: \(isPlayingPing)")
	}
	
	private func ensureAudioSessionForSpatialAudio() {
		do {
			let audioSession = AVAudioSession.sharedInstance()
			try audioSession.setCategory(.playback, mode: .default, options: [.allowBluetooth, .allowBluetoothA2DP, .allowAirPlay])
			try audioSession.setActive(true)
			print("✅ Audio session configured for spatial audio")
		} catch {
			print("❌ Failed to configure audio session for spatial audio: \(error)")
		}
	}
	
	func setDetectedObjectScreenPosition(_ position: CGPoint?) {
		print("🔵 Setting detected object screen position: \(position?.debugDescription ?? "nil")")
		
		// Ensure UI updates happen on main thread
		DispatchQueue.main.async { [weak self] in
			self?.detectedObjectScreenPosition = position
			
			// Clear the indicator after 3 seconds
			if position != nil {
				DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
					print("🔵 Clearing detected object indicator")
					self?.detectedObjectScreenPosition = nil
				}
			}
		}
	}
	
	func setDetectedBoundingBox(_ boundingBox: CGRect?) {
		print("📦 Setting detected bounding box: \(boundingBox?.debugDescription ?? "nil")")
		
		// Ensure UI updates happen on main thread
		DispatchQueue.main.async { [weak self] in
			self?.detectedBoundingBox = boundingBox
			
			// Clear the bounding box after 4 seconds (slightly longer than center point)
			if boundingBox != nil {
				DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
					print("📦 Clearing detected bounding box")
					self?.detectedBoundingBox = nil
				}
			}
		}
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
		// Determine the current interface orientation for accurate projection
		let interfaceOrientation: UIInterfaceOrientation = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.interfaceOrientation ?? .portrait
		let screenPoint = camera.projectPoint(
			worldPos,
			orientation: interfaceOrientation,
			viewportSize: CGSize(width: viewBounds.width, height: viewBounds.height)
		)
		
		// Check if the point is within the screen bounds
		if screenPoint.x >= 0 && screenPoint.x <= viewBounds.width && 
		   screenPoint.y >= 0 && screenPoint.y <= viewBounds.height {
			let newTargetPos = CGPoint(x: CGFloat(screenPoint.x), y: CGFloat(screenPoint.y))
			targetScreenPosition = newTargetPos
			print("🟢 Updated target screen position: \(newTargetPos)")
		} else {
			targetScreenPosition = nil
			print("🟢 Target is off-screen")
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
		print("🎵 startPinging called - isSetup: \(isSetup), hasBuffer: \(standardPingBuffer != nil)")
		guard isSetup, let _ = standardPingBuffer else { 
			print("❌ Cannot start pinging - missing setup or buffer")
			return 
		}
		
		// Start the audio engine if not running
		if !audioEngine.isRunning {
			print("🎵 Starting audio engine...")
			do {
				try audioEngine.start()
				print("✅ Audio engine started successfully")
			} catch {
				print("❌ Failed to start audio engine: \(error)")
				return
			}
		} else {
			print("🎵 Audio engine already running")
		}
		
		isPlayingPing = true
		print("🎵 Scheduling first ping...")
		schedulePing()
	}
	
	private func schedulePing() {
		print("🎵 schedulePing called - isPlayingPing: \(isPlayingPing), hasBuffer: \(getCurrentPingBuffer() != nil)")
		guard isPlayingPing, let buffer = getCurrentPingBuffer() else { 
			print("❌ Cannot schedule ping - not playing or no buffer")
			return 
		}
		
		// Calculate dynamic interval based on distance
		let interval = calculatePingInterval()
		print("🎵 Scheduling ping with interval: \(interval)s")
		
		playerNode.scheduleBuffer(buffer, at: nil, options: [], completionHandler: { [weak self] in
			print("🎵 Ping completed, scheduling next...")
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
			print("🎵 Starting player node...")
			playerNode.play()
		} else {
			print("🎵 Player node already playing")
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
	
	func clearTarget() {
		print("🚫 Clearing target")
		
		// Stop any pinging
		stopPinging()
		
		// Clear target positions
		targetWorldPosition = nil
		targetScreenPosition = nil
		
		// Clear detection indicators
		detectedObjectScreenPosition = nil
		detectedBoundingBox = nil
		
		print("✅ Target cleared")
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

// MARK: - Waypoint Management
extension simd_float3: Codable {
	public func encode(to encoder: Encoder) throws {
		var container = encoder.unkeyedContainer()
		try container.encode(x)
		try container.encode(y)
		try container.encode(z)
	}
	
	public init(from decoder: Decoder) throws {
		var container = try decoder.unkeyedContainer()
		let x = try container.decode(Float.self)
		let y = try container.decode(Float.self)
		let z = try container.decode(Float.self)
		self.init(x, y, z)
	}
}

struct Waypoint: Identifiable, Codable {
	let id = UUID()
	let name: String
	let worldPosition: simd_float3
	let dateCreated: Date
	
	init(name: String, worldPosition: simd_float3) {
		self.name = name
		self.worldPosition = worldPosition
		self.dateCreated = Date()
	}
}

class WaypointManager: ObservableObject {
	@Published var waypoints: [Waypoint] = []
	@Published var activeWaypoint: Waypoint?
	@Published var isShowingWaypointList = false
	@Published var isCreatingWaypoint = false
	@Published var pendingWaypointPosition: simd_float3?
	@Published var waypointNameInput = ""
	
	private let waypointsKey = "SavedWaypoints"
	
	init() {
		loadWaypoints()
	}
	
	func createWaypoint(at position: simd_float3, name: String) {
		let waypoint = Waypoint(name: name.trimmingCharacters(in: .whitespacesAndNewlines), worldPosition: position)
		waypoints.append(waypoint)
		saveWaypoints()
		print("📍 Created waypoint '\(waypoint.name)' at \(position)")
	}
	
	func deleteWaypoint(_ waypoint: Waypoint) {
		waypoints.removeAll { $0.id == waypoint.id }
		if activeWaypoint?.id == waypoint.id {
			activeWaypoint = nil
		}
		saveWaypoints()
		print("🗑️ Deleted waypoint '\(waypoint.name)'")
	}
	
	func renameWaypoint(_ waypoint: Waypoint, to newName: String) {
		if let index = waypoints.firstIndex(where: { $0.id == waypoint.id }) {
			let updatedWaypoint = Waypoint(name: newName.trimmingCharacters(in: .whitespacesAndNewlines), worldPosition: waypoint.worldPosition)
			waypoints[index] = updatedWaypoint
			if activeWaypoint?.id == waypoint.id {
				activeWaypoint = updatedWaypoint
			}
			saveWaypoints()
			print("✏️ Renamed waypoint to '\(newName)'")
		}
	}
	
	func setActiveWaypoint(_ waypoint: Waypoint) {
		activeWaypoint = waypoint
		print("🎯 Set active waypoint: '\(waypoint.name)'")
	}
	
	func clearActiveWaypoint() {
		activeWaypoint = nil
		print("🚫 Cleared active waypoint")
	}
	
	func findWaypoint(byName name: String) -> Waypoint? {
		let searchName = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
		return waypoints.first { waypoint in
			waypoint.name.lowercased().contains(searchName) || searchName.contains(waypoint.name.lowercased())
		}
	}
	
	func startCreatingWaypoint(at position: simd_float3) {
		pendingWaypointPosition = position
		waypointNameInput = ""
		isCreatingWaypoint = true
	}
	
	func cancelWaypointCreation() {
		pendingWaypointPosition = nil
		waypointNameInput = ""
		isCreatingWaypoint = false
	}
	
	func finishWaypointCreation() {
		guard let position = pendingWaypointPosition, !waypointNameInput.isEmpty else { return }
		createWaypoint(at: position, name: waypointNameInput)
		cancelWaypointCreation()
	}
	
	private func saveWaypoints() {
		do {
			let encoder = JSONEncoder()
			let data = try encoder.encode(waypoints)
			UserDefaults.standard.set(data, forKey: waypointsKey)
		} catch {
			print("Failed to save waypoints: \(error)")
		}
	}
	
	private func loadWaypoints() {
		guard let data = UserDefaults.standard.data(forKey: waypointsKey) else { return }
		do {
			let decoder = JSONDecoder()
			waypoints = try decoder.decode([Waypoint].self, from: data)
			print("📍 Loaded \(waypoints.count) saved waypoints")
		} catch {
			print("Failed to load waypoints: \(error)")
		}
	}
}

// MARK: - Object Detection Models
struct BoundingBox: Codable {
	let box_2d: [Int]
	let label: String
}

struct DetectionResponse: Codable {
	let success: Bool
	let detections: [BoundingBox]
	let error: String?
}

struct DetectionRequest: Codable {
	let image_base64: String
	let detection_target: String
}

// MARK: - Gemini Object Detection Manager
class ObjectDetectionManager: ObservableObject {
	private let vmServerURL = "http://35.238.205.88:8081"
	private let detectEndpoint: String
	
	@Published var isDetecting = false
	@Published var lastDetectionResult: String = ""
	
	init() {
		detectEndpoint = "\(vmServerURL)/detect"
	}
	
	func detectObject(in frame: ARFrame, target: String, completion: @escaping (CGPoint?, CGRect?) -> Void) {
		isDetecting = true
		lastDetectionResult = "Detecting \(target)..."
		
		// Convert ARFrame to UIImage immediately and don't retain frame
		let pixelBuffer = frame.capturedImage
		guard let image = convertPixelBufferToUIImage(pixelBuffer) else {
			DispatchQueue.main.async {
				self.isDetecting = false
				self.lastDetectionResult = "Failed to capture image"
				completion(nil, nil)
			}
			return
		}
		
		// Convert to base64
		guard let imageData = image.jpegData(compressionQuality: 0.8) else {
			DispatchQueue.main.async {
				self.isDetecting = false
				self.lastDetectionResult = "Failed to encode image"
				completion(nil, nil)
			}
			return
		}
		
		let imageBase64 = imageData.base64EncodedString()
		
		// Send to Gemini API via VM server
		let request = DetectionRequest(image_base64: imageBase64, detection_target: target)
		
		guard let url = URL(string: detectEndpoint) else {
			DispatchQueue.main.async {
				self.isDetecting = false
				self.lastDetectionResult = "Invalid server URL"
				completion(nil, nil)
			}
			return
		}
		
		var urlRequest = URLRequest(url: url)
		urlRequest.httpMethod = "POST"
		urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
		urlRequest.timeoutInterval = 60
		
		do {
			urlRequest.httpBody = try JSONEncoder().encode(request)
		} catch {
			DispatchQueue.main.async {
				self.isDetecting = false
				self.lastDetectionResult = "Failed to encode request"
				completion(nil, nil)
			}
			return
		}
		
		URLSession.shared.dataTask(with: urlRequest) { [weak self] data, response, error in
			DispatchQueue.main.async {
				self?.isDetecting = false
				
				if let error = error {
					self?.lastDetectionResult = "Network error: \(error.localizedDescription)"
					completion(nil, nil)
					return
				}
				
				guard let data = data else {
					self?.lastDetectionResult = "No data received"
					completion(nil, nil)
					return
				}
				
				do {
					let detectionResponse = try JSONDecoder().decode(DetectionResponse.self, from: data)
					
					if detectionResponse.success, let firstDetection = detectionResponse.detections.first {
						self?.lastDetectionResult = "Found \(firstDetection.label)"
						
						// Calculate center point and bounding box
						let result = self?.calculateCenterPoint(from: firstDetection, imageSize: image.size)
						completion(result?.center, result?.boundingBox)
					} else {
						self?.lastDetectionResult = "No \(target) found"
						completion(nil, nil)
					}
				} catch {
					self?.lastDetectionResult = "I did not find anything in the image"
					completion(nil, nil)
				}
			}
		}.resume()
	}
	
	private func convertPixelBufferToUIImage(_ pixelBuffer: CVPixelBuffer) -> UIImage? {
		let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
		let context = CIContext()
		
		guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
			return nil
		}
		
		return UIImage(cgImage: cgImage)
	}
	
	private func calculateCenterPoint(from bbox: BoundingBox, imageSize: CGSize) -> (center: CGPoint, boundingBox: CGRect) {
		// bbox.box_2d format: [y_min, x_min, y_max, x_max]
		// Robust unit handling: supports pixel, 0-1000, or 0-1 normalized inputs
		let yMinRaw = CGFloat(bbox.box_2d[0])
		let xMinRaw = CGFloat(bbox.box_2d[1])
		let yMaxRaw = CGFloat(bbox.box_2d[2])
		let xMaxRaw = CGFloat(bbox.box_2d[3])
		
		let maxRaw = max(yMinRaw, xMinRaw, yMaxRaw, xMaxRaw)
		
		// Determine scale
		let xMinPx: CGFloat
		let yMinPx: CGFloat
		let xMaxPx: CGFloat
		let yMaxPx: CGFloat
		
		if maxRaw <= 1.001 {
			// Already 0-1 normalized
			xMinPx = xMinRaw * imageSize.width
			yMinPx = yMinRaw * imageSize.height
			xMaxPx = xMaxRaw * imageSize.width
			yMaxPx = yMaxRaw * imageSize.height
		} else if maxRaw <= 1000.0 {
			// 0-1000 normalized
			xMinPx = (xMinRaw / 1000.0) * imageSize.width
			yMinPx = (yMinRaw / 1000.0) * imageSize.height
			xMaxPx = (xMaxRaw / 1000.0) * imageSize.width
			yMaxPx = (yMaxRaw / 1000.0) * imageSize.height
		} else {
			// Pixel coordinates
			xMinPx = xMinRaw
			yMinPx = yMinRaw
			xMaxPx = xMaxRaw
			yMaxPx = yMaxRaw
		}
		
		// Clamp to image bounds
		let clampedXMin = max(0, min(imageSize.width, xMinPx))
		let clampedYMin = max(0, min(imageSize.height, yMinPx))
		let clampedXMax = max(0, min(imageSize.width, xMaxPx))
		let clampedYMax = max(0, min(imageSize.height, yMaxPx))
		
		let centerX = (clampedXMin + clampedXMax) / 2.0
		let centerY = (clampedYMin + clampedYMax) / 2.0
		
		let boundingBox = CGRect(
			x: min(clampedXMin, clampedXMax),
			y: min(clampedYMin, clampedYMax),
			width: abs(clampedXMax - clampedXMin),
			height: abs(clampedYMax - clampedYMin)
		)
		
		let normCenterX = centerX / imageSize.width
		let normCenterY = centerY / imageSize.height
		print("📍 Normalized center: (\(normCenterX), \(normCenterY))")
		print("📍 Pixel center: (\(centerX), \(centerY)) in image size: \(imageSize)")
		print("📦 Bounding box: \(boundingBox)")
		
		return (center: CGPoint(x: centerX, y: centerY), boundingBox: boundingBox)
	}
}

// MARK: - Speech Recognition Manager
class SpeechManager: ObservableObject {
	private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
	private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
	private var recognitionTask: SFSpeechRecognitionTask?
	private var speechAudioEngine = AVAudioEngine() // Separate engine for speech
	
	@Published var isListening = false
	@Published var recognizedText = ""
	
	// Continuous transcription properties
	@Published var isContinuousMode = false
	@Published var isTranscribing = false
	@Published var fullTranscript = ""
	@Published var currentSegment = ""
	@Published var isShowingTranscript = false
	
	private var transcriptSegments: [String] = []
	private var lastTranscriptUpdate = Date()
	private let segmentTimeout: TimeInterval = 3.0 // Seconds of silence before starting new segment
	
	init() {
		requestPermissions()
	}
	
	private func requestPermissions() {
		SFSpeechRecognizer.requestAuthorization { status in
			DispatchQueue.main.async {
				switch status {
				case .authorized:
					print("Speech recognition authorized")
				default:
					print("Speech recognition not authorized")
				}
			}
		}
	}
	
	func startListening() {
		guard !isListening else { return }
		
		// Configure audio session for speech recognition
		do {
			let audioSession = AVAudioSession.sharedInstance()
			try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
			try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
		} catch {
			print("Failed to configure audio session: \(error)")
			return
		}
		
		// Cancel any previous task
		recognitionTask?.cancel()
		recognitionTask = nil
		
		// Reset audio engine to avoid format issues
		if speechAudioEngine.isRunning {
			speechAudioEngine.stop()
			speechAudioEngine.inputNode.removeTap(onBus: 0)
		}
		
		// Create recognition request
		recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
		guard let recognitionRequest = recognitionRequest else { return }
		recognitionRequest.shouldReportPartialResults = true
		
		// Configure audio engine with proper format handling
		let inputNode = speechAudioEngine.inputNode
		let recordingFormat = inputNode.outputFormat(forBus: 0)
		
		// Use a format that matches the input node's format to avoid mismatches
		let desiredFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, 
										  sampleRate: recordingFormat.sampleRate, 
										  channels: 1, 
										  interleaved: false)
		
		guard let format = desiredFormat else {
			print("Failed to create audio format")
			return
		}
		
		inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
			recognitionRequest.append(buffer)
		}
		
		speechAudioEngine.prepare()
		do {
			try speechAudioEngine.start()
		} catch {
			print("Speech audio engine couldn't start: \(error)")
			// Clean up on failure
			inputNode.removeTap(onBus: 0)
			return
		}
		
		// Start recognition
		recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
			DispatchQueue.main.async {
				if let result = result {
					self?.recognizedText = result.bestTranscription.formattedString
				}
				
				if error != nil || result?.isFinal == true {
					self?.stopListening()
				}
			}
		}
		
		isListening = true
	}
	
	func stopListening() {
		isListening = false
		
		// Stop audio engine safely
		if speechAudioEngine.isRunning {
			speechAudioEngine.stop()
		}
		
		// Remove tap safely
		speechAudioEngine.inputNode.removeTap(onBus: 0)
		
		// Clean up recognition
		recognitionRequest?.endAudio()
		recognitionTask?.cancel()
		recognitionTask = nil
		recognitionRequest = nil
		
		// Restore audio session for spatial audio playback (only if not in continuous mode)
		if !isContinuousMode || !isTranscribing {
			do {
				let audioSession = AVAudioSession.sharedInstance()
				try audioSession.setCategory(.playback, mode: .default, options: [.allowBluetooth, .allowBluetoothA2DP, .allowAirPlay])
				try audioSession.setActive(true)
				print("✅ Audio session restored for spatial audio")
			} catch {
				print("Failed to restore audio session for spatial audio: \(error)")
			}
		}
	}
	
	// MARK: - Continuous Transcription Methods
	
	func toggleContinuousMode() {
		if isContinuousMode {
			stopContinuousTranscription()
		} else {
			startContinuousTranscription()
		}
	}
	
	func startContinuousTranscription() {
		guard !isTranscribing else { return }
		
		isContinuousMode = true
		isTranscribing = true
		
		print("🎤 Starting continuous transcription...")
		startContinuousListening()
	}
	
	func stopContinuousTranscription() {
		isContinuousMode = false
		isTranscribing = false
		
		// Finalize current segment
		finalizeCurrentSegment()
		
		// Stop any ongoing recognition
		stopListening()
		
		print("🎤 Stopped continuous transcription")
	}
	
	func clearTranscript() {
		fullTranscript = ""
		currentSegment = ""
		transcriptSegments.removeAll()
		lastTranscriptUpdate = Date()
	}
	
	func saveTranscript() -> String {
		let timestamp = DateFormatter()
		timestamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
		let header = "Transcript - \(timestamp.string(from: Date()))\n\n"
		return header + fullTranscript
	}
	
	private func startContinuousListening() {
		// Configure audio session for continuous speech recognition
		do {
			let audioSession = AVAudioSession.sharedInstance()
			try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
			try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
		} catch {
			print("Failed to configure audio session for continuous transcription: \(error)")
			return
		}
		
		// Cancel any previous task
		recognitionTask?.cancel()
		recognitionTask = nil
		
		// Reset audio engine
		if speechAudioEngine.isRunning {
			speechAudioEngine.stop()
			speechAudioEngine.inputNode.removeTap(onBus: 0)
		}
		
		// Create recognition request
		recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
		guard let recognitionRequest = recognitionRequest else { return }
		recognitionRequest.shouldReportPartialResults = true
		
		// Configure audio engine
		let inputNode = speechAudioEngine.inputNode
		let recordingFormat = inputNode.outputFormat(forBus: 0)
		
		let desiredFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
										  sampleRate: recordingFormat.sampleRate,
										  channels: 1,
										  interleaved: false)
		
		guard let format = desiredFormat else {
			print("Failed to create audio format for continuous transcription")
			return
		}
		
		inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
			recognitionRequest.append(buffer)
		}
		
		speechAudioEngine.prepare()
		do {
			try speechAudioEngine.start()
		} catch {
			print("Speech audio engine couldn't start for continuous transcription: \(error)")
			inputNode.removeTap(onBus: 0)
			return
		}
		
		// Start recognition with continuous handling
		recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
			DispatchQueue.main.async {
				self?.handleContinuousRecognitionResult(result: result, error: error)
			}
		}
	}
	
	private func handleContinuousRecognitionResult(result: SFSpeechRecognitionResult?, error: Error?) {
		guard isContinuousMode && isTranscribing else { return }
		
		if let result = result {
			let newText = result.bestTranscription.formattedString
			currentSegment = newText
			lastTranscriptUpdate = Date()
			
			// If this is a final result, add it to the transcript and start a new segment
			if result.isFinal {
				finalizeCurrentSegment()
				// Restart recognition for next segment
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
					if self?.isContinuousMode == true && self?.isTranscribing == true {
						self?.restartContinuousRecognition()
					}
				}
			}
		}
		
		if let error = error {
			print("Continuous recognition error: \(error)")
			// Restart recognition after error
			DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
				if self?.isContinuousMode == true && self?.isTranscribing == true {
					self?.restartContinuousRecognition()
				}
			}
		}
	}
	
	private func finalizeCurrentSegment() {
		guard !currentSegment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
		
		let timestamp = DateFormatter()
		timestamp.dateFormat = "HH:mm:ss"
		let timestampedSegment = "[\(timestamp.string(from: Date()))] \(currentSegment.trimmingCharacters(in: .whitespacesAndNewlines))"
		
		transcriptSegments.append(timestampedSegment)
		fullTranscript = transcriptSegments.joined(separator: "\n\n")
		currentSegment = ""
		
		print("📝 Added segment to transcript: \(timestampedSegment)")
	}
	
	private func restartContinuousRecognition() {
		// Clean up current recognition
		recognitionRequest?.endAudio()
		recognitionTask?.cancel()
		recognitionTask = nil
		recognitionRequest = nil
		
		// Start new recognition session
		startContinuousListening()
	}
}

struct ContentView: View {
	@StateObject private var spatialAudioManager = SpatialAudioManager()
	@StateObject private var objectDetectionManager = ObjectDetectionManager()
	@StateObject private var speechManager = SpeechManager()
	@StateObject private var waypointManager = WaypointManager()
	@StateObject private var proximityManager = ProximityDetectionManager()

	var body: some View {
		VStack(spacing: 0) {
			ZStack {
				ARViewContainer(
					spatialAudioManager: spatialAudioManager,
					objectDetectionManager: objectDetectionManager,
					speechManager: speechManager,
					waypointManager: waypointManager,
					proximityManager: proximityManager
				)
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
				
				// Status indicators at top
				VStack {
					VStack(spacing: 8) {
						// Target active indicator
						if spatialAudioManager.isPlayingPing {
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
						}
						
					}
					.padding(.top, 20)
					Spacer()
				}
				
				// Target position indicator (green circle with music note)
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
				
				// Detected object bounding box (blue rectangle showing Gemini's detection)
				if let boundingBox = spatialAudioManager.detectedBoundingBox {
					Rectangle()
						.stroke(Color.blue, lineWidth: 2)
						.frame(width: boundingBox.width, height: boundingBox.height)
						.position(x: boundingBox.midX, y: boundingBox.midY)
						.animation(.easeInOut(duration: 0.3), value: boundingBox)
						.opacity(0.8)
					
					// Label for the bounding box
					Text("GEMINI DETECTION")
						.font(.system(size: 12, weight: .bold))
						.foregroundColor(.blue)
						.background(Color.white.opacity(0.8))
						.cornerRadius(4)
						.position(x: boundingBox.midX, y: boundingBox.minY - 10)
						.animation(.easeInOut(duration: 0.3), value: boundingBox)
				}
				
				// Detected object center point indicator (blue circle with eye icon)
				if let detectedPos = spatialAudioManager.detectedObjectScreenPosition {
					ZStack {
						Circle()
							.stroke(Color.blue, lineWidth: 3)
							.frame(width: 40, height: 40)
						
						Circle()
							.fill(Color.blue.opacity(0.3))
							.frame(width: 40, height: 40)
						
						Image(systemName: "eye.fill")
							.font(.system(size: 16, weight: .bold))
							.foregroundColor(.white)
						
						Text("CENTER")
							.font(.system(size: 10, weight: .bold))
							.foregroundColor(.blue)
							.offset(x: 0, y: -25)
					}
					.position(detectedPos)
					.animation(.easeInOut(duration: 0.3), value: detectedPos)
					.opacity(0.9)
				}
				
				VStack {
					Spacer()
					
					// Voice command button and waypoint buttons
					VStack(spacing: 12) {
						HStack(spacing: 15) {
							// Voice command button
							Button(action: {
								if speechManager.isListening {
									speechManager.stopListening()
									// Process the recognized text
									if !speechManager.recognizedText.isEmpty {
										let recognizedText = speechManager.recognizedText.lowercased()

										// Check for proximity mode commands first
										if recognizedText.contains("proximity") {
											if recognizedText.contains("off") || recognizedText.contains("stop") || recognizedText.contains("disable") {
												// Force proximity mode OFF
												if proximityManager.isEnabled {
													proximityManager.toggle()
												}
											} else if recognizedText.contains("on") || recognizedText.contains("start") || recognizedText.contains("enable") {
												// Force proximity mode ON
												if !proximityManager.isEnabled {
													proximityManager.toggle()
												}
											} else {
												// Just "proximity" - toggle current state
												proximityManager.toggle()
											}
										}
										// Check for waypoint creation commands
										else if recognizedText.contains("add waypoint") {
											let waypointName = extractWaypointName(from: speechManager.recognizedText)
											if !waypointName.isEmpty {
												// Create waypoint with voice command
												NotificationCenter.default.post(name: .addWaypointVoice, object: nil, userInfo: ["name": waypointName])
											}
										}
										// Check if it's a waypoint navigation command
										else if let waypoint = waypointManager.findWaypoint(byName: speechManager.recognizedText) {
											waypointManager.setActiveWaypoint(waypoint)
											spatialAudioManager.setTarget(worldPosition: waypoint.worldPosition)
										} else {
											// Fall back to object detection
											NotificationCenter.default.post(name: .detectObject, object: nil, userInfo: ["target": speechManager.recognizedText, "boxOnly": true])
										}
									}
								} else {
									speechManager.startListening()
								}
							}) {
								HStack(spacing: 8) {
									Image(systemName: speechManager.isListening ? "mic.fill" : "mic")
										.font(.system(size: 16))
									Text(speechManager.isListening ? "Listening..." : "Voice Command")
										.font(.system(size: 16, weight: .medium))
								}
								.foregroundColor(.white)
								.padding(.horizontal, 20)
								.padding(.vertical, 12)
								.background(speechManager.isListening ? Color.red.opacity(0.8) : Color.blue.opacity(0.8))
								.cornerRadius(25)
							}
							
							// Waypoint list button
							Button(action: {
								waypointManager.isShowingWaypointList.toggle()
							}) {
								HStack(spacing: 8) {
									Image(systemName: "list.bullet")
										.font(.system(size: 16))
									Text("Waypoints")
										.font(.system(size: 16, weight: .medium))
								}
								.foregroundColor(.white)
								.padding(.horizontal, 20)
								.padding(.vertical, 12)
								.background(Color.purple.opacity(0.8))
								.cornerRadius(25)
							}
						}
						
						HStack(spacing: 15) {
							// Add waypoint button
							Button(action: {
								NotificationCenter.default.post(name: .addWaypoint, object: nil)
							}) {
								HStack(spacing: 8) {
									Image(systemName: "plus.circle")
										.font(.system(size: 16))
									Text("Add Waypoint")
										.font(.system(size: 16, weight: .medium))
								}
								.foregroundColor(.white)
								.padding(.horizontal, 20)
								.padding(.vertical, 12)
								.background(Color.green.opacity(0.8))
								.cornerRadius(25)
							}
							
							// Manual target button (for temporary targets)
							Button(action: {
								NotificationCenter.default.post(name: .setTargetCenter, object: nil)
							}) {
								Text("Quick Target")
									.font(.system(size: 16, weight: .medium))
									.foregroundColor(.white)
									.padding(.horizontal, 20)
									.padding(.vertical, 12)
									.background(Color.black.opacity(0.6))
									.cornerRadius(25)
							}
						}
						
						HStack(spacing: 10) {
							// Proximity detection toggle
							Button(action: {
								proximityManager.toggle()
							}) {
								HStack(spacing: 8) {
									Image(systemName: proximityManager.isEnabled ? "iphone.radiowaves.left.and.right" : "iphone")
										.font(.system(size: 16))
									Text(proximityManager.isEnabled ? "Proximity ON" : "Proximity OFF")
										.font(.system(size: 16, weight: .medium))
								}
								.foregroundColor(.white)
								.padding(.horizontal, 20)
								.padding(.vertical, 12)
								.background(proximityManager.isEnabled ? Color.orange.opacity(0.8) : Color.gray.opacity(0.6))
								.cornerRadius(25)
							}
							
							// Reset proximity button (only show when enabled)
							if proximityManager.isEnabled {
								Button(action: {
									proximityManager.forceReset()
								}) {
									Image(systemName: "arrow.clockwise.circle")
										.font(.system(size: 16))
										.foregroundColor(.white)
										.padding(.horizontal, 12)
										.padding(.vertical, 12)
										.background(Color.blue.opacity(0.8))
										.cornerRadius(25)
								}
							}
						}
						
						
						// Clear target button (only show when target is active)
						if spatialAudioManager.isPlayingPing || waypointManager.activeWaypoint != nil {
							Button(action: {
								spatialAudioManager.clearTarget()
								waypointManager.clearActiveWaypoint()
							}) {
								HStack(spacing: 8) {
									Image(systemName: "xmark.circle")
										.font(.system(size: 16))
									Text("Clear Target")
										.font(.system(size: 16, weight: .medium))
								}
								.foregroundColor(.white)
								.padding(.horizontal, 20)
								.padding(.vertical, 12)
								.background(Color.red.opacity(0.8))
								.cornerRadius(25)
							}
						}
					}
					
					// Status messages
					if objectDetectionManager.isDetecting {
						Text("🔍 \(objectDetectionManager.lastDetectionResult)")
							.font(.system(size: 14))
							.foregroundColor(.white)
							.padding(.horizontal, 16)
							.padding(.vertical, 8)
							.background(Color.orange.opacity(0.8))
							.cornerRadius(15)
							.padding(.top, 10)
					} else if !objectDetectionManager.lastDetectionResult.isEmpty {
						Text("\(objectDetectionManager.lastDetectionResult)")
							.font(.system(size: 14))
							.foregroundColor(.white)
							.padding(.horizontal, 16)
							.padding(.vertical, 8)
							.background(Color.green.opacity(0.8))
							.cornerRadius(15)
							.padding(.top, 10)
					}
					
					// Proximity detection status with color-coded feedback
					if proximityManager.isEnabled {
						let (statusColor, statusText, backgroundColor) = getProximityColors(distance: proximityManager.currentDistance, isActive: proximityManager.isProximityActive)
						let (healthSymbol, healthColor) = getProximityHealthStatus()
						
						VStack(spacing: 5) {
							HStack(spacing: 8) {
								Text("📳")
									.font(.system(size: 12))
								Text("Proximity Detection")
									.font(.system(size: 12, weight: .medium))
								
								// Health status indicator
								Text(healthSymbol)
									.font(.system(size: 8))
									.foregroundColor(healthColor)
								
								if proximityManager.isProximityActive {
									Circle()
										.fill(statusColor)
										.frame(width: 10, height: 10)
										.scaleEffect(proximityManager.currentDistance <= 0.8 ? 1.2 : 1.0)
										.animation(.easeInOut(duration: proximityManager.currentDistance <= 0.4 ? 0.15 : 0.3).repeatForever(autoreverses: true), value: proximityManager.isProximityActive)
								}
							}
							.foregroundColor(.white)
							
							HStack(spacing: 8) {
								Text(String(format: "%.1fm", proximityManager.currentDistance))
									.font(.system(size: 11, weight: .bold))
								Text(statusText)
									.font(.system(size: 10))
									.opacity(0.9)
							}
							.foregroundColor(.white)
						}
						.padding(.horizontal, 16)
						.padding(.vertical, 8)
						.background(backgroundColor)
						.cornerRadius(15)
						.padding(.top, 5)
					}
					
					// Speech recognition text
					if speechManager.isListening && !speechManager.recognizedText.isEmpty {
						Text("🎤 \"\(speechManager.recognizedText)\"")
							.font(.system(size: 14))
							.foregroundColor(.white)
							.padding(.horizontal, 16)
							.padding(.vertical, 8)
							.background(Color.purple.opacity(0.8))
							.cornerRadius(15)
							.padding(.top, 5)
					}
					
					Spacer().frame(height: 50)
				}
				
				// Waypoint list overlay
				if waypointManager.isShowingWaypointList {
					Color.black.opacity(0.4)
						.ignoresSafeArea()
						.onTapGesture {
							waypointManager.isShowingWaypointList = false
						}
					
					VStack(spacing: 20) {
						Text("📍 Waypoints")
							.font(.title2)
							.fontWeight(.bold)
							.foregroundColor(.white)
						
						ScrollView {
							LazyVStack(spacing: 12) {
								ForEach(waypointManager.waypoints) { waypoint in
									HStack {
										VStack(alignment: .leading) {
											Text(waypoint.name)
												.font(.headline)
												.foregroundColor(.white)
											Text("Created: \(waypoint.dateCreated, formatter: dateFormatter)")
												.font(.caption)
												.foregroundColor(.gray)
										}
										
										Spacer()
										
										// Set active button
										Button(action: {
											waypointManager.setActiveWaypoint(waypoint)
											spatialAudioManager.setTarget(worldPosition: waypoint.worldPosition)
											waypointManager.isShowingWaypointList = false
										}) {
											Image(systemName: waypointManager.activeWaypoint?.id == waypoint.id ? "location.fill" : "location")
												.foregroundColor(waypointManager.activeWaypoint?.id == waypoint.id ? .green : .white)
										}
										
										// Delete button
										Button(action: {
											waypointManager.deleteWaypoint(waypoint)
										}) {
											Image(systemName: "trash")
												.foregroundColor(.red)
										}
									}
									.padding()
									.background(Color.black.opacity(0.6))
									.cornerRadius(10)
								}
							}
						}
						.frame(maxHeight: 300)
						
						Button("Close") {
							waypointManager.isShowingWaypointList = false
						}
						.foregroundColor(.white)
						.padding()
						.background(Color.gray.opacity(0.8))
						.cornerRadius(10)
					}
					.padding()
					.background(Color.black.opacity(0.8))
					.cornerRadius(15)
					.frame(maxWidth: 350)
				}
				
				// Waypoint creation dialog
				if waypointManager.isCreatingWaypoint {
					Color.black.opacity(0.4)
						.ignoresSafeArea()
					
					VStack(spacing: 20) {
						Text("📍 Name Your Waypoint")
							.font(.title2)
							.fontWeight(.bold)
							.foregroundColor(.white)
						
						TextField("Enter waypoint name", text: $waypointManager.waypointNameInput)
							.textFieldStyle(.roundedBorder)
							.padding(.horizontal)
						
						HStack(spacing: 20) {
							Button("Cancel") {
								waypointManager.cancelWaypointCreation()
							}
							.foregroundColor(.white)
							.padding()
							.background(Color.red.opacity(0.8))
							.cornerRadius(10)
							
							Button("Save") {
								waypointManager.finishWaypointCreation()
							}
							.foregroundColor(.white)
							.padding()
							.background(Color.green.opacity(0.8))
							.cornerRadius(10)
							.disabled(waypointManager.waypointNameInput.isEmpty)
						}
					}
					.padding()
					.background(Color.black.opacity(0.8))
					.cornerRadius(15)
					.frame(maxWidth: 300)
				}
				
			}
			.ignoresSafeArea()
		}
	}
	
	private var dateFormatter: DateFormatter {
		let formatter = DateFormatter()
		formatter.dateStyle = .none
		formatter.timeStyle = .short
		return formatter
	}
	
	// Helper function for color-coded proximity feedback
	private func getProximityColors(distance: Float, isActive: Bool) -> (Color, String, Color) {
		guard isActive else {
			return (Color.gray, "No obstacles detected", Color.gray.opacity(0.6))
		}
		
		if distance <= 0.4 { // veryCloseDistance - DARK RED
			return (Color.red.opacity(0.9), "VERY CLOSE - DANGER!", Color.red.opacity(0.9))
		} else if distance <= 0.8 { // closeDistance - RED
			return (Color.red, "CLOSE - CAUTION", Color.red.opacity(0.8))
		} else if distance <= 1.5 { // kindOfCloseDistance - ORANGE
			return (Color.orange, "KIND OF CLOSE", Color.orange.opacity(0.8))
		} else if distance <= 2.5 { // mediumDistance - GREEN
			return (Color.green, "MEDIUM DISTANCE", Color.green.opacity(0.8))
		} else if distance <= 4.0 { // farDistance - BLUE
			return (Color.blue, "FAR BUT DETECTED", Color.blue.opacity(0.8))
		} else {
			return (Color.gray, "CLEAR PATH", Color.gray.opacity(0.6))
		}
	}
	
	private func getProximityHealthStatus() -> (String, Color) {
		if proximityManager.isEnabled {
			let now = CACurrentMediaTime()
			let timeSinceLastReset = now - (proximityManager.lastResetTime > 0 ? proximityManager.lastResetTime : now)

			if timeSinceLastReset < 5.0 {
				return ("●", Color.green) // Recently reset - healthy
			} else if timeSinceLastReset < 25.0 {
				return ("●", Color.yellow) // Normal operation
			} else {
				return ("●", Color.orange) // May need reset soon
			}
		} else {
			return ("○", Color.gray) // Disabled
		}
	}

	private func extractWaypointName(from text: String) -> String {
		let lowercasedText = text.lowercased()

		// Remove common prefixes
		var cleanedText = lowercasedText
			.replacingOccurrences(of: "add a waypoint called", with: "")
			.replacingOccurrences(of: "add a waypoint", with: "")
			.replacingOccurrences(of: "add waypoint called", with: "")
			.replacingOccurrences(of: "add waypoint", with: "")
			.replacingOccurrences(of: "create a waypoint called", with: "")
			.replacingOccurrences(of: "create a waypoint", with: "")
			.replacingOccurrences(of: "create waypoint called", with: "")
			.replacingOccurrences(of: "create waypoint", with: "")
			.trimmingCharacters(in: .whitespacesAndNewlines)

		// Remove articles and common words that might not be part of the name
		let wordsToRemove = ["the", "a", "an"]
		let words = cleanedText.components(separatedBy: .whitespaces)
		let filteredWords = words.filter { !wordsToRemove.contains($0) }
		cleanedText = filteredWords.joined(separator: " ")

		// Capitalize first letter of each word for proper naming
		return cleanedText.capitalized
	}
}

extension Notification.Name {
	static let setTargetCenter = Notification.Name("setTargetCenter")
	static let detectObject = Notification.Name("detectObject")
	static let addWaypoint = Notification.Name("addWaypoint")
	static let addWaypointVoice = Notification.Name("addWaypointVoice")
}

struct ARViewContainer: UIViewRepresentable {
	let spatialAudioManager: SpatialAudioManager
	let objectDetectionManager: ObjectDetectionManager
	let speechManager: SpeechManager
	let waypointManager: WaypointManager
	let proximityManager: ProximityDetectionManager
	
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
		context.coordinator.setObjectDetectionManager(objectDetectionManager)
		context.coordinator.setWaypointManager(waypointManager)
		context.coordinator.setProximityManager(proximityManager)
		context.coordinator.setARView(arView)

		
		NotificationCenter.default.addObserver(forName: .setTargetCenter, object: nil, queue: .main) { _ in
			context.coordinator.setTargetAtCenter(arView: arView)
		}
		
		NotificationCenter.default.addObserver(forName: .detectObject, object: nil, queue: .main) { note in
			guard let target = note.userInfo?["target"] as? String else { return }
			let boxOnly = note.userInfo?["boxOnly"] as? Bool ?? false
			context.coordinator.detectAndSetTarget(target: target, arView: arView, boxOnly: boxOnly)
		}
		
		NotificationCenter.default.addObserver(forName: .addWaypoint, object: nil, queue: .main) { _ in
			context.coordinator.addWaypointAtCenter(arView: arView)
		}

		NotificationCenter.default.addObserver(forName: .addWaypointVoice, object: nil, queue: .main) { note in
			guard let waypointName = note.userInfo?["name"] as? String else { return }
			context.coordinator.addWaypointWithVoice(arView: arView, name: waypointName)
		}

		return arView
	}

	func updateUIView(_ uiView: ARView, context: Context) {}

	func makeCoordinator() -> Coordinator { Coordinator() }

	final class Coordinator: NSObject, ARSessionDelegate {
		private var spatialAudioManager: SpatialAudioManager?
		private var objectDetectionManager: ObjectDetectionManager?
		private var waypointManager: WaypointManager?
		private var proximityManager: ProximityDetectionManager?
		private var arView: ARView?

		func setSpatialAudioManager(_ manager: SpatialAudioManager) {
			spatialAudioManager = manager
		}
		
		func setObjectDetectionManager(_ manager: ObjectDetectionManager) {
			objectDetectionManager = manager
		}
		
		func setWaypointManager(_ manager: WaypointManager) {
			waypointManager = manager
		}
		
		func setProximityManager(_ manager: ProximityDetectionManager) {
			proximityManager = manager
		}
		
		func setARView(_ view: ARView) {
			arView = view
		}
		
		func setTargetAtCenter(arView: ARView) {
			guard let frame = arView.session.currentFrame else { return }
			
			// Get the center point of the screen
			let screenCenter = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
			
			// Prefer raycast for accuracy (supports vertical and horizontal planes)
			if let raycastResult = arView.raycast(from: screenCenter, allowing: .estimatedPlane, alignment: .any).first {
				let worldTransform = raycastResult.worldTransform
				let worldPosition = simd_float3(worldTransform.columns.3.x, worldTransform.columns.3.y, worldTransform.columns.3.z)
				spatialAudioManager?.setTarget(worldPosition: worldPosition)
				print("Target set via raycast at world position: \(worldPosition)")
				return
			}
			
			// Fallback to classic hitTest with broader types (including vertical planes)
			let hitTestResults = arView.hitTest(
				screenCenter,
				types: [.existingPlaneUsingExtent, .existingPlane, .estimatedHorizontalPlane, .estimatedVerticalPlane, .featurePoint]
			)
			
			if let result = hitTestResults.first {
				let worldTransform = result.worldTransform
				let worldPosition = simd_float3(worldTransform.columns.3.x, worldTransform.columns.3.y, worldTransform.columns.3.z)
				spatialAudioManager?.setTarget(worldPosition: worldPosition)
				print("Target set via hitTest at world position: \(worldPosition)")
			} else {
				// Final fallback: set target 1 meter in front of the camera
				let cameraTransform = frame.camera.transform
				let cameraPosition = simd_float3(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
				let cameraForward = -simd_float3(cameraTransform.columns.2.x, cameraTransform.columns.2.y, cameraTransform.columns.2.z)
				let targetPosition = cameraPosition + cameraForward * 1.0
				spatialAudioManager?.setTarget(worldPosition: targetPosition)
				print("Target set at fallback position: \(targetPosition)")
			}
		}
		
		func addWaypointAtCenter(arView: ARView) {
			guard let frame = arView.session.currentFrame else { return }

			// Get the center point of the screen
			let screenCenter = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)

			// Perform hit test from the center of the screen
			let hitTestResults = arView.hitTest(screenCenter, types: [.existingPlaneUsingExtent, .estimatedHorizontalPlane, .featurePoint])

			if let result = hitTestResults.first {
				// Convert hit test result to world position
				let worldTransform = result.worldTransform
				let worldPosition = simd_float3(worldTransform.columns.3.x, worldTransform.columns.3.y, worldTransform.columns.3.z)

				// Start waypoint creation process
				waypointManager?.startCreatingWaypoint(at: worldPosition)

				print("📍 Starting waypoint creation at world position: \(worldPosition)")
			} else {
				// Fallback: create waypoint 1 meter in front of the camera
				let cameraTransform = frame.camera.transform
				let cameraPosition = simd_float3(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
				let cameraForward = -simd_float3(cameraTransform.columns.2.x, cameraTransform.columns.2.y, cameraTransform.columns.2.z)
				let waypointPosition = cameraPosition + cameraForward * 1.0

				waypointManager?.startCreatingWaypoint(at: waypointPosition)

				print("📍 Starting waypoint creation at fallback position: \(waypointPosition)")
			}
		}

		func addWaypointWithVoice(arView: ARView, name: String) {
			guard let frame = arView.session.currentFrame else { return }

			// Get the center point of the screen (where camera is looking)
			let screenCenter = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)

			// Perform hit test from the center of the screen
			let hitTestResults = arView.hitTest(screenCenter, types: [.existingPlaneUsingExtent, .estimatedHorizontalPlane, .featurePoint])

			if let result = hitTestResults.first {
				// Convert hit test result to world position
				let worldTransform = result.worldTransform
				let worldPosition = simd_float3(worldTransform.columns.3.x, worldTransform.columns.3.y, worldTransform.columns.3.z)

				// Create waypoint directly with voice command
				waypointManager?.createWaypoint(at: worldPosition, name: name)

				print("🎤 Created waypoint '\(name)' at world position: \(worldPosition)")
			} else {
				// Fallback: create waypoint 1 meter in front of the camera
				let cameraTransform = frame.camera.transform
				let cameraPosition = simd_float3(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
				let cameraForward = -simd_float3(cameraTransform.columns.2.x, cameraTransform.columns.2.y, cameraTransform.columns.2.z)
				let waypointPosition = cameraPosition + cameraForward * 1.0

				// Create waypoint directly with voice command
				waypointManager?.createWaypoint(at: waypointPosition, name: name)

				print("🎤 Created waypoint '\(name)' at fallback position: \(waypointPosition)")
			}
		}
		
		func detectAndSetTarget(target: String, arView: ARView, boxOnly: Bool = false) {
			guard let frame = arView.session.currentFrame,
				  let detectionManager = objectDetectionManager else { return }
			
			// Create a copy of the frame data we need to avoid retaining the ARFrame
			let frameData = (
				capturedImage: frame.capturedImage,
				camera: frame.camera,
				sceneDepth: frame.sceneDepth
			)
			
			detectionManager.detectObject(in: frame, target: target) { [weak self] imagePoint, imageBoundingBox in
				guard let self = self, let imagePoint = imagePoint else { 
					print("❌ No detection result or imagePoint")
					return 
				}
				
				print("🎯 Object detected at image point: \(imagePoint)")
				
				// Convert image coordinates to ARView screen coordinates using ARKit displayTransform
				let imageSize = CVImageBufferGetDisplaySize(frameData.capturedImage)
				let screenPoint = self.convertImagePointToScreenPoint(imagePoint, imageSize: imageSize, arView: arView)
				print("📱 Converted to screen point: \(screenPoint)")
				
				// Convert bounding box to screen coordinates if available
				var screenBoundingBox: CGRect? = nil
				if let imageBBox = imageBoundingBox {
					screenBoundingBox = self.convertImageRectToScreenRect(imageBBox, imageSize: imageSize, arView: arView)
				}
				
				if boxOnly {
					// Box-only mode: draw only the bounding box, no center point or spatial target
					self.spatialAudioManager?.setDetectedBoundingBox(screenBoundingBox)
					self.spatialAudioManager?.setDetectedObjectScreenPosition(nil)
					// Also place the waypoint (green target) at the center of the box
					self.setTargetFromScreenPoint(screenPoint, arView: arView, camera: frameData.camera, sceneDepth: frameData.sceneDepth)
					print("🟦 Box-only mode: drew bounding box and placed waypoint at center")
				} else {
					// Show visual indicators where object was detected
					self.spatialAudioManager?.setDetectedObjectScreenPosition(screenPoint)
					self.spatialAudioManager?.setDetectedBoundingBox(screenBoundingBox)
					
					// Convert screen point to world position using LiDAR/depth
					self.setTargetFromScreenPoint(screenPoint, arView: arView, camera: frameData.camera, sceneDepth: frameData.sceneDepth)
				}
			}
		}
		
		private func convertImagePointToScreenPoint(_ imagePoint: CGPoint, imageSize: CGSize, arView: ARView) -> CGPoint {
			let viewSize = arView.bounds.size
			guard let frame = arView.session.currentFrame else { return .zero }
			let interfaceOrientation: UIInterfaceOrientation = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.interfaceOrientation ?? .portrait
			
			var normalized = CGPoint(x: imagePoint.x / imageSize.width, y: imagePoint.y / imageSize.height)
			let transform = frame.displayTransform(for: interfaceOrientation, viewportSize: viewSize)
			let mapped = normalized.applying(transform)
			let screenPoint = CGPoint(x: mapped.x * viewSize.width, y: mapped.y * viewSize.height)
			return CGPoint(x: max(0, min(viewSize.width, screenPoint.x)), y: max(0, min(viewSize.height, screenPoint.y)))
		}
		
		private func convertImageRectToScreenRect(_ imageRect: CGRect, imageSize: CGSize, arView: ARView) -> CGRect {
			let viewSize = arView.bounds.size
			guard let frame = arView.session.currentFrame else { return .zero }
			let interfaceOrientation: UIInterfaceOrientation = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.interfaceOrientation ?? .portrait
			let transform = frame.displayTransform(for: interfaceOrientation, viewportSize: viewSize)
			
			let topLeft = CGPoint(x: imageRect.minX / imageSize.width, y: imageRect.minY / imageSize.height).applying(transform)
			let topRight = CGPoint(x: imageRect.maxX / imageSize.width, y: imageRect.minY / imageSize.height).applying(transform)
			let bottomLeft = CGPoint(x: imageRect.minX / imageSize.width, y: imageRect.maxY / imageSize.height).applying(transform)
			let bottomRight = CGPoint(x: imageRect.maxX / imageSize.width, y: imageRect.maxY / imageSize.height).applying(transform)
			
			let xs = [topLeft.x, topRight.x, bottomLeft.x, bottomRight.x].map { $0 * viewSize.width }
			let ys = [topLeft.y, topRight.y, bottomLeft.y, bottomRight.y].map { $0 * viewSize.height }
			
			let minX = max(0, min(xs.min() ?? 0, viewSize.width))
			let maxX = min(viewSize.width, max(xs.max() ?? 0, 0))
			let minY = max(0, min(ys.min() ?? 0, viewSize.height))
			let maxY = min(viewSize.height, max(ys.max() ?? 0, 0))
			
			return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
		}
		
		private func setTargetFromScreenPoint(_ screenPoint: CGPoint, arView: ARView, camera: ARCamera, sceneDepth: ARDepthData?) {
			// Perform hit test at the detected object's center point
			let hitTestResults = arView.hitTest(screenPoint, types: [.existingPlaneUsingExtent, .estimatedHorizontalPlane, .featurePoint])
			
			if let result = hitTestResults.first {
				// Use hit test result for accurate world position
				let worldTransform = result.worldTransform
				let worldPosition = simd_float3(worldTransform.columns.3.x, worldTransform.columns.3.y, worldTransform.columns.3.z)
				
				spatialAudioManager?.setTarget(worldPosition: worldPosition)
				
				// Force update the target screen position immediately for visual feedback
				DispatchQueue.main.async { [weak self] in
					guard let currentFrame = arView.session.currentFrame else { return }
					print("🟢 Force updating target screen position after hit test")
					self?.spatialAudioManager?.updateTargetScreenPosition(frame: currentFrame, viewBounds: arView.bounds)
				}
				
				print("Object target set at world position: \(worldPosition)")
			} else {
				// Fallback: use depth estimation from LiDAR
				if let depthData = sceneDepth {
					let depthMap = depthData.depthMap
					
					// Convert screen point to normalized coordinates
					let normalizedPoint = CGPoint(
						x: screenPoint.x / arView.bounds.width,
						y: screenPoint.y / arView.bounds.height
					)
					
					// Sample depth at the point
					if let depth = sampleDepth(from: depthMap, at: normalizedPoint, cameraIntrinsics: camera.intrinsics) {
						// Unproject the screen point to world coordinates
						let worldPosition = unprojectPoint(screenPoint, depth: depth, camera: camera, viewBounds: arView.bounds)
						spatialAudioManager?.setTarget(worldPosition: worldPosition)
						
						// Force update the target screen position immediately for visual feedback
						DispatchQueue.main.async { [weak self] in
							guard let currentFrame = arView.session.currentFrame else { return }
							print("🟢 Force updating target screen position after depth sampling")
							self?.spatialAudioManager?.updateTargetScreenPosition(frame: currentFrame, viewBounds: arView.bounds)
						}
						
						print("Object target set using depth at world position: \(worldPosition)")
					} else {
						// Final fallback: estimate based on screen position
						fallbackTargetFromScreenPoint(screenPoint, arView: arView, camera: camera)
					}
				} else {
					// No depth data available, use fallback
					fallbackTargetFromScreenPoint(screenPoint, arView: arView, camera: camera)
				}
			}
		}
		
		private func sampleDepth(from depthMap: CVPixelBuffer, at normalizedPoint: CGPoint, cameraIntrinsics: simd_float3x3) -> Float? {
			CVPixelBufferLockBaseAddress(depthMap, .readOnly)
			defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
			
			let width = CVPixelBufferGetWidth(depthMap)
			let height = CVPixelBufferGetHeight(depthMap)
			
			let x = Int(normalizedPoint.x * CGFloat(width))
			let y = Int(normalizedPoint.y * CGFloat(height))
			
			guard x >= 0, x < width, y >= 0, y < height else { return nil }
			
			let baseAddress = CVPixelBufferGetBaseAddress(depthMap)
			let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
			
			let depthPointer = baseAddress?.assumingMemoryBound(to: Float32.self)
			let depthValue = depthPointer?[y * (bytesPerRow / 4) + x]
			
			return depthValue
		}
		
		private func unprojectPoint(_ screenPoint: CGPoint, depth: Float, camera: ARCamera, viewBounds: CGRect) -> simd_float3 {
			let cameraTransform = camera.transform
			let intrinsics = camera.intrinsics
			
			// Convert screen coordinates to normalized device coordinates
			let normalizedX = (screenPoint.x / viewBounds.width) * 2.0 - 1.0
			let normalizedY = (screenPoint.y / viewBounds.height) * 2.0 - 1.0
			
			// Convert to camera coordinates
			let fx = intrinsics.columns.0.x
			let fy = intrinsics.columns.1.y
			let cx = intrinsics.columns.2.x
			let cy = intrinsics.columns.2.y
			
			let cameraX = (Float(normalizedX) - cx) / fx * depth
			let cameraY = (Float(normalizedY) - cy) / fy * depth
			let cameraZ = -depth // Camera looks down negative Z
			
			// Transform to world coordinates
			let cameraPosition = simd_float4(cameraX, cameraY, cameraZ, 1.0)
			let worldPosition = cameraTransform * cameraPosition
			
			return simd_float3(worldPosition.x, worldPosition.y, worldPosition.z)
		}
		
		private func fallbackTargetFromScreenPoint(_ screenPoint: CGPoint, arView: ARView, camera: ARCamera) {
			// Estimate target 2 meters in front of camera in the direction of the screen point
			let cameraTransform = camera.transform
			let cameraPosition = simd_float3(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
			
			// Calculate direction based on screen point offset from center
			let centerX = arView.bounds.width / 2
			let centerY = arView.bounds.height / 2
			let offsetX = (screenPoint.x - centerX) / centerX * 0.5 // Scale factor
			let offsetY = (screenPoint.y - centerY) / centerY * 0.5
			
			let forward = -simd_float3(cameraTransform.columns.2.x, cameraTransform.columns.2.y, cameraTransform.columns.2.z)
			let right = simd_float3(cameraTransform.columns.0.x, cameraTransform.columns.0.y, cameraTransform.columns.0.z)
			let up = simd_float3(cameraTransform.columns.1.x, cameraTransform.columns.1.y, cameraTransform.columns.1.z)
			
			let targetDirection = forward + right * Float(offsetX) - up * Float(offsetY) // Negative Y because screen Y is inverted
			let normalizedDirection = simd_normalize(targetDirection)
			let targetPosition = cameraPosition + normalizedDirection * 2.0
			
			spatialAudioManager?.setTarget(worldPosition: targetPosition)
			
			// Force update the target screen position immediately for visual feedback
			DispatchQueue.main.async { [weak self] in
				guard let currentFrame = arView.session.currentFrame else { return }
				print("🟢 Force updating target screen position after fallback")
				self?.spatialAudioManager?.updateTargetScreenPosition(frame: currentFrame, viewBounds: arView.bounds)
			}
			
			print("Object target set at fallback position: \(targetPosition)")
		}


		func session(_ session: ARSession, didUpdate frame: ARFrame) {
			// Extract data we need immediately to avoid retaining the frame
			let cameraTransform = frame.camera.transform
			let currentFrame = frame // Only for immediate use
			
			// Update spatial audio listener position and orientation
			spatialAudioManager?.updateListenerPosition(cameraTransform: cameraTransform)
			
			// Update target screen position if we have an AR view
			if let arView = arView {
				spatialAudioManager?.updateTargetScreenPosition(
					frame: currentFrame,
					viewBounds: arView.bounds
				)
				
				// Update proximity detection
				proximityManager?.updateProximity(frame: currentFrame, arView: arView)
			}
			
			// Don't hold onto the frame reference beyond this point
		}

		func session(_ session: ARSession, didAdd anchors: [ARAnchor]) { }
		func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) { }

	}
}

