// EventSource wrapper for the queue SSE stream (US2). Server→client only.
// See backend contracts/sse-events.md.
import { API_BASE } from "./api";

export interface QueueStreamHandlers {
  onPosition?: (d: { position: number; depth: number }) => void;
  onAdmitted?: (d: { raid_id: number; claim_seconds_remaining?: number }) => void;
  onRaidFull?: () => void;
}

export function openQueueStream(
  raidId: number,
  token: string,
  handlers: QueueStreamHandlers,
): EventSource {
  const url = new URL(`${API_BASE}/raids/${raidId}/queue/stream`);
  url.searchParams.set("token", token);
  const es = new EventSource(url.toString());

  es.addEventListener("position", (e) =>
    handlers.onPosition?.(JSON.parse((e as MessageEvent).data)),
  );
  es.addEventListener("admitted", (e) => {
    handlers.onAdmitted?.(JSON.parse((e as MessageEvent).data));
    es.close(); // terminal — don't let EventSource auto-reconnect
  });
  es.addEventListener("raid_full", () => {
    handlers.onRaidFull?.();
    es.close();
  });

  return es;
}
