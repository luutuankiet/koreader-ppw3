import { DeviceRegistry } from './device-registry';
import { startDeviceListener } from './device-link';
import { createApp } from './gateway-server';

const PORT = parseInt(process.env.PORT || '9999', 10);
const DEVICE_PORT = parseInt(process.env.DEVICE_PORT || '9990', 10);

const registry = new DeviceRegistry();
const app = createApp(registry);

startDeviceListener(registry, DEVICE_PORT);
console.log(`[kindle-gateway] Device connections: TCP port ${DEVICE_PORT}`);

app.listen(PORT, () => {
  console.log(`[kindle-gateway] MCP endpoint: POST http://localhost:${PORT}/mcp`);
  console.log(`[kindle-gateway] Health: GET http://localhost:${PORT}/health`);
});
