#!/usr/bin/env ruby

require "fileutils"
require "minitest/autorun"
require "open3"
require "pathname"
require "tmpdir"

class PrepareReleaseTest < Minitest::Test
  SCRIPT = Pathname(__dir__).join("..", "prepare_release.rb").expand_path
  CHANGELOG = <<~MARKDOWN.freeze
    # Changelog

    ## [Unreleased]

    ### Added

    - Added one useful feature.

    ### Changed

    ### Fixed

    ### Security
  MARKDOWN

  def setup
    @temporary_directory = Dir.mktmpdir("vvterm-release-test")
    @root = Pathname(@temporary_directory)
    @root.join("VVTerm.xcodeproj").mkpath
    @project_path = @root.join("VVTerm.xcodeproj/project.pbxproj")
    @project_path.write(("MARKETING_VERSION = 2.15;\n" * 8))
    @changelog_path = @root.join("CHANGELOG.md")
    @changelog_path.write(CHANGELOG)
  end

  def teardown
    FileUtils.remove_entry(@temporary_directory)
  end

  def test_check_verifies_all_version_settings_without_writes
    output, error, status = run_script("--check")

    assert status.success?, error
    assert_includes output, "all 8 settings"
    assert_equal "2.15", versions.uniq.fetch(0)
    assert_equal CHANGELOG, @changelog_path.read
  end

  def test_prepare_updates_all_versions_and_finalizes_release_files
    output, error, status = run_script("2.16", "--date", "2026-08-12")

    assert status.success?, error
    assert_includes output, "Prepared VVTerm 2.16"
    assert_equal ["2.16"], versions.uniq
    assert_equal 8, versions.length
    changelog = @changelog_path.read
    assert_includes changelog, "## [2.16] - 2026-08-12"
    assert_includes changelog, "- Added one useful feature."
    assert_match(/## \[Unreleased\].*?### Added\n\n### Changed/m, changelog)
    assert_includes @root.join("release-notes/2.16.md").read, "# VVTerm 2.16"
  end

  def test_mismatched_versions_fail_without_writes
    original = @project_path.read.sub("MARKETING_VERSION = 2.15;", "MARKETING_VERSION = 2.14;")
    @project_path.write(original)

    _output, error, status = run_script("2.16")

    refute status.success?
    assert_includes error, "settings disagree"
    assert_equal original, @project_path.read
    refute @root.join("release-notes/2.16.md").exist?
  end

  def test_empty_unreleased_section_fails_without_writes
    empty_changelog = CHANGELOG.sub("- Added one useful feature.\n", "")
    @changelog_path.write(empty_changelog)

    _output, error, status = run_script("2.16")

    refute status.success?
    assert_includes error, "Unreleased has no entries"
    assert_equal empty_changelog, @changelog_path.read
    assert_equal ["2.15"], versions.uniq
  end

  private

  def run_script(*arguments)
    Open3.capture3(
      SCRIPT.to_s,
      *arguments,
      "--root",
      @root.to_s
    )
  end

  def versions
    @project_path.read.scan(/^MARKETING_VERSION = ([^;]+);$/).flatten
  end
end
