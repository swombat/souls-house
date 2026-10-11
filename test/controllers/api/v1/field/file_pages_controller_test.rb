require "test_helper"

class Api::V1::Field::FilePagesControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @resident = agents(:research_assistant)
    @account = @resident.account
    @headers = headers_for(@resident)
    @pdf = @account.field_files.create!(file: pdf_upload("mixed.pdf"), uploaded_by: @user)
    @pdf.extract_pdf!
  end

  test "the file says how much of the PDF was read, without page bodies" do
    get api_v1_field_files_path, headers: @headers
    listed = response.parsed_body["files"].find { it["id"] == @pdf.to_param }
    extraction = listed["text_extraction"]
    assert_equal "extracted", extraction["status"]
    assert_equal 4, extraction["page_count"]
    assert_equal 2, extraction["pages_with_text"]
    assert_equal 2, extraction["pages_without_text"]
    assert_equal "native", extraction["text_source"]
    assert_equal api_v1_field_file_pages_path(@pdf), listed["pages_path"]
    assert_not_includes response.body, "apricots"
  end

  test "page list carries states; one page carries its text and source" do
    get api_v1_field_file_pages_path(@pdf), headers: @headers
    assert_response :success
    pages = response.parsed_body["pages"]
    assert_equal [ 1, 2, 3, 4 ], pages.map { it["number"] }
    assert_equal %w[text text empty empty], pages.map { it["status"] }
    assert_equal [ "native", "native", nil, nil ], pages.map { it["source"] }
    assert pages.none? { it.key?("text") }

    get api_v1_field_file_page_path(@pdf, 1), headers: @headers
    assert_response :success
    page = response.parsed_body["page"]
    assert_equal "Orchard ledger, page one: apricots and quinces.", page["text"]
    assert_equal "native", page["source"]

    get api_v1_field_file_page_path(@pdf, 3), headers: @headers
    assert_nil response.parsed_body.dig("page", "text")
    assert_equal "empty", response.parsed_body.dig("page", "status")
  end

  test "missing pages, non-PDFs and other accounts' files are not found" do
    get api_v1_field_file_page_path(@pdf, 9), headers: @headers
    assert_response :not_found
    get api_v1_field_file_page_path(@pdf, "one"), headers: @headers
    assert_response :not_found

    text = @account.field_files.create!(file: Rack::Test::UploadedFile.new(file_fixture("test.txt"), "text/plain"))
    get api_v1_field_file_pages_path(text), headers: @headers
    assert_response :not_found

    theirs = accounts(:another_team).field_files.create!(file: pdf_upload("text_only.pdf"))
    theirs.extract_pdf!
    get api_v1_field_file_pages_path(theirs), headers: @headers
    assert_response :not_found
    get api_v1_field_file_page_path(theirs, 1), headers: @headers
    assert_response :not_found
  end

  test "discarded files' pages are gone" do
    @pdf.discard!
    get api_v1_field_file_page_path(@pdf, 1), headers: @headers
    assert_response :not_found
  end

  test "pages past the reading limit exist, unread; pages past the end don't" do
    @pdf.update_columns(pdf_page_count: 10, pdf_status: "partial",
      pdf_coverage: @pdf.pdf_coverage.merge("skipped" => 6))

    get api_v1_field_file_pages_path(@pdf), headers: @headers
    assert_equal 4, response.parsed_body["pages"].size
    assert_equal 4, response.parsed_body.dig("text_extraction", "pages_listed")

    get api_v1_field_file_page_path(@pdf, 7), headers: @headers
    assert_response :success
    page = response.parsed_body["page"]
    assert_equal "skipped", page["status"]
    assert_nil page["text"]
    assert_match(/Only the first/, page["reason"])

    get api_v1_field_file_page_path(@pdf, 11), headers: @headers
    assert_response :not_found
  end

  test "a summary of part of a PDF says so" do
    @pdf.update_columns(summary_short: "Orchard ledger", summary_long: "An orchard ledger.")
    get api_v1_field_file_path(@pdf), headers: @headers
    assert response.parsed_body.dig("file", "summary_partial")
    assert_equal false, response.parsed_body.dig("file", "text_extraction", "complete")
  end

  test "requires a token" do
    get api_v1_field_file_pages_path(@pdf)
    assert_response :unauthorized
  end

  private

  def pdf_upload(name)
    Rack::Test::UploadedFile.new(Rails.root.join("test/fixtures/files/field_pdfs", name), "application/pdf")
  end

  def headers_for(agent)
    key = ApiKey.generate_for(@user, name: "Field tests", agent: agent)
    { "Authorization" => "Bearer #{key.raw_token}" }
  end

end
