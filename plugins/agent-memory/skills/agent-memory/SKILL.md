---
name: agent-memory
description: Use TessariDB Agent Memory to keep what you learn past the end of a context window and to read what earlier sessions learned. Use it when starting work in a project you may have worked in before, when you learn something expensive to re-learn, before guessing at something that was probably tried, before starting a task another agent may hold, when tracking goals, tasks, decisions, checklists or a release, and when a memory tool refuses a call.
---

# Agent memory

TessariDB Agent Memory is a store for what agents learn. It outlives your context window, it is
shared by every agent that works in the same project, and you reach it through the `tessaridb-am`
tools. Each tool's schema says what it takes. This skill covers what a schema can't: when to use
the store, which tool fits which job, and what a complete round trip looks like.

More detail is in the files next to this one:

- [references/workflows.md](references/workflows.md): goals, tasks, decisions, checklists and releases from start to finish.
- [references/recall.md](references/recall.md): reading well. Scope, topics, hops, vectors, witnesses.
- [references/troubleshooting.md](references/troubleshooting.md): refusals, an unreachable server, signing in, revoking a credential.

## The five moments to use it

1. **Arriving.** Call `session_start` with your agent name and the absolute folder you work in. Then
   call `status` with `width: "project"` to see what is open here and who else is active.
2. **Before guessing.** Call `recall` with a few words about the problem. An empty answer costs
   one call. Rediscovering a known failure costs the afternoon.
3. **Before starting shared work.** Call `task_claim` on the task. If somebody holds it, you are
   told who holds it and until when. That is an answer, not a transient error, so do something else.
4. **After learning something expensive.** Write it down at once. That covers a measurement, a
   failure mode, a dead end, or a decision and its reason. You will not remember to do it later,
   because "later" is in a context window you will not have.
5. **Leaving.** Call `session_end` with `reason: "closed"`. That releases your claims and leaves the
   next agent a reason instead of a timeout.

While you work for a long time without calling anything, send `session_heartbeat` now and then.
From outside, a long pause looks exactly like a crash, and a crashed-looking session can have its
claims handed to someone else. A heartbeat does **not** extend a claim. A claim ends on the
deadline it was given when you took it, so take the task again if you are still on it.

## Starting a session

```
session_start { agent: "claude-code", path: "/abs/path/to/the/project" }
```

- `agent` is the name this installation knows your client by (`claude-code` for Claude Code).
  Every later call is attributed to it.
- `path` is the folder you are in. The nearest *declared* folder at or above it decides the group
  and the project, so every agent working in one project folder lands in the same project.
- If the folder has never been declared, the call is refused, and the refusal says so. **Ask the
  person**. Only they know whether the folder is one project or a group of projects. Then call
  again with what they said:

```
session_start { agent: "claude-code", path: "/work/acme",
                declare: { kind: "group", subprojects: ["api", "web"] } }
session_start { agent: "claude-code", path: "/work/tool",
                declare: { kind: "project" } }
```

The declaration is recorded once. Later sessions in that folder need only `path`.

Every other tool is refused until `session_start` has succeeded. After your client's context is
compacted or restarted, you are a new session as far as the service is concerned. Call it again.

## Three ways to write, and the one that goes wrong quietly

| Tool | It means | Use it for |
|---|---|---|
| `remember` | what **you** believe. No evidence needed, and it may be wrong. | notes, hunches, what you tried, how something works |
| `remember` with `as_fact` | something the **project** vouches for, with evidence | a confirmed measurement, a verified behaviour, an established rule of the code |
| `item_add` | a **record** other agents act on | goals, tasks, plans, questions, decisions, risks, ideas, rules, documents, checklists |
| `activity_log` | that something **happened**. Changes nothing else. | "closed task X", "promoted idea Y", so the history can be read back later |

Picking the wrong one is not refused. The expensive mistake is writing a guess as a project record
or a confirmed fact: the next agent can't tell it was a guess, and acts on it.

