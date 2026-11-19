module Api
  module V1
    module Disk
      # Importers (spec F10, build guide 7 and 9b): connect a source with a
      # read-only grant, start imports, follow progress, resume, cancel, report.
      class ImportsController < BaseController
        # The provider's redirect carries no inbox2 session; the signed,
        # expiring state minted in #connect for a live membership is the authorization.
        skip_before_action :authenticate_user!, only: :callback
        skip_before_action :enforce_api_key_scope!, only: :callback
        skip_before_action :require_organization!, only: :callback
        skip_before_action :require_disk!, only: :callback

        STATE_TTL = 15.minutes
        Space = ::Disk::Importer::Space
        Import = ::Disk::Import
        Connection = ::Disk::ImportConnection

        # GET /imports/sources — offered sources only (configured and allowed, gate G7).
        def sources
          list = ::Disk::ImportSource::PROVIDERS.select { |p| offered?(p) }.map { |p| source_for(p) }
          render json: { sources: ::Disk::ImportSourceSerializer.new(list).to_h }
        end

        # POST /imports/:provider/connect { reach: member|org } — the consent URL.
        def connect
          provider = offered_provider!
          reach = reach_param
          require_admin! if reach == Connection::REACH_ORG
          client = ::Disk::ImportSource.client(provider)
          state = self.class.verifier.generate({ "m" => membership.key, "o" => current_organization.slug, "r" => reach,
                                                 "p" => provider, "n" => SecureRandom.hex(16) }, expires_in: STATE_TTL)
          scope = ::Disk::ImportSource.scope(provider, reach)
          url = if provider == ::Disk::ImportSource::MICROSOFT && reach == Connection::REACH_ORG
            # Application permissions need a tenant admin's consent, not a user grant.
            "#{::Disk::Importer::Microsoft.at(:login)}/organizations/v2.0/adminconsent?" +
              { client_id: client[:id], scope: scope, redirect_uri: callback_uri(provider), state: state }.to_query
          else
            OauthProvider.authorize_uri(provider, redirect_uri: callback_uri(provider), state: state, scope: scope,
                                                  client: client)
          end
          render json: ::Disk::ImportConnectSerializer.new(::Disk::ImportConnectSerializer::Connect.new(authorize_url: url)).to_h
        end

        # GET /api/v1/disk/imports/:provider/callback — the provider's redirect.
        def callback
          provider = params[:provider].to_s
          data = self.class.verifier.verified(params[:state].to_s)
          return redirect_to(web_url(nil, provider, "error"), allow_other_host: true) unless data && data["p"] == provider &&
                                                                                           state_unused?(data["n"])

          slug = data["o"]
          m = Membership.find_by(key: data["m"], status: Membership::STATUS_ACTIVE)
          reach = data["r"]
          ok = m && ::Disk::ImportSource.known?(provider) && params[:error].blank? &&
               (reach == Connection::REACH_MEMBER || m.admin?)
          return redirect_to(web_url(slug, provider, "error"), allow_other_host: true) unless ok

          connection = Connection.find_or_initialize_by(membership: m, provider: provider, reach: reach)
          connection.organization_id = m.organization_id
          if provider == ::Disk::ImportSource::MICROSOFT && reach == Connection::REACH_ORG
            return redirect_to(web_url(slug, provider, "error"), allow_other_host: true) unless
              params[:admin_consent].to_s.casecmp?("true") && params[:tenant].present?

            connection.assign_attributes(tenant: params[:tenant].to_s, refresh_token: nil, access_token: nil)
          else
            tokens = OauthProvider.exchange_code(provider, params.require(:code), callback_uri(provider),
                                                 scope: ::Disk::ImportSource.scope(provider, reach),
                                                 client: ::Disk::ImportSource.client(provider))
            return redirect_to(web_url(slug, provider, "error"), allow_other_host: true) if tokens["refresh_token"].blank?

            connection.assign_attributes(refresh_token: tokens["refresh_token"], access_token: tokens["access_token"],
                                         access_expires_at: (tokens["expires_in"] || 3600).to_i.seconds.from_now)
            ::Disk::ImportSource.adapter(provider)&.identify(connection, tokens)
          end
          connection.save!
          redirect_to web_url(slug, provider, "connected"), allow_other_host: true
        rescue OauthProvider::Error, ::Disk::Refused => e
          Rails.logger.warn("[Disk import] #{provider} connect failed: #{e.message}")
          redirect_to web_url(slug, provider, "error"), allow_other_host: true
        end

        # DELETE /imports/:provider/connection?reach= — forget the stored grant.
        def disconnect
          provider = params[:provider].to_s
          raise ::Disk::Refused.new("Not found", status: 404) unless ::Disk::ImportSource.known?(provider)

          Connection.find_by!(membership: membership, provider: provider, reach: reach_param).destroy!
          head :no_content
        end

        # GET /imports?cursor= — this member's imports, every import for owners and admins.
        def index
          rows, next_cursor = paginate_cursor(visible.includes(:target_node, :share, :connection, owner: :user,
                                                                                            membership: :user)
                                                     .order(created_at: :desc, id: :desc))
          render json: { imports: ::Disk::ImportSerializer.new(rows).to_h, next_cursor: next_cursor }
        end

        # POST /imports { provider, spaces: [space ids], target_id? }. "personal"
        # lands in a folder named for the source under target_id (default the
        # member's C:\); shared spaces become shares and member spaces land in
        # the matching member's C:\ (owners and admins). A space imported
        # before into a target still there continues that import: same
        # target, only what changed since.
        def create
          provider = offered_provider!
          ids = Array(params.require(:spaces)).map(&:to_s).uniq
          raise ::Disk::Refused, "Choose at least one space to import" if ids.empty?

          spaces = ids.map { |id| resolve_space(provider, id) }
          imports = spaces.map { |space, connection| start(provider, space, connection) }
          render json: { imports: ::Disk::ImportSerializer.new(imports).to_h }, status: :created
        end

        # GET /imports/:id
        def show
          render json: { import: ::Disk::ImportSerializer.new(find_import!).to_h }
        end

        # POST /imports/:id/resume — after a quota, cap, authorisation or error pause.
        def resume
          import = find_import!
          raise ::Disk::Refused.new("This import is not paused", status: 409) unless import.resumable?

          import.update!(state: Import::STATE_QUEUED, pause_reason: nil, error: nil)
          ::Disk::ImportJob.perform_later(import.id)
          render json: { import: ::Disk::ImportSerializer.new(import).to_h }
        end

        # DELETE /imports/:id — cancel. What was imported stays.
        def destroy
          import = find_import!
          raise ::Disk::Refused.new("This import has already finished", status: 409) if
            [Import::STATE_DONE, Import::STATE_SKIPPED].include?(import.state)

          import.update!(state: Import::STATE_CANCELLED) unless import.cancelled?
          render json: { import: ::Disk::ImportSerializer.new(import).to_h }
        end

        # GET /imports/:id/report?cursor=&download=1 — counts, unmatched people
        # and groups on the first page, then the notable items 100 a page.
        def report
          import = find_import!
          notable = import.items.includes(:node).order(:id)
            .where("status <> ? OR jsonb_exists_any(detail, array['renamed_from','moved','converted'," \
                   "'deleted_at_source','public_link'])", ::Disk::ImportItem::STATUS_DONE)
          rows, next_cursor = paginate_cursor(notable)
          page = ::Disk::ImportReportSerializer::Page.new(import: import, entries: rows, next_cursor: next_cursor,
                                                          first: params[:cursor].blank?)
          if params[:download].present?
            response.headers["Content-Disposition"] =
              ActionDispatch::Http::ContentDisposition.format(disposition: "attachment",
                                                              filename: "import-report-#{import.key}.json")
          end
          render json: { report: ::Disk::ImportReportSerializer.new(page).to_h }
        end

        def self.verifier = Rails.application.message_verifier(:disk_import)

        private

        # One callback per state: the first claims its nonce for the state's
        # lifetime (the unless_exist claim mobile_push_sender uses; Solid Cache
        # in production, so it holds across pods).
        def state_unused?(nonce)
          nonce.present? && Rails.cache.write("disk_import:state:#{nonce}", true, expires_in: STATE_TTL, unless_exist: true)
        end

        def offered?(provider) = ::Disk::ImportSource.offered?(provider, current_organization) &&
                                 ::Disk::ImportSource.adapter(provider)

        def offered_provider!
          provider = params[:provider].to_s
          raise ::Disk::Refused.new("Not found", status: 404) unless ::Disk::ImportSource.known?(provider)

          ::Disk::ImportSource.client(provider) # 503 when this server has no app for it
          unless offered?(provider)
            raise ::Disk::Refused.new("The #{OauthProvider.label(provider)} importer is not yet available " \
                                      "for this organization", status: 403)
          end
          provider
        end

        def reach_param
          reach = params[:reach].presence || Connection::REACH_MEMBER
          raise ::Disk::Refused, "reach must be member or org" unless Connection::REACHES.include?(reach)

          reach
        end

        # Every provider's connections in one query (#sources asks per provider
        # and per reach).
        def connection_for(provider, reach)
          @connections ||= Connection.where(membership: membership).to_a
          @connections.find { |c| c.provider == provider && c.reach == reach }
        end

        def source_for(provider)
          mine = connection_for(provider, Connection::REACH_MEMBER)
          org = admin? ? connection_for(provider, Connection::REACH_ORG) : nil
          spaces = mine || org ? [] : nil
          spaces << Space.new(id: Import::SPACE_PERSONAL, kind: Import::SPACE_PERSONAL, name: personal_name(provider)) if mine
          error = nil
          begin
            if org
              index = ::Disk::ImportSource.member_index(current_organization)
              spaces.concat(org_spaces(provider, org).each { |s| s.member = index[s.email.to_s.downcase] if s.email })
            end
          rescue ::Disk::Importer::Throttled, ::Disk::Importer::Stop, ::Disk::Importer::ItemFailed, OauthProvider::Error,
                 Http::Incomplete => e
            error = e.message
          end
          ::Disk::ImportSourceSerializer::Source.new(provider: provider, connection: mine, org_connection: org,
                                                     org_available: admin?, spaces: spaces, spaces_error: error)
        end

        Http = ::Disk::Importer::Http

        def org_spaces(provider, connection)
          probe = Import.new(organization: current_organization, membership: membership, provider: provider,
                             connection: connection, space_kind: Import::SPACE_SHARED)
          ::Disk::Importer.for(probe).spaces
        end

        def personal_name(provider) = ::Disk::ImportSource::FOLDER_NAMES[provider]

        # [Space, connection] for a requested space id, refusing what this member may not import.
        def resolve_space(provider, id)
          if id == Import::SPACE_PERSONAL
            conn = connection_for(provider, Connection::REACH_MEMBER) ||
                   raise(::Disk::Refused, "Connect #{OauthProvider.label(provider)} first")
            return [Space.new(id: id, kind: Import::SPACE_PERSONAL, name: personal_name(provider)), conn]
          end

          require_admin!
          conn = connection_for(provider, Connection::REACH_ORG) ||
                 raise(::Disk::Refused, "Connect #{OauthProvider.label(provider)} for the organization first")
          @org_spaces ||= org_spaces(provider, conn)
          space = @org_spaces.find { |s| s.id == id } || raise(::Disk::Refused.new("No such space at the source: #{id}", status: 404))
          [space, conn]
        rescue ::Disk::Importer::Throttled, ::Disk::Importer::Stop, ::Disk::Importer::ItemFailed, OauthProvider::Error => e
          raise ::Disk::Refused.new("#{OauthProvider.label(provider)} could not list its spaces: #{e.message}", status: 502)
        end

        def start(provider, space, connection)
          attrs = { organization: current_organization, membership: membership, connection: connection,
                    provider: provider, space_kind: space.kind, space_id: space.id, space_name: space.name,
                    source_email: space.email }
          case space.kind
          when Import::SPACE_SHARED then start_shared(attrs, space)
          when Import::SPACE_MEMBER
            owner = ::Disk::ImportSource.member_index(current_organization)[space.email.to_s.downcase]
            unless owner
              return Import.create!(attrs.merge(state: Import::STATE_SKIPPED,
                                                error: "No member of this organization uses #{space.email}, so we skipped their files"))
            end
            start_in_c(attrs.merge(owner: owner), ::Disk::Node.c_root_for(owner))
          else start_in_c(attrs.merge(owner: membership), personal_parent)
          end
        end

        def personal_parent
          return ::Disk::Node.c_root_for(membership) if params[:target_id].blank?

          parent = ops.writable_folder!(params[:target_id])
          raise ::Disk::Refused, "Imported files are not sealed, so they can't go into a sealed folder" if parent.sealed?
          raise ::Disk::Refused, "Imports go into a folder, not a page" if parent.page?

          parent
        end

        # Into a folder named for the source under parent, or the folder an
        # earlier import of this space made there.
        def start_in_c(attrs, parent)
          earlier = previous(attrs, owner_membership_id: attrs[:owner].id)
          return earlier if earlier&.then { |e| e.state.in?(Import::ACTIVE_STATES + [Import::STATE_PAUSED]) }

          target = earlier&.target_node
          target = nil unless target && !target.trashed? && target.parent_id == parent.id
          target ||= ::Disk::NodeOps.new(attrs[:owner])
            .create_folder(parent_key: parent.key, name: personal_name(attrs[:provider]), keep_both: true)
          queue(attrs.merge(target_node: target, cursor: carried_cursor(earlier, target)))
        end

        def start_shared(attrs, space)
          earlier = previous(attrs)
          return earlier if earlier&.then { |e| e.state.in?(Import::ACTIVE_STATES + [Import::STATE_PAUSED]) }

          share = earlier&.share
          share = nil if share.nil? || share.trashed?
          share ||= ::Disk::Share.create_with_root!(organization: current_organization, name: share_name(space.name),
                                                    openness: ::Disk::Share::OPENNESS_ASSIGNED,
                                                    org_role: ::Disk::ROLE_VIEW).tap do |s|
            ::Disk::Event.record!(::Disk::Event::ACTION_SHARE_CREATED, actor: membership, share: s, name: s.name,
                                                                       imported_from: attrs[:provider])
          end
          queue(attrs.merge(owner: membership, share: share, target_node: share.root_node,
                            cursor: carried_cursor(earlier, share.root_node)))
        end

        def previous(attrs, **extra)
          Import.where(organization: current_organization, provider: attrs[:provider], space_id: attrs[:space_id],
                       space_kind: attrs[:space_kind], **extra)
            .where.not(state: [Import::STATE_CANCELLED, Import::STATE_SKIPPED]).order(created_at: :desc).first
        end

        # A finished import's change token, when the new run goes into the same target.
        def carried_cursor(earlier, target)
          earlier.cursor if earlier&.done? && earlier.target_node_id == target.id
        end

        def share_name(name)
          base = name.to_s.strip.first(100).presence || "Imported"
          taken = ::Disk::Share.where(organization_id: current_organization.id).live.pluck(Arel.sql("lower(name)")).to_set
          n = 1
          candidate = base
          candidate = "#{base} (#{n += 1})" while taken.include?(candidate.downcase)
          candidate
        end

        def queue(attrs)
          import = Import.create!(attrs.merge(state: Import::STATE_QUEUED))
          ::Disk::ImportJob.perform_later(import.id)
          import
        end

        def visible
          rel = Import.where(organization_id: current_organization.id)
          admin? ? rel : rel.where(membership_id: membership.id).or(rel.where(owner_membership_id: membership.id))
        end

        def find_import! = visible.find_by!(key: params[:id].to_s)

        # Must match between #connect and #callback byte for byte.
        def callback_uri(provider) = "#{request.base_url}/api/v1/disk/imports/#{provider}/callback"

        def web_url(slug, provider, status)
          return ::Disk::WebPath.url("/disk") if slug.blank?

          "#{::Disk::WebPath.url(::Disk::WebPath.org_home(slug, 'import'))}&source=#{provider}&status=#{status}"
        end
      end
    end
  end
end
