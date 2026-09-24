# frozen_string_literal: true

require "spica"
require "zaniah/ui"

module Spica
  # Optional adapter for Zaniah's command palette and combobox matcher API.
  class ZaniahMatcher
    def match(query, labels)
      matcher = Matcher.new(query)
      if query.empty?
        return labels.each_index.map { |index| Zaniah::UI::Matcher::Match.new(index: index, score: 0.0, ranges: []) }
      end

      labels.each_with_index.filter_map do |label, index|
        result = matcher.match(Candidate.new(label, index, precompute_mask: false))
        next unless result

        unless label.encoding == Encoding::UTF_8 || label.ascii_only?
          raise ArgumentError, "Zaniah labels must be UTF-8 text"
        end

        offsets = [0]
        label.each_char { |char| offsets << offsets.last + char.bytesize }
        ranges = result.positions.map { |position| offsets[position]...offsets[position + 1] }
        Zaniah::UI::Matcher::Match.new(index: index, score: result.score, ranges: ranges)
      end.sort_by { |result| [-result.score, labels[result.index].length, result.index] }
    end
  end
end
