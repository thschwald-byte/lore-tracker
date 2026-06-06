defmodule LoreTracker.Credo.Check.RawEventBridgePublish do
  @moduledoc """
  Issue #614 (Silent-Failure-Prävention): roher `Hub.EventBridge.publish/1,2`
  in einer LiveView umgeht den `HubWeb.CampaignLive.Publisher.publish/2`-Wrapper
  — und damit den #215-Cold-Fail-Pfad (Self-Message → Flash bei
  `{:error, :no_worker_online}` statt stillem Verschlucken des Events).

  Es ist dasselbe Designversagen wie bei der Stored-XSS (#604, vgl.
  `UnescapedMarkdownRender`): es gibt nebeneinander ein **sicheres**
  (`Publisher.publish/2`, Flash bei Cold-Fail) und ein **unsicheres**
  (`EventBridge.publish/1,2`, still) API, und das unsichere trägt den
  bequemeren Namen + bleibt frei aufrufbar. Ein Kommentar ist keine
  Durchsetzung — dieser Check ist die Durchsetzung (vgl. #613).

  **Warum AST statt Regex**: `EventBridge.publish` und das aliasierte
  `Hub.EventBridge.publish` sind verschiedene Quelltext-Strings, aber derselbe
  Dot-Call-Head im AST (`List.last(mods) == :EventBridge`) — beide werden
  erfasst, Arity egal (gepiped + direkt). Eine Erwähnung im `@moduledoc` ist
  kein Call-Knoten und kann gar nicht erst zum False-Positive werden.

  Ausgenommen: `campaign_live/publisher.ex` selbst (der legitime Wrapper). Ein
  LiveView-Pfad, der bewusst roh publishen MUSS, annotiert die Zeile mit
  `# credo:disable-for-this-line LoreTracker.Credo.Check.RawEventBridgePublish`
  + Begründung.
  """
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Roher Hub.EventBridge.publish/1,2 in einer LiveView umgeht den
      Publisher.publish/2-Wrapper (#215-Flash bei :no_worker_online) → Event
      kann still verloren gehen. Publisher.publish/2 nutzen.
      """
    ]

  alias Credo.IssueMeta
  alias Credo.SourceFile

  @impl true
  def run(%SourceFile{} = source_file, params) do
    if lv_file?(source_file.filename) and not publisher_file?(source_file.filename) do
      issue_meta = IssueMeta.for(source_file, params)

      source_file
      |> SourceFile.ast()
      |> collect([])
      |> Enum.sort()
      |> Enum.uniq()
      |> Enum.map(&issue_for(issue_meta, &1))
    else
      []
    end
  end

  # Nur die LiveView-Schicht — ein EventBridge.publish in Controllern/Mix-Tasks
  # hat keinen Publisher-Wrapper als Alternative (der ist LiveView-spezifisch).
  defp lv_file?(filename), do: String.contains?(filename, "/hub_web/live/")

  # Der Wrapper selbst — er IST der sichere Pfad.
  defp publisher_file?(filename),
    do: String.ends_with?(filename, "campaign_live/publisher.ex")

  # `…EventBridge.publish(…)` — Arity egal (publish/1 + publish/2 + gepiped).
  defp collect(
         {{:., _, [{:__aliases__, _, mods}, :publish]}, meta, args},
         acc
       )
       when is_list(mods) and is_list(args) do
    acc =
      if List.last(mods) == :EventBridge,
        do: [Keyword.get(meta, :line, 0) | acc],
        else: acc

    collect(args, acc)
  end

  defp collect({_form, _meta, args}, acc), do: collect(args, acc)
  defp collect(list, acc) when is_list(list), do: Enum.reduce(list, acc, &collect/2)
  defp collect({l, r}, acc), do: collect(r, collect(l, acc))
  defp collect(_other, acc), do: acc

  defp issue_for(issue_meta, line_no) do
    format_issue(
      issue_meta,
      message:
        "Roher EventBridge.publish in einer LiveView umgeht den " <>
          "Publisher.publish/2-Cold-Fail-Pfad (#215) → Event still verloren. " <>
          "Publisher.publish/2 nutzen.",
      line_no: line_no,
      trigger: "EventBridge.publish"
    )
  end
end
