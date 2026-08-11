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

  **Fail-closed:** alles andere — `:declined`, `:unclear`, kein Urteil (nichts
  gesagt), unbekannte Werte — verbietet das Speichern. Ein `:declined` im
  Fenster kann einen bereits persistierten Consent NICHT überschreiben; das wäre
  ein Widerruf, und der ist bewusst nicht Teil dieses Schnitts (er bräuchte einen
  persistierten Ablehnungs-Zustand, s. Issue). Ehrliche Grenze: wer heute
  widerspricht, aber früher zugestimmt hat, wird weiter aufgezeichnet.
  """

  alias Worker.Recording.ConsentPhrase

  @doc """
  `verdict` (aus dem Consent-Fenster, oder `nil`) + `persisted` (Consent-Row oder
  `nil`) → darf gespeichert werden?
  """
  @spec allow?(ConsentPhrase.verdict() | nil, map() | nil) :: boolean()
  def allow?(:granted, _persisted), do: true
  def allow?(_verdict, %{} = _persisted), do: true
  def allow?(_verdict, _persisted), do: false
end
