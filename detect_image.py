#!/usr/bin/env python3
"""
Bounding Box Detection Script using Gemini 2.5 Flash Lite
Prompts user for image path and detection targets, then displays bounding boxes.
"""

import json
import os
import sys
from pathlib import Path
from google import genai
from google.genai.types import (
    GenerateContentConfig,
    HarmBlockThreshold,
    HarmCategory,
    Part,
    SafetySetting,
)
from PIL import Image, ImageColor, ImageDraw
from pydantic import BaseModel
from typing import List


class BoundingBox(BaseModel):
    """
    Represents a bounding box with its 2D coordinates and associated label.

    Attributes:
        box_2d (list[int]): A list of integers representing the 2D coordinates of the bounding box,
                            typically in the format [y_min, x_min, y_max, x_max].
        label (str): A string representing the label or class associated with the object within the bounding box.
    """
    box_2d: List[int]
    label: str


# Hardcoded API key and image path
GEMINI_API_KEY = "AIzaSyAEY_B2spe-XeNAIr8t2mbxH8dlx1ETa4A"
IMAGE_PATH = "/Users/devnarang/Desktop/Projects/KellerAI/mainimage.jpg"


def plot_bounding_boxes(image_path: str, bounding_boxes: List[BoundingBox]) -> None:
    """
    Plots bounding boxes on an image with labels, using PIL and normalized coordinates.

    Args:
        image_path: The path to the local image file.
        bounding_boxes: A list of BoundingBox objects. Each box's coordinates are in
                        normalized [y_min, x_min, y_max, x_max] format.
    """
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
    print("🔍 Bounding Box Detection with Gemini 2.5 Flash Lite")
    print("=" * 50)
    print(f"📁 Using image: {IMAGE_PATH}")
    
    # Check if the hardcoded image exists
    if not Path(IMAGE_PATH).exists():
        print(f"❌ Image not found: {IMAGE_PATH}")
        sys.exit(1)
    
    # Get detection target
    detection_target = input("\n🎯 What would you like to detect in the image? (e.g., 'all people', 'red cars', 'animals'): ").strip()
    if not detection_target:
        detection_target = "all objects"
    
    return IMAGE_PATH, detection_target


def detect_objects(image_path: str, detection_target: str):
    """Detect objects in the image using Gemini."""
    try:
        print(f"\n🤖 Analyzing image for: {detection_target}")
        print("⏳ Processing with Gemini 2.5 Flash Lite...")
        
        # Initialize client with API key
        client = genai.Client(api_key=GEMINI_API_KEY)
        
        # Configure the model
        config = GenerateContentConfig(
            system_instruction=f"""
            Return bounding boxes as a JSON array with labels for {detection_target}.
            Never return masks. Limit to 25 objects.
            If an object is present multiple times, give each object a unique label
            according to its distinct characteristics (colors, size, position, etc.).
            Be precise and descriptive in your labels.
            
            Format the response as JSON like this:
            [
                {{"box_2d": [y_min, x_min, y_max, x_max], "label": "description"}},
                {{"box_2d": [y_min, x_min, y_max, x_max], "label": "description"}}
            ]
            """,
            temperature=0.3,
            safety_settings=[
                SafetySetting(
                    category=HarmCategory.HARM_CATEGORY_DANGEROUS_CONTENT,
                    threshold=HarmBlockThreshold.BLOCK_ONLY_HIGH,
                ),
            ],
        )
        
        # Prepare content parts for local file
        with open(image_path, 'rb') as f:
            image_data = f.read()
        
        content_parts = [
            Part.from_bytes(data=image_data, mime_type="image/jpeg"),
            f"Find and return bounding boxes for {detection_target} in this image. Label each detection clearly."
        ]
        
        # Generate content
        response = client.models.generate_content(
            model="gemini-2.5-flash-lite",
            contents=content_parts,
            config=config,
        )
        
        if response.text:
            try:
                # Try to parse the JSON response
                response_text = response.text.strip()
                if response_text.startswith('```json'):
                    response_text = response_text.split('```json')[1].split('```')[0].strip()
                elif response_text.startswith('```'):
                    response_text = response_text.split('```')[1].split('```')[0].strip()
                
                bbox_data = json.loads(response_text)
                
                # Convert to BoundingBox objects
                bounding_boxes = [BoundingBox(box_2d=item['box_2d'], label=item['label']) for item in bbox_data]
                
                print(f"✅ Found {len(bounding_boxes)} objects")
                
                # Print detected objects
                print("\n📋 Detected objects:")
                for i, bbox in enumerate(bounding_boxes, 1):
                    print(f"   {i}. {bbox.label}")
                
                # Plot bounding boxes
                plot_bounding_boxes(image_path, bounding_boxes)
                
                return bounding_boxes
                
            except (json.JSONDecodeError, KeyError) as e:
                print(f"❌ Error parsing response: {e}")
                print(f"Raw response: {response.text}")
                return []
        else:
            print("❌ No response received")
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
