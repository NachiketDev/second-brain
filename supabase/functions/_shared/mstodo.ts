// Microsoft To Do via Microsoft Graph (personal Microsoft account).
// The refresh token lives in the database Vault and is rotated on every use.
import { db, env } from './lib.ts';

export const MS_AUTH = 'https://login.microsoftonline.com/consumers/oauth2/v2.0';
export const MS_SCOPE = 'offline_access Tasks.ReadWrite';
export const msRedirect = () => `${env('SUPABASE_URL')}/functions/v1/msauth`;
const GRAPH = 'https://graph.microsoft.com/v1.0';
const LIST_NAME = Deno.env.get('MS_TODO_LIST') ?? 'Brain';

export const msConfigured = () => !!Deno.env.get('MS_CLIENT_ID') && !!Deno.env.get('MS_CLIENT_SECRET');

export async function msToken(form: Record<string, string>) {
  const res = await fetch(`${MS_AUTH}/token`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ client_id: env('MS_CLIENT_ID'), client_secret: env('MS_CLIENT_SECRET'),
      scope: MS_SCOPE, ...form }),
  });
  const j = await res.json();
  if (!res.ok) throw new Error(`Microsoft sign-in failed: ${j.error_description ?? j.error ?? res.status}`);
  if (j.refresh_token) await db().rpc('set_secret', { p_name: 'brain_ms_refresh_token', p_value: j.refresh_token });
  return j.access_token as string;
}

async function accessToken() {
  const { data: rt } = await db().rpc('get_secret', { p_name: 'brain_ms_refresh_token' });
  if (!rt) throw new Error('Microsoft To Do is not connected yet');
  return msToken({ grant_type: 'refresh_token', refresh_token: rt as string });
}

async function graph(token: string, path: string, init: RequestInit = {}) {
  const res = await fetch(`${GRAPH}${path}`, {
    ...init, headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json', ...(init.headers ?? {}) },
  });
  if (!res.ok) throw new Error(`Microsoft To Do ${res.status}: ${await res.text()}`);
  return res.status === 204 ? null : await res.json();
}

/** Find (or create once) the "Brain" list and cache its id. */
export async function ensureList(token: string) {
  const sb = db();
  const { data: cached } = await sb.from('kv').select('value').eq('key', 'ms_todo_list_id').maybeSingle();
  if (cached?.value) {
    try { await graph(token, `/me/todo/lists/${cached.value}`); return cached.value as string; } catch { /* list deleted */ }
  }
  const lists = await graph(token, '/me/todo/lists');
  // deno-lint-ignore no-explicit-any
  let list = (lists.value ?? []).find((l: any) => l.displayName === LIST_NAME);
  if (!list) list = await graph(token, '/me/todo/lists', { method: 'POST', body: JSON.stringify({ displayName: LIST_NAME }) });
  await sb.from('kv').upsert({ key: 'ms_todo_list_id', value: list.id });
  return list.id as string;
}

export async function addMsTask(p: { content: string; description?: string | null; due_date?: string | null }) {
  const token = await accessToken();
  const listId = await ensureList(token);
  return graph(token, `/me/todo/lists/${listId}/tasks`, {
    method: 'POST',
    body: JSON.stringify({
      title: p.content,
      body: p.description ? { content: p.description, contentType: 'text' } : undefined,
      dueDateTime: p.due_date ? { dateTime: `${p.due_date}T09:00:00`, timeZone: 'Eastern Standard Time' } : undefined,
      categories: ['Brain'],
    }),
  });
}
