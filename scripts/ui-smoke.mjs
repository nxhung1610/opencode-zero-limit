#!/usr/bin/env node

import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const outputDir = path.resolve(projectRoot, process.env.UI_SMOKE_OUT ?? 'artifacts/ui-smoke');
const startupTimeoutMs = 20_000;

function findChrome() {
  if (process.env.CHROME_BIN) return process.env.CHROME_BIN;

  const candidates = process.platform === 'darwin'
    ? [
        '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
        '/Applications/Chromium.app/Contents/MacOS/Chromium',
      ]
    : process.platform === 'win32'
      ? [
          path.join(process.env.PROGRAMFILES ?? 'C:\\Program Files', 'Google/Chrome/Application/chrome.exe'),
          path.join(process.env['PROGRAMFILES(X86)'] ?? 'C:\\Program Files (x86)', 'Google/Chrome/Application/chrome.exe'),
        ]
      : [];

  for (const candidate of candidates) {
    if (fs.existsSync(candidate)) return candidate;
  }

  const binaries = process.platform === 'win32'
    ? ['chrome.exe', 'chromium.exe']
    : ['google-chrome', 'google-chrome-stable', 'chromium', 'chromium-browser'];
  const locator = process.platform === 'win32' ? 'where.exe' : 'which';
  for (const binary of binaries) {
    const result = spawnSync(locator, [binary], { encoding: 'utf8' });
    const candidate = result.status === 0 ? result.stdout.trim().split(/\r?\n/)[0] : '';
    if (candidate) return candidate;
  }

  throw new Error('Chrome/Chromium not found. Install a browser or set CHROME_BIN to its executable path.');
}

async function freePort() {
  const server = net.createServer();
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const { port } = server.address();
  await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
  return port;
}

async function waitUntil(check, label, timeoutMs = startupTimeoutMs) {
  const deadline = Date.now() + timeoutMs;
  let lastError;
  while (Date.now() < deadline) {
    try {
      const result = await check();
      if (result) return result;
    } catch (error) {
      lastError = error;
    }
    await sleep(100);
  }
  throw new Error(`Timed out waiting for ${label}${lastError ? `: ${lastError.message}` : ''}`);
}

async function stopProcess(child) {
  if (!child || child.exitCode !== null || child.signalCode !== null) return;
  const exited = new Promise((resolve) => child.once('close', () => resolve(true)));
  const signal = (name) => {
    try {
      if (process.platform === 'win32') child.kill();
      else if (child.pid) process.kill(-child.pid, name);
      else child.kill(name);
    } catch (error) {
      if (error.code !== 'ESRCH') child.kill(name);
    }
  };
  signal('SIGTERM');
  if (!await Promise.race([exited, sleep(2_000).then(() => false)])) {
    signal('SIGKILL');
    await Promise.race([exited, sleep(2_000).then(() => false)]);
  }
}

async function removeTempDir(directory) {
  const deadline = Date.now() + 3_000;
  while (true) {
    try {
      fs.rmSync(directory, { recursive: true, force: true });
      return;
    } catch (error) {
      if (!['ENOTEMPTY', 'EBUSY'].includes(error.code) || Date.now() >= deadline) throw error;
      await sleep(100);
    }
  }
}

const chromePath = findChrome();
const appPort = await freePort();
const cdpPort = await freePort();
const baseUrl = `http://127.0.0.1:${appPort}/`;
const cdpUrl = `http://127.0.0.1:${cdpPort}`;
const profileDir = fs.mkdtempSync(path.join(os.tmpdir(), 'relaydock-ui-smoke-'));
const viteBin = path.join(projectRoot, 'node_modules/vite/bin/vite.js');
const vite = spawn(process.execPath, [viteBin, '--host', '127.0.0.1', '--port', String(appPort), '--strictPort'], {
  cwd: projectRoot,
  stdio: 'ignore',
  windowsHide: true,
  detached: process.platform !== 'win32',
});
const chrome = spawn(chromePath, [
  '--headless=new',
  '--no-sandbox',
  '--disable-gpu',
  '--no-first-run',
  '--remote-debugging-address=127.0.0.1',
  `--remote-debugging-port=${cdpPort}`,
  '--remote-allow-origins=*',
  `--user-data-dir=${profileDir}`,
  'about:blank',
], { stdio: 'ignore', windowsHide: true, detached: process.platform !== 'win32' });

