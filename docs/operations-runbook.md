# Operations runbook: every manual step, by stage of the stack

This is the owner's complete list of the manual commands used to build the platform by hand and then bring
it under OpenTofu. Each entry says what the command is for, whether it changes anything, what to expect, and
the idea behind it. The stages follow the order the platform was built in.

It does not replace the step-by-step guides (the template's `wiki/gke-cluster-setup.md`,
`wiki/platform-setup.md`, `wiki/github-repository-settings.md`) or this repository's
[`import-runbook.md`](import-runbook.md) and [`hardening-runbook.md`](hardening-runbook.md). It collects the
commands the owner ran or was told to run, with the corrections found on the way. A few items were added for
completeness; each is marked "Added for completeness, not from the session". Where a guide command and the
command that worked differ, this page gives the working one and says why.

This page is public. It contains no real project ID, number, account, e-mail, ID or secret: every value is a
variable from the env file or a placeholder such as `your-project-id` or `<billing-account>`.

## Contents

0. [How to use this runbook](#0-how-to-use-this-runbook)
1. [Workstation setup](#1-workstation-setup)
2. [Google Cloud project foundation](#2-google-cloud-project-foundation)
3. [Network](#3-network)
4. [Node service account](#4-node-service-account)
5. [GKE cluster](#5-gke-cluster)
6. [GitHub identity and Workload Identity Federation](#6-github-identity-and-workload-identity-federation)
7. [Cluster bootstrap](#7-cluster-bootstrap)
8. [Secrets](#8-secrets)
9. [GitHub repository settings and the release App](#9-github-repository-settings-and-the-release-app)
10. [Read-only live-config export](#10-read-only-live-config-export)
11. [OpenTofu: state, import, apply](#11-opentofu-state-import-apply)
12. [OpenTofu: GKE hardening](#12-opentofu-gke-hardening)
13. [Git and publishing](#13-git-and-publishing)
14. [Troubleshooting index](#14-troubleshooting-index)
15. [Concepts glossary](#15-concepts-glossary)
16. [Appendix: pausing the cluster and other one-off commands](#16-appendix-pausing-the-cluster-and-other-one-off-commands)

---

## 0. How to use this runbook

### Legend

| Mark | Meaning |
| --- | --- |
| 🔍 | Read-only. Safe to run any number of times. |
| ✏️ | Changes something (cloud, cluster, GitHub or local files). Read the "Expect" line first. |
| 🔐 | Handles a secret. The value is read from a file or standard input and is never typed, echoed or put on a command line. |

A block with several marks changes things in the order shown.

### Conventions

- **Run from where?** Every stage starts with a "Run from" line. Three places are used:
  - anywhere: workstation and `gcloud`, `gh` and `kubectl` commands;
  - the template repository root (your clone of the fullstack template): its `scripts/` and `deploy/` paths;
  - this repository's root (`lodestar-infra`): everything that starts with `tofu -chdir=` or `make`.
- **One terminal per stage, in order.** Variables set in one block are used by the next one. A new terminal
  needs `source ~/gke-setup.env` again.
- **bash and zsh.** All commands are written to work in both. Three zsh rules matter:
  1. **Brace a variable that is followed by a colon.** zsh treats `$VAR:e`, `:h`, `:t`, `:r`, `:a`, `:l`,
     `:u`, `:s`, `:q`, `:x`, `:p` and `:c` as history modifiers. `$GH_REPO:environment:$env` silently
     becomes `nvironment:dev`. Always write `${GH_REPO}:environment:${env}`.
  2. **Use `printf '%s\n' "${VAR}"`, not `echo`,** to show a value that has backslashes. zsh's built-in
     `echo` interprets them, so a correct value looks wrong.
  3. **Comments.** An interactive zsh does not ignore `# comment` by default. Run `setopt interactive_comments`
     once in the terminal, or leave the comments out when you paste.
- **`GH_REPO` pitfall.** The `gh` CLI honours the `GH_REPO` environment variable over the current directory.
  The env file sets it to the template repository, so a `gh` command run in this repository acts on the
  template. For `lodestar-infra` commands either run `unset GH_REPO` first or pass
  `-R "<owner>/lodestar-infra"`. `scripts/github-settings.sh` reads its repository from this checkout's
  `origin` remote and refuses to run while `GH_REPO` points elsewhere.
- **No comments in code blocks.** Code blocks contain no comments, so they paste safely into any zsh (where
  `#` is not a comment by default); the explanations live in the text around them.
- **Never paste prose.** A sentence copied into the shell is run as a command. It fails with errors such as
  `Excess arguments.` or `command not found`, and the next lines may still run. Copy only the code block.
- **Saved plans.** OpenTofu plans are saved to a file (`-out=...`), reviewed, and applied by that file. The file
  is deleted after use (`rm -f`), so a second apply of the same name fails; plan again.
- **Never commit** the env file, anything in `~/platform-config`, `*.tfvars`, `override.tf` or `*.tfplan`.
  The `.gitignore` already covers the last three.

### The env file and the private folder

`~/gke-setup.env` is a shell file of `export` lines, written once and loaded with `source ~/gke-setup.env`.
It lives in your home directory, outside every repository. Its variable names (never commit its values):

| Variable | Meaning | Set in |
| --- | --- | --- |
| `PROJECT_ID`, `PROJECT_NUMBER` | the Google Cloud project's ID and its numeric number | 2 |
| `REGION`, `ZONE` | `europe-west1` and `europe-west1-b` (the guide's defaults) | 2 |
| `CLUSTER`, `NETWORK`, `SUBNET`, `AR_REPO` | cluster `apps`, VPC `apps-vpc`, subnet `apps-subnet`, registry `apps` | 2 |
| `GH_OWNER`, `GH_REPO_NAME`, `GH_REPO` | the GitHub owner, repository name and `owner/name` | 2 |
| `KUBECONFIG` | a separate kubeconfig file, so this cluster never mixes with kind or minikube contexts | 2 |
| `NODE_SA` | the node service account's e-mail | 4 |
| `GH_OWNER_ID`, `GH_REPO_ID` | numeric IDs of the GitHub owner and repository | 6 |
| `SUB_PREFIX` | the repository's immutable OIDC subject prefix | 6 |
| `DEPLOYER_CLUSTER_ROLE` | the role that lets a deployer reach the cluster's DNS endpoint | 6 |
| `SERVICE_NAME` | the Helm release name and the namespace prefix | 8 |

`~/platform-config` (mode `700`) is the private folder for everything that holds identifiers:

| Path | What |
| --- | --- |
| `bootstrap-values-<env>.yaml` | the deployer name per environment, input of the bootstrap render |
| `bootstrap-<env>.yaml` | the rendered bootstrap manifests per environment |
| `github-vars.env` | the variables the GitHub settings script sets (mode `600`) |
| `settings-dryrun.txt` | the saved dry run of the settings script |
| `live/*.yaml` | the read-only export of the hand-built setup (mode `600`) |
| `bootstrap-override.tf` | a backup of `bootstrap/override.tf`, the only record of the state backend (mode `600`) |

The same rule covers both: nothing in them is ever committed, and anything that looks like a secret stays
out of them as well (the App's private key is deleted after it is stored in GitHub).

Create the env file once (the quoted `'EOF'` keeps the `${...}` unexpanded, so they are filled in when the
file is sourced). Then edit the three placeholders by hand.

✏️ Create the env file.

```bash
cat > ~/gke-setup.env <<'EOF'
export PROJECT_ID="your-project-id"
export REGION="europe-west1"
export ZONE="europe-west1-b"
export CLUSTER="apps"
export NETWORK="apps-vpc"
export SUBNET="apps-subnet"
export AR_REPO="apps"
export GH_OWNER="your-github-user"
export GH_REPO_NAME="your-repo-name"
export GH_REPO="${GH_OWNER}/${GH_REPO_NAME}"
export KUBECONFIG="${HOME}/.kube/gke-apps.yaml"
EOF
```

Expect: no output. Then open `~/gke-setup.env` and replace `your-project-id`, `your-github-user` and
`your-repo-name`.

Notes:

- The guide's defaults were `CLUSTER=apps-dev` and `SUBNET=apps-dev-subnet`. The owner renamed both to
  `apps` and `apps-subnet` before creating the cluster (the cluster hosts all three environments, so `-dev`
  was misleading), and changed the kubeconfig name to match. This page uses the final names.
- An unfilled placeholder is easy to miss. Check with `printf '%s\n' "${GH_REPO}"` after sourcing. A wrong
  repository name (a hyphen instead of an underscore, say) makes later `gh` commands fail with "not found".
- Appended lines need `export`, or child processes (scripts) do not see the variable after a re-source.
  The guide's `echo "PROJECT_NUMBER=..." >> ~/gke-setup.env` had no `export`; section 2 uses the corrected form.

---

## 1. Workstation setup

Run from: anywhere. Goal: every tool is present and prints a version.

### 1.1 Google Cloud CLI, the auth plugin and kubectl

The CLI is installed from Google's package repository (see
<https://cloud.google.com/sdk/docs/install>). On Debian or Ubuntu it comes from an apt source.

**Duplicate apt source.** `sudo apt update` can warn that the Google Cloud SDK source is configured twice
(two files in `/etc/apt/sources.list.d/` naming the same repository). Keep exactly one. Find them, then
write the single correct line:

🔍 List every file that names the repository. (Added for completeness, not from the session.)

```bash
grep -rl 'packages.cloud.google.com/apt' /etc/apt/sources.list /etc/apt/sources.list.d/
```

✏️ Write the one source file (it replaces the file of the same name) and refresh. Delete any other file the
grep listed.

```bash
printf '%s\n' 'deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main' \
  | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list
sudo apt update
```

Expect: `apt update` runs with no "configured multiple times" warning. Why: two entries for one repository make
apt warn on every run and can hide a real error.

✏️ Install the GKE auth plugin. Without it every `kubectl` call to GKE fails with
`gke-gcloud-auth-plugin ... not found`.

```bash
sudo apt-get install google-cloud-cli-gke-gcloud-auth-plugin
```

(If you installed the CLI from the tarball instead of apt: `gcloud components install gke-gcloud-auth-plugin`.
`kubectl` can come the same way, `gcloud components install kubectl`, or from your package manager.)

🔍 Check all four tools.

```bash
gcloud version
gke-gcloud-auth-plugin --version
kubectl version --client
jq --version
```

Expect: a version for each. If a `gcloud` flag later reports "unrecognized", update the CLI
(`gcloud components update`, or apt) and rerun section 5.1.

### 1.2 The repository toolchain: helm, yq, kubectl (template) and OpenTofu (this repository)

Both repositories install their pinned tools into a local `./.tools` folder, each download checked against
a sha256. Nothing is installed system-wide.

✏️ In the template repository (Helm 4, yq, kubectl, the chart pins). Run from the template repository root.

```bash
scripts/tools.sh install
export PATH="${PWD}/.tools/bin:${PATH}"
```

(`scripts/tools.sh install helm4 external-secrets-chart` installs only what section 8 needs. Added for
completeness, not from the session: the owner's own install command for `yq`, `helm` and `kubectl` is not in
the record, so the no-argument form here is the documented one.)

✏️ In this repository (OpenTofu, tflint, checkov, bats, shellcheck, gitleaks, actionlint, zizmor, pre-commit). Run from this repository's
root. It needs `uv`, `curl`, `make` and `bash`.

```bash
make tools
export PATH="${PWD}/.tools/bin:${PATH}"
tofu version
```

Expect: `OpenTofu v1.13.9`. Why `PATH` is set again in each new terminal: the tools live in the folder, not in
a system path.

### 1.3 GitHub CLI and login

`gh` is installed from GitHub's package repository (<https://cli.github.com/>), or with your package manager.

✏️ Log in as a repository admin (the settings script and `gh secret set` need admin rights).

```bash
gh auth login
```

Answer the prompts: GitHub.com, HTTPS, then **Login with a web browser**. This is the **device flow**: `gh`
prints a one-time code, you open the printed URL in a browser, type the code and approve. The terminal waits
until you do. If the browser step is skipped or the code expires, the command ends without a token; run it
again.

🔍 Prove it worked, and that you are an admin of the repository.

```bash
gh auth status
gh api "repos/${GH_REPO}" --jq .permissions.admin
```

Expect: "Logged in to github.com" and `true`. Why: the second command checks the right the later steps need,
not just the login. If it prints `false` or "Not Found", the account is not an admin or `GH_REPO` is wrong.

### 1.4 jq and yq

`jq` is used for filtering JSON (`kubectl get -o json`, `helm list --output json`, the RBAC check in section
12). `yq` comes with the template's tools (1.2) and is used to split the bootstrap manifests in section 7.
Both print a version: `jq --version`, `yq --version`.

---

## 2. Google Cloud project foundation

Run from: anywhere. Goal: an existing project with billing, the seven core APIs, a budget, and local
credentials in two places (the CLI's, and Application Default Credentials).

Creating the project itself is done in the console or with `gcloud projects create`; the template guide has no
step for it (a known gap) and no transcript of it exists in the sources, so it is not repeated here.

### 2.1 Log in and point gcloud at the project

✏️ (local config only)

```bash
gcloud auth login
gcloud init --skip-diagnostics
```

`gcloud auth login` opens a browser and stores the credentials the **CLI itself** uses. `gcloud init` walks
through choosing the account and the default project; `--skip-diagnostics` skips its network test.

Now load the env file (section 0), set the project and read its number.

✏️ ✏️ (local config; the env file gains one line)

```bash
source ~/gke-setup.env
gcloud config set project "${PROJECT_ID}"
export PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"
printf 'export PROJECT_NUMBER="%s"\n' "${PROJECT_NUMBER}" >> ~/gke-setup.env
```

🔍 Check.

```bash
gcloud config get-value project
printf '%s\n' "${PROJECT_NUMBER}"
gcloud auth list --filter=status:ACTIVE --format='value(account)'
```

Expect: the project ID, a 10 to 12 digit number, and your Google account. Why the number: the project
*number* (not the ID) appears in the Workload Identity principals and in Secret Manager resource names.
Why `export`: see the note in section 0.

### 2.2 Link billing

🔍 List the billing accounts you can use, and note the account ID (`XXXXXX-XXXXXX-XXXXXX`).

```bash
gcloud billing accounts list
```

✏️ Link it to the project, then check.

```bash
gcloud billing projects link "${PROJECT_ID}" --billing-account="<billing-account>"
gcloud billing projects describe "${PROJECT_ID}" --format='value(billingEnabled)'
```

Expect: `True`. Nothing that costs money works before this.

### 2.3 Enable the APIs

An API must be enabled in the project before its resources can be created.

✏️ Seven core APIs. Takes about a minute.

```bash
gcloud services enable \
  compute.googleapis.com container.googleapis.com artifactregistry.googleapis.com \
  iam.googleapis.com iamcredentials.googleapis.com sts.googleapis.com \
  cloudresourcemanager.googleapis.com
```

🔍 Count them.

```bash
gcloud services list --enabled --format='value(config.name)' | grep -E \
 '^(compute|container|artifactregistry|iam|iamcredentials|sts|cloudresourcemanager)\.googleapis\.com$' | wc -l
```

Expect: `7`. Two more APIs are enabled later by the stage that needs them: `billingbudgets` (2.4) and
`secretmanager` (section 8). The state bucket's own APIs (`cloudkms`, `storage`, `serviceusage`) are enabled
by OpenTofu in section 11.

Now managed by OpenTofu in `envs/apps` (the nine APIs): do not change by hand; change the code and plan.

### 2.4 The budget

A budget alerts you; it does not stop spending.

✏️ Enable the Budgets API, and read the billing account from the project.

```bash
source ~/gke-setup.env
gcloud services enable billingbudgets.googleapis.com
BILLING_ACCOUNT="$(gcloud billing projects describe "${PROJECT_ID}" \
  --format='value(billingAccountName)' | cut -d/ -f2)"
```

🔍 List the budgets that already exist on the account. Do this before creating one: a budget made in the
console earlier would be duplicated.

```bash
gcloud billing budgets list --billing-account="${BILLING_ACCOUNT}" \
  --format='yaml(displayName,amount.specifiedAmount,budgetFilter.projects,thresholdRules)'
```

The owner's account already had a budget made in the console, and he kept it: the record shows only the
`budgets list` command above, never a create or an update. Its live settings are the ones the OpenTofu module
records: 20 EUR a month, scoped to this project, with alerts at 0.5, 0.9, 1.0 and 1.5 of *current* spend and no
forecasted-spend rule.

If none covers your project, you can create one. Set the amount inside the block, and keep it equal to the
module's `amount_units` and `currency_code` (`modules/gcp-budget`), or the next plan shows a change.
Added for completeness, not from the session: `gcloud` documents `percent` as a fraction from 0.0 to 1.0, so a
1.5 threshold (150 percent) was set in the console, and the `percent=1.5` line below is untested.

✏️ Create (only if there is none).

```bash
gcloud billing budgets create --billing-account="${BILLING_ACCOUNT}" \
  --display-name="${PROJECT_ID} monthly" \
  --budget-amount=20.00EUR \
  --filter-projects="projects/${PROJECT_ID}" \
  --threshold-rule=percent=0.5 \
  --threshold-rule=percent=0.9 \
  --threshold-rule=percent=1.0 \
  --threshold-rule=percent=1.5
```

🔍 Check: rerun the `budgets list` command above.

Expect: `projects/<number>` in the filter; thresholds 0.5, 0.9, 1.0 and 1.5, all of current spend.

Now managed by OpenTofu in `envs/apps` (module `gcp-budget`, imported). Do not change by hand; change the
code, not the budget, and plan.

### 2.5 Application Default Credentials (ADC) and the quota project

OpenTofu's Google provider, and any program that uses Google's client libraries, do not read the login of
`gcloud auth login`. They read **Application Default Credentials**, a separate credential file. Log in a
second time for it, and set the **quota project**: the project that user-credential API calls are billed and
rate-limited against.

✏️ (writes `~/.config/gcloud/application_default_credentials.json`)

```bash
gcloud auth application-default login
gcloud auth application-default set-quota-project "${PROJECT_ID}"
printf 'project=%s region=%s zone=%s\n' "${PROJECT_ID}" "${REGION}" "${ZONE}"
```

Expect: a browser login, then "Quota project ... was added to ADC". The `printf` must show your three values;
an empty one means the env file was not sourced. The provider in `envs/apps` also sets
`user_project_override = true` and `billing_project`, because the Billing Budgets API refuses user
credentials without them. The ADC login is needed from section 11 on, and expires: repeat it when
OpenTofu reports an authentication error.

---

## 3. Network

Run from: anywhere, with the env file sourced. Goal: a private VPC whose nodes have no public address, with
Private Google Access and Cloud NAT.

Concepts: the nodes have **no public IP**. They reach Google services (Artifact Registry, the APIs) through
**Private Google Access** and the internet (Docker Hub and similar) through **Cloud NAT**. The subnet has two
**secondary ranges**, one for Pod IPs and one for Service IPs (a "VPC-native" cluster).

✏️ Create the network, subnet, router and NAT. Creating the VPC in custom mode means no default subnets.

```bash
source ~/gke-setup.env

gcloud compute networks create "${NETWORK}" --subnet-mode=custom

gcloud compute networks subnets create "${SUBNET}" \
  --network="${NETWORK}" --region="${REGION}" \
  --range=10.10.0.0/20 \
  --secondary-range=pods=10.20.0.0/16,services=10.30.0.0/20 \
  --enable-private-ip-google-access

gcloud compute routers create apps-router --network="${NETWORK}" --region="${REGION}"
gcloud compute routers nats create apps-nat --router=apps-router --region="${REGION}" \
  --auto-allocate-nat-external-ips --nat-all-subnet-ip-ranges \
  --enable-logging --log-filter=ERRORS_ONLY
```

Notes:

- The three ranges are private addresses. Change them only if they clash with a network you connect to later.
- NAT logging is limited to errors, which keeps the log cost near zero.
- **Pitfall: the subnet name.** The first run used the guide's `apps-dev-subnet`. When the owner renamed the
  cluster and subnet to the `apps` names, the old subnet was deleted and recreated before any cluster used
  it. Do that only while nothing runs in the subnet (`gcloud compute networks subnets delete apps-dev-subnet
  --region="${REGION}" --quiet` fails, or breaks a cluster, if something does). With a fresh start, just use
  the final `${SUBNET}` value from the beginning.
- A paste of only the first lines of a multi-line command (a trailing `\` with nothing after it) leaves the
  command waiting for more input. Copy the whole block.

🔍 Check.

```bash
gcloud compute networks subnets describe "${SUBNET}" --region="${REGION}" \
  --format='value(privateIpGoogleAccess,secondaryIpRanges[].rangeName)'
gcloud compute routers nats describe apps-nat --router=apps-router --region="${REGION}" \
  --format='value(name,sourceSubnetworkIpRangesToNat)'
```

Expect: `True` and the range names `pods;services` (the separator can vary), then
`apps-nat  ALL_SUBNETWORKS_ALL_IP_RANGES`.

Now managed by OpenTofu in `envs/apps` (module `gcp-network`: VPC, subnet, router, NAT; imported). Do not
change by hand. VPC flow logs on the subnet were added by the hardening change (section 12).

---

## 4. Node service account

Run from: anywhere. Goal: the identity the nodes run as, with only what nodes need.

Concept: by default GKE nodes use the Compute Engine default service account, which usually holds **Editor**
on the whole project. Replace it with a dedicated account that can only write logs and metrics (and, later,
read the registry).

✏️ Create the account and save its e-mail in the env file.

```bash
gcloud iam service-accounts create gke-nodes --display-name="GKE nodes (apps)"
export NODE_SA="gke-nodes@${PROJECT_ID}.iam.gserviceaccount.com"
printf 'export NODE_SA="%s"\n' "${NODE_SA}" >> ~/gke-setup.env
```

(The first run used the display name `GKE nodes (apps-dev)`; it was renamed with
`gcloud iam service-accounts update "${NODE_SA}" --display-name="GKE nodes (apps)"`. The display name is
cosmetic.)

🔍 Check that Google's ready-made node role exists in your project:

```bash
gcloud iam roles describe roles/container.defaultNodeServiceAccount --format='value(title)'
```

If it prints a title, grant it. The `--condition=None` is required: without it, on a policy that already has
conditional bindings, `gcloud` asks interactively which condition to use.

✏️ Grant.

```bash
gcloud projects add-iam-policy-binding "${PROJECT_ID}" --condition=None \
  --member="serviceAccount:${NODE_SA}" --role="roles/container.defaultNodeServiceAccount" \
  --format=none
```

If the role does not exist, grant the four classic node roles instead:

✏️ Grant (fallback).

```bash
for role in roles/logging.logWriter roles/monitoring.metricWriter \
            roles/monitoring.viewer roles/stackdriver.resourceMetadata.writer; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" --condition=None \
    --member="serviceAccount:${NODE_SA}" --role="${role}" --format=none
done
```

🔍 Check.

```bash
gcloud projects get-iam-policy "${PROJECT_ID}" --flatten='bindings[].members' \
  --filter="bindings.members:serviceAccount:${NODE_SA}" --format='value(bindings.role)'
```

Expect: the node role (or the four classic ones) and nothing else: no editor, no owner.

Now managed by OpenTofu in `envs/apps` (module `gcp-node-sa`, imported). Do not change by hand.

---

## 5. GKE cluster

Run from: anywhere. Goal: a private, zonal, spot-node Standard cluster, and a working `kubectl`.

### 5.1 Check that your gcloud knows every flag

🔍

```bash
for f in --enable-private-nodes --enable-dataplane-v2 --gateway-api --workload-pool \
         --enable-managed-prometheus --maintenance-window-recurrence --shielded-secure-boot \
         --cluster-secondary-range-name --enable-dns-access --spot; do
  gcloud container clusters create --help 2>/dev/null | grep -q -- "${f}" \
    && printf 'ok       %s\n' "${f}" || printf 'MISSING  %s   (update gcloud, then rerun this check)\n' "${f}"
done
```

Expect: every line starts with `ok`.

### 5.2 Create the cluster

✏️ Takes about 8 to 12 minutes and starts billing.

```bash
gcloud container clusters create "${CLUSTER}" \
  --location="${ZONE}" \
  --release-channel=stable \
  --network="${NETWORK}" --subnetwork="${SUBNET}" \
  --enable-ip-alias \
  --cluster-secondary-range-name=pods --services-secondary-range-name=services \
  --enable-private-nodes \
  --enable-dns-access \
  --enable-dataplane-v2 \
  --workload-pool="${PROJECT_ID}.svc.id.goog" \
  --gateway-api=standard \
  --service-account="${NODE_SA}" \
  --machine-type=e2-standard-2 --disk-type=pd-balanced --disk-size=50 \
  --num-nodes=2 --enable-autoscaling --min-nodes=1 --max-nodes=3 \
  --shielded-secure-boot --shielded-integrity-monitoring \
  --logging=SYSTEM,WORKLOAD --monitoring=SYSTEM --enable-managed-prometheus \
  --maintenance-window-start=2026-11-21T00:00:00Z \
  --maintenance-window-end=2026-11-21T08:00:00Z \
  --maintenance-window-recurrence='FREQ=WEEKLY;BYDAY=SA,SU' \
  --labels=cluster=apps \
  --enable-cost-allocation \
  --spot
```

What each flag is for:

| Flag | Why |
| --- | --- |
| `--location="${ZONE}"` | a **zonal** cluster: one control plane in one zone. Cheaper (the free tier covers the management fee) but the control plane is briefly unavailable during upgrades and some changes. |
| `--release-channel=stable` | Google patches and upgrades for you. The guide says `regular`; the owner chose `stable`. The channel can be changed later. |
| `--network`, `--subnetwork`, `--enable-ip-alias`, `--cluster-secondary-range-name`, `--services-secondary-range-name` | VPC-native cluster using the subnet and its two secondary ranges from section 3. Fixed at creation. |
| `--enable-private-nodes` | nodes get no public IP (they use NAT and Private Google Access). |
| `--enable-dns-access` | the **DNS-based control-plane endpoint**: reached with IAM only, no IP allowlist. CI and your laptop use it, and it keeps working if the public IP endpoint is closed later. |
| `--enable-dataplane-v2` | Cilium-based data plane: **NetworkPolicy is enforced**. Fixed at creation. |
| `--workload-pool` | turns on **Workload Identity for GKE**: Pods act as Google identities without key files. |
| `--gateway-api=standard` | the Gateway API CRDs and GKE's Gateway classes. |
| `--service-account` | nodes run as the minimal account of section 4. |
| `--machine-type`, `--disk-type`, `--disk-size` | `e2-standard-2`, balanced persistent disk, 50 GB per node. |
| `--num-nodes=2`, `--enable-autoscaling --min-nodes=1 --max-nodes=3` | start with 2 nodes; the autoscaler keeps 1 to 3. |
| `--shielded-secure-boot`, `--shielded-integrity-monitoring` | Shielded nodes. |
| `--logging`, `--monitoring`, `--enable-managed-prometheus` | system and workload logs, system metrics, Google Managed Prometheus. |
| `--maintenance-window-*` | upgrades only on Saturday and Sunday 00:00 to 08:00 UTC. GKE needs at least 48 hours of maintenance time in any 32 days, in blocks of 4 hours or more; two 8-hour days a week give 64. A shorter window fails with `Maintenance policy would go longer than 32d without 48h maintenance availability`. |
| `--labels`, `--enable-cost-allocation` | a label for cost reports, and GKE cost allocation. |
| `--spot` | **spot nodes**: about 60 to 91 percent cheaper, but Google can reclaim a node at any time. Right for dev and qa, not for production on its own. |

If the command asks for `--master-ipv4-cidr`, your gcloud still uses the older private-cluster model: add
`--master-ipv4-cidr=172.16.0.32/28` and run it again. A quota error (`CPUS`, `IN_USE_ADDRESSES`,
`SSD_TOTAL_GB`) needs a quota increase (IAM and Admin, Quotas) or smaller nodes.

🔍 Check.

```bash
gcloud container clusters describe "${CLUSTER}" --location="${ZONE}" --format="yaml(
  status, releaseChannel.channel, workloadIdentityConfig.workloadPool,
  networkConfig.datapathProvider, networkConfig.gatewayApiConfig.channel,
  controlPlaneEndpointsConfig.dnsEndpointConfig,
  nodePools[0].config.serviceAccount, nodePools[0].config.spot, nodePools[0].autoscaling)"
```

Expect: `status: RUNNING`; `channel: STABLE`; `workloadPool: <project>.svc.id.goog`;
`datapathProvider: ADVANCED_DATAPATH`; gateway channel `CHANNEL_STANDARD`; `serviceAccount: gke-nodes@...`;
`spot: true`; `autoscaling.enabled: true`; a `dnsEndpointConfig` with an `endpoint:` host name and
`allowExternalTraffic: true`.

Settings that cannot be changed on a live cluster: name, location type, network and ranges, VPC-native, Dataplane V2.
Changeable later: release channel, labels, autoscaling, machine type (through a new pool).

Now managed by OpenTofu in `envs/apps` (module `gcp-gke`, imported). Do not change by hand; change the code
and plan. `deletion_protection` is on in state (the import sets it), so a destroy of the cluster is refused.

### 5.3 Connect `kubectl`

✏️ (writes the kubeconfig file named by `KUBECONFIG`)

```bash
source ~/gke-setup.env
gcloud container clusters get-credentials "${CLUSTER}" --location="${ZONE}" --dns-endpoint
```

`--dns-endpoint` writes a kubeconfig that uses the DNS-based endpoint, the same way CI connects. Because
`KUBECONFIG` is a separate file, your kind and minikube contexts are untouched.

🔍 Check nodes and Gateway classes.

```bash
kubectl get nodes -o wide
kubectl get gatewayclass
```

Expect: 2 nodes `Ready`, with `<none>` in the EXTERNAL-IP column (private nodes). The class list includes
`gke-l7-global-external-managed` and a few other `gke-l7-*` classes. If `kubectl` reports
`gke-gcloud-auth-plugin not found`, install the plugin (1.1); if it hangs, check `KUBECONFIG` and the node
count.

### 5.4 Prove outbound traffic and NetworkPolicy

This test pulls two public images (it proves NAT works), then shows a deny policy actually blocks traffic
(it proves Dataplane V2 enforces policies). It creates and deletes a throwaway namespace.

✏️ Create the test namespace and a web Pod.

```bash
kubectl create namespace np-test
kubectl -n np-test run web --image=nginxinc/nginx-unprivileged:stable-alpine --port=8080 --labels=app=web
kubectl -n np-test expose pod web --port=8080
kubectl -n np-test wait --for=condition=Ready pod/web --timeout=180s
```

Probe A: with no policy, a client can reach `web` (this also tests cluster DNS, since it uses the name).

✏️ (creates and removes a short-lived Pod)

```bash
kubectl -n np-test run probe-a --rm -i --restart=Never --image=busybox:1.37 -- \
  wget -qO- -T 5 http://web:8080 | grep -o '<title>.*</title>'
```

Expect: `<title>Welcome to nginx!</title>`. If `web` stays in `ImagePullBackOff`, NAT is missing or is in the
wrong region (recheck section 3).

Probe B: deny all ingress, then try again.

✏️

```bash
kubectl -n np-test apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: default-deny-ingress }
spec: { podSelector: {}, policyTypes: [Ingress] }
EOF
kubectl -n np-test run probe-b --rm -i --restart=Never --image=busybox:1.37 -- \
  wget -qO- -T 5 http://web:8080
echo "exit=$?"
```

Expect: the `wget` times out and `exit=` is not `0`.

**Pitfall: `bad port '8080;'`.** The guide put `; echo "exit=$?"` on the same line as the `wget`. The `;`
reached `wget` as part of the URL, and the probe failed at once with `bad port '8080;'`, which looks like a
blocked connection but is a malformed URL. The likeliest cause (added for completeness, not from the session:
the record shows only the corrected command) is zsh's `url-quote-magic` (a default of oh-my-zsh), which
backslash-escapes characters such as `;` after something that looks like a URL when you paste. A stray
backslash from another paste route gives the same result. Keep `echo "exit=$?"` on its own line, as above. The result of probe B is only valid if the failure
is a timeout, not that message.

✏️ Clean up.

```bash
kubectl delete namespace np-test
```

---

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

---

## 7. Cluster bootstrap

Run from: the template repository root, with your admin kubeconfig. Goal: the namespaces (restricted Pod
Security, a quota and a limit range) and the deployer RBAC for every environment.

Concept: the chart creates no namespaces and the deploy passes no `--create-namespace`. A cluster admin
renders and applies the bootstrap once per environment. The deployer's Kubernetes user name is its service
account's e-mail; the bootstrap binds a Role to that name in each of the environment's namespaces.

**Choose `SERVICE_NAME` first** (a template bug, open at the time of writing): the chart names a CronJob
`<fullname>-pg-backup-verify`, and the API refuses CronJob names over 52 characters. With a release name that
does not contain the chart's name, `fullname` is `<release>-<chart>`, which makes a long release name fail the
dev and qa deploys with the in-cluster database. Use a short name, or the chart's own name. The owner first
rendered with a longer name, hit this, deleted the empty namespaces and re-rendered (7.5).

### 7.1 Render the bootstrap for each environment

✏️ (writes files in `~/platform-config`). The `PATH` line puts the repository's pinned helm, yq and kubectl first.

```bash
source ~/gke-setup.env
export PATH="${PWD}/.tools/bin:${PATH}"
export SERVICE_NAME="your-service-name"
mkdir -p ~/platform-config && chmod 700 ~/platform-config

for env in dev qa production; do
  printf 'deployer:\n  name: gh-deployer-%s@%s.iam.gserviceaccount.com\n' "${env}" "${PROJECT_ID}" \
    > ~/platform-config/bootstrap-values-${env}.yaml
  scripts/k8s-bootstrap.sh "${env}" --release "${SERVICE_NAME}" \
    --values ~/platform-config/bootstrap-values-${env}.yaml > ~/platform-config/bootstrap-${env}.yaml
done

grep -hE '^kind:' ~/platform-config/bootstrap-*.yaml | sort | uniq -c
```

Expect: counts of each kind (Namespace, ResourceQuota, LimitRange, Role, RoleBinding, ...). Why the values
files live outside the repository: they hold your project ID in the deployer's e-mail, and the template is
public. `k8s-bootstrap.sh` only prints YAML; it never contacts the cluster.

### 7.2 Namespaces first, then a server dry run

**Pitfall: `NotFound` on a dry run.** `kubectl apply --dry-run=server` creates nothing, so objects in a
namespace that does not exist yet are refused with `NotFound`. Create the namespaces first, then dry-run.

✏️ Apply only the Namespace documents, then dry-run everything.

```bash
for env in dev qa production; do
  yq 'select(.kind == "Namespace")' ~/platform-config/bootstrap-${env}.yaml | kubectl apply -f -
done

for env in dev qa production; do kubectl apply --dry-run=server -f ~/platform-config/bootstrap-${env}.yaml; done
```

Expect: `namespace/... created` (or `unchanged`), then every dry-run line ends `(server dry run)` with no error.

### 7.3 Apply

✏️

```bash
for env in dev qa production; do kubectl apply -f ~/platform-config/bootstrap-${env}.yaml; done
```

Expect: objects `created` (or `configured` when you rerun it, which is safe).

### 7.4 Check the deployer's rights

🔍

```bash
for env in dev qa production; do
  printf '%s: %s %s\n' "${env}" \
    "$(kubectl auth can-i create deployments -n "${SERVICE_NAME}-${env}" --as="gh-deployer-${env}@${PROJECT_ID}.iam.gserviceaccount.com")" \
    "$(kubectl auth can-i create resourcequotas -n "${SERVICE_NAME}-${env}" --as="gh-deployer-${env}@${PROJECT_ID}.iam.gserviceaccount.com")"
done
kubectl get namespaces | grep "${SERVICE_NAME}"
```

Expect: `yes no` three times (it may deploy, but not change quotas), and five namespaces:
`<name>-dev`, `<name>-dev-db`, `<name>-qa`, `<name>-qa-db`, `<name>-production`.

### 7.5 If you used the wrong service name

✏️ Destructive: deletes the namespaces and everything in them. Do it only while they are empty.

```bash
kubectl delete namespace "${SERVICE_NAME}-dev" "${SERVICE_NAME}-dev-db" \
  "${SERVICE_NAME}-qa" "${SERVICE_NAME}-qa-db" "${SERVICE_NAME}-production"
```

(Use the *old* name for `SERVICE_NAME` in that command.) Then set the new `SERVICE_NAME` and redo 7.1 to 7.4;
the deployer values files in `~/platform-config` do not change. Not managed by OpenTofu: the bootstrap is
rendered and applied by hand.

---

## 8. Secrets

Run from: the template repository root, env file sourced. Goal: the External Secrets Operator (ESO) reads
each environment's secrets from Secret Manager, and an environment can read only its own.

Concepts: **External Secrets Operator** copies values from an external store (here Google Secret Manager)
into Kubernetes Secrets. Each namespace has its own `SecretStore` that uses the namespace's own
`external-secrets` Kubernetes service account as a Google IAM principal, so there is no Google service
account and no key. IAM grants that principal `secretmanager.secretAccessor` under a **conditional IAM**
binding: the grant applies only to secret names that start with a given prefix. A dev `ExternalSecret` that
asks for a production secret is refused by Google.

### 8.1 Install the operator from the pinned chart

✏️ Installs Helm 4 and the chart into `.tools`, then installs the operator into namespace `external-secrets`.

```bash
scripts/tools.sh install helm4 external-secrets-chart
ESO_VERSION="$(awk -F'\t' '$1 == "external-secrets-chart" {print $2}' tools/pins.tsv)"
.tools/bin/helm upgrade --install external-secrets ".tools/opt/external-secrets-chart-${ESO_VERSION}/external-secrets" \
  --server-side=true --force-conflicts \
  --namespace external-secrets --create-namespace \
  -f deploy/external-secrets/external-secrets-values.yaml --wait --timeout 5m
```

Expect: `STATUS: deployed`. The values pin the images by digest and turn the cluster-wide store controller
off. To upgrade later, run the same lines after the pin moves.

🔍 Check.

```bash
.tools/bin/helm -n external-secrets list --output json | jq -r '.[0].chart'
kubectl -n external-secrets get deployments
kubectl get crd secretstores.external-secrets.io externalsecrets.external-secrets.io
```

Expect: `external-secrets-<the pinned version>`; three deployments (`external-secrets`,
`external-secrets-cert-controller`, `external-secrets-webhook`) each `1/1`; both CRDs listed. Not managed by
OpenTofu: the Helm release is installed by hand.

### 8.2 The Secret Manager API and one conditional grant per namespace

✏️ Enable the API and write the grants. `grant` takes the namespace and the secret-name prefix it may read. The principal names a *namespace and service account* in the
project's one Workload Identity pool (`<PROJECT_ID>.svc.id.goog`), which every cluster in the project shares.

```bash
source ~/gke-setup.env
export SERVICE_NAME="your-service-name"
printf 'export SERVICE_NAME="%s"\n' "${SERVICE_NAME}" >> ~/gke-setup.env
gcloud services enable secretmanager.googleapis.com

pool="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${PROJECT_ID}.svc.id.goog"
grant() {
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" --role=roles/secretmanager.secretAccessor \
    --member="principal://iam.googleapis.com/${pool}/subject/ns/${1}/sa/external-secrets" \
    --condition="expression=resource.name.startsWith(\"projects/${PROJECT_NUMBER}/secrets/${2}\"),title=eso-${1}" \
    --format=none
}
for env in dev qa production; do grant "${SERVICE_NAME}-${env}" "${SERVICE_NAME}-${env}-"; done
for env in dev qa; do grant "${SERVICE_NAME}-${env}-db" "${SERVICE_NAME}-${env}-db-password"; done
```

Expect: no JSON output (`--format=none`), though gcloud still prints `Updated IAM policy for project [...]` to
stderr for each grant. The app namespaces read `<service>-<env>-*`; the database namespaces (dev
and qa) read only `<service>-<env>-db-password`. Because the grant names a namespace, a namespace of the same
name in another cluster of the same project gets the same access: keep to one cluster per project for this
design.

🔍 Check: five bindings, each with a title and a condition.

```bash
gcloud projects get-iam-policy "${PROJECT_ID}" --flatten=bindings \
  --filter='bindings.role=roles/secretmanager.secretAccessor' \
  --format='table(bindings.condition.title,bindings.condition.expression)'
```

Expect: `eso-<service>-dev`, `-qa`, `-production`, `-dev-db`, `-qa-db`, each with a `startsWith(...)`
expression and no row without a condition.

Now managed by OpenTofu in `envs/apps` (module `gcp-secrets`: the five conditional bindings, imported). Do
not change by hand. The Secret Manager API itself is one of the nine managed APIs.

### 8.3 A store in each namespace

✏️ The same manifest in all five namespaces: a service account `external-secrets` and a `SecretStore`
`secret-manager`.

```bash
for ns in "${SERVICE_NAME}-dev" "${SERVICE_NAME}-dev-db" "${SERVICE_NAME}-qa" "${SERVICE_NAME}-qa-db" "${SERVICE_NAME}-production"; do
  kubectl apply -n "${ns}" -f deploy/external-secrets/secretstore-secret-manager.yaml
done
```

🔍 Check.

```bash
kubectl get secretstores --all-namespaces
for ns in dev dev-db qa qa-db production; do
  as="gh-deployer-${ns%-db}@${PROJECT_ID}.iam.gserviceaccount.com"
  printf '%s: %s %s\n' "${ns}" \
    "$(kubectl auth can-i create externalsecrets.external-secrets.io -n "${SERVICE_NAME}-${ns}" --as="${as}")" \
    "$(kubectl auth can-i create secretstores.external-secrets.io -n "${SERVICE_NAME}-${ns}" --as="${as}")"
done
```

Expect: `secret-manager` in five namespaces, `STATUS Valid`, `READY True`; and `yes no` five times (the deployer
may create `ExternalSecret`s but never a store). A first run can show the store not ready until the operator's
webhook is up; run the apply again after a minute. A `no` where `yes` is expected means the bootstrap of
section 7 predates the External Secrets rights: rerun it. Not managed by OpenTofu: the stores are applied by
hand.

### 8.4 Create the secrets without showing them 🔐

The value reaches `gcloud` on standard input (`--data-file=-`), so it is never on a command line, in shell
history or on the screen. Passwords are generated with `openssl rand -hex 24` (URL-safe, so they work inside
a database URL). The dev and qa database user name is not secret: it is the chart's `postgresql.auth.user`
(`app` unless you changed it).

✏️ 🔐 Creates seven secrets. `mk` takes the secret name as its argument and reads the value from standard input; it never shows it.

```bash
cd ~/path/to/the/template/repository
source ~/gke-setup.env

mk() {
  gcloud secrets create "${1}" --replication-policy=user-managed \
    --locations="${REGION}" --data-file=- --format=none
}
for env in dev qa; do
  printf '%s' app                    | mk "${SERVICE_NAME}-${env}-db-user"
  openssl rand -hex 24 | tr -d '\n'  | mk "${SERVICE_NAME}-${env}-db-password"
  openssl rand -hex 24 | tr -d '\n'  | mk "${SERVICE_NAME}-${env}-stats-pass"
done
openssl rand -hex 24 | tr -d '\n'    | mk "${SERVICE_NAME}-production-stats-pass"
```

Why `tr -d '\n'` and `printf '%s'`: a trailing newline would become part of the value. Production's `db-user`
and `db-password` come with the managed database (Cloud SQL) and are created when it exists. `user-managed`
replication with `--locations` keeps the secret in one region.

🔍 Check: seven names, no value printed.

```bash
gcloud secrets list --filter="name~/secrets/${SERVICE_NAME}-" --format='value(name.basename())' | sort
```

Not managed by OpenTofu: the *values*. OpenTofu manages only the secret containers (names, replication),
imported; no secret value ever goes through it, and a test in `make test` fails if a
`google_secret_manager_secret_version` appears in the code.

### 8.5 Prove that dev cannot read production 🔐

One `ExternalSecret` in the dev namespace reads a dev secret; another asks for a production secret that
exists (`production-stats-pass`; the guide's `production-db-user` does not exist yet, which would not prove a
permission denial).

✏️ Creates two `ExternalSecret`s, then deletes them. `probe` takes the name and the remote key as arguments.

```bash
probe() {
kubectl -n "${SERVICE_NAME}-dev" apply -f - <<EOF
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: ${1}
spec:
  secretStoreRef: {name: secret-manager, kind: SecretStore}
  refreshInterval: 1h
  target: {name: ${1}}
  data:
    - secretKey: value
      remoteRef: {key: ${2}}
EOF
}
probe probe-own "${SERVICE_NAME}-dev-db-user"
probe probe-production "${SERVICE_NAME}-production-stats-pass"

kubectl -n "${SERVICE_NAME}-dev" wait externalsecret/probe-own --for=condition=Ready --timeout=60s
kubectl -n "${SERVICE_NAME}-dev" wait externalsecret/probe-production --for=condition=Ready=false --timeout=60s
kubectl -n "${SERVICE_NAME}-dev" get externalsecrets probe-own probe-production
kubectl -n external-secrets logs deployment/external-secrets --tail=500 \
  | grep '"name":"probe-production"' | grep -m1 -o 'PermissionDenied'

kubectl -n "${SERVICE_NAME}-dev" delete externalsecret probe-own probe-production
```

Expect: `probe-own` shows `SecretSynced`, `READY True`; `probe-production` shows `SecretSyncedError`,
`READY False`, and the operator log prints `PermissionDenied` (the event itself only says the data could not
be read). The `delete` removes both and the Secret that `probe-own` made. If `probe-production` synced, a
binding of 8.2 has no condition or a wrong one: fix it before any deploy.

After the first deploy: `kubectl get externalsecrets --all-namespaces` must show `SecretSynced`, `READY True`
for every one. `SecretSyncedError` there means a secret does not exist yet (8.4) or a namespace lacks its
binding (8.2): `kubectl -n <ns> describe externalsecret <name>` names it.

### 8.6 The Cloudflare tunnel token (`cloudflared` namespace)

The container `cloudflared-tunnel-token` and the one conditional `secretAccessor` grant for the `external-secrets`
service account of namespace `cloudflared` (title `eso-cloudflared`, limited to that secret) are managed by
OpenTofu in `envs/apps` (module `gcp-platform-secret`). Do not create or change them by hand: that would show
as drift. The value never goes through OpenTofu.

1. Plan with your usual variables file. Expect `Plan: 2 to add, 0 to change, 0 to destroy.` (the secret and
   the grant, nothing else).
2. Apply that saved plan.
3. Plan again. Expect `No changes.`
4. Later, after creating the tunnel in Cloudflare, add the token without echoing it:

`PROJECT_ID` comes from the env file: run `source ~/gke-setup.env` first.

```
read -rs TOKEN
printf '%s' "${TOKEN}" | gcloud secrets versions add cloudflared-tunnel-token --project "${PROJECT_ID}" --data-file=-
unset TOKEN
```

5. Rotation: add a new version the same way, then restart the connector:

```
kubectl -n cloudflared rollout restart deployment/cloudflared
```

The output `CLOUDFLARED_TUNNEL_TOKEN_SECRET_ID` gives the secret id for the guide.

---

## 9. GitHub repository settings and the release App

Run from: the template repository root (the repository's own settings), `gh` logged in as an admin.
Goal: rulesets, environments, variables and the Actions policy set as code, plus the release GitHub App and
its key, then the first green `check` from GitHub.

### 9.1 The vars-file

The settings script sets repository and environment variables from a file kept **outside** the repository
(it refuses a path under the repo root). The guide's table (`wiki/platform-setup.md`, Variables and
secrets) is the single list of names.

✏️ (writes a file of identifiers, not secrets, in the private folder; mode `600`). `RELEASE_APP_ID` is a placeholder until 9.3.

```bash
source ~/gke-setup.env
WIF="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github/providers/github-oidc"
cat > ~/platform-config/github-vars.env <<EOF
# Repository variables
GCP_PROJECT_ID=${PROJECT_ID}
GKE_CLUSTER=${CLUSTER}
GKE_LOCATION=${ZONE}
SERVICE_NAME=${SERVICE_NAME}
RELEASE_APP_ID=<APP_ID>
# Environment variables (the same provider, a different deployer each)
ENV_dev_GCP_WIF_PROVIDER=${WIF}
ENV_qa_GCP_WIF_PROVIDER=${WIF}
ENV_production_GCP_WIF_PROVIDER=${WIF}
ENV_dev_GCP_DEPLOYER_SA=gh-deployer-dev@${PROJECT_ID}.iam.gserviceaccount.com
ENV_qa_GCP_DEPLOYER_SA=gh-deployer-qa@${PROJECT_ID}.iam.gserviceaccount.com
ENV_production_GCP_DEPLOYER_SA=gh-deployer-production@${PROJECT_ID}.iam.gserviceaccount.com
# Script input, never sent as a variable: the production reviewer (you)
REVIEWER_USER_ID=${GH_OWNER_ID}
EOF
chmod 600 ~/platform-config/github-vars.env
cat ~/platform-config/github-vars.env
```

Expect: the file printed with your values; replace `<APP_ID>` with the number once you have the App (9.3).
`DEPLOY_ENABLED` is left unset on purpose: deploys stay off until the platform rollout. Variables only
carry names and IDs, never a secret.

### 9.2 Dry run

🔍 ✏️ (writes the dry-run output to a local file) Prints (and with `--diff` also reads, so it says create versus update) every call it would make. Changes
nothing. `--template` is only for the upstream template repository (it marks the repository as a template);
leave it out for an adopter's copy.

```bash
cd ~/path/to/the/template/repository
scripts/github-settings.sh --repo "${GH_REPO}" --vars-file ~/platform-config/github-vars.env \
  --template --diff > ~/platform-config/settings-dryrun.txt 2>&1; echo "exit=$?"
```

Expect: `exit=0`, and `~/platform-config/settings-dryrun.txt` is about 80 lines. Read it. Check the line
`CI OK: pinned app id N; resolved <app> (id M)` (N and M must agree). The run exit codes: `0` done, `1` error,
`3` done with some settings skipped by the plan (the summary lists them). Re-running the dry run is safe; run it again after every edit of the vars-file.

### 9.3 Create the release GitHub App, and install it on the repository

By hand in the browser. Open **Settings → Developer settings → GitHub Apps → New GitHub App** and set:
repository permissions Contents (read and write), Pull requests (read and write), Issues (read and write),
Metadata (read), nothing else; webhooks off; a name of your choice. Save it. Put the **App ID** (shown on the
App's page) into `RELEASE_APP_ID` in the vars-file.

Then **install it on this repository only**: on the App's page choose **Install App**, pick your account and
select only this repository. Do this **before** `--apply`: the `release-tags` ruleset names the App as its one
actor, and GitHub refuses the ruleset with `HTTP 422 Actor ... integration must be part of the ruleset source
or owner organization` while the App is not installed. A first `--apply` failed exactly this way after
creating the `main` ruleset and stopped before the environments and variables. The fix is to install the App
and rerun; the script updates in place, so the rerun is safe.

### 9.4 Apply

✏️ Creates and updates rulesets, environments, variables, labels, the Actions policy and security settings.
It saves what it overwrites to a timestamped folder first and prints the path.

```bash
scripts/github-settings.sh --repo "${GH_REPO}" --vars-file ~/platform-config/github-vars.env \
  --template --apply; echo "exit=$?"
```

Expect: `exit=0` (or `3` with a printed list of skips on a private repository). After it, `main` takes pull
requests only (squash merges, `CI OK` green, no bypass), and `v*` tags only from the App.

🔍 Verify.

```bash
gh api "repos/${GH_REPO}/environments" --jq '.environments[].name'
gh api "repos/${GH_REPO}/rulesets" --jq '.[] | "\(.name) \(.target) \(.enforcement)"'
gh variable list --repo "${GH_REPO}"
for e in dev qa production; do printf '== %s\n' "${e}"; gh variable list --env "${e}" --repo "${GH_REPO}"; done
gh secret list --env release --repo "${GH_REPO}"
```

Expect: environments `dev`, `qa`, `production`, `release`, `github-pages`; rulesets `main` and `release-tags`,
both `active`; five repository variables; two variables in each deploy environment; and the secret list for
`release` empty until 9.5.

### 9.5 The App's private key 🔐

Generate it on the App's page, in the **Private keys** section (**Credentials → Key pairs**; that location
wording is added for completeness, not from the session): choose
**Generate a private key**. The browser downloads a `.pem` file. The script never sets secrets; store it
yourself, reading from the file so it never appears on screen, and then delete the local copy (a new key can be
generated any time).

✏️ 🔐 The `rm` runs only if the upload succeeded (`&&`), so a failed upload keeps the key and you can retry.

```bash
ls ~/Downloads/*.pem
gh secret set RELEASE_APP_PRIVATE_KEY --env release --repo "${GH_REPO}" < ~/Downloads/<the-file>.private-key.pem \
  && rm -f ~/Downloads/<the-file>.private-key.pem
gh secret list --env release --repo "${GH_REPO}"
```

Expect: the `ls` shows exactly the file you mean (the real file ended in `.private-key.pem`); the secret list
then shows `RELEASE_APP_PRIVATE_KEY` with an update time. If `gh secret set` fails, the file is still there:
fix the cause below and run it again. **Pitfalls hit here:**

- `<the-file>` is a placeholder. Typing it literally, or leaving it, gives "No such file". Replace it with the
  real name printed by `ls`.
- `ls` says "No such file" (the key was never generated, or was saved elsewhere). Search with
  `ls ~/Downloads/*.pem` and look in the browser's download list. Generate a key if there is none.
- A shell glob in a redirect (`< ~/Downloads/name.*.pem`): in bash it fails when it matches nothing or more than
  one file ("ambiguous redirect"); in zsh (with `MULTIOS`, the default) a glob that matches two files
  concatenates both into the input, so you could upload two keys joined together. Use the full exact name.
- `gh secret set` reports "Not Found" when `GH_REPO` does not name the real repository (a hyphen versus an
  underscore). `printf '%s\n' "${GH_REPO}"` first; the owner's env file had the template default, and the
  repository name had to be corrected there (and the command given the explicit repository once).

### 9.6 The first check from GitHub: `deploy-ops` `check`

The `check` operation logs in through WIF, gets the cluster credentials through the DNS endpoint, runs
`kubectl version` and `kubectl auth can-i --list` in the namespace. It is read-only. It runs only for a
workflow file that is on the default branch.

✏️ (starts a workflow run; changes nothing in the cluster)

```bash
for e in dev qa; do
  gh workflow run deploy-ops.yml --repo "${GH_REPO}" --ref main -f environment="${e}" -f operation=check
done
sleep 5; gh run list --repo "${GH_REPO}" --workflow deploy-ops.yml --limit 2
```

🔍 Follow the latest run, or open a finished one.

```bash
gh run watch --repo "${GH_REPO}" "$(gh run list --repo "${GH_REPO}" --workflow deploy-ops.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
gh run view <run-id> --repo "${GH_REPO}"
```

Expect: green runs whose log shows a server version and a short `can-i --list` for the namespace (the
deployer's Helm verbs). `production` runs only from a `v*` tag (its branch policy refuses `main`), so its
first check waits for the first tag. If a run fails with `getAccessToken denied`, see 14: three separate
causes, all met here (the immutable subject, the zsh-mangled member and the propagation wait), and the fix
in 6.7. Never set `DEPLOY_ENABLED=true` before a successful check of that environment.

Not managed by OpenTofu: GitHub settings stay in `scripts/github-settings.sh`.

---

## 10. Read-only live-config export

Run from: anywhere, env file sourced. Goal: a private snapshot of the hand-built setup, the input for writing
and checking the OpenTofu code. Every command only reads; the files hold IDs, so the folder is private.

🔍 ✏️ (writes files in `~/platform-config/live`, mode `600`)

```bash
source ~/gke-setup.env
D="${HOME}/platform-config/live"; mkdir -p "${D}" && chmod 700 "${D}"

gcloud container clusters describe "${CLUSTER}" --location="${ZONE}" --format=yaml > "${D}/cluster.yaml"
gcloud container node-pools describe default-pool --cluster="${CLUSTER}" --location="${ZONE}" --format=yaml > "${D}/node-pool.yaml"
gcloud compute networks describe "${NETWORK}" --format=yaml > "${D}/network.yaml"
gcloud compute networks subnets describe "${SUBNET}" --region="${REGION}" --format=yaml > "${D}/subnet.yaml"
gcloud compute routers describe apps-router --region="${REGION}" --format=yaml > "${D}/router.yaml"
gcloud iam workload-identity-pools providers describe github-oidc --location=global \
  --workload-identity-pool=github --format=yaml > "${D}/wif-provider.yaml"
gcloud secrets describe "${SERVICE_NAME}-dev-db-user" --format=yaml > "${D}/secret-sample.yaml"

BILLING_ACCOUNT="$(gcloud billing projects describe "${PROJECT_ID}" --format='value(billingAccountName)' | cut -d/ -f2)"
gcloud billing budgets list --billing-account="${BILLING_ACCOUNT}" --format=yaml > "${D}/budget.yaml"

chmod 600 "${D}"/*.yaml && ls -l "${D}"
```

Expect: eight files, each `-rw-------`. The secret export is metadata only (name, replication, labels), never a
value. Run the whole block: a paste that leaves out the first lines leaves `D` undefined, and the
`> "${D}/..."` redirects then fail. The budget file is also where section 11 reads the budget's ID.

---

## 11. OpenTofu: state, import, apply

Run from: this repository's root. Needs: ADC and the quota project (2.5), the tools (1.2), and the live export
(section 10). Every command here is run by hand; CI never holds credentials and never applies.

Concepts:

- **State** is OpenTofu's record of which real resource each block of code owns. It is a file; whoever
  holds it holds sensitive data.
- **Remote state** here is a versioned GCS bucket. **State encryption** (`gcp_kms` key provider plus the
  `aes_gcm` method) encrypts the state and the plan files with a Cloud KMS key *before* they are written, so
  even a reader of the bucket sees only `encrypted_data`.
- The **bootstrap root** creates that bucket and key. It starts with local state (nothing to store the state
  in yet), then migrates it into the bucket it created.
- The **fallback** (`unencrypted` method) lets the first migration read the old plain state. It is removed in
  the final form, which also sets `enforced = true`, so OpenTofu refuses to read or write plain state.
- **`import` blocks** (`envs/apps/imports.tf`) tell OpenTofu "this existing resource is that block". A plan
  with imports changes nothing in the cloud; applying the plan only writes state.
- **Saved plans** (`-out=file`) are reviewed, then applied by name, so what runs is exactly what you read.
- **Drift** is any difference between the code, the state and the real resource. `tofu plan` showing
  `No changes` after the import is the proof there is none.

### 11.1 Prepare the budget values and the bootstrap variables

🔍 ✏️ (writes the git-ignored `bootstrap/terraform.tfvars`)

```bash
make tools
export PATH="${PWD}/.tools/bin:${PATH}"
tofu version

source ~/gke-setup.env
printf 'project=%s region=%s zone=%s\n' "${PROJECT_ID}" "${REGION}" "${ZONE}"

grep -c '^name:' ~/platform-config/live/budget.yaml
BUDGET_NAME="$(sed -n 's/^name: //p' ~/platform-config/live/budget.yaml)"
BILLING_ACCOUNT="$(printf '%s' "${BUDGET_NAME}" | cut -d/ -f2)"
BUDGET_ID="$(printf '%s' "${BUDGET_NAME}" | cut -d/ -f4)"
BUDGET_DISPLAY_NAME="$(sed -n 's/^displayName: //p' ~/platform-config/live/budget.yaml | sed "s/^['\"]//; s/['\"]\$//")"
printf 'account=%s id=%s name=%s\n' "${BILLING_ACCOUNT}" "${BUDGET_ID}" "${BUDGET_DISPLAY_NAME}"

cat > bootstrap/terraform.tfvars <<EOF
project_id        = "${PROJECT_ID}"
state_bucket_name = "${PROJECT_ID}-tofu-state"
EOF
```

Expect: `1` from the `grep -c` (the parsing below assumes exactly one budget on the billing account; with
more, trim the export to the right one first), then all three budget values print non-empty (`name` has the form
`billingAccounts/<account>/budgets/<id>`). The bucket name must be globally unique; if the apply later says it
is taken, choose another in `bootstrap/terraform.tfvars`, plan again and apply the new plan. Never commit a `*.tfvars` file.

### 11.2 Plan and apply the bootstrap (local state)

✏️ `init` downloads providers; `plan -out` writes the saved plan (no change); `apply` creates the key ring,
key, bucket and three APIs.

```bash
tofu -chdir=bootstrap init
tofu -chdir=bootstrap plan -out=bootstrap.tfplan
```

Expect: `Plan: 6 to add, 0 to change, 0 to destroy.` (the APIs `cloudkms`, `storage`, `serviceusage`; key ring,
key, bucket). Read it, then apply exactly that plan:

✏️

```bash
tofu -chdir=bootstrap apply bootstrap.tfplan
rm -f bootstrap/bootstrap.tfplan
```

Pitfall: the plan file is in `bootstrap/`. `tofu apply "bootstrap.tfplan"` from the repository root, without
`-chdir=bootstrap`, fails to find it. A second apply of a deleted plan file also fails; plan again. If the
apply reports `SERVICE_DISABLED` for Cloud KMS right after the API was enabled, wait a minute, plan
again into a new file and apply that file: the saved plan was deleted, and is stale after a partial apply. The key ring, key and bucket have `prevent_destroy`: key rings can never be deleted in Cloud KMS.

### 11.3 Migrate the bootstrap's own state into the bucket, encrypted

✏️ Read the bucket and key, write the migration form of `bootstrap/override.tf` (git-ignored), and migrate.
`override.tf` has the backend and the encryption block, with the plain fallback.

```bash
BUCKET="$(tofu -chdir=bootstrap output -raw state_bucket)"
KEY="$(tofu -chdir=bootstrap output -raw kms_key_id)"
printf 'bucket=%s\nkey=%s\n' "${BUCKET}" "${KEY}"

cat > bootstrap/override.tf <<EOF
terraform {
  backend "gcs" {
    bucket = "${BUCKET}"
    prefix = "bootstrap"
  }

  encryption {
    key_provider "gcp_kms" "state" {
      kms_encryption_key = "${KEY}"
      key_length         = 32
    }

    method "aes_gcm" "state" {
      keys = key_provider.gcp_kms.state
    }

    method "unencrypted" "migrate" {}

    state {
      method = method.aes_gcm.state
      fallback {
        method = method.unencrypted.migrate
      }
    }

    plan {
      method = method.aes_gcm.state
      fallback {
        method = method.unencrypted.migrate
      }
    }
  }
}
EOF
tofu -chdir=bootstrap init -migrate-state
```

Answer `yes` to copying the state to the new backend.

🔍 Proof 1: the object in the bucket is encrypted.

```bash
gcloud storage cat "gs://${BUCKET}/bootstrap/default.tfstate" --project "${PROJECT_ID}" | grep -c encrypted_data
gcloud storage cat "gs://${BUCKET}/bootstrap/default.tfstate" --project "${PROJECT_ID}" | grep -c '"resources"'
```

Expect: a count of `1` or more for `encrypted_data`, and `0` for `"resources"`. If it is plain JSON, keep the
fallback, run `tofu -chdir=bootstrap apply` (expect `No changes`; it saves the state again with the new
method) and check again.

✏️ Write the final form: no fallback, no `unencrypted` method, encryption enforced.

```bash
cat > bootstrap/override.tf <<EOF
terraform {
  backend "gcs" {
    bucket = "${BUCKET}"
    prefix = "bootstrap"
  }

  encryption {
    key_provider "gcp_kms" "state" {
      kms_encryption_key = "${KEY}"
      key_length         = 32
    }

    method "aes_gcm" "state" {
      keys = key_provider.gcp_kms.state
    }

    state {
      method   = method.aes_gcm.state
      enforced = true
    }

    plan {
      method   = method.aes_gcm.state
      enforced = true
    }
  }
}
EOF
tofu -chdir=bootstrap plan
```

🔍 Proof 2: expect `No changes`. Without the fallback OpenTofu refuses plain state, so this also proves the
state is encrypted. Only then delete the old local copies, and back up the only record of the backend:

✏️

```bash
rm -f bootstrap/terraform.tfstate bootstrap/terraform.tfstate.backup
cp bootstrap/override.tf ~/platform-config/bootstrap-override.tf
chmod 600 ~/platform-config/bootstrap-override.tf
ls -la bootstrap/ | grep -E 'tfstate|override'
```

Expect: only `override.tf` is listed (no `tfstate`). Why the backup: `override.tf` is git-ignored and holds the bucket
name; if it is lost, the state in the bucket cannot be found again by the code.

### 11.4 The import plan

✏️ Writes the git-ignored `envs/apps/terraform.tfvars`, initialises, and writes the saved import plan (no
change in the cloud).

```bash
tofu -chdir=bootstrap plan

STATE_BUCKET="${BUCKET}"
STATE_KMS_KEY_ID="${KEY}"

cat > envs/apps/terraform.tfvars <<EOF
project_id          = "${PROJECT_ID}"
project_number      = "${PROJECT_NUMBER}"
region              = "${REGION}"
zone                = "${ZONE}"
github_repository   = "${GH_REPO}"
github_owner_id     = "${GH_OWNER_ID}"
github_repo_id      = "${GH_REPO_ID}"
sub_claim_prefix    = "${SUB_PREFIX}"
billing_account     = "${BILLING_ACCOUNT}"
budget_display_name = "${BUDGET_DISPLAY_NAME}"
budget_id           = "${BUDGET_ID}"
state_bucket        = "${STATE_BUCKET}"
state_kms_key_id    = "${STATE_KMS_KEY_ID}"
EOF
grep -c '""' envs/apps/terraform.tfvars
git status --porcelain envs/apps

tofu -chdir=envs/apps init
tofu -chdir=envs/apps plan -out=import.tfplan
```

Expect: `No changes` for the bootstrap plan; `0` from the `grep` (no empty value); nothing from `git status`
(the tfvars file is ignored); then a plan ending in
`Plan: 41 to import, 0 to add, N to change, 0 to destroy.` with at most 10 in-place updates. The owner's
actual run said `41 to import, 0 to add, 1 to change, 0 to destroy`: only the cluster's state-only labels
changed, and the APIs showed no change.

**Pitfall: Service Usage 403.** If the plan ends in errors with
`403 ... serviceusage.googleapis.com ... SERVICE_DISABLED`, the Service Usage API is not enabled in the
project (or has not propagated yet). The root bills its requests to the project (`user_project_override`),
so the nine `google_project_service` reads fail without it. The current bootstrap already enables it (it is
among the 6 additions of 11.2), so today this means the bootstrap apply was skipped or has not propagated: wait
2 to 3 minutes. The owner's first plan failed this way because his bootstrap had been applied *before* that API
was added to it. A plan that ends in errors must never be applied: delete it. Only for a bootstrap applied
before the fix, add the API through the bootstrap root and plan again:

✏️

```bash
rm -f envs/apps/import.tfplan
tofu -chdir=bootstrap plan -out=bootstrap.tfplan
tofu -chdir=bootstrap show -no-color bootstrap.tfplan | grep -E '# .* will be|^Plan:'
```

Expect (for that older bootstrap only): exactly one addition,
`google_project_service.apis["serviceusage.googleapis.com"]`, `Plan: 1 to add`.
Apply that saved plan, delete it, and wait for the API to propagate before planning `envs/apps` again:

✏️

```bash
tofu -chdir=bootstrap apply bootstrap.tfplan
rm -f bootstrap/bootstrap.tfplan

sleep 180
gcloud services list --enabled --project "${PROJECT_ID}" --filter='config.name=serviceusage.googleapis.com' --format='value(config.name)'
```

Expect: `serviceusage.googleapis.com`. If the apply of a saved plan finds no file (it was deleted after an earlier apply), or the API is not yet
visible, plan again into a new file.

### 11.5 Two mechanical checks on the saved plan

✏️ (writes a saved plan file locally; nothing in the cloud) 🔍 Both checks must pass before any apply. The
first must match only the summary line.

```bash
tofu -chdir=envs/apps plan -out=import.tfplan
tofu -chdir=envs/apps show -no-color import.tfplan | grep -nE 'must be replaced|-/\+|will be destroyed|to destroy'
tofu -chdir=envs/apps show -no-color import.tfplan | grep -nE '^ *[-+~] |will be updated in-place'
```

Expect, check 1: one line only, the summary `... 0 to destroy.` A line saying `must be replaced`, `-/+`
or `will be destroyed` is a **hard stop**: do not apply; paste the plan to someone who can read it.

Expect, check 2, and nothing else: the legend line `~ update in-place`; at most 10 `will be updated in-place`
headers (9 `google_project_service` and 1 `google_container_cluster`); under each API that appears a
`~ disable_dependent_services` and a `~ disable_on_destroy` line; under the cluster a
`~ resource_labels = {` and a `~ terraform_labels = {` line, each followed by `+ "cluster" = "apps"`. These
are provider-side or state-only fields; applying them does not change Google Cloud. In the owner's run only the
cluster line appeared (`1 to change`) and the APIs showed no change.

The summary also lists what is imported: 9 APIs, 4 network, 2 node service account, 11 Workload Identity, 5
conditional secret accessors, 7 secrets, 1 budget, 2 cluster and pool: 41 in all. Any other changed
attribute (for example a node pool `kubelet_config`) is a stop.

### 11.6 Apply the import, then prove "No changes"

✏️ Writes state only. Nothing is created or deleted in Google Cloud.

```bash
tofu -chdir=envs/apps apply import.tfplan
tofu -chdir=envs/apps plan
```

Expect: `Apply complete! Resources: 41 imported, 0 added, N changed, 0 destroyed.` (N was 1 in the owner's run) and then
`No changes. Your infrastructure matches the configuration.` Anything else: stop.

✏️ Delete the plan file.

```bash
rm -f envs/apps/import.tfplan
```

### 11.7 Three live checks

🔍 The cluster is still healthy.

```bash
gcloud container clusters describe "${CLUSTER}" --zone "${ZONE}" --project "${PROJECT_ID}" \
  --format='yaml(status,releaseChannel.channel,controlPlaneEndpointsConfig.dnsEndpointConfig.allowExternalTraffic,privateClusterConfig.enablePrivateNodes)'
```

Expect: `status: RUNNING`, channel `STABLE`, external traffic allowed on the DNS endpoint, private nodes on.

🔍 The provider's condition still pins your IDs and the workflow file.

```bash
actual="$(gcloud iam workload-identity-pools providers describe github-oidc \
  --project "${PROJECT_ID}" --location=global --workload-identity-pool=github --format='value(attributeCondition)')"
[[ "${actual}" == *"repository_owner_id=='${GH_OWNER_ID}'"* && "${actual}" == *"repository_id=='${GH_REPO_ID}'"* && "${actual}" == *"deploy-ops"* ]] \
  && printf 'condition matches\n' || printf 'DIFFERENT: compare by eye\n'
```

🔍 Each deployer can be impersonated only by its own environment.

```bash
for env in dev qa production; do
  printf '%s: ' "${env}"
  gcloud iam service-accounts get-iam-policy "gh-deployer-${env}@${PROJECT_ID}.iam.gserviceaccount.com" \
    --project "${PROJECT_ID}" --format='value(bindings.members)'
done
```

Expect: each line ends with `/subject/<SUB_PREFIX>:environment:<env>` for its own environment and has no other
member.

### 11.8 Rollback of the import

Nothing in Google Cloud changed, so to undo, remove the resources from state (`state rm` never deletes
anything in the cloud) and start again at 11.4:

✏️ (state only)

```bash
tofu -chdir=envs/apps state list
for m in project network node_sa github_wif secrets budget gke; do
  tofu -chdir=envs/apps state rm "module.${m}"
done
```

The outputs (`GCP_PROJECT_ID`, `GKE_CLUSTER`, `GKE_LOCATION`, `GCP_WIF_PROVIDER`, `GCP_DEPLOYER_SA`,
`dns_endpoint`) are the GitHub variables of 9.1; read them with `tofu -chdir=envs/apps output`.

**From here on, the resources of sections 2 to 6, 8.2 and the secret containers of 8.4 are managed by OpenTofu in `envs/apps`: change the
code and plan; do not change them by hand.** A manual change shows up as drift in the next `plan`.

---

## 12. OpenTofu: GKE hardening

Run from: this repository's root, in the terminal of section 11 (or re-source the env file and set the `PATH`).
Goal: the first change to live resources after the import, all in place: Secrets encrypted with a Cloud KMS
key, new RBAC bindings to the all-users groups (`system:authenticated`, `system:unauthenticated`) refused, VPC flow logs, and Data Access audit logs for the container
API. The detail and the acceptance rules are in [`hardening-runbook.md`](hardening-runbook.md); this is the
command sequence as it was run.

### 12.1 Plan, and the two checks

✏️ (writes a saved plan; changes nothing in the cloud)

```bash
export PATH="${PWD}/.tools/bin:${PATH}"
source ~/gke-setup.env
tofu -chdir=envs/apps init
tofu -chdir=envs/apps plan -out=hardening.tfplan
```

🔍

```bash
tofu -chdir=envs/apps show -no-color hardening.tfplan | grep -nE 'must be replaced|-/\+|will be destroyed|to destroy'
tofu -chdir=envs/apps show -no-color hardening.tfplan | grep -nE '^ *[-~] |will be |^ *\+ (log_config|key_name)'
```

Expect: `Plan: 4 to add, 2 to change, 0 to destroy.` The 4 additions are the KMS key ring, the key, the
key's grant to GKE's service agent, and the project's container audit config. The 2 in-place changes are the
cluster (`database_encryption` `DECRYPTED` to `ENCRYPTED` with a known key name, and the two
`rbac_binding_config` switches `true` to `false`) and the subnet (a `log_config` block added). The first check
may match only the summary; anything else is a hard stop. No line may start with `-`.

### 12.2 Apply, then plan again

Before applying: enabling Secrets encryption **restarts the cluster control plane**. On a zonal cluster the
control plane is unavailable meanwhile: running Pods keep serving, but `kubectl`, CI deploys, External Secrets
syncs and the autoscaler pause until it is back (an estimate: 10 to 30 minutes, not a promise). Pick a quiet
window and start no deploys.

✏️ Changes the live cluster, subnet and project IAM.

```bash
tofu -chdir=envs/apps apply hardening.tfplan
tofu -chdir=envs/apps plan
```

Expect: `Apply complete! Resources: 4 added, 2 changed, 0 destroyed.` then `No changes.`

If the apply fails after the four creations (for example while the new KMS grant propagates), the saved plan
is stale. Delete it, wait, and plan into a new file. Review with 12.1 (now `0 to add, 2 to change, 0 to
destroy` with the same two changes) and apply that file:

✏️

```bash
rm -f envs/apps/hardening.tfplan
sleep 180
tofu -chdir=envs/apps plan -out=hardening.tfplan
```

### 12.3 Verify against the live setup

🔍

```bash
gcloud container clusters describe "${CLUSTER}" --zone "${ZONE}" --project "${PROJECT_ID}" \
  --format='yaml(databaseEncryption,rbacBindingConfig,securityPostureConfig)'
gcloud compute networks subnets describe apps-subnet --region "${REGION}" --project "${PROJECT_ID}" --format='yaml(logConfig)'
gcloud projects get-iam-policy "${PROJECT_ID}" --format=json \
  | python3 -c 'import json,sys; [print(c["service"], sorted(l["logType"] for l in c["auditLogConfigs"])) for c in json.load(sys.stdin).get("auditConfigs", []) if c["service"] == "container.googleapis.com"]'
{ kubectl get clusterrolebindings -o json; kubectl get rolebindings -A -o json; } \
  | jq -r '.items[] | select(any(.subjects[]?; .name == "system:authenticated" or .name == "system:unauthenticated" or .name == "system:anonymous")) | "\(.kind) \(.metadata.namespace // "-") \(.metadata.name)"'
```

Expect: `databaseEncryption.state: ENCRYPTED`, both RBAC switches `false`, posture `BASIC`; flow logs enabled
(10-minute interval, sampling 0.1); `container.googleapis.com ['ADMIN_READ', 'DATA_WRITE']`; and only the
three built-in bindings `system:basic-user`, `system:discovery`, `system:public-info-viewer`. The RBAC switches
block only *new* bindings; they do not remove existing ones, which is why the last command lists them.

✏️ Clean up.

```bash
rm -f envs/apps/hardening.tfplan
```

Rollback and the one allowed destroy (the audit config) are in the hardening runbook. Never destroy the KMS
key or ring (`prevent_destroy`).

### 12.4 The CI identity (L1.7), as run on 2026-11-27

Run from: this repository's root, in the terminal of section 11. Goal: a read-only, keyless identity so that pull
requests show a plan summary and a weekly run plans `main` against the live project. The reasons, the limits of
the identity and the rollback are in [`ci-identity-runbook.md`](ci-identity-runbook.md); this is the command
sequence as it was run.

**Cloud Billing pre-check.** The identity reads the billing account, and the provider bills such calls to the
project (`user_project_override`), so the Cloud Billing API must be on in the project. The `ci_planner` module
enables it (`google_project_service.cloudbilling`); the first plan of the identity failed with `SERVICE_DISABLED`
before that resource existed. Enabling an enabled API succeeds, so the pre-check only tells you what to expect.

🔍

```bash
source ~/gke-setup.env
gcloud services list --enabled --project "${PROJECT_ID}" --filter='config.name=cloudbilling.googleapis.com' --format='value(config.name)'
```

Expect: empty output (the plan enables it), or the name when it is already on. Both are fine.

**The IDs and the immutable prefix.**

🔍

```bash
unset GH_REPO
export LODESTAR_REPO="${GH_OWNER}/lodestar-infra"
export LODESTAR_REPO_ID="$(gh api "repos/${LODESTAR_REPO}" --jq .id)"
export LODESTAR_SUB_PREFIX="$(gh api "repos/${LODESTAR_REPO}/actions/oidc/customization/sub" --jq '.sub_claim_prefix // empty')"
printf '%s\n' "${LODESTAR_REPO_ID}" "${LODESTAR_SUB_PREFIX}"
```

Expect: a number, then `repo:<owner>@<number>/lodestar-infra@<number>`. If the second line is empty, build the
immutable form from the IDs as the CI identity runbook (step 1) shows.

**The tfvars lines, appended once.**

✏️ Local files only.

```bash
grep -q '^ci_github_repository ' envs/apps/terraform.tfvars || printf 'ci_github_repository = "%s"\n' "${LODESTAR_REPO}" >> envs/apps/terraform.tfvars
grep -q '^ci_github_repo_id ' envs/apps/terraform.tfvars || printf 'ci_github_repo_id    = "%s"\n' "${LODESTAR_REPO_ID}" >> envs/apps/terraform.tfvars
grep -q '^ci_sub_claim_prefix ' envs/apps/terraform.tfvars || printf 'ci_sub_claim_prefix  = "%s"\n' "${LODESTAR_SUB_PREFIX}" >> envs/apps/terraform.tfvars
tofu fmt envs/apps/terraform.tfvars
```

Expect: `tofu fmt` prints the file name only when it changed it. A block run twice without the `grep -q` guards
appends every key twice, and the next plan stops with `Attribute redefined`. To repair such a file, keep the
first occurrence of each key:

✏️ Local files only.

```bash
awk -F' *= *' 'NF < 2 || !seen[$1]++' envs/apps/terraform.tfvars > envs/apps/terraform.tfvars.new
mv envs/apps/terraform.tfvars.new envs/apps/terraform.tfvars
tofu fmt envs/apps/terraform.tfvars
```

Expect: no output from the `awk` and `mv` lines; each key once (`grep -c '^ci_' envs/apps/terraform.tfvars` prints 3).

**Plan, apply, "No changes".**

✏️ (writes a saved plan; changes nothing in the cloud)

```bash
tofu -chdir=envs/apps init
tofu -chdir=envs/apps plan -out=ci-identity.tfplan
```

Expect: `Plan: 12 to add, 0 to change, 0 to destroy.` The 12 adds are listed, with the two mechanical checks, in the CI
identity runbook (step 4). Anything else is a hard stop.

✏️ Changes the live project, its IAM and the billing account's IAM.

```bash
tofu -chdir=envs/apps apply ci-identity.tfplan
rm -f envs/apps/ci-identity.tfplan
tofu -chdir=envs/apps plan
```

Expect: `Apply complete! Resources: 12 added, 0 changed, 0 destroyed.` then `No changes.`

**The 16 secrets and the 2 variables.**

🔐 Each value goes from OpenTofu's output or `terraform.tfvars` straight into `gh`; nothing is printed.

```bash
printf '%s' "$(tofu -chdir=envs/apps output -raw CI_WIF_PROVIDER)" | gh secret set GCP_CI_WIF_PROVIDER --repo "${LODESTAR_REPO}"
printf '%s' "$(tofu -chdir=envs/apps output -raw CI_SERVICE_ACCOUNT)" | gh secret set GCP_CI_SA --repo "${LODESTAR_REPO}"
set_secret() {
  sed -n "s/^${2} *= *\"\(.*\)\"\$/\1/p" envs/apps/terraform.tfvars | head -n 1 | tr -d '\n' | gh secret set "${1}" --repo "${LODESTAR_REPO}"
}
set_secret TF_PROJECT_ID project_id
set_secret TF_PROJECT_NUMBER project_number
set_secret TF_BILLING_ACCOUNT billing_account
set_secret TF_BUDGET_ID budget_id
set_secret TF_BUDGET_DISPLAY_NAME budget_display_name
set_secret TF_GITHUB_REPOSITORY github_repository
set_secret TF_GITHUB_OWNER_ID github_owner_id
set_secret TF_GITHUB_REPO_ID github_repo_id
set_secret TF_SUB_CLAIM_PREFIX sub_claim_prefix
set_secret TF_CI_GITHUB_REPOSITORY ci_github_repository
set_secret TF_CI_GITHUB_REPO_ID ci_github_repo_id
set_secret TF_CI_SUB_CLAIM_PREFIX ci_sub_claim_prefix
set_secret TF_STATE_BUCKET state_bucket
set_secret TF_STATE_KMS_KEY_ID state_kms_key_id
gh variable set TF_REGION --body "${REGION}" --repo "${LODESTAR_REPO}"
gh variable set TF_ZONE --body "${ZONE}" --repo "${LODESTAR_REPO}"
```

🔍

```bash
gh secret list --repo "${LODESTAR_REPO}" | cut -f1 | sort | wc -l
gh variable list --repo "${LODESTAR_REPO}" | cut -f1 | sort
```

Expect: `16`, then `TF_REGION` and `TF_ZONE`.

**The first drift run, and the scan of its public log.** The repository is public, so its Actions log is public.
Before trusting the setup, count the occurrences of each identifying value in the log. The values are read from
`terraform.tfvars` and never printed; only the count per key name is.

✏️ Starts a workflow run (read-only against the project).

```bash
gh workflow run drift.yml --repo "${LODESTAR_REPO}"
sleep 10
gh run watch "$(gh run list --workflow drift.yml --limit 1 --json databaseId --jq '.[0].databaseId' --repo "${LODESTAR_REPO}")" --repo "${LODESTAR_REPO}"
```

Expect: the run succeeds with `Plan: 0 to add, 0 to change, 0 to destroy, 0 to replace.` and `No changes.` in its job
summary, and no drift issue is opened.

🔍

```bash
LOG="$(mktemp)"
gh run view "$(gh run list --workflow drift.yml --limit 1 --json databaseId --jq '.[0].databaseId' --repo "${LODESTAR_REPO}")" --log --repo "${LODESTAR_REPO}" > "${LOG}"
for key in project_id project_number billing_account budget_id state_bucket state_kms_key_id github_owner_id github_repo_id ci_github_repo_id; do
  value="$(sed -n "s/^${key} *= *\"\(.*\)\"\$/\1/p" envs/apps/terraform.tfvars | head -n 1)"
  printf '%s: %s\n' "${key}" "$(grep -cF -- "${value}" "${LOG}")"
done
rm -f "${LOG}"
```

Expect: `0` for every key (GitHub shows each secret as `***`). Any other number is a leak: delete the run
(`gh run delete`), then find the step that printed it before running again.

---

## 13. Git and publishing

Run from: this repository's root. Goal: push reviewed work, with the right author address, and turn on the
repository protection.

### 13.1 Before a push

🔍 The quality gates and the secret scan (nothing here applies anything).

```bash
make check
make secrets
git status --short
git log --oneline origin/main..HEAD
```

Expect: `make check` ends without an error (fmt, validate, tflint, checkov, `tofu test`, bats, shellcheck,
gitleaks, actionlint, zizmor); `make secrets` runs gitleaks over the history and reports `no leaks found`.
Then scan the *added lines* for anything identifying (this repository and its docs are public). Added for
completeness, not from the session:

🔍

```bash
git diff origin/main..HEAD | grep -nE '^\+.*([0-9]{10,}|@gmail|@users\.noreply)' || printf 'nothing identifying found\n'
```

Expect: `nothing identifying found`. A hit is a stop: look at the line. Numbers of 10 or more digits are
project numbers and IDs; real e-mail addresses must not appear.

### 13.2 The GitHub noreply address

Every commit carries an author e-mail. If it is your real address, it becomes public in a public repository.
GitHub gives each account a **noreply address**, `<id>+<username>@users.noreply.github.com` (find the numeric
id with `gh api user --jq .id`; the address is also shown under **Settings → Emails**). With the setting
**Block command line pushes that expose my email** on, GitHub refuses a push whose commits use a private
address (`GH007`). Set the noreply address, per repository or globally:

✏️ For one repository (run inside it):

```bash
git config user.email "<id>+<username>@users.noreply.github.com"
```

✏️ For every repository on this machine:

```bash
git config --global user.email "<id>+<username>@users.noreply.github.com"
```

✏️ The owner copied the address already set in this repository to the other repositories he works in:

```bash
NR="$(git config user.email)"
for d in repo-one repo-two repo-three; do git -C ~/path/to/"${d}" config user.email "${NR}"; done
```

🔍 Check: `git config user.email` inside each repository, and `git log -1 --format='%ae'`. The setting only
affects *new* commits; rewriting old ones is a separate, history-changing step that needs the owner's explicit
approval.

### 13.3 The first push of a repository

For a first push of an existing local commit to an empty GitHub repository (no README or licence on GitHub, so
the push is plain):

✏️

```bash
git push origin <commit>:refs/heads/main
```

Why the explicit refspec: it pushes exactly that commit, fast-forward only, with no force. Do this **before**
any ruleset exists: a `main` ruleset that requires a pull request would refuse the push. From then on, work
goes through pull requests.

### 13.4 CI first run, then protect `main` (next)

At the time of writing this is the **next** step for this repository and has not been done.

1. Push a branch and open a pull request. The CI workflow and the PR-title workflow run and report two
   checks: `CI OK` and `PR title (Conventional Commits)`. They must each have run once so that GitHub can
   require them.
2. As a repository admin, logged in with your own `gh auth login`, run the settings script of this repository
   (a different, smaller script than the template's: it reads the repository from `gh repo view`):

🔍 Dry run: prints every call and the ruleset JSON; changes nothing.

```bash
bash scripts/github-settings.sh
```

✏️ Apply. Safe to repeat; the ruleset is updated in place.

```bash
bash scripts/github-settings.sh --apply
```

Expect: after it, `main` takes pull requests only: squash merges, both checks green and up to date, no force
push, no deletion, no bypass; secret scanning with push protection, Dependabot alerts and security updates, and
private vulnerability reporting are on. A failure prints GitHub's error body and stops.

**Conventional Commits** is the commit and PR-title format `type(scope): summary` (`feat`, `fix`, `docs`,
`chore`, ...; a `!` marks a breaking change). The squash merge takes the PR *title* as the commit message on
`main`, and the PR-title check holds it to the format, so the history stays machine-readable.

---

## 14. Troubleshooting index

| Symptom | Root cause | Fix |
| --- | --- | --- |
| `apt update` warns the Google Cloud SDK source is configured multiple times | two files in `/etc/apt/sources.list.d/` name the same repository | keep one file; see 1.1 |
| `gh auth login` ends with no token, or waits forever | the device flow was not completed: the one-time code must be entered in the browser at the printed URL, before it expires | rerun `gh auth login`; open the URL, type the code, approve; check with `gh auth status` |
| `wget: bad port '8080;'` in the NetworkPolicy probe | the `;` of `...:8080; echo "exit=$?"` reached `wget` as part of the URL | put `echo "exit=$?"` on its own line (5.4) |
| `kubectl apply --dry-run=server` says `NotFound` | the dry run creates nothing, so the namespaces do not exist | apply only the `Namespace` documents first with `yq` (7.2) |
| a deploy with the in-cluster database is refused: CronJob name too long (over 52 characters) | the chart's `<fullname>-pg-backup-verify` has no length guard (open template bug); a long release name makes the fullname long | use a shorter `SERVICE_NAME`; if namespaces already exist, delete the empty ones and re-render (7.5) |
| `github-settings.sh --apply` stops with `HTTP 422 ... Actor ... integration must be part of the ruleset source` | the release GitHub App is not installed on the repository, so the `release-tags` ruleset cannot name it | install the App on the repository, then rerun `--apply` (9.3); it updates in place |
| `ls ~/Downloads/*.pem` or `gh secret set ... < file`: "No such file" / not found | the key was not generated, is in another folder, a placeholder `<the-file>` was typed literally, a glob matched nothing or several files, or `GH_REPO` names the wrong repository | generate a key on the App's page (Credentials, Key pairs); list `ls ~/Downloads/*.pem`; use the exact name; check `printf '%s\n' "${GH_REPO}"` (9.5) |
| deploy-ops `check` fails: `Permission 'iam.serviceAccounts.getAccessToken' denied` | **cause 1:** the `workloadIdentityUser` member uses the classic subject (`repo:<owner>/<repo>:environment:<env>`), but the repository has immutable subjects | derive `SUB_PREFIX` from the API and rebind (6.2, 6.7); once section 11 is done these bindings are managed by OpenTofu (`gcp-github-wif`, `sub_claim_prefix`), so fix the value and apply a reviewed plan, never by hand |
| | **cause 2:** zsh turned `$GH_REPO:environment:$env` into `repo:nvironment:<env>` (and an unbraced repair into `nvironment:<env>`), members that match nothing | brace every variable before a colon, rebind and remove the bad members (6.7); after section 11, through the code and a plan |
| | **cause 3:** the binding is right but has not propagated yet | wait up to about 7 minutes after the change and rerun (6.6) |
| `gcloud` / `tofu` plan: `403 ... serviceusage.googleapis.com ... SERVICE_DISABLED` | the Service Usage API is not enabled in the project, and the root bills requests to the project, so the `google_project_service` reads fail | the bootstrap apply was skipped or has not propagated: wait 2 to 3 minutes; only for an old bootstrap, add the API through it (11.4) |
| apply or plan: `SERVICE_DISABLED` for `cloudbilling.googleapis.com` on a billing-account IAM member | `user_project_override` bills requests to the project, so the Cloud Billing API must be enabled there | the `ci_planner` module enables it; if it was just enabled, wait 2 to 3 minutes and plan again |
| plan: `Attribute redefined` for `ci_github_repository`, `ci_github_repo_id` or `ci_sub_claim_prefix` | the tfvars append of the CI identity runbook was run twice, so each key is in `terraform.tfvars` twice | keep the first occurrence of each key with the `awk` repair of 12.4, then `tofu fmt envs/apps/terraform.tfvars`; the append is now guarded and safe to repeat |
| `tofu apply <file>`: no such file / "Failed to load" a plan | the saved plan was already deleted (`rm -f` after use), or was run from the wrong directory (the file is in `bootstrap/` or `envs/apps/`) | plan again into a new file; use `tofu -chdir=<root> apply <file>` |
| `Excess arguments.`, `command not found: <word>`, or an odd error after a paste | prose (a sentence, a heading, a `->` explanation) was copied into the shell together with the commands | copy only the code block; if a prose line ran, check its side effects before going on |
| `unrecognized arguments` / flag unknown in `gcloud container clusters create` | an old gcloud | update gcloud and rerun 5.1 |
| `Maintenance policy would go longer than 32d without 48h maintenance availability` | the maintenance window is too short | use the Saturday and Sunday 8-hour window of 5.2 |
| `ImagePullBackOff` for a public image | no outbound route: NAT is missing or in another region | recheck section 3 |
| a workflow login is refused: `The given credential is rejected by the attribute condition` | wrong owner ID, repository ID, repository name case, or a workflow file or ref the condition does not allow | compare with `providers describe`. Before section 11: `providers update-oidc --attribute-condition=...` (6.3). After it the provider is managed by OpenTofu (`gcp-github-wif`): change the code and apply a reviewed plan, not by hand |
| `kubectl` hangs or times out | wrong kubeconfig, or the node pool is scaled to 0 | `source ~/gke-setup.env`; `kubectl config current-context`; check the node count |
| `tofu` reports an authentication or quota-project error | the ADC login expired or has no quota project | repeat 2.5 |
| zsh: `bad pattern` / `command not found: #` on a comment | interactive zsh does not ignore `#` comments by default | `setopt interactive_comments`, or paste without the comments |
| `GraphQL: Could not resolve to a PullRequest with the number of N`, or `gh` acting on the wrong repository | `GH_REPO` from `~/gke-setup.env` names the template repository, and `gh` prefers it to the current directory | `unset GH_REPO`, or add `-R "<owner>/lodestar-infra"` to the command |

---

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

---

## 16. Appendix: pausing the cluster and other one-off commands

### 16.1 Pause and resume the cluster (cost control)

The owner paused and resumed the earlier cluster to save money. Turn the autoscaler off first, or it adds a
node back for the system Pods. While paused you pay only for disks (and a load balancer, if there is one), and
the Cloudflare Tunnel's connector is down too.

✏️ Pause.

```bash
gcloud container node-pools update default-pool --cluster="${CLUSTER}" --location="${ZONE}" --no-enable-autoscaling
gcloud container clusters resize "${CLUSTER}" --location="${ZONE}" --node-pool=default-pool --num-nodes=0 --quiet
```

✏️ Resume (two nodes, then the autoscaler back on with the limits of 5.2).

```bash
gcloud container clusters resize "${CLUSTER}" --location="${ZONE}" --node-pool=default-pool --num-nodes=2 --quiet
gcloud container node-pools update default-pool --cluster="${CLUSTER}" --location="${ZONE}" \
  --enable-autoscaling --min-nodes=1 --max-nodes=3
```

Expect: a few minutes after the pause `kubectl get nodes` prints `No resources found`; after the resume, 2
nodes `Ready`. The node pool is now part of the OpenTofu cluster module: a pause changes its size and
autoscaling, so the next `tofu plan` WILL show them as drift. Resume before you plan or apply.

### 16.2 Look up a domain's registrar

🔍 Read-only. Used while choosing a domain for the Cloudflare step. `${DOMAIN}` is your domain name.

```bash
curl -fsSL "https://rdap.org/domain/${DOMAIN}" | jq -r '.entities[]? | select(.roles | index("registrar")) | .vcardArray[1][] | select(.[0] == "fn") | .[3]'
```

Expect: the registrar's name.