### `remember`

```
remember { kind: "semantic",
           body: "The importer drops rows whose date is in DD.MM.YYYY; it only parses ISO 8601." }
```

`kind` decides how long the memory lives and what it is for:

- `working`: scratch for the task in hand. Short-lived.
- `episodic`: what happened in a session ("tried X, it failed because Y").
- `semantic`: how something is ("service A calls B over gRPC with a 2 s deadline").
- `procedural`: how to do something ("to rebuild the index, run …").
- `instruction`: something a person told you to do or not do.
- `uncertainty`: something you are unsure of and want checked.

Write the body so it stands on its own. The reader will not have your context: give names, paths,
numbers and the reason, not "as discussed".

To make it a project fact, add `as_fact` with **one** claim:

```
remember { kind: "semantic", body: "…full explanation…",
           as_fact: { title: "Importer accepts ISO dates only",
                      statement: "The CSV importer parses dates as ISO 8601 and drops other formats.",
                      topic: "failure-mode", confidence: "confirmed", provenance: "code-audit",
                      evidence: [{ kind: "code", locator: "src/import/csv.rs:142" }] } }
```

`confidence: "confirmed"` needs evidence and is refused without it. Use `probable` or
`hypothesis` when you can't point at anything. A fact holds one claim, so that a later finding can
supersede it cleanly.

If you have an embedding of the text, pass it as `embedding: { vector, model }`. It must be 384
numbers wide. Any other width is not stored, but the memory still is, and the answer says so.

## Reading

`recall` is the one way to read. Text, topic filters and links are ranked together, and every hit
says where it came from.

```
recall { text: "importer date format" }
recall { text: "flaky test", topics: ["failure-mode"] }
recall { text: "auth redesign", hops: 1 }          # also return what the hits link to
```

It reads **your project only** unless you widen it on purpose with `reach`. An empty answer may
mean you are looking in the wrong place, not that nothing exists. See [references/recall.md](references/recall.md).

## Records other agents act on

`item_add` creates one of ten families: `goal`, `task`, `plan`, `question`, `decision`, `risk`,
`idea`, `rule`, `artifact` (a document such as a research note, report or critique) and
`checklist`. The family decides which fields are required. A missing one is refused by its field
name, so read the refusal and add it.

`item_update` changes an item. Two things to know:

- `expected_version` is required. Pass the version you read. If someone changed the item since,
  your write is refused instead of silently overwriting theirs: read it again and redo the change.
- `content` **replaces** the item. It is not a patch, so send the whole item as it should now read.
  Omit `content` to change only the `status`.

A status move the lifecycle doesn't allow is refused, and the refusal lists the moves that are
allowed. You never have to guess the state machine.

`item_link` relates two existing records (`parent_of`, `goal_parent_of_goal`, `blocks`,
`relates_to`). Both ends must exist. Repeating a link is harmless.

The full lifecycles and worked examples are in [references/workflows.md](references/workflows.md).

## A refusal is an answer

A refused call carries a code, the field it is about, and what to do instead. Read it and change
the call. Never send the identical call again, because nothing about the second try is different.

Three answers look alike and are not:

- **Refused**: your call is wrong or not allowed. Change it.
- **Unavailable**: the service or the database could not answer right now. Retrying later is fine.
- **Empty**: the call worked and nothing matched. Consider whether you looked in the right scope.

## Tools that are described but not carried out

Some tools exist in the list but their backing is not built yet. Their descriptions start with
`[not carried out]`, and they answer by saying so: `changes_since`, `export`, `import`, `status` at
widths `group` and `installation`, and the `page.after` cursor on a ranked search. Don't build a
plan on them. Use `recall` and `status` (widths `me` and `project`) instead.

## What this store is not

It is not where your plans, progress notes or repository files live. Those belong in files that
can be read with nothing running. The store holds what files can't give you: memory that spans
sessions, projects, agents and machines, and records several agents coordinate on.
