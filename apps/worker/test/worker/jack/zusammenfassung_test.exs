defmodule Worker.Jack.ZusammenfassungTest do
  use ExUnit.Case, async: true

  alias Worker.Jack.{Gedaechtnis, Halter, Stand, Zusammenfassung}

  @bloecke for i <- 0..99, do: %{text: "Satz #{i}.", sprecher: "X", block_id: "b#{i}"}

  defp naechster(text), do: text |> String.split("## Naechster Schritt\n") |> List.last()

  test "der Aufbau des Spikes: Kopf, Auftrag, Stand, Gedächtnis, nächster Schritt" do
    s = Stand.neu(bloecke: @bloecke, phase: 2)
    t = Zusammenfassung.text(s)

    assert [
             "# Stand deiner Arbeit (von deinen Werkzeugen geschrieben, nicht zusammengefasst)",
             "",
             "## Auftrag",
             "Du sammelst aus einem Gespraechsmitschnitt die Aussagen ueber die besprochene"
             | _
           ] = String.split(t, "\n")

    assert t =~ "\n## Wo du stehst\n" <> Gedaechtnis.stand_text(s) <> "\n"
    assert t =~ "\n## Dein Gedaechtnis\n(noch keine Notizen)\n"
  end

  test "Phase 1: weiterlesen ab dem Block nach dem letzten gelesenen" do
    s = %{Stand.neu(bloecke: @bloecke, phase: 1) | gelesen: [{0, 39}, {40, 59}]}
    assert naechster(Zusammenfassung.text(s)) =~ "Lies weiter ab Block 60 und schreib"

    assert naechster(Zusammenfassung.text(Stand.neu(bloecke: @bloecke, phase: 1))) =~
             "Lies weiter ab Block 0 und"

    assert naechster(Zusammenfassung.text(Stand.neu(bloecke: @bloecke, phase: 1, beppo: true))) =~
             "Ruf weiter() und mach dort weiter"
  end

  test "Phase 2: nicht fertig bis zum letzten Block, dann abschließen" do
    s = %{Stand.neu(bloecke: @bloecke, phase: 2) | sammelnd: [{0, 49}]}

    assert naechster(Zusammenfassung.text(s)) =~
             "Du bist NICHT fertig: beim Sammeln bist du bis Block 49 von 99 gekommen. " <>
               "Arbeite weiter, Bereich fuer Bereich: bloecke(von, bis) ab Block 50,"

    assert naechster(Zusammenfassung.text(%{s | beppo: true})) =~
             "Du bist NICHT fertig. Mach genau"

    fertig = %{s | sammelnd: [{0, 99}]}
    assert naechster(Zusammenfassung.text(fertig)) =~ "bis zum letzten Block gekommen"
  end

  test "der Rückruf baut den Text aus dem Stand im Halter und schreibt ihn ins Journal" do
    {:ok, h} = Halter.start_link(Stand.neu(bloecke: @bloecke, phase: 2))
    zusammenfassen = Zusammenfassung.fuer(h)

    text = zusammenfassen.(%{weggefallen: [%{role: :user}, %{role: :assistant}], vorherige: nil})
    assert text == Zusammenfassung.text(Halter.stand(h))

    assert [{"zusammenfassung.txt", %{"weggefallen" => 2, "phase" => 2, "text" => ^text}}] =
             Stand.journal_liste(Halter.stand(h))
  end
end
