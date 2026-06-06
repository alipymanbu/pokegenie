"use client";

// Organizer: create a raid and publish it so trainers can queue (US4).
import { useState } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import { createRaid, publishRaid } from "@/lib/api";

export default function NewRaidPage() {
  const router = useRouter();
  const [boss, setBoss] = useState("");
  const [gym, setGym] = useState("");
  const [startsAt, setStartsAt] = useState("");
  const [capacity, setCapacity] = useState(20);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  async function submit() {
    setError("");
    setBusy(true);
    try {
      const starts = startsAt ? new Date(startsAt).toISOString() : new Date(Date.now() + 3600_000).toISOString();
      const raid = await createRaid({ boss, gym_name: gym, starts_at: starts, capacity });
      await publishRaid(raid.id); // publish immediately so it's joinable
      router.push("/");
    } catch (e: any) {
      setError(e.message);
      setBusy(false);
    }
  }

  const valid = boss.trim() && gym.trim() && capacity > 0;

  return (
    <>
      <Link href="/" className="back-link">
        ← All raids
      </Link>
      <h2 className="section-title">Create a raid</h2>

      <div className="card">
        <label className="form-label">Raid boss</label>
        <input className="input input--block" placeholder="e.g. Mewtwo" value={boss} onChange={(e) => setBoss(e.target.value)} />

        <label className="form-label">Gym / location</label>
        <input className="input input--block" placeholder="e.g. Central Park Gym" value={gym} onChange={(e) => setGym(e.target.value)} />

        <label className="form-label">Starts at</label>
        <input className="input input--block" type="datetime-local" value={startsAt} onChange={(e) => setStartsAt(e.target.value)} />

        <label className="form-label">Lobby capacity</label>
        <input
          className="input input--block"
          type="number"
          min={1}
          value={capacity}
          onChange={(e) => setCapacity(Number(e.target.value))}
        />

        <button className="btn btn--go" style={{ marginTop: 18 }} onClick={submit} disabled={!valid || busy}>
          {busy ? "Creating…" : "Create & publish raid"}
        </button>
        {error && <div className="banner banner--error">{error}</div>}
      </div>
    </>
  );
}
