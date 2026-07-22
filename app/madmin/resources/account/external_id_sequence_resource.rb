class Account::ExternalIdSequenceResource < Madmin::Resource
  attribute :id, form: false, index: true
  attribute :value, form: false, index: true

  menu false
end
