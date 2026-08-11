#!/usr/bin/env ruby

require "date"
require "fileutils"
require "open3"
require "optparse"
require "pathname"
require "rbconfig"
require "tempfile"

EXPECTED_MARKETING_VERSION_COUNT = 8
VERSION_PATTERN = /\A\d+\.\d+(?:\.\d+)?\z/
EMPTY_UNRELEASED = <<~MARKDOWN.freeze
  ## [Unreleased]

  ### Added

  ### Changed

  ### Fixed

  ### Security
MARKDOWN

options = {
  root: Pathname(__dir__).join("..").expand_path,
  date: Date.today.iso8601,
  check: false
}

OptionParser.new do |parser|
  parser.banner = "Usage: scripts/prepare_release.rb VERSION [--date YYYY-MM-DD] [--root PATH]"
  parser.on("--check", "Validate release inputs without changing files") { options[:check] = true }
  parser.on("--date DATE", "Release date in ISO format") { |date| options[:date] = date }
  parser.on("--root PATH", "Repository root") { |path| options[:root] = Pathname(path).expand_path }
end.parse!

version = ARGV.shift
abort "Unexpected arguments: #{ARGV.join(' ')}" unless ARGV.empty?
abort "Do not pass VERSION with --check" if options[:check] && version
abort "VERSION is required" unless options[:check] || version

begin
  Date.iso8601(options[:date])
rescue Date::Error
  abort "Invalid release date: #{options[:date]}"
end
abort "Invalid version: #{version}" if version && !version.match?(VERSION_PATTERN)

root = options[:root]
project_path = root.join("VVTerm.xcodeproj/project.pbxproj")
changelog_path = root.join("CHANGELOG.md")
validator_path = Pathname(__dir__).join("validate_changelog.rb")
project = project_path.read
changelog = changelog_path.read

version_matches = project.scan(/^(\s*MARKETING_VERSION = )([^;]+);$/)
unless version_matches.length == EXPECTED_MARKETING_VERSION_COUNT
  abort "Expected #{EXPECTED_MARKETING_VERSION_COUNT} MARKETING_VERSION settings, found #{version_matches.length}"
end

current_versions = version_matches.map(&:last).uniq
unless current_versions.length == 1
  abort "MARKETING_VERSION settings disagree: #{current_versions.join(', ')}"
end

validation_output, validation_error, validation_status = Open3.capture3(
  RbConfig.ruby,
  validator_path.to_s,
  "-",
  stdin_data: changelog
)
unless validation_status.success?
  warn validation_error
  exit validation_status.exitstatus
end

if options[:check]
  puts "Release inputs are valid; MARKETING_VERSION is #{current_versions.first} in all #{EXPECTED_MARKETING_VERSION_COUNT} settings"
  exit 0
end

if changelog.match?(/^## \[#{Regexp.escape(version)}\](?: - |$)/)
  abort "CHANGELOG already contains release #{version}"
end

unreleased_match = changelog.match(/^## \[Unreleased\]\n(.*?)(?=^## |\z)/m)
abort "CHANGELOG has no Unreleased body" unless unreleased_match
unreleased_body = unreleased_match[1].rstrip
abort "Unreleased has no entries" unless unreleased_body.match?(/^\s*-\s+\S/m)

release_notes = unreleased_body.lines.filter_map do |line|
  case line
  when /^### (.+)$/
    "## #{Regexp.last_match(1)}\n"
  when /^\s*-\s+\S/
    line
  end
end.join.gsub(/\n{3,}/, "\n\n").rstrip
release_notes = "# VVTerm #{version}\n\n#{release_notes}\n"

released_section = "## [#{version}] - #{options[:date]}\n#{unreleased_body}\n"
changelog_start = unreleased_match.begin(0)
changelog_end = unreleased_match.end(0)
new_changelog = changelog[0...changelog_start]
new_changelog += EMPTY_UNRELEASED
new_changelog += "\n#{released_section}"
new_changelog += changelog[changelog_end..]

_output, new_validation_error, new_validation_status = Open3.capture3(
  RbConfig.ruby,
  validator_path.to_s,
  "-",
  stdin_data: new_changelog
)
unless new_validation_status.success?
  warn new_validation_error
  exit new_validation_status.exitstatus
end

new_project = project.gsub(/^(\s*MARKETING_VERSION = )([^;]+);$/) do
  "#{Regexp.last_match(1)}#{version};"
end
unless new_project.scan(/^\s*MARKETING_VERSION = #{Regexp.escape(version)};$/).length == EXPECTED_MARKETING_VERSION_COUNT
  abort "Could not update all MARKETING_VERSION settings"
end

notes_path = root.join("release-notes", "#{version}.md")
abort "Release notes already exist: #{notes_path}" if notes_path.exist?

writes = {
  project_path => new_project,
  changelog_path => new_changelog,
  notes_path => release_notes
}
originals = writes.to_h { |path, _content| [path, path.exist? ? path.binread : nil] }
modes = writes.to_h { |path, _content| [path, path.exist? ? path.stat.mode & 0o777 : 0o644] }
temporary_files = []

begin
  writes.each do |path, content|
    FileUtils.mkdir_p(path.dirname)
    temporary = Tempfile.new([path.basename.to_s, ".tmp"], path.dirname)
    temporary.binmode
    temporary.write(content)
    temporary.flush
    temporary.close
    temporary_files << temporary.path
    File.rename(temporary.path, path)
    File.chmod(modes.fetch(path), path)
  end
rescue StandardError
  originals.each do |path, content|
    content.nil? ? FileUtils.rm_f(path) : path.binwrite(content)
    File.chmod(modes.fetch(path), path) if content
  end
  raise
ensure
  temporary_files.each { |path| FileUtils.rm_f(path) }
end

puts "Prepared VVTerm #{version} for #{options[:date]}"
puts "Updated #{EXPECTED_MARKETING_VERSION_COUNT} MARKETING_VERSION settings"
puts "Created #{notes_path.relative_path_from(root)}"
