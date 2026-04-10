import { DeviceRegistry } from './device-registry';
import { createApp } from './gateway-server';

const PORT = parseInt(process.env.PORT || '9999', 10);

const registry = new DeviceRegistry();
const app = createApp(registry);

app.listen(PORT, () => {
  console.log(`[kindle-gateway] MCP server listening on port ${PORT}`);
  console.log(`[kindle-gateway] Registration: POST http://localhost:${PORT}/register`);
  console.log(`[kindle-gateway] MCP endpoint: POST http://localhost:${PORT}/mcp`);
  console.log(`[kindle-gateway] Health: GET http://localhost:${PORT}/health`);
});
