# Spica

A pure Ruby fuzzy subsequence matcher with scores, highlight positions and incremental filtering for command palettes and quick-open lists.

Edit-distance similarity is not enough for a palette: `amu` should find `app/models/user.rb`, rank its alignment, and tell the UI which characters to highlight. Spica combines that contract with reusable candidate preprocessing and query history. It requires Ruby 3.1+ and has no runtime gems or native extensions.

## Five-line example

```ruby
require "spica"
index = Spica::Index.new(["app/models/user.rb", "app/models/order.rb", "README.md"])
session = index.session
session.query = "amu"
p session.matches(50).map { |match| [match.candidate, match.score, match.positions] }
```

## Installation

```sh
gem install spica
```

## Stateless or incremental

```ruby
Spica.score("amf", "app/models/foo.rb")  # Float; -Float::INFINITY if absent
match = Spica.match("amu", "app/models/user.rb")
match.positions                           # [0, 4, 11]
match.score                               # optimal weighted alignment score
Spica.match("xyz", "README.md")          # nil
Spica.filter("srcm", candidates, limit: 50)  # Array<Match>
```

Positions are Unicode **character offsets**, not bytes or grapheme-cluster indices. Results, their strings/positions, and returned top arrays are immutable. `Match#text` aliases `candidate`; `index` is the stable registration ID.

```ruby
index = Spica::Index.new(paths)
session = index.session
session.query = "c";   session.matches(50)
session.query = "co";  session.matches(50)  # only previous matches are rescored
session.query = "con"; session.matches(50)
session.query = "co";  session.matches(50)  # cached match set and results

index.add(["new/file.rb"])
index.remove(["deleted/file.rb"])
session.matches(50)                    # index generation invalidates old history
session.total_matches                  # all matches, not only the first 50
```

Indices deduplicate identical text; removing and re-adding a path gives it a new registration ID. Original input strings can be edited without changing indexed records. A session retains the active prefix chain; unrelated pasted queries restart from the full index. Limiting the displayed top list never discards candidates needed for the next query.

A larger `matches(limit)` recomputes partial selection; a repeated or smaller limit reuses cached results. Build one Index per candidate collection and one Session per independent palette. Candidate records and Options are frozen, while Index mutations and Session operations are explicitly stateful: serialize mutations, and do not share a Session between concurrent callers.

## Scoring and options

The score is an optimal fzy-style subsequence alignment for inputs within the configured ceilings. A sparse D/M recurrence visits matching positions, carrying the best intervening-gap score instead of materializing every matrix cell. Score-only scans reuse two rows; highlight backtracking runs only for selected results. One-/two-character queries have equivalent scalar recurrences, and a contiguous match can stop early only when it reaches a proven global score upper bound.

The subsequence precheck also scores an alignment directly when every remaining query character has exactly one occurrence. Ambiguous alignments still use the full recurrence. Membership masks and DP scratch rows are prepared only when needed, avoiding unused preprocessing in stateless calls.

```ruby
options = Spica::Options.new(
  case_sensitivity: :smart,  # :smart, :insensitive, :sensitive
  path_mode: true,
  limit: 100,
  tie_break: :shorter
)
index = Spica::Index.new(paths, options:)
Spica.match("cf", "core/File.rb", options:)
```

Smart case is case-insensitive unless the query contains an uppercase character. Default ties are resolved by score descending, candidate character length ascending, then registration ID ascending. `tie_break: :index` skips the length criterion. Exact matches score positive infinity; an empty query matches every candidate with score zero.

Default weights preserve the upstream public fzy ranking cases:

| Option | Default |
| --- | ---: |
| `consecutive` | 1.0 |
| `slash` (also start of candidate / Windows separator) | 0.9 |
| `boundary` (after dash, underscore or space) | 0.8 |
| `camel` | 0.7 |
| `dot` | 0.6 |
| `leading_gap` / `trailing_gap` | -0.005 |
| `inner_gap` | -0.01 |
| `case_bonus` (exact-case micro-bonus, opt-in) | 0.0 |
| `basename_bonus` (used when `path_mode: true`) | 0.2 |

