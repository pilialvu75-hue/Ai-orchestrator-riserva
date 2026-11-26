import { spawn } from 'node:child_process';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { addFixtureWebApplicationData } from './web_application_fixture_data.mjs';

const ORIGIN = 'http://aivexus-generated.invalid';
const CSP = "sandbox allow-scripts allow-same-origin; default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; " +
  "img-src 'self' data:; connect-src 'none'; form-action 'none'; base-uri 'none'; frame-ancestors 'none'";
const TYPES = { html: 'text/html', css: 'text/css', js: 'text/javascript', mjs: 'text/javascript',
  json: 'application/json', txt: 'text/plain', md: 'text/plain' };

function connectDebugger(url) {
  const socket = new WebSocket(url);
  const commands = new Map();
  const handlers = new Map();
  let nextId = 0;
  const ready = new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('debugger startup timeout')), 3000);
    socket.addEventListener('open', () => { clearTimeout(timer); resolve(); }, { once: true });
    socket.addEventListener('error', () => { clearTimeout(timer); reject(new Error('debugger unavailable')); }, { once: true });
  });
  socket.addEventListener('message', ({ data }) => {
    const message = JSON.parse(data);
    if (message.id) {
      const call = commands.get(message.id);
      commands.delete(message.id);
      call?.(message);
    } else {
      handlers.get(message.method)?.(message.params);
    }
  });
  return {
    ready,
    close: () => socket.close(),
    on: (event, handler) => handlers.set(event, handler),
    async send(method, params = {}) {
      await ready;
      return new Promise((resolve, reject) => {
        const id = ++nextId;
        const timer = setTimeout(() => { commands.delete(id); reject(new Error('debugger command timeout')); }, 3500);
        commands.set(id, message => {
          clearTimeout(timer);
          if (message.error) reject(new Error('debugger command failed'));
          else resolve(message.result);
        });
        try { socket.send(JSON.stringify({ id, method, params })); } catch (error) {
          clearTimeout(timer);
          commands.delete(id);
          reject(error);
        }
      });
    },
  };
}

async function debuggerPage(profile, chrome) {
  const deadline = Date.now() + 12000;
  let created = false;
  while (Date.now() < deadline && chrome.exitCode === null) {
    try {
      const info = await readFile(join(profile, 'DevToolsActivePort'), 'utf8');
      const [port] = info.trim().split(/\r?\n/);
      if (!/^\d{2,5}$/.test(port)) throw new Error('invalid debugger port');
      const debuggerOrigin = `http://127.0.0.1:${port}`;
      const list = await fetch(`${debuggerOrigin}/json/list`, { signal: AbortSignal.timeout(1000) });
      let page = (await list.json()).find(item => item.type === 'page' && item.url === 'about:blank');
      if (!page && !created) {
        const response = await fetch(`${debuggerOrigin}/json/new?about:blank`, {
          method: 'PUT', signal: AbortSignal.timeout(1000),
        });
        if (response.ok) {
          created = true;
          page = await response.json();
        }
      }
      if (page?.type !== 'page' || page.url !== 'about:blank') throw new Error('blank debugger target missing');
      const url = new URL(page.webSocketDebuggerUrl);
      if (url.protocol === 'ws:' && url.hostname === '127.0.0.1' && url.port === port) return url;
    } catch (_) {
      await delay(60);
    }
  }
  throw new Error('browser startup failed');
}

function chromiumEnvironment(profile) {
  const env = { XDG_CONFIG_HOME: join(profile, 'config'), XDG_CACHE_HOME: join(profile, 'cache') };
  for (const name of ['PATH', 'SystemRoot', 'WINDIR', 'TEMP', 'TMP', 'TMPDIR', 'LANG']) {
    if (process.env[name]) env[name] = process.env[name];
  }
  return env;
}

function readStartupCategory(text) {
  if (/crashpad|crash reporter/i.test(text)) return 'browser_crash_reporter_failed';
  if (/no usable sandbox|namespace sandbox|sandbox initialization/i.test(text)) return 'browser_sandbox_unavailable';
  if (/cannot open shared object|error while loading shared libraries/i.test(text)) return 'browser_library_missing';
  return null;
}

function browserCheck({ action, selector, value }) {
  const element = document.querySelector(selector);
  if (!element || !element.checkVisibility()) return false;
  if (action === 'text') return element.innerText.trim() === value;
  if (action === 'click') {
    if (!(element instanceof HTMLElement) || element.matches(':disabled')) return false;
    element.click();
    return true;
  }
  if (!(element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement) ||
      element.readOnly || element.disabled) return false;
  element.value = value;
  element.dispatchEvent(new Event('input', { bubbles: true }));
  element.dispatchEvent(new Event('change', { bubbles: true }));
  return true;
}

