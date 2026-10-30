import { DeviceInfo } from './device-registry';

interface JsonRpcResponse {
  id: number;
  result?: unknown;
  error?: { code: number; message: string; data?: unknown };
}

/** Sends a tool call down a device's live connection and waits for the reply with its id. */
export class KindleClient {
  constructor(private device: DeviceInfo) {}

  async callTool(method: string, params?: Record<string, unknown>, timeoutMs: number = 10000): Promise<JsonRpcResponse> {
    try {
      return await this.device.link.call(method, params, timeoutMs);
    } catch (err) {
      if (err instanceof Error && err.message.startsWith('no reply')) {
        throw new Error(`Tool call to ${this.device.name} timed out after ${timeoutMs / 1000}s`);
      }
      throw err;
    }
  }
}
