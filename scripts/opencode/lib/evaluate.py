#!/usr/bin/env python3
"""evaluate.py — one OpenCode agent per practice skill, each on the model that suits it.

scripts/opencode/init.sh drives this file. It does the deterministic half of
the work: the same skills and the same data always give the same agents.

Subcommands:

  run    --skills DIR --root ROOT --state FILE [--models F --catalog F --aa F]
         Score the models, then write ROOT/.opencode/agents/<skill>.md for
         every practice skill. Without --models or --aa, or when the only
         provider is OpenCode's built-in one, every agent inherits the model of
         the session that runs it.
  clean  --root ROOT --state FILE
         Remove the agent files that `run` wrote.

Inputs:

  MODELS   the models OpenCode can use here, reduced by init.sh to
           {providerID, id, modelID, variants, tools, input, context, cost}.
           The raw /api/model output carries provider settings (API keys
           among them); it never reaches this script.
  CATALOG  the models.dev catalogue (models.opencode.ai/api.json). Read for
           canonical_model_id: the same model under every provider.
  AA       the Artificial Analysis /data/llms/models response.
  STATE    .opencode/byrde-agents.json. Records the files written, so a file
           somebody else put at the same path is never overwritten or removed.

Scoring:

  metric     one number from Artificial Analysis, turned into a percentile
             against every model AA lists, so adding a provider does not move
             the other scores. Lower-is-better metrics (price, latency) are
             flipped. Cost is the deployment's own price when OpenCode lists
             one (a free model scores best), else the AA list price.
  dimension  a weighted mean of the metrics the model has.
  task       a weighted mean of the dimensions in the skill's profile. A
             dimension with no data counts as the median (0.5). Every profile
             weighs cost.

  The best canonical model wins. On a tie, the deployment listed first in the
  models file wins.

Python 3.9, standard library only.
"""

import argparse
import json
import os
import re
import sys

ATTRIBUTION = "Artificial Analysis (https://artificialanalysis.ai/)"

# OpenCode's own provider. It is always present, so it does not count as a
# configured provider: alone, it means a bare session.
BUILTIN_PROVIDER = "opencode"

MIN_COVERAGE = 0.5
UNMEASURED = 0.5  # the median: what a dimension with no data counts as

# ─── Metrics ─────────────────────────────────────────────────────────────────
#
# name → (paths into an AA model entry, higher is better). The first path with
# a value is used: AA retires benchmark versions, and newer models only carry
# the newer one.

METRICS = {
    "intelligence_index": (["evaluations.artificial_analysis_intelligence_index"], True),
    "coding_index": (["evaluations.artificial_analysis_coding_index"], True),
    "gpqa": (["evaluations.gpqa"], True),
    "hle": (["evaluations.hle"], True),
    "livecodebench": (["evaluations.livecodebench"], True),
    "scicode": (["evaluations.scicode"], True),
    "ifbench": (["evaluations.ifbench"], True),
    "lcr": (["evaluations.lcr"], True),
    "aime": (["evaluations.aime_25", "evaluations.aime"], True),
    "terminalbench": (
        ["evaluations.terminalbench_v4_0", "evaluations.terminalbench_v2_1", "evaluations.terminalbench_hard"],
        True,
    ),
    "tau2": (["evaluations.tau2"], True),
    "price": (["pricing.price_1m_blended_3_to_1"], False),
    "output_speed": (["median_output_tokens_per_second"], True),
    "latency": (["median_time_to_first_answer_token", "median_time_to_first_token_seconds"], False),
}

DIMENSIONS = {
    "intelligence": {"intelligence_index": 1},
    "coding": {"coding_index": 0.5, "livecodebench": 0.25, "scicode": 0.25},
    "agentic": {"terminalbench": 0.6, "tau2": 0.4},
    "reasoning": {"gpqa": 0.35, "hle": 0.35, "aime": 0.3},
    "long-context": {"lcr": 1},
    "instruction-following": {"ifbench": 1},
    "cost": {"price": 1},
    "speed": {"output_speed": 0.6, "latency": 0.4},
}

# What a kind of work needs from a model. Skills with the same needs share a
# profile, so they land on the same model instead of whichever one a
# benchmark-noise margin favours.
PROFILES = {
    "deep": {"reasoning": 0.35, "intelligence": 0.25, "long-context": 0.15, "instruction-following": 0.1, "cost": 0.15},
    "build": {"coding": 0.35, "agentic": 0.3, "reasoning": 0.1, "cost": 0.25},
    "fast": {"speed": 0.3, "cost": 0.4, "coding": 0.3},
    "write": {"instruction-following": 0.4, "intelligence": 0.25, "cost": 0.25, "speed": 0.1},
}

