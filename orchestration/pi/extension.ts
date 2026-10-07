// Orchestration plugin, Pi side. Does for Pi what hooks/hooks.json and the
// agents/ directory do for Claude Code:
//
// 1. Reports the session to `orch hook` (SessionStart, PostToolUse, Stop,
//    SessionEnd) so orch knows each ticket session's health. Only inside a
//    project root (~/Projects/<project>) that has .agents/orchestration/state.db.
// 2. Offers the stage agents (agents/*.md) to the `subagents` extension as
//    `orchestration:<name>` profiles, translated to Pi tools, model and
//    thinking.
//
// Contract: skills/orchestration/references/orch-cli.md ("Hooks", "Harnesses").

import { spawn, spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export const PLUGIN_ROOT = path.resolve(import.meta.dirname, "..");
export const ORCH = path.join(PLUGIN_ROOT, "scripts", "orch");
export const AGENTS_DIR = path.join(PLUGIN_ROOT, "agents");

// A subagent child inherits this from its parent session, so its tool calls
// keep the parent ticket session `working` (Claude reports subagent tool
// calls under the parent's session id the same way).
export const PARENT_ENV = "ORCH_PI_PARENT_SESSION";
const POST_TOOL_THROTTLE_MS = 15_000;
const HOOK_TIMEOUT_MS = 10_000;
const END_TIMEOUT_MS = 3_000;

// The subagents extension reads profiles from providers registered here.
export const AGENT_PROVIDERS = Symbol.for("pi-subagents.agent-providers");

type Payload = Record<string, unknown>;

/** Run `orch hook` with `payload` on stdin; resolve with its stdout. Never rejects. */
export function runHook(payload: Payload, timeoutMs = HOOK_TIMEOUT_MS, orch = ORCH): Promise<string> {
	return new Promise((resolve) => {
		let out = "";
		let done = false;
		const finish = () => {
			if (done) return;
			done = true;
			clearTimeout(timer);
			resolve(out);
		};
		let child: ReturnType<typeof spawn>;
		try {
			child = spawn(orch, ["hook"], {
				cwd: typeof payload.cwd === "string" ? payload.cwd : undefined,
				env: { ...process.env, ORCH_HOOK_AGENT_PID: String(process.pid) },
				stdio: ["pipe", "pipe", "ignore"],
			});
		} catch {
			resolve("");
			return;
		}
		const timer = setTimeout(() => {
			try {
				child.kill("SIGKILL");
			} catch {}
			finish();
		}, timeoutMs);
		timer.unref?.();
		child.stdout?.on("data", (d) => (out += String(d)));
		child.on("error", finish);
		child.on("close", finish);
		child.stdin?.on("error", () => {});
		child.stdin?.end(JSON.stringify(payload));
	});
}

/** The project root (the folder directly under ORCH_PROJECTS_DIR, default
 * ~/Projects) holding `cwd`. A worktree outside it is traced through its main
 * checkout with one git call. Mirrors scripts/orch's project_root. */
export function projectRoot(cwd: string): string | null {
	let projects: string;
	try {
		projects = fs.realpathSync(process.env.ORCH_PROJECTS_DIR || path.join(os.homedir(), "Projects"));
	} catch {
		return null;
	}
	const under = (p: string): string | null => {
		let real: string;
		try {
			real = fs.realpathSync(p);
		} catch {
			return null;
		}
		const rel = path.relative(projects, real);
		if (!rel || rel.startsWith("..") || path.isAbsolute(rel)) return null;
		return path.join(projects, rel.split(path.sep)[0]);
	};
	const root = under(cwd);
	if (root) return root;
	const p = spawnSync("git", ["-C", cwd, "rev-parse", "--path-format=absolute", "--git-common-dir"], {
		encoding: "utf8",
		timeout: 5_000,
	});
	if (p.status !== 0 || !p.stdout.trim()) return null;
	return under(path.dirname(p.stdout.trim()));
}

/** Whether `cwd` belongs to a project orch keeps state for. */
export function hasOrchState(cwd: string): boolean {
	if (process.env.ORCH_HOME) return true;
	const root = projectRoot(cwd);
	return !!root && fs.existsSync(path.join(root, ".agents", "orchestration", "state.db"));
}

// ---- stage agents -----------------------------------------------------------

const PI_TOOLS: Record<string, string[]> = {
	Read: ["read"],
	Grep: ["grep"],
	Glob: ["find", "ls"],
	Bash: ["bash"],
	Write: ["write"],
	Edit: ["edit"],
};
// The agents name Claude model tiers. Each tier maps to a Pi model (the
// same choices as scripts/codex-agents) and a thinking level. Providers
// differ per machine: the machine config's `pi_models` overrides the map,
// and a model the session's registry does not know is left out, so that
// agent runs on the session's model.
const PI_THINKING: Record<string, string> = { haiku: "low", sonnet: "medium", opus: "high" };
export const PI_MODELS: Record<string, string> = {
	haiku: "openai-codex/gpt-6-luna",
	sonnet: "openai-codex/gpt-6.1-sol",
	opus: "openai-codex/gpt-6-astra",
};
// The implementor is also dispatched outside the pipeline (analyze-ticket),
// whose dispatcher passes the model: leave it unset.
const NO_MODEL = new Set(["implementor"]);
// Reviewer and verifier run on the sonnet tier's model with their own
// (opus) thinking: judgment at high effort, not the frontier model's cost.
// The same choice as scripts/codex-agents.
const MODEL_TIER: Record<string, string> = { reviewer: "sonnet", verifier: "sonnet" };
// The reporter only writes up the run: haiku tier, model and thinking.
const TIER: Record<string, string> = { reporter: "haiku" };

type ModelCheck = (model: string) => boolean;

/** The tier -> model map: PI_MODELS, overridden by the machine config's `pi_models`. */
export function piModels(): Record<string, string> {
	const base = process.env.XDG_CONFIG_HOME || path.join(process.env.HOME || "", ".config");
	try {
		const cfg = JSON.parse(fs.readFileSync(path.join(base, "orchestration", "config.json"), "utf8"));
		const own = cfg?.pi_models;
		if (own && typeof own === "object" && !Array.isArray(own)) {
			const out = { ...PI_MODELS };
			for (const [k, v] of Object.entries(own)) if (typeof v === "string" && v) out[k] = v;
			return out;
		}
	} catch {}
	return { ...PI_MODELS };
}

export interface StageAgent {
	name: string;
	description: string;
	tools?: string[];
	model?: string;
	thinking?: string;
	systemPrompt: string;
	source: "user";
	filePath: string;
}

export function parseAgent(
	text: string,
	filePath: string,
	models: Record<string, string> = PI_MODELS,
	available: ModelCheck = () => true,
): StageAgent | null {
	const m = text.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/);
	if (!m) return null;
	const fm: Record<string, string> = {};
	for (const line of m[1].split(/\r?\n/)) {
		const kv = line.match(/^([A-Za-z0-9_-]+):\s*(.*)$/);
		if (kv) fm[kv[1]] = kv[2].trim();
	}
	if (!fm.name || !fm.description) return null;
	const tools = [
		...new Set(
			(fm.tools ?? "")
				.split(",")
				.map((t) => t.trim())
				.flatMap((t) => PI_TOOLS[t] ?? []),
		),
	];
	const tier = TIER[fm.name] ?? fm.model ?? "";
	const model = NO_MODEL.has(fm.name) ? undefined : models[MODEL_TIER[fm.name] ?? tier];
	return {
		name: `orchestration:${fm.name}`,
		description: fm.description,
		tools: tools.length ? tools : undefined,
		model: model && available(model) ? model : undefined,
		thinking: PI_THINKING[tier],
		systemPrompt: m[2].trim(),
		source: "user",
		filePath,
	};
}

