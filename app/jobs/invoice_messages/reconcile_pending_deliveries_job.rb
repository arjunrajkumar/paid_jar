# One-release compatibility for Solid Queue payloads serialized before the
# ConversationMessage rename. Active scheduling uses the new class name.
class InvoiceMessages::ReconcilePendingDeliveriesJob < ConversationMessages::ReconcilePendingDeliveriesJob
end
