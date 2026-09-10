# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/reference_matcher"
require "open3"
require "tmpdir"
require "fileutils"

class OracleTest < Minitest::Test
  def native(cases)
    Dir.mktmpdir("spica-fzy") do |directory|
      vendor = File.expand_path("vendor/fzy", __dir__)
      source = File.join(directory, "src")
      FileUtils.mkdir_p(source)
      %w[match.c match.h bonus.h].each { |file| FileUtils.cp(File.join(vendor, file), File.join(source, file)) }
      FileUtils.cp(File.join(vendor, "config.def.h"), File.join(directory, "config.h"))
      executable = File.join(directory, "fzy-oracle")
      begin
        output, status = Open3.capture2e(ENV.fetch("CC", "cc"), "-std=c99", "-O2", "-I#{source}", File.join(source, "match.c"), File.expand_path("support/fzy_oracle.c", __dir__), "-lm", "-o", executable)
      rescue Errno::ENOENT
        flunk "C compiler required for fzy oracle" if ENV["FZY_REQUIRED"] == "1"
        skip "C compiler unavailable for optional fzy oracle"
      end
      assert status.success?, output
      output, status = Open3.capture2e(executable, stdin_data: cases.map { |query, text| "#{query.downcase}\t#{text}\n" }.join)
      assert status.success?, output
      output.lines.map do |line|
        score, *positions = line.split
        number = case score
        when "inf" then Float::INFINITY
        when "-inf" then -Float::INFINITY
        else Float(score)
        end
        [number, positions.map(&:to_i)]
      end
    end
  end

  def test_all_upstream_public_ranking_assertions
    source = File.read(File.expand_path("vendor/fzy/test_match.c", __dir__))
    cases = source.scan(/ASSERT\(match\("([^"]*)", "([^"]*)"\) ([<>]) match\("([^"]*)", "([^"]*)"\)\);/)
    assert_equal 8, cases.length
    inputs = cases.flat_map { |query, text, _, other_query, other_text| [[query, text], [other_query, other_text]] }
    results = native(inputs)
    cases.each_with_index do |(query, text, operator, other_query, other_text), index|
      left, right = Spica.score(query, text), Spica.score(other_query, other_text)
      assert_operator left, operator.to_sym, right
      assert_operator results[index * 2][0], operator.to_sym, results[index * 2 + 1][0]
    end
  end

  def test_native_scores_for_seeded_ascii_candidates
    random = Random.new(93)
    alphabet = "abcdeABCDE012/_-. "
    cases = 500.times.map do
      text = Array.new(random.rand(2..50)) { alphabet[random.rand(alphabet.length)] }.join
      query = text.chars.select { |character| character.match?(/[a-z0-9]/i) && random.rand(4).zero? }.join.downcase
      query = "z" if query.empty?
      [query, text]
    end
    results = native(cases)
    cases.zip(results).each do |(query, text), (expected, _positions)|
      actual = Spica.score(query, text, case_sensitivity: :insensitive)
      if expected.finite?
        assert_in_delta expected, actual, 1e-9, [query, text].inspect
      else
        assert_equal expected, actual, [query, text].inspect
      end
    end
  end

  def test_sparse_scores_equal_independent_dense_recurrence
    random = Random.new(231)
    alphabet = %w[a b C D / _ 日 🙂]
    settings = [{}, {path_mode: true, case_bonus: 0.025}, {leading_gap: -0.04, trailing_gap: -0.02, inner_gap: -0.015, consecutive: 0.71, boundary: 0.1234567}]
    3000.times do |iteration|
      text = Array.new(random.rand(1..40)) { alphabet.sample(random:) }.join
      query = text.chars.select { random.rand(4).zero? }.join
      options = settings[iteration % settings.length]
      expected = ReferenceMatcher::Matcher.new(query, ReferenceMatcher::Options.new(**options)).match(ReferenceMatcher::Candidate.new(text, 0))
      actual = Spica.match(query, text, **options)
      assert actual
      if expected.score.finite?
        assert_in_delta expected.score, actual.score, 1e-10, [query, text, options].inspect
      else
        assert_equal expected.score, actual.score
      end
      assert_equal query, actual.positions.map { |position| text[position] }.join
    end
  end

  def test_unique_alignment_and_ambiguous_reuse_equal_dense_recurrence
    cases = [
      ["amf", "app/models/foo.rb", [0, 4, 11]],
      ["abc", "xa/bc/z", [1, 3, 4]],
      ["a🙂D", "xa/🙂_D/z", [1, 3, 5]],
      ["İ日🙂", "xİ/日_🙂z", [1, 3, 5]]
    ]
    settings = [{}, {path_mode: true, case_bonus: 0.025},
      {case_sensitivity: :insensitive, consecutive: 0.1, leading_gap: -0.04,
       trailing_gap: -0.02, inner_gap: -0.015, boundary: 0.1234567}]
    settings.each do |options|
      cases.each do |query, text, positions|
        matcher = Spica::Matcher.new(query, Spica::Options.new(**options))
        reference = ReferenceMatcher::Matcher.new(query, ReferenceMatcher::Options.new(**options))
        # The same matcher must move between the unique shortcut, ordinary DP,
        # a non-match and an exact match without stale scratch/backtrack state.
        [text, "#{text}/#{text}", "", query, text].each_with_index do |candidate, index|
          record = Spica::Candidate.new(candidate, 0, precompute_mask: index.odd?)
          expected = reference.match(ReferenceMatcher::Candidate.new(candidate, 0))
          actual = matcher.match(record)
          if expected.nil?
            assert_nil actual
            assert_nil matcher.score(record)
          elsif expected.score.finite?
            assert_in_delta expected.score, actual.score, 1e-10, [query, candidate, options].inspect
            assert_equal actual.score, matcher.score(record)
            assert_equal positions, actual.positions if candidate == text
          else
            assert_equal expected.score, actual.score
            assert_equal expected.score, matcher.score(record)
          end
        end
      end
    end
  end
end
