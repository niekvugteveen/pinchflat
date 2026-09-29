defmodule Pinchflat.Repo.Migrations.AddDeleteWatchedMediaToSources do
  use Ecto.Migration

  # Off for every existing source: deleting what you've watched is opt-in per source, since
  # for some sources (kids' shows) watching something is a reason to keep it, not to delete it.
  def change do
    alter table(:sources) do
      add :delete_watched_media, :boolean, default: false, null: false
    end
  end
end
