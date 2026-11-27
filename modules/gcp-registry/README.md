# gcp-registry

Optional Artifact Registry Docker repository (the owner did not create one; the template pushes to
GHCR). Off by default: with `enabled = false` nothing is created. When on: immutable tags, delete
untagged images older than 30 days, keep the 10 most recent versions, and `roles/artifactregistry.reader`
for `reader_members`. No writer role. Codifies guide step 10.

Inputs: `project_id` (required), `region`, `enabled`, `repository_id`, `reader_members`.
Outputs: `repository_url` (null when disabled).
