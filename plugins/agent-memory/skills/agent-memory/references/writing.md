# Writing well

## A memory: `remember`

```
remember { kind: "semantic",
           body: "The importer drops rows whose date is in DD.MM.YYYY; it only parses ISO 8601." }
```

`kind` decides how long the memory lives and what it is for:

| kind | for |
|---|---|
| `working` | scratch for the task in hand; short-lived |
| `episodic` | what happened in a session ("tried X, it failed because Y") |
| `semantic` | how something is ("service A calls B over gRPC with a 2 s deadline") |
| `procedural` | how to do something ("to rebuild the index, run …") |
| `instruction` | something a person told you to do or not do |
| `uncertainty` | something you are unsure of and want checked |

Write the body so it stands on its own. The reader will not have your context: give names, paths,
numbers and the reason, not "as discussed". One memory, one thing. Several small memories are found
more reliably than one long one.

`learned_at` (milliseconds since the epoch) records when you came to know it, if that wasn't now.
`scope` writes somewhere other than your own project. Leave it out unless you mean it.

## A project fact: `remember` with `as_fact`

A fact is something the project vouches for. Ask for one only when you can point at evidence:

```
remember { kind: "semantic", body: "…the full explanation…",
           as_fact: { title: "Importer accepts ISO dates only",
                      statement: "The CSV importer parses dates as ISO 8601 and drops other formats.",
                      topic: "failure-mode", confidence: "confirmed", provenance: "code-audit",
                      evidence: [{ kind: "code", locator: "src/import/csv.rs:142" }] } }
```

- `statement` is **one** claim. A fact that says three things can't be superseded cleanly, because
  the next finding refutes one and leaves the other two standing.
- `confidence` is `confirmed`, `probable` or `hypothesis`. `confirmed` needs `evidence` and is
  refused without it.
- `evidence` items have a `kind` (`code`, `document`, `external`, `commit`) and a `locator` (path,
  URL or commit). A `note` says what to look at there.
- `provenance` says where the claim came from: `user`, `research`, `code-audit`, `conversation`,
  `adr`, `bug-resolution`, `external-doc`.
- `topic` is one of `architecture`, `decision`, `pattern`, `invariant`, `domain-rule`,
  `failure-mode`, `integration`, `performance`, `security`, `operations`, `tooling`, `constraint`.

Before writing a fact, `recall` for it. If it exists, link to it or supersede it rather than writing
a second copy.

## Embeddings

If you can produce an embedding of the text, pass it as `embedding: { vector, model }` so `recall`
can find the memory by meaning. It must be 384 numbers wide. Any other width is not stored, but the
memory still is, and the answer says so. Vectors are only compared with vectors from the same model.

## A project record: `item_add`

Goals, tasks, plans, questions, decisions, risks, ideas, rules, documents and checklists. Each
family requires its own fields, and a missing one is refused by name. See workflows.md for every
family with an example.

## That something happened: `activity_log`

```
activity_log { verb: "closed", object: { table: "task", id: "<task id>" }, note: "tests green" }
```

`verb` is one of `created`, `updated`, `closed`, `superseded`, `claimed`, `released`, `promoted`,
`validated`. It changes nothing; it makes the history answerable later.
