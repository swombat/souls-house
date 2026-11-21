require "test_helper"

module Backup
  class PausedResidentWatchJobTest < ActiveJob::TestCase

    include ActionMailer::TestHelper

    setup do
      @agent = agents(:research_assistant)
      @agent.update!(runtime: "external", uuid: SecureRandom.uuid_v7, container_name: "resident-watch-test")
      # The test cache keeps nothing; the job's memory between runs is in it.
      @cache = ActiveSupport::Cache::MemoryStore.new
      @start = Time.zone.parse("2026-11-20 04:00")
    end

    test "a resident paused for half an hour is reported once, never unpaused, and forgotten when it runs again" do
      paused = "resident-watch-test\nsomething-else\n"
      assert_no_error_reported { watch(paused, at: @start) }
      assert_no_error_reported { watch(paused, at: @start + 20.minutes) }
      assert_error_reported(ContainerPause::StillPaused) { watch(paused, at: @start + 30.minutes) }
      assert_no_error_reported { watch(paused, at: @start + 40.minutes) }

      watch("", at: @start + 50.minutes)
      assert_no_error_reported { watch(paused, at: @start + 60.minutes) }
      assert_error_reported(ContainerPause::StillPaused) { watch(paused, at: @start + 90.minutes) }
    end

    test "a backup's pause of a few minutes is never reported" do
      assert_no_error_reported do
        watch("resident-watch-test\n", at: @start)
        watch("", at: @start + 10.minutes)
        watch("resident-watch-test\n", at: @start + 40.minutes)
      end
      assert_no_enqueued_emails
    end

    test "a frozen resident's account admins and the site admins are emailed once, and told again when it runs" do
      admins = @agent.account.memberships.confirmed.admins.filter_map(&:user)
      operator = users(:site_admin_user)
      assert admins.any?
      paused = "resident-watch-test\n"

      watch(paused, at: @start)
      assert_no_enqueued_emails
      watch(paused, at: @start + 30.minutes)
      recipients = (admins + [ operator ]).uniq
      assert_enqueued_emails recipients.size
      recipients.each do |user|
        assert_enqueued_email_with ResidentHealthMailer, :resident_frozen,
          args: [ @agent, @start.iso8601, user, { operator: user == operator } ]
      end

      clear_enqueued_jobs
      watch(paused, at: @start + 40.minutes)
      assert_no_enqueued_emails

      watch(nil, at: @start + 45.minutes)
      assert_no_enqueued_emails # Docker not answering is not a recovery

      watch("", at: @start + 50.minutes)
      assert_enqueued_emails recipients.size
      recipients.each do |user|
        assert_enqueued_email_with ResidentHealthMailer, :resident_unfrozen, args: [ @agent, @start.iso8601, user ]
      end

      clear_enqueued_jobs
      watch("", at: @start + 60.minutes)
      assert_no_enqueued_emails
    end

    test "a pause that never lasted long enough to report sends no recovery email" do
      watch("resident-watch-test\n", at: @start)
      watch("", at: @start + 10.minutes)
      assert_no_enqueued_emails
    end

    test "Docker not answering keeps what was seen" do
      watch("resident-watch-test\n", at: @start)
      watch(nil, at: @start + 10.minutes)
      assert_error_reported(ContainerPause::StillPaused) { watch("resident-watch-test\n", at: @start + 30.minutes) }
    end

    test "a resident on a VM is the VM runner's, and nothing runs while backups are off" do
      Agents::RemoteRuntime.stub(:remote?, true) do
        assert_no_error_reported do
          watch("resident-watch-test\n", at: @start)
          watch("resident-watch-test\n", at: @start + 1.hour)
        end
      end
      Agents::Config.stub(:backups_enabled?, false) do
        ContainerPause.stub(:capture, ->(*) { flunk "backups are off" }) { PausedResidentWatchJob.perform_now }
      end
    end

    private

    # Only `docker ps` may be called: the job never unpauses.
    def watch(paused, at:)
      docker = lambda do |*args|
        assert_equal "ps", args[1], "the watch only lists; it never unpauses"
        paused.nil? ? [ "", "daemon down", failed ] : [ paused, "", ok ]
      end
      Agents::Config.stub(:backups_enabled?, true) do
        LocalInstance.stub(:current, Struct.new(:namespace).new(nil)) do
          Rails.stub(:cache, @cache) do
            ContainerPause.stub(:capture, docker) { PausedResidentWatchJob.perform_now(now: at) }
          end
        end
      end
    end

    def ok = Struct.new(:success?).new(true)
    def failed = Struct.new(:success?).new(false)

  end
end
