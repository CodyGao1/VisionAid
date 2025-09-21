#!/usr/bin/env python3
"""
Setup script for OpenAI Realtime Voice Chat
Installs dependencies and checks system requirements.
"""

import subprocess
import sys
import platform

def run_command(command, description):
    """Run a shell command and handle errors."""
    print(f"🔧 {description}...")
    try:
        result = subprocess.run(command, shell=True, capture_output=True, text=True)
        if result.returncode == 0:
            print(f"✅ {description} completed successfully")
            if result.stdout:
                print(f"   Output: {result.stdout.strip()}")
        else:
            print(f"❌ {description} failed")
            if result.stderr:
                print(f"   Error: {result.stderr.strip()}")
            return False
    except Exception as e:
        print(f"❌ {description} failed with exception: {e}")
        return False
    return True

def install_system_dependencies():
    """Install system-level dependencies based on OS."""
    system = platform.system().lower()
    
    if system == "darwin":  # macOS
        print("🍎 Detected macOS")
        # Check if Homebrew is installed
        if not run_command("which brew", "Checking for Homebrew"):
            print("❌ Homebrew not found. Please install Homebrew first:")
            print("   /bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"")
            return False
        
        # Install PortAudio (required for PyAudio)
        if not run_command("brew install portaudio", "Installing PortAudio via Homebrew"):
            print("❌ Failed to install PortAudio")
            return False
            
    elif system == "linux":
        print("🐧 Detected Linux")
        # Try to detect the package manager and install dependencies
        if run_command("which apt-get", "Checking for apt-get"):
            if not run_command("sudo apt-get update", "Updating package list"):
                return False
            if not run_command("sudo apt-get install -y portaudio19-dev python3-pyaudio", "Installing PortAudio and PyAudio"):
                return False
        elif run_command("which yum", "Checking for yum"):
            if not run_command("sudo yum install -y portaudio-devel", "Installing PortAudio"):
                return False
        else:
            print("⚠️  Could not detect package manager. Please install PortAudio manually:")
            print("   Ubuntu/Debian: sudo apt-get install portaudio19-dev")
            print("   CentOS/RHEL: sudo yum install portaudio-devel")
            
    elif system == "windows":
        print("🪟 Detected Windows")
        print("💡 On Windows, PyAudio should install directly from pip")
        print("   If you encounter issues, try installing Microsoft Visual C++ Build Tools")
    
    return True

def install_python_dependencies():
    """Install Python dependencies."""
    print("🐍 Installing Python dependencies...")
    
    # Upgrade pip first
    if not run_command(f"{sys.executable} -m pip install --upgrade pip", "Upgrading pip"):
        print("⚠️  Warning: Could not upgrade pip, continuing anyway...")
    
    # Install requirements
    if not run_command(f"{sys.executable} -m pip install -r requirements.txt", "Installing Python packages"):
        print("❌ Failed to install Python dependencies")
        print("💡 Try installing PyAudio manually:")
        print(f"   {sys.executable} -m pip install PyAudio")
        print("   If that fails, you may need to install system audio libraries first")
        return False
    
    return True

def verify_installation():
    """Verify that all dependencies are properly installed."""
    print("🔍 Verifying installation...")
    
    try:
        import websockets
        print("✅ websockets imported successfully")
    except ImportError:
        print("❌ Failed to import websockets")
        return False
    
    try:
        import pyaudio
        print("✅ PyAudio imported successfully")
        
        # Test audio system
        audio = pyaudio.PyAudio()
        print(f"   Audio system initialized with {audio.get_device_count()} devices")
        audio.terminate()
        
    except ImportError:
        print("❌ Failed to import PyAudio")
        return False
    except Exception as e:
        print(f"❌ PyAudio import succeeded but initialization failed: {e}")
        print("💡 This might be due to audio system issues")
        return False
    
    return True

def main():
    """Main setup function."""
    print("🚀 Setting up OpenAI Realtime Voice Chat")
    print("=" * 50)
    
    # Check Python version
    if sys.version_info < (3, 7):
        print("❌ Python 3.7 or higher is required")
        sys.exit(1)
    
    print(f"✅ Python {sys.version_info.major}.{sys.version_info.minor} detected")
    
    # Install system dependencies
    if not install_system_dependencies():
        print("❌ Failed to install system dependencies")
        sys.exit(1)
    
    # Install Python dependencies
    if not install_python_dependencies():
        print("❌ Failed to install Python dependencies")
        sys.exit(1)
    
    # Verify installation
    if not verify_installation():
        print("❌ Installation verification failed")
        sys.exit(1)
    
    print("\n🎉 Setup completed successfully!")
    print("\nTo run the voice chat:")
    print("   python voice-chat.py")
    print("\nMake sure to:")
    print("   1. Check your microphone and speaker permissions")
    print("   2. Ensure your OpenAI API key is valid")
    print("   3. Test your audio devices before starting")

if __name__ == "__main__":
    main()
