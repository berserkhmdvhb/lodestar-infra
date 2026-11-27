# Operations: glossary

Part of the [operations runbook](README.md). Section numbers are the runbook's original ones, so references such as "section 5.1" keep working; the index maps each to its file.

## 15. Concepts glossary

- **ADC (Application Default Credentials) and the quota project.** A credential file that Google client
  libraries and Terraform/OpenTofu providers read, separate from the `gcloud` CLI's own login (`gcloud auth
  login`). Created by `gcloud auth application-default login`. With user credentials, API calls need a
  **quota project**, the project billed and rate-limited for them: `gcloud auth application-default
  set-quota-project`.
- **`user_project_override` and `billing_project`.** Provider settings that send each API call "as" a given
  project for quota and billing. The Billing Budgets API refuses user credentials without both.
- **Workload Identity Federation (WIF).** Lets an outside identity provider (here GitHub's OIDC issuer) log in
  to Google without a key. A *pool* holds *providers*; a provider maps token claims to attributes and has an
  attribute condition; a service account lists, through `roles/iam.workloadIdentityUser`, which subjects may
  impersonate it.
- **OIDC subject, classic vs immutable.** The token's `sub` claim. Classic: `repo:<owner>/<repo>:environment:<env>`
  (names can be renamed or reused). Immutable, the default for repositories created, renamed or transferred
  after 2026-07-15:
  `repo:<owner>@<owner-id>/<repo>@<repo-id>:environment:<env>` (numeric IDs, safe against rename takeover). Read
  the prefix from `repos/<repo>/actions/oidc/customization/sub`.
- **Workload Identity for GKE.** The in-cluster counterpart: a Pod's Kubernetes service account acts as a
  Google IAM principal (`principal://...svc.id.goog/subject/ns/<ns>/sa/<name>`), with no key file.
- **Private nodes.** Nodes have no public IP; outbound traffic goes through Cloud NAT and Google API traffic
  through Private Google Access.
- **DNS-based control-plane endpoint.** A host name for the cluster API, reached with IAM only (needs
  `container.clusters.connect`). No IP allowlist for CI, and it keeps working if the public IP endpoint is later
  closed.
- **Dataplane V2.** GKE's Cilium-based data plane. It enforces Kubernetes NetworkPolicy.
- **Spot nodes.** Discounted VMs Google can reclaim at any time. Fine for dev and qa, not alone for production.
- **Cloud NAT.** A managed network address translator giving private nodes outbound access to the internet.
- **External Secrets Operator (ESO).** Syncs values from an external store (Secret Manager) into Kubernetes
  Secrets, per `ExternalSecret`, through a `SecretStore`.
- **Conditional IAM.** A role binding with a condition expression (`resource.name.startsWith(...)`) so the
  grant covers only matching resources. This design gives each binding its own title (`eso-<namespace>`) to tell them apart; IAM does not require titles to be unique.
- **OpenTofu state.** The record of which real resource each code block owns. Stored remotely, versioned, and
  encrypted.
- **State encryption (`gcp_kms` + `aes_gcm`, and the fallback).** OpenTofu encrypts state and plan files with
  AES-GCM with envelope encryption: a new data key for each file, wrapped by the Cloud KMS key. A `fallback` method lets the first migration read plain
  state; the final form has no fallback and `enforced = true`.
- **Import blocks.** `import { to = ...; id = ... }` declarations that put an existing resource into state at
  the next apply, without changing it. They may stay in the code afterwards.
- **Saved plans.** `tofu plan -out=file`, then `tofu apply file`: the apply runs exactly the reviewed plan,
  or refuses if the state has moved on.
- **Drift.** A difference between code, state and the real resource, caused by a manual change or a provider
  default. `tofu plan` shows it.
- **`prevent_destroy` and `deletion_protection`.** `prevent_destroy` is an OpenTofu lifecycle rule: a plan that
  would destroy the resource (the KMS key and ring, the state bucket) fails. `deletion_protection` is a
  provider argument on the cluster, enforced by OpenTofu only: the plan shows the destroy and the apply
  refuses it. `gcloud` or the console can still delete the cluster.
- **Rulesets.** GitHub's rules for branches and tags (require pull requests and checks, block force pushes,
  restrict who may create `v*` tags). They sit alongside the older branch-protection settings and are the more flexible of the two.
- **Conventional Commits.** The `type(scope): summary` format for commit messages and PR titles, enforced by a
  required check; the PR title becomes the squash commit message.

