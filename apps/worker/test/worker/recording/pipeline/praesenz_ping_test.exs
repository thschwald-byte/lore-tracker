defmodule Worker.Recording.Pipeline.PraesenzPingTest do
  @moduledoc """
  Issue #965 (Epic #911 Slice 2): der Präsenz-Ping-Halluzinations-Filter.
  Fixtures 1-4 sind die echten Treffer aus der Prod-Kampagne „Free Seattle"
  (`seattle-bereinigt-1`, Session 1) — der stärkste Realitäts-Anker für
  diese Regel. Kein LLM, kein Mnesia.
  """

  use ExUnit.Case, async: true

  alias Worker.Recording.Pipeline.PraesenzPing

  @base ~U[2026-07-05 19:54:00Z]

  defp utt(id, did, text, offset_s) do
    %{
      "id" => id,
      "discord_id" => did,
      "timestamp" => DateTime.add(@base, offset_s, :second),
      "text" => text
    }
  end

  describe "ping?/1" do
    test "echte Prod-Treffer matchen" do
      assert PraesenzPing.ping?("Ja, ich bin da.")
      assert PraesenzPing.ping?("Ja, ich bin da, ich bin da.")
      assert PraesenzPing.ping?("ich bin hier")
      assert PraesenzPing.ping?("Ich bin da")
    end

    test "echter Inhalt matcht NICHT — dieselbe Phrase eingebettet in mehr Text" do
      refute PraesenzPing.ping?("Ja, ich bin da, ich lese gerade was. Alles gut, ich bin hier.")
    end

    test "Substring-Fallstrick: 'noch da' als Teil eines echten Satzes matcht NICHT" do
      refute PraesenzPing.ping?("Das Signal ist vollständig noch da ist.")
    end

    test "nil/leer matcht nicht" do
      refute PraesenzPing.ping?(nil)
      refute PraesenzPing.ping?("")
    end
  end

  describe "question?/1" do
    test "Anwesenheitsfragen matchen" do
      assert PraesenzPing.question?("Bist du noch da?")
      assert PraesenzPing.question?("Seid ihr noch da?")
      assert PraesenzPing.question?("bist du da")
    end

    test "kein echter Treffer aus der gesichteten Session — reine Regex-Absicherung" do
      refute PraesenzPing.question?("Ja, ich bin da.")
      refute PraesenzPing.question?("Wie geht es dir?")
    end
  end

  describe "filter/1 — echte Prod-Fixtures (seattle-bereinigt-1, Session 1)" do
    test "Monolog-Unterbrechung ohne nahe Frage -> gestrippt (2 echte Treffer)" do
      utterances = [
        utt("u1", "spk-a", "Naja, also ich habe mir tatsächlich immer so wie so eine Mischung aus,", 0),
        utt("u2", "spk-a", "Kreditkarte und USB-Stick vorgestellt.", 4),
        utt("u3", "spk-a", "Ja, ich bin da.", 9),
        utt("u4", "spk-a", "Und die sind quasi auf deine ID getrimmt.", 2),
        utt("u5", "spk-a", "Ja, ich bin da.", 6),
        utt("u6", "spk-a", "Und können halt nur...", 2)
      ]

      {kept, discarded} = PraesenzPing.filter(utterances)

      assert Enum.sort(discarded) == ["u3", "u5"]
      assert Enum.map(kept, & &1["id"]) == ["u1", "u2", "u4", "u6"]
    end

    test "Grenzfall: Sprecherwechsel davor+danach (keine Monolog-Unterbrechung) -> bleibt stehen" do
      utterances = [
        utt("u1", "sl", "Und alles Weitere würde ich sagen, machen wir beim nächsten Mal.", 0),
        utt("u2", "sl", "Ich weiß, beim nächsten Mal.", 9),
        utt("u3", "tom", "Ja, ich bin da, ich bin da.", 1),
        utt("u4", "andere", "ha, ha, ha, ha, ha, ha.", 5)
      ]

      {kept, discarded} = PraesenzPing.filter(utterances)

      assert discarded == []
      assert Enum.map(kept, & &1["id"]) == ["u1", "u2", "u3", "u4"]
    end

    test "erste/letzte Utterance der Session ohne Nachbarn -> konservativ nicht gestrippt" do
      utterances = [
        utt("u1", "spk-a", "Ja, ich bin da.", 0),
        utt("u2", "spk-a", "Los geht's.", 2)
      ]

      {_kept, discarded} = PraesenzPing.filter(utterances)
      assert discarded == []
    end
  end

  describe "filter/1 — Guard-Verhalten (synthetisch, da keine echte Frage in der gesichteten Session vorkam)" do
    test "Anwesenheitsfrage in der Nähe schützt den Ping trotz Monolog-Unterbrechung" do
      utterances = [
        utt("u1", "a", "Bist du noch da?", 0),
        utt("u2", "a", "Der Auftraggeber wartet.", 3),
        utt("u3", "a", "Ja, ich bin da.", 10),
        utt("u4", "a", "Wir sollten los.", 2)
      ]

      {_kept, discarded} = PraesenzPing.filter(utterances)
      assert discarded == []
    end

    test "Frage außerhalb des ±30s-Fensters schützt nicht" do
      utterances = [
        utt("u1", "a", "Bist du noch da?", 0),
        utt("u2", "a", "Ja, ich bin da.", 40),
        utt("u3", "a", "weiter im Text", 2)
      ]

      {_kept, discarded} = PraesenzPing.filter(utterances)
      assert discarded == ["u2"]
    end

    test "kein Ping-Match -> Frage/Guard irrelevant, bleibt immer stehen" do
      utterances = [
        utt("u1", "a", "Ganz normale Narration.", 0),
        utt("u2", "a", "Noch mehr Narration.", 2),
        utt("u3", "a", "Und weiter.", 2)
      ]

      {_kept, discarded} = PraesenzPing.filter(utterances)
      assert discarded == []
    end
  end
end
