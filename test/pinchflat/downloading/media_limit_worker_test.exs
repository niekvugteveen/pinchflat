defmodule Pinchflat.Downloading.MediaLimitWorkerTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Downloading.MediaDownloadWorker
  alias Pinchflat.Downloading.MediaLimitWorker

  setup do
    stub(UserScriptRunnerMock, :run, fn _event_type, _data -> {:ok, "", 0} end)

    :ok
  end

  describe "perform/1" do
    test "deletes media that's past the limit of a delete_oldest source" do
      source = source_fixture(%{media_limit: 1, media_limit_behaviour: :delete_oldest})
      newest = downloaded_media_item(source, 1)
      oldest = downloaded_media_item(source, 2)

      perform_job(MediaLimitWorker, %{})

      assert File.exists?(newest.media_filepath)
      refute File.exists?(oldest.media_filepath)
    end

    test "frees up slots of a wait_for_slot source whose media is gone from disk" do
      source = source_fixture(%{media_limit: 1, media_limit_behaviour: :wait_for_slot})
      watched = downloaded_media_item(source, 1)

      File.rm!(watched.media_filepath)

      perform_job(MediaLimitWorker, %{})

      assert Repo.reload!(watched).prevent_download
    end

    test "enqueues downloads for the media items that now fit within the limit" do
      source = source_fixture(%{media_limit: 1, media_limit_behaviour: :wait_for_slot})
      watched = downloaded_media_item(source, 1)
      next_up = media_item_fixture(%{source_id: source.id, media_filepath: nil, uploaded_at: now_minus(2, :days)})

      File.rm!(watched.media_filepath)

      perform_job(MediaLimitWorker, %{})

      assert_enqueued(worker: MediaDownloadWorker, args: %{"id" => next_up.id})
    end

    test "doesn't enqueue downloads that don't fit within the limit" do
      source = source_fixture(%{media_limit: 1, media_limit_behaviour: :wait_for_slot})
      _downloaded = downloaded_media_item(source, 1)
      _next_up = media_item_fixture(%{source_id: source.id, media_filepath: nil, uploaded_at: now_minus(2, :days)})

      perform_job(MediaLimitWorker, %{})

      refute_enqueued(worker: MediaDownloadWorker)
    end

    test "leaves sources without a media limit alone" do
      source = source_fixture(%{media_limit: nil})
      media_item = downloaded_media_item(source, 1)
      _other_media_item = downloaded_media_item(source, 2)

      perform_job(MediaLimitWorker, %{})

      assert File.exists?(media_item.media_filepath)
      refute_enqueued(worker: MediaDownloadWorker)
    end

    test "leaves disabled sources alone" do
      source = source_fixture(%{enabled: false, media_limit: 1, media_limit_behaviour: :delete_oldest})
      _newest = downloaded_media_item(source, 1)
      oldest = downloaded_media_item(source, 2)

      perform_job(MediaLimitWorker, %{})

      assert File.exists?(oldest.media_filepath)
    end
  end

  defp downloaded_media_item(source, days_ago) do
    media_item_with_attachments(%{
      source_id: source.id,
      uploaded_at: now_minus(days_ago, :days),
      media_downloaded_at: now_minus(days_ago, :days)
    })
  end
end
