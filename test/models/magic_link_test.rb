require "test_helper"

class MagicLinkTest < ActiveSupport::TestCase
  test "generates a six character code and expiration" do
    magic_link = Identity.create!(email_address: "person@example.com").magic_links.create!

    assert_equal 6, magic_link.code.length
    assert_in_delta 15.minutes.from_now, magic_link.expires_at, 2.seconds
  end

  test "consume finds active sanitized code and destroys it" do
    magic_link = Identity.create!(email_address: "person@example.com").magic_links.create!(code: "G79NYX")
    sql_queries = []

    consumed_link = ActiveSupport::Notifications.subscribed(
      ->(*args) { sql_queries << args.last[:sql] },
      "sql.active_record"
    ) do
      MagicLink.consume(" g79-nyx ")
    end

    assert_equal magic_link, consumed_link
    assert_not MagicLink.exists?(magic_link.id)
    assert_nil MagicLink.consume(magic_link.code)
    assert sql_queries.any? { |sql| sql.match?(/\bFOR UPDATE\b/i) }, "expected consumption to lock the magic-link row"
  end

  test "consume ignores expired codes" do
    magic_link = Identity.create!(email_address: "person@example.com").magic_links.create!(expires_at: 1.minute.ago)

    assert_nil MagicLink.consume(magic_link.code)
  end

  test "consume raises and preserves the link when destruction is prevented" do
    magic_link = Identity.create!(email_address: "protected@example.com").magic_links.create!
    abort_destruction = -> { throw(:abort) }
    MagicLink.set_callback(:destroy, :before, abort_destruction)

    assert_raises ActiveRecord::RecordNotDestroyed do
      MagicLink.consume(magic_link.code)
    end
    assert MagicLink.exists?(magic_link.id)
  ensure
    MagicLink.skip_callback(:destroy, :before, abort_destruction) if abort_destruction
  end
end
