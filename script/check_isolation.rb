# frozen_string_literal: true

require "tmpdir"
require "open3"
require "rubygems/package"

root = File.expand_path("..", __dir__)
Dir[File.join(root, "lib/**/*.rb")].each do |path|
  abort "application dependency in #{path}" if File.read(path).match?(/\b(?:Zaniah|Canopus)\b/)
end
spec = Gem::Specification.load(File.join(root, "spica.gemspec"))
abort "unexpected runtime gem dependencies" unless spec.runtime_dependencies.empty?
Dir.mktmpdir("spica-install") do |directory|
  gem_file = File.join(directory, "spica.gem")
  Dir.chdir(root) { Gem::Package.build(spec, false, false, gem_file) }
  install = File.join(directory, "gems")
  output, status = Open3.capture2e(Gem.ruby, File.join(RbConfig::CONFIG.fetch("bindir"), "gem"), "install", "--local", "--ignore-dependencies", "--no-document", "--install-dir", install, gem_file)
  abort output unless status.success?
  smoke = <<~RUBY
    require "spica"
    index = Spica::Index.new(["app/models/user.rb", "README.md"])
    session = index.session
    session.query = "amu"
    result = session.matches(1).first
    abort "match failed" unless result.candidate == "app/models/user.rb" && result.positions == [0, 4, 11]
    actual = File.realpath(Gem.loaded_specs.fetch("spica").full_gem_path)
    abort "wrong gem: " + actual unless actual.start_with?(File.realpath(#{install.inspect}) + File::SEPARATOR)
    puts "isolated install: #{spec.version}, incremental matching succeeded"
  RUBY
  env = {"GEM_HOME" => install, "GEM_PATH" => install, "RUBYLIB" => nil, "RUBYOPT" => nil, "BUNDLE_GEMFILE" => nil}
  output, status = Open3.capture2e(env, Gem.ruby, "-e", smoke, chdir: directory)
  abort output unless status.success?
  puts output
end
