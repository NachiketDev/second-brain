// AGENTS (cron hourly): read the brain + what changed, and write PROPOSALS. Suggest-only: nothing here
// touches Todoist, your calendar or email. You approve from the daily digest; `act` executes.
//
//  todo      new commitment you own            -> "Add to Todoist?"
//  deadline  your commitment due within 3 days -> "Block prep time?" (Google Calendar link)
//  followup  someone owes you, 5+ days quiet   -> drafted nudge
//  review    a commitment's premise changed    -> "Keep or drop?" with the reason
//  (meeting briefings are written by the scheduled Claude task via briefing_candidates())
import { db, fmtDate, handler, requireCron } from '../_shared/lib.ts';

// deno-lint-ignore no-explicit-any
type Row = Record<string, any>;
type Proposal = { agent: string; kind: string; title: string; body?: string; payload?: Row; priority?: number;
                  dedupe_key: string; related?: Row };

const day = 864e5;
const ymd = (d: Date) => d.toISOString().slice(0, 10).replace(/-/g, '');
const first = (name: string) => name.split(' ')[0];

function gcalLink(title: string, date: string, details: string) {
  const d = new Date(`${date}T12:00:00Z`);
  const prev = new Date(d.getTime() - day);
  const p = new URLSearchParams({ action: 'TEMPLATE', text: title, dates: `${ymd(prev)}/${ymd(d)}`, details });
  return `https://calendar.google.com/calendar/render?${p}`;
}

async function propose(sb: ReturnType<typeof db>, items: Proposal[]) {
  if (!items.length) return 0;
  // every row needs the same columns, or PostgREST sends NULL for the missing ones
  const rows = items.map(p => ({ body: null, payload: {}, related: {}, priority: 2, ...p }));
  const { data, error } = await sb.from('proposals')
    .upsert(rows, { onConflict: 'dedupe_key', ignoreDuplicates: true }).select('id');
  if (error) throw new Error(`${error.code}: ${error.message}`);
  return data?.length ?? 0;
}

async function commitmentAgents(sb: ReturnType<typeof db>, names: Map<string, string>) {
  const { data: loops } = await sb.from('open_loops').select('*');
  const out: Proposal[] = [];
  const now = Date.now();
  for (const c of loops ?? []) {
    const src = `${c.source_title ?? 'source'} (${fmtDate(c.source_at)})`;
    if (c.status === 'needs_review') {
      const { data: why } = await sb.from('change_log').select('reason').eq('table_name', 'commitments')
        .eq('row_id', String(c.id)).eq('op', 'flag').order('id', { ascending: false }).limit(1);
      out.push({ agent: 'review', kind: 'review', priority: 2, dedupe_key: `review:${c.id}`,
        title: `Still relevant? ${c.action}`,
        body: `Flagged because ${why?.[0]?.reason ?? 'something it depended on changed'}.\nFrom ${src}.`,
        related: { commitment_id: c.id } });
      continue;
    }
    if (c.owner === 'me') {
      out.push({ agent: 'todo', kind: 'task', priority: c.due_at ? 2 : 3, dedupe_key: `task:${c.id}`,
        title: c.action,
        body: `From ${src}. "${c.evidence}"`,
        payload: { content: c.action, due_date: c.due_at, description: `From ${src}\n${c.evidence}` },
        related: { commitment_id: c.id } });
      if (c.due_at) {
        const left = (new Date(`${c.due_at}T23:59:00`).getTime() - now) / day;
        if (left <= 3 && left > -1) {
          out.push({ agent: 'deadline', kind: 'calendar', priority: 1, dedupe_key: `deadline:${c.id}:${c.due_at}`,
            title: `Due ${fmtDate(c.due_at + 'T12:00:00Z')}: ${c.action}`,
            body: `${Math.max(0, Math.ceil(left))} day(s) left. Block time the day before?`,
            payload: { url: gcalLink(`Prep: ${c.action}`, c.due_at, `From ${src}`) },
            related: { commitment_id: c.id } });
        }
      }
    } else if (c.beneficiary === 'me' && now - new Date(c.source_at).getTime() > 5 * day) {
      const who = names.get(c.owner) ?? c.owner;
      out.push({ agent: 'followup', kind: 'followup', priority: 3, dedupe_key: `followup:${c.id}`,
        title: `${who} hasn't followed up: ${c.action}`,
        body: `Promised ${fmtDate(c.source_at)}. Draft nudge:\n\nHi ${first(who)},\n\nThanks again for the time on ` +
              `${fmtDate(c.source_at, { month: 'long', day: 'numeric' })}. You'd mentioned you could ${
                c.action.replace(new RegExp(`^${first(who)}( to)?:?\\s*`, 'i'), '').replace(/^\w/, (m: string) => m.toLowerCase())}` +
              `. Just following up whenever you have a moment. Really appreciate it.\n\nBest,\n<your name>`,
        related: { commitment_id: c.id, entity: c.owner } });
    }
  }
  // a moved deadline makes the old deadline suggestion obsolete
  await sb.from('proposals').update({ status: 'expired' }).eq('agent', 'deadline').eq('status', 'pending')
    .not('dedupe_key', 'in', `(${out.filter(p => p.agent === 'deadline').map(p => `"${p.dedupe_key}"`).join(',') || '""'})`);
  return propose(sb, out);
}

Deno.serve(handler(async (req) => {
  await requireCron(req);
  const sb = db();
  const { data: maxRow } = await sb.from('change_log').select('id').order('id', { ascending: false }).limit(1);
  const { data: ents } = await sb.from('entities').select('id,type,name,aliases');
  const names = new Map((ents ?? []).map((e: Row) => [e.id, e.name]));
  const out: Row = {};
  try { out.commitments = await commitmentAgents(sb, names); } catch (e) { out.commitments = `error: ${(e as Error).message ?? JSON.stringify(e)}`; }
  if (maxRow?.[0]) await sb.from('change_log').update({ seen_by_agents: true }).lte('id', maxRow[0].id).eq('seen_by_agents', false);
  return { new_proposals: out };
}));
