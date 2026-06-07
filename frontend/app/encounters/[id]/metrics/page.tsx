"use client";

// Operator view for an elastic encounter: live queue depth + per-room fill (confirmed / holds /
// free), polled every 1.5s. Watch rooms spawn and fill under load.
import { useEffect, useState } from "react";
import { useParams } from "next/navigation";
import Link from "next/link";
import { getEncounterMetrics, type EncounterMetrics } from "@/lib/api";

function Stat({ label, value, accent }: { label: string; value: string | number; accent?: string }) {
  return (
    <div className="stat">
      <div className="stat-value" style={accent ? { color: accent } : undefined}>{value}</div>
      <div className="stat-label">{label}</div>
    </div>
  );
}

export default function EncounterMetricsPage() {
  const params = useParams<{ id: string }>();
  const id = Number(params.id);
  const [m, setM] = useState<EncounterMetrics | null>(null);
  const [error, setError] = useState("");

  useEffect(() => {
    let active = true;
    const tick = async () => {
      try {
        const d = await getEncounterMetrics(id);
        if (active) setM(d);
      } catch (e: any) {
        if (active) setError(e.message);
      }
    };
    tick();
    const t = setInterval(tick, 1500);
    return () => {
      active = false;
      clearInterval(t);
    };
  }, [id]);

  return (
    <>
      <Link href={`/encounters/${id}`} className="back-link">← Encounter</Link>
      <h2 className="section-title">Operator view <span className="live-dot" /> live</h2>

      {error && <div className="banner banner--error">{error}</div>}

      {m && (
        <>
          <div className="card">
            <div className="stat-grid">
              <Stat label="In line" value={m.queue_depth.toLocaleString()} accent="var(--blue)" />
              <Stat label="Rooms" value={m.rooms} accent="var(--red)" />
              <Stat label="Confirmed" value={m.confirmed} accent="var(--green)" />
              <Stat label="Admitted" value={m.admitted_total} />
              <Stat label="Room size" value={m.room_size} />
              <Stat label="Capacity" value={m.capacity_so_far} />
            </div>
          </div>

          <h2 className="section-title" style={{ marginTop: 22 }}>Rooms</h2>
          {m.room_breakdown.length === 0 && <div className="card muted">No rooms spawned yet.</div>}
          <ul className="raid-list">
            {m.room_breakdown.map((r) => {
              const confPct = (r.confirmed / r.room_size) * 100;
              const holdPct = (r.holding / r.room_size) * 100;
              return (
                <li key={r.room_number} className="card">
                  <div className="raid-top">
                    <div className="raid-boss" style={{ fontSize: 16 }}>Room #{r.room_number}</div>
                    <span className="badge badge--info">{r.confirmed}/{r.room_size}</span>
                  </div>
                  {/* stacked bar: confirmed (gold) + holds (blue, pending claim) */}
                  <div className="progress" aria-hidden style={{ display: "flex" }}>
                    <span style={{ width: `${confPct}%`, background: "var(--gold)" }} />
                    <span style={{ width: `${holdPct}%`, background: "var(--blue)", borderRadius: 0 }} />
                  </div>
                  <div className="raid-meta" style={{ marginTop: 8 }}>
                    <span style={{ color: "var(--amber)" }}>{r.confirmed} confirmed</span>
                    <span>·</span>
                    <span style={{ color: "var(--blue)" }}>{r.holding} holding</span>
                    <span>·</span>
                    <span>{r.free} free</span>
                  </div>
                </li>
              );
            })}
          </ul>
        </>
      )}
    </>
  );
}
