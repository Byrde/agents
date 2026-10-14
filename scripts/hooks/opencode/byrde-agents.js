// byrde-agents — OpenCode plugin, installed by .agents/scripts/init.sh.
//
// OpenCode has no shell-command hooks. Its hooks are plugins, so this file is
// the OpenCode side of what the other harnesses get from settings files and
// scripts/hooks/reinject-rules.sh:
//
//   rules re-injection  every Nth tool call, append the lead rule to the tool
//                       result the model reads (the stream that buries the
//                       rules brings them back)
//   rules on compaction hand the lead rule to the compaction request, so the
//                       summary that replaces the history still carries it
//   allow-all           approve every permission prompt (with "permission":
//                       "allow" in .opencode/opencode.json)
//   model routing       with the model router set up (OpenCode 2): tell the
//                       main agent which route-<task> subagent takes which
//                       kind of request, so it delegates without being asked;
//                       and when it loads a routed practice skill itself,
//                       redirect that work to the skill's subagent
//
// One default export serves both plugin APIs: OpenCode 2 calls setup(ctx),
// OpenCode 1 (1.18.29 and newer) calls server(input). No imports beyond Node
// built-ins, so it runs without installing @opencode/plugin.
//
// Settings: ../byrde-agents.json (written by init.sh).
// Routing: ../model-router.json (written by setup-model-router.sh).
// Cadence: BYRDE_RULES_REINJECT_EVERY (default 12 tool calls, 0 disables).
//
// Generated file. Edit the source in .agents/scripts/hooks/opencode/, then re-run init.sh.

