module Disk
  # One page of an import's report (spec F10): counts, the people and groups
  # that could not be matched (first page only), and the items worth naming:
  # skipped, failed, renamed, moved, converted, deleted at the source, or with
  # a public link at the source that was not recreated.
  class ImportReportSerializer
    include Alba::Resource

    Page = Struct.new(:import, :entries, :next_cursor, :first, keyword_init: true)

    attribute :import do |p|
      Disk::ImportSerializer.new(p.import).to_h
    end

    attribute :unmatched_people do |p|
      next nil unless p.first

      p.import.report.fetch("unmatched_people", {}).map { |email, n| { email: email, items: n } }
    end

    attribute :unresolved_groups do |p|
      next nil unless p.first

      p.import.report.fetch("unresolved_groups", {}).map { |name, n| { name: name, items: n } }
    end

    attribute :entries do |p|
      p.entries.map do |item|
        d = item.detail
        { source_id: item.source_id, name: item.name, status: item.status, reason: item.reason,
          node_id: item.node&.key, converted: d["converted"] == true, format: d["format"],
          hash_verified: d["hash_verified"], renamed_from: d["renamed_from"], renamed_to: d["renamed_to"],
          rename_reason: d["rename_reason"], clashed_with: d["clashed_with"], moved: d["moved"] == true,
          deleted_at_source: d["deleted_at_source"] == true, public_link: d["public_link"] == true }
      end
    end

    attributes :next_cursor
  end
end
