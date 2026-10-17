# vsql
VillageSQL testing and support tools

## Prebuilt variant testing

`scripts/vsql-test.sh` installs VillageSQL prebuilt binaries with the official
installer (`https://install.villagesql.com`) for each server codebase, starts
each one, runs a SQL script, and writes logs plus a summary.

| Codebase | Upstream |
|---|---|
| `mysql-8.4` | MySQL 8.4 |
| `percona-8.4` | Percona Server 8.4 |
| `mysql-9.7` | MySQL 9.7 |

The installer's prebuilt option provides the latest **stable** release only.

```
./scripts/vsql-test.sh sql/smoke.sql                       # all three
./scripts/vsql-test.sh sql/smoke.sql mysql-9.7 percona-8.4 # a subset
```

`scripts/run-and-pr.sh` wraps the test, commits the logs under
`logs/YYYY/MM/DD/<timestamp>/` on a `test-log/<timestamp>` branch, and opens a
pull request (squash-merged automatically when `AUTO_MERGE=1`). Failed runs are
recorded too.

```
GH_TOKEN=... ./scripts/run-and-pr.sh sql/smoke.sql
DRY_RUN=1 ./scripts/run-and-pr.sh            # local commit only, no push or PR
```

Each run directory holds `summary.md`, `summary.json`, `console.log`, the exact
`install.sh` and `test.sql` used, and per-variant `install.log`,
`sql-output.log` and `mysqld.log`. Root passwords are redacted.

## Running on Cloudflare Containers

`cloudflare/` is a Worker with a container-backed Durable Object. On a daily
cron (or an authenticated HTTP call) it starts an Ubuntu 24.04 container,
clones this repo, and runs `scripts/run-and-pr.sh` as a non-root user. A
Durable Object alarm polls every minute until the run finishes, then the
container is destroyed so every run starts clean.

### One-time setup

The Worker is managed with Cloudflare's `cf` CLI (open beta), configured in
`cloudflare/cloudflare.config.ts`. `cf` hands the build to Wrangler for
esbuild-bundled Workers, so Wrangler stays a dev dependency.

1. Workers Paid plan (required for Containers) and Docker running locally
   (the image is built from `cloudflare/Dockerfile` on deploy).
2. Create a fine-grained GitHub token limited to `ronaldbradford/vsql` with
   **Contents: Read and write** and **Pull requests: Read and write**.
3. Put the secrets in `cloudflare/.secrets.json` (git-ignored):

   ```json
   { "GITHUB_TOKEN": "github_pat_...", "RUN_KEY": "any-long-random-string" }
   ```

4. Deploy, then delete the secrets file:

   ```
   cd cloudflare
   npm install
   npm run check                                   # cf workers types + tsc
   npx cf deploy --secrets-file .secrets.json
   rm .secrets.json
   ```

   Later code-only deploys are just `npx cf deploy`. Use the secrets file
   again to rotate a token.

### Use

```
# start a run (body is optional)
curl -X POST https://vsql-test-runner.<subdomain>.workers.dev/run \
  -H "Authorization: Bearer $RUN_KEY" \
  --json '{"sqlFile":"sql/smoke.sql","codebases":["mysql-8.4","mysql-9.7"]}'

# check progress (includes the last few KB of output)
curl https://vsql-test-runner.<subdomain>.workers.dev/status \
  -H "Authorization: Bearer $RUN_KEY"
```

Settings live in `cloudflare/cloudflare.config.ts` under `env`: the default SQL
file, codebases, base branch and `AUTO_MERGE`; the cron schedule is under `triggers`
(`30 20 * * *` UTC, which is 06:30 Brisbane).

To add a test, commit a new file under `sql/` and pass it as `sqlFile`.

## Running on DigitalOcean

`digitalocean/do-run.sh` runs the same `scripts/run-and-pr.sh` on a throwaway
droplet: it creates the droplet, installs dependencies with
`digitalocean/cloud-init.yaml`, clones this repo as the non-root `runner`
user, runs the tests, copies the logs back to `digitalocean/results/<droplet>/`,
and destroys the droplet.

