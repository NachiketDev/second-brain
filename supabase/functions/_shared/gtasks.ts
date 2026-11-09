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

async function accessToken() {
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
