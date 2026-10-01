# Full-text search

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
`stemmer(german)`, `stemmer(french)` or `stemmer(spanish)`. There is no n-gram filter: prefix,
infix and fuzzy matching are query operators instead (below).

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
- `MATCHES PREFIX`, `INFIX` and `FUZZY` read every word of the query that way. `FUZZY` allows
  small misspellings. Prefixes and infixes must be at least three characters (`PrefixTooShort`).
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

**Never add scores from different fields or engines.** Two scores are on different scales. To combine
rankings, use `ORDER BY FUSE`, which fuses by rank:

```tessariql
DEFINE INDEX by_title ON notes FIELDS title SEARCH;
SELECT id FROM notes
ORDER BY FUSE (search::score(body, 'first'), search::score(title, 'compilers'))
LIMIT 3;
```

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
