require "test_helper"

class StonesControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:confirmed_user)
    @chat = @user.personal_account.chats.create!(title: "Private conversation title", model_id: "openrouter/auto")
    @stone = Stone.publish!(chat: @chat, title: "Public comparison",
      html: "<!doctype html><html><head><title>Comparison</title></head><body><h1>Options</h1></body></html>",
      author: @user, public: true)
    @revision = @stone.latest_revision
  end

  test "anonymous viewer exposes the stone not its conversation or account" do
    get stone_url(@stone.public_token)
    assert_response :success
    assert_select "h1", "Public comparison"
    assert_select "iframe[sandbox=''][referrerpolicy='no-referrer']", count: 1
    assert_select "script", count: 0
    assert_not_includes response.body, @chat.title
    assert_not_includes response.body, @user.email_address
    @user.profile.update!(first_name: "Private", last_name: "Person")
    get stone_url(@stone.public_token)
    assert_not_includes response.body, @user.full_name
    assert_nil response.headers["Set-Cookie"]
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"]
  end

  test "raw content enforces an opaque origin and no scripts or networking" do
    get stone_revision_content_url(@stone.public_token, @revision.number)
    assert_response :success
    assert_equal @revision.html.download, response.body
    assert_equal StonesController::CONTENT_POLICY, response.headers["Content-Security-Policy"]
    assert_includes response.headers["Content-Security-Policy"], "sandbox;"
    assert_not_includes response.headers["Content-Security-Policy"], "allow-scripts"
    assert_not_includes response.headers["Content-Security-Policy"], "allow-same-origin"
    assert_equal "nosniff", response.headers["X-Content-Type-Options"]
    assert_equal "no-referrer", response.headers["Referrer-Policy"]
    assert_nil response.headers["Set-Cookie"]
  end

  test "logged in and anonymous content responses are identical" do
    get stone_revision_content_url(@stone.public_token, 1)
    anonymous = response.body
    sign_in @user
    get stone_revision_content_url(@stone.public_token, 1)
    assert_response :success
    assert_equal anonymous, response.body
    assert_nil response.headers["Set-Cookie"]
  end

  test "revision URL stays pinned and shows newer revision" do
    @stone.revise!(title: "Revised comparison", html: "<!doctype html><h1>New options</h1>",
      author: @user, public: true, base_revision_id: @revision.to_param)
    get stone_revision_url(@stone.public_token, 1)
    assert_select "h1", "Public comparison"
    assert_select "a", text: "Newer revision available (2)"
    get stone_url(@stone.public_token)
    assert_select "h1", "Revised comparison"
  end

  test "generic blob delivery cannot bypass the sandbox" do
    get rails_blob_url(@revision.html)
    assert_response :not_found
    get rails_storage_proxy_url(@revision.html)
    assert_response :not_found
  end

  test "even an internally minted Disk service URL cannot bypass stone delivery" do
    service_url = ActiveStorage::Current.set(url_options: { host: "www.example.com", protocol: "http" }) do
      @revision.html.blob.url
    end
    get service_url
    assert_response :not_found
    @stone.withdraw!
    get service_url
    assert_response :not_found
  end

  test "withdrawal hides both viewer and raw content before purge" do
    generic_url = rails_blob_url(@revision.html)
    @stone.withdraw!
    get stone_url(@stone.public_token)
    assert_response :not_found
    get stone_revision_content_url(@stone.public_token, 1)
    assert_response :not_found
    get generic_url
    assert_response :not_found
  end

  test "discarded conversations hide all their public stones" do
    @chat.discard!
    get stone_url(@stone.public_token)
    assert_response :not_found
    get stone_revision_content_url(@stone.public_token, 1)
    assert_response :not_found
  end

  test "private hashid is not the public URL" do
    get stone_url(@stone.to_param)
    assert_response :not_found
  end

end
