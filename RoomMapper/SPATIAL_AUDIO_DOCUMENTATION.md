# RoomMapper Spatial Audio System Documentation

## Overview

The RoomMapper app implements a sophisticated spatial audio system that creates 3D positioned sound using AirPods head tracking and ARKit world tracking. This allows users to hear audio "pings" that appear to come from specific locations in 3D space, even as they move around and turn their head.

## Architecture

### Core Components

1. **SpatialAudioManager** - Main class handling all spatial audio logic
2. **AVAudioEngine** - Apple's low-level audio processing engine
3. **AVAudioEnvironmentNode** - 3D spatial audio processing node
4. **CMHeadphoneMotionManager** - AirPods head tracking
5. **ARKit Integration** - World position tracking

## How Spatial Audio Works

### 1. Audio Engine Setup

```swift
private func setupAudioEngine() {
    // Configure environment node for headphone spatial audio
    environmentNode.outputType = .headphones
    environmentNode.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
    environmentNode.listenerVectorOrientation = AVAudio3DVectorOrientation(
        forward: AVAudio3DVector(x: 0, y: 0, z: -1),
        up: AVAudio3DVector(x: 0, y: 1, z: 0)
    )
    
    // Audio chain: playerNode -> environmentNode -> output
    audioEngine.connect(playerNode, to: environmentNode, format: audioFormat)
    audioEngine.connect(environmentNode, to: audioEngine.outputNode, format: nil)
    
    // Configure for HRTF (Head-Related Transfer Function)
    playerNode.renderingAlgorithm = .HRTF
}
```

