# Maintaining the extension smoke tests

`sql/smoke.sql` is the default SQL run against every codebase (`mysql-8.4`,
`percona-8.4`, `mysql-9.7`) by `scripts/vsql-test.sh`, the Cloudflare cron and the
DigitalOcean runner. It has core checks plus **one section per extension bundled
in the prebuilt tarball**.

## How extensions are discovered

The installer puts the bundled extensions as `*.veb` files in the server's
`veb_dir` (`SHOW VARIABLES LIKE 'veb_dir'`; `<install>/.villagesql/prebuilt/lib/veb/`).
For stable 0.0.7 all three codebases ship the same 13:

`vsql_ai vsql_boolean vsql_complex vsql_crypto vsql_cube vsql_fuzzystrmatch vsql_http
vsql_network_address vsql_oauth2 vsql_rest vsql_simple vsql_trgm vsql_uuid`

(`vsql_complex` and `vsql_simple` are SDK example extensions; `vsql_oauth2` and
`vsql_rest` have no SQL functions, so they are checked via their system variables.)

Every run does this automatically: after the SQL finishes, `vsql-test.sh` lists
`lib/veb/*.veb` and compares it with the `-- [ext:<name>]` markers in the SQL file.
A `.veb` with no section is reported **UNTESTED** (a warning; set
`VSQL_REQUIRE_COVERAGE=1` to make it fail). So when a new VillageSQL release adds a
bundled extension, the next run says so in the log, `summary.md` and
`summary.json` (`untested_extensions`).

To inspect things by hand on a running server:

```sql
SELECT * FROM INFORMATION_SCHEMA.EXTENSIONS;              -- installed name + version
SELECT extension_name, registration_json                  -- functions/types/SDK version
  FROM INFORMATION_SCHEMA.EXTENSION_REGISTRATION;         -- (JSON_TABLE over $.funcs[*])
SHOW VARIABLES LIKE 'vsql_<ext>.%';                       -- per-extension variables
```

Usage docs live in each extension's repo README (`github.com/villagesql/vsql-<name>`)
and in `github.com/villagesql/villagesql-docs`; release notes in
`villagesql-server/Docs/release_notes/`.

## How PASS/FAIL works

* `mysql` runs with `--force`, so every extension section runs even if an earlier
  one failed (`VSQL_FORCE=0` stops at the first error).
* A variant is **FAIL** if the `mysql` exit status is non-zero **or** any `ERROR ...`
  line appears in `sql-output.log`.
* Each `ERROR ... at line N` is attributed to the last `-- [ext:<name>]` marker above
  line N. The log, `summary.md` and `summary.json` (`variants[].extensions`) show
  PASS / FAIL / UNTESTED per extension. Errors before the first marker are `(core)`.
* SQL has no ASSERT, so checks are raised as real errors with this single-line idiom
  (error 1242 "Subquery returns more than 1 row"; the reported line number is the
  failed assertion):

  ```sql
  DO IF(<condition>, 1, (SELECT 'assert failed' UNION ALL SELECT 'x'));
  ```

## Adding a test for a new extension

1. Run once and read the report: the new `.veb` shows as UNTESTED. Find usage in its
   README and list its functions with the `EXTENSION_REGISTRATION` query above.
2. Add a section to `sql/smoke.sql` (before the `(registry)` cross-check):

   ```sql
   -- [ext:vsql_example]
   SELECT '=== vsql_example ===' AS extension_test;
   INSTALL EXTENSION vsql_example;
   DO IF(example_fn('x')='expected', 1, (SELECT 'assert failed' UNION ALL SELECT 'x'));
   ```

   Keep it small: install, one function/type round trip, no network, no secrets, drop
   any tables you create (an extension with columns in use cannot be uninstalled).
   Keep each assertion on one line. Watch for custom-type quirks: bytearray/uuid values
   cannot be wrapped in `CONVERT`/`CAST AS CHAR`, and `` `cube` `` must be backticked.
3. Verify locally on all three codebases (below) and open a PR.

## Running locally

The tarballs need glibc 2.42 and libaio/libnuma, so use the runner image:

```bash
sudo docker build -t vsql-runner cloudflare/
sudo docker run --rm -v "$PWD":/repo:ro -v /tmp/vsql-out:/out --user runner vsql-runner bash -c \
  'cp -r /repo /tmp/r && cd /tmp/r && VSQL_LOG_DIR=/out ./scripts/vsql-test.sh sql/smoke.sql'
```

(`/tmp/vsql-out` must be writable by uid of `runner`.) Exit status 0 means all variants
PASS. `/out/<codebase>/sql-output.log` has the raw output.

## Checking vsql-statistics compatibility

`vsql_statistics` ([ronaldbradford/vsql-statistics](https://github.com/ronaldbradford/vsql-statistics))
is a community extension, **not bundled**; it is distributed as `.veb` assets on GitHub
releases (linux x86_64/aarch64, darwin arm64/x86_64). Check the newest release against
the current VillageSQL stable on all codebases:

```bash
VEB=$(./scripts/fetch-statistics-veb.sh | tail -1)     # prints tag, sha256, manifest version
VSQL_EXTRA_VEB="$VEB" ./scripts/vsql-test.sh sql/statistics.sql
```

`sql/statistics.sql` installs it, prints the SDK version and protocol it was built
with (`INFORMATION_SCHEMA.EXTENSION_REGISTRATION`), runs `STATS_IQR`, `STATS_MODE` and
`STATS_TTEST_GROUPS`, and uninstalls. The other bundled extensions are reported UNTESTED
in that run; that is expected. Things to look for:

* **ABI/protocol error on `INSTALL EXTENSION`**: the `.veb` was built for an SDK the
  server no longer accepts. Compare the `.veb` SDK version with
  `SHOW VARIABLES LIKE 'villagesql_server_version'` and
  `villagesql_vef_server_protocol`; the extension needs rebuilding against the new SDK
  (`VillageSQL_BUILD_DIR=... ./build.sh` in the vsql-statistics repo).
* **No asset for the platform** (`fetch-statistics-veb.sh` fails): the release lacks a
  linux build; note `dist/` on `main` has only a darwin-arm64 `.veb`.
* A newer VillageSQL release changes the answer: re-run after each stable bump.
* Upgrading in place is not supported: `UNINSTALL EXTENSION` then `INSTALL EXTENSION`.
