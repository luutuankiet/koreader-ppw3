import { spawnSync } from 'child_process';
import * as net from 'net';
import { buildRestartCommand, buildRestartScript, resolvePluginSource } from '../src/device-commands';
import { startDeviceListener } from '../src/device-link';
import { DeviceRegistry } from '../src/device-registry';
import { restartKoreader } from '../src/gateway-server';
import { closeServer, FakeDevice, Handler, listening } from './helpers/fake-device';

describe('resolvePluginSource', () => {
  const root = '/workspace';

  test('no source: <plugin>.koplugin at the workspace root (unchanged behaviour)', () => {
    expect(resolvePluginSource(root, 'koreader_mcp')).toEqual({ ok: true, srcPath: '/workspace/koreader_mcp.koplugin' });
    expect(resolvePluginSource(root, 'koreader_mcp', '')).toEqual({ ok: true, srcPath: '/workspace/koreader_mcp.koplugin' });
  });

  test('accepts a workspace-relative folder, such as one inside a git worktree', () => {
    expect(resolvePluginSource(root, 'syncedhistory', '.claude/worktrees/foo/syncedhistory.koplugin'))
      .toEqual({ ok: true, srcPath: '/workspace/.claude/worktrees/foo/syncedhistory.koplugin' });
  });

  test('accepts ".." that stays inside the workspace', () => {
    expect(resolvePluginSource(root, 'x', 'a/../x.koplugin')).toEqual({ ok: true, srcPath: '/workspace/x.koplugin' });
  });

  test('rejects absolute paths', () => {
    const r = resolvePluginSource(root, 'x', '/etc/x.koplugin');
    expect(r.ok).toBe(false);
    const inside = resolvePluginSource(root, 'x', '/workspace/x.koplugin');
    expect(inside.ok).toBe(false);
  });

  test('rejects ".." that escapes the workspace', () => {
    for (const src of ['..', '../x.koplugin', 'a/../../x.koplugin', '.claude/../../etc']) {
      const r = resolvePluginSource(root, 'x', src);
      expect(r.ok).toBe(false);
      if (!r.ok) expect(r.error).toMatch(/outside the workspace/);
    }
  });

  test('rejects the workspace root itself', () => {
    expect(resolvePluginSource(root, 'x', '.').ok).toBe(false);
  });
});

describe('buildRestartScript', () => {
  test('has no single quote, so buildRestartCommand can wrap it', () => {
    expect(buildRestartScript()).not.toContain("'");
    expect(buildRestartCommand()).toBe(`nohup sh -c '${buildRestartScript()}' > /tmp/ko_restart.log 2>&1 &`);
  });

  test('launches koreader.sh with --kual so the Kindle status bar stays paused', () => {
    expect(buildRestartScript()).toContain('./koreader.sh --kual');
  });

  test('wrapped command is valid sh', () => {
    const r = spawnSync('sh', ['-n', '-c', buildRestartCommand()]);
    expect(r.status).toBe(0);
  });

  test('kills no port: a live-mode device listens on nothing', () => {
    expect(buildRestartScript()).not.toMatch(/netstat|:\d{4}/);
    expect(buildRestartScript()).toContain('killall luajit');
  });
});

describe('restartKoreader against a fake device', () => {
  let listener: net.Server;
  let registry: DeviceRegistry;
  let port: number;
  const live: FakeDevice[] = [];

  beforeEach(async () => {
    registry = new DeviceRegistry();
    listener = startDeviceListener(registry, 0, '127.0.0.1');
    port = await listening(listener);
  });

  afterEach(async () => {
    for (const d of live.splice(0)) d.destroy();
    await closeServer(listener);
  });

  async function connect(handler: Handler): Promise<FakeDevice> {
    const d = new FakeDevice(port, handler);
    live.push(d);
    await d.hello('emu');
    return d;
  }

  test('reports online only when a NEW connection arrives after the restart command', async () => {
    const commands: string[] = [];
    await connect((_method, params) => {
      commands.push(params.command);
      if (params.command.startsWith('nohup')) {
        // The restart: this connection dies, a new one arrives a little later.
        setTimeout(() => {
          live[0].destroy();
          setTimeout(() => { void connect(() => ({ exit_code: 0 })); }, 10);
        }, 10);
      }
      return { exit_code: 0, stdout: '' };
    });
    const result = await restartKoreader(registry, 'emu', 2000);
    const data = JSON.parse((result.content[0] as { text: string }).text);
    expect(data).toEqual({ device: 'emu', restarted: true, status: 'online' });
    expect(commands.find((c) => c.startsWith('nohup'))).toBe(buildRestartCommand());
    expect(live).toHaveLength(2);
  });

  test('reports restart_timeout when the old connection stays and no new one arrives', async () => {
    await connect(() => ({ exit_code: 0, stdout: '' }));
    const result = await restartKoreader(registry, 'emu', 30);
    const data = JSON.parse((result.content[0] as { text: string }).text);
    expect(data).toEqual({ device: 'emu', restarted: false, status: 'restart_timeout' });
  });
});
