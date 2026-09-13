defmodule Worker.Jack.Epos.Eingabe do
  @moduledoc """
  Was der Epos-Jack (J6, #1210, Epic #1195) von einer Sitzung zu lesen
  bekommt: dieselbe Lesebasis wie der Resümee-Jack
  (`Worker.Jack.Resuemee.Eingabe.aus_repo/1` — die geprüften Fakten dieser
  und früherer Sitzungen, Bögen, Vorgeschichte, Mitschnitt samt Lader für
  frühere Sitzungen, Epos-Kapitel, Chronik, Bögen der Kampagne), dazu, was nur
  das Epos braucht (`zusaetze/3`, pur):

    * `art: :epos`;
    * `ueberschrift` — der Name der Epos-Spalte aus „Stil setzen“
      (`vorgaben["epos"].name`), sonst „Epos“, derselbe Standard wie der
      Spaltentitel im Hub (`HubWeb.CampaignLive.Components.default_output_label/1`);
    * `flavor` — `%{base:, epos:}`: Grundton und Epos-Ton
      (`Worker.Recording.Pipeline.Prompts.effective_flavor/2`);
    * `resuemee_weg` — der **Weg aus dem Resümee** dieser Sitzung (`weg/3`).

  Das Resümee dieser Sitzung selbst steht schon in der Lesebasis
  (`resuemee_diese`, `get_session_summary/1`, die angezeigte Fassung) — beim
  Epos-Jack ist es die Vorlage des Kapitels. `max_woerter` (die Länge des
  Resümees) fällt heraus. **Eine Länge hat das Kapitel nicht** — weder
  Mindest- noch Höchstlänge (Maintainer, 13.09.2026): der Epos-Jack schreibt
  frei.

  **Der Weg** sind die Stationen der GLIEDERUNG aus dem abgelegten Stand des
  Resümee-Jack (`JackResuemeeStandAbgelegt`,
  `Worker.Repo.jack_resuemee_stand_for_session/1`, `stand["notizen"]`), je
  Schlüssel, Zeile, kurze Fakt-IDs und Bögen. **Fehlt der Stand, ist der Weg
  leer** — der Epos-Jack stellt ihn dann selbst auf — und das steht als
  Warnung im Log.

  **Ein veralteter Weg wird nicht benutzt.** Die kurzen IDs (`S3-F12`) sind
  Positionen im Faktenbestand; wurden die Fakten nach dem Resümee-Lauf neu
  gebaut, zeigte „S3-F12“ auf einen anderen Fakt. Die Satzquellen des
  abgelegten Stands halten zu jeder zitierten kurzen ID die echte Fakt-ID
  fest; weicht eine davon vom heutigen Bestand ab, gilt der Weg als veraltet,
  bleibt leer und steht laut im Log. **Ehrliche Grenze:** geprüft werden nur
  die IDs, die ein Satz des Resümees zitiert — eine Station, deren Fakten
  kein Satz nennt, ließe sich so nicht als veraltet erkennen. In der Pipeline
  läuft das Epos direkt nach dem Resümee auf demselben Bestand (E4).
  """

  require Logger

  alias Worker.Jack.Resuemee.Eingabe, as: Basis
  alias Worker.Recording.Pipeline.Prompts

  @standard_ueberschrift "Epos"

  @doc """
  Die Eingabe für eine Sitzung aus dem Repo: `Worker.Jack.Resuemee.Eingabe.aus_repo/1`,
  dann `zusaetze/3` mit der Kampagne und dem abgelegten Stand des
  Resümee-Jack. Fehler wie dort, dazu `{:error, :keine_kampagne}`.
  """
  @spec aus_repo(String.t()) :: {:ok, map()} | {:error, term()}
  def aus_repo(session_id) do
    with {:ok, basis} <- Basis.aus_repo(session_id),
         {:ok, campaign} <- kampagne(session_id) do
      {:ok, zusaetze(basis, campaign, Worker.Repo.jack_resuemee_stand_for_session(session_id))}
    end
  end

  defp kampagne(session_id) do
    with %{campaign_id: cid} <- Worker.Repo.get_session(session_id),
         %{} = c <- Worker.Repo.get_campaign(cid) do
      {:ok, c}
    else
      _ -> {:error, :keine_kampagne}
    end
  end

  @doc """
  Die Lesebasis (`basis`, wie `Worker.Jack.Resuemee.Eingabe.aus_repo/1` sie
  liefert) mit dem, was nur das Epos braucht (Moduledoc). `resuemee_stand`
  ist das Ergebnis von `Worker.Repo.jack_resuemee_stand_for_session/1`
  (`%{stand: map}` oder `nil`).
  """
  @spec zusaetze(map(), map(), map() | nil) :: map()
  def zusaetze(basis, campaign, resuemee_stand) do
    basis
    |> Map.delete(:max_woerter)
    |> Map.merge(%{
      art: :epos,
      ueberschrift: ueberschrift(campaign),
      flavor: flavor(campaign),
      resuemee_weg: weg(resuemee_stand, basis.fakten, basis.sitzung)
    })
  end

  @doc """
  Die Überschrift der Epos-Spalte aus „Stil setzen“ (`vorgaben["epos"].name`),
  sonst „Epos“.
  """
  @spec ueberschrift(map()) :: String.t()
  def ueberschrift(campaign) do
    case Prompts.stage_heading(campaign, "epos") do
      n when is_binary(n) ->
        if String.trim(n) == "", do: @standard_ueberschrift, else: String.trim(n)

      _ ->
        @standard_ueberschrift
    end
  end

  @doc "Grundton und Epos-Ton aus „Stil setzen“ (`nil`, wo nichts gesetzt ist)."
  @spec flavor(map()) :: %{base: String.t() | nil, epos: String.t() | nil}
  def flavor(campaign) do
    flavors = campaign[:flavors] || %{}

    %{
      base: Prompts.effective_flavor(flavors, "base"),
      epos: Prompts.effective_flavor(flavors, "epos")
    }
  end

  @doc """
  Der Weg aus dem Resümee: die Stationen der GLIEDERUNG des abgelegten Stands
  (`%{stand: map}`), je `%{schluessel:, zeile:, fakten:, boegen:}` in ihrer
  Reihenfolge. `[]` ohne Stand oder bei veraltetem Stand, beides laut im Log
  (Moduledoc). `fakten` sind die Fakten dieser Sitzung, wie Jack sie sieht,
  `sitzung` `%{nummer:}`.
  """
  @spec weg(map() | nil, [map()], map()) :: [map()]
  def weg(%{stand: stand}, fakten, sitzung) when is_map(stand) do
    case veraltet(stand, fakten, sitzung.nummer) do
      [] ->
        stationen(stand)

      ids ->
        Logger.warning(
          "Epos-Jack: der Weg aus dem Resümee von Sitzung #{sitzung.nummer} passt nicht mehr " <>
            "zum Faktenbestand (#{Enum.join(Enum.take(ids, 5), ", ")} zeigen heute auf andere " <>
            "Fakten) — er wird nicht benutzt, Jack stellt den Weg selbst auf"
        )

        []
    end
  end

  def weg(_kein_stand, _fakten, sitzung) do
    Logger.warning(
      "Epos-Jack: zu Sitzung #{sitzung.nummer} liegt kein abgelegter Stand des Resümee-Jack " <>
        "vor — es gibt keinen Weg aus dem Resümee, Jack stellt ihn selbst auf"
    )

    []
  end

  defp stationen(stand) do
    for %{} = n <- List.wrap(stand["notizen"]),
        n["abschnitt"] == "GLIEDERUNG",
        is_binary(n["zeile"]) and String.trim(n["zeile"]) != "",
        n["schluessel"] not in [nil, ""] do
      %{
        schluessel: to_string(n["schluessel"]),
        zeile: n["zeile"],
        fakten: n["fakten"] |> List.wrap() |> Enum.filter(&is_binary/1),
        boegen: n["boegen"] |> List.wrap() |> Enum.filter(&is_binary/1)
      }
    end
  end

  # Die kurzen IDs dieser Sitzung, die ein Satz des Resümees zitiert und deren
  # echte Fakt-ID heute eine andere ist (oder die es nicht mehr gibt). Die
  # Satzquellen tragen je Satz `fakten` (kurz) und `fakt_ids` (echt) in
  # derselben Reihenfolge; ein Satz, bei dem die Längen nicht passen, bleibt
  # außen vor.
  defp veraltet(stand, fakten, nummer) do
    heute = Map.new(fakten, &{&1.id, &1.fakt_id})
    praefix = "S#{nummer}-"

    for %{} = q <- List.wrap(stand["satzquellen"]),
        kurz = List.wrap(q["fakten"]),
        echt = List.wrap(q["fakt_ids"]),
        length(kurz) == length(echt),
        {k, e} <- Enum.zip(kurz, echt),
        is_binary(k) and String.starts_with?(String.upcase(k), praefix),
        Map.get(heute, k) != e,
        uniq: true,
        do: k
  end
end
