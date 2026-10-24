# Full-text search

Checked against TessariDB 0.38.4. Full detail: <https://docs.tessaridb.com/query-language/full-text-search>.

Text becomes searchable in three steps: declare an **analyzer** (how text becomes terms), put it
on a **field**, and add a **SEARCH index** on that field when you want speed and scores.

## Analyzer, field, index

```tessariql
DEFINE ANALYZER english FILTERS lowercase, ascii, stemmer;
DEFINE COLLECTION notes;
DEFINE FIELD body ON notes TYPE string ANALYZER english;
DEFINE FIELD title ON notes TYPE string ANALYZER english;
DEFINE INDEX by_body ON notes FIELDS body SEARCH;
CREATE notes:1 = { title: 'Ada', body: 'Ada Lovelace wrote the first program' };
CREATE notes:2 = { title: 'Compilers', body: 'Grace Hopper wrote the first compiler' };
CREATE notes:3 = { title: 'Engines', body: 'Charles Babbage designed the analytical engine' };
SELECT * FROM notes WHERE body MATCHES 'programs';
```

There are three filters: `lowercase`, `ascii` (folds `café` to `cafe`) and `stemmer` (English
Porter2, so `programs` matches `program`). For other languages use `stemmer(russian)`,
`stemmer(german)`, `stemmer(french)` or `stemmer(spanish)`. There is no n-gram filter (naming one is
refused, `NgramFilter`): prefix, infix and fuzzy matching are query operators instead (below). Chinese
and Japanese text is split one ideograph or kana per token, so a quoted run of them matches exactly.

**Order matters.** Write `lowercase, ascii, stemmer`. The stemmer leaves alone a word that still
has a capital letter, so `stemmer, lowercase` quietly stems almost nothing, and searches just
return fewer rows. The analyzer belongs to the field: a field with no analyzer holds no terms, and
`MATCHES` on it finds nothing.

An analyzer can't be redefined. `DEFINE ANALYZER IF NOT EXISTS` with a different chain answers `ok`
and changes nothing. To change a chain, define one under a **new name** and point the field at it.

## Matching

```tessariql
SELECT * FROM notes WHERE body MATCHES 'first program';
SELECT * FROM notes WHERE body MATCHES '"the first compiler"';
SELECT * FROM notes WHERE body MATCHES 'hopper OR babbage';
SELECT * FROM notes WHERE body MATCHES 'first NOT hopper';
SELECT * FROM notes WHERE body MATCHES 'lovel*';
SELECT * FROM notes WHERE body MATCHES PREFIX 'lovel';
SELECT * FROM notes WHERE body MATCHES INFIX 'abbag';
SELECT * FROM notes WHERE body MATCHES FUZZY 'babbgae';
```

- Several words are all required. Quotes make a phrase.
- `OR` and `NOT` combine words. A trailing `*` makes a prefix of that one word.
- `MATCHES PREFIX`, `INFIX` and `FUZZY` read every word of the query that way. Prefixes and infixes
  must be at least three characters (`PrefixTooShort`).
- `FUZZY` allows no edit below three letters, one up to five and two beyond, and never in the first
  two characters. A misspelling is measured against the word as the text held it, not only its stem,
  so `trasnactoin` finds `transaction`. A `SEARCH` index built before 0.22.0-beta needs
  `REBUILD INDEX` for that; until then a fuzzy read over it scans, with the same answers.
- After upgrading to 0.26.0-beta or later, rebuild every full-text index once (`REBUILD INDEX`, or
  redefine a `DEFINE SEARCH`). An index built by an older tokenizer is not used until then: reads
  scan, and a search carries a `needs-rebuild` note. `search::score` now scores fuzzy matches.
- `MATCHES` works with or without an index. Without one, it scans and re-analyses each record.

## Scoring, ranking and highlighting

```tessariql
SELECT id, search::score(body, 'compiler') AS relevance FROM notes ORDER BY relevance DESC;
SELECT * FROM notes ORDER BY search::score(body, 'first') DESC LIMIT 2;
SELECT search::highlight(body) AS marks FROM notes WHERE body MATCHES 'lovelace';
SELECT id, search::explain(body, 'first compiler') AS why FROM notes WHERE body MATCHES 'first';
```

- `search::score` is BM25 and needs a `SEARCH` index on the field, because a score is measured
  against the collection.
- `search::highlight(field)` returns byte ranges `{ start, end }` of the words the query reached.
  It marks the matched terms, so stems and fuzzy matches are marked too.
- `search::explain` shows why a record scored what it did.
- Index options: `SEARCH POSITIONS OFFSETS` keeps what phrases and highlighting need to be served
  from the index; `SEARCH NO SCORE` keeps an index that only filters.

- A ranked read with a `LIMIT` scores only what it must and stays exact: `EXPLAIN` shows
  `access: 'ordered', shape: 'scored', exact: true`. Without a `LIMIT`, every record is scored.
