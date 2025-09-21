/*
 * ESP32-CAM WebSocket Video Broadcaster
 * 
 * Battery-powered ESP32-CAM that streams video via WebSocket
 * 
 * Required Libraries (install via Arduino Library Manager):
 * - WebSocketsClient by Markus Sattler
 * - ArduinoJson by Benoit Blanchon  
 * - Base64 by Densaugeo
 * 
 * Usage:
 * 1. Upload this code to ESP32-CAM
 * 2. Power via battery (3.7V Li-Po recommended)
 * 3. Camera will connect to WiFi and stream to WebSocket server
 * 4. Remove DEBUG_MODE line for production (saves battery)
 */

// Uncomment for debugging (remove for battery operation)
#define DEBUG_MODE

#include "esp_camera.h"
#include <WiFi.h>
#include <WebSocketsClient.h>
#include <ArduinoJson.h>
#include <base64.h>


// ===========================
// Select camera model in board_config.h
// ===========================
#include "board_config.h"


// ===========================
// WiFi and WebSocket Configuration
// ===========================
const char *ssid = "Dev iPhone 13 Pro";
const char *password = "historyis";

// WebSocket server details
const char* websocket_host = "35.238.205.88";
const int websocket_port = 8081;
const char* websocket_path = "/video?role=broadcaster";

WebSocketsClient webSocket;
bool wsConnected = false;
int framesSent = 0;
unsigned long lastConnectionAttempt = 0;
bool connectionAttempted = false;

void setupLedFlash();
void webSocketEvent(WStype_t type, uint8_t * payload, size_t length);
void sendVideoFrame();
void connectWebSocket();


