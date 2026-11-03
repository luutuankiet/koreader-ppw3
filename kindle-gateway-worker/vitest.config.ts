import { cloudflareTest } from '@cloudflare/vitest-plugin';
import { defineConfig } from 'vitest/config';

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: './wrangler.jsonc' },
      miniflare: {
        bindings: {
          DEVICE_KEY: 'test-device-key',
          AGENT_KEY: 'test-agent-key',
          ENABLE_DEBUG_ROUTES: '1',
        },
      },
    }),
  ],
});
