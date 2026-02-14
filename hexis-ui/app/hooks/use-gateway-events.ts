"use client";

import { useEffect, useRef } from "react";

/**
 * Hook that connects to the gateway SSE stream and calls `onEvent`
 * whenever a gateway event arrives. Used to trigger instant status
 * refreshes instead of 30-second polling.
 *
 * Always keeps a 60-second safety-net poll running alongside SSE so
 * the dashboard never goes completely stale if an event is missed.
 * Falls back to 30-second polling if the SSE connection fails.
 */
export function useGatewayEvents(onEvent: () => void) {
  const onEventRef = useRef(onEvent);
  onEventRef.current = onEvent;

  useEffect(() => {
    let es: EventSource | null = null;
    let fallbackInterval: ReturnType<typeof setInterval> | null = null;
    let safetyInterval: ReturnType<typeof setInterval> | null = null;
    let reconnectTimeout: ReturnType<typeof setTimeout> | null = null;
    let stopped = false;

    // Safety-net poll: always refresh every 60s regardless of SSE state
    safetyInterval = setInterval(() => {
      onEventRef.current();
    }, 60000);

    function connect() {
      if (stopped) return;

      try {
        es = new EventSource("/api/events/stream");

        es.addEventListener("gateway_event", () => {
          onEventRef.current();
        });

        es.onerror = () => {
          // Connection lost — close and fall back to faster polling
          es?.close();
          es = null;
          if (!stopped && !fallbackInterval) {
            fallbackInterval = setInterval(() => {
              onEventRef.current();
            }, 30000);
            // Try to reconnect after 10 seconds
            reconnectTimeout = setTimeout(() => {
              if (fallbackInterval) {
                clearInterval(fallbackInterval);
                fallbackInterval = null;
              }
              connect();
            }, 10000);
          }
        };
      } catch {
        // EventSource not supported or URL issue — fall back to polling
        if (!fallbackInterval) {
          fallbackInterval = setInterval(() => {
            onEventRef.current();
          }, 30000);
        }
      }
    }

    connect();

    return () => {
      stopped = true;
      es?.close();
      if (fallbackInterval) clearInterval(fallbackInterval);
      if (safetyInterval) clearInterval(safetyInterval);
      if (reconnectTimeout) clearTimeout(reconnectTimeout);
    };
  }, []);
}
