# RoomMapper (ARKit + RealityKit)

An iOS SwiftUI app that uses ARKit scene reconstruction to map a room and visualize mesh with debug overlays.

## Requirements
- Xcode 15 or newer
- iOS 17 device with LiDAR (e.g., iPhone 12 Pro or newer) for mesh reconstruction
- Developer account to sign and run on device

## Setup
1. Generate the Xcode project (already done):

```bash
cd RoomMapper
xcodegen generate
```

2. Open the project:

```bash
open RoomMapper.xcodeproj
```

3. In Xcode:
- Select the `RoomMapper` target.
- Set your Team in Signing & Capabilities.
- Ensure a physical device with LiDAR is selected.

4. Run on device. Grant camera access when prompted.

## Notes
- Mesh visualization is enabled via `ARView.DebugOptions.showSceneUnderstanding`.
- The app enables horizontal/vertical plane detection, scene reconstruction, and uses `sceneDepth` if supported.

MD
