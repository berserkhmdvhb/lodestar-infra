# Operations: secrets

Part of the [operations runbook](README.md). Section numbers are the runbook's original ones, so references such as "section 5.1" keep working; the index maps each to its file.

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

