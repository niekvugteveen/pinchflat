defmodule Pinchflat.MediaServers.Jellyfin do
  @moduledoc """
  Asks a Jellyfin server what has been watched, so that sources with `delete_watched_media`
  can delete it - see `Pinchflat.Downloading.WatchedMediaWorker`.

  Configured with environment variables (read in `config/runtime.exs`):

    - `JELLYFIN_URL` - eg: `http://host.docker.internal:8096`
    - `JELLYFIN_API_KEY` - an API key from Jellyfin's dashboard. API keys act as an
      administrator, which is what's needed to see every user's watched state
    - `JELLYFIN_MEDIA_PATH` - where Jellyfin sees Pinchflat's media directory, eg: `/media/youtube`
      if Jellyfin mounts Pinchflat's `/downloads` there. Defaults to the media directory itself

  Something counts as watched once _any_ Jellyfin user has it marked as played. Clients such as
  Kodi's Jellyfin add-on report playback to the server, so this covers them too.
  """

  require Logger

  @doc """
  Whether a Jellyfin server has been configured at all.

  Returns boolean()
  """
  def configured? do
    config(:jellyfin_url) not in [nil, ""] && config(:jellyfin_api_key) not in [nil, ""]
  end

  @doc """
  Lists everything any Jellyfin user has marked as played, as paths in _Pinchflat's_ media
  directory (ie: already translated from Jellyfin's view of them). Items that sit outside
  Pinchflat's media directory are left out.

  Returns {:ok, [%{filepath: String.t(), last_played_at: DateTime.t() | nil}]} | {:error, String.t()}
  """
  def list_watched_media do
    with {:ok, users} <- get_json("/Users") do
      Enum.reduce_while(users, {:ok, []}, fn user, {:ok, acc} ->
        case list_played_items_for(user["Id"]) do
          {:ok, items} -> {:cont, {:ok, items ++ acc}}
          err -> {:halt, err}
        end
      end)
    end
  end

  defp list_played_items_for(user_id) do
    query =
      URI.encode_query(%{
        "userId" => user_id,
        "recursive" => "true",
        "isPlayed" => "true",
        "mediaTypes" => "Video",
        "fields" => "Path",
        "enableUserData" => "true",
        "enableImages" => "false"
      })

    with {:ok, %{"Items" => items}} <- get_json("/Items?" <> query) do
      {:ok,
       Enum.flat_map(items, fn item ->
         case to_pinchflat_path(item["Path"]) do
           nil ->
             []

           filepath ->
             [%{filepath: filepath, last_played_at: parse_datetime(get_in(item, ["UserData", "LastPlayedDate"]))}]
         end
       end)}
    end
  end

  defp to_pinchflat_path(nil), do: nil

  defp to_pinchflat_path(jellyfin_path) do
    media_directory = Application.get_env(:pinchflat, :media_directory)
    jellyfin_media_path = config(:jellyfin_media_path) || media_directory

    case Path.relative_to(jellyfin_path, jellyfin_media_path) do
      # `relative_to/2` hands the path back unchanged when it isn't inside the directory
      ^jellyfin_path -> nil
      relative_path -> Path.join(media_directory, relative_path)
    end
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(string) do
    case DateTime.from_iso8601(string) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp get_json(path) do
    url = String.trim_trailing(config(:jellyfin_url), "/") <> path
    headers = [accept: "application/json", authorization: ~s(MediaBrowser Token="#{config(:jellyfin_api_key)}")]

    with {:ok, body} <- http_client().get(url, headers, timeout: 30_000),
         {:ok, decoded} <- Jason.decode(body) do
      {:ok, decoded}
    else
      {:error, %Jason.DecodeError{}} -> {:error, "Jellyfin returned something that isn't JSON for #{path}"}
      {:error, reason} -> {:error, "Jellyfin request to #{path} failed: #{reason}"}
    end
  end

  defp config(key), do: Application.get_env(:pinchflat, key)

  defp http_client do
    Application.get_env(:pinchflat, :http_client, Pinchflat.HTTP.HTTPClient)
  end
end
