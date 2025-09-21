#!/usr/bin/env python3
"""
ESP32-CAM Network Scanner
Helps find your ESP32 camera on the network and test connectivity
"""

import socket
import requests
import ipaddress
import threading
import time
from concurrent.futures import ThreadPoolExecutor
import subprocess
import platform

def get_local_network():
    """Get the local network range"""
    try:
        # Get default gateway
        if platform.system() == "Windows":
            result = subprocess.run(["ipconfig"], capture_output=True, text=True)
            lines = result.stdout.split('\n')
            for i, line in enumerate(lines):
                if "Default Gateway" in line and ":" in line:
                    gateway = line.split(":")[-1].strip()
                    if gateway and gateway != "":
                        # Assume /24 network
                        network_base = ".".join(gateway.split(".")[:-1])
                        return f"{network_base}.0/24"
        else:
            result = subprocess.run(["ip", "route", "show", "default"], capture_output=True, text=True)
            if result.stdout:
                gateway = result.stdout.split()[2]
                network_base = ".".join(gateway.split(".")[:-1])
                return f"{network_base}.0/24"
    except:
        pass
    
    # Fallback common networks
    return "192.168.1.0/24"

def ping_host(ip):
    """Ping a host to see if it's alive"""
    try:
        if platform.system() == "Windows":
            result = subprocess.run(["ping", "-n", "1", "-w", "1000", str(ip)], 
                                  capture_output=True, text=True)
            return result.returncode == 0
        else:
            result = subprocess.run(["ping", "-c", "1", "-W", "1", str(ip)], 
                                  capture_output=True, text=True)
            return result.returncode == 0
    except:
        return False

def check_camera_service(ip):
    """Check if IP has a camera service running"""
    try:
        # Test common camera endpoints
        endpoints = ["/", "/status", "/capture", "/stream"]
        for endpoint in endpoints:
            try:
                response = requests.get(f"http://{ip}{endpoint}", timeout=2)
                if response.status_code == 200:
                    return True, endpoint
            except:
                continue
        return False, None
    except:
        return False, None

def scan_network_range(network_range):
    """Scan network range for live hosts"""
    print(f"Scanning network: {network_range}")
    print("This may take a few minutes...")
    
    network = ipaddress.IPv4Network(network_range, strict=False)
    live_hosts = []
    camera_devices = []
    
    def check_host(ip):
        ip_str = str(ip)
        if ping_host(ip_str):
            live_hosts.append(ip_str)
            print(f"  Found host: {ip_str}")
            
            # Check if it's a camera
            is_camera, endpoint = check_camera_service(ip_str)
            if is_camera:
                camera_devices.append((ip_str, endpoint))
                print(f"  🎥 CAMERA FOUND: {ip_str} (responds to {endpoint})")
    
    # Use ThreadPoolExecutor for faster scanning
    with ThreadPoolExecutor(max_workers=50) as executor:
        executor.map(check_host, network.hosts())
    
    return live_hosts, camera_devices

def test_esp32_endpoints(ip):
    """Test ESP32-specific endpoints"""
    print(f"\n🔍 Testing ESP32 camera endpoints on {ip}:")
    
    endpoints = {
        "/": "Main page",
        "/status": "Camera status",
        "/capture": "Capture photo", 
        "/stream": "Video stream",
        "/control": "Camera controls"
    }
    
    working_endpoints = []
    
    for endpoint, description in endpoints.items():
        try:
            response = requests.get(f"http://{ip}{endpoint}", timeout=5)
            status = "✅ Working" if response.status_code == 200 else f"❌ Error {response.status_code}"
            print(f"  {endpoint:<12} ({description:<15}): {status}")
            if response.status_code == 200:
                working_endpoints.append(endpoint)
        except requests.exceptions.Timeout:
            print(f"  {endpoint:<12} ({description:<15}): ⏱️ Timeout")
        except requests.exceptions.ConnectionError:
            print(f"  {endpoint:<12} ({description:<15}): 🚫 Connection refused")
        except Exception as e:
            print(f"  {endpoint:<12} ({description:<15}): ❌ {str(e)}")
    
    return working_endpoints

