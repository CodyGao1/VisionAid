#!/usr/bin/env python3
"""
Test script for Neuralangelo 3D Reconstruction API
Tests with a single image to verify API connectivity and functionality
"""

import requests
import os
import sys
import io
from pathlib import Path
import json
import glob

# Configuration (override via env: API_BASE, IMAGE_PATH, EXPORT_FORMAT, ITERATIONS, TIMEOUT, MAX_IMAGES)
API_BASE = os.getenv("API_BASE", "http://35.202.229.212:8081")
IMAGE_PATH = os.getenv("IMAGE_PATH", "mainimage.jpg")
EXPORT_FORMAT = os.getenv("EXPORT_FORMAT", "ply")  # ply | obj | stl
ITERATIONS = int(os.getenv("ITERATIONS", "500"))
TIMEOUT = int(os.getenv("TIMEOUT", "300"))
MAX_IMAGES = int(os.getenv("MAX_IMAGES", "10"))

def test_health_check():
    """Test if the API server is responding"""
    print("🔍 Testing API health check...")
    try:
        response = requests.get(f"{API_BASE}/", timeout=10)
        if response.status_code == 200:
            data = response.json()
            print(f"✅ API is healthy!")
            print(f"   Service: {data['service']}")
            print(f"   GPU Available: {data['gpu_available']}")
            print(f"   Device: {data['device']}")
            if 'version' in data:
                print(f"   Version: {data['version']}")
            if 'colmap_available' in data:
                print(f"   COLMAP: {data['colmap_available']}")
            if 'midas_available' in data:
                print(f"   MiDaS: {data['midas_available']}")
            return True
        else:
            print(f"❌ Health check failed: HTTP {response.status_code}")
            return False
    except requests.exceptions.RequestException as e:
        print(f"❌ Connection failed: {e}")
        return False

def test_image_upload():
    """Test 3D reconstruction with a single image or a directory of images"""
    print(f"\n🖼️  Testing 3D reconstruction from: {IMAGE_PATH}")

    files_single = []
    files_multi = []
    using_dir = False

    if os.path.isdir(IMAGE_PATH):
        using_dir = True
        patterns = ["*.jpg", "*.jpeg", "*.png", "*.bmp"]
        paths: list[str] = []
        for p in patterns:
            paths.extend(sorted(glob.glob(os.path.join(IMAGE_PATH, p))))
        paths = sorted(paths)[:MAX_IMAGES]
        if len(paths) == 0:
            print(f"❌ No images found in directory: {IMAGE_PATH}")
            return False
        for idx, p in enumerate(paths):
            with open(p, 'rb') as f:
                data = f.read()
            ext = Path(p).suffix.lower() or '.jpg'
            mime = 'image/jpeg' if ext in ['.jpg', '.jpeg'] else 'image/png'
            files_multi.append(('files', (f"img_{idx:03d}{ext}", io.BytesIO(data), mime)))
        print(f"📁 Found {len(paths)} images in directory (max {MAX_IMAGES}).")
    else:
        if not os.path.exists(IMAGE_PATH):
            print(f"❌ Image not found at: {IMAGE_PATH}")
            return False
        image_size = os.path.getsize(IMAGE_PATH)
        print(f"📁 Image size: {image_size / 1024:.1f} KB")
        with open(IMAGE_PATH, 'rb') as f:
            image_data = f.read()
        files_single = [('files', ('mainimage.jpg', io.BytesIO(image_data), 'image/jpeg'))]
        files_multi = [
            ('files', ('mainimage1.jpg', io.BytesIO(image_data), 'image/jpeg')),
            ('files', ('mainimage2.jpg', io.BytesIO(image_data), 'image/jpeg'))
        ]

    data = {
        'iterations': ITERATIONS,
        'export_format': EXPORT_FORMAT
    }

    print("🚀 Sending reconstruction request...")
    print("   Parameters:")
    print(f"     - Iterations: {data['iterations']}")
    print(f"     - Format: {data['export_format']}")
    if using_dir:
        print(f"     - Images: {len(files_multi)} (from directory)")
    else:
        print("     - Images: 1 (single-view, MiDaS fallback)")

    try:
        if using_dir and len(files_multi) >= 2:
            response = requests.post(
                f"{API_BASE}/reconstruct",
                files=files_multi,
                data=data,
                timeout=max(TIMEOUT, 600)
            )
        else:
            response = requests.post(
                f"{API_BASE}/reconstruct",
                files=files_single,
                data=data,
                timeout=TIMEOUT
            )

        if response.status_code != 200 and not using_dir:
            print("   Single-view failed, trying multi-view with duplicated image...")
            response = requests.post(
                f"{API_BASE}/reconstruct",
                files=files_multi,
                data=data,
                timeout=max(TIMEOUT, 600)
            )

        if response.status_code == 200:
            print("✅ Reconstruction successful!")
            pipeline = "unknown"
            reconstruction_info = response.headers.get('X-Reconstruction-Info')
            if reconstruction_info:
                try:
                    info = json.loads(reconstruction_info)
                    pipeline = info.get('pipeline', pipeline)
                    print("📊 Reconstruction Results:")
                    print(f"     - Pipeline: {pipeline}")
                    print(f"     - Vertices: {info.get('mesh_vertices', 'N/A')}")
                    print(f"     - Faces: {info.get('mesh_faces', 'N/A')}")
                    print(f"     - Device: {info.get('processing_device', 'N/A')}")
                except json.JSONDecodeError:
                    print("📊 Reconstruction completed (info parsing failed)")

            output_path = f"reconstruction_{pipeline}.{EXPORT_FORMAT}"
            with open(output_path, 'wb') as f:
                f.write(response.content)
            file_size = os.path.getsize(output_path)
            print(f"💾 3D model saved: {output_path} ({file_size / 1024:.1f} KB)")
            return True

        else:
            print(f"❌ Reconstruction failed: HTTP {response.status_code}")
            try:
                error_data = response.json()
                print(f"   Error: {error_data.get('detail', 'Unknown error')}")
            except Exception:
                print(f"   Raw response: {response.text[:200]}...")
            return False

    except requests.exceptions.Timeout:
        print("❌ Request timed out (reconstruction took too long)")
        return False
    except requests.exceptions.RequestException as e:
        print(f"❌ Request failed: {e}")
        return False

