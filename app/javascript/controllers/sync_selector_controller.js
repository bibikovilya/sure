import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { baseUrl: String }
  static targets = ["loading", "content"]

  change(event) {
    const syncId = event.target.value
    const url = `${this.baseUrlValue}?sync_id=${syncId}`

    // Show loading spinner, hide content
    if (this.hasLoadingTarget) {
      this.loadingTarget.classList.remove("hidden")
    }
    if (this.hasContentTarget) {
      this.contentTarget.classList.add("hidden")
    }

    Turbo.visit(url, { frame: "modal" })
  }
}
