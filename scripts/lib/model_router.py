#!/usr/bin/env python3
"""model_router.py — score the models a project can use and pick one per task.

The OpenCode model router (setup-model-router.sh) drives this file. It does the
deterministic half of the work: the same config and the same data always give
the same assignments. The other half — deciding what the tasks are and what
matters for each — is a conversation between the user and the agent, written
down in the config.

Subcommands:

  init      CONFIG MODELS SKILLS…          write a starter config (never overwrites)
  sync      CONFIG SKILLS… [--check]       one task per practice skill, both ways
  evaluate  CONFIG MODELS CATALOG AA ROOT  score, assign, write evaluation, render
  render    CONFIG ROOT                    re-render agents/commands from the config
  show      CONFIG                         print the current assignments
  clean     CONFIG ROOT                    remove the rendered agents/commands

Inputs:

  CONFIG   .opencode/model-router.json (tasks, dimensions, providers, aliases)
  MODELS   the models OpenCode can use on this machine, already reduced to
           {providerID, id, modelID, name, variants, tools, input, context}
           by setup-model-router.sh. The raw /api/model output carries provider
           settings (API keys among them); it never reaches this script.
  CATALOG  the models.dev catalogue OpenCode uses (models.opencode.ai/api.json).
           Read for canonical_model_id: the same model under every provider.
  AA       the Artificial Analysis /data/llms/models response.
  ROOT     the project root; agents and commands go under ROOT/.opencode/.
  SKILLS   skills/ directories; their practice skills are the tasks' methods.

Scoring:

  metric     one number from Artificial Analysis, turned into a percentile
             against every model AA lists (not only the ones configured here),
             so adding a provider does not move the other scores. Lower-is-
             better metrics (price, latency) are flipped.
  dimension  a weighted mean of the metrics AA has for the model. The metrics in
             a dimension measure the same thing, so a missing one only lowers
             the dimension's coverage.
  task       a weighted mean of dimensions. A dimension with no data at all
             counts as the median (0.5): an unmeasured model neither escapes a
             speed penalty nor loses to one. Coverage reports the share of the
             task's weight that rests on real data. Hard requirements (tool
             calling, context size, input types) are checked per provider.

  The best canonical model wins; among the providers that serve it, the one
  listed first in "providers" is used.

Python 3.9, standard library only.
"""

import fnmatch
import json
import os
import re
import sys
from datetime import datetime, timezone

ATTRIBUTION = "Artificial Analysis (https://artificialanalysis.ai/)"
AGENT_PREFIX = "route-"

# ─── Metrics ──────────────────────────────────────────────────────────────────
#
# name → (paths into an AA model entry, higher is better). Several paths are
# alternatives: the first one with a value is used. AA retires benchmark
# versions (terminalbench_hard → v2_1 → v4_0); newer models only carry the newer
# one. A config can add or override metrics under "metrics".

METRICS = {
    "intelligence_index": (["evaluations.artificial_analysis_intelligence_index"], True),
    "coding_index": (["evaluations.artificial_analysis_coding_index"], True),
    "math_index": (["evaluations.artificial_analysis_math_index"], True),
    "gpqa": (["evaluations.gpqa"], True),
    "hle": (["evaluations.hle"], True),
    "mmlu_pro": (["evaluations.mmlu_pro"], True),
    "livecodebench": (["evaluations.livecodebench"], True),
    "scicode": (["evaluations.scicode"], True),
    "ifbench": (["evaluations.ifbench"], True),
    "lcr": (["evaluations.lcr"], True),
    "math_500": (["evaluations.math_500"], True),
    "aime": (["evaluations.aime_25", "evaluations.aime"], True),
    "terminalbench": (
        ["evaluations.terminalbench_v4_0", "evaluations.terminalbench_v2_1", "evaluations.terminalbench_hard"],
        True,
    ),
    "tau2": (["evaluations.tau2"], True),
    "tau_banking": (["evaluations.tau_banking"], True),
    "price": (["pricing.price_1m_blended_3_to_1"], False),
    "output_speed": (["median_output_tokens_per_second"], True),
    "latency": (["median_time_to_first_answer_token", "median_time_to_first_token_seconds"], False),
}

