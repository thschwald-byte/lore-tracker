defmodule Worker.Jack.Frage.Zusammenfassung do
  @moduledoc """
  Der Arbeitsstand des Frage-Jack für die Kompaktierung (#850).

  Er ist kurz, weil der Jack wenig mitschleppt: die Frage und was er bisher
  gelesen hat. Die Frage steht **wörtlich** darin — sie ist das Einzige, was
  nach einer Kompaktierung unbedingt erhalten bleiben muss.

  Dass es überhaupt dazu kommt, ist unwahrscheinlich: Bei `ctx_jack` (98304)
  liegt der Bedarf eines Laufs weit unter der Schwelle (gemessen am
  Chronik-Jack: fester Teil ~4.650 Token, Wachstum ~2.400 je Datenrunde). Der
  Rückruf ist trotzdem gesetzt — ein Lauf, der ihn braucht und nicht hat,
  stürbe am Fenster.
  """

  alias Worker.Jack.Resuemee.Stand
  alias Worker.Jack.Resuemee.Zusammenfassung, as: Gemeinsam

  @kopf "# Stand deiner Arbeit (von deinen Werkzeugen geschrieben, nicht zusammengefasst)"

  @doc "Der Rückruf für `kontext: [zusammenfassen: …]` eines Laufs mit diesem Halter."
  @spec fuer(pid()) :: (map() -> String.t())
  def fuer(halter), do: Gemeinsam.fuer(halter, &text/1)

  @doc "Der Arbeitsstand als Text."
  @spec text(Stand.t()) :: String.t()
  def text(%Stand{} = s) do
    Enum.join(
      [
        @kopf,
        "",
        "## Die Frage",
        s.frage || "(keine)",
        "",
        "## Gelesen",
        "#{MapSet.size(s.gelesen)} von #{length(s.fakten)} Fakten der Kampagne.",
        "",
        "## Auftrag",
        "Beantworte die Frage aus den Fakten und schließe mit antworte(text, fakt_ids) ab."
      ],
      "\n"
    )
  end
end
