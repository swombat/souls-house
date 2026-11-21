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

    test "a frozen resident's owner and the site admins are emailed once each; nobody else" do
      owner = @agent.account.owner
      operator = users(:site_admin_user)
      by_account = site_admin_by_account!
      clear_enqueued_jobs
      paused = "resident-watch-test\n"

      watch(paused, at: @start)
      assert_no_enqueued_emails
      watch(paused, at: @start + 30.minutes)
      expected = [ owner, operator, by_account ].uniq
      assert_enqueued_emails expected.size
      expected.each do |user|
        assert_enqueued_email_with ResidentHealthMailer, :resident_frozen, args: [ @agent, @start.iso8601, user ]
      end

      clear_enqueued_jobs
      watch(paused, at: @start + 40.minutes)
      assert_no_enqueued_emails
    end

    test "one recipient's failed send doesn't stop the others, and is tried again while the pause holds" do
      owner = @agent.account.owner
      operator = users(:site_admin_user)
      paused = "resident-watch-test\n"
      watch(paused, at: @start)

      real = ResidentHealthMailer.method(:resident_frozen)
      failing = lambda do |agent, since, user|
        raise IOError, "queue down" if user == owner
        real.call(agent, since, user)
      end
      ResidentHealthMailer.stub(:resident_frozen, failing) { watch(paused, at: @start + 30.minutes) }
      assert_enqueued_email_with ResidentHealthMailer, :resident_frozen, args: [ @agent, @start.iso8601, operator ]

      clear_enqueued_jobs
      watch(paused, at: @start + 35.minutes)
      assert_enqueued_emails 1
      assert_enqueued_email_with ResidentHealthMailer, :resident_frozen, args: [ @agent, @start.iso8601, owner ]
    end

    test "an owner whose membership is still a pending invitation isn't emailed" do
      owner = @agent.account.owner
      refute owner.site_admin, "the owner must not pass as an operator here"
      @agent.account.memberships.owners.find_by!(user: owner).update_columns(confirmed_at: nil)
      paused = "resident-watch-test\n"

      watch(paused, at: @start)
      asked = []
      real = ResidentHealthMailer.method(:resident_frozen)
      recording = lambda do |agent, since, user|
        asked << user
        real.call(agent, since, user)
      end
      ResidentHealthMailer.stub(:resident_frozen, recording) { watch(paused, at: @start + 30.minutes) }
      assert_includes asked, users(:site_admin_user)
      refute_includes asked, owner
    end

    test "leaving the paused list sends nothing: a stopped or removed container leaves it too" do
      watch("resident-watch-test\n", at: @start)
      watch("resident-watch-test\n", at: @start + 30.minutes)
      clear_enqueued_jobs
      watch("", at: @start + 40.minutes)
      watch(nil, at: @start + 45.minutes)
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

    # A confirmed member of an enabled site-admin account, without the flag
    # on the user; a member of a disabled one must not count.
    def site_admin_by_account!
      user = User.create!(email_address: "operator-by-account@example.com", password: "password123456")
      enabled = Account.create!(name: "Operators", account_type: :team, is_site_admin: true)
      enabled.memberships.create!(user:, role: "member", confirmed_at: Time.current)
      disabled_user = User.create!(email_address: "operator-disabled@example.com", password: "password123456")
      disabled = Account.create!(name: "Old operators", account_type: :team, is_site_admin: true, disabled_at: Time.current)
      disabled.memberships.create!(user: disabled_user, role: "member", confirmed_at: Time.current)
      user
    end

    def ok = Struct.new(:success?).new(true)
    def failed = Struct.new(:success?).new(false)

  end
end
