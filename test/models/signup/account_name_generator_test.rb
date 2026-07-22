require "test_helper"

class Signup::AccountNameGeneratorTest < ActiveSupport::TestCase
  test "recognizes st nd and rd ordinals after twenty" do
    {
      "21st" => "22nd",
      "22nd" => "23rd",
      "23rd" => "24th"
    }.each_with_index do |(existing_ordinal, next_ordinal), index|
      identity = Identity.create!(email_address: "ordinal-#{index}@example.com")
      add_account(identity:, name: "Avery's #{existing_ordinal} PaymentReminder")

      generated_name = Signup::AccountNameGenerator.new(identity:, name: "Avery Person").generate

      assert_equal "Avery's #{next_ordinal} PaymentReminder", generated_name
    end
  end

  test "does not count an account name with trailing text" do
    identity = Identity.create!(email_address: "trailing-name@example.com")
    add_account(identity:, name: "Avery's 23rd PaymentReminder archived")

    generated_name = Signup::AccountNameGenerator.new(identity:, name: "Avery Person").generate

    assert_equal "Avery's PaymentReminder", generated_name
  end

  private
    def add_account(identity:, name:)
      Account.create!(name:).users.create!(identity:, name: "Avery", role: :owner)
    end
end
