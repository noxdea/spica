# frozen_string_literal: true

module ReferenceMatcher
  Options = Struct.new(:case_sensitivity, :path_mode, :limit, :tie_break,
                       :consecutive, :boundary, :slash, :camel, :leading_gap,
                       :inner_gap, :trailing_gap, :case_bonus, keyword_init: true) do
    def initialize(case_sensitivity: :smart, path_mode: false, limit: 100,
                   tie_break: :shorter, consecutive: 1.0, boundary: 0.8,
                   slash: 0.9, camel: 0.7, leading_gap: -0.005,
                   inner_gap: -0.01, trailing_gap: -0.005, case_bonus: 0.0)
      super
      raise ArgumentError, "invalid case sensitivity" unless %i[smart sensitive insensitive].include?(case_sensitivity)
      raise ArgumentError, "invalid tie break" unless %i[shorter index].include?(tie_break)
      raise ArgumentError, "limit must be nonnegative" unless limit.is_a?(Integer) && limit >= 0
      freeze
    end
  end

  Match = Struct.new(:candidate, :score, :positions, :index, keyword_init: true) do
    alias text candidate
    def to_s = candidate
  end

  class Candidate
    attr_reader :text, :chars, :folded, :mask, :unicode, :index, :basename

    def initialize(text, index)
      raise ArgumentError, "candidate must be valid UTF-8 text" unless text.is_a?(String) && text.encoding.ascii_compatible? && text.valid_encoding?
      @text, @index = text.encode(Encoding::UTF_8).freeze, index
      @chars = @text.each_char.to_a.freeze
      @folded = @chars.map(&:downcase).freeze
      @mask, @unicode = 0, {}
      @folded.each do |c|
        c.ascii_only? ? @mask |= 1 << c.ord : @unicode[c] = true
      end
      @unicode.freeze
      @basename = (@chars.rindex { |c| c == "/" || c == "\\" } || -1) + 1
      freeze
    end
  end

  class Matcher
    NEGATIVE_INFINITY = -Float::INFINITY

    def initialize(query, options)
      raise ArgumentError, "query must be valid text" unless query.is_a?(String) && query.valid_encoding?
      @query = query.each_char.to_a
      @options = options
      @sensitive = options.case_sensitivity == :sensitive ||
        (options.case_sensitivity == :smart && query.match?(/\p{Upper}/))
      @folded = @query.map(&:downcase)
      @mask, @unicode = 0, []
      @folded.each { |c| c.ascii_only? ? @mask |= 1 << c.ord : @unicode << c }
    end

    def match(candidate)
      n, m = candidate.chars.length, @query.length
      return result(candidate, 0.0, []) if m.zero?
      return if m > n || (candidate.mask & @mask) != @mask || @unicode.any? { |c| !candidate.unicode[c] }
      query = @sensitive ? @query : @folded
      chars = @sensitive ? candidate.chars : candidate.folded
      positions, cursor = [], 0
      chars.each_with_index do |char, index|
        next unless char == query[cursor]
        positions << index
        cursor += 1
        break if cursor == m
      end
      return unless cursor == m
      return result(candidate, Float::INFINITY, positions) if m == n
      # ponytail: bound quadratic scoring on long strings; raise the ceiling or
      # use a banded DP if callers need optimal alignment beyond 1024 characters.
      return result(candidate, greedy_score(candidate, positions), positions) if n > 1024 || m > 256

      bonuses = candidate.chars.each_index.map { |j| bonus(candidate, j) }
      previous_d = previous_m = nil
      parents = Array.new(m) { Array.new(n) }
      best_ends = nil
      m.times do |i|
        d, best = Array.new(n, NEGATIVE_INFINITY), Array.new(n, NEGATIVE_INFINITY)
        ends = Array.new(n)
        gap = i == m - 1 ? @options.trailing_gap : @options.inner_gap
        n.times do |j|
          if chars[j] == query[i]
            exact_bonus = candidate.chars[j] == @query[i] ? @options.case_bonus : 0
            if i.zero?
              d[j] = j * @options.leading_gap + bonuses[j] + exact_bonus
            elsif j.positive?
              separated = previous_m[j - 1] + bonuses[j]
              adjacent = previous_d[j - 1] + @options.consecutive
              if adjacent >= separated
                d[j], parents[i][j] = adjacent + exact_bonus, j - 1
              else
                d[j], parents[i][j] = separated + exact_bonus, best_ends[j - 1]
              end
            end
          end
          carried = j.zero? ? NEGATIVE_INFINITY : best[j - 1] + gap
          if d[j] >= carried
            best[j], ends[j] = d[j], j
          else
            best[j], ends[j] = carried, ends[j - 1]
          end
        end
        previous_d, previous_m, best_ends = d, best, ends
      end
      finish = best_ends[-1]
      aligned = Array.new(m)
      (m - 1).downto(0) do |i|
        aligned[i] = finish
        finish = parents[i][finish]
      end
      result(candidate, previous_m[-1], aligned)
    end

    private

    def result(candidate, score, positions)
      Match.new(candidate: candidate.text, score: score, positions: positions.freeze, index: candidate.index).freeze
    end

    def bonus(candidate, j)
      prev = j.zero? ? "/" : candidate.chars[j - 1]
      value = if prev == "/" || prev == "\\"
        @options.slash
      elsif "-_ ".include?(prev)
        @options.boundary
      elsif prev == "."
        0.6
      elsif prev.match?(/\p{Lower}/) && candidate.chars[j].match?(/\p{Upper}/)
        @options.camel
      else
        0.0
      end
      value += 0.2 if @options.path_mode && j >= candidate.basename
      value
    end

    def greedy_score(candidate, positions)
      total = positions.first * @options.leading_gap
      positions.each_with_index do |j, i|
        total += if i.positive? && j == positions[i - 1] + 1
          @options.consecutive
        else
          bonus(candidate, j) + (i.zero? ? 0 : (j - positions[i - 1] - 1) * @options.inner_gap)
        end
      end
      total + (candidate.chars.length - positions.last - 1) * @options.trailing_gap
    end
  end
end
