-- Intelligence layer switch (25 Nov). "claude" (default) or "gemini". The Claude compile task checks it in Step 0
-- and exits when it is "gemini". The read-only Gmail bridge URL and secret live in Vault
-- (brain_gmail_bridge_url, brain_gmail_bridge_secret); the owner sets the secret himself.
insert into kv(key, value) values ('intelligence_layer', '"claude"'::jsonb) on conflict (key) do nothing;
