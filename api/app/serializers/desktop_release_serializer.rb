# Serializes a DesktopReleases::Release PORO for the /console download card.
# Not a model (no public `key`), so it includes Alba::Resource directly rather
# than inheriting ApplicationSerializer's `id => key` rule.
class DesktopReleaseSerializer
  include Alba::Resource

  attributes :version, :pub_date

  attribute :downloads do |release|
    release.downloads.map do |d|
      {
        os: d[:os],
        label: d[:label],
        kind: d[:kind],
        filename: d[:filename],
        url: d[:url],
        size: d[:size]
      }
    end
  end
end
