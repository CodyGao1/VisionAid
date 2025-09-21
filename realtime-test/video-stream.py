#!/usr/bin/env python3
"""
Video Streaming Client for KellerAI Backend
Captures video from computer camera and streams to WebSocket endpoint.
"""

import asyncio
import websockets
import cv2
import json
import base64
import threading
import signal
import sys
import time
from typing import Optional
import queue

# Configuration - Backend server video endpoint
BACKEND_SERVER_URL = "ws://35.238.205.88:8081/video?role=broadcaster"

# Video settings
FRAME_WIDTH = 640
FRAME_HEIGHT = 480
FPS = 5  # Reduced for debugging
JPEG_QUALITY = 80

class VideoStreamClient:
    def __init__(self):
        self.websocket: Optional[websockets.WebSocketClientProtocol] = None
        self.camera: Optional[cv2.VideoCapture] = None
        self.is_streaming = False
        self.frame_queue = queue.Queue(maxsize=2)  # Smaller queue for debugging
        self.running = True
        
        print("📹 Starting Video Stream to KellerAI Backend...")
        print("📝 Instructions:")
        print("   - Press ENTER to start/stop streaming")
        print("   - Type 'q' and press ENTER to quit")
        print("   - Video will be broadcast to all connected viewers")
        print(f"   - Backend server: {BACKEND_SERVER_URL}\n")
    
    def setup_camera(self):
        """Initialize camera capture."""
        try:
            print("🎥 Initializing camera...")
            self.camera = cv2.VideoCapture(0)  # Use default camera
            
            if not self.camera.isOpened():
                print("❌ Could not open camera")
                return False
            
            # Set camera properties
            self.camera.set(cv2.CAP_PROP_FRAME_WIDTH, FRAME_WIDTH)
            self.camera.set(cv2.CAP_PROP_FRAME_HEIGHT, FRAME_HEIGHT)
            self.camera.set(cv2.CAP_PROP_FPS, FPS)
            
            # Get actual properties (might be different from requested)
            actual_width = int(self.camera.get(cv2.CAP_PROP_FRAME_WIDTH))
            actual_height = int(self.camera.get(cv2.CAP_PROP_FRAME_HEIGHT))
            actual_fps = self.camera.get(cv2.CAP_PROP_FPS)
            
            print(f"✅ Camera initialized: {actual_width}x{actual_height} @ {actual_fps}fps")
            return True
            
        except Exception as e:
            print(f"❌ Camera setup failed: {e}")
            return False
    
    def capture_frames(self):
        """Capture video frames in a separate thread."""
        print("🎬 Starting frame capture thread...")
        frame_interval = 1.0 / FPS
        frame_count = 0
        
        while self.running and self.camera is not None:
            if self.is_streaming:
                try:
                    ret, frame = self.camera.read()
                    frame_count += 1
                    if ret:
                        if frame_count % 10 == 0:  # Only print every 10th frame
                            print(f"📸 Captured frame {frame_count}: {frame.shape}")
                        # Encode frame as JPEG
                        encode_param = [cv2.IMWRITE_JPEG_QUALITY, JPEG_QUALITY]
                        _, buffer = cv2.imencode('.jpg', frame, encode_param)
                        
                        # Convert to base64
                        frame_base64 = base64.b64encode(buffer).decode('utf-8')
                        
                        # Add to queue (non-blocking, drop frames if queue is full)
                        try:
                            self.frame_queue.put_nowait({
                                "type": "video_frame",
                                "data": frame_base64,
                                "timestamp": time.time(),
                                "format": "jpeg",
                                "width": frame.shape[1],
                                "height": frame.shape[0]
                            })
                            if frame_count % 10 == 0:  # Only print every 10th frame
                                print(f"🎯 Frame {frame_count} queued (queue size: {self.frame_queue.qsize()})")
                        except queue.Full:
                            # Drop frame if queue is full (prevents memory buildup)
                            if frame_count % 10 == 0:  # Only print every 10th frame
                                print(f"⚠️ Frame {frame_count} - Queue full, dropping frame")
                            pass
                    else:
                        print("❌ Failed to capture frame from camera")  # Debug info
                            
                    time.sleep(frame_interval)
                    
                except Exception as e:
                    print(f"⚠️  Frame capture error: {e}")
                    time.sleep(0.1)
            else:
                time.sleep(0.1)
        
        print("🔚 Frame capture thread stopped")
    
    async def connect_websocket(self):
        """Connect to the video WebSocket endpoint."""
        try:
            print("🔌 Connecting to backend server...")
            self.websocket = await websockets.connect(
                BACKEND_SERVER_URL,
                ping_interval=20,
                ping_timeout=10,
                close_timeout=10
            )
            print("✅ Connected to video WebSocket as broadcaster")
            
            # Start listening for messages
            asyncio.create_task(self.listen_for_messages())
            
        except Exception as e:
            print(f"❌ WebSocket connection failed: {e}")
            return False
        
        return True
    
    async def listen_for_messages(self):
        """Listen for messages from the WebSocket server."""
        try:
            async for message in self.websocket:
                try:
                    data = json.loads(message)
                    if data.get("type") == "broadcaster_connected":
                        print(f"📡 Broadcasting to {data.get('viewers', 0)} viewers")
                    else:
                        print(f"📥 Server message: {data}")
                except json.JSONDecodeError:
                    print(f"📥 Server message: {message}")
        except websockets.exceptions.ConnectionClosed:
            print("🔌 WebSocket connection closed")
        except Exception as e:
            print(f"⚠️  WebSocket listen error: {e}")
    
    async def send_frames(self):
        """Send video frames to WebSocket server."""
        print("📤 SEND_FRAMES FUNCTION CALLED - Starting frame transmission...")
        
        while self.running and self.websocket:
            if self.is_streaming:
                print("🔄 In streaming loop, trying to get frame from queue...")
                try:
                    # Get frame from queue (blocking with timeout)
                    frame_data = self.frame_queue.get(timeout=0.1)
                    
                    print(f"📤 Sending frame...")  # Debug info
                    # Send frame to server with timeout
                    await asyncio.wait_for(
                        self.websocket.send(json.dumps(frame_data)), 
                        timeout=1.0
                    )
                    print(f"✅ Frame sent successfully")  # Debug info
                    
                except queue.Empty:
                    # No frame available, continue
                    print("⏳ No frames in queue, waiting...")  # Debug info
                    pass
                except asyncio.TimeoutError:
                    print("⏰ WebSocket send timeout - connection may be slow")
                    await asyncio.sleep(0.1)
                except websockets.exceptions.ConnectionClosed:
                    print("🔌 WebSocket connection closed during transmission")
                    break
                except Exception as e:
                    print(f"⚠️  Frame transmission error: {e}")
                    await asyncio.sleep(0.1)
            else:
                await asyncio.sleep(0.1)
        
        print("🔚 Frame transmission stopped")
    
    async def start_streaming(self):
        """Start video streaming."""
        if self.is_streaming:
            print("⚠️  Already streaming")
            return
        
        if not self.websocket:
            if not await self.connect_websocket():
                return
        
        print("🎬 Starting video stream...")
        self.is_streaming = True
        
        # Start sending frames
        print("🚀 Creating send_frames task...")
        task = asyncio.create_task(self.send_frames())
        print(f"✅ Task created: {task}")
    
    def stop_streaming(self):
        """Stop video streaming."""
        if not self.is_streaming:
            print("⚠️  Not currently streaming")
            return
        
        print("⏹️  Stopping video stream...")
        self.is_streaming = False
    
    async def disconnect(self):
        """Disconnect from WebSocket."""
        if self.websocket:
            try:
                await self.websocket.close()
                print("👋 Disconnected from server")
            except:
                pass
    
    def cleanup(self):
        """Clean up resources."""
        print("🧹 Cleaning up resources...")
        
        self.running = False
        self.is_streaming = False
        
        if self.camera:
            self.camera.release()
        
        cv2.destroyAllWindows()
    
    async def run(self):
        """Main run loop."""
        # Setup camera
        if not self.setup_camera():
            return
        
        # Start frame capture thread
        capture_thread = threading.Thread(target=self.capture_frames, daemon=True)
        capture_thread.start()
        
        # Connect to WebSocket
        if not await self.connect_websocket():
            self.cleanup()
            return
        
        # Auto-start streaming for testing
        print("🚀 AUTO-STARTING STREAMING FOR TESTING...")
        await self.start_streaming()
        
        # Simple loop to keep running
        try:
            print("📺 Streaming started! Press Ctrl+C to stop...")
            while self.running:
                await asyncio.sleep(1)  # Give time for other tasks
                
        except KeyboardInterrupt:
            print("\n👋 Interrupted, exiting...")
        
        finally:
            self.stop_streaming()
            await self.disconnect()
            self.cleanup()

def signal_handler(signum, frame):
    """Handle shutdown signals gracefully."""
    print(f"\n🛑 Received signal {signum}, shutting down...")
    sys.exit(0)

async def main():
    """Main function."""
    # Set up signal handlers
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    
    client = VideoStreamClient()
    await client.run()

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n👋 Goodbye!")
    except Exception as e:
        print(f"❌ Unexpected error: {e}")
        sys.exit(1)
