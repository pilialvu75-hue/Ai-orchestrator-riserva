import { encodeRunnerBase64 } from './web_application_runner_packet.mjs';
import { addWebApplicationDataBridge } from './web_application_preview_bridge.mjs';

const encoder = new TextEncoder();
const SYNTHETIC = 'https://aivexus-preview.invalid';
const POLICY = [
  'sandbox allow-scripts', "default-src 'none'", "script-src 'unsafe-inline' data:",
  "style-src 'unsafe-inline' data:", 'img-src data:', 'font-src data:',
  "connect-src 'none'", "form-action 'none'", "base-uri 'none'", "frame-ancestors 'self'",
].join('; ');

function sourceUrl(reference, files, suffixes, mime) {
  if (typeof reference !== 'string' || !reference.trim() || reference.startsWith('//') ||
      /[:\\]/.test(reference)) return null;
  const url = new URL(reference, SYNTHETIC + '/index.html');
  if (url.origin !== SYNTHETIC || !suffixes.some(suffix => url.pathname.endsWith(suffix))) return null;
  const content = files.get(url.pathname.slice(1));
  if (content === undefined) return null;
  return `data:${mime};charset=utf-8;base64,${encodeRunnerBase64(encoder.encode(content))}`;
}

// Keep code in an opaque-origin iframe. Local script and style references are
// embedded as data so loading the preview does not depend on browser cookies.
export function previewWebApplication(source) {
  const files = new Map(source.files.map(({ path, content }) => [path, content]));
  const html = files.get('index.html');
  if (!html) throw new Error('Verified source is missing its entry point');
  const remove = { element(element) { element.remove(); } };
  const rewriter = new HTMLRewriter()
    .on('base, meta[http-equiv], iframe, object, embed, frame', remove)
    .on('script[src]', { element(element) {
      const target = sourceUrl(element.getAttribute('src'), files, ['.js', '.mjs'], 'text/javascript');
      if (!target) { element.remove(); return; }
      element.setAttribute('src', target);
      element.removeAttribute('integrity');
      element.removeAttribute('crossorigin');
    } })
    .on('link', { element(element) {
      const target = element.getAttribute('rel')?.toLowerCase() === 'stylesheet' &&
        sourceUrl(element.getAttribute('href'), files, ['.css'], 'text/css');
      if (!target) { element.remove(); return; }
      element.setAttribute('href', target);
      element.removeAttribute('integrity');
      element.removeAttribute('crossorigin');
    } })
    .on('a[href], area[href]', { element(element) {
      if (!element.getAttribute('href')?.startsWith('#')) element.removeAttribute('href');
      element.removeAttribute('target');
      element.removeAttribute('ping');
    } });
  return rewriter.transform(new Response(source.runtime ? addWebApplicationDataBridge(html) : html, { headers: {
    'Content-Type': 'text/html; charset=utf-8',
    'Content-Security-Policy': POLICY,
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
    'X-Frame-Options': 'SAMEORIGIN',
    'Referrer-Policy': 'no-referrer',
    'Permissions-Policy': 'camera=(), microphone=(), geolocation=(), payment=(), usb=()',
    'X-Robots-Tag': 'noindex, nofollow, noarchive',
  } }));
}
