# frozen_string_literal: true

module DiscourseSubscriptions
  class HooksController < ::ApplicationController
    include DiscourseSubscriptions::Group
    include DiscourseSubscriptions::Stripe

    requires_plugin DiscourseSubscriptions::PLUGIN_NAME

    layout false

    before_action :set_api_key, except: [:razorpay]
    skip_before_action :check_xhr
    skip_before_action :redirect_to_login_if_required
    skip_before_action :verify_authenticity_token, only: %i[create razorpay]

    def create
      Rails.logger.warn("[SUBS WEBHOOK DEBUG] Received a webhook request at /s/hooks.")
      begin
        payload = request.body.read
        sig_header = request.env["HTTP_STRIPE_SIGNATURE"]
        webhook_secret = SiteSetting.discourse_subscriptions_webhook_secret
        event = ::Stripe::Webhook.construct_event(payload, sig_header, webhook_secret)
        Rails.logger.warn("[SUBS WEBHOOK DEBUG] Webhook signature verified. Event type: #{event[:type]}.")
      rescue JSON::ParserError => e
        Rails.logger.error("[SUBS WEBHOOK DEBUG] JSON Parser Error: #{e.message}")
        return render_json_error e.message
      rescue ::Stripe::SignatureVerificationError => e
        Rails.logger.error("[SUBS WEBHOOK DEBUG] Signature Verification Error: #{e.message}")
        return render_json_error e.message
      end

      case event[:type]
      when "checkout.session.completed"
        Rails.logger.warn("[SUBS WEBHOOK DEBUG] Processing checkout.session.completed.")
        checkout_session = event[:data][:object]

        email = checkout_session.dig(:customer_details, :email)
        Rails.logger.warn("[SUBS WEBHOOK DEBUG] Session status: #{checkout_session[:status]}, Payment status: #{checkout_session[:payment_status]}, Email: #{email}")

        if checkout_session[:payment_status] != "paid"
          Rails.logger.warn("[SUBS WEBHOOK DEBUG] Exiting because payment_status is not 'paid'.")
          return head 200
        end

        user = ::User.find_by_username_or_email(email)
        unless user
          Rails.logger.warn("[SUBS WEBHOOK DEBUG] User not found for email: #{email}. Exiting.")
          return render_json_error "user not found"
        end
        Rails.logger.warn("[SUBS WEBHOOK DEBUG] User found: #{user.username}.")

        line_items = ::Stripe::Checkout::Session.list_line_items(checkout_session[:id], { limit: 1 })
        item = line_items[:data].first
        plan = item[:price]
        group = plan_group(plan)

        Rails.logger.warn("[SUBS WEBHOOK DEBUG] Finalizing subscription creation for plan #{plan.id}.")

        discourse_customer = Customer.find_or_create_by(user_id: user.id) do |c|
          c.customer_id = checkout_session[:customer]
        end

        Subscription.create!(
          customer_id: discourse_customer.id,
          external_id: checkout_session[:subscription] || checkout_session[:id],
          plan_id: plan.id,
          provider: 'Stripe',
          status: 'active'
        )

        group&.add(user)

        Rails.logger.warn("[SUBS WEBHOOK DEBUG] Process completed successfully.")


      when "customer.subscription.updated"
        subscription = event[:data][:object]
        status = subscription[:status]
        return head 200 if !%w[complete active].include?(status)

        customer = find_active_customer(subscription[:customer], subscription[:plan][:product])
        return render_json_error "customer not found" if !customer

        update_status(customer.id, subscription[:id], status)

        user = ::User.find_by(id: customer.user_id)
        return render_json_error "user not found" if !user

        if group = plan_group(subscription[:plan])
          group.add(user)
        end

      when "customer.subscription.deleted"
        subscription = event[:data][:object]

        local_sub = ::DiscourseSubscriptions::Subscription.find_by(external_id: subscription.id)
        return head 200 unless local_sub # Should not process if we don't have a local record

        customer = find_active_customer(subscription[:customer], subscription[:plan][:product])
        return render_json_error "customer not found" if !customer

        update_status(customer.id, subscription[:id], subscription[:status])

        user = ::User.find(customer.user_id)
        return render_json_error "user not found" if !user

        if group = plan_group(subscription[:plan])
          # FIX: This now calls our new, safer method
          safely_remove_user_from_group(user, group, local_sub.id)
        end
      end

      head 200
    end

    def razorpay
      webhook_secret = SiteSetting.discourse_subscriptions_razorpay_webhook_secret
      webhook_body = request.body.read
      signature = request.env['HTTP_X_RAZORPAY_SIGNATURE']

      begin
        DiscourseSubscriptions::Providers::RazorpayProvider.verify_webhook_signature(webhook_body, signature, webhook_secret)
      rescue ::Razorpay::Error::SignatureVerificationError => e
        Rails.logger.error("Razorpay webhook verification failed: #{e.message}")
        return render_json_error "Invalid webhook signature", status: 403
      end

      event = JSON.parse(webhook_body)

      if event['event'] == 'payment.captured'
        payment_entity = event.dig('payload', 'payment', 'entity')
        payment_id = payment_entity['id']
        notes = payment_entity['notes']

        if notes.blank? || notes['user_id'].blank? || notes['plan_id'].blank?
          Rails.logger.error("Razorpay webhook error: Missing metadata in payment #{payment_id}")
          return render_json_error("Webhook payload is missing required metadata")
        end

        if ::DiscourseSubscriptions::Subscription.exists?(external_id: payment_id)
          return head 200
        end

        user = ::User.find_by(id: notes['user_id'])
        plan = is_stripe_configured? ? ::Stripe::Price.retrieve(notes['plan_id']) : nil

        if user && plan
          transaction = {
            id: payment_id,
            customer: "cus_razorpay_#{user.id}"
          }

          subscribe_controller = DiscourseSubscriptions::SubscribeController.new
          # We must also pass the current_user to the controller instance for it to work
          subscribe_controller.instance_variable_set(:@current_user, user)
          subscribe_controller.send(:finalize_discourse_subscription, transaction, plan)
        else
          Rails.logger.error("Razorpay webhook error: Could not find User(#{notes['user_id']}) or Plan(#{notes['plan_id']})")
        end
      end

      head 200
    end

    private

    def safely_remove_user_from_group(user, group_to_remove_from, current_sub_id)
      other_subscriptions = ::DiscourseSubscriptions::Subscription
                              .joins(:customer)
                              .where(discourse_subscriptions_customers: { user_id: user.id })
                              .where(status: 'active')
                              .where.not(id: current_sub_id)

      has_other_access = other_subscriptions.any? do |sub|
        if sub.plan_id.present?
          begin
            other_plan = ::Stripe::Price.retrieve(sub.plan_id)
            other_group = plan_group(other_plan)
            other_group&.id == group_to_remove_from.id
          rescue ::Stripe::InvalidRequestError
            false
          end
        else
          false
        end
      end

      unless has_other_access
        group_to_remove_from.remove(user)
      end
    end

    def update_status(customer_id, subscription_id, status)
      discourse_subscription =
        Subscription.find_by(customer_id: customer_id, external_id: subscription_id)
      discourse_subscription.update(status: status) if discourse_subscription
    end

    def find_active_customer(customer_id, product_id)
      Customer
        .joins(:subscriptions)
        .where(customer_id: customer_id, product_id: product_id)
        .where(
          Subscription.arel_table[:status].eq(nil).or(
            Subscription.arel_table[:status].not_eq("canceled"),
            ),
          )
        .first
    end
  end
end
