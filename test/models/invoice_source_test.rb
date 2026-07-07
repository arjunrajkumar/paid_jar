require "test_helper"

class InvoiceSourceTest < ActiveSupport::TestCase
  test "belongs to an account" do
    assert_equal accounts(:paid_jar), invoice_sources(:xero).account
  end

  test "has many invoices" do
    assert_includes invoice_sources(:xero).invoices, invoices(:xero_invoice)
  end

  test "requires provider and external account id" do
    source = accounts(:paid_jar).invoice_sources.build

    assert_not source.valid?
    assert_includes source.errors[:provider], "can't be blank"
    assert_includes source.errors[:external_account_id], "can't be blank"
  end

  test "defaults to pending status" do
    source = accounts(:paid_jar).invoice_sources.build(
      provider: "xero",
      external_account_id: "xero-tenant-456"
    )

    assert_predicate source, :pending?
  end

  test "knows whether it is connected" do
    assert_predicate invoice_sources(:xero), :connected?
  end

  test "delegates connection and invoice sync to provider adapter" do
    source = invoice_sources(:xero)
    adapter = mock

    InvoiceSources::Xero.expects(:new).twice.with(source).returns(adapter)
    adapter.expects(:connect!).with(code: "auth-code")
    adapter.expects(:sync_invoices!)

    source.connect!(code: "auth-code")
    source.sync_invoices!
  end

  test "does not allow the same provider twice for an account" do
    source = accounts(:paid_jar).invoice_sources.build(
      provider: "xero",
      external_account_id: "different-xero-tenant"
    )

    assert_not source.valid?
    assert_includes source.errors[:provider], "has already been taken"
  end
end
