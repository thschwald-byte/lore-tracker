defmodule HubWeb.CampaignLive.DerivePermissionKeysTest do
  @moduledoc """
  Issue #1090: der Wächter gegen die Fehlerklasse, die den REC-Knopf lahmgelegt
  hat.

  `derive_assigns/2` berechnete `can_record?` korrekt — nur übertrug es niemand
  in den Socket, weil der Apply-Pfad eine handgepflegte Liste war. Ein fehlendes
  Assign erzeugt keinen Fehler, sondern einen toten Knopf: nichts wurde rot,
  weder beim Kompilieren noch in der Suite noch im Log.

  Dieser Test hält die berechneten Felder gegen die übertragenen. Wer ein neues
  Recht ergänzt und `@permission_assigns` vergisst, bekommt hier eine
  Fehlermeldung, die das fehlende Feld beim Namen nennt.
  """
  use ExUnit.Case, async: true

  alias HubWeb.CampaignLive.Derive
  alias HubWeb.Fixtures

  # Aus `derive_assigns/2` NICHT zu übertragen — mit Grund, nicht aus Versehen:
  @not_assigned_verbatim %{
    campaign: "wird als :campaign UND :current_campaign gesetzt",
    members: "durchläuft eigene Update-Pfade (Live-Events)",
    role: "heißt im Socket :viewer_role (abweichender Name)",
    campaign_role: "steckt in :perm_user, kein eigenes Assign",
    perm_user: "kein Boolean, wird ausdrücklich zugewiesen",
    is_member?: "wird übertragen — steht in @permission_assigns"
  }

  test "jedes berechnete Permission-Feld wird auch übertragen" do
    derived =
      Derive.derive_assigns(
        Fixtures.snapshot(
          viewer_role: "spielleiter",
          members: [Fixtures.member("did-sp", "spielleiter")]
        ),
        "did-sp"
      )

    berechnet = derived |> Map.keys() |> MapSet.new()
    uebertragen = MapSet.new(Derive.permission_assigns())
    bekannt_ausgenommen = @not_assigned_verbatim |> Map.keys() |> MapSet.new()

    vergessen =
      berechnet
      |> MapSet.difference(uebertragen)
      |> MapSet.difference(bekannt_ausgenommen)

    assert MapSet.size(vergessen) == 0,
           "derive_assigns/2 berechnet #{inspect(MapSet.to_list(vergessen))}, aber " <>
             "`@permission_assigns` in Derive überträgt es nicht in den Socket. " <>
             "Entweder dort eintragen — oder, wenn es absichtlich nicht übertragen " <>
             "wird, in @not_assigned_verbatim dieses Tests mit Begründung vermerken."
  end

  test "jeder übertragene Key wird auch berechnet" do
    # Die Gegenrichtung: ein Tippfehler in `@permission_assigns` würde sonst
    # erst zur Laufzeit als KeyError auffallen (Map.fetch!).
    derived =
      Derive.derive_assigns(Fixtures.snapshot(viewer_role: "spieler", members: []), "did-x")

    for key <- Derive.permission_assigns() do
      assert Map.has_key?(derived, key),
             "`@permission_assigns` nennt #{inspect(key)}, aber derive_assigns/2 " <>
               "liefert es nicht — `assign_permissions/2` würde mit KeyError sterben."
    end
  end

  test "die Sperr-Defaults decken dieselben Keys ab" do
    # Sonst rendert die Recording-Bar vor dem ersten Snapshot in einen KeyError
    # statt in einen gesperrten Knopf.
    assert Derive.default_permission_assigns() |> Map.keys() |> Enum.sort() ==
             Derive.permission_assigns() |> Enum.sort()

    assert Derive.default_permission_assigns() |> Map.values() |> Enum.all?(&(&1 == false))
  end
end
