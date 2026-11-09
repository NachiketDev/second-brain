// ACT: the only place anything leaves the brain, and only after you approve.
// Links in the digest look like /act?id=12&t=<token>&do=approve. Email scanners pre-open links, so
// every action needs a second click on a confirm link before it runs.
import { db, handler } from '../_shared/lib.ts';
import { addGoogleTask, gConfigured } from '../_shared/gtasks.ts';

const text = (body: string, status = 200) =>
  new Response(body, { status, headers: { 'content-type': 'text/plain; charset=utf-8' } });

async function todoist(payload: Record<string, string | null>) {
  const token = Deno.env.get('TODOIST_API_TOKEN');
  if (!token) throw new Error('TODOIST_API_TOKEN not set');
  const res = await fetch('https://api.todoist.com/api/v1/tasks', {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: JSON.stringify({ content: payload.content, description: payload.description ?? undefined,
      due_date: payload.due_date ?? undefined, labels: ['brain'] }),
  });
  if (!res.ok) throw new Error(`Todoist ${res.status}: ${await res.text()}`);
  return await res.json();
}

Deno.serve(handler(async (req) => {
  const u = new URL(req.url);
  const id = u.searchParams.get('id'), t = u.searchParams.get('t'), action = u.searchParams.get('do') ?? 'approve';
  const sb = db();
  const { data: p } = await sb.from('proposals').select('*').eq('id', id).eq('token', t).maybeSingle();
  if (!p) return text('Link not recognised or expired.', 404);
  if (!['pending', 'approved'].includes(p.status) || (p.status === 'approved' && action === 'approve'))
    return text(`Already handled: ${p.status}.\n\n${p.title}`);

  if (u.searchParams.get('confirm') !== '1') {
    const confirm = new URL(req.url); confirm.searchParams.set('confirm', '1');
    const verb = { approve: 'Approve', dismiss: 'Dismiss', keep: 'Keep', drop: 'Drop', done: 'Mark done' }[action] ?? action;
    return text(`${verb}: ${p.title}\n\nOpen this link to confirm:\n${confirm}`);
  }

  const decide = (status: string, reason: string) => p.related?.commitment_id
    ? sb.rpc('decide_commitment', { p_id: p.related.commitment_id, p_status: status, p_reason: reason }) : null;
  const finish = (status: string, result: unknown = null) =>
    sb.from('proposals').update({ status, decided_at: new Date().toISOString(), result }).eq('id', p.id);

  if (action === 'dismiss') { await finish('dismissed'); return text(`Dismissed: ${p.title}`); }
  if (action === 'done') {
    await decide('done', 'You marked it done from the digest'); await finish('executed', { done: true });
    return text(`Marked done: ${p.title}`);
  }
  if (p.kind === 'review') {
    const status = action === 'drop' ? 'dropped' : 'open';
    await decide(status, action === 'drop' ? 'You dropped it after its premise changed' : 'You kept it after review');
    await finish('executed', { status });
    return text(`${status === 'dropped' ? 'Dropped' : 'Kept'}: ${p.title.replace(/^Still relevant\? /, '')}`);
  }
  if (p.kind === 'task') {
    const where = gConfigured() ? 'Google Tasks' : 'Todoist';
    try {
      const task = gConfigured() ? await addGoogleTask(p.payload) : await todoist(p.payload);
      await finish('executed', { app: where, task_id: task?.id ?? null });
      return text(`Added to ${where}: ${p.title}${p.payload.due_date ? ` (due ${p.payload.due_date})` : ''}`);
    } catch (e) {
      await finish('failed', { error: String(e) });
      return text(`Could not add to ${where}: ${(e as Error).message}`, 502);
    }
  }
  if (p.kind === 'calendar') {
    await finish('approved');
    return text(`Open this to add the block to Google Calendar:\n${p.payload.url}`);
  }
  if (p.kind === 'followup') {
    await finish('approved');
    return text(`Copy and send this yourself:\n\n${p.body?.split('Draft nudge:\n\n')[1] ?? p.body}`);
  }
  await finish('approved');
  return text(`Noted: ${p.title}`);
}));