export function createChromiumWebVerifier({ executable }) {
  async function verifyOnce({ assets, checks, runtime }) {
    if (!executable) return { status: 'unavailable', diagnosis: 'browser_not_configured' };
    const profile = await mkdtemp(join(tmpdir(), 'aivexus-web-test-'));
    let exited;
    let chrome;
    let debuggerClient;
    let failureDiagnosis = 'browser_startup_failed';
    try {
      chrome = spawn(executable, ['--headless', '--remote-debugging-port=0', '--remote-debugging-address=127.0.0.1',
        `--user-data-dir=${profile}`, '--disable-extensions', '--disable-background-networking',
        '--no-first-run', '--no-default-browser-check', '--proxy-server=http://aivexus-blocked.invalid:9',
        '--proxy-bypass-list=<-loopback>',
        '--host-resolver-rules=MAP * ~NOTFOUND', '--force-webrtc-ip-handling-policy=disable_non_proxied_udp',
        'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'], env: chromiumEnvironment(profile), windowsHide: true });
      let startupCategory = null;
      chrome.stderr.setEncoding('utf8');
      chrome.stderr.on('data', text => { startupCategory ??= readStartupCategory(text); });
      const startupFailed = new Promise((_, reject) => chrome.once('error', reject));
      exited = new Promise(resolve => chrome.once('close', resolve));
      try {
        debuggerClient = connectDebugger(await Promise.race([debuggerPage(profile, chrome), startupFailed]));
      } catch (error) {
        failureDiagnosis = startupCategory ?? failureDiagnosis;
        throw error;
      }
      failureDiagnosis = 'browser_debugger_failed';
      const client = debuggerClient;
      let appError = false;
      let rejectedRequest = false;
      let interceptionFailed = false;
      client.on('Runtime.exceptionThrown', () => { appError = true; });
      client.on('Fetch.requestPaused', async ({ requestId, request }) => {
        const url = new URL(request.url);
        const path = url.pathname.slice(1) || 'index.html';
        const allowed = url.origin === ORIGIN && request.method === 'GET';
        const file = allowed ? assets.get(path) : undefined;
        const content = path === 'index.html' && file !== undefined ? addFixtureWebApplicationData(file, runtime) : file;
        try {
          if (content !== undefined || (allowed && path === 'favicon.ico')) {
            await client.send('Fetch.fulfillRequest', {
              requestId, responseCode: content === undefined ? 204 : 200,
              responseHeaders: [
                { name: 'Content-Type', value: (TYPES[path.split('.').at(-1)] ?? 'text/plain') + '; charset=utf-8' },
                { name: 'Content-Security-Policy', value: CSP },
                { name: 'X-Content-Type-Options', value: 'nosniff' },
              ],
              body: Buffer.from(content ?? '').toString('base64'),
            });
          } else {
            rejectedRequest = true;
            await client.send('Fetch.failRequest', { requestId, errorReason: 'BlockedByClient' });
          }
        } catch (_) { interceptionFailed = true; }
      });
      await client.send('Page.enable');
      await client.send('Runtime.enable');
      await client.send('Fetch.enable');
      let loaded;
      const pageLoaded = new Promise(resolve => { loaded = resolve; });
      client.on('Page.loadEventFired', loaded);
      const page = await client.send('Page.navigate', { url: ORIGIN + '/index.html' });
      if (page.errorText || !await Promise.race([pageLoaded.then(() => true), delay(2500, false)])) {
        return { status: 'unavailable', diagnosis: 'browser_navigation_failed' };
      }
      const world = await client.send('Page.createIsolatedWorld', { frameId: page.frameId, worldName: 'aivexus-checks' });
      const observedError = () => interceptionFailed ? 'browser_interception_failed' :
        rejectedRequest ? 'unexpected_resource_request' : appError ? 'javascript_error' : null;
      function diagnosis(checkIndex) {
        const issue = observedError();
        if (issue) return { status: interceptionFailed ? 'unavailable' : 'code_error', diagnosis: issue, checkIndex };
        return null;
      }
      for (const [checkIndex, check] of checks.entries()) {
        const before = diagnosis(checkIndex);
        if (before) return before;
        const result = await client.send('Runtime.evaluate', {
          expression: `(${browserCheck.toString()})(${JSON.stringify(check)})`,
          contextId: world.executionContextId, returnByValue: true, timeout: 1500,
        });
        // Browser events from app handlers can arrive just after the command.
        await delay(50);
        const after = diagnosis(checkIndex);
        if (after) return after;
        if (result.exceptionDetails || result.result.value !== true) {
          return { status: 'code_error', diagnosis: 'browser_check_failed', checkIndex };
        }
      }
      return { status: 'passed', diagnosis: 'browser_checks_passed', checks: checks.length };
    } catch (_) {
      return { status: 'unavailable', diagnosis: failureDiagnosis };
    } finally {
      if (debuggerClient) {
        try { await debuggerClient.send('Browser.close'); } catch (_) { /* process cleanup follows */ }
        debuggerClient.close();
      }
      chrome?.kill();
      if (exited) await Promise.race([exited, delay(2500)]);
      if (dirname(resolve(profile)) === resolve(tmpdir())) {
        await rm(profile, { recursive: true, force: true, maxRetries: 3, retryDelay: 100 });
      }
    }
  }
  return async function verify(input) {
    const result = await verifyOnce(input);
    if (result.diagnosis === 'browser_startup_failed') return verifyOnce(input);
    return result;
  };
}
