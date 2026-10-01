---
name: agent-memory
description: Use TessariDB Agent Memory to keep what you learn past the end of a context window and to read what earlier sessions learned. Use it when starting work in a project you may have worked in before, when you learn something expensive to re-learn, before guessing at something that was probably tried, before starting a task another agent may hold, when tracking goals, tasks, decisions, checklists or a release, and when a memory tool refuses a call.
---

# Agent memory

TessariDB Agent Memory is a store for what agents learn. It outlives your context window, it is
shared by every agent that works in the same project, and you reach it through the `tessaridb-am`
tools. Each tool's schema says what it takes. This skill covers what a schema can't: when to use
the store, which tool fits which job, and what a complete round trip looks like.

The detail is in the files under `references/`. Read the one that matches the task:

| File | Read it when |
|---|---|
| [references/writing.md](references/writing.md) | writing a memory or a project fact well: kinds, facts with evidence, embeddings |
| [references/workflows.md](references/workflows.md) | goals, tasks and claims, decisions, checklists, releases, caching a model's answer |
| [references/recall.md](references/recall.md) | reading well: scope, topics, links, vectors, witnesses and replay |
| [references/troubleshooting.md](references/troubleshooting.md) | a refusal, a server that isn't there, signing in, a tool that isn't built yet, a leaked credential |

## The five moments to use it

1. **Arriving.** Call `session_start` with your agent name and the absolute folder you work in.
   Then ask `status` for the project, to see what is open here and who else is active.
2. **Before guessing.** Call `recall` with a few words about the problem. An empty answer costs one
   call. Rediscovering a known failure costs the afternoon.
3. **Before starting shared work.** Take the task with `task_claim`. If somebody holds it, you are
   told who holds it and until when. That is an answer, not a transient error, so do something else.
4. **After learning something expensive.** Write it down at once. That covers a measurement, a
   failure mode, a dead end, or a decision and its reason. You will not remember to do it later,
   because "later" is in a context window you will not have.
5. **Leaving.** Call `session_end`. That releases your claims and leaves the next agent a reason
   instead of a timeout.

While you work for a long time without calling anything, send `session_heartbeat` now and then.
From outside, a long pause looks exactly like a crash, and a crashed-looking session can have its
claims handed to someone else. A heartbeat does **not** extend a claim. A claim ends on the deadline
it was given when you took it, so take the task again if you are still on it.

## Starting a session

```
session_start { agent: "claude-code", path: "/abs/path/to/the/project" }
```

- The agent name is the name this installation knows your client by (`claude-code` for Claude Code).
  Every later call is attributed to it.
- The path is the folder you are in. The nearest *declared* folder at or above it decides the group
  and the project, so every agent working in one project folder lands in the same project.
- If the folder has never been declared, the call is refused, and the refusal says so. **Ask the
  person**. Only they know whether the folder is one project or a group of projects. Then call again
  with what they said:

```
session_start { agent: "claude-code", path: "/work/acme",
                declare: { kind: "group", subprojects: ["api", "web"] } }
```

Every other tool is refused until a session exists. After your client's context is compacted or
restarted, you are a new session as far as the service is concerned, so start one again.

## Three ways to write

Three verbs look interchangeable and are not, and picking the wrong one is not refused:

| Tool | It means | Use it for |
|---|---|---|
| `remember` | what **you** believe. No evidence needed, and it may be wrong. Asked for with evidence, it becomes a project fact. | notes, hunches, what you tried, how something works; a confirmed finding as a fact |
| `item_add` | a **record** the project vouches for, and other agents act on | goals, tasks, plans, questions, decisions, risks, ideas, rules, documents, checklists |
| `activity_log` | that something **happened**. Changes nothing else. | "closed task X", "promoted idea Y", so the history can be read back later |

The expensive mistake is writing a guess as a project record or a confirmed fact: the next agent
can't tell it was a guess, and acts on it. How to write each one well is in
[references/writing.md](references/writing.md).

## Reading

`recall` is the one way to read. Text, topic filters and links are ranked together, and every hit
says where it came from.

```
recall { text: "importer date format" }
recall { text: "flaky test", topics: ["failure-mode"] }
```

It reads **your project only** unless you widen it on purpose. An empty answer may mean you are
looking in the wrong place, not that nothing exists. See [references/recall.md](references/recall.md).

## Changing a record

`item_update` changes an item. Two things to know:

- The expected version is required. Pass the version you read. If someone changed the item since,
  your write is refused instead of silently overwriting theirs: read it again and redo the change.
- The content you send **replaces** the item. It is not a patch, so send the whole item as it should
  now read, or send only a status move.

A status move the lifecycle doesn't allow is refused, and the refusal lists the moves that are
allowed. You never have to guess the state machine. Lifecycles and worked examples are in
[references/workflows.md](references/workflows.md).

## A refusal is an answer

A refused call carries a code, the field it is about, and what to do instead. Read it and change the
call. Never send the identical call again, because nothing about the second try is different.

Three answers look alike and are not:

- **Refused**: your call is wrong or not allowed. Change it.
- **Unavailable**: the service or the database could not answer right now. Retrying later is fine.
- **Empty**: the call worked and nothing matched. Consider whether you looked in the right scope.

A few tools are described but not built yet. Their descriptions start with *[not carried out]*. Don't
build a plan on them; [references/troubleshooting.md](references/troubleshooting.md) lists them and
what to use instead.

## What this store is not

It is not where your plans, progress notes or repository files live. Those belong in files that can
be read with nothing running. The store holds what files can't give you: memory that spans
sessions, projects, agents and machines, and records several agents coordinate on.
