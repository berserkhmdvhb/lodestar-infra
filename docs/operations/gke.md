# Operations: the GKE cluster, its bootstrap, and pausing it

Part of the [operations runbook](README.md). Section numbers are the runbook's original ones, so references such as "section 5.1" keep working; the index maps each to its file.

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
