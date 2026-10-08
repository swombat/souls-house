# frozen_string_literal: true

require "ripper"
require "set"

# Mirrors Rails 8.1's default discovery.
# System tests are run once by the workflow, not by this runner.
module RailsTestShard
  class Error < StandardError; end

  def self.arguments(argv)
    list = argv.first == "--list"
    values = list ? argv.drop(1) : argv
    unless values.length == 2 && values.all? { |value| value.match?(/\A[1-9]\d*\z/) }
      raise Error, "Usage: ruby scripts/run-rails-shard.rb [--list] SHARD TOTAL"
    end
    shard, total = values.map(&:to_i)
    raise Error, "SHARD must not exceed TOTAL" if shard > total
    [shard, total, list]
  end

  class Plan
    attr_reader :root, :files

    def initialize(root)
      @root = File.expand_path(root)
      @files = Dir.glob("test/**/*_test.rb", base: @root).sort.reject do |path|
        path.match?(%r{\Atest/(system|dummy|fixtures)/}) ||
          path.include?("test/isolation/assets/node_modules")
      end
      @dependencies = {}
    end

    def groups
      remaining = files.to_set
      edges = files.to_h { |file| [file, Set.new] }
      files.each do |file|
        reachable_tests(file).each do |dependency|
          edges.fetch(file).add(dependency)
          edges.fetch(dependency).add(file)
        end
      end
      result = []
      until remaining.empty?
        pending = [remaining.min]
        group = []
        until pending.empty?
          file = pending.pop
          next unless remaining.delete?(file)
          group << file
          pending.concat(edges.fetch(file).to_a)
        end
        result << group.sort
      end
      result.sort_by(&:first)
    end

    def shards(total)
      raise Error, "TOTAL must be a positive integer" unless total.is_a?(Integer) && total.positive?
      buckets = Array.new(total) { [] }
      weights = Array.new(total, 0)
      # Byte size is a cheap runtime heuristic, not a measured duration.
      # Largest groups first; path and shard index break ties deterministically.
      groups.sort_by { |group| [-weight(group), group.first] }.each do |group|
        index = (0...total).min_by { |candidate| [weights[candidate], candidate] }
        buckets[index].concat(group)
        weights[index] += weight(group)
      end
      buckets.map(&:sort)
    end

    private

    def weight(group)
      group.sum { |file| File.size(File.join(root, file)) }
    end

    def reachable_tests(file, seen = Set.new)
      return Set.new unless seen.add?(file)
      dependencies(file).each_with_object(Set.new) do |dependency, result|
        if files.include?(dependency)
          result.add(dependency)
        elsif dependency.start_with?("test/") && dependency.end_with?("_test.rb")
          raise Error, "#{file} requires excluded test #{dependency}"
        end
        result.merge(reachable_tests(dependency, seen))
      end
    end

    def dependencies(file)
      @dependencies[file] ||= begin
        tree = Ripper.sexp(File.read(File.join(root, file), encoding: "UTF-8"))
        raise Error, "Cannot parse #{file}" unless tree
        paths = []
        visit(tree) do |method, args, line|
          argument = argument_list(args)&.then { |values| values.one? ? values.first : nil }
          path = literal(argument)
          from_root = false
          if !path && method != "require_relative"
            path = rails_root_path(argument)
            from_root = !path.nil?
          end
          unless path
            raise Error, "#{file}:#{line}: dynamic #{method} cannot be safely sharded"
          end
          candidates = if method == "require_relative"
            [File.expand_path(path, File.dirname(File.join(root, file)))]
          elsif from_root
            [File.expand_path(path, root)]
          else
            [File.expand_path(path, File.join(root, "test")), File.expand_path(path, root)]
          end
          candidates.each do |candidate|
            candidate += ".rb" unless candidate.end_with?(".rb")
            next unless candidate.start_with?("#{root}/test/") && File.file?(candidate)
            paths << candidate.delete_prefix("#{root}/")
            break
          end
          if method == "require_relative" && candidates.none? { |candidate| File.file?(candidate.end_with?(".rb") ? candidate : "#{candidate}.rb") }
            raise Error, "#{file}:#{line}: missing relative dependency #{path}"
          end
        end
        paths.uniq
      end
    end

    # Parse actual calls rather than scanning comments, test names or heredocs.
    def visit(node, &block)
      return unless node.is_a?(Array)
      token, args = case node.first
      when :command then [node[1], node[2]]
      when :vcall then [node[1], nil]
      when :command_call
        [kernel_receiver?(node[1]) ? node[3] : nil, node[4]]
      when :method_add_arg
        call = node[1]
        token = if call[0] == :fcall
          call[1]
        elsif call[0] == :call && kernel_receiver?(call[1])
          call[3]
        end
        [token, node[2]]
      end
      if token && %w[require require_relative load].include?(token[1])
        yield token[1], args, token[2][0]
        return
      end
      node.each { |child| visit(child, &block) }
    end

    def kernel_receiver?(node)
      node && node[0] == :var_ref && node[1][0] == :@const && node[1][1] == "Kernel"
    end

    def argument_list(node)
      return unless node.is_a?(Array)
      node = node[1] if node[0] == :arg_paren
      node[1] if node && node[0] == :args_add_block && node[2] == false
    end

    def literal(node)
      return unless node && node[0] == :string_literal
      content = node[1]
      return unless content[0] == :string_content &&
        content.drop(1).all? { |part| part[0] == :@tstring_content }
      content.drop(1).map { |part| part[1] }.join
    end

    def rails_root_path(node)
      return unless node && node[0] == :method_add_arg
      call = node[1]
      return unless call[0] == :call && call[3][1] == "join"
      receiver = call[1]
      return unless receiver[0] == :call && receiver[3][1] == "root" &&
        receiver[1][0] == :var_ref && receiver[1][1][0] == :@const &&
        receiver[1][1][1] == "Rails"
      parts = argument_list(node[2])
      return unless parts && !parts.empty?
      strings = parts.map { |part| literal(part) }
      File.join(*strings) if strings.all?
    end
  end

  def self.run(argv, root:, executor: nil, out: $stdout, err: $stderr)
    shard, total, list = arguments(argv)
    selected = Plan.new(root).shards(total).fetch(shard - 1)
    if list
      selected.each { |file| out.puts(file) }
      return 0
    end
    out.puts("Rails shard #{shard}/#{total}: #{selected.length} files")
    selected.each { |file| out.puts(file) }
    return 0 if selected.empty?
    command = [File.join(File.expand_path(root), "bin/rails"), "test", *selected]
    success = executor ? executor.call(command) : system(*command, chdir: root)
    success ? 0 : ($?&.exitstatus || 1)
  rescue Error, SystemCallError => error
    err.puts(error.message)
    1
  end
end
