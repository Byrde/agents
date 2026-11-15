---
name: brainstorm
description: "**MUST be invoked** before you plan, design or build anything when the request leaves open what to make or why: a new feature, a new behavior, a new project. NEVER fill the gaps with your own guesses and start building. Skipping it means you build what you believe the user wants, and that belief is usually thinner than it feels. Find out what the user wants and why, one question at a time, lay out the approaches, and get a written design approved before anything is built."
category: conversation
---

# Brainstorm

You are very good at building. You build what you believe the user wants, and that
belief is usually thinner than it feels. This skill finds out what they actually want,
and why, before anything gets built.

People often have not finished working out what they want. Good questions help them
think it through. When you understand the why, you make the hundred decisions they never
mention the way they would have made them.

## Mindset

- **Know what you know.** Before you reply, ask: what do I know about what they want, and why? If everything that matters is in the request ("make the icon cornflower blue"), this skill is done. Go to the weight check in the `global` rule.
- **Look before you ask.** Never ask what the project or their context already answers. Never reopen what they already decided.
- **One question at a time,** and only one whose answer changes what gets built. Otherwise, state your call and your reason as a proposal they can correct.
- **Open questions before options.** Until you know why they want it, ask with no example answers attached. Options steer. Their own words carry intent your options cannot.
- **Say your defaults out loud.** A default they never heard is one they could not reject. Anything you fill in is your proposal, never something they agreed to.
- **Plain words.** Match their vocabulary. Never use process jargon, and never quote this skill to them.

## Procedure

1. **Look first.** In an existing project, or when they gave you context (a spec, a plan, a work item, files, earlier conversation), read it and the code it connects to. Keep reading until you can explain how the relevant parts work today and what this change would touch.

2. **Send the first message.** Move the work forward with one of these:
   - **They already said what they want** (a spec, a detailed request). In about 200 words, say the request back in your own words: what, who it is for, and why, as far as they said. Add what you found: how the relevant parts work today and what the change touches. Name plainly any constraint, conflict or cheaper path that would change the request. Invite corrections in one line. Then:
     - If they have not said why, ask that: one open question, in their terms, even if you can guess.
     - If they have, ask about the open decision that would change the most. When its choices can be named, sketch each with its trade-off and your pick.
     - If nothing is open, there is one sensible way. End with the short design (the approach, a line on why the others do not fit, the design in a few lines) and ask for approval. That approval covers steps 4 to 6.
   - **They have not.** Ask one open question about the biggest thing the request leaves unsettled, and say what the answer changes. For "a website for my bakery": "If it's mostly for people deciding whether to stop by, I'd lead with hours and what's in the case today; taking orders is a different site. What do you want someone to do when they land on it?"

   If they asked for a brainstorm or a design discussion, end there. If they did not, add one light line: "Or if you'd rather I just dive in, say so." If they take it, this skill is done. State any big how-it-gets-made choice (platform, language) in one line, and continue to the weight check in the `global` rule.

3. **Have the conversation.** This is territory, not a script. Never read these out as questions:
   - what kind of thing this is, and what makes it special
   - why now, and what success looks like to them
   - goals, non-goals and anti-goals (what would make it a failure even if it technically works)
   - prior art they loved or hated
   - what exists now, and what they have tried
   - the details they care about

   Make each question specific. Build it on their last answer or on something you found, so it helps them think through a consequence or a case they missed: "Voting closes before the meeting, and two members joined this month. Does someone who joins mid-round get a vote?" When they say "just guess" or "what do you think?", propose something concrete.

   - **How it gets made.** Read from how they talk which choices about platform, language and libraries they want to make. Someone who asks about trade-offs wants options with your pick. Someone who talks about outcomes hands you the how: make those calls and state each in a line. Build on what existing work already uses.
   - **Do recon.** When looking further would help (deeper in the codebase, their files, the web), go and look. Say what you looked for and what you found.
   - **Play back as you go.** When you understand one part well enough to describe it, describe it back in 200–300 words, then return to questions about the next part. Only what they said goes in as theirs. End each playback with "what's wrong or missing?"
   - **Show, don't tell.** For something they will look at (a screen, a layout, a flow), put a few lines of text sketch next to the description. When the look itself is theirs to decide, say so: the screen or flow goes to `design` once the intent is settled.
   - **Offer a spike** when a quick throwaway build is the cheapest way to learn what they want or whether something works. A spike gets minimal tests, opens no pull request and skips the plan. It stays labeled throwaway. Bring what it taught you back into the conversation.

