import WebSocket from "ws";
import { spawn } from "child_process";
import fs from "fs";
import { Readable } from "stream";
import readline from "readline";
import Speaker from "speaker";

// Hard-coded OpenAI API key
const OPENAI_API_KEY = "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";

const url = "wss://api.openai.com/v1/realtime?model=gpt-realtime";

console.log("🎤 Starting Real-time Voice Chat with OpenAI...");
console.log("📝 Instructions:");
console.log("   - Press SPACE to start talking");
console.log("   - Release SPACE to stop talking and send audio");
console.log("   - Press 'q' + ENTER to quit");
console.log("   - The AI will respond with voice automatically\n");

let isRecording = false;
let audioBuffer = [];
let ws = null;
let recordProcess = null;

// Create WebSocket connection
function connectToRealtime() {
    ws = new WebSocket(url, {
        headers: {
            Authorization: `Bearer ${OPENAI_API_KEY}`,
            "OpenAI-Beta": "realtime=v1"
        },
    });

    ws.on("open", function open() {
        console.log("✅ Connected to OpenAI Realtime API");
        
        // Configure the session for voice interaction
        ws.send(JSON.stringify({
            type: "session.update",
            session: {
                instructions: "You are a friendly AI assistant. Keep responses concise and conversational since this is voice chat.",
                voice: "alloy",
                input_audio_format: "pcm16",
                output_audio_format: "pcm16",
                temperature: 0.7,
                turn_detection: {
                    type: "server_vad", // Server-side voice activity detection
                    threshold: 0.5,
                    prefix_padding_ms: 300,
                    silence_duration_ms: 200
                }
            }
        }));

        console.log("🎯 Session configured! You can start talking now...\n");
    });

    ws.on("message", function incoming(message) {
        try {
            const event = JSON.parse(message.toString());
            
            switch (event.type) {
                case "session.created":
                    console.log("🎉 Voice session ready!");
                    break;
                    
                case "conversation.item.input_audio_transcription.completed":
                    console.log(`👤 You said: "${event.transcript}"`);
                    break;
                    
                case "response.audio_transcript.delta":
                    process.stdout.write(event.delta);
                    break;
                    
                case "response.audio_transcript.done":
                    console.log(`\n🤖 AI finished speaking`);
                    console.log("🎤 Ready for your next message (press SPACE)...\n");
                    break;
                    
                case "response.audio.delta":
                    // Store audio chunk for later playback
                    playAudioChunk(event.delta);
                    break;
                    
                case "response.audio.done":
                    // Play complete audio response
                    playCompleteAudio();
                    break;
                    
                case "input_audio_buffer.speech_started":
                    console.log("🗣️  Speech detected...");
                    break;
                    
                case "input_audio_buffer.speech_stopped":
                    console.log("🔇 Speech ended, processing...");
                    break;
                    
                case "error":
                    console.error("❌ Error:", event.error);
                    break;
            }
        } catch (error) {
            console.error("❌ Error parsing message:", error);
        }
    });

    ws.on("error", function error(err) {
        console.error("❌ WebSocket error:", err);
    });

    ws.on("close", function close() {
        console.log("👋 Connection closed");
        cleanup();
        process.exit(0);
    });
}

// Start recording audio from microphone
function startRecording() {
    if (isRecording) return;
    
    isRecording = true;
    audioBuffer = [];
    
    console.log("🔴 Recording... (release SPACE to send)");
    
    // Use sox to record audio in the right format for OpenAI
    recordProcess = spawn('sox', [
        '-d', // Default audio device (microphone)
        '-t', 'raw', // Raw format
        '-b', '16', // 16-bit
        '-e', 'signed-integer',
        '-r', '24000', // 24kHz sample rate
        '-c', '1', // Mono
        '-'  // Output to stdout
    ]);
    
    recordProcess.stdout.on('data', (chunk) => {
        if (isRecording && ws && ws.readyState === WebSocket.OPEN) {
            // Convert to base64 and send to OpenAI
            const base64Audio = chunk.toString('base64');
            ws.send(JSON.stringify({
                type: "input_audio_buffer.append",
                audio: base64Audio
            }));
        }
    });
    
    recordProcess.on('error', (error) => {
        if (error.code !== 'EPIPE') {
            console.error("❌ Recording error:", error);
            console.log("💡 Make sure you have 'sox' installed: brew install sox");
        }
        recordProcess = null;
        isRecording = false;
    });
    
    recordProcess.on('exit', () => {
        recordProcess = null;
        isRecording = false;
    });
}