# AA lists each reasoning effort as its own model: claude-opus-5-5-high, …-low.
# The suffix maps to the OpenCode variant id that selects the same effort.
EFFORT_SUFFIXES = [
    ("non-reasoning", "none"),
    ("xhigh", "xhigh"),
    ("high", "high"),
    ("medium", "medium"),
    ("low", "low"),
    ("minimal", "minimal"),
    ("max", "max"),
    ("thinking", "thinking"),
    ("reasoning", "thinking"),
    ("adaptive", None),
]
# The suffix-less entry names its effort in parentheses: "Claude Opus 5.5 (Max, …)".
EFFORT_WORDS = {
    "max": "max",
    "xhigh": "xhigh",
    "high": "high",
    "medium": "medium",
    "low": "low",
    "minimal": "minimal",
    "non-reasoning": "none",
    "reasoning": "thinking",
    "thinking": "thinking",
}

# ─── Starter config ───────────────────────────────────────────────────────────

STARTER_DIMENSIONS = {
    "intelligence": {"metrics": {"intelligence_index": 1}},
    "coding": {"metrics": {"coding_index": 0.5, "livecodebench": 0.25, "scicode": 0.25}},
    "agentic": {"metrics": {"terminalbench": 0.6, "tau2": 0.4}},
    "reasoning": {"metrics": {"gpqa": 0.35, "hle": 0.35, "aime": 0.3}},
    "long-context": {"metrics": {"lcr": 1}},
    "instruction-following": {"metrics": {"ifbench": 1}},
    "cost": {"metrics": {"price": 1}},
    "speed": {"metrics": {"output_speed": 0.6, "latency": 0.4}},
}

# One task per practice skill (skills/*/SKILL.md with category: practice). The
# skill is the method; the task picks the model that runs it. A skill missing
# here still gets a task on sync, seeded from its description.
STARTER_TASKS = {
    "plan": {
        "description": "Turning a request into tracked, sized work items",
        "when": "the user wants work broken down, scoped, sized, or turned into issues or epics",
        "weights": {"reasoning": 0.35, "intelligence": 0.3, "instruction-following": 0.2, "cost": 0.15},
    },
    "architect": {
        "description": "Structural decisions: module boundaries, dependencies, integration, build versus buy",
        "when": "the user asks how a system should be structured, compares approaches, or adds a dependency",
        "weights": {"reasoning": 0.45, "intelligence": 0.25, "coding": 0.15, "long-context": 0.15},
    },
    "design": {
        "description": "Designing a feature, flow, screen or component before it is built",
        "when": "the user wants a screen, flow or component designed or changed",
        "weights": {"intelligence": 0.35, "reasoning": 0.3, "instruction-following": 0.2, "long-context": 0.15},
    },
    "develop": {
        "description": "Implementing a feature or fix across files, test-first, through a pull request",
        "when": "the user asks for code to be written, a feature added, or a change that opens a pull request",
        "weights": {"coding": 0.4, "agentic": 0.35, "intelligence": 0.15, "cost": 0.1},
    },
    "test": {
        "description": "Validating an implementation against its acceptance criteria, adversarially",
        "when": "the user wants a build checked against its acceptance criteria before it is called done",
        "weights": {"agentic": 0.35, "reasoning": 0.35, "coding": 0.3},
    },
    "debug": {
        "description": "Finding and proving the root cause of a failure: failing tests, errors, wrong behavior",
        "when": "something is broken, a test fails, or an error needs explaining and fixing",
        "weights": {"agentic": 0.35, "coding": 0.3, "reasoning": 0.25, "long-context": 0.2},
    },
    "review": {
        "description": "Reviewing code, a diff or a pull request for defects, risk and fit",
        "when": "the user asks for a review of code, a diff, a branch or a pull request",
        "weights": {"reasoning": 0.35, "coding": 0.35, "long-context": 0.1, "instruction-following": 0.1},
    },
    "quick-edit": {
        "description": "Small, fully specified edits that open no pull request: a rename, a one-line fix, a config tweak",
        "when": "the change is small and fully specified, with no design or investigation needed",
        "weights": {"speed": 0.35, "cost": 0.35, "coding": 0.3},
    },
    "docs": {
        "description": "Writing prose for people: READMEs, guides, reference docs, changelogs",
        "when": "the deliverable is documentation for people to read rather than code",
        "weights": {"instruction-following": 0.4, "intelligence": 0.3, "cost": 0.2, "speed": 0.1},
    },
}

