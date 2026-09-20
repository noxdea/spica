# frozen_string_literal: true

require "fileutils"
require "spica"
require_relative "png_helper"

candidates = %w[app/models/user.rb app/models/order.rb lib/spica/index.rb README.md test/matcher_test.rb]
matches = Spica.filter("am", candidates)
width = 1_000
height = 520
rgba = [22, 27, 36, 255] * width * height
rect = lambda do |x, y, w, h, color|
  h.times { |row| w.times { |column| rgba[((y + row) * width + x + column) * 4, 4] = color } }
end
matches.each_with_index do |match, row|
  y = 40 + row * 88
  rect.call(42, y, 900, 48, [45, 55, 70, 255])
  offset = 48
  rect.call(offset, y + 10, [match.candidate.length * 13, 8].max, 28, [113, 128, 151, 255])
  match.positions.each do |position|
    rect.call(offset + position * 13, y + 10, 10, 28, [94, 234, 212, 255])
  end
end
FileUtils.mkdir_p("docs/media")
DemoPNG.write("docs/media/screenshot.png", width, height, rgba.pack("C*"))
