import Link from "next/link";
import { listEncounters, type Encounter } from "@/lib/api";

export const dynamic = "force-dynamic";

export default async function EncountersPage() {
  let encounters: Encounter[];
  try {
    encounters = await listEncounters();
  } catch {
    return (
      <div className="banner banner--error">
        Could not reach the API on <code>http://localhost:3000</code>.
      </div>
    );
  }

  return (
    <>
      <div className="toolbar">
        <h2 className="section-title" style={{ margin: 0 }}>
          Raid encounters
        </h2>
        <Link href="/encounters/new" className="link-btn">
          + Create an encounter
        </Link>
      </div>
      <p className="subtext" style={{ marginTop: -6 }}>
        Queue for a Pokémon — the system auto-assigns you to a room and spins up new ones as
        needed. No “full”, just wait your turn.
      </p>

      {encounters.length === 0 && (
        <div className="card muted">No published encounters yet. Create one!</div>
      )}

      <ul className="raid-list">
        {encounters.map((e) => (
          <li key={e.id}>
            <Link href={`/encounters/${e.id}`} className="card raid-card">
              <div className="raid-top">
                <div>
                  <div className="raid-boss">{e.boss}</div>
                  <div className="raid-gym">📍 {e.label}</div>
                </div>
                <span className="badge badge--info">∞ rooms · {e.room_size}/room</span>
              </div>
              <div className="raid-meta">
                <span>{e.rooms} room{e.rooms === 1 ? "" : "s"} open</span>
                <span>·</span>
                <span>🕒 {new Date(e.starts_at).toLocaleString()}</span>
              </div>
              <div className="raid-cta">Queue up →</div>
            </Link>
          </li>
        ))}
      </ul>

      <p style={{ marginTop: 20 }}>
        <Link href="/" className="back-link">
          ← Fixed-room raids
        </Link>
      </p>
    </>
  );
}
