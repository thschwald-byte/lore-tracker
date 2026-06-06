# Issue #614: die zwei Präventions-Checks, die die XSS- (#604) und die Silent-
# Failure-Klasse (#613) strukturell zumachen. Wie die übrigen Custom-Checks via
# `requires` geladen + credo-App starten (runtime: false).
for f <- ~w(raw_event_bridge_publish unescaped_markdown_render) do
  Code.require_file(Path.expand("../../../../tools/credo/#{f}.ex", __DIR__))
end

{:ok, _} = Application.ensure_all_started(:credo)

defmodule LoreTracker.Credo.Check.PreventionChecksTest do
  @moduledoc """
  Issue #614 / #557-Lesson #2: pro Check ein Positiv- + Negativ-Fixture. Die
  Negativ-Fälle sperren die FP-Klassen ein — insb. den `@moduledoc`-/Kommentar-
  FP (literales „escape: false" im Doc-String ist kein AST-Keyword) und die
  Scope-/Wrapper-Ausnahmen.
  """
  use Credo.Test.Case

  alias LoreTracker.Credo.Check.RawEventBridgePublish
  alias LoreTracker.Credo.Check.UnescapedMarkdownRender

  @live "apps/hub/lib/hub_web/live/foo_live.ex"
  @web "apps/hub/lib/hub_web/live/campaign_live/components.ex"

  describe "RawEventBridgePublish" do
    test "Positiv: roher EventBridge.publish in einer LiveView wird geflaggt" do
      """
      defmodule HubWeb.FooLive do
        def save(socket, payload) do
          EventBridge.publish(payload)
          {:noreply, socket}
        end
      end
      """
      |> to_source_file(@live)
      |> run_check(RawEventBridgePublish)
      |> assert_issue(fn i -> assert i.trigger == "EventBridge.publish" end)
    end

    test "Positiv: auch das voll-qualifizierte Hub.EventBridge.publish wird geflaggt" do
      """
      defmodule HubWeb.FooLive do
        def save(p), do: Hub.EventBridge.publish(cid(), p)
      end
      """
      |> to_source_file(@live)
      |> run_check(RawEventBridgePublish)
      |> assert_issue()
    end

    test "Negativ: Publisher.publish/2 (der sichere Wrapper) bleibt still" do
      """
      defmodule HubWeb.FooLive do
        alias HubWeb.CampaignLive.Publisher
        def save(socket, payload), do: Publisher.publish(socket, payload)
      end
      """
      |> to_source_file(@live)
      |> run_check(RawEventBridgePublish)
      |> refute_issues()
    end

    test "Negativ: publisher.ex selbst (der Wrapper) ist ausgenommen" do
      """
      defmodule HubWeb.CampaignLive.Publisher do
        alias Hub.EventBridge
        def publish(socket, payload), do: EventBridge.publish(cid(socket), payload)
      end
      """
      |> to_source_file("apps/hub/lib/hub_web/live/campaign_live/publisher.ex")
      |> run_check(RawEventBridgePublish)
      |> refute_issues()
    end

    test "Negativ: EventBridge.publish außerhalb der LiveView-Schicht ist out-of-scope" do
      """
      defmodule HubWeb.SomeController do
        def create(conn, p), do: Hub.EventBridge.publish(p)
      end
      """
      |> to_source_file("apps/hub/lib/hub_web/controllers/some_controller.ex")
      |> run_check(RawEventBridgePublish)
      |> refute_issues()
    end
  end

  describe "UnescapedMarkdownRender" do
    test "Positiv: Earmark.as_html(_, escape: false) wird geflaggt" do
      """
      defmodule HubWeb.CampaignLive.Components do
        def render_md(text) do
          {:ok, html, _} = Earmark.as_html(text, escape: false)
          Phoenix.HTML.raw(html)
        end
      end
      """
      |> to_source_file(@web)
      |> run_check(UnescapedMarkdownRender)
      |> assert_issue(fn i -> assert i.trigger == "Earmark.as_html" end)
    end

    test "Negativ: escape: true (render_md_safe-Vertrag) bleibt still" do
      """
      defmodule HubWeb.CampaignLive.Components do
        def render_md_safe(text) do
          {:ok, html, _} = Earmark.as_html(text, escape: true)
          html |> HtmlSanitizeEx.basic_html() |> Phoenix.HTML.raw()
        end
      end
      """
      |> to_source_file(@web)
      |> run_check(UnescapedMarkdownRender)
      |> refute_issues()
    end

    test "Negativ (FP-Sperre): \"escape: false\" im @moduledoc bleibt still" do
      ~S'''
      defmodule HubWeb.CampaignLive.Components do
        @moduledoc "Vertrag: NIE Earmark.as_html(text, escape: false) — Stored-XSS."
        def go, do: :ok
      end
      '''
      |> to_source_file(@web)
      |> run_check(UnescapedMarkdownRender)
      |> refute_issues()
    end

    test "Negativ: escape: false außerhalb des Hub-Web-Layers ist out-of-scope" do
      """
      defmodule Worker.Report do
        def render(text), do: Earmark.as_html(text, escape: false)
      end
      """
      |> to_source_file("apps/worker/lib/worker/report.ex")
      |> run_check(UnescapedMarkdownRender)
      |> refute_issues()
    end
  end
end
