import { bearerMatches } from './auth';

export { Hub } from './hub';

/**
 * The Worker only authenticates and forwards: the free plan allows 10 ms of CPU per request,
 * so every JSON and WebSocket job happens in the hub object. Add a route by adding a line to
 * `routes`.
 */
type Handler = (request: Request, env: Env) => Promise<Response>;

const routes: Record<string, Handler> = {
  'GET /health': async () => new Response('ok'),
  'GET /device': deviceUpgrade,
  // Test-only routes for driving the hub from outside; off unless ENABLE_DEBUG_ROUTES is "1".
  'GET /debug/devices': debugRoute(async (_req, env) => Response.json(await hub(env).listDevices())),
  'POST /debug/call': debugRoute(debugCall),
};

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const { pathname } = new URL(request.url);
    const handler = routes[`${request.method} ${pathname}`];
    return handler ? handler(request, env) : new Response('not found', { status: 404 });
  },
} satisfies ExportedHandler<Env>;

export function hub(env: Env): DurableObjectStub<import('./hub').Hub> {
  return env.HUB.get(env.HUB.idFromName('hub'));
}

async function deviceUpgrade(request: Request, env: Env): Promise<Response> {
  if (!(await bearerMatches(request.headers.get('Authorization'), env.DEVICE_KEY))) {
    return new Response('unauthorized', { status: 401 });
  }
  if (request.headers.get('Upgrade')?.toLowerCase() !== 'websocket') {
    return new Response('expected a WebSocket upgrade', { status: 426 });
  }
  return hub(env).fetch(request);
}

function debugRoute(handler: Handler): Handler {
  return async (request, env) => {
    if (env.ENABLE_DEBUG_ROUTES !== '1') return new Response('not found', { status: 404 });
    if (!(await bearerMatches(request.headers.get('Authorization'), env.AGENT_KEY))) {
      return new Response('unauthorized', { status: 401 });
    }
    return handler(request, env);
  };
}

/** Body `{device, method, params?, timeoutMs?}`; answers the device's reply or `{error}`. */
async function debugCall(request: Request, env: Env): Promise<Response> {
  const body = (await request.json()) as { device: string; method: string; params?: Record<string, unknown>; timeoutMs?: number };
  try {
    const reply = await hub(env).call(body.device, body.method, body.params, body.timeoutMs);
    return new Response(JSON.stringify(reply), { headers: { 'Content-Type': 'application/json' } });
  } catch (err) {
    return Response.json({ error: (err as Error).message }, { status: 502 });
  }
}
