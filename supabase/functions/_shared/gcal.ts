// Google Calendar: planned time blocks are written to a separate "Brain" calendar that the brain creates.
// Scope calendar.app.created: the brain can only see and change calendars it created itself, never his others.
// Uses the same Google sign-in as Google Tasks (gauth asks for both scopes).
import { db } from './lib.ts';
import { accessToken } from './gtasks.ts';

export const GCAL_SCOPE = 'https://www.googleapis.com/auth/calendar.app.created';
const API = 'https://www.googleapis.com/calendar/v3';
const CAL_NAME = 'Brain';
const TZ = 'America/New_York';

class NeedsSignIn extends Error {}

async function api(token: string, path: string, init: RequestInit = {}) {
  const res = await fetch(`${API}${path}`, {
    ...init, headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json', ...(init.headers ?? {}) },
  });
  if (res.status === 204 || (init.method === 'DELETE' && (res.status === 404 || res.status === 410))) return null;
  const body = await res.text();
  if (res.status === 403 && /insufficient|scope/i.test(body)) throw new NeedsSignIn('Google sign-in has no Calendar permission yet');
  if (res.status === 403 && /accessNotConfigured|has not been used|disabled/i.test(body))
    throw new NeedsSignIn('Google Calendar API is not enabled in the Google Cloud project');
  if (!res.ok) throw new Error(`Google Calendar ${res.status}: ${body.slice(0, 200)}`);
  return body ? JSON.parse(body) : null;
}

// deno-lint-ignore no-explicit-any
async function rpc(fn: string, params: Record<string, unknown>): Promise<any> {
  const { data, error } = await db().rpc(fn, params);
  if (error) throw new Error(`${fn}: ${error.message}`);
  return data;
}

/** Find (or create once) the "Brain" calendar and cache its id in kv g_calendar_id. */
export async function gEnsureCalendar(token: string) {
  const sb = db();
  const { data: cached } = await sb.from('kv').select('value').eq('key', 'g_calendar_id').maybeSingle();
  if (cached?.value) {
    try { await api(token, `/calendars/${encodeURIComponent(cached.value as string)}`); return cached.value as string; }
    catch (e) { if (e instanceof NeedsSignIn) throw e; /* calendar deleted: make a new one */ }
  }
  const cal = await api(token, '/calendars', { method: 'POST', body: JSON.stringify({ summary: CAL_NAME, timeZone: TZ,
    description: 'Time blocks planned on your Second Brain desk. Safe to hide; delete blocks on the desk.' }) });
  await sb.from('kv').upsert({ key: 'g_calendar_id', value: cal.id });
  return cal.id as string;
}

/** Push planned blocks (create, move, delete) to the Brain calendar. */
export async function pushCalendarBlocks(token?: string) {
  // deno-lint-ignore no-explicit-any
  const queue: any[] = await rpc('brain_gcal_queue', {});
  if (!queue.length) return { pushed: 0 };
  try {
    token = token ?? await accessToken();
    const cal = encodeURIComponent(await gEnsureCalendar(token));
    let ok = 0; const errors: string[] = [];
    for (const q of queue) {
      try {
        const ev = { summary: q.title, description: q.notes, start: { dateTime: q.start, timeZone: TZ }, end: { dateTime: q.end, timeZone: TZ },
          transparency: 'opaque', reminders: { useDefault: false }, extendedProperties: { private: { brain_block_id: String(q.id) } } };
        if (q.state === 'to_delete') {
          if (q.event_id) await api(token, `/calendars/${cal}/events/${encodeURIComponent(q.event_id)}`, { method: 'DELETE' });
          await rpc('brain_gcal_pushed', { p_id: q.id });
        } else if (q.state === 'to_create' || !q.event_id) {
          const r = await api(token, `/calendars/${cal}/events`, { method: 'POST', body: JSON.stringify(ev) });
          await rpc('brain_gcal_pushed', { p_id: q.id, p_event_id: r.id });
        } else {
          await api(token, `/calendars/${cal}/events/${encodeURIComponent(q.event_id)}`, { method: 'PATCH', body: JSON.stringify(ev) });
          await rpc('brain_gcal_pushed', { p_id: q.id });
        }
        ok++;
      } catch (e) {
        if (e instanceof NeedsSignIn) throw e;
        errors.push(`block ${q.id}: ${(e as Error).message.slice(0, 120)}`);
        await rpc('brain_gcal_pushed', { p_id: q.id, p_error: (e as Error).message });
      }
    }
    return { pushed: ok, errors };
  } catch (e) {
    if (e instanceof NeedsSignIn) return { waiting: e.message, queued: queue.length };
    throw e;
  }
}
