const callback = 'app.forge.github://oauth/callback';
const json = (value, status = 200) => Response.json(value, {
  status,
  headers: {'Cache-Control':'no-store', 'X-Content-Type-Options':'nosniff', 'Referrer-Policy':'no-referrer'},
});

export default {
  async fetch(request, env) {
    const path = new URL(request.url).pathname;
    if (request.method === 'GET' && path === '/') return json({service:'Forge GitHub sign-in',message:'Open Forge on your iPhone to sign in.'});
    if (!['/oauth/config','/oauth/token'].includes(path)) return json({error:'Not found.'},404);
    if (!env.GITHUB_CLIENT_ID || !env.GITHUB_CLIENT_SECRET) return json({error:'GitHub sign-in is not configured yet.'},503);
    if (path === '/oauth/config' && request.method === 'GET') return json({clientId:env.GITHUB_CLIENT_ID});
    if (path !== '/oauth/token' || request.method !== 'POST') return json({error:'Method not allowed.'},405);
    if (!request.headers.get('Content-Type')?.toLowerCase().startsWith('application/json')) return json({error:'Expected JSON.'},415);
    let body;
    try {
      // Bound the body before parsing, even without a Content-Length header.
      const reader = request.body?.getReader();
      if (!reader) return json({error:'Missing request body.'},400);
      let text = '', size = 0;
      const decoder = new TextDecoder();
      while (true) {
        const {value,done} = await reader.read();
        if (done) break;
        size += value.length;
        if (size > 4096) { await reader.cancel(); return json({error:'Request too large.'},413); }
        text += decoder.decode(value,{stream:true});
      }
      body = JSON.parse(text + decoder.decode());
    } catch { return json({error:'Invalid JSON.'},400); }
    if (!body || typeof body !== 'object' || Array.isArray(body) ||
        Object.keys(body).some(key => !['code','codeVerifier'].includes(key)) ||
        typeof body.code !== 'string' || !/^[A-Za-z0-9_-]{1,512}$/.test(body.code) ||
        typeof body.codeVerifier !== 'string' || !/^[A-Za-z0-9._~-]{43,128}$/.test(body.codeVerifier)) {
      return json({error:'A valid authorization code and PKCE verifier are required.'},400);
    }
    try {
      const result = await fetch('https://github.com/login/oauth/access_token', {
        method:'POST', redirect:'error', signal:AbortSignal.timeout(15000),
        headers:{'Accept':'application/json','Content-Type':'application/x-www-form-urlencoded','User-Agent':'Forge-iOS-auth'},
        body:new URLSearchParams({client_id:env.GITHUB_CLIENT_ID,client_secret:env.GITHUB_CLIENT_SECRET,
          code:body.code,code_verifier:body.codeVerifier,redirect_uri:callback}).toString(),
      });
      if (!result.ok) return json({error:'GitHub could not complete sign-in. Please try again.'},502);
      const token = await result.json();
      if (typeof token.access_token !== 'string' || token.token_type !== 'bearer') return json({error:'Sign-in expired or was declined. Please start again.'},400);
      // Return only the fields the native app needs. Never log or persist tokens.
      return json({access_token:token.access_token,token_type:'bearer',scope:token.scope ?? ''});
    } catch { return json({error:'GitHub is temporarily unavailable. Please try again.'},502); }
  },
};
