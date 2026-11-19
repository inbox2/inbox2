module Api
  module V1
    class NotificationsController < BaseController
      # spec 10.1, A14.1
      def index
        notifications = current_user.notifications.recent.includes(:conversation).limit(50)
        render json: { notifications: notifications.map { |n| NotificationSerializer.new(n).to_h } }
      end

      # spec 10.1, A14.2
      def mark_read
        notification_ids = params[:notification_ids] || []

        if notification_ids.empty?
          current_user.notifications.unread.update_all(read: true)
        else
          current_user.notifications.where(key: notification_ids).update_all(read: true)
        end

        head :no_content
      end

      # spec 10.2/10.3 (A14.3) notification preferences: not built. The hardcoded
      # stub that used to answer here was removed 2026-10-18 — no client read it.
    end
  end
end
