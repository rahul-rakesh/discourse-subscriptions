/* global Stripe, Razorpay */
import Controller from "@ember/controller";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { tracked } from "@glimmer/tracking";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { i18n } from "discourse-i18n";
import User from "discourse/models/user";

export default class SubscribeIndexController extends Controller {
  @service dialog;
  @service router;
  @service siteSettings;
  @service currentUser;

  @tracked loading = false;

  @action
  startCheckout(product, plan) {
    this.loading = true;

    // We now directly call the backend to create a payment session
    ajax("/s/create", {
      method: "POST",
      data: { plan: plan.id },
    })
        .then(result => {
          if (this.siteSettings.discourse_subscriptions_payment_provider === "Razorpay") {
            this.processRazorpayPayment(product, result);
          } else { // Stripe
            const stripe = Stripe(this.siteSettings.discourse_subscriptions_public_key);
            stripe.redirectToCheckout({ sessionId: result.session_id });
          }
        })
        .catch(popupAjaxError)
        .finally(() => {
          this.loading = false;
        });
  }

  processRazorpayPayment(product, order) {
    const options = {
      key: this.siteSettings.discourse_subscriptions_razorpay_key_id,
      amount: order.amount,
      currency: order.currency,
      name: product.name,
      order_id: order.id,
      handler: (response) => {
        ajax("/s/finalize_razorpay_payment", {
          method: "POST",
          data: { ...response, plan_id: order.notes.plan_id }
        })
            .then(() => this._advanceSuccessfulTransaction())
            .catch(popupAjaxError);
      },
      prefill: {
        name: this.currentUser.name || this.currentUser.username,
        email: this.currentUser.email,
      },
      theme: { color: "#3399cc" },
      modal: {
        ondismiss: () => { this.loading = false; }
      }
    };
    new Razorpay(options).open();
    this.loading = false;
  }

  _advanceSuccessfulTransaction() {
    this.dialog.alert(i18n("discourse_subscriptions.plans.success"));
    this.loading = false;
    this.router.transitionTo("user.billing.subscriptions", this.currentUser.username);
  }
}
