require "minitest/autorun"
require "pty"
require "open3"
require "rbconfig"
require "timeout"
require "tmpdir"
require "fileutils"

class InstanceCommandTest < Minitest::Test

  ROOT = File.expand_path("../..", __dir__)
  RUBY = RbConfig.ruby
  RUNNER = File.join(ROOT, "config/instance_command.rb")
  CLI = File.join(ROOT, "bin/instance")

  def setup
    # Exercise real CLI locks without contending with other parallel test cases
    # or writing identity claims into the developer's home directory.
    @checkout = Dir.mktmpdir("instance-command-")
    %w[bin config].each { |dir| FileUtils.mkdir_p(File.join(@checkout, dir)) }
    %w[bin/instance config/local_instance.rb config/instance_command.rb config/instance_terminal.rb config/instance_toolchain.rb .ruby-version package.json].each do |path|
      FileUtils.cp(File.join(ROOT, path), File.join(@checkout, path))
    end
    @cli = File.join(@checkout, "bin/instance")
    @env = { "HOME" => @checkout, "SOULSHOUSE_INSTANCE" => ENV.fetch("SOULSHOUSE_INSTANCE", "8") }
  end

  def teardown
    FileUtils.remove_entry(@checkout) if @checkout
  end

  def read_until(io, marker)
    text = +""
    Timeout.timeout(10) { text << io.readpartial(4096) until text.include?(marker) }
    text
  rescue EOFError, Errno::EIO
    raise "Terminal closed before #{marker.inspect}: #{text}"
  end

  def with_terminal(*command, **options)
    PTY.spawn(*command, **options) do |reader, writer, pid|
      yield reader, writer, pid
    ensure
      Process.kill("CONT", pid) rescue Errno::ESRCH
      Process.kill("TERM", pid) rescue Errno::ESRCH
      Timeout.timeout(5) { Process.waitpid(pid) } rescue Errno::ECHILD
    end
  end

  def driver(program)
    <<~CODE
      require #{RUNNER.inspect}
      STDOUT.sync = true
      result = LocalInstance::Command.run([#{RUBY.inspect}, "-e", #{program.inspect}])
      puts "RESULT:" + result.to_s
      puts "RESTORED:" + (LocalInstance::Terminal.tcgetpgrp(STDIN.fileno) == Process.getpgrp).to_s
      sleep 0.2
    CODE
  end

  def test_terminal_input_and_foreground_restoration
    with_terminal(RUBY, "-e", driver('STDOUT.sync=true; puts "READY"; puts "READ:" + STDIN.gets.strip')) do |reader, writer, _pid|
      read_until(reader, "READY")
      writer.puts "hello"
      output = read_until(reader, "RESTORED:true")
      assert_includes output, "READ:hello"
      assert_includes output, "RESULT:0"
    end
  end

  def test_terminal_ctrl_c_reaches_child_once_and_preserves_exit_status
    program = 'STDOUT.sync=true; Signal.trap("INT") { puts "INT_RECEIVED"; exit 42 }; puts "READY"; STDIN.gets'
    with_terminal(RUBY, "-e", driver(program)) do |reader, writer, _pid|
      read_until(reader, "READY")
      writer.write("\u0003")
      output = read_until(reader, "RESTORED:true")
      assert_equal 1, output.scan("INT_RECEIVED").length
      assert_includes output, "RESULT:42"
    end
  end

  def test_terminal_suspend_resume_returns_input_to_child
    with_terminal(RUBY, "-e", driver('STDOUT.sync=true; puts "READY"; puts "READ:" + STDIN.gets.strip')) do |reader, writer, pid|
      read_until(reader, "READY")
      writer.write("\u001a")
      _, status = Timeout.timeout(10) { Process.waitpid2(pid, Process::WUNTRACED) }
      assert status.stopped?
      Process.kill("CONT", pid)
      writer.puts "resumed"
      assert_includes read_until(reader, "RESTORED:true"), "READ:resumed"
    end
  end

  def test_term_reaches_headless_child_and_grandchild
    grandchild = 'STDOUT.sync=true; Signal.trap("TERM") { puts "GRANDCHILD_TERM"; exit }; puts "GRANDCHILD_READY"; sleep 60'
    child = "STDOUT.sync=true; Signal.trap('TERM') { puts 'CHILD_TERM'; exit }; Process.spawn(#{RUBY.inspect}, '-e', #{grandchild.inspect}); sleep 60"
    wrapper = "require #{RUNNER.inspect}; exit LocalInstance::Command.run([#{RUBY.inspect}, '-e', #{child.inspect}])"
    Open3.popen3(RUBY, "-e", wrapper) do |stdin, stdout, stderr, process|
      stdin.close
      read_until(stdout, "GRANDCHILD_READY")
      Process.kill("TERM", process.pid)
      output = Timeout.timeout(10) { stdout.read }
      assert_includes output, "CHILD_TERM"
      assert_includes output, "GRANDCHILD_TERM"
      assert Timeout.timeout(5) { process.value }.success?, stderr.read
    ensure
      Process.kill("TERM", process.pid) rescue Errno::ESRCH
    end
  end

  def test_terminal_reader_keeps_checkout_lock
    with_terminal(@env, RUBY, @cli, "exec", "command", "--", RUBY, "-e", 'STDOUT.sync=true; puts "READY"; STDIN.gets', chdir: @checkout) do |reader, writer, _pid|
      read_until(reader, "READY")
      output, status = Open3.capture2e(@env, RUBY, @cli, "exec", "command", "--", RUBY, "-e", 'puts "UNREACHABLE"', chdir: @checkout)
      refute status.success?
      assert_includes output, "never delete the lock file"
      refute_includes output, "UNREACHABLE"
      writer.puts "done"
    end
  end

  def test_ruby_command_runs_without_bun_on_path
    Dir.mktmpdir do |directory|
      output, status = Open3.capture2e(@env.merge("PATH" => directory), RUBY, @cli, "exec", "command", "--", RUBY, "-e", 'puts "RUBY_OK"', chdir: @checkout)
      assert status.success?, output
      assert_includes output, "RUBY_OK"
    end
  end

  def test_setup_and_browser_runner_require_bun_before_database_work
    Dir.mktmpdir do |directory|
      [ [ CLI, "setup" ], [ File.join(ROOT, "playwright/run-backend.rb"), "e2e" ] ].each do |arguments|
        output, status = Open3.capture2e({ "PATH" => directory }, RUBY, *arguments)
        refute status.success?
        assert_includes output, "Bun is required for setup/frontend commands"
      end
    end
  end

end
