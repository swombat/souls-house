require "test_helper"

class LivePartialEvaluationTest < ActionDispatch::IntegrationTest

  setup do
    @account = accounts(:personal_account)
    Setting.instance.update!(allow_agents: true)
    sign_in users(:site_admin_user)
    # Rhythm declares timezone validation at load time; the negative presenter
    # stub below must not intercept that unrelated one-time model load.
    Rhythm.column_names
  end

  test "Field listing and tweet partials do not rerun the active search" do
    FieldSearch.stub :new, ->(*) { flunk "unrequested full-text search" } do
      %w[items tweet_stream].each do |prop|
        get account_field_path(@account, q: "meeting"),
          headers: partial("field/index", prop)
        assert_response :success
        assert_not response.parsed_body.fetch("props").key?("search")
      end
    end
  end

  test "audit entry partial skips whole-table filter options" do
    controller = Admin::AuditLogsController.new
    Admin::AuditLogsController.stub :new, controller do
      controller.stub :filter_options, -> { flunk "unrequested filter options" } do
        get admin_audit_logs_path, headers: partial("admin/audit-logs", "audit_logs,pagination")
        assert_response :success
        assert_not response.parsed_body.fetch("props").key?("filters")
      end
    end
  end

  test "settings marker skips operational scans and status presenters" do
    controller = Admin::SettingsController.new
    Admin::SettingsController.stub :new, controller do
      controller.stub :follow_through_residents, -> { flunk "resident scan" } do
        controller.stub :stalled_sweep_accounts, -> { flunk "account scan" } do
          Agents::VmBirthPolicy.stub :current, -> { flunk "VM status" } do
            FieldOcr.stub :status_json, -> { flunk "OCR status" } do
              FieldTweets.stub :status_json, -> { flunk "tweet status" } do
                get admin_settings_path, headers: partial("admin/settings", "setting")
                assert_response :success
                assert response.parsed_body.fetch("props").key?("setting")
                assert_not response.parsed_body.fetch("props").key?("field_tweets")
              end
            end
          end
        end
      end
    end
  end

  test "requested settings status still evaluates and returns" do
    FieldOcr.stub :status_json, { synthetic: true } do
      get admin_settings_path, headers: partial("admin/settings", "field_ocr")
      assert_response :success
      assert_equal true, response.parsed_body.dig("props", "field_ocr", "synthetic")
    end
  end

  test "unrequested shared accounts are not materialized" do
    user = users(:site_admin_user)
    Current.stub :user, user do
      user.stub :confirmed_accounts, -> { flunk "unrequested shared account list" } do
        get admin_settings_path, headers: partial("admin/settings", "setting")
        assert_response :success
        assert_not response.parsed_body.fetch("props").key?("accounts")
      end
    end
    get admin_settings_path, headers: partial("admin/settings", "accounts")
    assert_response :success
    assert_kind_of Array, response.parsed_body.dig("props", "accounts")
  end

  test "rhythm-only partial skips resident choices and timezones" do
    controller = RhythmsController.new
    RhythmsController.stub :new, controller do
      controller.stub :resident_options, -> { flunk "unrequested resident choices" } do
        ActiveSupport::TimeZone.stub :all, -> { flunk "unrequested timezone choices" } do
          get account_rhythms_path(@account), headers: partial("rhythms/index", "rhythms")
          assert_response :success
          assert_not response.parsed_body.fetch("props").key?("residents")
          assert_not response.parsed_body.fetch("props").key?("timezones")
        end
      end
    end
  end

  private

  def partial(component, props)
    {
      "X-Inertia" => "true", "X-Inertia-Version" => ViteRuby.digest,
      "X-Inertia-Partial-Component" => component, "X-Inertia-Partial-Data" => props
    }
  end

end
