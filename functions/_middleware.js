function unauthorized() {
  return new Response('Authentication required.', {
    status: 401,
    headers: {
      'Cache-Control': 'no-store',
      'WWW-Authenticate': 'Basic realm="AI-Orchestrator Cantiere", charset="UTF-8"',
      'X-Content-Type-Options': 'nosniff',
      'Referrer-Policy': 'no-referrer',
    },
  });
}

function unavailable() {
  return new Response('Private Web access is not configured.', {
    status: 503,
    headers: {
      'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff',
      'Referrer-Policy': 'no-referrer',
    },
  });
}

async function digest(value) {
  const bytes = new TextEncoder().encode(value);
  return new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
}

function constantTimeEqual(left, right) {
  if (left.length !== right.length) return false;
  let mismatch = 0;
  for (let i = 0; i < left.length; i += 1) {
    mismatch |= left[i] ^ right[i];
  }
  return mismatch === 0;
}

async function credentialsMatch(candidate, expectedUser, expectedPassword) {
  const separator = candidate.indexOf(':');
  if (separator < 0) return false;

  const user = candidate.slice(0, separator);
  const password = candidate.slice(separator + 1);

  const [actualUser, wantedUser, actualPassword, wantedPassword] =
      await Promise.all([
        digest(user),
        digest(expectedUser),
        digest(password),
        digest(expectedPassword),
      ]);

  return (
    constantTimeEqual(actualUser, wantedUser) &&
    constantTimeEqual(actualPassword, wantedPassword)
  );
}

function securityHeaders(response) {
  const headers = new Headers(response.headers);
  headers.set('X-Content-Type-Options', 'nosniff');
  headers.set('Referrer-Policy', 'no-referrer');
  headers.set('X-Frame-Options', 'DENY');
  headers.set('Permissions-Policy', 'camera=(), microphone=(), geolocation=()');

  if ((response.headers.get('Content-Type') || '').includes('text/html')) {
    headers.set('Cache-Control', 'no-store');
  }

  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

export async function onRequest(context) {
  const expectedUser = context.env.WEB_ACCESS_USER;
  const expectedPassword = context.env.WEB_ACCESS_PASSWORD;

  // Fail closed: a deployment with missing secrets must never expose the site.
  if (!expectedUser || !expectedPassword) {
    return unavailable();
  }

  const authorization = context.request.headers.get('Authorization');
  if (!authorization || !authorization.startsWith('Basic ')) {
    return unauthorized();
  }

  let decoded;
  try {
    decoded = atob(authorization.slice('Basic '.length));
  } catch (_) {
    return unauthorized();
  }

  if (!(await credentialsMatch(decoded, expectedUser, expectedPassword))) {
    return unauthorized();
  }

  return securityHeaders(await context.next());
}
