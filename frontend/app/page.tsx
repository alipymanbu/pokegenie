import Link from "next/link";
import { listRaids } from "@/lib/api";

export const dynamic = "force-dynamic";

export default async function HomePage() {
  let raids;
  try {
    raids = await listRaids();
  } catch (e) {
    return (
      <main>
        <p style={{ color: "crimson" }}>
          Could not reach the API. Is the backend running on{" "}
          <code>http://localhost:3000</code>?
        </p>
      </main>
    );
  }

  return (
    <main>
      <h2>Open raids</h2>
      {raids.length === 0 && <p>No published raids right now.</p>}
      <ul style={{ listStyle: "none", padding: 0 }}>
        {raids.map((raid) => (
          <li
            key={raid.id}
            style={{ border: "1px solid #ddd", borderRadius: 8, padding: "1rem", marginBottom: "0.75rem" }}
          >
            <strong>{raid.boss}</strong> @ {raid.gym_name}
            <div style={{ color: "#666", fontSize: 14 }}>
              {raid.slots_remaining}/{raid.capacity} slots · starts{" "}
              {new Date(raid.starts_at).toLocaleString()}
            </div>
            <Link href={`/raids/${raid.id}`}>Join the line →</Link>
          </li>
        ))}
      </ul>
    </main>
  );
}
