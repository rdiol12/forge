import test from 'node:test';
import assert from 'node:assert/strict';
import worker from './worker.mjs';
const env = { GITHUB_CLIENT_ID: 'test-client', GITHUB_CLIENT_SECRET: 'test-secret' };

test('exchange requires PKCE, rejects arbitrary redirects, and never returns a secret', async () => {
  let calls = 0;
  const original = globalThis.fetch;
  globalThis.fetch = async (url, options) => {
    calls++;
    assert.equal(url, 'https://github.com/login/oauth/access_token');
    const form = new URLSearchParams(options.body);
    assert.equal(form.get('client_id'), env.GITHUB_CLIENT_ID);
    assert.equal(form.get('client_secret'), env.GITHUB_CLIENT_SECRET);
    assert.equal(form.get('redirect_uri'), 'app.forge.github://oauth/callback');
    assert.equal(form.get('code_verifier'), 'a'.repeat(43));
    assert.equal(options.redirect, 'error');
    return Response.json({access_token:'test-access-token', token_type:'bearer', scope:'repo,notifications', client_secret:'must-not-leak'});
  };
  try {
    for (const body of [{code:'abc'}, {code:'abc', codeVerifier:'short'}, {code:'abc', codeVerifier:'a'.repeat(43), redirectUri:'https://untrusted.example'}]) {
      const result = await worker.fetch(new Request('https://forge.example/oauth/token', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(body)}), env);
      assert.equal(result.status, 400);
    }
    assert.equal(calls, 0);
    const result = await worker.fetch(new Request('https://forge.example/oauth/token', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({code:'abc',codeVerifier:'a'.repeat(43)})}), env);
    assert.equal(result.status, 200);
    assert.equal(result.headers.get('Cache-Control'), 'no-store');
    assert.deepEqual(await result.json(), {access_token:'test-access-token',token_type:'bearer',scope:'repo,notifications'});
    assert.equal(calls, 1);
  } finally { globalThis.fetch = original; }
});

test('unconfigured login fails closed and public configuration contains no secret', async () => {
  const unavailable = await worker.fetch(new Request('https://forge.example/oauth/config'), {});
  assert.equal(unavailable.status, 503);
  const ready = await worker.fetch(new Request('https://forge.example/oauth/config'), env);
  assert.deepEqual(await ready.json(), {clientId:'test-client'});
  const oversized = await worker.fetch(new Request('https://forge.example/oauth/token', {method:'POST',headers:{'Content-Type':'application/json'},body:'x'.repeat(5000)}), env);
  assert.equal(oversized.status, 413);
});
