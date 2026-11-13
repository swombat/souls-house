require "test_helper"

class Admin::HetznerAvailabilitiesControllerTest < ActionDispatch::IntegrationTest

  test "renders with no checks yet" do
    sign_in users(:site_admin_user)
    get admin_hetzner_availability_path

    assert_response :success
    assert_equal "admin/hetzner-availability", inertia_component
    props = inertia_props["props"]
    assert_equal [], props["checks"]
    assert_equal 4, props["series"].size
    assert props["series"].all? { |line| line["points"].empty? }
  end

  test "renders the last checks and the pair series" do
    at = 10.minutes.ago.change(usec: 0)
    HetznerAvailabilitySample.record!({ "cx23" => { "fsn1" => false, "nbg1" => true } }, at:)
    HetznerAvailabilitySample.record_failure!("unavailable", at: at + 5.minutes)

    sign_in users(:site_admin_user)
    get admin_hetzner_availability_path

    props = inertia_props["props"]
    assert_equal 2, props["checks"].size
    assert_equal [ "nbg1" ], props["checks"].last["types"]["cx23"]["available"]
    assert_equal "unavailable", props["checks"].first["types"]["cx23"]["error"]
    assert_equal [ [ at.iso8601, 1 ], [ (at + 5.minutes).iso8601, nil ] ], props["series"].first["points"]
  end

  test "people who are not site admins are sent away" do
    sign_in users(:regular_user)
    get admin_hetzner_availability_path
    assert_redirected_to root_path
  end

end
