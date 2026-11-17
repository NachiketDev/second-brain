// Google Tasks via the Tasks API (personal Gmail). Client ID and refresh token live in the database Vault;
// the client secret is the GOOGLE_CLIENT_SECRET function secret.
import { db, env } from './lib.ts';

export const G_AUTH = 'https://accounts.google.com/o/oauth2/v2/auth';
export const G_SCOPE = 'https://www.googleapis.com/auth/tasks';
export const gRedirect = () => `${env('SUPABASE_URL')}/functions/v1/gauth`;
const API = 'https://tasks.googleapis.com/tasks/v1';
const LIST_NAME = 'Brain';

export const gConfigured = () => !!Deno.env.get('GOOGLE_CLIENT_SECRET');

export async function gClientId() {
  const { data } = await db().rpc('get_secret', { p_name: 'brain_google_client_id' });
  if (!data) throw new Error('Google client ID missing');
  return data as string;
}

export async function gToken(form: Record<string, string>) {
  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ client_id: await gClientId(), client_secret: env('GOOGLE_CLIENT_SECRET'), ...form }),
  });
  const j = await res.json();
  if (!res.ok) throw new Error(`Google sign-in failed: ${j.error_description ?? j.error ?? res.status}`);
  if (j.refresh_token) await db().rpc('set_secret', { p_name: 'brain_google_refresh_token', p_value: j.refresh_token });
  return j.access_token as string;
}

export async function accessToken() {
  const { data: rt } = await db().rpc('get_secret', { p_name: 'brain_google_refresh_token' });
  if (!rt) throw new Error('Google Tasks is not connected yet');
  return gToken({ grant_type: 'refresh_token', refresh_token: rt as string });
}

async function api(token: string, path: string, init: RequestInit = {}) {
  const res = await fetch(`${API}${path}`, {
    ...init, headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json', ...(init.headers ?? {}) },
  });
  if (!res.ok) throw new Error(`Google Tasks ${res.status}: ${await res.text()}`);
  return res.status === 204 ? null : await res.json();
}

/** Find (or create once) the "Brain" task list and cache its id. */
export async function gEnsureList(token: string) {
  const sb = db();
  const { data: cached } = await sb.from('kv').select('value').eq('key', 'g_tasklist_id').maybeSingle();
  if (cached?.value) {
    try { await api(token, `/users/@me/lists/${cached.value}`); return cached.value as string; } catch { /* list deleted */ }
  }
  const lists = await api(token, '/users/@me/lists?maxResults=100');
  // deno-lint-ignore no-explicit-any
  let list = (lists.items ?? []).find((l: any) => l.title === LIST_NAME);
  if (!list) list = await api(token, '/users/@me/lists', { method: 'POST', body: JSON.stringify({ title: LIST_NAME }) });
  await sb.from('kv').upsert({ key: 'g_tasklist_id', value: list.id });
  return list.id as string;
}

/** Open tasks across all of the user's Google Tasks lists (read-only). */
export async function listGoogleTasks(includeCompleted = false) {
  const token = await accessToken();
  const lists = await api(token, '/users/@me/lists?maxResults=100');
  const out: { list: string; title: string; due: string | null; notes: string | null; status: string }[] = [];
  for (const l of lists.items ?? []) {
    const q = new URLSearchParams({ maxResults: '100', showCompleted: String(includeCompleted), showHidden: String(includeCompleted) });
    const t = await api(token, `/lists/${l.id}/tasks?${q}`);
    for (const x of t.items ?? []) {
      if (!x.title) continue;
      out.push({ list: l.title, title: x.title, due: x.due ? x.due.slice(0, 10) : null, notes: x.notes ?? null, status: x.status });
    }
  }
  return out.sort((a, b) => (a.due ?? '9999').localeCompare(b.due ?? '9999'));
}

export async function addGoogleTask(p: { content: string; description?: string | null; due_date?: string | null }) {
  const token = await accessToken();
  const listId = await gEnsureList(token);
  return api(token, `/lists/${listId}/tasks`, {
    method: 'POST',
    body: JSON.stringify({
      title: p.content,
      notes: p.description ?? undefined,
      due: p.due_date ? `${p.due_date}T00:00:00.000Z` : undefined,   // Google Tasks keeps the date only
    }),
  });
}