Path mode adds a configurable bonus to nonconsecutive matches within the basename. Its default is off for fzy-compatible ranking. All weights are configurable finite real numbers; millipoint-exact weights use integer internal arithmetic so mathematically equal scores do not flicker from floating-point accumulation order.

The index precomputes folded ASCII strings, a 128-bit membership mask plus Unicode membership, boundary codes and basename offsets. Non-ASCII text keeps one lowercase mapping per original character. This preserves highlight positions through expanding lowercase mappings, but deliberately does not perform full Unicode case folding, normalization or grapheme matching: `ss` is not a substitute for `ß`, and composed/decomposed text is not silently normalized.

Candidates longer than `max_length: 1024` or queries longer than `max_query: 256` use bounded-memory greedy alignment when an exact fast path is unavailable. They remain valid subsequence matches, but their score/positions are not promised optimal. No edit distance, token rearrangement, transliteration or phonetic matching is performed. Invalid text/options raise `ArgumentError`.

## Verification

```sh
bundle install
bundle exec rake
bundle exec rake test:oracle
BUDGET=1 bundle exec rake bench
rbs -I sig validate
yard doc
```

Tests include 2,000 Unicode position properties, 3,000 comparisons against an independent dense recurrence with varied weights, randomized heap/top and session consistency, encoding/case behavior, deterministic ties, cache invalidation and malformed options.

The optional native oracle compiles the pinned, unmodified [upstream fzy scorer](test/vendor/fzy/README.md) in a temporary directory. It checks **all eight public ranking assertions** plus 500 seeded ASCII score comparisons. A compiler is only needed for this development oracle; the library works with `ruby --disable-gems`. `FZY_REQUIRED=1` makes a missing compiler fail instead of skip. Linux CI requires the oracle; macOS/Windows run it when a compiler is available. Isolation checks build/install the gem into a temporary GEM_HOME and emit results without development/application dependencies.

## Measured performance

Ruby 4.0.0 + YJIT, arm64 macOS; median of five warmed runs. The representative corpus has 100,000 paths, of which the first query `c` retains 10,000; the next query scans those 10,000. Timings include `query=` and `matches(50)`.

| Workload | Measured | Goal |
| --- | ---: | ---: |
| Build 100,000-candidate index | 87.83ms | <400ms |
| First key, 100,000 → 10,000 matches | 4.93ms | <40ms |
| Second key `co`, 10,000 candidates | 2.39ms | <5ms |
| Noncontiguous `cm`, 10,000 candidates | 3.13ms | — |
| Longer `component_123` query | 2.82ms | — |
| Cached backspace | 0.002ms | <1ms |
| Stateless `score("amf", "app/models/foo.rb")` | 2.18µs | <3µs |
| Adversarial first key matching all 100,000 | 15.23ms | — |
| Adversarial second key still matching all 100,000 | 11.54ms | — |

The 5ms second-key target applies to the specified **10,000 remaining candidates**, not 100,000 matches. The benchmark retains and reports the all-hit stress case separately. Performance depends on candidate/query distribution and hardware; these measurements are not worst-case guarantees.

A subsequent stateless-score CI regression check compared `4af16c3` with the unique-alignment/lazy-preparation fix on Ruby 4.0.6 + YJIT, Linux arm64, Bundler 4.0.19. Three alternating `BUDGET=1 bundle exec rake bench` pairs (each reporting five warmed runs) reduced the median stateless call from 2.62µs to 1.20µs; all gates passed in all three corrected runs. The same-call allocation count fell from 15 to 6 objects. The original failing GitHub x86_64 runner measured 5.17µs; these local measurements are not a rerun on that hardware. Neither the 3µs limit nor the benchmark workload was changed.

Retained candidate records measured 34.33MiB, about 360 bytes per candidate, excluding the Index hash and input array. This exceeds the design estimate of roughly 100 bytes per candidate / 10MB for 100,000; it is a known Ruby object-overhead tradeoff, not a passed memory target. `bench/search.rb` reports both timing gates and retained-size measurements.

## Name and license

A spica separates grain from chaff; this library separates useful palette matches from a large candidate list. MIT, see [LICENSE.txt](LICENSE.txt). Test-only fzy sources retain their [upstream MIT license](test/vendor/fzy/LICENSE).
