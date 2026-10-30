import { DeviceRegistry } from './device-registry';
import express from 'express';
import { createApp } from './gateway-server';
import { packageHostOptionsFromEnv, packageHostRouter } from './package-host';

const PORT = parseInt(process.env.PORT || '9999', 10);

const registry = new DeviceRegistry();
const pkgHost = packageHostOptionsFromEnv();
const app = express();
// The package host goes first: its upload route reads the raw body, which
// createApp's JSON body parser would otherwise consume.
app.use(packageHostRouter(pkgHost));
app.use(createApp(registry));

app.listen(PORT, () => {
  console.log(`[kindle-gateway] MCP server listening on port ${PORT}`);
  console.log(`[kindle-gateway] Registration: POST http://localhost:${PORT}/register`);
  console.log(`[kindle-gateway] MCP endpoint: POST http://localhost:${PORT}/mcp`);
  console.log(`[kindle-gateway] Health: GET http://localhost:${PORT}/health`);
  console.log(`[kindle-gateway] Packages: GET /pkg/ from ${pkgHost.pkgDir}; inbox: PUT /inbox/<device>/<file>.tar.gz into ${pkgHost.inboxDir} (max ${pkgHost.inboxMaxBytes} bytes)`);
});
