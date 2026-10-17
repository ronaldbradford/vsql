import { bindings, defineConfig, defineContainer, exports } from "cf/config";

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
		// Cron disabled for on-demand testing (was daily 30 20 * * *).
		env: {
			REPO: bindings.text("ronaldbradford/vsql"),
			BASE_BRANCH: bindings.text("main"),
			DEFAULT_SQL_FILE: bindings.text("sql/smoke.sql"),
			DEFAULT_CODEBASES: bindings.text("mysql-8.4 percona-8.4 mysql-9.7"),
			AUTO_MERGE: bindings.text("0"),
			// Optional Build Log endpoint override; empty = build-log default.
			BUILD_LOG_URL: bindings.text(""),
			// Optional Slack progress posts; the channel is public config.
			SLACK_CHANNEL: bindings.text("C0CA2TF6W4C"),
			// Optional: set with `wrangler secret put SLACK_BOT_TOKEN`; unset = no Slack posts.
			SLACK_BOT_TOKEN: bindings.secret(),
			// Contents + pull requests write on ronaldbradford/vsql.
			GITHUB_TOKEN: bindings.secret(),
			// Shared secret required to trigger runs over HTTP.
			RUN_KEY: bindings.secret(),
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
