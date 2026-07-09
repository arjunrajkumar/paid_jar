module ApplicationHelper
  def page_title_tag
    tag.title [ @page_title, Current.account&.name, "PaymentReminder" ].compact.uniq.join(" | ")
  end

  def body_classes
    [ @body_class ].compact.join(" ")
  end
end
