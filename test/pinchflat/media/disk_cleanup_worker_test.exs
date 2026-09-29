defmodule Pinchflat.Media.DiskCleanupWorkerTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Media.DiskCleanupWorker

  setup do
    stub(UserScriptRunnerMock, :run, fn _event_type, _data -> {:ok, "", 0} end)

    :ok
  end

  describe "perform/1" do
    test "deletes media that no longer matches its source's title filter" do
      source = source_fixture(%{title_filter_regex: "^(?!EN)"})
      dropped = media_item_with_attachments(%{source_id: source.id, title: "EN in English"})
      kept = media_item_with_attachments(%{source_id: source.id, title: "NL in het Nederlands"})

      perform_job(DiskCleanupWorker, %{})

      refute File.exists?(dropped.media_filepath)
      assert File.exists?(kept.media_filepath)

      dropped = Repo.reload!(dropped)
      refute dropped.media_filepath
      refute dropped.prevent_download
    end

    test "leaves media alone whose only problem is prevent_download" do
      source = source_fixture()
      media_item = media_item_with_attachments(%{source_id: source.id, prevent_download: true})

      perform_job(DiskCleanupWorker, %{})

      assert File.exists?(media_item.media_filepath)
    end

    test "deletes media that has prevent_download and another reason" do
      source = source_fixture(%{title_filter_regex: "^keep"})
      _kept = media_item_with_attachments(%{source_id: source.id, title: "keep me"})
      media_item = media_item_with_attachments(%{source_id: source.id, title: "drop", prevent_download: true})

      perform_job(DiskCleanupWorker, %{})

      refute File.exists?(media_item.media_filepath)
    end

    test "doesn't empty a whole source over a title filter that matches nothing" do
      source = source_fixture(%{title_filter_regex: "^tpyo"})
      first = media_item_with_attachments(%{source_id: source.id, title: "one"})
      second = media_item_with_attachments(%{source_id: source.id, title: "two"})

      perform_job(DiskCleanupWorker, %{})

      assert File.exists?(first.media_filepath)
      assert File.exists?(second.media_filepath)
    end

    test "removes orphans older than a day, and nothing younger" do
      old = orphan_file("aborted.f137.mp4.part", hours_ago: 30)
      young = orphan_file("slow.f137.mp4.part", hours_ago: 12)

      perform_job(DiskCleanupWorker, %{})

      refute File.exists?(old)
      assert File.exists?(young)
    end
  end

  defp orphan_file(name, hours_ago: hours_ago) do
    dir = Path.join(Application.get_env(:pinchflat, :media_directory), "orphans-#{:rand.uniform(1_000_000)}")
    path = Path.join(dir, name)
    File.mkdir_p!(dir)
    File.write!(path, "x")
    File.touch!(path, System.os_time(:second) - hours_ago * 3600)

    path
  end
end
