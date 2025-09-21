#!/usr/bin/env python3
"""
ESP32 Camera Controller - Python interface for ESP32 camera project
Provides Python API to control and interact with the ESP32 camera HTTP server
"""

import requests
import cv2
import numpy as np
from PIL import Image
import io
import threading
import time
from typing import Optional, Dict, Any, Callable
import json

class ESP32CameraController:
    def __init__(self, camera_ip: str, port: int = 80, stream_port: int = 81):
        """
        Initialize ESP32 Camera Controller
        
        Args:
            camera_ip: IP address of the ESP32 camera (e.g., "192.168.1.100")
            port: HTTP server port (default: 80)
            stream_port: Stream server port (default: 81)
        """
        self.camera_ip = camera_ip
        self.port = port
        self.stream_port = stream_port
        self.base_url = f"http://{camera_ip}:{port}"
        self.stream_url = f"http://{camera_ip}:{stream_port}"
        self._stream_thread = None
        self._streaming = False
        
    def test_connection(self) -> bool:
        """Test if the ESP32 camera is reachable"""
        try:
            response = requests.get(f"{self.base_url}/status", timeout=5)
            return response.status_code == 200
        except requests.RequestException:
            return False
    
    def get_status(self) -> Optional[Dict[str, Any]]:
        """Get camera status and settings"""
        try:
            response = requests.get(f"{self.base_url}/status", timeout=5)
            if response.status_code == 200:
                return response.json()
        except requests.RequestException as e:
            print(f"Error getting status: {e}")
        return None
    
    def capture_image(self, save_path: Optional[str] = None) -> Optional[np.ndarray]:
        """
        Capture a single image from the camera
        
        Args:
            save_path: Optional path to save the image
            
        Returns:
            numpy array of the image, or None if failed
        """
        try:
            response = requests.get(f"{self.base_url}/capture", timeout=10)
            if response.status_code == 200:
                # Convert to numpy array
                image_array = np.frombuffer(response.content, dtype=np.uint8)
                image = cv2.imdecode(image_array, cv2.IMREAD_COLOR)
                
                if save_path:
                    cv2.imwrite(save_path, image)
                    print(f"Image saved to {save_path}")
                
                return image
        except requests.RequestException as e:
            print(f"Error capturing image: {e}")
        return None
    
    def capture_bmp(self, save_path: Optional[str] = None) -> Optional[np.ndarray]:
        """Capture image in BMP format"""
        try:
            response = requests.get(f"{self.base_url}/bmp", timeout=10)
            if response.status_code == 200:
                image_array = np.frombuffer(response.content, dtype=np.uint8)
                image = cv2.imdecode(image_array, cv2.IMREAD_COLOR)
                
                if save_path:
                    cv2.imwrite(save_path, image)
                    print(f"BMP image saved to {save_path}")
                
                return image
        except requests.RequestException as e:
            print(f"Error capturing BMP: {e}")
        return None
    
    def set_camera_setting(self, setting: str, value: Any) -> bool:
        """
        Set camera setting via control endpoint
        
        Args:
            setting: Setting name (e.g., 'framesize', 'quality', 'brightness')
            value: Setting value
            
        Returns:
            True if successful
        """
        try:
            params = {setting: value}
            response = requests.get(f"{self.base_url}/control", params=params, timeout=5)
            return response.status_code == 200
        except requests.RequestException as e:
            print(f"Error setting {setting}: {e}")
        return False
    
    def set_resolution(self, resolution: str) -> bool:
        """
        Set camera resolution
        
        Common resolutions: 'UXGA', 'SVGA', 'VGA', 'CIF', 'QVGA', etc.
        """
        return self.set_camera_setting('framesize', resolution)
    
    def set_quality(self, quality: int) -> bool:
        """Set JPEG quality (0-63, lower = higher quality)"""
        return self.set_camera_setting('quality', quality)
    
    def set_brightness(self, brightness: int) -> bool:
        """Set brightness (-2 to 2)"""
        return self.set_camera_setting('brightness', brightness)
    
    def set_contrast(self, contrast: int) -> bool:
        """Set contrast (-2 to 2)"""
        return self.set_camera_setting('contrast', contrast)
    
    def set_saturation(self, saturation: int) -> bool:
        """Set saturation (-2 to 2)"""
        return self.set_camera_setting('saturation', saturation)
    
    def set_special_effect(self, effect: int) -> bool:
        """Set special effect (0=None, 1=Negative, 2=Grayscale, etc.)"""
        return self.set_camera_setting('special_effect', effect)
    
    def set_white_balance(self, wb: bool) -> bool:
        """Enable/disable auto white balance"""
        return self.set_camera_setting('awb', 1 if wb else 0)
    
    def set_exposure_control(self, aec: bool) -> bool:
        """Enable/disable auto exposure control"""
        return self.set_camera_setting('aec', 1 if aec else 0)
    
    def set_gain_control(self, agc: bool) -> bool:
        """Enable/disable auto gain control"""
        return self.set_camera_setting('agc', 1 if agc else 0)
    
    def flip_vertical(self, enable: bool = True) -> bool:
        """Flip image vertically"""
        return self.set_camera_setting('vflip', 1 if enable else 0)
    
    def flip_horizontal(self, enable: bool = True) -> bool:
        """Flip image horizontally"""
        return self.set_camera_setting('hmirror', 1 if enable else 0)
    
    def start_stream(self, frame_callback: Optional[Callable[[np.ndarray], None]] = None, 
                    display: bool = True) -> bool:
        """
        Start video streaming
        
        Args:
            frame_callback: Function to call with each frame
            display: Whether to display frames in OpenCV window
        """
        if self._streaming:
            print("Stream already running")
            return False
        
        def stream_worker():
            try:
                response = requests.get(f"{self.stream_url}/stream", stream=True, timeout=30)
                if response.status_code != 200:
                    print(f"Stream error: {response.status_code}")
                    return
                
                buffer = b""
                
                for chunk in response.iter_content(chunk_size=1024):
                    if not self._streaming:
                        break
                    
                    buffer += chunk
                    
                    # Look for JPEG boundaries
                    while True:
                        start = buffer.find(b'\xff\xd8')  # JPEG start
                        end = buffer.find(b'\xff\xd9')    # JPEG end
                        
                        if start != -1 and end != -1 and end > start:
                            # Extract JPEG image
                            jpeg_data = buffer[start:end+2]
                            buffer = buffer[end+2:]
                            
                            try:
                                # Decode image
                                image_array = np.frombuffer(jpeg_data, dtype=np.uint8)
                                frame = cv2.imdecode(image_array, cv2.IMREAD_COLOR)
                                
                                if frame is not None:
                                    # Call callback if provided
                                    if frame_callback:
                                        frame_callback(frame)
                                    
                                    # Display frame if requested
                                    if display:
                                        cv2.imshow('ESP32 Camera Stream', frame)
                                        if cv2.waitKey(1) & 0xFF == ord('q'):
                                            self._streaming = False
                                            break
                            except Exception as e:
                                print(f"Frame decode error: {e}")
                        else:
                            break
            
            except requests.RequestException as e:
                print(f"Stream error: {e}")
            finally:
                if display:
                    cv2.destroyAllWindows()
        
        self._streaming = True
        self._stream_thread = threading.Thread(target=stream_worker)
        self._stream_thread.daemon = True
        self._stream_thread.start()
        return True
    
    def stop_stream(self):
        """Stop video streaming"""
        self._streaming = False
        if self._stream_thread:
            self._stream_thread.join(timeout=2)
        cv2.destroyAllWindows()
    
    def get_web_interface_url(self) -> str:
        """Get URL for web interface"""
        return self.base_url
    
    def __enter__(self):
        return self
    
    def __exit__(self, exc_type, exc_val, exc_tb):
        self.stop_stream()


