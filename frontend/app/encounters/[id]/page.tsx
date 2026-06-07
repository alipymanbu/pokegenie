"use client";

// Encounter waiting room (feature 002): queue for a Pokémon, get auto-assigned a room on
// admission, then claim your spot in it. Real-time via SSE; refresh-safe via reconnect.
import { useEffect, useRef, useState } from "react";
import Link from "next/link";
import { useParams } from "next/navigation";
import {
  joinEncounter,
  getEncounter,
  reconnectEncounter,
  claimSlot,
  type Encounter,
  type EncounterStatus,
} from "@/lib/api";
import { openEncounterStream } from "@/lib/queueStream";

type Phase = "idle" | "waiting" | "admitted" | "confirmed" | "expired";

function mmss(t: number) {
  return `${Math.floor(t / 60)}:${(t % 60).toString().padStart(2, "0")}`;
}

export default function EncounterQueuePage() {
  const params = useParams<{ id: string }>();
  const encId = Number(params.id);
  const storageKey = `pg_enc_${encId}`;

  const [enc, setEnc] = useState<Encounter | null>(null);
  const [handle, setHandle] = useState("");
  const [token, setToken] = useState("");
  const [status, setStatus] = useState<EncounterStatus | null>(null);
  const [phase, setPhase] = useState<Phase>("idle");
  const [room, setRoom] = useState<{ id: number; number: number } | null>(null);
  const [secondsLeft, setSecondsLeft] = useState<number | null>(null);
  const [error, setError] = useState("");
  const startPos = useRef<number | null>(null);
  const deadline = useRef<number | null>(null);
  const didInit = useRef(false);

  useEffect(() => {
    getEncounter(encId).then(setEnc).catch(() => {});
  }, [encId]);

  function enterAdmitted(roomId: number, roomNumber: number, secs?: number | null) {
    setRoom({ id: roomId, number: roomNumber });
    const s = secs && secs > 0 ? secs : 120;
    deadline.current = Date.now() + s * 1000;
    setSecondsLeft(s);
    setPhase("admitted");
  }

  async function doJoin(h: string) {
    setError("");
    try {
      const s = await joinEncounter(encId, h);
      setHandle(h);
      setToken(s.token);
      setStatus(s);
      startPos.current = s.position ?? 1;
      localStorage.setItem(storageKey, JSON.stringify({ token: s.token, handle: h }));
      setPhase("waiting");
    } catch (e: any) {
      setError(e.message);
    }
  }

  // Resume on mount.
  useEffect(() => {
    if (didInit.current) return;
    didInit.current = true;
    const saved = typeof window !== "undefined" ? localStorage.getItem(storageKey) : null;
    if (!saved) return;
    const { token: savedToken, handle: savedHandle } = JSON.parse(saved);
    (async () => {
      const r = await reconnectEncounter(encId, savedToken);
      if ("expired" in r) {
        if (savedHandle) await doJoin(savedHandle);
        return;
      }
      setHandle(r.trainer_handle ?? savedHandle);
      setToken(r.token);
      localStorage.setItem(storageKey, JSON.stringify({ token: r.token, handle: r.trainer_handle ?? savedHandle }));
      if (r.state === "reserved" && r.room_id) {
        setRoom({ id: r.room_id, number: r.room_number ?? 0 });
        setPhase("confirmed");
      } else if (r.state === "admitted" && r.room_id) {
        enterAdmitted(r.room_id, r.room_number ?? 0, r.claim_seconds_remaining);
      } else if (r.state === "waiting") {
        startPos.current = r.position ?? 1;
        setStatus(r);
        setPhase("waiting");
      } else if (savedHandle) {
        await doJoin(savedHandle);
      }
    })();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [encId]);

  // SSE while waiting.
  useEffect(() => {
    if (phase !== "waiting" || !token) return;
    const es = openEncounterStream(encId, token, {
      onPosition: ({ position, depth }) =>
        setStatus({ token, encounter_id: encId, state: "waiting", position, depth }),
      onAdmitted: ({ room_id, room_number, claim_seconds_remaining }) =>
        enterAdmitted(room_id, room_number, claim_seconds_remaining),
    });
    return () => es.close();
  }, [phase, token, encId]);

  // Claim-window countdown.
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
    if (!room) return;
    setError("");
    const r = await claimSlot(room.id, handle); // claim into the assigned room (a Raid)
    if (r.ok) {
      setPhase("confirmed");
    } else if (r.body.error === "not_admitted") {
      setPhase("expired");
    } else {
      setError(r.body.message ?? "Could not claim your spot.");
    }
  }

  const progress =
    status?.position && startPos.current
      ? Math.min(100, Math.max(0, ((startPos.current - status.position) / startPos.current) * 100))
      : 0;
  const urgent = secondsLeft != null && secondsLeft <= 15;

  return (
    <>
      <Link href={`/encounters/${encId}/metrics`} className="ops-link">
        Operator view →
      </Link>
      <Link href="/encounters" className="back-link">
        ← All encounters
      </Link>
      <h2 className="section-title">{enc ? `${enc.boss} · ${enc.label}` : `Encounter #${encId}`}</h2>

      {phase === "idle" && (
        <div className="card">
          <p className="subtext">Join the line — we’ll auto-assign you a room when it’s your turn.</p>
          <div className="field">
            <input
              className="input"
              placeholder="Trainer name"
              value={handle}
              onChange={(e) => setHandle(e.target.value)}
              onKeyDown={(e) => e.key === "Enter" && handle && doJoin(handle)}
            />
            <button className="btn btn--primary" onClick={() => doJoin(handle)} disabled={!handle}>
              Join the line
            </button>
          </div>
        </div>
      )}

      {phase === "waiting" && status && (
        <div className="card">
          <div className="position-hero">
            <div className="position-label">Your position</div>
            <div className="position-number">#{status.position}</div>
            <div className="position-sub">
              <span className="live-dot" />
              live · {status.depth.toLocaleString()} in line · rooms spin up as needed
            </div>
          </div>
          <div className="progress" aria-hidden>
            <span style={{ width: `${progress}%` }} />
          </div>
          <p className="subtext" style={{ textAlign: "center", marginTop: 14 }}>
            You’ll be placed in a room automatically — no “full”. Safe to refresh.
          </p>
        </div>
      )}

      {phase === "admitted" && room && (
        <div className="card admitted-card">
          <div className="big-emoji">🎉</div>
          <div className="headline">You’re in — Room #{room.number}!</div>
          <p className="subtext">You’ve been auto-assigned a lobby. Claim your spot before it lapses.</p>
          {secondsLeft != null && (
            <div className={`countdown ${urgent ? "countdown--urgent" : ""}`}>⏳ {mmss(secondsLeft)} to claim</div>
          )}
          <button className="btn btn--go" onClick={handleClaim}>
            Claim my spot in Room #{room.number}
          </button>
        </div>
      )}

      {phase === "confirmed" && (
        <div className="card success-card">
          <div className="big-emoji">✅</div>
          <div className="headline">Locked in{room ? ` · Room #${room.number}` : ""}!</div>
          <p className="subtext">See you at {enc?.boss ?? "the raid"}.</p>
          <Link href="/encounters" className="btn btn--primary" style={{ textDecoration: "none" }}>
            Back to encounters
          </Link>
        </div>
      )}

      {phase === "expired" && (
        <div className="card">
          <div className="big-emoji">⌛</div>
          <div className="headline">Your hold expired</div>
          <p className="subtext">You didn’t claim in time. Rejoin to get a fresh spot.</p>
          <button className="btn btn--primary" onClick={() => doJoin(handle)}>
            Rejoin the line
          </button>
        </div>
      )}

      {error && <div className="banner banner--error">{error}</div>}
    </>
  );
}