import { readFileSync, readdirSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const HERE = dirname(fileURLToPath(import.meta.url))

function loadSettings() {
  try {
    return JSON.parse(readFileSync(join(HERE, "..", "byrde-agents.json"), "utf8"))
  } catch {
    return {}
  }
}

const settings = loadSettings()

// A malformed cadence falls back to the default instead of failing every call.
function cadence() {
  const raw = process.env.BYRDE_RULES_REINJECT_EVERY ?? ""
  return /^[0-9]+$/.test(raw) ? Number(raw) : 12
}

function stripFrontmatter(text) {
  const match = text.match(/^---\r?\n[\s\S]*?\r?\n---\r?\n/)
  return (match ? text.slice(match[0].length) : text).replace(/^\s+/, "")
}

// global.md leads, the rest are named. Same short form as reinject-rules.sh.
function readRules() {
  const dir = settings.rulesDir
  if (!dir) return undefined
  let files
  try {
    files = readdirSync(dir).filter((f) => f.endsWith(".md")).sort()
  } catch {
    return undefined
  }
  const lead = files.includes("global.md") ? "global.md" : files[0]
  if (!lead) return undefined
  let body
  try {
    body = stripFrontmatter(readFileSync(join(dir, lead), "utf8"))
  } catch {
    return undefined
  }
  return { body, others: files.filter((f) => f !== lead) }
}

function reinjection(n) {
  const rules = readRules()
  if (!rules) return undefined
  let text = `<project-rules-reinjected after-tool-calls="${n}">\n`
  text += "These rules are binding. Tool output has pushed them out of view. Read them again before your next step.\n\n"
  text += rules.body.replace(/\s+$/, "") + "\n"
  if (rules.others.length) {
    text += `\nThe other rules are in .agents/rules/: ${rules.others.join(", ")}.\n`
    text += "Read one when your next step touches what it covers.\n"
  }
  return text + "</project-rules-reinjected>"
}

function compactionNote() {
  const rules = readRules()
  if (!rules) return undefined
  return (
    "<project-rules>\nThe project rules below are binding for the rest of this session. " +
    "Keep them, unchanged in meaning, in the summary you write.\n\n" +
    rules.body.replace(/\s+$/, "") +
    "\n</project-rules>"
  )
}

// Per-session tool-call counter. Nothing fires at the start of a session: the
// rules are already in context there.
const calls = new Map()
function tick(sessionID) {
  const every = cadence()
  if (every === 0) return undefined
  const n = (calls.get(sessionID) ?? 0) + 1
  calls.set(sessionID, n)
  return n % every === 0 ? reinjection(n) : undefined
}

// ─── Model routing ───────────────────────────────────────────────────────────

const ROUTE_PREFIX = "route-"

// The routed tasks, read on every call, so a re-evaluation takes effect at
// once (OpenCode still needs a restart to load new subagent files). Only tasks
// whose subagent the router wrote: a file someone else owns at that path is
// not pinned to the assigned model.
function routedTasks() {
  let config
  try {
    config = JSON.parse(readFileSync(join(HERE, "..", "model-router.json"), "utf8"))
  } catch {
    return []
  }
  const tasks = config.tasks ?? {}
  const assigned = config.evaluation?.assignments ?? {}
  const written = new Set(config.evaluation?.generated ?? [])
  return Object.keys(tasks)
    .sort()
    .filter((task) => assigned[task]?.model && written.has(`.opencode/agents/${ROUTE_PREFIX}${task}.md`))
    .map((task) => ({
      agent: ROUTE_PREFIX + task,
      skill: tasks[task].skill,
      what: (tasks[task].when || tasks[task].description || task).replace(/[.\s]+$/, ""),
      model: assigned[task].model,
    }))
}

function routingNote() {
  const rows = routedTasks().map(
    (t) => `- ${t.agent}${t.skill ? ` (${t.skill} skill)` : ""}: ${t.what} (${t.model})`,
  )
  if (!rows.length) return undefined
  return (
    "<model-routing>\n" +
    "This project routes work by task. When a request matches a task below, hand it to that subagent " +
    "with the subagent tool instead of doing it yourself: it runs on the model chosen for that kind of work. " +
    "Give it the full request and the context it needs, then relay its result. Each task follows a practice " +
    "skill: when that skill's trigger applies, delegate instead of invoking the skill yourself, and tell the " +
    "subagent to invoke it. Do the work yourself when no task matches or the user asks you to.\n\n" +
    rows.join("\n") +
    "\n</model-routing>"
  )
}

// The main agent loaded a practice skill that has a routed task: the work
// belongs to that task's subagent. Said at the moment the skill loads, because
// the rules' "invoke the skill" otherwise wins over the routing table.
function skillRedirect(input) {
  const id = input?.id ?? input?.name
  if (!id) return undefined
  const t = routedTasks().find((task) => task.skill === id)
  if (!t) return undefined
  return (
    `<model-routing>\nThe ${id} skill is routed: its work runs on ${t.model}. Do not follow the procedure ` +
    `above yourself. Hand the request to the ${t.agent} subagent with the subagent tool, with the context it ` +
    `needs, and tell it to invoke the ${id} skill. Then relay its result.\n</model-routing>`
  )
}

function appendText(result, text) {
  const content = result.content
  const parts =
    typeof content === "string"
      ? [{ type: "text", text: content }]
      : content && content.length
        ? [...content]
        : result.output === undefined
          ? []
          : [{ type: "text", text: typeof result.output === "string" ? result.output : JSON.stringify(result.output) }]
  parts.push({ type: "text", text })
  result.content = parts
}

// ─── Plugin ──────────────────────────────────────────────────────────────────

export default {
  id: "byrde-agents",

  // OpenCode 2.
  async setup(ctx) {
    await ctx.tool.hook("execute.after", (event) => {
      if (event.status !== "completed") return
      if (event.tool === "skill" && !String(event.agent ?? "").startsWith(ROUTE_PREFIX)) {
        const redirect = skillRedirect(event.input)
        if (redirect) appendText(event.result, redirect)
      }
      const text = tick(event.sessionID)
      if (text) appendText(event.result, text)
    })

    if (settings.allowAll) {
      // A deny rule ends evaluation before this hook runs, so this only
      // turns "ask" into "allow".
      await ctx.permission.hook("evaluate", (event) => {
        if (event.effect === "ask") event.effect = "allow"
      })
    }

    await ctx.session.hook("compaction", (event) => {
      const text = compactionNote()
      if (text) event.system.push({ type: "text", text })
    })

    // Only an agent that can delegate gets the table; a routed subagent does
    // the work it was handed.
    await ctx.session.hook("context", (event) => {
      if (String(event.agent ?? "").startsWith(ROUTE_PREFIX)) return
      if (event.tools && !("subagent" in event.tools)) return
      const text = routingNote()
      if (text) event.system.push({ type: "text", text })
    })
  },

  // OpenCode 1.
  async server() {
    return {
      "tool.execute.after": async (input, output) => {
        const text = tick(input.sessionID)
        if (!text) return
        // Built-in tools return a string; MCP tools return the raw MCP result.
        if (typeof output.output === "string") output.output += "\n\n" + text
        else if (Array.isArray(output.content)) output.content.push({ type: "text", text })
      },
      "permission.ask": async (_input, output) => {
        if (settings.allowAll) output.status = "allow"
      },
      "experimental.session.compacting": async (_input, output) => {
        const text = compactionNote()
        if (text) output.context.push(text)
      },
    }
  },
}
