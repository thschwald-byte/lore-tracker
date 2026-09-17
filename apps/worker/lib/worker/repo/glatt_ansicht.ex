defmodule Worker.Repo.GlattAnsicht do
  @moduledoc """
  Issue #1198: Scope `campaign_glatt_ansicht` — die Geglättet-Spalte so, wie sie
  auf dem Bildschirm steht.

  **Warum es diesen Scope gibt.** Bis #1198 bekam der Hub über
  `campaign_luecken` das Skelett **aller** Blöcke einer Kampagne und rechnete
  Ansicht, Filter, Zähler und Fenster selbst. An seattleV4 sind das 5.317
  Blöcke, von denen höchstens ~600 angezeigt werden; im Hub wuchs der
  LiveView-Heap dabei von 10 auf 36 MB, der Pod um 84 MB. Am 10.09.2026 hat ein
  einziger Tab den Prod-Hub damit dreimal in drei Minuten umgebracht. Die Regel
  seither: alle Daten liegen im Worker, an den Hub geht nur, was er anzeigt.

  **Was die Antwort trägt.** Pro Session den Kopf (derselbe wie
  `Luecken.smoothed_for_campaign/2`, `Luecken.session_kopf/3`), die wirksame
  Ansicht samt Auto-Vorschlag, die drei Zahlen, die der Hub zeigt
  (`kuratieren_count`, `block_count`, `gefiltert_total`), den Fensteranfang
  `from` — und als `blocks` **nur das Fenster**, jeder Block komplett mit Text.
  Dazu `luecken_marker` (kampagnenweit, `GlattQuellen.marker/2`), weil eine
  Kuration den 🕳 an Resümee/Chronik/Epos ändern kann, und `nur` als Echo, damit
  der Hub eine Teilantwort von einer vollen unterscheiden kann.

  **Die Anfrage.** `nur` ([session_id] | nil = alle) und `sitzungen` mit einem
  Wunsch je Session: `ansicht` (`kuratieren` | `einfach` | `alles` | nil) und
  `fenster` (`%{"tail" => n}` oder `%{"from" => i, "count" => n}`). Eine Session
  ohne Wunsch bekommt die Auto-Ansicht und den Tail. Das Fenster läuft — wie
  bisher im Hub (`Components.window_slice/3`) — über die **gefilterte** Liste.

  **Die Ansicht wird hier nur vorgeschlagen, nicht gespeichert.** Schickt der
  Hub `ansicht: nil`, wählt der Worker `kuratieren`, solange es Kuratierbares
  gibt, sonst `einfach` — dieselbe Regel wie `Components.glatt_view_for/2`. Der
  Hub darf die gewählte Ansicht NICHT als Wunsch zurückschicken, sonst stürbe
  der Auto-Wechsel, sobald die letzte Lücke kuratiert ist.

  **Zwei Deckel, beide Speicherschutz.** Das Fenster ist auf 200 Blöcke
  begrenzt (`Components.window_max/0`); ein Hub-Fehler, der „alles" verlangt,
  bekommt trotzdem nur 200. Das ist kein Erreichbarkeits-Deckel: jeder Block
  bleibt über Fensterschritte erreichbar (die #883-Lehre).

  **Fehler.** Eine Exception wird zu `%{"error" => "glatt_ansicht_failed"}` plus
  lautem Log, statt den Socket-Prozess zu treffen
  (`Worker.HubClient.Rpc.on_snapshot/2` fängt nichts ab).

  **Ehrliche Grenze.** Die Zahl der angezeigten Blöcke ist ein Fenster **je
  Session** — bei 20 Sessions 1.000 (Tail 50 seit #1204, vorher 150 → 3.000).
  Ein globaler Deckel ist eigene Arbeit.
  """

  require Logger

  import Worker.Repo, only: [member?: 2]

  alias Worker.Repo.{GlattQuellen, Luecken}

  # Issue #1204: 50 statt 150. Im Lesen-Modus ist die Geglättet-Spalte
  # praktisch der ganze Render der Seite; an seattleV4 gemessen senkt das den
  # Diff des ersten Aufbaus um 65 % (1,47 → 0,52 MB) und die Heap-Spitze der
  # Ansicht von 28 auf 12–16 MB. Muss zu `HubWeb.CampaignLive.GlattAnsicht.tail/0`
  # passen — der Hub schickt den Tail nur für Sessions mit Wunsch mit.
  @tail_default 50
  @max 200
  @ansichten ~w(kuratieren einfach alles)

  @doc "Member-gated wie die übrigen Kampagnen-Scopes."
  @spec snapshot(map()) :: map()
  def snapshot(%{"id" => id, "viewer_discord_id" => viewer} = scope) when is_binary(id) do
    if member?(id, viewer), do: sicher(id, scope), else: %{"forbidden" => true}
  end

  def snapshot(_scope), do: %{"error" => "bad_request"}

  @doc "Harte Obergrenze eines Fensters (= `Components.window_max/0` im Hub)."
  @spec max_fenster() :: pos_integer()
  def max_fenster, do: @max

  defp sicher(id, scope) do
    ansicht(id, scope)
  rescue
    e ->
      Logger.error(
        "GlattAnsicht: Antwort gescheitert (campaign=#{id}) — " <>
          Exception.format(:error, e, __STACKTRACE__)
      )

      %{"error" => "glatt_ansicht_failed"}
  catch
    :exit, reason ->
      Logger.error("GlattAnsicht: Antwort abgebrochen (campaign=#{id}, exit #{inspect(reason)})")
      %{"error" => "glatt_ansicht_failed"}
  end

  defp ansicht(id, scope) do
    nur = nur(scope["nur"])
    wuensche = if is_map(scope["sitzungen"]), do: scope["sitzungen"], else: %{}

    # Jede Session wird genau einmal dekodiert und ihre Kuration genau einmal
    # aufgelöst — der Marker braucht alle Sessions, die Ansicht nur die
    # angefragten, beide aus denselben Daten.
    paare =
      id
      |> Worker.Repo.list_sessions()
      |> Enum.flat_map(fn session ->
        case Worker.Repo.get_smoothed_blocks(session.id) do
          nil ->
            []

          snap ->
            blocks = snap.blocks || []
            wirksam = Luecken.luecken_overrides_effective(session.id, blocks)
            [{session, snap, blocks, wirksam}]
        end
      end)

    index =
      Enum.reduce(paare, %{}, fn {_s, _snap, blocks, %{attached: attached}}, acc ->
        GlattQuellen.index_bloecke(acc, blocks, attached)
      end)

    ansichten =
      for {session, snap, blocks, wirksam} <- paare, nur == nil or session.id in nur do
        session_ansicht(session, snap, blocks, wirksam, wunsch(wuensche, session.id))
      end

    %{
      "glatt_ansicht" => ansichten,
      "nur" => nur,
      "luecken_marker" => GlattQuellen.marker(id, index)
    }
  end

  defp nur(liste) when is_list(liste), do: Enum.filter(liste, &is_binary/1)
  defp nur(_), do: nil

  defp wunsch(wuensche, session_id) do
    case Map.get(wuensche, session_id) do
      %{} = w -> w
      _ -> %{}
    end
  end

  defp session_ansicht(session, snap, blocks, %{attached: attached, verwaist: verwaist}, wunsch) do
    mit_status = Enum.map(blocks, &{&1, get_in(attached, [&1["id"], "status"])})
    kuratierbar = Enum.count(mit_status, &kuratierbar?/1)
    auto = if kuratierbar > 0, do: "kuratieren", else: "einfach"
    ansicht = if wunsch["ansicht"] in @ansichten, do: wunsch["ansicht"], else: auto
    gefiltert = filter(mit_status, ansicht)
    total = length(gefiltert)
    {from, count} = fenster(wunsch["fenster"], total)

    session
    |> Luecken.session_kopf(snap, verwaist)
    |> Map.merge(%{
      "ansicht" => ansicht,
      "ansicht_auto" => auto,
      "kuratieren_count" => kuratierbar,
      "block_count" => length(blocks),
      "gefiltert_total" => total,
      "from" => from,
      "blocks" => mit_texten(session.id, Enum.slice(gefiltert, from, count), attached)
    })
  end

  # `== true`: ein fehlender Schlüssel ist `nil`, und `nil and …` wirft
  # `BadBooleanError` statt falsch zu sein (#710/#1153).
  defp kuratierbar?({block, status}), do: block["hat_luecke"] == true and is_nil(status)

  # Dieselben drei Filter wie bis #1198 `Components.glatt_blocks/2` im Hub.
  defp filter(mit_status, "kuratieren"), do: Enum.filter(mit_status, &kuratierbar?/1)

  defp filter(mit_status, "einfach"),
    do: Enum.reject(mit_status, fn {_block, status} -> status == "unbrauchbar" end)

  defp filter(mit_status, _alles), do: mit_status

  # Der Hub schickt das Fenster explizit. Alles andere (fehlend, falscher Typ)
  # ist ein Aufruferfehler und bekommt den Tail, statt zu crashen.
  defp fenster(%{"tail" => n}, total) when is_integer(n) do
    from = max(0, total - (n |> max(0) |> min(@max)))
    {from, total - from}
  end

  defp fenster(%{"from" => f, "count" => c}, total) when is_integer(f) and is_integer(c) do
    from = f |> max(0) |> min(total)
    {from, c |> max(0) |> min(@max) |> min(total - from)}
  end

  defp fenster(_wunsch, total), do: fenster(%{"tail" => @tail_default}, total)

  # Der Roh-Text braucht die Utterances der Session — geladen nur, wenn das
  # Fenster überhaupt einen Block enthält.
  defp mit_texten(_session_id, [], _attached), do: []

  defp mit_texten(session_id, sichtbar, attached) do
    vorschlaege = Luecken.luecken_vorschlaege_for_session(session_id)

    utt_by_id =
      session_id |> Worker.Repo.list_utterances(limit: :all) |> Map.new(&{&1.id, &1})

    Enum.map(sichtbar, fn {block, status} ->
      id = block["id"]
      override = Map.get(attached, id)

      %{
        "block_id" => id,
        "quell_utterance_ids" => block["quell_utterance_ids"] || [],
        "hat_luecke" => block["hat_luecke"] == true,
        "status" => status
      }
      |> Map.merge(Luecken.block_texte(block, Map.get(vorschlaege, id), override, utt_by_id))
    end)
  end
end
