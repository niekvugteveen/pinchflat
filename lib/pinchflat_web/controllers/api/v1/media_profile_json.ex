defmodule PinchflatWeb.Api.V1.MediaProfileJSON do
  @moduledoc """
  Renders media profiles for the JSON API.
  """

  alias Pinchflat.Profiles.MediaProfile

  @doc """
  Renders a list of media profiles.
  """
  def index(%{media_profiles: media_profiles}) do
    %{media_profiles: Enum.map(media_profiles, &data/1)}
  end

  @doc """
  Renders a single media profile. Deliberately minimal - a client only needs enough to
  pick one, and the full profile is a large and frequently-changing struct.
  """
  def data(%MediaProfile{} = media_profile) do
    %{
      id: media_profile.id,
      name: media_profile.name
    }
  end
end
