# SSE Event Stream Contract

**Endpoint**: `GET /raids/{id}/queue/stream?token={queueToken}`
**Content-Type**: `text/event-stream`
**Direction**: server → client only (Principle V)

The client opens this with the browser `EventSource` API. On disconnect, `EventSource`
auto-reconnects; the client MUST reconnect with the **same `token`** so position is preserved
(FR-010). Each message uses a named `event:` plus a JSON `data:` line.

## Events

### `position`
Emitted on connect and then every ~1.5s (`POSITION_PUSH_MS`) while the trainer is still waiting.
Position is 1-based and monotonically non-increasing (SC-003, US2-AS1).

```
event: position
data: {"position": 4213, "depth": 51234}
```

### `admitted`
Emitted once, immediately, when the trainer is popped from the line by the admission worker
(FR-004, US2-AS2). After this the client may call `POST /raids/{id}/reservations` to claim.

```
event: admitted
data: {"raid_id": 7, "claim_deadline": "2026-06-06T18:32:00Z"}
```

### `raid_full`
Emitted when the trainer is drained from the line because the raid filled before their turn
(US1-AS1 losers), or when an admitted trainer's claim window context becomes full.

```
event: raid_full
data: {"raid_id": 7}
```

### `error`
Non-fatal stream-level error (e.g. token expired mid-stream → client should re-join).

```
event: error
data: {"error": "token_expired", "message": "Your place could not be restored; please rejoin."}
```

### keepalive
A comment line every ~15s to keep proxies from closing idle connections.

```
: keepalive
```

## Client reconnection sequence

1. `EventSource('/raids/7/queue/stream?token=ABC')`.
2. On network drop, `EventSource` retries automatically with the same URL (same token).
3. Server resolves `token:{ABC}`:
   - present → re-attach; resume `position` events at the preserved rank;
   - expired → emit `error: token_expired`; client falls back to `POST .../queue/join` (new place).
4. A trainer holding a confirmed reservation is unaffected by token expiry (reservation lives in
   PostgreSQL, FR-011).

## Ordering guarantees

- A given trainer never receives a `position` larger than a previously sent one (no backwards
  movement).
- `admitted` and `raid_full` are terminal for the waiting phase; no further `position` events
  follow them.