def get_camera_info(ip):
    """Get detailed camera information"""
    try:
        response = requests.get(f"http://{ip}/status", timeout=5)
        if response.status_code == 200:
            info = response.json()
            print(f"\n📊 Camera Information for {ip}:")
            print(f"  Frame Size: {info.get('framesize', 'Unknown')}")
            print(f"  Quality: {info.get('quality', 'Unknown')}")
            print(f"  Brightness: {info.get('brightness', 'Unknown')}")
            print(f"  WiFi Signal: Available via browser")
            return info
    except:
        pass
    return None

def main():
    print("🔍 ESP32-CAM Network Scanner")
    print("=" * 40)
    
    # Option 1: Scan entire network
    print("\nOptions:")
    print("1. Scan entire local network (slower but thorough)")
    print("2. Test specific IP address")
    print("3. Scan common ESP32 IP ranges")
    
    choice = input("\nEnter choice (1-3): ").strip()
    
    if choice == "2":
        ip = input("Enter IP address to test: ").strip()
        if ip:
            print(f"\n🎯 Testing specific IP: {ip}")
            
            if ping_host(ip):
                print(f"✅ {ip} is reachable")
                working_endpoints = test_esp32_endpoints(ip)
                get_camera_info(ip)
                
                if working_endpoints:
                    print(f"\n🎉 Success! Camera found at: http://{ip}")
                    print(f"📱 Open this in your phone browser: http://{ip}")
                    if "/stream" in working_endpoints:
                        print(f"🎥 Direct stream link: http://{ip}/stream")
                else:
                    print(f"\n⚠️ {ip} is reachable but doesn't appear to be an ESP32 camera")
            else:
                print(f"❌ {ip} is not reachable")
    
    elif choice == "3":
        # Scan common ranges
        common_ranges = [
            "192.168.1.0/24",
            "192.168.0.0/24", 
            "192.168.4.0/24",  # ESP32 AP mode
            "10.0.0.0/24"
        ]
        
        all_cameras = []
        for network_range in common_ranges:
            print(f"\n🔍 Scanning {network_range}...")
            live_hosts, cameras = scan_network_range(network_range)
            all_cameras.extend(cameras)
        
        if all_cameras:
            print(f"\n🎉 Found {len(all_cameras)} camera(s):")
            for ip, endpoint in all_cameras:
                print(f"  📱 http://{ip} (responds to {endpoint})")
                get_camera_info(ip)
        else:
            print(f"\n😞 No ESP32 cameras found in common network ranges")
    
    else:
        # Scan entire network
        network_range = get_local_network()
        print(f"\n🔍 Auto-detected network: {network_range}")
        
        live_hosts, cameras = scan_network_range(network_range)
        
        print(f"\n📊 Scan Results:")
        print(f"  Total hosts found: {len(live_hosts)}")
        print(f"  Camera devices: {len(cameras)}")
        
        if cameras:
            print(f"\n🎉 ESP32 Cameras Found:")
            for ip, endpoint in cameras:
                print(f"  📱 http://{ip}")
                working_endpoints = test_esp32_endpoints(ip)
                get_camera_info(ip)
                
                print(f"\n  💡 Quick Test URLs:")
                print(f"     Main page: http://{ip}")
                if "/capture" in working_endpoints:
                    print(f"     Take photo: http://{ip}/capture")
                if "/stream" in working_endpoints:
                    print(f"     Live stream: http://{ip}/stream")
        else:
            print(f"\n😞 No ESP32 cameras found on your network")
            print(f"\n🔧 Troubleshooting suggestions:")
            print(f"   1. Make sure ESP32 is powered on")
            print(f"   2. Check WiFi credentials in code")
            print(f"   3. Look for ESP32-CAM-Setup WiFi network (AP mode)")
            print(f"   4. Try connecting ESP32 via USB and check Serial Monitor")

    print(f"\n✨ Scan complete!")

if __name__ == "__main__":
    main()
