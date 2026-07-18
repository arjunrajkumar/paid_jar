require "bigdecimal"

module InvoiceSources
  class Stripe
    class Currency
      ZERO_DECIMAL_CODES = %w[
        BIF
        CLP
        DJF
        GNF
        JPY
        KMF
        KRW
        MGA
        PYG
        RWF
        UGX
        VND
        VUV
        XAF
        XOF
        XPF
      ].freeze

      def self.amount_from_minor_units(value, currency:)
        return if value.nil?

        divisor = currency.to_s.upcase.in?(ZERO_DECIMAL_CODES) ? 1 : 100
        BigDecimal(value.to_s) / divisor
      end
    end
  end
end
