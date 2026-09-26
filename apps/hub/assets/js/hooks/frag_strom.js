// Der Denkstrom EINES Frage-Laufs (#850).
//
// Er kommt per `push_event`, NICHT über die Assigns: Über einen Lauf sammeln
// sich Tausende Token, und in den Assigns würde das bei jedem Diff kopiert und
// gehalten (#1146). Hier landet es direkt im DOM.
//
// **Ein Element je Lauf, nicht eines fürs Fenster** (Maintainer, 25.09.2026:
// Frage → Denkstrom → Antwort, und der Strom der vorigen Frage bleibt stehen).
// `push_event` erreicht JEDEN gemounteten Hook dieses Namens — deshalb nimmt
// jeder nur, was seine Lauf-ID trägt. Ohne diesen Vergleich bekäme jeder Strom
// im Fenster jedes Stück, und alle zeigten dasselbe.
//
// **Kein Deckel und kein eigener Scrollbalken**: Der Strom wächst mit,
// gescrollt wird im Verlauf. Ein Kasten mit eigenem Balken verbirgt genau das,
// was man lesen will, und ein Deckel würfe weg, was bleiben soll.
export const FragStrom = {
  mounted() {
    this.lauf = this.el.dataset.laufId;
    this.handleEvent("frag_strom", ({ lauf_id, stuecke }) => {
      if (lauf_id !== this.lauf) return;
      this.anhaengen(stuecke);
    });
  },

  updated() {
    // Der Inhalt bleibt, weil phx-update="ignore" am Element steht; nur die
    // ID könnte sich theoretisch ändern — dann gehört das Element ohnehin zu
    // einem anderen Lauf.
    this.lauf = this.el.dataset.laufId;
  },

  anhaengen(stuecke) {
    if (!Array.isArray(stuecke)) return;

    // Ans Ende nachziehen ist nur richtig, wenn der Betrachter dort steht.
    // Wer hochgescrollt hat, liest etwas — dem reissen wir es nicht weg.
    const box = this.el.closest("[data-frag-verlauf]");
    const amEnde =
      box && box.scrollHeight - box.scrollTop - box.clientHeight < 40;

    for (const s of stuecke) {
      const zeile = document.createElement("div");
      zeile.className = klasse(s.art);
      zeile.textContent = zeichen(s.art) + (s.text || "");
      this.el.appendChild(zeile);
    }

    if (amEnde) box.scrollTop = box.scrollHeight;
  },
};

function klasse(art) {
  if (art === "denken") return "text-ink-2/45 italic font-sans";
  if (art === "werkzeug") return "text-primary/70";
  return "text-ink-2/40";
}

function zeichen(art) {
  if (art === "denken") return "💭 ";
  if (art === "werkzeug") return "🔎 ";
  return "→ ";
}
