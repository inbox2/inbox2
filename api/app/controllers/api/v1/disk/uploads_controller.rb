module Api
  module V1
    module Disk
      # The upload protocol (docs/plans/disk-build.md section 8). The bytes go
      # from the browser straight to storage through presigned part URLs.
      class UploadsController < BaseController
        # POST /uploads { parent_id | node_id, name, size_bytes, on_conflict, idempotency_key, staged,
        #                 sealed, chunk_bytes, key_epoch, id, metadata_ciphertext }
        # Sealed (build guide 6.5, 6.6): size_bytes is the ciphertext size; a new
        # file brings its proposed id and metadata_ciphertext.
        def create
          p = params.permit(:parent_id, :node_id, :name, :size_bytes, :on_conflict, :idempotency_key, :sealed,
                            :chunk_bytes, :key_epoch, :metadata_ciphertext, :id, :staged)
          raise ActionController::ParameterMissing, :parent_id if p[:parent_id].blank? && p[:node_id].blank?

          upload, created = uploads.reserve(
            size: params.require(:size_bytes), parent_key: p[:parent_id], node_key: p[:node_id], name: p[:name],
            on_conflict: p[:on_conflict], idempotency_key: p[:idempotency_key],
            sealed: ActiveModel::Type::Boolean.new.cast(p[:sealed]) || false, chunk_bytes: p[:chunk_bytes],
            key_epoch: p[:key_epoch], metadata_ciphertext: p[:metadata_ciphertext], id: p[:id],
            staged: ActiveModel::Type::Boolean.new.cast(p[:staged]) || false
          )
          render json: { upload: upload_json(upload) }, status: created ? :created : :ok
        end

        # GET /uploads/:id — state plus the parts storage holds, to resume after a reload.
        def show
          upload = uploads.find!(params[:id])
          render json: { upload: upload_json(upload),
                         parts: ::Disk::StoredPartSerializer.new(uploads.stored_parts(upload)).to_h }
        end

        # POST /uploads/:id/parts { numbers: [1, 2, ...] }
        def parts
          urls = uploads.issue_parts(uploads.find!(params[:id]), params.require(:numbers))
          expires_at = ::Disk::Storage::PART_URL_TTL.from_now
          parts = urls.map { |u| ::Disk::PresignedUrlSerializer::Url.new(**u, expires_at: expires_at) }
          render json: { parts: ::Disk::PresignedUrlSerializer.new(parts).to_h }
        end

        # POST /uploads/:id/complete { sha256 } or, sealed, { wrapped_key, manifest_ciphertext },
        # plus metadata_ciphertext when completing a sealed copy.
        def complete
          node, version = uploads.complete(uploads.find!(params[:id]), sha256: params[:sha256],
                                                                       wrapped_key: params[:wrapped_key],
                                                                       manifest_ciphertext: params[:manifest_ciphertext],
                                                                       metadata_ciphertext: params[:metadata_ciphertext])
          render json: { node: node_json(node.reload), version: ::Disk::VersionSerializer.new(version).to_h }
        end

        # DELETE /uploads/:id — cancel and release the reservation.
        def destroy
          render json: { upload: upload_json(uploads.abort(uploads.find!(params[:id]))) }
        end

        private

        def uploads = @uploads ||= ::Disk::UploadOps.new(membership)
        def upload_json(upload) = ::Disk::UploadSerializer.new(upload).to_h
      end
    end
  end
end
