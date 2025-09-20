import { EventEmitter } from "eventemitter3";
import { LiveClientOptions, StreamingLog } from "../App";

// WebSocket client event types
export interface WebSocketClientEventTypes {
  audio: (data: ArrayBuffer) => void;
  close: (event: CloseEvent) => void;
  content: (data: any) => void;
  error: (error: ErrorEvent) => void;
  interrupted: () => void;
  log: (log: StreamingLog) => void;
  open: () => void;
  setupcomplete: () => void;
  toolcall: (toolCall: any) => void;
  toolcallcancellation: (toolcallCancellation: any) => void;
  turncomplete: () => void;
}

export interface LiveConnectConfig {
  systemInstruction?: string;
  generationConfig?: any;
  tools?: any[];
  modality?: "text-to-text" | "voice-to-text" | "voice-to-voice";
  voiceName?: string;
}

export class WebSocketClient extends EventEmitter<WebSocketClientEventTypes> {
  private ws: WebSocket | null = null;
  private _status: "connected" | "disconnected" | "connecting" = "disconnected";
  private wsUrl: string;
  private model: string | null = null;
  private config: LiveConnectConfig | null = null;

  public get status() {
    return this._status;
  }

  constructor(options: LiveClientOptions) {
    super();
    // Connect to VM server - update this IP if your VM changes
    const host = process.env.REACT_APP_WEBSOCKET_HOST || "35.238.205.88";
    const port = process.env.REACT_APP_WEBSOCKET_PORT || "8081";
    const protocol = "ws:"; // VM server uses HTTP, not HTTPS
    this.wsUrl = `${protocol}//${host}:${port}/live`;
  }

  protected log(type: string, message: StreamingLog["message"]) {
    const log: StreamingLog = {
      date: new Date(),
      type,
      message,
    };
    this.emit("log", log);
  }

  async connect(model: string, config: LiveConnectConfig): Promise<boolean> {
    if (this._status === "connected" || this._status === "connecting") {
      return false;
    }

    // Clean up any existing connection first
    this.disconnect();

    this._status = "connecting";
    this.model = model;
    this.config = config;

    return new Promise((resolve, reject) => {
      try {
        this.ws = new WebSocket(this.wsUrl);
        
        this.ws.onopen = () => {
          this._status = "connected";
          this.log("client.open", "Connected to Live API");
          this.emit("open");
          
          // Send setup message with Live API configuration
          if (this.ws && this.model && this.config) {
            const setupMessage = {
              setup: {
                model: this.model,
                config: this.config
              }
            };
            console.log("Sending setup message:", setupMessage);
            this.ws.send(JSON.stringify(setupMessage));
          }
          resolve(true);
        };

        this.ws.onclose = (event) => {
          this._status = "disconnected";
          this.log("server.close", `disconnected ${event.reason ? `with reason: ${event.reason}` : ``}`);
          this.emit("close", event);
          this.ws = null;
        };

        this.ws.onerror = (event) => {
          this._status = "disconnected";
          this.log("server.error", "WebSocket error");
          this.emit("error", event as ErrorEvent);
          this.ws = null;
          reject(event);
        };

        this.ws.onmessage = (event) => {
          try {
            const message = JSON.parse(event.data);
            this.handleMessage(message);
          } catch (e) {
            console.error("Error parsing WebSocket message:", e);
          }
        };

      } catch (e) {
        console.error("Error connecting to WebSocket:", e);
        this._status = "disconnected";
        this.ws = null;
        resolve(false);
      }
    });
  }

