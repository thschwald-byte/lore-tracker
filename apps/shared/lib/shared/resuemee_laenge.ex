defmodule Shared.ResuemeeLaenge do
  @moduledoc """
  Die Länge des Resümees je Kampagne (J5, #1209): das **Ziel** in Wörtern,
  auf das der Resümee-Jack schreibt. Gesetzt in „Stil setzen“ (Resümee-Tab,
  `HubWeb.CampaignLive.Stil`), gespeichert per `CampaignResuemeeLaengeSet`
  im Worker (`Worker.Materializer.ResuemeeLaengeFolds`), gelesen vom
  Resümee-Jack (`Worker.Jack.Resuemee.Eingabe`).

  **Warum hier:** Hub und Worker brauchen denselben Standard, denselben
  Wertebereich und dieselbe Obergrenze — der Hub, um eine Eingabe abzulehnen
  und die Obergrenze anzuzeigen, der Worker, um beides anzuwenden. Zwei Listen
  an zwei Orten laufen auseinander, ohne dass etwas rot wird (#1090-Klasse).

  **Ein „Was bisher geschah“** (Maintainer, 13.09.2026). Anlass war der erste
  echte Lauf — 1272 Wörter, 107 von 114 Fakten erzählt, länger als das
  Epos-Kapitel.

  **Ziel und Obergrenze** (Maintainer, 13.09.2026, nach einem Lauf mit dem
  damaligen Standard 75: 73 Wörter, der Ablauf der Sitzung nur bruchstückhaft
  erkennbar): „Der Weg, den die Gruppe genommen hat, muss aus dem Resümee
  ersichtlich sein — wenn die 75 Wörter nicht reichen für die grobe Abdeckung,
  darf man bis zu maximal dem Doppelten erweitern.“ Der gesetzte Wert ist
  deshalb das Ziel, die harte Obergrenze ist `hoechstens/1` — das Doppelte.

  **Standard 150 Wörter, Obergrenze 300** (Maintainer, 13.09.2026): drei
  Resümees einer anderen Kampagne mit je rund 210 Wörtern hält er für eine
  gute Größe; bis dahin war der Standard 75.

  **Wertebereich 30 bis 1000, gegriffen:** unter 30 Wörtern trägt ein Absatz
  mit Titel kaum einen Satz, über 1000 wäre es kein Resümee mehr. Der
  Wertebereich gilt für das Ziel; `obergrenze/0` ist dessen größter Wert, nicht
  die Obergrenze eines Resümees.
  """

  @standard 150
  @untergrenze 30
  @obergrenze 1000
  @faktor 2

  @doc "Der Standard, wenn für die Kampagne nichts gesetzt ist."
  @spec standard() :: pos_integer()
  def standard, do: @standard

  @doc "Der kleinste erlaubte Wert."
  @spec untergrenze() :: pos_integer()
  def untergrenze, do: @untergrenze

  @doc "Der größte erlaubte Wert."
  @spec obergrenze() :: pos_integer()
  def obergrenze, do: @obergrenze

  @doc """
  Prüft einen Wert — eine Zahl oder, aus einem Formular, einen Text.
  `{:ok, n}` für eine ganze Zahl im Wertebereich, `:leer` für `nil` oder
  leeren Text (heißt: Standard), sonst `{:error, :ungueltig}`.
  """
  @spec pruefen(term()) :: {:ok, pos_integer()} | :leer | {:error, :ungueltig}
  def pruefen(nil), do: :leer

  def pruefen(n) when is_integer(n) and n >= @untergrenze and n <= @obergrenze, do: {:ok, n}

  def pruefen(t) when is_binary(t) do
    case String.trim(t) do
      "" ->
        :leer

      s ->
        case Integer.parse(s) do
          {n, ""} -> pruefen(n)
          _ -> {:error, :ungueltig}
        end
    end
  end

  def pruefen(_), do: {:error, :ungueltig}

  @doc "Der Wert, der gilt: ein gültiger Wert, sonst der Standard."
  @spec wirksam(term()) :: pos_integer()
  def wirksam(wert) do
    case pruefen(wert) do
      {:ok, n} -> n
      _ -> @standard
    end
  end

  @doc """
  Wie viele Wörter ein Resümee mit diesem Ziel höchstens hat: das Doppelte
  des wirksamen Ziels (`wirksam/1`, also auch für `nil` oder einen ungültigen
  Wert), beim Standard 150 also 300.
  """
  @spec hoechstens(term()) :: pos_integer()
  def hoechstens(ziel), do: @faktor * wirksam(ziel)
end
