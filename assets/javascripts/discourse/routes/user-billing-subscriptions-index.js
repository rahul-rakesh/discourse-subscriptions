import { action } from "@ember/object";
import Route from "@ember/routing/route";
import { service } from "@ember/service";
import { i18n } from "discourse-i18n";
import UserSubscription from "discourse/plugins/discourse-subscriptions/discourse/models/user-subscription";
import { popupAjaxError } from "discourse/lib/ajax-error";

export default class UserBillingSubscriptionsIndexRoute extends Route {
  @service dialog;
  @service router;

  model() {
    console.log("[SUBS DEBUG] Frontend: Fetching subscriptions from server...");
    return UserSubscription.findAll().then((result) => {
      console.log("[SUBS DEBUG] Frontend: Received data from server:", result);
      if (Array.isArray(result)) {
        return result.map((sub) => UserSubscription.create(sub));
      }
      console.error("[SUBS DEBUG] Frontend: Server response is NOT an array.", result);
      return []; // Return empty array on failure to prevent crash
    });
  }

  @action
  cancelSubscription(subscription) {
    this.dialog.yesNoConfirm({
      message: i18n(
          "discourse_subscriptions.user.subscriptions.operations.destroy.confirm"
      ),
      didConfirm: () => {
        console.log("[SUBS DEBUG] Frontend: 'Cancel' confirmed for subscription:", subscription.id);
        subscription.set("loading", true);
        subscription.destroy()
            .then(updatedSubscription => {
              console.log("[SUBS DEBUG] Frontend: 'destroy' promise resolved. Data from server:", updatedSubscription);

              // This is the object with the new status and date
              const newProperties = {
                status: updatedSubscription.status,
                renews_at: updatedSubscription.renews_at
              };

              console.log("[SUBS DEBUG] Frontend: Updating model properties with:", newProperties);
              subscription.setProperties(newProperties);
            })
            .catch(popupAjaxError)
            .finally(() => {
              console.log("[SUBS DEBUG] Frontend: 'finally' block. Setting loading to false.");
              subscription.set("loading", false)
            });
      },
    });
  }
}
