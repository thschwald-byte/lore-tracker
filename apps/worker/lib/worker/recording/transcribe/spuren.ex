defmodule Worker.Recording.Transcribe.Spuren do
  @moduledoc """
  Issue #1054: Wie eine **einzelne** Spur abgesichert und gemeldet wird.

  Eigenes Modul aus demselben Grund wie `Transcribe.Confidence` (#791): der
  `Transcribe` steht an der 600-Code-Zeilen-Grenze (#544/#1097). Der Schnitt ist
  inhaltlich — hier steht die Absicherung und die Meldung, dort das
  Transkribieren selbst.

  Am 13.08.2026 starb die Transkription bei Spur 2 von 18: die Spuren liefen in
  einem blanken `Enum.map`, und die erste Ausnahme beendete die Schleife. Die
  restlichen 16 wurden nie transkribiert, das Audio trotzdem weggeräumt.
  """

  require Logger

  alias Worker.Recording.Stage1Status

  @typedoc "Ausgang einer Spur: Utterances gezählt, oder der Schlüssel der gescheiterten Spur."
  @type ergebnis :: {:ok, non_neg_integer()} | {:offen, String.t()}

  @doc """
  Führt die Arbeit EINER Spur aus, abgeschirmt gegen alles, was sie hochreißen
  kann.

  Vorbild ist die Fehlerisolierung pro Handlungsbogen (#838): ein
  fehlschlagender Teil darf weder seine Nachbarn noch den Rest des Laufs
  mitreißen.

  `catch` neben `rescue` ist kein Zierrat: ein `throw` oder `exit` aus einer der
  aufgerufenen Bibliotheken erzeugte vorher **gar keinen** Fehlereintrag, nur
  die Erfolgsmeldung der Warteschlange (benannter Nebenfund des Tickets).
  """
  @spec isoliert(String.t() | nil, String.t(), (-> non_neg_integer())) :: ergebnis()
  def isoliert(campaign_id, key, fun) do
    {:ok, fun.()}
  rescue
    e ->
      melde_abbruch(campaign_id, key, Exception.message(e), __STACKTRACE__)
      {:offen, key}
  catch
    kind, reason ->
      melde_abbruch(campaign_id, key, "#{kind}: #{inspect(reason)}", __STACKTRACE__)
      {:offen, key}
  end

  @doc """
  Faltet die Ausgänge aller Spuren zu `{Utterance-Gesamtzahl, offene Schlüssel}`.

  Die Reihenfolge der offenen Schlüssel bleibt die der Dateien — sie steht so in
  der Meldung, und wer sie mit dem Verzeichnis vergleicht, soll sie wiederfinden.
  """
  @spec summiere([ergebnis()]) :: {non_neg_integer(), [String.t()]}
  def summiere(ergebnisse) do
    {count, offen} =
      Enum.reduce(ergebnisse, {0, []}, fn
        {:ok, n}, {count, offen} -> {count + n, offen}
        {:offen, key}, {count, offen} -> {count, [key | offen]}
      end)

    {count, Enum.reverse(offen)}
  end

  @doc """
  Der Abschluss-Befund über die ganze Sitzung.

  Er nennt die Zahl, nach der man im Dashboard sucht („wie viele Spuren
  fehlen?"), und sagt zu, dass das Audio nicht weggeräumt ist. Ohne ihn stünden
  dort nur N Einzelfehler, aus denen niemand den Zustand der Sitzung ablesen
  kann.
  """
  @spec melde_offene(String.t() | nil, [String.t()], non_neg_integer()) :: :ok
  def melde_offene(campaign_id, offen, gesamt) do
    Logger.error(
      "Transcribe: #{length(offen)} von #{gesamt} Spuren offen (spuren_unvollstaendig): " <>
        Enum.join(offen, ", ")
    )

    Stage1Status.notify(
      campaign_id,
      "failed",
      "spuren_unvollstaendig: #{length(offen)} von #{gesamt} Spuren wurden nicht " <>
        "transkribiert (#{Enum.join(offen, ", ")}). Ihr Audio bleibt liegen und wird " <>
        "erneut versucht; die übrigen Spuren sind im Protokoll."
    )

    :ok
  end

  defp melde_abbruch(campaign_id, key, grund, stacktrace) do
    Logger.error(
      "Transcribe: Spur #{key} abgebrochen (spur_abgebrochen): #{grund}\n" <>
        Exception.format_stacktrace(stacktrace)
    )

    Stage1Status.notify(
      campaign_id,
      "failed",
      "Spur #{key} nicht transkribiert: spur_abgebrochen — #{grund}. " <>
        "Die übrigen Spuren laufen weiter; das Audio dieser Spur bleibt liegen " <>
        "und wird vom Wiederherstellungs-Lauf erneut versucht."
    )
  end
end
