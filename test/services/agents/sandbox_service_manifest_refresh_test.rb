require "test_helper"
require "tmpdir"

module Agents
  class SandboxServiceManifestRefreshTest < ActiveSupport::TestCase

    setup do
      @sandbox = Sandbox.new(agents(:research_assistant))
      @yaml = "services:\n  example:\n    token: fake-manifest-credential\n"
    end

    test "writes only stdin as root after checking running state and ownership" do
      events = []
      capture = ->(*args, **options) do
        events << :exec
        assert_equal [ :running, :ownership, :exec ], events
        assert_equal [ "docker", "exec", "-i", "-u", "0", @sandbox.agent.container_name, "sh", "-c" ], args.first(8)
        assert_equal 9, args.size
        assert_equal({ stdin_data: @yaml }, options)
        assert_not_includes args.join, "fake-manifest-credential"
        [ "", "", process_status(true) ]
      end

      @sandbox.stub(:running?, -> { events << :running; true }) do
        @sandbox.stub(:verify_resources!, -> { events << :ownership }) do
          Open3.stub(:capture3, capture) do
            assert_equal true, @sandbox.refresh_service_manifest!(yaml: @yaml)
          end
        end
      end
    end

    test "stages private unique files beside each destination before ordered atomic replacement" do
      script = manifest_script
      assert_match(/\Aexec >\/dev\/null 2>&1\nset -eu\numask 077\n/, script)
      assert_includes script, 'source_stage=$(mktemp /run/.helixkit-source.yml.XXXXXX)'
      assert_includes script, 'live_stage=$(mktemp /run/helixkit/.services.yml.XXXXXX)'
      assert_includes script, 'trap \'rm -f -- "$source_stage"\' EXIT'
      assert_includes script, "trap 'exit 1' HUP INT TERM"
      assert_includes script, 'cat > "$source_stage"'
      assert_includes script, 'cat > "$live_stage"'
      assert_includes script, "' < /run/helixkit-source.yml"
      source_replace = script.index('mv -fT -- "$source_stage" /run/helixkit-source.yml')
      live_replace = script.index('mv -fT -- "$live_stage" /run/helixkit/services.yml')
      assert source_replace
      assert live_replace
      privilege_drop = script.index("gosu agent sh -c")
      assert_operator source_replace, :<, privilege_drop
      assert_operator privilege_drop, :<, script.index('live_stage=$(mktemp')
      assert_operator source_replace, :<, live_replace
      assert_not_includes script, "chmod"
      assert_not_includes script, "chown"
      assert_not_includes script, "echo"
    end

    test "local shell replaces both files privately without modifying their old inodes" do
      exercise_script do |root, source, live, output, errors, status|
        assert status.success?
        assert_empty output
        assert_empty errors
        [ source, live ].each do |path|
          assert_equal @yaml, File.read(path)
          assert_equal 0o600, File.stat(path).mode & 0o777
          assert_equal "old manifest\n", File.read("#{path}.old")
          assert_not_equal File.stat("#{path}.old").ino, File.stat(path).ino
        end
        assert_equal @yaml, File.read("#{root}/source-at-gosu")
        assert_equal "old manifest\n", File.read("#{root}/live-at-gosu")
        assert_empty Dir.glob("#{root}/**/.*.??????")
      end
    end

    test "local shell failures preserve old destinations and clean private stages without output" do
      %w[source live].each do |failure|
        exercise_script(failure: failure) do |root, source, live, output, errors, status|
          assert_not status.success?
          assert_empty output
          assert_empty errors
          assert_equal(failure == "source" ? "old manifest\n" : @yaml, File.read(source))
          assert_equal "old manifest\n", File.read(live)
          assert_equal "old manifest\n", File.read("#{source}.old")
          assert_equal "old manifest\n", File.read("#{live}.old")
          assert_empty Dir.glob("#{root}/**/.*.??????")
        end
      end
    end

    test "stopped container returns false without exec or recreation" do
      @sandbox.stub(:running?, false) do
        Open3.stub(:capture3, ->(*) { flunk "must not invoke Docker" }) do
          @sandbox.stub(:spawn!, -> { flunk "must not start a container" }) do
            @sandbox.stub(:recreate!, -> { flunk "must not recreate a container" }) do
              assert_equal false, @sandbox.refresh_service_manifest!(yaml: @yaml)
            end
          end
        end
      end
    end

    test "ownership rejection prevents exec" do
      @sandbox.stub(:running?, true) do
        @sandbox.stub(:verify_resources!, -> { raise Resources::OwnershipError, "foreign resources" }) do
          Open3.stub(:capture3, ->(*) { flunk "must not invoke Docker on foreign resources" }) do
            assert_raises(Resources::OwnershipError) { @sandbox.refresh_service_manifest!(yaml: @yaml) }
          end
        end
      end
    end

    test "exec failure returns false if the container stopped or disappeared during the write" do
      [ [ "false\n", "", process_status(true) ], [ "", "No such container", process_status(false) ] ].each do |stopped_result|
        calls = []
        capture = ->(*args, **_options) do
          calls << args
          case calls.size
          when 1 then [ "true\n", "", process_status(true) ]
          when 2 then [ "", @yaml, process_status(false) ]
          when 3 then stopped_result
          else flunk "must not start or recreate the container"
          end
        end
        @sandbox.stub(:verify_resources!, true) do
          Open3.stub(:capture3, capture) do
            assert_equal false, @sandbox.refresh_service_manifest!(yaml: @yaml)
          end
        end
        inspect_command = [ "docker", "container", "inspect", "--format", "{{.State.Running}}", @sandbox.agent.container_name ]
        assert_equal inspect_command, calls.first
        assert_equal "exec", calls.second[1]
        assert_equal inspect_command, calls.third
      end
    end

    test "an unverifiable running state after exec failure raises a generic error" do
      running_checks = 0
      running = -> do
        running_checks += 1
        raise IOError, @yaml if running_checks > 1
        true
      end
      @sandbox.stub(:running?, running) do
        @sandbox.stub(:verify_resources!, true) do
          Open3.stub(:capture3, [ "", @yaml, process_status(false) ]) do
            error = assert_raises(Sandbox::SandboxError) { @sandbox.refresh_service_manifest!(yaml: @yaml) }
            assert_equal "Failed to refresh service manifest", error.message
            assert_nil error.cause
          end
        end
      end
    end

    test "failed exec hides stdout stderr and underlying exception details" do
      [
        ->(*) { [ @yaml, @yaml, process_status(false) ] },
        ->(*) { raise IOError, @yaml }
      ].each do |capture|
        with_running_sandbox do
          Open3.stub(:capture3, capture) do
            output, errors = capture_io do
              error = assert_raises(Sandbox::SandboxError) { @sandbox.refresh_service_manifest!(yaml: @yaml) }
              assert_equal "Failed to refresh service manifest", error.message
              assert_nil error.cause
              assert_not_includes error.full_message, "fake-manifest-credential"
            end
            assert_empty output
            assert_empty errors
          end
        end
      end
    end

    private

    def manifest_script
      script = nil
      with_running_sandbox do
        Open3.stub(:capture3, ->(*args, **_options) { script = args.last; [ "", "", process_status(true) ] }) do
          @sandbox.refresh_service_manifest!(yaml: @yaml)
        end
      end
      script
    end

    # Runs only in a disposable temp directory, as the test user. Fake gosu
    # checks ordering but cannot prove the real runtime's UID transition.
    def exercise_script(failure: nil)
      script = manifest_script
      Dir.mktmpdir("manifest-refresh-") do |root|
        FileUtils.mkdir_p([ "#{root}/helixkit", "#{root}/bin" ])
        source = "#{root}/helixkit-source.yml"
        live = "#{root}/helixkit/services.yml"
        [ source, live ].each do |path|
          File.write(path, "old manifest\n", mode: "w", perm: 0o600)
          File.link(path, "#{path}.old")
        end
        File.write("#{root}/bin/gosu", <<~'SHELL', perm: 0o700)
          #!/bin/sh
          set -eu
          test "$1" = agent
          shift
          cat "$TEST_ROOT/helixkit-source.yml" > "$TEST_ROOT/source-at-gosu"
          cat "$TEST_ROOT/helixkit/services.yml" > "$TEST_ROOT/live-at-gosu"
          exec "$@"
        SHELL
        File.write("#{root}/bin/mv", <<~'SHELL', perm: 0o700)
          #!/bin/sh
          for destination do :; done
          if [ "$destination" = "$FAIL_RENAME" ]; then
            printf '%s\n' "$FAKE_SECRET" >&2
            exit 1
          fi
          exec /usr/bin/mv "$@"
        SHELL
        env = {
          "PATH" => "#{root}/bin:/usr/bin:/bin", "TEST_ROOT" => root,
          "FAIL_RENAME" => { "source" => source, "live" => live }.fetch(failure, ""),
          "FAKE_SECRET" => @yaml
        }
        # Substitute every /run path, including those inside the nested shell.
        local_script = script.gsub("/run/", "#{root}/")
        assert_not_includes local_script, "/run/"
        output, errors, status = Open3.capture3(env, "sh", "-c", local_script, stdin_data: @yaml)
        yield root, source, live, output, errors, status
      end
    end

    def with_running_sandbox(&block)
      @sandbox.stub(:running?, true) do
        @sandbox.stub(:verify_resources!, true, &block)
      end
    end

    def process_status(success)
      Struct.new(:success?).new(success)
    end

  end
end
