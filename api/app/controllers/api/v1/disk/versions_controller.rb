module Api
  module V1
    module Disk
      # File history, downloads of one version, and the presigned PUTs for its
      # thumbnail and rendition (which do not count toward quota).
      class VersionsController < BaseController
        # GET /nodes/:id/versions?cursor=&limit=
        def index
          node = find_node!(params[:id])
          rows, next_cursor = paginate_cursor(node.versions.includes(:node, author: :user).order(number: :desc))
          render json: { versions: ::Disk::VersionSerializer.new(rows).to_h, next_cursor: next_cursor }
        end

        # GET /versions/:id/download?variant=thumbnail|rendition
        def download
          version = find_version!
          variant = params[:variant].presence
          raise ::Disk::Refused, "variant must be thumbnail or rendition" if variant && ::Disk::Version::VARIANTS.exclude?(variant)

          render_download(version, variant)
        end

        # POST /versions/:id/restore — becomes the newest version. A sealed one
        # answers { upload }: the copied object's reservation, completed with K_v
        # re-wrapped under the current epoch (build guide 6.8).
        def restore
          version = ops.restore_version(find_version!)
          return render json: { upload: ::Disk::UploadSerializer.new(version).to_h }, status: :created if version.is_a?(::Disk::Upload)

          node = version.node.reload
          render json: { node: node_json(node), version: ::Disk::VersionSerializer.new(version).to_h }, status: :created
        end

        # PUT /versions/:id/thumbnail and /rendition — a presigned PUT for the derived object;
        # then the same call with `landed=1` once the PUT succeeded. Only that second call
        # records the object on the version: recording it at presign left a version that
        # claimed an exact view (or thumbnail) whose upload had failed.
        def thumbnail = derived(::Disk::Version::VARIANT_THUMBNAIL)
        def rendition = derived(::Disk::Version::VARIANT_RENDITION)

        private

        def find_version!
          ::Disk::Version.where(node_id: visible_nodes.select(:id)).includes(:node).find_by!(key: params[:id].to_s)
        end

        def derived(variant)
          version = find_version!
          ops.require_role!(version.node, ::Disk::ROLE_EDIT)
          version.node.write_check!(membership) if version.node.sealed? # sealed under K_v, so any epoch
          key = version.variant_key(variant)
          storage = ::Disk::Storage.current
          unless ActiveModel::Type::Boolean.new.cast(params[:landed])
            url = ::Disk::PresignedUrlSerializer::Url.new(url: storage.put_url(key), expires_at: ::Disk::Storage::PUT_URL_TTL.from_now)
            return render json: { upload: ::Disk::PresignedUrlSerializer.new(url).to_h }
          end

          raise ::Disk::Refused, "The #{variant} has not been uploaded" unless storage.size(key)

          version.update!("#{variant}_storage_key" => key)
          render json: { version: ::Disk::VersionSerializer.new(version).to_h }
        end
      end
    end
  end
end
