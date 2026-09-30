require "test_helper"

class Admin::ResidentTurnsControllerTest < ActionDispatch::IntegrationTest

  test "administration requires a site administrator" do
    get admin_resident_turns_path
    assert_redirected_to login_path
    sign_in(users(:regular_user))
    patch "/admin/resident_turns/capacity", params: { limit: 100 }
    assert_redirected_to root_path
    get admin_resident_turns_path
    assert_redirected_to root_path
  end

  test "administrator can pause and change capacity but not set an invalid limit" do
    sign_in(users(:site_admin_user))
    patch "/admin/resident_turns/capacity", params: { limit: 0 }
    assert_redirected_to admin_resident_turns_path
    assert_equal 0, ResidentTurn.capacity
    patch "/admin/resident_turns/capacity", params: { limit: -1 }
    assert_equal 0, ResidentTurn.capacity
    patch "/admin/resident_turns/capacity", params: { limit: 100 }
    assert_equal 100, ResidentTurn.capacity
  end

  test "admin list contains no request payload or credential material" do
    sign_in(users(:site_admin_user))
    get admin_resident_turns_path
    assert_response :success
    assert_not_includes response.body, "activity_token_digest"
  end

end
