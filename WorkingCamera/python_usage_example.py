#!/usr/bin/env python3
"""
Simple usage examples for ESP32CameraController
"""

from esp32_camera_controller import ESP32CameraController
import time
import cv2

# Configure your ESP32 camera IP address
CAMERA_IP = "172.20.10.8"  # Your ESP32's actual IP

def basic_example():
    """Basic usage - capture a single image"""
    print("Basic Example: Single Image Capture")
    print("-" * 40)
    
    with ESP32CameraController(CAMERA_IP) as camera:
        if camera.test_connection():
            print("✅ Camera connected!")
            
            # Capture and save image
            image = camera.capture_image("my_photo.jpg")
            if image is not None:
                print(f"📸 Captured image: {image.shape}")
                # Optionally display the image
                cv2.imshow("Captured Image", image)
                cv2.waitKey(3000)  # Show for 3 seconds
                cv2.destroyAllWindows()
        else:
            print("❌ Cannot connect to camera")

def streaming_example():
    """Stream video and process frames"""
    print("Streaming Example: Live Video")
    print("-" * 40)
    
    def frame_processor(frame):
        """Process each frame - add timestamp"""
        timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
        cv2.putText(frame, timestamp, (10, 30), 
                   cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 255, 0), 2)
    
    with ESP32CameraController(CAMERA_IP) as camera:
        if camera.test_connection():
            print("✅ Camera connected!")
            print("🎥 Starting stream... Press 'q' to stop")
            
            # Start streaming with frame processing
            camera.start_stream(frame_callback=frame_processor, display=True)
            
            # Keep streaming until user stops
            input("Press Enter to stop...")
        else:
            print("❌ Cannot connect to camera")

def settings_example():
    """Demonstrate camera settings adjustment"""
    print("Settings Example: Camera Configuration")
    print("-" * 40)
    
    with ESP32CameraController(CAMERA_IP) as camera:
        if camera.test_connection():
            print("✅ Camera connected!")
            
            # Get current status
            status = camera.get_status()
            if status:
                print(f"📊 Current settings: {status}")
            
            # Adjust settings
            print("🔧 Adjusting camera settings...")
            camera.set_quality(12)  # Lower number = higher quality
            camera.set_brightness(1)  # Brighter
            camera.set_contrast(1)  # More contrast
            camera.flip_vertical(True)  # Flip image
            
            # Capture image with new settings
            print("📸 Capturing with new settings...")
            camera.capture_image("adjusted_photo.jpg")
            
            # Reset settings
            camera.set_brightness(0)
            camera.set_contrast(0)
            camera.flip_vertical(False)
            
        else:
            print("❌ Cannot connect to camera")

def time_lapse_example():
    """Create a simple time-lapse"""
    print("Time-lapse Example: Capture Multiple Images")
    print("-" * 40)
    
    with ESP32CameraController(CAMERA_IP) as camera:
        if camera.test_connection():
            print("✅ Camera connected!")
            
            interval = 5  # seconds between captures
            num_images = 5
            
            print(f"📸 Capturing {num_images} images every {interval} seconds...")
            
            for i in range(num_images):
                filename = f"timelapse_{i+1:03d}.jpg"
                image = camera.capture_image(filename)
                if image is not None:
                    print(f"✅ Captured {filename}")
                else:
                    print(f"❌ Failed to capture {filename}")
                
                if i < num_images - 1:  # Don't wait after last image
                    print(f"⏳ Waiting {interval} seconds...")
                    time.sleep(interval)
            
            print("🎉 Time-lapse complete!")
        else:
            print("❌ Cannot connect to camera")

if __name__ == "__main__":
    print("ESP32 Camera Controller Examples")
    print("=" * 50)
    print(f"Using ESP32 at IP: {CAMERA_IP}")
    print("=" * 50)
    
    examples = {
        "1": ("Basic image capture", basic_example),
        "2": ("Live video streaming", streaming_example),
        "3": ("Camera settings", settings_example),
        "4": ("Time-lapse photography", time_lapse_example)
    }
    
    print("\nAvailable examples:")
    for key, (description, _) in examples.items():
        print(f"{key}. {description}")
    
    choice = input("\nEnter example number (1-4) or 'all' to run all: ").strip().lower()
    
    if choice == "all":
        for _, (_, func) in examples.items():
            func()
            print("\n" + "="*50 + "\n")
    elif choice in examples:
        examples[choice][1]()
    else:
        print("Invalid choice!")