void setup() {
  // Optional Serial for debugging (remove for battery operation)
  #ifdef DEBUG_MODE
  Serial.begin(115200);
  Serial.setDebugOutput(true);
  Serial.println();
  #endif


  camera_config_t config;
  config.ledc_channel = LEDC_CHANNEL_0;
  config.ledc_timer = LEDC_TIMER_0;
  config.pin_d0 = Y2_GPIO_NUM;
  config.pin_d1 = Y3_GPIO_NUM;
  config.pin_d2 = Y4_GPIO_NUM;
  config.pin_d3 = Y5_GPIO_NUM;
  config.pin_d4 = Y6_GPIO_NUM;
  config.pin_d5 = Y7_GPIO_NUM;
  config.pin_d6 = Y8_GPIO_NUM;
  config.pin_d7 = Y9_GPIO_NUM;
  config.pin_xclk = XCLK_GPIO_NUM;
  config.pin_pclk = PCLK_GPIO_NUM;
  config.pin_vsync = VSYNC_GPIO_NUM;
  config.pin_href = HREF_GPIO_NUM;
  config.pin_sccb_sda = SIOD_GPIO_NUM;
  config.pin_sccb_scl = SIOC_GPIO_NUM;
  config.pin_pwdn = PWDN_GPIO_NUM;
  config.pin_reset = RESET_GPIO_NUM;
  config.xclk_freq_hz = 20000000;
  config.frame_size = FRAMESIZE_UXGA;
  config.pixel_format = PIXFORMAT_JPEG;  // for streaming
  //config.pixel_format = PIXFORMAT_RGB565; // for face detection/recognition
  config.grab_mode = CAMERA_GRAB_WHEN_EMPTY;
  config.fb_location = CAMERA_FB_IN_PSRAM;
  config.jpeg_quality = 12;
  config.fb_count = 1;


  // if PSRAM IC present, init with UXGA resolution and higher JPEG quality
  //                      for larger pre-allocated frame buffer.
  if (config.pixel_format == PIXFORMAT_JPEG) {
    if (psramFound()) {
      config.jpeg_quality = 10;
      config.fb_count = 2;
      config.grab_mode = CAMERA_GRAB_LATEST;
    } else {
      // Limit the frame size when PSRAM is not available
      config.frame_size = FRAMESIZE_SVGA;
      config.fb_location = CAMERA_FB_IN_DRAM;
    }
  } else {
    // Best option for face detection/recognition
    config.frame_size = FRAMESIZE_240X240;
#if CONFIG_IDF_TARGET_ESP32S3
    config.fb_count = 2;
#endif
  }


#if defined(CAMERA_MODEL_ESP_EYE)
  pinMode(13, INPUT_PULLUP);
  pinMode(14, INPUT_PULLUP);
#endif


  // camera init
  esp_err_t err = esp_camera_init(&config);
  if (err != ESP_OK) {
    #ifdef DEBUG_MODE
    Serial.printf("Camera init failed with error 0x%x", err);
    #endif
    return;
  }


  sensor_t *s = esp_camera_sensor_get();
  // initial sensors are flipped vertically and colors are a bit saturated
  if (s->id.PID == OV3660_PID) {
    s->set_vflip(s, 1);        // flip it back
    s->set_brightness(s, 1);   // up the brightness just a bit
    s->set_saturation(s, -2);  // lower the saturation
  }
  // drop down frame size for higher initial frame rate and smaller WebSocket packets
  if (config.pixel_format == PIXFORMAT_JPEG) {
    s->set_framesize(s, FRAMESIZE_QVGA);  // 320x240 for better WebSocket transmission
    s->set_quality(s, 15);  // Lower quality for smaller file size (0-63, lower = better quality)
  }


#if defined(CAMERA_MODEL_M5STACK_WIDE) || defined(CAMERA_MODEL_M5STACK_ESP32CAM)
  s->set_vflip(s, 1);
  s->set_hmirror(s, 1);
#endif


#if defined(CAMERA_MODEL_ESP32S3_EYE)
  s->set_vflip(s, 1);
#endif


// Setup LED FLash if LED pin is defined in camera_pins.h
#if defined(LED_GPIO_NUM)
  setupLedFlash();
#endif


  WiFi.begin(ssid, password);
  WiFi.setSleep(false);

  #ifdef DEBUG_MODE
  Serial.print("WiFi connecting");
  #endif
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    #ifdef DEBUG_MODE
    Serial.print(".");
    #endif
  }
  #ifdef DEBUG_MODE
  Serial.println("");
  Serial.println("WiFi connected");
  Serial.print("IP Address: ");
  Serial.println(WiFi.localIP());
  #endif


  // Wait a bit for camera to stabilize
  delay(2000);

  // Setup WebSocket connection
  connectWebSocket();

  #ifdef DEBUG_MODE
  Serial.println("Camera Ready! Attempting to stream to WebSocket server...");
  Serial.println("===== ESP32-CAM WebSocket Broadcaster =====");
  Serial.print("Target: ");
  Serial.print(websocket_host);
  Serial.print(":");
  Serial.println(websocket_port);
  Serial.print("Path: ");
  Serial.println(websocket_path);
  Serial.println("============================================");
  #endif
}


void loop() {
  // Handle WebSocket events
  webSocket.loop();
  
  if (wsConnected) {
    // Send video frame if connected
    sendVideoFrame();
    delay(200); // Slower frame rate for WebSocket (200ms = ~5 FPS)
  } else {
    // Check connection status every 5 seconds
    unsigned long now = millis();
    if (now - lastConnectionAttempt > 5000) {
      lastConnectionAttempt = now;
      
      #ifdef DEBUG_MODE
      if (!connectionAttempted) {
        Serial.println("[WS] ⏳ Waiting for WebSocket connection...");
        Serial.println("[WS] Check server logs and /video/status endpoint");
        connectionAttempted = true;
      } else {
        Serial.println("[WS] ⏳ Still waiting for connection...");
        Serial.printf("[WS] WiFi status: %s\n", WiFi.isConnected() ? "Connected" : "Disconnected");
        Serial.printf("[WS] Free heap: %d bytes\n", ESP.getFreeHeap());
      }
      #endif
    }
    delay(1000);
  }
}

