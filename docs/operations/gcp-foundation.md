# Operations: Google Cloud project, network and node service account

Part of the [operations runbook](README.md). Section numbers are the runbook's original ones, so references such as "section 5.1" keep working; the index maps each to its file.

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

