# RoomMapper (ARKit + RealityKit + WebSocket streaming)

## iOS App
- Streams AR mesh anchors over WebSocket as JSON
- UI to configure server URL and start/stop streaming

### Run
1. Open in Xcode, set Signing Team, select device, Run.
2. Ensure the Python server is reachable on the same network.

## Python Server
Located in `RoomStreamServer/`.

### Setup
```bash
cd RoomStreamServer
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python server.py
```
- Server listens at `ws://0.0.0.0:8765` and visualizes the merged mesh (Open3D).

### Data format (JSON text frame)
```json
{
  "type": "mesh-anchor",
  "anchorId": "UUID",
  "transform": [16 floats],
  "vertices": [x,y,z,...],
  "normals": [x,y,z,...],
  "indices": [i0,i1,i2,...]
}
```
