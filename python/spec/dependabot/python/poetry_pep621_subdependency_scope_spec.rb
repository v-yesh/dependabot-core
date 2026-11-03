# typed: false
# frozen_string_literal: true

require "spec_helper"
require "dependabot/python/poetry_pep621_subdependency_scope"
require "dependabot/python/file_parser/poetry_lock"

RSpec.describe Dependabot::Python::PoetryPep621SubdependencyScope do
  let(:package_class) { Dependabot::Python::FileParser::PoetryLock::Package }

  describe ".pin_targets" do
    context "when the package wasn't found in the lockfile" do
      it "returns no extras, no main marker, and an unknown scope of false" do
        extra_markers, main_marker, scope_unknown = described_class.pin_targets(nil)

        expect(extra_markers).to eq({})
        expect(main_marker).to be_nil
        expect(scope_unknown).to be(false)
      end
    end

    context "with a bare, unparenthesized multi-extra group that isn't uniformly scoped" do
      # Each "or" branch here has its own, distinct condition - the trailing bare group
      # (`extra == "test" or extra == "lint"`) can't be safely treated as one shared unit, since
      # "lint" actually applies with no platform restriction at all.
      let(:package) do
        package_class.new(
          name: "colorama",
          version: "0.4.6",
          optional: true,
          markers: 'platform_system == "Windows" and extra == "test" or extra == "lint"'
        )
      end

      it "falls back to the unchanged marker for every matching extra, rather than misattributing it" do
        extra_markers, main_marker, scope_unknown = described_class.pin_targets(package)

        expect(extra_markers["test"]).to eq(package.markers)
        expect(extra_markers["lint"]).to eq(package.markers)
        expect(main_marker).to be_nil
        expect(scope_unknown).to be(false)
      end
    end

    context "with a marker that mixes a non-extra branch and an extra-gated branch" do
      # The package applies unconditionally on win32 (no extra involved) *and* via the "lint"
      # extra everywhere else - both pins need to coexist, neither should be dropped.
      let(:package) do
        package_class.new(
          name: "some-pkg",
          version: "1.0.0",
          optional: false,
          markers: 'sys_platform == "win32" or extra == "lint"'
        )
      end

      it "reports both a main marker and an extra marker for the same package" do
        extra_markers, main_marker, scope_unknown = described_class.pin_targets(package)

        expect(main_marker).to eq(package.markers)
        expect(extra_markers["lint"]).to eq(package.markers)
        expect(scope_unknown).to be(false)
      end
    end

    context "with an optional package that has no markers at all (legacy lockfile format)" do
      let(:package) do
        package_class.new(
          name: "ftputil",
          version: "5.1.0",
          optional: true,
          markers: nil
        )
      end

      it "reports an unknown scope rather than a safe-to-pin-unconditionally main marker" do
        extra_markers, main_marker, scope_unknown = described_class.pin_targets(package)

        expect(extra_markers).to eq({})
        expect(main_marker).to be_nil
        expect(scope_unknown).to be(true)
      end
    end

    context "with a non-optional package that has no markers at all" do
      let(:package) do
        package_class.new(
          name: "urllib3",
          version: "2.2.3",
          optional: false,
          markers: nil
        )
      end

      it "doesn't report an unknown scope, since a non-optional package is always safe to pin unconditionally" do
        extra_markers, main_marker, scope_unknown = described_class.pin_targets(package)

        expect(extra_markers).to eq({})
        expect(main_marker).to be_nil
        expect(scope_unknown).to be(false)
      end
    end
  end
end
