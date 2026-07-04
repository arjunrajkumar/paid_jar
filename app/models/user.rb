class User < ApplicationRecord
  belongs_to :account, inverse_of: :users

  normalizes :email, with: -> { _1.strip.downcase }

  validates :name, :email, presence: true
  validates :email, uniqueness: { case_sensitive: false }

  scope :ordered, -> { order(Arel.sql("LOWER(name)"), :id) }

  def self.filtered_by(query)
    query = query.to_s.strip
    return all if query.blank?

    where(
      arel_table[:name].matches("%#{sanitize_sql_like(query)}%")
        .or(arel_table[:email].matches("%#{sanitize_sql_like(query)}%"))
    )
  end

  def initials
    name.to_s.scan(/\b\w/).join.upcase
  end

  def title
    [ name, email ].compact_blank.join(" - ")
  end
end
