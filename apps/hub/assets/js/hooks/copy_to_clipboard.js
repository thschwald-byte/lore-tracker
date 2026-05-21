export const CopyToClipboard = {
  mounted() {
    this.el.addEventListener('click', (e) => {
      e.preventDefault()
      e.stopPropagation()
      const text = this.el.dataset.copyText
      navigator.clipboard.writeText(text)
        .then(() => this.pushEvent("copy_success", {}))
        .catch(() => this.pushEvent("copy_failed", {}))
    })
  }
}
