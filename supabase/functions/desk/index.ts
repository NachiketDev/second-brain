// DESK: read and act API for the standalone desk apps (v1 and v2) when they run outside Claude.
// Auth: brain_mcp_secret, sent in the x-brain-token header or as the last path segment. Wrong token = 404.
// v1: GET returns the brain_desk bundle; POST {action:'done'|'dropped'|'open', id} marks one of HIS commitments.
// v2: GET ?view=control|goals|workbench|people|person|week|review|trust|health (+ org, id, week_start, month)
//     returns that desk_* screen; POST {op, ...} runs one of a few fixed writes (all through brain_* functions).
// Nothing is ever sent to anyone from here; Google Tasks gets a copy of his own task changes.
import { checkSecret, db } from '../_shared/lib.ts';
import { gConfigured, pushGoogleTasks } from '../_shared/gtasks.ts';

const CORS = { 'access-control-allow-origin': '*', 'access-control-allow-methods': 'GET, POST, OPTIONS', 'access-control-allow-headers': 'content-type, x-brain-token', 'access-control-max-age': '86400' };
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...CORS, 'content-type': 'application/json', 'cache-control': 'no-store' } });

const VIEWS: Record<string, (q: URLSearchParams) => [string, Record<string, unknown>]> = {
  control:   () => ['desk_control', {}],
  goals:     () => ['desk_goals', {}],
  workbench: () => ['desk_workbench', {}],
  people:    (q) => ['desk_people', { p_org: q.get('org') || null }],
  person:    (q) => ['desk_person', { p_id: q.get('id') ?? '' }],
  week:      (q) => ['desk_week', { p_start: q.get('week_start') || null }],
  review:    (q) => ['desk_review', { p_month: q.get('month') || null }],
  trust:     () => ['desk_trust', {}],
  health:    () => ['desk_health', {}],
};

async function rpc(fn: string, params: Record<string, unknown>) {
  const { data, error } = await db().rpc(fn, params);
  if (error) throw error;
  return data;
}
async function syncGoogle(id: number) {
  if (!gConfigured()) return 'Google Tasks not connected';
  try { const r = await pushGoogleTasks([id]); return r.errors?.length ? r.errors.join('; ') : 'synced'; }
  catch (e) { return `will retry: ${(e as Error).message}`; }
}

// deno-lint-ignore no-explicit-any
const OPS: Record<string, (b: any) => Promise<unknown>> = {
  mark: async (b) => {
    if (!['done', 'dropped', 'open'].includes(b.status) || !Number.isInteger(b.id)) throw new Error('bad request');
    const r = await rpc('brain_complete', { p_id: b.id, p_status: b.status, p_source: 'desk', p_note: b.reason ?? `marked ${b.status} on the desk` });
    return { ...r, google: await syncGoogle(b.id) };
  },
  set_priorities: (b) => rpc('brain_set_priorities', { p_day: b.date, p_ids: (b.commitment_ids ?? []).map(Number), p_set_by: 'desk' }),
  update_pursuit: (b) => {
    const p: Record<string, unknown> = { id: String(b.id) };
    for (const k of ['stage', 'status', 'deadline']) if (b[k] !== undefined) p[k] = b[k];
    return rpc('brain_upsert_pursuit', { p });
  },
  plan_block: (b) => rpc('brain_plan_block', { p_starts: b.start, p_ends: b.end, p_commitment_id: b.commitment_id ?? null,
    p_pursuit_id: b.pursuit_id ?? null, p_goal_id: b.goal_id ?? null, p_title: b.title ?? null, p_kind: b.kind ?? 'planned' }),
  delete_block: (b) => rpc('brain_delete_block', { p_id: Number(b.id) }),
};

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
      const view = url.searchParams.get('view');
      if (view) {
        const v = VIEWS[view];
        if (!v) return json({ error: 'unknown view' }, 400);
        const [fn, p] = v(url.searchParams);
        return json(await rpc(fn, p));
      }
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
      if (b.op) {
        const op = OPS[b.op];
        if (!op) return json({ error: 'unknown op' }, 400);
        if (b.op === 'mark') {
          const { data: row } = await sb.from('commitments').select('owner').eq('id', b.id).maybeSingle();
          if (!row || row.owner !== 'me') return json({ error: 'only your own commitments can be changed here' }, 403);
        }
        return json(await op(b));
      }
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
