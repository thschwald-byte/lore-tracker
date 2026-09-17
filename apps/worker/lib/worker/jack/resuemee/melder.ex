defmodule Worker.Jack.Resuemee.Melder do
  @moduledoc """
  Meldet den Fortschritt eines Resümee-Laufs ans Laufband (J5, #1209, B4) —
  das Gegenstück zu `Worker.Jack.Melder`. Der Halter des Laufs
  (`Worker.Jack.Resuemee.Halter`) schickt beim Start und nach jedem
  Werkzeugaufruf `{:jack_resuemee_stand, abbild}`
  (`Worker.Jack.Resuemee.Stand.abbild/1`); daraus zählt der Melder
  (`zaehlung/1`):

    * im **Überblick** die gelesenen Fakten dieser Sitzung — gesamt ist die
      Zahl ihrer Fakten;
    * in der **Durchsicht** die entschiedenen Absätze des laufenden
      Durchgangs (alle, deren Status nicht `offen` ist), mit dem Durchgang —
      das Band zeigt dann „Durchgang 2“ und „1/3“. Ändert sich der Durchgang
      oder die Zahl der Absätze (einer wurde gestrichen), beginnt die Zählung
      neu;
    * im **Schreiben** nichts: wie viele Absätze es werden, steht vorher
      nicht fest, und eine Zahl ohne Gesamtzahl ist keine Auskunft.

  Gemeldet wird über den Rückruf `melde` (`:melde_stufe`, siehe
  `Worker.Jack.Resuemee.laufen/2`), in derselben Form wie beim Fakten-Jack:
  `{:zaehlung, gesamt, durchgang}`, dann je Einheit `{:gelesen, n, durchgang}`.

  Seit J6 (#1210, E4) meldet er auch die Läufe des Epos-Jack: dessen Halter
  schickt dieselbe Nachricht mit demselben Abbild (`"jack" => "epos"`,
  `Worker.Jack.Epos.Notizen.abbild/1`), gezählt wird genauso. `gemeldet/5`
  fährt einen Lauf als Stufe — für beide Jacks.

  **Ein Melder je Lauf**, aus demselben Grund wie beim Fakten-Jack: ein
  verspäteter Stand des vorigen Laufs landet bei dessen Melder statt bei der
  nächsten Stufe. Der Halter kennt nur einen Beobachter; jeder Stand geht
  deshalb an `:weiter` (die Laufsicht) weiter.
  """

  @doc """
  Startet den Melder für einen Lauf: `stufe` (Name aus
  `Shared.PipelineStufen`). Liefert die Pid — sie gehört als
  `:stand_beobachter` in den Lauf. Option `:weiter` (Pid oder `nil`).
  """
  @spec start((String.t(), term() -> term()), String.t(), keyword()) :: pid()
  def start(melde, stufe, opts \\ []) do
    m = %{melde: melde, stufe: stufe, weiter: opts[:weiter]}
    spawn_link(fn -> schleife(m, %{abschnitt: nil, gemeldet: MapSet.new()}) end)
  end

  @doc "Beendet den Melder, nachdem er alles Empfangene gemeldet hat (`Worker.Jack.Melder.stopp/1`)."
  @spec stopp(pid()) :: :ok
  defdelegate stopp(pid), to: Worker.Jack.Melder

  @doc """
  Fährt einen Lauf als Stufe des Laufbands: `melde.(stufe, :beginn)`, ein
  Melder für die Zählung (er reicht jeden Stand an den `:stand_beobachter`
  aus `opts` weiter), der Lauf selbst (`lauf.(opts)` mit dem Melder als
  `:stand_beobachter`), dann `melde.(stufe, {:ende, :ok | {:error, grund}})`.
  `tag` markiert den Fehler fürs Band — `{:error, {tag, grund}}` —, damit er
  in `/admin/errors` eine eigene Klasse bekommt (die Durchsicht). Liefert das
  Ergebnis des Laufs unverändert.

  Gemeinsam für den Resümee-Jack und den Epos-Jack (J6, #1210): die Abbilder
  beider Halter tragen dieselben Felder, aus denen `zaehlung/1` zählt.
  Wirft der Lauf, wird der Melder trotzdem beendet; das Ende meldet dann der
  Aufrufer (`Worker.Jack.Epos.Pipeline.kapitel/6`).
  """
  @spec gemeldet(String.t(), (String.t(), term() -> term()), keyword(), (keyword() -> term())) ::
          term()
  def gemeldet(stufe, melde, opts, lauf, tag \\ nil) do
    melde.(stufe, :beginn)
    melder = start(melde, stufe, weiter: opts[:stand_beobachter])

    ergebnis =
      try do
        lauf.(Keyword.put(opts, :stand_beobachter, melder))
      after
        stopp(melder)
      end

    melde.(stufe, {:ende, fuers_band(ergebnis, tag)})
    ergebnis
  end

  defp fuers_band({:ok, _}, _tag), do: :ok
  defp fuers_band({:error, grund}, nil), do: {:error, grund}
  defp fuers_band({:error, grund}, tag), do: {:error, {tag, grund}}

  @doc """
  Was ein Stand zu zählen hergibt: `{gesamt, durchgang, fertige_einheiten}`
  oder `nil` (Schreiben, oder ein Abbild ohne die nötigen Felder). Die
  Einheiten sind Nummern ab 1 — gelesene Fakten im Überblick, entschiedene
  Absätze in der Durchsicht.
  """
  @spec zaehlung(map()) :: {non_neg_integer(), pos_integer() | nil, [pos_integer()]} | nil
  def zaehlung(%{"lauf" => "ueberblick", "fakten" => gesamt, "gelesen" => gelesen})
      when is_integer(gesamt) and is_integer(gelesen),
      do: {gesamt, nil, Enum.to_list(1..min(gelesen, gesamt)//1)}

  def zaehlung(%{"lauf" => "durchsicht", "durchsicht" => %{"status" => status} = d})
      when is_list(status) do
    fertig = for {s, i} <- Enum.with_index(status, 1), s != "offen", do: i
    {length(status), d["durchgang"], fertig}
  end

  def zaehlung(_abbild), do: nil

  defp schleife(m, z) do
    receive do
      {:jack_resuemee_stand, _} = nachricht -> schleife(m, stand(m, z, nachricht))
      :stopp -> nachlesen(m, z)
      _anderes -> schleife(m, z)
    end
  end

  # Was vor dem Stopp schon im Postfach lag, gehört noch zu diesem Lauf.
  defp nachlesen(m, z) do
    receive do
      {:jack_resuemee_stand, _} = nachricht -> nachlesen(m, stand(m, z, nachricht))
    after
      0 -> :ok
    end
  end

  defp stand(m, z, {:jack_resuemee_stand, abbild} = nachricht) do
    if m.weiter, do: send(m.weiter, nachricht)

    case zaehlung(abbild) do
      nil -> z
      {gesamt, durchgang, fertig} -> melden(m, z, {gesamt, durchgang}, fertig)
    end
  end

  defp melden(m, z, {gesamt, durchgang} = abschnitt, fertig) do
    z =
      if abschnitt == z.abschnitt do
        z
      else
        m.melde.(m.stufe, {:zaehlung, gesamt, durchgang})
        %{abschnitt: abschnitt, gemeldet: MapSet.new()}
      end

    neu = Enum.reject(fertig, &MapSet.member?(z.gemeldet, &1))
    Enum.each(neu, &m.melde.(m.stufe, {:gelesen, &1, durchgang}))
    %{z | gemeldet: Enum.into(neu, z.gemeldet)}
  end
end
