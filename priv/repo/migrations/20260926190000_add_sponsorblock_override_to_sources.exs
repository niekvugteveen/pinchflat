defmodule Pinchflat.Repo.Migrations.AddSponsorblockOverrideToSources do
  use Ecto.Migration

  # Both columns are nullable with no default on purpose: `nil` means "use the media
  # profile's SponsorBlock settings", which is what every existing source keeps doing.
  def change do
    alter table(:sources) do
      add :sponsorblock_behaviour, :string
      add :sponsorblock_categories, {:array, :string}
    end
  end
end
