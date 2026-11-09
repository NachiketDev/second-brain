// INGEST: the single front door into raw memory.
// POST JSON with header `x-brain-secret: <brain_ingest_secret from Vault>` (or ?secret=...) from Zapier, an iOS Shortcut,
// the poll function, or anything else. Raw content is stored untouched; the scheduled Claude task compiles it.
//
// Body (all optional except external_id or content):
// { provider, external_id, occurred_at, title, kind, url, attendees,
//   content | transcript | notes | summary, consent_scope, payload }
import { checkSecret, handler, HttpError } from '../_shared/lib.ts';
import { ingestOne } from '../_shared/ingest.ts';


Deno.serve(handler(async (req) => {
  if (req.method !== 'POST') throw new HttpError(405, 'POST only');
  const secret = req.headers.get('x-brain-secret') ?? new URL(req.url).searchParams.get('secret');
  if (!(await checkSecret('brain_ingest_secret', secret))) throw new HttpError(401, 'bad secret');
  const body = await req.json();
  const items = Array.isArray(body) ? body : [body];
  const results = [];
  for (const item of items) results.push(await ingestOne(item));
  return { results };
}));