def test_client_endpoint():
    """Test if the HTML client is accessible"""
    print(f"\n🌐 Testing web client endpoint...")
    try:
        response = requests.get(f"{API_BASE}/client", timeout=10)
        if response.status_code == 200:
            content = response.text
            if "<!DOCTYPE html>" in content and "Neuralangelo" in content:
                print("✅ Web client is accessible!")
                print(f"   URL: {API_BASE}/client")
                return True
            else:
                print("❌ Web client returned unexpected content")
                return False
        else:
            print(f"❌ Web client failed: HTTP {response.status_code}")
            return False
    except requests.exceptions.RequestException as e:
        print(f"❌ Web client test failed: {e}")
        return False

def main():
    """Run all tests"""
    print("🎯 Neuralangelo 3D Reconstruction API Test")
    print("=" * 50)
    
    # Test 1: Health check
    health_ok = test_health_check()
    
    # Test 2: Web client
    client_ok = test_client_endpoint()
    
    # Test 3: Image reconstruction (only if health check passes)
    reconstruction_ok = False
    if health_ok:
        reconstruction_ok = test_image_upload()
    else:
        print("\n⏭️  Skipping reconstruction test (API not healthy)")
    
    # Summary
    print("\n" + "=" * 50)
    print("📋 Test Summary:")
    print(f"   Health Check: {'✅' if health_ok else '❌'}")
    print(f"   Web Client: {'✅' if client_ok else '❌'}")
    print(f"   3D Reconstruction: {'✅' if reconstruction_ok else '❌'}")
    
    if health_ok and client_ok:
        print(f"\n🎉 API is working! Access the web interface at:")
        print(f"   {API_BASE}/client")
    else:
        print(f"\n🔧 Issues detected. Check:")
        print(f"   - Server is running: gcloud compute ssh testing --command 'ps aux | grep python3'")
        print(f"   - Firewall rule: gcloud compute firewall-rules list | grep 8081")
        print(f"   - Server logs: gcloud compute ssh testing --command 'tail -20 server.log'")
    
    return health_ok and reconstruction_ok

if __name__ == "__main__":
    success = main()
    sys.exit(0 if success else 1)
