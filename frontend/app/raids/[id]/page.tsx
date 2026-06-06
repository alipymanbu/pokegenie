"use client";

// MVP waiting room: join, then POLL /queue/status every 2s and claim once admitted.
// US2 replaces this poll with the SSE stream (lib/queueStream.ts) for instant updates.
import { useEffect, useState } from "react";
import { useParams } from "next/navigation";
import { joinQueue, getStatus, claimSlot, type QueueStatus } from "@/lib/api";

export default function RaidQueuePage() {
  const params = useParams<{ id: string }>();
  const raidId = Number(params.id);

  const [handle, setHandle] = useState("");
  const [token, setToken] = useState("");
  const [status, setStatus] = useState<QueueStatus | null>(null);
  const [result, setResult] = useState<string>("");
  const [error, setError] = useState<string>("");

  async function handleJoin() {
    setError("");
    try {
      const s = await joinQueue(raidId, handle);
      setToken(s.token);
      setStatus(s);
    } catch (e: any) {
      setError(e.message);
    }
  }

  // Poll position/admission while waiting.
  useEffect(() => {
    if (!token || !handle || status?.state === "admitted") return;
    const timer = setInterval(async () => {
      const s = await getStatus(raidId, handle, token);
      if ("position" in s) setStatus(s as QueueStatus);
    }, 2000);
    return () => clearInterval(timer);
  }, [token, handle, raidId, status?.state]);

  async function handleClaim() {
    const r = await claimSlot(raidId, handle);
    setResult(
      r.ok
        ? `Reservation #${r.body.id} confirmed!`
        : `Could not claim: ${r.body.error}`,
    );
  }

  return (
    <main>
      <h2>Raid #{raidId} — waiting room</h2>

      {!token && (
        <div>
          <input
            placeholder="Trainer handle"
            value={handle}
            onChange={(e) => setHandle(e.target.value)}
          />
          <button onClick={handleJoin} disabled={!handle}>
            Join the line
          </button>
        </div>
      )}

      {error && <p style={{ color: "crimson" }}>{error}</p>}

      {status && status.state === "waiting" && (
        <p>
          You are <strong>#{status.position}</strong> of {status.depth} in line…
        </p>
      )}

      {status && status.state === "admitted" && !result && (
        <div>
          <p>🎉 You’re admitted! Claim your slot:</p>
          <button onClick={handleClaim}>Claim a slot</button>
        </div>
      )}

      {result && <p style={{ fontWeight: 600 }}>{result}</p>}
    </main>
  );
}