# The shipped practice skills: their profile, and the description OpenCode
# shows when it decides which agent takes a request. A skill missing here
# gets the "deep" profile and its own description.
SKILLS = {
    "plan": ("deep", "Turns a request into tracked, sized work items. Use it when the user wants work broken down, scoped, sized, or turned into issues or epics."),
    "architect": ("deep", "Makes structural decisions: module boundaries, dependencies, integration, build versus buy. Use it when the user asks how a system should be structured, compares approaches, or adds a dependency."),
    "design": ("deep", "Designs a feature, flow, screen or component before it is built. Use it when the user wants a screen, flow or component designed or changed."),
    "review": ("deep", "Reviews code, a diff or a pull request for defects, risk and fit. Use it when the user asks for a review of code, a diff, a branch or a pull request."),
    "develop": ("build", "Implements a feature or fix test-first, through a pull request. Use it when the user asks for code to be written, a feature added, or a change that opens a pull request."),
    "test": ("build", "Validates an implementation against its acceptance criteria, adversarially. Use it when a build must be checked against its acceptance criteria before it is called done."),
    "debug": ("build", "Finds and proves the root cause of anything reported as broken, before it is fixed. Use it when something behaves wrongly: a failing test, an error, a regression, a bug report."),
    "quick-edit": ("fast", "Makes small, fully specified edits that open no pull request: a rename, a config tweak, a formatting change. A reported bug goes to debug first."),
    "docs": ("write", "Writes prose for people: READMEs, guides, reference docs, changelogs. Use it when the deliverable is documentation rather than code."),
}
DEFAULT_PROFILE = "deep"

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
EFFORT_WORDS = {
    "max": "max", "xhigh": "xhigh", "high": "high", "medium": "medium", "low": "low",
    "minimal": "minimal", "non-reasoning": "none", "reasoning": "thinking", "thinking": "thinking",
}

# ─── Helpers ─────────────────────────────────────────────────────────────────


def die(msg):
    sys.stderr.write("error: " + msg + "\n")
    sys.exit(1)


def load_json(path, default=None):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        if default is not None:
            return default
        die("missing file: " + path)
    except ValueError as e:
        die("not valid JSON: %s (%s)" % (path, e))


def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
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
    s = re.sub(r"-preview(-[a-z0-9-]*)?$", "", slug)
    s = re.sub(r"-(\d{4}-\d{2}-\d{2}|\d{2}-\d{4}|\d{3})$", "", s)
    s = re.sub(r"-it$", "", s)
    return s


def token_key(slug):
    return " ".join(sorted(t for t in slug.split("-") if t))


def rounded(x, n=3):
    return None if x is None else round(x + 0.0, n)


def yaml_str(s):
    return json.dumps(s, ensure_ascii=False)  # a JSON string is a valid YAML scalar


# ─── Skills ──────────────────────────────────────────────────────────────────


def read_skills(skills_dir):
    """{name: description} for every practice skill (category: practice)."""
    found = {}
    if not os.path.isdir(skills_dir):
        die("skills directory not found: " + skills_dir)
    for name in sorted(os.listdir(skills_dir)):
        path = os.path.join(skills_dir, name, "SKILL.md")
        if not os.path.isfile(path):
            continue
        with open(path) as f:
            text = f.read()
        m = re.match(r"^---\n(.*?)\n---", text, re.S)
        front = m.group(1) if m else ""
        if not re.search(r"^category:\s*practice\s*$", front, re.M):
            continue
        d = re.search(r'^description:\s*"(.*)"\s*$', front, re.M) or re.search(r"^description:\s*(.*)$", front, re.M)
        found[name] = (d.group(1) if d else name).replace("**", "")
    return found


def skill_profile(name):
    return SKILLS[name][0] if name in SKILLS else DEFAULT_PROFILE


def skill_description(name, own):
    return SKILLS[name][1] if name in SKILLS else own


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
    def __init__(self, aa):
        entries = aa.get("data") if isinstance(aa, dict) else aa
        if not isinstance(entries, list):
            die("the Artificial Analysis response has no 'data' list")
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
        self.populations = {}
        for paths, _ in METRICS.values():
            for p in paths:
                vals = [v for v in (dig(e, p) for e in entries) if v is not None and self._valid(p, v)]
                self.populations[p] = sorted(vals)

    @staticmethod
    def _valid(path, v):
        # AA reports 0 for an unmeasured price or speed; a real one is positive.
        return v > 0 if not path.startswith("evaluations.") else True

    def match(self, canonical):
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

    def metric(self, entry, name, price=None):
        paths, higher = METRICS[name]
        if name == "price" and price is not None:
            # The deployment's own price, placed among AA's list prices.
            pop = self.populations.get(paths[0]) or []
            if not pop:
                return None
            if price <= 0:
                return 1.0
            return self.percentile(paths[0], price, higher)
        for p in paths:
            v = dig(entry, p)
            if v is not None and self._valid(p, v):
                return self.percentile(p, v, higher)
        return None


