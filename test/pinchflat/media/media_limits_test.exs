defmodule Pinchflat.Media.MediaLimitsTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Media.MediaLimits

  setup do
    stub(UserScriptRunnerMock, :run, fn _event_type, _data -> {:ok, "", 0} end)

    :ok
  end

  describe "limited?/1" do
    test "is false when the source has no media limit" do
      refute MediaLimits.limited?(source_fixture(%{media_limit: nil}))
    end

    test "is true when the source has a media limit" do
      assert MediaLimits.limited?(source_fixture(%{media_limit: 5}))
    end
  end

  describe "list_downloadable_media_items_for/1 when the source has no limit" do
    test "returns every pending media item" do
      source = source_fixture(%{media_limit: nil})
      media_items = Enum.map(1..3, fn days_ago -> pending_media_item(source, days_ago) end)

      assert ids(MediaLimits.list_downloadable_media_items_for(source)) == ids(media_items)
    end
  end

  describe "list_downloadable_media_items_for/1 when waiting for a free slot" do
    test "returns the newest media items up to the limit" do
      source = limited_source(2, :wait_for_slot)
      newest = pending_media_item(source, 1)
      middle = pending_media_item(source, 2)
      _oldest = pending_media_item(source, 3)

      assert ids(MediaLimits.list_downloadable_media_items_for(source)) == ids([newest, middle])
    end

    test "counts already-downloaded media items against the limit" do
      source = limited_source(2, :wait_for_slot)
      _downloaded = downloaded_media_item(source, 1)
      next_up = pending_media_item(source, 2)
      _oldest = pending_media_item(source, 3)

      assert ids(MediaLimits.list_downloadable_media_items_for(source)) == ids([next_up])
    end

    test "returns nothing once the limit is full" do
      source = limited_source(1, :wait_for_slot)
      _downloaded = downloaded_media_item(source, 1)
      _pending = pending_media_item(source, 2)

      assert MediaLimits.list_downloadable_media_items_for(source) == []
    end

    test "doesn't return media items that aren't pending" do
      source = limited_source(5, :wait_for_slot)
      pending = pending_media_item(source, 1)
      _prevented = pending_media_item(source, 2, %{prevent_download: true})

      assert ids(MediaLimits.list_downloadable_media_items_for(source)) == ids([pending])
    end
  end

  describe "list_downloadable_media_items_for/1 when deleting the oldest media" do
    test "returns the newest media items up to the limit" do
      source = limited_source(2, :delete_oldest)
      newest = pending_media_item(source, 1)
      middle = pending_media_item(source, 2)
      _oldest = pending_media_item(source, 3)

      assert ids(MediaLimits.list_downloadable_media_items_for(source)) == ids([newest, middle])
    end

    test "doesn't return media items that have already been downloaded" do
      source = limited_source(2, :delete_oldest)
      _downloaded = downloaded_media_item(source, 1)
      pending = pending_media_item(source, 2)
      _oldest = pending_media_item(source, 3)

      assert ids(MediaLimits.list_downloadable_media_items_for(source)) == ids([pending])
    end

    test "doesn't return media items older than the ones already on-disk" do
      source = limited_source(2, :delete_oldest)
      _newest = downloaded_media_item(source, 1)
      _middle = downloaded_media_item(source, 2)
      _oldest = pending_media_item(source, 3)

      assert MediaLimits.list_downloadable_media_items_for(source) == []
    end
  end

  describe "downloadable?/1" do
    test "is true for a pending media item that fits within the limit" do
      source = limited_source(1, :wait_for_slot)
      media_item = pending_media_item(source, 1)

      assert MediaLimits.downloadable?(media_item)
    end

    test "is false for a pending media item that doesn't fit within the limit" do
      source = limited_source(1, :wait_for_slot)
      _newest = pending_media_item(source, 1)
      media_item = pending_media_item(source, 2)

      refute MediaLimits.downloadable?(media_item)
    end

    test "falls back to pending-ness for sources without a limit" do
      source = source_fixture(%{media_limit: nil})

      assert MediaLimits.downloadable?(pending_media_item(source, 1))
      refute MediaLimits.downloadable?(downloaded_media_item(source, 2))
    end
  end

  describe "enforce_limit_for/1 when the source has no limit" do
    test "doesn't delete anything" do
      source = source_fixture(%{media_limit: nil})
      media_items = Enum.map(1..3, fn days_ago -> downloaded_media_item(source, days_ago) end)

      assert :ok = MediaLimits.enforce_limit_for(source)

      Enum.each(media_items, fn media_item -> assert File.exists?(media_item.media_filepath) end)
    end
  end

  describe "enforce_limit_for/1 when deleting the oldest media" do
    test "deletes the media files of everything past the limit" do
      source = limited_source(2, :delete_oldest)
      newest = downloaded_media_item(source, 1)
      middle = downloaded_media_item(source, 2)
      oldest = downloaded_media_item(source, 3)

      assert :ok = MediaLimits.enforce_limit_for(source)

      assert File.exists?(newest.media_filepath)
      assert File.exists?(middle.media_filepath)
      refute File.exists?(oldest.media_filepath)

      assert Repo.reload!(middle).media_filepath
      refute Repo.reload!(oldest).media_filepath
    end

    test "sets culled_at but not prevent_download so a bigger limit brings media back" do
      source = limited_source(1, :delete_oldest)
      _newest = downloaded_media_item(source, 1)
      oldest = downloaded_media_item(source, 2)

      assert :ok = MediaLimits.enforce_limit_for(source)

      assert Repo.reload!(oldest).culled_at
      refute Repo.reload!(oldest).prevent_download
    end

    test "doesn't delete media items that have prevent_culling set" do
      source = limited_source(1, :delete_oldest)
      _newest = downloaded_media_item(source, 1)
      oldest = downloaded_media_item(source, 2, %{prevent_culling: true})

      assert :ok = MediaLimits.enforce_limit_for(source)

      assert File.exists?(oldest.media_filepath)
      assert Repo.reload!(oldest).media_filepath
    end

    test "doesn't delete anything when the source is under its limit" do
      source = limited_source(5, :delete_oldest)
      media_items = Enum.map(1..3, fn days_ago -> downloaded_media_item(source, days_ago) end)

      assert :ok = MediaLimits.enforce_limit_for(source)

      Enum.each(media_items, fn media_item -> assert File.exists?(media_item.media_filepath) end)
    end
  end

  describe "enforce_limit_for/1 when waiting for a free slot" do
    test "doesn't delete anything, even when over the limit" do
      source = limited_source(1, :wait_for_slot)
      media_items = Enum.map(1..3, fn days_ago -> downloaded_media_item(source, days_ago) end)

      assert :ok = MediaLimits.enforce_limit_for(source)

      Enum.each(media_items, fn media_item -> assert File.exists?(media_item.media_filepath) end)
    end

    test "frees up the slot of media that's been deleted from outside Pinchflat" do
      source = limited_source(2, :wait_for_slot)
      kept = downloaded_media_item(source, 1)
      watched = downloaded_media_item(source, 2)

      File.rm!(watched.media_filepath)

      assert :ok = MediaLimits.enforce_limit_for(source)

      assert Repo.reload!(kept).media_filepath
      refute Repo.reload!(watched).media_filepath
    end

    test "prevents re-downloading media that's been deleted from outside Pinchflat" do
      source = limited_source(1, :wait_for_slot)
      watched = downloaded_media_item(source, 1)

      File.rm!(watched.media_filepath)

      assert :ok = MediaLimits.enforce_limit_for(source)

      assert Repo.reload!(watched).prevent_download
    end

    test "lets the next media item be downloaded once a slot is freed" do
      source = limited_source(1, :wait_for_slot)
      watched = downloaded_media_item(source, 1)
      next_up = pending_media_item(source, 2)

      assert MediaLimits.list_downloadable_media_items_for(source) == []

      File.rm!(watched.media_filepath)
      assert :ok = MediaLimits.enforce_limit_for(source)

      assert ids(MediaLimits.list_downloadable_media_items_for(source)) == ids([next_up])
    end
  end

  defp limited_source(media_limit, media_limit_behaviour) do
    source_fixture(%{media_limit: media_limit, media_limit_behaviour: media_limit_behaviour})
  end

  defp pending_media_item(source, days_ago, attrs \\ %{}) do
    attrs
    |> Map.merge(%{source_id: source.id, media_filepath: nil, uploaded_at: now_minus(days_ago, :days)})
    |> media_item_fixture()
  end

  defp downloaded_media_item(source, days_ago, attrs \\ %{}) do
    attrs
    |> Map.merge(%{
      source_id: source.id,
      uploaded_at: now_minus(days_ago, :days),
      media_downloaded_at: now_minus(days_ago, :days)
    })
    |> media_item_with_attachments()
  end

  defp ids(media_items) do
    Enum.map(media_items, & &1.id)
  end
end
