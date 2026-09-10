# frozen_string_literal: true

require_relative "spica/version"
require_relative "spica/matcher"
require_relative "spica/index"

# Fuzzy subsequence search for palettes and quick-open interfaces.
module Spica
  # Base error class reserved for library-level failures.
  class Error < StandardError; end

  # Match a query subsequence and return its score and character positions.
  # @param query [String] valid query text
  # @param candidate [String] valid candidate text
  # @param options [Options] immutable scoring policy
  # @return [Match, nil] optimal alignment, or nil if there is no subsequence
  # @raise [ArgumentError] on invalid text/options
  def self.match(query, candidate, options: DEFAULT_OPTIONS, **settings)
    options = Options.new(**options.to_h.merge(settings)) unless settings.empty?
    Matcher.new(query, options).match(Candidate.new(candidate, 0, precompute_mask: false))
  end

  # Compute a score without reconstructing highlighted positions.
  # @return [Float] score, or negative infinity if the query does not match
  def self.score(query, candidate, options: DEFAULT_OPTIONS, **settings)
    options = Options.new(**options.to_h.merge(settings)) unless settings.empty?
    Matcher.new(query, options).score(Candidate.new(candidate, 0, precompute_mask: false)) || -Float::INFINITY
  end

  # One-shot ranked filtering. Reuse Index/Session for repeated queries.
  # @return [Array<Match>] at most limit results, sorted deterministically
  def self.filter(query, candidates, limit: nil, **settings)
    index = Index.new(candidates, **settings)
    index.session.tap { |session| session.query = query }.matches(limit || index.options.limit)
  end
end
