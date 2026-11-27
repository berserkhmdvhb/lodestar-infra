# Operations: GitHub identity and Workload Identity Federation

Part of the [operations runbook](README.md). Section numbers are the runbook's original ones, so references such as "section 5.1" keep working; the index maps each to its file.

## 6. GitHub identity and Workload Identity Federation

Run from: anywhere, `gh` logged in (1.3), env file sourced. Goal: GitHub Actions logs in to Google with no
key, and each GitHub environment acts as its own service account.

Concepts: GitHub signs a short-lived **OIDC** token for each workflow run. **Workload Identity Federation**
(WIF) lets Google accept it: a **pool** holds **providers**; a provider trusts GitHub's issuer, maps token
claims to attributes, and has an **attribute condition** that must be true or the login is refused. The token
can then impersonate a service account that has granted `roles/iam.workloadIdentityUser` to the token's
**subject**.

### 6.1 Numeric IDs

An owner or repository name can be renamed or reused; its numeric ID cannot. The condition below pins both.

✏️ (appends to the env file)

```bash
source ~/gke-setup.env

export GH_OWNER_ID="$(gh api "users/${GH_OWNER}" --jq .id)"
printf 'export GH_OWNER_ID="%s"\n' "${GH_OWNER_ID}" >> ~/gke-setup.env
printf '%s\n' "${GH_OWNER_ID}"

export GH_REPO_ID="$(gh api "repos/${GH_REPO}" --jq .id)"
[[ "${GH_REPO_ID}" =~ ^[0-9]+$ ]] || printf 'GH_REPO_ID is empty or not a number: do not continue\n'
printf '%s\n' "${GH_REPO_ID}"
```

Expect: two numbers. Only then save the second:

✏️

```bash
printf 'export GH_REPO_ID="%s"\n' "${GH_REPO_ID}" >> ~/gke-setup.env
```

The guide used `curl https://api.github.com/...` and a `python3` one-liner. That fails for a private repository
and gives an empty ID on a rate limit; `gh api` works for both, so this page uses it. The repository must exist
first.

### 6.2 The immutable OIDC subject prefix

