# frozen_string_literal: true

require "spica"

index = Spica::Index.new(%w[app/models/user.rb app/models/order.rb app/controllers/users_controller.rb README.md])
session = index.session
(ARGV.empty? ? %w[a am amu am] : ARGV).each do |query|
  session.query = query
  puts "#{query.inspect}: #{session.total_matches} matches"
  session.matches(5).each do |match|
    highlighted = match.candidate.each_char.with_index.map { |character, position| match.positions.include?(position) ? "[#{character}]" : character }.join
    puts "  #{highlighted} (#{match.score})"
  end
end
