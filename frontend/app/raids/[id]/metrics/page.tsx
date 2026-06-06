"use client";

// Operator view (US-polish, FR-016/SC-007): live raid metrics, polled every 2s.
import { useEffect, useState } from "react";
import { useParams } from "next/navigation";
import Link from "next/link";
import { getMetrics, type Metrics } from "@/lib/api";

function Stat({ label, value, accent }: { label: string; value: string | number; accent?: string }) {
  return (
    <div className="stat">
      <div className="stat-value" style={accent ? { color: accent } : undefined}>
        {value}
      </div>
      <div className="stat-label">{label}</div>
    </div>
  );
}

export default function MetricsPage() {
  const params = useParams<{ id: string }>();
  const raidId = Number(params.id);
  const [m, setM] = useState<Metrics | null>(null);
  const [error, setError] = useState("");

  useEffect(() => {
    let active = true;
    const tick = async () => {
      try {
        const data = await getMetrics(raidId);
        if (active) setM(data);
      } catch (e: any) {
        if (active) setError(e.message);
      }
    };
    tick();
    const timer = setInterval(tick, 2000);
    return () => {
      active = false;
      clearInterval(timer);
    };
  }, [raidId]);

  const filled = m ? ((m.capacity - m.slots_remaining) / m.capacity) * 100 : 0;

  return (
    <>
      <Link href={`/raids/${raidId}`} className="back-link">
        ← Raid
      </Link>
      <h2 className="section-title">
        Operator view <span className="live-dot" /> live
      </h2>

      {error && <div className="banner banner--error">{error}</div>}

      {m && (
        <>
          <div className="card">
            <div className="stat-grid">
              <Stat label="In line" value={m.queue_depth.toLocaleString()} accent="var(--blue)" />
              <Stat label="Slots left" value={`${m.slots_remaining}/${m.capacity}`} accent="var(--green)" />
              <Stat label="Admitted" value={m.admitted_total.toLocaleString()} />
              <Stat label="Claims" value={m.claims_total.toLocaleString()} />
              <Stat label="Conflicts" value={m.conflicts_total.toLocaleString()} accent="var(--amber)" />
              <Stat
                label="Conflict rate"
                value={`${(m.conflict_rate * 100).toFixed(1)}%`}
                accent={m.conflict_rate > 0.1 ? "var(--red)" : undefined}
              />
            </div>
          </div>

          <div className="card" style={{ marginTop: 14 }}>
            <div className="raid-meta" style={{ marginTop: 0 }}>
              {m.capacity - m.slots_remaining}/{m.capacity} slots claimed
            </div>
            <div className="progress" aria-hidden>
              <span style={{ width: `${filled}%` }} />
            </div>
          </div>
        </>
      )}
    </>
  );
}
