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

end
