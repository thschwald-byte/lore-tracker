// Issue #275: IconUpload — Drag-and-Drop + Click-to-Pick für Campaign-Icons.
// Client-side resize via Canvas auf 512×512, Center-Crop, JPEG-Q85 →
// Data-URI in einen Hidden-Input. Server speichert das im
// `campaigns.icon_url`-Feld.
//
// `data-target-input` zeigt auf die ID des Hidden-Inputs der die
// finale Data-URI bekommt. Nach Set wird ein `input`-Event dispatched
// damit der LV-`phx-change` triggert.

const MAX_DATA_URI_BYTES = 200_000;
const TARGET_SIZE = 512;
const JPEG_QUALITY = 0.85;

export const IconUpload = {
  mounted() {
    const targetId = this.el.dataset.targetInput;
    this.target = document.getElementById(targetId);

    this.fileInput = document.createElement("input");
    this.fileInput.type = "file";
    this.fileInput.accept = "image/jpeg,image/png,image/webp";
    this.fileInput.style.display = "none";
    this.el.appendChild(this.fileInput);

    this.onClick = (e) => {
      if (e.target.tagName === "BUTTON") return;
      this.fileInput.click();
    };
    this.onDragOver = (e) => {
      e.preventDefault();
      this.el.classList.add("border-accent");
    };
    this.onDragLeave = () => this.el.classList.remove("border-accent");
    this.onDrop = (e) => {
      e.preventDefault();
      this.el.classList.remove("border-accent");
      const file = e.dataTransfer && e.dataTransfer.files[0];
      if (file) this.processFile(file);
    };
    this.onChange = (e) => {
      const file = e.target.files[0];
      if (file) this.processFile(file);
    };

    this.el.addEventListener("click", this.onClick);
    this.el.addEventListener("dragover", this.onDragOver);
    this.el.addEventListener("dragleave", this.onDragLeave);
    this.el.addEventListener("drop", this.onDrop);
    this.fileInput.addEventListener("change", this.onChange);
  },

  destroyed() {
    this.el.removeEventListener("click", this.onClick);
    this.el.removeEventListener("dragover", this.onDragOver);
    this.el.removeEventListener("dragleave", this.onDragLeave);
    this.el.removeEventListener("drop", this.onDrop);
  },

  processFile(file) {
    if (!/^image\/(jpeg|png|webp)$/.test(file.type)) {
      alert("Nur JPEG, PNG oder WebP erlaubt.");
      return;
    }

    const reader = new FileReader();
    reader.onload = (ev) => {
      const img = new Image();
      img.onload = () => {
        const size = Math.min(img.width, img.height);
        const sx = (img.width - size) / 2;
        const sy = (img.height - size) / 2;

        const canvas = document.createElement("canvas");
        canvas.width = TARGET_SIZE;
        canvas.height = TARGET_SIZE;
        const ctx = canvas.getContext("2d");
        ctx.drawImage(img, sx, sy, size, size, 0, 0, TARGET_SIZE, TARGET_SIZE);

        const dataUri = canvas.toDataURL("image/jpeg", JPEG_QUALITY);
        if (dataUri.length > MAX_DATA_URI_BYTES) {
          alert(
            "Bild zu groß nach Komprimierung (" +
              Math.round(dataUri.length / 1024) +
              " KB > 200 KB). Bitte kleineres Original wählen."
          );
          return;
        }

        this.target.value = dataUri;
        this.target.dispatchEvent(new Event("input", { bubbles: true }));
      };
      img.onerror = () => alert("Bild konnte nicht geladen werden.");
      img.src = ev.target.result;
    };
    reader.onerror = () => alert("Datei konnte nicht gelesen werden.");
    reader.readAsDataURL(file);
  },
};