def main():
    """Example usage of ESP32CameraController"""
    # Replace with your ESP32 camera IP address
    CAMERA_IP = "172.20.10.8"  # Your ESP32's actual IP
    
    print("ESP32 Camera Controller Example")
    print("=" * 40)
    
    # Create controller instance
    camera = ESP32CameraController(CAMERA_IP)
    
    # Test connection
    if not camera.test_connection():
        print(f"❌ Cannot connect to camera at {CAMERA_IP}")
        print("Make sure:")
        print("1. ESP32 is powered on and running the camera code")
        print("2. ESP32 is connected to WiFi")
        print("3. Update CAMERA_IP in this script")
        return
    
    print(f"✅ Connected to ESP32 camera at {CAMERA_IP}")
    
    # Get camera status
    status = camera.get_status()
    if status:
        print(f"📊 Camera Status: {json.dumps(status, indent=2)}")
    
    # Configure camera settings
    print("\n🔧 Configuring camera settings...")
    camera.set_quality(10)  # Good quality
    camera.set_brightness(0)  # Normal brightness
    camera.set_contrast(0)  # Normal contrast
    
    # Capture a single image
    print("\n📸 Capturing image...")
    image = camera.capture_image("captured_image.jpg")
    if image is not None:
        print("✅ Image captured successfully!")
        print(f"Image shape: {image.shape}")
    
    # Start streaming (press 'q' to stop)
    print("\n🎥 Starting video stream (press 'q' to stop)...")
    camera.start_stream(display=True)
    
    # Wait for user to stop streaming
    input("Press Enter to stop streaming and exit...")
    camera.stop_stream()
    
    print(f"\n🌐 Web interface available at: {camera.get_web_interface_url()}")


if __name__ == "__main__":
    main()
