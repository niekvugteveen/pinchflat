defmodule Pinchflat.Sources.SourceUrlResolver do
  @moduledoc """
  Resolves a YouTube _video_ URL into the URL of the channel that published it.

  `Source.youtube_channel_or_playlist_regex/0` deliberately rejects video URLs, but sharing
  from the YouTube app almost always yields one. Anything that accepts a shared URL therefore
  has to resolve it to a channel URL before handing it to the `Source` changeset.

  Deliberate non-goal: a `youtube.com/watch?v=...&list=...` URL resolves to the **channel**,
  not to the playlist. Keeping that simple is worth more than guessing which one was meant.

  Non-YouTube URLs are returned unchanged - the regex above tolerates them on purpose
  ("tenuous support for non-youtube sources") and this module must not break that.
  """

  alias Pinchflat.YtDlp.MediaCollection

  # Mirrors the URLs that `Source.youtube_channel_or_playlist_regex/0` rejects. These are
  # deliberately coupled: this module exists to resolve exactly what that changeset refuses.
  @video_url_regex ~r<youtube\.com/(watch|shorts|embed)|youtu\.be>

  @doc """
  Resolves a URL to something the `Source` changeset will accept.

  Video URLs are looked up with yt-dlp and turned into `https://www.youtube.com/channel/<id>`.
  Everything else is returned as-is.

  Returns {:ok, binary()} | {:error, binary()}
  """
  def resolve(url) when is_binary(url) do
    if video_url?(url) do
      resolve_video_url(url)
    else
      {:ok, url}
    end
  end

  @doc """
  Returns a boolean indicating whether the URL looks like a YouTube video URL.
  """
  def video_url?(url) when is_binary(url) do
    Regex.match?(@video_url_regex, url)
  end

  defp resolve_video_url(url) do
    # Skipping the sleep interval since a user is waiting on this response
    case MediaCollection.get_source_details(url, [], skip_sleep_interval: true) do
      {:ok, %{channel_id: channel_id}} when is_binary(channel_id) and channel_id != "" ->
        {:ok, "https://www.youtube.com/channel/#{channel_id}"}

      {:ok, _source_details} ->
        # Never fall through to the video URL - the changeset error the user would get
        # ("must be a channel or playlist URL") is misleading about what actually went wrong.
        {:error, "yt-dlp did not return a channel ID for this video URL"}

      {:error, message, _status_code} ->
        {:error, to_string(message)}

      {:error, message} ->
        {:error, to_string(message)}
    end
  end
end
