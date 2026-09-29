defmodule Pinchflat.Downloading.WatchedMediaWorkerTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Downloading.MediaDownloadWorker
  alias Pinchflat.Downloading.WatchedMediaWorker

  @jellyfin_media_path "/media/youtube"

  setup do
    stub(UserScriptRunnerMock, :run, fn _event_type, _data -> {:ok, "", 0} end)

    Application.put_env(:pinchflat, :jellyfin_url, "http://jellyfin:8096")
    Application.put_env(:pinchflat, :jellyfin_api_key, "abc123")
    Application.put_env(:pinchflat, :jellyfin_media_path, @jellyfin_media_path)
    Application.put_env(:pinchflat, :watched_grace_hours, 12)

    on_exit(fn ->
      Enum.each(~w(jellyfin_url jellyfin_api_key jellyfin_media_path watched_grace_hours)a, fn key ->
        Application.delete_env(:pinchflat, key)
      end)
    end)

    :ok
  end

  describe "perform/1" do
    test "deletes watched media and prevents it from being downloaded again" do
      source = source_fixture(%{delete_watched_media: true})
      watched = downloaded_media_item(source, 1)
      unwatched = downloaded_media_item(source, 2)

      stub_jellyfin([played(watched, hours_ago: 13)])

      perform_job(WatchedMediaWorker, %{})

      refute File.exists?(watched.media_filepath)
      assert File.exists?(unwatched.media_filepath)

      watched = Repo.reload!(watched)
      assert watched.prevent_download
      assert watched.culled_at
      refute watched.media_filepath
    end

    test "leaves media alone that was played within the grace period" do
      source = source_fixture(%{delete_watched_media: true})
      just_watched = downloaded_media_item(source, 1)

      stub_jellyfin([played(just_watched, hours_ago: 2)])

      perform_job(WatchedMediaWorker, %{})

      assert File.exists?(just_watched.media_filepath)
    end

    test "treats media without a last played date as past the grace period" do
      source = source_fixture(%{delete_watched_media: true})
      watched = downloaded_media_item(source, 1)

      stub_jellyfin([%{"Path" => jellyfin_path(watched), "UserData" => %{"Played" => true}}])

      perform_job(WatchedMediaWorker, %{})

      refute File.exists?(watched.media_filepath)
    end

    test "leaves sources alone that don't delete watched media" do
      source = source_fixture(%{delete_watched_media: false})
      watched = downloaded_media_item(source, 1)

      expect(HTTPClientMock, :get, 0, fn _url, _headers, _opts -> {:ok, "[]"} end)

      perform_job(WatchedMediaWorker, %{})

      assert File.exists?(watched.media_filepath)
    end

    test "leaves disabled sources alone" do
      source = source_fixture(%{enabled: false, delete_watched_media: true})
      watched = downloaded_media_item(source, 1)

      stub_jellyfin([played(watched, hours_ago: 24)])

      perform_job(WatchedMediaWorker, %{})

      assert File.exists?(watched.media_filepath)
    end

    test "respects prevent_culling" do
      source = source_fixture(%{delete_watched_media: true})
      keeper = downloaded_media_item(source, 1)
      Repo.update!(Ecto.Changeset.change(keeper, prevent_culling: true))

      stub_jellyfin([played(keeper, hours_ago: 24)])

      perform_job(WatchedMediaWorker, %{})

      assert File.exists?(keeper.media_filepath)
    end

    test "doesn't touch other sources' media that happens to be watched" do
      source = source_fixture(%{delete_watched_media: true})
      other_source = source_fixture(%{delete_watched_media: false})
      _unwatched = downloaded_media_item(source, 1)
      other_watched = downloaded_media_item(other_source, 1)

      stub_jellyfin([played(other_watched, hours_ago: 24)])

      perform_job(WatchedMediaWorker, %{})

      assert File.exists?(other_watched.media_filepath)
    end

    test "fills the freed-up slot with the newest media that hasn't been watched" do
      source = source_fixture(%{delete_watched_media: true, media_limit: 1, media_limit_behaviour: :delete_oldest})
      watched = downloaded_media_item(source, 1)
      next_up = media_item_fixture(%{source_id: source.id, media_filepath: nil, uploaded_at: now_minus(2, :days)})

      stub_jellyfin([played(watched, hours_ago: 24)])

      perform_job(WatchedMediaWorker, %{})

      assert_enqueued(worker: MediaDownloadWorker, args: %{"id" => next_up.id})
      refute_enqueued(worker: MediaDownloadWorker, args: %{"id" => watched.id})
    end

    test "does nothing when Jellyfin isn't configured" do
      Application.delete_env(:pinchflat, :jellyfin_url)
      source = source_fixture(%{delete_watched_media: true})
      watched = downloaded_media_item(source, 1)

      expect(HTTPClientMock, :get, 0, fn _url, _headers, _opts -> {:ok, "[]"} end)

      assert :ok = perform_job(WatchedMediaWorker, %{})
      assert File.exists?(watched.media_filepath)
    end

    test "fails the job without deleting anything when Jellyfin can't be reached" do
      source = source_fixture(%{delete_watched_media: true})
      watched = downloaded_media_item(source, 1)

      stub(HTTPClientMock, :get, fn _url, _headers, _opts -> {:error, "connection refused"} end)

      assert {:error, _} = perform_job(WatchedMediaWorker, %{})
      assert File.exists?(watched.media_filepath)
    end
  end

  defp stub_jellyfin(played_items) do
    stub(HTTPClientMock, :get, fn url, _headers, _opts ->
      cond do
        String.ends_with?(url, "/Users") -> {:ok, Phoenix.json_library().encode!([%{"Id" => "user-1"}])}
        String.contains?(url, "/Items?") -> {:ok, Phoenix.json_library().encode!(%{"Items" => played_items})}
      end
    end)
  end

  defp played(media_item, hours_ago: hours_ago) do
    last_played = DateTime.add(DateTime.utc_now(), -hours_ago, :hour)

    %{
      "Path" => jellyfin_path(media_item),
      "UserData" => %{"Played" => true, "LastPlayedDate" => DateTime.to_iso8601(last_played)}
    }
  end

  defp jellyfin_path(media_item) do
    media_directory = Application.get_env(:pinchflat, :media_directory)

    Path.join(@jellyfin_media_path, Path.relative_to(media_item.media_filepath, media_directory))
  end

  defp downloaded_media_item(source, days_ago) do
    media_item_with_attachments(%{
      source_id: source.id,
      uploaded_at: now_minus(days_ago, :days),
      media_downloaded_at: now_minus(days_ago, :days)
    })
  end
end