# Weights for a skill with no starter entry. Seeded tasks are marked so the
# model-router skill asks the user to tune them.
SEED_WEIGHTS = {"intelligence": 0.4, "reasoning": 0.3, "coding": 0.3}


def starter_config(models):
    providers = sorted({m["providerID"] for m in models})
    return {
        "$comment": (
            "OpenCode model router. Edit tasks, dimensions and providers with the model-router skill; "
            "'evaluation' is written by setup-model-router.sh evaluate. Benchmark data: " + ATTRIBUTION + "."
        ),
        "providers": providers,
        "requirements": {"tools": True},
        "minCoverage": 0.5,
        "commands": True,
        "exclude": [],
        "skipSkills": [],
        "aliases": {},
        "metrics": {},
        "dimensions": STARTER_DIMENSIONS,
        "tasks": {},  # filled by sync, one per practice skill
    }


# ─── Skills ↔ tasks ───────────────────────────────────────────────────────────
#
# Two-way: every practice skill has a task, and every task has a skill.
#   skill → task  sync adds a task for a practice skill that has none (unless
#                 it is listed in skipSkills).
#   task → skill  a task whose skill does not exist is reported; the
#                 model-router skill then writes that practice skill with the
#                 user, or the user drops the task.


def read_skills(dirs):
    """{name: description} for every practice skill under the given skills/ dirs."""
    found = {}
    for d in dirs:
        if not os.path.isdir(d):
            continue
        for name in sorted(os.listdir(d)):
            path = os.path.join(d, name, "SKILL.md")
            if not os.path.isfile(path):
                continue
            with open(path) as f:
                text = f.read()
            m = re.match(r"^---\n(.*?)\n---", text, re.S)
            front = m.group(1) if m else ""
            if not re.search(r"^category:\s*practice\s*$", front, re.M):
                continue
            d_m = re.search(r'^description:\s*"(.*)"\s*$', front, re.M) or re.search(r"^description:\s*(.*)$", front, re.M)
            found.setdefault(name, d_m.group(1) if d_m else "")
    return found


def seed_task(name, description):
    """A task for a practice skill: the curated starter, or one derived from its description."""
    if name in STARTER_TASKS:
        task = dict(STARTER_TASKS[name])
        task["weights"] = dict(task["weights"])
    else:
        text = description.replace("**", "")
        sentences = [x.strip() for x in re.split(r"(?<=\.)\s+", text) if x.strip()]
        trigger = re.search(r"\bbefore (?:you )?(.+?)\.?$", sentences[0]) if sentences else None
        body = [x for x in sentences if not re.match(r"(MUST|NEVER|Skipping|Invoke once)", x)]
        task = {
            "description": (" ".join(body) or name).rstrip(". ")[:300],
            "when": ("you are about to " + trigger.group(1)) if trigger else "the work calls for the %s skill" % name,
            "weights": dict(SEED_WEIGHTS),
            "seeded": True,
        }
    return dict([("skill", name)] + list(task.items()))


