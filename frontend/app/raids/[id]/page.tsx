"use client";

// Waiting room with real-time SSE (US2): position + admission are pushed by the server.
import { useEffect, useRef, useState } from "react";
import Link from "next/link";
import { useParams } from "next/navigation";
import { joinQueue, getRaid, claimSlot, type QueueStatus, type Raid } from "@/lib/api";
import { openQueueStream } from "@/lib/queueStream";

type Phase = "idle" | "waiting" | "admitted" | "confirmed" | "full" | "expired";

function mmss(total: number) {
  const m = Math.floor(total / 60);
  const s = total % 60;
  return `${m}:${s.toString().padStart(2, "0")}`;
}

export default function RaidQueuePage() {
  const params = useParams<{ id: string }>();
  const raidId = Number(params.id);

  const [raid, setRaid] = useState<Raid | null>(null);
  const [handle, setHandle] = useState("");
  const [token, setToken] = useState("");
  const [status, setStatus] = useState<QueueStatus | null>(null);
  const [phase, setPhase] = useState<Phase>("idle");
  const [reservationId, setReservationId] = useState<number | null>(null);
  const [secondsLeft, setSecondsLeft] = useState<number | null>(null);
  const [error, setError] = useState("");
  const startPos = useRef<number | null>(null);
  const deadline = useRef<number | null>(null);

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

  function enterAdmitted(remaining?: number) {
    const secs = remaining && remaining > 0 ? remaining : 120;
    deadline.current = Date.now() + secs * 1000;
    setSecondsLeft(secs);
    setPhase("admitted");
  }

  // Real-time stream while waiting (replaces polling).
  useEffect(() => {
    if (phase !== "waiting" || !token) return;
    const es = openQueueStream(raidId, token, {
      onPosition: ({ position, depth }) =>
        setStatus({ token, raid_id: raidId, state: "waiting", position, depth }),
      onAdmitted: ({ claim_seconds_remaining }) => enterAdmitted(claim_seconds_remaining),
      onRaidFull: () => setPhase("full"),
    });
    return () => es.close();
  }, [phase, token, raidId]);

  // Count down the claim window; lapse → expired.
  useEffect(() => {
    if (phase !== "admitted" || deadline.current == null) return;
    const timer = setInterval(() => {
      const left = Math.max(0, Math.round((deadline.current! - Date.now()) / 1000));
      setSecondsLeft(left);
      if (left <= 0) {
        clearInterval(timer);
        setPhase("expired");
      }
    }, 1000);
    return () => clearInterval(timer);
  }, [phase]);

  async function handleClaim() {
    setError("");
    const r = await claimSlot(raidId, handle);
    if (r.ok) {
      setReservationId(r.body.id);
      setPhase("confirmed");
    } else if (r.body.error === "raid_full") {
      setPhase("full");
    } else if (r.body.error === "not_admitted") {
      setPhase("expired");
    } else {
      setError(r.body.message ?? "Could not claim a slot.");
    }
  }

  function rejoin() {
    deadline.current = null;
    setSecondsLeft(null);
    setStatus(null);
    handleJoin();
  }

  const progress =
    status?.position && startPos.current
      ? Math.min(100, Math.max(0, ((startPos.current - status.position) / startPos.current) * 100))
      : 0;

  const urgent = secondsLeft != null && secondsLeft <= 15;

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

      {/* WAITING — live position (SSE) */}
      {phase === "waiting" && status && (
        <div className="card">
          <div className="position-hero">
            <div className="position-label">Your position</div>
            <div className="position-number">#{status.position}</div>
            <div className="position-sub">
              <span className="live-dot" />
              live · {status.depth.toLocaleString()} trainers in line
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

      {/* ADMITTED — claim with countdown */}
      {phase === "admitted" && (
        <div className="card admitted-card">
          <div className="big-emoji">🎉</div>
          <div className="headline">You’re up!</div>
          <p className="subtext">Claim your slot before your hold expires.</p>
          {secondsLeft != null && (
            <div className={`countdown ${urgent ? "countdown--urgent" : ""}`}>
              ⏳ {mmss(secondsLeft)} to claim
            </div>
          )}
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

      {/* EXPIRED — hold lapsed */}
      {phase === "expired" && (
        <div className="card">
          <div className="big-emoji">⌛</div>
          <div className="headline">Your hold expired</div>
          <p className="subtext">
            You didn’t claim in time, so your slot was released for other trainers. You can rejoin
            the line — you’ll start from the back.
          </p>
          <button className="btn btn--primary" onClick={rejoin}>
            Rejoin the line
          </button>
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
