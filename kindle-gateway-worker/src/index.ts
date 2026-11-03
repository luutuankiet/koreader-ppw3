import { bearerMatches } from './auth';
import { inboxRoute } from './inbox';

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
  // MCP is stateless: POST carries every exchange; GET and DELETE get the SDK's 405.
  'POST /mcp': mcp,
  'GET /mcp': mcp,
  'DELETE /mcp': mcp,
};

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const { pathname } = new URL(request.url);
    // The one prefix route: the device and file name are part of the path.
    if (pathname.startsWith('/inbox/')) return inboxRoute(request, env);
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

/** The agent key is checked here, before any MCP work; the hub does the rest. */
async function mcp(request: Request, env: Env): Promise<Response> {
  if (!(await bearerMatches(request.headers.get('Authorization'), env.AGENT_KEY))) {
    return new Response('unauthorized', { status: 401, headers: { 'WWW-Authenticate': 'Bearer' } });
  }
  return hub(env).fetch(request);
}