def sync(config, skills):
    """Link tasks and practice skills both ways. Returns (changed, notes, orphans)."""
    tasks = config.setdefault("tasks", {})
    skip = set(config.get("skipSkills") or [])
    changed = False
    notes = []
    linked = {t.get("skill") for t in tasks.values() if t.get("skill")}
    for name in sorted(skills):
        if name in linked or name in skip:
            continue
        if name in tasks and not tasks[name].get("skill"):
            tasks[name] = dict([("skill", name)] + [(k, v) for k, v in tasks[name].items() if k != "skill"])
            notes.append("linked task '%s' to the %s skill" % (name, name))
        elif name in tasks:
            notes.append("skill '%s' has no task: the task '%s' links to '%s'" % (name, name, tasks[name]["skill"]))
            continue
        else:
            tasks[name] = seed_task(name, skills[name])
            notes.append(
                "added task '%s' for the %s skill%s"
                % (name, name, " (weights seeded: tune them)" if tasks[name].get("seeded") else "")
            )
            # The seeded weights name starter dimensions; a config that renamed
            # or dropped them gets them back rather than failing to evaluate.
            dims = config.setdefault("dimensions", {})
            for d in tasks[name]["weights"]:
                if d not in dims:
                    dims[d] = json.loads(json.dumps(STARTER_DIMENSIONS[d]))
                    notes.append("added dimension '%s' for task '%s'" % (d, name))
        changed = True
    orphans = sorted(t for t, v in tasks.items() if (v.get("skill") or "") not in skills)
    for t in orphans:
        notes.append("task '%s' has no practice skill (%s): write one with the model-router skill, or drop the task"
                     % (t, "skill '%s' not found" % tasks[t]["skill"] if tasks[t].get("skill") else "no 'skill' set"))
    return changed, notes, orphans


# ─── Helpers ─────────────────────────────────────────────────────────────────


def die(msg, code=1):
    sys.stderr.write("error: " + msg + "\n")
    sys.exit(code)


def load_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        die("missing file: " + path)
    except ValueError as e:
        die("not valid JSON: %s (%s)" % (path, e))


def write_json(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, path)


def dig(entry, path):
    cur = entry
    for key in path.split("."):
        if not isinstance(cur, dict):
            return None
        cur = cur.get(key)
    return cur if isinstance(cur, (int, float)) and not isinstance(cur, bool) else None


def norm_slug(s):
    """Model id → comparable slug: lowercase, last path segment, dashes only."""
    s = s.lower().strip().lstrip("~")
    s = s.split("/")[-1]
    s = re.sub(r"^(us|eu|jp|apac|au|ca|in|global)\.", "", s)  # Bedrock inference-profile regions
    s = re.sub(r"^[a-z0-9-]+\.(?=[a-z])", "", s)  # Bedrock vendor prefix: anthropic.claude-…
    s = re.sub(r"[._:@ ]+", "-", s)
    s = re.sub(r"-v\d+(-\d+)?$", "", s)  # Bedrock -v1:0
    s = re.sub(r"-(\d{8}|latest|preview-\d{2}-\d{2})$", "", s)  # dated or rolling releases
    return s.strip("-")


def loose_slug(slug):
    """A slug with release markers dropped, for the last-resort match."""
    s = re.sub(r"-preview(-[a-z0-9-]*)?$", "", slug)
    s = re.sub(r"-(\d{4}-\d{2}-\d{2}|\d{2}-\d{4}|\d{3})$", "", s)  # -2024-11-20, -09-2025, -001
    s = re.sub(r"-it$", "", s)  # instruction-tuned open weights (gemma-4-31b-it)
    return s


def token_key(slug):
    return " ".join(sorted(t for t in slug.split("-") if t))


def rounded(x, n=3):
    return None if x is None else round(x + 0.0, n)


# ─── Artificial Analysis index ───────────────────────────────────────────────


def split_effort(entry):
    """(base slug, OpenCode variant id or None) for an AA entry."""
    slug = entry.get("slug") or ""
    for suffix, variant in EFFORT_SUFFIXES:
        if slug.endswith("-" + suffix):
            return slug[: -len(suffix) - 1], variant
    m = re.search(r"\(([^,)]+)", entry.get("name") or "")
    word = m.group(1).strip().lower() if m else ""
    return slug, EFFORT_WORDS.get(word)


