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

  Als Sitzungsanker dient die **jüngste** Sitzung der Kampagne: Die Lesebasis
  braucht eine (Mitschnitt, `sitzung.nummer`, `fruehere`), und die jüngste ist
  die, auf die sich „zuletzt" in einer Frage bezieht.
  """

  alias Worker.Jack.Chronik.Eingabe, as: Chronik
  alias Worker.Jack.Resuemee.Eingabe, as: Basis

  @doc """
  Die Eingabe für eine Frage an eine Kampagne.

  `{:error, :keine_sitzung}`, wenn die Kampagne keine Sitzung hat — dann gibt
  es nichts zu fragen, und die Lesebasis hätte keinen Anker.
  """
  @spec aus_repo(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def aus_repo(campaign_id, frage) when is_binary(campaign_id) and is_binary(frage) do
    with {:ok, session_id} <- juengste_sitzung(campaign_id),
         {:ok, basis} <- Basis.aus_repo(session_id) do
      {:ok, zusaetze(basis, frage)}
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

  defp juengste_sitzung(campaign_id) do
    case Worker.Repo.list_sessions(campaign_id) do
      [] -> {:error, :keine_sitzung}
      sessions -> {:ok, sessions |> List.last() |> Map.fetch!(:id)}
    end
  end
end
