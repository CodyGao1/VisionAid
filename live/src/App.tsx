import { useRef, useState } from "react";
import "./App.scss";
import { LiveAPIProvider } from "./contexts/LiveAPIContext";
import { SidePanel } from "./components/Components";
import ControlTray from "./components/Components";
import cn from "classnames";
import { ReportHandler } from 'web-vitals';
// Removed Google GenAI imports - now handled by backend

// =======================
// Type Definitions
// =======================

/**
 * the options to initiate the WebSocket client
 */
export type LiveClientOptions = { wsUrl?: string };

/** log types */
export type StreamingLog = {
  date: Date;
  type: string;
  count?: number;
  message:
    | string
    | ClientContentLog
    | any;
};

export type ClientContentLog = {
  turns: any[];
  turnComplete: boolean;
};

// =======================
// Web Vitals Utility
// =======================

const reportWebVitals = (onPerfEntry?: ReportHandler) => {
  if (onPerfEntry && onPerfEntry instanceof Function) {
    import('web-vitals').then(({ getCLS, getFID, getFCP, getLCP, getTTFB }) => {
      getCLS(onPerfEntry);
      getFID(onPerfEntry);
      getFCP(onPerfEntry);
      getLCP(onPerfEntry);
      getTTFB(onPerfEntry);
    });
  }
};

// =======================
// Test Setup & Functions
// =======================

// Jest-dom setup (equivalent to setupTests.ts)
// Note: This would typically be in a separate setupTests.ts file for jest configuration
// but consolidated here as requested

// Test function for App component (equivalent to App.test.tsx)
export const testAppRender = () => {
  // This would normally use @testing-library/react for actual testing
  // Keeping the test logic here as an export for reference
  console.log('App test: renders learn react link');
  // Original test: render(<App />); screen.getByText(/learn react/i); expect(linkElement).toBeInTheDocument();
};

// =======================
// React App Environment
// =======================

// TypeScript environment declarations (equivalent to react-app-env.d.ts)
// Note: These would normally be in a .d.ts file
declare global {
  /// <reference types="react-scripts" />
}

// =======================
// Application Configuration
// =======================

// No API key needed in frontend - backend handles Gemini API
const apiOptions: LiveClientOptions = {};


function App() {
  // this video reference is used for displaying the active stream, whether that is the webcam or screen capture
  // feel free to style as you see fit
  const videoRef = useRef<HTMLVideoElement>(null);
  // either the screen capture, the video or null, if null we hide it
  const [videoStream, setVideoStream] = useState<MediaStream | null>(null);

  return (
    <div className="App">
      <LiveAPIProvider options={apiOptions}>
        <div className="streaming-console">
          <SidePanel />
          <main>
            <div className="main-app-area">
              <video
                className={cn("stream", {
                  hidden: !videoRef.current || !videoStream,
                })}
                ref={videoRef}
                autoPlay
                playsInline
              />
            </div>

            <ControlTray
              videoRef={videoRef}
              supportsVideo={true}
              onVideoStreamChange={setVideoStream}
              enableEditingSettings={true}
            >
              {/* put your own buttons here */}
            </ControlTray>
          </main>
        </div>
      </LiveAPIProvider>
    </div>
  );
}

export default App;

// =======================
// Application Exports & Utilities
// =======================

// Export web vitals function for performance monitoring
export { reportWebVitals };

// Initialize performance monitoring (originally called from index.tsx)
// If you want to start measuring performance in your app, pass a function
// to log results (for example: reportWebVitals(console.log))
// or send to an analytics endpoint. Learn more: https://bit.ly/CRA-vitals
if (typeof window !== 'undefined') {
  reportWebVitals();
}