class AAIndex(object):
    def __init__(self, aa, metrics):
        entries = aa.get("data") if isinstance(aa, dict) else aa
        if not isinstance(entries, list):
            die("the Artificial Analysis response has no 'data' list")
        self.entries = entries
        self.metrics = metrics
        # base slug → {effort: entry}; the newest release wins a duplicate.
        self.by_base = {}
        self.creators = {}
        for e in entries:
            base, effort = split_effort(e)
            slot = self.by_base.setdefault(base, {})
            old = slot.get(effort)
            if old is None or (e.get("release_date") or "") > (old.get("release_date") or ""):
                slot[effort] = e
            self.creators.setdefault(base, set()).add(((e.get("model_creator") or {}).get("slug") or ""))
        self.by_tokens = {}
        self.by_loose = {}
        for base in self.by_base:
            self.by_tokens.setdefault(token_key(base), set()).add(base)
            self.by_loose.setdefault(token_key(loose_slug(base)), set()).add(base)
        # Sorted value lists per path, for percentiles against the whole population.
        self.populations = {}
        for paths, higher in metrics.values():
            for p in paths:
                if p in self.populations:
                    continue
                vals = [v for v in (dig(e, p) for e in entries) if v is not None and self._valid(p, v)]
                self.populations[p] = sorted(vals)

    @staticmethod
    def _valid(path, v):
        # AA reports 0 for an unmeasured price or speed; a real one is positive.
        return v > 0 if not path.startswith("evaluations.") else True

    def match(self, canonical):
        """AA base slug for a canonical id, or None."""
        creator = canonical.split("/")[0].lower() if "/" in canonical else ""
        slug = norm_slug(canonical)
        if slug in self.by_base:
            return slug
        for table, key in ((self.by_tokens, token_key(slug)), (self.by_loose, token_key(loose_slug(slug)))):
            hits = sorted(table.get(key, ()))
            if len(hits) > 1 and creator:
                hits = [h for h in hits if creator in self.creators.get(h, ())] or hits
            if len(hits) == 1:
                return hits[0]
        return None

    def percentile(self, path, value, higher):
        pop = self.populations.get(path) or []
        if not pop:
            return None
        below = sum(1 for v in pop if v < value)
        equal = sum(1 for v in pop if v == value)
        p = (below + 0.5 * equal) / len(pop)
        return p if higher else 1.0 - p

    def metric(self, entry, name):
        paths, higher = self.metrics[name]
        for p in paths:
            v = dig(entry, p)
            if v is not None and self._valid(p, v):
                return self.percentile(p, v, higher)
        return None


def metric_table(config):
    table = dict(METRICS)
    for name, spec in (config.get("metrics") or {}).items():
        if isinstance(spec, dict) and spec.get("paths"):
            table[name] = (list(spec["paths"]), bool(spec.get("higherIsBetter", True)))
    for dim in (config.get("dimensions") or {}).values():
        for name in (dim.get("metrics") or {}):
            if name not in table:  # a bare AA evaluation key, e.g. "aime_25"
                path = name if "." in name else "evaluations." + name
                table[name] = ([path], True)
    return table


# ─── Scoring ──────────────────────────────────────────────────────────────────


def weighted(parts):
    """parts: [(weight, value or None)] → (mean over present, share of weight present)."""
    total = sum(w for w, _ in parts if w > 0)
    have = [(w, v) for w, v in parts if w > 0 and v is not None]
    if total <= 0 or not have:
        return None, 0.0
    got = sum(w for w, _ in have)
    return sum(w * v for w, v in have) / got, got / total


def dimension_scores(index, entry, dimensions):
    out = {}
    for name, dim in dimensions.items():
        parts = [(float(w), index.metric(entry, m)) for m, w in (dim.get("metrics") or {}).items()]
        out[name] = weighted(parts)
    return out


UNMEASURED = 0.5  # the median: what a dimension with no data counts as


def task_score(dims, weights):
    parts = []
    coverage_parts = []
    for name, w in weights.items():
        score, cov = dims.get(name, (None, 0.0))
        parts.append((float(w), UNMEASURED if score is None else score))
        coverage_parts.append((float(w), cov))
    score, _ = weighted(parts)
    coverage, _ = weighted(coverage_parts)
    return score, coverage or 0.0


def meets(model, req):
    """'' when the deployment meets the requirements, else the reason it does not."""
    if req.get("tools", True) and not model.get("tools"):
        return "no tool calling"
    ctx = req.get("minContext")
    if ctx and (model.get("context") or 0) < ctx:
        return "context %s < %s" % (model.get("context") or 0, ctx)
    for kind in req.get("input") or []:
        if kind not in (model.get("input") or []):
            return "no %s input" % kind
    return ""


