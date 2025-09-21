#!/usr/bin/env python3
"""
Bounding Box Detection Script - Client for KellerAI VM Backend
Sends image to VM server for detection using Gemini API, then displays bounding boxes.
"""

import json
import base64
import requests
from pathlib import Path
from PIL import Image, ImageColor, ImageDraw
from pydantic import BaseModel
from typing import List
import sys


class BoundingBox(BaseModel):
    box_2d: List[int]
    label: str


# Configuration for VM server
VM_SERVER_URL = "http://35.238.205.88:8081"  # KellerAI VM server
DETECT_ENDPOINT = f"{VM_SERVER_URL}/detect"
IMAGE_PATH = "/Users/devnarang/Desktop/Projects/KellerAI/mainimage.jpg"


def plot_bounding_boxes(image_path: str, bounding_boxes: List[BoundingBox]) -> None:
    try:
        # Open local image file
        im = Image.open(image_path)
        
        width, height = im.size
        draw = ImageDraw.Draw(im)
        
        colors = list(ImageColor.colormap.keys())
        
        for i, bbox in enumerate(bounding_boxes):
            # Scale normalized coordinates to image dimensions
            abs_y_min = int(bbox.box_2d[0] / 1000 * height)
            abs_x_min = int(bbox.box_2d[1] / 1000 * width)
            abs_y_max = int(bbox.box_2d[2] / 1000 * height)
            abs_x_max = int(bbox.box_2d[3] / 1000 * width)
            
            color = colors[i % len(colors)]
            
            # Draw the rectangle using the correct (x, y) pairs
            draw.rectangle(
                ((abs_x_min, abs_y_min), (abs_x_max, abs_y_max)),
                outline=color,
                width=4,
            )
            if bbox.label:
                # Position the text at the top-left corner of the box
                draw.text((abs_x_min + 8, abs_y_min + 6), bbox.label, fill=color)
        
        im.show()
        print(f"✅ Displayed image with {len(bounding_boxes)} bounding boxes")
        
    except Exception as e:
        print(f"❌ Error displaying image: {e}")


def get_user_input():
    """Get detection target from user."""
    print("🔍 KellerAI Object Detection - VM Backend Client")
    print("=" * 50)
    print(f"🖥️  VM Server: {VM_SERVER_URL}")
    print(f"📁 Using image: {IMAGE_PATH}")
    
    # Check if the hardcoded image exists
    if not Path(IMAGE_PATH).exists():
        print(f"❌ Image not found: {IMAGE_PATH}")
        sys.exit(1)
    
    # Test server connectivity
    try:
        print(f"\n🔗 Testing connection to VM server...")
        response = requests.get(f"{VM_SERVER_URL}/", timeout=5)
        if response.status_code == 200:
            print("✅ VM server is online and ready")
        else:
            print(f"⚠️  VM server responded with status {response.status_code}")
    except requests.exceptions.ConnectionError:
        print(f"❌ Cannot connect to VM server at {VM_SERVER_URL}")
        print("Make sure the server is running and the URL is correct.")
        sys.exit(1)
    except Exception as e:
        print(f"⚠️  Error testing server connection: {e}")
    
    # Get detection target
    detection_target = input("\n🎯 What would you like to detect in the image? (e.g., 'all people', 'red cars', 'animals'): ").strip()
    if not detection_target:
        detection_target = "all objects"
    
    return IMAGE_PATH, detection_target


def detect_objects(image_path: str, detection_target: str):
    """Send image to VM server for object detection."""
    try:
        print(f"\n🤖 Analyzing image for: {detection_target}")
        print("⏳ Sending to KellerAI VM server...")
        
        # Encode image to base64
        with open(image_path, 'rb') as f:
            image_data = f.read()
            image_base64 = base64.b64encode(image_data).decode('utf-8')
        
        # Prepare request payload
        payload = {
            "image_base64": image_base64,
            "detection_target": detection_target
        }
        
        # Send request to VM server
        response = requests.post(
            DETECT_ENDPOINT,
            json=payload,
            headers={"Content-Type": "application/json"},
            timeout=60  # 60 second timeout for processing
        )
        
        if response.status_code == 200:
            result = response.json()
            
            if result["success"]:
                # Convert to BoundingBox objects
                bounding_boxes = [BoundingBox(box_2d=item['box_2d'], label=item['label']) for item in result["detections"]]
                
                print(f"✅ Found {len(bounding_boxes)} objects")
                
                # Print detected objects
                if bounding_boxes:
                    print("\n📋 Detected objects:")
                    for i, bbox in enumerate(bounding_boxes, 1):
                        print(f"   {i}. {bbox.label}")
                    
                    # Plot bounding boxes
                    plot_bounding_boxes(image_path, bounding_boxes)
                else:
                    print("📋 No objects detected matching your criteria")
                
                return bounding_boxes
            else:
                print(f"❌ Detection failed: {result.get('error', 'Unknown error')}")
                return []
        else:
            print(f"❌ Server error: {response.status_code}")
            if response.text:
                print(f"Error details: {response.text}")
            return []
            
    except requests.exceptions.Timeout:
        print("❌ Request timed out. VM server may be overloaded or image too large.")
        return []
    except requests.exceptions.ConnectionError:
        print(f"❌ Could not connect to VM server at {VM_SERVER_URL}")
        print("Make sure the server is running and accessible.")
        return []
    except Exception as e:
        print(f"❌ Error during detection: {e}")
        return []


def main():
    """Main function."""
    try:
        # Get user input
        image_path, detection_target = get_user_input()
        
        # Detect objects
        bounding_boxes = detect_objects(image_path, detection_target)
        
        if bounding_boxes:
            # Ask if user wants to save results
            save_results = input("\n💾 Save detection results to JSON? (y/N): ").strip().lower()
            if save_results in ['y', 'yes']:
                results = {
                    'image_path': image_path,
                    'detection_target': detection_target,
                    'detections': [bbox.model_dump() for bbox in bounding_boxes]
                }
                
                output_file = f"detection_results_{Path(image_path).stem}.json"
                with open(output_file, 'w') as f:
                    json.dump(results, f, indent=2)
                print(f"✅ Results saved to {output_file}")
        
        # Ask if user wants to detect another image
        another = input("\n🔄 Detect objects in another image? (y/N): ").strip().lower()
        if another in ['y', 'yes']:
            main()
        
    except KeyboardInterrupt:
        print("\n\n👋 Goodbye!")
    except Exception as e:
        print(f"❌ Unexpected error: {e}")


if __name__ == "__main__":
    main()
