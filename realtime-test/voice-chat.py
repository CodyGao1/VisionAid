#!/usr/bin/env python3
"""
OpenAI Realtime Voice Chat - Python Implementation
Real-time voice conversation with OpenAI using WebSocket and microphone.
"""

import asyncio
import websockets
import pyaudio
import json
import base64
import threading
import signal
import sys
from typing import Optional
import queue
import time
import ssl
import certifi

# Configuration
OPENAI_API_KEY = "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"
API_URL = "wss://api.openai.com/v1/realtime?model=gpt-realtime"

# Audio settings
CHUNK_SIZE = 1024
FORMAT = pyaudio.paInt16
CHANNELS = 1
SAMPLE_RATE = 24000  # OpenAI uses 24kHz
BYTES_PER_SAMPLE = 2

class VoiceChat:
    def __init__(self):
        self.audio = pyaudio.PyAudio()
        self.websocket: Optional[websockets.WebSocketServerProtocol] = None
        self.is_recording = False
        self.audio_queue = queue.Queue()
        self.playback_queue = queue.Queue()
        self.running = True
        
        # Audio streams
        self.input_stream: Optional[pyaudio.Stream] = None
        self.output_stream: Optional[pyaudio.Stream] = None
        
        print("🎤 Starting Real-time Voice Chat with OpenAI...")
        print("📝 Instructions:")
        print("   - Press ENTER to start/stop recording")
        print("   - Type 'q' and press ENTER to quit")
        print("   - The AI will respond with voice automatically\n")

    def setup_audio(self):
        """Initialize audio input and output streams."""
        try:
            # Input stream for recording
            self.input_stream = self.audio.open(
                format=FORMAT,
                channels=CHANNELS,
                rate=SAMPLE_RATE,
                input=True,
                frames_per_buffer=CHUNK_SIZE,
                stream_callback=self._audio_callback
            )
            
            # Output stream for playback
            self.output_stream = self.audio.open(
                format=FORMAT,
                channels=CHANNELS,
                rate=SAMPLE_RATE,
                output=True,
                frames_per_buffer=CHUNK_SIZE
            )
            
            print("🔊 Audio system initialized")
            
        except Exception as e:
            print(f"❌ Error setting up audio: {e}")
            print("💡 Make sure your microphone and speakers are working")
            sys.exit(1)

    def _audio_callback(self, in_data, frame_count, time_info, status):
        """Callback for audio input stream."""
        if self.is_recording and self.websocket:
            # Convert audio data to base64 and queue for sending
            audio_base64 = base64.b64encode(in_data).decode('utf-8')
            self.audio_queue.put(audio_base64)
        return (None, pyaudio.paContinue)

    async def connect_websocket(self):
        """Connect to OpenAI Realtime API."""
        headers = {
            "Authorization": f"Bearer {OPENAI_API_KEY}",
            "OpenAI-Beta": "realtime=v1"
        }
        
        # Create SSL context with proper certificates
        try:
            ssl_context = ssl.create_default_context(cafile=certifi.where())
        except Exception:
            print("⚠️  Warning: Could not create SSL context with certifi, using default")
            ssl_context = ssl.create_default_context()
        
        try:
            print("🔌 Connecting to OpenAI Realtime API...")
            self.websocket = await websockets.connect(
                API_URL, 
                extra_headers=headers,
                ssl=ssl_context
            )
            print("✅ Connected to OpenAI Realtime API")
            
            # Configure session
            await self.configure_session()
            
            # Start audio processing
            self.setup_audio()
            
            # Start background tasks
            await asyncio.gather(
                self.handle_messages(),
                self.send_audio_data(),
                self.handle_playback(),
                self.handle_user_input()
            )
            
        except ssl.SSLError as ssl_error:
            print(f"⚠️  SSL error: {ssl_error}")
            print("🔄 Retrying with unverified SSL context (less secure)...")
            # Fallback: create unverified SSL context
            ssl_context = ssl.create_default_context()
            ssl_context.check_hostname = False
            ssl_context.verify_mode = ssl.CERT_NONE
            
            self.websocket = await websockets.connect(
                API_URL, 
                extra_headers=headers,
                ssl=ssl_context
            )
            print("✅ Connected to OpenAI Realtime API (with unverified SSL)")
            
            # Configure session
            await self.configure_session()
            
            # Start audio processing
            self.setup_audio()
            
            # Start background tasks
            await asyncio.gather(
                self.handle_messages(),
                self.send_audio_data(),
                self.handle_playback(),
                self.handle_user_input()
            )
            
        except Exception as e:
            print(f"❌ Connection error: {e}")
            sys.exit(1)

    async def configure_session(self):
        """Configure the OpenAI session."""
        session_config = {
            "type": "session.update",
            "session": {
                "instructions": "You are a friendly AI assistant. Keep responses concise and conversational since this is voice chat.",
                "voice": "alloy",
                "input_audio_format": "pcm16",
                "output_audio_format": "pcm16", 
                "temperature": 0.7,
                "turn_detection": {
                    "type": "server_vad",
                    "threshold": 0.5,
                    "prefix_padding_ms": 300,
                    "silence_duration_ms": 200
                }
            }
        }
        
        await self.websocket.send(json.dumps(session_config))
        print("🎯 Session configured! You can start talking now...\n")

    async def handle_messages(self):
        """Handle incoming messages from OpenAI."""
        audio_buffers = []
        
        try:
            async for message in self.websocket:
                try:
                    event = json.loads(message)
                    event_type = event.get("type")
                    
                    if event_type == "session.created":
                        print("🎉 Voice session ready!")
                        
                    elif event_type == "conversation.item.input_audio_transcription.completed":
                        print(f"👤 You said: \"{event.get('transcript', '')}\"")
                        
                    elif event_type == "response.audio_transcript.delta":
                        print(event.get("delta", ""), end="", flush=True)
                        
                    elif event_type == "response.audio_transcript.done":
                        print(f"\n🤖 AI finished speaking")
                        print("🎤 Press ENTER to record your next message...\n")
                        
                    elif event_type == "response.audio.delta":
                        # Store audio chunks for playback
                        audio_data = event.get("delta")
                        if audio_data:
                            audio_buffers.append(base64.b64decode(audio_data))
                            
                    elif event_type == "response.audio.done":
                        # Play complete audio response
                        if audio_buffers:
                            complete_audio = b''.join(audio_buffers)
                            self.playback_queue.put(complete_audio)
                            audio_buffers = []
                            
                    elif event_type == "input_audio_buffer.speech_started":
                        print("🗣️  Speech detected...")
                        
                    elif event_type == "input_audio_buffer.speech_stopped":
                        print("🔇 Speech ended, processing...")
                        
                    elif event_type == "error":
                        print(f"❌ Error: {event.get('error', {})}")
                        
                except json.JSONDecodeError:
                    print("❌ Error parsing message")
                    
        except websockets.exceptions.ConnectionClosed:
            print("🔌 WebSocket connection closed")
        except Exception as e:
            print(f"❌ Error handling messages: {e}")

    async def send_audio_data(self):
        """Send audio data to OpenAI."""
        while self.running:
            try:
                if not self.audio_queue.empty():
                    audio_base64 = self.audio_queue.get_nowait()
                    message = {
                        "type": "input_audio_buffer.append",
                        "audio": audio_base64
                    }
                    await self.websocket.send(json.dumps(message))
                else:
                    await asyncio.sleep(0.01)  # Small delay to prevent busy waiting
            except Exception as e:
                print(f"❌ Error sending audio: {e}")
                break

    async def handle_playback(self):
        """Handle audio playback."""
        while self.running:
            try:
                if not self.playback_queue.empty():
                    audio_data = self.playback_queue.get_nowait()
                    if self.output_stream:
                        self.output_stream.write(audio_data)
                else:
                    await asyncio.sleep(0.01)  # Small delay to prevent busy waiting
            except Exception as e:
                print(f"❌ Error during playback: {e}")
                break

    async def handle_user_input(self):
        """Handle user keyboard input."""
        loop = asyncio.get_event_loop()
        recording_state = False
        
        print("🎤 Press ENTER to start/stop recording, or 'q' to quit:")
        
        while self.running:
            try:
                # Read user input asynchronously
                user_input = await loop.run_in_executor(None, input)
                command = user_input.strip().lower()
                
                if command == 'q' or command == 'quit':
                    print("\n👋 Goodbye!")
                    await self.cleanup()
                    break
                else:
                    if not recording_state:
                        await self.start_recording()
                        recording_state = True
                        print("🎤 Press ENTER again to stop recording...")
                    else:
                        await self.stop_recording()
                        recording_state = False
                        print("🎤 Press ENTER to start recording again...")
                        
            except KeyboardInterrupt:
                print("\n👋 Goodbye!")
                await self.cleanup()
                break
            except Exception as e:
                print(f"❌ Error handling input: {e}")
                break

    async def start_recording(self):
        """Start recording audio."""
        if not self.is_recording:
            self.is_recording = True
            print("🔴 Recording... (press ENTER to stop)")
            
            if self.input_stream:
                self.input_stream.start_stream()

    async def stop_recording(self):
        """Stop recording audio."""
        if self.is_recording:
            self.is_recording = False
            print("⏹️  Stopped recording, sending to AI...")
            
            if self.input_stream:
                self.input_stream.stop_stream()
            
            # Commit audio buffer and request response
            if self.websocket:
                commit_message = {"type": "input_audio_buffer.commit"}
                await self.websocket.send(json.dumps(commit_message))
                
                response_message = {"type": "response.create"}
                await self.websocket.send(json.dumps(response_message))

    async def cleanup(self):
        """Clean up resources."""
        print("🧹 Cleaning up...")
        self.running = False
        
        # Stop audio streams
        if self.input_stream:
            try:
                self.input_stream.stop_stream()
                self.input_stream.close()
            except:
                pass
                
        if self.output_stream:
            try:
                self.output_stream.close()
            except:
                pass
                
        # Close audio
        if self.audio:
            try:
                self.audio.terminate()
            except:
                pass
        
        # Close websocket
        if self.websocket:
            try:
                await self.websocket.close()
            except:
                pass

def signal_handler(signum, frame):
    """Handle Ctrl+C gracefully."""
    print("\n👋 Goodbye!")
    sys.exit(0)

async def main():
    """Main function."""
    # Set up signal handler
    signal.signal(signal.SIGINT, signal_handler)
    
    # Create and run voice chat
    voice_chat = VoiceChat()
    
    try:
        await voice_chat.connect_websocket()
    except KeyboardInterrupt:
        print("\n👋 Goodbye!")
    finally:
        await voice_chat.cleanup()

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n👋 Goodbye!")
        sys.exit(0)
