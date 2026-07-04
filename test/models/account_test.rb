require "test_helper"

class AccountTest < ActiveSupport::TestCase
  test "has many users" do
    assert_includes accounts(:paid_jar).users, users(:arjun)
  end

  test "requires a name" do
    account = Account.new

    assert_not account.valid?
    assert_includes account.errors[:name], "can't be blank"
  end

  test "orders by name" do
    zed = Account.create!(name: "zed studio")
    alpha = Account.create!(name: "Alpha Books")

    assert_equal [ "Alpha Books", "zed studio" ], Account.where(id: [ alpha.id, zed.id ]).ordered.pluck(:name)
  end

  test "filters by name" do
    assert_equal [ accounts(:paid_jar) ], Account.filtered_by("paid").to_a
  end

  test "returns initials" do
    assert_equal "P", accounts(:paid_jar).initials
  end
end