def canonical_for(model, catalog, aliases):
    ref = "%s/%s" % (model["providerID"], model["id"])
    if ref in aliases and isinstance(aliases[ref], str) and "/" in aliases[ref]:
        return aliases[ref]
    prov = (catalog.get(model["providerID"]) or {}).get("models") or {}
    for key in (model["id"], model.get("modelID")):
        entry = prov.get(key) if key else None
        if entry and entry.get("canonical_model_id"):
            return entry["canonical_model_id"]
    # Unknown to the catalogue (custom provider): the id is the best identity left.
    return "%s/%s" % (model["providerID"], norm_slug(model.get("modelID") or model["id"]))


def evaluate(config, models, catalog, aa):
    providers = list(config.get("providers") or [])
    if not providers:
        die("'providers' is empty in the config: list the providers to evaluate, in priority order")
    rank = {p: i for i, p in enumerate(providers)}
    aliases = config.get("aliases") or {}
    exclude = config.get("exclude") or []
    dimensions = config.get("dimensions") or {}
    tasks = config.get("tasks") or {}
    if not tasks:
        die("'tasks' is empty in the config")
    for tname, task in tasks.items():
        for d in (task.get("weights") or {}):
            if d not in dimensions:
                die("task '%s' weighs unknown dimension '%s'" % (tname, d))
    base_req = config.get("requirements") or {}
    min_cov = float(config.get("minCoverage", 0.5))
    index = AAIndex(aa, metric_table(config))

    warnings = []
    available = sorted({m["providerID"] for m in models})
    for p in providers:
        if p not in available:
            warnings.append("provider '%s' is listed but not available on this machine; its models were not evaluated" % p)

    # canonical → {aa, deployments}
    unmatched = {}
    candidates = []  # one per (deployment, effort)
    for m in sorted(models, key=lambda x: (rank.get(x["providerID"], 99), x["providerID"], x["id"])):
        if m["providerID"] not in rank:
            continue
        ref = "%s/%s" % (m["providerID"], m["id"])
        canonical = canonical_for(m, catalog, aliases)
        if any(fnmatch.fnmatch(ref, pat) or fnmatch.fnmatch(canonical, pat) for pat in exclude):
            continue
        if meets(m, base_req):
            continue  # cannot serve any task (an embedding or image model, say)
        if canonical in aliases:
            base = aliases[canonical]  # an AA base slug, or null to skip on purpose
            if base is None:
                continue
        else:
            base = index.match(canonical)
        if base is None or base not in index.by_base:
            unmatched.setdefault(canonical, []).append(ref)
            continue
        efforts = index.by_base[base]
        variants = set(m.get("variants") or [])
        picks = [(eff, e) for eff, e in sorted(efforts.items(), key=lambda kv: kv[0] or "") if eff and eff in variants]
        if not picks:
            # No variant to pin the effort with: the provider's default effort,
            # scored with the suffix-less AA entry (or the only one there is).
            entry = efforts.get(None) or efforts[sorted(efforts, key=lambda k: k or "")[0]]
            picks = [(None, entry)]
        for eff, entry in picks:
            candidates.append({
                "ref": ref + ("#" + eff if eff else ""),
                "provider": m["providerID"],
                "canonical": canonical,
                "variant": eff,
                "aa": entry.get("slug"),
                "model": m,
                "dims": dimension_scores(index, entry, dimensions),
            })

    assignments = {}
    for tname in sorted(tasks):
        task = tasks[tname]
        req = dict(base_req)
        req.update(task.get("require") or {})
        cov_floor = float(task.get("minCoverage", min_cov))
        weights = task.get("weights") or {}
        scored = []
        rejected = 0
        for c in candidates:
            if meets(c["model"], req):
                rejected += 1
                continue
            score, cov = task_score(c["dims"], weights)
            if score is None or cov < cov_floor:
                continue
            scored.append((round(score, 6), c, cov))
        # Best score first; on a tie (the same model under several providers),
        # the provider listed first; then the reference, for a stable order.
        scored.sort(key=lambda t: (-t[0], rank.get(t[1]["provider"], 99), t[1]["ref"]))
        if not scored:
            assignments[tname] = {"model": None, "reason": "no candidate meets the requirements and coverage floor"}
            continue
        best_score, best, best_cov = scored[0]
        runner = next((t for t in scored if t[1]["canonical"] != best["canonical"]), None)
        a = {
            "model": best["ref"],
            "canonical": best["canonical"] + ("#" + best["variant"] if best["variant"] else ""),
            "benchmark": best["aa"],
            "score": rounded(best_score),
            "coverage": rounded(best_cov, 2),
            "providers": sorted(
                {t[1]["provider"] for t in scored if t[1]["canonical"] == best["canonical"] and t[1]["variant"] == best["variant"]},
                key=lambda p: rank.get(p, 99),
            ),
        }
        if runner:
            a["runnerUp"] = {"model": runner[1]["ref"], "score": rounded(runner[0]), "coverage": rounded(runner[2], 2)}
        assignments[tname] = a

    # Candidate table: one row per canonical model + effort, with its providers.
    rows = {}
    for c in candidates:
        key = c["canonical"] + ("#" + c["variant"] if c["variant"] else "")
        row = rows.get(key)
        if row is None:
            row = rows[key] = {
                "model": key,
                "benchmark": c["aa"],
                "dimensions": {d: rounded(s) for d, (s, _) in sorted(c["dims"].items())},
                "coverage": {d: rounded(cv, 2) for d, (_, cv) in sorted(c["dims"].items())},
                "deployments": [],
            }
        row["deployments"].append(c["ref"])

    return {
        "at": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
        "source": ATTRIBUTION,
        "assignments": assignments,
        "candidates": [rows[k] for k in sorted(rows)],
        "unmatched": [{"canonical": k, "deployments": v} for k, v in sorted(unmatched.items())],
        "warnings": warnings,
    }


