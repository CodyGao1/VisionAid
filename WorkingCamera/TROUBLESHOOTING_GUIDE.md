# ESP32-CAM Troubleshooting Guide

## Key Fixes Applied:

### 1. **Fixed LED Pin Conflict**
- Changed from GPIO 2 to GPIO 33 (GPIO 2 can cause boot issues on some boards)
- GPIO 4 is reserved for camera flash LED on AI_THINKER boards

### 2. **Improved Power Stability**
- Added startup delay for power stabilization
- Better WiFi reconnection logic
- Automatic restart on camera failure

### 3. **Enhanced Error Handling**
- Multiple WiFi connection attempts
- Clear LED status indicators
- Fallback to AP mode if WiFi fails

## LED Status Indicators:

| LED Pattern | Meaning |
|-------------|---------|
| Solid ON during startup | Initializing |
| 3 medium blinks | Camera initialized successfully |
| Fast blinking (250ms) | Connecting to WiFi |
| Rapid blinking (50ms × 30) | Camera initialization failed |
| 3 slow blinks then solid | WiFi connected, server started |
| 5 fast blinks then OFF | AP mode active |
| Solid ON | Ready and connected |
| OFF | No WiFi or AP mode |

## Troubleshooting Steps:

### **Problem 1: Still depends on USB cable**

#### **Test Method:**
1. Upload code with `ENABLE_SERIAL_DEBUG false`
2. Power off ESP32 completely
3. Remove USB cable
4. Power via 5V external power or battery
5. Watch LED behavior

#### **If LED doesn't turn on at all:**
- **Power Issue**: Check if you're supplying 5V (not 3.3V) with enough current (>500mA)
- **Wiring**: Ensure GND is connected and power connections are solid
- **Board Issue**: Try a different ESP32-CAM board

#### **If LED blinks rapidly 30 times then stops:**
- **Camera Hardware**: Camera module might be loose or faulty
- **PSRAM Issue**: Try different board selection in Arduino IDE
- **Power Supply**: Insufficient power can cause camera init to fail

#### **If LED never gets past startup (solid ON):**
- **Code Issue**: There might be a hidden dependency causing the hang
- **Try This Fix**: Set `ENABLE_SERIAL_DEBUG true`, upload, check Serial Monitor for exact error, then set back to `false`

### **Problem 2: Other devices can't connect**

#### **Test Network Connectivity:**

**Step 1: Find the ESP32's IP Address**
- Method A: Check your router's admin panel (usually 192.168.1.1 or 192.168.0.1)
- Method B: Use a network scanner app (e.g., "Fing" on mobile)
- Method C: Temporarily set `ENABLE_SERIAL_DEBUG true` to see IP in Serial Monitor

**Step 2: Test Local Access**
```bash
# From a computer on the same network:
ping [ESP32_IP_ADDRESS]
curl http://[ESP32_IP_ADDRESS]/status
```

**Step 3: Check Firewall/Network Settings**
- Windows: Disable Windows Firewall temporarily
- Router: Check if client isolation/AP isolation is enabled (disable it)
- VPN: Disconnect from VPN services

**Step 4: Test Different URLs**
```
http://[ESP32_IP]/           # Main page
http://[ESP32_IP]/stream     # Video stream
http://[ESP32_IP]/capture    # Single photo
http://[ESP32_IP]/status     # Camera status
```

#### **If ESP32 Creates AP Mode Instead:**
1. Connect phone to "ESP32-CAM-Setup" network (password: "12345678")
2. Go to http://192.168.4.1
3. This means your WiFi credentials are wrong or network is unreachable

#### **Network-Specific Issues:**

**5GHz vs 2.4GHz WiFi:**
- ESP32 only supports 2.4GHz
- If your router broadcasts both, ESP32 won't see 5GHz networks
- Try connecting to 2.4GHz specifically or create a separate 2.4GHz network

**Corporate/Guest Networks:**
- May block device-to-device communication
- May require MAC address registration
- Try mobile hotspot instead

**Distance/Signal Issues:**
- ESP32-CAM has weaker WiFi antenna than phones
- Move closer to router during testing
- Check signal strength in Serial Monitor

### **Problem 3: Stream loads but no video**

#### **Browser Compatibility:**
- **Chrome/Edge**: Full support
- **Safari**: May have issues with MJPEG streams
- **Firefox**: Usually works but may be slower

#### **Stream URL Issues:**
- Use: `http://[IP]/stream` for live video
- Use: `http://[IP]/capture` for single photo
- Don't use: `http://[IP]:81/stream` (port 81 not used in this version)

#### **Performance Issues:**
- Start with single photo capture first: `http://[IP]/capture`
- If photos work, try stream: `http://[IP]/stream`
- Lower quality in camera settings if stream is choppy

### **Advanced Debugging:**

#### **Enable Debug Mode:**
1. Change `#define ENABLE_SERIAL_DEBUG true`
2. Upload code
3. Open Serial Monitor (115200 baud)
4. Power cycle ESP32
5. Look for error messages

#### **Common Error Messages:**
- `Camera init failed 0x20001`: Camera hardware issue
- `WiFi connection timeout`: Wrong credentials or network issue
- `E (xxxxx) camera: Camera probe failed`: Camera not connected properly
- `Brownout detector`: Power supply insufficient

#### **Hardware Checklist:**
- **Camera ribbon cable**: Properly seated, not reversed
- **Power supply**: 5V, >500mA current capability
- **SD card**: Remove if present (can cause conflicts)
- **Jumper wires**: GPIO 0 should NOT be connected to GND during normal operation

#### **Reset to Factory Defaults:**
If all else fails:
1. Connect GPIO 0 to GND
2. Press reset button
3. Remove GPIO 0 connection
4. Upload a simple blink sketch first
5. Then upload camera code

## Quick Test Sequence:

1. **Upload code** with debug enabled
2. **Check Serial Monitor** for IP address and errors
3. **Set debug to false** and re-upload
4. **Remove USB** and power externally
5. **Watch LED pattern** to confirm status
6. **Scan network** for ESP32's IP
7. **Test from phone** browser: `http://[IP]/capture`
8. **If capture works**, try stream: `http://[IP]/stream`

## Still Having Issues?

If problems persist:
1. Try a different ESP32-CAM board (hardware defect)
2. Use a different WiFi network (network compatibility)
3. Test with a different power supply (power issues)
4. Check camera ribbon cable connection (camera hardware)

## Success Indicators:

✅ **LED stays solid after startup** = Code running, WiFi connected
✅ **Can ping ESP32 IP** = Network connectivity good  
✅ **http://[IP]/status returns JSON** = Camera server working
✅ **http://[IP]/capture shows image** = Camera hardware good
✅ **http://[IP]/stream shows video** = Full functionality