// ── Two-way sync (core model rebuild, 17 Nov) ──────────────────────────────────────────────────────
// The database is the task store; Google Tasks is a copy. Pull: every Google task goes through
// brain_gtask_seen (link, import, complete or reopen). Push: brain_gtask_queue lists commitments whose
// Google copy needs a write; each result is reported back with brain_gtask_pushed.

// deno-lint-ignore no-explicit-any
async function rpc(fn: string, params: Record<string, unknown>): Promise<any> {
  const { data, error } = await db().rpc(fn, params);
  if (error) throw new Error(`${fn}: ${error.message}`);
  return data;
}

/** Pull changes from Google. First run reads everything; later runs only tasks updated since the cursor. */
export async function pullGoogleTasks(token?: string) {
  token = token ?? await accessToken();
  const sb = db();
  const { data: cur } = await sb.from('kv').select('value').eq('key', 'gtask_sync_at').maybeSingle();
  const started = new Date().toISOString();
  const since = cur?.value ? new Date(new Date(cur.value as string).getTime() - 5 * 60_000).toISOString() : null;
  const counts: Record<string, number> = {};
  const lists = await api(token, '/users/@me/lists?maxResults=100');
  for (const l of lists.items ?? []) {
    let page: string | undefined;
    do {
      const q = new URLSearchParams({ maxResults: '100', showCompleted: 'true', showHidden: 'true' });
      if (since) q.set('updatedMin', since);
      if (page) q.set('pageToken', page);
      const t = await api(token, `/lists/${l.id}/tasks?${q}`);
      for (const x of t.items ?? []) {
        if (!x.title || x.deleted) continue;
        const r = await rpc('brain_gtask_seen', {
          p_gtask_id: x.id, p_list_id: l.id, p_title: x.title, p_due: x.due ? x.due.slice(0, 10) : null,
          p_notes: x.notes ?? null, p_completed: x.status === 'completed' });
        counts[r?.result ?? 'other'] = (counts[r?.result ?? 'other'] ?? 0) + 1;
      }
      page = t.nextPageToken;
    } while (page);
  }
  await sb.from('kv').upsert({ key: 'gtask_sync_at', value: started });   // documented cursor update
  return counts;
}

/** Push the brain's changes (new tasks, edits, ticks, reopens) to Google. Optionally only some ids. */
export async function pushGoogleTasks(onlyIds?: number[], token?: string) {
  // deno-lint-ignore no-explicit-any
  let queue: any[] = await rpc('brain_gtask_queue', {});
  if (onlyIds?.length) queue = queue.filter(q => onlyIds.includes(Number(q.id)));
  if (!queue.length) return { pushed: 0 };
  token = token ?? await accessToken();
  let defaultList: string | null = null;
  let ok = 0; const errors: string[] = [];
  for (const q of queue) {
    try {
      const list = q.list ?? (defaultList ??= await gEnsureList(token));
      if (q.state === 'to_create' || !q.gtask_id) {
        const t = await api(token, `/lists/${list}/tasks`, { method: 'POST', body: JSON.stringify({
          title: q.title, notes: q.notes ?? undefined, due: q.due ? `${q.due}T00:00:00.000Z` : undefined,
          status: ['done', 'dropped'].includes(q.status) ? 'completed' : 'needsAction' }) });
        await rpc('brain_gtask_pushed', { p_id: q.id, p_gtask_id: t.id, p_list_id: list });
      } else {
        const body = q.state === 'to_complete' ? { status: 'completed' }
          : q.state === 'to_reopen' ? { status: 'needsAction', completed: null }
          : { title: q.title, due: q.due ? `${q.due}T00:00:00.000Z` : null };
        await api(token, `/lists/${list}/tasks/${q.gtask_id}`, { method: 'PATCH', body: JSON.stringify(body) });
        await rpc('brain_gtask_pushed', { p_id: q.id, p_gtask_id: null, p_list_id: list });
      }
      ok++;
    } catch (e) {
      errors.push(`#${q.id}: ${(e as Error).message.slice(0, 120)}`);
      await rpc('brain_gtask_pushed', { p_id: q.id, p_gtask_id: null, p_list_id: null, p_error: (e as Error).message });
    }
  }
  return { pushed: ok, errors };
}
