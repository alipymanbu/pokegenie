// REST client for the Rails queue API. Base URL is configurable so the same build runs
// locally and in docker-compose.
export const API_BASE =
  process.env.NEXT_PUBLIC_API_BASE ?? "http://localhost:3000";

export interface Raid {
  id: number;
  boss: string;
  gym_name: string;
  starts_at: string;
  capacity: number;
  slots_remaining: number;
  status: string;
}

export interface QueueStatus {
  token: string;
  state: "waiting" | "admitted" | "raid_full";
  position: number | null;
  depth: number;
  raid_id: number;
}

export async function getRaid(raidId: number): Promise<Raid> {
  const res = await fetch(`${API_BASE}/raids/${raidId}`, { cache: "no-store" });
  if (!res.ok) throw new Error(`Failed to load raid (${res.status})`);
  return res.json();
}

export async function listRaids(): Promise<Raid[]> {
  const res = await fetch(`${API_BASE}/raids`, { cache: "no-store" });
  if (!res.ok) throw new Error(`Failed to load raids (${res.status})`);
  const body = await res.json();
  return body.raids as Raid[];
}

export async function joinQueue(
  raidId: number,
  trainerHandle: string,
): Promise<QueueStatus> {
  const res = await fetch(`${API_BASE}/raids/${raidId}/queue/join`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ trainer_handle: trainerHandle }),
  });
  if (!res.ok) {
    const err = await res.json().catch(() => ({}));
    throw new Error(err.message ?? `Join failed (${res.status})`);
  }
  return res.json();
}

export async function getStatus(
  raidId: number,
  trainerHandle: string,
  token: string,
): Promise<QueueStatus | { state: "gone" }> {
  const url = new URL(`${API_BASE}/raids/${raidId}/queue/status`);
  url.searchParams.set("trainer_handle", trainerHandle);
  if (token) url.searchParams.set("token", token);
  const res = await fetch(url.toString(), { cache: "no-store" });
  if (res.status === 404) return { state: "gone" };
  if (!res.ok) throw new Error(`Status failed (${res.status})`);
  return res.json();
}

export async function claimSlot(raidId: number, trainerHandle: string) {
  const res = await fetch(`${API_BASE}/raids/${raidId}/reservations`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ trainer_handle: trainerHandle }),
  });
  const body = await res.json().catch(() => ({}));
  return { ok: res.ok, status: res.status, body };
}
