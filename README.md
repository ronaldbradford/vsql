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
