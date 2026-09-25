defmodule Worker.Jack.Resuemee.Halter do
  @moduledoc """
  Hält den Stand eines Resümee-Laufs zwischen den Werkzeugaufrufen — das
  Muster von `Worker.Jack.Halter`: die Laufzeit kennt Werkzeuge nur als
  Funktionen, der Stand liegt in diesem Prozess, und die Module unter
  `Worker.Jack.Resuemee` bleiben rein.

  Ein eigener Halter statt des Fakten-Jack-Halters, weil jener zwei Teile
  mitbringt, die nur dort Sinn haben: `Worker.Jack.Probieren` (kennt
  `aussage` und prüft `suche` gegen eingereichte Aussagen) und
  `Worker.Jack.Abbild` (schreibt den Bestand in die Dateien des Spikes).

  Beim Start und nach jedem Aufruf bekommt ein Beobachter (Option
  `:beobachter`) den Stand als `{:jack_resuemee_stand, abbild}`
  (`Worker.Jack.Resuemee.Stand.abbild/1`) — eine eigene Nachricht, damit
  eine Laufsicht, die nur den Fakten-Jack kennt, sie überhört statt sie
  falsch zu lesen. Mit der Option `:abbild` (`fn stand -> map end`) baut ein
  anderer Jack sein eigenes Abbild — der Epos-Jack (#1210) mit
  `"jack" => "epos"` (`Worker.Jack.Epos.Notizen.abbild/1`).

  Wirft ein Werkzeug oder liefert es keinen Stand zurück, bleibt der Stand,
  wie er war, und das Ergebnis ist ein Fehler mit der Meldung.

  **Geprüft wird der TYP, nicht der Inhalt** (bob, 19.09.2026). Ein Werkzeug,
  das einen frischen Stand desselben Moduls zurückgibt statt des
  fortgeschriebenen, kommt durch: Die Struct stimmt, die Buchführung darin ist
  zurückgesetzt. Bei einem Jack, dessen Abschlussregel daran hängt (der
  Zeit-Jack zählt gelesene Zeilen), hiesse das je nach Richtung ein
  unerreichbares `fertig()` oder eine Buchführung, die nichts mehr belegt. Das
  kann dieser Halter nicht sehen — er kennt den Typ nicht, das ist gerade
  sein Zweck. Wer ein Werkzeug schreibt, reicht den **übergebenen** Stand
  fort; ein neu gebauter ist ein Fehler, den erst die Werkzeugtests fangen.
  """

  alias Worker.Jack.Resuemee.Stand

  @doc """
  Startet den Halter mit einem Stand. Optionen: `:beobachter`, `:abbild`.

  **Der Stand muss kein `Resuemee.Stand` sein** (#1247): Der Halter macht
  nichts, was diesen Typ kennt — er hält, ruft auf und meldet. Der Zeit-Jack
  bringt seinen eigenen Stand mit und gibt sein Abbild über `:abbild` mit,
  wie der Epos-Jack es seit #1210 tut. Ein zweiter Halter wäre eine Kopie von
  sechzig Zeilen, die beim nächsten Umbau auseinanderliefe.
  """
  @spec start_link(struct(), keyword()) :: Agent.on_start()
  def start_link(s, opts \\ []) when is_struct(s) do
    abbild = opts[:abbild] || standard_abbild!(s)

    Agent.start_link(fn ->
      z = %{
        stand: s,
        modul: s.__struct__,
        beobachter: opts[:beobachter],
        abbild: abbild,
        nach_aufruf: opts[:nach_aufruf]
      }

      melden(z)
      z
    end)
  end

  # **`:nach_aufruf` läuft nach JEDEM Werkzeugaufruf, im Halter.**
  #
  # `fn stand -> stand end` — der Zeit-Jack sichert damit seinen Stand in die
  # Datenbank (Maintainer, 24.09.2026: „jeder werkzeugaufruf speichert in
  # db"), statt erst am Ende des Laufs zu veröffentlichen. Zwei Läufe von je
  # etwa einer Stunde sind an einem Tag verloren gegangen, weil sie das Ende
  # nie erreichten.
  #
  # Der Halter weiss dabei NICHTS über das Speichern: Er ist geteilt
  # (Resümee, Epos, Chronik, Zeit), und ein Jack-spezifischer Schreibpfad hier
  # wäre dieselbe Auffangzweig-Klasse, die schon zweimal Läufe gekostet hat
  # (#1211). Wer nichts mitgibt, bekommt das bisherige Verhalten.
  #
  # Läuft es synchron im Agent? Ja, mit Absicht: Zwei Speicherungen
  # gleichzeitig könnten dieselbe Zeile in umgekehrter Reihenfolge schreiben,
  # und die Ordnung zweier UUIDv7 innerhalb einer Millisekunde ist nicht
  # garantiert. Der Aufrufer wartet ohnehin auf die Antwort des Werkzeugs.
  defp nach_aufruf(%{nach_aufruf: nil} = z), do: z

  defp nach_aufruf(%{nach_aufruf: fun} = z) when is_function(fun, 1) do
    %{z | stand: fun.(z.stand)}
  rescue
    e ->
      require Logger
      Logger.error("Halter: nach_aufruf gescheitert: " <> Exception.message(e))
      z
  end

  # **Der Default muss zum Stand passen, nicht zum Modul.** Solange der Guard
  # `%Stand{} = s` hiess, war `&Stand.abbild/1` sicher: Es kam nur ein
  # Resümee-Stand herein. Der Guard war damit nicht bloss eine Typprüfung,
  # sondern die Schranke, die den Default gültig machte — mit `is_struct/1`
  # fiele sie, und ein fremder Stand ohne `:abbild` liefe in den
  # `FunctionClauseError` von `Stand.abbild/1`.
  #
  # Und zwar an der schlechtestmöglichen Stelle: `melden/1` ist ohne
  # Beobachter ein `:ok`, das Abbild würde also in Tests und Messläufen NIE
  # gerufen. Mit Beobachter — im Betrieb, wenn die Laufsicht zusieht — wirft
  # es beim ersten Melden, und das steht in `Agent.start_link`: der Halter
  # stürbe beim Start und der ganze Lauf mit ihm. Grün im Test, tot in Prod,
  # und nur dann tot, wenn jemand zusieht. (Review-Fund, 19.09.2026; dieselbe
  # Klasse wie der Auffangzweig in `Stand.abschnitte/1`, der am 18.09. die
  # Chronik-Abschnitte still durch die des Resümees ersetzte.)
  #
  # Deshalb wird hier aufgelöst, **bevor** der Agent startet: Jeder Stand
  # bringt sein eigenes `abbild/1` mit, und wer keins hat, scheitert laut und
  # sofort statt beim ersten Beobachter.
  defp standard_abbild!(%Stand{}), do: &Stand.abbild/1

  defp standard_abbild!(s) do
    modul = s.__struct__
    Code.ensure_loaded(modul)

    if function_exported?(modul, :abbild, 1) do
      &modul.abbild/1
    else
      raise ArgumentError,
            "#{inspect(modul)} hat kein abbild/1 — der Halter braucht dann die Option " <>
              ":abbild. Ohne sie fiele die Laufsicht auf das Abbild des Resümee-Jack " <>
              "zurück und zeigte Werte, die es in diesem Lauf nicht gibt (#1211)."
    end
  end

  @doc """
  Der aktuelle Stand.

  **Der Rückgabetyp ist `struct()`, nicht `Stand.t()`** (#1247): Welchen Stand
  dieser Halter hält, weiss er nicht — das ist gerade der Punkt der
  Lockerung oben. Die alten Specs behaupteten das Gegenteil, und der
  Dialyzer las daraus, dass `Worker.Jack.Zeit.Werkzeuge.fuer/1` niemals
  zurückkehren kann. Eine Spec, die mehr verspricht als die Funktion, ist
  kein Schutz, sondern eine falsche Auskunft an jeden, der ihr glaubt.
  """
  @spec stand(pid()) :: struct()
  def stand(halter), do: Agent.get(halter, & &1.stand)

  @doc """
  Liest etwas Kleines aus dem Stand, ohne ihn zu ändern: `fun` läuft im
  Halter, zurück kommt nur ihr Ergebnis — nicht der ganze Stand, der samt
  geladener Mitschnitte früherer Sitzungen groß sein kann (#1210). Wirft
  `fun`, ist das Ergebnis `:fehler` und der Halter lebt weiter.
  """
  @spec lesen(pid(), (struct() -> term())) :: term()
  def lesen(halter, fun) do
    Agent.get(
      halter,
      fn z ->
        try do
          fun.(z.stand)
        rescue
          _ -> :fehler
        end
      end,
      :infinity
    )
  end

  @doc """
  Führt `fun` (`fn stand, argumente -> {stand, ergebnis} end`) auf dem Stand
  aus, übernimmt den neuen Stand und liefert das Ergebnis.
  """
  @spec aufrufen(pid(), (struct(), map() -> {struct(), term()}), map()) :: term()
  def aufrufen(halter, fun, argumente) do
    Agent.get_and_update(
      halter,
      fn z ->
        {s, ergebnis} = sicher(fun, z.stand, z.modul, argumente)
        z = nach_aufruf(%{z | stand: s})
        melden(z)
        {ergebnis, z}
      end,
      :infinity
    )
  end

  # **Geprüft wird gegen den Stand, den dieser Halter hält** (#1247) — nicht
  # gegen `Resuemee.Stand`. Der feste Match war die zweite Hälfte derselben
  # Lockerung wie oben beim Guard, und sie blieb liegen: Ein Zeit-Werkzeug
  # lieferte seinen korrekten Stand, fiel hier durch, und der Aufrufer bekam
  # `{:error, "Werkzeug lieferte keinen Stand: ..."}`. Für das Modell ist das
  # nicht von „dir fehlt noch etwas" zu unterscheiden — es hätte den Lauf in
  # die Wiederholung geschickt (#1211: 28 von 51 Runden an genau dieser
  # Klasse). Die Schranke bleibt also, sie zeigt nur auf das richtige Modul:
  # ein Werkzeug, das die Struct eines fremden Jack zurückgibt, wird weiter
  # abgewiesen.
  defp sicher(fun, s, modul, argumente) do
    case fun.(s, argumente) do
      {neu, ergebnis} when is_struct(neu, modul) ->
        {neu, ergebnis}

      anderes ->
        {s, {:error, "Werkzeug lieferte keinen Stand: #{inspect(anderes, limit: 20)}"}}
    end
  rescue
    e -> {s, {:error, Exception.message(e)}}
  end

  defp melden(%{beobachter: nil}), do: :ok

  defp melden(%{stand: s, beobachter: b, abbild: abbild}),
    do: send(b, {:jack_resuemee_stand, abbild.(s)})
end
