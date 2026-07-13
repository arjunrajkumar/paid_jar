import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  open(event) {
    const target = document.querySelector(this.element.hash)
    if (!(target instanceof HTMLDetailsElement)) return

    event.preventDefault()
    target.open = true
    target.scrollIntoView({ behavior: "smooth", block: "start" })
    target.querySelector("summary")?.focus({ preventScroll: true })
  }
}
