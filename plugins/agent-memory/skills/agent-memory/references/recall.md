# Reading well with `recall`

`recall` combines words, topic filters, links and (optionally) a vector into one ranked list. Each
hit says what found it.

## Scope: where it looks

A scope has three levels: an **identity** (who owns the data), a **group** of projects, and a
**project**. Your session works in the project your folder resolved to.

- By default a read looks at **exactly your scope**. Records kept at the group or identity level
  above your project are *not* included.
- To look somewhere else as well, name it on purpose:

```
recall { text: "rate limiter", reach: { reach: "also",
         scope: { identity: "acme", group: "platform" } } }
```

When a search finds nothing but you are sure something exists, the usual cause is scope. Widen
deliberately rather than concluding the store is empty.

## Words

`text` is matched against memories, facts and records. Use the words the writer would have used:
names of components, error messages, file names. Several short searches beat one long sentence.

From `0.3.0-alpha`, memories and facts are ranked together as one collection, so a record holding
more of your words ranks above one holding fewer, whichever kind it is. Common English words (`the`,
`of`, `is`, `how`) do not count toward a match, and any of your words is enough to find a record.
The analyzer folds case, accents and word endings, so `deploy` also finds `deployed`.

A word ending in `*` is a prefix: `auth*` finds `authorize` and `authentication`. A starred word
shorter than three letters is searched as the plain word.

## Topics

`topics` restricts the search to a closed set of subjects: `architecture`, `decision`, `pattern`,
`invariant`, `domain-rule`, `failure-mode`, `integration`, `performance`, `security`, `operations`,
`tooling`, `constraint`. The set is closed so that a filter filters, rather than matching nothing
because of an invented topic.

## Following links

`hops` (0 to 3) also returns what the hits link to: a goal's tasks, a task's blockers, related
facts. The default of 0 is the ordinary case. More than 3 is refused rather than quietly reduced,
because an unbounded walk over a well-linked store returns the whole store.

## Vectors

If you can produce embeddings, pass `similar_to: { vector, model }` (384 numbers). With `text` as
well, each family is ranked by words and vector together, and each hit says which of the two found
it. Vectors are compared only within the same `model`. A wrong width is refused instead of
returning results that are all infinitely far away.

## Page size

`page: { limit: n }` caps the answer. The default is small on purpose. Paging forward with
`page.after` is **not** available on a ranked search: the ranking is recomputed on every call, so
a position from one call names nothing in the next. Narrow the query instead.

## Witnesses: what did the agent see when it decided?

```
recall { text: "deploy freeze", witness: true }
```

This keeps the query and the version of every hit, and the answer's hints carry a witness key.
Later,

```
recall_replay { witness: "<key>" }
```

shows each hit's text as it was seen, read from the store's own history, beside what it says now.
Use it when a decision rested on what the store said at the time, and someone later asks why.

## Habits that pay off

- Recall before you research, and again before you write a new fact. The fact may already exist,
  and then you should supersede or link it rather than duplicate it.
- When a recall changes your plan, say so in your reasoning and name the record, so a reader can
  follow it.
- Treat a memory as a lead, not proof. Memories may be wrong by design. Facts carry a confidence
  and evidence; check the evidence when the stakes are real.
