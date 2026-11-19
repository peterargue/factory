# Memory map: where a fact lives

The factory's agents remember things in five places. Each place owns one kind of
fact. A fact lives in exactly one of them; every other place may point to it but
never copies it, because a copy drifts and nothing reconciles it. When two places
disagree, the owner below wins and the other is corrected.

A repo names its own instances of these in `FACTORY.md` under `memory:`.

## Who owns what

| Place | Owns | Read and written by | Lifetime | Never put here |
|---|---|---|---|---|
| **The repo** (`CLAUDE.md`, `.claude/rules/`, `FACTORY.md`, the specs) | How this repo is built: rules, conventions, the factory contract, the design of each change | Every session in the repo, through reviewed PRs | As long as the code | Business facts, in-flight status, anything only one session needs |
| **The knowledge base** (`memory.knowledge_base`) | What the business is: companies, people, suppliers, products, provinces, processes, what each system is *for* | People and agents, before acting on business data; corrected whenever an agent learns better | Permanent, edited like a wiki | Code mechanics, PR status, agent lessons |
| **Project memory** (`memory.project_memory`, the claude.ai project's shared memory) | Work in flight across threads: decisions the owner made and why, which PR or change carries them, what is waiting on whom, cloud-container gotchas | The project's coordinator and threads (cloud only) | Until the work lands; then pruned to the decision that outlives it | Anything a Mac session needs, rules that belong in the repo, business facts |
| **codev** (`memory.local_memory`, the Felix store in `~/codev` on the Mac) | Local sessions' memory: lessons, patterns and decisions from Mac CLI sessions, guard-denial logs (`codev-memory`), each project board's Now/Done | Mac sessions only (SessionStart hook, `codev search/save`) | Consolidated nightly ("dream"); history in git | Anything a cloud thread needs: cloud threads cannot reach the Mac |
| **`~/.agents`** (`memory.conventions`) | Personal, cross-harness agent conventions (`AGENTS.md`) and personal skills that are not part of the factory | Local harnesses on the Mac | Until changed by hand | Factory machinery (that is the plugin), repo facts (that is the repo) |

Two more homes are not memory but are often mistaken for it: **the tracker** (Linear)
owns the work contract and its order, and **the factory plugin** owns the machinery. A
lesson that changes how the factory works is a change to the plugin, not a memory.

## Where does this fact go?

Ask in order and stop at the first yes:

1. Is it true of the business whatever the code does? → **knowledge base**.
2. Does every future session in this repo need it, and can a reviewer check it? → **the repo**
   (a rule, `CLAUDE.md`, `FACTORY.md` or a spec). Not memory.
3. Does it change how the factory works for every repo? → **the factory plugin**. Not memory.
4. Is it about work in flight that a cloud thread or the coordinator will need? → **project memory**.
5. Is it something a Mac session learned that only Mac sessions will need? → **codev**.
6. Is it a personal convention for agents in general, not this factory? → **`~/.agents`**.

If none fits, it probably does not need remembering.

## Crossing between them

- **Mac to cloud.** A Mac session never writes project memory (it cannot reach it). It
  reports back to the thread that started it, and the thread saves what the project needs.
- **Cloud to Mac.** A cloud thread that learns something a Mac session will need puts it
  in the repo (if it is a rule) or tells the Mac session through Remote Control. It does
  not rely on codev.
- **Memory to rule.** A lesson seen twice (the `review-sessions` skill counts) is promoted
  out of codev or project memory into a rule in the repo or a change to the plugin, and the
  memory entry is replaced by a pointer or deleted.
- **Done work.** When a PR merges, project memory keeps the decision and its reason, not
  the PR's progress notes. When a change lands, the knowledge base page for the system it
  touched is updated if what the system is *for* changed.
