
(() => {

'use strict';
/* ---------- config (no data lives here; everything shown comes from the brain) ---------- */
const API_BASE = 'https://<your-project-ref>.supabase.co/functions/v1/desk/';
const TZ = 'America/New_York';
const REFRESH_MS = 5 * 60 * 1000;
const VIEWS = [['control', 'Control room'], ['workbench', 'Workbench'], ['observatory', 'Observatory'], ['planning', 'Planning'], ['mirror', 'Mirror'], ['trust', 'Trust']];
// Which goal box a commitment or event belongs to, by words in its text. Box keys come from goal_plan:<key> facts.
const BOX_WORDS = {
  career: ['apply', 'application', 'case', 'bcg', 'mckinsey', 'bain', 'coffee chat', 'resume', 'interview', 'recruit', 'pei', 'cisco', 'strategy&', 'amgen', 'l.e.k', 'office hours', 'cca', 'assessment', 'netflix', 'kkr', 'internship', 'mba associate'],
  impact: ['cfi', 'sea ranger', 'second brain', 'brain build', 'ship', 'mentor'],
  social: ['dinner', 'friendsgiving', 'lunch', 'birthday', 'mixer', 'party', 'chai', 'catan', 'board game'],
  together: ['reply', 'dietary', 'dues', 'treasurer', 'headshot', 'zelle', 'goals interview', 'plan', 'laundry'],
  body: ['gym', 'workout', 'run ', 'sleep', 'skincare', 'haircut', 'ski'],
  wealth: ['invest', 'savings', 'money', 'budget', 'income'],
  party: ['quest', 'pact', 'iit'],
  unique: ['hobby', 'otamatone', 'live cod', 'tarot', 'new thing', 'travel'],
};
const CLASS_RE = /^[A-Z]{2,5}\d? [A-Z]$/; // school section course codes like "FIN1 B"

/* ---------- tiny helpers ---------- */
const $ = (s) => document.querySelector(s);
const h = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const fmt = (d, o) => new Intl.DateTimeFormat('en-US', { timeZone: TZ, ...o }).format(new Date(d));
const ymd = (d) => new Intl.DateTimeFormat('en-CA', { timeZone: TZ }).format(new Date(d));
const time = (d) => fmt(d, { hour: 'numeric', minute: '2-digit' }).replace(':00', '').replace(' AM', 'am').replace(' PM', 'pm');
const daysBetween = (a, b) => Math.round((new Date(b + 'T12:00:00') - new Date(a + 'T12:00:00')) / 864e5);
const ago = (iso) => { const d = daysBetween(ymd(iso), ymd(Date.now())); return d <= 0 ? 'today' : d === 1 ? 'yesterday' : d + ' days'; };
const minsOf = (d) => { const p = fmt(d, { hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).split(':'); return +p[0] * 60 + +p[1]; };
const plural = (n, w) => n + ' ' + w + (n === 1 ? '' : 's');
const clean = (t) => String(t ?? '').replace(/^(FW|Fwd|RE|Re):\s*/i, '').replace(/\s*\|.*$/, '').trim();
const askClaude = (prompt) => 'https://claude.ai/new?q=' + encodeURIComponent(prompt);
const store = { get: (k, d) => { try { return localStorage.getItem(k) ?? d; } catch { return d; } }, set: (k, v) => { try { localStorage.setItem(k, v); } catch { /* storage off */ } } };
const ring = (pct, size = 52, stroke = 6, color = 'var(--ac)') => {
  const r = (size - stroke) / 2, c = 2 * Math.PI * r, off = c * (1 - Math.max(0, Math.min(1, pct)));
  return `<svg class="ring" width="${size}" height="${size}" viewBox="0 0 ${size} ${size}"><circle cx="${size / 2}" cy="${size / 2}" r="${r}" fill="none" stroke="var(--s2)" stroke-width="${stroke}"/>` +
    (pct > 0 ? `<circle class="v" style="--c:${c}" cx="${size / 2}" cy="${size / 2}" r="${r}" fill="none" stroke="${color}" stroke-width="${stroke}" stroke-linecap="round" stroke-dasharray="${c}" stroke-dashoffset="${off}" transform="rotate(-90 ${size / 2} ${size / 2})"/>` : '') + '</svg>';
};
const tickSvg = '<svg width="14" height="14" viewBox="0 0 24 24"><path d="M5 12.5l4.5 4.5L19 7.5" fill="none" stroke="var(--aci)" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/></svg>';
const toast = (m) => { const t = document.createElement('div'); t.className = 'toast'; t.textContent = m; document.body.appendChild(t); setTimeout(() => t.remove(), 2600); };

/* ---------- state ---------- */
let D = null, M = null; // raw data, derived model
const cleanToken = (v) => String(v ?? '').trim().replace(/[?#].*$/, '').split('/').filter(Boolean).pop() ?? '';
let token = (() => {
  let k = null; try { const u = new URL(location.href); k = u.searchParams.get('k'); if (k) { u.searchParams.delete('k'); history.replaceState(null, '', u.pathname + u.hash); } } catch { /* no URL access */ }
  if (k) { store.set('brain_token', cleanToken(k)); return cleanToken(k); }
  return cleanToken(store.get('brain_token', ''));
})();
const theme = () => store.get('theme', 'graphite');
document.documentElement.dataset.theme = theme();

/* ---------- data ---------- */
let MCP = null;
const SERVER = 'Second Brain'; // the claude.ai connector's display name
async function initMcp() { try { return window.claude?.use ? await window.claude.use('mcp') : null; } catch { return null; } }
async function load() {
  if (MCP) {
    const res = await MCP.callTool(SERVER, 'get_desk', {}, { cache: false });
    D = typeof res.payload === 'string' ? JSON.parse(res.payload) : res.payload;
    if (!D || !Array.isArray(D.commitments)) throw new Error('Unexpected reply from get_desk: ' + JSON.stringify(res.payload ?? res).slice(0, 160));
    M = derive(D);
    store.set('last_data', JSON.stringify(D));
    return;
  }
  const r = await fetch(API_BASE + encodeURIComponent(token), { cache: 'no-store', headers: { 'x-brain-token': token } });
  if (r.status === 404) throw new Error('token');
  if (!r.ok) throw new Error('HTTP ' + r.status);
  D = await r.json();
  M = derive(D);
  store.set('last_data', JSON.stringify(D));
}

function boxOf(text) {
  const t = ' ' + String(text).toLowerCase() + ' ';
  for (const [k, words] of Object.entries(BOX_WORDS)) if (words.some((w) => t.includes(w))) return k;
  return null;
}

function derive(d) {
  const today = d.day, wk = d.week_start, nowMs = Date.now();
  const weekEnd = ymd(new Date(new Date(wk + 'T12:00:00').getTime() + 6 * 864e5));
  const mine = d.commitments.filter((c) => c.owner === 'me');
  const open = mine.filter((c) => c.status === 'open' || c.status === 'needs_review');
  const overdue = open.filter((c) => c.due && c.due < today).sort((a, b) => a.due.localeCompare(b.due));
  const dueWeek = open.filter((c) => c.due && c.due >= today && c.due <= weekEnd).sort((a, b) => a.due.localeCompare(b.due));
  const undated = open.filter((c) => !c.due).sort((a, b) => a.updated.localeCompare(b.updated));
  const doneToday = mine.filter((c) => c.status === 'done' && ymd(c.updated) === today);
  const doneWeek = mine.filter((c) => c.status === 'done' && ymd(c.updated) >= wk);
  // Big 3: overdue first, then due soonest, then undated oldest. Today's completions stay visible as ticked.
  const big3 = [...doneToday.slice(0, 3).map((c) => ({ ...c, ticked: true }))];
  for (const c of [...overdue, ...dueWeek, ...undated]) { if (big3.length >= 3) break; big3.push(c); }

  // goals
  const g = (p) => d.goals.filter((x) => x.predicate === p).map((x) => x.value);
  const center = g('center_goal')[0] ?? null;
  const subs = g('sub_goal');
  const boxes = d.goals.filter((x) => x.predicate.startsWith('goal_plan:')).map((x) => {
    const key = x.predicate.split(':')[1];
    const sub = subs.find((s) => s.split(':')[0].toLowerCase().includes(key)) ?? key;
    const name = sub.split(':')[0].replace(/\s*\(.*\)$/, '');
    const plan = x.value.split('. Tracker:')[0];
    const tracker = (x.value.split('Tracker:')[1] ?? '').trim();
    const items = mine.filter((c) => boxOf(c.action) === key);
    const done = items.filter((c) => c.status === 'done' && ymd(c.updated) >= wk).length;
    const pending = items.filter((c) => (c.status === 'open' || c.status === 'needs_review') && (!c.due || c.due <= weekEnd)).length;
    const late = items.filter((c) => (c.status === 'open' || c.status === 'needs_review') && c.due && c.due < today).length;
    const evs = d.events.filter((e) => boxOf(e.title) === key && ymd(e.start) >= wk && ymd(e.start) <= weekEnd);
    const hours = evs.reduce((a, e) => a + (e.end ? (new Date(e.end) - new Date(e.start)) / 36e5 : 1), 0);
    return { key, name, plan, tracker, done, pending, late, hours, pct: done + pending ? done / (done + pending) : 0 };
  });

  // schedule with clashes
  const evToday = d.events.filter((e) => ymd(e.start) === today);
  const mark = (list) => list.map((e, i) => {
    const s = new Date(e.start).getTime(), en = e.end ? new Date(e.end).getTime() : s + 36e5;
    const clashes = list.filter((o, j) => j !== i && new Date(o.start).getTime() < en && (o.end ? new Date(o.end).getTime() : new Date(o.start).getTime() + 36e5) > s && !CLASS_RE.test(o.title));
    return { ...e, s, en, clash: clashes.length > 0 && !CLASS_RE.test(e.title), cls: CLASS_RE.test(e.title) };
  });
  const today_ev = mark(evToday);
  const nowEv = today_ev.find((e) => e.s <= nowMs && e.en > nowMs) ?? null;
  const nextEv = today_ev.find((e) => e.s > nowMs) ?? null;

  // people and clusters
  const byCluster = {};
  for (const p of d.people) {
    const k = p.parent_name || p.group_name || 'Others';
    (byCluster[k] ??= []).push(p);
  }
  const owe = new Set(open.map((c) => c.for).filter(Boolean));
  const owedToMe = d.commitments.filter((c) => c.owner !== 'me' && c.for === 'me' && c.status === 'open');
  const waitingOn = new Set(owedToMe.map((c) => c.owner));
  const clusters = Object.entries(byCluster).map(([name, ppl]) => ({
    name, ppl: ppl.sort((a, b) => (owe.has(b.id) - owe.has(a.id)) || (b.direct - a.direct) || String(b.last).localeCompare(String(a.last))),
    strength: ppl.reduce((a, p) => a + p.direct, 0), owe: ppl.filter((p) => owe.has(p.id)).length,
  })).sort((a, b) => (a.name === 'Others') - (b.name === 'Others') || b.ppl.length - a.ppl.length);

  // promises
  const kept = mine.filter((c) => c.status === 'done').length, dropped = mine.filter((c) => c.status === 'dropped').length;
  const monthStart = today.slice(0, 8) + '01';
  const keptMonth = mine.filter((c) => c.status === 'done' && ymd(c.updated) >= monthStart).length;
  const droppedMonth = mine.filter((c) => c.status === 'dropped' && ymd(c.updated) >= monthStart).length;
  const withDeadline = mine.filter((c) => c.due && c.status !== 'unknown');
  const selfHeld = mine.filter((c) => !c.due && c.status !== 'unknown');
  const rate = (l) => { const done = l.filter((c) => c.status === 'done').length, fin = l.filter((c) => c.status === 'done' || c.status === 'dropped').length; return { done, total: l.length, open: l.length - fin, pct: l.length ? done / l.length : 0 }; };

  // dormant: things you owe a person that have sat for 14+ days, oldest first
  const dormant = open.filter((c) => c.for && c.for !== 'me' && daysBetween(ymd(c.updated), today) >= 14)
    .map((c) => ({ ...c, age: daysBetween(ymd(c.updated), today) })).sort((a, b) => b.age - a.age);

  // next moves for the observatory: dormant people + overdue with a person, ranked by age
  const moves = [...dormant, ...overdue.filter((c) => c.for && !dormant.includes(c)).map((c) => ({ ...c, age: daysBetween(c.due, today) }))]
    .filter((v, i, a) => a.findIndex((x) => x.id === v.id) === i).slice(0, 4);

  // skills: improve vs strength by month
  const skillMonths = {};
  for (const s of d.skills) { const m = String(s.at).slice(0, 7); (skillMonths[m] ??= { improve: 0, strength: 0 })[s.predicate.endsWith('strength') ? 'strength' : 'improve']++; }

  // pursuits
  const recruiting = d.stories.filter((s) => /recruiting/i.test(s.title));
  const other = d.stories.filter((s) => !/recruiting/i.test(s.title));
  const firmWord = (s) => s.title.split(/[ (]/)[0].toLowerCase().replace(/[^a-z&.]/g, '');
  const firms = recruiting.map((s) => {
    const w = firmWord(s);
    const next = open.find((c) => c.action.toLowerCase().includes(w)) ?? null;
    const ppl = d.people.filter((p) => String(p.parent_name ?? '').toLowerCase().startsWith(w));
    return { ...s, next, ppl, quiet: daysBetween(ymd(s.updated), today) };
  }).sort((a, b) => b.events - a.events);

  return { today, wk, weekEnd, mine, open, overdue, dueWeek, undated, doneToday, doneWeek, big3, center, boxes, today_ev, nowEv, nextEv,
    clusters, owe, owedToMe, waitingOn, kept, dropped, keptMonth, droppedMonth, ded: rate(withDeadline), self: rate(selfHeld), dormant, moves, skillMonths,
    firms, other, values: g('core_value') };
}

/* ---------- shell ---------- */
function mode() {
  const m = store.get('mode', 'auto'); if (m !== 'auto') return m;
  const hr = +fmt(Date.now(), { hour: '2-digit', hourCycle: 'h23' });
  return hr >= 23 || hr < 6 ? 'night' : hr < 10 ? 'morning' : hr >= 19 ? 'evening' : 'day';
}
const view = () => (location.hash.slice(1) || 'control');

function header(sub) {
  const v = view();
  return `<header>
    <div class="col" style="gap:2px"><div class="h" style="font-size:30px">${h(VIEWS.find((x) => x[0] === v)?.[1] ?? '')}</div><div class="mu" style="font-size:14px">${sub}</div></div>
    <nav>${VIEWS.map(([k, l]) => `<a href="#${k}" class="${k === v ? 'on' : ''}">${l}</a>`).join('')}</nav>
    <div class="col" style="gap:0;align-items:flex-end;min-width:150px"><div class="h" id="clock" style="font-size:30px">${time(Date.now())}</div><div class="mu" style="font-size:13px">${fmt(Date.now(), { weekday: 'long', month: 'short', day: 'numeric' })}</div></div>
  </header>`;
}

function footer() {
  const hl = D.health ?? {};
  const fresh = hl.last_compiled ? (Date.now() - new Date(hl.last_compiled)) / 36e5 : 99;
  return `<footer><span class="dot" style="background:${fresh < 7 ? 'var(--good)' : 'var(--warn)'}"></span>
    <span>Brain compiled ${hl.last_compiled ? ago(hl.last_compiled) + ' at ' + time(hl.last_compiled) : 'never'}</span>
    <span>${plural(hl.waiting ?? 0, 'source')} waiting</span>
    <span>Screen refreshed ${time(Date.now())}</span>
    <span style="margin-left:auto" class="row">
      ${['graphite', 'paper', 'midnight', 'arctic'].map((t) => `<button data-theme-set="${t}" class="pill" style="${t === theme() ? 'background:var(--ac);color:var(--aci)' : ''}">${t}</button>`).join('')}
      <button data-mode-set class="pill">mode: ${store.get('mode', 'auto')}</button>
      <button class="pill" data-reload>Reload</button>
    </span></footer>`;
}

/* ---------- views ---------- */
const VIEW_FN = {};

VIEW_FN.control = () => {
  const m = M, md = mode();
  const clashes = m.today_ev.filter((e) => e.clash);
  const parts = [];
  if (m.overdue.length) parts.push(`${plural(m.overdue.length, 'thing')} overdue`);
  if (m.dueWeek.length) parts.push(`${m.dueWeek.length} due this week`);
  if (clashes.length) parts.push(`${clean(clashes[0].title)} clashes with ${plural(clashes.length - 1, 'other event')}`);
  const headline = parts.length ? parts.join('. ') + '.' : 'Nothing overdue and nothing clashing. Protect your Big 3.';
  const allDone = m.big3.length && m.big3.every((c) => c.ticked);

  const tl = m.today_ev.length ? m.today_ev.map((e) => `<div class="ev ${e === m.nowEv ? 'now' : ''} ${e.en < Date.now() ? 'past' : ''} ${e.clash ? 'clash' : ''}">
      <div class="mu" style="width:62px;flex:none">${time(e.start)}</div><div class="grow"><div class="t clip" style="font-weight:${e.cls ? 500 : 600}">${h(clean(e.title))}</div>${e.clash ? '<div class="wn" style="font-size:12px">clashes</div>' : ''}</div></div>`).join('')
    : '<div class="empty">No events today.</div>';

  const big3 = m.big3.length ? m.big3.map((c) => `<div class="item" style="background:transparent;padding:8px 0">
      <button class="tick ${c.ticked ? 'on' : ''}" data-done="${c.id}" aria-label="Mark done">${tickSvg}</button>
      <div class="grow"><div class="${c.ticked ? 'done-txt' : ''}" style="font-size:16px;font-weight:600;line-height:1.35">${h(c.action)}</div>
      <div class="mu" style="font-size:12.5px;margin-top:3px">${c.ticked ? '<span class="gd">done today</span>' : c.due ? (c.due < m.today ? `<span class="wn">overdue since ${fmt(c.due + 'T12:00', { month: 'short', day: 'numeric' })}</span>` : 'due ' + fmt(c.due + 'T12:00', { weekday: 'short', month: 'short', day: 'numeric' })) : 'no date'}${boxOf(c.action) ? ' · ' + boxName(boxOf(c.action)) : ''}</div></div></div>`).join('')
    : '<div class="empty">No open commitments. Add your Big 3 in the morning check-in.</div>';

  const week = [...m.overdue, ...m.dueWeek].filter((c) => !m.big3.find((b) => b.id === c.id)).slice(0, 5);
  const yes = D.needs_yes.slice(0, 3);
  const brief = (D.brief?.meeting_briefings ?? [])[0];

  const middle = md === 'evening' || allDone ? `
    <div class="card rise" style="background:var(--acs);flex-direction:row;align-items:center;gap:22px">
      <div style="width:64px;height:64px;border-radius:32px;background:var(--ac);display:flex;align-items:center;justify-content:center;animation:pop .6s">${tickSvg.replace('width="14" height="14"', 'width="34" height="34"')}</div>
      <div class="col" style="gap:4px"><div class="h" style="font-size:28px">${allDone ? 'Day complete' : 'Wrapping up'}</div>
      <div class="mu">${plural(m.doneToday.length, 'commitment')} closed today · ${plural(m.doneWeek.length, 'commitment')} this week</div></div>
      <a class="btn" style="margin-left:auto" target="_blank" href="${askClaude('Evening check-in')}">Start evening check-in</a></div>` : '';

  const boxes = m.boxes.map((b) => `<div class="row" style="padding:10px 12px;border-radius:14px;background:var(--s2)">
      <div style="position:relative">${ring(b.pct, 50, 6, b.late ? 'var(--warn)' : 'var(--ac)')}<div style="position:absolute;inset:0;display:flex;align-items:center;justify-content:center;font-size:12px;font-weight:700">${b.done + b.pending ? b.done + '/' + (b.done + b.pending) : '–'}</div></div>
      <div class="grow"><div style="font-weight:600;font-size:14.5px" class="clip">${h(b.name)}</div>
      <div class="mu clip" style="font-size:12px">${b.done + b.pending ? (b.late ? `<span class="wn">${b.late} late</span> · ` : '') + (b.hours ? b.hours.toFixed(1) + ' h booked' : 'this week') : (b.hours ? b.hours.toFixed(1) + ' h booked this week' : 'nothing linked yet')}</div></div></div>`).join('');

  return `${header(h(m.center ?? 'Center goal not set'))}
  <main style="grid-template-columns:420px minmax(0,1fr) 440px">
    <section class="col" style="gap:18px">
      <div class="card" style="background:var(--acs)">
        <div class="lbl ac">${m.nowEv ? 'Now · until ' + time(m.nowEv.en) : 'Next'}</div>
        <div class="h" style="font-size:24px;line-height:1.25">${h(clean((m.nowEv ?? m.nextEv)?.title ?? 'Free for the rest of today'))}</div>
        <div class="mu" style="font-size:14px">${m.nowEv && m.nextEv ? 'Then ' + time(m.nextEv.start) + ' · ' + h(clean(m.nextEv.title)) : (m.nextEv && !m.nowEv ? 'Starts ' + time(m.nextEv.start) + (m.nextEv.location ? ' · ' + h(m.nextEv.location) : '') : '')}</div>
      </div>
      <div class="card grow"><div class="lbl">Today · ${plural(m.today_ev.length, 'event')}${clashes.length ? ` · <span class="wn">${clashes.length} clashing</span>` : ''}</div><div class="tl" style="overflow:hidden">${tl}</div></div>
    </section>
    <section class="col" style="gap:18px;min-width:0">
      <div class="h rise" style="font-size:30px;line-height:1.2;padding:4px 4px 0">${h(headline)}</div>
      ${middle}
      <div class="card"><div class="row"><div class="lbl grow">Big 3 · ${m.big3.filter((c) => c.ticked).length} of ${m.big3.length} done</div>${ring(m.big3.length ? m.big3.filter((c) => c.ticked).length / m.big3.length : 0, 34, 5)}</div>${big3}</div>
      <div class="row" style="gap:18px;align-items:stretch;flex:1;min-height:0">
        <div class="card grow"><div class="lbl">Also this week</div>${week.length ? week.map((c) => `<div class="row" style="font-size:14px"><span class="${c.due < m.today ? 'wn' : 'mu'}" style="width:62px;flex:none">${fmt(c.due + 'T12:00', { weekday: 'short' })}</span><span class="cl2 grow">${h(c.action)}</span></div>`).join('') : '<div class="empty">Nothing else due.</div>'}</div>
        <div class="card grow"><div class="lbl">Needs your yes · ${D.needs_yes.length}</div>${yes.length ? yes.map((p) => `<div class="col" style="gap:6px;padding-bottom:10px;border-bottom:1px solid var(--line)"><div class="cl2" style="font-size:14px;font-weight:600">${h(p.title)}</div><div class="row"><span class="mu" style="font-size:12px">${ago(p.created)}</span><a class="btn sm" style="margin-left:auto" target="_blank" href="${askClaude('Review this draft with me before I send it:\n\n' + p.body)}">Review</a></div></div>`).join('') : '<div class="empty">Nothing waiting for you.</div>'}</div>
      </div>
    </section>
    <section class="col" style="gap:18px">
      <div class="card"><div class="lbl">Goal boxes · this week</div><div style="display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);gap:10px">${boxes || '<div class="empty">No goal plans in the brain yet.</div>'}</div></div>
      ${brief ? `<div class="card grow"><div class="lbl">Before ${h(brief.title.replace(/^Briefing:\s*/, ''))}</div><div style="font-size:13.5px;line-height:1.5;overflow:hidden" class="grow">${md2html(brief.briefing.split('**Use this meeting to**')[1] ?? brief.briefing)}</div></div>` : ''}
      <div class="card"><div class="lbl">Owed to you · ${m.owedToMe.length}</div>${m.owedToMe.slice(0, 3).map((c) => `<div class="row" style="font-size:13.5px"><span class="cl2 grow">${h(c.action)}</span><span class="mu" style="font-size:12px">${ago(c.updated)}</span></div>`).join('') || '<div class="empty">Nobody owes you anything.</div>'}</div>
    </section>
  </main>${footer()}`;
};

const boxName = (k) => M.boxes.find((b) => b.key === k)?.name ?? k;
function md2html(s) {
  return h(s).replace(/\*\*(.+?)\*\*/g, '<b>$1</b>').split('\n').filter((l) => l.trim()).map((l) => l.startsWith('- ') ? `<div style="display:flex;gap:8px;margin:5px 0"><span class="ac">•</span><span>${l.slice(2)}</span></div>` : `<div style="margin:6px 0">${l}</div>`).join('');
}

VIEW_FN.workbench = () => {
  const m = M;
  const sel = store.get('pursuit', 'recruiting');
  const pursuits = [{ id: 'recruiting', title: 'Recruiting', events: m.firms.reduce((a, f) => a + f.events, 0), updated: m.firms.map((f) => f.updated).sort().pop() }, ...m.other];
  const side = pursuits.map((p) => `<button data-pursuit="${h(p.id)}" class="item" style="text-align:left;background:${p.id === sel ? 'var(--acs)' : 'var(--s2)'};flex-direction:column;gap:2px">
      <div style="font-weight:600;font-size:14.5px" class="clip">${h(p.title)}</div><div class="mu" style="font-size:12px">${plural(p.events, 'update')} · last ${p.updated ? ago(p.updated) : 'never'}</div></button>`).join('');
  let body;
  if (sel === 'recruiting') {
    const quiet = m.firms.filter((f) => f.quiet >= 7);
    const head = `${plural(m.firms.length, 'firm')} in play. ${quiet.length ? quiet.map((f) => f.title.split(' (')[0]).join(', ') + ' quiet for a week or more.' : 'All active this week.'}`;
    body = `<div class="h" style="font-size:28px;line-height:1.2">${h(head)}</div>
      <div style="display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:16px;overflow:hidden;align-content:start" class="grow">${m.firms.map((f) => `<div class="card" style="gap:10px">
        <div class="row"><div class="h grow clip" style="font-size:19px">${h(f.title)}</div><span class="pill ${f.quiet >= 7 ? 'wn' : ''}">${f.quiet <= 0 ? 'today' : f.quiet + 'd quiet'}</span></div>
        <div class="col" style="gap:6px">${(f.notes ?? []).slice(0, 2).map((n) => `<div class="row" style="font-size:13px;align-items:flex-start;gap:10px"><span class="mu" style="width:46px;flex:none">${fmt(n.at, { month: 'short', day: 'numeric' })}</span><span class="cl2">${h(n.note ?? n.title)}</span></div>`).join('') || `<div class="mu cl2" style="font-size:13px">${h(f.summary ?? '')}</div>`}</div>
        <div class="row" style="flex-wrap:wrap;gap:6px">${f.ppl.sort((a, b) => b.direct - a.direct).slice(0, 4).map((p) => `<span class="pill" style="${M.owe.has(p.id) ? 'color:var(--warn)' : ''}">${h(p.name.split(' ')[0])}</span>`).join('')}${f.ppl.length > 4 ? `<span class="pill mu">+${f.ppl.length - 4}</span>` : ''}${f.ppl.length ? '' : '<span class="mu" style="font-size:12.5px">No contacts yet</span>'}</div>
        ${f.next ? `<div class="item" style="padding:10px 12px"><button class="tick" data-done="${f.next.id}">${tickSvg}</button><div class="grow" style="font-size:13.5px"><div class="lbl" style="font-size:11px">Next move</div><div class="cl2">${h(f.next.action)}</div></div></div>` : `<a class="btn ghost sm" style="align-self:flex-start;padding-left:0" target="_blank" href="${askClaude('What is my next move for ' + f.title + '? Use my second brain.')}">No next move set · ask Claude</a>`}
      </div>`).join('')}</div>`;
  } else {
    const s = m.other.find((x) => x.id === sel) ?? m.other[0];
    const nexts = s ? m.open.filter((c) => s.title.toLowerCase().split(/[ (/:]/).filter((w) => w.length > 3).some((w) => c.action.toLowerCase().includes(w))) : [];
    body = s ? `<div class="h" style="font-size:28px">${h(s.title)}</div><div class="card"><div style="font-size:15px;line-height:1.55">${h(s.summary ?? '')}</div></div>
      <div class="row" style="gap:18px;align-items:stretch" class="grow"><div class="card grow"><div class="lbl">Recent</div>${(s.notes ?? []).map((n) => `<div class="row" style="font-size:14px;align-items:flex-start"><span class="mu" style="width:70px;flex:none">${fmt(n.at, { month: 'short', day: 'numeric' })}</span><span>${h(n.note ?? n.title)}</span></div>`).join('')}</div>
      <div class="card grow"><div class="lbl">Open moves · ${nexts.length}</div>${nexts.map((c) => `<div class="item"><button class="tick" data-done="${c.id}">${tickSvg}</button><div class="grow" style="font-size:14px">${h(c.action)}</div></div>`).join('') || '<div class="empty">No open moves linked to this pursuit.</div>'}</div></div>` : '<div class="empty">No pursuits yet.</div>';
  }
  const lessons = D.patterns.slice(0, 4);
  return `${header('Every pursuit in one place · recruiting is one of them')}
  <main style="grid-template-columns:320px minmax(0,1fr) 400px">
    <aside class="col" style="gap:8px;overflow:hidden"><div class="lbl" style="padding:4px">Pursuits · ${pursuits.length}</div>${side}</aside>
    <section class="col" style="gap:18px;min-width:0">${body}</section>
    <aside class="col" style="gap:18px"><div class="card grow"><div class="lbl">Lessons the brain has noticed</div>${lessons.map((p) => `<div class="col" style="gap:4px;padding-bottom:10px;border-bottom:1px solid var(--line)"><div style="font-weight:600;font-size:14.5px">${h(p.title)}</div><div class="mu cl2" style="font-size:13px;line-height:1.45">${h(p.description)}</div></div>`).join('')}</div></aside>
  </main>${footer()}`;
};

VIEW_FN.observatory = () => {
  const m = M;
  const total = m.clusters.reduce((a, c) => a + c.ppl.length, 0);
  const top = m.clusters[0];
  const headline = top ? `${top.name} is ${Math.round(top.ppl.length / Math.max(1, total) * 100)}% of the people in your brain.${m.dormant.length ? ` ${plural(m.dormant.length, 'promise')} to people sat 2+ weeks.` : ''}` : 'No people in the brain yet.';
  const cl = m.clusters.slice(0, 8);
  return `${header('Patterns across people, time and promises')}
  <main style="grid-template-columns:minmax(0,1fr) 440px">
    <section class="col" style="gap:18px;min-width:0">
      <div class="card grow" style="gap:4px">
        <div class="row" style="align-items:flex-start"><div class="col grow" style="gap:4px"><div class="lbl">Constellation · ${total} people</div><div class="h" style="font-size:26px">${h(headline)}</div></div>
        <div class="row mu" style="font-size:13px;gap:16px;padding-top:6px"><span class="row" style="gap:6px"><i class="dot" style="background:var(--ac);width:10px;height:10px;border-radius:5px"></i>You've talked directly</span><span class="row" style="gap:6px"><i style="width:10px;height:10px;border-radius:5px;border:2px solid var(--warn);display:inline-block"></i>You owe them</span><span class="row" style="gap:6px"><i class="dot" style="background:var(--mu);opacity:.5;width:10px;height:10px;border-radius:5px"></i>Mentioned only</span></div></div>
        ${constellation(cl)}
      </div>
      <div style="display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:18px;height:230px">
        <div class="card"><div class="lbl">Promise reliability</div>
          ${[['With a deadline', m.ded], ['Only you hold', m.self]].map(([l, r]) => `<div class="col" style="gap:6px"><div class="row" style="font-size:13.5px"><span class="grow">${l}</span><b>${Math.round(r.pct * 100)}%</b><span class="mu">kept of ${r.total}</span></div><div class="bar"><i style="width:${r.pct * 100}%;background:var(--ac)"></i></div></div>`).join('')}
          <div style="font-size:13.5px;line-height:1.45">${m.ded.pct - m.self.pct > 0.15 ? 'Deadlines from others get done. Promises only you hold drift.' : 'Your own promises hold up about as well as deadlines.'}</div></div>
        <div class="card"><div class="lbl">Case and class feedback by month</div>${skillChart(m.skillMonths)}</div>
        <div class="card"><div class="lbl">Dormant value · ${m.dormant.length}</div>${m.dormant.slice(0, 4).map((c) => `<div class="row" style="font-size:13.5px"><span class="cl2 grow">${h(c.action)}</span><span class="wn" style="font-weight:600;white-space:nowrap">${c.age}d</span></div>`).join('') || '<div class="empty">Nothing sitting idle.</div>'}</div>
      </div>
    </section>
    <aside class="col" style="gap:18px">
      <div class="card grow"><div class="lbl">Next moves · oldest first</div>
        ${m.moves.map((c, i) => `<div class="item" style="flex-direction:column;gap:6px;${i === 0 ? 'background:var(--acs)' : ''}"><div class="row"><b class="grow clip">${h(c.for_name ?? c.for)}</b><span class="${c.age >= 14 ? 'wn' : 'mu'}" style="font-size:12px;font-weight:600">${c.age}d</span></div><div class="mu cl2" style="font-size:13px">${h(c.action)}</div>
        <div class="row"><a class="btn sm" target="_blank" href="${askClaude('Help me draft this for ' + (c.for_name ?? c.for) + ': ' + c.action + '. Use my second brain for context. Do not send anything.')}">Draft it</a><button class="btn ghost sm" data-done="${c.id}">Mark done</button></div></div>`).join('') || '<div class="empty">No moves waiting. Nice.</div>'}
      </div>
      <div class="card"><div class="lbl">Lenses waiting for data</div>${[['Time use', 'calendar events tagged by box'], ['Habits', 'evening habit ticks'], ['Money', 'a savings and spending feed'], ['Health and body', 'workouts and sleep']].map(([n, w]) => `<div class="row" style="font-size:13.5px"><span style="font-weight:600;width:130px">${n}</span><span class="mu">needs ${w}</span></div>`).join('')}</div>
    </aside>
  </main>${footer()}`;
};

function constellation(cl) {
  const W = 1340, H = 560, cx = W / 2, cy = H / 2;
  const n = cl.length; if (!n) return '<div class="empty">No people yet.</div>';
  const out = [], links = [], glows = [];
  cl.forEach((c, i) => {
    const ang = -Math.PI / 2 + i * 2 * Math.PI / n;
    const x = cx + Math.cos(ang) * 500, y = cy + Math.sin(ang) * 205;
    const ppl = c.ppl.slice(0, 4), more = c.ppl.length - ppl.length;
    const cols = ppl.length >= 3 ? 2 : ppl.length, rows = Math.ceil(ppl.length / cols), dx = 104, dy = 46;
    const hw = cols * dx / 2 + 26, hh = rows * dy / 2 + 34;
    const warm = c.owe >= 2;
    glows.push(`<ellipse cx="${x}" cy="${y}" rx="${hw}" ry="${hh}" fill="url(#${warm ? 'gw' : 'ga'})"/>`);
    const ux = (x - cx), uy = (y - cy), L = Math.hypot(ux, uy), vx = ux / L, vy = uy / L;
    const k = 0.82 / Math.sqrt((vx / hw) ** 2 + (vy / hh) ** 2), ex = x - vx * k, ey = y - vy * k, sx = cx + vx * 38, sy = cy + vy * 38;
    const mx = (sx + ex) / 2 - vy * 28, my = (sy + ey) / 2 + vx * 28;
    links.push(`<path d="M${sx} ${sy}Q${mx} ${my} ${ex} ${ey}" fill="none" stroke="var(--mu)" stroke-opacity=".35" stroke-width="${Math.max(1, Math.min(7, c.strength / 4))}" stroke-linecap="round"/>`);
    const top = y - (rows - 1) / 2 * dy - 30;
    out.push(`<text x="${x}" y="${top - 6}" text-anchor="middle" font-size="12" font-weight="700" letter-spacing="1.2" fill="${warm ? 'var(--warn)' : 'var(--tx)'}">${h(c.name.toUpperCase().replace(/\s*\(.*\)/, ''))}</text><text x="${x}" y="${top + 9}" text-anchor="middle" font-size="11" fill="var(--mu)">${plural(c.ppl.length, 'person').replace('persons', 'people')}${c.owe ? ' · ' + c.owe + ' owed' : ''}${more > 0 ? ' · +' + more + ' more' : ''}</text>`);
    ppl.forEach((p, j) => {
      const col = j % cols, row = Math.floor(j / cols);
      const px = x + (col - (cols - 1) / 2) * dx, py = y + (row - (rows - 1) / 2) * dy;
      const owe = M.owe.has(p.id), direct = p.direct > 0, r = 4 + Math.min(4, p.direct);
      out.push(`<circle cx="${px}" cy="${py}" r="${r}" fill="${owe ? 'var(--s1)' : direct ? 'var(--ac)' : 'var(--mu)'}" fill-opacity="${owe || direct ? 1 : .5}" stroke="${owe ? 'var(--warn)' : 'none'}" stroke-width="2"/><text x="${px}" y="${py + r + 14}" text-anchor="middle" font-size="11.5" font-weight="${owe ? 700 : 500}" fill="${owe ? 'var(--warn)' : direct ? 'var(--tx)' : 'var(--mu)'}">${h(p.name.length > 16 ? p.name.split(' ')[0] : p.name)}</text>`);
    });
  });
  return `<svg viewBox="0 0 ${W} ${H}" style="width:100%;flex:1;min-height:0" font-family="Inter,sans-serif" role="img" aria-label="People grouped by context around you">
    <defs><radialGradient id="ga"><stop offset="0" stop-color="var(--ac)" stop-opacity=".16"/><stop offset=".7" stop-color="var(--ac)" stop-opacity=".05"/><stop offset="1" stop-color="var(--ac)" stop-opacity="0"/></radialGradient>
    <radialGradient id="gw"><stop offset="0" stop-color="var(--warn)" stop-opacity=".15"/><stop offset=".7" stop-color="var(--warn)" stop-opacity=".04"/><stop offset="1" stop-color="var(--warn)" stop-opacity="0"/></radialGradient>
    <radialGradient id="gy"><stop offset="0" stop-color="var(--ac)" stop-opacity=".35"/><stop offset="1" stop-color="var(--ac)" stop-opacity="0"/></radialGradient></defs>
    ${links.join('')}${glows.join('')}${out.join('')}
    <circle cx="${cx}" cy="${cy}" r="70" fill="url(#gy)"/><circle cx="${cx}" cy="${cy}" r="30" fill="var(--ac)"/><text x="${cx}" y="${cy + 6}" text-anchor="middle" font-size="15" font-weight="700" fill="var(--aci)" font-family="Space Grotesk,sans-serif">You</text></svg>`;
}

function skillChart(sm) {
  const ms = Object.keys(sm).sort().slice(-4);
  if (!ms.length) return '<div class="empty">No feedback captured yet.</div>';
  const max = Math.max(...ms.map((k) => sm[k].improve + sm[k].strength));
  return `<div class="row grow" style="align-items:flex-end;gap:14px;padding-top:6px">${ms.map((k) => `<div class="col grow" style="gap:4px;align-items:center;height:100%;justify-content:flex-end">
    <div style="width:100%;display:flex;flex-direction:column;justify-content:flex-end;height:110px"><div style="height:${sm[k].strength / max * 100}%;background:var(--ac);border-radius:6px 6px 0 0"></div><div style="height:${sm[k].improve / max * 100}%;background:var(--warn);opacity:.75"></div></div>
    <div class="mu" style="font-size:12px">${fmt(k + '-15T12:00', { month: 'short' })}</div></div>`).join('')}</div>
    <div class="row mu" style="font-size:12px;gap:14px"><span class="ac">■ strengths</span><span class="wn">■ to improve</span></div>`;
}

VIEW_FN.planning = () => {
  const m = M, startH = 8, endH = 22, ph = 48;
  const days = [...Array(7)].map((_, i) => ymd(new Date(new Date(m.wk + 'T12:00:00').getTime() + i * 864e5)));
  const evs = D.events.filter((e) => ymd(e.start) >= m.wk && ymd(e.start) <= m.weekEnd);
  const byDay = days.map((d) => {
    const l = evs.filter((e) => ymd(e.start) === d);
    return l.map((e, i) => { const s = new Date(e.start).getTime(), en = e.end ? new Date(e.end).getTime() : s + 36e5; const cls = CLASS_RE.test(e.title);
      const clash = !cls && l.some((o, j) => j !== i && !CLASS_RE.test(o.title) && new Date(o.start).getTime() < en && (o.end ? new Date(o.end).getTime() : new Date(o.start).getTime() + 36e5) > s);
      return { ...e, s, en, cls, clash }; });
  }).map((l) => { l.sort((a, b) => a.s - b.s); const lanes = []; for (const e of l) { let i = lanes.findIndex((end) => end <= e.s); if (i < 0) { i = lanes.length; lanes.push(0); } lanes[i] = e.en; e.lane = i; }
    for (const e of l) e.lanes = Math.max(...l.filter((o) => o.s < e.en && o.en > e.s).map((o) => o.lane)) + 1; return l; });
  const booked = byDay.map((l) => l.reduce((a, e) => a + Math.min(e.en - e.s, 4 * 36e5) / 36e5, 0));
  const free = booked.map((b) => Math.max(0, (endH - startH) - b));
  const clashes = byDay.flat().filter((e) => e.clash);
  const dueBy = days.map((d) => m.open.filter((c) => c.due === d));
  const hours = [...Array(endH - startH)].map((_, i) => startH + i);
  const grid = `<div class="wk" style="height:${(endH - startH) * ph + 64}px">
    <div></div>${days.map((d) => `<div class="row" style="height:30px;font-size:13px;font-weight:600;${d === m.today ? 'color:var(--ac)' : ''}">${fmt(d + 'T12:00', { weekday: 'short', day: 'numeric' })}<span class="mu" style="font-weight:500;font-size:12px;margin-left:auto">${free[days.indexOf(d)].toFixed(0)}h free</span></div>`).join('')}
    <div></div>${days.map((d, i) => `<div style="height:34px;padding:2px 3px">${dueBy[i].length ? `<div class="blk due clip" style="position:static;height:28px;line-height:18px;white-space:nowrap" title="${h(dueBy[i].map((c) => c.action).join('\n'))}">⚑ ${dueBy[i].length > 1 ? dueBy[i].length + ' due' : h(dueBy[i][0].action)}</div>` : ''}</div>`).join('')}
    <div style="position:relative">${hours.map((hr) => `<div class="mu" style="height:${ph}px;font-size:11px">${hr > 12 ? hr - 12 + 'pm' : hr + (hr === 12 ? 'pm' : 'am')}</div>`).join('')}</div>
    ${byDay.map((l, i) => `<div style="position:relative;border-left:1px solid var(--line);height:${(endH - startH) * ph}px">${l.map((e) => { const st = Math.max(0, minsOf(e.start) - startH * 60), du = Math.max(25, (e.en - e.s) / 6e4); return `<div class="blk ${e.cls ? 'class' : ''} ${e.clash ? 'clash' : ''}" style="left:calc(${e.lane / e.lanes * 100}% + 3px);right:auto;width:calc(${100 / e.lanes}% - 6px);top:${st / 60 * ph}px;height:${Math.min(du, (endH * 60 - startH * 60) - st) / 60 * ph - 2}px"><b>${h(clean(e.title))}</b><div class="mu">${time(e.start)}</div></div>`; }).join('')}</div>`).join('')}
  </div>`;
  const totalFree = free.reduce((a, b) => a + b, 0), totalBooked = booked.reduce((a, b) => a + b, 0);
  return `${header('Week of ' + fmt(m.wk + 'T12:00', { month: 'short', day: 'numeric' }))}
  <main style="grid-template-columns:minmax(0,1fr) 420px">
    <section class="card" style="overflow:hidden">${grid}</section>
    <aside class="col" style="gap:18px">
      <div class="card"><div class="lbl">Capacity</div><div class="h" style="font-size:26px">${totalBooked.toFixed(0)}h booked · ${totalFree.toFixed(0)}h open</div>
        <div class="bar" style="height:12px"><i style="width:${totalBooked / (totalBooked + totalFree) * 100}%;background:var(--ac)"></i></div>
        <div class="mu" style="font-size:13px">Between ${startH}am and ${endH - 12}pm, ${days.length} days</div></div>
      <div class="card"><div class="lbl">Hours by goal box</div>${m.boxes.filter((b) => b.hours).sort((a, b) => b.hours - a.hours).map((b) => `<div class="row" style="font-size:13.5px"><span style="width:150px" class="clip">${h(b.name)}</span><div class="bar grow"><i style="width:${b.hours / Math.max(...m.boxes.map((x) => x.hours)) * 100}%;background:var(--ac)"></i></div><span style="width:44px;text-align:right">${b.hours.toFixed(1)}h</span></div>`).join('') || '<div class="empty">No events matched to goal boxes yet.</div>'}
        ${m.boxes.filter((b) => !b.hours).length ? `<div class="mu" style="font-size:12.5px">Zero hours: ${m.boxes.filter((b) => !b.hours).map((b) => h(b.name)).join(', ')}</div>` : ''}</div>
      <div class="card grow"><div class="lbl">Decide · ${clashes.length ? Math.ceil(clashes.length / 2) + ' clash' + (clashes.length > 2 ? 'es' : '') : 'no clashes'}</div>
        ${clashes.slice(0, 6).map((e) => `<div class="row" style="font-size:13.5px"><span class="wn" style="width:84px;flex:none">${fmt(e.start, { weekday: 'short' })} ${time(e.start)}</span><span class="clip grow">${h(clean(e.title))}</span></div>`).join('') || '<div class="empty">Nothing overlaps this week.</div>'}
        <a class="btn" style="margin-top:auto;align-self:flex-start" target="_blank" href="${askClaude('Plan my week with me using my second brain: clashes, Big 3 per day, and what to drop.')}">Plan the week with Claude</a></div>
    </aside>
  </main>${footer()}`;
};

VIEW_FN.mirror = () => {
  const m = M;
  const mStart = m.today.slice(0, 8) + '01';
  const verdict = (b) => b.late ? ['Behind', 'var(--warn)'] : b.done ? ['Moving', 'var(--good)'] : b.pending ? ['Not started', 'var(--warn)'] : ['No data', 'var(--mu)'];
  const boxRows = m.boxes.map((b) => { const doneM = m.mine.filter((c) => c.status === 'done' && ymd(c.updated) >= mStart && boxOf(c.action) === b.key).length; const v = doneM ? (b.late ? ['Behind', 'var(--warn)'] : ['Moving', 'var(--good)']) : verdict(b); return { ...b, doneM, v }; });
  const failing = boxRows.filter((b) => !b.doneM);
  const oldest = [...m.open].filter((c) => !c.due).sort((a, b) => a.updated.localeCompare(b.updated))[0];
  const nextReview = (() => { const d = new Date(m.today + 'T12:00:00'); d.setMonth(d.getMonth() + 1, 1); while (d.getDay() !== 6) d.setDate(d.getDate() + 1); return ymd(d); })();
  const qs = [];
  if (failing.length) qs.push(['What went wrong', 'var(--bad)', `${failing.map((b) => b.name).join(', ')} had nothing done this month. Is that a choice or a drift?`, failing.map((b) => b.name + ': ' + (b.tracker || 'no tracker')).join(' · ')]);
  if (oldest) qs.push(['Excuse check', 'var(--warn)', `"${oldest.action}" has been open ${daysBetween(ymd(oldest.updated), m.today)} days. What is actually stopping it?`, 'Only you hold it. No one else is waiting.']);
  if (m.ded.pct - m.self.pct > 0.1) qs.push(['Root cause', 'var(--ac)', `You keep ${Math.round(m.ded.pct * 100)}% of promises with a deadline and ${Math.round(m.self.pct * 100)}% of the ones only you hold. Why does your own word count for less?`, `${m.self.open} self-held promises open right now.`]);
  if (m.keptMonth) qs.push(['What went well', 'var(--good)', `${plural(m.keptMonth, 'promise')} kept this month. What made those work, and which box could run the same way?`, '']);
  return `${header('Monthly review · next one ' + fmt(nextReview + 'T12:00', { weekday: 'long', month: 'short', day: 'numeric' }))}
  <div class="card" style="flex-direction:row;align-items:center;gap:28px;flex:none"><div class="col grow" style="gap:4px"><div class="lbl">Month so far</div><div class="h" style="font-size:28px">${h(boxRows.filter((b) => b.doneM).map((b) => b.name).join(' and ') || 'Nothing')} moving. ${failing.length ? h(failing.length + ' of ' + boxRows.length + ' boxes have no evidence at all.') : 'Every box has evidence.'}</div></div>
    ${[[m.keptMonth, 'kept', 'var(--good)'], [m.droppedMonth, 'dropped', 'var(--bad)'], [m.overdue.length, 'overdue', 'var(--warn)'], [m.open.length, 'open', 'var(--tx)']].map(([n, l, c]) => `<div class="col" style="align-items:center;gap:2px;min-width:90px"><div class="h" style="font-size:38px;color:${c}">${n}</div><div class="mu" style="font-size:13px">${l}</div></div>`).join('')}</div>
  <main style="grid-template-columns:520px minmax(0,1fr) 420px">
    <section class="card"><div class="lbl">Scorecard · evidence this month</div>${boxRows.map((b) => `<div class="row" style="padding:10px 12px;border-radius:12px;background:var(--s2)"><span style="width:100px;font-size:11.5px;font-weight:700;letter-spacing:.05em;text-transform:uppercase;color:${b.v[1]}">${b.v[0]}</span><div class="grow"><div style="font-weight:600;font-size:14.5px">${h(b.name)}</div><div class="mu clip" style="font-size:12.5px">${b.doneM} done this month${b.late ? ' · ' + b.late + ' late' : ''} · tracker: ${h(b.tracker || 'not set')}</div></div></div>`).join('')}</section>
    <section class="card"><div class="row"><div class="h grow" style="font-size:24px">The interrogation</div><a class="btn" target="_blank" href="${askClaude('Run my monthly Mirror review. Be harsh and specific, use evidence from my second brain, one question at a time.')}">Start the review call</a></div>
      ${qs.map((q) => `<div class="item" style="flex-direction:column;gap:6px;padding:14px 16px"><div style="font-size:11.5px;font-weight:700;letter-spacing:.06em;text-transform:uppercase;color:${q[1]}">${q[0]}</div><div style="font-size:17px;font-weight:600;line-height:1.4">${h(q[2])}</div>${q[3] ? `<div class="mu" style="font-size:13px">${h(q[3])}</div>` : ''}</div>`).join('')}</section>
    <section class="col" style="gap:18px"><div class="card"><div class="lbl">Values you said matter</div>${m.values.map((v) => `<div style="font-size:14px;line-height:1.4">· ${h(v)}</div>`).join('')}</div>
      <div class="card grow"><div class="lbl">Dropped this month</div>${m.mine.filter((c) => c.status === 'dropped' && ymd(c.updated) >= mStart).map((c) => `<div style="font-size:13.5px" class="cl2">${h(c.action)}</div>`).join('') || '<div class="empty">Nothing dropped.</div>'}</div></section>
  </main>${footer()}`;
};

VIEW_FN.trust = () => {
  const c = D.counts, hy = D.hypotheses;
  return `${header('What the brain believes, why, and how fresh it is')}
  <div style="display:flex;gap:16px;flex:none">${[[c.people, 'people'], [c.facts, 'current facts'], [c.links, 'links'], [c.sources, 'sources captured'], [hy.length, 'hypotheses to check'], [D.stale.length, 'stale, worth a check']].map(([n, l], i) => `<div class="card grow" style="gap:2px;padding:16px 20px"><div class="h" style="font-size:30px;color:${i === 4 ? 'var(--ac)' : i === 5 ? 'var(--warn)' : 'var(--tx)'}">${n}</div><div class="mu" style="font-size:13px">${l}</div></div>`).join('')}</div>
  <main style="grid-template-columns:repeat(3,minmax(0,1fr))">
    <section class="card"><div class="lbl">Hypotheses · guesses until you confirm</div>${hy.map((x) => `<div class="item" style="flex-direction:column;gap:8px"><div style="font-size:15px;font-weight:600;line-height:1.4">${h(x.guess)}</div><div class="mu" style="font-size:12.5px">from ${h(x.source ?? 'unknown')} · ${Math.round((x.confidence ?? 0) * 100)}% sure</div><div class="row"><a class="btn sm" target="_blank" href="${askClaude('Hypothesis ' + x.id + ' in my second brain says: "' + x.guess + '". It is right. Confirm it.')}">That's right</a><a class="btn ghost sm" target="_blank" href="${askClaude('Hypothesis ' + x.id + ' in my second brain says: "' + x.guess + '". It is wrong. Reject it and ask me what is true.')}">Wrong</a></div></div>`).join('') || '<div class="empty">No open guesses.</div>'}
      <div class="lbl" style="margin-top:8px">Patterns</div>${D.patterns.map((p) => `<div class="row" style="font-size:13.5px"><span class="pill" style="font-size:11px">${h(p.class)}</span><span class="clip grow">${h(p.title)}</span></div>`).join('')}</section>
    <section class="card"><div class="lbl">Stale sweep · still true?</div>${D.stale.map((s) => `<div class="item" style="align-items:center"><div class="grow" style="font-size:14px"><b>${h(s.subject)}</b> · ${h(s.predicate.replace(/_/g, ' '))}: ${h(s.value)}</div><span class="wn" style="font-size:12px;white-space:nowrap">${s.age_days}d</span><a class="btn ghost sm" target="_blank" href="${askClaude('In my second brain: ' + s.subject + ' ' + s.predicate + ' = ' + s.value + '. Is this still true? Ask me and record a correction if not.')}">Check</a></div>`).join('') || '<div class="empty">Nothing stale.</div>'}</section>
    <section class="col" style="gap:18px"><div class="card"><div class="lbl">Your corrections</div>${D.corrections.map((x) => `<div class="row" style="font-size:13.5px"><span class="mu" style="width:56px">${fmt(x.at, { month: 'short', day: 'numeric' })}</span><span class="clip grow">${h(x.title.replace(/^Correction:\s*/, ''))}</span></div>`).join('') || '<div class="empty">None yet.</div>'}</div>
      <div class="card grow"><div class="lbl">Changed in the last 24 hours</div>${(D.brief?.changed_last_24h ?? []).slice(0, 16).map((x) => `<div class="cl2" style="font-size:13px;line-height:1.4">${h(x)}</div>`).join('') || '<div class="empty">No changes.</div>'}</div></section>
  </main>${footer()}`;
};

/* ---------- render + events ---------- */
const status = (t) => { const el = $('#status'); if (!el) return; if (t) { el.textContent = t; el.style.display = 'block'; } else el.style.display = 'none'; };
function phone() {
  const m = M;
  const ev = m.today_ev.filter((e) => e.en > Date.now()).slice(0, 6);
  $('#phone').innerHTML = `<div class="col" style="gap:2px"><div class="mu" style="font-size:13px">${fmt(Date.now(), { weekday: 'long', month: 'short', day: 'numeric' })}</div><div class="h" style="font-size:26px">Today</div></div>
  <div class="card" style="background:var(--acs)"><div class="lbl ac">${m.nowEv ? 'Now' : 'Next'}</div><div style="font-size:18px;font-weight:600">${h(clean((m.nowEv ?? m.nextEv)?.title ?? 'Free for the rest of today'))}</div></div>
  <div class="card"><div class="lbl">Big 3 · ${m.big3.filter((c) => c.ticked).length} of ${m.big3.length}</div>${m.big3.map((c) => `<div class="row" style="align-items:flex-start"><button class="tick ${c.ticked ? 'on' : ''}" data-done="${c.id}">${tickSvg}</button><div class="${c.ticked ? 'done-txt' : ''}" style="line-height:1.35">${h(c.action)}</div></div>`).join('') || '<div class="empty">Nothing open.</div>'}</div>
  <div class="card"><div class="lbl">Rest of today</div>${ev.map((e) => `<div class="row"><span class="mu" style="width:64px;flex:none">${time(e.start)}</span><span class="${e.clash ? 'wn' : ''}">${h(clean(e.title))}</span></div>`).join('') || '<div class="empty">Nothing else today.</div>'}</div>
  <div class="card"><div class="lbl">Needs your yes · ${D.needs_yes.length}</div>${D.needs_yes.slice(0, 3).map((p) => `<div class="row"><span class="grow cl2">${h(p.title)}</span><a class="btn sm" target="_blank" href="${askClaude('Review this draft with me before I send it:\n\n' + p.body)}">Review</a></div>`).join('') || '<div class="empty">Nothing waiting.</div>'}</div>
  <div class="mu" style="font-size:13px;text-align:center">Full screens are on the desk view: open this page on a laptop or the desk monitor.</div>`;
}
function fit() { const w = document.documentElement.clientWidth || innerWidth || 1920, vh = innerHeight || 0; const s = (vh > 300 ? Math.min(w / 1920, vh / 1080) : w / 1920) || 1; const hh = Math.max(vh, 1080 * s); document.body.classList.toggle('narrow', w < 900); if (w >= 900) document.body.style.height = hh + 'px'; else document.body.style.height = 'auto'; const st = $('#stage'); st.style.transform = `scale(${s})`; st.style.left = Math.max(0, (w - 1920 * s) / 2) + 'px'; st.style.top = Math.max(0, (hh - 1080 * s) / 2) + 'px'; }
function render() {
  if (!M) return;
  document.body.classList.toggle('night', mode() === 'night');
  status('');
  document.body.classList.toggle('narrow', (document.documentElement.clientWidth || innerWidth) < 900);
  try { phone(); } catch (e) { console.error(e); }
  try { $('#stage').innerHTML = (VIEW_FN[view()] ?? VIEW_FN.control)(); }
  catch (e) { console.error(e); $('#stage').innerHTML = `<div class="card" style="margin:auto;width:900px"><div class="h" style="font-size:26px">This screen hit a bug</div><div class="mu" style="font-size:15px">${h(e.message)}</div><div class="row"><a class="btn" href="#control">Control room</a><button class="btn ghost" data-reload>Reload</button></div></div>`; }
  fit();
}
function setup(msg) {
  document.body.insertAdjacentHTML('beforeend', `<div id="setup"><div class="card"><div class="h" style="font-size:26px">Connect your second brain</div>
    <div class="mu" style="font-size:14px;line-height:1.5">${msg}</div><input id="tok" type="password" placeholder="Connector token or the full connector URL" autocomplete="off">
    <button class="btn" id="go">Connect</button><div class="mu" style="font-size:12.5px">Stored only in this browser. Use the same token as the brain connector.</div></div></div>`);
  $('#go').onclick = async () => {
    const v = cleanToken($('#tok').value);
    if (!v) { $('#tok').focus(); return; }
    token = v; store.set('brain_token', v); $('#setup').remove();
    status('Connecting…'); await refresh(); if (!window.__iv) window.__iv = setInterval(refresh, REFRESH_MS);
  };
}
document.addEventListener('click', async (e) => {
  if (e.target.closest('[data-reload]')) { location.reload(); return; }
  const t = e.target.closest('[data-done],[data-theme-set],[data-mode-set],[data-pursuit]');
  if (!t) return;
  if (t.dataset.themeSet) { store.set('theme', t.dataset.themeSet); document.documentElement.dataset.theme = t.dataset.themeSet; render(); return; }
  if (t.hasAttribute('data-mode-set')) { const order = ['auto', 'morning', 'day', 'evening', 'night']; store.set('mode', order[(order.indexOf(store.get('mode', 'auto')) + 1) % order.length]); render(); return; }
  if (t.dataset.pursuit) { store.set('pursuit', t.dataset.pursuit); render(); return; }
  const id = +t.dataset.done, c = D.commitments.find((x) => x.id === id);
  if (!c || c.status === 'done') return;
  t.classList.add('on');
  try {
    if (MCP) await MCP.callTool(SERVER, 'mark_commitment', { commitment_id: id, status: 'done', reason: 'the user ticked it on the desk screen' });
    else { const r = await fetch(API_BASE + encodeURIComponent(token), { method: 'POST', headers: { 'content-type': 'application/json', 'x-brain-token': token }, body: JSON.stringify({ action: 'done', id }) });
      if (!r.ok) throw new Error(await r.text()); }
    c.status = 'done'; c.updated = new Date().toISOString(); M = derive(D);
    toast('Done: ' + c.action.slice(0, 60));
    setTimeout(render, 700);
  } catch (err) { t.classList.remove('on'); toast('Could not save. ' + String(err.message ?? err.code ?? err).slice(0, 80)); }
});
addEventListener('hashchange', render);
addEventListener('resize', fit);
document.addEventListener('visibilitychange', () => { if (!document.hidden) refresh(); });
setInterval(() => { const c = $('#clock'); if (c) c.textContent = time(Date.now()); }, 15000);
async function refresh() {
  try { await load(); render(); }
  catch (e) {
    if (e.message === 'token') { document.getElementById('setup')?.remove(); return setup('That token was not accepted. Paste the part after the last / of the connector URL, or the whole URL.'); }
    const fix = { needs_reauth: 'Reconnect the Second Brain connector in claude.ai Settings, Connectors, then reload.', server_not_connected: 'Add the Second Brain connector in claude.ai Settings, Connectors, then reload.',
      selection_required: 'Choose which Second Brain connector this page should use, then reload.', not_in_manifest: 'This page is not allowed to use the Second Brain connector. Allow it, then reload.',
      approval_required: 'This page needs your OK to read your Second Brain. Reload and choose Allow.', tool_error: 'The brain answered with an error: ' + String(e.message ?? '').slice(0, 140) };
    if (e.code && fix[e.code] && !D) return notice(fix[e.code]);
    const cached = store.get('last_data', null);
    if (cached && !D) { try { D = JSON.parse(cached); M = derive(D); render(); } catch { D = null; } }
    if (!D) return notice(MCP ? 'Could not load: ' + String(e.message ?? e.code ?? e) : 'This page could not reach your brain. Open it inside Claude so it can use your Second Brain connector, or open the downloaded file and enter your token. (' + String(e.message ?? e) + ')');
    toast('Offline · showing the last saved data');
  }
}
function notice(msg) {
  status(msg);
  document.body.insertAdjacentHTML('beforeend', `<div id="setup"><div class="card"><div class="h" style="font-size:24px">Can't load your second brain</div><div class="mu" style="font-size:14px;line-height:1.5">${h(msg)}</div><button class="btn" data-reload>Try again</button></div></div>`);
}
fit();
if (window.ResizeObserver) new ResizeObserver(fit).observe(document.documentElement);
$('#stage').innerHTML = '<div class="col" style="margin:auto;align-items:center;gap:14px"><div class="h" style="font-size:34px">Loading your second brain…</div><div class="mu" style="font-size:18px">One moment</div></div>';
addEventListener('error', (e) => { if (!D) notice('Something broke while loading: ' + (e.message || 'unknown error')); });
addEventListener('unhandledrejection', (e) => { if (!D) notice('Something broke while loading: ' + String(e.reason?.message ?? e.reason?.code ?? e.reason)); });
(async () => {
  status('Connecting to your Second Brain connector…');
  MCP = await initMcp();
  status(MCP ? 'Connected. Loading data… (allow access if Claude asks)' : (token ? 'No connector here. Trying the direct link…' : ''));
  if (!MCP && !token) return setup('Paste the brain connector token once. After that the screen loads by itself and refreshes every 5 minutes.');
  await refresh(); setInterval(refresh, REFRESH_MS);
})();

})();
