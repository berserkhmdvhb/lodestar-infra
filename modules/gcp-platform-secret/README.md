# gcp-platform-secret

Secret containers owned by a non-app namespace (for example the Cloudflare tunnel token in `cloudflared`),
plus one conditional `roles/secretmanager.secretAccessor` project member per secret for that namespace's
`external-secrets` service account (condition title `eso-<namespace>`, expression
`resource.name.startsWith("projects/<number>/secrets/<id>/")`; the trailing slash keeps `<id>-other` out).

**No secret version is ever created here**: the value is added by hand (`gcloud secrets versions add`),
because a managed value would be stored in state. `make test` fails if a `google_secret_manager_secret_version`
appears under `modules/`.

Kept separate from `gcp-secrets` so that module's resource addresses and `for_each` keys (the live import
list) do not change.

Inputs: `project_id`, `project_number`, `secrets` (required), `region`. Outputs: `secret_ids`.
