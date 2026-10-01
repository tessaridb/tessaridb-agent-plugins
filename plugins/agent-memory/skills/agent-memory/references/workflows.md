# Workflows

Worked paths through the record tools. Field names are the tools' own. When a call is refused, the
refusal names the field or the allowed moves, so follow it.

## Goals: something to achieve, judged criterion by criterion

A goal must carry its criteria when it is created. A goal with none can never be achieved, so it
is refused. Each criterion needs a `validation_method`: the command, test or measurement that
decides it.

```
item_add { item: {
  family: "goal",
  objective: "Search answers the ten support questions in the top three results",
  owner: "ada",
  criteria: [
    { text: "Recall@3 >= 0.9 on the support judgment set",
      validation_method: "python eval/judge.py --set support --k 3" },
    { text: "p95 search latency under 50 ms at 1M documents",
      validation_method: "bench/search.sh --docs 1000000" } ],
  non_criteria: ["Changing the ranking model"],
  kill_criteria: ["The judgment set cannot be built from real tickets"] } }
```

Lifecycle: `draft → clarified → active → achieved`, or `dropped`. A criterion moves
`open → passed | failed`, through `item_update` on the `criterion` family.

To see where a goal stands, call `goal_achieve { goal: "<id>" }`. It judges **every** criterion
separately and reports each one. The goal is achieved only when every criterion has passed with
evidence. One summary verdict is never enough.

Break the work down with tasks that name the goal (`task.goal`), and link goals to sub-goals with
`item_link { kind: "goal_parent_of_goal" }`.

## Tasks: units of work several agents share

```
item_add { item: { family: "task", title: "Build the support judgment set", kind: "research",
                   goal: "<goal id>" } }
```

`kind` is one of `feature`, `fix`, `remediation`, `research`, `chore`. Use `depends_on` to list
tasks that must finish first, or link them with `item_link { kind: "blocks" }`.

Lifecycle: `open → claimed → done`, or `blocked`.

**Claiming** is how two agents avoid doing the same work:

```
task_claim { task: "<task id>" }   # take this one
task_claim {}                      # hand me the oldest open, unclaimed task here
```

- The answer names the task you now hold and when the hold ends.
- If someone else holds it, the answer says who and until when. Pick other work.
- A hold is bounded and **nothing renews it**: heartbeats don't. If you are still working when it
  ends, claim the task again. Otherwise another agent may take it, and neither of you is told.
- `session_end` releases everything you hold.

When finished, move the task to `done` with `item_update` (status only, with `expected_version`).
Then log it: `activity_log { verb: "closed", object: { table: "task", id: "<id>" } }`.

## Questions, decisions, risks, ideas, rules

| Family | Required | Lifecycle |
|---|---|---|
| `question` | `text`, `blocking` (true = it holds a stage until answered) | `open → answered / deferred / dropped` |
| `decision` | `title`, `context`, `decision`, `consequences` (including the cost) | `accepted → superseded` |
| `risk` | `title`, `severity` (blocking/major/minor/nit), `likelihood` (high/medium/low) | `open → mitigated / accepted` |
| `idea` | `problem`, `proposed_change`, `confidence` | `captured → promoted / dropped` |
| `rule` | `text`, `force` (must/should/never), `source` (owner/agent/imported/derived-from-incident) | — |

Some details:

- Record a decision **with its cost** in `consequences`. A decision written without one reads later
  as free.
- A rule's `source` is asked for, not inferred. A rule the owner stated is `owner`; one the agents
  worked out themselves is `agent`. Mixing them up gives a guess the authority of an instruction.
- A rule binds downward: one set on a group binds every project in it.

## Documents (artifacts)

Research notes, reports, snapshots, critiques, concepts, audits and governance checks are all
`family: "artifact"` with a `kind`. They need a `title` and a `body`. They can also carry:

- `findings`, each with `kind` (defect/risk/gap/question/preference/praise), `summary`, `severity`,
  `confidence` and `basis` (the rule, measurement or standard it rests on);
- `matrix_rows`, for correspondence work (port, migration, parity), where `exists` and
  `semantics_verified` are separate on purpose: a unit that exists and behaves wrongly is not
  verified;
- `checklists` (a frozen snapshot) or `gated_by` (ids of standing checklists).

## Checklists: a gate you fill in over time

Create the checklist **before** the phase it gates, with every row. Rows can't be added or removed
later. That is the point: coverage can't shrink to what got done.

```
item_add { item: { family: "checklist", kind: "pre", flow: "review", written_before: true,
  rows: [ { item: "Every changed file read in full", status: "open" },
          { item: "Tests run and their result recorded", status: "open" } ] } }
```

Settle rows one at a time:

```
checklist_discharge { checklist: "<id>", at: 1,
  item: "Tests run and their result recorded",
  status: "done", evidence: "cargo test: 412 passed, 0 failed (2026-10-02)" }
```

- `at` counts from zero. `item` repeats the row's text, and a mismatch is refused, so a misread
  position can't settle the wrong row.
- `done` needs `evidence`. `not-applicable` and `no-evidence` need a `reason`, and they mean
  different things: "this question doesn't arise" versus "nobody could check it here".

## Releases: a record opened before the work

Open the record when the release starts, not afterwards from a git log:

```
release_open { version: "1.4.0", channel: "stable", previous: "1.3.2" }
```

The version is fixed from then on. A published number is never reused or re-pointed.

Then record sections as the work produces them, with `release_record { release, section }`:

- `surfaces`: every file or place that carries the version, from a scan you ran. Rows neither
  updated nor exempt block the cut.
- `content`: every change in the range from `previous` to this release, reconciled both ways.
- `readiness`: the id of the checklist that gates the release.
- `approval`: who authorized it, on what evidence.
- `reversal`: how to take it back. `strategy` is rollback, roll-forward or none-available; for a
  rollback, give `target` and the command that proved the target still exists.
- `deploy`: one movement of bits into an environment.
- `observation`: what an environment actually reports running, with a freshness bound.
- `deprecation`, `obligation`, `amendment`: a dated removal, a debt owed to a later release, and
  a correction recorded beside the original rather than over it.

Move it through `planned → cut → published → available`, or to `superseded`, `withdrawn`,
`abandoned` or `failed`, with `release_transition`. A withdrawal keeps the record and requires the
reason, what consumers may still hold, and what they must do.

`release_status` answers what is in flight, what each release still owes, and what each environment
last reported. A report older than its freshness bound reads UNKNOWN.

## Caching a model's answer

For repeated expensive questions, keep the answer against the question's embedding:

```
cache_store  { question, answer, embedding: { vector, model }, keep_seconds: 86400 }
cache_lookup { embedding: { vector, model }, threshold: 0.95 }
```

- `keep_seconds` is required (1 to 2 592 000, i.e. thirty days), because only you know how fast
  the answer goes stale.
- `threshold` is required (above 0, at most 1). A hit is marked `cached`, with the similarity and
  when it was kept. A miss says how close the nearest came. Expired answers are never returned.
- Vectors are only compared with vectors from the same `model`.

## Logging what happened

`activity_log { verb, object: { table, id }, note }`, with `verb` one of `created`, `updated`,
`closed`, `superseded`, `claimed`, `released`, `promoted`, `validated`. It changes nothing; it makes
the history answerable later. Log the acts other agents would want to reconstruct.
