defmodule Worker.AudioConsentStatusConvergenceTest do
  @moduledoc """
  Issue #1005: Zustimmung und Widerruf konkurrieren um denselben logischen
  Zustand und reisen durch dasselbe replizierte Event-Log — das ist
  Delete↔Wiederkehr (#766-Klasse). Auflösung ist **LWW-by-`event_id`**, nicht
  „Zustimmung gewinnt" und nicht Terminalität.

  Deshalb wird hier in **allen Zustellreihenfolgen** geprüft: zwei Worker, die
  dieselben Events in unterschiedlicher Folge sehen, müssen zum selben Ergebnis
  kommen. Ein terminales `:granted` (der verworfene Urentwurf) würde hier
  auffallen — eine alte Zustimmung überlebte je nach Reihenfolge den Widerruf.

  Zusätzlich gepinnt: die **Read-both/Write-new**-Regel. Die Legacy-Tabelle
  `worker_audio_consents` gilt nur, solange kein Status existiert — deshalb
  gewinnt ein Widerruf gegen eine Alt-Zustimmung ohne `event_id` (bewusste
  Umkehr der üblichen „Alt-Verhalten gewinnt"-Degradation, weil bei Einwilligung
  fail-closed richtig ist).
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Materializer
  alias Worker.Schema.Mnesia, as: S

  @did "615614311255244801"

  setup do
    clear_all_tables!()
    {:atomic, :ok} = :mnesia.clear_table(S.audio_consents())
    {:atomic, :ok} = :mnesia.clear_table(S.audio_consent_status())
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    :ok
  end

  defp grant(event_id, seq) do
    event(
      "AudioConsentRecorded",
      %{"discord_id" => @did, "version" => "v1", "accepted_at" => "2026-08-12T10:00:00Z"},
      seq,
      event_id: event_id
    )
  end

  defp revoke(event_id, seq) do
    event(
      "AudioConsentRevoked",
      %{"discord_id" => @did, "version" => "v1", "revoked_at" => "2026-08-12T11:00:00Z"},
      seq,
      event_id: event_id
    )
  end

  defp apply_all(evs), do: Enum.each(evs, &Materializer.apply_event/1)

  defp status, do: Worker.Repo.audio_consent_status(@did)

  defp permutations([]), do: [[]]
  defp permutations(list), do: for(x <- list, rest <- permutations(list -- [x]), do: [x | rest])

  describe "LWW-Konvergenz zwischen Zustimmung und Widerruf" do
    test "höhere event_id gewinnt — in JEDER Zustellreihenfolge" do
      # e2 (Widerruf) ist jünger als e1 (Zustimmung) → Widerruf gilt, egal wer
      # zuerst ankommt.
      for order <- permutations([grant("e1", 1), revoke("e2", 2)]) do
        clear_all_tables!()
        {:atomic, :ok} = :mnesia.clear_table(S.audio_consent_status())
        apply_all(order)

        assert status() == {:revoked, "v1"},
               "Reihenfolge #{inspect(Enum.map(order, & &1["event_id"]))} divergierte"
      end
    end

    test "umgekehrt: jüngere Zustimmung nach älterem Widerruf gewinnt ebenfalls" do
      for order <- permutations([revoke("e1", 1), grant("e2", 2)]) do
        clear_all_tables!()
        {:atomic, :ok} = :mnesia.clear_table(S.audio_consent_status())
        apply_all(order)

        assert status() == {:granted, "v1"},
               "Reihenfolge #{inspect(Enum.map(order, & &1["event_id"]))} divergierte"
      end
    end

    test "Mid-Insert: ein nachgezogenes MITTLERES Event ändert das Ergebnis nicht" do
      # Das klassische Konvergenz-Szenario: e5 grant, e9 revoke sind schon da,
      # dann trudelt e7 (grant) nachträglich ein. e9 bleibt der Gewinner.
      apply_all([grant("e5", 1), revoke("e9", 2), grant("e7", 3)])
      assert status() == {:revoked, "v1"}
    end

    test "Doppel-Zustellung ist idempotent" do
      apply_all([grant("e1", 1), revoke("e2", 2), revoke("e2", 2)])
      assert status() == {:revoked, "v1"}
    end

    test "granted ist NICHT terminal (der verworfene Urentwurf)" do
      # Wäre :granted terminal, bliebe hier {:granted, _} stehen und der
      # Widerruf wäre im Modell nicht darstellbar.
      apply_all([grant("e1", 1)])
      assert status() == {:granted, "v1"}
      apply_all([revoke("e2", 2)])
      assert status() == {:revoked, "v1"}
    end
  end

  describe "Read-both/Write-new gegenüber der Legacy-Tabelle" do
    test "ohne Status gilt die Legacy-Zustimmung als granted" do
      # Row wie sie vor #1005 entstand: nur in worker_audio_consents, ohne event_id.
      :ok =
        :mnesia.dirty_write({S.audio_consents(), @did, "v1", ~U[2026-08-02 18:15:17Z]})

      assert status() == {:granted, "v1"}
    end

    test "ein Widerruf gewinnt gegen eine Alt-Zustimmung OHNE event_id" do
      # Die bewusste Umkehr: sonst gilt „fehlender Anker → Alt-Verhalten
      # gewinnt", hier gewinnt fail-closed.
      :ok =
        :mnesia.dirty_write({S.audio_consents(), @did, "v1", ~U[2026-08-02 18:15:17Z]})

      apply_all([revoke("e1", 1)])
      assert status() == {:revoked, "v1"}
    end

    test "kein Eintrag in beiden Tabellen → nil (Abwesenheit ist keine Zustimmung)" do
      assert status() == nil
    end

    test "die Legacy-Tabelle wird von einer Zustimmung weiter mitgeschrieben" do
      # Bestandsleser (u.a. der Browser-Pfad über audio_consent/1) dürfen nicht
      # ausfallen, solange sie existieren.
      apply_all([grant("e1", 1)])
      assert %{version: "v1"} = Worker.Repo.audio_consent(@did)
    end
  end
end
