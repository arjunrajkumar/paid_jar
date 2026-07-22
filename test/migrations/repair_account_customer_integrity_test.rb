require "test_helper"
require Rails.root.join("db/migrate/20260716010000_create_customer_segments")
require Rails.root.join("db/migrate/20260722130000_repair_account_customer_integrity")

class RepairAccountCustomerIntegrityTest < ActiveSupport::TestCase
  test "restores every missing default customer segment without changing existing rules" do
    account = Account.create!(name: "Incomplete Segment Account")
    good_segment = account.customer_segment(:good_debtor)
    good_segment.update!(on_time_rate: 90)
    RepairAccountCustomerIntegrity::MigrationCustomerSegment
      .where(account_id: account.id, payer_segment: "bad_debtor")
      .delete_all

    RepairAccountCustomerIntegrity.new.send(:ensure_default_customer_segments)

    segments = account.customer_segments.reload.index_by(&:payer_segment)
    assert_equal CustomerSegment::PAYER_SEGMENTS.keys.sort, segments.keys.sort
    assert_equal 90, segments.fetch("good_debtor").on_time_rate
    assert_equal 50, segments.fetch("bad_debtor").on_time_rate
  end

  test "builds a provider customer for a legacy invoice without one" do
    account = Account.create!(name: "Legacy Invoice Customer Account")
    source = account.invoice_sources.create!(
      provider: :stripe,
      status: :active,
      external_account_id: "acct_legacy_invoice_customer"
    )
    invoice = RepairAccountCustomerIntegrity::MigrationInvoice.new(
      account_id: account.id,
      invoice_source_id: source.id,
      external_id: "in_legacy_customer",
      contact_external_id: "cus_legacy_customer",
      contact_name: "Legacy Customer",
      issued_on: Date.new(2026, 7, 1),
      provider_data: { "customer_email" => "legacy-customer@example.com" },
      raw_data: {}
    )
    normal_segment_id = account.customer_segment(:normal_debtor).id

    customer = RepairAccountCustomerIntegrity.new.send(
      :customer_for,
      invoice,
      normal_segment_id:
    )

    assert_equal account.id, customer.account_id
    assert_equal source.id, customer.invoice_source_id
    assert_equal normal_segment_id, customer.customer_segment_id
    assert_equal "cus_legacy_customer", customer.external_id
    assert_equal "Legacy Customer", customer.name
    assert_equal "legacy-customer@example.com", customer.email
  end

  test "moves a cross-account customer segment to the matching account segment" do
    account = Account.create!(name: "Correct Customer Segment Account")
    source = account.invoice_sources.create!(
      provider: :stripe,
      status: :active,
      external_account_id: "acct_cross_account_segment"
    )
    customer = source.customers.create!(
      account:,
      customer_segment: account.customer_segment(:normal_debtor),
      external_id: "cus_cross_account_segment",
      name: "Cross-account Segment Customer"
    )
    other_account = Account.create!(name: "Wrong Customer Segment Account")
    customer.update_column(
      :customer_segment_id,
      other_account.customer_segment(:bad_debtor).id
    )

    RepairAccountCustomerIntegrity.new.send(:repair_customer_segment_references)

    assert_equal account.customer_segment(:bad_debtor), customer.reload.customer_segment
  end

  test "declares the legacy payer segment mapping used by the historical migration" do
    assert_equal(
      {
        "pays_on_time" => "good_debtor",
        "slow_payer" => "bad_debtor",
        "unreliable_payer" => "bad_debtor"
      },
      CreateCustomerSegments::LEGACY_SEGMENTS
    )
  end
end