- `search::score` over a field with no `SEARCH` index is refused (`NoSearchIndex`), not answered
  with a number that orders nothing.
- A query term the collection doesn't hold gets a suggestion printed beside the answer
  (`did you mean: hoppr -> hopper`). The suggestion is **never** run in its place.
- `NOT` alone (`MATCHES 'NOT babbage'`) is refused: it names every record the index doesn't hold.

**Weighting two text fields of one table** is ordinary arithmetic over their scores, each field
with its own `SEARCH` index: `search::score(title, 'lock') * 3 + search::score(body, 'lock')`. A
field the record doesn't match contributes `0`, so a weight never invents relevance.

**Never add scores from different engines** (a text score, a vector distance, a distance in
metres): they are on different scales and the one with the larger range decides alone. Combine
them with `ORDER BY FUSE`, which ranks by each record's **place** in each order:

```tessariql
DEFINE INDEX by_title ON notes FIELDS title SEARCH;
SELECT id FROM notes
ORDER BY FUSE (search::score(body, 'first') DESC WEIGHT 2, search::score(title, 'compilers') DESC)
LIMIT 3;
SELECT id, search::ranks() AS ranks FROM notes
ORDER BY FUSE (search::score(body, 'first') DESC, search::score(title, 'compilers') DESC) LIMIT 2;
```

- Each branch is an order with its own direction. A record placed in a branch's first `DEPTH`
  places (default 100) earns `weight / (60 + place)`; the fused order is the sum.
- A record no branch placed is not in the answer, so a `LIMIT` can answer with fewer.
- The `WHERE` applies to every branch, and a fused read is exact (`APPROXIMATE` is ignored there).
- `search::ranks()` gives each branch's place for the record, `none` where it wasn't placed.
- One branch alone, a zero weight, `GROUP BY` or an `AFTER` cursor beside `FUSE` is refused.

## One search over several fields and tables: `DEFINE SEARCH`

When one ranking should cover several fields, or several tables, declare a search. It has one
analyzer, one set of statistics and per-field weights (BM25F), and each table keeps its own grants.

```tessariql
DEFINE ANALYZER plain FILTERS lowercase, ascii;
DEFINE COLLECTION articles;
CREATE articles:1 = { headline: 'Engines of thought', text: 'Babbage designed an engine; Lovelace saw what it could do', code: 'AE-1' };
DEFINE SYNONYMS machines { engine: ['loom', 'machine'] };
DEFINE STOPWORDS common ['the', 'a', 'of'];
DEFINE SEARCH knowledge
  ON notes    FIELDS title WEIGHT 3 SNIPPET, body SYNONYMS machines
  ON articles FIELDS headline WEIGHT 2, text, code NO FUZZY NO PREFIX
  ANALYZER plain STOPWORDS common;
```

```tessariql
SELECT search::table_name() AS source, search::score() AS score
FROM SEARCH knowledge MATCHES 'lovelace';
SELECT search::table_name() AS source, search::snippet() AS window
FROM SEARCH knowledge MATCHES 'ada';
SELECT term, documents FROM SEARCH knowledge COMPLETE 'lov';
```

- Results come best first. `ORDER BY` over a search is refused (`SearchIsItsOwnOrder`), because
  the search already ranks.
- `search::score()`, `search::table_name()`, `search::snippet()` (the best 24-word window of a
  `SNIPPET` field, as byte offsets) and `search::highlight(field)` only work in a `FROM SEARCH`
  read.
- `COMPLETE 'prefix'` is type-ahead: the search's words beginning with the prefix, ranked by how
  many records hold them. With a stemming analyzer they are stems, so build type-ahead on an
  unstemmed search.
- Per-field options: `WEIGHT n`, `SNIPPET`, `SYNONYMS <set>`, `NO FUZZY`, `NO PREFIX`, `NO PHRASE`.
  Synonyms and stop words apply when the search runs, so changing them needs no rebuild.
- A table the reader can't read, or a member with a field they can't read, is left out of the
  search, statistics included. Scores never leak another table's words.
- Facets are a grouping over the same source: `SELECT kind, count(*) AS n FROM SEARCH s MATCHES 'x'
  GROUP BY kind`.
- `INFO FOR SEARCH name` describes it. `DROP SEARCH name` removes it and leaves the tables alone.

## Checking that search does what you think

- `EXPLAIN SELECT … WHERE body MATCHES '…'` should say `access: 'index'` once an index exists.
- To compare two configurations, run the same `MATCHES` against a copy of the table with no index:
  the record sets must be equal. Never benchmark against a read that has no `WHERE`; it answers a
  different question.
- For ranking changes, keep a small list of real queries with the records that should come first,
  and measure recall@10 before and after. Don't judge ranking by eye.
