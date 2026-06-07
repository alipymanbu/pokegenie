"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import { createEncounter, publishEncounter } from "@/lib/api";

export default function NewEncounterPage() {
  const router = useRouter();
  const [boss, setBoss] = useState("");
  const [label, setLabel] = useState("");
  const [startsAt, setStartsAt] = useState("");
  const [roomSize, setRoomSize] = useState(20);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  async function submit() {
    setError("");
    setBusy(true);
    try {
      const starts = startsAt ? new Date(startsAt).toISOString() : new Date(Date.now() + 3600_000).toISOString();
      const enc = await createEncounter({ boss, label, starts_at: starts, room_size: roomSize });
      await publishEncounter(enc.id);
      router.push("/encounters");
    } catch (e: any) {
      setError(e.message);
      setBusy(false);
    }
  }

  const valid = boss.trim() && label.trim() && roomSize > 0;

  return (
    <>
      <Link href="/encounters" className="back-link">
        ← All encounters
      </Link>
      <h2 className="section-title">Create an encounter</h2>

      <div className="card">
        <label className="form-label">Raid boss</label>
        <input className="input input--block" placeholder="e.g. Rayquaza" value={boss} onChange={(e) => setBoss(e.target.value)} />

        <label className="form-label">Label / location</label>
        <input className="input input--block" placeholder="e.g. Sky Pillar" value={label} onChange={(e) => setLabel(e.target.value)} />

        <label className="form-label">Starts at</label>
        <input className="input input--block" type="datetime-local" value={startsAt} onChange={(e) => setStartsAt(e.target.value)} />

        <label className="form-label">Room size (trainers per lobby)</label>
        <input className="input input--block" type="number" min={1} value={roomSize} onChange={(e) => setRoomSize(Number(e.target.value))} />

        <button className="btn btn--go" style={{ marginTop: 18 }} onClick={submit} disabled={!valid || busy}>
          {busy ? "Creating…" : "Create & publish encounter"}
        </button>
        {error && <div className="banner banner--error">{error}</div>}
      </div>
    </>
  );
}
