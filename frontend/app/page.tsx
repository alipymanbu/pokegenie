import Link from "next/link";
import { listRaids, type Raid } from "@/lib/api";

export const dynamic = "force-dynamic";

function slotBadge(raid: Raid) {
  const ratio = raid.slots_remaining / raid.capacity;
  if (raid.slots_remaining === 0) return { cls: "badge--full", text: "Full" };
  if (ratio <= 0.25) return { cls: "badge--low", text: `${raid.slots_remaining} left` };
  return { cls: "badge--ok", text: `${raid.slots_remaining} slots open` };
}

export default async function HomePage() {
  let raids: Raid[];
  try {
    raids = await listRaids();
  } catch {
    return (
      <div className="banner banner--error">
        Could not reach the API. Is the backend running on{" "}
        <code>http://localhost:3000</code>?
      </div>
    );
  }

  return (
    <>
      <h2 className="section-title">Open raids</h2>

      {raids.length === 0 && (
        <div className="card muted">No published raids right now. Check back soon!</div>
      )}

      <ul className="raid-list">
        {raids.map((raid) => {
          const badge = slotBadge(raid);
          const filled = ((raid.capacity - raid.slots_remaining) / raid.capacity) * 100;
          return (
            <li key={raid.id}>
              <Link href={`/raids/${raid.id}`} className="card raid-card">
                <div className="raid-top">
                  <div>
                    <div className="raid-boss">{raid.boss}</div>
                    <div className="raid-gym">📍 {raid.gym_name}</div>
                  </div>
                  <span className={`badge ${badge.cls}`}>{badge.text}</span>
                </div>

                <div className="progress" aria-hidden>
                  <span style={{ width: `${filled}%` }} />
                </div>

                <div className="raid-meta">
                  <span>
                    {raid.capacity - raid.slots_remaining}/{raid.capacity} claimed
                  </span>
                  <span>·</span>
                  <span>🕒 {new Date(raid.starts_at).toLocaleString()}</span>
                </div>

                <div className="raid-cta">Join the line →</div>
              </Link>
            </li>
          );
        })}
      </ul>
    </>
  );
}
