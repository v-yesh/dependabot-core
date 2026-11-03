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

      # A single `extra == "name"` clause.
      EXTRA_SINGLE = 'extra\s*==\s*"[^"]+"'
      # Several single clauses joined by "or" - how Poetry writes a package needed by more than
      # one extra. Safe to treat as "pure extra selection, nothing else" wherever it appears, since
      # there's no other condition around it to misattribute.
      EXTRA_GROUP = T.let("#{EXTRA_SINGLE}(?:\\s+or\\s+#{EXTRA_SINGLE})*".freeze, String)
      # A clause that's safe to isolate as one uniformly-scoped unit when splitting a marker into
      # "extra selector" + "remaining condition": either a single extra, or a *balanced,
      # parenthesized* multi-extra group. A **bare**, unparenthesized multi-extra group is excluded
      # here on purpose - each "or"-joined extra there can carry its own distinct trailing
      # condition (e.g. `sys_platform == "win32" and extra == "test" or extra == "lint"`, where
      # "lint" applies unconditionally), so splitting it as one unit would wrongly apply one
      # extra's condition to the other. The enclosing parens, when present, are only matched as a
      # tight, balanced pair immediately around the group itself: without that, a marker where
      # parens wrap a larger expression (e.g. a whole `(extra == "x" and sys_platform == "win32")`
      # clause) would have its opening paren consumed without its matching close, leaving an
      # unbalanced, invalid fragment in the remainder.
      SAFE_EXTRA_CLAUSE = T.let("(?:#{EXTRA_SINGLE}|\\(\\s*#{EXTRA_GROUP}\\s*\\))".freeze, String)
      EXTRA_ONLY_MARKER = /\A(?:#{EXTRA_GROUP}|\(\s*#{EXTRA_GROUP}\s*\))\z/
      EXTRA_CLAUSE_THEN_REST = /\A#{SAFE_EXTRA_CLAUSE}\s+and\s+(?<rest>.+)\z/
      REST_THEN_EXTRA_CLAUSE = /\A(?<rest>.+?)\s+and\s+#{SAFE_EXTRA_CLAUSE}\z/
      EXTRA_NAME = /extra\s*==\s*"([^"]+)"/
      ANOTHER_EXTRA_CLAUSE = /extra\s*==\s*"/

      class << self
        extend T::Sig

        # Reads which extra(s), if any, a sub-dependency was scoped to (Poetry records this as
        # `markers = "extra == \"name\""` on its package entry), and separately any plain
        # environment marker (platform/Python version) it carries as a non-optional, main
        # dependency - so neither gets silently dropped when the pin is constructed. A marker can
        # carry both at once (e.g. `sys_platform == "win32" or extra == "lint"`, needed
        # unconditionally on Windows *and* via the "lint" extra everywhere else), so the two aren't
        # mutually exclusive. Returns [extra_markers, main_marker, scope_unknown]: extra_markers
        # maps each matching extra to any remaining non-extra condition; scope_unknown flags a
        # legacy-format optional package with no markers at all, where the original extra scope
        # can't be recovered from this package entry alone.
        sig do
          params(package: T.nilable(Dependabot::Python::FileParser::PoetryLock::Package))
            .returns([T::Hash[String, T.nilable(String)], T.nilable(String), T::Boolean])
        end
        def pin_targets(package)
          return [{}, nil, false] unless package

          extra_markers = T.let({}, T::Hash[String, T.nilable(String)])
          main_markers = T.let([], T::Array[String])

          package.marker_strings.each do |marker|
            extra_names = marker.scan(EXTRA_NAME).flatten
            if extra_names.empty?
              main_markers << marker
            else
              remainder = marker_without_extra_clause(marker)
              extra_names.each { |extra| extra_markers[extra] = remainder }
              main_markers << marker if marker_has_main_branch?(marker)
            end
          end

          scope_unknown = package.optional && extra_markers.empty? && main_markers.empty?

          [extra_markers, main_markers.first, scope_unknown]
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

        # Shared by both call sites: works out which pin string(s) to add, given pin_targets'
        # result. Returns [main_pin, extra_pins] - main_pin is nil if no unconditional/main pin
        # should be added; extra_pins maps each extra to its own pin string. Main and extra pins
        # aren't mutually exclusive - a marker like `sys_platform == "win32" or extra == "lint"`
        # needs both. An optional package whose scope can't be recovered from the lockfile at all
        # (scope_unknown) is deliberately left unpinned here, rather than risking promoting it into
        # the unconditional main install. Callers append the strings into the pyproject hash
        # themselves, since that hash's value types are untyped TOML data this module shouldn't
        # need to know about.
        sig do
          params(
            pin: String,
            extra_markers: T::Hash[String, T.nilable(String)],
            main_marker: T.nilable(String),
            scope_unknown: T::Boolean
          ).returns([T.nilable(String), T::Hash[String, String]])
        end
        def pins_for(pin, extra_markers, main_marker, scope_unknown)
          main_pin = pin_with_marker(pin, main_marker) if main_marker || (extra_markers.empty? && !scope_unknown)

          extra_pins = extra_markers.to_h { |extra, remaining_marker| [extra, pin_with_marker(pin, remaining_marker)] }

          [main_pin, extra_pins]
        end

        private

        sig { params(pin: String, marker: T.nilable(String)).returns(String) }
        def pin_with_marker(pin, marker)
          marker ? "#{pin}; #{marker}" : pin
        end

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

        # True if a marker's top-level "or" branches include at least one that doesn't reference
        # any extra at all - meaning the package also applies unconditionally (under that branch's
        # own condition), independent of any extra. Splitting only on *top-level* "or" (ignoring
        # any inside parens) matters: a parenthesized group like `(extra == "a" or extra == "b")`
        # is one unit, not two independent branches.
        sig { params(marker: String).returns(T::Boolean) }
        def marker_has_main_branch?(marker)
          top_level_or_branches(marker).any? { |branch| !branch.match?(ANOTHER_EXTRA_CLAUSE) }
        end

        # Splits a marker on "or" at paren-depth zero only, so a parenthesized sub-expression is
        # never split apart from itself.
        sig { params(marker: String).returns(T::Array[String]) }
        def top_level_or_branches(marker)
          branches = T.let([], T::Array[String])
          depth = 0
          current = +""

          i = 0
          while i < marker.length
            if marker[i] == "(" || marker[i] == ")"
              depth += marker[i] == "(" ? 1 : -1
              current << T.must(marker[i])
              i += 1
            elsif depth.zero? && marker[i, 4] == " or "
              branches << current
              current = +""
              i += 4
            else
              current << T.must(marker[i])
              i += 1
            end
          end
          branches << current

          branches.map(&:strip)
        end
      end
    end
  end
end
