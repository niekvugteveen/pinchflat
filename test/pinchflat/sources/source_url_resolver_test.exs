defmodule Pinchflat.Sources.SourceUrlResolverTest do
  use Pinchflat.DataCase

  import Pinchflat.SourcesFixtures

  alias Pinchflat.Sources.SourceUrlResolver

  describe "video_url?/1" do
    test "returns true for the URL shapes the Source changeset rejects" do
      assert SourceUrlResolver.video_url?("https://www.youtube.com/watch?v=abc123")
      assert SourceUrlResolver.video_url?("https://www.youtube.com/shorts/abc123")
      assert SourceUrlResolver.video_url?("https://www.youtube.com/embed/abc123")
      assert SourceUrlResolver.video_url?("https://youtu.be/abc123")
    end

    test "returns false for channel and playlist URLs" do
      refute SourceUrlResolver.video_url?("https://www.youtube.com/@SomeChannel")
      refute SourceUrlResolver.video_url?("https://www.youtube.com/channel/UC123")
      refute SourceUrlResolver.video_url?("https://www.youtube.com/playlist?list=PL123")
    end

    test "returns false for non-youtube URLs" do
      refute SourceUrlResolver.video_url?("https://example.com/watch/abc123")
    end
  end

  describe "resolve/1" do
    test "returns non-video URLs unchanged without calling yt-dlp" do
      url = "https://www.youtube.com/@SomeChannel"

      assert {:ok, ^url} = SourceUrlResolver.resolve(url)
    end

    test "returns non-youtube URLs unchanged" do
      url = "https://example.com/some/feed"

      assert {:ok, ^url} = SourceUrlResolver.resolve(url)
    end

    test "resolves a video URL to its channel URL" do
      expect(YtDlpRunnerMock, :run, fn _url, :get_source_details, _opts, _ot, _addl ->
        {:ok, source_details_return_fixture(%{channel_id: "UC_the_channel"})}
      end)

      assert {:ok, "https://www.youtube.com/channel/UC_the_channel"} =
               SourceUrlResolver.resolve("https://www.youtube.com/watch?v=abc123")
    end

    test "returns an error rather than falling through when yt-dlp returns no channel ID" do
      expect(YtDlpRunnerMock, :run, fn _url, :get_source_details, _opts, _ot, _addl ->
        {:ok, Phoenix.json_library().encode!(%{channel_id: nil})}
      end)

      assert {:error, message} = SourceUrlResolver.resolve("https://youtu.be/abc123")
      assert message =~ "channel ID"
    end

    test "returns yt-dlp's own error message" do
      expect(YtDlpRunnerMock, :run, fn _url, :get_source_details, _opts, _ot, _addl ->
        {:error, "Video unavailable", 1}
      end)

      assert {:error, "Video unavailable"} = SourceUrlResolver.resolve("https://youtu.be/abc123")
    end
  end
end
