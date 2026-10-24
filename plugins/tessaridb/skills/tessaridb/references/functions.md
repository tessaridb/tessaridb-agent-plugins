# Functions and aggregates

Checked against TessariDB 0.38.3; every name below answered on that build. The page with examples
for each is <https://docs.tessaridb.com/reference/functions>.

A call is an ordinary expression and stands wherever a value stands. Every name is
`family::name`, so a function never collides with a field. A function earns a place only when the
language can't already say it: there is no `array::contains` because `CONTAINS` says it.

## The rule for missing and wrong values

- **An absence narrows.** A call over a field the record doesn't have answers with an absence, and
  an absence in a condition is false, so the record drops out instead of failing the read.
  `WHERE array::len(tags) > 0` skips records without `tags`.
- **A wrong type refuses.** A value that is present and of the wrong type is `WrongArgument`; the
  wrong number of arguments is `WrongArity` before anything runs; an unknown name is
  `NoSuchFunction`.
- Four answer for an absence instead of propagating it: `type::of` answers `none`, the three
  `vector::` distances answer `+∞`, and `search::score` answers `0`.
- Overflow and division by zero are refusals, never infinities or wrapped numbers.

## Strings (characters, not bytes)

| function | answers |
|---|---|
| `string::len(t)` | number of characters |
| `string::lower(t)`, `string::upper(t)` | case changed |
| `string::trim(t)`, `string::trim_start(t)`, `string::trim_end(t)` | whitespace removed |
| `string::concat(a, b, …)` | two or more strings joined |
| `string::split(t, sep)` | an array of pieces |
| `string::slice(t, start, count)` | `count` characters from `start` (from 0) |
| `string::lines(t, start, count)` | `count` lines from `start`: page a long body without knowing offsets |
| `string::replace(t, from, to)` | every occurrence replaced |
| `string::contains(t, needle)`, `string::starts_with(t, p)`, `string::ends_with(t, s)` | text tests (plain text, not `LIKE` patterns) |
| `string::index_of(t, needle)` | position in characters, or `none` (never `-1`) |
| `string::reverse(t)` | characters back to front |

`LIKE 'ka%'` (with `%` and `_`) is the pattern match.

## Arrays (one array in one record; the row aggregates are separate)

| function | answers |
|---|---|
| `array::len(a)`, `array::first(a)`, `array::last(a)` | length, first, last (absence when empty) |
| `array::distinct(a)`, `array::sort(a)`, `array::reverse(a)`, `array::flatten(a)` | reshaped |
| `array::join(a, sep)` | one string |
| `array::slice(a, start, count)` | a part |
| `array::append(a, v)` | one more element (an array appended is one element) |
| `array::concat(a, b)` | both arrays' elements |
| `array::index_of(a, v)` | first position, or `none` |
| `array::min(a)`, `array::max(a)`, `array::sum(a)` | folds over one array (`sum` of nothing is 0) |

## Objects

`object::keys(o)` (sorted), `object::values(o)`, `object::len(o)`, `object::entries(o)` (pairs,
name first), `object::has(o, name)` (present at all, even holding `none`), `object::merge(a, b)`
(`b` wins).

## Numbers

`math::abs`, `math::floor`, `math::ceil`, `math::round` (half away from zero), `math::trunc`
(toward zero), `math::sqrt`, `math::pow(base, exp)`, `math::exp`, `math::ln` (`none` at zero and
below), `math::sign`, `math::min(a, b)` and `math::max(a, b)` (two numbers, not a column).

## Time (UTC)

| function | answers |
|---|---|
| `time::now()` | the moment the statement ran (one instant per statement); not allowed in `ASSERT` |
| `time::bucket(at, 1h)` | `at` rounded down to a boundary, for grouping |
| `time::year`, `month`, `day`, `hour`, `minute`, `second` | calendar parts, in UTC |
| `time::unix(at)`, `time::from_unix(seconds)` | to and from epoch seconds |
| `duration::from_secs(n)` | a duration |