# ─── Render ───────────────────────────────────────────────────────────────────


def yaml_str(s):
    return json.dumps(s, ensure_ascii=False)  # a JSON string is a valid YAML scalar


def agent_name(task):
    return AGENT_PREFIX + task


def render(config, root, previous):
    """Write one subagent (and command) per assigned task. Returns the paths written.

    Only files this router wrote before (`previous`) are overwritten or removed;
    a file someone else put at the same path is left alone.
    """
    tasks = config.get("tasks") or {}
    ev = config.get("evaluation") or {}
    assigned = ev.get("assignments") or {}
    agents_dir = os.path.join(root, ".opencode", "agents")
    commands_dir = os.path.join(root, ".opencode", "commands")
    previous = set(previous or [])
    written = []
    notes = []

    def put(rel, content):
        path = os.path.join(root, rel)
        if os.path.exists(path) and rel not in previous:
            notes.append("kept %s: it exists and the router did not write it" % rel)
            return
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(content)
        written.append(rel)

    for tname in sorted(tasks):
        a = assigned.get(tname) or {}
        if not a.get("model"):
            continue
        task = tasks[tname]
        name = agent_name(tname)
        desc = (task.get("description") or tname).rstrip(". ")
        when = (task.get("when") or "").rstrip(". ")
        text = desc + "."
        if when:
            text += " Delegate here when " + when + "."
        if task.get("skill"):
            text += " Follows the %s skill." % task["skill"]
        text += " Runs on %s, chosen for this task by the model router." % a["model"]
        # No body: a body would replace OpenCode's default system prompt.
        put(
            os.path.join(".opencode", "agents", name + ".md"),
            "---\ndescription: %s\nmode: subagent\nmodel: %s\n---\n" % (yaml_str(text), yaml_str(a["model"])),
        )
        if config.get("commands", True):
            put(
                os.path.join(".opencode", "commands", name + ".md"),
                "---\ndescription: %s\nagent: %s\nsubagent: true\n---\n$ARGUMENTS\n"
                % (yaml_str("%s (on %s)" % (desc, a["model"])), yaml_str(name)),
            )

    for rel in sorted(previous - set(written)):
        path = os.path.join(root, rel)
        if os.path.isfile(path):
            os.remove(path)
            notes.append("removed %s" % rel)
    for d in (agents_dir, commands_dir):
        if os.path.isdir(d) and not os.listdir(d):
            os.rmdir(d)
    return sorted(written), notes


# ─── Report ──────────────────────────────────────────────────────────────────


