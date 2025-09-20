import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { GenAILiveClient, AudioStreamer, audioContext, VolMeterWorket, LiveConnectConfig } from "../lib";
import { LiveClientOptions } from "../App";
import { DEFAULT_SYSTEM_INSTRUCTIONS } from "../config/systemInstructions";

// =======================
// Media Stream Types
// =======================

export type UseMediaStreamResult = {
  type: "webcam" | "screen";
  start: () => Promise<MediaStream>;
  stop: () => void;
  isStreaming: boolean;
  stream: MediaStream | null;
};

// =======================
// Live API Hook
// =======================

export type UseLiveAPIResults = {
  client: GenAILiveClient;
  setConfig: (config: LiveConnectConfig) => void;
  config: LiveConnectConfig;
  model: string;
  setModel: (model: string) => void;
  connected: boolean;
  connect: () => Promise<void>;
  disconnect: () => Promise<void>;
  volume: number;
};

export function useLiveAPI(options: LiveClientOptions): UseLiveAPIResults {
  const client = useMemo(() => new GenAILiveClient(options), [options]);
  const audioStreamerRef = useRef<AudioStreamer | null>(null);

  // Use native audio Live API model
  const [model, setModel] = useState<string>("gemini-2.5-flash-preview-native-audio-dialog");
  const [config, setConfig] = useState<LiveConnectConfig>({
    systemInstruction: DEFAULT_SYSTEM_INSTRUCTIONS,
    modality: "voice-to-voice",  // Default to voice-to-voice
    voiceName: "Puck"           // Default voice
  });
  const [connected, setConnected] = useState(false);
  const [volume, setVolume] = useState(0);

  // register audio for streaming server -> speakers
  useEffect(() => {
    if (!audioStreamerRef.current) {
      audioContext({ id: "audio-out" }).then((audioCtx: AudioContext) => {
        audioStreamerRef.current = new AudioStreamer(audioCtx);
        audioStreamerRef.current
          .addWorklet<any>("vumeter-out", VolMeterWorket, (ev: any) => {
            setVolume(ev.data.volume);
          })
          .then(() => {
            console.log("Audio worklet added successfully");
          })
          .catch((error) => {
            console.error("Error adding audio worklet:", error);
          });
      });
    }
  }, [audioStreamerRef]);

  useEffect(() => {
    const onOpen = () => {
      console.log("Live API connection opened");
      setConnected(true);
    };

    const onClose = () => {
      console.log("Live API connection closed");
      setConnected(false);
    };

    const onError = (error: ErrorEvent) => {
      console.error("Live API error", error);
    };

    const stopAudioStreamer = () => {
      console.log("Stopping audio streamer due to interruption");
      audioStreamerRef.current?.stop();
    };

    const onAudio = (data: ArrayBuffer) => {
      console.log("Received audio data:", data.byteLength, "bytes");
      if (audioStreamerRef.current) {
        audioStreamerRef.current.addPCM16(new Uint8Array(data));
      }
    };

    const onSetupComplete = () => {
      console.log("Live API setup complete");
    };

    client
      .on("error", onError)
      .on("open", onOpen)
      .on("close", onClose)
      .on("interrupted", stopAudioStreamer)
      .on("audio", onAudio)
      .on("setupcomplete", onSetupComplete);

    return () => {
      client
        .off("error", onError)
        .off("open", onOpen)
        .off("close", onClose)
        .off("interrupted", stopAudioStreamer)
        .off("audio", onAudio)
        .off("setupcomplete", onSetupComplete)
        .disconnect();
    };
  }, [client]);

  const connect = useCallback(async () => {
    if (!config) {
      throw new Error("config has not been set");
    }
    console.log("Connecting to Live API with config:", config);
    client.disconnect();
    const success = await client.connect(model, config);
    if (!success) {
      throw new Error("Failed to connect to Live API");
    }
  }, [client, config, model]);

  const disconnect = useCallback(async () => {
    console.log("Disconnecting from Live API");
    client.disconnect();
    if (audioStreamerRef.current) {
      audioStreamerRef.current.stop();
    }
    setConnected(false);
  }, [setConnected, client]);

  return {
    client,
    config,
    setConfig,
    model,
    setModel,
    connected,
    connect,
    disconnect,
    volume,
  };
}

// =======================
// Webcam Hook
// =======================

export function useWebcam(): UseMediaStreamResult {
  const [stream, setStream] = useState<MediaStream | null>(null);
  const [isStreaming, setIsStreaming] = useState(false);

  useEffect(() => {
    const handleStreamEnded = () => {
      setIsStreaming(false);
      setStream(null);
    };
    if (stream) {
      stream
        .getTracks()
        .forEach((track) => track.addEventListener("ended", handleStreamEnded));
      return () => {
        stream
          .getTracks()
          .forEach((track) =>
            track.removeEventListener("ended", handleStreamEnded),
          );
      };
    }
  }, [stream]);

  const start = async () => {
    const mediaStream = await navigator.mediaDevices.getUserMedia({
      video: true,
    });
    setStream(mediaStream);
    setIsStreaming(true);
    return mediaStream;
  };

  const stop = () => {
    if (stream) {
      stream.getTracks().forEach((track) => track.stop());
      setStream(null);
      setIsStreaming(false);
    }
  };

  const result: UseMediaStreamResult = {
    type: "webcam",
    start,
    stop,
    isStreaming,
    stream,
  };

  return result;
}

// =======================
// Screen Capture Hook
// =======================

export function useScreenCapture(): UseMediaStreamResult {
  const [stream, setStream] = useState<MediaStream | null>(null);
  const [isStreaming, setIsStreaming] = useState(false);

  useEffect(() => {
    const handleStreamEnded = () => {
      setIsStreaming(false);
      setStream(null);
    };
    if (stream) {
      stream
        .getTracks()
        .forEach((track) => track.addEventListener("ended", handleStreamEnded));
      return () => {
        stream
          .getTracks()
          .forEach((track) =>
            track.removeEventListener("ended", handleStreamEnded),
          );
      };
    }
  }, [stream]);

  const start = async () => {
    // const controller = new CaptureController();
    // controller.setFocusBehavior("no-focus-change");
    const mediaStream = await navigator.mediaDevices.getDisplayMedia({
      video: true,
      // controller
    });
    setStream(mediaStream);
    setIsStreaming(true);
    return mediaStream;
  };

  const stop = () => {
    if (stream) {
      stream.getTracks().forEach((track) => track.stop());
      setStream(null);
      setIsStreaming(false);
    }
  };

  const result: UseMediaStreamResult = {
    type: "screen",
    start,
    stop,
    isStreaming,
    stream,
  };

  return result;
}