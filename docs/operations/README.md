# Operations runbook: every manual step, by stage of the stack

This is the owner's complete list of the manual commands used to build the platform by hand and then bring
it under OpenTofu. Each entry says what the command is for, whether it changes anything, what to expect, and
the idea behind it. The stages follow the order the platform was built in.

It does not replace the step-by-step guides (the template's `wiki/gke-cluster-setup.md`,
`wiki/platform-setup.md`, `wiki/github-repository-settings.md`) or this repository's
[`import-runbook.md`](../import-runbook.md), [`hardening-runbook.md`](../hardening-runbook.md) and
[`production-runbook.md`](../production-runbook.md) (the separate production project and cluster). It collects the
commands the owner ran or was told to run, with the corrections found on the way. A few items were added for
completeness; each is marked "Added for completeness, not from the session". Where a guide command and the
command that worked differ, this page gives the working one and says why.

This page is public. It contains no real project ID, number, account, e-mail, ID or secret: every value is a
variable from the env file or a placeholder such as `your-project-id` or `<billing-account>`.

## Contents

The runbook is split by stack. Section numbers are the original ones (prose such as "section 5.1" refers to
them); this table says where each section lives.

| Section | File |
| --- | --- |
| [0. How to use this runbook](#0-how-to-use-this-runbook) | this page |
| 1. Workstation setup | [workstation.md](workstation.md#1-workstation-setup) |
| 2. Google Cloud project foundation | [gcp-foundation.md](gcp-foundation.md#2-google-cloud-project-foundation) |
| 3. Network | [gcp-foundation.md](gcp-foundation.md#3-network) |
| 4. Node service account | [gcp-foundation.md](gcp-foundation.md#4-node-service-account) |
| 5. GKE cluster | [gke.md](gke.md#5-gke-cluster) |
| 6. GitHub identity and Workload Identity Federation | [github-identity.md](github-identity.md#6-github-identity-and-workload-identity-federation) |
| 7. Cluster bootstrap | [gke.md](gke.md#7-cluster-bootstrap) |
| 8. Secrets | [secrets.md](secrets.md#8-secrets) |
| 9. GitHub repository settings and the release App | [github-settings.md](github-settings.md#9-github-repository-settings-and-the-release-app) |
| 10. Read-only live-config export | [opentofu.md](opentofu.md#10-read-only-live-config-export) |
| 11. OpenTofu: state, import, apply | [opentofu.md](opentofu.md#11-opentofu-state-import-apply) |
| 12. OpenTofu: GKE hardening (12.4: the CI identity) | [opentofu.md](opentofu.md#12-opentofu-gke-hardening) |
| 13. Git and publishing | [github-settings.md](github-settings.md#13-git-and-publishing) |
| 14. Troubleshooting index | [troubleshooting.md](troubleshooting.md#14-troubleshooting-index) |
| 15. Concepts glossary | [glossary.md](glossary.md#15-concepts-glossary) |
| 16. Appendix: pausing the cluster and other one-off commands | [gke.md](gke.md#16-appendix-pausing-the-cluster-and-other-one-off-commands) |

Cloudflare: to be written from the owner's setup run.

The procedure runbooks: [`import-runbook.md`](../import-runbook.md), [`hardening-runbook.md`](../hardening-runbook.md),
[`ci-identity-runbook.md`](../ci-identity-runbook.md) and [`production-runbook.md`](../production-runbook.md).

The production project and its regional cluster are built by [`production-runbook.md`](../production-runbook.md),
which reuses the commands of sections 5, 7, 8 and 12 with production's names.

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