  private handleMessage(message: any) {
    console.log("WebSocket received message:", message);
    
    if (message.setupComplete) {
      this.log("server.send", "setupComplete");
      this.emit("setupcomplete");
      return;
    }
    
    if (message.toolCall) {
      this.log("server.toolCall", message);
      this.emit("toolcall", message.toolCall);
      return;
    }
    
    if (message.toolCallCancellation) {
      this.log("server.toolCallCancellation", message);
      this.emit("toolcallcancellation", message.toolCallCancellation);
      return;
    }

    if (message.serverContent) {
      const { serverContent } = message;
      console.log("Processing serverContent:", serverContent);
      
      // Handle interruptions
      if ("interrupted" in serverContent) {
        this.log("server.content", "interrupted");
        this.emit("interrupted");
        return;
      }
      
      // Handle turn completion
      if ("turnComplete" in serverContent && serverContent.turnComplete) {
        this.log("server.content", "turnComplete");
        this.emit("turncomplete");
      }

      // Handle text responses
      if ("modelTurn" in serverContent) {
        const content = { modelTurn: serverContent.modelTurn };
        console.log("Emitting text content:", content);
        this.emit("content", content);
        this.log("server.content", message);
      }

      // Handle audio responses from Live API
      if ("audio" in serverContent) {
        console.log("Received audio data");
        const audioData = serverContent.audio;
        if (audioData.data) {
          try {
            // Convert base64 to ArrayBuffer for audio playback
            const binaryString = atob(audioData.data);
            const bytes = new Uint8Array(binaryString.length);
            for (let i = 0; i < binaryString.length; i++) {
              bytes[i] = binaryString.charCodeAt(i);
            }
            this.emit("audio", bytes.buffer);
            this.log("server.audio", `buffer (${bytes.length})`);
          } catch (e) {
            console.error("Error processing audio data:", e);
          }
        }
      }
    }

    if (message.error) {
      this.log("server.error", message.error.message);
    }
  }

  public disconnect() {
    if (this.ws) {
      // Remove event listeners to prevent unwanted callbacks
      this.ws.onopen = null;
      this.ws.onclose = null;
      this.ws.onerror = null;
      this.ws.onmessage = null;
      
      // Close the connection if it's open
      if (this.ws.readyState === WebSocket.OPEN || this.ws.readyState === WebSocket.CONNECTING) {
        this.ws.close(1000, "Client disconnect");
      }
      
      this.ws = null;
    }
    
    this._status = "disconnected";
    this.log("client.close", "Disconnected");
    return true;
  }

  sendRealtimeInput(chunks: Array<{ mimeType: string; data: string }>) {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
      console.warn("WebSocket not connected, state:", this.ws?.readyState);
      return;
    }

    for (const chunk of chunks) {
      const message = {
        realtime_input: {
          media: chunk
        }
      };
      this.ws.send(JSON.stringify(message));
    }

    let hasAudio = false;
    let hasVideo = false;
    for (const ch of chunks) {
      if (ch.mimeType.includes("audio")) {
        hasAudio = true;
      }
      if (ch.mimeType.includes("image")) {
        hasVideo = true;
      }
      if (hasAudio && hasVideo) {
        break;
      }
    }
    
    const message =
      hasAudio && hasVideo
        ? "audio + video"
        : hasAudio
        ? "audio"
        : hasVideo
        ? "video"
        : "unknown";
    this.log("client.realtimeInput", message);
  }

  sendToolResponse(toolResponse: any) {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
      console.warn("WebSocket not connected, state:", this.ws?.readyState);
      return;
    }

    if (toolResponse.functionResponses && toolResponse.functionResponses.length) {
      const message = {
        tool_response: toolResponse
      };
      this.ws.send(JSON.stringify(message));
      this.log("client.toolResponse", toolResponse);
    }
  }

  send(parts: any | any[], turnComplete: boolean = true) {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
      console.warn("WebSocket not connected, state:", this.ws?.readyState);
      return;
    }

    const message = {
      client_content: {
        turns: Array.isArray(parts) ? parts : [parts],
        turnComplete
      }
    };
    
    this.ws.send(JSON.stringify(message));
    this.log("client.send", {
      turns: Array.isArray(parts) ? parts : [parts],
      turnComplete,
    });
  }
}