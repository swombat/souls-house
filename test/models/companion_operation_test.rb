require "test_helper"

class CompanionOperationTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    grant = CompanionEnrollmentGrant.create!(account: @agent.account, minting_agent: @agent,
      created_by_user: users(:user_1), name: "Fixture", device_request_id: "fixture",
      policy: { "residents" => [ { "id" => @agent.obfuscated_id,
        "volumes" => [ { "volume" => "fixture-volume", "access" => "read" } ], "execute" => false } ] },
      expires_at: 1.hour.from_now)
    @device, @credential = CompanionEnrollmentGrant.enroll!(grant.issue_token!(@agent), "fixture")
    @device.update!(connection_epoch: "fixture-epoch")
  end

  def start_read
    CompanionOperation.start!(device: @device, agent: @agent, kind: "read",
      arguments: { "volume" => "fixture-volume", "path" => "fixture.txt", "limit" => 16 })
  end

  def allow_mutations(execute: false, source_write: false)
    request_id = SecureRandom.hex(12)
    grant = CompanionEnrollmentGrant.create!(account: @agent.account, minting_agent: @agent,
      created_by_user: users(:user_1), name: "Mutation fixture", device_request_id: request_id,
      policy: { "residents" => [ { "id" => @agent.obfuscated_id, "execute" => execute,
        "volumes" => [ { "volume" => "fixture-volume", "access" => source_write ? "write" : "read" },
          { "volume" => "destination", "access" => "write" } ] } ] },
      expires_at: 1.hour.from_now)
    @device, @credential = CompanionEnrollmentGrant.enroll!(grant.issue_token!(@agent), request_id)
    @device.update!(connection_epoch: "fixture-epoch")
  end

  test "copy needs source read but move needs source write too" do
    allow_mutations
    arguments = { "source_volume" => "fixture-volume", "source_path" => "source",
      "volume" => "destination", "path" => "target" }
    assert CompanionOperation.start!(device: @device, agent: @agent, kind: "copy", arguments: arguments)
    assert_raises(CompanionOperation::Refused) do
      CompanionOperation.start!(device: @device, agent: @agent, kind: "move", arguments: arguments)
    end
    allow_mutations(source_write: true)
    assert CompanionOperation.start!(device: @device, agent: @agent, kind: "move", arguments: arguments)
  end

  test "input waits before dispatch and is bound to epoch revision and current grants" do
    allow_mutations
    operation = CompanionOperation.start!(device: @device, agent: @agent, kind: "write",
      arguments: { "volume" => "destination", "path" => "fixture", "input_size" => 7 })
    assert_not operation.dispatch!
    assert_raises(CompanionOperation::Refused) { operation.attach_input!("wrong-size") }
    operation.attach_input!("PRIVATE")
    assert_not_includes operation.attributes.to_json, "PRIVATE"
    assert_raises(CompanionOperation::Refused) { operation.attach_input!("PRIVATE") }
    assert operation.dispatch!
    assert_nil operation.take_input!(epoch: "other", revision: 1)
    assert_nil operation.take_input!(epoch: "fixture-epoch", revision: 2)
    @device.update!(paused: true)
    assert_nil operation.take_input!(epoch: "fixture-epoch", revision: 1)
    @device.update!(paused: false)
    assert_equal "PRIVATE", operation.take_input!(epoch: "fixture-epoch", revision: 1)
    assert_nil operation.reload.take_input!(epoch: "fixture-epoch", revision: 1)
  end

  test "execute requires explicit computer grant and keeps argv only in temporary input" do
    allow_mutations
    args = { "input_size" => 34, "timeout_seconds" => 300 }
    assert_raises(CompanionOperation::Refused) do
      CompanionOperation.start!(device: @device, agent: @agent, kind: "execute", arguments: args)
    end
    allow_mutations(execute: true)
    operation = CompanionOperation.start!(device: @device, agent: @agent, kind: "execute", arguments: args)
    assert_in_delta 300, operation.deadline - Time.current, 1
    assert_raises(CompanionOperation::Refused) do
      CompanionOperation.start!(device: @device, agent: @agent, kind: "execute",
        arguments: args.merge("argv" => [ "secret argument" ]))
    end
    assert_raises(CompanionOperation::Refused) do
      CompanionOperation.start!(device: @device, agent: @agent, kind: "execute",
        arguments: args.merge("timeout_seconds" => 301))
    end
  end

  test "persists before dispatch then stores content separately and consumes once" do
    operation = start_read
    assert_equal "pending", operation.state
    assert operation.dispatch!
    assert_equal "dispatched", operation.reload.state
    assert operation.complete!(epoch: "fixture-epoch", revision: 1,
      data: "private fixture", content_type: "application/octet-stream")
    assert_equal "completed", operation.reload.state
    assert_not_includes operation.attributes.to_json, "private fixture"
    assert_equal [ "private fixture", "application/octet-stream" ], operation.take_body!
    assert_nil operation.take_body!
    assert_equal "completed", operation.reload.state
  end

  test "read grants do not grant writes exec other resident or other volume" do
    %w[write exec move].each do |kind|
      assert_raises(CompanionOperation::Refused) do
        CompanionOperation.start!(device: @device, agent: @agent, kind: kind, arguments: {})
      end
    end
    assert_raises(CompanionOperation::Refused) do
      CompanionOperation.start!(device: @device, agent: agents(:code_reviewer), kind: "drives", arguments: {})
    end
    assert_raises(CompanionOperation::Refused) do
      CompanionOperation.start!(device: @device, agent: @agent, kind: "read", arguments: { "volume" => "other" })
    end
  end

  test "bounded concurrency and deadline free a slot without replay" do
    operations = 4.times.map { start_read }
    assert_raises(CompanionOperation::Refused) { start_read }
    operations.first.update!(deadline: 1.second.ago)
    assert start_read
    assert_equal "timed_out", operations.first.reload.state
    assert_not operations.first.dispatch!
  end

  test "late old epoch revoked paused and changed revision results are suppressed" do
    [ { connection_epoch: "new" }, { revoked_at: Time.current }, { paused: true }, { grant_revision: 2 } ].each do |change|
      @device.update!(connection_epoch: "fixture-epoch", revoked_at: nil, paused: false, grant_revision: 1)
      operation = start_read
      operation.dispatch!
      @device.update!(change)
      assert_not operation.complete!(epoch: "fixture-epoch", revision: 1, data: "not deliverable")
      assert_equal "cancelled", operation.reload.state
      assert_nil operation.body
    end
  end

  test "completed content is withheld on revocation or expiration" do
    operation = start_read
    operation.dispatch!
    operation.complete!(epoch: "fixture-epoch", revision: 1, data: "fixture")
    @device.update!(revoked_at: Time.current)
    assert_nil operation.take_body!
    assert_nil operation.reload.body
  end

  test "body expires independently from retained audit" do
    operation = start_read
    operation.dispatch!
    operation.complete!(epoch: "fixture-epoch", revision: 1, data: "fixture")
    id = operation.body.id
    travel 11.minutes
    CompanionBodyExpiryJob.perform_now(id)
    assert_nil operation.reload.body
    assert_equal "completed", operation.state
  end

  test "desktop is its own grant: execute and volumes never imply it, and it never implies them" do
    snapshot = { "command" => "snapshot", "app" => "Finder", "interactive" => true }
    assert_raises(CompanionOperation::Refused) do
      CompanionOperation.start!(device: @device, agent: @agent, kind: "desktop", arguments: snapshot)
    end
    allow_mutations(execute: true, source_write: true)
    assert_raises(CompanionOperation::Refused) do
      CompanionOperation.start!(device: @device, agent: @agent, kind: "desktop", arguments: snapshot)
    end
    @device.change_resident_authority!(resident_id: @agent.obfuscated_id, execute: false, desktop: true, actor: users(:user_1))
    operation = CompanionOperation.start!(device: @device, agent: @agent, kind: "desktop", arguments: snapshot)
    assert_equal "desktop", operation.envelope[:operation]
    assert_equal true, operation.envelope[:policy]["residents"].first["desktop"]
    assert operation.input_required?
    assert_raises(CompanionOperation::Refused) do
      CompanionOperation.start!(device: @device, agent: @agent, kind: "execute", arguments: { "input_size" => 2 })
    end
  end

  test "desktop arguments keep the outer shape and bounds" do
    allow_mutations
    @device.change_resident_authority!(resident_id: @agent.obfuscated_id, execute: false, desktop: true, actor: users(:user_1))
    start = ->(arguments) { CompanionOperation.start!(device: @device, agent: @agent, kind: "desktop", arguments: arguments) }
    assert start.call({ "command" => "batch", "timeout_seconds" => 120,
      "steps" => [ { "command" => "snapshot", "app" => "Finder" }, { "command" => "click", "app" => "Finder", "ref" => "@a:e1" } ] })
    [
      { "command" => "snapshot", "app" => "Finder", "headed" => true },
      { "command" => "snapshot", "app" => "Finder", "timeout_seconds" => 121 },
      { "command" => "batch", "steps" => [] },
      { "command" => "batch", "steps" => [ { "command" => "batch", "steps" => [] } ] },
      { "command" => "batch", "steps" => Array.new(17) { { "command" => "snapshot", "app" => "Finder" } } },
      { "app" => "Finder" },
      { "command" => "launch", "app" => "Terminal" },
      { "command" => "snapshot", "app" => { "x" => 1 } },
      { "command" => "snapshot", "app" => "Finder", "input_size" => 3 },
      { "command" => "batch", "steps" => [ { "command" => "click", "app" => [ "Finder" ], "ref" => "@a:e1" } ] }
    ].each do |arguments|
      assert_raises(CompanionOperation::Refused, arguments.inspect) { start.call(arguments) }
    end
  end

  test "owner changes execute and desktop after enrollment; revision bump cancels in-flight work" do
    allow_mutations
    operation = start_read
    revision = @device.grant_revision
    assert @device.change_resident_authority!(resident_id: @agent.obfuscated_id, execute: false, desktop: true, actor: users(:user_1))
    assert_equal revision + 1, @device.reload.grant_revision
    assert_equal "cancelled", operation.reload.state
    assert_equal [ { "volume" => "fixture-volume", "access" => "read" }, { "volume" => "destination", "access" => "write" } ],
      @device.policy["residents"].first["volumes"]
    assert_not @device.change_resident_authority!(resident_id: @agent.obfuscated_id, execute: false, desktop: true, actor: users(:user_1))
    assert_equal revision + 1, @device.reload.grant_revision
    log = AuditLog.where(action: "companion.device.authority_changed").last
    assert_equal({ "execute" => false, "desktop" => true }, log.data["after"])
    @device.change_resident_authority!(resident_id: @agent.obfuscated_id, execute: false, desktop: false, actor: users(:user_1))
    assert_not @device.reload.policy["residents"].first.key?("desktop")
    assert_raises(ArgumentError) do
      @device.change_resident_authority!(resident_id: "Nobody", execute: true, desktop: true, actor: users(:user_1))
    end
  end

  test "desktop payload is private and short-lived; the durable row keeps verbs and apps only" do
    allow_mutations
    @device.change_resident_authority!(resident_id: @agent.obfuscated_id, execute: false, desktop: true, actor: users(:user_1))
    @device.update!(connection_epoch: "fixture-epoch")
    payload = { "command" => "batch", "steps" => [
      { "command" => "click", "app" => "Finder", "ref" => "@abc:e1" },
      { "command" => "type", "app" => "Finder", "ref" => "@abc:e2", "text" => "secret words" } ] }
    operation = CompanionOperation.start!(device: @device, agent: @agent, kind: "desktop", arguments: payload)
    assert_equal({ "command" => "batch", "steps" => [ { "command" => "click", "app" => "Finder" },
      { "command" => "type", "app" => "Finder" } ], "input_size" => JSON.generate(payload).bytesize }, operation.reload.arguments)
    assert_not_includes operation.arguments.to_json, "secret"
    assert operation.input.expires_at <= operation.deadline

    assert operation.input_required?
    assert_equal JSON.generate(payload).bytesize, operation.arguments["input_size"]
    sent = nil
    CompanionChannel.stub(:broadcast_to, ->(_device, message) { sent = message }) { assert operation.dispatch! }
    assert_not_includes sent.to_json, "secret"
    assert_not_includes sent.to_json, "@abc"
    assert_equal true, sent[:input_required]
    assert_equal payload, JSON.parse(operation.take_input!(epoch: "fixture-epoch", revision: @device.reload.grant_revision))
    assert_nil operation.take_input!(epoch: "fixture-epoch", revision: @device.grant_revision)
    assert_raises(CompanionOperation::Refused) { operation.attach_input!("{}") }

    missing = CompanionOperation.start!(device: @device, agent: @agent, kind: "desktop", arguments: payload)
    missing.input.destroy!
    assert_not missing.reload.dispatch!

    cancelled = CompanionOperation.start!(device: @device, agent: @agent, kind: "desktop", arguments: payload)
    @device.change_resident_authority!(resident_id: @agent.obfuscated_id, execute: false, desktop: false, actor: users(:user_1))
    assert_equal "cancelled", cancelled.reload.state
    assert_nil CompanionOperationInput.find_by(companion_operation_id: cancelled.id)

    @device.change_resident_authority!(resident_id: @agent.obfuscated_id, execute: false, desktop: true, actor: users(:user_1))
    expired = CompanionOperation.start!(device: @device, agent: @agent, kind: "desktop", arguments: payload)
    travel 11.minutes do
      CompanionSweepJob.perform_now
      assert_nil CompanionOperationInput.find_by(companion_operation_id: expired.id)
      assert_not expired.reload.dispatch!
    end
  end

end
