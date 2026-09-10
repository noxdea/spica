# frozen_string_literal: true

require_relative "test_helper"

class MatcherTest < Minitest::Test
  def test_fzy_public_ranking_cases
    # Ranking assertions from jhawthorn/fzy test/test_match.c (MIT), accessed
    # 2026-09-09. The numerical score is deliberately not part of compatibility.
    cases = [
      ["amor", "app/models/order", "app/models/zrder"],
      ["amo", "app/models/foo", "app/m/foo"],
      ["gemfil", "Gemfile", "Gemfile.lock"],
      ["abce", "abcdef", "abc de"],
      ["abc", "    a b c ", " a  b  c "],
      ["abc", " a b c    ", " a  b  c "],
      ["test", "tests", "testing"],
      ["test", "testing", "/testing"]
    ]
    cases.each { |query, better, worse| assert_operator Spica.score(query, better), :>, Spica.score(query, worse), [query, better, worse].inspect }
    assert_equal [0, 4, 5], Spica.match("amo", "app/models/foo").positions
    assert_equal [0, 4, 11, 12], Spica.match("amor", "app/models/order").positions
    assert_equal [2, 4, 6], Spica.match("abc", "a/a/b/c/c").positions
  end

  def test_case_unicode_and_long_inputs
    assert_nil Spica.match("FO", "foo")
    assert Spica.match("FO", "foo", case_sensitivity: :insensitive)
    match = Spica.match("日🙂e", "日本/🙂/e\u0301.rb")
    assert_equal [0, 3, 5], match.positions
    assert Spica.match("aa", "a" * 4096)
    assert_nil Spica.match("aaaa", "aa")
    assert_equal [], Spica.match("", "foo").positions
    assert_equal(-Float::INFINITY, Spica.score("z", "foo"))
  end

  def test_positions_property
    random = Random.new(12)
    alphabet = %w[a b C D / _ 日 🙂]
    2_000.times do
      candidate = Array.new(random.rand(1..40)) { alphabet.sample(random: random) }.join
      query = candidate.chars.select { random.rand(4).zero? }.join
      match = Spica.match(query, candidate)
      assert match
      assert_equal query, match.positions.map { |p| candidate[p] }.join
      assert_equal match.positions.sort.uniq, match.positions
    end
  end

  def test_sessions_equal_full_search_with_backspace_and_mutations
    paths = ["foo.rb", "FOO.rb", "food.txt", "src/core.rb", "src/codec.rb", "日本語", "frob"]
    index = Spica::Index.new(paths)
    session = index.session
    ["", "f", "fo", "foo", "fo", "fO", "src", "sc", "日本", "", "fo"].each do |query|
      session.query = query
      assert_equal Spica.filter(query, paths).map(&:candidate), session.matches.map(&:candidate)
    end
    index.add("forum.rb")
    paths << "forum.rb"
    assert_equal Spica.filter("fo", paths).map(&:candidate), session.matches.map(&:candidate)
    index.remove("foo.rb")
    refute_includes session.matches.map(&:candidate), "foo.rb"
    assert_equal [], session.matches(0)
  end

  def test_limit_never_discards_candidates_needed_by_next_query
    session = Spica::Index.new(%w[ab ac ad ae]).session
    session.query = "a"
    assert_equal ["ab"], session.matches(1).map(&:candidate)
    session.query = "ae"
    assert_equal ["ae"], session.matches(1).map(&:candidate)
  end

  def test_deterministic_registration_order_and_options
    20.times do |seed|
      input = %w[ab ac ad].shuffle(random: Random.new(seed))
      assert_equal input, Spica.filter("a", input).map(&:candidate)
    end
    assert_raises(ArgumentError) { Spica::Options.new(limit: -1) }
    assert_raises(ArgumentError) { Spica::Options.new(case_sensitivity: :unknown) }
  end

  def test_matches_equal_full_sort_for_random_limits_and_tie_rules
    random = Random.new(33)
    paths = Array.new(400) { |index| "#{%w[a A b B _ /].sample(random:)}#{index}/#{%w[alpha beta gamma].sample(random:)}" }
    [:shorter, :index].each do |tie_break|
      index = Spica::Index.new(paths, tie_break:)
      session = index.session
      100.times do
        query = %w[a ab ba b B ga _ z].sample(random:)
        session.query = query
        full = paths.each_with_index.filter_map do |path, registration|
          match = Spica.match(query, path)
          [match, registration] if match
        end
        full.sort_by! { |match, registration| [-match.score, *(tie_break == :shorter ? [match.candidate.length] : []), registration] }
        limit = random.rand(0..450)
        assert_equal full.first(limit).map { |match, _| match.candidate }, session.matches(limit).map(&:candidate)
        assert_equal full.length, session.total_matches
      end
    end
  end

  def test_unicode_case_folding_configuration_and_mutability
    paths = ["éclair", "日本/モデル.rb", "İstanbul", "Straße", "e\u0301x", "🙂.rb"]
    index = Spica::Index.new(paths)
    index.add("éclair".encode(Encoding::ISO_8859_1))
    assert_equal paths.length, index.size
    index.remove("éclair".encode(Encoding::ISO_8859_1))
    assert_equal paths.length - 1, index.size
    assert_equal [0], Spica.match("İ", "İstanbul").positions
    assert_nil Spica.match("ss", "Straße", case_sensitivity: :insensitive)
    refute_equal Spica.score("ab", "a_b"), Spica.score("ab", "a_b", boundary: 0.1)
    assert_equal 1, Spica.filter("a", %w[ab ac ad], options: Spica::Options.new(limit: 1)).length
    source = +"abc"
    index = Spica::Index.new([source])
    source.replace("zzz")
    session = index.session
    session.query = "a"
    result = session.matches
    assert_equal "abc", result.first.candidate
    assert_same result, session.matches
    assert_raises(FrozenError) { result.clear }
    assert_raises(FrozenError) { result.first.positions.clear }
    [Float::INFINITY, Float::NAN, "1", Complex(1, 2)].each { |number| assert_raises(ArgumentError) { Spica::Options.new(slash: number) } }
    [nil, 42, "\xff".b].each { |bad| assert_raises(ArgumentError) { Spica.match(bad, "abc") } }
    assert_raises(ArgumentError) { Spica::Options.new(max_length: 0) }
    assert_raises(ArgumentError) { Spica::Options.new(path_mode: :yes) }
  end
end
