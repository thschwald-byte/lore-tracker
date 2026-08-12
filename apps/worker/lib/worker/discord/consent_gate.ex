defmodule Worker.Discord.ConsentGate do
  @moduledoc """
  Issue #1002/#1005: die **eine** Entscheidung „darf diese Tonspur gespeichert
  werden?" — absichtlich eine winzige PURE Funktion, getrennt vom
  `VoiceSession`-GenServer (der ohne echten Nostrum-Bot kaum testbar ist).

  ## Zwei Quellen einer gültigen Einwilligung

    * **Urteil aus der laufenden Session** (`:granted`) — zählt sofort, obwohl
      das `AudioConsentRecorded`-Event den Weg über den Hub noch nicht
      zurückgelegt hat. Ohne diesen Zweig würde eine kurze Session ihre Spuren
      verwerfen, obwohl gerade eben zugestimmt wurde.
    * **Persistierter Status** — deckt frühere Spielabende ab UND den
      Browser-Mikro-Pfad, weil beide Pfade auf dieselbe, auf `discord_id`
      geschlüsselte Wahrheit schreiben. Wer im Browser schon zugestimmt hat,
      muss im Voice-Kanal nichts tun.

  Ein persistierter Status zählt nur, wenn er zur **aktuellen Version des
  Einwilligungs-Wortlauts** passt (`ConsentPhrase.version/0`, verglichen über
  `Worker.Materializer.version_rank/1` — dieselbe Rangfolge wie das
  Max-Version-Lattice des Folds, #824). Sonst wurde in einen anderen Text
  eingewilligt, und es wird neu gefragt. Ohne diese Prüfung wäre die
  Versionierung reine Dekoration: geschrieben, aber nie ausgewertet.

  ## Widerruf (#1005)

  `allow?/3` nimmt den Status als `{verdict, version}`-Paar. `:revoked` verbietet
  das Speichern **unabhängig davon**, ob eine ältere Zustimmung existiert — die
  LWW-Auflösung zwischen Zustimmung und Widerruf ist bereits im Fold passiert
  (`worker_audio_consent_status`, LWW-by-`event_id`, #766-Klasse). Dieses Modul
  entscheidet nicht mehr, *welches* Verdikt gilt, sondern nur, was aus dem
  geltenden folgt.

  **Fail-closed:** alles andere — `:declined`, `:unclear`, kein Urteil (nichts
  gesagt, nichts geklickt), unbekannte Werte, fehlende/kaputte Version —
  verbietet das Speichern. Abwesenheit von Information gilt **nie** als
  Zustimmung.

  Ein `:declined`/`:revoked` aus der laufenden Session kann einen persistierten
  `:granted` überstimmen (beides verbietet), aber ein Session-`:granted`
  überstimmt einen persistierten `:revoked` **nicht** — ein Widerruf lässt sich
  nur durch einen neuen, persistierten Zustimmungs-Akt aufheben, nicht durch
  eine Spracherkennung im laufenden Betrieb.
  """

  alias Worker.Recording.ConsentPhrase

  @typedoc "Persistierter Status: Verdikt + Wortlaut-Version (oder `nil` = keiner)."
  @type persisted :: {:granted | :revoked, String.t() | nil} | nil

  @doc """
  `verdict` (aus der laufenden Session, oder `nil`) + `persisted` → darf
  gespeichert werden?
  """
  @spec allow?(ConsentPhrase.verdict() | nil, persisted()) :: boolean()
  def allow?(verdict, persisted) do
    cond do
      # Ein persistierter Widerruf schlägt alles — auch ein frisches
      # Sprach-`:granted`. Aufheben geht nur über einen neuen Zustimmungs-Akt,
      # der dann selbst persistiert wird (und im Fold per LWW gewinnt).
      revoked?(persisted) -> false
      verdict == :granted -> true
      granted_and_current?(persisted) -> true
      true -> false
    end
  end

  @doc """
  Wie `allow?/2`, aber für den Fall, dass beides getrennt vorliegt: das
  Session-Verdikt und der persistierte Status. Existiert nur, damit Call-Sites
  nicht selbst zu einem Tupel zusammenbauen müssen.
  """
  @spec allow?(ConsentPhrase.verdict() | nil, :granted | :revoked | nil, String.t() | nil) ::
          boolean()
  def allow?(verdict, persisted_verdict, persisted_version) do
    persisted = if persisted_verdict, do: {persisted_verdict, persisted_version}
    allow?(verdict, persisted)
  end

  # ─── intern ──────────────────────────────────────────────────────

  defp revoked?({:revoked, _version}), do: true
  defp revoked?(_), do: false

  defp granted_and_current?({:granted, version}), do: version_current?(version)
  defp granted_and_current?(_), do: false

  # Eine Zustimmung zu einer NEUEREN Version deckt die aktuelle mit ab (sie ist
  # umfassender oder gleich); eine ältere nicht. Nicht-Strings ⇒ Rang 0 ⇒ nur
  # gültig, wenn auch die geforderte Version Rang 0 hätte (fail-closed).
  defp version_current?(version) do
    Worker.Materializer.version_rank(to_string(version)) >=
      Worker.Materializer.version_rank(ConsentPhrase.version())
  end
end
