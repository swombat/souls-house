require "test_helper"

class Agents::AllowanceBrakeTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @agent.update!(model_id: "openai/gpt-5", allowance_brake_threshold_percent: 40,
      provider_auth_modes: { "openai" => "oauth_account" })
    @reading = AllowanceBrakeReading.create!(agent: @agent, provider: "openai", model: "gpt-5",
      windows: [ window(30) ], checked_at: Time.current, observed_at: Time.current,
      refresh_requested_at: Time.current)
  end

  test "strict below threshold, equal, above, zero and disabled" do
    assert gate.braked?
    [ 40, 60, 100 ].each do |value|
      @reading.update!(windows: [ window(value) ])
      assert_equal "available", gate.status
    end
    @agent.update!(allowance_brake_threshold_percent: 0)
    @reading.update!(windows: [ window(0) ])
    assert_not gate.braked?
    @agent.update!(allowance_brake_threshold_percent: nil)
    assert_equal "disabled", gate.status
    assert_not @agent.scheduled_wakes_essential?
  end

  test "essential bypass and API-key inference are not subscription verdicts" do
    assert_equal "essential", Agents::AllowanceBrake.check(@agent, essential: true).status
    @agent.update!(provider_auth_modes: { "openai" => "api_key" })
    assert_equal "unavailable", gate.status
  end

  test "stale low remains braked until provider reset, not the cache expiry" do
    @reading.update!(checked_at: 2.hours.ago, observed_at: 2.hours.ago)
    assert_equal "braked_stale", gate.status
    @reading.update!(windows: [ window(30, reset: 1.second.ago) ])
    assert_equal "unavailable", gate.status
  end

  test "stale high and stale low without reset fail open" do
    @reading.update!(checked_at: 2.hours.ago, observed_at: 2.hours.ago, windows: [ window(70) ])
    assert_equal "unavailable", gate.status
    @reading.update!(windows: [ window(30, reset: nil) ])
    assert_equal "unavailable", gate.status
  end

  test "fresh low with unknown reset brakes but has conservative durable dedup" do
    @reading.update!(windows: [ window(20, reset: nil) ])
    assert_difference "AllowanceBrakeNotice.count", 1 do
      3.times { assert gate.braked? }
      @reading.update!(windows: [ window(10, reset: nil).merge("id" => "changed") ])
      assert gate.braked?
    end
    assert_equal "unknown-window", AllowanceBrakeNotice.last.window_key
  end

  test "notice dedup survives repeat checks and threshold flapping, and distinguishes resets" do
    assert_difference "AllowanceBrakeNotice.count", 1 do
      3.times { gate }
      @agent.update!(allowance_brake_threshold_percent: 20)
      gate
      @agent.update!(allowance_brake_threshold_percent: 40)
      gate
    end
    @reading.update!(windows: [ window(30, reset: 2.days.from_now) ])
    assert_difference("AllowanceBrakeNotice.count", 1) { gate }
  end

  test "a probe is outside its reading row lock; locked checks never call transport" do
    client = Object.new
    client.define_singleton_method(:usage) { |**| raise "network in check" }
    AgentProviderAuthClient.stub(:new, client) do
      @reading.with_lock { assert gate.braked? }
    end
    assert_equal "braked", @agent.allowance_brake_status[:status]
  end

  test "valid refresh replaces evidence; stale or invalid observations never overwrite good low" do
    [ nil, "bad", 1.hour.from_now.iso8601 ].each do |observed|
      refresh(snapshot.merge("observed_at" => observed))
      assert_equal 30, @reading.reload.windows.first["remaining_percent"]
    end
    refresh(snapshot.merge("observed_at" => 1.day.ago.iso8601))
    assert_equal 30, @reading.reload.windows.first["remaining_percent"]
    refresh(snapshot)
    assert_equal 80, @reading.reload.windows.first["remaining_percent"]
  end

  test "unknown status and model or provider mismatch cannot supply evidence" do
    [ { "status" => "unknown" }, { "status" => "unavailable" },
      { "provider" => "anthropic" }, { "model" => "another-model" } ].each do |change|
      refresh(snapshot.merge(change))
      assert_equal 30, @reading.reload.windows.first["remaining_percent"]
    end
  end

  test "null boolean strings nonfinite out-of-range percentages are not zero" do
    [ nil, true, false, "", "0", Float::NAN, Float::INFINITY, -1, 101 ].each do |value|
      refresh(snapshot.merge("windows" => [ window(value) ]))
      assert_equal 30, @reading.reload.windows.first["remaining_percent"]
    end
  end

  test "all applicable OpenAI windows are compared without duration inference" do
    refresh(snapshot.merge("windows" => [
      window(80).merge("id" => "a", "label" => "Allowance A"),
      window(10).merge("id" => "b", "label" => "Allowance B"),
      window(0).merge("id" => "spark", "label" => "codex-spark")
    ]))
    assert_equal 2, @reading.reload.windows.size
    assert_equal 10, gate.remaining_percent
    assert gate.braked?
  end

  test "a partly malformed refresh cannot erase a known low allowance" do
    [ nil, Float::NAN, 101 ].each do |invalid|
      refresh(snapshot.merge("windows" => [
        window(80).merge("id" => "other"),
        window(invalid)
      ]))
      assert_equal 30, @reading.reload.windows.first["remaining_percent"]
      assert gate.braked?
    end
    refresh(snapshot.merge("windows" => [ window(80), window(10).merge("resets_at" => "invalid") ]))
    assert_equal 30, @reading.reload.windows.first["remaining_percent"]
  end

  test "spark only considers spark windows" do
    @reading.update!(model: "codex-spark")
    refresh(snapshot.merge("model" => "codex-spark", "windows" => [
      window(0).merge("label" => "Ordinary allowance"),
      window(60).merge("label" => "codex-spark")
    ]))
    assert_equal [ 60 ], @reading.reload.windows.pluck("remaining_percent")
  end

  test "two exhausted applicable windows do not recover when only the first resets" do
    @reading.update!(windows: [ window(0, reset: 1.second.ago), window(10, reset: 1.day.from_now).merge("id" => "second") ])
    assert gate.braked?
    @reading.update!(checked_at: 1.hour.ago, observed_at: 1.hour.ago)
    assert_equal "braked_stale", gate.status
  end

  test "owner admin policy excludes ordinary members and foreign account users" do
    account = accounts(:team_account)
    assert Agents::AllowanceBrake.manageable_by?(account, account.owner)
    assert Agents::AllowanceBrake.manageable_by?(account, User.find(memberships(:team_admin).user_id))
    assert_not Agents::AllowanceBrake.manageable_by?(account, User.find(memberships(:team_member).user_id))
    assert_not Agents::AllowanceBrake.manageable_by?(account, users(:regular_user))
    assert_not Agents::AllowanceBrake.manageable_by?(account, nil)
  end

  test "threshold validation rejects invalid integers" do
    [ -1, 101, 1.5, "no" ].each do |value|
      @agent.allowance_brake_threshold_percent = value
      assert_not @agent.valid?
      assert @agent.errors[:allowance_brake_threshold_percent].present?
    end
  end

  private

  def gate
    Agents::AllowanceBrake.check(@agent, refresh: false)
  end

  def window(value, reset: 1.day.from_now)
    { "id" => "provider-window", "label" => "Allowance", "remaining_percent" => value,
      "blocking" => true, "resets_at" => reset&.iso8601 }
  end

  def snapshot
    { "provider" => @reading.provider, "model" => @reading.model, "status" => "available",
      "observed_at" => Time.current.iso8601(6), "windows" => [ window(80) ] }
  end

  def refresh(body)
    client = Object.new
    client.define_singleton_method(:usage) { |**| body }
    AgentProviderAuthClient.stub(:new, client) { Agents::AllowanceBrake.refresh!(@reading) }
  end

end