export function loadStageAgents(dir = AGENTS_DIR, available: ModelCheck = () => true): StageAgent[] {
	const models = piModels();
	let names: string[];
	try {
		names = fs.readdirSync(dir).filter((n) => n.endsWith(".md")).sort();
	} catch {
		return [];
	}
	const agents: StageAgent[] = [];
	for (const n of names) {
		const file = path.join(dir, n);
		try {
			const a = parseAgent(fs.readFileSync(file, "utf8"), file, models, available);
			if (a) agents.push(a);
		} catch {}
	}
	return agents;
}

// The session's model registry, once a session started; until then every
// mapped model is offered.
let registry: { find(provider: string, id: string): unknown } | undefined;

export function modelKnown(model: string): boolean {
	if (!registry) return true;
	const slash = model.indexOf("/");
	if (slash <= 0) return false;
	try {
		return !!registry.find(model.slice(0, slash), model.slice(slash + 1));
	} catch {
		return false;
	}
}

export function registerStageAgents(): void {
	const g = globalThis as Record<symbol, unknown>;
	if (!(g[AGENT_PROVIDERS] instanceof Map)) g[AGENT_PROVIDERS] = new Map();
	(g[AGENT_PROVIDERS] as Map<string, () => StageAgent[]>).set("orchestration", () =>
		loadStageAgents(AGENTS_DIR, modelKnown),
	);
}

