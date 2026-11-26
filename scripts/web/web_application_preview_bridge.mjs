const CHANNEL = 'aivexus-data:v1';

export function newWebApplicationRecordId() {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  const hex = Array.from(bytes, byte => byte.toString(16).padStart(2, '0')).join('');
  return hex.slice(0, 8) + '-' + hex.slice(8, 12) + '-' + hex.slice(12, 16) + '-' +
    hex.slice(16, 20) + '-' + hex.slice(20);
}

function installFrameData(channelName, newRecordId) {
  const pair = new MessageChannel();
  const requests = new Map();
  let nextId = 0;
  pair.port1.onmessage = ({ data }) => {
    const pending = requests.get(data?.id);
    if (!pending) return;
    requests.delete(data.id);
    clearTimeout(pending.timeout);
    if (data.ok) pending.resolve(data.result);
    else pending.reject(new Error(data.error || 'records_unavailable'));
  };
  const request = (operation, payload) => new Promise((resolve, reject) => {
    if (requests.size >= 4) { reject(new Error('records_busy')); return; }
    const id = ++nextId;
    const timeout = setTimeout(() => { requests.delete(id); reject(new Error('records_timeout')); }, 12000);
    requests.set(id, { resolve, reject, timeout });
    try { pair.port1.postMessage({ id, operation, payload }); }
    catch (_) { clearTimeout(timeout); requests.delete(id); reject(new Error('invalid_request')); }
  });
  Object.defineProperty(window, 'aivexusData', { value: Object.freeze({
    newRecordId,
    request: payload => request('records', payload),
    integration: integration => request('integration', { integration }),
  }) });
  parent.postMessage(channelName, '*', [pair.port2]);
}

function installPreviewHost(generationId, channelName) {
  const frame = document.createElement('iframe');
  frame.title = 'Applicazione generata';
  frame.setAttribute('sandbox', 'allow-scripts');
  frame.referrerPolicy = 'no-referrer';
  let connected = false;
  let pending = 0;
  const accept = (event) => {
    if (connected || event.source !== frame.contentWindow || event.origin !== 'null' ||
        event.data !== channelName || event.ports.length !== 1) return;
    connected = true;
    window.removeEventListener('message', accept);
    const port = event.ports[0];
    port.onmessage = async ({ data }) => {
      const { id, operation, payload } = data ?? {};
      if (!Number.isSafeInteger(id)) return;
      const reject = error => port.postMessage({ id, ok: false, error });
      if (pending >= 4) { reject('records_busy'); return; }
      if (operation !== 'records' && operation !== 'integration') { reject('invalid_request'); return; }
      if (!payload || typeof payload !== 'object' || Array.isArray(payload)) { reject('invalid_request'); return; }
      pending++;
      try {
        const body = JSON.stringify({ ...payload, generationId });
        if (body.length > 24576) { reject('invalid_request'); return; }
        const response = await fetch('/api/cantiere/proposals/' + operation, {
          method: 'POST', headers: { 'Content-Type': 'application/json' }, body,
          credentials: 'same-origin', redirect: 'manual', signal: AbortSignal.timeout(10000),
        });
        const result = await response.json();
        if (!response.ok || !result.ok) { reject(result.error || 'records_unavailable'); return; }
        port.postMessage({ id, ok: true, result });
      } catch (_) { reject('records_unavailable'); }
      finally { pending--; }
    };
  };
  window.addEventListener('message', accept);
  frame.src = '/api/cantiere/proposals/preview?generationId=' + encodeURIComponent(generationId);
  document.body.append(frame);
}

export function prependWebApplicationBootstrap(html, bootstrap) {
  return '<!doctype html><script>' + bootstrap + '</script>' + html.replace(/^\s*<!doctype html\s*>/i, '');
}

export function addWebApplicationDataBridge(html) {
  return prependWebApplicationBootstrap(html,
    `(${installFrameData.toString()})(${JSON.stringify(CHANNEL)},${newWebApplicationRecordId.toString()})`);
}

export function renderWebApplicationPreviewHost(generationId) {
  const nonce = btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(18))));
  const script = `(${installPreviewHost.toString()})(${JSON.stringify(generationId)},${JSON.stringify(CHANNEL)})`;
  return new Response(`<!doctype html><meta charset="utf-8"><title>Anteprima AIVEXUS</title>
    <style nonce="${nonce}">html,body,iframe{width:100%;height:100%;margin:0;border:0}iframe{display:block}</style>
    <body><script nonce="${nonce}">${script}</script>`, { headers: {
    'Content-Type': 'text/html; charset=utf-8',
    'Content-Security-Policy': `default-src 'none'; script-src 'nonce-${nonce}'; style-src 'nonce-${nonce}'; frame-src 'self'; connect-src 'self'; frame-ancestors 'self'; base-uri 'none'; form-action 'none'`,
    'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', 'X-Frame-Options': 'SAMEORIGIN',
    'Referrer-Policy': 'no-referrer',
  } });
}
