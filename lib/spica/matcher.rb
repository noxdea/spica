# frozen_string_literal: true

module Spica
  # Immutable scoring policy. Defaults preserve fzy's ranking.
  Options = Struct.new(:case_sensitivity, :path_mode, :limit, :tie_break,
                       :consecutive, :boundary, :slash, :camel, :dot, :basename_bonus,
                       :leading_gap, :inner_gap, :trailing_gap, :case_bonus,
                       :max_length, :max_query, keyword_init: true) do
    attr_reader :scoring
    def initialize(case_sensitivity: :smart, path_mode: false, limit: 100,
                   tie_break: :shorter, consecutive: 1.0, boundary: 0.8,
                   slash: 0.9, camel: 0.7, dot: 0.6, basename_bonus: 0.2,
                   leading_gap: -0.005, inner_gap: -0.01, trailing_gap: -0.005,
                   case_bonus: 0.0, max_length: 1024, max_query: 256)
      super
      raise ArgumentError, "invalid case sensitivity" unless %i[smart sensitive insensitive].include?(case_sensitivity)
      raise ArgumentError, "invalid tie break" unless %i[shorter index].include?(tie_break)
      raise ArgumentError, "path_mode must be boolean" unless path_mode == true || path_mode == false
      raise ArgumentError, "limit must be nonnegative" unless limit.is_a?(Integer) && limit >= 0
      %i[max_length max_query].each { |name| raise ArgumentError, "#{name} must be positive" unless self[name].is_a?(Integer) && self[name].positive? }
      %i[consecutive boundary slash camel dot basename_bonus leading_gap inner_gap trailing_gap case_bonus].each do |name|
        number = self[name]
        raise ArgumentError, "#{name} must be finite and real" unless number.is_a?(Numeric) && number.real? && number.to_f.finite?
        self[name] = number.to_f
      end
      bonuses = [0.0, self.slash, self.boundary, self.dot, self.camel]
      path = path_mode ? self.basename_bonus : 0.0
      weights = [*bonuses, self.leading_gap, self.inner_gap, self.trailing_gap, self.consecutive, self.case_bonus, path]
      scale = weights.all? { |weight| (weight * 1000).finite? && weight * 1000 == (weight * 1000).round } ? 1000.0 : 1.0
      weights.map! { |weight| (weight * scale).round } if scale == 1000.0
      bonuses = weights.shift(5).freeze
      leading, inner, trailing, consecutive_weight, case_weight, path_weight = weights
      max_bonus = bonuses.max + [case_weight, 0].max + [path_weight, 0].max
      contiguous = leading == trailing && inner <= leading && consecutive_weight >= bonuses.max + [path_weight, 0].max
      @scoring = [scale, bonuses, leading, inner, trailing, consecutive_weight, case_weight, path_weight, max_bonus, contiguous].freeze
      freeze
    end
  end
  # Shared immutable fzy-compatible default policy.
  DEFAULT_OPTIONS = Options.new

  # Immutable UI result; positions are Unicode character offsets, not bytes.
  Match = Struct.new(:candidate, :score, :positions, :index, keyword_init: true) do
    alias text candidate
    # @return [String] candidate text
    def to_s = candidate
  end

  # Compact ASCII representation; Unicode keeps per-character folds so an
  # expanding lowercase mapping never shifts the original highlight offsets.
  class Candidate
    # Shared byte used to allocate compact per-character boundary codes.
    ZERO_BYTE = "\0".b.freeze
    attr_reader :text, :chars, :folded, :mask, :unicode, :index, :basename,
                :bonuses, :length

    def ascii_only? = @ascii

    # @param text [String] candidate text, copied unless already immutable
    # @param index [Integer] registration ID for stable tie resolution
    # @param precompute_mask [Boolean] cache memberships for repeated queries
    def initialize(text, index, precompute_mask: true)
      raise ArgumentError, "candidate must be valid text" unless text.is_a?(String) && text.encoding.ascii_compatible? && text.valid_encoding?
      @text = text.encoding == Encoding::UTF_8 ? (text.frozen? ? text : text.dup.freeze) : text.encode(Encoding::UTF_8).freeze
      @index = index
      @ascii = @text.ascii_only?
      @basename = 0
      low = high = 0
      if @ascii
        @chars = @text
        @folded = @text.match?(/[A-Z]/) ? @text.downcase.freeze : @text
        @length = @text.bytesize
        @unicode = nil
        @bonuses = ZERO_BYTE * @length
        previous = 47
        position = 0
        while position < @length
          original = @text.getbyte(position)
          if precompute_mask
            folded = @folded.getbyte(position)
            if folded < 64
              low |= 1 << folded
            else
              high |= 1 << (folded - 64)
            end
          end
          kind = if previous == 47 || previous == 92
            1
          elsif previous == 45 || previous == 95 || previous == 32
            2
          elsif previous == 46
            3
          elsif previous >= 97 && previous <= 122 && original >= 65 && original <= 90
            4
          else
            0
          end
          @bonuses.setbyte(position, kind)
          @basename = position + 1 if original == 47 || original == 92
          previous = original
          position += 1
        end
      else
        @chars = @text.each_char.map(&:freeze).freeze
        @folded = @chars.map { |character| character.downcase.freeze }.freeze
        @length = @chars.length
        @unicode = precompute_mask ? {} : nil
        @bonuses = ZERO_BYTE * @length
        previous = "/"
        @chars.each_with_index do |original, position|
          folded = @folded[position]
          if precompute_mask
            if folded.ascii_only?
              code = folded.ord
              code < 64 ? low |= 1 << code : high |= 1 << (code - 64)
            else
              @unicode[folded] = true
            end
          end
          kind = if previous == "/" || previous == "\\"
            1
          elsif ["-", "_", " "].include?(previous)
            2
          elsif previous == "."
            3
          elsif previous.match?(/\p{Lower}/) && original.match?(/\p{Upper}/)
            4
          else
            0
          end
          @bonuses.setbyte(position, kind)
          @basename = position + 1 if original == "/" || original == "\\"
          previous = original
        end
        @unicode.freeze
      end
      @mask = precompute_mask ? low | (high << 64) : nil
      @bonuses.freeze
      freeze
    rescue EncodingError => error
      raise ArgumentError, "candidate encoding: #{error.message}"
    end
  end

  # Sparse form of the fzy D/M recurrence. Only matching character positions
  # need a cell; the maximum across intervening gaps is carried analytically.
  class Matcher
    # Sentinel for unreachable DP states.
    NEGATIVE_INFINITY = -Float::INFINITY
    # Immutable one-byte query strings shared across scorers.
    ASCII_CHARACTERS = Array.new(128) { |code| code.chr(Encoding::UTF_8).freeze }.freeze
    # Shared empty non-ASCII membership list.
    EMPTY_CHARACTERS = [].freeze

    # @param query [String] query to preprocess once
    # @param options [Options] scoring policy
    def initialize(query, options = DEFAULT_OPTIONS)
      raise ArgumentError, "query must be valid text" unless query.is_a?(String) && query.encoding.ascii_compatible? && query.valid_encoding?
      query = query.encoding == Encoding::UTF_8 ? (query.frozen? ? query : query.dup.freeze) : query.encode(Encoding::UTF_8).freeze
      @original_text = query
      @options = options
      @sensitive = options.case_sensitivity == :sensitive ||
        (options.case_sensitivity == :smart && query.match?(/\p{Upper}/))
      @scale, @bonus_values, @leading, @inner, @trailing, @consecutive, @case_bonus, @path_bonus, @max_bonus, @contiguous_bound = options.scoring
      if query.ascii_only?
        @query_text = @sensitive ? query : query.downcase
        @query = []
        @query_text.each_byte { |code| @query << ASCII_CHARACTERS[code] }
        @original = query.each_byte.map { |code| ASCII_CHARACTERS[code] } unless @case_bonus.zero?
      else
        @original = query.each_char.to_a
        folded = @original.map(&:downcase)
        @query = @sensitive ? @original : folded
        @query_text = @query.join.freeze
      end
      @size = @query.length
      # Keep one object layout even when these caches remain unused.
      @mask = @unicode = @positions_a = @positions_b = @scores_a = @scores_b = nil
    rescue EncodingError => error
      raise ArgumentError, "query encoding: #{error.message}"
    end

    # @return [Float, nil] optimal score, or nil for a non-match
    def score(candidate)
      value = evaluate(candidate, false)
      raise ArgumentError, "scoring overflow; reduce option weights" if value.is_a?(Float) && value.nan?
      value / @scale if value
    end

    # Backtracking is only performed for results actually returned to the UI.
    # @return [Match, nil]
    def match(candidate)
      value = evaluate(candidate, true)
      return unless value
      raise ArgumentError, "scoring overflow; reduce option weights" if value.is_a?(Float) && value.nan?
      Match.new(candidate: candidate.text, score: value / @scale, positions: @aligned.freeze, index: candidate.index).freeze
    end

    private

    # Membership masks only help indexed candidates. Stateless calls and short
    # queries never inspect them, so avoid building their arbitrary-size integers.
    def prepare_mask
      @unicode = @query_text.ascii_only? ? EMPTY_CHARACTERS : []
      low = high = 0
      @query.each do |character|
        character = character.downcase if @sensitive
        if character.ascii_only?
          code = character.ord
          code < 64 ? low |= 1 << code : high |= 1 << (code - 64)
        else
          @unicode << character
        end
      end
      @mask = low.zero? ? high << 64 : low | (high << 64)
    end

    def find(chars, needle, offset)
      return chars.index(needle, offset) if chars.is_a?(String)
      while offset < chars.length
        return offset if chars[offset] == needle
        offset += 1
      end
      nil
    end

    def bonus(candidate, position)
      value = @bonus_values[candidate.bonuses.getbyte(position)]
      @path_bonus.zero? || position < candidate.basename ? value : value + @path_bonus
    end

    def case_bonus(candidate, position, query_index)
      return 0.0 if @case_bonus.zero?
      character = candidate.ascii_only? ? candidate.text.getbyte(position) : candidate.chars[position]
      expected = candidate.ascii_only? ? @original[query_index].ord : @original[query_index]
      character == expected ? @case_bonus : 0.0
    end

    def evaluate(candidate, backtrack)
      n, m = candidate.length, @size
      if m.zero?
        @aligned = [] if backtrack
        return 0.0
      end
      return if m > n
      if m > 2 && candidate.mask
        prepare_mask unless @mask
        return if (candidate.mask & @mask) != @mask || @unicode.any? { |character| !candidate.unicode || !candidate.unicode[character] }
      end
      chars = @sensitive ? candidate.chars : candidate.folded
      # A consecutive run starting at the strongest possible boundary reaches
      # the global DP upper bound. This is an exact shortcut, not a heuristic.
      if m > 1 && candidate.ascii_only? && @query_text.ascii_only? && @contiguous_bound
        position = chars.index(@query_text)
        if position && bonus(candidate, position) + @case_bonus == @max_bonus && (@case_bonus.zero? || candidate.text.index(@original_text, position) == position)
          @aligned = (position...(position + m)).to_a if backtrack
          return Float::INFINITY if m == n
          return (n - m) * @leading + bonus(candidate, position) + (m - 1) * @consecutive + m * @case_bonus
        end
      end
      return score_one_character(candidate, chars, backtrack) if m == 1
      return score_two_characters(candidate, chars, backtrack) if m == 2
      # Cheap C-level subsequence checks precede the sparse DP.
      cursor = 0
      unique = n <= @options.max_length && m <= @options.max_query
      total = 0
      aligned = [] if backtrack
      i = 0
      while i < m
        character = @query[i]
        position = find(chars, character, cursor)
        return unless position
        # If each remaining character occurs only once, there is no alignment
        # choice for DP to resolve. Stop checking as soon as one is ambiguous.
        unique &&= find(chars, character, position + 1).nil?
        if unique
          value = bonus(candidate, position)
          value = @consecutive if i.positive? && position == cursor && @consecutive > value
          total += value + (i.zero? ? position * @leading : (position - cursor) * @inner)
          total += case_bonus(candidate, position, i) unless @case_bonus.zero?
          aligned << position if backtrack
        end
        cursor = position + 1
        i += 1
      end
      if m == n
        @aligned = (0...m).to_a if backtrack
        return Float::INFINITY
      end
      if unique
        @aligned = aligned if backtrack
        return total + (n - cursor) * @trailing
      end
      # ponytail: exceptionally long text uses greedy alignment; configurable
      # ceilings bound memory/time without dropping valid subsequence matches.
      return score_greedily(candidate, chars, backtrack) if n > @options.max_length || m > @options.max_query

      score_ambiguous_alignment(candidate, chars, backtrack)
    end

    def score_one_character(candidate, chars, backtrack)
      length = candidate.length
      position = find(chars, @query[0], 0)
      return unless position
      if length == 1
        @aligned = [0] if backtrack
        return Float::INFINITY
      end
      best, finish = NEGATIVE_INFINITY, nil
      while position
        value = bonus(candidate, position)
        value += case_bonus(candidate, position, 0) unless @case_bonus.zero?
        value += @leading == @trailing ? (length - 1) * @leading : position * @leading + (length - position - 1) * @trailing
        if value >= best
          best, finish = value, position
        end
        break if !backtrack && @leading == @trailing && value >= (length - 1) * @leading + @max_bonus
        position = find(chars, @query[0], position + 1)
      end
      @aligned = [finish] if backtrack
      best
    end

    # Two rows collapse to scalar prefix maxima: no temporary arrays, while
    # retaining every alignment and the exact same D/M recurrence.
    def score_two_characters(candidate, chars, backtrack)
      first = find(chars, @query[0], 0)
      return unless first
      second = find(chars, @query[1], first + 1)
      return unless second
      if candidate.length == 2
        @aligned = [0, 1] if backtrack
        return Float::INFINITY
      end
      maximum = best = NEGATIVE_INFINITY
      maximum_position = last_position = last_score = finish_first = finish_second = nil
      while second
        while first && first < second
          score = first * @leading + bonus(candidate, first)
          score += case_bonus(candidate, first, 0) unless @case_bonus.zero?
          adjusted = score - first * @inner
          if adjusted >= maximum
            maximum, maximum_position = adjusted, first
          end
          last_position, last_score = first, score
          first = find(chars, @query[0], first + 1)
        end
        separated = maximum + (second - 1) * @inner + bonus(candidate, second)
        adjacent = last_position == second - 1 ? last_score + @consecutive : NEGATIVE_INFINITY
        if adjacent >= separated
          score, start = adjacent, last_position
        else
          score, start = separated, maximum_position
        end
        score += case_bonus(candidate, second, 1) unless @case_bonus.zero?
        score += (candidate.length - second - 1) * @trailing
        if score >= best
          best, finish_first, finish_second = score, start, second
        end
        second = find(chars, @query[1], second + 1)
      end
      @aligned = [finish_first, finish_second] if backtrack
      best
    end

    def score_greedily(candidate, chars, backtrack)
      cursor = 0
      previous = nil
      total = 0.0
      @aligned = [] if backtrack
      @query.each_with_index do |character, i|
        position = find(chars, character, cursor)
        @aligned << position if backtrack
        total += if previous && position == previous + 1
          @consecutive
        else
          bonus(candidate, position) + (previous ? (position - previous - 1) * @inner : position * @leading)
        end
        total += case_bonus(candidate, position, i)
        previous = position
        cursor = position + 1
      end
      total + (candidate.length - previous - 1) * @trailing
    end

    def score_ambiguous_alignment(candidate, chars, backtrack)
      n, m = candidate.length, @size

      previous_positions, current_positions = (@positions_a ||= []), (@positions_b ||= [])
      previous_scores, current_scores = (@scores_a ||= []), (@scores_b ||= [])
      previous_positions.clear
      previous_scores.clear
      rows = [] if backtrack
      parents = [] if backtrack
      i = 0
      while i < m
        current_positions.clear
        current_scores.clear
        parent_row = [] if backtrack
        position = find(chars, @query[i], i)
        previous_cursor = 0
        maximum = NEGATIVE_INFINITY
        maximum_index = nil
        while position && position <= n - m + i
          if i.zero?
            value = position * @leading + bonus(candidate, position)
            parent_index = nil
          else
            while previous_cursor < previous_positions.length && previous_positions[previous_cursor] < position
              adjusted = previous_scores[previous_cursor] - previous_positions[previous_cursor] * @inner
              if adjusted >= maximum
                maximum, maximum_index = adjusted, previous_cursor
              end
              previous_cursor += 1
            end
            if maximum_index.nil?
              position = find(chars, @query[i], position + 1)
              next
            end
            separated = maximum + (position - 1) * @inner + bonus(candidate, position)
            adjacent = previous_cursor.positive? && previous_positions[previous_cursor - 1] == position - 1 ? previous_scores[previous_cursor - 1] + @consecutive : NEGATIVE_INFINITY
            if adjacent >= separated
              value, parent_index = adjacent, previous_cursor - 1
            else
              value, parent_index = separated, maximum_index
            end
          end
          value += case_bonus(candidate, position, i) unless @case_bonus.zero?
          current_positions << position
          current_scores << value
          parent_row << parent_index if backtrack
          position = find(chars, @query[i], position + 1)
        end
        if backtrack
          rows << current_positions.dup
          parents << parent_row
        end
        previous_positions, current_positions = current_positions, previous_positions
        previous_scores, current_scores = current_scores, previous_scores
        i += 1
      end
      best, finish = NEGATIVE_INFINITY, nil
      previous_positions.each_with_index do |position, index|
        value = previous_scores[index] + (n - position - 1) * @trailing
        if value >= best
          best, finish = value, index
        end
      end
      if backtrack
        @aligned = Array.new(m)
        (m - 1).downto(0) do |row|
          @aligned[row] = rows[row][finish]
          finish = parents[row][finish]
        end
      end
      best
    end
  end
end
