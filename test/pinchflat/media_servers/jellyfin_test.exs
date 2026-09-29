defmodule Pinchflat.MediaServers.JellyfinTest do
  use Pinchflat.DataCase

  alias Pinchflat.MediaServers.Jellyfin

  setup do
    Application.put_env(:pinchflat, :jellyfin_url, "http://jellyfin:8096/")
    Application.put_env(:pinchflat, :jellyfin_api_key, "abc123")
    Application.put_env(:pinchflat, :jellyfin_media_path, "/media/youtube")

    on_exit(fn ->
      Enum.each(~w(jellyfin_url jellyfin_api_key jellyfin_media_path)a, &Application.delete_env(:pinchflat, &1))
    end)

    :ok
  end

  describe "configured?/0" do
    test "needs both a URL and an API key" do
      assert Jellyfin.configured?()

      Application.put_env(:pinchflat, :jellyfin_api_key, "")
      refute Jellyfin.configured?()

      Application.delete_env(:pinchflat, :jellyfin_api_key)
      refute Jellyfin.configured?()
    end
  end

  describe "list_watched_media/0" do
    test "asks every user what they've played, authenticating with the API key" do
      expect(HTTPClientMock, :get, fn url, headers, _opts ->
        assert url == "http://jellyfin:8096/Users"
        assert headers[:authorization] == ~s(MediaBrowser Token="abc123")

        {:ok, Phoenix.json_library().encode!([%{"Id" => "u1"}, %{"Id" => "u2"}])}
      end)

      expect(HTTPClientMock, :get, 2, fn url, _headers, _opts ->
        query = url |> URI.parse() |> Map.get(:query) |> URI.decode_query()
        assert query["isPlayed"] == "true"
        assert query["recursive"] == "true"

        {:ok, Phoenix.json_library().encode!(%{"Items" => [item("/media/youtube/shows/#{query["userId"]}.mp4")]})}
      end)

      assert {:ok, watched} = Jellyfin.list_watched_media()

      media_directory = Application.get_env(:pinchflat, :media_directory)

      assert Enum.sort(Enum.map(watched, & &1.filepath)) == [
               Path.join(media_directory, "shows/u1.mp4"),
               Path.join(media_directory, "shows/u2.mp4")
             ]
    end

    test "parses Jellyfin's seven-digit fractional seconds" do
      stub_items([item("/media/youtube/a.mp4", "2026-09-27T19:23:07.9052088Z")])

      assert {:ok, [%{last_played_at: last_played_at}]} = Jellyfin.list_watched_media()
      assert DateTime.truncate(last_played_at, :second) == ~U[2026-09-27 19:23:07Z]
    end

    test "leaves out items outside Pinchflat's media directory" do
      stub_items([item("/media/movies/a.mkv"), item("/media/youtube-other/b.mp4"), %{"Path" => nil}])

      assert {:ok, []} = Jellyfin.list_watched_media()
    end

    test "passes on a failed request" do
      stub(HTTPClientMock, :get, fn _url, _headers, _opts -> {:error, "HTTP request failed with status code 401"} end)

      assert {:error, message} = Jellyfin.list_watched_media()
      assert message =~ "401"
    end

    test "treats a response that isn't JSON as an error" do
      stub(HTTPClientMock, :get, fn _url, _headers, _opts -> {:ok, "<html>login</html>"} end)

      assert {:error, message} = Jellyfin.list_watched_media()
      assert message =~ "isn't JSON"
    end
  end

  defp stub_items(items) do
    stub(HTTPClientMock, :get, fn url, _headers, _opts ->
      if String.ends_with?(url, "/Users") do
        {:ok, Phoenix.json_library().encode!([%{"Id" => "u1"}])}
      else
        {:ok, Phoenix.json_library().encode!(%{"Items" => items})}
      end
    end)
  end

  defp item(path, last_played \\ "2026-09-27T19:23:07Z") do
    %{"Path" => path, "UserData" => %{"Played" => true, "LastPlayedDate" => last_played}}
  end
end
