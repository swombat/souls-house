#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "pathname"

ROOT = Pathname.pwd
REQUIREMENTS_DIRS = [
  ROOT.join("docs/proposals/requirements"),
  ROOT.join("docs/.bak/requirements")
].freeze

REVIEW_SUFFIX_PATTERNS = [
  /-dhh-feedback\b/,
  /-dhh-review\b/,
  /-implementation\b/,
  /-implementation-review\b/,
  /-code-review\b/,
  /-impl\b/,
  /-progress\b/,
  /-architecture-review\b/,
  /-codex-review\b/,
  /-superseded\b/
].freeze

def usage!
  warn "Usage: ruby .agents/skills/architecture/scripts/resolve_architecture_files.rb <requirements-file-or-stem>"
  exit 1
end

def hidden_or_store?(path)
  basename = path.basename.to_s
  basename.start_with?(".") || basename == ".DS_Store"
end

def basename_without_extension(path)
  path.basename.to_s.sub(/\.[^.]+\z/, "")
end

def normalize_slug(value)
  value.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
end

def review_artifact?(path)
  stem = basename_without_extension(path)
  REVIEW_SUFFIX_PATTERNS.any? { |pattern| stem.match?(pattern) }
end

def parse_family(stem)
  match = stem.match(/\A(?<family>\d{6}-\d{2})(?<letter>[a-z]?)(?:[-_](?<slug>.*))?\z/)
  return unless match

  {
    family: match[:family],
    letter: match[:letter].to_s,
    slug: match[:slug].to_s
  }
end

def list_files(dir)
  return [] unless dir.directory?

  Dir.children(dir).sort.map { |entry| dir.join(entry) }.select(&:file?).reject { |path| hidden_or_store?(path) }
end

def exact_file_candidates(argument)
  possible = []
  raw = Pathname.new(argument)

  possible << raw if raw.absolute?
  possible << ROOT.join(argument)
  possible << ROOT.join("#{argument}.md")

  possible.select(&:file?).map(&:cleanpath).uniq
end

def resolve_requirements(argument)
  direct_matches = exact_file_candidates(argument).select { |path| REQUIREMENTS_DIRS.include?(path.dirname) }
  return direct_matches.first if direct_matches.one?
  return direct_matches.first if direct_matches.any?

  stem = File.basename(argument.to_s).sub(/\.[^.]+\z/, "")
  available = REQUIREMENTS_DIRS.flat_map { |dir| list_files(dir) }.reject { |path| review_artifact?(path) }
  # An active proposal supersedes an archived requirement with the same name.
  available = available.uniq { |path| path.basename.to_s }

  exact_stem_matches = available.select do |path|
    file_stem = basename_without_extension(path)
    file_name = path.basename.to_s
    [file_stem, file_name].include?(argument) || [file_stem, file_name].include?(stem)
  end
  return exact_stem_matches.first if exact_stem_matches.one?

  parsed = parse_family(stem)
  return nil unless parsed

  family_matches = available.select do |path|
    file_parsed = parse_family(basename_without_extension(path))
    file_parsed && file_parsed[:family] == parsed[:family]
  end

  if family_matches.size > 1
    same_slug = family_matches.select do |path|
      normalize_slug(parse_family(basename_without_extension(path))[:slug]) == normalize_slug(parsed[:slug])
    end
    family_matches = same_slug if same_slug.any?
  end

  return family_matches.first if family_matches.one?

  nil
end

def letter_rank(letter)
  return 0 if letter.to_s.empty?

  letter.ord - "a".ord + 1
end

def plan_score(plan_path, requirement_slug)
  plan_stem = basename_without_extension(plan_path)
  parsed = parse_family(plan_stem)
  rest = normalize_slug(parsed[:slug])
  req = normalize_slug(requirement_slug)

  score = 0
  score += 100 if !req.empty? && rest == req
  score += 50 if !req.empty? && (rest.start_with?(req) || req.start_with?(rest))
  score += 10 if !req.empty? && rest.include?(req)
  score -= rest.length
  score -= plan_stem.length / 100.0
  score
end

def resolve_plans(requirement_path)
  requirement_stem = basename_without_extension(requirement_path)
  parsed_requirement = parse_family(requirement_stem)
  return nil unless parsed_requirement

  family = parsed_requirement[:family]
  requirement_slug = parsed_requirement[:slug]

  all_family_files = list_files(requirement_path.dirname.parent.join("plans")).select do |path|
    file_parsed = parse_family(basename_without_extension(path))
    file_parsed && file_parsed[:family] == family
  end

  primary_candidates = all_family_files.reject { |path| review_artifact?(path) }
  return nil if primary_candidates.empty?

  highest_rank = primary_candidates.map { |path| letter_rank(parse_family(basename_without_extension(path))[:letter]) }.max
  highest_letter_candidates = primary_candidates.select do |path|
    letter_rank(parse_family(basename_without_extension(path))[:letter]) == highest_rank
  end

  final_plan = highest_letter_candidates.max_by { |path| plan_score(path, requirement_slug) }
  alternates = highest_letter_candidates.reject { |path| path == final_plan }
  supporting_files = (all_family_files - [ final_plan ]).sort_by(&:to_s)

  {
    family: family,
    primary_candidates: primary_candidates.sort_by(&:to_s),
    final_plan: final_plan,
    final_plan_alternates: alternates.sort_by(&:to_s),
    supporting_files: supporting_files
  }
end

argument = ARGV.join(" ").strip
usage! if argument.empty?

unless REQUIREMENTS_DIRS.any?(&:directory?)
  warn "Expected current proposals or archived requirements under #{ROOT}/docs"
  exit 1
end

requirements_file = resolve_requirements(argument)

unless requirements_file
  warn "Could not resolve a requirements file from #{argument.inspect}"
  exit 2
end

plans = resolve_plans(requirements_file)

unless plans
  warn "Could not resolve plan files for #{requirements_file}"
  exit 3
end

requirement_stem = basename_without_extension(requirements_file)
parsed_requirement = parse_family(requirement_stem)
parsed_final_plan = parse_family(basename_without_extension(plans[:final_plan]))

payload = {
  requirements_file: requirements_file.relative_path_from(ROOT).to_s,
  requirements_stem: requirement_stem,
  family: plans[:family],
  requirement_letter: parsed_requirement[:letter],
  requirement_slug: parsed_requirement[:slug],
  final_plan: plans[:final_plan].relative_path_from(ROOT).to_s,
  final_plan_letter: parsed_final_plan[:letter],
  final_plan_alternates: plans[:final_plan_alternates].map { |path| path.relative_path_from(ROOT).to_s },
  primary_plan_candidates: plans[:primary_candidates].map { |path| path.relative_path_from(ROOT).to_s },
  supporting_files: plans[:supporting_files].map { |path| path.relative_path_from(ROOT).to_s }
}

puts JSON.pretty_generate(payload)
