<h1 align="center">Spica</h1>

<p align="center">
  <strong>Pure Ruby fuzzy subsequence matching with scoring, highlights, and incremental filtering</strong>
</p>

<p align="center">
  <a href="https://rubygems.org/gems/spica"><img src="https://img.shields.io/gem/v/spica.svg?colorB=319e8c" alt="Gem version"></a>
  <a href="https://rubygems.org/gems/spica"><img src="https://img.shields.io/gem/dt/spica.svg" alt="Gem downloads"></a>
  <a href="https://github.com/noxdea/spica/actions/workflows/main.yml"><img src="https://github.com/noxdea/spica/actions/workflows/main.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/ruby-%3E%3D%203.1-CC342D.svg" alt="Ruby 3.1 or newer">
  <a href="LICENSE.txt"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License"></a>
</p>

<p align="center">
  <a href="#features">Features</a> ·
  <a href="#installation">Installation</a> ·
  <a href="#quick-start">Quick Start</a> ·
  <a href="#api">API</a> ·
  <a href="#configuration">Configuration</a> ·
  <a href="#performance">Performance</a>
</p>

---

Spica is a fuzzy matcher for command palettes and quick-open lists. It ranks subsequence matches, returns the character positions to highlight, and reuses previous results as a query grows. It has no runtime dependencies or native extensions.

## Features

- fzy-style scoring with optimal alignments inside configurable length limits
- Highlight positions as Unicode character offsets
- Incremental filtering, prefix history, and cached backspace results
- Deterministic ranking with configurable tie-breaking and path bonuses
- Smart-case, case-sensitive, and case-insensitive matching
- Mutable indexes with immutable candidate records and results
- RBS type signatures

## Installation

Add Spica to your Gemfile:

```ruby
gem "spica"
```

Then run:

```sh
bundle install
```

Or install it directly:

```sh
gem install spica
```

Spica requires Ruby 3.1 or newer. A C compiler is only used by an optional development oracle.

## Quick start

```ruby
require "spica"

candidates = ["app/models/user.rb", "app/models/order.rb", "README.md"]

Spica.filter("amu", candidates, limit: 3).each do |match|
  p [match.candidate, match.positions]
end

# ["app/models/user.rb", [0, 4, 11]]
```

## API

### One-shot matching

```ruby
Spica.score("amf", "app/models/foo.rb")
# => a Float, or -Float::INFINITY when there is no match

match = Spica.match("amu", "app/models/user.rb")
match.candidate # => "app/models/user.rb"
match.score     # => weighted alignment score
match.positions # => [0, 4, 11]

Spica.match("xyz", "README.md")
# => nil
```

`Spica.filter` ranks a collection in one call. For repeated queries over the same candidates, use an index and session instead.

### Incremental filtering

```ruby
index = Spica::Index.new(paths)
session = index.session

session.query = "c"
session.matches(50)

session.query = "co"
session.matches(50) # rescans only the previous matches

session.query = "c"
session.matches(50) # reuses the cached result

index.add("new/file.rb")
index.remove("deleted/file.rb")
session.matches(50) # index changes invalidate the old history

session.total_matches # total before the display limit
```

Build one index per candidate collection and one session per independent palette. Serialize index mutations, and do not share a session between concurrent callers.

Indexes deduplicate identical text. Removing and re-adding a candidate assigns it a new registration ID. Input strings are copied when needed, and returned matches, positions, and result arrays are frozen.

`Match#text` aliases `candidate`; `Match#index` is the stable registration ID. A session keeps the active prefix chain, while an unrelated query restarts from the full index. Display limits never discard candidates needed by the next query.

## Configuration

Pass settings directly or reuse an immutable `Spica::Options` instance:

```ruby
options = Spica::Options.new(
  case_sensitivity: :smart,
  path_mode: true,
  limit: 100,
  tie_break: :shorter
)

index = Spica::Index.new(paths, options:)
Spica.match("cf", "core/File.rb", options:)
```

