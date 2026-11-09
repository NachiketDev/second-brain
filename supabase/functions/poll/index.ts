// POLL (cron, every 15 min): pulls sources that can't push.
//  - Bee: GET /v1/conversations (Bee has no webhooks). New or changed conversations -> raw_events.
//  - Calendar: your Google Calendar "secret address in iCal format" -> calendar_events (used by the prep agent).
import { db, handler, requireCron } from '../_shared/lib.ts';
import { ingestOne } from '../_shared/ingest.ts';

const BEE = Deno.env.get('BEE_API_BASE') ?? 'https://api.developer.bee.amazon.dev';

// Bee's response shapes aren't fully documented; pull text from whichever fields exist.
// deno-lint-ignore no-explicit-any
export function beeText(c: any): string {
  const utter = (c.transcriptions ?? c.utterances ?? c.transcript?.utterances ?? [])
    // deno-lint-ignore no-explicit-any
    .flatMap((t: any) => t.utterances ?? [t])
    // deno-lint-ignore no-explicit-any
    .map((u: any) => `${u.speaker ?? u.speaker_label ?? 'Speaker'}: ${u.text ?? ''}`.trim())
    .filter((l: string) => l.length > 10);
  return [
    c.short_summary && `## Summary\n${c.short_summary}`,
    c.summary && `## Details\n${c.summary}`,
    typeof c.transcript === 'string' && `## Transcript\n${c.transcript}`,
    utter.length && `## Transcript\n${utter.join('\n')}`,
  ].filter(Boolean).join('\n\n');
}

async function pollBee() {
  const token = Deno.env.get('BEE_API_TOKEN');
  if (!token) return { bee: 'skipped (no BEE_API_TOKEN)' };
  const h = { authorization: `Bearer ${token}` };
  const res = await fetch(`${BEE}/v1/conversations?limit=25`, { headers: h });
  if (!res.ok) throw new Error(`Bee list ${res.status}: ${await res.text()}`);
  const body = await res.json();
  const list = body.conversations ?? body.data ?? body.items ?? (Array.isArray(body) ? body : []);
  let stored = 0;
  for (const item of list) {
    if (item.state && !['COMPLETED', 'completed', 'done'].includes(item.state)) continue;   // still recording
    const d = await fetch(`${BEE}/v1/conversations/${item.id}`, { headers: h });
    if (!d.ok) continue;
    const full = await d.json();
    const conv = full.conversation ?? full;
    const content = beeText(conv);
    if (!content) continue;
    const r = await ingestOne({
      provider: 'bee', kind: 'conversation', external_id: String(conv.id ?? item.id),
      occurred_at: conv.start_time ?? conv.created_at ?? item.start_time ?? new Date().toISOString(),
      title: conv.short_summary?.slice(0, 120) ?? 'Bee conversation', content,
      payload: { location: conv.primary_location ?? null },
    });
    if (r.result === 'stored' || r.result === 'revision') stored++;
  }
  return { bee: `${list.length} seen, ${stored} new` };
}