def report(config, before):
    ev = config.get("evaluation") or {}
    old = (before or {}).get("assignments") or {}
    lines = []
    width = max([len(t) for t in (ev.get("assignments") or {})] + [4])
    for tname, a in sorted((ev.get("assignments") or {}).items()):
        if not a.get("model"):
            lines.append("  %-*s  — %s" % (width, tname, a.get("reason", "unassigned")))
            continue
        prev = (old.get(tname) or {}).get("model")
        change = "" if prev in (None, a["model"]) else "   (was %s)" % prev
        lines.append("  %-*s  %s  score %.3f  coverage %.2f%s" % (width, tname, a["model"], a["score"], a["coverage"], change))
        ru = a.get("runnerUp")
        if ru:
            lines.append("  %-*s    runner-up %s  %.3f" % (width, "", ru["model"], ru["score"]))
    unmatched = ev.get("unmatched") or []
    if unmatched:
        lines.append("  ? %d model(s) have no Artificial Analysis match and were not scored:" % len(unmatched))
        for u in unmatched[:12]:
            lines.append("      %s  (%s)" % (u["canonical"], ", ".join(u["deployments"])))
        if len(unmatched) > 12:
            lines.append("      … the full list is under evaluation.unmatched")
        lines.append("    Map one with aliases: {\"<canonical>\": \"<AA slug>\"}, or null to skip it.")
    for w in ev.get("warnings") or []:
        lines.append("  ! " + w)
    lines.append("  Benchmark data: " + ATTRIBUTION)
    return "\n".join(lines)


# ─── CLI ─────────────────────────────────────────────────────────────────────


def main(argv):
    if len(argv) < 2:
        die(__doc__.strip().split("\n\n")[1])
    cmd = argv[1]
    if cmd == "init":
        cfg_path, models_path, skill_dirs = argv[2], argv[3], argv[4:]
        if os.path.exists(cfg_path):
            print("kept %s" % cfg_path)
            return 0
        config = starter_config(load_json(models_path))
        sync(config, read_skills(skill_dirs))
        write_json(cfg_path, config)
        print("wrote %s (%d tasks, one per practice skill)" % (cfg_path, len(config["tasks"])))
        return 0
    if cmd == "sync":
        args = [a for a in argv[2:] if a != "--check"]
        check = "--check" in argv[2:]
        cfg_path, skill_dirs = args[0], args[1:]
        config = load_json(cfg_path)
        changed, notes, orphans = sync(config, read_skills(skill_dirs))
        for n in notes:
            print("  " + n)
        if check:
            return 3 if (changed or orphans) else 0
        if changed:
            write_json(cfg_path, config)
        return 0
    if cmd == "evaluate":
        cfg_path, models_path, cat_path, aa_path, root = argv[2:7]
        config = load_json(cfg_path)
        before = config.get("evaluation") or {}
        ev = evaluate(config, load_json(models_path), load_json(cat_path), load_json(aa_path))
        config["evaluation"] = ev
        written, notes = render(config, root, before.get("generated"))
        ev["generated"] = written
        write_json(cfg_path, config)
        print(report(config, before))
        for n in notes:
            print("  " + n)
        return 0
    if cmd == "render":
        cfg_path, root = argv[2], argv[3]
        config = load_json(cfg_path)
        ev = config.get("evaluation") or {}
        written, notes = render(config, root, ev.get("generated"))
        if ev:
            ev["generated"] = written
            write_json(cfg_path, config)
        for n in notes:
            print("  " + n)
        print("  %d file(s) rendered" % len(written))
        return 0
    if cmd == "show":
        print(report(load_json(argv[2]), None))
        return 0
    if cmd == "clean":
        # Uninstall: remove the generated agents and commands, keep the config.
        cfg_path, root = argv[2], argv[3]
        if not os.path.exists(cfg_path):
            return 0
        config = load_json(cfg_path)
        ev = config.get("evaluation") or {}
        _, notes = render({"tasks": {}}, root, ev.get("generated"))
        if ev.get("generated"):
            ev["generated"] = []
            write_json(cfg_path, config)
        for n in notes:
            print("  " + n)
        return 0
    die("unknown subcommand: " + cmd)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
