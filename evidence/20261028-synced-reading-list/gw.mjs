#!/usr/bin/env node
// Call one kindle-gateway MCP tool from the shell.
//   node gw.mjs list                       list the gateway's tools
//   node gw.mjs <tool> '<json args>' [out] call a tool; images are saved to [out] (default ./gw-shot-<ts>.png)
// Example: node gw.mjs screenshot '{"device":"emu"}' /path/shot.png
// Env: GATEWAY_URL (default http://thinkpad:9999/mcp)
import { createRequire } from 'node:module';
import fs from 'node:fs';
const require = createRequire('/home/$KOSYNC_USER/dev/koreader-ppw3/kindle-gateway/package.json');
const { Client } = require('@modelcontextprotocol/sdk/client/index.js');
const { StreamableHTTPClientTransport } = require('@modelcontextprotocol/sdk/client/streamableHttp.js');

const url = new URL(process.env.GATEWAY_URL || 'http://thinkpad:9999/mcp');
const [tool, rawArgs = '{}', out] = process.argv.slice(2);
if (!tool) { console.error('usage: gw.mjs list | <tool> <json> [out.png]'); process.exit(2); }

const client = new Client({ name: 'gw-cli', version: '1.0.0' });
await client.connect(new StreamableHTTPClientTransport(url));
try {
  if (tool === 'list') {
    const { tools } = await client.listTools();
    for (const t of tools) console.log(`${t.name}: ${t.description}\n  args: ${JSON.stringify(t.inputSchema.properties || {})}`);
  } else {
    const res = await client.callTool({ name: tool, arguments: JSON.parse(rawArgs) }, undefined, { timeout: 300000 });
    let n = 0;
    for (const c of res.content || []) {
      if (c.type === 'image') {
        const file = out ? (n ? out.replace(/(\.png)?$/, `-${n}.png`) : out) : `gw-shot-${Date.now()}-${n}.png`;
        fs.writeFileSync(file, Buffer.from(c.data, 'base64'));
        console.log(`[image saved: ${file}]`);
        n++;
      } else if (c.type === 'text') console.log(c.text);
      else console.log(JSON.stringify(c));
    }
    if (res.isError) process.exitCode = 1;
  }
} finally { await client.close(); }
