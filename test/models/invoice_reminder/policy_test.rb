require "test_helper"

class InvoiceReminder::PolicyTest < ActiveSupport::TestCase
  test "defines the good debtor schedule" do
    assert_equal(
      [
        [ "pre_due_3", :pre_due, 3, :friendly ],
        [ "overdue_3", :overdue, 3, :neutral ],
        [ "overdue_10", :overdue, 10, :final ]
      ],
      schedule_for(:good_debtor)
    )
  end

  test "defines the normal debtor schedule" do
    assert_equal(
      [
        [ "pre_due_7", :pre_due, 7, :friendly ],
        [ "pre_due_1", :pre_due, 1, :direct ],
        [ "overdue_3", :overdue, 3, :direct ],
        [ "overdue_7", :overdue, 7, :firm ],
        [ "overdue_14", :overdue, 14, :final ]
      ],
      schedule_for(:normal_debtor)
    )
  end

  test "defines the bad debtor schedule" do
    assert_equal(
      [
        [ "pre_due_14", :pre_due, 14, :direct ],
        [ "pre_due_7", :pre_due, 7, :direct ],
        [ "pre_due_3", :pre_due, 3, :direct ],
        [ "pre_due_1", :pre_due, 1, :direct ],
        [ "overdue_1", :overdue, 1, :firm ],
        [ "overdue_5", :overdue, 5, :final ]
      ],
      schedule_for(:bad_debtor)
    )
  end

  test "accepts a persisted payer segment string" do
    stages = InvoiceReminder::Policy.stages_for(payer_segment: "good_debtor")

    assert_equal "pre_due_3", stages.first.key
  end

  test "calculates stage dates from an invoice due date" do
    due_on = Date.new(2026, 7, 31)
    stages = InvoiceReminder::Policy.stages_for(payer_segment: :normal_debtor).index_by(&:key)

    assert_equal Date.new(2026, 7, 24), stages.fetch("pre_due_7").date_for(due_on:)
    assert_equal Date.new(2026, 8, 14), stages.fetch("overdue_14").date_for(due_on:)
  end

  test "returns the next stage after a current stage" do
    stage = InvoiceReminder::Policy.get_next_stage(
      customer_segment: customer_segments(:normal_debtor_segment),
      current_reminder: reminder_for(category: :pre_due, day_offset: 7),
      due_on: Date.new(2026, 11, 1)
    )

    assert_equal "pre_due_1", stage.key
  end

  test "returns the next stage when the current rating does not contain the old stage" do
    stage = InvoiceReminder::Policy.get_next_stage(
      customer_segment: customer_segments(:good_debtor_segment),
      current_reminder: reminder_for(category: :pre_due, day_offset: 7),
      due_on: Date.new(2026, 11, 1)
    )

    assert_equal "pre_due_3", stage.key
  end

  test "returns nil after the final stage" do
    assert_nil InvoiceReminder::Policy.get_next_stage(
      customer_segment: customer_segments(:good_debtor_segment),
      current_reminder: reminder_for(category: :overdue, day_offset: 10),
      due_on: Date.new(2026, 11, 1)
    )
  end

  test "returns the first upcoming stage without a current reminder" do
    travel_to Time.zone.local(2026, 11, 8, 12) do
      stage = InvoiceReminder::Policy.get_next_stage(
        customer_segment: customer_segments(:good_debtor_segment),
        current_reminder: nil,
        due_on: Date.new(2026, 11, 1)
      )

      assert_equal "overdue_10", stage.key
    end
  end

  test "returns nil without a current reminder when the schedule has passed" do
    travel_to Time.zone.local(2026, 11, 20, 12) do
      assert_nil InvoiceReminder::Policy.get_next_stage(
        customer_segment: customer_segments(:good_debtor_segment),
        current_reminder: nil,
        due_on: Date.new(2026, 11, 1)
      )
    end
  end

  test "returns an immutable schedule" do
    stages = InvoiceReminder::Policy.stages_for(payer_segment: :good_debtor)

    assert_predicate stages, :frozen?
    assert_raises(FrozenError) { stages << stages.first }
  end

  test "rejects an unknown payer segment" do
    assert_raises KeyError do
      InvoiceReminder::Policy.stages_for(payer_segment: :unknown)
    end
  end

  private
    def reminder_for(category:, day_offset:)
      Struct.new(:category, :day_offset).new(category.to_s, day_offset)
    end

    def schedule_for(payer_segment)
      InvoiceReminder::Policy.stages_for(payer_segment:).map do |stage|
        [ stage.key, stage.category, stage.day_offset, stage.tone ]
      end
    end
end
