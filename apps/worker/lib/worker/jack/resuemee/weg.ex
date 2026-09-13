defmodule Worker.Jack.Resuemee.Weg do
  @moduledoc """
  Die GLIEDERUNG als **Weg der Gruppe** durch die Sitzung (J5, #1209):
  Station für Station, vom Anfang bis zum Ende. Maintainer, 13.09.2026: „Der
  Weg, den die Gruppe genommen hat, muss aus dem Resümee ersichtlich sein.“
  Anlass war ein Lauf mit 73 Wörtern, in dem der Ablauf der Sitzung nur
  bruchstückhaft erkennbar war. Pur: Stand hinein, Stationen, Zahlen oder
  Text heraus.

    * **Im Überblick ein Hinweis, keine Ablehnung** (`spanne/1`,
      `hinweis/1`): von welchem bis zu welchem Block die Fakten dieser
      Sitzung reichen, die die GLIEDERUNG nennt, verglichen mit der Spanne
      aller Fakten der Sitzung, und ob die Stationen in Blockreihenfolge
      stehen. Die Blöcke eines Fakts sind die Nummern seiner Belege im
      Mitschnitt (`bloecke`). **Eine Station steht dort, wo ihr frühester
      Beleg liegt** — benannte Wahl: eine Station, die ein spätes Ereignis mit
      einem frühen Anlass verbindet, rückt dadurch nach vorn. Eine Rückblende
      weicht bewusst von der Blockreihenfolge ab; deshalb ist es ein Hinweis.
    * **Im Schreiben eine Pflicht** (`ohne_satz/1`, `hindernisse/1`): jede
      Station trägt mindestens ein Satz, der einen ihrer Fakten **dieser**
      Sitzung nennt. `fertig` lehnt ab, solange eine fehlt
      (`Worker.Jack.Resuemee.Abschluss`); ein Satz darf mehrere Stationen
      tragen, wenn er ihre Fakten nennt.
    * **In der Durchsicht bleibt der Weg vollständig** (`verloren/2`): ein
      Absatz wird nicht gestrichen oder ersetzt, wenn danach eine Station,
      die vorher getragen war, keinen Satz mehr hätte
      (`Worker.Jack.Resuemee.Durchsicht`).

  **Eine Station nennt einen Fakt dieser Sitzung** — `notiz` lehnt einen
  Gliederungspunkt ohne ab (`Worker.Jack.Resuemee.Notizen`). Kommt eine
  Ablage mit einem solchen Punkt von außen (etwa aus einem älteren Lauf),
  zählt er hier nicht: er ließe sich nie tragen, und `fertig` käme nie durch.

  **Ehrliche Grenze:** geprüft wird, dass ein Satz einen Fakt der Station
  nennt, nicht, dass er die Station erzählt — wie überall im Resümee-Jack
  hängt die Prüfung an den genannten Fakten, nicht am Wortlaut.
  """

  alias Worker.Jack.Resuemee.Stand

  @doc """
  Die Fakten dieser Sitzung, die ein Gliederungspunkt nennt, ohne doppelte.
  IDs, die es nicht (mehr) gibt, fallen weg.
  """
  @spec eigene(Stand.t(), Stand.notiz()) :: [Stand.fakt()]
  def eigene(%Stand{} = s, punkt) do
    for id <- List.wrap(punkt.fakten),
        f = Stand.fakt(s, id),
        f != nil,
        Stand.diese_sitzung?(s, f),
        uniq: true,
        do: f
  end

  @doc """
  Die Stationen, die sich tragen lassen: die Punkte der GLIEDERUNG, die
  mindestens einen Fakt dieser Sitzung nennen (Moduldoc), in ihrer
  Reihenfolge.
  """
  @spec pruefbar(Stand.t()) :: [Stand.notiz()]
  def pruefbar(%Stand{} = s),
    do: Enum.filter(Stand.abschnitt(s, "GLIEDERUNG"), &(eigene(s, &1) != []))

  @doc """
  Die Stationen der GLIEDERUNG, von denen kein Satz des Entwurfs einen Fakt
  dieser Sitzung nennt, in ihrer Reihenfolge. Stationen ohne Fakt dieser
  Sitzung zählen nicht (`pruefbar/1`).
  """
  @spec ohne_satz(Stand.t()) :: [Stand.notiz()]
  def ohne_satz(%Stand{} = s) do
    zitiert = Stand.im_text(s)

    Enum.reject(pruefbar(s), fn p ->
      Enum.any?(eigene(s, p), &MapSet.member?(zitiert, &1.id))
    end)
  end

  @doc """
  Die Stationen, die im Stand `vorher` einen Satz hatten und im Stand
  `nachher` keinen mehr. Eine Station, die schon vorher keinen hatte, zählt
  nicht — ein von außen eingereichter Entwurf soll sich nicht festfahren.
  """
  @spec verloren(Stand.t(), Stand.t()) :: [Stand.notiz()]
  def verloren(%Stand{} = vorher, %Stand{} = nachher) do
    schon = MapSet.new(ohne_satz(vorher), & &1.schluessel)
    Enum.reject(ohne_satz(nachher), &MapSet.member?(schon, &1.schluessel))
  end

  @doc "Stationen als Text: `„1“ — Zeile; „3“ — Zeile`."
  @spec text([Stand.notiz()]) :: String.t()
  def text(punkte), do: Enum.map_join(punkte, "; ", &"„#{&1.schluessel}“ — #{&1.zeile}")

  @doc "Stationen für Abbild und Zählwerte, JSON-fähig: je `%{\"schluessel\", \"zeile\"}`."
  @spec abbild([Stand.notiz()]) :: [map()]
  def abbild(punkte),
    do: Enum.map(punkte, &%{"schluessel" => &1.schluessel, "zeile" => &1.zeile})

  @doc """
  Die Zeile für den Stand des Schreibens und `entwurf()`: wie viele Stationen
  einen Satz haben und welche noch keinen. Gezählt werden die Stationen, die
  sich tragen lassen (`pruefbar/1`); `nil`, wenn es keine gibt.
  """
  @spec stand_zeile(Stand.t()) :: String.t() | nil
  def stand_zeile(%Stand{} = s) do
    n = length(pruefbar(s))

    case ohne_satz(s) do
      _ when n == 0 ->
        nil

      [] ->
        "Weg der Gruppe: jede der #{n} Stationen deiner GLIEDERUNG hat einen Satz."

      fehlen ->
        "Weg der Gruppe: #{n - length(fehlen)} von #{n} Stationen deiner GLIEDERUNG haben " <>
          "einen Satz. Noch ohne Satz: #{text(fehlen)}."
    end
  end

  @doc "Was der Weg `fertig` im Schreiben entgegenhält; `[]`, wenn jede Station getragen ist."
  @spec hindernisse(Stand.t()) :: [String.t()]
  def hindernisse(%Stand{} = s) do
    case ohne_satz(s) do
      [] ->
        []

      fehlen ->
        [
          "Diese Stationen deiner GLIEDERUNG erzählt noch kein Satz: #{text(fehlen)}. Der Weg " <>
            "der Gruppe muss aus dem Resümee ersichtlich sein: gib jeder Station mindestens " <>
            "einen Satz oder Satzteil, der einen ihrer Fakten dieser Sitzung nennt."
        ]
    end
  end

  # ─── Spanne und Reihenfolge (Überblick) ───────────────────────────────

  @doc """
  Die Spanne der GLIEDERUNG in Blocknummern:

    * `gliederung` — `{von, bis}` über die Blöcke der Fakten dieser Sitzung,
      die eine Station nennt; `nil`, wenn keiner eine Blocknummer trägt;
    * `sitzung` — `{von, bis}` über alle Fakten dieser Sitzung; `nil` ohne
      Blocknummern;
    * `reihenfolge` — `:ja` (die Stationen stehen in Blockreihenfolge, gemessen
      am frühesten Beleg je Station), `{:nein, {früher_angelegt, block},
      {später_angelegt, block}}` für das erste Paar, das rückwärts springt,
      oder `:offen` (keine Station mit Blocknummer).
  """
  @spec spanne(Stand.t()) :: %{
          gliederung: tuple() | nil,
          sitzung: tuple() | nil,
          reihenfolge: term()
        }
  def spanne(%Stand{} = s) do
    stationen =
      for p <- Stand.abschnitt(s, "GLIEDERUNG"),
          do: {p, Enum.flat_map(eigene(s, p), & &1.bloecke)}

    %{
      gliederung: bereich(Enum.flat_map(stationen, &elem(&1, 1))),
      sitzung: bereich(Enum.flat_map(s.fakten, & &1.bloecke)),
      reihenfolge: reihenfolge(for {p, [_ | _] = b} <- stationen, do: {p, Enum.min(b)})
    }
  end

  defp bereich([]), do: nil
  defp bereich(l), do: Enum.min_max(l)

  defp reihenfolge([]), do: :offen

  defp reihenfolge(stationen) do
    stationen
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find(fn [{_, a}, {_, b}] -> b < a end)
    |> case do
      nil -> :ja
      [vorn, hinten] -> {:nein, vorn, hinten}
    end
  end

  @doc """
  Der Hinweis zur Spanne für `notiz`, `notizen_lesen`, den Stand-Text und
  `fertig` im Überblick — ein Fingerzeig, keine Ablehnung. `nil` ohne
  GLIEDERUNG oder ohne Blocknummern in der Sitzung.
  """
  @spec hinweis(Stand.t()) :: String.t() | nil
  def hinweis(%Stand{} = s) do
    if Stand.abschnitt(s, "GLIEDERUNG") == [], do: nil, else: hinweis_text(spanne(s))
  end

  defp hinweis_text(%{sitzung: nil}), do: nil

  defp hinweis_text(%{gliederung: nil, sitzung: {a, b}}),
    do:
      "Die Fakten deiner GLIEDERUNG tragen keine Blocknummern; die Fakten dieser Sitzung " <>
        "reichen von Block #{a} bis #{b}."

  defp hinweis_text(%{gliederung: {g1, g2}, sitzung: {a, b}, reihenfolge: r}) do
    Enum.join(
      [
        "Die Fakten deiner GLIEDERUNG reichen von Block #{g1} bis #{g2}, die Fakten dieser " <>
          "Sitzung von Block #{a} bis #{b}."
      ] ++ ausserhalb(g1, g2, a, b) ++ reihenfolge_text(r),
      " "
    )
  end

  defp ausserhalb(g1, g2, a, b) do
    teile =
      Enum.reject(
        [if(a < g1, do: "vor Block #{g1}"), if(g2 < b, do: "nach Block #{g2}")],
        &is_nil/1
      )

    case teile do
      [] ->
        []

      _ ->
        [
          "#{gross(Enum.join(teile, " und "))} liegen Fakten, die keine Station nennt — der " <>
            "Weg der Gruppe reicht vom Anfang bis zum Ende der Sitzung."
        ]
    end
  end

  # Nur den ersten Buchstaben groß — `String.capitalize/1` machte aus
  # „nach Block 3“ „Nach block 3“.
  defp gross(t) do
    {erster, rest} = String.split_at(t, 1)
    String.upcase(erster) <> rest
  end

  defp reihenfolge_text(:ja), do: ["Die Stationen stehen in Blockreihenfolge."]
  defp reihenfolge_text(:offen), do: []

  defp reihenfolge_text({:nein, {p, a}, {q, b}}),
    do: [
      "Die Stationen stehen nicht in Blockreihenfolge: „#{q.schluessel}“ beginnt bei Block " <>
        "#{b}, vor „#{p.schluessel}“ (Block #{a}), steht aber dahinter. Die Gliederung " <>
        "erzählt den Weg in der Reihenfolge der Handlung; eine Rückblende darf davon abweichen."
    ]
end
