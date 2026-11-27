# gcp-secrets

Secret Manager access for External Secrets, and the empty secret containers. Codifies guide sections 14.2
and 14.4.

- One conditional `roles/secretmanager.secretAccessor` binding per app namespace `<service>-<env>`: the
  `external-secrets` service account there may read only secrets whose name starts with
  `projects/<number>/secrets/<service>-<env>-` (condition title `eso-<service>-<env>`).
- One per database namespace `<service>-<env>-db`: it may read only `<service>-<env>-db-password`
  (title `eso-<service>-<env>-db`).
- There is never an unconditioned accessor binding.
- One `google_secret_manager_secret` per entry of `secret_keys`, id `<service>-<env>-<key>`, replicated to
  `region` only. **No secret version is ever created here**: values are added by hand, because a value
  managed by OpenTofu would be stored in state. `make test` fails if a `google_secret_manager_secret_version`
  appears under `modules/`.

Production's `db-user` and `db-password` come later with Cloud SQL: add them to `secret_keys.production`.

Inputs: `project_id`, `project_number` (required), `region`, `service_name`, `app_environments`,
`db_environments`, `secret_keys`.
Outputs: `secret_ids`, `binding_titles`.