// ── Minimal iCal parser (Google's secret iCal feed). Recurring masters are expanded only for simple
//    weekly/daily rules within the 14-day window; everything else uses its listed instances.
export function parseIcs(text: string) {
  const lines = text.replace(/\r\n[ \t]/g, '').split(/\r?\n/);
  const events: Record<string, string | string[]>[] = [];
  let cur: Record<string, string | string[]> | null = null;
  for (const line of lines) {
    if (line === 'BEGIN:VEVENT') cur = { ATTENDEE: [] };
    else if (line === 'END:VEVENT' && cur) { events.push(cur); cur = null; }
    else if (cur) {
      const i = line.indexOf(':'); if (i < 0) continue;
      const [name, ...params] = line.slice(0, i).split(';');
      const val = line.slice(i + 1).replace(/\\n/g, '\n').replace(/\\,/g, ',').replace(/\\;/g, ';');
      if (name === 'ATTENDEE') {
        const cn = params.find(p => p.startsWith('CN='))?.slice(3).replace(/"/g, '');
        (cur.ATTENDEE as string[]).push(cn ?? val.replace(/^mailto:/i, ''));
      } else {
        cur[name] = name === 'EXDATE' && cur.EXDATE ? `${cur.EXDATE},${val}` : val;
        const tz = params.find(p => p.startsWith('TZID='));
        if (tz) cur[`${name}_TZID`] = tz.slice(5);
      }
    }
  }
  return events;
}

export function icsDate(v: string, tzid?: string): Date {
  const m = v.match(/^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})(Z)?)?$/);
  if (!m) return new Date(v);
  const [, y, mo, d, h = '00', mi = '00', s = '00', z] = m;
  if (z) return new Date(Date.UTC(+y, +mo - 1, +d, +h, +mi, +s));
  const tz = tzid ?? Deno.env.get('BRAIN_TIMEZONE') ?? 'America/New_York';
  // Interpret wall-clock time in tz: read that zone's UTC offset at the guessed instant, then correct.
  const wall = Date.UTC(+y, +mo - 1, +d, +h, +mi, +s);
  const offsetAt = (t: number) => {
    const p = Object.fromEntries(new Intl.DateTimeFormat('en-US', { timeZone: tz, hourCycle: 'h23',
      year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit' })
      .formatToParts(new Date(t)).map(x => [x.type, x.value]));
    return Date.UTC(+p.year, +p.month - 1, +p.day, +p.hour, +p.minute, +p.second) - t;
  };
  let t = wall - offsetAt(wall);
  t = wall - offsetAt(t);          // second pass handles instants near a DST switch
  return new Date(t);
}

// Outlook feeds use Windows zone names; map the common ones to IANA.
const WIN_TZ: Record<string, string> = {
  'Eastern Standard Time': 'America/New_York', 'Central Standard Time': 'America/Chicago',
  'Mountain Standard Time': 'America/Denver', 'Pacific Standard Time': 'America/Los_Angeles',
  'GMT Standard Time': 'Europe/London', 'India Standard Time': 'Asia/Kolkata', 'UTC': 'UTC',
  'W. Europe Standard Time': 'Europe/Berlin', 'Romance Standard Time': 'Europe/Paris',
};
export function normTz(tz?: string) {
  if (!tz) return undefined;
  const t = tz.replace(/"/g, '');
  if (WIN_TZ[t]) return WIN_TZ[t];
  try { new Intl.DateTimeFormat('en-US', { timeZone: t }); return t; } catch { return undefined; }
}

const DAYS = ['SU', 'MO', 'TU', 'WE', 'TH', 'FR', 'SA'];
/** Expand DAILY/WEEKLY rules in wall-clock time (so DST changes keep 10:00 at 10:00). */
export function expand(dtstart: string, tz: string | undefined, rule: string, from: number, to: number): Date[] {
  const m = dtstart.match(/^(\d{4})(\d{2})(\d{2})(T\d{6}Z?)?$/);
  const first = icsDate(dtstart, tz);
  if (!m) return [first];
  const freq = rule.match(/FREQ=(DAILY|WEEKLY)/)?.[1];
  if (!freq) return first.getTime() >= from && first.getTime() <= to ? [first] : [];
  const interval = +(rule.match(/INTERVAL=(\d+)/)?.[1] ?? 1);
  const until = rule.match(/UNTIL=(\w+)/)?.[1];
  const untilT = until ? icsDate(until, tz).getTime() : Infinity;
  const count = +(rule.match(/COUNT=(\d+)/)?.[1] ?? Infinity);
  const byday = rule.match(/BYDAY=([A-Z,]+)/)?.[1]?.split(',').map(d => DAYS.indexOf(d)).filter(d => d >= 0);
  const time = m[4] ?? '';
  const base = Date.UTC(+m[1], +m[2] - 1, +m[3]);
  const baseDow = new Date(base).getUTCDay();
  const out: Date[] = [];
  let n = 0;
  for (let day = 0; day < 800; day++) {
    const d = new Date(base + day * 864e5);
    const weeks = Math.floor((day + baseDow) / 7);   // week index, weeks start Sunday
    const ok = freq === 'DAILY' ? day % interval === 0
      : weeks % interval === 0 && (byday?.length ? byday.includes(d.getUTCDay()) : d.getUTCDay() === baseDow);
    if (!ok) continue;
    const ds = d.toISOString().slice(0, 10).replace(/-/g, '') + time;
    const t = icsDate(ds, tz);
    if (t.getTime() > untilT || t.getTime() > to || ++n > count) break;
    if (t.getTime() >= from) out.push(t);
  }
  return out;
}

async function pollCalendar() {
  const urls = (Deno.env.get('CALENDAR_ICS_URL') ?? '').split(/[\s,]+/).filter(Boolean)
    .map(u => u.replace(/^webcal:/i, 'https:'));
  if (!urls.length) return { calendar: 'skipped (no CALENDAR_ICS_URL)' };
  const now = Date.now(), from = now - 864e5, to = now + 14 * 864e5;
  const rows = new Map<string, Record<string, unknown>>();
  const seen = new Set<string>();   // same event in two feeds (e.g. Partiful RSVP also in Outlook)
  const report: string[] = [];
  for (const [i, url] of urls.entries()) {
    try {
      const res = await fetch(url);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const events = parseIcs(await res.text());
      // moved/edited single instances of a series, so the master's original slot is dropped
      const overridden = new Set(events.filter(e => e['RECURRENCE-ID'])
        .map(e => `${e.UID}@${icsDate(e['RECURRENCE-ID'] as string, normTz(e['RECURRENCE-ID_TZID'] as string)).toISOString()}`));
      let n = 0;
      for (const e of events) {
        if (!e.DTSTART || e.STATUS === 'CANCELLED') continue;
        const tz = normTz(e.DTSTART_TZID as string);
        const start = icsDate(e.DTSTART as string, tz);
        const end = e.DTEND ? icsDate(e.DTEND as string, normTz(e.DTEND_TZID as string) ?? tz) : null;
        const dur = end ? end.getTime() - start.getTime() : 0;
        const rule = (e.RRULE as string | undefined) ?? '';
        const isSeries = !e['RECURRENCE-ID'] && /FREQ=(DAILY|WEEKLY)/.test(rule);
        const exdates = new Set(String(e.EXDATE ?? '').split(',').filter(Boolean)
          .map(x => icsDate(x, normTz(e.EXDATE_TZID as string) ?? tz).toISOString()));
        const starts = isSeries ? expand(e.DTSTART as string, tz, rule, from, to)
          : start.getTime() >= from && start.getTime() <= to ? [start] : [];
        for (const st of starts) {
          const iso = st.toISOString();
          if (isSeries && (exdates.has(iso) || overridden.has(`${e.UID}@${iso}`))) continue;
          const uid = e['RECURRENCE-ID'] || isSeries ? `${e.UID}@${iso}` : String(e.UID);
          const title = String(e.SUMMARY ?? '(no title)').replace(/\s*\|\s*Partiful\s*$/i, '').trim();
          const key = `${title.toLowerCase().replace(/[^a-z0-9]/g, '')}|${iso}`;
          if (seen.has(key) && !rows.has(uid)) continue;
          seen.add(key);
          rows.set(uid, {
            uid, title, starts_at: iso,
            ends_at: dur ? new Date(st.getTime() + dur).toISOString() : null,
            attendees: e.ATTENDEE, location: e.LOCATION ?? null,
            description: String(e.DESCRIPTION ?? '').replace(/<https?:[^>]+>/g, '').slice(0, 2000),
            updated_at: new Date().toISOString(),
          });
          n++;
        }
      }
      report.push(`${new URL(url).host}: ${n}`);
    } catch (err) { report.push(`${(() => { try { return new URL(url).host; } catch { return `feed ${i + 1}`; } })()}: error ${(err as Error).message}`); }
  }
  if (rows.size) {
    const { error } = await db().from('calendar_events').upsert([...rows.values()], { onConflict: 'uid' });
    if (error) throw error;
  }
  return { calendar: `${rows.size} events in window (${report.join(', ')})` };
}

Deno.serve(handler(async (req) => {
  await requireCron(req);
  const out: Record<string, unknown> = {};
  for (const [name, fn] of [['bee', pollBee], ['calendar', pollCalendar]] as const) {
    try { Object.assign(out, await fn()); } catch (e) { out[name] = `error: ${(e as Error).message}`; }
  }
  return out;
}));
