// Starts the relay on Railway (or anywhere): PORT picks the port, and the
// limits in relay.js can each be set from the environment.
import { startRelay, limitsFromEnv } from "./relay.js";

const relay = await startRelay({ port: Number(process.env.PORT ?? 8080), limits: limitsFromEnv(process.env) });
console.log(`Workbench relay listening on ${relay.port}`);

// Once an hour, how much the relay carried: counts of rooms, devices,
// frames and bytes, with nothing that says whose. Only when a PostHog key
// is set, so a relay someone hosts for themselves reports to nobody.
const key = process.env.POSTHOG_KEY;
if (key) {
  const host = process.env.POSTHOG_HOST ?? "https://us.i.posthog.com";
  const report = async () => {
    const totals = relay.takeTotals();
    if (totals.hosts + totals.guests + totals.frames === 0 && totals.peakRooms === 0) return;
    try {
      await fetch(`${host}/capture/`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          api_key: key,
          event: "relay_hour",
          distinct_id: "workbench-relay",
          properties: {
            hosts_joined: totals.hosts,
            guests_joined: totals.guests,
            frames: totals.frames,
            bytes: totals.bytes,
            refused: totals.refused,
            peak_rooms: totals.peakRooms,
            peak_guests: totals.peakGuests,
            $process_person_profile: false,
          },
        }),
      });
    } catch {
      // A missed report is only a missed report.
    }
  };
  setInterval(report, 60 * 60 * 1000).unref();
}

// Railway sends SIGTERM on a redeploy. Closing tells every Mac and phone
// to reconnect, which they do on their own.
for (const signal of ["SIGTERM", "SIGINT"]) {
  process.on(signal, async () => {
    await relay.close();
    process.exit(0);
  });
}
