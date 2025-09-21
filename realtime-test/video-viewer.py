#!/usr/bin/env python3
"""
Video Viewer Client for KellerAI Backend
Connects as a viewer to watch the video stream from the broadcaster.
"""

import asyncio
import websockets
import cv2
import json
import base64
import signal
import sys
import time
import numpy as np
from typing import Optional
import threading
import queue

# Configuration - Backend server video endpoint (viewer role)
BACKEND_SERVER_URL = "ws://35.238.205.88:8081/video?role=viewer"

# Display settings
WINDOW_NAME = "KellerAI Video Stream"
WINDOW_WIDTH = 640
WINDOW_HEIGHT = 480

class VideoViewerClient:
    def __init__(self):
        self.websocket: Optional[websockets.WebSocketClientProtocol] = None
        self.frame_queue = queue.Queue(maxsize=5)  # Small buffer for smooth playback
        self.is_connected = False
        self.is_displaying = False
        self.running = True
        self.broadcaster_connected = False
        
        print("📺 Starting Video Viewer for KellerAI Backend...")
        print("📝 Instructions:")
        print("   - Connecting as viewer to watch video stream")
        print("   - Press 'q' in video window or Ctrl+C to quit")
        print("   - Video window will appear when broadcaster starts streaming")
        print(f"   - Backend server: {BACKEND_SERVER_URL}\n")
    
    async def connect_websocket(self):
        """Connect to the video WebSocket endpoint as viewer."""
        try:
            print("🔌 Connecting to backend server as viewer...")
            self.websocket = await websockets.connect(
                BACKEND_SERVER_URL,
                ping_interval=20,
                ping_timeout=10,
                close_timeout=10
            )
            self.is_connected = True
            print("✅ Connected to video WebSocket as viewer")
            
            # Start listening for video frames
            asyncio.create_task(self.listen_for_frames())
            
        except Exception as e:
            print(f"❌ WebSocket connection failed: {e}")
            return False
        
        return True
    
    async def listen_for_frames(self):
        """Listen for video frames from the WebSocket server."""
        try:
            async for message in self.websocket:
                try:
                    data = json.loads(message)
                    
                    if data.get("type") == "viewer_connected":
                        self.broadcaster_connected = data.get("broadcaster_connected", False)
                        if self.broadcaster_connected:
                            print("📡 Broadcaster is online, waiting for video frames...")
                        else:
                            print("⏳ Waiting for broadcaster to connect...")
                    
                    elif data.get("type") == "video_frame":
                        # Decode and queue video frame
                        try:
                            frame_base64 = data.get("data")
                            if frame_base64:
                                # Decode base64 to bytes
                                frame_bytes = base64.b64decode(frame_base64)
                                
                                # Decode JPEG to OpenCV image
                                nparr = np.frombuffer(frame_bytes, np.uint8)
                                frame = cv2.imdecode(nparr, cv2.IMREAD_COLOR)
                                
                                if frame is not None:
                                    # Add to display queue (non-blocking)
                                    try:
                                        self.frame_queue.put_nowait(frame)
                                        
                                        # Start display thread if not already running
                                        if not self.is_displaying:
                                            self.is_displaying = True
                                            display_thread = threading.Thread(
                                                target=self.display_frames, 
                                                daemon=True
                                            )
                                            display_thread.start()
                                    
                                    except queue.Full:
                                        # Drop frame if queue is full
                                        try:
                                            self.frame_queue.get_nowait()  # Remove oldest frame
                                            self.frame_queue.put_nowait(frame)  # Add new frame
                                        except queue.Empty:
                                            pass
                        
                        except Exception as e:
                            print(f"⚠️  Frame decode error: {e}")
                    
                    else:
                        print(f"📥 Server message: {data}")
                
                except json.JSONDecodeError:
                    print(f"📥 Non-JSON message: {message}")
                
        except websockets.exceptions.ConnectionClosed:
            print("🔌 WebSocket connection closed")
            self.is_connected = False
        except Exception as e:
            print(f"⚠️  WebSocket listen error: {e}")
            self.is_connected = False
    
    def display_frames(self):
        """Display video frames in OpenCV window (runs in separate thread)."""
        print("🎬 Starting video display...")
        
        # Create window
        cv2.namedWindow(WINDOW_NAME, cv2.WINDOW_NORMAL)
        cv2.resizeWindow(WINDOW_NAME, WINDOW_WIDTH, WINDOW_HEIGHT)
        
        # Display loop
        while self.running and self.is_connected:
            try:
                # Get frame from queue (blocking with timeout)
                frame = self.frame_queue.get(timeout=0.1)
                
                # Display frame
                cv2.imshow(WINDOW_NAME, frame)
                
                # Check for quit key (1ms timeout)
                key = cv2.waitKey(1) & 0xFF
                if key == ord('q') or key == 27:  # 'q' or ESC
                    print("👋 Quit key pressed")
                    self.running = False
                    break
                
                # Check if window was closed
                if cv2.getWindowProperty(WINDOW_NAME, cv2.WND_PROP_VISIBLE) < 1:
                    print("👋 Window closed")
                    self.running = False
                    break
            
            except queue.Empty:
                # No frame available, continue
                # Still need to process OpenCV events
                key = cv2.waitKey(1) & 0xFF
                if key == ord('q') or key == 27:
                    print("👋 Quit key pressed")
                    self.running = False
                    break
                
                if cv2.getWindowProperty(WINDOW_NAME, cv2.WND_PROP_VISIBLE) < 1:
                    print("👋 Window closed")
                    self.running = False
                    break
            
            except Exception as e:
                print(f"⚠️  Display error: {e}")
                time.sleep(0.1)
        
        # Cleanup
        cv2.destroyAllWindows()
        self.is_displaying = False
        print("🔚 Video display stopped")
    
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
        self.is_connected = False
        cv2.destroyAllWindows()
    
    async def run(self):
        """Main run loop."""
        # Connect to WebSocket
        if not await self.connect_websocket():
            return
        
        try:
            # Keep connection alive and handle the video display
            print("⏳ Waiting for video stream... (Press Ctrl+C to quit)")
            
            while self.running and self.is_connected:
                await asyncio.sleep(0.1)
                
        except KeyboardInterrupt:
            print("\n👋 Interrupted, exiting...")
        except Exception as e:
            print(f"⚠️  Runtime error: {e}")
        
        finally:
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
    
    client = VideoViewerClient()
    await client.run()

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n👋 Goodbye!")
    except Exception as e:
        print(f"❌ Unexpected error: {e}")
        sys.exit(1)