# ─── Scoring ─────────────────────────────────────────────────────────────────


def weighted(parts):
    """parts: [(weight, value or None)] → (mean over present, share of weight present)."""
    total = sum(w for w, _ in parts if w > 0)
    have = [(w, v) for w, v in parts if w > 0 and v is not None]
    if total <= 0 or not have:
        return None, 0.0
    got = sum(w for w, _ in have)
    return sum(w * v for w, v in have) / got, got / total


def deployment_price(model):
    """Blended 3:1 price per million tokens from OpenCode's cost list, or None."""
    cost = model.get("cost")
    if isinstance(cost, list):
        cost = cost[0] if cost else None
    if not isinstance(cost, dict) or "input" not in cost or "output" not in cost:
        return None
    return (3 * float(cost["input"]) + float(cost["output"])) / 4


def dimension_scores(index, entry, price):
    out = {}
    for name, metrics in DIMENSIONS.items():
        out[name] = weighted([(float(w), index.metric(entry, m, price)) for m, w in metrics.items()])
    return out


def task_score(dims, weights):
    parts = []
    coverage = []
    for name, w in weights.items():
        score, cov = dims.get(name, (None, 0.0))
        parts.append((float(w), UNMEASURED if score is None else score))
        coverage.append((float(w), cov))
    score, _ = weighted(parts)
    cov, _ = weighted(coverage)
    return score, cov or 0.0


def canonical_for(model, catalog):
    prov = (catalog.get(model["providerID"]) or {}).get("models") or {}
    for key in (model["id"], model.get("modelID")):
        entry = prov.get(key) if key else None
        if entry and entry.get("canonical_model_id"):
            return entry["canonical_model_id"]
    return "%s/%s" % (model["providerID"], norm_slug(model.get("modelID") or model["id"]))


def configured_providers(models):
    return sorted({m["providerID"] for m in models} - {BUILTIN_PROVIDER})


def evaluate(skills, models, catalog, aa):
    """{skill: assignment}, candidates, unmatched."""
    index = AAIndex(aa)
    order = {}
    for m in models:
        order.setdefault(m["providerID"], len(order))
    candidates = []
    unmatched = {}
    for pos, m in enumerate(models):
        if not m.get("tools"):
            continue  # an agent needs tool calling
        ref = "%s/%s" % (m["providerID"], m["id"])
        canonical = canonical_for(m, catalog)
        base = index.match(canonical)
        if base is None:
            unmatched.setdefault(canonical, []).append(ref)
            continue
        efforts = index.by_base[base]
        variants = set(m.get("variants") or [])
        picks = [(eff, e) for eff, e in sorted(efforts.items(), key=lambda kv: kv[0] or "") if eff and eff in variants]
        if not picks:
            # No variant pins the effort: the provider's default, scored with
            # the suffix-less AA entry (or the only one there is).
            entry = efforts.get(None) or efforts[sorted(efforts, key=lambda k: k or "")[0]]
            picks = [(None, entry)]
        price = deployment_price(m)
        for eff, entry in picks:
            candidates.append({
                "ref": ref + ("#" + eff if eff else ""),
                "canonical": canonical,
                "pos": pos,
                "benchmark": entry.get("slug"),
                "dims": dimension_scores(index, entry, price),
            })

    assignments = {}
    for name in sorted(skills):
        profile = skill_profile(name)
        scored = []
        for c in candidates:
            score, cov = task_score(c["dims"], PROFILES[profile])
            if score is None or cov < MIN_COVERAGE:
                continue
            scored.append((round(score, 6), c, cov))
        scored.sort(key=lambda t: (-t[0], t[1]["pos"], t[1]["ref"]))
        if not scored:
            assignments[name] = {"model": None, "profile": profile, "reason": "no scored model meets the coverage floor"}
            continue
        score, best, cov = scored[0]
        a = {"model": best["ref"], "profile": profile, "benchmark": best["benchmark"],
             "score": rounded(score), "coverage": rounded(cov, 2)}
        runner = next((t for t in scored if t[1]["canonical"] != best["canonical"]), None)
        if runner:
            a["runnerUp"] = {"model": runner[1]["ref"], "score": rounded(runner[0])}
        assignments[name] = a
    return assignments, sorted(unmatched.items())


# ─── Render ──────────────────────────────────────────────────────────────────


def agent_rel(name):
    return os.path.join(".opencode", "agents", name + ".md")


