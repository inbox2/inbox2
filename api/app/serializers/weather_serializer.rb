# Serializes a WeatherService::Result (a plain Struct, not an AR model — so it
# includes Alba::Resource directly rather than inheriting ApplicationSerializer, which
# assumes a `key`). `short` is the ready-to-speak line; null when weather is unavailable.
class WeatherSerializer
  include Alba::Resource

  attributes :short, :temp_c, :code, :place
end
