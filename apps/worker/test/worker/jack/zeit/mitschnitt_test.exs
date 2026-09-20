defmodule Worker.Jack.Zeit.MitschnittTest do
  @moduledoc """
  #1247 (Z2): der Mitschnitt des Zeit-Jack — eine Zeile je Utterance.

  Die Fälle stammen aus seattleV5 S3, handgelesen (dave, 19.09.2026): der
  Block mit zwei Welten in einem Atemzug, und die Utterances, die der
  OOC-Filter aus der Glättung wirft.
  """
  use ExUnit.Case, async: true

  alias Worker.Jack.Zeit.Mitschnitt

  defp u(id, did, text), do: %{id: id, discord_id: did, text: text}

  defp block(id, utt_ids, text, sprecher \\ "gm") do
    %{
      "id" => id,
      "quell_utterance_ids" => utt_ids,
      "text" => text,
      "speaker_discord_id" => sprecher
    }
  end

  @namen %{"gm" => "Spielleitung", "p1" => "Kodex"}

  describe "eine Zeile je Utterance" do
    test "ein mehrteiliger Block zerfällt in seine Zeilen" do
      # Der reale Fall: ein Sprecher, ein Atemzug, zwei Welten.
      us = [
        u("u1", "gm", "Wir machen nochmal zehn Minuten mehr."),
        u("u2", "gm", "Bewegt euch durch den Wald zurück."),
        u("u3", "gm", "Nach einer weiteren halben Stunde seid ihr dann wieder da.")
      ]

      bl = [block("b1", ["u1", "u2", "u3"], "Wir machen … Bewegt … Nach einer …")]

      zeilen = Mitschnitt.bauen(us, bl, %{}, @namen)

      assert length(zeilen) == 3
      assert Enum.map(zeilen, & &1.nr) == [1, 2, 3]
      assert Enum.map(zeilen, & &1.utterance_id) == ["u1", "u2", "u3"]
      # Alle drei gehören zum selben Block — die feine Adresse ist die Zeile.
      assert Enum.all?(zeilen, &(&1.block_id == "b1"))
      assert Enum.at(zeilen, 0).text =~ "zehn Minuten"

      assert Enum.at(zeilen, 2).text =~ "halbe Stunde" or
               Enum.at(zeilen, 2).text =~ "halben Stunde"
    end

    test "der Sprecher steht mit Namen da, nie mit Discord-ID" do
      zeilen = Mitschnitt.bauen([u("u1", "gm", "x")], [block("b1", ["u1"], "x")], %{}, @namen)
      assert hd(zeilen).sprecher == "Spielleitung"
    end

    test "ein unbekannter Sprecher bekommt eine Bezeichnung, nicht seine ID" do
      zeilen = Mitschnitt.bauen([u("u1", "fremd", "x")], [block("b1", ["u1"], "x")], %{}, @namen)

      refute hd(zeilen).sprecher =~ "fremd"
      assert hd(zeilen).sprecher =~ "ohne Namen"
    end
  end

  describe "die OOC-Verworfenen" do
    test "stehen in der Liste und sind markiert" do
      # In S1 sind 43 Utterances in keinem Block, in S3 107 — der Merge-Run
      # bricht dort. Ohne sie wäre „jede Utterance ist zugeordnet"
      # unerfüllbar, weil Jack sie nie zu sehen bekäme.
      us = [u("u1", "gm", "im Spiel"), u("u2", "p1", "Pizza?"), u("u3", "gm", "weiter")]
      bl = [block("b1", ["u1"], "im Spiel"), block("b2", ["u3"], "weiter")]

      zeilen = Mitschnitt.bauen(us, bl, %{}, @namen)

      assert length(zeilen) == 3
      assert Enum.at(zeilen, 1).ooc?
      assert Enum.at(zeilen, 1).block_id == nil
      refute Enum.at(zeilen, 0).ooc?
      refute Enum.at(zeilen, 2).ooc?
    end

    test "sie sind auch im Text als solche erkennbar" do
      us = [u("u1", "gm", "Pizza?")]
      assert Mitschnitt.bauen(us, [], %{}, @namen) |> Mitschnitt.als_text() =~ "[ooc]"
    end
  end

  describe "der wirksame Text" do
    test "wird einmal je Block gezeigt, nicht je Zeile" do
      # Bei einer uncurierten Lücke gilt der Gap-Fill-Vorschlag, nicht der
      # Rohtext — sonst liest Jack eine andere Sitzung als die, auf der die
      # Referenzliste entstanden ist. Je Zeile wiederholt wäre er bei 1.803
      # Blöcken die Hälfte des Kontextfensters.
      us = [u("u1", "gm", "I don't"), u("u2", "gm", "know.")]
      bl = [block("b1", ["u1", "u2"], "I don't know.")]
      wirksam = %{"b1" => "Ich weiß es nicht."}

      zeilen = Mitschnitt.bauen(us, bl, wirksam, @namen)

      assert Enum.at(zeilen, 0).block_text == "Ich weiß es nicht."
      assert Enum.at(zeilen, 1).block_text == nil

      text = Mitschnitt.als_text(zeilen)
      assert text =~ "Ich weiß es nicht."
      # Genau einmal, nicht zweimal.
      assert length(String.split(text, "Ich weiß es nicht.")) == 2
    end

    test "ohne Abweichung steht er gar nicht da" do
      us = [u("u1", "gm", "klarer Satz")]
      zeilen = Mitschnitt.bauen(us, [block("b1", ["u1"], "klarer Satz")], %{}, @namen)

      assert hd(zeilen).block_text == nil
      refute Mitschnitt.als_text(zeilen) =~ "geglättet"
    end
  end

  describe "als_text/1" do
    test "jede Zeile trägt ihre Nummer, den Sprecher und ihren eigenen Text" do
      us = [u("u1", "gm", "eins"), u("u2", "p1", "zwei")]
      bl = [block("b1", ["u1"], "eins"), block("b2", ["u2"], "zwei", "p1")]

      text = Mitschnitt.als_text(Mitschnitt.bauen(us, bl, %{}, @namen))

      assert text =~ "1  Spielleitung: eins"
      assert text =~ "2  Kodex: zwei"
    end
  end
end
