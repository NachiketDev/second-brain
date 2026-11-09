// DIGEST (cron daily, morning): one email with what changed, why, and what needs a decision.
// Sends with Resend if RESEND_API_KEY is set; always returns the HTML so you can test it.
import { db, env, fmtDate, fmtTime, handler, requireCron } from '../_shared/lib.ts';

// deno-lint-ignore no-explicit-any
type Row = Record<string, any>;
const esc = (s: unknown) => String(s ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]!));

const C = { ink: '#172033', muted: '#5d677c', line: '#d9dee8', accent: '#2547d0', crit: '#b3261e', ok: '#1f7a4d', soft: '#f3f5f9' };

function link(p: Row, action: string, label: string, color = C.accent) {
  const url = `${env('SUPABASE_URL')}/functions/v1/act?id=${p.id}&t=${p.token}&do=${action}`;
  return `<a href="${url}" style="color:${color};font-weight:600;text-decoration:none;margin-right:14px">${label}</a>`;
}

function section(title: string, inner: string, note = '') {
  return inner ? `<h2 style="font:600 16px/1.3 Helvetica,Arial,sans-serif;color:${C.ink};margin:28px 0 4px">${title}</h2>` +
    (note ? `<p style="margin:0 0 10px;color:${C.muted};font-size:13px">${note}</p>` : '') + inner : '';
}

function item(title: string, body: string, actions = '', accent = C.line) {
  return `<div style="border-left:3px solid ${accent};padding:8px 12px;margin:8px 0;background:${C.soft}">
    <div style="font-weight:600;color:${C.ink}">${esc(title)}</div>
    ${body ? `<div style="color:${C.ink};font-size:14px;white-space:pre-wrap;margin-top:4px">${body}</div>` : ''}
    ${actions ? `<div style="margin-top:8px;font-size:14px">${actions}</div>` : ''}</div>`;
}

Deno.serve(handler(async (req) => {
  await requireCron(req);
  const sb = db();
  const since = new Date(Date.now() - 24 * 3600e3).toISOString();
  const [changes, props, deadlines, today] = await Promise.all([
    sb.from('recent_changes').select('*').gte('at', since).not('summary', 'like', '%now current%').limit(200),
    sb.from('proposals').select('*').eq('status', 'pending').order('priority').order('created_at'),
    sb.from('open_loops').select('action,due_at,owner').eq('owner', 'me').not('due_at', 'is', null)
      .lte('due_at', new Date(Date.now() + 7 * 864e5).toISOString().slice(0, 10)).order('due_at'),
    sb.from('calendar_events').select('title,starts_at').gte('starts_at', new Date().toISOString())
      .lte('starts_at', new Date(Date.now() + 24 * 3600e3).toISOString()).order('starts_at'),
  ]);
  const P = (props.data ?? []) as Row[];
  const by = (k: string) => P.filter(p => p.kind === k);

  // what changed, grouped by the source that caused it
  const groups = new Map<string, Row[]>();
  for (const c of (changes.data ?? []) as Row[]) {
    const k = c.source_title ? `${c.source_title} · ${fmtDate(c.source_at)}` : 'Your decisions';
    groups.set(k, [...(groups.get(k) ?? []), c]);
  }
  const changed = [...groups].map(([src, rows]) => `<div style="margin:10px 0"><div style="font-weight:600;color:${C.ink}">${esc(src)}</div>
    <ul style="margin:4px 0 0;padding-left:18px;color:${C.ink};font-size:14px">${rows.slice(0, 8).map(r =>
      `<li>${esc(r.summary)}${r.reason && !/^extracted|^explicit|^story/.test(r.reason) ? ` <span style="color:${C.muted}">(why: ${esc(r.reason)})</span>` : ''}</li>`).join('')}
    ${rows.length > 8 ? `<li style="color:${C.muted}">+${rows.length - 8} more</li>` : ''}</ul></div>`).join('');

  const html = `<div style="max-width:640px;margin:0 auto;font:15px/1.5 Helvetica,Arial,sans-serif;color:${C.ink}">
  <h1 style="font:700 22px/1.2 Helvetica,Arial,sans-serif;margin:0">Your brain, ${fmtDate(new Date(), { weekday: 'long', month: 'short', day: 'numeric' })}</h1>
  <p style="color:${C.muted};margin:4px 0 0">${P.length} suggestions waiting · ${(changes.data ?? []).length} changes in the last 24h</p>
  ${section('Today', (today.data ?? []).map((e: Row) => `<div>${fmtTime(e.starts_at)} · ${esc(e.title)}</div>`).join(''))}
  ${section('Briefings', by('briefing').map(p => item(p.title, esc(p.body), link(p, 'approve', 'Got it') + link(p, 'dismiss', 'Dismiss', C.muted), C.accent)).join(''))}
  ${section('Deadlines this week', (deadlines.data ?? []).map((d: Row) => `<div><b style="color:${C.crit}">${fmtDate(d.due_at + 'T12:00:00Z')}</b> · ${esc(d.action)}</div>`).join(''))}
  ${section('Needs a decision', by('review').map(p => item(p.title.replace(/^Still relevant\? /, ''), esc(p.body),
      link(p, 'keep', 'Keep') + link(p, 'drop', 'Drop', C.crit)), C.crit).join(''), 'Something these depended on changed.')}
  ${section('Block time?', by('calendar').map(p => item(p.title, esc(p.body), link(p, 'approve', 'Add to calendar') + link(p, 'dismiss', 'Dismiss', C.muted), C.crit)).join(''))}
  ${section('Owed to you', by('followup').map(p => item(p.title, esc(p.body), link(p, 'approve', 'Use draft') + link(p, 'dismiss', 'Not now', C.muted), C.ok)).join(''))}
  ${section(Deno.env.get('GOOGLE_CLIENT_SECRET') ? 'Add to Google Tasks?' : 'Add to Todoist?', by('task').slice(0, 15).map(p => item(p.title, esc(p.body),
      link(p, 'approve', 'Add') + link(p, 'done', 'Already done', C.ok) + link(p, 'dismiss', 'Dismiss', C.muted))).join(''),
      by('task').length > 15 ? `Showing 15 of ${by('task').length}.` : '')}
  ${section('What changed and why', changed)}
  <p style="color:${C.muted};font-size:12px;margin-top:32px">Every link asks you to confirm before anything happens.</p></div>`;

  const nothing = !P.length && !(changes.data ?? []).length;
  let sent = 'not sent';
  const key = Deno.env.get('RESEND_API_KEY');
  if (key && !nothing) {
    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { authorization: `Bearer ${key}`, 'content-type': 'application/json' },
      body: JSON.stringify({ from: Deno.env.get('DIGEST_FROM') ?? 'Second Brain <onboarding@resend.dev>',
        to: [env('DIGEST_EMAIL')], subject: `Brain · ${P.length} to review · ${fmtDate(new Date())}`, html }),
    });
    sent = res.ok ? 'sent' : `failed: ${await res.text()}`;
  }
  await sb.from('kv').upsert({ key: 'last_digest', value: { at: new Date().toISOString(), sent, html } });
  return { sent, suggestions: P.length, changes: (changes.data ?? []).length, html };
}));
