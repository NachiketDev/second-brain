// Shared helpers for all brain functions.
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

export const env = (k: string, required = true) => {
  const v = Deno.env.get(k);
  if (required && !v) throw new Error(`missing secret ${k}`);
  return v ?? '';
};

export const db = () => createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'), {
  auth: { persistSession: false },
});

export const TZ = Deno.env.get('BRAIN_TIMEZONE') ?? 'America/New_York';

/** Secrets live in the database Vault; functions ask the database to check a value, never hold a copy. */
export async function checkSecret(name: string, value: string | null) {
  if (!value) return false;
  const { data, error } = await db().rpc('check_secret', { p_name: name, p_value: value });
  return !error && data === true;
}

/** Cron calls carry `Authorization: Bearer <brain_cron_secret>`. */
export async function requireCron(req: Request) {
  const token = (req.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, '');
  if (!(await checkSecret('brain_cron_secret', token))) throw new HttpError(401, 'unauthorized');
}

export class HttpError extends Error {
  constructor(public status: number, msg: string) { super(msg); }
}

export function handler(fn: (req: Request) => Promise<Response | unknown>) {
  return async (req: Request) => {
    try {
      const out = await fn(req);
      return out instanceof Response ? out : Response.json(out ?? { ok: true });
    } catch (e) {
      const status = e instanceof HttpError ? e.status : 500;
      console.error(e);
      return Response.json({ error: String((e as Error).message ?? e) }, { status });
    }
  };
}

export const fmtDate = (iso: string | Date, opts: Intl.DateTimeFormatOptions = { month: 'short', day: 'numeric' }) =>
  new Date(iso).toLocaleDateString('en-US', { timeZone: TZ, ...opts });

export const fmtTime = (iso: string | Date) =>
  new Date(iso).toLocaleTimeString('en-US', { timeZone: TZ, hour: 'numeric', minute: '2-digit' });
