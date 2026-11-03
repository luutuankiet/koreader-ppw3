/**
 * The shell command that restarts KOReader on a device, shared by the Node gateway and the
 * Cloudflare Worker. Keep this file free of Node imports: kindle-gateway-worker imports it by
 * relative path.
 */

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
