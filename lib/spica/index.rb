# frozen_string_literal: true

module Spica
  # Mutable registry; immutable candidate records can be shared by sessions.
  class Index
    attr_reader :options, :generation

    # @param candidates [Array<String>] initial candidate collection
    # @param options [Options] shared immutable scoring policy
    def initialize(candidates = [], options: DEFAULT_OPTIONS, **settings)
      @options = settings.empty? ? options : Options.new(**options.to_h.merge(settings))
      @entries, @sequence, @generation = {}, 0, 0
      add(candidates)
    end

    # Add unique text, retaining monotonic registration IDs.
    # @return [self]
    def add(candidates)
      Array(candidates).each do |text|
        next if @entries.key?(text)
        candidate = Candidate.new(text, @sequence)
        next if @entries.key?(candidate.text)
        @entries[candidate.text] = candidate
        @sequence += 1
        @generation += 1
      end
      self
    end

    # Remove text and invalidate active session histories via generation.
    # @return [self]
    def remove(candidates)
      Array(candidates).each do |text|
        raise ArgumentError, "candidate must be valid text" unless text.is_a?(String) && text.valid_encoding?
        @generation += 1 if @entries.delete(text.encode(Encoding::UTF_8))
      end
      self
    rescue EncodingError => error
      raise ArgumentError, "candidate encoding: #{error.message}"
    end

    # @return [Integer] number of registered unique candidates
    def size = @entries.size
    # @return [Array<Candidate>] immutable records in registration order
    def candidates = @entries.values
    # @return [Session] independent query history over this index
    def session = Session.new(self)
  end

  # Incremental match sets and cached top results. A session is thread-confined;
  # separate sessions keep independent query history and reusable DP scratch.
  class Session
    # Session-owned cached match set, scorer and largest requested top list.
    Snapshot = Struct.new(:candidates, :scores, :matcher, :top_limit, :top_matches)
    private_constant :Snapshot
    attr_reader :query

    # @param index [Index] registry observed for generation changes
    def initialize(index)
      @index, @query, @generation = index, "", -1
      @history = {}
      @shorter = index.options.tie_break == :shorter
    end

    # Narrow the previous match set or restore a cached query prefix.
    # @param query [String] new query (copied/frozen internally)
    # @return [String] caller's query
    def query=(query)
      raise ArgumentError, "query must be valid text" unless query.is_a?(String) && query.encoding.ascii_compatible? && query.valid_encoding?
      @query = query.encode(Encoding::UTF_8).freeze
      refresh
      query
    rescue EncodingError => error
      raise ArgumentError, "query encoding: #{error.message}"
    end

    # Select only the best candidates, then reconstruct their highlights.
    # @return [Array<Match>] frozen deterministic result list
    def matches(limit = @index.options.limit)
      raise ArgumentError, "limit must be nonnegative" unless limit.is_a?(Integer) && limit >= 0
      refresh
      state = @history.fetch(@query)
      limit = [limit, state.candidates.length].min
      if state.top_matches && limit <= state.top_limit
        return limit == state.top_limit ? state.top_matches : state.top_matches.first(limit).freeze
      end
      state.top_limit = limit
      state.top_matches = best_matches(state, limit)
    end

    # @return [Integer] complete match count, independent from display limit
    def total_matches
      refresh
      @history.fetch(@query).candidates.length
    end

    private

    def best_matches(state, limit)
      candidates, scores = state.candidates, state.scores
      heap = []
      unless limit.zero?
        candidates.each_index do |index|
          if heap.length < limit
            heap << index
            child = heap.length - 1
            while child.positive?
              parent = (child - 1) / 2
              break unless better?(heap[parent], heap[child], candidates, scores)
              heap[parent], heap[child] = heap[child], heap[parent]
              child = parent
            end
          elsif better?(index, heap[0], candidates, scores)
            heap[0] = index
            parent = 0
            loop do
              left = parent * 2 + 1
              break if left >= heap.length
              right = left + 1
              child = right < heap.length && better?(heap[left], heap[right], candidates, scores) ? right : left
              break unless better?(heap[parent], heap[child], candidates, scores)
              heap[parent], heap[child] = heap[child], heap[parent]
              parent = child
            end
          end
        end
      end
      heap.sort! { |a, b| compare(a, b, candidates, scores) }
      heap.map { |index| state.matcher.match(candidates[index]) }.freeze
    end

    def better?(a, b, candidates, scores)
      left, right = scores[a], scores[b]
      return left > right unless left == right
      x, y = candidates[a], candidates[b]
      return x.length < y.length if @shorter && x.length != y.length
      x.index < y.index
    end

    def compare(a, b, candidates, scores)
      comparison = scores[b] <=> scores[a]
      return comparison unless comparison.zero?
      x, y = candidates[a], candidates[b]
      comparison = x.length <=> y.length if @shorter
      comparison.zero? ? x.index <=> y.index : comparison
    end

    def refresh
      if @generation != @index.generation
        @history.clear
        @generation = @index.generation
      end
      return if @history.key?(@query)
      prefix = @history.keys.select { |key| @query.start_with?(key) }.max_by(&:length)
      candidates = prefix ? @history[prefix].candidates : @index.candidates
      matcher = Matcher.new(@query, @index.options)
      matched, scores = [], []
      candidates.each do |candidate|
        score = matcher.score(candidate)
        next unless score
        matched << candidate
        scores << score
      end
      # Keep only the current prefix chain, including cached top lists so a
      # backspace never has to score or select those results again.
      @history.delete_if { |key, _| !@query.start_with?(key) }
      @history[@query] = Snapshot.new(matched.freeze, scores.freeze, matcher)
    end
  end
end
