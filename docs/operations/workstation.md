# Operations: workstation setup

Part of the [operations runbook](README.md). Section numbers are the runbook's original ones, so references such as "section 5.1" keep working; the index maps each to its file.

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