GitHub repositories created after 2026-07-15 use **immutable subjects** by default, and so do repositories
**renamed or transferred** after that date ([GitHub changelog, 2026-04-23](https://github.blog/changelog/2026-04-23-immutable-subject-claims-for-github-actions-oidc-tokens)). The prefix contains the names, so a rename changes it: read it again and rebind. The token's `sub` claim is
then `repo:<owner>@<owner-id>/<repo>@<repo-id>:environment:<env>`, not `repo:<owner>/<repo>:environment:<env>`.
A binding written in the old form never matches a new repository, and every login fails with
`iam.serviceAccounts.getAccessToken denied` (see the troubleshooting index). Derive the prefix from the API
rather than assembling it by hand:

🔍 ✏️ (read from GitHub; appends to the env file)

```bash
source ~/gke-setup.env
SUB_PREFIX="$(gh api "repos/${GH_REPO}/actions/oidc/customization/sub" --jq .sub_claim_prefix)"
printf '%s\n' "${SUB_PREFIX}"
printf 'export SUB_PREFIX="%s"\n' "${SUB_PREFIX}" >> ~/gke-setup.env
```

Expect: `repo:<owner>@<number>/<repo>@<number>` for a new repository; plain `repo:<owner>/<repo>` for one
created before that date. This guide uses `${SUB_PREFIX}` everywhere a subject is built.

### 6.3 The pool and the provider

The condition admits a token only if the owner ID, the repository ID and the running workflow file all
match: `deploy.yml` or `deploy-ops.yml`, on `main` or a `v*` tag. The regex is a CEL string, so each backslash
is doubled; the final `\$` keeps a literal `$` for the shell.

✏️ Create the pool and the provider.

```bash
source ~/gke-setup.env

CONDITION="assertion.repository_owner_id=='${GH_OWNER_ID}' && assertion.repository_id=='${GH_REPO_ID}' && assertion.job_workflow_ref.matches('^${GH_REPO}/\\\\.github/workflows/(deploy|deploy-ops)\\\\.yml@refs/(heads/main|tags/v.*)\$')"
printf '%s\n' "${CONDITION}"

gcloud iam workload-identity-pools create github \
  --location=global --display-name="GitHub Actions"

gcloud iam workload-identity-pools providers create-oidc github-oidc \
  --location=global --workload-identity-pool=github \
  --display-name="GitHub OIDC" \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repository_owner_id=assertion.repository_owner_id,attribute.repository_id=assertion.repository_id,attribute.job_workflow_ref=assertion.job_workflow_ref,attribute.ref=assertion.ref" \
  --attribute-condition="${CONDITION}"
```

Why `printf` and not `echo` for the condition: in zsh `echo` turns `\\.` into `\.`, so a correct value looks
wrong. The printed condition must read `...matches('^<owner>/<repo>/\\.github/workflows/(deploy|deploy-ops)\\.yml@refs/(heads/main|tags/v.*)$')`.

The first version of this step (an earlier guide) used only `assertion.repository=='<owner>/<repo>'`. That
admits any workflow in the repository on any branch; the three-part condition is the corrected form.

🔍 Check the stored condition, by eye and by comparison.

```bash
gcloud iam workload-identity-pools providers describe github-oidc \
  --location=global --workload-identity-pool=github \
  --format='value(state,attributeCondition)'

actual="$(gcloud iam workload-identity-pools providers describe github-oidc \
  --location=global --workload-identity-pool=github --format='value(attributeCondition)')"
[[ "${actual}" == "${CONDITION}" ]] && printf 'condition matches\n' || printf 'DIFFERENT: compare by eye\n'
```

Expect: `ACTIVE` followed by the condition, then `condition matches`. (`CONDITION` is only set in the same
terminal as the create step; set it again if you opened a new one.) A deleted pool's name stays reserved for 30
days, so a typo in the pool name is expensive: check it before running the create.

Now managed by OpenTofu in `envs/apps` (module `gcp-github-wif`, imported). Do not change by hand.

### 6.4 The deployer role

The DNS-based endpoint needs the permission `container.clusters.connect`. `roles/container.clusterViewer`
has had it. Check, and fall back to a custom role if Google changes the role. Never give a deployer
`roles/container.developer` or `roles/container.viewer`: through IAM they grant Kubernetes rights in every
namespace and defeat the per-namespace RBAC.

🔍 ✏️ (appends to the env file; the `else` branch creates a custom role)

```bash
if gcloud iam roles describe roles/container.clusterViewer --format='value(includedPermissions)' \
     | tr ';' '\n' | grep -qx container.clusters.connect; then
  export DEPLOYER_CLUSTER_ROLE="roles/container.clusterViewer"
else
  gcloud iam roles create gkeDnsConnect --project="${PROJECT_ID}" --title="GKE DNS endpoint connect" \
    --permissions=container.clusters.get,container.clusters.connect --stage=GA
  export DEPLOYER_CLUSTER_ROLE="projects/${PROJECT_ID}/roles/gkeDnsConnect"
fi
printf 'export DEPLOYER_CLUSTER_ROLE="%s"\n' "${DEPLOYER_CLUSTER_ROLE}" >> ~/gke-setup.env
printf '%s\n' "${DEPLOYER_CLUSTER_ROLE}"
```

Expect: `roles/container.clusterViewer` (what the owner got) or the custom role. Rerunning the custom-role
create after it exists fails with "already exists"; skip it then.

### 6.5 One deployer service account per environment

A job of environment `dev` must never act as the production deployer, so each environment gets its own
service account, and only the subject that contains that environment's name may impersonate it. No key is
ever created for any of them.

✏️ Create the three accounts, the impersonation bindings and the cluster-connect grants. `${SUB_PREFIX}` is
from 6.2, and every variable before a colon is braced (zsh).

```bash
source ~/gke-setup.env
for env in dev qa production; do
  sa="gh-deployer-${env}"
  gcloud iam service-accounts create "${sa}" --display-name="GitHub Actions deployer (${env})"

  gcloud iam service-accounts add-iam-policy-binding "${sa}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role="roles/iam.workloadIdentityUser" \
    --member="principal://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github/subject/${SUB_PREFIX}:environment:${env}" \
    --format=none

  gcloud projects add-iam-policy-binding "${PROJECT_ID}" --condition=None \
    --member="serviceAccount:${sa}@${PROJECT_ID}.iam.gserviceaccount.com" --role="${DEPLOYER_CLUSTER_ROLE}" \
    --format=none
done
```

The guide wrote the member as `.../subject/repo:$GH_REPO:environment:$env`. That had two problems, both found
only when the first CI check failed: in zsh `$GH_REPO:e` is a modifier, so the member became
`.../subject/repo:nvironment:<env>`; and for a repository with immutable subjects, even the correctly expanded
form never matches. See 6.7 for repairing bindings made that way.

🔍 Before the cluster bootstrap, each deployer can do nothing in the cluster (needs your admin kubeconfig).

```bash
for env in dev qa production; do
  printf '%s: %s\n' "${env}" "$(kubectl auth can-i create deployments --namespace default --as="gh-deployer-${env}@${PROJECT_ID}.iam.gserviceaccount.com")"
done
```

Expect: `no` three times. Deploy rights are Kubernetes RBAC, delivered by the bootstrap in section 7.

Now managed by OpenTofu in `envs/apps` (module `gcp-github-wif`, imported: the three accounts, the three
impersonation members, the three cluster-viewer grants). Do not change by hand.

### 6.6 IAM propagation wait

A new or changed IAM binding is not effective everywhere at once. After changing a `workloadIdentityUser`
binding, wait up to about 7 minutes before rerunning a failed job. In the owner's run, a rerun at 1 to 2
minutes was still denied and one at about 5 minutes passed. A denial right after a change is not proof the
change is wrong.

### 6.7 Repair bindings made the old way (the rebind fix)

If the first CI check fails with `getAccessToken denied` (14), list what each deployer has:

🔍

```bash
for env in dev qa production; do
  printf '%s: %s\n' "${env}" "$(gcloud iam service-accounts get-iam-policy "gh-deployer-${env}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --format='value(bindings.members)')"
done
```

Expect, once correct: each line ends with `/subject/<SUB_PREFIX>:environment:<env>` for its own `<env>`, and has
no other member. Three wrong members can show up:

- the classic `.../subject/repo:<owner>/<repo>:environment:<env>` (right for an old repository, wrong for one with
  immutable subjects);
- the zsh-mangled `.../subject/repo:nvironment:<env>` (the guide's command run in zsh);
- the second mangled form `.../subject/nvironment:<env>` (a repair run in zsh without braces).

How it went on 2026-11-27, which explains the two mangled forms. The guide's command, run in zsh, created
`.../subject/repo:nvironment:<env>`. The first repair, still unbraced, added `${POOL}/${SUB_PREFIX}:environment:${env}`;
since `${SUB_PREFIX}:e` is empty here (there is no dot), zsh turned it into `.../subject/nvironment:<env>`.
That repair's remove used `repo:$GH_REPO:environment:$env`, which expands to `repo:nvironment:<env>`, so it did
remove the first mangled member (it matched only because it expanded the same way). The second repair used
braces, added the correct member and removed `${POOL}/nvironment:${env}`, the member the first repair had added.
After that, each deployer showed exactly one member: its own environment's immutable subject. The live setup is
clean.

Add the correct member, then remove each wrong member the listing showed, one line per form. A `remove` fails
with "not found" for a member that is not there, so run a remove line only if the listing shows that member.
`printf '%s\n'` shows the prefix for you to check first.

✏️ Add the correct binding.

```bash
source ~/gke-setup.env
POOL="principal://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github/subject"
printf '%s\n' "${SUB_PREFIX}"

for env in dev qa production; do
  sa="gh-deployer-${env}@${PROJECT_ID}.iam.gserviceaccount.com"
  gcloud iam service-accounts add-iam-policy-binding "${sa}" --role=roles/iam.workloadIdentityUser \
    --member="${POOL}/${SUB_PREFIX}:environment:${env}" --format=none
done
```

✏️ Remove a wrong member (one block per form shown by the listing, for the environment `env` that has it). For
the classic form use `${POOL}/repo:${GH_REPO}:environment:${env}` as the member.

```bash
sa="gh-deployer-${env}@${PROJECT_ID}.iam.gserviceaccount.com"
gcloud iam service-accounts remove-iam-policy-binding "${sa}" \
  --role=roles/iam.workloadIdentityUser --member="${POOL}/repo:nvironment:${env}" --format=none
gcloud iam service-accounts remove-iam-policy-binding "${sa}" \
  --role=roles/iam.workloadIdentityUser --member="${POOL}/nvironment:${env}" --format=none
```

The first command removes the first mangled form and the second removes the second; run only the one the
listing showed. Set `env` to `dev`, `qa` or `production` first, or put the block in the
`for env in dev qa production` loop. After section 11 these bindings are managed by OpenTofu (module
`gcp-github-wif`, from `sub_claim_prefix`): do not repair them by hand. Fix the value, review a plan and apply
it. A hand fix would show as drift.

Then rerun the failed workflow runs (the run IDs are on the run pages):

✏️ (starts the workflow again)

```bash
gh run rerun <run-id> --repo "${GH_REPO}"
```

Expect: green after the propagation wait (6.6).

