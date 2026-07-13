class Customers::Collection
  def initialize(invoices, as_of: Date.current)
    @invoices = Receivables::Dashboard.new(invoices, as_of: as_of).issued_invoices
    @as_of = as_of
  end

  def profiles
    @profiles ||= build_profiles.tap { |profiles| assign_value_segments(profiles) }
  end

  def find!(key)
    profiles.find { |profile| profile.to_param == key.to_s } || raise(ActiveRecord::RecordNotFound)
  end

  private
    attr_reader :as_of, :invoices

    def build_profiles
      invoices
        .group_by { |invoice| Customers::Profile.identity_for(invoice) }
        .map { |identity, customer_invoices| Customers::Profile.new(customer_invoices, identity: identity, as_of: as_of) }
        .sort_by { |profile| profile.name.downcase }
    end

    def assign_value_segments(profiles)
      profiles.group_by(&:primary_currency).each_value do |currency_profiles|
        ranked_profiles = currency_profiles.select(&:average_invoice_amount).sort_by do |profile|
          [ profile.average_invoice_amount, profile.name ]
        end

        ranked_profiles.each_with_index do |profile, index|
          profile.value_segment = value_segment(index, ranked_profiles.size)
        end
      end
    end

    def value_segment(index, profile_count)
      return "Standard value" if profile_count < 3

      percentile = index.to_f / (profile_count - 1)
      return "Lower value" if percentile <= 0.33
      return "High value" if percentile >= 0.67

      "Standard value"
    end
end
