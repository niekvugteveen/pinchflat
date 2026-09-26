defmodule PinchflatWeb.Api.V1.MediaItemControllerTest do
  use PinchflatWeb.ConnCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Settings

  setup do
    {:ok, %{token: Settings.get!(:route_token), source: source_fixture()}}
  end

  defp auth_conn(conn, token) do
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  describe "index" do
    test "returns 401 without a token", %{conn: conn, source: source} do
      conn = get(conn, ~p"/api/v1/sources/#{source.id}/media_items")

      assert json_response(conn, 401)
    end

    test "lists the source's media items newest first", %{conn: conn, token: token, source: source} do
      older = media_item_fixture(source_id: source.id, title: "Older", uploaded_at: ~U[2026-01-01 00:00:00Z])
      newer = media_item_fixture(source_id: source.id, title: "Newer", uploaded_at: ~U[2026-02-01 00:00:00Z])
      _other_source = media_item_fixture(title: "Elsewhere")

      conn = conn |> auth_conn(token) |> get(~p"/api/v1/sources/#{source.id}/media_items")

      assert %{"source_id" => source_id, "media_items" => items} = json_response(conn, 200)
      assert source_id == source.id
      assert Enum.map(items, & &1["id"]) == [newer.id, older.id]
      assert hd(items)["media_id"] == newer.media_id
      assert hd(items)["downloaded"] == true
    end

    test "includes items that are not downloaded or will never be", %{conn: conn, token: token, source: source} do
      media_item_fixture(source_id: source.id, media_filepath: nil, prevent_download: true)

      conn = conn |> auth_conn(token) |> get(~p"/api/v1/sources/#{source.id}/media_items")

      assert [%{"prevent_download" => true, "downloaded" => false}] = json_response(conn, 200)["media_items"]
    end

    test "filters on a case-insensitive title substring", %{conn: conn, token: token, source: source} do
      media_item_fixture(source_id: source.id, title: "Aflevering #420 - Bitcoin")
      media_item_fixture(source_id: source.id, title: "Aflevering #419 - Ethereum")

      conn = conn |> auth_conn(token) |> get(~p"/api/v1/sources/#{source.id}/media_items", %{q: "BITCOIN"})

      assert [%{"title" => "Aflevering #420 - Bitcoin"}] = json_response(conn, 200)["media_items"]
    end

    test "treats LIKE wildcards in the search term literally", %{conn: conn, token: token, source: source} do
      media_item_fixture(source_id: source.id, title: "100% bitcoin")
      media_item_fixture(source_id: source.id, title: "1000 bitcoin")

      conn = conn |> auth_conn(token) |> get(~p"/api/v1/sources/#{source.id}/media_items", %{q: "100%"})

      assert [%{"title" => "100% bitcoin"}] = json_response(conn, 200)["media_items"]
    end

    test "can exclude or select shorts before applying the limit", %{conn: conn, token: token, source: source} do
      episode =
        media_item_fixture(source_id: source.id, short_form_content: false, uploaded_at: ~U[2026-01-01 00:00:00Z])

      short = media_item_fixture(source_id: source.id, short_form_content: true, uploaded_at: ~U[2026-02-01 00:00:00Z])

      path = ~p"/api/v1/sources/#{source.id}/media_items"

      conn = conn |> auth_conn(token) |> get(path, %{shorts: "exclude", limit: "1"})
      assert [%{"id" => id}] = json_response(conn, 200)["media_items"]
      assert id == episode.id

      conn = build_conn() |> auth_conn(token) |> get(path, %{shorts: "only"})
      assert [%{"id" => id}] = json_response(conn, 200)["media_items"]
      assert id == short.id

      conn = build_conn() |> auth_conn(token) |> get(path)
      assert length(json_response(conn, 200)["media_items"]) == 2
    end

    test "respects and caps the limit", %{conn: conn, token: token, source: source} do
      for _ <- 1..3, do: media_item_fixture(source_id: source.id)

      conn = conn |> auth_conn(token) |> get(~p"/api/v1/sources/#{source.id}/media_items", %{limit: "2"})
      assert length(json_response(conn, 200)["media_items"]) == 2

      conn = build_conn() |> auth_conn(token) |> get(~p"/api/v1/sources/#{source.id}/media_items", %{limit: "0"})
      assert json_response(conn, 422)
    end

    test "returns 404 for an unknown source", %{conn: conn, token: token} do
      conn = conn |> auth_conn(token) |> get(~p"/api/v1/sources/999999/media_items")

      assert %{"error" => "not_found"} = json_response(conn, 404)
    end
  end
end
