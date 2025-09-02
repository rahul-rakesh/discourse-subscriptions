import Controller from "@ember/controller";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { htmlSafe } from "@ember/template";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import discourseComputed from "discourse/lib/decorators";
import { i18n } from "discourse-i18n";
import GrantSubscriptionModal from "../components/modal/grant-subscription"; // ADD THIS IMPORT

export default class AdminPluginsDiscourseSubscriptionsController extends Controller {
  @service dialog;
  @service modal;

  loading = false;

  @discourseComputed
  stripeConfigured() {
    return !!this.siteSettings.discourse_subscriptions_public_key;
  }

  @action
  showGrantSubscriptionModal() {
    // This now shows our new modal component instead of an alert
    this.modal.show(GrantSubscriptionModal, {
      model: {} // We can pass data to the modal here later
    });
  }
}
