class Conversations::AttentionSummary
  Result = Data.define(:count)

  def self.call(account:)
    Result.new(
      count: Conversations::Inbox.call(
        account:,
        filter: :needs_attention
      ).except(:select, :order).count
    )
  end
end
