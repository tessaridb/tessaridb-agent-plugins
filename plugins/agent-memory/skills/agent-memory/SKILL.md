---
name: agent-memory
description: Use TessariDB Agent Memory to keep what you learn past the end of a context window, and to read what earlier sessions already learned. Reach for this when you are starting work in a project you may have worked in before, when you learn something worth keeping, when you are about to start a task somebody else may already hold, or when the memory server refuses a call and you need to know what to do about it.
---

# Agent memory

There is a store here for what an agent learns. It outlives your context window, it is readable by
whoever works in this project next, and it is reached through a set of verbs served as tools.

The tool list tells you what each verb takes. This tells you the two things a tool list structurally
cannot: **when to reach for the store at all**, and **what a whole round trip looks like**.

## When to reach for it

Four moments. None of them announces itself, which is why they are written down.

**Before you start.** You are in a project you may have been in before, and you have no memory of it
because a context window ended. Ask `status` what is going on here. If the work you are about to
start is a task, `task_claim` it before you begin — an unclaimed task is one two agents will both
start, and the second one finds out late.

**When you learn something that was expensive to learn.** A measurement, a failure mode, a thing
that turned out not to work, a decision and its reason. If re-deriving it would cost what deriving
it cost, it belongs in the store. `remember` it while you still have it in front of you; an
intention to write it down later does not survive the window either.

**When you are about to guess.** Something was probably tried before. `recall` it first. A search
that comes back empty costs one call; a rediscovery costs the afternoon.

**When you stop.** `session_end`, with a reason. Otherwise the next agent inherits a session that
looks crashed and has to decide what that means.

## The round trip

This is the whole path, from no session to a memory read back. Verbs are named the way the tool list
names them; the arguments each one takes are in its own schema and are not repeated here.

1. `session_start` — announce yourself. Every other verb is refused before it, and the refusal says
   so, so getting this wrong is loud rather than silent.
2. `remember` — write down what you learned, in your own words.
3. `recall` — search. Text, filters and links are ranked together; you do not choose a search mode.
4. `session_end` — finish, and release what you were holding.

A `recall` that finds nothing is worth one more thought before you believe it: reads are scoped to
the project you are in unless you widen them deliberately, so an empty answer can mean *looking in
the wrong place* rather than *nothing is there*.

## The one choice that goes wrong quietly

Three verbs write, they look interchangeable, and picking the wrong one is not refused.

| verb | what it means | who acts on it |
|---|---|---|
| `remember` | what **you** believe. No evidence required. Allowed to be wrong. | you, and anybody reading your reasoning |
| `item_add` | a record the **project** vouches for — a goal, a task, a question, a decision | other agents, as fact |
| `activity_log` | something **happened**. Changes nothing else. | anybody reconstructing what occurred |

Writing a belief as a project record is the common mistake and the expensive one, because the next
agent has no way to tell that it was a guess.

## What the server tells you, so this does not

Do not look for it here — look at what the connection already gave you.

- **Which verbs exist, and what each one takes.** The tool list, with a schema per verb. It is built
  from the service's own verb set, so it cannot be out of date the way a written list would be.
- **Which verbs only read.** Each verb is annotated; a read-only verb is safe to try.
- **Which verbs are described but not carried out.** A few are: the need is real and the backing is
  not, and each says which of the two it is in its own summary, before you build a plan on it.
- **The service's own orientation.** Sent once when the connection opens.

## A refusal is an answer

It carries a code, the field it is about, and what to do instead. Read it and change the call. Do
not send the identical call again — nothing about the second attempt will be different.

## When the server is not there

The memory server runs as a child of your client, so it is present or it is not, and nothing you can
call will bring it back. If the tools are missing, say so and carry on working: the client has to be
restarted by the person using it.

If a shell is available, the same verbs are reachable as `tessari-am <verb>`, which reads its own
settings and needs no client. Use it to check whether the store is up before concluding it is down.

## When a credential has to be taken back

The tools cannot do it, and that is deliberate rather than missing. Adding a user, blocking one,
granting authority and withdrawing it are operator acts. An agent never performs them, so carrying
them as tools would cost every agent eight more lines to read on every turn and save nobody
anything.

They live on the command line instead, and they reach the same node over the wire, so it makes no
difference whether the store runs on this machine or another one. `tessari-am --help` lists all
eight with what each one does, built from the set the program itself dispatches, so that list
cannot drift out of date. The one worth knowing before you need it is
`tessari-am admin credential.revoke`, which stops a credential admitting anybody and takes its
logins with it.

If you are an agent and a credential has leaked, say so and name that command rather than looking
for a verb. There is no verb, the refusal you get will not explain why, and the person reading you
is the one with the shell.

## What this is not

It is not where your plans, your progress notes or your governance state live. Those are files, and
they have to be readable when nothing is running. This store holds what files cannot: recall that
spans the sessions, the projects and the machines the files are not on.
