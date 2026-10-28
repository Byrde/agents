// byrde-agents — OpenCode 2 plugin, installed by .agents/scripts/opencode/init.sh.
//
// Three jobs, each on a hook that OpenCode 2.2 calls:
//
//   skill method      session.hook("context"): when the session runs a practice
//                     agent (plan, develop, …), add that skill's SKILL.md to the
//                     system prompt. The agent files carry no body, because a
//                     body replaces OpenCode's default system prompt.
//   memory            session.hook("context"): tell every agent where project
//                     memory lives, and give it the index (memory/MEMORY.md).
//   rules re-injection tool.hook("execute.after"): every Nth tool call, append
//                     the lead rule to the tool result the model reads.
//
// Allow-all is not here: it is a "permissions" rule in .opencode/opencode.json.
//
// Settings: ../byrde-agents.json (written by init.sh).
// Cadence: BYRDE_RULES_REINJECT_EVERY (default 12 tool calls, 0 disables).
//
// Generated file. Edit the source in .agents/scripts/opencode/plugin/, then re-run init.sh.

import { readFileSync, readdirSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const HERE = dirname(fileURLToPath(import.meta.url))

function readJson(path) {
  try {
    return JSON.parse(readFileSync(path, "utf8"))
  } catch {
    return {}
  }
}

function readText(path) {
  try {
    return readFileSync(path, "utf8")
  } catch {
    return undefined
  }
}

// Read on every call, so a re-run of init takes effect without a restart.
const settings = () => readJson(join(HERE, "..", "byrde-agents.json"))

function stripFrontmatter(text) {
  const match = text.match(/^---\r?\n[\s\S]*?\r?\n---\r?\n/)
  return (match ? text.slice(match[0].length) : text).trim()
}

function cadence() {
  const raw = process.env.BYRDE_RULES_REINJECT_EVERY ?? ""
  return /^[0-9]+$/.test(raw) ? Number(raw) : 12
}

// ─── Skill method ────────────────────────────────────────────────────────────

function skillNote(s, agent) {
  if (!agent || !s.skillsDir || !(s.generated ?? []).includes(`.opencode/agents/${agent}.md`)) return undefined
  const text = readText(join(s.skillsDir, agent, "SKILL.md"))
  if (!text) return undefined
  return (
    `<practice-skill name="${agent}">\n` +
    `You are the ${agent} agent. Follow this method for the work you are given.\n\n` +
    stripFrontmatter(text) +
    "\n</practice-skill>"
  )
}

// ─── Memory ──────────────────────────────────────────────────────────────────

function memoryNote(s) {
  if (!s.memoryDir) return undefined
  const index = readText(join(s.memoryDir, "MEMORY.md"))
  let text =
    "<project-memory>\n" +
    `Project memory lives in ${s.memoryDir}: one file per fact, indexed in MEMORY.md. ` +
    "Recall the relevant memories before you assert why something is the way it is. " +
    "Write a memory in the same turn you learn something that qualifies (the memory rule says what does), " +
    "then add a one-line pointer to MEMORY.md.\n"
  text += index ? `\nMEMORY.md:\n${index.trim()}\n` : "\nMEMORY.md does not exist yet. Create it with the first memory.\n"
  return text + "</project-memory>"
}

// ─── Rules re-injection ──────────────────────────────────────────────────────

// global.md leads, the rest are named. Same short form as reinject-rules.sh.
function reinjection(s, n) {
  if (!s.rulesDir) return undefined
  let files
  try {
    files = readdirSync(s.rulesDir).filter((f) => f.endsWith(".md")).sort()
  } catch {
    return undefined
  }
  const lead = files.includes("global.md") ? "global.md" : files[0]
  const body = lead && readText(join(s.rulesDir, lead))
  if (!body) return undefined
  const others = files.filter((f) => f !== lead)
  let text = `<project-rules-reinjected after-tool-calls="${n}">\n`
  text += "These rules are binding. Tool output has pushed them out of view. Read them again before your next step.\n\n"
  text += stripFrontmatter(body) + "\n"
  if (others.length) {
    text += `\nThe other rules are in .agents/rules/: ${others.join(", ")}.\n`
    text += "Read one when your next step touches what it covers.\n"
  }
  return text + "</project-rules-reinjected>"
}

// Per-session tool-call counter. Nothing fires at the start of a session: the
// rules are already in context there.
const calls = new Map()
function tick(sessionID) {
  const every = cadence()
  if (every === 0) return undefined
  const n = (calls.get(sessionID) ?? 0) + 1
  calls.set(sessionID, n)
  return n % every === 0 ? reinjection(settings(), n) : undefined
}

// ─── Plugin ──────────────────────────────────────────────────────────────────

export default {
  id: "byrde-agents",

  async setup(ctx) {
    await ctx.session.hook("context", (event) => {
      const s = settings()
      for (const text of [skillNote(s, event.agent), memoryNote(s)]) {
        if (text) event.system.push({ type: "text", text })
      }
    })

    await ctx.tool.hook("execute.after", (event) => {
      if (event.status !== "completed" || !event.result) return
      const text = tick(event.sessionID)
      if (!text) return
      event.result.content = [...(event.result.content ?? []), { type: "text", text }]
    })
  },
}