| Option | Default | Description |
| --- | --- | --- |
| `case_sensitivity` | `:smart` | `:smart`, `:sensitive`, or `:insensitive` |
| `path_mode` | `false` | Adds `basename_bonus` to nonconsecutive basename matches |
| `limit` | `100` | Default number of session results |
| `tie_break` | `:shorter` | Prefer shorter candidates, or use `:index` for registration order |
| `max_length` | `1024` | Longest candidate guaranteed to use optimal alignment |
| `max_query` | `256` | Longest query guaranteed to use optimal alignment |

The scoring weights are also configurable:

| Option | Default | Description |
| --- | ---: | --- |
| `consecutive` | 1.0 | Consecutive-character bonus |
| `slash` | 0.9 | Bonus at the candidate start and after a path separator |
| `boundary` | 0.8 | Bonus after a dash, underscore, or space |
| `camel` | 0.7 | Lowercase-to-uppercase boundary bonus |
| `dot` | 0.6 | Bonus after a dot |
| `leading_gap` | -0.005 | Gap penalty before the match |
| `inner_gap` | -0.01 | Gap penalty inside the match |
| `trailing_gap` | -0.005 | Gap penalty after the match |
| `case_bonus` | 0.0 | Exact-case bonus |
| `basename_bonus` | 0.2 | Path-mode basename bonus |

All weights must be finite real numbers. Default weights preserve the public fzy ranking cases; exact-case and basename bonuses are opt-in.

### Matching behavior

- Smart case is insensitive unless the query contains an uppercase character.
- Default ties use score descending, candidate character length ascending, then registration ID ascending.
- Exact matches score positive infinity; an empty query matches every candidate with score zero.
- Positions are Unicode character offsets, not byte or grapheme-cluster indices.
- Unicode text preserves positions through expanding lowercase mappings, but Spica does not normalize text or perform full Unicode case folding. For example, `ss` does not match `ß`.
- Candidates longer than `max_length` or queries longer than `max_query` use bounded-memory greedy alignment when an exact fast path is unavailable. They remain valid subsequence matches, but their score and positions may not be optimal.
- Spica does not provide edit distance, token rearrangement, transliteration, or phonetic matching.
- Invalid text and options raise `ArgumentError`.

## Performance

Measured on Ruby 4.0.0 with YJIT on arm64 macOS. Values are medians of five warmed runs. The representative corpus contains 100,000 paths; the first query retains 10,000 candidates, and the second scans those 10,000.

| Workload | Measured | Goal |
| --- | ---: | ---: |
| Build a 100,000-candidate index | 87.83ms | <400ms |
| First key, 100,000 → 10,000 matches | 4.93ms | <40ms |
| Second key `co`, 10,000 candidates | 2.39ms | <5ms |
| Noncontiguous `cm`, 10,000 candidates | 3.13ms | — |
| Longer `component_123` query | 2.82ms | — |
| Cached backspace | 0.002ms | <1ms |
| Stateless `score("amf", "app/models/foo.rb")` | 2.18µs | <3µs |
| First key matching all 100,000 candidates | 15.23ms | — |
| Second key still matching all 100,000 candidates | 11.54ms | — |

Performance depends on the candidate distribution and hardware; these are not worst-case guarantees. Retained candidate records measured 34.33MiB, excluding the index hash and input array. This exceeds the original roughly 10MiB design estimate and is not a passed memory target. Run `BUDGET=1 bundle exec rake bench` to reproduce the benchmark and its timing gates.

## Development

```sh
bundle install
bundle exec rake
bundle exec rake test:oracle
BUDGET=1 bundle exec rake bench
```

The test suite covers Unicode positions, randomized session and ranking behavior, deterministic ties, cache invalidation, malformed options, and comparisons with an independent dense recurrence. The native oracle uses the pinned [upstream fzy scorer](test/vendor/fzy/README.md); it is optional without a compiler and required in Linux CI.

## Contributing

Bug reports and pull requests are welcome on [GitHub](https://github.com/noxdea/spica).

## License

Spica is released under the [MIT License](LICENSE.txt). The test-only fzy sources retain their [upstream MIT license](test/vendor/fzy/LICENSE).

The name Spica comes from the part of a wheat ear that separates grain from chaff—much like this library separates useful matches from a large candidate list.
