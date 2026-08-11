#!/usr/bin/env ruby

require "date"

path = ARGV.fetch(0, "CHANGELOG.md")
text = File.read(path)
errors = []
expected_sections = %w[Added Changed Fixed Security].freeze

unless text.start_with?("# Changelog\n")
  errors << "the file must start with '# Changelog'"
end

release_headings = text.scan(/^## \[([^\]]+)\](?: - (\d{4}-\d{2}-\d{2}))?$/)
unless release_headings.first&.first == "Unreleased"
  errors << "Unreleased must be the first release section"
end
unreleased = release_headings.select { |version, _date| version == "Unreleased" }
errors << "there must be exactly one Unreleased section" unless unreleased.length == 1

versions = release_headings.filter_map do |version, date|
  next if version == "Unreleased"

  unless version.match?(/\A\d+\.\d+(?:\.\d+)?\z/)
    errors << "release '#{version}' is not a valid version"
  end
  if date.nil?
    errors << "release '#{version}' has no ISO date"
  else
    begin
      Date.iso8601(date)
    rescue Date::Error
      errors << "release '#{version}' has invalid date '#{date}'"
    end
  end
  version
end
errors << "release versions must be unique" unless versions.uniq.length == versions.length

text.scan(/^## \[([^\]]+)\](?: - \d{4}-\d{2}-\d{2})?\n(.*?)(?=^## |\z)/m).each do |version, body|
  actual_sections = body.scan(/^### (.+)$/).flatten
  unless actual_sections == expected_sections
    errors << "#{version} sections must be: #{expected_sections.join(', ')}"
  end
end

if errors.any?
  warn errors.map { |error| "CHANGELOG: #{error}" }.join("\n")
  exit 1
end

puts "CHANGELOG is valid"
