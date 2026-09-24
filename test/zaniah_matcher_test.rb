# frozen_string_literal: true

require_relative "test_helper"
require "spica/zaniah_matcher"

class ZaniahMatcherTest < Minitest::Test
  def test_matches_keep_input_indices_including_duplicate_labels
    labels = ["save", "open", "save"]
    matches = Spica::ZaniahMatcher.new.match("sa", labels)

    assert_equal [0, 2], matches.map(&:index)
    assert_equal [[0...1, 1...2], [0...1, 1...2]], matches.map(&:ranges)
    assert matches.all? { |match| match.is_a?(Zaniah::UI::Matcher::Match) }
  end

  def test_unicode_character_positions_become_utf8_byte_ranges
    labels = ["日本/🙂/e\u0301.rb", "other"]
    matches = Spica::ZaniahMatcher.new.match("日🙂e", labels)

    assert_equal [0], matches.map(&:index)
    assert_equal [0...3, 7...11, 12...13], matches.first.ranges
    highlighted = Zaniah::UI::Matcher.segments(labels.first, matches.first.ranges).select(&:last).map(&:first)
    assert_equal ["日", "🙂", "e\u0301"], highlighted
    assert_equal [0, 1], Spica::ZaniahMatcher.new.match("", labels).map(&:index)
    assert_equal [[], []], Spica::ZaniahMatcher.new.match("", labels).map(&:ranges)
  end

  def test_non_utf8_multibyte_labels_fail_before_returning_wrong_ranges
    assert_raises(ArgumentError) { Spica::ZaniahMatcher.new.match("é", ["é".encode(Encoding::ISO_8859_1)]) }
  end
end
