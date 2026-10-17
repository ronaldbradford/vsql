import { DurableObject } from "cloudflare:workers";

// One test run at a time: clone ronaldbradford/vsql inside the container,
// run scripts/run-and-pr.sh as the non-root "runner" user, and poll with a
// Durable Object alarm until it finishes. The script itself opens the PR.

const WORK = "/workspace";
const CHECKOUT = `${WORK}/vsql`;
const JOB_LOG = `${WORK}/job.log`;
const JOB_EXIT = `${WORK}/job.exit`;
const POLL_MS = 60_000;
const MAX_RUN_MS = 60 * 60_000;

type RunRequest = { sqlFile?: string; codebases?: string[]; source?: string; dryRun?: boolean; ref?: string };

type RunState = {
	status: "idle" | "running" | "finished" | "timed-out" | "error";
	startedAt?: string;
	finishedAt?: string;
	exitCode?: number;
	request?: RunRequest;
	logTail?: string;
	error?: string;
};

const CODEBASES = new Set(["mysql-8.4", "percona-8.4", "mysql-9.7"]);
const SAFE_PATH = /^[A-Za-z0-9._/-]+$/;

function shellQuote(s: string): string {
	return `'${s.replace(/'/g, `'\\''`)}'`;
}

export class VsqlRunner extends DurableObject<Env> {
	private get container() {
		const c = this.ctx.container;
		if (!c) throw new Error("The container binding is not configured");
		return c;
	}

	private async ensureStarted() {
		if (!this.container.running) {
			this.container.start({
				image: this.container.images.vsql,
				instance: "standard-3",
				// Needs github.com, api.github.com, install.villagesql.com and the
				// release download hosts.
				enableInternet: true,
			});
			// DIAGNOSTIC: record why the container exits.
			const st = this.ctx.storage;
			this.container.monitor().then(
				() => st.put("containerExit", { at: new Date().toISOString(), ok: true }),
				(e) => st.put("containerExit", { at: new Date().toISOString(), error: String(e) }),
			);
		}
		// Keep the container alive while the detached job runs.
		await this.container.setInactivityTimeout(MAX_RUN_MS + 10 * 60_000);
	}

	private baseEnv(): Record<string, string> {
		return {
			PATH: "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
			HOME: "/home/runner",
			LANG: "C.UTF-8",
			GH_TOKEN: this.env.GITHUB_TOKEN,
		};
	}

	// Run a shell command as the unprivileged "runner" user.
	private async sh(script: string, env: Record<string, string> = {}) {
		const process = await this.container.exec(["bash", "-c", script], {
			cwd: WORK,
			user: "runner",
			env: { ...this.baseEnv(), ...env },
		});
		const output = await process.output();
		const decode = (b: ArrayBuffer) => new TextDecoder().decode(b);
		return {
			exitCode: output.exitCode,
			stdout: decode(output.stdout),
			stderr: decode(output.stderr),
		};
	}

	async status(): Promise<RunState> {
		return (await this.ctx.storage.get<RunState>("state")) ?? { status: "idle" };
	}

	async start(req: RunRequest): Promise<RunState> {
		const current = await this.status();
		if (current.status === "running") return current;

		const sqlFile = req.sqlFile ?? this.env.DEFAULT_SQL_FILE;
		const codebases = req.codebases ?? this.env.DEFAULT_CODEBASES.split(/\s+/).filter(Boolean);
		if (!SAFE_PATH.test(sqlFile) || sqlFile.includes("..")) {
			throw new Error(`Invalid sqlFile: ${sqlFile}`);
		}
		if (req.ref !== undefined && (!SAFE_PATH.test(req.ref) || req.ref.includes(".."))) {
			throw new Error(`Invalid ref: ${req.ref}`);
		}
		for (const cb of codebases) {
			if (!CODEBASES.has(cb)) throw new Error(`Unknown codebase: ${cb}`);
		}
		const request: RunRequest = { sqlFile, codebases, source: req.source ?? "manual", dryRun: req.dryRun === true, ref: req.ref };

		try {
			await this.ensureStarted();

			const clone = await this.sh(
				`rm -rf ${CHECKOUT} ${JOB_LOG} ${JOB_EXIT} && ` +
					`gh repo clone ${shellQuote(this.env.REPO)} ${CHECKOUT} -- --quiet${request.ref ? ` --branch ${shellQuote(request.ref)}` : ""} && ` +
					`test -f ${CHECKOUT}/${sqlFile}`,
			);
			if (clone.exitCode !== 0) {
				throw new Error(`Clone failed: ${clone.stderr || clone.stdout}`);
			}

			// Launch detached so this call returns; the alarm polls for completion.
			const args = [sqlFile, ...codebases].map(shellQuote).join(" ");
			const launch = await this.sh(
				`cd ${CHECKOUT} && setsid nohup bash -c ` +
					shellQuote(`./scripts/run-and-pr.sh ${args} > ${JOB_LOG} 2>&1; echo $? > ${JOB_EXIT}`) +
					` > /dev/null 2>&1 &`,
				{
					BASE_BRANCH: request.ref ?? this.env.BASE_BRANCH,
					AUTO_MERGE: this.env.AUTO_MERGE,
					...(request.dryRun ? { DRY_RUN: "1" } : {}),
					...(this.env.BUILD_LOG_URL ? { BUILD_LOG_URL: this.env.BUILD_LOG_URL } : {}),
					...(this.env.SLACK_BOT_TOKEN ? { SLACK_BOT_TOKEN: this.env.SLACK_BOT_TOKEN } : {}),
					...(this.env.SLACK_CHANNEL ? { SLACK_CHANNEL: this.env.SLACK_CHANNEL } : {}),
					RUN_SOURCE: `grokbot cloudflare ${request.source}`,
				} as unknown as Record<string, string>,
			);
			if (launch.exitCode !== 0) {
				throw new Error(`Launch failed: ${launch.stderr || launch.stdout}`);
			}
		} catch (e) {
			const state: RunState = {
				status: "error",
				request,
				finishedAt: new Date().toISOString(),
				error: e instanceof Error ? e.message : String(e),
			};
			await this.ctx.storage.put("state", state);
			return state;
		}

		const state: RunState = { status: "running", startedAt: new Date().toISOString(), request };
		await this.ctx.storage.put("state", state);
		await this.ctx.storage.setAlarm(Date.now() + POLL_MS);
		return state;
	}

	async alarm(): Promise<void> {
		const state = await this.status();
		if (state.status !== "running") return;

		// The container stops if it goes idle; this poll also keeps it active.
		if (!this.container.running) {
			const ce = await this.ctx.storage.get("containerExit");
			await this.finish(state, "error", undefined, "Container stopped before the run finished" + (ce ? ` ${JSON.stringify(ce)}` : ""));
			return;
		}

		const check = await this.sh(`cat ${JOB_EXIT} 2>/dev/null; echo; tail -c 4000 ${JOB_LOG} 2>/dev/null`);
		const [first, ...rest] = check.stdout.split("\n");
		const tail = rest.join("\n");

		if (first.trim() !== "") {
			await this.finish(state, "finished", Number(first.trim()), undefined, tail);
			return;
		}
		if (Date.now() - Date.parse(state.startedAt ?? "") > MAX_RUN_MS) {
			await this.finish(state, "timed-out", undefined, "Run exceeded the time limit", tail);
			return;
		}
		await this.ctx.storage.put("state", { ...state, logTail: tail });
		await this.ctx.storage.setAlarm(Date.now() + POLL_MS);
	}

	private async finish(
		state: RunState,
		status: RunState["status"],
		exitCode?: number,
		error?: string,
		logTail?: string,
	) {
		await this.ctx.storage.put("state", {
			...state,
			status,
			exitCode,
			error,
			logTail: logTail ?? state.logTail,
			finishedAt: new Date().toISOString(),
		});
		// A fresh container for every run keeps results independent.
		await this.container.destroy().catch(() => {});
	}
}

function runner(ctx: ExecutionContext) {
	// Same-Worker Durable Object via ctx.exports (a binding cannot be declared
	// for a container-backed DO in the same Worker with this config schema).
	const ns = (ctx as unknown as { exports: { VsqlRunner: DurableObjectNamespace<VsqlRunner> } }).exports.VsqlRunner;
	return ns.getByName("vsql-test-runner");
}

export default {
	async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
		const url = new URL(request.url);
		if (request.headers.get("authorization") !== `Bearer ${env.RUN_KEY}`) {
			return new Response("Unauthorized", { status: 401 });
		}

		if (url.pathname === "/run" && request.method === "POST") {
			const body = (await request.json().catch(() => ({}))) as RunRequest;
			try {
				return Response.json(await runner(ctx).start({ ...body, source: "http" }));
			} catch (e) {
				return Response.json({ error: e instanceof Error ? e.message : String(e) }, { status: 400 });
			}
		}
		if (url.pathname === "/status" && request.method === "GET") {
			return Response.json(await runner(ctx).status());
		}
		return new Response("Not found", { status: 404 });
	},

	async scheduled(_controller: ScheduledController, _env: Env, ctx: ExecutionContext): Promise<void> {
		ctx.waitUntil(runner(ctx).start({ source: "cron" }));
	},
} satisfies ExportedHandler<Env>;
