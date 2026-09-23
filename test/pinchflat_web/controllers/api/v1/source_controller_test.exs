defmodule PinchflatWeb.Api.V1.SourceControllerTest do
  use PinchflatWeb.ConnCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures
  import Pinchflat.ProfilesFixtures

  alias Pinchflat.Repo
  alias Pinchflat.Settings
  alias Pinchflat.Sources.Source

  @channel_url "https://www.youtube.com/@SomeChannel"
  @video_url "https://www.youtube.com/watch?v=abc123"

  setup do
    media_profile = media_profile_fixture()
    token = Settings.get!(:route_token)

    {:ok, %{media_profile: media_profile, token: token}}
  end

  defp auth_conn(conn, token) do
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  defp expect_source_details(channel_id, name \\ "Some Channel") do
    expect(YtDlpRunnerMock, :run, fn _url, :get_source_details, _opts, _ot, _addl ->
      {:ok, source_details_return_fixture(%{channel_id: channel_id, playlist_id: channel_id, channel: name})}
    end)
  end

  describe "authentication" do
    test "returns 401 without a token", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/sources", %{url: @channel_url})

      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end

    test "returns 401 with the wrong token", %{conn: conn} do
      conn = conn |> auth_conn("nope") |> post(~p"/api/v1/sources", %{url: @channel_url})

      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end

    test "fails closed when the route_token setting is empty", %{conn: conn} do
      Settings.set(route_token: "")
      conn = conn |> auth_conn("") |> get(~p"/api/v1/sources")

      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end

    test "accepts the token as a query parameter", %{conn: conn, token: token} do
      conn = get(conn, ~p"/api/v1/sources?#{[route_token: token]}")

      assert %{"sources" => _} = json_response(conn, 200)
    end

    test "does not require basic auth even when it is configured", %{conn: conn, token: token} do
      Application.put_env(:pinchflat, :basic_auth_username, "user")
      Application.put_env(:pinchflat, :basic_auth_password, "pass")

      on_exit(fn ->
        Application.put_env(:pinchflat, :basic_auth_username, nil)
        Application.put_env(:pinchflat, :basic_auth_password, nil)
      end)

      conn = conn |> auth_conn(token) |> get(~p"/api/v1/sources")

      assert %{"sources" => _} = json_response(conn, 200)
    end
  end

  describe "index" do
    test "lists sources with their media profile name", %{conn: conn, token: token, media_profile: media_profile} do
      source = source_fixture(media_profile_id: media_profile.id)

      conn = conn |> auth_conn(token) |> get(~p"/api/v1/sources")

      assert %{"sources" => [rendered]} = json_response(conn, 200)
      assert rendered["id"] == source.id
      assert rendered["media_profile_name"] == media_profile.name
      assert rendered["collection_id"] == source.collection_id
    end
  end

  describe "create" do
    test "creates a source from a channel URL", %{conn: conn, token: token, media_profile: media_profile} do
      expect_source_details("UC_channel_1")

      conn =
        conn
        |> auth_conn(token)
        |> post(~p"/api/v1/sources", %{url: @channel_url, media_profile_id: media_profile.id})

      assert %{"created" => true, "source" => source} = json_response(conn, 201)
      assert source["collection_id"] == "UC_channel_1"
      assert source["collection_name"] == "Some Channel"
      assert source["media_profile_id"] == media_profile.id
      assert source["media_profile_name"] == media_profile.name
      assert Repo.aggregate(Source, :count) == 1
    end

    test "resolves a video URL to its channel first", %{conn: conn, token: token, media_profile: media_profile} do
      # Once to resolve the video URL, once when the source is created from the channel URL
      expect_source_details("UC_from_video")
      expect_source_details("UC_from_video")

      conn =
        conn
        |> auth_conn(token)
        |> post(~p"/api/v1/sources", %{url: @video_url, media_profile_id: media_profile.id})

      assert %{"created" => true, "source" => source} = json_response(conn, 201)
      assert source["original_url"] == "https://www.youtube.com/channel/UC_from_video"
    end

    test "is idempotent for the same channel and profile", %{conn: conn, token: token, media_profile: media_profile} do
      expect_source_details("UC_twice")
      expect_source_details("UC_twice")

      attrs = %{url: @channel_url, media_profile_id: media_profile.id}

      first = conn |> auth_conn(token) |> post(~p"/api/v1/sources", attrs)
      assert %{"created" => true, "source" => created} = json_response(first, 201)

      second = build_conn() |> auth_conn(token) |> post(~p"/api/v1/sources", attrs)
      assert %{"created" => false, "source" => existing} = json_response(second, 200)

      assert existing["id"] == created["id"]
      assert Repo.aggregate(Source, :count) == 1
    end

    test "creates a second source for a different media profile", %{conn: conn, token: token, media_profile: profile} do
      other_profile = media_profile_fixture()
      expect_source_details("UC_shared")
      expect_source_details("UC_shared")

      first =
        conn |> auth_conn(token) |> post(~p"/api/v1/sources", %{url: @channel_url, media_profile_id: profile.id})

      assert json_response(first, 201)

      second =
        build_conn()
        |> auth_conn(token)
        |> post(~p"/api/v1/sources", %{url: @channel_url, media_profile_id: other_profile.id})

      assert %{"created" => true} = json_response(second, 201)
      assert Repo.aggregate(Source, :count) == 2
    end

    test "resolves the media profile by name", %{conn: conn, token: token, media_profile: media_profile} do
      expect_source_details("UC_by_name")

      conn =
        conn
        |> auth_conn(token)
        |> post(~p"/api/v1/sources", %{url: @channel_url, media_profile_name: media_profile.name})

      assert %{"source" => source} = json_response(conn, 201)
      assert source["media_profile_id"] == media_profile.id
    end

    test "returns 422 for an unknown media profile name", %{conn: conn, token: token} do
      conn =
        conn
        |> auth_conn(token)
        |> post(~p"/api/v1/sources", %{url: @channel_url, media_profile_name: "Nope"})

      assert %{"error" => "unprocessable_entity", "errors" => errors} = json_response(conn, 422)
      assert errors["media_profile_name"] == ["does not match any media profile"]
    end

    test "returns 422 for an unknown media profile id", %{conn: conn, token: token} do
      conn =
        conn
        |> auth_conn(token)
        |> post(~p"/api/v1/sources", %{url: @channel_url, media_profile_id: 123_456})

      assert %{"errors" => errors} = json_response(conn, 422)
      assert errors["media_profile_id"] == ["does not match any media profile"]
    end

    test "returns 422 when no media profile is given", %{conn: conn, token: token} do
      conn = conn |> auth_conn(token) |> post(~p"/api/v1/sources", %{url: @channel_url})

      assert %{"errors" => errors} = json_response(conn, 422)
      assert errors["media_profile_id"] == ["either media_profile_id or media_profile_name is required"]
    end

    test "returns 400 when url is missing", %{conn: conn, token: token, media_profile: media_profile} do
      conn =
        conn |> auth_conn(token) |> post(~p"/api/v1/sources", %{media_profile_id: media_profile.id})

      assert %{"error" => "bad_request", "message" => message} = json_response(conn, 400)
      assert message =~ "url"
    end

    test "returns 400 when url is blank", %{conn: conn, token: token, media_profile: media_profile} do
      conn =
        conn
        |> auth_conn(token)
        |> post(~p"/api/v1/sources", %{url: "   ", media_profile_id: media_profile.id})

      assert json_response(conn, 400)
    end

    test "returns 502 when yt-dlp fails on a video URL", %{conn: conn, token: token, media_profile: media_profile} do
      expect(YtDlpRunnerMock, :run, fn _url, :get_source_details, _opts, _ot, _addl ->
        {:error, "Video unavailable", 1}
      end)

      conn =
        conn
        |> auth_conn(token)
        |> post(~p"/api/v1/sources", %{url: @video_url, media_profile_id: media_profile.id})

      assert %{"error" => "bad_gateway", "message" => message} = json_response(conn, 502)
      assert message =~ "Video unavailable"
      assert Repo.aggregate(Source, :count) == 0
    end

    test "returns 502 when yt-dlp fails on a channel URL", %{conn: conn, token: token, media_profile: media_profile} do
      expect(YtDlpRunnerMock, :run, fn _url, :get_source_details, _opts, _ot, _addl ->
        {:error, "Private channel"}
      end)

      conn =
        conn
        |> auth_conn(token)
        |> post(~p"/api/v1/sources", %{url: @channel_url, media_profile_id: media_profile.id})

      assert %{"error" => "bad_gateway", "message" => message} = json_response(conn, 502)
      assert message =~ "Private channel"
    end

    test "applies optional passthrough attributes", %{conn: conn, token: token, media_profile: media_profile} do
      expect_source_details("UC_with_opts")

      conn =
        conn
        |> auth_conn(token)
        |> post(~p"/api/v1/sources", %{
          url: @channel_url,
          media_profile_id: media_profile.id,
          custom_name: "Kids channel",
          media_limit: 5,
          media_limit_behaviour: "delete_oldest",
          download_media: false
        })

      assert %{"source" => source} = json_response(conn, 201)
      assert source["custom_name"] == "Kids channel"
      assert source["media_limit"] == 5
      assert source["media_limit_behaviour"] == "delete_oldest"
      assert source["download_media"] == false
    end

    test "returns 422 when the changeset rejects an attribute", %{
      conn: conn,
      token: token,
      media_profile: media_profile
    } do
      conn =
        conn
        |> auth_conn(token)
        |> post(~p"/api/v1/sources", %{
          url: @channel_url,
          media_profile_id: media_profile.id,
          media_limit: -1
        })

      assert %{"error" => "unprocessable_entity", "errors" => errors} = json_response(conn, 422)
      assert errors["media_limit"]
      assert Repo.aggregate(Source, :count) == 0
    end
  end

  describe "show" do
    test "renders every setting, not just the actionable ones", %{
      conn: conn,
      token: token,
      media_profile: media_profile
    } do
      source =
        source_fixture(
          media_profile_id: media_profile.id,
          retention_period_days: 30,
          download_cutoff_date: ~D[2025-01-01],
          min_duration_seconds: 60
        )

      conn = conn |> auth_conn(token) |> get(~p"/api/v1/sources/#{source.id}")

      assert %{"source" => rendered} = json_response(conn, 200)
      assert rendered["id"] == source.id
      assert rendered["retention_period_days"] == 30
      assert rendered["download_cutoff_date"] == "2025-01-01"
      assert rendered["min_duration_seconds"] == 60
      assert rendered["media_profile_name"] == media_profile.name
    end

    test "counts the media items that no longer meet the source's criteria", %{
      conn: conn,
      token: token,
      media_profile: media_profile
    } do
      source = source_fixture(media_profile_id: media_profile.id, retention_period_days: 30)

      # Downloaded 60 days ago, so past a 30-day retention period
      media_item_fixture(source_id: source.id, media_downloaded_at: DateTime.add(DateTime.utc_now(), -60, :day))
      # Downloaded today, so well within it
      media_item_fixture(source_id: source.id, media_downloaded_at: DateTime.utc_now())

      conn = conn |> auth_conn(token) |> get(~p"/api/v1/sources/#{source.id}")

      assert %{"stats" => stats} = json_response(conn, 200)
      assert stats["media_items_count"] == 2
      assert stats["downloaded_media_items_count"] == 2
      assert stats["pending_cull_count"] == 1
      assert stats["over_media_limit_count"] == 0
    end

    test "counts the media items that a lowered media limit puts over the window", %{
      conn: conn,
      token: token,
      media_profile: media_profile
    } do
      source = source_fixture(media_profile_id: media_profile.id, media_limit: 1)

      media_item_fixture(source_id: source.id, uploaded_at: DateTime.add(DateTime.utc_now(), -2, :day))
      media_item_fixture(source_id: source.id, uploaded_at: DateTime.utc_now())

      conn = conn |> auth_conn(token) |> get(~p"/api/v1/sources/#{source.id}")

      assert %{"stats" => %{"over_media_limit_count" => 1}} = json_response(conn, 200)
    end

    test "returns 404 for an unknown id", %{conn: conn, token: token} do
      conn = conn |> auth_conn(token) |> get(~p"/api/v1/sources/123456")

      assert %{"error" => "not_found"} = json_response(conn, 404)
    end

    test "returns 401 without a token", %{conn: conn, media_profile: media_profile} do
      source = source_fixture(media_profile_id: media_profile.id)
      conn = get(conn, ~p"/api/v1/sources/#{source.id}")

      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end
  end

  describe "update" do
    test "updates only the fields that were sent", %{conn: conn, token: token, media_profile: media_profile} do
      source = source_fixture(media_profile_id: media_profile.id, media_limit: 5, custom_name: "Keep me")

      conn =
        conn
        |> auth_conn(token)
        |> patch(~p"/api/v1/sources/#{source.id}", %{retention_period_days: 14})

      assert %{"source" => rendered} = json_response(conn, 200)
      assert rendered["retention_period_days"] == 14
      assert rendered["media_limit"] == 5
      assert rendered["custom_name"] == "Keep me"
    end

    test "clears a field when sent an explicit null", %{conn: conn, token: token, media_profile: media_profile} do
      source = source_fixture(media_profile_id: media_profile.id, download_cutoff_date: ~D[2025-01-01])

      conn =
        conn
        |> auth_conn(token)
        |> patch(~p"/api/v1/sources/#{source.id}", %{download_cutoff_date: nil})

      assert %{"source" => rendered} = json_response(conn, 200)
      assert rendered["download_cutoff_date"] == nil
    end

    test "reports what the new settings are about to delete", %{
      conn: conn,
      token: token,
      media_profile: media_profile
    } do
      source = source_fixture(media_profile_id: media_profile.id)
      media_item_fixture(source_id: source.id, media_downloaded_at: DateTime.add(DateTime.utc_now(), -60, :day))

      before = conn |> auth_conn(token) |> get(~p"/api/v1/sources/#{source.id}")
      assert %{"stats" => %{"pending_cull_count" => 0}} = json_response(before, 200)

      conn =
        build_conn()
        |> auth_conn(token)
        |> patch(~p"/api/v1/sources/#{source.id}", %{retention_period_days: 7})

      assert %{"stats" => %{"pending_cull_count" => 1}} = json_response(conn, 200)
    end

    test "accepts PUT as well as PATCH", %{conn: conn, token: token, media_profile: media_profile} do
      source = source_fixture(media_profile_id: media_profile.id)

      conn = conn |> auth_conn(token) |> put(~p"/api/v1/sources/#{source.id}", %{enabled: false})

      assert %{"source" => %{"enabled" => false}} = json_response(conn, 200)
    end

    test "does not accept fields outside the allowlist", %{conn: conn, token: token, media_profile: media_profile} do
      source = source_fixture(media_profile_id: media_profile.id)
      other_profile = media_profile_fixture()

      conn =
        conn
        |> auth_conn(token)
        |> patch(~p"/api/v1/sources/#{source.id}", %{
          media_profile_id: other_profile.id,
          original_url: "https://www.youtube.com/@SomewhereElse"
        })

      assert %{"error" => "unprocessable_entity", "updatable_fields" => fields} = json_response(conn, 422)
      refute "media_profile_id" in fields
      refute "original_url" in fields

      reloaded = Repo.reload!(source)
      assert reloaded.media_profile_id == media_profile.id
      assert reloaded.original_url == source.original_url
    end

    test "returns 422 when the changeset rejects an attribute", %{
      conn: conn,
      token: token,
      media_profile: media_profile
    } do
      source = source_fixture(media_profile_id: media_profile.id, media_limit: 5)

      conn = conn |> auth_conn(token) |> patch(~p"/api/v1/sources/#{source.id}", %{media_limit: 0})

      assert %{"error" => "unprocessable_entity", "errors" => errors} = json_response(conn, 422)
      assert errors["media_limit"]
      assert Repo.reload!(source).media_limit == 5
    end

    test "returns 404 for an unknown id", %{conn: conn, token: token} do
      conn = conn |> auth_conn(token) |> patch(~p"/api/v1/sources/123456", %{enabled: false})

      assert %{"error" => "not_found"} = json_response(conn, 404)
    end
  end
end
