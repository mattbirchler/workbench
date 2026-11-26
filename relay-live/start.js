// Starts the relay on Railway (or anywhere): PORT picks the port, and the
// limits in relay.js can each be set from the environment.
import { startRelay, limitsFromEnv } from "./relay.js";

const relay = await startRelay({ port: Number(process.env.PORT ?? 8080), limits: limitsFromEnv(process.env) });
console.log(`Workbench relay listening on ${relay.port}`);

// Railway sends SIGTERM on a redeploy. Closing tells every Mac and phone
// to reconnect, which they do on their own.
for (const signal of ["SIGTERM", "SIGINT"]) {
  process.on(signal, async () => {
    await relay.close();
    process.exit(0);
  });
}
