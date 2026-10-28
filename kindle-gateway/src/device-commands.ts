import * as path from 'path';

/**
 * Shell command run on the device (through koreader_mcp's run_command) to restart KOReader.
 * It detaches and sleeps first so the run_command reply gets out before KOReader dies.
 * The kill step targets whatever listens on the device's own koreader_mcp port: the emulator
 * listens on 8889 and shares its host's network, where 8888 may belong to something else.
 */
export function buildRestartCommand(port: number): string {
  return `nohup sh -c '${buildRestartScript(port)}' > /tmp/ko_restart.log 2>&1 &`;
}

/** The script buildRestartCommand detaches. Contains no single quote, so it can be wrapped in one. */
export function buildRestartScript(port: number): string {
  if (!Number.isInteger(port) || port <= 0 || port > 65535) {
    throw new Error(`Invalid device port: ${port}`);
  }
  // Inner script, run by `sh -c '...'`. Column 4 of `netstat -tlnp` is the local address,
  // the last column is PID/program ("-" for processes we cannot see, skipped).
  const inner = [
    'sleep 2',
    `PID=$(netstat -tlnp 2>/dev/null | awk "\\$4 ~ /:${port}\\$/ && \\$NF ~ /^[0-9]+\\// {print \\$NF}" | cut -d/ -f1 | head -n 1)`,
    '[ -n "$PID" ] && kill -9 $PID',
    'killall luajit',
    'sleep 5',
    'cd /mnt/us/koreader && ./koreader.sh',
  ].join('; ');
  return inner;
}

export type SourceResolution =
  | { ok: true; srcPath: string }
  | { ok: false; error: string };

/**
 * Where deploy_plugin reads a plugin from. Without `source` it is `<root>/<plugin>.koplugin`.
 * With `source` it is that workspace-relative folder (for example a plugin inside a git
 * worktree under `.claude/worktrees/`), which must stay inside `root`.
 */
export function resolvePluginSource(root: string, plugin: string, source?: string): SourceResolution {
  const workspace = path.resolve(root);
  if (source === undefined || source === '') {
    return { ok: true, srcPath: path.join(workspace, `${plugin}.koplugin`) };
  }
  if (path.isAbsolute(source)) {
    return { ok: false, error: `source must be relative to the workspace, got absolute path '${source}'` };
  }
  const resolved = path.resolve(workspace, source);
  const rel = path.relative(workspace, resolved);
  if (rel === '' || rel === '..' || rel.startsWith(`..${path.sep}`) || path.isAbsolute(rel)) {
    return { ok: false, error: `source '${source}' resolves outside the workspace` };
  }
  return { ok: true, srcPath: resolved };
}
