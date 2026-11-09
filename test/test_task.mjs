// Simulates one scheduled Claude task run against embedded Postgres.
import { PGlite } from '@electric-sql/pglite';
import fs from 'node:fs';
const ok = (c, m) => { if (!c) { console.log('FAIL', m); process.exit(1); } console.log('PASS', m); };
const db = new PGlite();
for (const f of ['20261029000001_brain.sql', '20261029000003_claude_task.sql'])
  await db.exec(fs.readFileSync(`../supabase/migrations/${f}`, 'utf8'));
await db.exec(fs.readFileSync('../supabase/seed_sample.sql', 'utf8'));
const one = async (sql, args = []) => (await db.query(sql, args)).rows[0];

// 1. ingest a new Granola note, then the same note again, then an edited version
const a = await one(`select ingest_raw('granola','g-new','2026-10-30T15:00-04:00','Follow-up with Riley Chen',
  'Riley sent PIPE intros: Dana Lee and Omar Haddad. I will email both by Friday.','https://x') r`);
const b = await one(`select ingest_raw('granola','g-new','2026-10-30T15:00-04:00','Follow-up with Riley Chen',
  'Riley sent PIPE intros: Dana Lee and Omar Haddad. I will email both by Friday.','https://x') r`);
const c = await one(`select ingest_raw('granola','g-new','2026-10-30T15:00-04:00','Follow-up with Riley Chen',
  'Riley sent PIPE intros: Dana Lee and Omar Haddad. I will email both by Friday. Also mentioned FI team is hiring.','https://x') r`);
ok(a.r.result === 'stored' && b.r.result === 'duplicate' && c.r.result === 'revision', 'ingest_raw: stored, duplicate, revision');
const p = await one(`select ingest_raw('granola','g-p','2026-10-30T16:00-04:00','Therapy-free chat [private]','x') r`);
ok(p.r.consent_scope === 'exclude', '[private] title is excluded from the brain');

// 2. claim + context
const claimed = (await db.query(`select id, title from claim_raw_events(5)`)).rows;
ok(claimed.length === 2, `claimed ${claimed.length} pending events`);
const ctx = (await one(`select brain_context($1) c`, [a.r.id])).c;
const mentioned = ctx.mentioned_entity_details.map(e => e.id);
ok(mentioned.includes('riley-chen') && ctx.open_commitments.some(x => x.action.includes('PIPE')),
   'brain_context finds Riley and the open PIPE commitment');

// 3. apply the diff Claude would return
const pipe = ctx.open_commitments.find(x => x.action.includes('PIPE'));
const r = await one(`select apply_diff($1,$2::jsonb,'task-test') r`, [a.r.id, JSON.stringify({
  entities: [{ id: 'dana-lee', type: 'person', name: 'Dana Lee', summary: 'Atlas PIPE contact (intro via Riley)' },
             { id: 'omar-haddad', type: 'person', name: 'Omar Haddad', summary: 'Atlas PIPE contact (intro via Riley)' }],
  claims: [], edges: [{ src: 'riley-chen', rel: 'introduced', dst: 'dana-lee' }, { src: 'riley-chen', rel: 'introduced', dst: 'omar-haddad' }],
  commitments: [{ owner: 'me', beneficiary: 'dana-lee', action: 'Email Dana Lee (PIPE intro from Riley)', due_at: '2026-10-30', evidence: 'I will email both by Friday' },
                { owner: 'me', beneficiary: 'omar-haddad', action: 'Email Omar Haddad (PIPE intro from Riley)', due_at: '2026-10-30', evidence: 'I will email both by Friday' }],
  commitment_updates: [{ id: pipe.id, status: 'done', reason: 'Riley sent the intros' }],
  stories: [{ id: 'atlas-recruiting', note: 'Riley delivered PIPE intros' }] })]);
ok(r.r.result === 'applied', 'apply_diff applied the compiled note');
const why = await one(`select summary, reason from change_log where summary like '%-> done%PIPE%'`);
console.log('  ', why);
ok(why?.reason === 'Riley sent the intros', 'change log explains why Riley\'s commitment closed');

// 4. briefing candidates from calendar
await db.query(`insert into calendar_events (uid, title, starts_at, attendees) values
  ('ev1','Coffee chat: Jordan Park', now() + interval '20 hours', '["Jordan Park","Sam Owner"]'),
  ('ev2','Microeconomics', now() + interval '5 hours', '[]')`);
const cands = (await one(`select briefing_candidates() c`)).c;
ok(cands.length === 1 && cands[0].people.some(x => x.id === 'jordan-park') && cands[0].open_commitments.length > 0,
   'briefing_candidates picks the Jordan meeting with the open loop, skips class');
await db.query(`select save_briefing($1,$2,$3,$4)`, [cands[0].calendar_uid, cands[0].starts_at, 'Briefing: Jordan', 'body']);
ok((await one(`select briefing_candidates() c`)).c.length === 0, 'a saved briefing is not proposed twice');
