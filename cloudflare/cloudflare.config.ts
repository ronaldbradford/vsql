import { bindings, defineConfig, defineContainer, exports, triggers } from "cf/config";

// Ubuntu 24.04 image with the test tooling; see ./Dockerfile.
// The Durable Object starts it with `this.container.images.vsql`.
const vsqlContainer = defineContainer({
	name: "vsql-test-runner",
	schedulingPolicy: "durable-object",
	images: {
		vsql: { dockerfile: "./Dockerfile" },
	},
});

export default defineConfig({
	worker: {
		name: "vsql-test-runner",
		compatibilityDate: "2026-10-16",
		entrypoint: "src/index.ts",
		observability: {
			enabled: true,
		},
		// Daily at 20:30 UTC (06:30 Brisbane).
		triggers: [triggers.scheduled({ schedule: "30 20 * * *" })],
		env: {
			REPO: bindings.text("ronaldbradford/vsql"),
			BASE_BRANCH: bindings.text("main"),
			DEFAULT_SQL_FILE: bindings.text("sql/smoke.sql"),
			DEFAULT_CODEBASES: bindings.text("mysql-8.4 percona-8.4 mysql-9.7"),
			AUTO_MERGE: bindings.text("1"),
			// Contents + pull requests write on ronaldbradford/vsql.
			GITHUB_TOKEN: bindings.secret(),
			// Shared secret required to trigger runs over HTTP.
			RUN_KEY: bindings.secret(),
			VSQL_RUNNER: bindings.durableObject({
				worker: "vsql-test-runner",
				exportName: "VsqlRunner",
			}),
		},
		exports: {
			VsqlRunner: exports.durableObject({
				storage: "sqlite",
				container: vsqlContainer,
			}),
		},
	},
	containers: [vsqlContainer],
});
