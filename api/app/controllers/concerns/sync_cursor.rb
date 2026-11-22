# The transaction-horizon cursor shared by the MX feed (Api::V1::SyncController)
# and the Disk feed (Api::V1::Disk::SyncController). See docs/MX-Sync.md.
module SyncCursor
  private

  # Everything below this xid is committed or rolled back — a stable set.
  def horizon
    ActiveRecord::Base.connection.select_value("SELECT pg_snapshot_xmin(pg_current_snapshot())::text::bigint").to_i
  end

  # The next xid to be assigned: no real cursor can be past it.
  def next_xid
    ActiveRecord::Base.connection.select_value("SELECT pg_snapshot_xmax(pg_current_snapshot())::text::bigint").to_i
  end

  # Drained (no more rows): jump to the horizon so the next pull skips the scan.
  # (`last` can sit past the horizon only for rows written by this very transaction.)
  def next_cursor(has_more, last, hi, xid, seq)
    return encode_cursor(last[:xid], last[:seq]) if has_more

    encode_cursor(*[[hi, 0], last ? [last[:xid], last[:seq]] : [xid, seq]].max)
  end

  def clamp(value, default, max)
    n = value.to_i
    n.positive? ? [n, max].min : default
  end

  # Opaque to clients. Blank = from the beginning.
  def encode_cursor(xid, seq) = "#{xid}.#{seq}"

  def decode_cursor(raw)
    return [0, 0] if raw.blank?

    m = /\A(\d+)\.(\d+)\z/.match(raw.to_s)
    m && [m[1].to_i, m[2].to_i]
  end

  def render_bad_cursor
    render json: ErrorSerializer.serialize("Invalid cursor", status: 422), status: :unprocessable_content
  end
end