let ws;
try {
  await waitUntil(async () => {
    const response = await fetch(baseUrl);
    return response.ok;
  }, 'Vite dev server');
  const targets = await waitUntil(async () => {
    const response = await fetch(`${cdpUrl}/json/list`);
    if (!response.ok) return false;
    const items = await response.json();
    return items.find((item) => item.type === 'page');
  }, 'Chrome DevTools page');

  ws = new WebSocket(targets.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    ws.addEventListener('open', resolve, { once: true });
    ws.addEventListener('error', reject, { once: true });
  });

  let nextId = 0;
  const pending = new Map();
  ws.addEventListener('message', ({ data }) => {
    const message = JSON.parse(data);
    if (!message.id) return;
    const request = pending.get(message.id);
    if (!request) return;
    pending.delete(message.id);
    if (message.error) request.reject(new Error(message.error.message));
    else request.resolve(message.result);
  });

  function cdp(method, params = {}) {
    const id = ++nextId;
    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject });
      ws.send(JSON.stringify({ id, method, params }));
    });
  }

  async function evaluate(expression) {
    const response = await cdp('Runtime.evaluate', {
      expression,
      returnByValue: true,
      awaitPromise: true,
    });
    if (response.exceptionDetails) {
      throw new Error(response.exceptionDetails.exception?.description ?? response.exceptionDetails.text);
    }
    return response.result.value;
  }

  async function waitFor(expression, label, timeoutMs = 8_000) {
    return waitUntil(async () => evaluate(expression), label, timeoutMs);
  }

  async function click(selector) {
    const clicked = await evaluate(`(() => { const el = document.querySelector(${JSON.stringify(selector)}); if (!el) return false; el.click(); return true; })()`);
    if (!clicked) throw new Error(`Could not click ${selector}`);
  }

  async function clickButton(text) {
    const clicked = await evaluate(`(() => { const button = [...document.querySelectorAll('button')].find((item) => item.innerText.trim() === ${JSON.stringify(text)}); if (!button) return false; button.click(); return true; })()`);
    if (!clicked) throw new Error(`Could not click button: ${text}`);
  }

  async function ensureTheme(theme) {
    const expectedLabel = `Theme is ${theme}; click to cycle theme`;
    for (let attempt = 0; attempt < 3; attempt += 1) {
      const current = await evaluate(`document.querySelector('button[aria-label^="Theme is"]')?.getAttribute('aria-label')`);
      const resolvedDark = await evaluate(`document.documentElement.classList.contains('dark')`);
      if (current === expectedLabel && resolvedDark === (theme === 'dark')) return;
      await click('button[aria-label^="Theme is"]');
      await waitFor(`document.querySelector('button[aria-label^="Theme is"]')?.getAttribute('aria-label') !== ${JSON.stringify(current)}`, `${theme} theme cycle`);
      await waitFor(`document.documentElement.classList.contains('dark') === ${theme === 'dark'}`, `${theme} resolved theme`);
    }
    throw new Error(`Could not set explicit ${theme} theme`);
  }

  async function captureScreenshot(filePath) {
    const image = await cdp('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false });
    fs.writeFileSync(filePath, Buffer.from(image.data, 'base64'));
  }

  async function traverseKeyboard(pageTitle, viewportName, theme) {
    await click(`nav[aria-label="Primary navigation"] button[title="${pageTitle}"]`);
    await waitFor(`document.querySelector('main h1')?.innerText.includes(${JSON.stringify(pageTitle)})`, `${pageTitle} for keyboard traversal`);
    await evaluate('document.activeElement?.blur(); window.__UI_SMOKE_TAB_SEEN = []');
    const focused = [];
    for (let index = 0; index < 80; index += 1) {
      await cdp('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Tab', code: 'Tab', windowsVirtualKeyCode: 9, nativeVirtualKeyCode: 9 });
      await cdp('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Tab', code: 'Tab', windowsVirtualKeyCode: 9, nativeVirtualKeyCode: 9 });
      const item = await evaluate(`(() => {
        const el = document.activeElement;
        if (window.__UI_SMOKE_TAB_SEEN.includes(el)) return { repeat: true };
        window.__UI_SMOKE_TAB_SEEN.push(el);
        const style = getComputedStyle(el);
        const labelledBy = el.getAttribute('aria-labelledby')?.split(/\\s+/).map((id) => document.getElementById(id)?.innerText.trim()).filter(Boolean).join(' ');
        const label = el.id ? document.querySelector('label[for="' + CSS.escape(el.id) + '"]')?.innerText.trim() : '';
        const name = el.getAttribute('aria-label') || labelledBy || label || el.innerText?.trim() || el.value || el.getAttribute('title') || '';
        const focusVisible = el.matches(':focus-visible');
        const hasVisibleOutline = style.outlineStyle !== 'none' && Number.parseFloat(style.outlineWidth) > 0;
        const canvas = document.createElement('canvas');
        canvas.width = canvas.height = 1;
        const context = canvas.getContext('2d', { willReadFrequently: true });
        const parseColor = (value) => {
          context.clearRect(0, 0, 1, 1);
          context.fillStyle = 'transparent'; context.fillStyle = value; context.fillRect(0, 0, 1, 1);
          const [red, green, blue, alpha] = context.getImageData(0, 0, 1, 1).data;
          return { rgb: [red, green, blue], alpha: alpha / 255 };
        };
        const blend = (front, back) => {
          const alpha = front.alpha + back.alpha * (1 - front.alpha);
          return { rgb: front.rgb.map((value, index) => (value * front.alpha + back.rgb[index] * back.alpha * (1 - front.alpha)) / alpha), alpha };
        };
        let backdrop = { rgb: [255, 255, 255], alpha: 1 };
        let ancestorOpacity = 1;
        let hasImageBackground = false;
        const ancestors = [];
        for (let node = el.parentElement; node; node = node.parentElement) ancestors.unshift(node);
        for (const node of ancestors) {
          const ancestorStyle = getComputedStyle(node);
          const layerOpacity = Number.parseFloat(ancestorStyle.opacity);
          const nextOpacity = Number.isFinite(layerOpacity) ? layerOpacity : 1;
          if (ancestorStyle.backgroundImage && ancestorStyle.backgroundImage !== 'none') hasImageBackground = true;
          const background = parseColor(ancestorStyle.backgroundColor);
          backdrop = blend({ rgb: background.rgb, alpha: background.alpha * ancestorOpacity * nextOpacity }, backdrop);
          ancestorOpacity *= nextOpacity;
        }
        const elementOpacity = Number.parseFloat(style.opacity);
        const renderedOpacity = ancestorOpacity * (Number.isFinite(elementOpacity) ? elementOpacity : 1);
        const colors = [...style.boxShadow.matchAll(/rgba?\\([^)]*\\)|#[\\da-f]{3,8}/gi)].map((match) => match[0]);
        const visibleColors = colors.filter((color) => parseColor(color).alpha > 0);
        const visibleFocus = focusVisible && (hasVisibleOutline || visibleColors.length > 0);
        const indicatorValue = hasVisibleOutline ? style.outlineColor : visibleColors.at(-1) || style.outlineColor;
        const indicator = parseColor(indicatorValue);
        indicator.alpha *= renderedOpacity;
        const luminance = (rgb) => rgb.map((channel) => {
          const value = channel / 255;
          return value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4;
        }).reduce((sum, value, index) => sum + value * [0.2126, 0.7152, 0.0722][index], 0);
        const renderedIndicator = blend(indicator, backdrop);
        const l = [luminance(renderedIndicator.rgb), luminance(backdrop.rgb)].sort((a, b) => b - a);
        const focusContrast = Number(((l[0] + 0.05) / (l[1] + 0.05)).toFixed(2));
        return { tag: el.tagName.toLowerCase(), name, visibleFocus, focusContrast, indicator: indicatorValue, backdrop: backdrop.rgb.map(Math.round), hasImageBackground };
      })()`);
      if (item.repeat || item.tag === 'body' || item.tag === 'html') break;
      if (!item.name || !item.visibleFocus) {
        throw new Error(`Unnamed or invisible keyboard focus on ${pageTitle}/${viewportName}: ${JSON.stringify(item)}`);
      }
      if (item.hasImageBackground) throw new Error(`Focus indicator over image/gradient background needs visual verification on ${pageTitle}/${viewportName}: ${JSON.stringify(item)}`);
      if (item.focusContrast < 3) {
        throw new Error(`Focus indicator contrast below 3:1 on ${pageTitle}/${viewportName}: ${JSON.stringify(item)}`);
      }
      focused.push(item);
    }
    if (focused.length === 0) throw new Error(`No keyboard-focusable controls found on ${pageTitle}/${viewportName}`);
    return { theme, page: pageTitle, viewport: viewportName, tabbableControls: focused.length, minimumFocusContrast: Math.min(...focused.map((item) => item.focusContrast)), focusStops: focused };
  }

  async function assertAXNode(role, nameIncludes, context) {
    const { nodes } = await cdp('Accessibility.getFullAXTree');
    const exposed = nodes.some((node) => !node.ignored && node.role?.value === role && (!nameIncludes || node.name?.value?.includes(nameIncludes)));
    if (!exposed) throw new Error(`Accessibility tree does not expose ${role}${nameIncludes ? ` named ${nameIncludes}` : ''} during ${context}`);
  }

  const mock = `(() => {
    let status = { running: false, healthy: false, port: null, version: null, error: null };
    let settings = { autoRotate: false, autoStart: false, opencodeBin: null, theme: 'system' };
    let connections = [];
    let loginPolls = 0;
    const failures = new Set();
    const token = 'smoke-test-session-token-that-is-long-enough';
    window.__UI_SMOKE__ = { failures };
    const proxyState = {
      mode: 'auto', manualId: null,
      proxies: [
        { id: 'px_a', label: 'proxy-a', url: 'http://demo:example@proxy-a.invalid:8080', enabled: true, health: { ok: true, latencyMs: 42, checkedAt: Date.now() } },
        { id: 'px_b', label: 'proxy-b', url: 'socks5://proxy-b.invalid:1080', enabled: true },
      ],
      bindings: { 'demo@example.invalid|https://console.example.invalid': 'px_a' },
    };
    const usage = (days) => ({
      days, assistantMessages: 12, userMessages: 13, sessions: 3,
      inputTokens: 18200, outputTokens: 7300, reasoningTokens: 1200,
      cacheReadTokens: 4500, cacheWriteTokens: 2800, cost: 0.42,
      models: [{ model: 'opencode/test-model', requests: 12 }],
    });
    const invoke = (command, args = {}) => {
      if (failures.has(command)) throw new Error('mock failure for ' + command);
      switch (command) {
        case 'opencode_status': return status;
        case 'opencode_start':
        case 'opencode_restart': status = { running: true, healthy: true, port: 4096, version: '2.0.26', error: null }; return status;
        case 'opencode_stop': status = { running: false, healthy: false, port: null, version: null, error: null }; return status;
        case 'opencode_binary': return '/usr/local/bin/opencode';
        case 'settings_get': return { ...settings };
        case 'settings_set': settings = { ...args.settings }; return { ...settings };
        case 'console_connections': return connections.map((connection) => ({ ...connection }));
        case 'console_login_start':
          loginPolls = 0;
          return { attemptID: 'attempt-1', url: 'https://opencode.ai/console/device?code=smoke-link', instructions: 'Approve sign-in in your browser.', mode: 'auto' };
        case 'console_login_status':
          loginPolls += 1;
          if (loginPolls < 2) return { status: 'pending' };
          connections = [
            { id: 'cred-a', label: 'demo@example.invalid', active: true, method: 'oauth' },
            { id: 'cred-b', label: 'backup@example.invalid', active: false, method: 'oauth' },
          ];
          return { status: 'complete' };
        case 'console_login_complete': return null;
        case 'console_login_cancel': return 'Sign-in cancelled';
        case 'console_activate': connections = connections.map((connection) => ({ ...connection, active: connection.id === args.credentialID })); return status;
        case 'console_logout': connections = connections.filter((connection) => connection.id !== args.credentialID); return 'Removed local account';
        case 'usage_summary': return usage(args.days);
        case 'proxy_list': return structuredClone(proxyState);
        case 'proxy_import':
        case 'proxy_remove':
        case 'proxy_set_enabled':
        case 'proxy_set_mode':
        case 'proxy_check_all': return structuredClone(proxyState);
        default: return null;
      }
    };
    const nativeFetch = window.fetch.bind(window);
    window.fetch = async (input, init = {}) => {
      const url = new URL(typeof input === 'string' ? input : input.url, location.href);
      if (url.pathname === '/api/session') {
        return new Response(JSON.stringify({ token }), { headers: { 'Content-Type': 'application/json' } });
      }
      if (url.pathname === '/api/app-info') {
        return new Response(JSON.stringify({ version: '0.1.0' }), { headers: { 'Content-Type': 'application/json' } });
      }
      if (url.pathname === '/api/command') {
        const request = JSON.parse(init.body || '{}');
        try {
          return new Response(JSON.stringify(invoke(request.command, request.args || {})), { headers: { 'Content-Type': 'application/json' } });
        } catch (error) {
          return new Response(JSON.stringify({ error: String(error.message || error) }), { status: 400, headers: { 'Content-Type': 'application/json' } });
        }
      }
      return nativeFetch(input, init);
    };
    window.EventSource = class extends EventTarget {
      constructor(url) { super(); this.url = url; }
      close() {}
    };
    localStorage.removeItem('relaydock.setup-guide-dismissed.v1');
    localStorage.removeItem('opencode-zero-limit.setup-guide-dismissed.v1');
  })();`;

  await cdp('Page.enable');
  await cdp('Runtime.enable');
  await cdp('Accessibility.enable');
  await cdp('Page.addScriptToEvaluateOnNewDocument', { source: mock });
  await cdp('Page.navigate', { url: baseUrl });
  await waitFor("document.querySelector('main h1')?.innerText.includes('Accounts')", 'Accounts page');
  await waitFor("!!document.querySelector('aside[aria-labelledby=\\\"setup-guide-heading\\\"]')", 'first-run guide');

  fs.mkdirSync(outputDir, { recursive: true });
  for (const file of fs.readdirSync(outputDir)) {
    if (file.endsWith('.png') || file === 'results.json') fs.rmSync(path.join(outputDir, file));
  }

  const onboardingImage = path.join(outputDir, 'onboarding-first-run.png');
  await cdp('Emulation.setDeviceMetricsOverride', { width: 680, height: 820, deviceScaleFactor: 1, mobile: false });
  await sleep(150);
  await captureScreenshot(onboardingImage);
  const onboardingMinimumImage = path.join(outputDir, 'onboarding-minimum.png');
  await cdp('Emulation.setDeviceMetricsOverride', { width: 800, height: 560, deviceScaleFactor: 1, mobile: false });
  await sleep(150);
  await captureScreenshot(onboardingMinimumImage);
  await cdp('Emulation.setDeviceMetricsOverride', { width: 680, height: 820, deviceScaleFactor: 1, mobile: false });

  // Complete the first-run path: start service, connect in a browser, select an account, finish.
  await waitFor("[...document.querySelectorAll('button')].some((button) => button.innerText.trim() === 'Start')", 'server Start action');
  await clickButton('Start');
  await waitFor("[...document.querySelectorAll('button')].some((button) => button.innerText.trim() === 'Add account')", 'account setup action');
  await waitFor("[...document.querySelectorAll('button')].some((button) => button.innerText.trim() === 'Reload' && !button.disabled)", 'accounts ready for reload');
  await evaluate("window.__UI_SMOKE__.failures.add('console_connections')");
  await clickButton('Reload');
  await waitFor("[...document.querySelectorAll('[role=alert]')].some((el) => el.innerText.includes('Could not load Console connections:') && el.innerText.includes('mock failure for console_connections'))", 'accounts load error');
  await assertAXNode('alert', null, 'Accounts error');
  await assertAXNode('button', 'Try again', 'Accounts retry');
  await evaluate("window.__UI_SMOKE__.failures.delete('console_connections')");
  await clickButton('Try again');
  await waitFor("document.querySelector('main')?.innerText.includes('No OpenCode Console accounts are connected yet')", 'accounts load recovery');
  await clickButton('Add account');
  await waitFor("document.querySelector('a[href^=\\\"https://opencode.ai/console/device?code=\\\"]')?.innerText.includes('Open sign-in in browser')", 'browser sign-in link');
  const linkTarget = await evaluate("document.querySelector('a[href^=\\\"https://opencode.ai/console/device?code=\\\"]')?.target");
  if (linkTarget !== '_blank') throw new Error('Browser sign-in link should open in a new tab');
  await waitFor("[...document.querySelectorAll('li')].some((item) => item.innerText.includes('backup@example.invalid'))", 'connections after browser sign-in');
  const selectBackup = await evaluate(`(() => { const row = [...document.querySelectorAll('li')].find((item) => item.innerText.includes('backup@example.invalid')); const button = row?.querySelector('button.account-picker__select'); if (!button) return false; button.click(); return true; })()`);
  if (!selectBackup) throw new Error('Could not select the mocked backup Console connection');
  await clickButton('Use account');
  await waitFor("document.querySelector('.account-current')?.innerText.includes('backup@example.invalid')", 'connection activation');
  await waitFor("document.querySelector('.setup-guide__collapsed-label')?.innerText.includes('Setup complete')", 'setup guide collapses after active account');
  await clickButton('Show setup guide');
  await waitFor("document.querySelector('aside[aria-labelledby=\\\"setup-guide-heading\\\"]')?.innerText.includes('The selected OpenCode Console connection is active')", 'active account guide reopens');
  const finishClicked = await evaluate(`(() => { const guide = document.querySelector('aside[aria-labelledby="setup-guide-heading"]'); const button = [...(guide?.querySelectorAll('button') ?? [])].find((item) => item.innerText.trim() === 'Finish setup'); if (!button) return false; button.click(); return true; })()`);
  if (!finishClicked) throw new Error('Could not finish setup guide');
  await waitFor("localStorage.getItem('relaydock.setup-guide-dismissed.v1') === 'true'", 'setup completion saved');
  await waitFor("[...document.querySelectorAll('button')].some((button) => button.innerText.includes('Show setup guide'))", 'guide dismissal control');

  const errorRecovery = ['Accounts error announcement + retry'];
  const accessibilityAnnouncements = ['Accounts alert and retry action appear in the accessibility tree'];
  await evaluate("window.__UI_SMOKE__.failures.add('usage_summary')");
  await click('nav[aria-label="Primary navigation"] button[title="Usage"]');
  await waitFor("[...document.querySelectorAll('[role=alert]')].some((el) => el.innerText.includes('mock failure for usage_summary'))", 'usage load error');
  await assertAXNode('alert', null, 'Usage error');
  await assertAXNode('button', 'Try again', 'Usage retry');
  accessibilityAnnouncements.push('Usage alert and retry action appear in the accessibility tree');
  await evaluate("window.__UI_SMOKE__.failures.delete('usage_summary')");
  await clickButton('Try again');
  await waitFor("document.querySelector('main')?.innerText.includes('Assistant messages')", 'usage load recovery');
  errorRecovery.push('Usage error announcement + retry');

  await evaluate("window.__UI_SMOKE__.failures.add('proxy_list')");
  await click('nav[aria-label="Primary navigation"] button[title="Proxies"]');
  await waitFor("[...document.querySelectorAll('[role=alert]')].some((el) => el.innerText.includes('mock failure for proxy_list'))", 'proxy load error');
  await assertAXNode('alert', null, 'Proxies error');
  await assertAXNode('button', 'Try again', 'Proxies retry');
  accessibilityAnnouncements.push('Proxies alert and retry action appear in the accessibility tree');
  await evaluate("window.__UI_SMOKE__.failures.delete('proxy_list')");
  await clickButton('Try again');
  await waitFor("document.querySelector('main')?.innerText.includes('Import proxies')", 'proxy load recovery');
  errorRecovery.push('Proxies error announcement + retry');

  await evaluate("window.__UI_SMOKE__.failures.add('settings_get')");
  await click('nav[aria-label="Primary navigation"] button[title="Settings"]');
  await waitFor("[...document.querySelectorAll('[role=alert]')].some((el) => el.innerText.includes('mock failure for settings_get'))", 'settings load error');
  await assertAXNode('alert', null, 'Settings error');
  await assertAXNode('button', 'Try again', 'Settings retry');
  accessibilityAnnouncements.push('Settings alert and retry action appear in the accessibility tree');
  await evaluate("window.__UI_SMOKE__.failures.delete('settings_get')");
  await clickButton('Try again');
  await waitFor("document.querySelector('main')?.innerText.includes('Save & restart')", 'settings load recovery');
  errorRecovery.push('Settings error announcement + retry');

  const sizes = [
    { name: 'mobile', width: 390, height: 844 },
    { name: 'narrow', width: 680, height: 820 },
    { name: 'minimum', width: 800, height: 560 },
    { name: 'default', width: 960, height: 680 },
    { name: 'medium', width: 1024, height: 820 },
    { name: 'wide', width: 1440, height: 900 },
  ];
  const pages = [
    { name: 'accounts', title: 'Accounts' },
    { name: 'usage', title: 'Usage' },
    { name: 'proxy', title: 'Proxies' },
    { name: 'settings', title: 'Settings' },
  ];
  const results = [];
  for (const theme of ['light', 'dark']) {
    await click('button[aria-label^="Theme is"]');
    await waitFor(`[...document.querySelectorAll('button')].some((button) => button.getAttribute('aria-label') === ${JSON.stringify(`Theme is ${theme}; click to cycle theme`)})`, `${theme} theme label`);
    await waitFor(`document.documentElement.classList.contains('dark') === ${theme === 'dark'}`, `${theme} theme`);
    for (const size of sizes) {
      await cdp('Emulation.setDeviceMetricsOverride', {
        width: size.width, height: size.height, deviceScaleFactor: 1, mobile: false,
      });
      await sleep(150);
      for (const page of pages) {
        await click(`nav[aria-label="Primary navigation"] button[title="${page.title}"]`);
        await waitFor(`document.querySelector('main h1')?.innerText.includes(${JSON.stringify(page.title)})`, `${page.title} page`);
        await sleep(120);
        const audit = await evaluate(`(() => ({
          title: document.querySelector('main h1')?.innerText.trim(),
          viewport: window.innerWidth,
          documentWidth: document.documentElement.scrollWidth,
          bodyWidth: document.body.scrollWidth,
          mainWidth: document.querySelector('main')?.clientWidth,
          mainScrollWidth: document.querySelector('main')?.scrollWidth,
          alerts: [...document.querySelectorAll('[role=alert]')].map((el) => el.innerText.trim()),
          unlabeledControls: [...document.querySelectorAll('button, [role=button], [role=switch], input, textarea, select, a[href]')].filter((el) => {
            const style = getComputedStyle(el);
            if (style.display === 'none' || style.visibility === 'hidden') return false;
            const labelledBy = el.getAttribute('aria-labelledby')?.split(/\\s+/).map((id) => document.getElementById(id)?.innerText.trim()).filter(Boolean).join(' ');
            const label = el.id ? document.querySelector('label[for="' + CSS.escape(el.id) + '"]')?.innerText.trim() : '';
            const text = (el.innerText || el.value || '').trim();
            return !(el.getAttribute('aria-label') || labelledBy || label || text || el.getAttribute('title'));
          }).map((el) => el.tagName.toLowerCase() + '#' + el.id),
          contrastRatios: (() => {
            const canvas = document.createElement('canvas');
            canvas.width = canvas.height = 1;
            const context = canvas.getContext('2d', { willReadFrequently: true });
            const parse = (value) => {
              context.clearRect(0, 0, 1, 1);
              context.fillStyle = 'transparent';
              context.fillStyle = value;
              context.fillRect(0, 0, 1, 1);
              const [red, green, blue, alpha] = context.getImageData(0, 0, 1, 1).data;
              return { rgb: [red, green, blue], alpha: alpha / 255 };
            };
            const background = (el) => {
              for (let node = el; node; node = node.parentElement) {
                const color = parse(getComputedStyle(node).backgroundColor);
                if (color?.alpha > 0.98) return color.rgb;
              }
              return [255, 255, 255];
            };
            const luminance = (rgb) => rgb.map((channel) => {
              const value = channel / 255;
              return value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4;
            }).reduce((sum, value, index) => sum + value * [0.2126, 0.7152, 0.0722][index], 0);
            const measure = (el) => {
              if (!el) return null;
              const foreground = parse(getComputedStyle(el).color);
              const backdrop = background(el);
              if (!foreground) return null;
              const values = [luminance(foreground.rgb), luminance(backdrop)].sort((a, b) => b - a);
              return Number(((values[0] + 0.05) / (values[1] + 0.05)).toFixed(2));
            };
            const main = document.querySelector('main');
            return Object.fromEntries(Object.entries({
              heading: main?.querySelector('h1'),
              mutedText: main?.querySelector('.text-muted-foreground'),
              primaryButton: main?.querySelector('button.bg-primary'),
            }).map(([name, el]) => [name, measure(el)]).filter(([, value]) => value !== null));
          })(),
          allTextContrast: (() => {
            const canvas = document.createElement('canvas');
            canvas.width = canvas.height = 1;
            const context = canvas.getContext('2d', { willReadFrequently: true });
            const parse = (value) => {
              context.clearRect(0, 0, 1, 1);
              context.fillStyle = 'transparent';
              context.fillStyle = value;
              context.fillRect(0, 0, 1, 1);
              const [red, green, blue, alpha] = context.getImageData(0, 0, 1, 1).data;
              return { rgb: [red, green, blue], alpha: alpha / 255 };
            };
            const blend = (front, back) => {
              const alpha = front.alpha + back.alpha * (1 - front.alpha);
              if (!alpha) return { rgb: [255, 255, 255], alpha: 1 };
              return { rgb: front.rgb.map((channel, index) => (channel * front.alpha + back.rgb[index] * back.alpha * (1 - front.alpha)) / alpha), alpha };
            };
            const luminance = (rgb) => rgb.map((channel) => {
              const value = channel / 255;
              return value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4;
            }).reduce((sum, value, index) => sum + value * [0.2126, 0.7152, 0.0722][index], 0);
            const ratio = (foreground, background) => {
              const values = [luminance(foreground), luminance(background)].sort((a, b) => b - a);
              return Number(((values[0] + 0.05) / (values[1] + 0.05)).toFixed(2));
            };
            const result = { checked: 0, minimum: 100, minimumActive: 100, lowContrast: [], disabledText: 0, disabledLowContrast: [], unverifiedBackgrounds: [] };
            const check = (element, text, textStyle) => {
              if (!text.trim() || element.closest('script, style, svg, [aria-hidden="true"], .sr-only')) return;
              const ancestors = [];
              for (let node = element; node; node = node.parentElement) ancestors.unshift(node);
              let backdrop = { rgb: [255, 255, 255], alpha: 1 };
              let opacity = 1;
              let hasImageBackground = false;
              for (const node of ancestors) {
                const style = getComputedStyle(node);
                if (style.backgroundImage && style.backgroundImage !== 'none') hasImageBackground = true;
                const layerOpacity = Number.parseFloat(style.opacity);
                const nextOpacity = Number.isFinite(layerOpacity) ? layerOpacity : 1;
                const background = parse(style.backgroundColor);
                backdrop = blend({ rgb: background.rgb, alpha: background.alpha * opacity * nextOpacity }, backdrop);
                opacity *= nextOpacity;
              }
              if (hasImageBackground) result.unverifiedBackgrounds.push(text.trim().slice(0, 80));
              const foreground = parse(textStyle.color);
              foreground.alpha *= opacity;
              const renderedForeground = blend(foreground, backdrop);
              const measured = ratio(renderedForeground.rgb, backdrop.rgb);
              const fontSize = Number.parseFloat(textStyle.fontSize) || 16;
              const fontWeight = Number.parseFloat(textStyle.fontWeight) || (textStyle.fontWeight === 'bold' ? 700 : 400);
              const threshold = fontSize >= 24 || (fontSize >= 18.66 && fontWeight >= 700) ? 3 : 4.5;
              const disabled = Boolean(element.closest('button:disabled, input:disabled, textarea:disabled, select:disabled, [aria-disabled="true"]'));
              result.checked += 1;
              result.minimum = Math.min(result.minimum, measured);
              if (disabled) {
                result.disabledText += 1;
                if (measured < threshold) result.disabledLowContrast.push({ text: text.trim().slice(0, 80), measured, threshold });
              } else {
                result.minimumActive = Math.min(result.minimumActive, measured);
                if (measured < threshold) result.lowContrast.push({ text: text.trim().slice(0, 80), measured, threshold, foreground: renderedForeground.rgb.map(Math.round), background: backdrop.rgb.map(Math.round), sourceForeground: textStyle.color });
              }
            };
            const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
            while (walker.nextNode()) {
              const node = walker.currentNode;
              const element = node.parentElement;
              if (!element) continue;
              const style = getComputedStyle(element);
              if (style.display === 'none' || style.visibility === 'hidden') continue;
              const range = document.createRange();
              range.selectNodeContents(node);
              if (![...range.getClientRects()].some((rect) => rect.width > 0 && rect.height > 0)) continue;
              check(element, node.nodeValue || '', style);
            }
            for (const input of document.querySelectorAll('input[placeholder], textarea[placeholder]')) {
              if (input.value || !input.placeholder) continue;
              const style = getComputedStyle(input);
              if (style.display !== 'none' && style.visibility !== 'hidden' && input.getClientRects().length) {
                check(input, input.placeholder, getComputedStyle(input, '::placeholder'));
              }
            }
            if (!result.checked) result.minimum = result.minimumActive = null;
            else if (result.minimumActive === 100) result.minimumActive = null;
            return result;
          })(),
          dark: document.documentElement.classList.contains('dark'),
        }))()`);
        const axTree = await cdp('Accessibility.getFullAXTree');
        const interactiveRoles = new Set(['button', 'link', 'textbox', 'switch', 'checkbox', 'radio button', 'combobox', 'slider', 'tab', 'toggle button']);
        const exposedControls = axTree.nodes.filter((node) => !node.ignored && interactiveRoles.has(node.role?.value));
        const unnamedAxControls = exposedControls.filter((node) => !node.name?.value?.trim());
        const hasNamedNavigation = axTree.nodes.some((node) => !node.ignored && node.role?.value === 'navigation' && node.name?.value === 'Primary navigation');
        const hasMainLandmark = axTree.nodes.some((node) => !node.ignored && node.role?.value === 'main');
        if (unnamedAxControls.length || !hasNamedNavigation || !hasMainLandmark) {
          throw new Error(`Accessibility tree issue at ${theme}/${size.name}/${page.name}: ${JSON.stringify({ unnamedAxControls: unnamedAxControls.map((node) => node.role?.value), hasNamedNavigation, hasMainLandmark })}`);
        }
        audit.accessibilityTree = { namedInteractiveControls: exposedControls.length, namedNavigation: hasNamedNavigation, mainLandmark: hasMainLandmark };
        if (audit.documentWidth > size.width + 1 || audit.bodyWidth > size.width + 1 || audit.mainScrollWidth > audit.mainWidth + 1) {
          const overflowNodes = await evaluate(`([...document.querySelectorAll('main *')].filter((el) => el.scrollWidth > el.clientWidth + 1).map((el) => ({ tag: el.tagName.toLowerCase(), className: String(el.className.baseVal ?? el.className ?? ''), clientWidth: el.clientWidth, scrollWidth: el.scrollWidth, text: (el.innerText || '').trim().slice(0, 100) })))`);
          throw new Error(`Horizontal overflow at ${theme}/${size.name}/${page.name}: ${JSON.stringify({ audit, overflowNodes })}`);
        }
        if (audit.alerts.length) throw new Error(`Unexpected alert at ${theme}/${size.name}/${page.name}: ${audit.alerts.join(' | ')}`);
        if (audit.unlabeledControls.length) throw new Error(`Unlabeled controls at ${theme}/${size.name}/${page.name}: ${audit.unlabeledControls.join(', ')}`);
        if (audit.allTextContrast.unverifiedBackgrounds.length) throw new Error(`Text over image/gradient backgrounds needs visual verification at ${theme}/${size.name}/${page.name}: ${JSON.stringify(audit.allTextContrast.unverifiedBackgrounds)}`);
        if (audit.allTextContrast.lowContrast.length || audit.allTextContrast.disabledLowContrast.length) throw new Error(`Visible text contrast below WCAG AA at ${theme}/${size.name}/${page.name}: ${JSON.stringify([...audit.allTextContrast.lowContrast, ...audit.allTextContrast.disabledLowContrast].slice(0, 12))}`);
        const lowContrast = Object.entries(audit.contrastRatios).filter(([, ratio]) => ratio < 4.5);
        if (lowContrast.length) throw new Error(`Sampled text contrast below 4.5:1 at ${theme}/${size.name}/${page.name}: ${JSON.stringify(lowContrast)}`);
        const screenshot = path.join(outputDir, `${theme}-${size.name}-${page.name}.png`);
        await captureScreenshot(screenshot);
        results.push({ theme, size: `${size.width}x${size.height}`, page: page.name, screenshot: path.relative(projectRoot, screenshot), ...audit });
      }
    }
  }

  const keyboardTraversal = [];
  for (const theme of ['light', 'dark']) {
    await ensureTheme(theme);
    for (const viewport of sizes) {
      await cdp('Emulation.setDeviceMetricsOverride', { width: viewport.width, height: viewport.height, deviceScaleFactor: 1, mobile: false });
      for (const page of pages) keyboardTraversal.push(await traverseKeyboard(page.title, viewport.name, theme));
    }
  }
  const keyboardFocus = keyboardTraversal[0].focusStops[0];

  const report = {
    generatedAt: new Date().toISOString(),
    browser: path.basename(chromePath),
    onboarding: { completed: true, screenshot: path.relative(projectRoot, onboardingImage) },
    combinations: results.length,
    errorRecovery,
    accessibilityAnnouncements,
    keyboardFocus,
    keyboardTraversal,
    checks: ['no horizontal overflow', 'no unexpected role=alert in healthy state', 'accessible name present on visible interactive controls', 'full Tab traversal reaches named controls with visible focus on every page at all tested widths', 'all visible text nodes/placeholders, including disabled actions, meet WCAG AA contrast (4.5:1 normal, 3:1 large)', 'accessibility tree exposes named controls and main/navigation landmarks', 'Tab focus outline contrast >=3:1 across light/dark at all tested widths'],
    results,
  };
  fs.writeFileSync(path.join(outputDir, 'results.json'), `${JSON.stringify(report, null, 2)}\n`);
  const gallery = ['light', 'dark'].flatMap((theme) => sizes.map((size) => {
    const tiles = pages.map((page) => {
      const filename = `${theme}-${size.name}-${page.name}.png`;
      return `<figure><a href="./${filename}"><img src="./${filename}" alt="${theme} ${page.title} at ${size.width} by ${size.height}"></a><figcaption>${page.title}</figcaption></figure>`;
    }).join('');
    return `<section><h3>${theme} · ${size.width}×${size.height}</h3><div class="grid">${tiles}</div></section>`;
  })).join('');
  fs.writeFileSync(path.join(outputDir, 'index.html'), `<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>UI smoke screenshots</title>
<style>body{font:14px system-ui,sans-serif;margin:24px;color:#18212b}h1,h2,h3{margin:0 0 12px}section{margin:24px 0} .grid{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:12px}figure{margin:0}img{display:block;width:100%;height:auto;border:1px solid #cbd5e1;background:#f8fafc}figcaption{padding:6px 2px;color:#475569}@media(max-width:900px){.grid{grid-template-columns:repeat(2,minmax(0,1fr))}}</style>
<h1>UI smoke screenshots</h1><p>Mocked local HTTP API · onboarding + ${results.length} theme/page/viewport captures · <a href="./results.json">machine-readable results</a></p>
<h2>First-run guide</h2><div class="grid"><figure><a href="./onboarding-first-run.png"><img src="./onboarding-first-run.png" alt="First-run onboarding at 680 by 820"></a><figcaption>First-run setup guide · 680×820</figcaption></figure><figure><a href="./onboarding-minimum.png"><img src="./onboarding-minimum.png" alt="First-run onboarding at the 800 by 560 minimum window size"></a><figcaption>First-run setup guide · 800×560 minimum window</figcaption></figure></div>
${gallery}
</html>\n`);
  console.log(`UI smoke passed: onboarding + ${results.length} page/theme/viewport combinations.`);
  console.log(`Screenshots and machine-readable results: ${path.relative(projectRoot, outputDir)}`);
} finally {
  ws?.close();
  await Promise.all([stopProcess(chrome), stopProcess(vite)]);
  await removeTempDir(profileDir);
}