def render(skills, assignments, root, previous):
    """Write one agent per practice skill. Returns (written, notes).

    The agent has no body: a body replaces OpenCode's default system prompt.
    The byrde-agents plugin adds the skill's method to the prompt instead.
    """
    previous = set(previous or [])
    written = []
    notes = []
    for name in sorted(skills):
        rel = agent_rel(name)
        path = os.path.join(root, rel)
        if os.path.exists(path) and rel not in previous:
            notes.append("kept %s: it exists and init did not write it" % rel)
            continue
        model = (assignments.get(name) or {}).get("model")
        text = "---\ndescription: %s\nmode: all\n" % yaml_str(skill_description(name, skills[name]))
        if model:
            text += "model: %s\n" % yaml_str(model)
        text += "---\n"
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(text)
        written.append(rel)
    for rel in sorted(previous - set(written)):
        path = os.path.join(root, rel)
        if os.path.isfile(path):
            os.remove(path)
            notes.append("removed %s" % rel)
    agents_dir = os.path.join(root, ".opencode", "agents")
    if os.path.isdir(agents_dir) and not os.listdir(agents_dir):
        os.rmdir(agents_dir)
    return sorted(written), notes


def report(skills, assignments, previous, mode, unmatched):
    lines = []
    width = max([len(s) for s in skills] + [4])
    old = previous or {}
    for name in sorted(skills):
        a = assignments.get(name) or {}
        model = a.get("model")
        was = (old.get(name) or {}).get("model")
        change = "" if was == model else "   (was %s)" % (was or "inherit")
        if not model:
            lines.append("  %-*s  inherit%s" % (width, name, change))
            continue
        lines.append("  %-*s  [%s] %s  score %.3f  coverage %.2f%s"
                     % (width, name, a["profile"], model, a["score"], a["coverage"], change))
        ru = a.get("runnerUp")
        if ru:
            lines.append("  %-*s    runner-up %s  %.3f" % (width, "", ru["model"], ru["score"]))
    if mode == "scored":
        if unmatched:
            lines.append("  ? %d model(s) have no Artificial Analysis match and were not scored:" % len(unmatched))
            for canonical, refs in unmatched[:12]:
                lines.append("      %s  (%s)" % (canonical, ", ".join(refs)))
        lines.append("  Benchmark data: " + ATTRIBUTION)
    return "\n".join(lines)


# ─── CLI ─────────────────────────────────────────────────────────────────────


def cmd_run(args):
    skills = read_skills(args.skills)
    state = load_json(args.state, {})
    previous = state.get("agents") or {}
    models = load_json(args.models) if args.models else []
    providers = configured_providers(models)

    if not providers:
        mode, reason = "inherit", "no provider is configured beyond OpenCode's built-in one"
    elif not args.aa:
        mode, reason = "inherit", "no Artificial Analysis data (set ARTIFICIAL_ANALYSIS_API_KEY)"
    else:
        mode, reason = "scored", "providers: " + ", ".join(providers)

    unmatched = []
    if mode == "scored":
        catalog = load_json(args.catalog, {}) if args.catalog else {}
        assignments, unmatched = evaluate(skills, models, catalog, load_json(args.aa))
    else:
        assignments = {name: {"model": None, "profile": skill_profile(name)} for name in skills}

    written, notes = render(skills, assignments, args.root, state.get("generated"))
    state["generated"] = written
    state["agents"] = assignments
    state["evaluation"] = {"mode": mode, "reason": reason, "providers": providers,
                           "unmatched": [{"canonical": c, "deployments": r} for c, r in unmatched]}
    write_json(args.state, state)

    print("  mode: %s (%s)" % (mode, reason))
    print(report(skills, assignments, previous, mode, unmatched))
    for n in notes:
        print("  " + n)
    return 0


def cmd_clean(args):
    state = load_json(args.state, {})
    _, notes = render({}, {}, args.root, state.get("generated"))
    for n in notes:
        print("  " + n)
    for key in ("generated", "agents", "evaluation"):
        state.pop(key, None)
    if os.path.exists(args.state):
        write_json(args.state, state)
    return 0


def main(argv):
    p = argparse.ArgumentParser(prog="evaluate.py")
    sub = p.add_subparsers(dest="cmd", required=True)
    run = sub.add_parser("run")
    run.add_argument("--skills", required=True)
    run.add_argument("--root", required=True)
    run.add_argument("--state", required=True)
    run.add_argument("--models")
    run.add_argument("--catalog")
    run.add_argument("--aa")
    clean = sub.add_parser("clean")
    clean.add_argument("--root", required=True)
    clean.add_argument("--state", required=True)
    args = p.parse_args(argv[1:])
    return cmd_run(args) if args.cmd == "run" else cmd_clean(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
