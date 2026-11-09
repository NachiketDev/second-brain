// Loads the migration into embedded Postgres, replays the October meetings through apply_diff,
// and checks: idempotency, order independence, change log, dependency flagging, validation.
import { PGlite } from '@electric-sql/pglite';
import fs from 'node:fs';
import crypto from 'node:crypto';

const MIG = fs.readFileSync(new URL('../supabase/migrations/20261029000001_brain.sql', import.meta.url), 'utf8');
const DIFFS = JSON.parse(fs.readFileSync(new URL('../sample/sample_diffs.json', import.meta.url), 'utf8'));
const ok = (c, m) => { if (!c) { console.log('FAIL', m); process.exit(1); } console.log('PASS', m); };

async function build(order) {
  const db = new PGlite();
  await db.exec(MIG);
  const idOf = {};
  for (const d of order) {
    const s = d.source;
    const hash = crypto.createHash('sha256').update(s.external_id).digest('hex');
    const r = await db.query(
      `insert into raw_events (provider, external_id, content_hash, occurred_at, title, consent_scope, payload)
       values ($1,$2,$3,$4,$5,$6,'{}') on conflict do nothing returning id`,
      [s.provider, s.external_id, hash, s.occurred_at, s.title, s.consent_scope || 'full']);
    idOf[`${s.provider}:${s.external_id}`] = r.rows[0].id;
  }
  // entity order matters for references; reflection pass (patterns) must run last because it references raw ids
  const pending = order.filter(d => d.source.provider !== 'reflection');
  for (let pass = 0; pass < 5 && pending.length; pass++) {
    for (const d of [...pending]) {
      try {
        await db.query('select apply_diff($1, $2::jsonb, $3)', [idOf[`${d.source.provider}:${d.source.external_id}`], JSON.stringify(d), 'seed']);
        pending.splice(pending.indexOf(d), 1);
      } catch (e) { if (pass === 4) throw e; }
    }
  }
  const refl = order.find(d => d.source.provider === 'reflection');
  refl.patterns.forEach(p => { p.raw_event_ids = p.source_ids.map(id => idOf[id]); });
  await db.query('select apply_diff($1, $2::jsonb, $3)', [idOf[`reflection:${refl.source.external_id}`], JSON.stringify(refl), 'seed']);
  return { db, idOf };
}

const snap = async db => JSON.stringify({
  cur: (await db.query(`select subject,predicate,value from facts where status='current' order by 1,2,3`)).rows,
  all: (await db.query(`select subject,predicate,value,status from facts order by 1,2,3,4`)).rows,
  com: (await db.query(`select owner,action,status from commitments order by 1,2`)).rows,
  ent: (await db.query(`select id from entities order by 1`)).rows,
});

const { db, idOf } = await build(DIFFS);
const counts = (await db.query(`select (select count(*) from entities) e, (select count(*) from facts) f,
  (select count(*) from commitments) c, (select count(*) from change_log) l, (select count(*) from edges) g`)).rows[0];
console.log('loaded:', counts);
const base = await snap(db);

// 1. idempotency: re-applying compiled events is a no-op
for (const d of DIFFS.slice(0, 5)) {
  const r = await db.query('select apply_diff($1,$2::jsonb) r', [idOf[`${d.source.provider}:${d.source.external_id}`], JSON.stringify(d)]);
  if (r.rows[0].r.result !== 'already_compiled') ok(false, 'idempotency');
}
ok(await snap(db) === base, 'idempotency: re-delivered events changed nothing');

// 2. order independence
for (let seed = 1; seed <= 3; seed++) {
  const shuffled = [...DIFFS].sort((a, b) => (crypto.createHash('md5').update(seed + a.source.external_id).digest('hex') <
                                              crypto.createHash('md5').update(seed + b.source.external_id).digest('hex')) ? -1 : 1);
  const { db: d2 } = await build(shuffled);
  ok(await snap(d2) === base, `order independence (shuffle ${seed})`);
}

// 3. version chain on the office decision
const office = (await db.query(`select predicate, value, status, valid_from::date, valid_to::date from facts
  where predicate like 'target_office%' order by predicate, valid_from`)).rows;
console.table(office);

// 4. dependency flagging: the SF task was automatically flagged when the Meridian office changed
const flagged = (await db.query(`select action, status from commitments where status='needs_review'`)).rows;
console.log('flagged:', flagged);
ok(flagged.some(r => r.action.includes('SF')), 'stale commitment auto-flagged when its fact changed');
const why = (await db.query(`select summary, reason from change_log where op='flag'`)).rows;
console.log('why:', why);

// 5. change log answers what / when / why
const log = (await db.query(`select op, summary, reason, source_title from recent_changes
  where summary like '%target_office:atlas%' order by id`)).rows;
console.table(log);
ok(log.length >= 3 && log.every(r => r.reason && r.source_title), 'change log records what, when and why for every change');

// 6. validation
await db.query(`insert into raw_events (provider, external_id, content_hash, occurred_at) values ('test','x','x',now())`);
const tid = (await db.query(`select id from raw_events where provider='test'`)).rows[0].id;
let rejected = false;
try { await db.query('select apply_diff($1,$2::jsonb)', [tid, JSON.stringify({ claims: [{ subject: 'me', predicate: 'trait', value: 'anxious', kind: 'fact', class: 'inferred', evidence: 'x' }] })]); }
catch { rejected = true; }
ok(rejected, 'inferred claim stored as fact is rejected (whole diff rolled back)');
rejected = false;
try { await db.query('select apply_diff($1,$2::jsonb)', [tid, JSON.stringify({ claims: [{ subject: 'ghost', predicate: 'x', value: 'y', kind: 'fact', class: 'observed', evidence: 'e' }] })]); }
catch { rejected = true; }
ok(rejected, 'claim about unknown entity is rejected');

// 7. a new note arrives that changes things: deadline moved, commitment done
const nid = (await db.query(`insert into raw_events (provider, external_id, content_hash, occurred_at, title)
  values ('manual','n1','h',  '2026-10-30T10:00:00-04:00','Quick voice note') returning id`)).rows[0].id;
const appId = (await db.query(`select id from commitments where action like 'Submit Atlas application%'`)).rows[0].id;
const mayaId = (await db.query(`select id from commitments where action like 'Book weekly case sessions with Maya%'`)).rows[0].id;
await db.query('select apply_diff($1,$2::jsonb,$3)', [nid, JSON.stringify({
  commitment_updates: [
    { id: appId, due_at: '2026-11-07', reason: 'Decided to submit 3 days early to leave buffer' },
    { id: mayaId, status: 'done', reason: 'Booked Mon/Wed/Fri with Maya' }],
  claims: [{ subject: 'me', predicate: 'case_prep_cadence', value: '3/week with Maya (booked)', kind: 'decision', class: 'declared', evidence: 'booked Mon Wed Fri', change_reason: 'adopted Maya cadence' }]
}), 'test-run']);
const latest = (await db.query(`select op, summary, reason, source_title from recent_changes where source_title='Quick voice note' order by id`)).rows;
console.table(latest);
ok(latest.length >= 3, 'new information produces explained changes');
