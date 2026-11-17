// DESK: read API for the standalone desk app. One GET returns everything the screens need.
// Auth: brain_mcp_secret, sent in the x-brain-token header or as the last path segment. Wrong token = 404.
// POST {action:'done'|'dropped'|'open', id} marks one of HIS commitments; nothing is ever sent to anyone from here.
import { checkSecret, db } from '../_shared/lib.ts';

const CORS = { 'access-control-allow-origin': '*', 'access-control-allow-methods': 'GET, POST, OPTIONS', 'access-control-allow-headers': 'content-type, x-brain-token', 'access-control-max-age': '86400' };
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...CORS, 'content-type': 'application/json', 'cache-control': 'no-store' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS });
  const url = new URL(req.url);
  const parts = url.pathname.split('/').filter(Boolean);
  const fromPath = parts[parts.length - 1] === 'desk' ? '' : decodeURIComponent(parts[parts.length - 1] ?? '');
  const secret = (req.headers.get('x-brain-token') ?? '').trim() || fromPath.trim();
  if (!(await checkSecret('brain_mcp_secret', secret))) return new Response(secret ? 'Not found' : 'Token missing', { status: 404, headers: CORS });
  const sb = db();
  try {
    if (req.method === 'GET') {
      const day = url.searchParams.get('day');
      const [desk, health] = await Promise.all([
        sb.rpc('brain_desk', day ? { p_day: day } : {}),
        sb.rpc('brain_desk_health'),
      ]);
      if (desk.error) throw desk.error;
      return json({ ...desk.data, health: health.data ?? desk.data.health });
    }
    if (req.method === 'POST') {
      const b = await req.json();
      if (!['done', 'dropped', 'open'].includes(b.action) || !Number.isInteger(b.id)) return json({ error: 'bad request' }, 400);
      const { data: row } = await sb.from('commitments').select('owner').eq('id', b.id).maybeSingle();
      if (!row || row.owner !== 'me') return json({ error: 'only your own commitments can be changed here' }, 403);
      const { error } = await sb.rpc('decide_commitment', { p_id: b.id, p_status: b.action, p_reason: `the user marked it ${b.action} on the desk screen` });
      if (error) throw error;
      return json({ ok: true, id: b.id, status: b.action });
    }
    return json({ error: 'method not allowed' }, 405);
  } catch (e) {
    console.error(e);
    return json({ error: (e as { message?: string }).message ?? String(e) }, 500);
  }
});
