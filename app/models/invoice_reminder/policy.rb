class InvoiceReminder::Policy
  Stage = Data.define(:category, :day_offset, :tone) do
    def key
      "#{category}_#{day_offset}"
    end

    def date_for(due_on:)
      case category
      when :pre_due
        due_on - day_offset.days
      when :overdue
        due_on + day_offset.days
      end
    end
  end

  SCHEDULES = {
    good_debtor: [
      Stage.new(category: :pre_due, day_offset: 3, tone: :friendly),
      Stage.new(category: :overdue, day_offset: 3, tone: :neutral),
      Stage.new(category: :overdue, day_offset: 10, tone: :final)
    ].freeze,
    normal_debtor: [
      Stage.new(category: :pre_due, day_offset: 7, tone: :friendly),
      Stage.new(category: :pre_due, day_offset: 1, tone: :direct),
      Stage.new(category: :overdue, day_offset: 3, tone: :direct),
      Stage.new(category: :overdue, day_offset: 7, tone: :firm),
      Stage.new(category: :overdue, day_offset: 14, tone: :final)
    ].freeze,
    bad_debtor: [
      Stage.new(category: :pre_due, day_offset: 14, tone: :direct),
      Stage.new(category: :pre_due, day_offset: 7, tone: :direct),
      Stage.new(category: :pre_due, day_offset: 3, tone: :direct),
      Stage.new(category: :pre_due, day_offset: 1, tone: :direct),
      Stage.new(category: :overdue, day_offset: 1, tone: :firm),
      Stage.new(category: :overdue, day_offset: 5, tone: :final)
    ].freeze
  }.freeze

  def self.stages_for(payer_segment:)
    SCHEDULES.fetch(payer_segment.to_s.to_sym)
  end

  def self.get_next_stage(customer_segment:, current_reminder:, due_on:)
    stages = stages_for(payer_segment: customer_segment.payer_segment)
    return stages.find { |stage| stage.date_for(due_on:) >= Date.current } unless current_reminder

    current_position = stage_position(
      category: current_reminder.category,
      day_offset: current_reminder.day_offset
    )

    stages.find do |stage|
      stage_position(category: stage.category, day_offset: stage.day_offset) > current_position
    end
  end

  def self.stage_position(category:, day_offset:)
    category.to_sym == :pre_due ? -day_offset.to_i : day_offset.to_i
  end
  private_class_method :stage_position
end
