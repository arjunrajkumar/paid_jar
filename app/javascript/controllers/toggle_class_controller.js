import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static classes = [ "toggle" ]
  static targets = [ "trigger", "panel" ]

  connect() {
    this.updateExpandedState()
  }

  toggle() {
    this.element.classList.toggle(this.toggleClass)
    this.updateExpandedState()
  }

  close(event) {
    if (!this.element.classList.contains(this.toggleClass)) return

    event?.preventDefault()
    this.element.classList.remove(this.toggleClass)
    this.updateExpandedState()
    if (this.hasTriggerTarget) this.triggerTarget.focus()
  }

  updateExpandedState() {
    const expanded = this.element.classList.contains(this.toggleClass)
    this.triggerTargets.forEach((trigger) => {
      trigger.setAttribute("aria-expanded", expanded.toString())
    })
  }
}