Arithmetic: `datetime ± duration` is an instant, `datetime − datetime` is a duration. There is no
time-zone argument: a zone belongs to how you display an instant.

## Casts and introspection

`type::bool`, `type::int`, `type::float`, `type::string`, `type::datetime`, `type::uuid` convert
text arriving from outside. There is no `type::number` or `type::decimal`. `type::of(v)` names a
value's type. `session::context()` answers `{ node, namespace, database }` for this session.

## Identifiers, digests, encoding, JSON

| function | answers |
|---|---|
| `rand::uuid()` | a fresh uuid, per record (safe as a `DEFAULT` in bulk inserts) |
| `crypto::sha256(t)`, `crypto::sha512(t)`, `crypto::sha1(t)`, `crypto::md5(t)` | lowercase hex digests; checksums, **never password hashing** |
| `encoding::base64(b)`, `encoding::base64_decode(t)`, `encoding::hex(b)`, `encoding::hex_decode(t)` | bytes to text and back (`none` for text that encodes nothing) |
| `json::parse(t)` | the value JSON text spells, or `none`; integers stay exact, `null` is `NULL` |
| `json::encode(v)` | compact JSON; keys in name order, decimals quoted, `NONE` fields left out |

## Vectors, shapes and ranking

- Distances: `vector::euclidean(a, b)`, `vector::cosine(a, b)`, `vector::dot(a, b)`
  ([vectors-geo-graphs.md](vectors-geo-graphs.md)).
- Shapes: `geo::intersects`, `disjoint`, `within` (boundary excluded), `covered_by` (boundary
  included), `contains`, `covers`, `touches`, `equals`, `geo::area(a)`, `geo::distance(a, b)`
  (metres, to the nearest point), `geo::cell(position, level)`.
- Ranking ([search.md](search.md)): `search::score(field, terms)`, `search::highlight(field)`,
  `search::explain(field, terms)`, `search::ranks()` (only under `ORDER BY FUSE`); inside
  `FROM SEARCH`: `search::score()`, `search::table_name()`, `search::snippet()`.

## Aggregates over rows

Used with `GROUP BY` (or over a whole read):

| aggregate | answers |
|---|---|
| `count(*)`, `count(f)` | rows, or rows where `f` is present |
| `sum(f)`, `mean(f)`, `min(f)`, `max(f)` | the usual folds; float sums are exact and rounded once |
| `median(f)`, `collect(f)` | the middle value; every value as an array (bounded) |
| `increase(f)`, `delta(f)`, `rate(f)` | counter folds for time series, resets included |
| `approx_distinct(f)` | distinct count, exact up to 1 024 values, then within about 2.5 % |
| `approx_quantile(f, q)` | the value at rank `q`, within about 1 % |

The two `approx_` folds attach an `estimated` note saying how the figure was estimated and its
bound; surface it.

```tessariql
DEFINE COLLECTION hits;
CREATE hits:1 = { at: datetime '2026-08-26T10:05:00Z', n: 3, who: 'a' };
CREATE hits = { at: datetime '2026-08-26T10:41:00Z', n: 4, who: 'b' };
CREATE hits = { at: datetime '2026-08-26T11:02:00Z', n: 5, who: 'a' };
SELECT time::bucket(at, 1h) AS hour, sum(n) AS total, count(*) AS rows FROM hits GROUP BY time::bucket(at, 1h);
SELECT approx_distinct(who) AS visitors, approx_quantile(n, 0.5) AS typical FROM hits;
SELECT at + duration::from_secs(90) AS later, at - 1h AS earlier FROM hits:1;
SELECT string::upper(who) AS who, crypto::sha256(who) AS fingerprint, type::of(n) AS kind FROM hits:1;
RETURN json::parse('{"b": 2, "a": [1, "x", null]}');
```

`GROUP BY` takes the expression itself, not its alias. A script answers with **one** `RETURN`:
two `RETURN` statements in one submitted script are refused.
