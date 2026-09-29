defmodule Pinchflat.Repo.Migrations.AddMaxAgeDaysToSources do
  use Ecto.Migration

  # Nullable with no default: `nil` means "no maximum age", which is what every existing
  # source keeps doing.
  def change do
    alter table(:sources) do
      add :max_age_days, :integer
    end
  end
end
