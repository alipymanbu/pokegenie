"use client";

// MVP waiting room: join, then POLL /queue/status every 2s and claim once admitted.
// US2 replaces this poll with the SSE stream (lib/queueStream.ts) for instant updates.
import { useEffect, useRef, useState } from "react";
import Link from "next/link";
import { useParams } from "next/navigation";
import {
  joinQueue,
  getStatus,
  getRaid,
  claimSlot,
  type QueueStatus,
  type Raid,
} from "@/lib/api";

type Phase = "idle" | "waiting" | "admitted" | "confirmed" | "full";

export default function RaidQueuePage() {
  const params = useParams<{ id: string }>();
  const raidId = Number(params.id);

  const [raid, setRaid] = useState<Raid | null>(null);
  const [handle, setHandle] = useState("");
  const [token, setToken] = useState("");
  const [status, setStatus] = useState<QueueStatus | null>(null);
  const [phase, setPhase] = useState<Phase>("idle");
  const [reservationId, setReservationId] = useState<number | null>(null);
  const [error, setError] = useState("");
  const startPos = useRef<number | null>(null);

  useEffect(() => {
    getRaid(raidId).then(setRaid).catch(() => {});
  }, [raidId]);

  async function handleJoin() {
    setError("");
    try {
      const s = await joinQueue(raidId, handle);
      setToken(s.token);
      setStatus(s);
      startPos.current = s.position ?? 1;
      setPhase(s.state === "raid_full" ? "full" : "waiting");
    } catch (e: any) {
      setError(e.message);
    }
  }

  // Poll position/admission while waiting.
  useEffect(() => {
    if (phase !== "waiting" || !token || !handle) return;
    const timer = setInterval(async () => {
      try {
        const s = await getStatus(raidId, handle, token);
        if ("position" in s) {
          setStatus(s as QueueStatus);
          if (s.state === "admitted") setPhase("admitted");
        }
      } catch {
        /* transient; keep polling */
      }
    }, 2000);
    return () => clearInterval(timer);
  }, [phase, token, handle, raidId]);

  async function handleClaim() {
    setError("");
    const r = await claimSlot(raidId, handle);
    if (r.ok) {
      setReservationId(r.body.id);
      setPhase("confirmed");
    } else if (r.body.error === "raid_full") {
      setPhase("full");
    } else {
      setError(r.body.message ?? "Could not claim a slot.");
    }
  }

  const progress =
    status?.position && startPos.current
      ? Math.min(100, Math.max(0, ((startPos.current - status.position) / startPos.current) * 100))
      : 0;

  return (
    <>
      <Link href="/" className="back-link">
        ← All raids
      </Link>

      <h2 className="section-title">
        {raid ? `${raid.boss} · ${raid.gym_name}` : `Raid #${raidId}`}
      </h2>

      {/* IDLE — join form */}
      {phase === "idle" && (
        <div className="card">
          <p className="subtext">Enter your trainer name to join the waiting line.</p>
          <div className="field">
            <input
              className="input"
              placeholder="Trainer name"
              value={handle}
              onChange={(e) => setHandle(e.target.value)}
              onKeyDown={(e) => e.key === "Enter" && handle && handleJoin()}
            />
            <button className="btn btn--primary" onClick={handleJoin} disabled={!handle}>
              Join the line
            </button>
          </div>
        </div>
      )}

      {/* WAITING — live position */}
      {phase === "waiting" && status && (
        <div className="card">
          <div className="position-hero">
            <div className="position-label">Your position</div>
            <div className="position-number">#{status.position}</div>
            <div className="position-sub">
              <span className="live-dot" />
              {status.depth.toLocaleString()} trainers in line
            </div>
          </div>
          <div className="progress" aria-hidden>
            <span style={{ width: `${progress}%` }} />
          </div>
          <p className="subtext" style={{ textAlign: "center", marginTop: 14 }}>
            Hang tight — you’ll be admitted automatically when it’s your turn.
          </p>
        </div>
      )}

      {/* ADMITTED — claim */}
      {phase === "admitted" && (
        <div className="card admitted-card">
          <div className="big-emoji">🎉</div>
          <div className="headline">You’re up!</div>
          <p className="subtext">A slot is ready for you. Claim it before it’s gone.</p>
          <button className="btn btn--go" onClick={handleClaim}>
            Claim my slot
          </button>
        </div>
      )}

      {/* CONFIRMED — success */}
      {phase === "confirmed" && (
        <div className="card success-card">
          <div className="big-emoji">✅</div>
          <div className="headline">Slot reserved!</div>
          <p className="subtext">
            You’re in for {raid?.boss ?? "the raid"}
            {reservationId ? ` · reservation #${reservationId}` : ""}.
          </p>
          <Link href="/" className="btn btn--primary" style={{ textDecoration: "none" }}>
            Back to raids
          </Link>
        </div>
      )}

      {/* FULL */}
      {phase === "full" && (
        <div className="card">
          <div className="big-emoji">😕</div>
          <div className="headline">This raid is full</div>
          <p className="subtext">All slots have been claimed. Try another raid!</p>
          <Link href="/" className="btn btn--primary" style={{ textDecoration: "none" }}>
            Back to raids
          </Link>
        </div>
      )}

      {error && <div className="banner banner--error">{error}</div>}
    </>
  );
}
