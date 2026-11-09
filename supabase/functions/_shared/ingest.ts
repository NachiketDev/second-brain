// Shared ingest logic for the ingest webhook and the poller. Everything goes through the database's
// ingest_raw(), the same entry point the scheduled Claude task uses, so dedupe, revisions and
// [private] / NDA handling behave identically for every source.
import { db, HttpError } from './lib.ts';

export async function ingestOne(body: Record<string, unknown>) {
  const s = (k: string) => (typeof body[k] === 'string' ? (body[k] as string) : undefined);
  const content = [
    s('notes') && `## My notes\n${s('notes')}`,
    s('summary') && `## Summary\n${s('summary')}`,
    s('transcript') && `## Transcript\n${s('transcript')}`,
    s('content'),
  ].filter(Boolean).join('\n\n').trim();
  const title = s('title') ?? '';
  if (!content && !title) throw new HttpError(400, 'nothing to ingest: send content, transcript, notes or summary');

  const occurred_at = s('occurred_at') ?? new Date().toISOString();
  const external_id = s('external_id') ?? `${s('provider') ?? 'manual'}-${occurred_at}`;
  const { data, error } = await db().rpc('ingest_raw', {
    p_provider: (s('provider') ?? 'manual').toLowerCase(),
    p_external_id: external_id,
    p_occurred_at: occurred_at,
    p_title: title,
    p_content: content,
    p_url: s('url') ?? null,
    p_kind: s('kind') ?? 'meeting',
    p_payload: { attendees: body.attendees ?? null, ...((body.payload as object) ?? {}) },
  });
  if (error) throw new Error(error.message);
  return data as { result: string; id: number; consent_scope?: string };
}