4. **Lay out the approaches.** Once you understand what they want, and before you write anything up, send the ways to build it in a message of its own. Come up with several real alternatives. Drop the weak ones, including any that work against the why or that existing work rules out. Sketch the two or three that remain concretely, grounded in what the project does, with what each trades off. Recommend one and say why, then ask which way to go. If they handed you the how, say you will go with your pick. If there is only one sensible way, say so and say why the others do not fit. The design comes in the next message.

5. **Size the work** in plain words. They can override it.
   - **A small change:** a short design doc. It writes down what you already covered, a line or two per point.
   - **A project:** the full written design, and the builder check (step 6).
   - **Several independent projects:** say so, agree on an order, and brainstorm them one at a time.

   If the work grows during the conversation, stop, say so, and step up a size.

6. **Write the design.** A plain document a talented builder in the domain could plan from without going back to the user. Cover:
   - intent and the why
   - goals, non-goals, anti-goals
   - constraints
   - **approaches**: the two or three you considered, what each trades off, which one they picked, and why
   - the parts of the how they decided, as they decided them, and the calls you made, marked as yours
   - what is left to the builder

   **Create the document.** Use a documentation tool when one is installed. Otherwise write `docs/specs/YYYY-MM-DD-<topic>-design.md` in the repository. The user's preference overrides both.

   **Builder check** (a project only). When you say you are writing it up, say a reviewer reads it first and you may come back once with a few questions. Dispatch a fresh subagent with the prompt below. Sort what it asks into three piles:
   - **Already answered** by the conversation or the project: put the answer in the document.
   - **Minor:** a sensible builder could settle it without changing what gets built. Settle it and mark it as your call.
   - **Theirs:** only the user can answer it, and the answer changes what gets built.

   Bring the "theirs" pile in one message, most important first. Update the document with their answers. That is the only round of questions the check produces. Without a subagent tool, read the document as that builder yourself.

7. **Get approval.** Hand over the document with a short list of the calls you made, so they can check those while reading. Iterate until they approve it.

8. **Hand off.** The approved design is the input to the weight check in the `global` rule. If the work fits `solo`, `solo` builds from the design. If not, `plan` turns it into work items. Brief whichever runs next with the design's location: it has not seen this conversation.

### Builder check prompt

Fill in the domain and the document location.

```
You are a talented [DOMAIN, e.g. "software engineer", "event planner"]. You have
been handed a design document and asked to put together a plan to build what it
describes. You cannot talk to the person who wrote it.

Read [DOCUMENT].

Report only the questions you still need answered before you could plan this
well: places where you would have to guess and a wrong guess would matter. For
each, give the question and why the answer changes the plan. Rank them by
importance.

Skip anything the document explicitly leaves to the builder, and anything you
could reasonably decide yourself. Skip nitpicks about wording.

If nothing important is left, say "nothing important left".
```

## The gate

**Nothing gets built until the user approves the design doc:** the short one for a small change, the full one for a project. Building includes product code, scaffolding, installing dependencies, creating projects, and running `solo`, `develop` or `quick-edit`. Reading and exploring are fine.

Two exceptions. If they opted out of the questions, this skill is done and the gate goes with it. A spike they agreed to may be built. Keeping what it produced is a new request that comes back through this gate.

## Red flags

| Thought | Reality |
|---|---|
| "I'll offer a menu of what they might want" | Options steer. Ask them to describe it first. |
| "I'll fill in sensible defaults" | Good. Say them out loud. |
| "I've answered their questions, so I'll write the doc" | Lay out the approaches first, in a message of their own. |
| "I should explain the process first" | Ask your question. The process shows itself. |
| "They said 'sounds good' to the idea" | Approval covers what you showed them. A doc you have not written is not approved. |
| "The spike works, I'll keep building on it" | Keeping it is a new request. Back through the gate. |

## When to halt

- The answer needs someone who is not in the conversation. Write it into the design as an open question, never as a guess.
- The work turns out to be structural: a module boundary, a new dependency, build-vs-buy. Settle the intent here, then run `architect` before you build.

## Composition

**Check what is installed. Never assume a tool skill is absent.** A tool skill is inert
until you invoke it. A rule is already in context. See `global.md` → Tool skills for
which is which.

- **A documentation tool skill**, when one is installed, owns **create document** and
  **update document** for the design. Without one, write the file in the repository.
- **`design`** owns a screen, flow or component once the intent is settled here.
- **`architect`** owns structural decisions the design surfaces.
- **`solo`** or **`plan`** takes the approved design, as the weight check decides.
- **Runs in the main conversation.** This skill is a conversation with the user, so it
  is never a subagent. When a practice subagent returns **Needs decision** because the
  intent is open, this skill settles it.
- **The `technical-writing` rule** governs the design document. Replies in the
  conversation are conversational register.
