defmodule Worker.Jack.Resuemee.Laenge do
  @moduledoc """
  Die Länge des Resümees beim Schreiben und in der Durchsicht (J5, #1209):
  **Ziel** und **Obergrenze**. Pur: Stand hinein, Text oder Entscheidung
  heraus.

  Maintainer, 13.09.2026: „Der Weg, den die Gruppe genommen hat, muss aus dem
  Resümee ersichtlich sein — wenn die 75 Wörter nicht reichen für die grobe
  Abdeckung, darf man bis zu maximal dem Doppelten erweitern.“ Daraus:

    * `max_woerter` (je Kampagne aus „Stil setzen“, Standard 150) ist das
      **Ziel**.
    * Die **Obergrenze** ist das Doppelte
      (`Worker.Jack.Resuemee.Stand.obergrenze/1`, gerechnet in
      `Shared.ResuemeeLaenge.hoechstens/1`, damit Hub und Worker dieselbe Zahl
      haben).
    * Bis zum Ziel ist nichts zu tun. **Zwischen Ziel und Obergrenze** verlangt
      `fertig` im Schreiben die `laenge_begruendung` — ein Pflichtfeld, das
      bis zum Ziel leer bleiben darf. Sie steht im Journal und in den
      Zählwerten. **Über der Obergrenze** lehnt `fertig` ab.
    * `absatz` trägt auch über dem Ziel und über der Obergrenze ein (sonst
      ließe sich nie umformulieren); die Antwort warnt, über der Obergrenze
      deutlich (`warnung/1`).
    * Die Durchsicht lehnt eine Ersetzung ab, mit der der Entwurf über der
      Obergrenze läge **und** länger würde (`zu_lang?/2`) — der Entwurf aus
      dem Schreiben liegt darunter (`fertig` hat es geprüft); nur ein von
      außen eingereichter Entwurf, der schon darüber liegt, darf so noch
      gekürzt werden.

  Gezählt wird wie in `Worker.Jack.Resuemee.Stand.woerter/1`: alle Satztexte
  und Absatztitel, getrennt durch Leerraum.

  **Die Wortzahl je Absatz steht in den Antworten** (`je_absatz/1`,
  `absatz_woerter/2`): `absatz`, `absatz_ersetzen`, `absatz_streichen`,
  `entwurf()`, der Stand-Text und `durchsicht(nummer)` nennen sie. Anlass
  (13.09.2026, Teststage): im ersten Lauf mit Obergrenze zählte Jack die
  Wörter je Absatz in der Denkspur selbst nach, eine Modellrunde brauchte
  dafür 21 Minuten und 33 600 Ausgabe-Token, der Lauf 72 Minuten. Das
  Werkzeug zählt ohnehin — es sagt es jetzt (Maintainer).

  **Ehrliche Grenze:** ob die Begründung trägt, prüft niemand — sie macht die
  Überschreitung nachlesbar, nicht richtig.
  """

  alias Worker.Jack.Resuemee.Stand

  @doc """
  Die Warnung in den Antworten von `absatz`, `absatz_ersetzen` und
  `absatz_streichen`; `nil` bis zum Ziel.
  """
  @spec warnung(Stand.t()) :: String.t() | nil
  def warnung(%Stand{} = s) do
    cond do
      Stand.ueber_obergrenze?(s) ->
        "Der Entwurf hat jetzt #{Stand.woerter_text(s)} — ÜBER DER OBERGRENZE. fertig() lehnt " <>
          "ab, solange er darüber liegt: kürze ihn, fass Sätze zusammen und behalte jede " <>
          "Station des Weges."

      Stand.ueber_ziel?(s) ->
        "Der Entwurf hat jetzt #{Stand.woerter_text(s)} — über dem Ziel. Bis " <>
          "#{Stand.obergrenze(s)} Wörter geht es, wenn der Weg der Gruppe sonst nicht erkennbar " <>
          "wird; dann schreibst du in fertig() die laenge_begruendung. Reicht das Ziel für den " <>
          "Weg, kürze auf #{s.max_woerter} Wörter."

      true ->
        nil
    end
  end

  @doc "Die Längen-Zeile für den Stand-Text und `entwurf()`, mit der Wortzahl je Absatz."
  @spec zeile(Stand.t()) :: String.t()
  def zeile(%Stand{} = s) do
    "Länge: #{Stand.woerter_text(s)}" <>
      cond do
        Stand.ueber_obergrenze?(s) ->
          " — über der Obergrenze, kürze ihn."

        Stand.ueber_ziel?(s) ->
          " — über dem Ziel; bis #{Stand.obergrenze(s)} nur, wenn der Weg der Gruppe es " <>
            "braucht, mit laenge_begruendung in fertig()."

        true ->
          "."
      end <> je_absatz_text(s)
  end

  defp je_absatz_text(%Stand{entwurf: []}), do: ""
  defp je_absatz_text(s), do: " Je Absatz: " <> Enum.join(je_absatz(s), ", ") <> "."

  @doc """
  Die Wörter je Absatz als Liste `"Absatz n: k Wörter"`, in Entwurfsreihenfolge
  — für die Antworten der Werkzeuge, damit Jack nicht selbst zählt.
  """
  @spec je_absatz(Stand.t()) :: [String.t()]
  def je_absatz(%Stand{entwurf: e} = s),
    do: for({_, n} <- Enum.with_index(e, 1), do: "Absatz #{n}: #{anzahl(absatz_woerter(s, n))}")

  @doc "Eine Wortzahl in Worten: „1 Wort“, sonst „n Wörter“."
  @spec anzahl(non_neg_integer()) :: String.t()
  def anzahl(1), do: "1 Wort"
  def anzahl(n), do: "#{n} Wörter"

  @doc "Die Wörter von Absatz `nr` (ab 1), gezählt wie `Worker.Jack.Resuemee.Stand.woerter/1`."
  @spec absatz_woerter(Stand.t(), pos_integer()) :: non_neg_integer()
  def absatz_woerter(%Stand{entwurf: e}, nr), do: Stand.woerter_in([Enum.at(e, nr - 1)])

  @doc """
  Die Begründung aus den Argumenten von `fertig`, ohne Leerraum am Rand;
  leer oder fehlend ist `nil`.
  """
  @spec begruendung(map()) :: String.t() | nil
  def begruendung(p) do
    case p |> Map.get("laenge_begruendung") |> Kernel.||("") |> to_string() |> String.trim() do
      "" -> nil
      t -> t
    end
  end

  @doc """
  Was die Länge `fertig` im Schreiben entgegenhält: über der Obergrenze
  immer, über dem Ziel ohne `laenge_begruendung`. Sonst `[]`.
  """
  @spec hindernisse(Stand.t(), map()) :: [String.t()]
  def hindernisse(%Stand{} = s, p) do
    cond do
      Stand.ueber_obergrenze?(s) ->
        [
          "Der Entwurf hat #{Stand.woerter_text(s)} (gezählt: alle Sätze und Absatztitel). Über " <>
            "#{Stand.obergrenze(s)} Wörter geht es nicht: kürze ihn mit absatz_ersetzen() und " <>
            "absatz_streichen() — fass Sätze zusammen und behalte jede Station des Weges. Die " <>
            "übrigen Fakten bleiben im Faktenbestand; ein Handlungsbogen, den das Resümee dann " <>
            "nicht mehr erzählt, kommt mit dem Grund in ausgelassen."
        ]

      Stand.ueber_ziel?(s) and begruendung(p) == nil ->
        [
          "Der Entwurf hat #{Stand.woerter_text(s)} (gezählt: alle Sätze und Absatztitel) und " <>
            "liegt über dem Ziel. Braucht der Weg der Gruppe diese Wörter, schreib in " <>
            "laenge_begruendung in einem Satz, warum. Reicht das Ziel für den Weg, kürze auf " <>
            "#{s.max_woerter} Wörter."
        ]

      true ->
        []
    end
  end

  @doc """
  In der Durchsicht: ob eine Ersetzung abgelehnt wird — der Entwurf läge
  danach über der Obergrenze und wäre länger als vorher.
  """
  @spec zu_lang?(Stand.t(), Stand.t()) :: boolean()
  def zu_lang?(%Stand{} = vorher, %Stand{} = nachher),
    do: Stand.ueber_obergrenze?(nachher) and Stand.woerter(nachher) > Stand.woerter(vorher)

  @doc """
  Wie viele Wörter Absatz `nr` (ab 1) haben darf, damit der Entwurf unter der
  Obergrenze bleibt — mindestens so viele, wie er jetzt hat.
  """
  @spec platz(Stand.t(), pos_integer()) :: non_neg_integer()
  def platz(%Stand{} = s, nr) do
    jetzt = Stand.woerter_in([Enum.at(s.entwurf, nr - 1)])
    max(Stand.obergrenze(s) - (Stand.woerter(s) - jetzt), jetzt)
  end
end