// Stop recording audio
function stopRecording() {
    if (!isRecording) return;
    
    isRecording = false;
    console.log("⏹️  Stopped recording, sending to AI...");
    
    if (recordProcess) {
        recordProcess.kill();
        recordProcess = null;
    }
    
    // Commit the audio buffer
    if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({
            type: "input_audio_buffer.commit"
        }));
        
        // Create response
        ws.send(JSON.stringify({
            type: "response.create"
        }));
    }
}

let speaker = null;
let audioBuffers = [];

// Initialize speaker for audio playback
function initSpeaker() {
    if (!speaker) {
        speaker = new Speaker({
            channels: 1,          // Mono
            bitDepth: 16,         // 16-bit
            sampleRate: 24000,    // 24kHz (OpenAI's format)
        });
        
        speaker.on('error', (error) => {
            console.error("❌ Speaker error:", error);
            speaker = null;
        });
        
        speaker.on('close', () => {
            speaker = null;
        });
    }
    return speaker;
}

// Play audio chunk directly
function playAudioChunk(base64Audio) {
    try {
        const audioBuffer = Buffer.from(base64Audio, 'base64');
        audioBuffers.push(audioBuffer);
    } catch (error) {
        console.error("❌ Error processing audio chunk:", error);
    }
}

// Play complete audio when response is done
function playCompleteAudio() {
    if (audioBuffers.length === 0) return;
    
    try {
        // Combine all audio buffers
        const totalLength = audioBuffers.reduce((sum, buf) => sum + buf.length, 0);
        const combinedBuffer = Buffer.concat(audioBuffers, totalLength);
        
        // Initialize speaker and play audio
        const audioSpeaker = initSpeaker();
        if (audioSpeaker) {
            audioSpeaker.write(combinedBuffer);
        }
        
        // Clear buffers for next response
        audioBuffers = [];
        
    } catch (error) {
        console.error("❌ Error playing complete audio:", error);
        audioBuffers = [];
    }
}

// Handle keyboard input for push-to-talk
function setupKeyboardInput() {
    process.stdin.setRawMode(true);
    process.stdin.resume();
    process.stdin.setEncoding('utf8');
    
    process.stdin.on('data', (key) => {
        // Space bar to toggle recording
        if (key === ' ') {
            if (!isRecording) {
                startRecording();
            }
        } else if (key === 'q' || key === '\u0003') { // 'q' or Ctrl+C to quit
            console.log("\n👋 Goodbye!");
            cleanup();
            process.exit(0);
        }
    });
    
    process.stdin.on('keyup', (key) => {
        // Stop recording when space is released
        if (key === ' ' && isRecording) {
            stopRecording();
        }
    });
}

// Alternative: Simple key press detection (works better in most terminals)
function setupSimpleInput() {
    const rl = readline.createInterface({
        input: process.stdin,
        output: process.stdout
    });
    
    console.log("🎤 Press ENTER to start/stop recording, or 'q' to quit:");
    
    let recordingState = false;
    
    rl.on('line', (input) => {
        const command = input.trim().toLowerCase();
        
        if (command === 'q' || command === 'quit') {
            console.log("\n👋 Goodbye!");
            cleanup();
            process.exit(0);
        } else {
            if (!recordingState) {
                startRecording();
                recordingState = true;
                console.log("🎤 Press ENTER again to stop recording...");
            } else {
                stopRecording();
                recordingState = false;
                console.log("🎤 Press ENTER to start recording again...");
            }
        }
    });
}

// Cleanup function
function cleanup() {
    if (recordProcess) {
        recordProcess.kill();
        recordProcess = null;
    }
    if (speaker) {
        try {
            speaker.end();
        } catch (e) {}
        speaker = null;
    }
    if (ws) {
        ws.close();
    }
}

// Handle process termination
process.on('SIGINT', cleanup);
process.on('SIGTERM', cleanup);

// Start the voice chat
connectToRealtime();
setupSimpleInput(); // Using simple input method for better compatibility
