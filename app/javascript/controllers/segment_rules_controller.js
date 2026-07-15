import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "minimumHistory",
    "unreliableHistory",
    "paysOnTimeRate",
    "unreliableOnTimeRate"
  ]

  connect() {
    this.updateOptionAvailability()
  }

  updateOptionAvailability() {
    this.disableOptionsAbove(this.minimumHistoryTarget, this.unreliableHistory)
    this.disableOptionsBelow(this.unreliableHistoryTarget, this.minimumHistory)
    this.disableOptionsAtOrBelow(this.paysOnTimeRateTarget, this.unreliableOnTimeRate)
    this.disableOptionsAtOrAbove(this.unreliableOnTimeRateTarget, this.paysOnTimeRate)
  }

  disableOptionsAbove(select, maximum) {
    this.updateOptions(select, value => value > maximum)
  }

  disableOptionsBelow(select, minimum) {
    this.updateOptions(select, value => value < minimum)
  }

  disableOptionsAtOrBelow(select, minimum) {
    this.updateOptions(select, value => value <= minimum)
  }

  disableOptionsAtOrAbove(select, maximum) {
    this.updateOptions(select, value => value >= maximum)
  }

  updateOptions(select, shouldDisable) {
    Array.from(select.options).forEach(option => {
      option.disabled = shouldDisable(Number(option.value))
    })
  }

  get minimumHistory() {
    return Number(this.minimumHistoryTarget.value)
  }

  get unreliableHistory() {
    return Number(this.unreliableHistoryTarget.value)
  }

  get paysOnTimeRate() {
    return Number(this.paysOnTimeRateTarget.value)
  }

  get unreliableOnTimeRate() {
    return Number(this.unreliableOnTimeRateTarget.value)
  }
}
