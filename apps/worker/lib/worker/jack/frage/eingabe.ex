defmodule Worker.Jack.Frage.Eingabe do
  @moduledoc """
  Die Eingabe des Frage-Jack (#850, Epic #1195).

  Anders als die vier Jacks der Pipeline beantwortet dieser Jack eine **Frage
  an die Kampagne**, nicht eine Aufgabe an einer Sitzung. Daraus folgen zwei
  Unterschiede, und beide sind der Grund, warum es eine eigene Eingabe gibt:

    * **Der Bezugsrahmen ist die Kampagne.** Wie der Chronik-Jack (#1211)
      bekommt er `Worker.Jack.Chronik.Eingabe.alle_fakten/1` — alle geprüften
      Fakten aller Sitzungen. Die Lesebasis des Resümee-Jack ist
      sitzungsbezogen („ohne `sitzung` die Fakten dieser Sitzung"); ohne diese
      Erweiterung bekäme eine Kampagnenfrage einen Bruchteil und hielte ihn
      für alles.
    * **Die Frage reist mit** (`frage`) und ist der einzige Teil der Eingabe,
      der von aussen kommt. Sie steht im Auftrag als abgesetzter Datenblock,
      nie als Anweisungssatz — siehe `Worker.Jack.Frage.auftrag/1`.

  Als Sitzungsanker dient die jüngste Sitzung **mit Fakten**. Die Lesebasis
  braucht eine (Mitschnitt, `sitzung.nummer`, `fruehere`), und „jüngste" allein
  reicht nicht: Sitzungen werden angelegt, bevor sie bespielt sind — am ersten
  echten Lauf gegen eine Kampagne mit vier Sitzungen (Fakten nur in 1 und 2)
  scheiterte die Eingabe deshalb mit `{:error, :no_facts}`, obwohl 208 Fakten
  dalagen. Eine leere jüngste Sitzung ist der Normalfall, nicht der Ausreißer.
  """

  alias Worker.Jack.Chronik.Eingabe, as: Chronik
  alias Worker.Jack.Resuemee.Eingabe, as: Basis

  @doc """
  Die Eingabe für eine Frage an eine Kampagne.

  `{:error, :keine_sitzung}`, wenn die Kampagne keine Sitzung **mit Fakten**
  hat — dann gibt es nichts zu fragen, und die Lesebasis hätte keinen Anker.
  """
  @spec aus_repo(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def aus_repo(campaign_id, frage) when is_binary(campaign_id) and is_binary(frage) do
    with {:ok, session_id} <- anker(campaign_id),
         {:ok, basis} <- Basis.aus_repo(session_id) do
      {:ok, zusaetze(basis, frage)}
    end
  end

  @doc """
  Die Sitzung, an der die Lesebasis hängt: die jüngste **mit Fakten**.

  Pur ab der Sitzungsliste, damit ein Test die Auswahl ohne Repo prüfen kann.
  `hat_fakten?` sagt für eine Sitzungs-ID, ob Fakten vorliegen.
  """
  @spec anker_aus([map()], (String.t() -> boolean())) :: {:ok, String.t()} | {:error, term()}
  def anker_aus([], _hat_fakten?), do: {:error, :keine_sitzung}

  def anker_aus(sessions, hat_fakten?) do
    sessions
    |> Enum.sort_by(& &1.number)
    |> Enum.reverse()
    |> Enum.find(&hat_fakten?.(&1.id))
    |> case do
      nil -> {:error, :keine_sitzung}
      s -> {:ok, s.id}
    end
  end

  @doc """
  Die Lesebasis mit dem, was nur die Frage braucht. Pur, damit ein Test sie
  ohne Repo bauen kann (Muster `Worker.Jack.Chronik.Eingabe.zusaetze/2`).
  """
  @spec zusaetze(map(), String.t()) :: map()
  def zusaetze(basis, frage) do
    basis
    |> Map.delete(:max_woerter)
    |> Map.merge(%{
      art: :frage,
      frage: frage,
      fakten: Chronik.alle_fakten(basis)
    })
  end

  @doc "Die Frage aus einer Eingabe; ohne sie ein leerer Text."
  @spec frage(map()) :: String.t()
  def frage(eingabe), do: Map.get(eingabe, :frage) || ""

  defp anker(campaign_id),
    do: anker_aus(Worker.Repo.list_sessions(campaign_id), &fakten?/1)

  defp fakten?(session_id) do
    case Worker.Repo.get_session_facts(session_id) do
      %{facts: [_ | _]} -> true
      _ -> false
    end
  end
end
