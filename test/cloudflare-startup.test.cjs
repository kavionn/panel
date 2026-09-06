const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const egg = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'nodejs-egg.json'), 'utf8'));
const helperSource = fs.readFileSync(path.join(__dirname, '..', 'ptero-startup.sh'), 'utf8')
  .replace(/\r\n/g, '\n').trimEnd();
const embeddedHelperMatch = egg.scripts.installation.script.replace(/\r\n/g, '\n')
  .match(/cat >"\$\{STARTUP_HELPER_DIR\}\/startup\.sh" <<'PTERO_STARTUP'\n([\s\S]*?)\nPTERO_STARTUP/);
assert.ok(embeddedHelperMatch, 'installation script must embed the generated startup helper');
const embeddedHelper = embeddedHelperMatch[1].trimEnd();
const bash = process.env.BASH_TEST_BINARY || (process.platform === 'win32'
  ? 'C:/Program Files/Git/bin/bash.exe' : 'bash');
const shellPath = value => value.replace(/\\/g, '/').replace(/^([A-Za-z]):/, (_, drive) => '/' + drive.toLowerCase());

function runStartup({ enabled = '1', token = 'test-only-token', installed = true,
  ytdlpInstalled = true, failDownload = false, failRun = false,
  startupCommand = 'echo MOCK_APP_STARTED' } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'egg-cloudflare-test-'));
  try {
    const binaryDir = path.join(root, '.local', 'bin');
    fs.mkdirSync(binaryDir, { recursive: true });
    const mockBinary = path.join(root, 'mock-cloudflared');
    fs.writeFileSync(mockBinary, '#!/bin/bash\nif [[ "$1" == "--version" ]]; then echo mock-version; exit 0; fi\n[[ "$TUNNEL_TOKEN" == "test-only-token" ]] || exit 9\necho mock-connector-output\nexit ' + (failRun ? '7' : '0') + '\n', { mode: 0o755 });
    if (installed) fs.copyFileSync(mockBinary, path.join(binaryDir, 'cloudflared'));
    const mockYtdlpBinary = path.join(root, 'mock-yt-dlp');
    fs.writeFileSync(mockYtdlpBinary, '#!/bin/bash\nif [[ "$1" == "--version" ]]; then echo mock-yt-dlp-version; fi\nexit 0\n', { mode: 0o755 });
    if (ytdlpInstalled) fs.copyFileSync(mockYtdlpBinary, path.join(binaryDir, 'yt-dlp'));
    const startup = embeddedHelper.replaceAll('/home/container', shellPath(root));
    const prelude = `curl() { ${failDownload ? 'return 22;' : 'local args="$*"; while [[ "$1" != "-o" ]]; do shift; done; if [[ "$args" == *"yt-dlp"* ]]; then cp "$MOCK_YTDLP_BINARY" "$2"; else cp "$MOCK_BINARY" "$2"; fi;'} }; export -f curl;\n`;
    const result = spawnSync(bash, ['-s'], {
      input: prelude + startup + '; wait\n', encoding: 'utf8', cwd: root,
      env: { ...process.env, CLOUDFLARE_TUNNEL_ENABLED: enabled, TUNNEL_TOKEN: token,
        NODE_PACKAGES: '', UNNODE_PACKAGES: '', AUTO_UPDATE: '0',
        STARTUP_COMMAND: startupCommand, MOCK_BINARY: shellPath(mockBinary),
        MOCK_YTDLP_BINARY: shellPath(mockYtdlpBinary) }, timeout: 15000,
    });
    assert.ifError(result.error);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /MOCK_APP_STARTED/);
    assert.ok(!result.stdout.includes('test-only-token'));
    const logPath = path.join(root, '.cloudflare', 'tunnel.log');
    const log = fs.existsSync(logPath) ? fs.readFileSync(logPath, 'utf8') : null;
    assert.ok(!log?.includes('test-only-token'));
    return { log, stdout: result.stdout, installed: fs.existsSync(path.join(binaryDir, 'cloudflared')),
      ytdlpInstalled: fs.existsSync(path.join(binaryDir, 'yt-dlp')),
      partials: fs.readdirSync(binaryDir).filter(name => name.includes('.download.')) };
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
}

test('egg startup, generated helper, and installation script have valid Bash syntax', () => {
  for (const script of [egg.startup, embeddedHelper, egg.scripts.installation.script]) {
    const result = spawnSync(bash, ['-n'], { input: script, encoding: 'utf8' });
    assert.ifError(result.error);
    assert.equal(result.status, 0, result.stderr);
  }
});
test('egg keeps startup short and embeds the reviewed helper verbatim', () => {
  assert.equal(egg.startup, 'bash /home/container/.ptero/startup.sh');
  assert.equal(embeddedHelper, helperSource);
  assert.match(egg.scripts.installation.script, /chmod 755 "\$\{STARTUP_HELPER_DIR\}\/startup\.sh"/);
});
test('disabled tunnel does not create logs or install a binary', () => {
  const result = runStartup({ enabled: '0', installed: false });
  assert.equal(result.log, null);
  assert.equal(result.installed, false);
});
test('missing token creates an actionable log and allows the app to start', () => {
  assert.match(runStartup({ token: '' }).log, /TUNNEL_TOKEN is empty/);
});
test('existing binary receives token through environment and logs its output', () => {
  assert.match(runStartup().log, /mock-connector-output/);
});
test('theme-style true and on values enable the tunnel', () => {
  assert.match(runStartup({ enabled: 'true' }).log, /mock-connector-output/);
  assert.match(runStartup({ enabled: 'on' }).log, /mock-connector-output/);
});
test('missing binary is downloaded on startup without reinstalling the server', () => {
  const result = runStartup({ installed: false });
  assert.equal(result.installed, true);
  assert.match(result.log, /mock-connector-output/);
  assert.deepEqual(result.partials, []);
});
test('missing yt-dlp is downloaded and available to the application', () => {
  const result = runStartup({
    ytdlpInstalled: false,
    startupCommand: 'command -v yt-dlp; echo MOCK_APP_STARTED',
  });
  assert.equal(result.ytdlpInstalled, true);
  assert.match(result.stdout, /yt-dlp installed successfully/);
  assert.match(result.stdout, /\.local\/bin\/yt-dlp/);
  assert.deepEqual(result.partials, []);
});
test('failed downloads leave no installed or partial binary', () => {
  const result = runStartup({ installed: false, failDownload: true });
  assert.equal(result.installed, false);
  assert.deepEqual(result.partials, []);
  assert.match(result.log, /download failed/);
});
test('connector failure appears in console and log', () => {
  const result = runStartup({ failRun: true });
  assert.match(result.log, /exited \(code 7\)/);
  assert.match(result.stdout, /exited \(code 7\)/);
});
