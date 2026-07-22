class Current < ActiveSupport::CurrentAttributes
  attribute :session, :user, :identity, :account

  def session=(value)
    super(value)

    if value.present?
      self.identity = session.identity
    end
  end

  def identity=(identity)
    super(identity)

    if identity.present?
      self.user = if account.present?
        identity.users.active.find_by(account_id: account.id)
      else
        identity.users.active.first
      end
      self.account ||= user&.account
    else
      self.user = nil
    end
  end

  def with_account(value, &)
    with(account: value, &)
  end

  def without_account(&)
    with(account: nil, &)
  end
end
