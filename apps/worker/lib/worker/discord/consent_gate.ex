defmodule Worker.Discord.ConsentGate do
  @moduledoc """
  Issue #1002: die **eine** Entscheidung „darf diese Tonspur gespeichert werden?"
  — absichtlich als winzige PURE Funktion, getrennt vom `VoiceSession`-GenServer
  (der ohne echten Nostrum-Bot kaum testbar ist). Alles, was an dieser Frage
  hängt, ist hier vollständig und mit Tests festgenagelt.

  Zwei Quellen einer gültigen Einwilligung, ODER-verknüpft:

    * **Urteil aus dem laufenden Consent-Fenster** (`:granted`) — es zählt
      sofort, obwohl das `AudioConsentRecorded`-Event den Weg über den Hub noch
      nicht zurückgelegt hat. Ohne diesen Zweig würde eine kurze Session ihre
      Spuren verwerfen, obwohl gerade eben zugestimmt wurde.
    * **Persistierter Consent** (`%{version:, accepted_at:}` aus
      `worker_audio_consents`) — deckt frühere Spielabende ab UND den
      Browser-Mikro-Pfad, weil beide Pfade auf dieselbe, auf `discord_id`
      geschlüsselte Tabelle schreiben. Wer im Browser schon zugestimmt hat, muss
      im Voice-Kanal nichts mehr sagen.

  Ein persistierter Consent zählt nur, wenn er zur **aktuellen Version des
  Einwilligungs-Wortlauts** passt (`ConsentPhrase.version/0`, verglichen über
  `Worker.Materializer.version_rank/1` — dieselbe Rangfolge wie das
  Max-Version-Lattice des Folds, #824). Sonst wurde in einen anderen Text
  eingewilligt, und es wird neu gefragt. Ohne diese Prüfung wäre die
  Versionierung reine Dekoration: sie würde geschrieben, aber nie ausgewertet —
  eine `v1`-Zustimmung würde eine `v2`-Einwilligung stillschweigend abdecken.

  **Fail-closed:** alles andere — `:declined`, `:unclear`, kein Urteil (nichts
  gesagt), unbekannte Werte, fehlende/kaputte Version — verbietet das Speichern.
  Ein `:declined` im Fenster kann einen bereits persistierten Consent NICHT
  überschreiben; das wäre ein Widerruf, und der ist bewusst nicht Teil dieses
  Schnitts (er bräuchte einen persistierten Ablehnungs-Zustand, s. Issue).
  Ehrliche Grenze: wer heute widerspricht, aber früher zur aktuellen Version
  zugestimmt hat, wird weiter aufgezeichnet.
  """

  alias Worker.Recording.ConsentPhrase

  @doc """
  `verdict` (aus dem Consent-Fenster, oder `nil`) + `persisted` (Consent-Row oder
  `nil`) → darf gespeichert werden?
  """
  @spec allow?(ConsentPhrase.verdict() | nil, map() | nil) :: boolean()
  def allow?(:granted, _persisted), do: true
  def allow?(_verdict, %{version: version}), do: version_current?(version)
  def allow?(_verdict, _persisted), do: false

  # Eine Zustimmung zu einer NEUEREN Version deckt die aktuelle mit ab (sie ist
  # umfassender oder gleich); eine ältere nicht. Nicht-Strings ⇒ Rang 0 ⇒ nur
  # gültig, wenn auch die geforderte Version Rang 0 hätte (fail-closed).
  defp version_current?(version) do
    Worker.Materializer.version_rank(to_string(version)) >=
      Worker.Materializer.version_rank(ConsentPhrase.version())
  end
end
