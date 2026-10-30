import * as path from 'path';

/**
 * Shell command run on the device (through koreader_mcp's run_command) to restart KOReader.
 * It detaches and sleeps first so the run_command reply gets out before KOReader dies.
 */
export function buildRestartCommand(): string {
  return `nohup sh -c '${buildRestartScript()}' > /tmp/ko_restart.log 2>&1 &`;
}

/** The script buildRestartCommand detaches. Contains no single quote, so it can be wrapped in one. */
export function buildRestartScript(): string {
  return [
    'sleep 2',
    'killall luajit',
    'sleep 5',
    // --kual makes koreader.sh SIGSTOP the Kindle window manager (FW >= 5.7.2). Without it the
    // Kindle status bar's clock and WiFi icon repaint over KOReader every minute.
    'cd /mnt/us/koreader && ./koreader.sh --kual',
  ].join('; ');
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
