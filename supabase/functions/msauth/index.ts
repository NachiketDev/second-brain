// MSAUTH: one-time Microsoft sign-in for To Do.
//  ?start=<state>  -> redirects to Microsoft (state is a one-time value created in the database)
//  ?code&state     -> Microsoft sends you back here; the refresh token is stored in Vault
import { db, env, handler } from '../_shared/lib.ts';
import { ensureList, MS_AUTH, MS_SCOPE, msRedirect, msToken } from '../_shared/mstodo.ts';

const text = (body: string, status = 200) =>
  new Response(body, { status, headers: { 'content-type': 'text/plain; charset=utf-8' } });

Deno.serve(handler(async (req) => {
  const u = new URL(req.url);
  const sb = db();
  const { data: row } = await sb.from('kv').select('value').eq('key', 'ms_oauth_state').maybeSingle();
  const valid = (s: string | null) => !!s && row?.value?.state === s && !row.value.used &&
    Date.now() - new Date(row.value.at).getTime() < 24 * 3600e3;

  if (u.searchParams.get('error'))
    return text(`Microsoft returned an error: ${u.searchParams.get('error_description') ?? u.searchParams.get('error')}`, 400);

  const start = u.searchParams.get('start');
  if (start) {
    if (!valid(start)) return text('This sign-in link has expired. Ask Claude for a new one.', 403);
    const p = new URLSearchParams({ client_id: env('MS_CLIENT_ID'), response_type: 'code', redirect_uri: msRedirect(),
      response_mode: 'query', scope: MS_SCOPE, state: start, prompt: 'select_account' });
    return Response.redirect(`${MS_AUTH}/authorize?${p}`, 302);
  }

  const code = u.searchParams.get('code'), state = u.searchParams.get('state');
  if (code) {
    if (!valid(state)) return text('This sign-in link has expired. Ask Claude for a new one.', 403);
    const token = await msToken({ grant_type: 'authorization_code', code, redirect_uri: msRedirect() });
    await sb.from('kv').update({ value: { ...row!.value, used: true } }).eq('key', 'ms_oauth_state');
    await ensureList(token);
    return text('Connected. Approved tasks from your digest will now go to the "Brain" list in Microsoft To Do. You can close this tab.');
  }
  return text('Nothing to do here.', 400);
}));
