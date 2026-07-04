class Account < ApplicationRecord
  has_many :users, dependent: :destroy, inverse_of: :account

  validates :name, presence: true

  scope :ordered, -> { order(Arel.sql("LOWER(name)"), :id) }

  def self.filtered_by(query)
    query = query.to_s.strip
    return all if query.blank?

    where(arel_table[:name].matches("%#{sanitize_sql_like(query)}%"))
  end

  def initials
    name.to_s.scan(/\b\w/).join.upcase
  end
end
