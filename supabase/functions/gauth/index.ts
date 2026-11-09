// GAUTH: one-time Google sign-in for Google Tasks.
//  ?start=<state>  -> redirects to Google (state is a one-time value created in the database)
//  ?code&state     -> Google sends you back here; the refresh token is stored in Vault
import { db, handler } from '../_shared/lib.ts';
import { G_AUTH, G_SCOPE, gClientId, gEnsureList, gRedirect, gToken } from '../_shared/gtasks.ts';

const text = (body: string, status = 200) =>
  new Response(body, { status, headers: { 'content-type': 'text/plain; charset=utf-8' } });

Deno.serve(handler(async (req) => {
  const u = new URL(req.url);
  const sb = db();
  const { data: row } = await sb.from('kv').select('value').eq('key', 'g_oauth_state').maybeSingle();
  const valid = (s: string | null) => !!s && row?.value?.state === s && !row.value.used &&
    Date.now() - new Date(row.value.at).getTime() < 24 * 3600e3;

  if (u.searchParams.get('error')) return text(`Google returned an error: ${u.searchParams.get('error')}`, 400);

  const start = u.searchParams.get('start');
  if (start) {
    if (!valid(start)) return text('This sign-in link has expired. Ask Claude for a new one.', 403);
    const p = new URLSearchParams({ client_id: await gClientId(), redirect_uri: gRedirect(), response_type: 'code',
      scope: G_SCOPE, access_type: 'offline', prompt: 'consent', include_granted_scopes: 'true', state: start });
    return Response.redirect(`${G_AUTH}?${p}`, 302);
  }

  const code = u.searchParams.get('code'), state = u.searchParams.get('state');
  if (code) {
    if (!valid(state)) return text('This sign-in link has expired. Ask Claude for a new one.', 403);
    const token = await gToken({ grant_type: 'authorization_code', code, redirect_uri: gRedirect() });
    await sb.from('kv').update({ value: { ...row!.value, used: true } }).eq('key', 'g_oauth_state');
    await gEnsureList(token);
    return text('Connected. Approved tasks from your digest will now go to the "Brain" list in Google Tasks. You can close this tab.');
  }
  return text('Nothing to do here.', 400);
}));
