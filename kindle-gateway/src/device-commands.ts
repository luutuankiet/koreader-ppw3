import * as path from 'path';

export { buildRestartCommand, buildRestartScript } from './restart-command';

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
