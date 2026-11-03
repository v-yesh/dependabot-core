# typed: strong
# frozen_string_literal: true

require "sorbet-runtime"
require "dependabot/python/file_parser/poetry_lock"

module Dependabot
  module Python
    # Pure sub-dependencies of a PEP 621-only project (no [tool.poetry] table) need a pin added
    # directly to project.dependencies/project.optional-dependencies - both when the file updater
    # pins the final lockfile's sub-dependencies, and when the version resolver pins a scratch
    # manifest to drive `poetry lock` during version resolution. Both call sites need the pin
    # scoped the same way Poetry originally recorded it in the pre-update poetry.lock (extra-only,
    # environment-conditional, or both), or they risk broadening the lockfile's install conditions,
    # or causing the resolver to reject an update that's only invalid in an unrelated environment.
    module PoetryPep621SubdependencyScope
      extend T::Sig

      # Matches a single `extra == "name"` clause, or several joined by "or" - how Poetry writes a
      # package needed by more than one extra. The group's enclosing parens, if any, are only
      # matched as a tight, balanced pair immediately around the group itself: without that,
      # a marker where parens wrap a larger expression (e.g. a whole
      # `(extra == "x" and sys_platform == "win32")` clause) would have its opening paren consumed
      # here without its matching close, leaving an unbalanced, invalid fragment in the remainder.
      EXTRA_GROUP = 'extra\s*==\s*"[^"]+"(?:\s+or\s+extra\s*==\s*"[^"]+")*'
      EXTRA_CLAUSE = T.let("(?:#{EXTRA_GROUP}|\\(\\s*#{EXTRA_GROUP}\\s*\\))".freeze, String)
      EXTRA_ONLY_MARKER = /\A#{EXTRA_CLAUSE}\z/
      EXTRA_CLAUSE_THEN_REST = /\A#{EXTRA_CLAUSE}\s+and\s+(?<rest>.+)\z/
      REST_THEN_EXTRA_CLAUSE = /\A(?<rest>.+?)\s+and\s+#{EXTRA_CLAUSE}\z/
      EXTRA_NAME = /extra\s*==\s*"([^"]+)"/
      ANOTHER_EXTRA_CLAUSE = /extra\s*==\s*"/

      class << self
        extend T::Sig

        # Reads which extra(s), if any, a sub-dependency was scoped to (Poetry records this as
        # `markers = "extra == \"name\""` on its package entry), and separately any plain
        # environment marker (platform/Python version) it carries as a non-optional, main
        # dependency - so neither gets silently dropped when the pin is constructed. Returns
        # [extra_markers, main_marker], where extra_markers maps each matching extra to any
        # remaining non-extra condition.
        sig do
          params(package: T.nilable(Dependabot::Python::FileParser::PoetryLock::Package))
            .returns([T::Hash[String, T.nilable(String)], T.nilable(String)])
        end
        def pin_targets(package)
          return [{}, nil] unless package

          extra_markers = T.let({}, T::Hash[String, T.nilable(String)])
          main_markers = T.let([], T::Array[String])

          package.marker_strings.each do |marker|
            extra_names = marker.scan(EXTRA_NAME).flatten
            if extra_names.empty?
              main_markers << marker
            else
              remainder = marker_without_extra_clause(marker)
              extra_names.each { |extra| extra_markers[extra] = remainder }
            end
          end

          [extra_markers, main_markers.first]
        end

        # Shared by both call sites (the file updater and the version resolver), since each needs
        # to read the pre-update lockfile's packages to scope a sub-dependency pin the same way.
        sig do
          params(lockfile: T.nilable(Dependabot::DependencyFile))
            .returns(T::Array[Dependabot::Python::FileParser::PoetryLock::Package])
        end
        def packages_from_lockfile(lockfile)
          return [] unless lockfile

          Dependabot::Python::FileParser::PoetryLock.from_file(lockfile).packages
        end

        private

        # Strips the extra-selecting clause(s) from a marker, leaving any other condition intact
        # (e.g. "extra == \"security\" and sys_platform == \"win32\"" -> "sys_platform ==
        # \"win32\""). Falls back to the marker unchanged if it can't confidently isolate the
        # remainder, or if the isolated remainder still references a *different* extra's own
        # clause (a compound marker whose "or" branches can't be safely divided between each
        # extra's pin without changing when each applies) - that fallback is still valid PEP 508
        # syntax on an entry already scoped to the extra, just slightly redundant.
        sig { params(marker: String).returns(T.nilable(String)) }
        def marker_without_extra_clause(marker)
          return if marker.match?(EXTRA_ONLY_MARKER)

          match = marker.match(EXTRA_CLAUSE_THEN_REST) || marker.match(REST_THEN_EXTRA_CLAUSE)
          return marker unless match

          rest = T.must(match[:rest])
          return marker if rest.match?(ANOTHER_EXTRA_CLAUSE)

          rest
        end
      end
    end
  end
end