// ---- session reporting --------------------------------------------------------

const SOURCES: Record<string, string> = { startup: "startup", resume: "resume", fork: "resume", new: "clear", reload: "resume" };

export default function orchestration(pi: ExtensionAPI, hook = runHook) {
	registerStageAgents();

	const child = process.env.PI_SUBAGENT_CHILD === "1";
	let enabled = false;
	let sessionId: string | undefined;
	let cwd = process.cwd();
	let lastPost = 0;
	let context: string | undefined;

	pi.on("session_start", async (event: any, ctx: any) => {
		cwd = ctx?.cwd ?? process.cwd();
		if (typeof ctx?.modelRegistry?.find === "function") registry = ctx.modelRegistry;
		lastPost = 0;
		if (child) {
			sessionId = process.env[PARENT_ENV];
			enabled = !!sessionId && hasOrchState(cwd);
			return;
		}
		try {
			sessionId = ctx?.sessionManager?.getSessionId?.();
		} catch {
			sessionId = undefined;
		}
		enabled = !!sessionId && hasOrchState(cwd);
		if (!enabled) return;
		process.env[PARENT_ENV] = sessionId;
		const out = await hook({
			hook_event_name: "SessionStart",
			session_id: sessionId,
			cwd,
			source: SOURCES[event?.reason] ?? "startup",
		});
		context = out.trim() || undefined;
	});

	// The SessionStart reply ("You are the ticket orchestrator for ...") goes
	// to the model with the next prompt, as Claude adds hook output to context.
	pi.on("before_agent_start", async () => {
		if (!context) return;
		const content = context;
		context = undefined;
		return { message: { customType: "orchestration", content, display: false } };
	});

	pi.on("tool_result", async (event: any) => {
		if (!enabled || !sessionId) return;
		const now = Date.now();
		if (now - lastPost < POST_TOOL_THROTTLE_MS) return;
		lastPost = now;
		void hook({ hook_event_name: "PostToolUse", session_id: sessionId, cwd, tool_name: event?.toolName });
	});

	pi.on("agent_settled", async () => {
		if (!enabled || child || !sessionId) return;
		lastPost = 0;
		await hook({ hook_event_name: "Stop", session_id: sessionId, cwd });
	});

	pi.on("session_shutdown", async (event: any) => {
		if (!enabled || child || !sessionId) return;
		await hook({ hook_event_name: "SessionEnd", session_id: sessionId, cwd, reason: event?.reason ?? "quit" }, END_TIMEOUT_MS);
	});
}
