require "test_helper"

class DirectReplyMentionsTest < ActiveSupport::TestCase

  Human = Struct.new(:id, :first_name, :full_name)
  Resident = Struct.new(:id, :name)
  Room = Struct.new(:agents)
  Post = Struct.new(:content, :user_id, :chat)

  setup do
    @daniel = Human.new(1, "Daniel", "Daniel Smith")
    @jane = Human.new(2, "Jane", "Jane Doe")
    @users = [ @daniel, @jane ]
    @residents = [ Resident.new(1, "Mira") ]
  end

  test "first and full names are case insensitive and return distinct IDs in mention order" do
    assert_equal [ 2, 1 ], match("@JANE DOE, @daniel! @Daniel Smith @Jane")
  end

  test "a direct tag needs no question or inference" do
    UtilityInference.stub :structured, ->(**) { flunk "No inference" } do
      UtilityInference.stub :decide, ->(**) { flunk "No inference" } do
        assert_equal [ 1 ], match("@Daniel, here is the file.")
        assert_empty match("Daniel, can you check this?")
      end
    end
  end

  test "only supplied eligible humans match and email is never an alias" do
    assert_empty match("@Jane @missing@example.com", users: [ @daniel ])
    nameless = Human.new(3, nil, nil)
    assert_empty match("@test @test@example.com", users: [ nameless ])
    assert_equal [ 1 ], match("@Daniel", users: [ @daniel, @daniel ])
    assert_empty match(nil)
    assert_empty match("@Daniel", users: [])
  end

  test "human and resident authors can tag humans but human authors cannot tag themselves" do
    assert_equal [ 1, 2 ], match("@Daniel @Jane")
    assert_equal [ 2 ], match("@Daniel @Jane", author: 1)
    assert_empty match("@Mira")
  end

  test "self exclusion happens after shared alias ambiguity" do
    other = Human.new(3, "Daniel", "Daniel Jones")
    assert_empty match("@Daniel", users: [ @daniel, other ], author: 1)
    assert_equal [ 3 ], match("@Daniel Jones", users: [ @daniel, other ], author: 1)
    assert_equal [ 1 ], match("@Daniel Smith", users: [ @daniel, other ])
  end

  test "identical full names are ambiguous even if one belongs to the author" do
    twin = Human.new(3, "Daniel", "Daniel Smith")
    assert_empty match("@Daniel Smith", users: [ @daniel, twin ], author: 1)
  end

  test "resident full and first names block human aliases" do
    @residents << Resident.new(2, "Daniel Jones")
    assert_empty match("@Daniel")
    assert_equal [ 1 ], match("@Daniel Smith")
    @residents << Resident.new(3, "Daniel Smith")
    assert_empty match("@Daniel Smith")
  end

  test "longest full name wins over shorter full and first names" do
    shorter = Human.new(3, "Daniel", "Daniel Smith Jones")
    assert_equal [ 3 ], match("@Daniel Smith Jones", users: [ @daniel, shorter ])
    @residents << Resident.new(2, "Daniel Smith Jones")
    assert_empty match("@Daniel Smith Jones", users: [ @daniel, shorter ])
  end

  test "Unicode aliases use canonical normalization and case folding" do
    jose = Human.new(3, "José", "José Núñez")
    street = Human.new(4, "Straße", "Straße Müller")
    assert_equal [ 3, 4 ], match("@JOSE\u0301 NU\u0301ÑEZ @STRASSE", users: [ jose, street ])
    assert_empty match("@JoséOther @José\u0301x", users: [ jose ])
  end

  test "name boundaries reject longer handles and email substrings" do
    %w[@DanielOther @Daniel_foo @Daniel2 @Daniel-Smithson @Daniel.Smithson
       x@Daniel x.y@Daniel @@Daniel @Daniel@example.com].each do |content|
      assert_empty match(content), content
    end
    assert_equal [ 1 ], match("(@Daniel), @Daniel. @Daniel! @Daniel?")
    assert_empty match("@Daniel SmithOther", users: [ Human.new(3, nil, "Daniel Smith") ])
  end

  test "blockquotes nested quotes code fences and indented code are excluded" do
    [
      "> @Daniel\n>\n> @Jane",
      "> outer\n>> @Daniel",
      "```ruby\n@Daniel\n@Jane\n```",
      "~~~\n@Daniel\n~~~",
      "    @Daniel\n    @Jane",
      "`@Daniel` and ``@Jane``"
    ].each { |content| assert_empty match(content), content }
    assert_equal [ 2 ], match("> @Daniel\n\n@Jane")
    assert_equal [ 2 ], match("`@Daniel` @Jane")
  end

  test "links images autolinks and bare URLs are excluded including labels" do
    [
      "[@Daniel](https://example.com)",
      "[label](https://example.com/@Daniel)",
      "![alt @Daniel](https://example.com/image.png)",
      "<https://example.com/@Daniel>",
      "https://example.com/@Daniel",
      "www.example.com/@Daniel",
      "[@Daniel](javascript:alert)",
      "[@Daniel][ref]\n\n[ref]: https://example.com",
      "<person@Daniel>"
    ].each { |content| assert_empty match(content), content }
    assert_equal [ 2 ], match("[@Daniel](https://example.com) @Jane")
  end

  test "escaped tags do not match but escaped backslashes permit tags" do
    assert_empty match('\@Daniel \\@Jane')
    assert_empty match('\\\\\@Daniel')
    assert_equal [ 1 ], match('\\\\@Daniel')
    assert_equal [ 2 ], match('\@Daniel @Jane')
  end

  test "ordinary emphasis can contain tags without concatenating excluded code" do
    assert_equal [ 1 ], match("**@Daniel Smith**")
    assert_equal [ 1 ], match("@Daniel **Smith**")
    assert_empty match("@`ignored`Daniel")
  end

  test "plain prose quotation marks are not Markdown blockquotes" do
    assert_equal [ 1 ], match('He wrote "@Daniel" in the message.')
  end

  private

  def match(content, users: @users, author: nil)
    message = Post.new(content, author, Room.new(@residents))
    DirectReplyMentions.call(message: message, users: users)
  end

end
