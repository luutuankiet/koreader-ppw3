import { DeviceInfo } from './device-registry';

interface JsonRpcRequest {
  jsonrpc: '2.0';
  id: number;
  method: string;
  params?: Record<string, unknown>;
}

interface JsonRpcResponse {
  jsonrpc: '2.0';
  id: number;
  result?: unknown;
  error?: { code: number; message: string; data?: unknown };
}

export class KindleClient {
  private device: DeviceInfo;
  private static idCounter = 0;

  constructor(device: DeviceInfo) {
    this.device = device;
  }

  get baseUrl(): string {
    return `http://${this.device.ip}:${this.device.port}`;
  }

  async callTool(method: string, params?: Record<string, unknown>, timeoutMs: number = 10000): Promise<JsonRpcResponse> {
    const request: JsonRpcRequest = {
      jsonrpc: '2.0',
      id: ++KindleClient.idCounter,
      method,
      ...(params ? { params } : {}),
    };

    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), timeoutMs);

    try {
      const response = await fetch(`${this.baseUrl}/jsonrpc`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(request),
        signal: controller.signal,
      });

      if (!response.ok) {
        throw new Error(`HTTP ${response.status}: ${response.statusText}`);
      }

      return await response.json() as JsonRpcResponse;
    } catch (err) {
      if (err instanceof Error && err.name === 'AbortError') {
        throw new Error(`Tool call to ${this.device.name} timed out after ${timeoutMs / 1000}s`);
      }
      throw err;
    } finally {
      clearTimeout(timeout);
    }
  }

  async healthCheck(): Promise<boolean> {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 3000);

    try {
      const response = await fetch(`${this.baseUrl}/health`, {
        signal: controller.signal,
      });
      return response.ok;
    } catch {
      return false;
    } finally {
      clearTimeout(timeout);
    }
  }
}