### One-time setup

```
brew install doctl jq
doctl auth init
doctl compute ssh-key import my-laptop --public-key-file ~/.ssh/id_ed25519.pub
```

### Use

```
./digitalocean/do-run.sh run                          # all three, sql/smoke.sql
./digitalocean/do-run.sh run sql/smoke.sql mysql-9.7  # same arguments as run-and-pr.sh
./digitalocean/do-run.sh run --local                  # test uncommitted scripts/ and sql/
./digitalocean/do-run.sh run --if-changed             # no droplet if this release already passed
./digitalocean/do-run.sh run --keep                   # leave it up; then: ssh, down
./digitalocean/do-run.sh reap 90                      # destroy vsql-test droplets older than 90 min
```

Without `GH_TOKEN` the run is `DRY_RUN=1` and the logs are only copied back
locally; with it, run-and-pr.sh pushes the logs and opens a PR as usual.

Reporting matches the Cloudflare runner (see *Slack messages* below). With `SLACK_BOT_TOKEN` set, the
droplet's lifecycle is posted to `SLACK_CHANNEL` (default `C0CA2TF6W4C`):
created, destroyed and the approximate cost, plus any aborts and reaps.
run-and-pr.sh also posts its per-codebase results. `scripts/build-log` records
the whole droplet run from your machine, and each codebase from the droplet.

Tokens are piped to the droplet over SSH, never placed in user-data, which is
readable from the droplet's metadata service.

**Image:** the default is `ubuntu-26-04-x64`. The 0.0.7 prebuilt clients
(`mysql`, `mysqladmin`) need glibc ≥ 2.42. Ubuntu 24.04 has 2.39, so there the
installer's `mysqladmin ping` fails even though `mysqld` (glibc 2.38) would
run.

### Cost

Droplets are billed per second (60 s / $0.01 minimum), and a powered-off
droplet still bills, so the script always *destroys* it: on success, failure
or Ctrl-C (unless `--keep`). `reap` is the backstop for a killed laptop. A run
takes a few minutes on `s-2vcpu-4gb`, well under a cent; `down` prints the
figure. `--if-changed` asks GitHub for the latest release before creating
anything, so a scheduled run costs nothing on nights without a new release:

```
17 3 * * *  cd ~/projects/villagesql/vsql && ./digitalocean/do-run.sh run --if-changed
```

## Slack messages

The same tests can run from Cloudflare, DigitalOcean, or any virtual or
physical machine, all posting to one channel. Every message starts with
`[RUN_SOURCE · host]`:

```
[cloudflare cron · 8f3a…] :rocket: vsql test run started: sql=sql/smoke.sql …
[digitalocean · vsql-test-20261017t015126z] :droplet: vsql droplet created (s-2vcpu-4gb, syd1, ubuntu-26-04-x64)
[homelab · nuc01] :white_check_mark: mysql-9.7 PASS (14s)
```

- `RUN_SOURCE`: the environment. The Cloudflare worker sets
  `cloudflare cron`/`cloudflare http`, `do-run.sh` defaults to `digitalocean`,
  and anywhere else defaults to `manual`. Set it to name a machine class, e.g.
  `RUN_SOURCE=homelab ./scripts/run-and-pr.sh`.
- `RUN_HOST`: the machine (default: short hostname). DigitalOcean messages use
  the droplet name.

`RUN_SOURCE` is also recorded in the PR body and the build log.

To check the token, channel and prefix without running any tests:

```
SLACK_BOT_TOKEN=xoxb-… SLACK_CHANNEL=C0CA2TF6W4C RUN_SOURCE=homelab ./scripts/slack-test
SLACK_BOT_TOKEN=xoxb-… ./digitalocean/do-run.sh slack-test   # adds droplet created/destroyed samples; no droplet
SLACK_DRY_RUN=1 SLACK_CHANNEL=C0CA2TF6W4C ./scripts/slack-test   # print only, no token needed
```
