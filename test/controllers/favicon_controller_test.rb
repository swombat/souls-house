require "test_helper"

class FaviconControllerTest < ActionController::TestCase

  tests FaviconController

  test "should get favicon as png" do
    get :show, params: { format: "png" }

    assert_response :success
    assert_match(/image\/(png|svg\+xml)/, response.headers["Content-Type"])
  end

  test "should get favicon as ico" do
    get :show, params: { format: "ico" }

    assert_response :success
    assert_match(/image\/(vnd.microsoft.icon|x-icon|png|svg\+xml)/, response.headers["Content-Type"])
  end

  test "should get favicon as svg" do
    get :show, params: { format: "svg" }

    assert_response :success
    assert_equal "image/svg+xml", response.media_type
    assert_equal Rails.root.join("public/favicon.svg").read, response.body
    refute_includes response.body, "Helix"
    refute_includes response.body, "KIT"
  end

  test "should get apple touch icon" do
    get :apple_touch_icon

    assert_response :success
    assert_match(/image\/(png|svg\+xml)/, response.headers["Content-Type"])
  end

  test "should return 404 for unsupported format" do
    get :show, params: { format: "webp" }

    assert_response :not_found
  end

end
