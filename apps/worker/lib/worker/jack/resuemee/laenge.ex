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

  @doc "Die Längen-Zeile für den Stand-Text und `entwurf()`."
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
      end
  end

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
