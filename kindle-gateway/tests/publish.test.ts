import { execFileSync, spawnSync } from 'child_process';
import crypto from 'crypto';
import fs from 'fs';
import os from 'os';
import path from 'path';

// Runs scripts/publish.sh against a throwaway plugin; needs bash, git, GNU tar and python3.
const PUBLISH = path.resolve(__dirname, '../../scripts/publish.sh');

function write(file: string, content: string) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, content);
}

function publish(pkgDir: string, ...args: string[]) {
  return spawnSync('bash', [PUBLISH, ...args], { env: { ...process.env, PKG_DIR: pkgDir }, encoding: 'utf8' });
}

const tarList = (archive: string) =>
  execFileSync('tar', ['-tzf', archive], { encoding: 'utf8' }).trim().split('\n').sort();

describe('scripts/publish.sh', () => {
  let root: string;
  let pkgDir: string;
  let plugin: string;

  beforeEach(() => {
    root = fs.mkdtempSync(path.join(os.tmpdir(), 'publish-'));
    pkgDir = path.join(root, 'pkg');
    fs.mkdirSync(pkgDir);
    plugin = path.join(root, 'src', 'demo.koplugin');
    write(path.join(plugin, '_meta.lua'), [
      'local _ = require("gettext")',
      'return {',
      '    name = "demo",',
      '    fullname = _("Demo plugin"),',
      '    description = _([[Does a',
      '    demo thing.]]),',
      '    version = "1.2.0",',
      '    min_koreader = "v2024.11",',
      '}',
    ].join('\n'));
    write(path.join(plugin, 'main.lua'), 'return {}\n');
    write(path.join(plugin, 'lib', 'helper.lua'), 'return 1\n');
    write(path.join(plugin, 'secret_config.lua'), 'return { password = "x" }\n');
    write(path.join(plugin, '.gitignore'), 'secret_config.lua\n');
    write(path.join(plugin, 'test_main.lua'), '-- test\n');
    write(path.join(plugin, 'run_tests.sh'), '#!/bin/sh\n');
    write(path.join(plugin, 'tests', 'fixture.lua'), '-- fixture\n');
    write(path.join(plugin, 'NOTES.md'), 'dev notes\n');
    execFileSync('git', ['init', '-q', plugin]);
  });

  afterEach(() => fs.rmSync(root, { recursive: true, force: true }));

  it('packs exactly the plugin folder: no tests, dev files or gitignored config', () => {
    const r = publish(pkgDir, plugin);
    expect(r.stderr).toBe('');
    expect(r.status).toBe(0);
    expect(tarList(path.join(pkgDir, 'demo-1.2.0.tar.gz'))).toEqual([
      'demo.koplugin/',
      'demo.koplugin/_meta.lua',
      'demo.koplugin/lib/',
      'demo.koplugin/lib/helper.lua',
      'demo.koplugin/main.lua',
    ]);
  });

  it('unpacks to the same bytes as the source files', () => {
    publish(pkgDir, plugin);
    const out = path.join(root, 'out');
    fs.mkdirSync(out);
    execFileSync('tar', ['-xzf', path.join(pkgDir, 'demo-1.2.0.tar.gz'), '-C', out]);
    expect(fs.readdirSync(out)).toEqual(['demo.koplugin']);
    for (const f of ['_meta.lua', 'main.lua', 'lib/helper.lua']) {
      expect(fs.readFileSync(path.join(out, 'demo.koplugin', f)).equals(fs.readFileSync(path.join(plugin, f)))).toBe(true);
    }
  });

  it('writes an index entry with size, sha256 and the _meta.lua fields', () => {
    publish(pkgDir, plugin);
    const archive = fs.readFileSync(path.join(pkgDir, 'demo-1.2.0.tar.gz'));
    const index = JSON.parse(fs.readFileSync(path.join(pkgDir, 'index.json'), 'utf8'));
    expect(index).toEqual({
      format: 1,
      plugins: [{
        name: 'demo',
        version: '1.2.0',
        file: 'demo-1.2.0.tar.gz',
        size: archive.length,
        sha256: crypto.createHash('sha256').update(archive).digest('hex'),
        description: 'Does a demo thing.',
        fullname: 'Demo plugin',
        min_koreader: 'v2024.11',
      }],
    });
  });

  it('builds the same bytes twice, and refuses changed content under the same version', () => {
    publish(pkgDir, plugin);
    const first = fs.readFileSync(path.join(pkgDir, 'demo-1.2.0.tar.gz'));
    const again = publish(pkgDir, plugin);
    expect(again.status).toBe(0);
    expect(again.stdout).toContain('unchanged');
    expect(fs.readFileSync(path.join(pkgDir, 'demo-1.2.0.tar.gz')).equals(first)).toBe(true);

    write(path.join(plugin, 'main.lua'), 'return { changed = true }\n');
    const clash = publish(pkgDir, plugin);
    expect(clash.status).not.toBe(0);
    expect(clash.stderr).toContain('bump version');
    expect(publish(pkgDir, '--force', plugin).status).toBe(0);
  });

  it('lists only the highest version of each plugin', () => {
    publish(pkgDir, plugin);
    const meta = path.join(plugin, '_meta.lua');
    fs.writeFileSync(meta, fs.readFileSync(meta, 'utf8').replace('"1.2.0"', '"1.10.0"'));
    publish(pkgDir, plugin);
    const index = JSON.parse(fs.readFileSync(path.join(pkgDir, 'index.json'), 'utf8'));
    expect(index.plugins.map((p: { file: string }) => p.file)).toEqual(['demo-1.10.0.tar.gz']);
    expect(fs.existsSync(path.join(pkgDir, 'demo-1.2.0.tar.gz'))).toBe(true);
  });

  it('refuses a plugin without a version', () => {
    const meta = path.join(plugin, '_meta.lua');
    fs.writeFileSync(meta, fs.readFileSync(meta, 'utf8').replace('    version = "1.2.0",\n', ''));
    const r = publish(pkgDir, plugin);
    expect(r.status).not.toBe(0);
    expect(r.stderr).toContain('no version');
    expect(fs.readdirSync(pkgDir)).toEqual([]);
  });
});