**Key Concepts:**
- **HRTF (Head-Related Transfer Function)**: Algorithm that simulates how sound reaches each ear differently based on head position and sound source location
- **Environment Node**: Processes 3D audio positioning and applies spatial effects
- **Listener Position**: Your location in 3D space (from phone's ARKit tracking)
- **Listener Orientation**: Which direction you're facing (from AirPods head tracking)

### 2. Dual Tracking System

#### Position Tracking (ARKit)
```swift
func updateListenerPosition(cameraTransform: simd_float4x4) {
    // Extract position from camera transform (phone's position in world)
    let position = cameraTransform.columns.3
    currentCameraPosition = simd_float3(position.x, position.y, position.z)
    
    // Update listener position from phone's AR tracking
    environmentNode.listenerPosition = AVAudio3DPoint(
        x: position.x, y: position.y, z: position.z
    )
}
```

#### Orientation Tracking (AirPods)
```swift
private func updateListenerOrientation(from motion: CMDeviceMotion) {
    let rotationMatrix = motion.attitude.rotationMatrix
    
    // Convert AirPods coordinate system to audio coordinate system
    let forward = AVAudio3DVector(
        x: Float(-rotationMatrix.m13),
        y: Float(-rotationMatrix.m23), 
        z: Float(rotationMatrix.m33)
    )
    
    let up = AVAudio3DVector(
        x: Float(rotationMatrix.m12),
        y: Float(rotationMatrix.m22),
        z: Float(-rotationMatrix.m32)
    )
    
    environmentNode.listenerVectorOrientation = AVAudio3DVectorOrientation(
        forward: forward,
        up: up
    )
}
```

**Why This Hybrid Approach:**
- **Position from Phone**: ARKit provides accurate world-space positioning as you walk around
- **Orientation from AirPods**: Head tracking provides accurate head direction, independent of phone orientation
- **Result**: You can hold your phone pointing anywhere while your head movements control audio orientation

### 3. Sound Generation

#### Standard Ping Sound
```swift
// Simple 800Hz sine wave with exponential decay
for i in 0..<Int(standardFrameCount) {
    let time = Float(i) / Float(sampleRate)
    let amplitude = exp(-time * 5.0) * 0.25
    let sample = sin(2.0 * Float.pi * 800 * time) * amplitude
    channelData[i] = sample
}
```

#### Close Proximity Bell Sound
```swift
// Pleasant bell with harmonics for when very close to target
let fundamental = sin(2.0 * Float.pi * 1200 * time)
let harmonic2 = sin(2.0 * Float.pi * 1800 * time) * 0.3
let harmonic3 = sin(2.0 * Float.pi * 2400 * time) * 0.15
let sample = (fundamental + harmonic2 + harmonic3) * amplitude
```

### 4. Distance-Based Ping Frequency

```swift
private func calculatePingInterval() -> TimeInterval {
    let distance = simd_distance(currentCameraPosition, target)
    let clampedDistance = max(minDistance, min(maxDistance, distance))
    let normalizedDistance = (clampedDistance - minDistance) / (maxDistance - minDistance)
    
    // Exponential curve makes pings much faster when close
    let exponentialDistance = pow(normalizedDistance, 2.5)
    let interval = minPingInterval + (maxPingInterval - minPingInterval) * TimeInterval(exponentialDistance)
    
    return interval
}
```

**Ping Frequency Ranges:**
- **Far (3+ meters)**: 1.2 seconds between pings
- **Close (0.5 meters)**: 0.15 seconds + bell sound
- **Very close (0.1 meters)**: Maximum frequency

### 5. 3D Audio Positioning

```swift
func setTarget(worldPosition: simd_float3) {
    targetWorldPosition = worldPosition
    // Position the audio source in 3D space
    playerNode.position = AVAudio3DPoint(x: worldPosition.x, y: worldPosition.y, z: worldPosition.z)
    startPinging()
}
```

## Coordinate Systems

### World Space (ARKit)
- **Origin**: Where ARKit session started
- **X**: Right
- **Y**: Up  
- **Z**: Toward user (at session start)
- **Units**: Meters

### AirPods Motion Space
- **X**: Right (when wearing normally)
- **Y**: Up (top of head)
- **Z**: Forward (direction of face)

### Audio Space (AVAudioEnvironmentNode)
- **X**: Right
- **Y**: Up
- **Z**: Forward (negative values = toward listener)

## Visual Feedback System

### Screen Projection
```swift
func updateTargetScreenPosition(frame: ARFrame, viewBounds: CGRect) {
    // Use ARKit's built-in projection
    let screenPoint = camera.projectPoint(worldPos, 
                                          orientation: .portrait, 
                                          viewportSize: CGSize(width: viewBounds.width, height: viewBounds.height))
    
    // Check bounds and update UI
    if screenPoint.x >= 0 && screenPoint.x <= viewBounds.width && 
       screenPoint.y >= 0 && screenPoint.y <= viewBounds.height {
        targetScreenPosition = CGPoint(x: CGFloat(screenPoint.x), y: CGFloat(screenPoint.y))
    }
}
```

### UI Elements
- **Crosshair**: Shows where new targets will be placed (center of screen)
- **Green Circle**: Shows where current audio target is located in 3D space
- **Musical Note**: Visual indicator above the target location
- **Status Badge**: Shows when spatial audio is active

## Performance Considerations

### Update Rates
- **ARKit Frame Updates**: ~60 FPS (tied to camera frame rate)
- **AirPods Head Tracking**: ~60 FPS (automatic, managed by CMHeadphoneMotionManager)
- **Audio Buffer Scheduling**: Dynamic based on distance

### Memory Management
- **Audio Buffers**: Pre-generated and cached (standard ping + close bell)
- **Weak References**: Used in completion handlers to prevent retain cycles
- **Automatic Cleanup**: Head tracking and audio engine stopped in deinit

## Technical Deep Dive

### HRTF Processing
The `AVAudioPlayerNode` uses HRTF (Head-Related Transfer Function) processing when `renderingAlgorithm = .HRTF`. This simulates:

1. **Interaural Time Difference (ITD)**: Sound reaches one ear before the other
2. **Interaural Level Difference (ILD)**: Sound is louder in the ear closer to source
3. **Spectral Filtering**: Head and ear shape affect frequency response
4. **Distance Modeling**: Volume and reverb change with distance

### Coordinate System Transformations

```swift
// AirPods -> Audio Space Conversion
let forward = AVAudio3DVector(
    x: Float(-rotationMatrix.m13), // Negate Z component
    y: Float(-rotationMatrix.m23), // Negate Y component  
    z: Float(rotationMatrix.m33)   // Z becomes forward
)
```

This transformation accounts for the different coordinate system conventions between Core Motion and AVAudioEnvironmentNode.

## Potential Improvements

### 1. Enhanced Distance Modeling
```swift
// Add realistic distance attenuation
let distanceAttenuation = 1.0 / (1.0 + distance * 0.1)
playerNode.volume = Float(distanceAttenuation)
```

### 2. Reverb Based on Room Acoustics
```swift
// Use ARKit's room mesh to calculate reverb parameters
let reverbNode = AVAudioUnitReverb()
reverbNode.loadFactoryPreset(.largeRoom)
audioEngine.attach(reverbNode)
```

### 3. Multiple Audio Sources
```swift
// Support multiple simultaneous spatial audio sources
var audioSources: [UUID: AVAudioPlayerNode] = [:]
```

### 4. Advanced Head Tracking
```swift
// Add head velocity for Doppler effects
let headVelocity = calculateHeadVelocity(from: motion)
// Apply Doppler shift to audio frequency
```

### 5. Environmental Audio
```swift
// Use ARKit plane detection for audio occlusion
if wallBetweenListenerAndSource {
    applyOcclusionFilter()
}
```

## Debugging Tips

### Audio Issues
- Check `headTracker.isDeviceMotionAvailable` for AirPods connection
- Verify `audioEngine.isRunning` before playing sounds
- Monitor `environmentNode.listenerPosition` values
- Use `print()` statements to track coordinate transformations

### Visual Indicator Issues
- Verify `targetScreenPosition` values are within screen bounds
- Check if `targetWorldPosition` is behind camera (should be nil)
- Monitor ARKit tracking state: `frame.camera.trackingState`

### Performance Issues
- Profile audio buffer allocation and reuse
- Monitor update frequencies with Instruments
- Check for retain cycles in completion handlers

## Summary

The spatial audio system works by:

1. **Tracking your position** in 3D space using ARKit
2. **Tracking your head orientation** using AirPods motion sensors  
3. **Positioning virtual audio sources** at specific world coordinates
4. **Processing audio** through HRTF algorithms to simulate realistic 3D sound
5. **Providing visual feedback** by projecting 3D positions to screen coordinates
6. **Adjusting ping frequency** based on proximity to create intuitive navigation

This creates an immersive audio experience where sounds truly appear to come from specific locations in your physical environment, making it possible to navigate to targets using audio cues alone.