// WebSocket event handler
void webSocketEvent(WStype_t type, uint8_t * payload, size_t length) {
  switch(type) {
    case WStype_DISCONNECTED:
      #ifdef DEBUG_MODE
      Serial.println("[WS] Disconnected from server");
      #endif
      wsConnected = false;
      break;
      
    case WStype_CONNECTED:
      #ifdef DEBUG_MODE
      Serial.printf("[WS] Successfully connected to: %s\n", payload);
      Serial.println("[WS] Ready to broadcast video!");
      #endif
      wsConnected = true;
      break;
      
    case WStype_TEXT:
      #ifdef DEBUG_MODE
      Serial.printf("[WS] Server message: %s\n", payload);
      #endif
      // Handle server confirmation messages
      // Check if this is the broadcaster confirmation
      if (strstr((char*)payload, "broadcaster_connected")) {
        #ifdef DEBUG_MODE
        Serial.println("[WS] ✅ Broadcaster role confirmed by server!");
        #endif
        wsConnected = true;  // Ensure we're marked as connected
      }
      break;
      
    case WStype_ERROR:
      #ifdef DEBUG_MODE
      Serial.printf("[WS] Connection error occurred (code: %d)\n", type);
      #endif
      wsConnected = false;
      break;

    case WStype_PING:
      #ifdef DEBUG_MODE
      Serial.println("[WS] Ping received");
      #endif
      break;

    case WStype_PONG:
      #ifdef DEBUG_MODE
      Serial.println("[WS] Pong received");
      #endif
      break;
      
    default:
      #ifdef DEBUG_MODE
      Serial.printf("[WS] Unknown event type: %d\n", type);
      #endif
      break;
  }
}

// Connect to WebSocket server
void connectWebSocket() {
  #ifdef DEBUG_MODE
  Serial.println("[WS] Attempting to connect to WebSocket server...");
  Serial.printf("[WS] Host: %s:%d\n", websocket_host, websocket_port);
  Serial.printf("[WS] Path: %s\n", websocket_path);
  #endif
  
  // Initialize WebSocket connection
  webSocket.begin(websocket_host, websocket_port, websocket_path);
  webSocket.onEvent(webSocketEvent);
  
  // Set connection parameters
  webSocket.setReconnectInterval(5000);  // Try to reconnect every 5 seconds
  webSocket.enableHeartbeat(15000, 3000, 2);  // Ping every 15s, timeout 3s, 2 tries
  
  #ifdef DEBUG_MODE
  Serial.println("[WS] WebSocket client initialized");
  #endif
}

// Capture and send video frame
void sendVideoFrame() {
  camera_fb_t * fb = esp_camera_fb_get();
  if (!fb) {
    #ifdef DEBUG_MODE
    Serial.println("[CAM] Frame capture failed!");
    #endif
    return;
  }
  
  #ifdef DEBUG_MODE
  Serial.printf("[CAM] Captured frame: %d bytes, format: %d\n", fb->len, fb->format);
  #endif
  
  // Check if frame is JPEG format
  if (fb->format != PIXFORMAT_JPEG) {
    #ifdef DEBUG_MODE
    Serial.println("[CAM] Warning: Frame is not JPEG format!");
    #endif
    esp_camera_fb_return(fb);
    return;
  }
  
  // Check frame size (limit to reasonable size for WebSocket)
  if (fb->len > 100000) { // 100KB limit
    #ifdef DEBUG_MODE
    Serial.printf("[CAM] Frame too large: %d bytes, skipping\n", fb->len);
    #endif
    esp_camera_fb_return(fb);
    return;
  }
  
  // Encode frame to base64
  String encoded = base64::encode(fb->buf, fb->len);
  
  #ifdef DEBUG_MODE
  Serial.printf("[CAM] Encoded to base64: %d chars\n", encoded.length());
  #endif
  
  // Send to WebSocket
  bool sent = webSocket.sendTXT(encoded);
  
  if (sent) {
    framesSent++;
    #ifdef DEBUG_MODE
    if (framesSent % 10 == 0) {  // Log every 10th frame to avoid spam
      Serial.printf("[WS] Frame #%d sent successfully\n", framesSent);
    }
    #endif
  } else {
    #ifdef DEBUG_MODE
    Serial.println("[WS] Failed to send frame!");
    #endif
  }
  
  esp_camera_fb_return(fb);
}

