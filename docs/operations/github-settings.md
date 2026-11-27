# Operations: GitHub settings, the release App, and Git publishing

Part of the [operations runbook](README.md). Section numbers are the runbook's original ones, so references such as "section 5.1" keep working; the index maps each to its file.

## 9. GitHub repository settings and the release App

Run from: the template repository root (the repository's own settings), `gh` logged in as an admin.
Goal: rulesets, environments, variables and the Actions policy set as code, plus the release GitHub App and
its key, then the first green `check` from GitHub.

### 9.1 The vars-file

The settings script sets repository and environment variables from a file kept **outside** the repository
(it refuses a path under the repo root). The guide's table (`wiki/platform-setup.md`, Variables and
secrets) is the single list of names.

✏️ (writes a file of identifiers, not secrets, in the private folder; mode `600`). `RELEASE_APP_ID` is a placeholder until 9.3.

The file has three groups: the repository variables (`GCP_PROJECT_ID` to `RELEASE_APP_ID`), the environment variables (the same provider, a different deployer each: the `ENV_*` lines), and a script input that is never sent as a variable (`REVIEWER_USER_ID`, the production reviewer, you).

```bash
source ~/gke-setup.env
WIF="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github/providers/github-oidc"
cat > ~/platform-config/github-vars.env <<EOF
GCP_PROJECT_ID=${PROJECT_ID}
GKE_CLUSTER=${CLUSTER}
GKE_LOCATION=${ZONE}
SERVICE_NAME=${SERVICE_NAME}
RELEASE_APP_ID=<APP_ID>
ENV_dev_GCP_WIF_PROVIDER=${WIF}
ENV_qa_GCP_WIF_PROVIDER=${WIF}
ENV_production_GCP_WIF_PROVIDER=${WIF}
ENV_dev_GCP_DEPLOYER_SA=gh-deployer-dev@${PROJECT_ID}.iam.gserviceaccount.com
ENV_qa_GCP_DEPLOYER_SA=gh-deployer-qa@${PROJECT_ID}.iam.gserviceaccount.com
ENV_production_GCP_DEPLOYER_SA=gh-deployer-production@${PROJECT_ID}.iam.gserviceaccount.com
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
  --template --diff > ~/platform-config/settings-dryrun.txt 2>&1; printf 'exit=%s\n' "$?"
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
  --template --apply; printf 'exit=%s\n' "$?"
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

