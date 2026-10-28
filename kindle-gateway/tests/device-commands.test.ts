import { spawn, spawnSync } from 'child_process';
import * as fs from 'fs';
import http from 'http';
import * as os from 'os';
import * as path from 'path';
import { buildRestartCommand, buildRestartScript, resolvePluginSource } from '../src/device-commands';
import { DeviceRegistry } from '../src/device-registry';
import { restartKoreader } from '../src/gateway-server';

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
  test('targets the given port and never the hardcoded 8888', () => {
    const script = buildRestartScript(8889);
    expect(script).toContain(':8889');
    expect(script).not.toContain('8888');
    expect(buildRestartScript(8888)).toContain(':8888');
  });

  test('has no single quote, so buildRestartCommand can wrap it', () => {
    expect(buildRestartScript(8889)).not.toContain("'");
    expect(buildRestartCommand(8889)).toBe(`nohup sh -c '${buildRestartScript(8889)}' > /tmp/ko_restart.log 2>&1 &`);
  });

  test('launches koreader.sh with --kual so the Kindle status bar stays paused', () => {
    expect(buildRestartScript(8888)).toContain('./koreader.sh --kual');
  });

  test('rejects a bad port', () => {
    expect(() => buildRestartScript(0)).toThrow();
    expect(() => buildRestartScript(1.5)).toThrow();
  });

  test('wrapped command is valid sh', () => {
    const r = spawnSync('sh', ['-n', '-c', buildRestartCommand(8889)]);
    expect(r.status).toBe(0);
  });

  // Runs the real script with stand-in netstat/killall/sleep on PATH. netstat lists a process we
  // cannot see on 8888 (the emulator's host case), our victim on 8889, and a longer port 88890.
  test('kills only the process listening on the device port', async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'restart-'));
    const victim = spawn('/bin/sleep', ['30']);
    const decoy = spawn('/bin/sleep', ['30']);
    try {
      const netstat = [
        'Active Internet connections (only servers)',
        'Proto Recv-Q Send-Q Local Address           Foreign Address         State       PID/Program name',
        'tcp6       0      0 :::8888                 :::*                    LISTEN      -',
        `tcp        0      0 0.0.0.0:88890           0.0.0.0:*               LISTEN      ${decoy.pid}/other`,
        `tcp        0      0 0.0.0.0:8889            0.0.0.0:*               LISTEN      ${victim.pid}/./luajit`,
      ].join('\n');
      fs.writeFileSync(path.join(dir, 'netstat'), `#!/bin/sh\ncat <<'EOF'\n${netstat}\nEOF\n`, { mode: 0o755 });
      fs.writeFileSync(path.join(dir, 'killall'), '#!/bin/sh\necho "killall $*" >> "$LOG"\n', { mode: 0o755 });
      fs.writeFileSync(path.join(dir, 'sleep'), '#!/bin/sh\nexit 0\n', { mode: 0o755 });
      const log = path.join(dir, 'log');
      const victimExit = new Promise<NodeJS.Signals | null>((resolve) => victim.on('exit', (_c, sig) => resolve(sig)));

      spawnSync('sh', ['-c', buildRestartScript(8889)], {
        env: { ...process.env, PATH: `${dir}:${process.env.PATH}`, LOG: log },
      });

      expect(await victimExit).toBe('SIGKILL');
      expect(decoy.exitCode).toBeNull();
      expect(decoy.signalCode).toBeNull();
      expect(fs.readFileSync(log, 'utf8')).toContain('killall luajit');
    } finally {
      victim.kill('SIGKILL');
      decoy.kill('SIGKILL');
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe('restartKoreader against a fake device', () => {
  const PORT = 18889;
  const commands: string[] = [];
  let fake: http.Server;

  beforeAll(async () => {
    fake = http.createServer((req, res) => {
      let body = '';
      req.on('data', (c) => { body += c; });
      req.on('end', () => {
        const rpc = JSON.parse(body);
        if (rpc.method === 'run_command') commands.push(rpc.params.command);
        const result = rpc.method === 'run_command' ? { exit_code: 0, stdout: '' } : { ok: true };
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ jsonrpc: '2.0', id: rpc.id, result }));
      });
    });
    await new Promise<void>((resolve) => fake.listen(PORT, '127.0.0.1', resolve));
  });

  afterAll(async () => {
    await new Promise<void>((resolve) => fake.close(() => resolve()));
  });

  test('sends the kill step for the device port and reports healthy', async () => {
    const registry = new DeviceRegistry();
    registry.register('emu', '127.0.0.1', PORT, ['run_command']);
    const result = await restartKoreader(registry, 'emu', 10);
    const data = JSON.parse((result.content[0] as { text: string }).text);
    expect(data).toEqual({ device: 'emu', restarted: true, status: 'online' });

    const restart = commands.find((c) => c.startsWith('nohup'));
    expect(restart).toBe(buildRestartCommand(PORT));
    expect(restart).toContain(`:${PORT}`);
    expect(restart).not.toContain('8888');
    expect(registry.get('emu')!.status).toBe('online');
  });
});
