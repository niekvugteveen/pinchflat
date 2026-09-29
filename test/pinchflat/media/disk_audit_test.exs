defmodule Pinchflat.Media.DiskAuditTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Media.DiskAudit

  setup do
    stub(UserScriptRunnerMock, :run, fn _event_type, _data -> {:ok, "", 0} end)

    :ok
  end

  describe "report/1 - ineligible media" do
    test "reports downloaded media that no longer matches the source's title filter" do
      source = source_fixture(%{title_filter_regex: "^(?!EN)"})
      dropped = media_item_with_attachments(%{source_id: source.id, title: "EN Something in English"})
      kept = media_item_with_attachments(%{source_id: source.id, title: "NL Iets in het Nederlands"})

      %{ineligible: ineligible} = DiskAudit.report()

      assert [%{id: id, reasons: [:title_filter]}] = for_source(ineligible, source)
      assert id == dropped.id
      refute Enum.any?(ineligible, &(&1.id == kept.id))
    end

    test "reports downloaded media that has prevent_download set" do
      source = source_fixture()
      media_item = media_item_with_attachments(%{source_id: source.id, prevent_download: true})

      %{ineligible: ineligible} = DiskAudit.report()

      assert [%{id: id, reasons: [:prevent_download]}] = for_source(ineligible, source)
      assert id == media_item.id
    end

    test "lists every reason that applies" do
      source = source_fixture(%{title_filter_regex: "^keep", max_age_days: 2})
      media_item_with_attachments(%{source_id: source.id, title: "drop", uploaded_at: now_minus(10, :days)})

      %{ineligible: ineligible} = DiskAudit.report()

      assert [%{reasons: reasons}] = for_source(ineligible, source)
      assert Enum.sort(reasons) == [:max_age, :title_filter]
    end

    test "leaves out media with prevent_culling, and sources that are disabled or don't download" do
      culling_prevented = source_fixture(%{title_filter_regex: "^keep"})
      disabled = source_fixture(%{title_filter_regex: "^keep", enabled: false})
      not_downloading = source_fixture(%{title_filter_regex: "^keep", download_media: false})

      media_item_with_attachments(%{source_id: culling_prevented.id, title: "drop", prevent_culling: true})
      media_item_with_attachments(%{source_id: disabled.id, title: "drop"})
      media_item_with_attachments(%{source_id: not_downloading.id, title: "drop"})

      %{ineligible: ineligible} = DiskAudit.report()

      assert for_source(ineligible, culling_prevented) == []
      assert for_source(ineligible, disabled) == []
      assert for_source(ineligible, not_downloading) == []
    end

    test "ignores media that isn't downloaded" do
      source = source_fixture(%{title_filter_regex: "^keep"})
      media_item_fixture(%{source_id: source.id, title: "drop", media_filepath: nil})

      assert for_source(DiskAudit.report().ineligible, source) == []
    end
  end

  describe "report/1 - orphans" do
    test "reports old files no media item or source refers to" do
      path = orphan_file("aborted.f137.mp4.part", hours_ago: 24)

      assert Enum.any?(DiskAudit.report().orphans, &(&1.path == path))
    end

    test "leaves out recently modified files, which may be a download in progress" do
      path = orphan_file("in-progress.f137.mp4.part", hours_ago: 1)

      refute Enum.any?(DiskAudit.report().orphans, &(&1.path == path))
      assert Enum.any?(DiskAudit.report(min_age_hours: 0).orphans, &(&1.path == path))
    end

    test "leaves out hidden files" do
      path = orphan_file(".keep", hours_ago: 24)

      refute Enum.any?(DiskAudit.report().orphans, &(&1.path == path))
    end

    test "doesn't report files that belong to a media item" do
      media_item = media_item_with_attachments()

      paths = Enum.map(DiskAudit.report(min_age_hours: 0).orphans, & &1.path)

      refute media_item.media_filepath in paths
      refute media_item.thumbnail_filepath in paths
      refute Enum.any?(media_item.subtitle_filepaths, fn [_, path] -> path in paths end)
    end
  end

  describe "fix!/1" do
    test "deletes ineligible media without preventing a later download, and removes orphans" do
      source = source_fixture(%{title_filter_regex: "^keep"})
      media_item = media_item_with_attachments(%{source_id: source.id, title: "drop"})
      orphan = orphan_file("left-behind.temp.mp4", hours_ago: 24)

      report = %{ineligible: for_source(DiskAudit.report().ineligible, source), orphans: [%{path: orphan}]}

      assert %{deleted_media: 1, deleted_orphans: 1} = DiskAudit.fix!(report)

      refute File.exists?(media_item.media_filepath)
      refute File.exists?(orphan)

      media_item = Repo.reload!(media_item)
      refute media_item.media_filepath
      refute media_item.prevent_download
      assert media_item.culled_at
    end
  end

  defp for_source(ineligible, source) do
    Enum.filter(ineligible, &(&1.source == source.custom_name && source_media_ids(source) |> MapSet.member?(&1.id)))
  end

  defp source_media_ids(source) do
    Pinchflat.Media.MediaItem
    |> where(source_id: ^source.id)
    |> select([mi], mi.id)
    |> Repo.all()
    |> MapSet.new()
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
